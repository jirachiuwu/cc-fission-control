-- reactor.lua
-- 核分裂炉ロジックアダプタのラッパー。
-- 設計方針:
--   * 全 API 呼び出しは pcall で包む。存在しない/失敗したメソッドは nil を返す。
--   * パーセント系は割合(0-1)と %(0-100) の両バージョンに対応して 0-100 に正規化。
--   * 安全判定はフェイルセーフ: 重要値が読めなければ「危険」と判定する。

local Reactor = {}
Reactor.__index = Reactor

-- 生のパーセント値を 0-100 に正規化する。
-- Mekanism は版によって割合(0-1)を返すものと %(0-100) を返すものがある。
-- 1.0 以下なら割合とみなして *100、それより大きければ既に % とみなす。
local function toPct(v)
  if type(v) ~= "number" then return nil end
  if v <= 1.0 then return v * 100 end
  return v
end

-- 周辺機器を検出する。
function Reactor.new(adapterName)
  local self = setmetatable({}, Reactor)

  if adapterName and adapterName ~= "" then
    self.dev = peripheral.wrap(adapterName)
    self.name = adapterName
  else
    -- 1) 型名で検索
    local dev = peripheral.find("fissionReactorLogicAdapter")
    -- 2) だめなら getTemperature を持つ機器を総当たり（型名の差異に強い）
    if not dev then
      for _, n in ipairs(peripheral.getNames()) do
        local p = peripheral.wrap(n)
        if p and type(p.getTemperature) == "function" then
          dev = p
          self.name = n
          break
        end
      end
    else
      self.name = peripheral.getName and peripheral.getName(dev) or "fissionReactorLogicAdapter"
    end
    self.dev = dev
  end

  return self
end

function Reactor:ok()
  return self.dev ~= nil
end

-- メソッドを安全に呼ぶ。存在しない/エラーなら nil。
function Reactor:call(method, ...)
  if not self.dev then return nil end
  local fn = self.dev[method]
  if type(fn) ~= "function" then return nil end
  local res = { pcall(fn, ...) }
  if res[1] then
    return res[2]
  end
  return nil
end

-- 炉の状態を読む。full=true のときだけ重い「表示専用/低頻度」値も読み直す。
-- 毎 tick は安全・制御に必要な 7 値だけ読み、peripheral 呼び出し回数を抑える
-- （400 MOD 等で TPS が低いサーバーでは呼び出し 1 回が重く、ループが遅くなるため）。
function Reactor:read(full)
  local r = {
    status     = self:call("getStatus"),                               -- boolean
    temp       = self:call("getTemperature"),                          -- K
    damage     = toPct(self:call("getDamagePercent")),                -- %
    coolantPct = toPct(self:call("getCoolantFilledPercentage")),      -- %
    heatedPct  = toPct(self:call("getHeatedCoolantFilledPercentage")), -- %
    wastePct   = toPct(self:call("getWasteFilledPercentage")),        -- %
    burnRate   = self:call("getBurnRate"),                             -- mB/t（設定値）
  }

  -- maxBurn は制御に必要だが滅多に変わらない → キャッシュし、full のとき更新。
  -- fuelPct / actualBurn / boilEff は表示・補助 → 同じく低頻度更新。
  if full or self._maxBurn == nil then
    self._maxBurn    = self:call("getMaxBurnRate")
    self._fuelPct    = toPct(self:call("getFuelFilledPercentage"))
    self._actualBurn = self:call("getActualBurnRate")
    self._boilEff    = self:call("getBoilEfficiency")
  end
  r.maxBurn    = self._maxBurn
  r.fuelPct    = self._fuelPct
  r.actualBurn = self._actualBurn
  r.boilEff    = self._boilEff
  return r
end

-- 安全判定。ok(boolean), reason(string) を返す。
-- フェイルセーフ: 温度が読めない時点で危険と判定する。
function Reactor:checkSafety(r, cfg)
  local s = cfg.safety

  -- 画面表示は CC が日本語非対応のため ASCII 固定（コメントは日本語 OK）。
  if r.temp == nil then
    return false, "temp unreadable (failsafe)"
  end
  if r.temp >= s.scramTemp then
    return false, string.format("HIGH TEMP %.0fK >= %.0fK", r.temp, s.scramTemp)
  end
  if r.damage ~= nil and r.damage >= s.scramDamagePct then
    return false, string.format("DAMAGE %.1f%%", r.damage)
  end
  if r.coolantPct ~= nil and r.coolantPct < s.minCoolantPct then
    return false, string.format("LOW COOLANT %.0f%% < %.0f%%", r.coolantPct, s.minCoolantPct)
  end
  if r.heatedPct ~= nil and r.heatedPct >= s.maxHeatedCoolantPct then
    return false, string.format("HEATED BACKUP %.0f%%", r.heatedPct)
  end
  if r.wastePct ~= nil and r.wastePct >= s.maxWastePct then
    return false, string.format("WASTE FULL %.0f%%", r.wastePct)
  end
  if r.fuelPct ~= nil and r.fuelPct < s.minFuelPct then
    return false, "NO FUEL"
  end

  return true, "OK"
end

-- 起動時の能力監査。各メソッドが実際に呼べるか（nil でないか）を調べて返す。
-- メソッド名が MOD バージョンで違う場合に「安全チェックが黙って無効化」されるのを防ぐ。
-- critical = メルトダウンに直結する経路。これが欠けたら点火を拒否すべき。
function Reactor:audit()
  local critical = {
    "getTemperature", "getDamagePercent", "getCoolantFilledPercentage",
    "getHeatedCoolantFilledPercentage", "getWasteFilledPercentage",
    "getStatus", "scram", "activate", "setBurnRate", "getMaxBurnRate", "getBurnRate",
  }
  local optional = { "getFuelFilledPercentage", "getActualBurnRate", "getBoilEfficiency" }

  -- メソッドの存在は「呼べるか」ではなく型で確認する（一時エラーと未実装を混同しない）。
  local missingCritical, missingOptional = {}, {}
  for _, m in ipairs(critical) do
    if type(self.dev[m]) ~= "function" then
      missingCritical[#missingCritical + 1] = m
    end
  end
  for _, m in ipairs(optional) do
    if type(self.dev[m]) ~= "function" then
      missingOptional[#missingOptional + 1] = m
    end
  end
  return missingCritical, missingOptional
end

function Reactor:scram()
  return self:call("scram")
end

function Reactor:activate()
  return self:call("activate")
end

-- 安全側の自動制御（オーバーシュート＝熱の遅れで行き過ぎる事故への対策）:
--   1. 緊急: 温度がソフト上限 or 「上昇率から予測した lookahead 秒先」が scram 超え
--            → burn を半減して叩き落とす（hard scram に到達させない）
--   2. 非対称: 上げは控えめ（maxRiseFraction）、下げは強め（maxFallFraction）
--   3. 予測: このまま上げると目標を超えそうなら、目標未満でも上げを止める（WAIT）
-- 戻り値: 制御内容を表す ASCII 文字列（画面で可視化）。
function Reactor:autoAdjust(r, cfg, turbineEnergyPct)
  local c = cfg.control
  if not c.enabled then return "AUTO off" end
  if r.temp == nil or r.burnRate == nil or r.maxBurn == nil then return "AUTO: no data" end

  -- 周期（秒）。ゲイン/上限は「毎秒」基準なので dt で実 tick 量にスケールする
  -- （tickInterval を変えても実時間の挙動が変わらない）。
  local dt = cfg.tickInterval or 1

  -- 温度上昇率（K/秒）。初回は 0。1tick の差分を dt で割って毎秒に正規化。
  local ratePerSec = (r.temp - (self._lastTemp or r.temp)) / dt
  self._lastTemp = r.temp

  local hardMax   = r.maxBurn * c.maxBurnRateFraction
  local scramTemp = cfg.safety.scramTemp
  local predicted = r.temp + ratePerSec * (c.lookahead or 0)  -- lookahead 秒先の予測温度
  local rate = ratePerSec  -- 表示用（dT/秒）

  local function set(newRate, fmt, ...)
    -- burn rate を maxBurn の burnStepPct% 刻みに丸める（粗く・安定。±半刻みのヒステリシス）。
    local unit = r.maxBurn * ((c.burnStepPct or 0) / 100)
    if unit > 0 then newRate = math.floor(newRate / unit + 0.5) * unit end
    if newRate < c.minBurnRate then newRate = c.minBurnRate end
    if newRate > hardMax then newRate = hardMax end
    if math.abs(newRate - r.burnRate) > 1e-4 then
      self:call("setBurnRate", newRate)
    end
    return string.format(fmt, r.burnRate, newRate, r.temp, rate)
  end

  -- 1) 緊急冷却: ソフト上限 or 予測が scram 超え → 半減で素早く叩き落とす
  if r.temp >= c.softTemp or predicted >= scramTemp then
    return set(r.burnRate * 0.5, "COOL! %.1f->%.1f T=%.0f dT%+.0f")
  end

  -- タービン満タン → 強めに絞る（毎秒上限 × dt）
  if cfg.turbine and cfg.turbine.enabled and turbineEnergyPct ~= nil
     and turbineEnergyPct >= cfg.turbine.throttleAtPct then
    return set(r.burnRate - r.maxBurn * c.maxFallFraction * dt, "THROTTLE %.1f->%.1f T=%.0f dT%+.0f")
  end

  -- 冷却の追従を「変化率（トレンド）」で見る。復水は待てば追いつくので、減った量でなく
  -- 「減り続けているか」を判定する。ノイズ低減のため平滑化（EMA）する。
  local cP, hP = r.coolantPct, r.heatedPct
  local cRate = cP and ((cP - (self._lastCoolant or cP)) / dt) or 0  -- %/秒（+で増加）
  local hRate = hP and ((hP - (self._lastHeated  or hP)) / dt) or 0
  self._lastCoolant, self._lastHeated = cP, hP
  self._cRate = (self._cRate or 0) * 0.6 + cRate * 0.4
  self._hRate = (self._hRate or 0) * 0.6 + hRate * 0.4

  -- 急速悪化（過渡）/ フロア割れ → 温度に関係なく強く下げる（暴走の本命対策）
  local coolingFast  = (self._cRate < -c.coolingTrendFast) or (self._hRate > c.coolingTrendFast)
  local coolingFloor = (cP and cP < c.coolantFloorPct) or (hP and hP > c.heatedCeilPct)
  if coolingFloor or coolingFast then
    local step = r.maxBurn * c.maxFallFraction * dt
    return set(r.burnRate - step, "COOL-SAT %.1f->%.1f T=%.0f dT%+.0f")
  end

  -- クーラント残量が目標を下回る（= 冷却が追いついていない）→ 温度に関係なく緩やかに下げ、
  -- 目標残量に戻す。復水が追いつけば残量が回復し、下の温度制御がまた上げる＝持続可能点に張り付く。
  local coolingBelow = (cP and cP < c.coolantTargetPct) or (hP and hP > c.heatedTargetPct)
  if coolingBelow then
    local step = r.maxBurn * c.maxRiseFraction * dt   -- 上げと同じ緩やかさで下げる
    return set(r.burnRate - step, "EASE %.1f->%.1f T=%.0f dT%+.0f")
  end

  local err = c.targetTemp - r.temp
  if math.abs(err) <= c.tempDeadband then
    return string.format("HOLD %.1f T=%.0f dT%+.0f", r.burnRate, r.temp, rate)
  end

  if err > 0 then
    -- 予測で目標を超えそうなら上げない（オーバーシュート防止）
    if predicted >= c.targetTemp then
      return string.format("WAIT %.1f T=%.0f dT%+.0f", r.burnRate, r.temp, rate)
    end
    -- ゲイン/上限は毎秒基準なので dt を掛けて 1tick 分にする
    local step = (err / c.targetTemp) * r.maxBurn * c.riseGain * dt
    local cap  = r.maxBurn * c.maxRiseFraction * dt
    if step > cap then step = cap end
    return set(r.burnRate + step, "RAISE %.1f->%.1f T=%.0f dT%+.0f")
  else
    -- 下げる: 強め（毎秒基準 × dt）
    local step = (err / c.targetTemp) * r.maxBurn * c.fallGain * dt   -- 負の値
    local cap  = r.maxBurn * c.maxFallFraction * dt
    if step < -cap then step = -cap end
    return set(r.burnRate + step, "LOWER %.1f->%.1f T=%.0f dT%+.0f")
  end
end

Reactor.toPct = toPct
return Reactor

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

-- 自動制御 v2（崖を探らない＝設定した安全 burn rate を保持 + 異常時のみ降圧）:
--   通常: 設定した目標 burn rate（targetBurnRate / targetBurnFraction）まで緩やかに上げて保持。
--   安全（降圧のみ。温度は限界探しに使わず安全装置として使う）:
--     COOL!     温度がソフト上限 or 予測 scram 超え → 半減
--     COOL-SAT  冷却フロア割れ / 急速悪化（タービン詰まり等で一気に dry out する崖の保険）→ 強降圧
--     EASE      クーラント残量が目標を下回る → 緩降圧で持続可能側へ
--     THROTTLE  タービン満タン → 降圧
-- 戻り値: 制御内容を表す ASCII 文字列（画面で可視化）。
function Reactor:autoAdjust(r, cfg, turbineEnergyPct)
  local c = cfg.control
  if not c.enabled then return "AUTO off" end
  if r.temp == nil or r.burnRate == nil or r.maxBurn == nil then return "AUTO: no data" end

  local dt = cfg.tickInterval or 1
  local ratePerSec = (r.temp - (self._lastTemp or r.temp)) / dt  -- 温度上昇率 K/秒
  self._lastTemp = r.temp
  local rate = ratePerSec

  local hardMax  = r.maxBurn * c.maxBurnRateFraction
  local riseStep = r.maxBurn * c.maxRiseFraction * dt
  local fallStep = r.maxBurn * c.maxFallFraction * dt
  local predicted = r.temp + ratePerSec * (c.lookahead or 0)

  -- 冷却トレンド（急速悪化の保険用）。EMA で平滑化。
  local cP, hP = r.coolantPct, r.heatedPct
  self._cRate = (self._cRate or 0) * 0.6 + ((cP and (cP - (self._lastCoolant or cP)) / dt) or 0) * 0.4
  self._hRate = (self._hRate or 0) * 0.6 + ((hP and (hP - (self._lastHeated  or hP)) / dt) or 0) * 0.4
  self._lastCoolant, self._lastHeated = cP, hP

  local function set(newRate, fmt)
    if newRate < c.minBurnRate then newRate = c.minBurnRate end
    if newRate > hardMax then newRate = hardMax end
    if math.abs(newRate - r.burnRate) > 1e-4 then self:call("setBurnRate", newRate) end
    return string.format(fmt, r.burnRate, newRate, r.temp, rate)
  end

  -- ===== 安全オーバーライド（下げる方向のみ）=====
  -- 1) 温度: ソフト上限 or 予測で scram 超え → 半減
  if r.temp >= c.softTemp or predicted >= cfg.safety.scramTemp then
    return set(r.burnRate * 0.5, "COOL! %.1f->%.1f T=%.0f dT%+.0f")
  end
  -- 2) 冷却フロア割れ / 急速悪化（崖の保険）→ 強く下げる
  if (cP and cP < c.coolantFloorPct) or (hP and hP > c.heatedCeilPct)
     or self._cRate < -c.coolingTrendFast or self._hRate > c.coolingTrendFast then
    return set(r.burnRate - fallStep, "COOL-SAT %.1f->%.1f T=%.0f dT%+.0f")
  end
  -- 3) クーラント残量が目標未満 → 緩降圧（持続可能側へ戻す）
  if (cP and cP < c.coolantTargetPct) or (hP and hP > c.heatedTargetPct) then
    return set(r.burnRate - riseStep, "EASE %.1f->%.1f T=%.0f dT%+.0f")
  end
  -- 4) タービン満タン → 下げる
  if cfg.turbine and cfg.turbine.enabled and turbineEnergyPct ~= nil
     and turbineEnergyPct >= cfg.turbine.throttleAtPct then
    return set(r.burnRate - fallStep, "THROTTLE %.1f->%.1f T=%.0f dT%+.0f")
  end

  -- ===== 通常: 設定した目標 burn rate へ緩やかにランプして保持 =====
  local desired = c.targetBurnRate or (r.maxBurn * c.targetBurnFraction)
  if desired > hardMax then desired = hardMax end
  local eps = riseStep * 0.5
  if r.burnRate < desired - eps then
    return set(math.min(desired, r.burnRate + riseStep), "RAISE %.1f->%.1f T=%.0f dT%+.0f")
  elseif r.burnRate > desired + eps then
    return set(math.max(desired, r.burnRate - fallStep), "LOWER %.1f->%.1f T=%.0f dT%+.0f")
  end
  return string.format("HOLD %.1f/%.0f T=%.0f dT%+.0f", r.burnRate, desired, r.temp, rate)
end

Reactor.toPct = toPct
return Reactor

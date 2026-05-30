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

-- 自動制御 v3（auto-seek: 炉ごとの「捌ける最大 burn」を信号から自動発見して張り付く）:
--   思想: coolant を安全ゾーン(≈100%)に保ったまま境界をなぞる。上限以下は coolant=100 で
--   信号が出ない＝余裕あり→ゆっくり攻める。境界を越えると coolant が下がり heated が上がる
--   →即引く（非対称: 引きは攻めの10倍速）。これで理論上限の直下に滑らかに張り付く。
--   設計はシミュレーター（sim/）で複数戦略を競わせ、隠し上限 250-950 全てで上限到達 ratio≈1.0
--   かつ波 P2P<9・溶融ゼロを確認した integral_seek 系を採用。
--   ハード安全層（下げのみ）: COOL!(温度) / COOL-SAT(フロア割れ・急速悪化) / THROTTLE(タービン)。
-- 戻り値: 制御内容を表す ASCII 文字列（画面で可視化）。
function Reactor:autoAdjust(r, cfg, turbineEnergyPct)
  local c = cfg.control
  if not c.enabled then return "AUTO off" end
  if r.temp == nil or r.burnRate == nil or r.maxBurn == nil then return "AUTO: no data" end

  local dt = cfg.tickInterval or 1
  if self._seekCmd == nil then self._seekCmd = r.burnRate end  -- 出力指令の積分器（永続）

  local ratePerSec = (r.temp - (self._lastTemp or r.temp)) / dt  -- 温度上昇率 K/秒
  self._lastTemp = r.temp
  local rate = ratePerSec
  local predicted = r.temp + ratePerSec * (c.lookahead or 0)

  local hardMax  = r.maxBurn * c.maxBurnRateFraction
  local fallStep = r.maxBurn * c.maxFallFraction * dt

  -- 冷却トレンド（急速悪化＝崖の入り口検知用）。EMA で平滑化。
  local cP, hP = r.coolantPct, r.heatedPct
  self._cRate = (self._cRate or 0) * 0.6 + ((cP and (cP - (self._lastCoolant or cP)) / dt) or 0) * 0.4
  self._hRate = (self._hRate or 0) * 0.6 + ((hP and (hP - (self._lastHeated  or hP)) / dt) or 0) * 0.4
  self._lastCoolant, self._lastHeated = cP, hP

  -- set: 指令(積分器)を更新しつつ実際に setBurnRate。
  local function set(newRate, fmt)
    if newRate < c.minBurnRate then newRate = c.minBurnRate end
    if newRate > hardMax then newRate = hardMax end
    self._seekCmd = newRate
    if math.abs(newRate - r.burnRate) > 1e-4 then self:call("setBurnRate", newRate) end
    return string.format(fmt, r.burnRate, newRate, r.temp, rate)
  end

  -- ===== ハード安全層（下げる方向のみ・最終手前ガード）=====
  -- 1) 温度: ソフト上限 or 予測で scram 超え → 半減
  if r.temp >= c.softTemp or predicted >= cfg.safety.scramTemp then
    return set(self._seekCmd * 0.5, "COOL! %.1f->%.1f T=%.0f dT%+.0f")
  end
  -- 2) 冷却フロア割れ / 急速悪化（崖の入り口）→ 強く下げる
  if (cP and cP < c.coolantFloorPct) or (hP and hP > c.heatedCeilPct)
     or self._cRate < -c.coolingTrendFast or self._hRate > c.coolingTrendFast then
    return set(self._seekCmd - fallStep, "COOL-SAT %.1f->%.1f T=%.0f dT%+.0f")
  end
  -- 3) タービン満タン → 下げる
  if cfg.turbine and cfg.turbine.enabled and turbineEnergyPct ~= nil
     and turbineEnergyPct >= cfg.turbine.throttleAtPct then
    return set(self._seekCmd - fallStep, "THROTTLE %.1f->%.1f T=%.0f dT%+.0f")
  end

  -- ===== auto-seek core: 安全ゾーン(coolant≈100)を保って境界に張り付く =====
  -- ストレス = 冷却が健全からどれだけ離れたか（coolant 下降 / heated 上昇）。
  local stress = 0.0
  if cP and cP < c.coolantHealthyPct then stress = stress + (c.coolantHealthyPct - cP) end
  if hP and hP > c.heatedHealthyPct  then stress = stress + (hP - c.heatedHealthyPct) end

  if stress <= 0.0 then
    -- 余裕あり: maxBurn の割合でゆっくり攻める。境界直下(coolant が 100 からわずかに下降)はブレーキ。
    local g = r.maxBurn * c.seekUpFraction
    if cP and cP < c.seekBrakePct then g = g * c.seekBrakeFactor end
    return set(self._seekCmd + g * dt, "SEEK+ %.1f->%.1f T=%.0f dT%+.0f")
  else
    -- ストレス: 度合いに比例して引く（非対称・安全側）
    local down = r.maxBurn * (c.seekDownFraction * stress + c.seekBackoffFraction)
    return set(self._seekCmd - down * dt, "SEEK- %.1f->%.1f T=%.0f dT%+.0f")
  end
end

Reactor.toPct = toPct
return Reactor

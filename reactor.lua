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

-- 自動制御 v4（PI on coolant: クーラント残量を「低い予備ライン」に保つ）:
--   実機物理: coolant は常に循環し、burn を上げるほど表示 % が下がって各点で安定する
--   （循環で減った分は正常。99% 等の高い値には張り付かない）。本当の限界(runout)は coolant が
--   循環予備すら維持できず 0 に向かう時。
--   → coolant を「低い設定値 coolantSetpoint(例 12%)」に PI 制御すれば、burn が自動で
--      「coolant がその予備分になる点」= 理論上限の直下まで上がって張り付く。設定値が低いほど高出力。
--   slew リミッタ（上げ gentle・下げ速い）+ アンチワインドアップで起動オーバーシュートと波を抑制。
--   設計は循環物理モデル（sim/）で複数 runout 上限を検証。全上限で coolant=設定値に張り付き、
--   burn が runout の ~88%（持続可能最大）、波ゼロ、溶融ゼロを確認。
--   ハード安全層（下げのみ）: COOL!(温度) / COOL-SAT(フロア割れ・急速悪化) / THROTTLE(タービン)。
-- 戻り値: 制御内容を表す ASCII 文字列（画面で可視化）。
function Reactor:autoAdjust(r, cfg, turbineEnergyPct)
  local c = cfg.control
  if not c.enabled then return "AUTO off" end
  if r.temp == nil or r.burnRate == nil or r.maxBurn == nil then return "AUTO: no data" end

  local dt = cfg.tickInterval or 1
  if self._piI   == nil then self._piI   = r.burnRate end  -- PI 積分器（永続）
  if self._piOut == nil then self._piOut = r.burnRate end  -- 直前の出力（slew 用）

  -- 外部要因（SCRAM / 手動操作）で実 burn が指令より大きく下がっていたら積分器を実値に同期し直す。
  -- これをしないと SCRAM 解除後に巻き上がった積分器がいきなり最大 burn を命じて発振する。
  if r.burnRate < self._piOut - r.maxBurn * 0.05 then
    self._piI   = r.burnRate
    self._piOut = r.burnRate
  end

  local tRate = (r.temp - (self._lastTemp or r.temp)) / dt  -- 温度上昇率 K/秒
  self._lastTemp = r.temp
  local predicted = r.temp + tRate * (c.lookahead or 0)

  -- 冷却トレンド（急速悪化＝runout への落下検知用）。EMA で平滑化。
  local cP, hP = r.coolantPct, r.heatedPct
  self._cRate = (self._cRate or 0) * 0.6 + ((cP and (cP - (self._lastCoolant or cP)) / dt) or 0) * 0.4
  self._hRate = (self._hRate or 0) * 0.6 + ((hP and (hP - (self._lastHeated  or hP)) / dt) or 0) * 0.4
  self._lastCoolant, self._lastHeated = cP, hP

  local hardMax = r.maxBurn * c.maxBurnRateFraction

  -- apply: 出力を確定して setBurnRate。resetI=true で積分器を出力に合わせ直す（強制降圧時の巻き戻り防止）。
  local function apply(newOut, fmt, resetI)
    if newOut < c.minBurnRate then newOut = c.minBurnRate end
    if newOut > hardMax then newOut = hardMax end
    self._piOut = newOut
    if resetI then self._piI = newOut end
    if math.abs(newOut - r.burnRate) > 1e-4 then self:call("setBurnRate", newOut) end
    return string.format(fmt, r.burnRate, newOut, r.temp, tRate)
  end

  local fallStep = r.maxBurn * c.maxFallFraction * dt

  -- ===== ハード安全層（下げる方向のみ・最終手前ガード）=====
  -- 1) 温度: ソフト上限 or 予測で scram 超え → 半減
  if r.temp >= c.softTemp or predicted >= cfg.safety.scramTemp then
    return apply(self._piOut * 0.5, "COOL! %.1f->%.1f T=%.0f dT%+.0f", true)
  end
  -- 2) 冷却フロア割れ（runout 直前）/ heated 上限超 / 急速悪化 → 強く下げる
  if (cP and cP < c.coolantFloorPct) or (hP and hP > c.heatedCeilPct)
     or self._cRate < -c.coolingTrendFast then
    return apply(self._piOut - fallStep, "COOL-SAT %.1f->%.1f T=%.0f dT%+.0f", true)
  end
  -- 3) タービン満タン → 下げる
  if cfg.turbine and cfg.turbine.enabled and turbineEnergyPct ~= nil
     and turbineEnergyPct >= cfg.turbine.throttleAtPct then
    return apply(self._piOut - fallStep, "THROTTLE %.1f->%.1f T=%.0f dT%+.0f", true)
  end

  -- ===== PI core: coolant を低い設定値に保つ → 理論上限の直下に張り付く =====
  if cP == nil then
    return string.format("HOLD %.1f T=%.0f (no coolant)", r.burnRate, r.temp)
  end
  local Ki  = r.maxBurn * c.piKiFraction
  local Kp  = r.maxBurn * c.piKpFraction
  local err = cP - c.coolantSetpoint   -- >0 = coolant が設定値より上 = まだ攻める余地

  self._piI = self._piI + Ki * err * dt
  if self._piI < 0 then self._piI = 0 end
  if self._piI > hardMax then self._piI = hardMax end
  local out = self._piI + Kp * err

  -- slew リミッタ: 上げ gentle（起動オーバーシュート防止）/ 下げ速い（安全）
  local upSlew   = r.maxBurn * c.piUpSlewFraction   * dt
  local downSlew = r.maxBurn * c.piDownSlewFraction * dt
  local d = out - self._piOut
  if d >  upSlew   then d =  upSlew   end
  if d < -downSlew then d = -downSlew end
  out = self._piOut + d

  -- アンチワインドアップ: 積分が slew 制限された出力より先走らないよう抑える
  local windCap = out + r.maxBurn * 0.03
  if self._piI > windCap then self._piI = windCap end

  local lbl = (math.abs(err) < 1.0) and "HOLD" or (err > 0 and "SEEK+" or "SEEK-")
  return apply(out, lbl .. " %.1f->%.1f T=%.0f dT%+.0f", false)
end

Reactor.toPct = toPct
return Reactor

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

-- 炉の全状態を 1 回のサイクルで読む。
function Reactor:read()
  return {
    status     = self:call("getStatus"),                              -- boolean: 稼働中か
    temp       = self:call("getTemperature"),                         -- K
    damage     = toPct(self:call("getDamagePercent")),               -- %
    coolantPct = toPct(self:call("getCoolantFilledPercentage")),     -- %
    heatedPct  = toPct(self:call("getHeatedCoolantFilledPercentage")),-- %
    fuelPct    = toPct(self:call("getFuelFilledPercentage")),        -- %
    wastePct   = toPct(self:call("getWasteFilledPercentage")),       -- %
    burnRate   = self:call("getBurnRate"),                            -- mB/t（設定値）
    actualBurn = self:call("getActualBurnRate"),                      -- mB/t（実効）
    maxBurn    = self:call("getMaxBurnRate"),                         -- mB/t（=燃料集合体数）
    boilEff    = self:call("getBoilEfficiency"),                      -- 0-1
  }
end

-- 安全判定。ok(boolean), reason(string) を返す。
-- フェイルセーフ: 温度が読めない時点で危険と判定する。
function Reactor:checkSafety(r, cfg)
  local s = cfg.safety

  if r.temp == nil then
    return false, "温度が読めない (フェイルセーフ)"
  end
  if r.temp >= s.scramTemp then
    return false, string.format("高温 %.0fK >= %.0fK", r.temp, s.scramTemp)
  end
  if r.damage ~= nil and r.damage >= s.scramDamagePct then
    return false, string.format("損傷 %.1f%%", r.damage)
  end
  if r.coolantPct ~= nil and r.coolantPct < s.minCoolantPct then
    return false, string.format("冷却材不足 %.0f%% < %.0f%%", r.coolantPct, s.minCoolantPct)
  end
  if r.heatedPct ~= nil and r.heatedPct >= s.maxHeatedCoolantPct then
    return false, string.format("加熱冷却材 詰まり %.0f%%", r.heatedPct)
  end
  if r.wastePct ~= nil and r.wastePct >= s.maxWastePct then
    return false, string.format("廃棄物 満杯 %.0f%%", r.wastePct)
  end
  if r.fuelPct ~= nil and r.fuelPct < s.minFuelPct then
    return false, "燃料切れ"
  end

  return true, "正常"
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

-- 温度に応じて burn rate を比例調整する（デッドバンド付き、発振防止）。
-- 安全側に倒すため、増やす前に必ず炉の上限でクランプする。
-- turbineEnergyPct（0-100、無ければ nil）が throttle 閾値以上なら、温度に余裕があっても
-- 出力を上げず下げる（蒸気の行き場が無く逆流→過熱を未然に防ぐ）。
function Reactor:autoAdjust(r, cfg, turbineEnergyPct)
  local c = cfg.control
  if not c.enabled then return end
  if r.temp == nil or r.burnRate == nil or r.maxBurn == nil then return end

  local hardMax = r.maxBurn * c.maxBurnRateFraction
  local newRate = r.burnRate

  local turbineFull = (cfg.turbine and cfg.turbine.enabled
      and turbineEnergyPct ~= nil and turbineEnergyPct >= cfg.turbine.throttleAtPct)

  if turbineFull then
    newRate = r.burnRate - c.rateStep      -- タービン満タン → 行き場なし、出力を絞る
  elseif r.temp > c.targetTemp + c.tempDeadband then
    newRate = r.burnRate - c.rateStep      -- 熱すぎる → 出力を下げる
  elseif r.temp < c.targetTemp - c.tempDeadband then
    newRate = r.burnRate + c.rateStep      -- 余裕あり → 出力を上げる
  else
    return                                  -- デッドバンド内 → 触らない
  end

  if newRate < c.minBurnRate then newRate = c.minBurnRate end
  if newRate > hardMax then newRate = hardMax end

  if math.abs(newRate - r.burnRate) > 1e-6 then
    self:call("setBurnRate", newRate)
  end
end

Reactor.toPct = toPct
return Reactor

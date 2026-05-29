-- turbine.lua
-- Industrial Turbine（任意）のラッパー。エネルギーバッファの充填率を読む。
-- getEnergyFilledPercentage は実スクリプトで確認済み（0-1 の割合）。

local Turbine = {}
Turbine.__index = Turbine

local function toPct(v)
  if type(v) ~= "number" then return nil end
  if v <= 1.0 then return v * 100 end
  return v
end

-- 検出。name 指定が無ければ getEnergyFilledPercentage を持つ機器を探す。
-- 炉アダプタは getEnergyFilledPercentage を持たないので誤検出しない。
function Turbine.new(name)
  local self = setmetatable({}, Turbine)
  if name and name ~= "" then
    self.dev = peripheral.wrap(name)
    self.name = name
  else
    for _, n in ipairs(peripheral.getNames()) do
      local p = peripheral.wrap(n)
      if p and type(p.getEnergyFilledPercentage) == "function" then
        self.dev = p
        self.name = n
        break
      end
    end
  end
  return self
end

function Turbine:ok()
  return self.dev ~= nil
end

function Turbine:call(method, ...)
  if not self.dev then return nil end
  local fn = self.dev[method]
  if type(fn) ~= "function" then return nil end
  local res = { pcall(fn, ...) }
  if res[1] then return res[2] end
  return nil
end

-- エネルギー充填率（%）。読めなければ nil。
function Turbine:energyPct()
  return toPct(self:call("getEnergyFilledPercentage"))
end

return Turbine

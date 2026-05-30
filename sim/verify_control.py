"""
統合テスト: 実物の reactor.lua / config.lua を lupa(LuaJIT) でそのまま読み込み、
循環物理モデル（実機の挙動）に対して autoAdjust/checkSafety を毎 tick 走らせて挙動を出力する。
ポートのバグ・暴走・発振があればここで露見する。

循環モデル: coolant は burn とともに平衡値が下がり一次遅れで追従。runout 上限 B0 で平衡 0。

実行: python sim/verify_control.py
"""
import os
from lupa import LuaRuntime

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
with open(os.path.join(HERE, "config.lua"), encoding="utf-8") as f:
    config_src = f.read()
with open(os.path.join(HERE, "reactor.lua"), encoding="utf-8") as f:
    reactor_src = f.read()

lua = LuaRuntime(unpack_returned_tuples=True)
cfg = lua.execute(config_src)
Reactor = lua.execute(reactor_src)
lua.globals().CFG = cfg
lua.globals().REACTOR = Reactor

harness = r"""
local cfg, Reactor = CFG, REACTOR
local applied = { rate = 0 }
local mock = { setBurnRate = function(x) applied.rate = x end }
local self = setmetatable({ dev = mock }, { __index = Reactor })

local maxBurn, B0, dt = 1000, B0VAL, 0.5   -- B0 = runout 上限（coolant 平衡が 0 になる burn）
local kSettle = 0.15
local temp, coolant, heated, burn = 350, 100, 0, 0
local out = {}
local melted = false
local function clamp(v,a,b) if v<a then return a elseif v>b then return b end return v end

for t = 1, 600 do
  local r = {
    status=true, temp=temp, damage=0,
    coolantPct=coolant, heatedPct=heated, wastePct=0,
    burnRate=burn, maxBurn=maxBurn, fuelPct=100,
  }
  local safe, reason = Reactor.checkSafety(self, r, cfg)
  local action
  if not safe then applied.rate = 0; action = "SCRAM("..tostring(reason)..")"
  else action = Reactor.autoAdjust(self, r, cfg, nil) end
  burn = applied.rate

  local Seq = clamp(100*(1 - burn/B0), 0, 100)
  local Heq = clamp((burn/B0)*40, 0, 100)
  coolant = coolant + (Seq - coolant) * kSettle * dt
  heated  = heated  + (Heq - heated)  * kSettle * dt
  local dT = burn*0.003*dt - (temp-350)*0.02*dt
  if coolant < 5 then dT = dT + burn*0.08*dt end
  temp = clamp(temp + dT, 300, 6000)
  if temp >= 1200 then melted = true end

  if t % 40 == 0 or action:sub(1,4)=="COOL" or action:sub(1,5)=="SCRAM" then
    out[#out+1] = string.format("t=%3d burn=%6.1f T=%5.0f cool=%5.1f heat=%5.1f | %s",
      t, burn, temp, coolant, heated, action)
  end
end
out[#out+1] = melted and ">>> MELTDOWN" or ">>> 溶融なし。安定動作。"
out[#out+1] = string.format("final: burn=%.1f T=%.0f cool=%.1f heat=%.1f (runout B0=%d, setpoint=%.0f)",
  burn, temp, coolant, heated, B0, cfg.control.coolantSetpoint)
return table.concat(out, "\n")
"""

print(f"version={cfg.version}  coolantSetpoint={cfg.control.coolantSetpoint}  "
      f"coolantFloor={cfg.control.coolantFloorPct}  heatedCeil={cfg.control.heatedCeilPct}  tick={cfg.tickInterval}")

for B0 in [300, 645, 900]:
    print("=" * 78)
    print(f"runout 上限 B0={B0}（制御は知らない。coolant を設定値に保って自動で張り付くか）")
    print("-" * 78)
    print(lua.execute(harness.replace("B0VAL", str(B0))))

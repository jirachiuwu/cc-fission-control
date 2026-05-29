"""
制御ロジック検証シミュレーター。
ゲーム内では走らせられないので、実物の reactor.lua / config.lua を lupa(LuaJIT) で
そのまま読み込み、簡易物理モデル（発熱・冷却・復水）に対して autoAdjust/checkSafety を
毎 tick 走らせて挙動を出力する。暴走・発振・収束不能があればここで露見する。

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
cfg = lua.execute(config_src)        # config.lua は cfg を return する
Reactor = lua.execute(reactor_src)   # reactor.lua は Reactor を return する
lua.globals().CFG = cfg
lua.globals().REACTOR = Reactor

# 簡易物理モデル + 実物ロジックを毎 tick 回す Lua ハーネス。
# モデル: maxBurn=1000、冷却が捌ける上限 coolingCap。burn>cap で coolant 枯渇＆温度上昇、
#         burn<=cap で coolant 回復。= 「復水が追いつかない」現象を再現。
harness = r"""
local cfg, Reactor = CFG, REACTOR
cfg.control.targetBurnRate = TARGET   -- nil なら config の fraction を使用
local applied = { rate = 0 }
local mock = { setBurnRate = function(x) applied.rate = x end }
local self = setmetatable({ dev = mock }, { __index = Reactor })

local maxBurn   = 1000
local coolingCap = 220      -- この burn を超えると復水が追いつかない（崖）
local temp, coolant, heated, burn = 350, 100, 0, 0
local out = {}
local function clamp(v,a,b) if v<a then return a elseif v>b then return b end return v end

local melted = false
for t = 1, 300 do
  local r = {
    status=true, temp=temp, damage=0,
    coolantPct=coolant, heatedPct=heated, wastePct=0,
    burnRate=burn, maxBurn=maxBurn, fuelPct=100,
  }
  local safe, reason = Reactor.checkSafety(self, r, cfg)
  local action
  if not safe then
    applied.rate = 0
    action = "SCRAM("..tostring(reason)..")"
  else
    action = Reactor.autoAdjust(self, r, cfg, nil)
  end
  burn = applied.rate

  -- 物理更新（dt=tickInterval）
  local dt = cfg.tickInterval or 0.5
  local deficit = burn - coolingCap
  -- 温度: 冷却が捌ける分は除去、超過分が温度を押し上げる
  local dT = (deficit > 0 and deficit * 0.9 or deficit * 0.5) * dt - (temp-350)*0.01*dt
  temp = clamp(temp + dT, 300, 6000)
  -- 冷却材/加熱: 超過で枯渇、余裕で回復
  coolant = clamp(coolant - deficit * 0.08 * dt, 0, 100)
  heated  = clamp(heated  + deficit * 0.08 * dt, 0, 100)

  if temp >= 1200 then melted = true end

  if t % 10 == 0 or action:sub(1,4)=="COOL" or action:sub(1,5)=="SCRAM"
     or action:sub(1,4)=="CATC" then
    out[#out+1] = string.format(
      "t=%3d burn=%6.1f T=%5.0f cool=%5.1f heat=%5.1f | %s",
      t, burn, temp, coolant, heated, action)
  end
end
out[#out+1] = melted and ">>> MELTDOWN (temp>=1200 を観測)" or ">>> 溶融なし。安定動作。"
out[#out+1] = string.format("final: burn=%.1f T=%.0f cool=%.1f heat=%.1f (coolingCap=%d)", burn, temp, coolant, heated, coolingCap)
return table.concat(out, "\n")
"""

print(f"profile={cfg.profile}  scram={cfg.safety.scramTemp}  softTemp={cfg.control.softTemp}")
print(f"maxRiseFraction={cfg.control.maxRiseFraction} maxFallFraction={cfg.control.maxFallFraction} "
      f"coolantTarget={cfg.control.coolantTargetPct} tick={cfg.tickInterval}")

for label, target in [
    ("A) 目標=config(maxの10%=100)。持続可能内 → 保持できるか", None),
    ("B) 目標=350（持続可能220を超過）。安全層が頭打ちにして溶けないか", 350),
]:
    print("=" * 78)
    print(label)
    print("-" * 78)
    lua.globals().TARGET = target
    print(lua.execute(harness))

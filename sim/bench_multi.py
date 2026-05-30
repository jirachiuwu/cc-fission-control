"""
汎化ベンチ: 候補制御を「複数の隠し上限 cap」でテストし、どの炉でも上限近くまで
滑らかに張り付けるかを評価する。特定 cap への過学習を弾き、真に「理論上限を自動発見して
張り付く」戦略を選ぶ。

使い方: python sim/bench_multi.py sim/cand_X.lua
"""
import sys, json
from lupa import LuaRuntime

cand_path = sys.argv[1]
with open(cand_path, encoding="utf-8") as f:
    cand_src = f.read()

CAPS = [250, 600, 850, 950]

MODEL = r"""
local control = control
local maxBurn, cap, dt = 1000, CAP, 0.5
local temp, coolant, heated, burn = 350, 100, 0, 0
local mem = {}
local TICKS = 1600
local burns = {}
local melted = false
local function clamp(v,a,b) if v<a then return a elseif v>b then return b end return v end

for t = 1, TICKS do
  local s = { burn=burn, temp=temp, coolant=coolant, heated=heated,
              maxBurn=maxBurn, dt=dt, t=t, mem=mem }
  local nb = control(s)
  if type(nb) ~= "number" then nb = burn end
  burn = clamp(nb, 0, maxBurn)
  local deficit = burn - cap
  local kBuf = 0.05
  if deficit > 0 then
    coolant = clamp(coolant - deficit*kBuf*dt, 0, 100)
    heated  = clamp(heated  + deficit*kBuf*dt, 0, 100)
  else
    coolant = clamp(coolant - deficit*kBuf*1.5*dt, 0, 100)
    heated  = clamp(heated  + deficit*kBuf*1.5*dt, 0, 100)
  end
  local dT = 0
  if deficit > 0 then dT = dT + deficit*0.04*dt end
  if coolant < 12 then dT = dT + burn*0.06*dt end
  dT = dT - (temp-350)*0.02*dt
  temp = clamp(temp + dT, 300, 6000)
  if temp >= 1200 then melted = true end
  burns[t] = burn
end
local s0 = math.floor(TICKS*0.75)
local sum,n,mn,mx = 0,0,1e9,-1e9
for t=s0,TICKS do local b=burns[t]; sum=sum+b; n=n+1; if b<mn then mn=b end; if b>mx then mx=b end end
return { melted=melted, ssMean=sum/n, ssP2P=mx-mn }
"""

def run(cap):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(cand_src)
    r = lua.execute(MODEL.replace("CAP", str(cap)))
    return {"melted": bool(r["melted"]), "ssMean": r["ssMean"], "ssP2P": r["ssP2P"]}

rows = []
any_melt = False
ratios = []
worst_p2p = 0
for cap in CAPS:
    m = run(cap)
    ratio = m["ssMean"] / cap
    ratios.append(ratio)
    worst_p2p = max(worst_p2p, m["ssP2P"])
    if m["melted"]:
        any_melt = True
    rows.append({
        "cap": cap, "ssMean": round(m["ssMean"], 1),
        "ratio": round(ratio, 3), "ssP2P": round(m["ssP2P"], 1),
        "melted": m["melted"],
    })

avg_ratio = sum(ratios) / len(ratios)
# 汎化スコア: 平均到達率(高いほど良い) - 最悪の波ペナルティ。溶けたら失格。
score = -1e9 if any_melt else (avg_ratio * 100 - max(0, worst_p2p - 25) * 0.5)
print(json.dumps({
    "candidate": cand_path,
    "anyMelt": any_melt,
    "avgRatio": round(avg_ratio, 3),
    "worstP2P": round(worst_p2p, 1),
    "score": round(score, 1),
    "perCap": rows,
}, ensure_ascii=False))

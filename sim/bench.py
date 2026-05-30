"""
制御戦略ベンチマーク。
候補の制御関数（Lua、function control(s) を定義）を、Mekanism 風の物理モデルに対して
走らせ、指標を JSON で出す。複数戦略を客観比較するための共通ハーネス。

物理モデル（現象論）:
  - maxBurn=1000、捌ける上限 cap=600（制御側は知らない）。
  - coolant(0-100) / heated(0-100) は相補バッファ。burn<=cap で coolant→100, heated→0,
    温度は安定。burn>cap で deficit に比例して coolant 枯渇・heated 充填・温度上昇。
    coolant が枯れる(<~12%)と冷却崩壊で温度が急騰（崖）。
  - = 「上限以下は安定、超えるとバッファが数十秒かけて枯れて最後に崖」を再現。

候補インターフェース（候補 .lua 内でグローバル関数 control を定義）:
  s = { burn, temp, coolant, heated, maxBurn, dt, t, mem }  -- mem は永続テーブル
  return 新しい burn rate（数値）

使い方: python sim/bench.py sim/cand_X.lua
"""
import sys, json
from lupa import LuaRuntime

cand_path = sys.argv[1]
with open(cand_path, encoding="utf-8") as f:
    cand_src = f.read()

lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute(cand_src)  # control をグローバル定義

MODEL = r"""
local control = control
local maxBurn, cap, dt = 1000, 600, 0.5
local temp, coolant, heated, burn = 350, 100, 0, 0
local mem = {}
local TICKS = 1200          -- 600s
local burns, temps = {}, {}
local melted = false
local maxBurnReached = 0

local function clamp(v,a,b) if v<a then return a elseif v>b then return b end return v end

for t = 1, TICKS do
  local s = { burn=burn, temp=temp, coolant=coolant, heated=heated,
              maxBurn=maxBurn, dt=dt, t=t, mem=mem }
  local nb = control(s)
  if type(nb) ~= "number" then nb = burn end
  burn = clamp(nb, 0, maxBurn)

  -- 物理更新
  local deficit = burn - cap
  local kBuf = 0.05
  if deficit > 0 then
    coolant = clamp(coolant - deficit*kBuf*dt, 0, 100)
    heated  = clamp(heated  + deficit*kBuf*dt, 0, 100)
  else
    coolant = clamp(coolant - deficit*kBuf*1.5*dt, 0, 100)  -- 回復はやや速い
    heated  = clamp(heated  + deficit*kBuf*1.5*dt, 0, 100)
  end
  -- 温度: 超過分で上昇、冷却崩壊(coolant低)で急騰、余裕で緩和
  local dT = 0
  if deficit > 0 then dT = dT + deficit*0.04*dt end
  if coolant < 12 then dT = dT + burn*0.06*dt end       -- 崖
  dT = dT - (temp-350)*0.02*dt
  temp = clamp(temp + dT, 300, 6000)

  if temp >= 1200 then melted = true end
  if burn > maxBurnReached then maxBurnReached = burn end
  burns[t] = burn; temps[t] = temp
end

-- 定常指標（後半25%）
local s0 = math.floor(TICKS*0.75)
local sum, n, mn, mx = 0, 0, 1e9, -1e9
for t=s0,TICKS do
  local b=burns[t]; sum=sum+b; n=n+1
  if b<mn then mn=b end; if b>mx then mx=b end
end
local mean = sum/n
local tsum=0; for t=s0,TICKS do tsum=tsum+temps[t] end
return {
  melted = melted,
  maxBurnReached = maxBurnReached,
  ssMean = mean,            -- 定常 burn 平均（高いほど良い、cap=600 に近いほど良い）
  ssP2P = mx-mn,            -- 定常 burn の山谷差（小さいほど滑らか）
  ssTemp = tsum/n,
  ssCoolant = coolant,
  cap = cap,
}
"""

lua.globals().control = lua.globals().control
res = lua.execute(MODEL)
out = {
    "candidate": cand_path,
    "melted": bool(res["melted"]),
    "maxBurnReached": round(res["maxBurnReached"], 1),
    "ssMean": round(res["ssMean"], 1),
    "ssP2P": round(res["ssP2P"], 1),
    "ssTemp": round(res["ssTemp"], 0),
    "ssCoolant": round(res["ssCoolant"], 1),
    "cap": res["cap"],
}
print(json.dumps(out, ensure_ascii=False))

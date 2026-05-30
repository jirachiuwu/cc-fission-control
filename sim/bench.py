"""
制御戦略ベンチマーク（物理モデル v2 = 循環モデル、実機の挙動に修正）。

実機の挙動（ユーザー実測）:
  - coolant は常に循環。burn を上げるほど循環量が増え、coolant タンクの表示 % は下がる。
  - 各 burn で coolant はある平衡値に「落ち着く」（それ以上は減らない）。平衡値は burn とともに低下。
  - 本当の限界(runout)は burn=B0 で coolant 平衡が 0 になる時。そこで冷却崩壊 → 温度急騰 → melt。
  - つまり coolant% は burn の減少関数。低 burn でも 100% ではない（循環してるから）。

モデル:
  - maxBurn=1000、runout 上限 B0=CAP（隠し）。dt=0.5。
  - coolant 平衡 Seq(burn) = 100*(1 - burn/B0)。coolant は kSettle で Seq へ一次遅れで追従。
  - heated 平衡 Heq(burn) = (burn/B0)*40。同様に追従。
  - 温度: burn に緩く比例して上昇 + coolant が極低(<5%)で冷却崩壊し急騰。temp>=1200 で melt。
  - 持続可能な最大 = coolant 平衡が「安全予備(例 8%)」になる burn ≈ 0.92*B0。そこに張り付くのが理想。

候補インターフェース（候補 .lua 内でグローバル関数 control を定義）:
  s = { burn, temp, coolant, heated, maxBurn, dt, t, mem }
  return 新しい burn rate（数値）。使ってよい信号は coolant/heated/temp/burn/maxBurn/dt のみ。
"""
import sys, json
from lupa import LuaRuntime

cand_path = sys.argv[1]
cap = int(sys.argv[2]) if len(sys.argv) > 2 else 600
with open(cand_path, encoding="utf-8") as f:
    cand_src = f.read()

lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute(cand_src)

MODEL = r"""
local control = control
local maxBurn, B0, dt = 1000, __CAP__, 0.5
local kSettle = 0.15
local temp, coolant, heated, burn = 350, 100, 0, 0
local mem = {}
local TICKS = 2000
local burns = {}
local melted = false
local maxBurnReached = 0
local function clamp(v,a,b) if v<a then return a elseif v>b then return b end return v end

for t = 1, TICKS do
  local s = { burn=burn, temp=temp, coolant=coolant, heated=heated,
              maxBurn=maxBurn, dt=dt, t=t, mem=mem }
  local nb = control(s)
  if type(nb) ~= "number" then nb = burn end
  burn = clamp(nb, 0, maxBurn)

  local Seq = clamp(100*(1 - burn/B0), 0, 100)        -- coolant 平衡（burn で減少）
  local Heq = clamp((burn/B0)*40, 0, 100)             -- heated 平衡（burn で増加）
  coolant = coolant + (Seq - coolant) * kSettle * dt  -- 一次遅れで追従
  heated  = heated  + (Heq - heated)  * kSettle * dt

  local dT = burn*0.003*dt - (temp-350)*0.02*dt
  if coolant < 5 then dT = dT + burn*0.08*dt end       -- runout で冷却崩壊
  temp = clamp(temp + dT, 300, 6000)

  if temp >= 1200 then melted = true end
  if burn > maxBurnReached then maxBurnReached = burn end
  burns[t] = burn
end

local s0 = math.floor(TICKS*0.75)
local sum,n,mn,mx = 0,0,1e9,-1e9
for t=s0,TICKS do local b=burns[t]; sum=sum+b; n=n+1; if b<mn then mn=b end; if b>mx then mx=b end end
return { melted=melted, maxBurnReached=maxBurnReached, ssMean=sum/n, ssP2P=mx-mn,
         ssTemp=temp, ssCoolant=coolant, ssHeated=heated, B0=B0 }
"""

res = lua.execute(MODEL.replace("__CAP__", str(cap)))
print(json.dumps({
    "candidate": cand_path, "B0": cap,
    "melted": bool(res["melted"]),
    "maxBurnReached": round(res["maxBurnReached"], 1),
    "ssMean": round(res["ssMean"], 1),
    "ssP2P": round(res["ssP2P"], 1),
    "ssTemp": round(res["ssTemp"], 0),
    "ssCoolant": round(res["ssCoolant"], 1),
    "ssHeated": round(res["ssHeated"], 1),
    "ratioToRunout": round(res["ssMean"] / cap, 3),
}, ensure_ascii=False))

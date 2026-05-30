-- pi3: PI on coolant（設定値 12%）+ 変化率ゲート。
-- 改良点: coolant が「落下中（消費>復水でまだ追いつき待ち）」は積分を止めて HOLD。
--   coolant が「落ち着いた（rate≈0）」時だけ上げる。これで復水の遅れがあっても行き過ぎない。
--   = 「ゆっくり状態を見ながら上げる」の自動化。

function control(s)
  local m = s.mem
  local dt = s.dt
  if not m.init then
    m.init = true
    m.I = s.burn
    m.prevC = s.coolant
    m.cRate = 0
    m.prevOut = s.burn
  end

  -- coolant 変化率 EMA（%/s）
  local dC = (s.coolant - m.prevC) / dt
  m.prevC = s.coolant
  m.cRate = m.cRate * 0.6 + dC * 0.4

  local SP = 12.0
  local Ki = s.maxBurn * 0.0008
  local Kp = s.maxBurn * 0.002
  local settleTol = 0.5   -- %/s: これより緩い下降/上昇 = 落ち着いた

  local err = s.coolant - SP

  -- ★積分ゲート: 設定値より下なら常に下げる。上なら「落ち着いている時だけ」上げる。
  --   落下中（上だが下降中）は積分しない = HOLD（復水の追いつき待ち。行き過ぎ防止）。
  if err < 0 or m.cRate >= -settleTol then
    m.I = m.I + Ki * err * dt
  end
  if m.I < 0 then m.I = 0 end
  if m.I > s.maxBurn then m.I = s.maxBurn end

  local out = m.I + Kp * err

  -- 安全: runout 直前
  if s.coolant < 5 then out = out - s.maxBurn * 0.1; m.I = m.I - Ki * 4 * dt end

  -- slew + アンチワインドアップ
  local prev = m.prevOut
  local upSlew   = s.maxBurn * 0.006 * dt
  local downSlew = s.maxBurn * 0.10  * dt
  local d = out - prev
  if d >  upSlew   then d =  upSlew   end
  if d < -downSlew then d = -downSlew end
  out = prev + d
  local windCap = out + s.maxBurn * 0.03
  if m.I > windCap then m.I = windCap end

  if out < 0 then out = 0 end
  if out > s.maxBurn then out = s.maxBurn end
  m.prevOut = out
  return out
end

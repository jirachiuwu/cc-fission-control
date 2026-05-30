-- pi4: 二重制約 PI。coolant（下限 setpoint）と heated（上限 setpoint）の両方を見て、
--   どちらか先に効く方で burn を頭打ちにする。
--   - coolant 律速（冷却材供給不足）→ coolant が下限に達して止まる
--   - タービン律速（蒸気がタービンにパンパン→ボイラー水枯れ）→ heated が上限に達して止まる
--   どちらの炉構成でも「先に詰まる方」で安全に張り付く。
--   + 変化率ゲート（落下/上昇中は HOLD）で復水ラグでの行き過ぎ防止。

function control(s)
  local m = s.mem
  local dt = s.dt
  if not m.init then
    m.init = true
    m.I = s.burn
    m.prevC = s.coolant
    m.prevH = s.heated
    m.cRate = 0
    m.hRate = 0
    m.prevOut = s.burn
  end

  -- 変化率 EMA
  m.cRate = m.cRate * 0.6 + ((s.coolant - m.prevC) / dt) * 0.4
  m.hRate = m.hRate * 0.6 + ((s.heated - m.prevH) / dt) * 0.4
  m.prevC = s.coolant
  m.prevH = s.heated

  local coolantSP = 12.0    -- coolant 下限（これ以上をキープ。低いほど高出力）
  local heatedSP  = 60.0    -- heated 上限（これ以下をキープ。高いほど高出力だがタービン詰まりに近づく）
  local Ki = s.maxBurn * 0.0008
  local Kp = s.maxBurn * 0.002
  local settleTol = 0.5

  -- 二重制約: 余裕 = min(coolant の余裕, heated の余裕)。先に尽きる方で頭打ち。
  local coolErr = s.coolant - coolantSP      -- >0 = coolant に余裕
  local heatErr = heatedSP - s.heated         -- >0 = heated に余裕
  local err = (coolErr < heatErr) and coolErr or heatErr

  -- 変化率ゲート: err<0 なら常に下げる。err>=0 でも「coolant 落下中 or heated 上昇中」は HOLD。
  local settled = (m.cRate >= -settleTol) and (m.hRate <= settleTol)
  if err < 0 or settled then
    m.I = m.I + Ki * err * dt
  end
  if m.I < 0 then m.I = 0 end
  if m.I > s.maxBurn then m.I = s.maxBurn end

  local out = m.I + Kp * err

  -- 安全
  if s.coolant < 5 or s.heated > 90 then out = out - s.maxBurn * 0.1; m.I = m.I - Ki * 4 * dt end

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

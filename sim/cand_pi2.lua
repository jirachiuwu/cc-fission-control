-- pi2: coolant を「低い予備ライン(setpoint)」に PI 制御で保つ。
-- 実機物理: coolant は各 burn で安定値に落ち着き、burn を上げるほど安定値が下がる。
-- → coolant を低い設定値(例 12%)に保つよう burn を PI 調整すれば、burn が自動で
--   「coolant がその予備分になる点」= 理論上限の直下まで上がって張り付く。
-- 循環で coolant が下がるのは正常。99.5%等の高い閾値で止めない。低い予備ラインだけ守る。

function control(s)
  local m = s.mem
  local dt = s.dt
  if not m.init then
    m.init = true
    m.I = s.burn            -- 積分器（= burn 指令の主成分）
  end

  local SP = 12.0          -- coolant 設定値（% 低い予備ライン。低いほど高出力・runout に近い）
  local Ki = s.maxBurn * 0.0008   -- 積分ゲイン（burn/秒 per %err、maxBurn 比でサイズ非依存）
  local Kp = s.maxBurn * 0.002    -- 比例ゲイン（過渡のダンピング）

  local err = s.coolant - SP       -- >0 = coolant が予備より上 = まだ攻める余地

  m.I = m.I + Ki * err * dt
  if m.I < 0 then m.I = 0 end
  if m.I > s.maxBurn then m.I = s.maxBurn end

  local out = m.I + Kp * err

  -- 安全: coolant が危険域(runout 直前) → 強く引いて積分も抜く（巻き戻り防止）
  if s.coolant < 5 then
    out = out - s.maxBurn * 0.1
    m.I = m.I - Ki * 4 * dt
  end

  -- slew リミッタ: 上げは gentle（coolant が追従する速さに合わせ、起動オーバーシュート防止）、
  -- 下げは速い（安全）。
  local prev = m.prevOut or s.burn
  local upSlew   = s.maxBurn * 0.006 * dt
  local downSlew = s.maxBurn * 0.10  * dt
  local delta = out - prev
  if delta >  upSlew   then delta =  upSlew   end
  if delta < -downSlew then delta = -downSlew end
  out = prev + delta

  -- アンチワインドアップ: 積分が slew 制限された出力より大きく先走らないよう抑える
  local windCap = out + s.maxBurn * 0.03
  if m.I > windCap then m.I = windCap end

  if out < 0 then out = 0 end
  if out > s.maxBurn then out = s.maxBurn end
  m.prevOut = out
  return out
end

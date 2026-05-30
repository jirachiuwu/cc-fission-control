-- naive: coolant 90% を目安に、上なら上げ下なら下げる固定ステップ（荒い bang-bang）
function control(s)
  local step = s.maxBurn * 0.01 * s.dt
  if s.coolant < 90 then return s.burn - step end
  return s.burn + step
end

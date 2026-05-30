-- baseline: 固定目標(maxの10%=100)へ緩やかにランプして保持（b12相当）
function control(s)
  local desired = s.maxBurn * 0.10
  local step = s.maxBurn * 0.01 * s.dt
  if s.burn < desired - step then return s.burn + step end
  if s.burn > desired + step then return s.burn - step end
  return desired
end

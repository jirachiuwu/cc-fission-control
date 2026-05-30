-- freestyle: adaptive boundary-rider for Mekanism fission burn control.
-- Goal: high sustained burn (near hidden cap), small ripple, never melt.
--
-- Idea: cap is hidden, but the buffers reveal it. With burn <= cap the coolant
-- saturates at 100 and heated drains to 0 (no signal -> room to push). With
-- burn > cap, heated rises and coolant falls in proportion to the deficit.
-- So we pin `heated` just above 0 at a tiny setpoint: that parks burn exactly
-- on the boundary (the maximum sustainable point). A slow integral term tracks
-- the cap estimate; a deadband + damping + output slew limit kill the ripple.

function control(s)
  local m = s.mem
  if not m.init then
    m.init = true
    m.est = 500.0       -- running estimate of the sustainable burn (cap)
    m.out = 0.0         -- last commanded burn (for slew limiting)
    m.pHeat = 0.0       -- previous heated (for rate damping)
  end

  local coolant = s.coolant
  local heated  = s.heated
  local temp    = s.temp
  local dt = s.dt

  -- Heated setpoint: a hair above 0 so we sit right at the edge.
  local heatSet = 1.5
  local heatErr = heated - heatSet          -- >0 over edge, <0 under it
  local dHeat   = (heated - m.pHeat) / dt    -- heated rate of change
  m.pHeat = heated

  -- Adaptive estimate of sustainable burn.
  -- Asymmetric, with a deadband so we coast smoothly once parked on the edge.
  local kUp   = 10.0    -- climb rate /s when clearly under the edge
  local kDown = 16.0    -- back-off rate /s when over the edge
  local dead  = 1.0     -- deadband around the setpoint (no integral push)
  if heatErr < -dead then
    m.est = m.est + kUp * ((-heatErr - dead) / heatSet) * dt
  elseif heatErr > dead then
    m.est = m.est - kDown * ((heatErr - dead) / heatSet) * dt
  end

  -- Rate damping: if heated is climbing, pre-emptively ease off (anticipate
  -- the overshoot before it builds). If falling, allow a gentle nudge up.
  local kDamp = 1.2
  m.est = m.est - kDamp * dHeat * dt

  -- Safety: coolant low -> hard retreat well before the cliff (coolant<12).
  if coolant < 40 then
    m.est = m.est - 50.0 * (40 - coolant) / 40 * dt
  end
  -- Temperature guard.
  if temp > 600 then
    m.est = m.est - (temp - 600) * 0.05 * dt
  end

  if m.est < 0 then m.est = 0 end
  if m.est > 980 then m.est = 980 end

  -- Output slew limiter: smooth the commanded burn so ripple stays tiny.
  local maxStep = 4.0 * dt   -- per-second slew, scaled to tick
  local target = m.est
  local delta = target - m.out
  if delta >  maxStep then delta =  maxStep end
  if delta < -maxStep then delta = -maxStep end
  m.out = m.out + delta

  return m.out
end

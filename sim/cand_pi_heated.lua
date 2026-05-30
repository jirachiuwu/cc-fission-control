-- pi_heated: PI control on heated coolant.
-- heated rises when burn > cap, falls when burn < cap. By holding heated at a
-- small positive setpoint we park burn right at the hidden throughput cap with
-- a thin safety margin. heated is the leading indicator of overload.

local SET = 1.0        -- heated setpoint (%) — thin margin, attack the boundary
local KP = 6.0         -- proportional gain (burn per % heated error, per sec)
local KI = 2.5         -- integral gain
local IMAX = 700.0     -- integrator clamp (burn units)
local SLEW = 35.0      -- max burn change per second (smoothness limiter)

function control(s)
  local m = s.mem
  if m.burn == nil then
    -- bootstrap: ramp from 0, seed integrator near a sane operating point
    m.burn = 0
    m.I = 400.0
  end

  local dt = s.dt
  local heated = s.heated
  local coolant = s.coolant

  -- error: positive when heated below setpoint (room to push harder)
  local err = SET - heated

  -- integral with anti-windup clamp
  m.I = m.I + KI * err * dt
  if m.I > IMAX then m.I = IMAX elseif m.I < 0 then m.I = 0 end

  local target = m.I + KP * err

  -- hard safety: if coolant getting low, back off aggressively
  if coolant < 25 then
    target = target - (25 - coolant) * 12.0
  end

  if target < 0 then target = 0 end
  if target > s.maxBurn then target = s.maxBurn end

  -- slew-rate limit for smoothness
  local maxStep = SLEW * dt
  local d = target - m.burn
  if d > maxStep then d = maxStep elseif d < -maxStep then d = -maxStep end
  m.burn = m.burn + d

  return m.burn
end

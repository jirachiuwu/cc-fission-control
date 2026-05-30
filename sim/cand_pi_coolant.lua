-- pi_coolant: PI control keeping coolant at a setpoint just below full.
-- Strategy: drive burn so coolant holds at SP (~97%). Integral term removes
-- steady-state error so burn converges to the hidden cap; proportional gain
-- is small to suppress oscillation. heated/temp used as safety guards.

function control(s)
  local m = s.mem
  if not m.init then
    m.init = true
    m.I = 520           -- integral accumulator seeds burn near a sane start
    m.burn = 300        -- last commanded burn (ramp from low/safe)
  end

  local SP   = 98.5     -- coolant setpoint (% just below full): high margin, gentle transient
  local Kp   = 1.0      -- proportional gain (per % error, small to suppress waves)
  local Ki   = 1.5      -- integral gain (per % error per second): kills steady-state error
  local dt   = s.dt

  local err = s.coolant - SP   -- >0 means coolant above SP -> room to push burn up

  -- integrate (this is the steady-state-holding term)
  m.I = m.I + Ki * err * dt

  -- clamp integral to plausible burn band to avoid windup
  if m.I < 0 then m.I = 0 end
  if m.I > s.maxBurn then m.I = s.maxBurn end

  local out = m.I + Kp * err

  -- safety: if heated buffer is filling fast or temp climbing, back off hard
  if s.heated > 8 or s.coolant < 30 then
    out = out - (s.heated * 6 + (30 - math.min(s.coolant,30)) * 4)
    -- bleed the integral too so we don't wind back up into the cliff
    m.I = m.I - Ki * 2 * dt
  end

  if out < 0 then out = 0 end
  if out > s.maxBurn then out = s.maxBurn end

  m.burn = out
  return out
end

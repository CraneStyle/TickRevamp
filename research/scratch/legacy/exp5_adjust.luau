local tick = require("./LegacyTick")
local DT = 1/60

print("=== 5a: adjust() on a delay-0 event => NaN timer => zombie visited every frame, never fires, never removed (F6) ===")
do
  local g = tick.group()
  local fired = false
  local h = g:delay(function() fired = true end, 0)
  h:adjust(5)
  print("  timer =", h.timer, " delay =", h.delay)
  for _ = 1, 600 do g:update(DT) end
  print("  fired after 10s?", fired, " #array=", #g, " (zombie)")
end

print("=== 5b: adjust(0) then adjust(x): 0 -> then NaN ; adjust(0) on recurring => infinite loop next update (guarded) ===")
do
  local g = tick.group()
  local n = 0
  local R = g:recur(function() n += 1; if n >= 1000 then error("infinite") end end, 1)
  R:adjust(0)
  print("  after adjust(0): timer =", R.timer, " delay =", R.delay)
  local ok = pcall(function() g:update(DT) end)
  print("  update hung until injected error?", not ok, " fires:", n)
end

print("=== 5c: adjust(negative) => negative timer & delay; recurring => infinite loop ===")
do
  local g = tick.group()
  local h = g:delay(function() end, 2)
  h:adjust(-1)
  print("  one-shot adjust(-1): timer =", h.timer, " (fires next update)")
  g:update(DT); print("  #array=", #g)
end

print("=== 5d: adjust(nil)/adjust('5') ===")
do
  local g = tick.group()
  local h = g:delay(function() end, 2)
  print("  adjust(nil):", pcall(function() h:adjust(nil) end))
  print("  adjust('4'):", pcall(function() h:adjust("4") end), " timer =", h.timer, " delay =", h.delay, type(h.delay))
end

print("=== 5e: reset() on a one-shot from inside its own callback => no-op (already removed) ===")
do
  local g = tick.group()
  local fires = 0
  local h; h = g:delay(function() fires += 1; h:reset() end, 0.5)
  for _ = 1, 120 do g:update(DT) end
  print("  fires:", fires, "(a user expecting re-arm gets 1)  #array=", #g, " h.timer=", h.timer)
end

print("=== 5f: reset() on an already-fired one-shot from OUTSIDE (AfterNotTouched.Touch after fn error) => no-op ===")
do
  local g = tick.group()
  local fires = 0
  local h = g:delay(function() fires += 1 end, 0.5)
  g:update(1); h:reset()
  for _ = 1, 120 do g:update(DT) end
  print("  fires:", fires, " #array=", #g)
end

print("=== 5g: reset() inside a recurring callback: phase drifts by the residual each time; cancels catch-up ===")
do
  local g = tick.group()
  local t = 0; local times = {}
  local R; R = g:recur(function() table.insert(times, t); R:reset() end, 0.1)
  for _ = 1, 60 do t += DT; g:update(DT) end
  local gaps = {}
  for i = 2, #times do gaps[#gaps+1] = string.format("%.4f", times[i] - times[i-1]) end
  print("  fire gaps with reset():", table.concat(gaps, " "), " (period 0.1; 7 frames=0.1167 => 17% slower than requested)")
  local g2 = tick.group(); t = 0; local n2 = 0
  local R2; R2 = g2:recur(function() n2 += 1; R2:reset() end, 0.1)
  g2:update(1.0)
  print("  lag 1.0s then reset() in callback: fires =", n2, "(without reset would be 10)")
end

print("=== 5h: adjust() on a recurring event from its own callback while lagging ===")
do
  local g = tick.group()
  local n = 0
  local R; R = g:recur(function() n += 1; if n == 1 then R:adjust(0.5) end end, 0.1)
  g:update(0.35)
  print("  fires in one update after adjust(0.5) on first fire:", n, " R.timer=", R.timer, " R.delay=", R.delay)
end

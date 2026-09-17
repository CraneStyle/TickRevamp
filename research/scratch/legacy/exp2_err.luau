local tick = require("./LegacyTick")
local DT = 1/60

print("=== 2a: self.err inside a RECURRING callback is POSITIVE (time-to-next-fire), nested delay is late ===")
do
  local g = tick.group()
  local t = 0
  local nestedFiredAt, createdAt
  local R = g:recur(function()
    if not createdAt then
      createdAt = t
      print(string.format("  R fired at t=%.4f, group.err=%.4f (residual would be %.4f)", t, g.err, g.err - 1))
      g:delay(function() nestedFiredAt = t end, 0.5)
    end
  end, 1)
  for _ = 1, 200 do t += DT; g:update(DT); if nestedFiredAt then break end end
  print(string.format("  nested delay(0.5) created at t=%.4f fired at t=%.4f => actual wait %.4f (expected ~0.5)", createdAt, nestedFiredAt, nestedFiredAt - createdAt))
end

print("=== 2b: self.err inside a ONE-SHOT callback is the residual (<=0): nested delay correct ===")
do
  local g = tick.group()
  local t = 0
  local nestedFiredAt, createdAt
  g:delay(function()
    createdAt = t
    print(string.format("  D fired at t=%.4f, group.err=%.4f", t, g.err))
    g:delay(function() nestedFiredAt = t end, 0.5)
  end, 1)
  for _ = 1, 200 do t += DT; g:update(DT); if nestedFiredAt then break end end
  print(string.format("  nested delay(0.5) created at t=%.4f fired at t=%.4f => actual wait %.4f", createdAt, nestedFiredAt, nestedFiredAt - createdAt))
end

print("=== 2c: err POISONING after a callback error: err stays non-zero until next successful update ===")
do
  local g = tick.group()
  g:recur(function() error("boom") end, 1)
  local ok, e = pcall(function() for _ = 1, 60 do g:update(DT) end end)
  print("  update raised:", ok == false, tostring(e):sub(1, 40), " group.err now =", g.err, "(should be 0 between updates)")
  -- top-level code now creates a normal 0.5s delay:
  local B = g:delay(function() print("  B fired") end, 0.5)
  print("  top-level delay(0.5) got timer =", B.timer, "(expected 0.5) => late by", B.timer - 0.5)
  -- one-shot error variant: err negative -> top-level short delay fires SYNCHRONOUSLY at top level
  local g2 = tick.group()
  g2:delay(function() error("boom") end, 0.01)
  pcall(function() g2:update(0.5) end)
  print("  after one-shot error: g2.err =", g2.err)
  local firedSync = false
  local h = g2:delay(function() firedSync = true end, 0.1)
  print("  top-level delay(0.1) fired synchronously inside delay()?", firedSync, " returned handle fn is noop?", h.fn ~= nil and tostring(h.fn):find("function") ~= nil)
end

print("=== 2d: error mid-frame skips remaining (lower-index) events for that frame: they drift by dt ===")
do
  local g = tick.group()
  local A = g:delay(function() end, 10)       -- idx 1, visited last
  local E = g:delay(function() error("x") end, 0.5) -- idx 2, visited first
  pcall(function() g:update(1) end)
  print("  A.timer after update(1) =", A.timer, "(expected 9; A never got this frame's dt)")
end

print("=== 2e: immediate-fire path: fn runs BEFORE delay() returns => handle is nil inside fn ===")
do
  local g = tick.group()
  local msg
  g:delay(function()
    -- inside a callback, err = residual (e.g. -0.5 here)
    local h
    local ok, e = pcall(function()
      h = g:delay(function() h:stop() end, 0.1)  -- 0.1 + (-0.5) < 0 => fires NOW, h still nil
    end)
    msg = tostring(e)
  end, 0.5)
  g:update(1)
  print("  nested fn errored with:", msg)
end

print("=== 2f: immediate-fire path with recur: user fn runs ONCE, a noop recurs forever in its place ===")
do
  local g = tick.group()
  local userFires = 0
  local handle
  g:delay(function()
    handle = g:recur(function() userFires += 1 end, 0.1) -- 0.1 + (-0.5) < 0
  end, 0.5)
  g:update(1)
  for _ = 1, 600 do g:update(DT) end -- 10 more seconds
  print("  user recur(0.1) fired", userFires, "times over 10s (expected ~100);", "handle.fn is the module noop?", handle.recur, "#group =", #g, "handle.timer", handle.timer)
end

print("=== 2g: immediate-fire path with recur(fn, 0) inside a callback => noop recur with delay 0 => next update hangs (guarded) ===")
do
  local g = tick.group()
  g:delay(function() g:recur(function() end, 0) end, 0.5)
  g:update(1)
  -- Now the dummy has recur=true, delay=0. Next update would loop forever. Prove by patching noop? We can't reach noop; instead bound the loop via debug.sethook-less approach:
  -- swap the dummy's fn for a counter that errors after 1000 iterations.
  local dummy = g[1]
  local n = 0
  dummy.fn = function() n += 1; if n >= 1000 then error("would loop forever") end end
  local ok, e = pcall(function() g:update(DT) end)
  print("  update terminated only by the injected error?", not ok, "iterations before bail:", n, " dummy.delay =", dummy.delay, "recur =", dummy.recur)
end

print("=== 2h: zero-delay events: top-level delay(fn,0) fires NEXT frame; nested delay(fn,0) fires now or next frame depending on residual ===")
do
  local g = tick.group()
  local topFired = false
  g:delay(function() topFired = true end, 0)
  print("  top-level delay(0): fired synchronously?", topFired)
  g:update(DT); print("  after 1 update:", topFired)
  local g2 = tick.group()
  local seq = {}
  g2:delay(function() table.insert(seq, "parent"); g2:delay(function() table.insert(seq, "nested0") end, 0); table.insert(seq, "after-create") end, 0.5)
  g2:update(1)  -- residual -0.5 => nested d = 0 + (-0.5) < 0 => synchronous
  print("  residual -0.5: order =", table.concat(seq, " > "))
  local g3 = tick.group(); seq = {}
  g3:delay(function() table.insert(seq, "parent"); g3:delay(function() table.insert(seq, "nested0") end, 0); table.insert(seq, "after-create") end, 1)
  g3:update(1)  -- residual exactly 0 => d = 0, NOT < 0 => normal event, fires next frame
  print("  residual  0.0: order =", table.concat(seq, " > "), " (nested0 pending:", #g3, ")")
end

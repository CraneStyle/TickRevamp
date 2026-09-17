local tick = require("./LegacyTick")
local DT = 1/60

print("=== 6a: nested update() from inside a callback ===")
do
  local g = tick.group()
  local A = g:delay(function() end, 10)
  local log = {}
  local B; B = g:delay(function()
    table.insert(log, "B.fn err=" .. tostring(g.err))
    g:update(1)  -- re-entrant
    table.insert(log, "after nested update err=" .. tostring(g.err))
    g:delay(function() end, 0.5)  -- created with err now 0 instead of -0.5
  end, 0.5)
  g:update(1)
  print("  ", table.concat(log, " | "), " A.timer=", A.timer, "(expected 9, got 8: double dt)")
end

print("=== 6b: a callback that YIELDS suspends update() mid-loop; the next frame's update runs on the same array ===")
do
  local g = tick.group()
  local A = g:recur(function() end, 10)   -- idx1, visited last
  local log = {}
  local Y; Y = g:delay(function()
    table.insert(log, "Y.fn start (err=" .. g.err .. ")")
    coroutine.yield()                      -- simulates task.wait()/remote call inside the callback
    table.insert(log, "Y.fn resumed (err=" .. g.err .. ")")
    g:delay(function() end, 0.5)           -- nested creation after resume
  end, 0.5)
  local C = g:delay(function() end, 10)  -- idx3, visited first
  local co = coroutine.create(function() g:update(1) end)
  coroutine.resume(co)                   -- frame 1: C visited, Y fires and yields
  table.insert(log, "frame1 suspended: A.timer=" .. A.timer .. " C.timer=" .. C.timer .. " err=" .. g.err)
  g:update(1)                            -- frame 2 runs to completion while frame 1 is suspended
  table.insert(log, "frame2 done: A.timer=" .. A.timer .. " C.timer=" .. C.timer .. " err=" .. g.err)
  coroutine.resume(co)                   -- frame 1 resumes: continues its loop from i=1 with stale bound
  table.insert(log, "frame1 finished: A.timer=" .. A.timer .. " C.timer=" .. C.timer .. " err=" .. g.err)
  print("  " .. table.concat(log, "\n  "))
  print("  => A got 3 dt over 2 frames; nested delay created after resume saw err=0 (lost residual)")
end

print("=== 6c: callback stops a DIFFERENT due event in the same frame: is it silently skipped? ===")
do
  local g = tick.group()
  local ran = {}
  local A = g:delay(function() ran.A = true end, 0.5)     -- idx1, due, visited second
  local B = g:delay(function() ran.B = true; A:stop() end, 0.5) -- idx2, due, visited first
  g:update(1)
  print("  B ran:", ran.B, " A ran:", ran.A, "(A was due this frame but B cancelled it first: order-dependent)")
  -- reverse creation order: A visited first and fires before B can cancel it
  local g2 = tick.group(); ran = {}
  local B2; B2 = g2:delay(function() ran.B = true; end, 0.5)
  local A2 = g2:delay(function() ran.A = true; B2:stop() end, 0.5)
  g2:update(1)
  print("  reversed: A2 ran:", ran.A, " B2 ran:", ran.B, "(B2 cancelled before it could fire)")
end

local tick = require("./LegacyTick")
local DT = 1/60

print("=== 4a: after() on an event whose fn already ran => dead chain, child never scheduled, no error ===")
do
  local g = tick.group()
  local P = g:delay(function() end, 0.5); g:update(1)
  local ran = false
  local C = P:after(function() ran = true end, 0.1)
  for _ = 1, 120 do g:update(DT) end
  print("  child ran?", ran, " #array=", #g, " returned child timer=", C.timer)
end

print("=== 4b: after() from inside the parent's own callback => dead (parent already removed) ===")
do
  local g = tick.group()
  local ran = false
  local P; P = g:delay(function() P:after(function() ran = true end, 0.1) end, 0.5)
  for _ = 1, 120 do g:update(DT) end
  print("  child ran?", ran, " #array=", #g)
end

print("=== 4c: chain of chains timing + err carry ===")
do
  local g = tick.group()
  local t = 0
  local times = {}
  local A = g:delay(function() times.A = t end, 1.0)
  local B = A:after(function() times.B = t end, 1.0)
  local C = B:after(function() times.C = t end, 1.0)
  for _ = 1, 60 * 4 do t += DT; g:update(DT) end
  print(string.format("  A@%.4f B@%.4f C@%.4f  (ideal 1,2,3; each within one frame)", times.A, times.B, times.C))
end

print("=== 4d: two after()s on one parent: both children run ===")
do
  local g = tick.group()
  local ran = {}
  local A = g:delay(function() ran.A = true end, 0.5)
  A:after(function() ran.B = true end, 0.1)
  A:after(function() ran.C = true end, 0.1)
  for _ = 1, 60 do g:update(DT) end
  print("  A,B,C ran:", ran.A, ran.B, ran.C)
end

print("=== 4e: parent callback errors => wrapper aborts => child never added (chain silently dies) ===")
do
  local g = tick.group()
  local ran = false
  local A = g:delay(function() error("parent boom") end, 0.5)
  A:after(function() ran = true end, 0.1)
  pcall(function() g:update(1) end)
  for _ = 1, 60 do g:update(DT) end
  print("  child ran?", ran, " #array=", #g)
end

print("=== 4f: F8 revive: stop child before parent fires, child still runs ===")
do
  local g = tick.group()
  local ran = false
  local A = g:delay(function() end, 0.5)
  local B = A:after(function() ran = true end, 0.1)
  B:stop()
  for _ = 1, 60 do g:update(DT) end
  print("  child ran despite stop?", ran)
end

print("=== 4g: stopping the PARENT before it fires: child never runs (correct), but child:stop() later leaks a false key ===")
do
  local g = tick.group()
  local A = g:delay(function() end, 0.5)
  local B = A:after(function() end, 0.1)
  A:stop(); B:stop()
  local n = 0 for k, v in pairs(g) do if v == false then n += 1 end end
  print("  false keys:", n, " #array=", #g)
end

print("=== 4h: after() on the immediate-fire dummy: chain still works, one frame late ===")
do
  local g = tick.group()
  local t = 0
  local times = {}
  g:delay(function()
    times.parentCb = t
    local d = g:delay(function() times.inner = t end, 0.1) -- 0.1 - 0.5 < 0 -> immediate, dummy returned
    d:after(function() times.chained = t end, 0.2)
  end, 0.5)
  for _ = 1, 120 do t += DT; g:update(DT) end
  print(string.format("  parentCb@%.4f inner@%.4f chained@%.4f  (chained ideal = parent-ideal 0.5 + 0.1 + 0.2 = 0.8)", times.parentCb, times.inner, times.chained))
end

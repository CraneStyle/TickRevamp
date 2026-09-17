-- Experiment 1: swap-on-remove double-dt family
local tick = require("./LegacyTick")
local function fresh() return tick.group() end
local function names(g) local t = {} for i = 1, #g do t[#t+1] = g[i].name end return table.concat(t, ",") end

print("=== 1a: one-shot B (idx2) fires, callback stops A (idx1); C (idx3) recurring long ===")
do
  local g = fresh()
  local A = g:delay(function() print("A fired") end, 10); A.name = "A"
  local B; B = g:delay(function() print("  B.fn: stopping A"); A:stop() end, 0.5); B.name = "B"
  local C = g:recur(function() print("C fired") end, 10); C.name = "C"
  print("order:", names(g), " C.timer=", C.timer)
  g:update(1)
  print("after update(1): order:", names(g), " C.timer=", C.timer, "(expected 9, got 8 => double dt)")
end

print("=== 1b: recurring e at tail stops A (lower idx): e visited twice ===")
do
  local g = fresh()
  local A = g:delay(function() print("A fired") end, 10); A.name = "A"
  local fires = 0
  local E; E = g:recur(function() fires += 1; print("  E.fn fire#", fires, "timer", E.timer); if fires == 1 then A:stop() end end, 1); E.name = "E"
  print("order:", names(g))
  g:update(1)
  print("after update(1): order:", names(g), " E.timer=", E.timer, "(expected 1, got 0 => double dt); fires=", fires)
  g:update(0.001)
  print("after update(0.001): fires=", fires, " (E fired again 1s early)")
end

print("=== 1c: replace pattern in callback: stop old, create new -> new gets extra dt ===")
do
  local g = fresh()
  local A = g:delay(function() print("A fired") end, 10); A.name = "A"
  local Cnew
  local B; B = g:delay(function() A:stop(); Cnew = g:delay(function() print("Cnew fired") end, 1); Cnew.name = "Cnew" end, 0.5); B.name = "B"
  g:update(1)
  print("after update(1): order:", names(g), " Cnew.timer=", Cnew.timer, "(expected 1 + err(-0.5) = 0.5, got -0.5 => extra dt; fires next frame regardless, but 1s later it would be late... check)")
end

print("=== 1d: create new, then stop old: new event moved into stopped slot -> extra dt ===")
do
  local g = fresh()
  local A = g:delay(function() print("A fired") end, 10); A.name = "A"
  local Cnew
  local B; B = g:delay(function() Cnew = g:delay(function() print("Cnew fired") end, 3); Cnew.name = "Cnew"; A:stop() end, 0.5); B.name = "B"
  g:update(1)
  print("after update(1): order:", names(g), " Cnew.timer=", Cnew.timer, "(expected 3-0.5=2.5, got 1.5 => extra dt)")
end

print("=== 1e: nil guard trigger: e is tail, callback stops a lower event -> slot nil; rxi upstream would crash ===")
do
  local g = fresh()
  local A = g:delay(function() print("A fired") end, 10); A.name = "A"
  local B = g:delay(function() print("B fired") end, 10); B.name = "B"
  local E = g:delay(function() print("  E.fn stops B"); B:stop() end, 0.5); E.name = "E"
  print("before:", names(g), "#=", #g)
  local ok, err = pcall(function() g:update(1) end)
  print("update ok?", ok, err, " after:", names(g), " A.timer=", A.timer, "(A visited once: 9)")
end

print("=== 1f: callback stops TWO lower events; check every survivor's timer ===")
do
  local g = fresh()
  local A = g:delay(function() end, 10); A.name = "A"
  local B = g:delay(function() end, 10); B.name = "B"
  local C = g:delay(function() end, 10); C.name = "C"
  local D = g:delay(function() end, 10); D.name = "D"
  local E = g:delay(function() A:stop(); B:stop() end, 0.5); E.name = "E"
  g:update(1)
  print("after:", names(g), " C.timer=", C.timer, " D.timer=", D.timer, "(expected 9 each)")
end

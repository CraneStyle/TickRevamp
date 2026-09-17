local tick = require("./LegacyTick")
local rxi = require("./rxi_tick")
local DT = 1/60

print("=== 8a: rxi upstream CRASHES on the case the legacy nil-guard hides ===")
do
  local g = rxi.group()
  local A = g:delay(function() end, 10)
  local B = g:delay(function() end, 10)
  local E = g:delay(function() B:stop() end, 0.5)
  print("  rxi update:", pcall(function() g:update(1) end))
end

print("=== 8b: input validation: NaN delay => zombie; math.huge; string coercion; boolean ===")
do
  local g = tick.group()
  local fired = false
  local h = g:delay(function() fired = true end, 0/0)
  for _ = 1, 100 do g:update(1) end
  print("  delay(NaN): accepted, timer =", h.timer, " fired?", fired, " #array=", #g, "(permanent zombie)")
  local g2 = tick.group()
  print("  delay('0.5'):", pcall(function() return g2:delay(function() end, "0.5").timer end))
  print("  delay(true):", pcall(function() return g2:delay(function() end, true) end))
  print("  delay(nil):", pcall(function() return g2:delay(function() end, nil) end))
  print("  delay(-1):", pcall(function() return g2:delay(function() end, -1) end))
  print("  delay(fn=nil):", pcall(function() return g2:delay(nil, 1) end))
  print("  delay(fn=callable table):", pcall(function() return type(g2:delay(setmetatable({}, {__call = function() end}), 1)) end))
  print("  recur(fn, 0) at top level => infinite loop on next update (F5): guarded probe:")
  local g3 = tick.group(); local n = 0
  g3:recur(function() n += 1; if n >= 1000 then error("infinite") end end, 0)
  print("   ", pcall(function() g3:update(DT) end), " fires before bail:", n)
end

print("=== 8c: catch-up burst after a hitch: recur(0.01) with one dt=5 frame ===")
do
  local g = tick.group(); local n = 0
  g:recur(function() n += 1 end, 0.01)
  g:update(5)
  print("  fires in one update:", n)
end

print("=== 8d: same-frame ordering is newest-first and gets scrambled by swap-on-remove ===")
do
  local g = tick.group(); local order = {}
  for i = 1, 5 do g:delay(function() table.insert(order, i) end, 1) end
  g:update(1)
  print("  5 events same due, creation 1..5, fire order:", table.concat(order, ","))
  local g2 = tick.group(); order = {}
  local hs = {}
  for i = 1, 6 do hs[i] = g2:delay(function() table.insert(order, i) end, 1) end
  hs[1]:stop(); hs[2]:stop()  -- swaps 6->1, 5->2
  g2:update(1)
  print("  after stopping #1,#2 the array is [6,5,3,4]; fire order:", table.concat(order, ","))
end

print("=== 8e: remove(idx) misuse via public bound.remove(number) ===")
do
  local g = tick.group()
  print("  remove(7) on 0 events:", pcall(function() return g:remove(7) end))
end

print("=== 8f: 0.5 s fires one frame late? boundary: delay == k*dt ===")
do
  local g = tick.group(); local t = 0; local at
  g:delay(function() at = t end, 3 * DT)
  for _ = 1, 10 do t += DT; g:update(DT); if at then break end end
  print(string.format("  delay(3dt) fired at %.6f (3dt=%.6f) => timer<=0 fires on the boundary frame, subject to float error", at, 3 * DT))
end

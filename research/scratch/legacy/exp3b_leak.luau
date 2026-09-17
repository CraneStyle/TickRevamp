local tick = require("./LegacyTick")
local function falseCount(g) local n = 0 for k, v in pairs(g) do if v == false then n += 1 end end return n end
print("=== 3b: one-shot that stops ITSELF from inside its callback (cleanup idiom) ===")
do local g = tick.group(); for i = 1, 1000 do local h; h = g:delay(function() h:stop() end, 0.001); g:update(1) end
  print("  #array=", #g, " false-keys=", falseCount(g), "(N=1000)") end
print("=== 3c: double stop on a pending event ===")
do local g = tick.group(); local h = g:delay(function() end, 5); h:stop(); h:stop(); print("  #array=", #g, " false-keys=", falseCount(g), " g[h] =", g[h]) end
print("=== 3d: recurring stops itself on first fire while lagging: keeps firing this frame + leaks ===")
do local g = tick.group(); local fires = 0; local R; R = g:recur(function() fires += 1; R:stop() end, 0.1); g:update(0.35)
  print("  fires:", fires, "(expected 1)  false-keys=", falseCount(g), " #array=", #g) end
print("=== 3e: stop child before parent fires: false key then overwritten by add (no leak) but F8 revive ===")
do local g = tick.group(); local ran = false; local P = g:delay(function() end, 1); local C = P:after(function() ran = true end, 1); C:stop()
  print("  after C:stop(): g[C] =", g[C]); g:update(1); print("  parent fired; g[C] =", g[C], " #array=", #g); g:update(1); print("  child ran despite stop?", ran, " g[C] =", g[C]) end

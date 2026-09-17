local Legacy = require("../../../../TickAPIOptimize/reference/lune/Tick")
local okR, rxi = pcall(require, "../../../reference/rxi-tick/tick")
print("rxi loadable:", okR, okR and type(rxi) or rxi)

local function run(lib, label)
	print("\n== "..label..": victim at idx1, two already-processed entries above the firing one")
	local g = lib.group(); local log = {}
	local victim = g:delay(function() table.insert(log,"victim") end, 5)   -- idx1
	local y = g:delay(function() table.insert(log,"y") end, 1.2)           -- idx2
	local c = g:recur(function() table.insert(log,"c"); victim:stop() end, 0.5) -- idx3 (recurring: stays)
	local w = g:delay(function() table.insert(log,"w") end, 1.9)           -- idx4 processed first
	local ok, err = pcall(function() g:update(1) end)
	print("ok:", ok, err or "", "log:", table.concat(log,","), "w.timer=", w.timer, "(0.9 = once; -0.1/fired = double-ticked)", "y.timer=", y.timer)
end
run(Legacy, "legacy")
if okR then run(rxi, "rxi") end

local function run2(lib, label)
	print("\n== "..label..": one-shot fires and stops victim idx1 while >=2 processed entries above")
	local g = lib.group(); local log = {}
	local victim = g:delay(function() table.insert(log,"victim") end, 5)   -- idx1
	local y = g:delay(function() table.insert(log,"y") end, 1.2)           -- idx2
	local c = g:delay(function() table.insert(log,"c"); victim:stop() end, 0.5) -- idx3
	local w = g:delay(function() table.insert(log,"w") end, 1.9)           -- idx4
	local v = g:delay(function() table.insert(log,"v") end, 1.8)           -- idx5 processed first
	local ok, err = pcall(function() g:update(1) end)
	print("ok:", ok, err or "", "log:", table.concat(log,","), "w.timer=", w.timer, "v.timer=", v.timer, "y.timer=", y.timer)
end
run2(Legacy, "legacy")
if okR then run2(rxi, "rxi") end

print("\n== rxi: nil-skip case (stop of idx1 from idx3 with 3 entries)")
if okR then
	local g = rxi.group(); local log = {}
	local x = g:delay(function() table.insert(log,"x") end, 5)
	local y = g:delay(function() table.insert(log,"y") end, 1.2)
	local z = g:delay(function() table.insert(log,"z"); x:stop() end, 0.5)
	print("rxi ok:", pcall(function() g:update(1) end))
end

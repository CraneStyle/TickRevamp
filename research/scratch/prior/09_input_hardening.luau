local C = require("./_common")
local G = C.G
C.section("update(nil)")
print(pcall(function() G().update(nil) end))
C.section("update(NaN) permanently poisons the group: everything fires immediately forever")
do
	local g = G()
	g.update(0 / 0)
	local fired = false
	g.delay(function() fired = true end, 3600)
	g.update(0.001)
	print("now =", g.now(), "| delay(3600) fired next frame:", fired)
end
C.section("update(-1): clock runs backwards, no guard")
do
	local g = G()
	g.update(-1)
	print("now =", g.now())
end
C.section("update(math.huge) with a recur: uncapped => infinite loop (NOT run); capped => fires every frame forever")
do
	local g = G({ maxCatchUpPerFrame = 1 })
	local n = 0
	g.recur(function() n += 1 end, 1)
	g.update(math.huge)
	for _ = 1, 5 do g.update(0.001) end
	print("1s recur fires after inf + 5 tiny updates:", n, "(expected 1) | now =", g.now())
end
C.section("delay(fn, NaN) is ACCEPTED (Handle.new checks period<0 only) and corrupts heap order")
do
	local g = G()
	local log = {}
	g.delay(function() table.insert(log, "d0.1") end, 0.1)      -- root
	local ok = pcall(function() g.delay(function() table.insert(log, "dNaN") end, 0 / 0) end) -- node 2
	print("delay(NaN) accepted:", ok)
	g.delay(function() table.insert(log, "d0.2") end, 0.2)      -- node 3
	g.delay(function() table.insert(log, "d0.05") end, 0.05)    -- node 4, child of NaN: cannot sift past it
	g.update(0.06)
	print("after update(0.06): fired =", table.concat(log, ","), "(d0.05 is due but stuck under the NaN node)")
	g.update(0.05)
	print("after update(0.11): fired =", table.concat(log, ","))
end
C.section("recur(fn, NaN) is rejected; delay(fn, inf) accepted (never fires)")
print(pcall(function() G().recur(function() end, 0 / 0) end))
print(pcall(function() return G().delay(function() end, math.huge)._due end))
C.section("huge dt with default maxCatchUpPerFrame=nil: recur(0.01) + update(1000) => 100k dispatches in one update")
do
	local g = G()
	local n = 0
	g.recur(function() n += 1 end, 0.01)
	local t0 = os.clock()
	g.update(1000)
	print(("dispatches: %d in %.1f ms"):format(n, (os.clock() - t0) * 1000))
end

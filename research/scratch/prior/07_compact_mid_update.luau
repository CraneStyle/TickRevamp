local C = require("./_common")
local G = C.G
C.section("rebuild from a callback mid-update: current recur kept, later same-frame one-shot still dispatched")
do
	local g = G()
	local far = {}
	for i = 1, 200 do far[i] = g.delay(function() end, 100) end
	local rFires, sFired = 0, false
	g.recur(function()
		rFires += 1
		if rFires == 1 then for i = 1, 150 do far[i]:stop() end end -- stale 150 > max(64, live=52) -> rebuild now
	end, 1)
	g.delay(function() sFired = true end, 1) -- created after r, same due -> pops after r
	g.update(1)
	print("after update(1): rFires =", rFires, "sFired =", sFired, "|", C.stats(g))
	g.update(1)
	print("after update(2): rFires =", rFires, "(recur survived the rebuild) |", C.stats(g))
end
C.section("stale-drift check across a long random workload (uncapped): stale never negative")
do
	local g = G()
	math.randomseed(7); local rng = { NextInteger = function(_, a, b) return math.random(a, b) end, NextNumber = function(_, a, b) if a == nil then return math.random() end return a + math.random() * (b - a) end }
	local hs = {}
	local minStale = 0
	for _ = 1, 3000 do
		local op = rng:NextInteger(1, 6)
		if op == 1 then table.insert(hs, g.delay(function() end, rng:NextNumber(0, 3)))
		elseif op == 2 then table.insert(hs, g.recur(function() end, rng:NextNumber(0.1, 2)))
		elseif op == 3 and #hs > 0 then hs[rng:NextInteger(1, #hs)]:stop()
		elseif op == 4 and #hs > 0 then local h = hs[rng:NextInteger(1, #hs)]; if h:getState() == "Pending" then h:pause() end
		elseif op == 5 and #hs > 0 then hs[rng:NextInteger(1, #hs)]:resume()
		else g.update(rng:NextNumber(0, 0.5)) end
		minStale = math.min(minStale, g:getStats().stale)
	end
	print("uncapped random workload min stale =", minStale, "|", C.stats(g))
end
C.section("same workload with maxCatchUpPerFrame=1 and self-stopping recurs: stale drifts negative")
do
	local g = G({ maxCatchUpPerFrame = 1 })
	math.randomseed(7); local rng = { NextInteger = function(_, a, b) return math.random(a, b) end, NextNumber = function(_, a, b) if a == nil then return math.random() end return a + math.random() * (b - a) end }
	local minStale = 0
	for _ = 1, 3000 do
		local op = rng:NextInteger(1, 3)
		if op == 1 then local h; h = g.recur(function() if rng:NextNumber() < 0.5 then h:stop() end end, rng:NextNumber(0.1, 1))
		else g.update(rng:NextNumber(0, 0.5)) end
		minStale = math.min(minStale, g:getStats().stale)
	end
	print("capped random workload min stale =", minStale, "|", C.stats(g))
end

local C = require("./_common")
local G = C.G

C.section("Re-entrant update: nested update() clears the outer pass's onError='error' slot")
do
	local g = G({ onError = "error" })
	g.delay(function() error("boom-from-A") end, 1)
	g.delay(function() g.update(0) end, 1) -- fires after A in the same pass, nests an update
	local ok, err = pcall(function() g.update(1) end)
	print("outer update raised? (expected true with 'boom-from-A'):", not ok, err)
end

C.section("Re-entrant update: nested update() breaks the _base carry for chained children")
do
	local g = G()
	local parent = g.delay(function() g.update(5) end, 1)
	local child = parent:after(function() end, 1)
	g.update(1)
	print("child due =", child._due, "(carry-preserving answer: 2 = parent due 1 + 1)")
	print("stats after outer update:", C.stats(g), "<- examined/dispatched are the INNER pass's numbers")
end

C.section("Re-entrant update: a recurring callback calling update(period) recurses into itself")
do
	local g = G()
	local depth, maxDepth = 0, 0
	local h
	h = g.recur(function()
		depth += 1
		maxDepth = math.max(maxDepth, depth)
		if depth < 6 then g.update(1) end -- guard so the demo terminates
		depth -= 1
	end, 1)
	g.update(1)
	print("max nesting depth reached (6 = the guard; unguarded => stack overflow):", maxDepth, C.stats(g))
end

C.section("Re-entrant update: no _updating guard exists")
do
	local g = G()
	print("g._updating =", g._updating, "| g._inUpdate =", g._inUpdate)
end

local C = require("./_common")
local G = C.G
C.section("equal-due fire order = creation order")
do
	local g = G()
	local log = {}
	for i = 1, 6 do g.delay(function() table.insert(log, i) end, 1) end
	g.update(1)
	print(table.concat(log, ","))
end
C.section("zero-delay self-reschedule from inside a callback runs to exhaustion in ONE update (infinite loop without a guard)")
do
	local g = G()
	local n = 0
	local function tick() n += 1; if n < 1000 then g.delay(tick, 0) end end
	g.delay(tick, 0)
	g.update(1 / 60)
	print("fires in ONE update:", n, "(a 'next frame' idiom becomes a same-frame busy loop) |", C.stats(g))
end
C.section("delay(fn,0) at top level fires on the NEXT update; inside a callback it fires in the SAME update")
do
	local g = G()
	local top, nested = false, false
	g.delay(function() top = true end, 0)
	print("top-level delay(0) before any update:", top)
	g.update(0.016)
	print("after first update:", top)
	g.delay(function() g.delay(function() nested = true end, 0) end, 0.5)
	g.update(0.5)
	print("nested delay(0) fired inside the creating update:", nested)
end
C.section("adjust(same) inside own callback when exactly on time: no loop")
do
	local g = G()
	local n = 0
	local h
	h = g.recur(function() n += 1; if n > 20 then h:stop() end; h:adjust(1) end, 1)
	g.update(1.0)
	print("exactly-on-time adjust(same): fires =", n, "(1 expected)")
end

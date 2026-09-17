local C = require("./_common")
local G = C.G
C.section("after() on a Chained child (grandchild) arms when the child fires")
do
	local g = G()
	local log = {}
	local p = g.delay(function() table.insert(log, "p@" .. g.now()) end, 1)
	local c = p:after(function() table.insert(log, "c@" .. g.now()) end, 1)
	local gc = c:after(function() table.insert(log, "gc@" .. g.now()) end, 1)
	for _ = 1, 4 do g.update(1) end
	print(table.concat(log, " "), "| gc state:", gc:getState())
end
C.section("multiple after() on one parent fire in insertion order; adjust() on a Chained child uses the new period")
do
	local g = G()
	local log = {}
	local p = g.delay(function() end, 1)
	for i = 1, 4 do p:after(function() table.insert(log, i) end, 1) end
	local slow = p:after(function() table.insert(log, "slow@" .. g.now()) end, 1)
	slow:adjust(3)
	g.update(2); g.update(2)
	print(table.concat(log, ","), "| slow period", slow.period)
end
C.section("parent PAUSED then STOPPED -> children Stopped; parent paused/resumed -> child armed")
do
	local g = G()
	local p = g.delay(function() end, 1)
	local c = p:after(function() end, 1)
	p:pause(); p:stop()
	print("child after parent pause+stop:", c:getState())
	local p2 = g.delay(function() end, 1)
	local c2 = p2:after(function() end, 1)
	p2:pause(); g.update(5); p2:resume(); g.update(1)
	print("child after parent pause/resume/fire:", c2:getState(), "due", c2._due)
end
C.section("after() called on a terminal handle returns the PARENT itself (no child created)")
do
	local g = G()
	local ret
	local p
	p = g.delay(function() ret = p:after(function() print("never") end, 1) end, 1)
	g.update(1)
	print("inside own callback: after() returned parent?", ret == p, "| #p._chained =", #p._chained)
	local s = g.delay(function() end, 1); s:stop()
	local r2 = s:after(function() end, 1)
	print("on Stopped: returned parent?", r2 == s, "| Handle.is:", C.Handle.is(r2))
end
C.section("getRemaining on a Chained child returns its period, not time-until-fire")
do
	local g = G()
	local p = g.delay(function() end, 5)
	local c = p:after(function() end, 1)
	print("child remaining =", c:getRemaining(), "(true time until fire = 6)")
end

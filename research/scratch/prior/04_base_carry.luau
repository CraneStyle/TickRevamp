local C = require("./_common")
local G = C.G
local Tick = require("../../../../TickAPIOptimize/reference/lune/Tick")

C.section("_base carry: delay created inside the 3rd catch-up fire of a recur")
do
	local g = G()
	local nested
	local fires = 0
	g.recur(function()
		fires += 1
		if fires == 3 then nested = g.delay(function() end, 0.25) end
	end, 1)
	g.update(3.5)
	print("new Group: nested due =", nested._due, "(3rd fire due 3 + 0.25 = 3.25)")
end

C.section("SAME scenario on the legacy/rxi core: nested delay inside a recur is measured from the NEXT due")
do
	local grp = Tick.group()
	local nested
	local fires = 0
	grp:recur(function()
		fires += 1
		if fires == 3 then nested = grp:delay(function() end, 0.25) end
	end, 1)
	grp:update(3.5)
	print("legacy: nested.timer =", nested.timer, "-> fires at now(3.5)+timer =", 3.5 + nested.timer, "(= next due 4 + 0.25; new Group says 3.25)")
end

C.section("Non-lagging case: recur period 1 at 60 Hz, callback arms delay(0.5): when does it fire?")
do
	local grp = Tick.group()
	local t, firedAt = 0, nil
	local armed = false
	grp:recur(function() if not armed then armed = true; grp:delay(function() firedAt = t end, 0.5) end end, 1)
	for _ = 1, 200 do t += 1 / 60; if not firedAt then grp:update(1 / 60) end end
	print(("legacy: recur fires at ~1.0s, nested delay(0.5) fired at t=%.3f"):format(firedAt or -1))
	local g = G()
	local t2, firedAt2 = 0, nil
	local armed2 = false
	g.recur(function() if not armed2 then armed2 = true; g.delay(function() firedAt2 = t2 end, 0.5) end end, 1)
	for _ = 1, 200 do t2 += 1 / 60; if not firedAt2 then g.update(1 / 60) end end
	print(("new:    nested delay(0.5) fired at t=%.3f"):format(firedAt2 or -1))
end

C.section("Chained child after() carry: both measure from the parent's due (parity)")
do
	local grp = Tick.group()
	local lt, lfired = 0, nil
	grp:delay(function() end, 1):after(function() lfired = lt end, 0.5)
	for _ = 1, 200 do lt += 1 / 60; if not lfired then grp:update(1 / 60) end end
	local g = G()
	local nt, nfired = 0, nil
	g.delay(function() end, 1):after(function() nfired = nt end, 0.5)
	for _ = 1, 200 do nt += 1 / 60; if not nfired then g.update(1 / 60) end end
	print(("legacy after fired at %.3f, new after fired at %.3f"):format(lfired or -1, nfired or -1))
end

C.section("reset() inside a callback: legacy is now-relative, new is firing-due-relative")
do
	local grp = Tick.group()
	local other = grp:delay(function() end, 10)
	grp:delay(function() other:reset() end, 1)
	grp:update(1.4)
	print("legacy other.timer after reset =", other.timer, "(fires at 1.4 + 10 = 11.4)")
	local g = G()
	local o2 = g.delay(function() end, 10)
	g.delay(function() o2:reset() end, 1)
	g.update(1.4)
	print("new    other._due after reset  =", o2._due, "(fires at 11.0)")
end

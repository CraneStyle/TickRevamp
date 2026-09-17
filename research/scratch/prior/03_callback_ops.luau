local C = require("./_common")
local G = C.G

C.section("clear() from inside a callback mid-update: later same-frame handles must not fire")
do
	local g = G()
	local fired = {}
	g.delay(function() fired.A = true; g.clear() end, 1)
	g.delay(function() fired.B = true end, 1)
	g.recur(function() fired.R = true end, 2)
	g.delay(function() fired.P = true end, 1):after(function() fired.Pc = true end, 0)
	g.update(1)
	print("fired A,B,R,P,Pc:", fired.A, fired.B, fired.R, fired.P, fired.Pc, "| expected: true nil nil nil nil |", C.stats(g))
end

C.section("stop() of a handle due later in the SAME update -> stale path, no fire, counters return to 0")
do
	local g = G()
	local firedB = false
	local B
	g.delay(function() B:stop() end, 1)
	B = g.delay(function() firedB = true end, 1)
	g.update(1)
	print("B fired:", firedB, "|", C.stats(g))
end

C.section("reset() of a recurring handle from inside its own callback: stale accounting")
do
	local g = G()
	local n = 0
	local h
	h = g.recur(function() n += 1; h:reset() end, 1)
	g.update(1)
	print("after update(1): fires =", n, "| h._due =", h._due, "|", C.stats(g), "(1 stale orphan expected)")
	g.update(1)
	print("after update(2): fires =", n, "| h._due =", h._due, "|", C.stats(g))
end

C.section("adjust() inside its own LAGGING recurring callback -> infinite loop in update (guarded at 50)")
do
	local g = G()
	local n = 0
	local h
	h = g.recur(function()
		n += 1
		if n >= 50 then h:stop() return end -- escape hatch; without it update(2.5) never returns
		h:adjust(1)                          -- same period; remaining = max(h._due - now, 0) = 0 -> re-armed at _base = due <= now
	end, 1)
	local t0 = os.clock()
	g.update(2.5)
	print(("fires in ONE update(2.5) with period 1: %d (correct: 2). took %.3f ms"):format(n, (os.clock() - t0) * 1000))
end

C.section("adjust() to a SMALLER period inside own callback, not lagging by a full period -> same loop")
do
	local g = G()
	local n = 0
	local h
	h = g.recur(function()
		n += 1
		if n >= 50 then h:stop() return end
		h:adjust(0.05)
	end, 1)
	g.update(1.9)
	print("fires in ONE update(1.9): ", n, "(correct: 1 or 2)")
end

C.section("pause()+resume() inside own lagging callback -> re-armed at due <= now -> same loop")
do
	local g = G()
	local n = 0
	local h
	h = g.recur(function()
		n += 1
		if n >= 50 then h:stop() return end
		h:pause(); h:resume()
	end, 1)
	g.update(2.5)
	print("fires in ONE update(2.5):", n, "(correct: 2)")
end

C.section("AfterNotTouched Touch()/reset() from inside a lagging callback fires the clock EARLY")
do
	local g = G()
	local antFired = false
	local ant = C.ANT.new(g, 0.5, function() antFired = true end)
	g.recur(function() ant:Touch() end, 1)
	g.update(3) -- recur due at 1 -> base = 1 -> touch re-arms ANT at 1 + 0.5 = 1.5 <= 3 -> fires this update
	print("ANT fired in the very update it was touched:", antFired, "| (expected: re-armed to now+0.5 = 3.5, not fired)")
end

C.section("reset() of an unrelated handle from inside a callback is measured from the FIRING due, not now")
do
	local g = G()
	local other = g.delay(function() end, 10)
	g.delay(function() other:reset() end, 1)
	g.update(1.4) -- firing due 1, now 1.4
	print("other._due after reset inside callback =", other._due, "(legacy reset: timer=delay -> now-relative = 11.4)")
end

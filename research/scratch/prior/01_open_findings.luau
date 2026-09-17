local C = require("./_common")
local G, TickAPI, Driver = C.G, C.TickAPI, C.Driver

C.section("(1) adjust() on a zero-period one-shot -> NaN due, fires immediately")
do
	local g = G()
	local fired = false
	local h = g.delay(function() fired = true end, 0)
	h:adjust(5)
	print("h._due =", h._due, "| getRemaining =", h:getRemaining(), "| period =", h.period)
	g.update(0.001)
	print("fired after 1 ms (correct behaviour: false, expect ~5s):", fired)
	local g2 = G()
	local h2 = g2.delay(function() end, math.huge)
	h2:adjust(5)
	print("delay(inf):adjust(5) -> _due =", h2._due)
end

C.section("(2) compact()/Heap.rebuild DOES run from inside update (comment at Group:54-55 is false)")
do
	local g = G()
	local victims = {}
	for i = 1, 100 do victims[i] = g.delay(function() end, 100) end
	local heapBefore, heapAfter, staleBefore, staleAfter
	g.delay(function()
		heapBefore, staleBefore = g:getStats().heapSize, g:getStats().stale
		for i = 1, 70 do victims[i]:stop() end -- stale climbs to 70 > max(64, live=31) -> rebuild
		heapAfter, staleAfter = g:getStats().heapSize, g:getStats().stale
	end, 1)
	g.update(1)
	print(("inside callback: heap %d->%d, stale %d->%d  (rebuild happened mid-update: %s)"):format(
		heapBefore, heapAfter, staleBefore, staleAfter, tostring(heapAfter < heapBefore)))
end

C.section("(3) TickAPI.new groups: _unbind is a dead store; RunService connection leaks; no Destroy")
do
	local rs = C.fakeRunService(true)
	Driver._inject(rs)
	local groups = {}
	for i = 1, 5 do groups[i] = TickAPI.new({ driver = "Heartbeat" }) end
	print("fake connections after 5 TickAPI.new:", rs._connections)
	print("type(group._unbind) =", type(groups[1]._unbind), "| group.Destroy =", groups[1].Destroy, "| group.unbind =", groups[1].unbind)
	groups = nil
	print("after dropping every reference, connections still:", rs._connections, "(leak; nothing ever calls _unbind)")
	Driver._inject(nil)
end

C.section("(4) iscallable duplicated: Handle:58-64 vs Variants:60-66 (static; cite only)")

C.section("(5) h:pause() on a Paused / Chained handle raises a raw 'illegal transition' error")
do
	local g = G()
	local h = g.delay(function() end, 5)
	h:pause()
	print("pause twice ->", pcall(function() h:pause() end))
	local p = g.delay(function() end, 5)
	local child = p:after(function() end, 1)
	print("pause Chained ->", pcall(function() child:pause() end))
	print("resume on Pending (RF-011 fixed) ->", pcall(function() g.delay(function() end, 1):resume() end), C.stats(g))
end

C.section("(7) Default driver 'Manual': TickAPI.new({}) under an injected Roblox never binds")
do
	local rs = C.fakeRunService(true)
	Driver._inject(rs)
	local g = TickAPI.new({ name = "Silent" })
	local fired = false
	g.delay(function() fired = true end, 0.1)
	for _ = 1, 100 do rs:fire("Heartbeat", 1 / 60) end
	print("driver =", g._variant.driver, "| fake connections =", rs._connections, "| fired after 100 heartbeats =", fired)
	Driver._inject(nil)
end

C.section("(8) capped catch-up re-arm resurrects a handle its own callback stopped -> stale negative")
do
	local g = G({ maxCatchUpPerFrame = 1 })
	local h
	h = g.recur(function() h:stop() end, 1)
	g.update(1)
	print("after update(1):", C.stats(g), "| h state =", h:getState(), "| h._inHeap =", h._inHeap, "| phantom gen match =", g._heap._gen[1] == h._gen)
	g.update(1) -- pops the phantom
	print("after update(2):", C.stats(g), "<- stale negative; compaction now needs one extra stale")
	-- pause inside own callback under cap: remaining recorded as 0 -> resume fires immediately
	local g2 = G({ maxCatchUpPerFrame = 1 })
	local fires = 0
	local h2
	h2 = g2.recur(function() fires += 1; h2:pause() end, 1)
	g2.update(1)
	print("cap=1 pause-in-callback: remaining =", h2:getRemaining(), "(expected 1)", C.stats(g2))
	h2:resume()
	g2.update(0.001)
	print("after resume + 1ms: fires =", fires, "(expected 1; 2 means immediate re-fire)", C.stats(g2))
	-- reset inside a capped callback is overridden by the post-loop re-arm (2 heap entries)
	local g3 = G({ maxCatchUpPerFrame = 1 })
	local h3
	h3 = g3.recur(function() h3:reset() end, 1)
	g3.update(1.5)
	print("cap=1 reset-in-callback at now=1.5: h3._due =", h3._due, C.stats(g3))
end

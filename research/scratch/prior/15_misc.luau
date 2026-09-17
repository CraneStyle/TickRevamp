local C = require("./_common")
local G = C.G
C.section("dot-call misuse on a handle: h.stop() / h.reset()")
do
	local g = G()
	local h = g.delay(function() end, 1)
	print("h.stop() ->", pcall(function() h.stop() end))
	print("h.reset() ->", pcall(function() h.reset() end))
	print("g.remove(nil) ->", pcall(function() g.remove(nil) end))
	print("g.remove(42) ->", pcall(function() g.remove(42) end))
	print("g.delay(fn) (nil delay) ->", pcall(function() g.delay(function() end) end))
	print("g.delay(fn,'5') ->", pcall(function() return g.delay(function() end, "5").period end))
	print("g.update('0.5') ->", pcall(function() g.update("0.5") end), g.now())
end
C.section("lazy deletion pins stopped handles (and their closures) in the heap until due or compaction")
do
	local g = G()
	local hs = {}
	for i = 1, 10000 do hs[i] = g.delay(function() end, 3600) end
	for i = 1, 5000 do hs[i]:stop() end
	print("after stopping 5000 of 10000 far-future handles:", C.stats(g), "<- 5000 dead entries retained (stale > max(64,live) is false at equality)")
	hs[5001]:stop()
	print("after one more stop:", C.stats(g))
end
C.section("Handle table gains an undeclared field (_inHeap) after arm; HandleImpl type omits it")
do
	local g = G()
	local h = g.delay(function() end, 1)
	local n = 0
	for _ in h do n += 1 end
	print("fields on a live handle:", n, "| _inHeap =", h._inHeap)
end
C.section("Group has no Destroy/teardown")
do
	local g = G()
	print("g.Destroy:", g.Destroy, "| g.destroy:", g.destroy, "| g.unbind:", g.unbind)
end
C.section("setPeriod on a Pending recur takes effect only at the next re-arm (documented)")
do
	local g = G()
	local fires = {}
	local h = g.recur(function() table.insert(fires, g.now()) end, 1)
	h:setPeriod(0.25)
	for _ = 1, 8 do g.update(0.25) end
	print("fires at:", table.concat(fires, ","))
end

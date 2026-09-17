local C = require("./_common")
local G = C.G
local function kb() return collectgarbage("count") end
C.section("per-update garbage on an IDLE group (fireCounts/capped tables)")
do
	local g = G()
	g.update(0.001)
	local samples = {}
	for s = 1, 5 do
		local before = kb()
		for _ = 1, 1000 do g.update(0.001) end
		samples[s] = math.floor((kb() - before) * 1024 / 1000)
	end
	table.sort(samples)
	print(("bytes/update idle: samples = %s (median %d; negatives = a GC step ran inside the sample)"):format(
		table.concat(samples, ", "), samples[3]))
end
C.section("per-update garbage on 3 idle groups x 60 Hz for 10 s")
do
	local gs = { G(), G(), G() }
	local before = kb()
	for _ = 1, 600 do for _, g in gs do g.update(1 / 60) end end
	local d = kb() - before
	print(("%.1f KB (%.0f bytes/frame for 3 groups)"):format(d, d * 1024 / 600))
end
C.section("per-handle allocation: delay() x 10000")
do
	local g = G()
	local fn = function() end
	local before = kb()
	for _ = 1, 10000 do g.delay(fn, 100) end
	print(("bytes/handle (Handle table + _chained {} + heap slots): ~%.0f"):format((kb() - before) * 1024 / 10000))
end
C.section("per-group allocation: Group.new x 1000 (10 bindDual closures each)")
do
	local before = kb()
	local keep = {}
	for i = 1, 1000 do keep[i] = G() end
	print(("bytes/group: ~%.0f"):format((kb() - before) * 1024 / 1000))
end
C.section("per-dispatch garbage: recur firing every update")
do
	local g = G()
	g.recur(function() end, 0.001)
	g.update(0.001)
	local before = kb()
	for _ = 1, 1000 do g.update(0.001) end
	print(("bytes/update with 1 dispatch: ~%.0f"):format((kb() - before) * 1024 / 1000))
end

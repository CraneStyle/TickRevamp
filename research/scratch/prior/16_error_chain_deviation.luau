local C = require("./_common")
local G = C.G
local Tick = require("../../../../TickAPIOptimize/reference/lune/Tick")

C.section("parent callback ERRORS: legacy never schedules the after() child; new Group arms it anyway")
do
	local grp = Tick.group()
	local lchild = false
	grp:delay(function() error("parent-failed") end, 1):after(function() lchild = true end, 1)
	local ok = pcall(function() grp:update(1) end)
	pcall(function() grp:update(1) end); pcall(function() grp:update(1) end)
	print("legacy: update raised =", not ok, "| child fired later =", lchild)
	local g = G()
	local nchild = false
	g.delay(function() error("parent-failed") end, 1):after(function() nchild = true end, 1)
	g.update(1); g.update(1)
	print("new (warn policy): child fired later =", nchild)
end

C.section("recur created inside a recur callback: first due is base+period (legacy: next-due+period)")
do
	local grp = Tick.group()
	local lfirst
	local lt = 0
	local armed = false
	grp:recur(function()
		if not armed then armed = true; grp:recur(function() if not lfirst then lfirst = lt end end, 0.5) end
	end, 1)
	for _ = 1, 200 do lt += 1 / 60; if not lfirst then grp:update(1 / 60) end end
	local g = G()
	local nfirst
	local nt = 0
	local narmed = false
	g.recur(function()
		if not narmed then narmed = true; g.recur(function() if not nfirst then nfirst = nt end end, 0.5) end
	end, 1)
	for _ = 1, 200 do nt += 1 / 60; if not nfirst then g.update(1 / 60) end end
	print(("legacy inner recur first fire t=%.3f | new t=%.3f"):format(lfirst or -1, nfirst or -1))
end

C.section("one-shot delay(0.5) created inside a ONE-SHOT callback: parity (both base = firing due)")
do
	local grp = Tick.group()
	local lf, lt = nil, 0
	grp:delay(function() grp:delay(function() lf = lt end, 0.5) end, 1)
	for _ = 1, 200 do lt += 1 / 60; if not lf then grp:update(1 / 60) end end
	local g = G()
	local nf, nt = nil, 0
	g.delay(function() g.delay(function() nf = nt end, 0.5) end, 1)
	for _ = 1, 200 do nt += 1 / 60; if not nf then g.update(1 / 60) end end
	print(("legacy t=%.3f | new t=%.3f"):format(lf or -1, nf or -1))
end

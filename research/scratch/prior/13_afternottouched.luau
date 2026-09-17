local C = require("./_common")
local G, ANT, TickAPI = C.G, C.ANT, C.TickAPI
C.section("fn error: Destroy still runs; error re-raised into the group's callback -> onError policy")
do
	local captured
	local g = G({ onError = function(msg) captured = msg end })
	local a = ANT.new(g, 1, function() error("ant-fn-failed") end)
	g.update(1)
	print("destroyed:", a.isDestroying, "| in Storage:", ANT.Storage[a.Id] ~= nil, "| Clock:", a.Clock)
	print("policy message (first 300 chars):", ((captured or ""):sub(1, 300):gsub("\n", " | ")))
end
C.section("group.clear() strands the AfterNotTouched object in Storage forever")
do
	local g = G()
	local before = ANT.count()
	local a = ANT.new(g, 1, function() end)
	g.clear()
	g.update(5)
	print("ANT.count delta after clear+update:", ANT.count() - before, "| isDestroying:", a.isDestroying, "| Clock state:", a.Clock and a.Clock:getState())
	a:Touch()
	print("Touch after clear: clock state", a.Clock and a.Clock:getState())
	a:Destroy()
end
C.section("GetAfterNotTouched + SafeStopClock live shapes")
do
	local a = TickAPI.GetAfterNotTouched(1, function() end, "Tickh")
	print("Id type:", type(a.Id), "| SafeStopClock(nil) ->", TickAPI.SafeStopClock(nil), "| SafeStopClock(h) ->", TickAPI.SafeStopClock(a.Clock))
	a:Destroy()
end

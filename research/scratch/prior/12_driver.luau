local C = require("./_common")
local TickAPI, Driver = C.TickAPI, C.Driver
C.section("Stepped forwards the SECOND argument as dt")
do
	local rs = C.fakeRunService(true)
	Driver._inject(rs)
	local g = TickAPI.new({ driver = "Stepped" })
	rs:fire("Stepped", 12345.678, 0.25)
	print("group now after Stepped(time=12345.678, dt=0.25):", g.now())
	Driver._inject(nil)
end
C.section("RenderStepped on the server errors from TickAPI.new; client is fine")
do
	Driver._inject(C.fakeRunService(true))
	print(pcall(function() TickAPI.new({ driver = "RenderStepped" }) end))
	Driver._inject(C.fakeRunService(false))
	print(pcall(function() return TickAPI.new({ driver = "RenderStepped" }).name end))
	Driver._inject(nil)
end
C.section("Tickr is nil under Lune / on the server -> GetAfterNotTouched('Tickr') errors")
do
	print("TickAPI.Tickr =", TickAPI.Tickr)
	print(pcall(function() TickAPI.GetAfterNotTouched(1, function() end, "Tickr") end))
end
C.section("_inject seam is module-global state: a forgotten _inject(nil) leaks into later binds")
do
	local rs = C.fakeRunService(true)
	Driver._inject(rs)
	print("isRoblox with fake:", Driver.isRoblox())
	TickAPI.new({ driver = "Heartbeat" })
	print("later bind connected to the stale fake:", rs._connections)
	Driver._inject(nil)
end
C.section("bind to a signal the RunService lacks (e.g. PreRender on an older engine)")
do
	local rs = C.fakeRunService(false)
	rs.PreRender = nil
	Driver._inject(rs)
	print(pcall(function() TickAPI.new({ driver = "PreRender" }) end))
	Driver._inject(nil)
end
C.section("unbind is idempotent; but nothing public calls it")
do
	local rs = C.fakeRunService(true)
	Driver._inject(rs)
	local g = TickAPI.new({ driver = "Heartbeat" })
	g._unbind(); g._unbind()
	print("connections after calling private _unbind twice:", rs._connections)
	Driver._inject(nil)
end

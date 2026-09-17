-- Shared helpers for the prior-build repro scripts. Required as "./_common".
-- Lune 0.10.5 accepts ONLY ./ ../ @ prefixes; the absolute path form is rejected.
local TickAPI = require("../../../../TickAPIOptimize/build/src/TickAPI")
local M = {}
M.TickAPI = TickAPI
M.Group, M.Variants, M.Handle, M.Heap, M.Driver, M.ANT =
	TickAPI.Group, TickAPI.Variants, TickAPI.Handle, TickAPI.Heap, TickAPI.Driver, TickAPI.AfterNotTouched
function M.G(opts)
	opts = opts or {}
	if opts.driver == nil then opts.driver = "Manual" end
	return M.Group.new(M.Variants.resolve(opts))
end
function M.stats(g)
	local s = g:getStats()
	return ("live=%d paused=%d stale=%d heap=%d now=%s ex=%d disp=%d"):format(
		s.live, g._paused, s.stale, s.heapSize, tostring(s.now), s.examined, s.dispatched)
end
function M.section(name) print(("\n### %s"):format(name)) end
-- Fake RunService for Driver tests. Tracks live connections.
function M.fakeRunService(isServer)
	local rs = { _connections = 0, _handlers = {} }
	function rs:IsServer() return isServer end
	function rs:IsClient() return not isServer end
	for _, sig in { "Heartbeat", "Stepped", "RenderStepped", "PreRender", "PreAnimation", "PreSimulation", "PostSimulation" } do
		rs[sig] = {
			Connect = function(_, fn)
				rs._connections += 1
				table.insert(rs._handlers, { sig = sig, fn = fn })
				return { Disconnect = function() rs._connections -= 1 end }
			end,
		}
	end
	function rs:fire(sig, ...)
		for _, h in rs._handlers do if h.sig == sig then h.fn(...) end end
	end
	return rs
end
return M

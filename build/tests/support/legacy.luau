--!nonstrict
--[[
	build/tests/support/legacy.luau — adapters over the legacy Lune shim (DESIGN §9, §12 WP2).

	`reference/lune/Tick.luau` is the live `Tick` core minus its unused RunService line; it is
	the parity oracle. The shim's module value is a `bound` table whose metatable is the `tick`
	group class, so `Tick.group()` builds a fresh group. Every helper below calls the shim's own
	colon methods, so a parity harness can drive the legacy group and a Veron with one step list:

		local g = Legacy.group()
		local h = Legacy.delay(g, fn, 0.5)
		Legacy.update(g, 1 / 64)

	Path note: `./` here is build/tests/support, so the workspace `reference/` folder is three
	levels up (`../../../reference`), not `../../reference` (which would be build/reference).
]]

local Tick = require("../../../reference/lune/Tick")

local Legacy = {}

-- The shim module itself (the `bound` table over the process-wide default group).
Legacy.Tick = Tick

--[[
	A fresh legacy group (its own `err` carry, its own array of events).
]]
function Legacy.group()
	return Tick.group()
end

function Legacy.delay(group, fn, delay)
	return group:delay(fn, delay)
end

function Legacy.recur(group, fn, period)
	return group:recur(fn, period)
end

function Legacy.update(group, dt)
	return group:update(dt)
end

function Legacy.getClocks(group)
	return group:getClocks()
end

function Legacy.stop(handle)
	return handle:stop()
end

function Legacy.reset(handle)
	return handle:reset()
end

function Legacy.adjust(handle, newTotal)
	return handle:adjust(newTotal)
end

function Legacy.after(handle, fn, delay)
	return handle:after(fn, delay)
end

return Legacy

--!nonstrict
--[[
	parity_spec — differential harness against the legacy core (docs/DESIGN.md
	§9 parity row, §7.3 DV table, §12 WP7).

	ONE step list (support/gen.luau schema) drives the legacy shim
	(`Legacy.group()` over reference/lune/Tick.luau) and a `Veron.new{}`; per
	update the SORTED list of fired ids is compared (same-update ORDER is a
	documented deviation, DV-1). The generator's `recur` step arms
	`Recur(fn, p, true)` (legacy is uncapped) for the main runs and the
	default (capped) `Recur(fn, p)` for the "default cap" run. Every number is
	dyadic (B-20). The 20 two-sided pins assert BOTH the legacy value and the
	new value for every DV row of §7.3.
]]

local fs = require("@lune/fs")

local Veron = require("../../../src/Veron")
local VeronEvent = require("../../../src/Veron/VeronEvent")
local Env = require("../../../src/Veron/Env")
local Legacy = require("../../support/legacy")
local Gen = require("../../support/gen")
local Oracle = require("../../support/oracle")

local SEED = 20260916
local SEQUENCES = 500
local STEPS = 200
local DT60 = 1 / 60
local DT64 = 1 / 64

--[[
	A fresh oracle-wrapped Veron; `Name` defaults to "T".
]]
local function _new(cfg)
	cfg = cfg or {}
	if cfg.Name == nil then
		cfg.Name = "T"
	end
	return Oracle.wrap(Veron.new(cfg))
end

--[[
	Runs `body(warnings)` with Env.Warn captured; restores the seam whatever
	happens and re-raises a failure unchanged.
]]
local function _withWarnings(body)
	local warnings = {}
	local restore = Env.SetWarn(function(message)
		warnings[#warnings + 1] = tostring(message)
	end)
	local ok, err = pcall(body, warnings)
	restore()
	if not ok then
		error(err, 0)
	end
	return warnings
end

--[[
	Steps `dt` up to `count` times, stopping early once `done()` is true;
	returns the number of frames stepped (false when never done).
]]
local function _frames(update, dt, count, done)
	for frame = 1, count do
		update(dt)
		if done() then
			return frame
		end
	end
	return false
end

local function _find(message, text)
	return string.find(tostring(message), text, 1, true) ~= nil
end

local function _falseKeys(group)
	local count = 0
	for _, value in pairs(group) do
		if value == false then
			count += 1
		end
	end
	return count
end

-------------------------------------------------------------------
-- Adapters: one identical surface over both schedulers
-------------------------------------------------------------------

local function _legacyAdapter()
	local group = Legacy.group()
	return {
		delay = function(fn, delay)
			return Legacy.delay(group, fn, delay)
		end,
		recur = function(fn, period)
			return Legacy.recur(group, fn, period)
		end,
		after = function(parent, fn, delay)
			return Legacy.after(parent, fn, delay)
		end,
		stop = function(h)
			Legacy.stop(h)
		end,
		reset = function(h)
			Legacy.reset(h)
		end,
		adjust = function(h, newTotal)
			Legacy.adjust(h, newTotal)
		end,
		update = function(dt)
			Legacy.update(group, dt)
		end,
	}
end

--[[
	`uncapped` is the third argument of `Recur`; every instance is
	oracle-wrapped so the invariant walk runs after every op of every
	sequence.
]]
local function _veronAdapter(uncapped, cfg)
	local s = _new(cfg)
	return {
		instance = s,
		delay = function(fn, delay)
			return s:Delay(fn, delay)
		end,
		recur = function(fn, period)
			return s:Recur(fn, period, uncapped)
		end,
		after = function(parent, fn, delay)
			return parent:After(fn, delay)
		end,
		stop = function(h)
			h:Stop()
		end,
		reset = function(h)
			h:Reset()
		end,
		adjust = function(h, newTotal)
			h:Adjust(newTotal)
		end,
		update = function(dt)
			s:Update(dt)
		end,
	}
end

--[[
	Interprets a gen.luau step list against an adapter. Returns one string
	per `update` step: the sorted ids fired during that update, joined by
	",", plus the number of steps skipped because their handle did not
	exist yet (a `nest` child whose parent has not fired; the generator's
	model never emits one on a raw sequence, a sanitized one can). A `nest`
	step registers a delay that is CREATED from inside its parent's
	callback, so the arm carries the sub-frame error on both sides.
]]
local function _run(adapter, steps)
	local handles, nests, fired = {}, {}, {}
	local skipped = 0
	local fireOf
	fireOf = function(id)
		return function()
			fired[#fired + 1] = id
			local pending = nests[id]
			if pending then
				nests[id] = nil
				for _, nest in pending do
					handles[nest.id] = adapter.delay(fireOf(nest.id), nest.delay)
				end
			end
		end
	end
	local perUpdate = {}
	for index, step in steps do
		local op = step.op
		if op == "delay" then
			handles[step.id] = adapter.delay(fireOf(step.id), step.delay)
		elseif op == "recur" then
			handles[step.id] = adapter.recur(fireOf(step.id), step.period)
		elseif op == "after" then
			local parent = handles[step.parent]
			if parent == nil then
				skipped += 1
			else
				handles[step.id] = adapter.after(parent, fireOf(step.id), step.delay)
			end
		elseif op == "nest" then
			local list = nests[step.parent]
			if not list then
				list = {}
				nests[step.parent] = list
			end
			list[#list + 1] = { id = step.id, delay = step.delay }
		elseif op == "stop" or op == "reset" or op == "adjust" then
			local h = handles[step.target]
			if h == nil then
				skipped += 1
			elseif op == "stop" then
				adapter.stop(h)
			elseif op == "reset" then
				adapter.reset(h)
			else
				adapter.adjust(h, step.newTotal)
			end
		elseif op == "update" then
			table.clear(fired)
			adapter.update(step.dt)
			local ids = table.clone(fired)
			table.sort(ids)
			perUpdate[#perUpdate + 1] = table.concat(ids, ",")
		else
			error(("step %d: unknown op %s"):format(index, tostring(op)))
		end
	end
	return perUpdate, skipped
end

--[[
	Drops every `adjust` that would shrink an UNARMED chained child (an
	`after` id) to a delay <= `maxDt`: the generator keeps chained delays
	above every dt at creation (DV-2) but its adjust step can halve them
	below it, and a chained child armed at or below its parent's overshoot
	is a documented deviation (legacy appends it unvisited → next update;
	Veron dispatches it later in the same update). Returns the new list
	and the number of steps dropped.
]]
local function _sanitize(steps, maxDt)
	local chained, armed = {}, {}
	local out, dropped = {}, 0
	for _, step in steps do
		if step.op == "after" then
			chained[step.id] = step.parent
		end
		local keep = true
		if step.op == "adjust" and chained[step.target] and not armed[step.target] then
			keep = step.newTotal > maxDt
		elseif step.op == "update" then
			for _, id in step.expect or {} do
				armed[id] = true                  -- a fired parent armed its children
				for child, parent in chained do
					if parent == id then
						armed[child] = true
					end
				end
			end
		end
		if keep then
			out[#out + 1] = step
		else
			dropped += 1
		end
	end
	return out, dropped
end

--[[
	Runs `steps` on both sides and asserts the per-update fire lists match;
	a mismatch names the update, both lists and the generator's own
	expectation so the divergence is localized.
]]
local function _assertParity(t, label, steps, uncapped, allowSkips)
	local legacy, legacySkips = _run(_legacyAdapter(), steps)
	local modern, modernSkips = _run(_veronAdapter(uncapped), steps)
	t.eq(#modern, #legacy, label .. ": update count")
	t.eq(modernSkips, legacySkips, label .. ": both sides skipped the same steps")
	if not allowSkips then
		t.eq(legacySkips, 0, label .. ": a raw sequence never targets an uncreated handle")
	end
	local updateIndex = 0
	for index, step in steps do
		if step.op == "update" then
			updateIndex += 1
			if modern[updateIndex] ~= legacy[updateIndex] then
				error(("%s: update %d (step %d, dt %s): legacy [%s] veron [%s] expect [%s]"):format(
					label, updateIndex, index, tostring(step.dt),
					legacy[updateIndex], modern[updateIndex],
					table.concat(step.expect or {}, ",")
				), 2)
			end
		end
	end
end

-------------------------------------------------------------------
-- Nine scripted scenarios (gen.luau schema), covering
-- delay / recur / after / stop / reset / adjust / nest
-------------------------------------------------------------------

local function _u(dt)
	return { op = "update", dt = dt }
end

local SCENARIOS = {
	{ "single delays, mixed dts", {
		{ op = "delay", id = 1, delay = 1 },
		{ op = "delay", id = 2, delay = 2 },
		{ op = "delay", id = 3, delay = 5 },
		_u(1), _u(3), _u(1), _u(1),
	} },
	{ "boundary: dt exactly equal to remaining", {
		{ op = "delay", id = 1, delay = 1 },
		{ op = "delay", id = 2, delay = 2 },
		_u(1), _u(1),
	} },
	{ "recurring with catch-up then stop", {
		{ op = "recur", id = 1, period = 1 },
		_u(3), _u(1),
		{ op = "stop", target = 1 },
		_u(5),
	} },
	{ "stop before due", {
		{ op = "delay", id = 1, delay = 2 },
		{ op = "delay", id = 2, delay = 2 },
		{ op = "stop", target = 1 },
		_u(3),
	} },
	{ "reset mid-life", {
		{ op = "delay", id = 1, delay = 4 },
		_u(2),
		{ op = "reset", target = 1 },
		_u(2), _u(2),
	} },
	{ "adjust mid-life (4 to 8) and on a recurring", {
		{ op = "delay", id = 1, delay = 4 },
		{ op = "recur", id = 2, period = 2 },
		_u(2),
		{ op = "adjust", target = 1, newTotal = 8 },
		{ op = "adjust", target = 2, newTotal = 1 },
		_u(3), _u(1),
	} },
	{ "after chains of length 3 with a stopped sibling", {
		{ op = "delay", id = 1, delay = 1 },
		{ op = "after", id = 2, parent = 1, delay = 1 },
		{ op = "after", id = 3, parent = 2, delay = 1 },
		{ op = "after", id = 4, parent = 1, delay = 2 },
		_u(1), _u(1), _u(1), _u(1),
	} },
	{ "nested creation carrying the sub-frame error", {
		{ op = "delay", id = 1, delay = 2 },
		{ op = "nest", id = 2, parent = 1, delay = 3 },
		{ op = "nest", id = 3, parent = 1, delay = 3 / 2 },
		_u(3), _u(1 / 2), _u(1 / 2), _u(1),
	} },
	{ "survivors: reset, adjust and stop under one long update", {
		{ op = "delay", id = 1, delay = 10 },
		{ op = "delay", id = 2, delay = 4 },
		{ op = "reset", target = 2 },
		{ op = "recur", id = 3, period = 3 },
		{ op = "delay", id = 4, delay = 1 / 2 },
		{ op = "adjust", target = 4, newTotal = 1 },
		_u(2), _u(2),
		{ op = "stop", target = 3 },
		_u(1 / 2), _u(6),
	} },
}

-------------------------------------------------------------------
-- DV-7 shared driver: nested delay inside a recurring callback
-------------------------------------------------------------------

--[[
	Arms recur(1) whose first fire creates delay(1/2); returns the frame the
	nested delay fired on. `arm(fn, t, isRecur)` and `update(dt)` abstract
	the scheduler.
]]
local function _dv7(arm, update, dt, limit)
	local firedAt = false
	local frames = 0
	local first = true
	arm(function()
		if first then
			first = false
			arm(function()
				firedAt = frames
			end, 1 / 2, false)
		end
	end, 1, true)
	for _ = 1, limit do
		frames += 1
		update(dt)
		if firedAt then
			break
		end
	end
	return firedAt
end

local function _dv7Legacy(dt)
	local group = Legacy.group()
	return _dv7(function(fn, period, isRecur)
		if isRecur then
			Legacy.recur(group, fn, period)
		else
			Legacy.delay(group, fn, period)
		end
	end, function(step)
		Legacy.update(group, step)
	end, dt, 400)
end

local function _dv7Veron(dt, cfg)
	local s = _new(cfg)
	return _dv7(function(fn, period, isRecur)
		if isRecur then
			s:Recur(fn, period)
		else
			s:Delay(fn, period)
		end
	end, function(step)
		s:Update(step)
	end, dt, 400)
end

return function(t)
	-----------------------------------------------------------------
	-- Differential runs
	-----------------------------------------------------------------

	t.test("500 seeded op sequences match", function()
		for index = 0, SEQUENCES - 1 do
			local seed = SEED + index
			local steps = Gen.new(seed):sequence(STEPS)
			_assertParity(t, "seed " .. seed, steps, true)
		end
	end)

	t.test("9 scripted prior scenarios match", function()
		t.eq(#SCENARIOS, 9, "scenario count")
		for _, scenario in SCENARIOS do
			_assertParity(t, scenario[1], scenario[2], true)
		end
	end)

	t.test("default cap generator (never lags > 8 periods) matches", function()
		-- wider dts so a recurring can owe several fires per update, bounded
		-- by the generator to the default MaxCatchUp (8); Recur(fn, p) capped
		local constraints = { dts = { 1 / 64, 1 / 32, 1 / 8, 1 / 4 }, lagLimit = 8 }
		local lagging, dropped = 0, 0
		for index = 0, SEQUENCES - 1 do
			local seed = SEED + index
			local steps, skipped = _sanitize(Gen.new(seed):sequence(STEPS, constraints), 1 / 4)
			dropped += skipped
			for _, step in steps do
				if step.op == "update" and step.expect and #step.expect >= 2 then
					local last = false
					for _, id in step.expect do
						if id == last then
							lagging += 1
							break
						end
						last = id
					end
				end
			end
			_assertParity(t, "capped seed " .. seed, steps, false, true)
		end
		t.eq(lagging > 0, true, "some update owed a recurring more than one fire")
		t.eq(dropped < SEQUENCES, true, "sanitizer dropped fewer than one step per sequence")
	end)

	t.test("reference file is the live file minus the RunService line", function()
		local lune = fs.readFile("reference/lune/Tick.luau")
		local live = fs.readFile("reference/live/Tick.luau")
		local liveLines = string.split(live, "\n")
		local kept = {}
		local removed = 0
		for _, line in liveLines do
			if _find(line, "RunService") then
				removed += 1
			else
				kept[#kept + 1] = line
			end
		end
		t.eq(removed, 1, "exactly one RunService line in the live file")
		t.eq(table.concat(kept, "\n"), lune, "live minus that line is the reference file")
		t.eq(_find(lune, "RunService"), false, "the reference file never names RunService")
		t.eq(_find(lune, "game:"), false, "the reference file never touches game")
	end)

	-----------------------------------------------------------------
	-- Two-sided DV pins (§7.3): legacy value AND new value
	-----------------------------------------------------------------

	t.test("DV-1: same-due order legacy newest-first and scrambled by removals, new (due, Id) FIFO", function()
		-- legacy: 5 equal dues fire 5,4,3,2,1; after stopping #1,#2 of 6 → 4,3,5,6
		local group = Legacy.group()
		local order = {}
		for index = 1, 5 do
			Legacy.delay(group, function()
				order[#order + 1] = index
			end, 1)
		end
		Legacy.update(group, 1)
		t.eq(table.concat(order, ","), "5,4,3,2,1", "legacy newest-first")
		local group2 = Legacy.group()
		order = {}
		local handles = {}
		for index = 1, 6 do
			handles[index] = Legacy.delay(group2, function()
				order[#order + 1] = index
			end, 1)
		end
		Legacy.stop(handles[1])
		Legacy.stop(handles[2])
		Legacy.update(group2, 1)
		t.eq(table.concat(order, ","), "4,3,5,6", "legacy scrambled by swap-on-remove")
		-- legacy: two after() children fire newest-first
		local group3 = Legacy.group()
		order = {}
		local parent = Legacy.delay(group3, function() end, 1)
		Legacy.after(parent, function()
			order[#order + 1] = "a"
		end, 1)
		Legacy.after(parent, function()
			order[#order + 1] = "b"
		end, 1)
		Legacy.update(group3, 1)
		Legacy.update(group3, 1)
		t.eq(table.concat(order, ","), "b,a", "legacy children newest-first")

		-- new: creation order, unaffected by removals; children in registration order
		local s = _new()
		order = {}
		for index = 1, 5 do
			s:Delay(function()
				order[#order + 1] = index
			end, 1)
		end
		s:Update(1)
		t.eq(table.concat(order, ","), "1,2,3,4,5", "new FIFO")
		local s2 = _new()
		order = {}
		handles = {}
		for index = 1, 6 do
			handles[index] = s2:Delay(function()
				order[#order + 1] = index
			end, 1)
		end
		handles[1]:Stop()
		handles[2]:Stop()
		s2:Update(1)
		t.eq(table.concat(order, ","), "3,4,5,6", "new order survives removals")
		local s3 = _new()
		order = {}
		local p = s3:Delay(function() end, 1)
		p:After(function()
			order[#order + 1] = "a"
		end, 1)
		p:After(function()
			order[#order + 1] = "b"
		end, 1)
		s3:Update(1)
		s3:Update(1)
		t.eq(table.concat(order, ","), "a,b", "new children in registration order")
	end)

	t.test("DV-2: nested past-due legacy fires synchronously with a noop dummy, new later in the same update", function()
		-- legacy: parent delay(1/2) under update(1) → residual -1/2; a nested
		-- delay(1/8) fires BEFORE delay() returns and the handle is a dummy
		local group = Legacy.group()
		local order = {}
		local nestedFn = function()
			order[#order + 1] = "nested"
		end
		local dummy
		Legacy.delay(group, function()
			order[#order + 1] = "parent"
			dummy = Legacy.delay(group, nestedFn, 1 / 8)
			order[#order + 1] = "after-create"
		end, 1 / 2)
		Legacy.update(group, 1)
		t.eq(table.concat(order, ">"), "parent>nested>after-create", "legacy synchronous")
		t.eq(dummy.fn ~= nestedFn, true, "legacy returns a noop dummy")
		t.eq(Legacy.getClocks(group), 1, "legacy dummy stays in the array")

		-- new: fires after the creator returns, still in the same update; real handle
		local s = _new()
		order = {}
		local h, stateInside
		s:Delay(function()
			order[#order + 1] = "parent"
			h = s:Delay(function()
				order[#order + 1] = "nested"
			end, 1 / 8)
			stateInside = h:GetState()
			order[#order + 1] = "after-create"
		end, 1 / 2)
		s:Update(1)
		t.eq(table.concat(order, ">"), "parent>after-create>nested", "new same update, after the creator")
		t.eq(stateInside, "Pending", "new handle is real inside the callback")
		t.eq(h:GetState(), "Fired")
		t.eq(h:IsActive(), false)
		t.eq(s:GetClocks(), 0, "nothing lingers")
	end)

	t.test("DV-3: legacy TickAPI.Tick:remove(h) colon is a silent no-op, new removes", function()
		-- legacy: the bound module's colon form passes the bound table as `e`
		local Tick = Legacy.Tick
		local fired = false
		local h = Tick.delay(function()
			fired = true
		end, 1)
		Tick:remove(h)
		Tick.update(1)
		t.eq(fired, true, "legacy: the handle still fires after the colon remove")

		-- new: the dual closure shifts self, so the colon form removes
		local s = _new()
		fired = false
		local h2 = s.delay(function()
			fired = true
		end, 1)
		t.eq(s:remove(h2), true, "new colon remove returns true")
		s.update(1)
		t.eq(fired, false, "new: the handle never fires")
		t.eq(h2:GetState(), "Stopped")
	end)

	t.test("DV-4: legacy accepts NaN/inf delay, recur 0 and bad adjust, new rejects them at creation / adjust", function()
		-- legacy: NaN delay is a zombie visited every frame
		local group = Legacy.group()
		local fired = false
		Legacy.delay(group, function()
			fired = true
		end, 0 / 0)
		for _ = 1, 100 do
			Legacy.update(group, 1)
		end
		t.eq(fired, false, "legacy NaN never fires")
		t.eq(Legacy.getClocks(group), 1, "legacy NaN zombie stays")
		-- legacy: recur 0 hangs the next update (bounded by an injected error)
		local group2 = Legacy.group()
		local spins = 0
		Legacy.recur(group2, function()
			spins += 1
			if spins >= 1000 then
				error("would loop forever")
			end
		end, 0)
		local ok = pcall(Legacy.update, group2, DT64)
		t.eq(ok, false, "legacy recur 0 only stops through the injected error")
		t.eq(spins, 1000)
		-- legacy: adjust(-1) poisons, adjust(NaN) poisons
		local group3 = Legacy.group()
		local a = Legacy.delay(group3, function() end, 1)
		Legacy.adjust(a, -1)
		t.eq(a.timer, -1, "legacy adjust(-1) negative timer")
		t.eq(a.delay, -1)
		local b = Legacy.delay(group3, function() end, 1)
		Legacy.adjust(b, 0 / 0)
		t.eq(b.timer ~= b.timer, true, "legacy adjust(NaN) NaN timer")

		-- new: rejected before any mutation
		local s = _new()
		local fn = function() end
		t.throws(function()
			s:Delay(fn, 0 / 0)
		end, "expected `delay` to be a finite number")
		t.throws(function()
			s:Delay(fn, math.huge)
		end, "expected `delay` to be a finite number")
		t.throws(function()
			s:Recur(fn, 0)
		end, "expected recur `delay` greater than zero")
		local h = s:Delay(fn, 1)
		t.throws(function()
			h:Adjust(-1)
		end, "expected `newTotal` greater than zero")
		t.throws(function()
			h:Adjust(0 / 0)
		end, "expected `newTotal` greater than zero")
		t.throws(function()
			h:Adjust(0)
		end, "expected `newTotal` greater than zero")
		t.eq(h:GetRemaining(), 1, "new: a failed adjust leaves the handle alone")
		t.eq(s:GetClocks(), 1, "new: only the good handle exists")
		t.eq(s:Validate(), true)
	end)

	t.test("DV-5: legacy stop-after-fire leaks and dead-handle adjust mutates, new terminal handles are no-ops", function()
		-- legacy
		local group = Legacy.group()
		local h = Legacy.delay(group, function() end, 1 / 2)
		Legacy.update(group, 1)
		Legacy.stop(h)
		t.eq(_falseKeys(group), 1, "legacy: one false key per stop-after-fire")
		Legacy.stop(h)
		t.eq(_falseKeys(group), 1, "legacy: the key is a single leaked slot")
		Legacy.adjust(h, 4)
		t.eq(h.delay, 4, "legacy: adjust on a dead handle mutates it")
		Legacy.reset(h)
		t.eq(h.timer, 4, "legacy: reset on a dead handle mutates it")

		-- new
		local s = _new()
		local fires = 0
		local h2 = s:Delay(function()
			fires += 1
		end, 1 / 2)
		s:Update(1)
		t.eq(h2:GetState(), "Fired")
		t.eq(h2:Adjust(4), h2, "new: adjust after fire returns h")
		t.eq(h2:GetPeriod(), 1 / 2, "new: adjust after fire is a no-op")
		t.eq(h2:Reset(), h2)
		t.eq(h2:GetRemaining(), 0)
		t.eq(h2:GetState(), "Fired")
		-- Restart is the one explicit re-arm of a Fired handle
		h2:Restart()
		t.eq(h2:GetState(), "Pending")
		s:Update(1 / 2)
		t.eq(fires, 2, "new: Restart ran the same callback again")
		-- an explicit Stop on a Fired handle finalizes it (SafeStopClock path)
		t.eq(s:Stop(h2), false, "instance Stop on Fired returns false")
		t.eq(h2:GetState(), "Stopped")
		t.eq(rawget(h2, "_Fn"), Oracle.noop(), "closure released")
		h2:Restart()
		t.eq(h2:GetState(), "Stopped", "Stopped is final")
		h2:stop()
		t.eq(h2:GetState(), "Stopped", "double stop is silent")
		t.eq(s:GetClocks(), 0)
		t.eq(s:Validate(), true)
	end)

	t.test("DV-6: legacy parent callback throw kills its after chain, new children still arm", function()
		-- legacy
		local group = Legacy.group()
		local childFired = false
		local parent = Legacy.delay(group, function()
			error("parent-failed")
		end, 1)
		Legacy.after(parent, function()
			childFired = true
		end, 1)
		local ok = pcall(Legacy.update, group, 1)
		t.eq(ok, false, "legacy: the throw escapes update")
		pcall(Legacy.update, group, 1)
		pcall(Legacy.update, group, 1)
		t.eq(childFired, false, "legacy: the child never runs")
		t.eq(Legacy.getClocks(group), 0)

		-- new
		local s = _new()
		childFired = false
		local warnings = _withWarnings(function()
			local p = s:Delay(function()
				error("parent-failed")
			end, 1)
			p:After(function()
				childFired = true
			end, 1)
			s:Update(1)
			s:Update(1)
		end)
		t.eq(childFired, true, "new: the child fires")
		t.eq(#warnings, 1, "new: the parent error is warned once")
		t.eq(_find(warnings[1], "parent-failed"), true)
		t.eq(s:GetStats().Errors, 1)
	end)

	t.test("DV-7: legacy 2.500, new 1.517, LegacyRecurBase equals legacy", function()
		-- at 1/60: the design's numbers (a nested delay(0.5) armed by the
		-- first fire of recur(1) fires a full parent period earlier)
		local legacyFrame = _dv7Legacy(DT60)
		local newFrame = _dv7Veron(DT60)
		local flagFrame = _dv7Veron(DT60, { LegacyRecurBase = true })
		t.eq(legacyFrame, 150, "legacy frame at 1/60")
		t.near(legacyFrame * DT60, 2.5, 1e-9, "legacy 2.500")
		t.eq(newFrame, 91, "new frame at 1/60")
		t.near(newFrame * DT60, 1.517, 1e-3, "new 1.517")
		t.eq(newFrame < legacyFrame - 55, true, "about one parent period earlier")
		t.eq(math.abs(flagFrame - legacyFrame) <= 1, true,
			"LegacyRecurBase equals legacy within the one-frame float class (DV-11)")

		-- dyadic clock: the same three numbers, exact
		t.eq(_dv7Legacy(DT64) * DT64, 2.5, "legacy 2.5 exactly at 1/64")
		t.eq(_dv7Veron(DT64) * DT64, 1.5, "new 1.5 exactly at 1/64")
		t.eq(_dv7Veron(DT64, { LegacyRecurBase = true }) * DT64, 2.5, "LegacyRecurBase == legacy exactly")
	end)

	t.test("DV-8: legacy self-stop inside a lagging recurring fires the backlog, new exactly one fire", function()
		-- legacy: period 1/8, update(7/16) owes 3
		local group = Legacy.group()
		local fires = 0
		local h
		h = Legacy.recur(group, function()
			fires += 1
			Legacy.stop(h)
		end, 1 / 8)
		Legacy.update(group, 7 / 16)
		t.eq(fires, 3, "legacy fires the backlog")
		t.eq(_falseKeys(group), 1, "legacy leaks a false key for the extra stops")

		-- new
		local s = _new()
		fires = 0
		local h2
		h2 = s:Recur(function()
			fires += 1
			h2:Stop()
		end, 1 / 8, true)
		s:Update(7 / 16)
		t.eq(fires, 1, "new: exactly one fire")
		t.eq(h2:GetState(), "Stopped")
		t.eq(s:GetClocks(), 0)
		s:Update(1)
		t.eq(fires, 1)
	end)

	t.test("DV-9: legacy co-due sibling stop double-ticks a processed entry, new never", function()
		-- legacy L-02 B: A = delay(10); E = recur(1) whose first fire stops A
		local group = Legacy.group()
		local a = Legacy.delay(group, function() end, 10)
		local fires = 0
		local e
		e = Legacy.recur(group, function()
			fires += 1
			if fires == 1 then
				Legacy.stop(a)
			end
		end, 1)
		Legacy.update(group, 1)
		t.eq(fires, 2, "legacy: E fires twice in one update (swapped into A's slot)")
		t.eq(e.timer, 1, "legacy: re-armed after the double fire, one full period early")

		-- new
		local s = _new()
		local a2 = s:Delay(function() end, 10)
		fires = 0
		local e2
		e2 = s:Recur(function()
			fires += 1
			if fires == 1 then
				a2:Stop()
			end
		end, 1, true)
		s:Update(1)
		t.eq(fires, 1, "new: one fire")
		t.eq(e2:GetRemaining(), 1, "new: E keyed one full period ahead")
		s:Update(1 / 64)
		t.eq(fires, 1, "new: nothing early")
	end)

	t.test("DV-10: legacy unbounded catch-up burst, new 8 per handle per update, remainder dropped on-grid", function()
		-- period 1/128, one 4 s hitch: 512 owed
		local group = Legacy.group()
		local fires = 0
		Legacy.recur(group, function()
			fires += 1
		end, 1 / 128)
		Legacy.update(group, 4)
		t.eq(fires, 512, "legacy: every owed fire in one update")

		local s = _new()
		fires = 0
		s:Recur(function()
			fires += 1
		end, 1 / 128)
		s:Update(4)
		t.eq(fires, 8, "new: capped at MaxCatchUp")
		t.eq(s:GetStats().Dropped, 504, "new: the remainder is dropped")
		s:Update(1 / 128)
		t.eq(fires, 9, "new: phase kept on the grid")
		-- Recur(fn, p, true) restores the legacy burst (valve-bounded)
		local s2 = _new()
		fires = 0
		s2:Recur(function()
			fires += 1
		end, 1 / 128, true)
		s2:Update(4)
		t.eq(fires, 512, "new uncapped: nothing lost")
		t.eq(s2:GetStats().ValveHits, 0)
		-- a render instance built with MaxCatchUp = 1
		local s3 = _new({ MaxCatchUp = 1 })
		fires = 0
		s3:Recur(function()
			fires += 1
		end, 1 / 128)
		s3:Update(4)
		t.eq(fires, 1, "new MaxCatchUp = 1: one fire per update")
	end)

	t.test("DV-11: legacy delay(3*dt) fires on the 4th frame, new on the 3rd; both fire 10*0.1 one update late", function()
		local group = Legacy.group()
		local fired = false
		Legacy.delay(group, function()
			fired = true
		end, 3 * DT60)
		local legacyFrame = _frames(function(dt)
			Legacy.update(group, dt)
		end, DT60, 10, function()
			return fired
		end)
		t.eq(legacyFrame, 4, "legacy: three subtractions leave ~1e-17")

		local s = _new()
		fired = false
		s:Delay(function()
			fired = true
		end, 3 * DT60)
		local newFrame = _frames(function(dt)
			s:Update(dt)
		end, DT60, 10, function()
			return fired
		end)
		t.eq(newFrame, 3, "new: three additions reach 3 * dt")

		-- the same class of one-frame lateness on both axes, no epsilon
		local group2 = Legacy.group()
		fired = false
		Legacy.delay(group2, function()
			fired = true
		end, 10 * 0.1)
		t.eq(_frames(function(dt)
			Legacy.update(group2, dt)
		end, 0.1, 20, function()
			return fired
		end), 11, "legacy 10 x 0.1: one late")
		local s2 = _new()
		fired = false
		s2:Delay(function()
			fired = true
		end, 10 * 0.1)
		t.eq(_frames(function(dt)
			s2:Update(dt)
		end, 0.1, 20, function()
			return fired
		end), 11, "new 10 x 0.1: one late, documented")
	end)

	t.test("DV-12: legacy getClocks() is always 0 on the module (dot form errors), new counts Pending + Paused", function()
		local Tick = Legacy.Tick
		local h = Tick.delay(function() end, 1000)
		t.eq(Tick:getClocks(), 0, "legacy colon form: the bound table has no events")
		local ok, err = pcall(function()
			return Tick.getClocks()
		end)
		t.eq(ok, false, "legacy dot form raises")
		t.eq(_find(err, "attempt to get length of a nil value"), true)
		Tick.remove(h)

		local s = _new()
		local a = s:Delay(function() end, 1)
		local b = s:Recur(function() end, 1)
		b:Pause()
		local c = s:Delay(function() end, 1)
		c:After(function() end, 1)
		t.eq(s.getClocks(), 3, "new dot form")
		t.eq(s:getClocks(), 3, "new colon form")
		t.eq(s:GetClocks(), 3)
		a:Stop()
		t.eq(s:GetClocks(), 2, "Chained not counted, Paused counted")
	end)

	t.test("DV-13: legacy after() on a terminal parent never fires, new Fired arms now and Stopped is Stopped", function()
		-- legacy
		local group = Legacy.group()
		local parent = Legacy.delay(group, function() end, 1 / 2)
		Legacy.update(group, 1)
		local ran = false
		local child = Legacy.after(parent, function()
			ran = true
		end, 1 / 8)
		for _ = 1, 64 do
			Legacy.update(group, DT64)
		end
		t.eq(ran, false, "legacy: never runs")
		t.eq(child.timer, 1 / 8, "legacy: the child looks armed")
		t.eq(Legacy.getClocks(group), 0)

		-- new
		local s = _new()
		local p = s:Delay(function() end, 1 / 2)
		s:Update(1)
		ran = false
		local c = p:After(function()
			ran = true
		end, 1 / 8)
		t.eq(c ~= p, true, "never the parent")
		t.eq(c:GetState(), "Pending", "new: armed from the caller's clock")
		t.eq(c:GetRemaining(), 1 / 8)
		s:Update(1 / 8)
		t.eq(ran, true, "new: fires")
		local stopped = s:Delay(function() end, 1)
		stopped:Stop()
		local born = stopped:After(function()
			ran = "never"
		end, 1 / 8)
		t.eq(born:GetState(), "Stopped", "new: born-Stopped child")
		t.eq(born ~= stopped, true)
		s:Update(1)
		t.eq(ran, true, "the Stopped child never fires")
	end)

	t.test("DV-14: legacy and new both advance 2 s on a 2 s dt, MaxDt = 0.25 advances 0.25", function()
		local group = Legacy.group()
		local fires = 0
		Legacy.delay(group, function()
			fires += 1
		end, 2)
		Legacy.recur(group, function()
			fires += 1
		end, 1)
		Legacy.update(group, 2)
		t.eq(fires, 3, "legacy: a 2 s hitch is 2 s of timer time")

		local s = _new()
		fires = 0
		s:Delay(function()
			fires += 1
		end, 2)
		s:Recur(function()
			fires += 1
		end, 1, true)
		s:Update(2)
		t.eq(fires, 3, "new default: unchanged (MaxDt off)")
		t.eq(s:Now(), 2)
		t.eq(s:GetStats().ClampedDt, 0)

		local clamped = _new({ MaxDt = 0.25 })
		fires = 0
		clamped:Delay(function()
			fires += 1
		end, 2)
		clamped:Update(2)
		t.eq(fires, 0, "new MaxDt: the hitch is clamped")
		t.eq(clamped:Now(), 0.25)
		t.eq(clamped:GetStats().ClampedDt, 1)
		t.eq(clamped:GetStats().LastDt, 0.25)
	end)

	t.test("DV-15: legacy throwing callback aborts the frame and poisons err, new isolates it under OnError", function()
		-- legacy: A (index 1) never gets this frame's dt; err stays poisoned
		local group = Legacy.group()
		local a = Legacy.delay(group, function() end, 10)
		local siblingFired = false
		Legacy.delay(group, function()
			siblingFired = true
		end, 1)
		Legacy.delay(group, function()
			error("boom")
		end, 1 / 2)
		local ok = pcall(Legacy.update, group, 1)
		t.eq(ok, false, "legacy: the error escapes update")
		t.eq(a.timer, 10, "legacy: A skipped this frame's dt")
		t.eq(siblingFired, false, "legacy: the due sibling never ran")
		t.eq(group.err, -1 / 2, "legacy: err poisoned")
		local late = Legacy.delay(group, function() end, 1)
		t.eq(late.timer, 1 / 2, "legacy: the next top-level delay is early by the poison")

		-- new
		local s = _new()
		local a2 = s:Delay(function() end, 10)
		siblingFired = false
		local received
		s:SetOnError(function(message, h)
			received = { message = message, handle = h }
		end)
		s:Delay(function()
			siblingFired = true
		end, 1)
		local thrower = s:Delay(function()
			error("boom")
		end, 1 / 2)
		s:Update(1)
		t.eq(a2:GetRemaining(), 9, "new: A charged exactly once")
		t.eq(siblingFired, true, "new: the sibling still fires")
		t.eq(_find(received.message, "boom"), true, "new: OnError received the message")
		t.eq(received.handle, thrower, "new: OnError received the handle")
		t.eq(s:GetStats().Errors, 1)
		t.eq(s:GetBase(), false, "new: no carry leaks")
		local late2 = s:Delay(function() end, 1)
		t.eq(late2:GetRemaining(), 1, "new: the next top-level delay measures from now")
	end)

	t.test("DV-17: legacy remove(number) removes by array index or raises, new returns false", function()
		local group = Legacy.group()
		local ok, err = pcall(function()
			return group:remove(7)
		end)
		t.eq(ok, false, "legacy: bad index raises")
		t.eq(_find(err, "table index is nil"), true)
		local h1 = Legacy.delay(group, function() end, 1)
		Legacy.delay(group, function() end, 1)
		t.eq(group:remove(1), h1, "legacy: remove(1) pops the first array slot")
		t.eq(Legacy.getClocks(group), 1)

		local s = _new()
		s:Delay(function() end, 1)
		s:Delay(function() end, 1)
		t.eq(s.remove(7), false, "new: false")
		t.eq(s.remove(1), false)
		t.eq(s:Stop(1), false)
		t.eq(s:GetClocks(), 2, "new: nothing removed")
		s:SetStrict(true)
		t.throws(function()
			s:Stop(1)
		end, "expected a VeronEvent, got number")
	end)

	t.test("DV-20: legacy raw internal errors, new prefixed errors and byte-identical validation strings", function()
		local group = Legacy.group()
		local h = Legacy.delay(group, function() end, 1)
		local ok, err = pcall(function()
			h.stop()
		end)
		t.eq(ok, false)
		t.eq(_find(err, "attempt to index nil with 'parent'"), true, "legacy dot-call is a raw index error")
		ok, err = pcall(function()
			Legacy.delay(group, function() end, -1)
		end)
		t.eq(_find(err, "expected `delay` of zero or greater"), true, "legacy validation string")

		local s = _new()
		local h2 = s:Delay(function() end, 1)
		ok, err = pcall(function()
			h2.stop()
		end)
		t.eq(ok, false)
		t.eq(_find(err, "VeronEvent: methods take a colon: event:Stop(), not event.Stop()"), true, "new dot-call message")
		ok, err = pcall(function()
			s:Update(nil)
		end)
		t.eq(_find(err, "Veron 'T': Update(dt) expects a finite number >= 0, got nil"), true, "new prefixed error")
		ok, err = pcall(function()
			s:Delay(function() end, -1)
		end)
		t.eq(_find(err, "expected `delay` of zero or greater"), true, "new keeps the legacy validation string")
		t.eq(_find(err, "Veron"), false, "validation family stays unprefixed")
	end)

	t.test("DV-21: legacy re-entrant update runs unguarded on the same array, new nested pass is counted", function()
		-- legacy (L-16): the nested update clobbers err for the rest of the callback
		local group = Legacy.group()
		local errAfter, nestedTimer
		Legacy.delay(group, function()
			Legacy.update(group, 1)
			errAfter = group.err
			nestedTimer = Legacy.delay(group, function() end, 1 / 2).timer
		end, 1 / 2)
		Legacy.update(group, 1)
		t.eq(errAfter, 0, "legacy: err clobbered to 0 by the nested update")
		t.eq(nestedTimer, 1 / 2, "legacy: the residual is lost")

		-- new
		local s = _new()
		local baseAfter, nestedFired = nil, false
		local warnings = _withWarnings(function()
			s:Delay(function()
				s:Update(1)
				baseAfter = s:GetBase()
				s:Delay(function()
					nestedFired = true
				end, 1 / 2)
			end, 1 / 2)
			s:Update(1)
		end)
		t.eq(baseAfter, 1 / 2, "new: the base survives the nested pass")
		t.eq(nestedFired, true, "new: due 1.0 <= now 2, dispatched by the outer pass")
		t.eq(s:Now(), 2)
		t.eq(s:GetStats().Reentries, 1)
		t.eq(s:GetStats().UpdateDepth, 0)
		t.eq(#warnings, 1, "warned once")
		t.eq(_find(warnings[1], "re-entered"), true)
	end)

	t.test("DV-23: legacy bad dt grows/poisons/coerces timers, new raises the prefixed error before any state", function()
		local group = Legacy.group()
		local e = Legacy.delay(group, function() end, 1)
		Legacy.update(group, -1)
		t.eq(e.timer, 2, "legacy: negative dt grows the timer")
		Legacy.update(group, "0.5")
		t.eq(e.timer, 1.5, "legacy: a numeric string is coerced")
		local ok, err = pcall(Legacy.update, group, nil)
		t.eq(ok, false, "legacy: nil raises mid-loop")
		t.eq(_find(err, "arithmetic"), true)
		Legacy.update(group, 0 / 0)
		t.eq(e.timer ~= e.timer, true, "legacy: NaN poisons the timer")

		local s = _new()
		local h = s:Delay(function() end, 1)
		for _, bad in { -1, "0.5", 0 / 0, math.huge, -math.huge } do
			local okNew, errNew = pcall(function()
				s:Update(bad)
			end)
			t.eq(okNew, false, "new rejects " .. tostring(bad))
			t.eq(_find(errNew, "Veron 'T': Update(dt) expects a finite number >= 0, got "), true)
		end
		t.throws(function()
			s:Update(nil)
		end, "Veron 'T': Update%(dt%) expects a finite number >= 0, got nil")
		t.eq(s:Now(), 0, "new: the clock never moved")
		t.eq(h:GetRemaining(), 1, "new: the timer never moved")
		t.eq(s:GetStats().Updates, 0)
	end)

	t.test("DV-24: delay(fn, true) legacy 'CurrentType: nil', new 'CurrentType: boolean'", function()
		local group = Legacy.group()
		local fn = function() end
		local ok, err = pcall(Legacy.delay, group, fn, true)
		t.eq(ok, false)
		t.eq(_find(err, "expected `delay` to be a number. CurrentType: nil"), true, "legacy reports the coerced type")
		ok, err = pcall(Legacy.delay, group, fn, {})
		t.eq(_find(err, "CurrentType: nil"), true, "legacy: a table is nil too")

		local s = _new()
		ok, err = pcall(function()
			s:Delay(fn, true)
		end)
		t.eq(ok, false)
		t.eq(_find(err, "expected `delay` to be a number. CurrentType: boolean"), true, "new reports the original type")
		ok, err = pcall(function()
			s:Delay(fn, {})
		end)
		t.eq(_find(err, "expected `delay` to be a number. CurrentType: table"), true)
		ok, err = pcall(function()
			s:Recur(fn, nil)
		end)
		t.eq(_find(err, "expected `delay` to be a number. CurrentType: nil"), true, "nil stays nil on both sides")
		t.eq(s:GetClocks(), 0)
		t.eq(getmetatable(s:Delay(fn, "0.5")), VeronEvent, "numeric strings are still coerced")
	end)
end

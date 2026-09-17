--!nonstrict
--[[
	alloc_spec — the zero-garbage guarantees of docs/DESIGN.md (D1/D24,
	F-ALG-3, §2.2 GetStats, §3.1 handle literal, §9 `alloc/alloc_spec` row,
	§10 P2 "delta == 0 KB exactly", §12 WP8). Four tests, names verbatim.

	Method: `collectgarbage("count")` deltas over a measured window (Lune
	0.10.5 has "count" only — "collect" is an invalid option, verified).
	Nothing in the core allocates on the idle path, the busy path or a
	warmed GetStats(into)/Validate, and Luau's collector only takes a step
	when something is allocated, so the delta over those windows is exactly
	0 — no rounding, no tolerance. Each window is preceded by one warm-up
	round run through the SAME helper as the window itself, immediately
	before it (§2.2: the first GetStats(into) sizes the hash part; the
	first dispatching Update issued from a call site can grow the
	interpreter stack once — 1.6 KB measured when the warm-up ran from a
	different frame than the window; see BUILD-NOTES WP8).

	RAW instances on purpose: `Oracle.wrap`'s wrappers pack results into a
	table (`table.pack`), so a wrapped call can never measure 0 B. The
	oracle audits every instance OUTSIDE the measured windows
	(`Oracle.check` before and after).

	`one table per Delay` is the ONLY test where the window allocates by
	design, so the collector may take a step inside it and free earlier
	garbage; the test therefore takes the MAX delta over several short
	rounds (a round no collector step touched is the exact number) and
	compares it with the same-shape 14-key literal measured the same way.
]]

local Veron = require("../../../src/Veron")
local VeronEvent = require("../../../src/Veron/VeronEvent")
local Oracle = require("../../support/oracle")

local ARMED = 10000
local UPDATES = 1000
local BUSY_HANDLES = 50
local DT = 1 / 64

-- one table per Delay: rounds × handles per round (short rounds so a
-- collector step cannot hide in every one of them)
local ROUNDS = 10
local PER_ROUND = 200

-- the 14-key literal of §3.1 fits a 16-node hash part; a 17th key would
-- step the table to 1088 B, so the literal must stay at or under this
local LITERAL_BUDGET = 576

local eventDict = VeronEvent

local function _noop() end

local function _bytes()
	return collectgarbage("count") * 1024
end

--[[
	The measured window: `count` updates of `dt`; returns the byte delta.
	Used for the warm-up round too, so the window never runs anything the
	warm-up did not already run from the same frame.
]]
local function _updates(s, dt, count)
	local before = _bytes()
	for _ = 1, count do
		s:Update(dt)
	end
	return _bytes() - before
end

--[[
	The GetStats(into) + Validate window; returns the byte delta and how
	many of the calls filled `into` and validated true.
]]
local function _statsAndValidate(s, into, count)
	local okCount = 0
	local before = _bytes()
	for _ = 1, count do
		local stats = s:GetStats(into)
		if stats == into and s:Validate() == true then
			okCount += 1
		end
	end
	return _bytes() - before, okCount
end

--[[
	A raw instance with `ARMED` far-future one-shots (dues 1000..1010 s on
	a deterministic grid, beyond every window) so every measured window
	runs over a full heap.
]]
local function _armed(name)
	local s = Veron.new({ Name = name })
	for index = 1, ARMED do
		s:Delay(_noop, 1000 + (index % 100) / 10)
	end
	Oracle.check(s)
	return s
end

--[[
	Builds one handle-shaped literal exactly as `_newEvent` does (§3.1:
	12 user fields + class + type), stamped with the handle dict. Never
	scheduled; only its size is measured.
]]
local function _literal(id)
	local h = {
		class = VeronEvent,
		type = "VeronEvent",
		Id = id,
		_Scheduler = false,
		_Fn = _noop,
		_Period = 5,
		_IsRecur = false,
		_State = 1,
		_HeapIndex = 0,
		_Chained = false,
		_Burst = 0,
		_BurstSerial = 0,
		_MaxCatchUp = false,
		_Flags = 0,
	}
	return setmetatable(h, eventDict)
end

--[[
	Runs `fill(holder, index)` for PER_ROUND slots, ROUNDS times, and
	returns the largest per-slot byte delta seen. `holder` is pre-sized so
	the holder itself never grows inside a window.
]]
local function _maxPerSlot(fill)
	local holder = table.create(PER_ROUND)
	local best = -math.huge
	for _ = 1, ROUNDS do
		local before = _bytes()
		for index = 1, PER_ROUND do
			holder[index] = fill(index)
		end
		local delta = (_bytes() - before) / PER_ROUND
		if delta > best then
			best = delta
		end
		for index = 1, PER_ROUND do
			local h = holder[index]
			if h._Scheduler then
				h:Stop()
			end
			holder[index] = nil
		end
	end
	return best
end

return function(t)
	t.test("1000 idle updates with 10k armed allocate 0 bytes", function()
		local s = _armed("AllocIdle")
		local dt = 1 / 2048 -- 2000 updates advance < 1 s: nothing comes due
		local statsBefore = s:GetStats()
		_updates(s, dt, UPDATES) -- warm-up round, same helper, same frame

		local delta = _updates(s, dt, UPDATES)

		t.eq(delta, 0, "bytes allocated by 1000 idle updates")
		local stats = s:GetStats()
		t.eq(stats.Updates - statsBefore.Updates, 2 * UPDATES, "every update counted (warm-up + window)")
		t.eq(stats.Dispatched, 0, "nothing was due")
		t.eq(stats.Pending, ARMED, "heap untouched")
		Oracle.check(s)
		s:Destroy()
	end)

	t.test("1000 busy updates with 50 noop dispatches each allocate 0 bytes", function()
		local s = _armed("AllocBusy")
		for _ = 1, BUSY_HANDLES do
			s:Recur(_noop, DT) -- period == dt: exactly one fire per update each
		end
		Oracle.check(s)
		local statsBefore = s:GetStats()
		_updates(s, DT, UPDATES) -- warm-up round, same helper, same frame

		local delta = _updates(s, DT, UPDATES)

		t.eq(delta, 0, "bytes allocated by 1000 busy updates")
		local stats = s:GetStats()
		t.eq(stats.Dispatched - statsBefore.Dispatched, 2 * UPDATES * BUSY_HANDLES,
			"50 dispatches per update (warm-up + window)")
		t.eq(stats.Dropped, 0, "never lagged")
		t.eq(stats.ValveHits, 0)
		t.eq(stats.Errors, 0)
		t.eq(stats.Pending, ARMED + BUSY_HANDLES, "the recurring handles stay keyed")
		Oracle.check(s)
		s:Destroy()
	end)

	t.test("warmed GetStats(into) and Validate allocate 0 bytes", function()
		local s = _armed("AllocStats")
		for _ = 1, BUSY_HANDLES do
			s:Recur(_noop, DT)
		end
		local paused = s:Recur(_noop, DT)
		paused:Pause()
		local parent = s:Delay(_noop, 5)
		parent:After(_noop, 1) -- Validate walks a chained list too
		s:Update(DT)

		local into = {}
		local _, warmOk = _statsAndValidate(s, into, 1) -- the one warm-up fill sizes the hash part
		t.eq(warmOk, 1, "consistent before the window")

		local delta, okCount = _statsAndValidate(s, into, UPDATES)

		t.eq(delta, 0, "bytes allocated by 1000 GetStats(into) + Validate")
		t.eq(okCount, UPDATES, "every call filled `into` and validated true")
		t.eq(into.Pending, ARMED + BUSY_HANDLES + 1)
		t.eq(into.Paused, 1)
		t.eq(into.Chained, 1)
		Oracle.check(s)
		s:Destroy()
	end)

	t.test("one table per Delay", function()
		local s = Veron.new({ Name = "AllocDelay" })
		-- grow the heap arrays once (arm, then stop) so no window pays an
		-- array doubling: a removed slot keeps its capacity
		local grown = table.create(PER_ROUND)
		for index = 1, PER_ROUND do
			grown[index] = s:Delay(_noop, 5)
		end
		for index = 1, PER_ROUND do
			grown[index]:Stop()
		end
		Oracle.check(s)

		local literalBytes = _maxPerSlot(_literal)
		local delayBytes = _maxPerSlot(function()
			return s:Delay(_noop, 5)
		end)

		t.eq(literalBytes > 0, true, "the literal measures a positive size")
		t.eq(literalBytes <= LITERAL_BUDGET, true,
			("14-key literal is %d B, budget %d B (no rehash)"):format(literalBytes, LITERAL_BUDGET))
		t.eq(delayBytes, literalBytes, "a Delay allocates exactly the handle table and nothing else")
		Oracle.check(s)
		t.eq(s:GetClocks(), 0, "every measured handle was stopped again")
		s:Destroy()
	end)
end

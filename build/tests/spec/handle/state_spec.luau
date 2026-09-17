--!nonstrict
--[[
	state_spec — VeronEvent state × operation behaviour (docs/DESIGN.md
	§2.3, §4.4, §4.5, §5, §9 handle/state_spec row).

	WP3 wrote ONE test here: `handle dot-call raises the colon message`,
	which needs no scheduler (a hand-built §3.1 literal over a fake owner).
	The remaining 19 §9 names were added by the WP4/WP5 spec writer; every
	instance they touch runs through `Oracle.wrap`. Timing uses dyadic
	numbers only (1/4, 1/64, …) so every float boundary is exact.
]]

local Veron = require("../../../src/Veron")
local VeronEvent = require("../../../src/Veron/VeronEvent")
local Oracle = require("../../support/oracle")

-- Every method of the §2.3 surface plus the LEGACY SURFACE aliases.
local METHOD_NAMES = {
	"Stop",
	"Reset",
	"Adjust",
	"After",
	"SetPeriod",
	"GetPeriod",
	"SetRemaining",
	"GetRemaining",
	"Pause",
	"Resume",
	"IsPaused",
	"Toggle",
	"Restart",
	"Complete",
	"CompleteNow",
	"SetCatchUp",
	"GetState",
	"GetStateId",
	"IsActive",
	"IsRecurring",
	"GetId",
	"GetScheduler",
	"Describe",
	"stop",
	"reset",
	"adjust",
	"after",
	"Destroy",
}

-- The §2.3 fluent methods (return `h`) with a VALID argument each; the
-- terminal no-op walk of the first two added tests iterates this list.
local FLUENT_CALLS = {
	{ "Reset" },
	{ "reset" },
	{ "Adjust", 1 },
	{ "adjust", 1 },
	{ "SetPeriod", 1 },
	{ "SetRemaining", 1 },
	{ "Pause" },
	{ "Resume" },
	{ "Toggle" },
	{ "SetCatchUp", "all" },
	{ "SetCatchUp", "cap", 2 },
	{ "SetCatchUp", "inherit" },
}

-- The §9 bad arguments: a terminal handle swallows them BEFORE validation.
local INVALID_CALLS = {
	{ "Adjust", 0 / 0 },
	{ "adjust", 0 / 0 },
	{ "Adjust", 0 },
	{ "Adjust", -1 },
	{ "Adjust", math.huge },
	{ "Adjust", nil },
	{ "Adjust", "bogus" },
	{ "SetRemaining", -1 },
	{ "SetRemaining", 0 / 0 },
	{ "SetRemaining", nil },
	{ "SetPeriod", nil },
	{ "SetPeriod", 0 },
	{ "SetPeriod", -1 },
	{ "SetPeriod", 0 / 0 },
	{ "SetCatchUp", "bogus" },
	{ "SetCatchUp", "cap", -5 },
	{ "SetCatchUp", "cap", 0 / 0 },
	{ "SetCatchUp", nil },
}

local COLON_MESSAGE = "VeronEvent: methods take a colon: event:Stop(), not event.Stop()"

--[[
	A hand-built §3.1 literal over a FAKE owner. The owner carries the §3.2
	container fields with the literal sitting in its one-slot heap, so the
	oracle's independent walk (which runs after every handle call once any
	spec has called Oracle.wrap) finds a consistent instance; no Veron is
	involved.
]]
local function _literalHandle()
	local owner = {
		Name = "T",
		_Due = {},
		_Item = {},
		_N = 0,
		_Paused = {},
		_PausedCount = 0,
		_Children = {},
		_ChildCount = 0,
		_ChainedCount = 0,
		_RecurCount = 0,
		_UpdateDepth = 0,
		_SyncDepth = 0,
		_Base = false,
		_Firing = false,
		_FiringThread = false,
	}
	local handle = {
		class = VeronEvent,
		type = "VeronEvent",
		Id = 1,
		_Scheduler = owner,
		_Fn = function() end,
		_Period = 1,
		_IsRecur = false,
		_State = 1,
		_HeapIndex = 1,
		_Chained = false,
		_Burst = 0,
		_BurstSerial = 0,
		_MaxCatchUp = false,
		_Flags = 0,
	}
	owner._Due[1] = 1
	owner._Item[1] = handle
	owner._N = 1
	return setmetatable(handle, VeronEvent)
end

--[[
	A fresh oracle-wrapped instance. `cfg` may add `Valve`, `TimeScale`, …;
	the Name defaults to "T" (a label only, §2.1).
]]
local function _new(cfg)
	cfg = cfg or {}
	if cfg.Name == nil then
		cfg.Name = "T"
	end
	return Oracle.wrap(Veron.new(cfg))
end

--[[
	Returns a counter table and a callback that increments it, so a test can
	tell how many times a handle fired.
]]
local function _counter()
	local count = { n = 0 }
	local function fn()
		count.n += 1
	end
	return count, fn
end

--[[
	Everything observable about a handle through its public queries plus the
	three private fields the §9 tests read directly (`_Flags`, `_HeapIndex`,
	`_Fn`).
]]
local function _snapshot(h)
	return {
		state = h:GetState(),
		stateId = h:GetStateId(),
		remaining = h:GetRemaining(),
		paused = h:IsPaused(),
		period = h:GetPeriod(),
		id = h:GetId(),
		active = h:IsActive(),
		recur = h:IsRecurring(),
		describe = h:Describe(),
		flags = rawget(h, "_Flags"),
		heapIndex = rawget(h, "_HeapIndex"),
		fn = rawget(h, "_Fn"),
	}
end

local function _assertSame(t, h, before, label)
	local after = _snapshot(h)
	for key, value in before do
		t.eq(after[key], value, label .. " changed " .. key)
	end
end

--[[
	Builds the four terminal handles the no-op walks use: a Fired one-shot, a
	Fired recurring (via `Complete{ Stop = true }` + update, §4.7), a Stopped
	one-shot and a Stopped recurring. Returns the instance, the handle list
	and the fire counter (every handle shares the counter).
]]
local function _terminalHandles()
	local s = _new()
	local count, fn = _counter()
	local firedOne = s:Delay(fn, 1 / 64)
	local firedRecur = s:Recur(fn, 1 / 64)
	firedRecur:Complete({ Stop = true })
	local stoppedOne = s:Delay(fn, 1 / 64)
	local stoppedRecur = s:Recur(fn, 1 / 64)
	stoppedOne:Stop()
	stoppedRecur:Stop()
	s:Update(1 / 64)
	local handles = {
		{ name = "fired one-shot", h = firedOne, fired = true },
		{ name = "fired recurring", h = firedRecur, fired = true },
		{ name = "stopped one-shot", h = stoppedOne, fired = false },
		{ name = "stopped recurring", h = stoppedRecur, fired = false },
	}
	return s, handles, count
end

return function(t)
	t.test("handle dot-call raises the colon message", function()
		local handle = _literalHandle()
		for _, name in METHOD_NAMES do
			local method = handle[name]
			t.eq(type(method), "function", name .. " exists")
			-- `event.Stop()`: self is nil
			local ok, err = pcall(method)
			t.eq(ok, false, name .. " dot-call raises")
			t.eq(tostring(err):find(COLON_MESSAGE, 1, true) ~= nil, true, name .. ": " .. tostring(err))
			-- `event.Stop(x)` with a non-handle receiver raises the same way
			ok, err = pcall(method, {})
			t.eq(ok, false, name .. " dot-call with a foreign table raises")
			t.eq(tostring(err):find(COLON_MESSAGE, 1, true) ~= nil, true, name .. ": " .. tostring(err))
		end
		-- level 2: the message blames the caller's line, not VeronEvent's.
		-- Once any spec in the process has called Oracle.wrap, the dict entries
		-- are the oracle's wrappers (one pcall frame, re-raised at level 0), so
		-- the position prefix is gone and only the bare message can be checked
		-- (WP2 caveat: level assertions need RAW methods; errors_spec is raw).
		local ok, err = pcall(function()
			handle.Stop()
		end)
		t.eq(ok, false)
		local stopSource = debug.info(rawget(VeronEvent, "Stop"), "s")
		if tostring(stopSource):find("oracle", 1, true) == nil then
			t.eq(tostring(err):find("state_spec:%d+: VeronEvent: methods take a colon") ~= nil, true, tostring(err))
		else
			t.eq(tostring(err), COLON_MESSAGE, "bare message through the oracle wrapper")
		end
		-- the guard never fires on a real colon call
		t.eq(handle:GetState(), "Pending")
	end)

	-- §2.3 (every method total on terminal handles, D8), §4.3–§4.7, §5
	t.test("every public method is a no-op on Stopped and, Stop/Restart excepted, on Fired; each returns h", function()
		local s, handles, count = _terminalHandles()
		t.eq(count.n, 2, "both Fired handles fired exactly once")
		t.eq(handles[1].h:GetState(), "Fired")
		t.eq(handles[2].h:GetState(), "Fired")
		t.eq(handles[2].h:IsRecurring(), true)
		t.eq(handles[3].h:GetState(), "Stopped")
		t.eq(handles[4].h:GetState(), "Stopped")
		local clocksBefore = s:GetClocks()
		local statsBefore = s:GetStats()

		for _, entry in handles do
			local h = entry.h
			local before = _snapshot(h)
			-- fluent methods: return h, change nothing
			for _, call in FLUENT_CALLS do
				local name = call[1]
				local result = h[name](h, call[2], call[3])
				t.eq(result, h, entry.name .. ": " .. name .. " returns h")
				_assertSame(t, h, before, entry.name .. ": " .. name)
			end
			-- Complete / CompleteNow: false on a terminal handle (§4.7, F7)
			t.eq(h:Complete(), false, entry.name .. ": Complete is false")
			_assertSame(t, h, before, entry.name .. ": Complete")
			t.eq(h:Complete({ Stop = true }), false, entry.name .. ": Complete{Stop} is false")
			_assertSame(t, h, before, entry.name .. ": Complete{Stop}")
			t.eq(h:CompleteNow(), false, entry.name .. ": CompleteNow is false")
			_assertSame(t, h, before, entry.name .. ": CompleteNow")
			-- queries stay total
			t.eq(h:GetRemaining(), 0, entry.name .. ": GetRemaining is 0")
			t.eq(h:IsActive(), false, entry.name .. ": IsActive is false")
			t.eq(h:IsPaused(), false, entry.name .. ": IsPaused is false")
			t.eq(h:GetScheduler(), s, entry.name .. ": GetScheduler")
			-- Stop / Restart on a STOPPED handle are no-ops too (Stopped is final)
			if not entry.fired then
				t.eq(h:Stop(), nil, entry.name .. ": Stop returns nothing")
				_assertSame(t, h, before, entry.name .. ": Stop")
				t.eq(h:stop(), nil, entry.name .. ": stop returns nothing")
				t.eq(h:Destroy(), nil, entry.name .. ": Destroy returns nothing")
				_assertSame(t, h, before, entry.name .. ": Destroy")
				t.eq(h:Restart(), h, entry.name .. ": Restart returns h")
				_assertSame(t, h, before, entry.name .. ": Restart")
				t.eq(s.Stop(h), false, entry.name .. ": instance Stop is false")
				_assertSame(t, h, before, entry.name .. ": instance Stop")
				-- After on a Stopped parent: a born-Stopped child, never the parent (A5)
				local child = h:After(function() end, 1 / 64)
				t.eq(child ~= h, true, entry.name .. ": After never returns the parent")
				t.eq(child:GetState(), "Stopped", entry.name .. ": After child is born Stopped")
				_assertSame(t, h, before, entry.name .. ": After")
			end
		end

		-- After on the Fired ONE-SHOT: arms a child from the caller's clock and
		-- leaves the parent alone (A4; a Fired recurring refuses chaining, A3)
		local firedOne = handles[1].h
		local before = _snapshot(firedOne)
		local childCount, childFn = _counter()
		local child = firedOne:After(childFn, 1 / 64)
		t.eq(child ~= firedOne, true, "After on Fired never returns the parent")
		t.eq(child:GetState(), "Pending")
		_assertSame(t, firedOne, before, "fired one-shot: After")
		child:Stop()

		-- nothing above touched the instance: same clocks, same counters
		t.eq(s:GetClocks(), clocksBefore, "GetClocks unchanged")
		t.eq(s:GetStats().Recurring, statsBefore.Recurring, "Recurring stat unchanged")
		t.eq(s:GetStats().Recurring, 0, "a Fired recurring is not counted as recurring")
		s:Update(4)
		t.eq(count.n, 2, "no terminal handle fires again")
		t.eq(childCount.n, 0, "the stopped child never fires")

		-- the two exceptions on Fired: Stop finalizes, Restart re-arms (§4.3, §4.4)
		local firedRecur = handles[2].h
		t.eq(firedRecur:Restart(), firedRecur, "Restart returns h")
		t.eq(firedRecur:GetState(), "Pending", "Restart re-arms a Fired handle")
		firedRecur:Stop()
		t.eq(firedOne:Stop(), nil)
		t.eq(firedOne:GetState(), "Stopped", "Stop finalizes a Fired handle")
	end)

	-- §4.5 (terminal check BEFORE argument validation, D8; JF-01), §2.3, §5
	t.test("every public method is a no-op on Stopped and, Stop/Restart excepted, on Fired even with invalid arguments", function()
		local s, handles, count = _terminalHandles()
		for _, entry in handles do
			local h = entry.h
			local before = _snapshot(h)
			for _, call in INVALID_CALLS do
				local name = call[1]
				local ok, result = pcall(h[name], h, call[2], call[3])
				local label = entry.name .. ": " .. name .. "(" .. tostring(call[2]) .. ")"
				t.eq(ok, true, label .. " must not raise: " .. tostring(result))
				t.eq(result, h, label .. " returns h")
				_assertSame(t, h, before, label)
			end
			-- After with bad arguments on a STOPPED parent: total, no validation (§4.6, A5)
			if not entry.fired then
				for _, args in { { nil, 1 }, { function() end, -1 }, { function() end, "x" }, { 5, 0 / 0 } } do
					local ok, child = pcall(h.After, h, args[1], args[2])
					t.eq(ok, true, entry.name .. ": After(bad) must not raise: " .. tostring(child))
					t.eq(child ~= h, true, entry.name .. ": After(bad) never returns the parent")
					t.eq(child:GetState(), "Stopped", entry.name .. ": After(bad) child is born Stopped")
					_assertSame(t, h, before, entry.name .. ": After(bad)")
				end
				local ok, child = pcall(h.after, h, nil, 1)
				t.eq(ok, true, entry.name .. ": after(nil, 1) must not raise")
				t.eq(child:GetState(), "Stopped")
			end
		end
		s:Update(4)
		t.eq(count.n, 2, "no terminal handle fires again")
		t.eq(s:Validate(), true)
	end)

	-- §4.4 table, R8/RF-006
	t.test("pause on Paused, resume on Pending are no-ops, never a raw transition error", function()
		local s = _new()
		local count, fn = _counter()
		local h = s:Delay(fn, 1)
		s:Update(1 / 4)
		-- resume on Pending: no-op
		local before = _snapshot(h)
		t.eq(h:Resume(), h)
		_assertSame(t, h, before, "Resume on Pending")
		t.eq(h:GetRemaining(), 3 / 4)
		-- pause, then pause again: no-op, no error
		t.eq(h:Pause(), h)
		t.eq(h:GetState(), "Paused")
		t.eq(h:IsPaused(), true)
		t.eq(h:GetRemaining(), 3 / 4)
		before = _snapshot(h)
		local ok, result = pcall(h.Pause, h)
		t.eq(ok, true, "pause on Paused must not raise: " .. tostring(result))
		t.eq(result, h)
		_assertSame(t, h, before, "Pause on Paused")
		t.eq(s:GetStats().Paused, 1, "still exactly one paused handle")
		-- recurring: same
		local r = s:Recur(fn, 1)
		t.eq(r:Resume(), r)
		t.eq(r:GetState(), "Pending")
		r:Pause()
		r:Pause()
		t.eq(r:GetState(), "Paused")
		t.eq(s:GetStats().Paused, 2)
		-- thaw both, they fire exactly once each
		h:Resume()
		r:Resume()
		s:Update(1)
		t.eq(count.n, 2)
	end)

	-- §4.4 (`_Pause`: remaining = max(due − now, 0); `_Resume`: push at now + remaining), R8
	t.test("pause freezes remaining, resume arms from now", function()
		local s = _new()
		local count, fn = _counter()
		local h = s:Delay(fn, 1)
		s:Update(1 / 4)
		t.eq(h:GetRemaining(), 3 / 4)
		h:Pause()
		t.eq(h:GetState(), "Paused")
		t.eq(h:GetRemaining(), 3 / 4, "remaining frozen at pause")
		t.eq(s:GetClocks(), 1, "a Paused handle still counts as a clock")
		s:Update(1)
		t.eq(count.n, 0, "a paused handle never fires")
		t.eq(h:GetRemaining(), 3 / 4, "remaining does not move while Paused")
		t.eq(s:Now(), 5 / 4)
		h:Resume()
		t.eq(h:GetState(), "Pending")
		t.eq(h:GetRemaining(), 3 / 4, "resume arms from now with the frozen remaining")
		s:Update(1 / 2)
		t.eq(count.n, 0)
		t.eq(h:GetRemaining(), 1 / 4)
		s:Update(1 / 4)
		t.eq(count.n, 1, "fires exactly at now + remaining")
		t.eq(h:GetState(), "Fired")
	end)

	-- §4.4 ("a paused recurring accumulates no missed fires"), R8, §2.4 recur-till-touched
	t.test("paused recurring accumulates no missed fires", function()
		local s = _new()
		local count, fn = _counter()
		local r = s:Recur(fn, 1 / 4)
		s:Update(1 / 8)
		t.eq(r:GetRemaining(), 1 / 8)
		r:Pause()
		s:Update(10)
		t.eq(count.n, 0)
		t.eq(s:GetStats().Dropped, 0, "nothing dropped: nothing was owed")
		r:Resume()
		t.eq(r:GetState(), "Pending")
		t.eq(r:GetRemaining(), 1 / 8, "runs on from the frozen remaining")
		s:Update(0)
		t.eq(count.n, 0, "no burst of missed fires on resume")
		s:Update(1 / 8)
		t.eq(count.n, 1)
		s:Update(1 / 4)
		t.eq(count.n, 2, "then the normal cadence")
		t.eq(r:IsRecurring(), true)
		t.eq(r:GetState(), "Pending")
	end)

	-- §4.4 (Chained → PWC), §4.2 `_fireOneShot` (PWC → Paused, remaining = its delay), A8
	t.test("pause while Chained then parent fires → Paused with remaining = delay", function()
		local s = _new()
		local parentCount, parentFn = _counter()
		local childCount, childFn = _counter()
		local p = s:Delay(parentFn, 1)
		local c = p:After(childFn, 1 / 2)
		t.eq(c:GetState(), "Chained")
		t.eq(c:Pause(), c)
		t.eq(c:GetState(), "Chained", "pause on Chained only flags it")
		t.eq(rawget(c, "_Flags") % 2, 1, "PWC set")
		t.eq(c:GetRemaining(), 1 / 2, "a Chained child reports its delay")
		t.eq(s:GetClocks(), 1, "a Chained child is not a clock")
		s:Update(1)
		t.eq(parentCount.n, 1)
		t.eq(p:GetState(), "Fired")
		t.eq(c:GetState(), "Paused", "parent fire parks the PWC child")
		t.eq(c:IsPaused(), true)
		t.eq(c:GetRemaining(), 1 / 2, "remaining = its delay")
		t.eq(rawget(c, "_Flags"), 0, "PWC consumed")
		t.eq(s:GetClocks(), 1, "the Paused child is a clock now")
		t.eq(s:GetStats().Paused, 1)
		t.eq(s:GetStats().Chained, 0)
		s:Update(5)
		t.eq(childCount.n, 0, "stays parked")
		c:Resume()
		t.eq(c:GetState(), "Pending")
		t.eq(c:GetRemaining(), 1 / 2)
		s:Update(1 / 2)
		t.eq(childCount.n, 1)
	end)

	-- §4.4 (`_Resume` on Chained: `_Flags -= PWC` if set), A8
	t.test("resume while Chained clears the flag", function()
		local s = _new()
		local childCount, childFn = _counter()
		local p = s:Delay(function() end, 1)
		local c = p:After(childFn, 1 / 2)
		-- resume without pause: nothing to clear, no error
		t.eq(c:Resume(), c)
		t.eq(rawget(c, "_Flags"), 0)
		t.eq(c:GetState(), "Chained")
		c:Pause()
		t.eq(rawget(c, "_Flags") % 2, 1)
		t.eq(c:Resume(), c)
		t.eq(rawget(c, "_Flags") % 2, 0, "PWC cleared")
		t.eq(c:GetState(), "Chained")
		s:Update(1)
		t.eq(c:GetState(), "Pending", "arms normally when the parent fires")
		t.eq(c:GetRemaining(), 1 / 2, "from the parent's ideal due")
		t.eq(s:GetStats().Paused, 0)
		s:Update(1 / 2)
		t.eq(childCount.n, 1)
	end)

	-- §2.3 GetState row (SEM S1), §4.2 `_fireOneShot` (Fired BEFORE fn), R-B
	t.test("GetState inside own callback reads Fired", function()
		local s = _new()
		local seen = {}
		local h
		h = s:Delay(function()
			seen.state = h:GetState()
			seen.stateId = h:GetStateId()
			seen.active = h:IsActive()
			seen.remaining = h:GetRemaining()
			seen.heapIndex = rawget(h, "_HeapIndex")
			seen.validate = s:Validate()
		end, 1 / 4)
		s:Update(1 / 4)
		t.eq(seen.state, "Fired")
		t.eq(seen.stateId, 4)
		t.eq(seen.active, false)
		t.eq(seen.remaining, 0)
		t.eq(seen.heapIndex, 0, "already out of the heap")
		t.eq(seen.validate, true, "invariants hold inside the callback")
		t.eq(h:GetState(), "Fired")
		-- a recurring is re-keyed in place before its callback: it reads Pending
		local recurSeen = {}
		local r
		r = s:Recur(function()
			recurSeen.state = r:GetState()
			recurSeen.remaining = r:GetRemaining()
		end, 1 / 4)
		s:Update(1 / 4)
		t.eq(recurSeen.state, "Pending")
		t.eq(recurSeen.remaining, 1 / 4, "already re-keyed at d + period")
	end)

	-- §4.5 `_GetRemaining` (Pending max(due−now,0) | Paused frozen | Chained P | terminal 0), R9, B-14
	t.test("GetRemaining per state", function()
		local s = _new()
		local fn = function() end
		local pending = s:Delay(fn, 1)
		local paused = s:Delay(fn, 1)
		local fired = s:Delay(fn, 1 / 4)
		local stopped = s:Delay(fn, 1)
		local chained = pending:After(fn, 2)
		stopped:Stop()
		s:Update(1 / 4)
		t.eq(pending:GetRemaining(), 3 / 4, "Pending: due − now")
		paused:Pause()
		s:Update(1 / 4)
		t.eq(pending:GetRemaining(), 1 / 2)
		t.eq(paused:GetRemaining(), 3 / 4, "Paused: frozen remaining")
		t.eq(chained:GetRemaining(), 2, "Chained: its delay (B-14, documented)")
		t.eq(fired:GetState(), "Fired")
		t.eq(fired:GetRemaining(), 0, "Fired: 0")
		t.eq(stopped:GetRemaining(), 0, "Stopped: 0")
		-- never negative: a deferred Complete keys at now, the query clamps at 0
		pending:Complete()
		t.eq(pending:GetRemaining(), 0)
		-- the instance query is owner-agnostic and never raises (S-09: nil, never 0)
		t.eq(s:GetRemaining(paused), 3 / 4)
		t.eq(s:GetRemaining(nil), nil)
		t.eq(s:GetRemaining(5), nil)
		t.eq(s:GetRemaining({}), nil)
		local strict = _new({ Name = "Strict", Strict = true })
		t.eq(strict:GetRemaining({}), nil, "nil even under Strict")
		-- instance-seconds under TimeScale (R9): 1/4 wall second at ×2 consumes 1/2
		local scaled = _new({ Name = "Scaled", TimeScale = 2 })
		local h = scaled:Delay(fn, 1)
		scaled:Update(1 / 4)
		t.eq(h:GetRemaining(), 1 / 2, "scheduler seconds, not wall seconds")
	end)

	-- §5 IsActive row (Pending/Paused/Chained true; Fired/Stopped false), §2.2 GetClocks (D20)
	t.test("IsActive per state", function()
		local s = _new()
		local fn = function() end
		local pending = s:Delay(fn, 1)
		local paused = s:Delay(fn, 1)
		local fired = s:Delay(fn, 1 / 4)
		local stopped = s:Delay(fn, 1)
		local chained = pending:After(fn, 1)
		paused:Pause()
		stopped:Stop()
		s:Update(1 / 4)
		t.eq(pending:GetState(), "Pending")
		t.eq(pending:IsActive(), true)
		t.eq(paused:GetState(), "Paused")
		t.eq(paused:IsActive(), true)
		t.eq(chained:GetState(), "Chained")
		t.eq(chained:IsActive(), true)
		t.eq(fired:GetState(), "Fired")
		t.eq(fired:IsActive(), false)
		t.eq(stopped:GetState(), "Stopped")
		t.eq(stopped:IsActive(), false)
		t.eq(s:GetClocks(), 2, "GetClocks counts Pending + Paused, not Chained")
		t.eq(s:GetStats().Pending, 1)
		t.eq(s:GetStats().Paused, 1)
		t.eq(s:GetStats().Chained, 1)
	end)

	-- §2.3 Stop aliases (`stop`, `Destroy`), S10
	t.test("Destroy alias equals stop", function()
		local dict = VeronEvent
		t.eq(rawget(dict, "Destroy"), rawget(dict, "Stop"), "Destroy is the same function object as Stop")
		t.eq(rawget(dict, "stop"), rawget(dict, "Stop"), "stop is the same function object as Stop")
		local s = _new()
		local count, fn = _counter()
		local h = s:Delay(fn, 1)
		t.eq(h.Destroy, h.Stop)
		t.eq(h.stop, h.Stop)
		t.eq(h:Destroy(), nil, "returns nothing, like stop")
		t.eq(h:GetState(), "Stopped")
		t.eq(s:GetClocks(), 0)
		t.eq(h:Destroy(), nil, "idempotent")
		t.eq(h:stop(), nil)
		t.eq(h:GetState(), "Stopped")
		-- cascades like Stop (A2)
		local p = s:Delay(fn, 1)
		local c = p:After(fn, 1)
		p:Destroy()
		t.eq(c:GetState(), "Stopped")
		s:Update(5)
		t.eq(count.n, 0)
	end)

	-- §2.3 Describe (`VeronEvent<Tick#42 recur 0.5s Pending>`), §4.4 (`+stop`/`+repause`), §4.11 instance Describe
	t.test("Describe strings", function()
		local s = _new()
		local fn = function() end
		local r = s:Recur(fn, 0.5)
		local d = s:Delay(fn, 1)
		t.eq(r:Describe(), "VeronEvent<T#1 recur 0.5s Pending>")
		t.eq(d:Describe(), "VeronEvent<T#2 delay 1s Pending>")
		t.eq(s:Describe(), "Veron<T now=0.000 pending=2 paused=0>")
		d:Pause()
		t.eq(d:Describe(), "VeronEvent<T#2 delay 1s Paused>")
		t.eq(s:Describe(), "Veron<T now=0.000 pending=1 paused=1>")
		local c = d:After(fn, 0.25)
		t.eq(c:Describe(), "VeronEvent<T#3 delay 0.25s Chained>")
		local fired = s:Delay(fn, 0.125)
		s:Update(0.125)
		t.eq(fired:Describe(), "VeronEvent<T#4 delay 0.125s Fired>")
		t.eq(s:Describe(), "Veron<T now=0.125 pending=1 paused=1>")
		fired:Stop()
		t.eq(fired:Describe(), "VeronEvent<T#4 delay 0.125s Stopped>")
		-- COMMITTED recurring handles show the owed forced fire
		r:Complete({ Stop = true })
		t.eq(r:Describe(), "VeronEvent<T#1 recur 0.5s Pending+stop>")
		local pausedRecur = s:Recur(fn, 2)
		pausedRecur:Pause()
		pausedRecur:Complete()
		t.eq(pausedRecur:Describe(), "VeronEvent<T#5 recur 2s Pending+repause>")
		-- a differently named instance shows its own label
		local other = _new({ Name = "Tick" })
		local h = other:Recur(fn, 0.5)
		t.eq(h:Describe(), "VeronEvent<Tick#1 recur 0.5s Pending>")
		t.eq(other:Describe(), "Veron<Tick now=0.000 pending=1 paused=0>")
	end)

	-- §4.4 `_Toggle`, §2.3 Toggle row, §5 Toggle row (Q-J18)
	t.test("Toggle flips Pending and Paused, flips PWC on Chained, no-op on terminal and COMMITTED", function()
		local s = _new()
		local count, fn = _counter()
		-- Pending ↔ Paused (the recur switch)
		local r = s:Recur(fn, 1)
		s:Update(1 / 4)
		t.eq(r:Toggle(), r)
		t.eq(r:GetState(), "Paused")
		t.eq(r:IsPaused(), true)
		t.eq(r:GetRemaining(), 3 / 4)
		s:Update(5)
		t.eq(count.n, 0, "off: nothing fires")
		t.eq(r:Toggle(), r)
		t.eq(r:GetState(), "Pending")
		t.eq(r:IsPaused(), false)
		t.eq(r:GetRemaining(), 3 / 4, "on: runs on from the frozen remaining")
		s:Update(3 / 4)
		t.eq(count.n, 1)
		r:Stop()
		-- Chained: flips PWC
		local p = s:Delay(fn, 1)
		local c = p:After(fn, 1)
		t.eq(c:Toggle(), c)
		t.eq(c:GetState(), "Chained")
		t.eq(rawget(c, "_Flags") % 2, 1, "PWC set")
		t.eq(c:Toggle(), c)
		t.eq(rawget(c, "_Flags") % 2, 0, "PWC cleared")
		t.eq(c:GetState(), "Chained")
		p:Stop()
		-- terminal: no-op
		local fired = s:Delay(fn, 1 / 4)
		local stopped = s:Delay(fn, 1)
		stopped:Stop()
		s:Update(1 / 4)
		t.eq(fired:GetState(), "Fired")
		for _, h in { fired, stopped } do
			local before = _snapshot(h)
			t.eq(h:Toggle(), h)
			_assertSame(t, h, before, h:GetState() .. ": Toggle")
		end
		-- COMMITTED (STOP_ON_FIRE): no-op until the forced fire
		local committed = s:Recur(fn, 1)
		committed:Complete({ Stop = true })
		t.eq(rawget(committed, "_Flags"), 4)
		local before = _snapshot(committed)
		t.eq(committed:Toggle(), committed)
		_assertSame(t, committed, before, "COMMITTED (+stop): Toggle")
		t.eq(committed:GetState(), "Pending")
		-- COMMITTED (REPAUSE): no-op, stays logically paused
		local repause = s:Recur(fn, 1)
		repause:Pause()
		repause:Complete()
		t.eq(rawget(repause, "_Flags"), 8)
		t.eq(repause:IsPaused(), true)
		before = _snapshot(repause)
		t.eq(repause:Toggle(), repause)
		_assertSame(t, repause, before, "COMMITTED (+repause): Toggle")
		local firesBefore = count.n
		s:Update(0)
		t.eq(count.n, firesBefore + 2, "both forced fires happen")
		t.eq(committed:GetState(), "Fired")
		t.eq(repause:GetState(), "Paused")
	end)

	-- §4.4 `_Restart` (Fired → Pending at _Now + period, fresh Id), §2.4 reset-after-touched
	t.test("Restart re-arms a Fired one-shot from now with its full period and it fires again", function()
		local s = _new()
		local count, fn = _counter()
		local h = s:Delay(fn, 1)
		s:Update(1)
		t.eq(count.n, 1)
		t.eq(h:GetState(), "Fired")
		local oldId = h:GetId()
		s:Update(1 / 2)
		t.eq(h:Restart(), h, "returns h")
		t.eq(h:GetState(), "Pending")
		t.eq(h:IsActive(), true)
		t.eq(h:GetRemaining(), 1, "full period from now, not from the old due")
		t.eq(h:GetPeriod(), 1)
		t.eq(h:GetId() > oldId, true, "a fresh Id")
		t.eq(h.Id, h:GetId())
		t.eq(s:GetClocks(), 1)
		s:Update(1 / 2)
		t.eq(count.n, 1, "not yet")
		s:Update(1 / 2)
		t.eq(count.n, 2, "fires again with the same function")
		t.eq(h:GetState(), "Fired")
		-- a restarted handle can be restarted again, and again takes a fresh Id
		local secondId = h:GetId()
		h:Restart()
		t.eq(h:GetId() > secondId, true)
		s:Update(1)
		t.eq(count.n, 3)
		-- from inside its own callback: Fired was set before fn, the push lands normally
		local selfCount = 0
		local again
		again = s:Delay(function()
			selfCount += 1
			if selfCount < 3 then
				again:Restart()
			end
		end, 1 / 4)
		s:Update(1 / 4)
		t.eq(selfCount, 1)
		t.eq(again:GetState(), "Pending", "self-Restart from the callback re-armed it")
		t.eq(again:GetRemaining(), 1 / 4)
		s:Update(1 / 4)
		s:Update(1 / 4)
		t.eq(selfCount, 3)
		s:Update(1)
		t.eq(selfCount, 3)
		t.eq(again:GetState(), "Fired")
	end)

	-- §4.4 `_Restart` ("a STOP_ON_FIRE'd recurring re-arms as recurring"), §4.7 opts.Stop
	t.test("Restart re-arms a Fired recurring as recurring", function()
		local s = _new()
		local count, fn = _counter()
		local r = s:Recur(fn, 1 / 2)
		s:Update(1 / 2)
		t.eq(count.n, 1)
		t.eq(r:Complete({ Stop = true }), true)
		s:Update(0)
		t.eq(count.n, 2, "the forced final fire")
		t.eq(r:GetState(), "Fired")
		t.eq(r:IsRecurring(), true)
		t.eq(s:GetStats().Recurring, 0, "a Fired recurring is not counted")
		t.eq(s:GetClocks(), 0)
		local oldId = r:GetId()
		t.eq(r:Restart(), r)
		t.eq(r:GetState(), "Pending")
		t.eq(r:IsRecurring(), true, "still recurring")
		t.eq(r:GetRemaining(), 1 / 2, "full period from now")
		t.eq(rawget(r, "_Flags"), 0, "no leftover STOP_ON_FIRE")
		t.eq(r:GetId() > oldId, true)
		t.eq(s:GetStats().Recurring, 1, "counted again")
		t.eq(s:GetClocks(), 1)
		s:Update(1 / 2)
		t.eq(count.n, 3)
		t.eq(r:GetState(), "Pending", "re-arms itself like any recurring")
		s:Update(1)
		t.eq(count.n, 5, "keeps going")
		r:Stop()
		t.eq(s:GetStats().Recurring, 0)
	end)

	-- §4.4 `_Restart` (Stopped → no-op), §4.3 (Stopped is final), SafeStopClock semantics
	t.test("Restart on Stopped is a no-op (Stopped is final)", function()
		local s = _new()
		local count, fn = _counter()
		-- stopped before firing
		local h = s:Delay(fn, 1)
		h:Stop()
		local before = _snapshot(h)
		t.eq(h:Restart(), h, "returns h")
		_assertSame(t, h, before, "Stopped: Restart")
		t.eq(h:GetState(), "Stopped")
		t.eq(rawget(h, "_Fn"), Oracle.noop(), "still NOOP")
		-- the SafeStopClock-after-fire path: Fired → stop() → Restart refused
		local fired = s:Delay(fn, 1 / 4)
		s:Update(1 / 4)
		t.eq(count.n, 1)
		fired:stop()
		t.eq(fired:GetState(), "Stopped")
		before = _snapshot(fired)
		t.eq(fired:Restart(), fired)
		_assertSame(t, fired, before, "Fired then stopped: Restart")
		t.eq(fired:GetState(), "Stopped")
		-- a stopped recurring too
		local r = s:Recur(fn, 1 / 4)
		r:Stop()
		t.eq(r:Restart(), r)
		t.eq(r:GetState(), "Stopped")
		t.eq(s:GetClocks(), 0)
		s:Update(5)
		t.eq(count.n, 1, "nothing ever fires again")
		t.eq(s:GetStats().Recurring, 0)
	end)

	-- §4.4 `_Restart` (Pending/Paused → `_Reset` then `_Resume`; Chained/COMMITTED → no-op), §5 Restart row
	t.test("Restart on Pending/Paused equals Reset then Resume", function()
		local s = _new()
		local count, fn = _counter()
		local fn2 = function() end
		-- Pending: full period from now, keeps running (a twin does Reset + Resume)
		local a = s:Delay(fn, 1)
		local twinA = s:Delay(fn2, 1)
		s:Update(1 / 4)
		t.eq(a:GetRemaining(), 3 / 4)
		t.eq(a:Restart(), a)
		twinA:Reset():Resume()
		t.eq(a:GetState(), "Pending")
		t.eq(a:GetRemaining(), 1)
		t.eq(a:GetRemaining(), twinA:GetRemaining())
		t.eq(a:GetState(), twinA:GetState())
		t.eq(a:GetId(), 1, "no fresh Id on a live handle")
		-- Paused: → Pending at now + P, running (the twin does Reset + Resume)
		local b = s:Delay(fn, 1)
		local twinB = s:Delay(fn2, 1)
		s:Update(1 / 4)
		b:Pause()
		twinB:Pause()
		t.eq(b:GetRemaining(), 3 / 4)
		t.eq(b:Restart(), b)
		twinB:Reset():Resume()
		t.eq(b:GetState(), "Pending")
		t.eq(b:IsPaused(), false)
		t.eq(b:GetRemaining(), 1)
		t.eq(b:GetRemaining(), twinB:GetRemaining())
		t.eq(b:GetState(), twinB:GetState())
		s:Update(1)
		t.eq(count.n, 2, "both fire one full period after the Restart")
		-- Paused recurring: the recur-till-touched pattern (§2.4): Restart = fresh full period
		local r = s:Recur(fn, 1)
		s:Update(3 / 4)
		r:Pause()
		t.eq(r:GetRemaining(), 1 / 4)
		r:Restart()
		t.eq(r:GetState(), "Pending")
		t.eq(r:GetRemaining(), 1, "fresh full period, not the frozen remaining")
		r:Stop()
		-- Chained: no-op
		local p = s:Delay(fn2, 1)
		local c = p:After(fn2, 1 / 2)
		local before = _snapshot(c)
		t.eq(c:Restart(), c)
		_assertSame(t, c, before, "Chained: Restart")
		p:Stop()
		-- COMMITTED: no-op (the forced fire is owed)
		local committed = s:Recur(fn2, 1)
		committed:Complete({ Stop = true })
		before = _snapshot(committed)
		t.eq(committed:Restart(), committed)
		_assertSame(t, committed, before, "COMMITTED: Restart")
		t.eq(committed:GetRemaining(), 0, "still keyed at now")
	end)

	-- §4.4 `_Restart` (`self._IsDestroyed` → no-op), §2.2 ("every handle method stays total" after Destroy)
	t.test("Restart on a handle of a destroyed Veron is a no-op", function()
		local s = _new()
		local count, fn = _counter()
		local fired = s:Delay(fn, 1 / 4)
		local live = s:Delay(fn, 1)
		local paused = s:Delay(fn, 1)
		paused:Pause()
		s:Update(1 / 4)
		t.eq(fired:GetState(), "Fired")
		s:Destroy()
		t.eq(s:IsDestroyed(), true)
		t.eq(live:GetState(), "Stopped", "Destroy clears live handles")
		t.eq(paused:GetState(), "Stopped")
		t.eq(fired:GetState(), "Fired", "Clear never reaches a Fired handle")
		local before = _snapshot(fired)
		local ok, result = pcall(fired.Restart, fired)
		t.eq(ok, true, "must not raise: " .. tostring(result))
		t.eq(result, fired, "returns h")
		_assertSame(t, fired, before, "destroyed owner: Restart")
		t.eq(fired:GetState(), "Fired")
		t.eq(fired:GetId(), before.id, "no fresh Id")
		for _, h in { live, paused } do
			local snap = _snapshot(h)
			t.eq(h:Restart(), h)
			_assertSame(t, h, snap, "destroyed owner, Stopped: Restart")
		end
		t.eq(s:GetClocks(), 0)
		t.eq(count.n, 1)
		-- the fired handle can still be finalized on the dead instance
		fired:Stop()
		t.eq(fired:GetState(), "Stopped")
	end)

	-- R-B, §3.1 `_Fn` comment, §4.3 (`_Fn = NOOP` on Stop), §4.4 (Restart re-runs the kept fn), Q-J18
	t.test("a Fired handle keeps its function until Restart or Stop, a Stopped handle has NOOP", function()
		local s = _new()
		local count, fn = _counter()
		local noop = Oracle.noop()
		t.eq(type(noop), "function", "the oracle captured the NOOP")
		-- Stopped: NOOP, shared by every Stopped handle, never the user's function
		local stoppedA = s:Delay(fn, 1)
		local stoppedB = s:Recur(fn, 1)
		stoppedA:Stop()
		stoppedB:Stop()
		t.eq(rawget(stoppedA, "_Fn"), noop, "Stopped one-shot carries NOOP")
		t.eq(rawget(stoppedB, "_Fn"), noop, "Stopped recurring carries NOOP")
		t.eq(rawget(stoppedA, "_Fn"), rawget(stoppedB, "_Fn"), "one NOOP for every Stopped handle")
		t.eq(rawget(stoppedA, "_Fn") ~= fn, true)
		-- Fired: keeps fn
		local fired = s:Delay(fn, 1 / 4)
		local firedRecur = s:Recur(fn, 1 / 4)
		firedRecur:Complete({ Stop = true })
		s:Update(1 / 4)
		t.eq(fired:GetState(), "Fired")
		t.eq(firedRecur:GetState(), "Fired")
		t.eq(rawget(fired, "_Fn"), fn, "Fired one-shot keeps its function")
		t.eq(rawget(firedRecur, "_Fn"), fn, "Fired recurring keeps its function")
		t.eq(rawget(fired, "_Flags"), 0)
		t.eq(rawget(fired, "_HeapIndex"), 0)
		-- Restart re-runs the SAME function
		fired:Restart()
		t.eq(rawget(fired, "_Fn"), fn, "kept across Restart")
		local firesBefore = count.n
		s:Update(1 / 4)
		t.eq(count.n, firesBefore + 1, "the kept function ran again")
		t.eq(rawget(fired, "_Fn"), fn, "still kept after the second fire")
		-- an explicit Stop on a Fired handle releases it: NOOP from then on
		fired:Stop()
		t.eq(fired:GetState(), "Stopped")
		t.eq(rawget(fired, "_Fn"), noop, "Stop on Fired installs NOOP")
		s.Stop(firedRecur)
		t.eq(rawget(firedRecur, "_Fn"), noop, "instance Stop on Fired installs NOOP")
		-- a Restart after that is refused and NOOP stays
		fired:Restart()
		t.eq(fired:GetState(), "Stopped")
		t.eq(rawget(fired, "_Fn"), noop)
		s:Update(5)
		t.eq(count.n, firesBefore + 1)
	end)
end

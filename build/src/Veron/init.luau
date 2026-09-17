--!native
--!nonstrict
local VeronClass = {
	_VERSION = "3.0.0",
	_DESCRIPTION = "Veron - an instance-based, due-time-ordered timer scheduler "
		.. "(indexed min-heap, virtual clock) driven by Update(dt)",
	--[[
		A Veron is one scheduler. You build one per RunService hook and call
		its Update(dt) once a frame; it fires the timers that came due. Each
		armed timer is a VeronEvent handle. Handles live in an indexed binary
		min-heap keyed by due time, so an idle frame touches nothing and a
		busy frame only touches what fired. The heap orders on (due, Id), so
		two timers due at the same instant fire oldest first.

		The clock is virtual. Update(dt) advances _Now by dt, so the scheduler
		is driven and never bound to the wall clock. UpdateTo(t) drives it from
		an absolute time source instead.

		Two rules run through the whole file. First, a timer is finalized
		before its callback runs: it is popped or re-keyed, its after-chain
		children are armed, and its terminal state is set, all before the
		callback fires. So if a callback stops, resets or completes its own
		timer, the callback wins. Second, an arm made from inside a firing
		callback, on that callback's own coroutine, measures from the timer's
		ideal due time (_Base) rather than from _Now, so a periodic timer does
		not drift. Any other thread measures from _Now.

		Callbacks are untrusted. Each callback runs under a protected call, and
		each pass runs under one too with cleanup that always happens, so a
		callback that errors, re-enters Update or mutates timers still leaves
		the instance consistent. Validate() proves that after the fact.

		Layout, top to bottom: the heap operations, then the validation and arm
		helpers, then the stop cascade, then diagnostics and the fire paths,
		then the dispatch pass and the clock, then the class and its methods.
		_advanceTo, _stopTerminal and _attach are forward-declared near the top
		because they are used above where they are defined.
	--]]
}

local Env
if typeof(script) == "Instance" then
	Env = require(script.Env)
else
	Env = require("./Veron/Env")
end

local VeronEvent
if Env.IsRoblox then
	VeronEvent = require(script.VeronEvent)
else
	VeronEvent = require("./Veron/VeronEvent")
end

-- The five states a handle can be in. PENDING is armed and waiting in the
-- heap. PAUSED is frozen aside with its remaining time held. CHAINED is an
-- after-child waiting for its parent to fire. FIRED and STOPPED are the two
-- terminal states, so "terminal" is just _State >= FIRED.
local PENDING, PAUSED, CHAINED, FIRED, STOPPED = 1, 2, 3, 4, 5

-- _Flags packs four one-bit switches so they can be read with plain
-- arithmetic instead of bit32. PWC (1) marks a chained child that should
-- arrive paused when its parent fires. COMPLETING (2) guards a synchronous
-- complete against mutual recursion. STOP_ON_FIRE (4) turns a recurring into
-- a one-shot that stops after its next fire. REPAUSE (8) makes a paused
-- recurring fire once and then park itself paused again. To test one bit:
-- PWC is _Flags % 2 == 1, COMPLETING is _Flags % 4 >= 2, STOP_ON_FIRE is
-- _Flags % 8 >= 4, REPAUSE is _Flags >= 8, and a plain recurring (neither
-- of the last two) is _Flags < 4.
local PWC, COMPLETING, STOP_ON_FIRE, REPAUSE = 1, 2, 4, 8

local HUGE = math.huge

local xpcall, pcall, tonumber, type, typeof, getmetatable =
	xpcall, pcall, tonumber, type, typeof, getmetatable
local running = coroutine.running
local traceback = Env.Traceback

--[[ Does nothing. A stopped handle's callback is swapped to this. ]]
local function NOOP() end

local eventDict = VeronEvent
local veronDict -- set to Veron once the module table below is created

-- Bumped once per instance to build the default Name ("Veron" .. n).
local instanceCount = 0

-- How deep synchronous CompleteNow calls may nest before one is refused.
local MAX_SYNC_DEPTH = 8

-- The one options table any method still accepts (Complete / CompleteNow).
local COMPLETE_OPTS = { Stop = true }

-- Public methods and the alternate spellings that call the same closure.
-- initialize walks this list and stores one closure under every name in a
-- row, so "Update" and "update" (and the rest) are the same function.
local PUBLIC = {
	{ "Update", "update" },
	{ "UpdateTo" },
	{ "Now" },
	{ "SetTimeScale" },
	{ "GetTimeScale" },
	{ "Pause" },
	{ "Resume" },
	{ "IsPaused" },
	{ "Delay", "delay" },
	{ "Recur", "recur" },
	{ "DelayAt" },
	{ "Stop", "Remove", "remove" },
	{ "Complete", "ForceEventComplete" },
	{ "CompleteNow" },
	{ "GetRemaining" },
	{ "GetClocks", "getClocks" },
	{ "GetStats" },
	{ "Validate" },
	{ "Describe" },
	{ "SetOnError" },
	{ "SetMaxCatchUp" },
	{ "GetMaxCatchUp" },
	{ "SetValve" },
	{ "SetMaxDt" },
	{ "SetStrict" },
	{ "Clear" },
	{ "Attach" },
	{ "Detach" },
	{ "GetChildren" },
	{ "Drive" },
	{ "Destroy" },
	{ "IsDestroyed" },
	{ "IsUpdating" },
	{ "GetBase" },
}

-- Forward declarations; each is assigned where it is defined further down.
local _advanceTo, _stopTerminal, _attach

-- These helpers raise errors at a caller-relative stack level, so they must
-- be forward-declared locals rather than plain `local function`s. The Luau
-- compiler inlines a small `local function` into its caller, which erases the
-- frame the level count depends on; a local assigned after its declaration is
-- left alone, so the reported line stays correct.
local _checkOption, _checkOpts, _validateUncapped, _validateArgs, _resolve

-------------------------------------------------------------------
-- HOT PATH: the indexed binary min-heap.
--
-- Three parallel arrays hold the queue: self._Due[i] is a due time,
-- self._Item[i] is the handle at that slot, and self._N is how many slots
-- are in use. The heap orders on (due, Id), so the earliest due time sits at
-- slot 1 and ties break by Id (oldest first). Every handle also stores its
-- own slot number in _HeapIndex (0 means it is not in the heap), which is
-- what lets remove and re-key find a handle in O(log n) without a scan.
--
-- This block is kept tight and uses short locals on purpose; it runs on
-- every push and every fire.
-------------------------------------------------------------------

--[[
	Bubbles the handle at slot i toward the root until its parent is not
	later than it. Used after a push or a decrease in due time. Returns the
	slot it settled in.
]]
local function siftUp(due, item, i)
	local d, it = due[i], item[i]
	local s = it.Id
	while i > 1 do
		local p = i // 2
		local dp = due[p]
		if d < dp or (d == dp and s < item[p].Id) then
			due[i] = dp
			local ip = item[p]
			item[i] = ip
			ip._HeapIndex = i
			i = p
		else
			break
		end
	end
	due[i] = d
	item[i] = it
	it._HeapIndex = i
	return i
end

--[[
	Sinks the handle at slot i toward the leaves until neither child is
	earlier than it. Used after a pop or an increase in due time. It always
	picks the earlier of the two children to swap with. Returns the slot it
	settled in.
]]
local function siftDown(due, item, n, i)
	local d, it = due[i], item[i]
	local s = it.Id
	while true do
		local c = i + i
		if c > n then
			break
		end
		local dc = due[c]
		local r = c + 1
		if r <= n then
			local dr = due[r]
			if dr < dc or (dr == dc and item[r].Id < item[c].Id) then
				c = r
				dc = dr
			end
		end
		if dc < d or (dc == d and item[c].Id < s) then
			due[i] = dc
			local ic = item[c]
			item[i] = ic
			ic._HeapIndex = i
			i = c
		else
			break
		end
	end
	due[i] = d
	item[i] = it
	it._HeapIndex = i
	return i
end

--[[ Adds handle h with due time d as a new leaf, then sifts it up. ]]
local function heapPush(self, h, d)
	local n = self._N + 1
	self._N = n
	local due, item = self._Due, self._Item
	due[n] = d
	item[n] = h
	h._HeapIndex = n
	siftUp(due, item, n)
end

--[[
	Removes and returns the earliest entry (due time, handle) from the root.
	The last leaf is moved into slot 1 and sifted down to restore order. The
	popped handle's _HeapIndex is cleared to 0.
]]
local function heapPop(self)
	local due, item, n = self._Due, self._Item, self._N
	local d, it = due[1], item[1]
	it._HeapIndex = 0
	if n > 1 then
		due[1] = due[n]
		item[1] = item[n]
	end
	due[n] = nil
	item[n] = nil
	n -= 1
	self._N = n
	if n > 0 then
		siftDown(due, item, n, 1)
	end
	return d, it
end

--[[
	Removes handle `it` from anywhere in the heap using its stored slot. The
	last leaf fills the hole and is sifted up or down as needed. Returns true
	if it was removed, false if it was not actually in the heap (a stale or
	already-popped handle), which callers rely on being harmless.
]]
local function heapRemove(self, it)
	local i = it._HeapIndex
	if i == 0 then
		return false
	end
	local due, item, n = self._Due, self._Item, self._N
	if item[i] ~= it then
		return false
	end
	it._HeapIndex = 0
	if i == n then
		due[n] = nil
		item[n] = nil
		self._N = n - 1
		return true
	end
	due[i] = due[n]
	item[i] = item[n]
	due[n] = nil
	item[n] = nil
	n -= 1
	self._N = n
	local p = i // 2
	if i > 1 and (due[i] < due[p] or (due[i] == due[p] and item[i].Id < item[p].Id)) then
		siftUp(due, item, i)
	else
		siftDown(due, item, n, i)
	end
	return true
end

--[[
	Changes handle `it`'s due time to nd in place and sifts it the right
	direction (up if it moved earlier, down if later). Errors if the handle is
	not currently in this heap, since re-keying something that is not queued is
	a caller mistake.
]]
local function heapUpdate(self, it, nd)
	local i = it._HeapIndex
	local due, item = self._Due, self._Item
	if i == 0 or item[i] ~= it then
		error("Veron: handle is not scheduled on this Veron", 2)
	end
	local old = due[i]
	due[i] = nd
	if nd < old then
		siftUp(due, item, i)
	else
		siftDown(due, item, self._N, i)
	end
end

--[[
	Empties the heap. Every handle's _HeapIndex is zeroed first so no handle is
	left thinking it still holds a slot, then the arrays are wiped and the
	count reset.
]]
local function heapClear(self)
	local due, item = self._Due, self._Item
	for i = 1, self._N do
		item[i]._HeapIndex = 0
	end
	table.clear(due)
	table.clear(item)
	self._N = 0
end

-- END HOT PATH

-------------------------------------------------------------------
-- Validation and arm helpers
-------------------------------------------------------------------

--[[ True if value is a function or a table with a __call metamethod. ]]
local function _isCallable(value)
	if type(value) == "function" then
		return true
	end

	local mt = type(value) == "table" and getmetatable(value)
	return type(mt) == "table" and type(rawget(mt, "__call")) == "function"
end

--[[ True for a real number that is not NaN and not either infinity. ]]
local function _isFinite(value)
	return type(value) == "number" and value == value and value ~= HUGE and value ~= -HUGE
end

--[[ True for a whole number of 1 or more. ]]
local function _isPositiveInteger(value)
	return _isFinite(value) and value >= 1 and value % 1 == 0
end

--[[
	Which clock a new arm should measure from. Inside the callback that is
	firing right now, and only on that same coroutine, it returns the timer's
	ideal due time (_Base) so a periodic arm keeps its phase. From any other
	thread (a yield window, task.spawn, a remote handler) it returns _Now.
]]
local function _clockOf(self)
	local base = self._Base
	if base ~= false and running() == self._FiringThread then
		return base
	end

	return self._Now
end

--[[
	One row per config option and runtime setter. Each row is { message,
	predicate }: the predicate says whether a value is acceptable, and the
	message is the human phrasing used when it is not. The same table backs
	both the constructor and the SetX setters, so the two can never disagree
	on what a valid value is.
]]
local OPTION_CHECKS = {
	Name = { "a string", function(value)
		return type(value) == "string"
	end },
	TimeScale = { "a finite number >= 0", function(value)
		return _isFinite(value) and value >= 0
	end },
	MaxCatchUp = { "an integer >= 1", _isPositiveInteger },
	Valve = { "an integer >= 1", _isPositiveInteger },
	MaxDt = { "a number > 0 or false", function(value)
		return value == false or (_isFinite(value) and value > 0)
	end },
	MaxUpdateDepth = { "an integer >= 1", _isPositiveInteger },
	OnError = { "\"warn\", \"error\" or a function", function(value)
		return value == "warn" or value == "error" or type(value) == "function"
	end },
	Strict = { "a boolean", function(value)
		return type(value) == "boolean"
	end },
	LegacyRecurBase = { "a boolean", function(value)
		return type(value) == "boolean"
	end },
}

--[[
	Checks one option value against its row and returns it unchanged when it
	passes, otherwise raises with the row's message. `prefix` and `level` let
	the caller aim the error: the constructor blames the new() site, a setter
	blames its own caller.
]]
_checkOption = function(prefix, key, value, level)
	local spec = OPTION_CHECKS[key]
	if spec[2](value) then
		return value
	end

	error(("%soption '%s' expects %s, got %s"):format(prefix, key, spec[1], tostring(value)), level)
end

--[[
	Validates a method's options table: nil is allowed (nothing to check), a
	non-table is rejected, and any key not in `allowed` is rejected by name.
	Used by Complete and CompleteNow, which take only { Stop = true }.
]]
_checkOpts = function(self, opts, allowed, method, level)
	if opts == nil then
		return
	end

	if type(opts) ~= "table" then
		error(("Veron '%s': %s expects an options table, got %s"):format(self.Name, method, typeof(opts)), level)
	end

	for key in opts do
		if not allowed[key] then
			error(("Veron '%s': unknown option '%s' in %s"):format(self.Name, tostring(key), method), level)
		end
	end
end

--[[
	Turns the `uncapped` argument of Recur and Drive into an internal
	catch-up value: nil or false means inherit the instance cap (false),
	true means uncapped (HUGE). Anything else raises, and it does so before
	any timer is armed.
]]
_validateUncapped = function(uncapped, level)
	if uncapped == nil or uncapped == false then
		return false
	end

	if uncapped == true then
		return HUGE
	end

	error("expected `uncapped` to be a boolean", level)
end

--[[
	Shared front door for every arm. Rejects a destroyed instance, a
	non-callable fn, and a delay that is not a finite number of zero or more.
	A recurring arm additionally rejects a zero delay, since that would be a
	tight loop. The delay is coerced through tonumber and returned. The
	error text reports the type of the value the caller actually passed.
]]
_validateArgs = function(self, fn, delayArg, isRecur, level)
	if self._IsDestroyed then
		error(("Veron '%s': destroyed"):format(self.Name), level)
	end

	if not _isCallable(fn) then
		error("expected `fn` to be callable", level)
	end

	local delay = tonumber(delayArg)
	if type(delay) ~= "number" then
		error("expected `delay` to be a number. CurrentType: " .. typeof(delayArg), level)
	end

	if delay ~= delay or delay == HUGE or delay == -HUGE then
		error("expected `delay` to be a finite number", level)
	end

	if delay < 0 then
		error("expected `delay` of zero or greater", level)
	end

	if isRecur and delay == 0 then
		error("expected recur `delay` greater than zero", level)
	end

	return delay
end

--[[
	Builds one VeronEvent handle. This is the only table an arm allocates, and
	it is built after every check has passed so a rejected arm never bumps a
	counter or an id. Takes the next id, counts the handle if it is recurring,
	and returns it wired to the VeronEvent metatable.
]]
local function _newEvent(self, fn, period, isRecur, state, maxCatchUp)
	local id = self._NextId + 1
	self._NextId = id
	if isRecur then
		self._RecurCount += 1
	end

	local h = {
		class = VeronEvent,
		type = "VeronEvent",
		Id = id,
		_Scheduler = self,
		_Fn = fn,
		_Period = period,
		_IsRecur = isRecur,
		_State = state,
		_HeapIndex = 0,
		_Chained = false,
		_Burst = 0,
		_BurstSerial = 0,
		_MaxCatchUp = maxCatchUp,
		_Flags = 0,
	}
	return setmetatable(h, eventDict)
end

-------------------------------------------------------------------
-- Stop cascade: the only route a handle takes to Stopped
-------------------------------------------------------------------

--[[
	Stops a handle and reports whether a live one actually became Stopped.
	The terminal check comes first. An already-Stopped handle is left alone
	and returns false. A Fired handle is finalized (marked Stopped, callback
	swapped to NOOP) but returns false too, since it was never live to stop.
	A live handle is pulled out of whichever container holds it (heap, paused
	set, or its parent's chained list), zeroed, and its still-chained children
	are stopped in turn. A child that a Complete already detached is no longer
	chained, so it keeps its promised fire.
]]
_stopTerminal = function(self, h)
	local state = h._State
	if state == STOPPED then
		return false
	end

	if state == FIRED then
		h._State, h._Fn = STOPPED, NOOP
		return false
	end

	if state == PENDING then
		heapRemove(self, h) -- if it was already popped this is a harmless no-op
	elseif state == PAUSED then
		self._Paused[h] = nil
		self._PausedCount -= 1
	else
		self._ChainedCount -= 1 -- chained: the parent's list will skip it later
	end

	if h._IsRecur then
		self._RecurCount -= 1
	end

	h._State, h._Fn, h._Flags = STOPPED, NOOP, 0

	local children = h._Chained
	if children then
		h._Chained = false
		for index = 1, #children do
			local child = children[index]
			if child._State == CHAINED then
				_stopTerminal(self, child)
			end
		end
	end

	return true
end

--[[
	The per-handle step Clear uses. It writes the terminal state directly and
	does not touch the heap or the paused set, because Clear wipes those in
	one shot afterward. It still recurses into chained descendants, which live
	in no container of their own. Returns how many handles it stopped,
	counting h itself.
]]
local function _clearTerminal(self, h)
	h._State, h._Fn, h._Flags, h._HeapIndex = STOPPED, NOOP, 0, 0
	local count = 1

	local children = h._Chained
	if children then
		h._Chained = false
		for index = 1, #children do
			local child = children[index]
			if child._State == CHAINED then
				count += _clearTerminal(self, child)
			end
		end
	end

	return count
end

--[[
	Turns a user-supplied value into a handle of this Veron, or nil. nil in
	gives nil out. A value that is not a VeronEvent gives nil, unless Strict
	is on, in which case it raises. A real VeronEvent that belongs to a
	different Veron always raises, since acting on it here would corrupt the
	other instance.
]]
_resolve = function(self, x, level)
	if x == nil then
		return nil
	end

	if getmetatable(x) ~= eventDict then
		if self._Strict then
			error(("Veron '%s': expected a VeronEvent, got %s"):format(self.Name, typeof(x)), level)
		end

		return nil
	end

	if x._Scheduler ~= self then
		error(
			("Veron '%s': event #%d belongs to Veron '%s', not '%s'"):format(
				self.Name,
				x.Id,
				x._Scheduler.Name,
				self.Name
			),
			level
		)
	end

	return x
end

-------------------------------------------------------------------
-- Diagnostics, error reporting, and the fire paths
-------------------------------------------------------------------

--[[
	The single channel for problems the scheduler itself notices: a
	re-entered Update, a backwards clock, a tripped valve, a sub-resolution
	period, a too-deep CompleteNow. If the OnError policy is a function it is
	given the message; otherwise the message is warned. A diagnostic is never
	re-raised, even under the "error" policy, and a warn seam that itself
	throws cannot escape this function.
]]
local function _diagnose(self, message, h)
	local policy = self._OnError
	if type(policy) == "function" and pcall(policy, message, h) then
		return
	end

	pcall(Env.Warn, ("[Veron %s] %s"):format(self.Name, message))
end

--[[
	Reports a callback that errored, with rate limiting so a misbehaving timer
	cannot flood the log: at most one report per second for the same handle,
	and roughly eight per second across distinct handles. Under the "error"
	policy nothing is logged here; the first message is stored and re-raised
	once when the whole update unwinds. Suppressed errors are counted and the
	count is folded into the next message that does get through.
]]
local function _report(self, message, h)
	self._Errors += 1
	local policy = self._OnError
	if policy == "error" then
		if not self._Errored then
			self._Errored = message
		end

		return
	end

	local now = self._Now
	local since = now - self._LastErrorAt
	if since < 1 and (h.Id == self._LastErrorId or since < 0.125) then
		self._ErrorsSuppressed += 1
		return
	end

	self._LastErrorId, self._LastErrorAt = h.Id, now
	local suppressed = self._ErrorsSuppressed
	if suppressed > 0 then
		message = ("%s (%d suppressed so far)"):format(message, suppressed)
	end

	if policy == "warn" then
		pcall(Env.Warn, ("[Veron %s] event #%d: %s"):format(self.Name, h.Id, message))
	elseif not pcall(policy, message, h) then
		pcall(Env.Warn, ("[Veron %s] OnError handler failed for event #%d: %s"):format(self.Name, h.Id, message))
	end
end

--[[
	Runs one timer callback under protection so an error in it cannot break
	the pass. When this same handle already errored within the last second the
	next report would be suppressed anyway, so it uses a plain pcall and skips
	building a traceback. Otherwise it uses xpcall with a traceback handler.
	The callback is always called with no arguments.
]]
local function _runCallback(self, h, fn)
	local ok, message
	if h.Id == self._LastErrorId and self._Now - self._LastErrorAt < 1 then
		ok, message = pcall(fn) -- report would be suppressed anyway; save the alloc
	else
		ok, message = xpcall(fn, traceback)
	end

	if ok then
		return
	end

	_report(self, message, h)
end

--[[
	Fires a handle that has already been popped from the heap, as a one-shot.
	Everything is settled before the callback runs: the handle is marked Fired,
	its still-chained children are armed off the ideal due time d, and its
	flags are zeroed. The callback itself is kept rather than dropped, so a
	Restart from inside it can re-arm the same handle. After the callback
	returns, nothing scheduling-related happens.
]]
local function _fireOneShot(self, h, d)
	h._State = FIRED
	if h._IsRecur then
		self._RecurCount -= 1 -- a recurring only reaches here on the stop-on-fire path
	end

	local children = h._Chained
	if children then
		h._Chained = false
		for index = 1, #children do
			local child = children[index]
			if child._State == CHAINED then
				self._ChainedCount -= 1
				if child._Flags % 2 == 1 then -- pause bit set: arrive Paused with its delay
					child._Flags -= PWC
					child._State = PAUSED
					self._Paused[child] = child._Period
					self._PausedCount += 1
				else
					child._State = PENDING
					heapPush(self, child, d + child._Period)
				end
			end
		end
	end

	h._Flags = 0
	self._Base, self._Firing = d, h
	_runCallback(self, h, h._Fn)
end

--[[
	Fires a paused recurring that was force-completed without a stop. It was
	popped to fire once; before the callback runs it is parked back in the
	paused set with a fresh full period, so it stays paused afterward.
]]
local function _fireRepause(self, h, d)
	h._Flags -= REPAUSE
	h._State = PAUSED
	self._Paused[h] = h._Period
	self._PausedCount += 1
	self._Base, self._Firing = d, h
	_runCallback(self, h, h._Fn)
end

--[[
	The runaway guard tripped. Bumping _ValveHits also acts as a latch that
	stops every pass of the current outer Update: each pass records the count
	when it starts and breaks at the top of its loop as soon as it sees the
	count change. That is what keeps a callback that arms a zero-delay timer
	and calls Update(0) from looping forever; the leftover timers stay queued
	for the next real update. The warning is emitted only once per instance.
]]
local function _valveHit(self, h)
	self._ValveHits += 1
	if self._WarnedValve then
		return
	end

	self._WarnedValve = true
	_diagnose(
		self,
		"runaway valve hit (" .. self._Valve .. " nested arms / catch-up repeats); remainder deferred to the next update",
		h
	)
end

--[[
	Handles a recurring whose period is now too small to make progress: at a
	large clock value, adding the period lands on the same float, so it would
	fire forever at the same instant. Rather than hang, the handle is stopped
	and a warning is emitted once per instance.
]]
local function _stopResolution(self, h)
	_stopTerminal(self, h)
	if self._WarnedResolution then
		return
	end

	self._WarnedResolution = true
	_diagnose(
		self,
		"recur period below clock resolution at now = " .. self._Now .. "; event #" .. h.Id .. " stopped",
		h
	)
end

-------------------------------------------------------------------
-- The dispatch pass
-------------------------------------------------------------------

--[[
	Fires everything that is due at the current clock. This is the loop body
	of an update and always runs under a protected call set up by _advanceTo.

	It reads the earliest entry, stops if that entry is still in the future,
	and otherwise dispatches it. A one-shot is popped and fired. A plain
	recurring is re-keyed to its next due time in place, before its callback
	runs, so the callback sees the timer already rescheduled.

	Two things bound the loop. The valve counts timers that were armed during
	this same pass and, separately, extra repeats of an uncapped recurring;
	once the count passes the valve limit the pass breaks and the rest waits
	for the next update. The catch-up cap bounds how many times a single
	recurring may fire to catch up after a long frame: past the cap it snaps
	forward to the next grid point after now, keeping its phase, and counts
	the fires it skipped in Dropped. A period that has shrunk below float
	resolution stops the handle instead of hanging. Returns how many callbacks
	it dispatched.

	Example: a 1s recurring last due at t=10 when the clock jumps to t=15 with
	a catch-up cap of 8 fires at 11, 12, 13, 14, 15 and carries on. With a cap
	of 2 it fires twice, then snaps to 15 and records the skipped fires.
]]
local function _pass(self, serial, valveHits)
	local due, item = self._Due, self._Item
	local startId, valve, valveCap = self._NextId, 0, self._Valve
	local legacyBase = self._LegacyRecurBase
	local dispatched = 0
	-- HOT PATH: locals only, and nothing is scheduled after a callback runs.
	while self._N > 0 do -- Clear and Destroy set _N = 0, which exits here
		if self._ValveHits ~= valveHits then
			break -- some pass of this outer Update tripped the valve; stop now
		end
		local now = self._Now -- re-read: a nested pass may have moved it
		local d = due[1]
		if d > now then
			break
		end
		local h = item[1]
		if h.Id > startId then -- armed during this pass and already due again
			valve += 1
			if valve > valveCap then
				_valveHit(self, h)
				break
			end
		end
		if h._IsRecur and h._Flags < 4 then -- plain recurring
			local period = h._Period
			local burst = 1
			if h._BurstSerial == serial then
				burst = h._Burst + 1
			else
				h._BurstSerial = serial
			end
			h._Burst = burst
			local cap = h._MaxCatchUp or self._MaxCatchUp -- false inherits; HUGE is uncapped; 1 drops
			if burst > cap then -- over the cap: snap to the first grid point past now
				local m = (now - d) // period + 1
				local nextDue = d + m * period
				if nextDue <= now then
					nextDue += period
				end
				if nextDue <= now then
					heapPop(self)
					_stopResolution(self, h)
				else
					due[1] = nextDue
					siftDown(due, item, self._N, 1)
					self._Dropped += m
				end
			else
				local nextDue = d + period
				if nextDue <= d then -- period too small to advance the float: stop, never hang
					heapPop(self)
					_stopResolution(self, h)
				else
					if burst > 1 and cap == HUGE then -- uncapped: each extra repeat spends the valve
						valve += 1
						if valve > valveCap then
							_valveHit(self, h) -- still keyed at d, so it fires next update
							break
						end
					end
					due[1] = nextDue
					siftDown(due, item, self._N, 1) -- re-key in place, before the callback
					self._Base = legacyBase and nextDue or d -- ideal due for arms in the callback
					self._Firing = h
					_runCallback(self, h, h._Fn)
					dispatched += 1
				end
			end
		elseif h._IsRecur then -- cold recurring: stop-on-fire, or a deferred re-pause
			heapPop(self)
			if h._Flags >= REPAUSE then
				_fireRepause(self, h, d)
			else
				_fireOneShot(self, h, d)
			end
			dispatched += 1
		else
			heapPop(self)
			_fireOneShot(self, h, d)
			dispatched += 1
		end
	end
	-- END HOT PATH
	return dispatched
end

--[[
	Moves the clock to `target` and runs one protected pass if anything is
	due. The clock never goes backwards: a backwards target is clamped and
	counted, and a large backwards jump warns once.

	Updates can nest, because a callback might call Update again. A nested or
	overlapped call runs a real pass while the depth is below MaxUpdateDepth,
	and merely advances the clock past that. The depth is decremented on the
	way out and never restored to a saved value, which keeps it correct even
	when coroutines unwind out of order.

	The pass runs under xpcall and the cleanup below it always runs. When the
	OnError policy is "error", the first stored callback error is re-raised
	once here, at the outermost exit. An internal fault (a bug in the
	scheduler itself) is re-raised after state has already been made clean.
]]
_advanceTo = function(self, target)
	local now = self._Now
	if target > now then
		self._Now = target
	elseif target < now then
		self._ClampedBackwards += 1
		if now - target > 1 and not self._WarnedBackwards then
			self._WarnedBackwards = true
			_diagnose(self, ("clock asked to move backwards by %g s; clamped"):format(now - target), false)
		end
	end

	local depth = self._UpdateDepth
	if depth > 0 then
		self._Reentries += 1
		if not self._WarnedReentry then
			self._WarnedReentry = true
			_diagnose(self, "Update re-entered from a callback (see Stats.Reentries)", false)
		end

		if depth >= self._MaxUpdateDepth then
			return -- too deep: advance the clock only, run no pass
		end
	end

	self._Updates += 1
	if self._N == 0 or self._Due[1] > self._Now then -- nothing due: idle fast path
		self._LastDispatched = 0
		return
	end

	self._UpdateDepth = depth + 1
	local savedBase, savedFiring, savedThread = self._Base, self._Firing, self._FiringThread
	self._FiringThread = running() -- recorded once per pass, not once per callback
	local serial = self._Serial + 1
	self._Serial = serial

	local ok, result = xpcall(_pass, traceback, self, serial, self._ValveHits)

	depth = self._UpdateDepth - 1
	self._UpdateDepth = depth -- decrement, never restore a saved value
	if depth == 0 and self._SyncDepth == 0 then
		self._Base, self._Firing, self._FiringThread = false, false, false
	else
		self._Base, self._Firing, self._FiringThread = savedBase, savedFiring, savedThread
	end

	if ok then
		self._Dispatched += result
		self._LastDispatched = result
	else
		self._LastDispatched = 0
	end

	if depth == 0 then
		local errored = self._Errored
		if errored then
			self._Errored = false
			if ok then
				error(errored, 0) -- "error" policy: re-raise once, at the outermost exit
			end
		end
	end

	if not ok then
		error(("Veron '%s': internal fault during Update: %s"):format(self.Name, tostring(result)), 0)
	end
end

-------------------------------------------------------------------
-- Validate() helpers: they allocate nothing but the reason string
-------------------------------------------------------------------

--[[
	Checks the invariants that must hold for a single handle no matter which
	container it lives in: it belongs to this Veron, its state and flags are
	in range, a terminal handle keeps no slot or flags, and its state agrees
	with where it is (Paused handles are keys of the paused set, Pending
	handles sit at their heap slot, and so on). Returns nil when all is well,
	or the reason string of the first thing that is wrong.
]]
local function _validateShape(self, h)
	if type(h) ~= "table" then
		return "handle slot holds a non-table"
	end

	if h._Scheduler ~= self then
		return "handle belongs to another Veron"
	end

	local state, flags, heapIndex = h._State, h._Flags, h._HeapIndex
	if type(state) ~= "number" or state < PENDING or state > STOPPED then
		return "handle _State outside 1..5"
	end

	if type(flags) ~= "number" or flags < 0 or flags > 15 then
		return "handle _Flags outside 0..15"
	end

	if state >= FIRED then
		if heapIndex ~= 0 then
			return "terminal handle keeps a _HeapIndex"
		end

		if flags ~= 0 then
			return "terminal handle keeps _Flags"
		end

		if state == STOPPED and h._Fn ~= NOOP then
			return "Stopped handle _Fn is not NOOP"
		end
	end

	if flags >= STOP_ON_FIRE and not (state == PENDING and h._IsRecur) then
		return "_Flags >= 4 on a handle that is not a Pending recurring"
	end

	if state == PAUSED then
		if heapIndex ~= 0 then
			return "Paused handle keeps a _HeapIndex"
		end

		if self._Paused[h] == nil then
			return "Paused handle is not a key of _Paused"
		end
	elseif self._Paused[h] ~= nil then
		return "non-Paused handle is a key of _Paused"
	end

	if state == PENDING then
		if heapIndex == 0 or self._Item[heapIndex] ~= h then
			return "Pending handle is not at its _HeapIndex slot"
		end
	elseif state == CHAINED then
		if heapIndex ~= 0 then
			return "Chained handle keeps a _HeapIndex"
		end

		if h._IsRecur then
			return "Chained handle is recurring"
		end
	end

	return nil
end

--[[
	Walks a handle's chained-child list and its descendants. Checks the shape
	of each child and recurses into the ones that are still chained. Returns
	the number of still-chained descendants and nil, or a partial count and
	the reason of the first violation it finds.
]]
local function _validateChain(self, h)
	local list = h._Chained
	if not list then
		return 0, nil
	end

	if type(list) ~= "table" then
		return 0, "handle _Chained is neither false nor a list"
	end

	local count = 0
	for index = 1, #list do
		local child = list[index]
		local reason = _validateShape(self, child)
		if reason then
			return count, reason
		end

		if child._State == CHAINED then
			local below, deepReason = _validateChain(self, child)
			if deepReason then
				return count, deepReason
			end

			count += 1 + below
		end
	end

	return count, nil
end

-------------------------------------------------------------------
-- The class
-------------------------------------------------------------------

local Veron = {}
Veron.__index = Veron
veronDict = Veron

-- Test-only handle on the raw heap ops so the heap tests can drive them
-- against a bare instance's arrays. It is never reached on the hot path.
Veron._Heap = {
	push = heapPush,
	pop = heapPop,
	remove = heapRemove,
	update = heapUpdate,
	clear = heapClear,
}

--[[
	True when class is Veron. The same instance check any class offers, so code
	that identifies objects by class keeps working for a scheduler too.
]]
function Veron:isInstanceOf(class)
	return class == Veron
end

--[[ Reads one config value, falling back to `default` when it is absent. ]]
local function _readOption(cfg, key, default)
	local value = cfg and cfg[key]
	if value == nil then
		return default
	end

	return value
end

--[[
	Sets up a fresh instance. It validates the config table first, rejecting
	an unknown option by name before checking any value, so the error blames
	the new() call site. Then it assigns every field a starting value: the
	heap arrays, the virtual clock, the pass bookkeeping, the policy settings,
	the side indexes, and the stat counters. Last, it builds the public
	methods as closures that accept either the dot or the colon call form, one
	closure stored under each of a method's names.
]]
function Veron:initialize(cfg)
	if cfg ~= nil and type(cfg) ~= "table" then
		error(("Veron: expected a config table, got %s"):format(typeof(cfg)), 4)
	end

	if cfg ~= nil then
		for key in cfg do
			if OPTION_CHECKS[key] == nil then
				error(("Veron: unknown option '%s'"):format(tostring(key)), 4)
			end
		end

		for key, value in cfg do
			_checkOption("Veron: ", key, value, 5)
		end
	end

	instanceCount += 1

	-- lifecycle
	self.Name = _readOption(cfg, "Name", "Veron" .. instanceCount)
	self._IsDestroyed = false

	-- heap
	self._Due = {}
	self._Item = {}
	self._N = 0

	-- clock
	self._Now = 0
	self._Base = false
	self._Firing = false
	self._FiringThread = false
	self._TimeScale = _readOption(cfg, "TimeScale", 1)
	self._IsPaused = false
	self._Offset = 0
	self._LastAbs = false

	-- pass
	self._UpdateDepth = 0
	self._SyncDepth = 0
	self._Serial = 0
	self._NextId = 0
	self._Errored = false

	-- policy
	self._MaxCatchUp = _readOption(cfg, "MaxCatchUp", 8)
	self._Valve = _readOption(cfg, "Valve", 1000)
	self._MaxDt = _readOption(cfg, "MaxDt", false)
	self._MaxUpdateDepth = _readOption(cfg, "MaxUpdateDepth", 8)
	self._OnError = _readOption(cfg, "OnError", "warn")
	self._Strict = _readOption(cfg, "Strict", false)
	self._LegacyRecurBase = _readOption(cfg, "LegacyRecurBase", false)

	-- side indexes (cold)
	self._Paused = {}
	self._PausedCount = 0
	self._Children = {}
	self._ChildCount = 0
	self._Parent = false
	self._ChainedCount = 0
	self._RecurCount = 0

	-- stats
	self._Updates = 0
	self._Dispatched = 0
	self._LastDispatched = 0
	self._Reentries = 0
	self._Dropped = 0
	self._ValveHits = 0
	self._ClampedBackwards = 0
	self._ClampedDt = 0
	self._Errors = 0
	self._ErrorsSuppressed = 0
	self._LastDt = 0
	self._LastErrorId = 0
	self._LastErrorAt = -HUGE
	self._WarnedReentry = false
	self._WarnedValve = false
	self._WarnedBackwards = false
	self._WarnedResolution = false

	-- Build the call closures from the method table, so each closure picks up
	-- the current method and both the dot and colon call forms reach it.
	for _, names in PUBLIC do
		local method = veronDict[names[1]]
		local closure = function(first, ...)
			if first == self then
				return method(self, ...)
			end

			return method(self, first, ...)
		end
		for _, alias in names do
			self[alias] = closure
		end
	end
end

--[[
	Builds the instance table, stamps Veron as its metatable so method calls
	resolve, and runs initialize. Kept as its own hop between Veron.new and
	initialize so initialize sits at the same call depth it always has, which is
	what keeps the line numbers in its config errors pointing at the caller. It
	is a forward-declared local, not a `local function`, so the Luau optimizer
	leaves it as a real stack frame instead of inlining it away.
]]
local _construct
_construct = function(cfg)
	local self = setmetatable({ class = Veron, type = "Veron" }, Veron)
	self:initialize(cfg)
	return self
end

--[[
	Makes a new scheduler. All three spellings work and reach the same place:
	Veron.new(cfg), Veron:new(cfg) and Veron(cfg). With the colon or the call
	form the first argument is Veron itself, so it is shifted off and the real
	config takes its place.
]]
function Veron.new(a, cfg)
	if a ~= Veron then
		cfg = a
	end

	return _construct(cfg)
end

setmetatable(Veron, {
	__call = function(_, cfg)
		return Veron.new(cfg)
	end,
})

-------------------------------------------------------------------
-- The clock and the update entry points
-------------------------------------------------------------------

--[[
	The normal way to drive a Veron: call it once a frame with the elapsed
	time. It checks that dt is a finite number of zero or more, checks the
	instance is not destroyed, then applies the optional MaxDt clamp so one
	huge frame cannot flood the scheduler. A paused instance records the dt
	and advances nothing. Otherwise it advances the clock by dt times the
	time scale and runs a pass.
]]
function Veron:Update(dt)
	if type(dt) ~= "number" or dt ~= dt or dt < 0 or dt == HUGE then
		error(("Veron '%s': Update(dt) expects a finite number >= 0, got %s"):format(self.Name, tostring(dt)), 3)
	end

	if self._IsDestroyed then
		error(("Veron '%s': destroyed"):format(self.Name), 3)
	end

	local maxDt = self._MaxDt
	if maxDt and dt > maxDt then
		dt = maxDt
		self._ClampedDt += 1
	end

	self._LastDt = dt
	if self._IsPaused then
		return
	end

	_advanceTo(self, self._Now + dt * self._TimeScale)
end

--[[
	Drives the clock from an absolute time source instead of a delta. The
	first sample only anchors the offset between that source and the virtual
	clock; it does not sweep any timers forward. After that, each call
	advances the clock to match. At time scale 1 it maps the absolute time
	straight through the offset with no accumulation, so it stays exact. While
	paused the elapsed gap is folded into the offset so no time is lost. A
	backwards move is clamped and counted inside _advanceTo.
]]
function Veron:UpdateTo(t)
	if type(t) ~= "number" or t ~= t or t == HUGE or t == -HUGE then
		error(("Veron '%s': UpdateTo(t) expects a finite number, got %s"):format(self.Name, tostring(t)), 3)
	end

	if self._IsDestroyed then
		error(("Veron '%s': destroyed"):format(self.Name), 3)
	end

	local last = self._LastAbs
	if last == false then
		self._LastAbs, self._Offset = t, t - self._Now
		if not self._IsPaused then
			_advanceTo(self, self._Now) -- fires anything already due, like Update(0)
		end

		return
	end

	if self._IsPaused then
		self._Offset += t - last
		self._LastAbs = t
		return
	end

	local target
	if self._TimeScale == 1 then
		target = t - self._Offset -- straight through the offset, no drift
	else
		target = self._Now + (t - last) * self._TimeScale
		self._Offset = t - target
	end

	self._LastAbs = t
	_advanceTo(self, target)
end

--[[ The current virtual time. ]]
function Veron:Now()
	return self._Now
end

--[[
	Changes how fast virtual time runs relative to the dt passed in. Re-anchors
	the absolute-clock offset so a live UpdateTo stream stays continuous across
	the change.
]]
function Veron:SetTimeScale(x)
	_checkOption(("Veron '%s': "):format(self.Name), "TimeScale", x, 4)
	self._TimeScale = x
	if self._LastAbs ~= false then
		self._Offset = self._LastAbs - self._Now
	end
end

--[[ The current time scale. ]]
function Veron:GetTimeScale()
	return self._TimeScale
end

--[[ Freezes the clock: Update still records dt but advances nothing. ]]
function Veron:Pause()
	self._IsPaused = true
end

--[[ Unfreezes the clock so Update advances it again. ]]
function Veron:Resume()
	self._IsPaused = false
end

--[[ Whether the clock is currently frozen. ]]
function Veron:IsPaused()
	return self._IsPaused
end

--[[ Whether a pass is running right now, for example inside a callback. ]]
function Veron:IsUpdating()
	return self._UpdateDepth > 0
end

--[[
	The ideal due time an arm on the calling thread would measure from. It
	returns _Base only when called on the coroutine that is firing right now,
	and false everywhere else. Useful for a callback that wants to schedule
	relative to its own exact due time.
]]
function Veron:GetBase()
	local base = self._Base
	if base ~= false and running() == self._FiringThread then
		return base
	end

	return false
end

-------------------------------------------------------------------
-- Arming timers
-------------------------------------------------------------------

--[[
	Arms a one-shot: fn runs once, delay seconds from now. Returns the handle.
	When called from inside a firing callback the delay is measured from that
	timer's ideal due time, so a chain of delays does not drift.
]]
function Veron:Delay(fn, delayArg)
	local period = _validateArgs(self, fn, delayArg, false, 4)
	local h = _newEvent(self, fn, period, false, PENDING, false)
	heapPush(self, h, _clockOf(self) + period)
	return h
end

--[[
	Arms a recurring timer: fn runs every `period` seconds. `uncapped` chooses
	the catch-up behaviour after a long frame (see _validateUncapped and the
	catch-up cap in _pass). Returns the handle.
]]
function Veron:Recur(fn, periodArg, uncapped)
	local period = _validateArgs(self, fn, periodArg, true, 4)
	local maxCatchUp = _validateUncapped(uncapped, 4) -- last place this can raise
	local h = _newEvent(self, fn, period, true, PENDING, maxCatchUp)
	heapPush(self, h, _clockOf(self) + period)
	return h
end

--[[
	Arms a one-shot at an absolute time on the UpdateTo axis. It works out how
	far that time is from the last absolute sample, scales it, and subtracts
	any carry the calling thread already holds, so the timer lands at the right
	virtual moment. Needs UpdateTo to have been called at least once, since
	there is no absolute axis before that.
]]
function Veron:DelayAt(fn, absDue)
	if self._IsDestroyed then
		error(("Veron '%s': destroyed"):format(self.Name), 3)
	end

	local last = self._LastAbs
	if last == false then
		error(("Veron '%s': DelayAt needs UpdateTo to have been called at least once"):format(self.Name), 3)
	end

	local due = _validateArgs(self, fn, absDue, false, 4)
	local clock = _clockOf(self)
	local delay = math.max((due - last) * self._TimeScale - (clock - self._Now), 0)
	local h = _newEvent(self, fn, delay, false, PENDING, false)
	heapPush(self, h, clock + delay)
	return h
end

-------------------------------------------------------------------
-- Stop, Complete, and queries taking a handle
-------------------------------------------------------------------

--[[
	Stops a timer so it never fires again. Returns true only if a live timer
	was actually stopped. A nil or unrecognised handle is ignored (unless
	Strict rejects it in _resolve).
]]
function Veron:Stop(x)
	local h = _resolve(self, x, 4)
	return h ~= nil and _stopTerminal(self, h)
end

--[[
	Force-completes a timer on the next pass: it fires soon rather than at its
	scheduled time. See _Complete for the details of what each state does and
	what opts.Stop means. Returns false for a nil or unrecognised handle.
]]
function Veron:Complete(x, opts)
	local h = _resolve(self, x, 4)
	if h == nil then
		return false
	end

	return self:_Complete(h, opts, 4)
end

--[[
	Force-completes a timer right now, running its callback before this call
	returns. See _CompleteNow for the guards. Returns false for a nil or
	unrecognised handle.
]]
function Veron:CompleteNow(x, opts)
	local h = _resolve(self, x, 4)
	if h == nil then
		return false
	end

	return self:_CompleteNow(h, opts, 4)
end

--[[
	Seconds until a handle is next due. Any VeronEvent answers through its own
	owner, so it does not matter which Veron you ask. A nil or non-handle
	returns nil and never raises, even under Strict.
]]
function Veron:GetRemaining(x)
	if getmetatable(x) ~= eventDict then
		return nil
	end

	return x:GetRemaining()
end

--[[ How many timers are alive: pending in the heap plus paused. ]]
function Veron:GetClocks()
	return self._N + self._PausedCount
end

-------------------------------------------------------------------
-- Stats, Validate, and Describe
-------------------------------------------------------------------

--[[
	Fills a table with the instance's counters and current sizes and returns
	it. Every value is a plain counter, so this is cheap to call often. Pass
	the same `into` table back each time to avoid allocating a new one; a
	missing or non-table `into` gets a fresh table.
]]
function Veron:GetStats(into)
	local stats = into
	if type(stats) ~= "table" then
		stats = {}
	end

	stats.Name = self.Name
	stats.Destroyed = self._IsDestroyed
	stats.Now = self._Now
	stats.TimeScale = self._TimeScale
	stats.IsPaused = self._IsPaused
	stats.Pending = self._N
	stats.Paused = self._PausedCount
	stats.Chained = self._ChainedCount
	stats.Recurring = self._RecurCount
	stats.HeapSize = self._N
	stats.Clocks = self._N + self._PausedCount
	stats.Updates = self._Updates
	stats.LastDt = self._LastDt
	stats.Dispatched = self._Dispatched
	stats.LastDispatched = self._LastDispatched
	stats.Reentries = self._Reentries
	stats.UpdateDepth = self._UpdateDepth
	stats.Dropped = self._Dropped
	stats.ValveHits = self._ValveHits
	stats.ClampedBackwards = self._ClampedBackwards
	stats.ClampedDt = self._ClampedDt
	stats.Errors = self._Errors
	stats.ErrorsSuppressed = self._ErrorsSuppressed
	stats.Children = self._ChildCount
	return stats
end

--[[
	Walks the whole instance and checks that every invariant still holds: the
	heap property on (due, Id), each handle sitting at the slot it thinks it
	holds, the paused set matching the paused handles, every counter matching
	what is actually reachable, the terminal-handle rules, and the firing
	triple being clear while idle. It is O(n) and allocates only the reason
	string. Returns true when consistent, or false and the first broken
	invariant. It never raises, so tests can call it freely.
]]
function Veron:Validate()
	local due, item, n = self._Due, self._Item, self._N
	if type(n) ~= "number" or n < 0 or n % 1 ~= 0 then
		return false, "_N is not an integer >= 0"
	end

	if #due ~= n then
		return false, "#_Due ~= _N"
	end

	if #item ~= n then
		return false, "#_Item ~= _N"
	end

	local recurCount, chainedCount = 0, 0
	for slot = 1, n do
		local d = due[slot]
		if type(d) ~= "number" or d ~= d or d == HUGE or d == -HUGE then
			return false, "_Due holds a non-finite number"
		end

		local h = item[slot]
		if type(h) ~= "table" or h._HeapIndex ~= slot then
			return false, "_Item[h._HeapIndex] ~= h"
		end

		if h._State ~= PENDING then
			return false, "heap slot holds a non-Pending handle"
		end

		if slot > 1 then
			local parent = slot // 2
			local parentDue = due[parent]
			if d < parentDue or (d == parentDue and h.Id < item[parent].Id) then
				return false, "heap property violated"
			end
		end

		local reason = _validateShape(self, h)
		if reason then
			return false, reason
		end

		if h._IsRecur then
			recurCount += 1
		end

		local below, chainReason = _validateChain(self, h)
		if chainReason then
			return false, chainReason
		end

		chainedCount += below
	end

	local pausedCount = 0
	for h, remaining in self._Paused do
		pausedCount += 1
		if type(h) ~= "table" or h._State ~= PAUSED then
			return false, "_Paused key is not a Paused handle"
		end

		if type(remaining) ~= "number" or remaining ~= remaining or remaining < 0 or remaining == HUGE then
			return false, "_Paused remaining is not a finite number >= 0"
		end

		local reason = _validateShape(self, h)
		if reason then
			return false, reason
		end

		if h._IsRecur then
			recurCount += 1
		end

		local below, chainReason = _validateChain(self, h)
		if chainReason then
			return false, chainReason
		end

		chainedCount += below
	end

	if pausedCount ~= self._PausedCount then
		return false, "_PausedCount ~= count(_Paused)"
	end

	if chainedCount ~= self._ChainedCount then
		return false, "_ChainedCount ~= reachable Chained handles"
	end

	if recurCount ~= self._RecurCount then
		return false, "_RecurCount ~= recurring handles that are Pending or Paused"
	end

	local childCount = 0
	for child in self._Children do
		childCount += 1
		if type(child) ~= "table" or child._Parent ~= self then
			return false, "attached child does not point back at its parent"
		end
	end

	if childCount ~= self._ChildCount then
		return false, "_ChildCount ~= count(_Children)"
	end

	local firing = self._Firing
	if firing ~= false then
		local reason = _validateShape(self, firing)
		if reason then
			return false, reason
		end
	end

	if self._UpdateDepth == 0 and self._SyncDepth == 0 then
		if self._Base ~= false or firing ~= false or self._FiringThread ~= false then
			return false, "firing triple set while idle"
		end
	end

	return true
end

--[[ A short one-line summary of the instance, handy when debugging. ]]
function Veron:Describe()
	return ("Veron<%s now=%.3f pending=%d paused=%d>"):format(self.Name, self._Now, self._N, self._PausedCount)
end

-------------------------------------------------------------------
-- Runtime setters for the policy options
-------------------------------------------------------------------

--[[ Sets how callback errors are handled: "warn", "error", or a function. ]]
function Veron:SetOnError(policy)
	_checkOption(("Veron '%s': "):format(self.Name), "OnError", policy, 4)
	self._OnError = policy
end

--[[ Sets the default catch-up cap for recurring timers on this instance. ]]
function Veron:SetMaxCatchUp(n)
	_checkOption(("Veron '%s': "):format(self.Name), "MaxCatchUp", n, 4)
	self._MaxCatchUp = n
end

--[[ The instance-wide catch-up cap. ]]
function Veron:GetMaxCatchUp()
	return self._MaxCatchUp
end

--[[ Sets the runaway valve limit (arms and repeats allowed in one pass). ]]
function Veron:SetValve(n)
	_checkOption(("Veron '%s': "):format(self.Name), "Valve", n, 4)
	self._Valve = n
end

--[[ Sets the per-frame dt clamp, or false to turn the clamp off. ]]
function Veron:SetMaxDt(x)
	_checkOption(("Veron '%s': "):format(self.Name), "MaxDt", x, 4)
	self._MaxDt = x
end

--[[ Turns strict handle checking on or off (see _resolve). ]]
function Veron:SetStrict(flag)
	_checkOption(("Veron '%s': "):format(self.Name), "Strict", flag, 4)
	self._Strict = flag
end

-------------------------------------------------------------------
-- Clear, Destroy, attachment, and Drive
-------------------------------------------------------------------

--[[
	Stops every timer on the instance, pending, paused and chained alike, then
	empties the containers in one shot. It also clears any attached child
	Verons. Safe to call from inside an update, since the pass checks _N == 0
	at the top of its loop and exits. Returns how many handles were stopped,
	counting those on attached children.
]]
function Veron:Clear()
	local count = 0
	local item = self._Item
	for slot = 1, self._N do
		count += _clearTerminal(self, item[slot])
	end

	local paused = self._Paused
	for h in paused do
		count += _clearTerminal(self, h)
	end

	heapClear(self)
	table.clear(paused)
	self._PausedCount = 0
	self._ChainedCount = 0
	self._RecurCount = 0

	for child in self._Children do
		count += child:Clear()
	end

	return count
end

--[[
	Tears the instance down for good. It marks itself destroyed first, so any
	arm attempted afterward (even from a callback still unwinding) errors
	cleanly, then clears its timers, destroys its attached children, and
	detaches from its parent. Safe to call from inside its own callback, and
	calling it twice does nothing the second time.
]]
function Veron:Destroy()
	if self._IsDestroyed then
		return
	end

	self._IsDestroyed = true
	self:Clear()

	local children = self._Children
	self._Children, self._ChildCount = {}, 0
	for child in children do
		child._Parent = false
		child:Destroy()
	end

	local parent = self._Parent
	if parent then
		self._Parent = false
		parent._Children[self] = nil
		parent._ChildCount -= 1
	end
end

--[[ Whether Destroy has been called on this instance. ]]
function Veron:IsDestroyed()
	return self._IsDestroyed
end

--[[
	Makes `child` a child Veron of self. Rejects a destroyed instance or
	child, a non-Veron, attaching to itself, a child that is already attached
	somewhere, and any attachment that would form a cycle. Shared by Attach
	and Drive, so it takes a `level` to aim the error at the real caller.
]]
_attach = function(self, child, level)
	if self._IsDestroyed then
		error(("Veron '%s': destroyed"):format(self.Name), level)
	end

	if getmetatable(child) ~= veronDict then
		error(("Veron '%s': Attach expects a Veron, got %s"):format(self.Name, typeof(child)), level)
	end

	if child == self then
		error(("Veron '%s': cannot attach itself"):format(self.Name), level)
	end

	if child._IsDestroyed then
		error(("Veron '%s': '%s' is destroyed"):format(self.Name, child.Name), level)
	end

	if child._Parent then
		error(
			("Veron '%s': '%s' is already attached to '%s'"):format(self.Name, child.Name, child._Parent.Name),
			level
		)
	end

	local ancestor = self._Parent
	while ancestor do
		if ancestor == child then
			error(("Veron '%s': Attach would create a cycle"):format(self.Name), level)
		end

		ancestor = ancestor._Parent
	end

	child._Parent = self
	self._Children[child] = true
	self._ChildCount += 1
end

--[[ Attaches `child` as a child Veron of this one. ]]
function Veron:Attach(child)
	_attach(self, child, 4)
end

--[[
	Detaches `child` from this instance. Returns true if it was a child,
	false if it was not (so calling it on an unrelated Veron is harmless).
]]
function Veron:Detach(child)
	if child == nil or not self._Children[child] then
		return false
	end

	self._Children[child] = nil
	self._ChildCount -= 1
	child._Parent = false
	return true
end

--[[ A fresh array of the attached children. Allocates; not for per-frame use. ]]
function Veron:GetChildren()
	local list = {}
	for child in self._Children do
		list[#list + 1] = child
	end

	return list
end

--[[
	Sets up one Veron to drive another: it arms a recurring timer on self that
	calls child:Update(period) every period, and stops itself once the child
	is destroyed. It always attaches the child too, so a mutual Drive is
	refused as a cycle. `uncapped` defaults to true here, so the child acts as
	a lossless sub-clock that never drops ticks after a long frame.
]]
function Veron:Drive(child, period, uncapped)
	if getmetatable(child) ~= veronDict or child == self then
		error(("Veron '%s': Drive expects another Veron"):format(self.Name), 3)
	end

	local seconds = _validateArgs(self, NOOP, period, true, 4)
	if uncapped == nil then
		uncapped = true
	end

	local maxCatchUp = _validateUncapped(uncapped, 4) -- last check that can raise
	_attach(self, child, 4) -- always attach; may raise, and nothing is armed yet

	local h
	--[[ The recurring body: tick the child, or stop once it is gone. ]]
	local function pump()
		if child._IsDestroyed then
			h:Stop()
			return
		end

		child:Update(seconds)
	end

	h = _newEvent(self, pump, seconds, true, PENDING, maxCatchUp)
	heapPush(self, h, _clockOf(self) + seconds)
	return h
end

-------------------------------------------------------------------
-- Private operations the VeronEvent handle forwards to. Each takes the
-- handle first. Each checks for a terminal handle, and for one already
-- committed to a forced fire, before it looks at its arguments, so those
-- states are always a quiet no-op rather than an error.
-------------------------------------------------------------------

--[[ Stops a handle; the plain forward behind VeronEvent:Stop. ]]
function Veron:_Stop(h)
	_stopTerminal(self, h)
end

--[[
	Pauses a handle. A pending timer is pulled from the heap and parked in the
	paused set with its remaining time frozen. A chained child is marked so it
	arrives paused when its parent fires. A paused, terminal, or
	already-committed timer is left as is.
]]
function Veron:_Pause(h)
	local state = h._State
	if state == PENDING then
		if h._Flags >= STOP_ON_FIRE then
			return h -- already owes a forced fire; leave it alone
		end

		local remaining = self._Due[h._HeapIndex] - self._Now
		if remaining < 0 then
			remaining = 0
		end

		heapRemove(self, h)
		h._State = PAUSED
		self._Paused[h] = remaining
		self._PausedCount += 1
	elseif state == CHAINED then
		if h._Flags % 2 == 0 then
			h._Flags += PWC
		end
	end

	return h
end

--[[
	Resumes a handle. A paused timer goes back into the heap due at now plus
	its frozen remaining. A pending timer that was set to re-pause after a
	deferred complete has that flag cleared, so it fires and then keeps
	running. A chained child has its pause mark cleared.
]]
function Veron:_Resume(h)
	local state = h._State
	if state == PAUSED then
		local remaining = self._Paused[h]
		self._Paused[h] = nil
		self._PausedCount -= 1
		h._State = PENDING
		heapPush(self, h, self._Now + remaining)
	elseif state == PENDING then
		if h._Flags >= REPAUSE then
			h._Flags -= REPAUSE
		end
	elseif state == CHAINED then
		if h._Flags % 2 == 1 then
			h._Flags -= PWC
		end
	end

	return h
end

--[[ Flips a handle between running and paused: pause it if it is live,
     resume it if it is paused, and flip the pause mark on a chained child. ]]
function Veron:_Toggle(h)
	local state = h._State
	if state == PENDING then
		self:_Pause(h) -- if it is committed, _Pause is already a no-op
	elseif state == PAUSED then
		self:_Resume(h)
	elseif state == CHAINED then
		if h._Flags % 2 == 1 then
			h._Flags -= PWC
		else
			h._Flags += PWC
		end
	end

	return h
end

--[[
	Re-arms a handle. This is the only way to bring a fired timer back: it is
	set pending again at now plus its period, and given a fresh id. The fresh
	id matters because the valve counts arms by "id newer than the pass
	start", so restarting a timer from inside its own callback reads as a
	nested arm and is bounded, not an infinite loop. A pending or paused timer
	is instead reset and resumed. A chained, stopped, or already-committed
	handle, or one whose owner is destroyed, does nothing.
]]
function Veron:_Restart(h)
	local state = h._State
	if state == STOPPED or state == CHAINED or self._IsDestroyed then
		return h
	end

	if state == FIRED then
		local id = self._NextId + 1
		self._NextId = id
		h.Id = id
		h._State = PENDING
		if h._IsRecur then
			self._RecurCount += 1 -- a recurring stopped on fire comes back recurring
		end

		heapPush(self, h, self._Now + h._Period) -- explicit re-arm, measured from now
		return h
	end

	if h._Flags >= STOP_ON_FIRE then
		return h -- already owes a forced fire; leave it alone
	end

	self:_Reset(h)
	return self:_Resume(h)
end

--[[
	Restarts a timer's countdown: it becomes due a full period from now. A
	terminal or committed handle does nothing. A chained child does nothing
	either, since its delay is measured from when its parent fires.
]]
function Veron:_Reset(h)
	local state = h._State
	if state >= FIRED or h._Flags >= STOP_ON_FIRE then
		return h
	end

	if state == PENDING then
		heapUpdate(self, h, self._Now + h._Period)
	elseif state == PAUSED then
		self._Paused[h] = h._Period
	end

	return h
end

--[[
	Retimes a running timer to a new total period while keeping how far
	through it already is. If a timer is halfway to firing and you adjust it to
	20 seconds, it will now fire in 10. The terminal and committed check runs
	before the argument is validated, so completing then adjusting a dead
	handle is a quiet no-op even with a bad argument. A zero period is never
	divided by.
]]
function Veron:_Adjust(h, newTotalArg)
	local state = h._State
	if state >= FIRED or h._Flags >= STOP_ON_FIRE then
		return h
	end

	local x = tonumber(newTotalArg)
	if type(x) ~= "number" or x ~= x or x == HUGE or x <= 0 then
		error("expected `newTotal` greater than zero", 3)
	end

	local period = h._Period
	if state == PENDING then
		local now = self._Now
		local frac = if period > 0 then math.clamp((self._Due[h._HeapIndex] - now) / period, 0, 1) else 1
		heapUpdate(self, h, now + frac * x)
	elseif state == PAUSED then
		local frac = if period > 0 then math.clamp(self._Paused[h] / period, 0, 1) else 1
		self._Paused[h] = frac * x
	end

	h._Period = x -- for a chained child only the stored delay changes
	return h
end

--[[
	Changes the period used by future arms only; it does not re-key the timer
	that is already ticking. A recurring period must be greater than zero, a
	one-shot delay may be zero or more. Terminal and committed handles are a
	no-op checked first.
]]
function Veron:_SetPeriod(h, periodArg)
	local state = h._State
	if state >= FIRED or h._Flags >= STOP_ON_FIRE then
		return h
	end

	local period = tonumber(periodArg)
	if h._IsRecur then
		if type(period) ~= "number" or period ~= period or period == HUGE or period <= 0 then
			error("expected `newPeriod` greater than zero", 3)
		end
	elseif type(period) ~= "number" or period ~= period or period == HUGE or period < 0 then
		error("expected `newPeriod` of zero or greater", 3)
	end

	h._Period = period
	return h
end

--[[
	Sets how long until the timer next fires, measured from now, without
	changing its period. Terminal and committed handles are a no-op checked
	before the argument is validated.
]]
function Veron:_SetRemaining(h, remainingArg)
	local state = h._State
	if state >= FIRED or h._Flags >= STOP_ON_FIRE then
		return h
	end

	local remaining = tonumber(remainingArg)
	if type(remaining) ~= "number" or remaining ~= remaining or remaining == HUGE or remaining < 0 then
		error("expected `remaining` of zero or greater", 3)
	end

	if state == PENDING then
		heapUpdate(self, h, self._Now + remaining)
	elseif state == PAUSED then
		self._Paused[h] = remaining
	else
		h._Period = remaining -- chained: this is its delay from the parent's fire
	end

	return h
end

--[[
	Seconds until the handle next fires: for a pending timer, the gap from now
	to its due time (never negative); for a paused one, its frozen remaining;
	for a chained one, its delay; for anything terminal, zero.
]]
function Veron:_GetRemaining(h)
	local state = h._State
	if state == PENDING then
		local remaining = self._Due[h._HeapIndex] - self._Now
		if remaining < 0 then
			return 0
		end

		return remaining
	elseif state == PAUSED then
		return self._Paused[h]
	elseif state == CHAINED then
		return h._Period
	end

	return 0
end

--[[
	Overrides the catch-up behaviour for one recurring timer. A one-shot or
	terminal handle is a no-op checked first. The modes are "cap" with a count
	(nil takes a snapshot of the instance cap), "all" for uncapped, "drop" to
	fire at most once per pass, and "inherit" to fall back to the instance cap.
]]
function Veron:_SetCatchUp(h, mode, n)
	if not h._IsRecur or h._State >= FIRED then
		return h
	end

	local value
	if mode == "inherit" then
		value = false
	elseif mode == "all" then
		value = HUGE
	elseif mode == "drop" then
		value = 1
	elseif mode == "cap" then
		value = if n == nil then self._MaxCatchUp else n
		if type(value) ~= "number" or value ~= value or value < 1 or value % 1 ~= 0 or value == HUGE then
			error(("Veron '%s': option 'MaxCatchUp' expects an integer >= 1, got %s"):format(self.Name, tostring(n)), 3)
		end
	else
		error(("Veron '%s': option 'CatchUp' expects cap, all, drop or inherit"):format(self.Name), 3)
	end

	h._MaxCatchUp = value
	return h
end

-------------------------------------------------------------------
-- After-chains: run fn once, some time after another timer fires
-------------------------------------------------------------------

--[[
	Chains a child to run `delay` seconds after `parent` fires. Normally the
	child is registered on the parent and armed off the parent's ideal due time
	when the parent fires. If the parent has already fired, the child is armed
	right away from the caller's clock. If the parent is stopped, or the
	instance is destroyed, it returns a child that is born stopped without even
	validating the arguments. A recurring parent cannot be chained.
]]
function Veron:_After(parent, fn, delayArg)
	local state = parent._State
	if state == STOPPED or self._IsDestroyed then
		return _newEvent(self, NOOP, 0, false, STOPPED, false)
	end

	if parent._IsRecur then
		error("cannot chain a recurring event", 3)
	end

	local period = _validateArgs(self, fn, delayArg, false, 4)
	if state == FIRED then
		local child = _newEvent(self, fn, period, false, PENDING, false)
		heapPush(self, child, _clockOf(self) + period)
		return child
	end

	local child = _newEvent(self, fn, period, false, CHAINED, false)
	local list = parent._Chained
	if not list then
		list = {}
		parent._Chained = list -- allocated only when a handle first gets a child
	end

	list[#list + 1] = child -- kept in the order children were added
	self._ChainedCount += 1
	return child
end

-------------------------------------------------------------------
-- Complete: deferred (next pass) and CompleteNow (right away)
-------------------------------------------------------------------

--[[
	Deferred force-complete. It re-keys the handle to the caller's now so it
	fires on the next pass rather than at its scheduled time. With opts.Stop a
	recurring is flagged to stop after that fire; a paused recurring without
	Stop is flagged to fire once and then park itself paused again. A chained
	child is detached and armed; its entry stays in the parent's list, which
	skips it from then on. Returns false for a terminal handle, or for the
	timer that is firing on this very thread right now.
]]
function Veron:_Complete(h, opts, level)
	_checkOpts(self, opts, COMPLETE_OPTS, "Complete", level + 1)
	local state = h._State
	if state >= FIRED or (self._Firing == h and running() == self._FiringThread) then
		return false
	end

	local stop = opts ~= nil and opts.Stop == true
	local now = self._Now
	if stop and h._IsRecur then
		if h._Flags >= REPAUSE then
			h._Flags -= REPAUSE
		end

		if h._Flags % 8 < 4 then
			h._Flags += STOP_ON_FIRE
		end
	end

	if state == PENDING then
		heapUpdate(self, h, now)
	elseif state == PAUSED then
		self._Paused[h] = nil
		self._PausedCount -= 1
		if h._IsRecur and not stop then
			h._Flags += REPAUSE -- fire once, then go back to paused with a full period
		end

		h._State = PENDING
		heapPush(self, h, now)
	else -- chained: detach it; the parent's list keeps the slot but skips it
		self._ChainedCount -= 1
		if h._Flags % 2 == 1 then
			h._Flags -= PWC
		end

		h._State = PENDING
		heapPush(self, h, now)
	end

	return true
end

--[[
	The state change and the callback for a synchronous complete. _CompleteNow
	runs this under a protected call. `d` is the caller's now. A one-shot, or a
	recurring being stopped, leaves its container and fires as a one-shot. A
	plain recurring restarts its phase from now and fires. A paused recurring,
	or one told to re-pause, is parked paused and fires from there.
]]
local function _completeNowBody(self, h, state, stop, d)
	if not h._IsRecur or stop then
		-- one-shot, or recurring with Stop: leave the container, fire as a one-shot
		if state == PENDING then
			heapRemove(self, h)
		elseif state == PAUSED then
			self._Paused[h] = nil
			self._PausedCount -= 1
		else
			self._ChainedCount -= 1
		end

		_fireOneShot(self, h, d) -- marks it Fired and arms its children before firing
		return
	end

	if state == PENDING and h._Flags < REPAUSE then
		-- recurring Pending: the phase restarts from now
		heapUpdate(self, h, d + h._Period)
		self._Base, self._Firing = d, h
		_runCallback(self, h, h._Fn)
		return
	end

	-- paused recurring, or one flagged to re-pause: park it, and it stays paused
	if h._HeapIndex > 0 then
		heapRemove(self, h)
	end

	if h._Flags >= REPAUSE then
		h._Flags -= REPAUSE
	end

	if state ~= PAUSED then
		self._PausedCount += 1
	end

	h._State = PAUSED
	self._Paused[h] = h._Period
	self._Base, self._Firing = d, h
	_runCallback(self, h, h._Fn)
end

--[[
	Synchronous force-complete: runs the callback before the call returns. It
	returns false, and does nothing, when the handle is terminal, when it is
	the timer firing on this same thread, when it is already being completed
	further up the stack (which stops a mutual A completes B completes A loop),
	or when synchronous completes have nested past their cap (which is
	diagnosed). The state change and the callback run under a protected call
	with cleanup that always happens, so it returns true even if the callback
	itself errored.
]]
function Veron:_CompleteNow(h, opts, level)
	_checkOpts(self, opts, COMPLETE_OPTS, "CompleteNow", level + 1)
	local state = h._State
	if state >= FIRED or (self._Firing == h and running() == self._FiringThread) then
		return false
	end

	if h._Flags % 4 >= 2 then
		return false -- already mid-complete higher up the stack; refuse the loop
	end

	if self._SyncDepth >= MAX_SYNC_DEPTH then
		_diagnose(
			self,
			("CompleteNow nested deeper than %d; event #%d refused"):format(MAX_SYNC_DEPTH, h.Id),
			h
		)
		return false
	end

	local stop = (opts ~= nil and opts.Stop == true) or h._Flags % 8 >= 4
	h._Flags += COMPLETING
	self._SyncDepth += 1
	local savedBase, savedFiring, savedThread = self._Base, self._Firing, self._FiringThread
	self._FiringThread = running()
	local d = self._Now -- explicit op, measured from now

	local ok, result = pcall(_completeNowBody, self, h, state, stop, d)

	if h._Flags % 4 >= 2 then
		h._Flags -= COMPLETING -- unless a one-shot fire already cleared every flag
	end

	self._SyncDepth -= 1
	self._Base, self._Firing, self._FiringThread = savedBase, savedFiring, savedThread

	if self._UpdateDepth == 0 and self._SyncDepth == 0 then
		local errored = self._Errored
		if errored then
			self._Errored = false
			if ok then
				error(errored, 0) -- "error" policy: re-raise once, at the outermost exit
			end
		end
	end

	if not ok then
		error(("Veron '%s': internal fault during CompleteNow: %s"):format(self.Name, tostring(result)), 0)
	end

	return true
end

return Veron

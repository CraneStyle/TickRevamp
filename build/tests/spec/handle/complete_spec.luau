--!nonstrict
--[[
	complete_spec — Complete (deferred, = ForceEventComplete) and CompleteNow
	(synchronous): docs/DESIGN.md §4.7, the COMMITTED rule of §4.4, the R-D
	thread-bound own-callback guard, the §5 Complete/CompleteNow rows;
	§9 handle/complete_spec row — 23 tests, names verbatim.

	Every instance runs through Oracle.wrap. Timing uses dyadic numbers.
	Callbacks only RECORD what they observe (a failing assertion inside a
	callback would be swallowed as a callback error); the test asserts
	outside. Yield tests wrap Update in a coroutine.

	Modules are required lazily so this file loads before the core exists.
]]

local Veron, Env, Oracle

local function _load()
	if Veron then
		return
	end
	Veron = require("../../../src/Veron")
	Env = require("../../../src/Veron/Env")
	Oracle = require("../../support/oracle")
end

local function _noop() end

local function _newVeron(cfg)
	_load()
	return Oracle.wrap(Veron.new(cfg or { Name = "T" }))
end

--[[
	A counting callback: `box.fn` bumps `box.count`.
]]
local function _counter()
	local box = { count = 0 }
	box.fn = function()
		box.count += 1
	end
	return box
end

--[[
	An ordered log: `mark(tag)` returns a callback that appends `tag`.
]]
local function _logger()
	local log = {}
	local function mark(tag)
		return function()
			log[#log + 1] = tag
		end
	end
	return log, mark
end

--[[
	Runs `body(captured)` with Env.Warn swapped for a collector; restores the
	seam even when the body raises, then re-raises.
]]
local function _withWarnCapture(body)
	_load()
	local captured = {}
	local restore = Env.SetWarn(function(message)
		captured[#captured + 1] = tostring(message)
	end)
	local ok, err = pcall(body, captured)
	restore()
	if not ok then
		error(err, 0)
	end
	return captured
end

local function _contains(text, needle)
	return tostring(text):find(needle, 1, true) ~= nil
end

return function(t)
	t.test("deferred re-keys to now and fires next update in order", function()
		-- §4.7 `_Complete` PENDING: heapUpdate(h, now); fires on the next pass in (due, Id) order (F3)
		local s = _newVeron()
		local log, mark = _logger()
		local a = s:Delay(mark("a"), 1)
		local b = s:Delay(mark("b"), 1 / 2)
		local c = s:Delay(mark("c"), 2)
		s:Update(1 / 4) -- now 0.25
		t.eq(c:Complete(), true)
		t.eq(a:Complete(), true)
		t.eq(c:GetRemaining(), 0)
		t.eq(a:GetRemaining(), 0)
		t.eq(#log, 0, "deferred: nothing fires at Complete")
		t.eq(a:GetState(), "Pending")
		t.eq(c:GetState(), "Pending")
		s:Update(0)
		t.eq(table.concat(log, ","), "a,c", "(due, Id) order: a before c")
		t.eq(b:GetState(), "Pending", "b at 0.5 is untouched")
		t.eq(b:GetRemaining(), 1 / 4)
		t.eq(s:GetClocks(), 1)
	end)

	t.test("completes a non-root entry", function()
		-- §4.7 (S-01): heapUpdate on a non-root slot sifts it to the root
		local s = _newVeron()
		local log, mark = _logger()
		local a = s:Delay(mark("a"), 1 / 4)
		local b = s:Delay(mark("b"), 1 / 2)
		local c = s:Delay(mark("c"), 3 / 4)
		t.eq(rawget(c, "_HeapIndex") ~= 1, true, "c is not at the root")
		t.eq(s:Complete(c), true)
		s:Update(0)
		t.eq(table.concat(log, ","), "c")
		t.eq(a:GetState(), "Pending")
		t.eq(b:GetState(), "Pending")
		t.eq(a:GetRemaining(), 1 / 4)
		s:Update(1)
		t.eq(table.concat(log, ","), "c,a,b")
	end)

	t.test("Complete from inside a pass on a later entry fires once this pass", function()
		-- §4.7 (F5): `<= now` fires later in the SAME pass, exactly once
		local s = _newVeron()
		local later = _counter()
		local seen = {}
		local b
		local a = s:Delay(function()
			seen.result = b:Complete()
		end, 1 / 4)
		b = s:Delay(later.fn, 1)
		s:Update(1 / 4)
		t.eq(seen.result, true)
		t.eq(later.count, 1, "fires later in the same pass")
		t.eq(b:GetState(), "Fired")
		s:Update(2)
		t.eq(later.count, 1)
		t.eq(s:GetStats().Dispatched, 2)
	end)

	t.test("recurring fires once then re-arms from now", function()
		-- §4.7: plain recurring → fires then re-arms at now + period through the normal re-key
		local s = _newVeron()
		local box = _counter()
		local r = s:Recur(box.fn, 1)
		s:Update(1 / 4) -- now 0.25
		t.eq(r:Complete(), true)
		t.eq(box.count, 0)
		s:Update(0)
		t.eq(box.count, 1)
		t.eq(r:GetState(), "Pending")
		t.eq(r:IsRecurring(), true)
		t.eq(r:GetRemaining(), 1, "a full period from the completion time")
		s:Update(1 - 1 / 64)
		t.eq(box.count, 1)
		s:Update(1 / 64)
		t.eq(box.count, 2)
		t.eq(s:GetStats().Recurring, 1)
	end)

	t.test("opts.Stop ends a recurring and Recurring stat drops", function()
		-- §4.7: STOP_ON_FIRE → `_fireOneShot` (Fired, no re-arm, _RecurCount -= 1)
		local s = _newVeron()
		local box = _counter()
		local r = s:Recur(box.fn, 1)
		t.eq(s:GetStats().Recurring, 1)
		s:Update(1 / 4)
		t.eq(r:Complete({ Stop = true }), true)
		t.eq(_contains(r:Describe(), "+stop"), true, r:Describe())
		t.eq(s:GetStats().Recurring, 1, "still recurring until the forced fire")
		s:Update(0)
		t.eq(box.count, 1)
		t.eq(r:GetState(), "Fired")
		t.eq(r:IsRecurring(), true, "the handle remembers it was recurring")
		t.eq(s:GetStats().Recurring, 0)
		t.eq(s:GetClocks(), 0)
		s:Update(5)
		t.eq(box.count, 1)

		-- the instance form takes the same options
		local box2 = _counter()
		local r2 = s:Recur(box2.fn, 1)
		t.eq(s:Complete(r2, { Stop = true }), true)
		s:Update(0)
		t.eq(box2.count, 1)
		t.eq(r2:GetState(), "Fired")
		t.eq(s:GetStats().Recurring, 0)
	end)

	t.test("paused recurring completes and stays paused with full period", function()
		-- §4.7 PAUSED case (D7): REPAUSE → `_fireRepause` re-parks with remaining = period
		local s = _newVeron()
		local box = _counter()
		local r = s:Recur(box.fn, 1)
		s:Update(1 / 4)
		r:Pause()
		t.eq(r:GetRemaining(), 3 / 4)
		t.eq(r:Complete(), true)
		t.eq(r:GetState(), "Pending", "transient Pending until the forced fire")
		t.eq(r:IsPaused(), true, "logically still paused")
		t.eq(_contains(r:Describe(), "+repause"), true, r:Describe())
		s:Update(0)
		t.eq(box.count, 1)
		t.eq(r:GetState(), "Paused")
		t.eq(r:IsPaused(), true)
		t.eq(r:GetRemaining(), 1, "a full period, frozen")
		t.eq(s:GetStats().Paused, 1)
		t.eq(s:GetStats().Recurring, 1)
		s:Update(5)
		t.eq(box.count, 1, "paused: nothing accumulates")
		r:Resume()
		s:Update(1)
		t.eq(box.count, 2)
	end)

	t.test("Resume after a deferred Complete on a Paused recurring is honoured", function()
		-- §4.4 `_Resume` on Pending + REPAUSE: clears REPAUSE; fires, then runs on
		local s = _newVeron()
		local box = _counter()
		local r = s:Recur(box.fn, 1)
		s:Update(1 / 4)
		r:Pause()
		t.eq(r:Complete(), true)
		t.eq(r:Resume(), r)
		t.eq(r:IsPaused(), false)
		t.eq(r:GetState(), "Pending")
		t.eq(r:GetRemaining(), 0)
		s:Update(0)
		t.eq(box.count, 1)
		t.eq(r:GetState(), "Pending", "runs on instead of re-parking")
		t.eq(r:GetRemaining(), 1)
		s:Update(1)
		t.eq(box.count, 2)
	end)

	t.test("Reset after a deferred Complete on a Paused recurring does not resume it", function()
		-- §4.4 COMMITTED (REPAUSE): Reset/Adjust/SetRemaining/SetPeriod/Toggle/Restart are no-ops
		local s = _newVeron()
		local box = _counter()
		local r = s:Recur(box.fn, 1)
		s:Update(1 / 4)
		r:Pause()
		t.eq(r:Complete(), true)
		t.eq(r:Reset(), r)
		t.eq(r:IsPaused(), true)
		t.eq(r:GetState(), "Pending")
		t.eq(r:GetRemaining(), 0, "Reset was a no-op: still keyed at now")
		t.eq(r:Adjust(4), r)
		t.eq(r:GetPeriod(), 1)
		t.eq(r:GetRemaining(), 0)
		t.eq(r:SetRemaining(2), r)
		t.eq(r:GetRemaining(), 0)
		t.eq(r:SetPeriod(3), r)
		t.eq(r:GetPeriod(), 1)
		t.eq(r:Toggle(), r)
		t.eq(r:GetState(), "Pending")
		t.eq(r:Restart(), r)
		t.eq(r:GetRemaining(), 0)
		t.eq(r:IsPaused(), true)
		s:Update(0)
		t.eq(box.count, 1)
		t.eq(r:GetState(), "Paused")
		t.eq(r:GetRemaining(), 1)
		s:Update(5)
		t.eq(box.count, 1)
	end)

	t.test("Pause after a deferred Complete is a no-op until the fire", function()
		-- §4.4 `_Pause` on Pending COMMITTED: no-op (REPAUSE re-parks itself after the forced fire)
		local s = _newVeron()
		local box = _counter()
		local r = s:Recur(box.fn, 1)
		s:Update(1 / 4)
		r:Pause()
		t.eq(r:Complete(), true)
		t.eq(r:Pause(), r)
		t.eq(r:GetState(), "Pending")
		t.eq(s:GetStats().Paused, 0)
		t.eq(s:GetStats().Pending, 1)
		s:Update(0)
		t.eq(box.count, 1, "the forced fire happened")
		t.eq(r:GetState(), "Paused", "re-parked by the fire")
		t.eq(s:GetStats().Paused, 1)
		t.eq(r:Pause(), r)
		t.eq(r:GetState(), "Paused")
		t.eq(r:GetRemaining(), 1)
		s:Update(5)
		t.eq(box.count, 1)
	end)

	t.test("Pause/Reset after Complete{Stop=true} keep the forced final fire", function()
		-- §4.4 COMMITTED (STOP_ON_FIRE, F6): every retime/Pause/Resume/Toggle is a no-op
		local s = _newVeron()
		local box = _counter()
		local r = s:Recur(box.fn, 1)
		s:Update(1 / 4)
		t.eq(r:Complete({ Stop = true }), true)
		t.eq(r:Pause(), r)
		t.eq(r:GetState(), "Pending")
		t.eq(r:IsPaused(), false)
		t.eq(r:Reset(), r)
		t.eq(r:GetRemaining(), 0)
		t.eq(r:Resume(), r)
		t.eq(r:GetRemaining(), 0)
		t.eq(r:Toggle(), r)
		t.eq(r:GetState(), "Pending")
		t.eq(r:Restart(), r)
		t.eq(r:GetRemaining(), 0)
		s:Update(0)
		t.eq(box.count, 1, "the forced final fire")
		t.eq(r:GetState(), "Fired")
		t.eq(s:GetStats().Recurring, 0)
		s:Update(5)
		t.eq(box.count, 1)
	end)

	t.test("chained completes detached", function()
		-- §4.7 CHAINED case: Complete → detached Pending @ now; CompleteNow → detach, fire
		local s = _newVeron()
		local child, child2 = _counter(), _counter()
		local p = s:Delay(_noop, 1)
		local c = p:After(child.fn, 1 / 4)
		t.eq(c:Complete(), true)
		t.eq(c:GetState(), "Pending")
		t.eq(s:GetStats().Chained, 0)
		t.eq(s:GetStats().Pending, 2)
		s:Update(0)
		t.eq(child.count, 1)
		t.eq(c:GetState(), "Fired")

		local p2 = s:Delay(_noop, 1)
		local c2 = p2:After(child2.fn, 1 / 4)
		t.eq(c2:CompleteNow(), true)
		t.eq(child2.count, 1, "synchronous")
		t.eq(c2:GetState(), "Fired")
		t.eq(s:GetStats().Chained, 0)

		s:Update(1) -- both parents fire; neither re-arms its detached child
		t.eq(p:GetState(), "Fired")
		t.eq(p2:GetState(), "Fired")
		t.eq(child.count, 1)
		t.eq(child2.count, 1)
	end)

	t.test("Complete from own callback returns false", function()
		-- §4.7 (F6): `_Firing == h and running() == _FiringThread` → false
		local s = _newVeron()
		local seen = { count = 0 }
		local h
		h = s:Delay(function()
			seen.oneShot = h:Complete()
			seen.oneShotInstance = s:Complete(h)
		end, 1 / 4)
		s:Update(1 / 4)
		t.eq(seen.oneShot, false)
		t.eq(seen.oneShotInstance, false)
		t.eq(h:GetState(), "Fired")

		local r
		r = s:Recur(function()
			seen.count += 1
			seen.recurring = r:Complete()
		end, 1 / 4)
		s:Update(1 / 4)
		t.eq(seen.recurring, false)
		t.eq(seen.count, 1, "no extra fire")
		t.eq(r:GetState(), "Pending")
		t.eq(r:GetRemaining(), 1 / 4)
	end)

	t.test("top-level Complete on a yielded recurring returns true and fires", function()
		-- R-D: the guard is thread-bound; the main thread is not the firing thread
		local captured = _withWarnCapture(function()
			local s = _newVeron()
			local count = 0
			local r = s:Recur(function()
				count += 1
				if count == 1 then
					coroutine.yield()
				end
			end, 1)
			local co = coroutine.create(function()
				s:Update(1)
			end)
			local ok, err = coroutine.resume(co)
			t.eq(ok, true, tostring(err))
			t.eq(coroutine.status(co), "suspended")
			t.eq(count, 1)
			t.eq(s:IsUpdating(), true)
			t.eq(r:Complete(), true, "not the firing thread: honoured")
			t.eq(r:GetRemaining(), 0)
			s:Update(0)
			t.eq(count, 2, "fired from the overlapped pass")
			t.eq(coroutine.resume(co), true)
			t.eq(coroutine.status(co), "dead")
			t.eq(s:IsUpdating(), false)
			t.eq(s:GetBase(), false)
			t.eq(s:Validate(), true)
			t.eq(r:GetState(), "Pending")
			t.eq(s:GetStats().Reentries, 1)
		end)
		t.eq(#captured >= 1, true, "the re-entry was warned once")
	end)

	t.test("CompleteNow inside own callback returns false", function()
		-- §4.7 `_CompleteNow`: own callback (thread-bound) or COMPLETING → false
		local s = _newVeron()
		local seen = { count = 0 }
		local h
		h = s:Delay(function()
			seen.oneShot = h:CompleteNow()
		end, 1 / 4)
		s:Update(1 / 4)
		t.eq(seen.oneShot, false)
		t.eq(h:GetState(), "Fired")

		local r
		r = s:Recur(function()
			seen.count += 1
			seen.recurring = r:CompleteNow()
		end, 1 / 4)
		s:Update(1 / 4)
		t.eq(seen.recurring, false)
		t.eq(seen.count, 1)
		t.eq(r:GetState(), "Pending")

		-- from inside its own CompleteNow callback as well
		local r2
		r2 = s:Recur(function()
			seen.nested = r2:CompleteNow()
		end, 1)
		t.eq(r2:CompleteNow(), true)
		t.eq(seen.nested, false)
		t.eq(s:Validate(), true)
	end)

	t.test("nested Update inside a CompleteNow callback keeps the base and the own-callback guard", function()
		-- §4.7 tail: a nested Update sees _SyncDepth > 0 and RESTORES the triple (F5)
		local s = _newVeron()
		local inner = {}
		local seen = { count = 0 }
		local x = s:Delay(function()
			inner.base = s:GetBase()
			inner.updating = s:IsUpdating()
		end, 1 / 8)
		local r
		r = s:Recur(function()
			seen.count += 1
			seen.baseBefore = s:GetBase()
			seen.nowBefore = s:Now()
			s:Update(1 / 4) -- nested pass: x fires
			seen.baseAfter = s:GetBase()
			seen.nowAfter = s:Now()
			seen.completeInside = r:Complete()
			seen.completeNowInside = r:CompleteNow()
			seen.validate = s:Validate()
			seen.updating = s:IsUpdating()
		end, 1)
		t.eq(r:CompleteNow(), true)
		t.eq(seen.count, 1)
		t.eq(seen.baseBefore, 0, "d = now at the CompleteNow call")
		t.eq(seen.nowBefore, 0)
		t.eq(inner.base, 1 / 8, "the nested pass had its own base")
		t.eq(inner.updating, true)
		t.eq(x:GetState(), "Fired")
		t.eq(seen.nowAfter, 1 / 4)
		t.eq(seen.baseAfter, 0, "the triple was restored, not cleared")
		t.eq(seen.completeInside, false, "the own-callback guard still holds")
		t.eq(seen.completeNowInside, false)
		t.eq(seen.validate, true, "Validate holds inside the callback")
		t.eq(seen.updating, false)
		t.eq(r:GetState(), "Pending")
		t.eq(r:GetRemaining(), 3 / 4, "re-keyed at d + period = 1, now 0.25")
		t.eq(s:GetBase(), false)
		t.eq(s:IsUpdating(), false)
		t.eq(s:GetStats().Reentries, 0, "a nested Update at depth 0 is not a re-entry")
		t.eq(s:Validate(), true)
	end)

	t.test("mutual CompleteNow A->B->A stops at the COMPLETING flag", function()
		-- §4.7: COMPLETING set → false (F6, mutual A→B→A)
		local s = _newVeron()
		local seen = { countA = 0, countB = 0 }
		local a, b
		a = s:Recur(function()
			seen.countA += 1
			seen.resA = b:CompleteNow()
		end, 1)
		b = s:Recur(function()
			seen.countB += 1
			seen.resB = a:CompleteNow()
		end, 1)
		t.eq(a:CompleteNow(), true)
		t.eq(seen.countA, 1)
		t.eq(seen.countB, 1)
		t.eq(seen.resA, true, "B was not completing")
		t.eq(seen.resB, false, "A was still completing")
		t.eq(a:GetState(), "Pending")
		t.eq(b:GetState(), "Pending")
		t.eq(s:GetBase(), false)
		t.eq(s:IsUpdating(), false)
		t.eq(s:Validate(), true)
	end)

	t.test("CompleteNow nesting beyond 8 is refused via OnError", function()
		-- §4.7: `_SyncDepth >= 8` → `_diagnose(...)` + false
		_load()
		local messages = {}
		local s = _newVeron({
			Name = "T",
			OnError = function(message, handle)
				messages[#messages + 1] = { message = message, handle = handle }
			end,
		})
		local fires = 0
		local handles = {}
		local results = {}
		for index = 1, 9 do
			handles[index] = s:Recur(function()
				fires += 1
				local nextHandle = handles[index + 1]
				if nextHandle then
					results[index] = nextHandle:CompleteNow()
				end
			end, 1)
		end
		t.eq(handles[1]:CompleteNow(), true)
		t.eq(fires, 8, "depths 1..8 fire; the 9th is refused")
		for index = 1, 7 do
			t.eq(results[index], true, "depth " .. index)
		end
		t.eq(results[8], false, "refused at the cap")
		t.eq(#messages, 1, "exactly one diagnostic")
		t.eq(type(messages[1].message), "string")
		t.eq(handles[9]:GetState(), "Pending")
		t.eq(handles[9]:GetRemaining(), 1, "the refused handle was not touched")
		t.eq(s:GetStats().Errors, 0, "a diagnostic is not a callback error")
		t.eq(s:Validate(), true)
	end)

	t.test("terminal and nil return false", function()
		-- §4.7 (F7): neither verb ever runs on a terminal handle; nil → false
		local s = _newVeron()
		local fired = s:Delay(_noop, 1 / 4)
		s:Update(1 / 4)
		t.eq(fired:GetState(), "Fired")
		t.eq(fired:Complete(), false)
		t.eq(fired:CompleteNow(), false)
		local stopped = s:Delay(_noop, 1)
		stopped:Stop()
		t.eq(stopped:Complete(), false)
		t.eq(stopped:CompleteNow(), false)
		t.eq(s:Complete(nil), false)
		t.eq(s:CompleteNow(nil), false)
		t.eq(s:Complete(fired), false)
		t.eq(s:CompleteNow(stopped), false)
		fired:Stop() -- finalized (§4.3): still false
		t.eq(fired:Complete(), false)
		t.eq(fired:CompleteNow(), false)
		t.eq(s:GetStats().Dispatched, 1)
	end)

	t.test("error inside CompleteNow reported after transitions", function()
		-- §4.7 (E5/F8): returns true even if the callback errored; state settled before fn
		local captured = _withWarnCapture(function()
			local s = _newVeron()
			local child = _counter()
			local seen = {}
			local h
			h = s:Delay(function()
				seen.state = h:GetState()
				error("now boom")
			end, 1)
			local c = h:After(child.fn, 1 / 4)
			t.eq(h:CompleteNow(), true, "true even though the callback errored")
			t.eq(seen.state, "Fired", "the transition happened before the callback")
			t.eq(h:GetState(), "Fired")
			t.eq(c:GetState(), "Pending", "children armed before the callback")
			t.eq(c:GetRemaining(), 1 / 4)
			t.eq(s:GetStats().Errors, 1)
			t.eq(s:GetBase(), false)
			t.eq(s:IsUpdating(), false)
			t.eq(s:Validate(), true)
		end)
		t.eq(#captured, 1, "reported once")
		t.eq(_contains(captured[1], "now boom"), true, captured[1])

		-- "error" policy: re-raised once at the outermost exit, after the transitions
		local s2 = _newVeron({ Name = "E", OnError = "error" })
		local h2 = s2:Delay(function()
			error("strict boom")
		end, 1)
		local ok, err = pcall(function()
			return h2:CompleteNow()
		end)
		t.eq(ok, false, "re-raised")
		t.eq(_contains(err, "strict boom"), true, tostring(err))
		t.eq(h2:GetState(), "Fired")
		t.eq(s2:GetStats().Errors, 1)
		t.eq(s2:GetBase(), false)
		t.eq(s2:IsUpdating(), false)
		t.eq(s2:Validate(), true)
	end)

	t.test("exactly one fire when completed mid-update", function()
		-- §4.2 (b) / §4.7: a co-due sibling completed from a callback fires once
		local s = _newVeron()
		local box, box2 = _counter(), _counter()
		local seen = {}
		local b
		local a = s:Delay(function()
			seen.deferred = b:Complete()
		end, 1 / 4)
		b = s:Delay(box.fn, 1 / 4)
		s:Update(1 / 4)
		t.eq(seen.deferred, true)
		t.eq(box.count, 1)
		s:Update(1)
		t.eq(box.count, 1)
		t.eq(b:GetState(), "Fired")

		-- CompleteNow on a co-due sibling: fired synchronously, never popped again
		local d
		local c = s:Delay(function()
			seen.now = d:CompleteNow()
		end, 1 / 2)
		d = s:Delay(box2.fn, 1 / 2)
		s:Update(1 / 2)
		t.eq(seen.now, true)
		t.eq(box2.count, 1)
		t.eq(c:GetState(), "Fired")
		t.eq(d:GetState(), "Fired")
		s:Update(1)
		t.eq(box2.count, 1)
		t.eq(s:GetClocks(), 0)
		t.eq(s:Validate(), true)
	end)

	t.test("instance Complete(nil/non-handle) is false, foreign errors", function()
		-- §4.7 / §2.2: through `_resolve(self, x, 4)` — as Stop
		local s = _newVeron()
		t.eq(s:Complete(nil), false)
		t.eq(s:Complete({}), false)
		t.eq(s:Complete(42), false)
		t.eq(s:Complete("h"), false)
		t.eq(s:CompleteNow(nil), false)
		t.eq(s:CompleteNow({}), false)
		t.eq(s:CompleteNow(true), false)
		local other = _newVeron({ Name = "U" })
		local foreign = other:Delay(_noop, 1)
		t.throws(function()
			s:Complete(foreign)
		end, "belongs to Veron 'U', not 'T'")
		t.throws(function()
			s:CompleteNow(foreign)
		end, "belongs to Veron 'U', not 'T'")
		local ok, err = pcall(function()
			s:Complete(foreign)
		end)
		t.eq(ok, false)
		t.eq(_contains(err, "Veron 'T': event #1 belongs to Veron 'U', not 'T'"), true, tostring(err))
		t.eq(foreign:GetState(), "Pending")
		t.eq(foreign:GetRemaining(), 1)
		-- Strict: a non-handle raises, nil stays false
		local strict = _newVeron({ Name = "S", Strict = true })
		t.throws(function()
			strict:Complete({})
		end, "expected a VeronEvent, got table")
		t.throws(function()
			strict:CompleteNow(7)
		end, "expected a VeronEvent, got number")
		t.eq(strict:Complete(nil), false)
		t.eq(strict:CompleteNow(nil), false)
	end)

	t.test("{stop=true} lowercase is rejected", function()
		-- §4.7 `_checkOpts`: `{stop = true}` is an error, never a silent no-op
		local s = _newVeron()
		local box = _counter()
		local r = s:Recur(box.fn, 1)
		s:Update(1 / 4)
		t.throws(function()
			r:Complete({ stop = true })
		end, "unknown option 'stop' in Complete")
		t.throws(function()
			r:CompleteNow({ stop = true })
		end, "unknown option 'stop' in Complete")
		t.throws(function()
			s:Complete(r, { stop = true })
		end, "unknown option 'stop' in Complete")
		t.throws(function()
			s:CompleteNow(r, { stop = true })
		end, "unknown option 'stop' in Complete")
		local ok, err = pcall(function()
			r:Complete({ stop = true })
		end)
		t.eq(ok, false)
		t.eq(_contains(err, "Veron 'T': unknown option 'stop' in Complete"), true, tostring(err))
		t.throws(function()
			r:Complete({ Stop = true, Extra = 1 })
		end, "unknown option 'Extra' in Complete")
		t.throws(function()
			r:Complete(8)
		end, "expects an options table, got number")
		t.eq(r:GetRemaining(), 3 / 4, "no mutation")
		t.eq(box.count, 0)
		t.eq(_contains(r:Describe(), "+stop"), false)
		s:Update(0)
		t.eq(box.count, 0)
	end)

	t.test("ForceEventComplete alias", function()
		-- §2.2 / §3.2 PUBLIC: `ForceEventComplete` is the same closure as `Complete`
		local s = _newVeron()
		local box = _counter()
		t.eq(s.ForceEventComplete, s.Complete)
		local h = s:Delay(box.fn, 1)
		t.eq(s.ForceEventComplete(h), true, "the legacy dot-call shape")
		t.eq(h:GetRemaining(), 0)
		t.eq(box.count, 0, "deferred")
		s:Update(0)
		t.eq(box.count, 1)
		local h2 = s:Delay(box.fn, 1)
		t.eq(s:ForceEventComplete(h2), true, "colon form")
		s:Update(0)
		t.eq(box.count, 2)
		t.eq(s.ForceEventComplete(nil), false)
		t.eq(s.ForceEventComplete(h2), false, "terminal")
	end)
end

--!nonstrict
--[[
	chain_spec — After-chains (docs/DESIGN.md §4.6; the state-gated cascade of
	§4.3; the Chained detach of §4.7; the §5 "parent fires" / "After" rows;
	§9 handle/chain_spec row — 15 tests, names verbatim).

	Every instance runs through Oracle.wrap. Timing uses dyadic numbers so
	every due is exact. Assertions never run INSIDE a callback (a failing
	assertion there would be swallowed as a callback error and merely
	warned): callbacks record what they see and the test asserts outside.

	The modules are required lazily so this file loads even before the Veron
	core exists (a missing core then fails each test, not the whole file).
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

return function(t)
	t.test("child stopped before parent never fires", function()
		-- §4.6 / §4.3 (A1/F8): the parent's list skips non-Chained entries
		local s = _newVeron()
		local child = _counter()
		local parent = s:Delay(_noop, 1 / 4)
		local c = parent:After(child.fn, 1 / 4)
		t.eq(c:GetState(), "Chained")
		t.eq(s:GetStats().Chained, 1)
		c:Stop()
		t.eq(c:GetState(), "Stopped")
		t.eq(c:IsActive(), false)
		t.eq(s:GetStats().Chained, 0)
		s:Update(2)
		t.eq(parent:GetState(), "Fired")
		t.eq(child.count, 0, "a stopped child never fires")
		t.eq(c:GetState(), "Stopped")
		t.eq(s:GetClocks(), 0)
		-- the legacy alias path (`h:stop()`) stops a child the same way
		local parent2 = s:Delay(_noop, 1 / 4)
		local c2 = parent2:After(child.fn, 1 / 4)
		c2:stop()
		s:Update(2)
		t.eq(child.count, 0)
		t.eq(c2:GetState(), "Stopped")
	end)

	t.test("after on recurring errors", function()
		-- §4.6 (A3): `cannot chain a recurring event`, nothing allocated
		local s = _newVeron()
		local r = s:Recur(_noop, 1 / 4)
		t.throws(function()
			r:After(_noop, 1)
		end, "cannot chain a recurring event")
		t.throws(function()
			r:after(_noop, 1)
		end, "cannot chain a recurring event")
		t.eq(s:GetStats().Chained, 0)
		t.eq(rawget(r, "_Chained"), false, "no list was allocated")
		t.eq(s:GetClocks(), 1)
		-- a one-shot parent still chains normally on the same instance
		local p = s:Delay(_noop, 1 / 4)
		t.eq(p:After(_noop, 1 / 4):GetState(), "Chained")
	end)

	t.test("After on Fired arms from the caller's clock, never returns the parent", function()
		-- §4.6 (A4/B-07): top level → `now`; inside the firing thread → the base
		local s = _newVeron()
		local child = _counter()
		local parent = s:Delay(_noop, 1 / 4)
		s:Update(1 / 2) -- now 0.5; parent fired at its ideal due 0.25
		t.eq(parent:GetState(), "Fired")
		local c = parent:After(child.fn, 1 / 4)
		t.eq(c ~= parent, true, "never the parent")
		t.eq(c:GetState(), "Pending")
		t.eq(c:GetRemaining(), 1 / 4, "top level: from now, not from the parent's due")
		s:Update(15 / 64) -- now 0.734375
		t.eq(child.count, 0)
		s:Update(1 / 64) -- now 0.75
		t.eq(child.count, 1)

		-- inside the firing thread: from the firing entry's ideal due (R-D)
		local s2 = _newVeron({ Name = "U" })
		local inner = _counter()
		local seen = {}
		local p2
		p2 = s2:Delay(function()
			seen.state = p2:GetState()
			seen.child = p2:After(inner.fn, 1 / 4)
			seen.remaining = seen.child:GetRemaining()
		end, 1 / 4)
		s2:Update(3 / 8) -- now 0.375, base 0.25
		t.eq(seen.state, "Fired", "a one-shot reads Fired inside its callback")
		t.eq(seen.child ~= p2, true)
		t.eq(seen.child:GetState(), "Pending")
		t.eq(seen.remaining, 1 / 8, "armed from the ideal due 0.25, not from now 0.375")
		t.eq(inner.count, 0)
		s2:Update(1 / 8) -- now 0.5
		t.eq(inner.count, 1)
	end)

	t.test("after on Stopped returns a Stopped child", function()
		-- §4.6 (A5): born Stopped, WITHOUT argument validation (total, D8)
		local s = _newVeron()
		local child = _counter()
		local parent = s:Delay(_noop, 1)
		parent:Stop()
		local c = parent:After(child.fn, 1 / 4)
		t.eq(c ~= parent, true, "never the parent")
		t.eq(c:GetState(), "Stopped")
		t.eq(c:IsActive(), false)
		t.eq(c:GetRemaining(), 0)
		local ok, c2 = pcall(function()
			return parent:After(nil, "bogus")
		end)
		t.eq(ok, true, "no validation on a Stopped parent: " .. tostring(c2))
		t.eq(c2:GetState(), "Stopped")
		t.eq(c:After(_noop, 1):GetState(), "Stopped", "a born-Stopped child chains nothing either")
		s:Update(5)
		t.eq(child.count, 0)
		t.eq(s:GetClocks(), 0)
		t.eq(s:GetStats().Chained, 0)
	end)

	t.test("After on a handle of a destroyed instance returns a Stopped child", function()
		-- §2.2 "After Destroy" / §4.6: no `destroyed` raise on a handle method
		local s = _newVeron()
		local child = _counter()
		local fired = s:Delay(_noop, 1 / 4)
		local pending = s:Delay(_noop, 1)
		s:Update(1 / 4)
		t.eq(fired:GetState(), "Fired")
		s:Destroy()
		t.eq(s:IsDestroyed(), true)
		t.eq(pending:GetState(), "Stopped")
		local ok, c = pcall(function()
			return fired:After(child.fn, 1 / 4)
		end)
		t.eq(ok, true, "no `destroyed` raise: " .. tostring(c))
		t.eq(c ~= fired, true)
		t.eq(c:GetState(), "Stopped")
		local ok2, c2 = pcall(function()
			return pending:After(nil, nil)
		end)
		t.eq(ok2, true, "no validation either: " .. tostring(c2))
		t.eq(c2:GetState(), "Stopped")
		t.eq(child.count, 0)
		-- the instance itself still refuses arms
		t.throws(function()
			s:Delay(_noop, 1)
		end, "destroyed")
	end)

	t.test("multiple children fire in registration order", function()
		-- §4.6 (A6/D23): registration order == Id order == (due, Id) FIFO
		local s = _newVeron()
		local log, mark = _logger()
		local parent = s:Delay(mark("p"), 1 / 4)
		local a = parent:After(mark("a"), 1 / 4)
		local b = parent:After(mark("b"), 1 / 4)
		local c = parent:After(mark("c"), 1 / 4)
		t.eq(s:GetStats().Chained, 3)
		t.eq(a:GetId() < b:GetId() and b:GetId() < c:GetId(), true, "ids ascend in registration order")
		s:Update(1) -- parent at 0.25, children at 0.5: one pass
		t.eq(table.concat(log, ","), "p,a,b,c")
		t.eq(s:GetStats().Chained, 0)
		t.eq(s:GetClocks(), 0)
	end)

	t.test("3-deep chain", function()
		-- §4.6 (A7): unlimited depth; each level arms from the previous ideal due
		local s = _newVeron()
		local log, mark = _logger()
		local p = s:Delay(mark("p"), 1 / 4)
		local c = p:After(mark("c"), 1 / 4)
		local g = c:After(mark("g"), 1 / 4)
		t.eq(c:GetState(), "Chained")
		t.eq(g:GetState(), "Chained")
		t.eq(s:GetStats().Chained, 2)
		s:Update(1 / 4)
		t.eq(table.concat(log, ","), "p")
		t.eq(c:GetState(), "Pending")
		t.eq(g:GetState(), "Chained")
		t.eq(s:GetStats().Chained, 1)
		s:Update(1 / 4)
		t.eq(table.concat(log, ","), "p,c")
		t.eq(g:GetState(), "Pending")
		t.eq(s:GetStats().Chained, 0)
		s:Update(1 / 4)
		t.eq(table.concat(log, ","), "p,c,g")
		t.eq(s:GetClocks(), 0)
	end)

	t.test("children arm from parent ideal due", function()
		-- §4.6 (A9): child due = d + delay, d the parent's ideal due, not now
		local s = _newVeron()
		local child = _counter()
		local p = s:Delay(_noop, 1 / 4)
		local c = p:After(child.fn, 1 / 4)
		s:Update(3 / 8) -- now 0.375; parent's ideal due 0.25 → child due 0.5
		t.eq(p:GetState(), "Fired")
		t.eq(c:GetState(), "Pending")
		t.eq(c:GetRemaining(), 1 / 8, "0.5 - 0.375, not a full 0.25 from now")
		s:Update(1 / 16) -- now 0.4375
		t.eq(child.count, 0)
		s:Update(1 / 16) -- now 0.5
		t.eq(child.count, 1)
	end)

	t.test("children of a deferred-completed parent arm from the completion time", function()
		-- §4.6 / §4.7: `d` IS the completion time (the caller's now at Complete)
		local s = _newVeron()
		local child = _counter()
		local p = s:Delay(_noop, 1)
		local c = p:After(child.fn, 1 / 4)
		s:Update(1 / 4) -- now 0.25
		t.eq(p:Complete(), true)
		t.eq(c:GetState(), "Chained", "deferred: nothing fired yet")
		s:Update(1 / 8) -- now 0.375: the parent fires with d = 0.25
		t.eq(p:GetState(), "Fired")
		t.eq(c:GetState(), "Pending")
		t.eq(c:GetRemaining(), 1 / 8, "child due = 0.25 (completion time) + 0.25")
		s:Update(1 / 8) -- now 0.5
		t.eq(child.count, 1)

		-- CompleteNow: the completion time is exactly now
		local s2 = _newVeron({ Name = "U" })
		local child2 = _counter()
		local p2 = s2:Delay(_noop, 1)
		local c2 = p2:After(child2.fn, 1 / 4)
		s2:Update(1 / 4)
		t.eq(p2:CompleteNow(), true)
		t.eq(p2:GetState(), "Fired")
		t.eq(c2:GetState(), "Pending")
		t.eq(c2:GetRemaining(), 1 / 4)
		s2:Update(1 / 4)
		t.eq(child2.count, 1)
	end)

	t.test("erroring parent still arms children", function()
		-- §4.6 (A10/B-13, DV-6): children are armed BEFORE the callback (R-B)
		local captured = _withWarnCapture(function()
			local s = _newVeron()
			local child = _counter()
			local p = s:Delay(function()
				error("parent boom")
			end, 1 / 4)
			local c = p:After(child.fn, 1 / 4)
			s:Update(1 / 2)
			t.eq(p:GetState(), "Fired")
			t.eq(c:GetState(), "Fired")
			t.eq(child.count, 1)
			t.eq(s:GetStats().Errors, 1)
			t.eq(s:Validate(), true)
		end)
		t.eq(#captured, 1, "the parent's error was reported once")
		t.eq(captured[1]:find("parent boom", 1, true) ~= nil, true, captured[1])
	end)

	t.test("Complete on a Chained child detaches it: parent later skips it", function()
		-- §4.7 CHAINED case: detached → Pending @ now; stays in the parent's
		-- list, which the arm skips (non-Chained entries)
		local s = _newVeron()
		local parent, child = _counter(), _counter()
		local p = s:Delay(parent.fn, 1)
		local c = p:After(child.fn, 1 / 4)
		s:Update(1 / 4)
		t.eq(c:Complete(), true)
		t.eq(c:GetState(), "Pending")
		t.eq(c:GetRemaining(), 0)
		t.eq(s:GetStats().Chained, 0)
		t.eq(s:GetClocks(), 2, "the detached child now counts as Pending")
		s:Update(0)
		t.eq(child.count, 1)
		t.eq(c:GetState(), "Fired")
		t.eq(parent.count, 0)
		s:Update(1)
		t.eq(parent.count, 1)
		t.eq(child.count, 1, "the parent's fire skipped the completed child")
		t.eq(c:GetState(), "Fired")
	end)

	t.test("parent Stop after child Complete leaves the completed child armed and firing", function()
		-- §4.3 (F2, non-negotiable 11): the cascade is state-gated
		local s = _newVeron()
		local child, sibling = _counter(), _counter()
		local p = s:Delay(_noop, 1)
		local c = p:After(child.fn, 1 / 4)
		local sib = p:After(sibling.fn, 1 / 4)
		t.eq(c:Complete(), true)
		t.eq(c:GetState(), "Pending")
		p:Stop()
		t.eq(p:GetState(), "Stopped")
		t.eq(sib:GetState(), "Stopped", "the still-Chained sibling cascades")
		t.eq(c:GetState(), "Pending", "the completed child survives the cascade")
		s:Update(0)
		t.eq(child.count, 1)
		t.eq(sibling.count, 0)
		t.eq(c:GetState(), "Fired")

		-- the instance-side Stop / Remove alias cascades the same way
		local p2 = s:Delay(_noop, 1)
		local c2 = p2:After(child.fn, 1 / 4)
		t.eq(c2:Complete(), true)
		t.eq(s:Remove(p2), true)
		t.eq(c2:GetState(), "Pending")
		s:Update(0)
		t.eq(child.count, 2)
	end)

	t.test("Clear/Destroy with a completed child does not corrupt the walk", function()
		-- §4.3 Clear: a child detached by Complete is Pending and is visited by
		-- the walk itself, never by a cascade; legal mid-update (under
		-- Oracle.wrap, from inside a callback)
		for _, verb in { "Clear", "Destroy" } do
			local s = _newVeron({ Name = verb })
			local child, sibling = _counter(), _counter()
			local seen = {}
			local trigger = s:Delay(function()
				if verb == "Clear" then
					seen.cleared = s:Clear()
				else
					s:Destroy()
				end
				seen.validate = s:Validate()
				seen.clocks = s:GetClocks()
			end, 0)
			local p = s:Delay(_noop, 1)
			local c = p:After(child.fn, 1 / 4)
			local sib = p:After(sibling.fn, 1 / 4)
			local paused = s:Recur(_noop, 1)
			paused:Pause()
			t.eq(c:Complete(), true) -- Pending at now = 0, still in p's list
			t.eq(trigger:GetId() < c:GetId(), true, "the trigger fires first at due 0")
			s:Update(0)
			t.eq(trigger:GetState(), "Fired", verb)
			t.eq(seen.validate, true, verb .. ": Validate holds inside the callback")
			t.eq(seen.clocks, 0, verb)
			if verb == "Clear" then
				-- p, c and paused are walked; sib is cascaded: 3 walked + 1 cascaded
				t.eq(type(seen.cleared), "number", "Clear returns a count")
				t.eq(seen.cleared >= 3 and seen.cleared <= 4, true, "Clear count: " .. tostring(seen.cleared))
			else
				t.eq(s:IsDestroyed(), true)
			end
			t.eq(p:GetState(), "Stopped", verb)
			t.eq(c:GetState(), "Stopped", verb .. ": the completed child is walked, not cascaded")
			t.eq(sib:GetState(), "Stopped", verb)
			t.eq(paused:GetState(), "Stopped", verb)
			t.eq(child.count, 0, verb)
			t.eq(sibling.count, 0, verb)
			local stats = s:GetStats()
			t.eq(stats.Pending, 0, verb)
			t.eq(stats.Paused, 0, verb)
			t.eq(stats.Chained, 0, verb)
			t.eq(stats.Recurring, 0, verb)
			t.eq(s:GetClocks(), 0, verb)
			t.eq(s:Validate(), true, verb)
			if verb == "Clear" then
				s:Update(5)
				t.eq(child.count, 0, "nothing left to fire")
			end
		end
	end)

	t.test("GetRemaining on a Chained child is its delay", function()
		-- §4.5 `_GetRemaining`: CHAINED → _Period; §5 GetRemaining row
		local s = _newVeron()
		local p = s:Delay(_noop, 1)
		local c = p:After(_noop, 3 / 8)
		t.eq(c:GetRemaining(), 3 / 8)
		t.eq(s:GetRemaining(c), 3 / 8, "the owner-agnostic instance query agrees")
		s:Update(1 / 2)
		t.eq(c:GetRemaining(), 3 / 8, "a Chained child does not count down")
		t.eq(c:GetState(), "Chained")
		-- retimes on a Chained child set the delay (§5 rows)
		c:SetRemaining(1 / 4)
		t.eq(c:GetRemaining(), 1 / 4)
		t.eq(c:GetPeriod(), 1 / 4)
		c:Adjust(1 / 2)
		t.eq(c:GetRemaining(), 1 / 2)
		-- PWC leaves it untouched
		c:Pause()
		t.eq(c:GetState(), "Chained")
		t.eq(c:GetRemaining(), 1 / 2)
		c:Resume()
		t.eq(c:GetRemaining(), 1 / 2)
	end)

	t.test("After on a restarted parent chains normally; old children never re-fire", function()
		-- §4.4 Restart: `_Chained` was cleared at fire; a fresh Id; a later
		-- After chains normally (Q-J18)
		local s = _newVeron()
		local old, new = _counter(), _counter()
		local p = s:Delay(_noop, 1 / 4)
		local c1 = p:After(old.fn, 1 / 4)
		s:Update(1 / 2) -- p at 0.25, c1 at 0.5: both fire in this pass
		t.eq(p:GetState(), "Fired")
		t.eq(c1:GetState(), "Fired")
		t.eq(old.count, 1)
		local oldId = p:GetId()
		t.eq(p:Restart(), p)
		t.eq(p:GetState(), "Pending")
		t.eq(p:GetId() > oldId, true, "the Fired re-arm takes a fresh Id")
		t.eq(p:GetRemaining(), 1 / 4, "from now with the full period")
		local c2 = p:After(new.fn, 1 / 4)
		t.eq(c2:GetState(), "Chained")
		t.eq(s:GetStats().Chained, 1)
		s:Update(1 / 4) -- now 0.75: p fires again, c2 armed at 1.0
		t.eq(p:GetState(), "Fired")
		t.eq(c2:GetState(), "Pending")
		t.eq(old.count, 1, "the old child never re-fires")
		t.eq(new.count, 0)
		s:Update(1 / 4) -- now 1.0
		t.eq(new.count, 1)
		t.eq(old.count, 1)
		t.eq(c1:GetState(), "Fired")
		t.eq(s:GetClocks(), 0)
	end)
end

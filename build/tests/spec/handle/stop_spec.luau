--!nonstrict
--[[
	stop_spec — the Stop / Remove cascade and the instance `Stop(x)` resolver
	(docs/DESIGN.md §2.2 Stop row, §2.3 Stop row, §4.3, §5, §9
	handle/stop_spec row). Every instance runs through `Oracle.wrap`; timing
	uses dyadic numbers only.
]]

local Veron = require("../../../src/Veron")
local VeronEvent = require("../../../src/Veron/VeronEvent")
local Env = require("../../../src/Veron/Env")
local Oracle = require("../../support/oracle")

--[[
	A fresh oracle-wrapped instance; the Name defaults to "T".
]]
local function _new(cfg)
	cfg = cfg or {}
	if cfg.Name == nil then
		cfg.Name = "T"
	end
	return Oracle.wrap(Veron.new(cfg))
end

local function _counter()
	local count = { n = 0 }
	local function fn()
		count.n += 1
	end
	return count, fn
end

--[[
	Runs `body` with Env.Warn captured into a list; restores the seam
	whatever happens and re-raises a failure unchanged.
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

return function(t)
	-- §4.3 `_stopTerminal` (terminal check FIRST), §5 Stop row (Stopped → no-op), SEM S5
	t.test("double stop no-op", function()
		local s = _new()
		local count, fn = _counter()
		local h = s:Delay(fn, 1)
		t.eq(s:GetClocks(), 1)
		t.eq(h:Stop(), nil, "Stop returns nothing")
		t.eq(h:GetState(), "Stopped")
		t.eq(s:GetClocks(), 0)
		local okSecond, result = pcall(h.Stop, h)
		t.eq(okSecond, true, "second Stop must not raise: " .. tostring(result))
		t.eq(result, nil)
		t.eq(h:GetState(), "Stopped")
		t.eq(s:GetClocks(), 0)
		t.eq(h:stop(), nil)
		t.eq(h:Destroy(), nil)
		-- the instance form: true once (a LIVE handle became Stopped), then false
		local h2 = s:Recur(fn, 1)
		t.eq(s.Stop(h2), true)
		t.eq(s.Stop(h2), false, "nothing live changed the second time")
		t.eq(s.remove(h2), false)
		t.eq(s:Remove(h2), false)
		t.eq(h2:GetState(), "Stopped")
		t.eq(s:GetStats().Recurring, 0)
		-- a paused handle stops once too
		local h3 = s:Delay(fn, 1)
		h3:Pause()
		t.eq(s.Stop(h3), true)
		t.eq(s.Stop(h3), false)
		t.eq(s:GetStats().Paused, 0)
		s:Update(5)
		t.eq(count.n, 0)
		t.eq(s:Validate(), true)
	end)

	-- §2.2 Stop row (`nil`/non-handle → `false`), §4.3 `_resolve` (nil FIRST, before Strict), SEM S6
	t.test("remove nil false", function()
		local s = _new()
		t.eq(s.remove(nil), false)
		t.eq(s.Remove(nil), false)
		t.eq(s.Stop(nil), false)
		t.eq(s.remove(), false, "no argument at all")
		t.eq(s:remove(nil), false, "colon form")
		t.eq(s:Stop(nil), false)
		-- nil is the normal "no clock yet" value: false even under Strict
		local strict = _new({ Name = "Strict", Strict = true })
		local ok, result = pcall(strict.remove, nil)
		t.eq(ok, true, "Strict remove(nil) must not raise: " .. tostring(result))
		t.eq(result, false)
		t.eq(strict.Stop(nil), false)
		t.eq(strict:Stop(), false)
	end)

	-- §2.2 Stop row (`Strict` → error), §4.3 `_resolve` (`getmetatable(x) ~= eventDict`), Q-J5
	t.test("remove non-handle false, Strict errors", function()
		local s = _new()
		t.eq(s.remove({}), false)
		t.eq(s.remove("x"), false)
		t.eq(s.remove(true), false)
		t.eq(s.Stop(function() end), false)
		t.eq(s.Remove(setmetatable({}, {})), false)
		-- a §3.1-shaped table with the WRONG metatable is not a handle either
		local fake = {
			class = VeronEvent,
			type = "VeronEvent",
			Id = 1,
			_Scheduler = s,
			_Fn = function() end,
			_Period = 1,
			_IsRecur = false,
			_State = 1,
			_HeapIndex = 0,
			_Chained = false,
			_Burst = 0,
			_BurstSerial = 0,
			_MaxCatchUp = false,
			_Flags = 0,
		}
		t.eq(s.remove(fake), false)
		t.eq(s:Validate(), true)

		local strict = _new({ Name = "Strict", Strict = true })
		t.throws(function()
			strict.remove({})
		end, "Veron 'Strict': expected a VeronEvent, got table")
		t.throws(function()
			strict.Stop("x")
		end, "Veron 'Strict': expected a VeronEvent, got string")
		t.throws(function()
			strict:Remove(true)
		end, "Veron 'Strict': expected a VeronEvent, got boolean")
		t.throws(function()
			strict.remove(fake)
		end, "Veron 'Strict': expected a VeronEvent, got table")
		-- a real handle still works under Strict
		local h = strict:Delay(function() end, 1)
		t.eq(strict.remove(h), true)
		t.eq(h:GetState(), "Stopped")
	end)

	-- L-15 (legacy `remove(number)` threw "table index is nil"), §2.2 Stop row
	t.test("remove number false", function()
		local s = _new()
		local count, fn = _counter()
		local h = s:Delay(fn, 1)
		for _, value in { 7, 0, -1, 1.5, h:GetId(), 0 / 0, math.huge } do
			local ok, result = pcall(s.remove, value)
			t.eq(ok, true, "remove(" .. tostring(value) .. ") must not raise: " .. tostring(result))
			t.eq(result, false, "remove(" .. tostring(value) .. ") is false")
		end
		t.eq(s.Stop(1), false)
		t.eq(s:remove(1), false)
		t.eq(h:GetState(), "Pending", "an index is never a handle: nothing removed")
		t.eq(s:GetClocks(), 1)
		s:Update(1)
		t.eq(count.n, 1)
		-- Strict: a number is a non-handle, so it errors
		local strict = _new({ Name = "Strict", Strict = true })
		t.throws(function()
			strict.remove(7)
		end, "Veron 'Strict': expected a VeronEvent, got number")
	end)

	-- §2.2 Stop row (`event #<id> belongs to Veron '<Y>', not '<X>'`), §4.3 `_resolve`, SEM S7
	t.test("foreign handle errors with both names", function()
		local a = _new({ Name = "A" })
		local b = _new({ Name = "B" })
		local count, fn = _counter()
		local h = a:Delay(fn, 1)
		t.eq(h:GetId(), 1)
		t.throws(function()
			b.remove(h)
		end, "Veron 'B': event #1 belongs to Veron 'A', not 'B'")
		t.throws(function()
			b.Stop(h)
		end, "event #1 belongs to Veron 'A', not 'B'")
		t.throws(function()
			b.Remove(h)
		end, "event #1 belongs to Veron 'A', not 'B'")
		t.throws(function()
			b:remove(h)
		end, "Veron 'B': event #1 belongs to Veron 'A', not 'B'")
		-- the other way round names the other pair
		local hb = b:Recur(fn, 1)
		t.throws(function()
			a.remove(hb)
		end, "Veron 'A': event #1 belongs to Veron 'B', not 'A'")
		-- Complete / CompleteNow resolve the same way (§2.2)
		t.throws(function()
			b.Complete(h)
		end, "Veron 'B': event #1 belongs to Veron 'A', not 'B'")
		t.throws(function()
			b.CompleteNow(h)
		end, "Veron 'B': event #1 belongs to Veron 'A', not 'B'")
		-- a cross-scheduler remove never touches the owner
		t.eq(h:GetState(), "Pending")
		t.eq(hb:GetState(), "Pending")
		t.eq(a:GetClocks(), 1)
		t.eq(b:GetClocks(), 1)
		t.eq(a:Validate(), true)
		t.eq(b:Validate(), true)
		a:Update(1)
		t.eq(count.n, 1, "the foreign attempt did not stop it")
	end)

	-- §2.3 Stop row ("owner-agnostic"), §4.10 (`h:Stop()` → `h._Scheduler:_Stop(h)`), SEM S7
	t.test("h:Stop on a foreign handle still works", function()
		local a = _new({ Name = "A" })
		local b = _new({ Name = "B" })
		local count, fn = _counter()
		local h = a:Delay(fn, 1)
		local hb = b:Recur(fn, 1)
		-- code holding B stops a handle that belongs to A through the handle itself
		t.eq(h:GetScheduler(), a)
		t.eq(h:Stop(), nil)
		t.eq(h:GetState(), "Stopped")
		t.eq(a:GetClocks(), 0, "removed from its OWNER")
		t.eq(b:GetClocks(), 1, "the other instance untouched")
		t.eq(hb:stop(), nil)
		t.eq(hb:GetState(), "Stopped")
		t.eq(b:GetClocks(), 0)
		t.eq(b:GetStats().Recurring, 0)
		a:Update(5)
		b:Update(5)
		t.eq(count.n, 0)
		t.eq(a:Validate(), true)
		t.eq(b:Validate(), true)
	end)

	-- §4.3 (Fired → Stopped, `_Fn = NOOP`, no container op, `Stop(h)` returns false),
	-- §4.4 (Restart refused), §5 Fired column
	t.test("h:stop() on a Fired handle is silent and makes it final (Stop returns false)", function()
		local s = _new()
		local count, fn = _counter()
		local noop = Oracle.noop()
		local warnings = _withWarnings(function()
			local h1 = s:Delay(fn, 1 / 4)
			local h2 = s:Delay(fn, 1 / 4)
			local h3 = s:Delay(fn, 1 / 4)
			s:Update(1 / 4)
			t.eq(count.n, 3)
			for _, h in { h1, h2, h3 } do
				t.eq(h:GetState(), "Fired")
				t.eq(rawget(h, "_Fn"), fn, "a Fired handle keeps its function")
			end
			t.eq(s:GetClocks(), 0, "a Fired handle is in no container")
			-- the SafeStopClock path: `x:stop()` after the fire
			local okStop, result = pcall(h1.stop, h1)
			t.eq(okStop, true, "must not raise: " .. tostring(result))
			t.eq(result, nil, "stop returns nothing")
			t.eq(h1:GetState(), "Stopped")
			t.eq(rawget(h1, "_Fn"), noop, "finalized: NOOP")
			t.eq(rawget(h1, "_Flags"), 0)
			t.eq(rawget(h1, "_HeapIndex"), 0)
			-- the instance form returns false: no LIVE handle changed
			t.eq(s.Stop(h2), false)
			t.eq(h2:GetState(), "Stopped")
			t.eq(rawget(h2, "_Fn"), noop)
			t.eq(s.remove(h3), false)
			t.eq(h3:GetState(), "Stopped")
			-- final: a later Restart is a no-op, nothing ever fires again
			for _, h in { h1, h2, h3 } do
				t.eq(h:Restart(), h)
				t.eq(h:GetState(), "Stopped")
				t.eq(h:IsActive(), false)
				t.eq(h:GetRemaining(), 0)
				-- and a second stop stays silent
				t.eq(h:stop(), nil)
				t.eq(s.Stop(h), false)
			end
			t.eq(s:GetClocks(), 0)
			s:Update(5)
			t.eq(count.n, 3)
			-- a Fired recurring (via Complete{Stop=true}) finalizes the same way
			local r = s:Recur(fn, 1 / 4)
			r:Complete({ Stop = true })
			s:Update(0)
			t.eq(r:GetState(), "Fired")
			t.eq(s.Stop(r), false)
			t.eq(r:GetState(), "Stopped")
			t.eq(rawget(r, "_Fn"), noop)
			t.eq(r:Restart(), r)
			t.eq(r:GetState(), "Stopped")
			t.eq(s:GetStats().Recurring, 0)
			t.eq(s:Validate(), true)
		end)
		t.eq(#warnings, 0, "silent: no warning was emitted: " .. table.concat(warnings, " | "))
	end)

	-- §2.2 (dual dot/colon closures, D15), §3.2 dual closures, SEM S8 / DV-3
	t.test("instance colon form TickAPI.Tick:remove(h) removes", function()
		local s = _new({ Name = "Tick" })
		local count, fn = _counter()
		local TickAPI = { Tick = s }
		local h = TickAPI.Tick.delay(fn, 1)
		t.eq(s:GetClocks(), 1)
		t.eq(TickAPI.Tick:remove(h), true, "colon form removes and reports it")
		t.eq(h:GetState(), "Stopped")
		t.eq(s:GetClocks(), 0)
		t.eq(TickAPI.Tick:remove(h), false, "second time: nothing live")
		-- every spelling, both forms
		local h2 = TickAPI.Tick:delay(fn, 1)
		t.eq(TickAPI.Tick:Stop(h2), true)
		local h3 = TickAPI.Tick.recur(fn, 1)
		t.eq(TickAPI.Tick:Remove(h3), true)
		local h4 = TickAPI.Tick.delay(fn, 1)
		t.eq(TickAPI.Tick.remove(h4), true, "dot form still the canonical one")
		t.eq(h2:GetState(), "Stopped")
		t.eq(h3:GetState(), "Stopped")
		t.eq(h4:GetState(), "Stopped")
		t.eq(s:GetClocks(), 0)
		t.eq(s.remove, s.Remove, "one closure under every alias")
		t.eq(s.remove, s.Stop)
		-- the colon form with nil / a non-handle behaves like the dot form
		t.eq(TickAPI.Tick:remove(nil), false)
		t.eq(TickAPI.Tick:remove({}), false)
		TickAPI.Tick:update(5)
		t.eq(count.n, 0)
		t.eq(s:Validate(), true)
	end)

	-- §4.3 cascade (recursive over still-CHAINED children), §5 Stop row, SEM A2
	t.test("parent stop cascades through grandchildren", function()
		local s = _new()
		local count, fn = _counter()
		local p = s:Delay(fn, 1)
		local c1 = p:After(fn, 1)
		local c2 = p:After(fn, 1)
		local gc1 = c1:After(fn, 1)
		local gc2 = gc1:After(fn, 1)
		local gc3 = c2:After(fn, 1)
		t.eq(s:GetStats().Chained, 5)
		t.eq(s:GetClocks(), 1)
		-- a child stopped on its own before the cascade stays Stopped, siblings unaffected
		gc3:Stop()
		t.eq(gc3:GetState(), "Stopped")
		t.eq(c2:GetState(), "Chained")
		t.eq(s:GetStats().Chained, 4)
		t.eq(p:Stop(), nil)
		t.eq(p:GetState(), "Stopped")
		for _, h in { c1, c2, gc1, gc2, gc3 } do
			t.eq(h:GetState(), "Stopped", "descendant #" .. h:GetId() .. " is Stopped")
			t.eq(h:IsActive(), false)
			t.eq(h:GetRemaining(), 0)
			t.eq(rawget(h, "_Fn"), Oracle.noop())
		end
		t.eq(s:GetStats().Chained, 0)
		t.eq(s:GetClocks(), 0)
		t.eq(s:Validate(), true)
		s:Update(10)
		t.eq(count.n, 0, "nothing in the chain ever fires")
		-- the instance form cascades the same way, from the middle of a chain
		local p2 = s:Delay(fn, 1)
		local mid = p2:After(fn, 1)
		local leaf = mid:After(fn, 1)
		t.eq(s.Stop(mid), true)
		t.eq(mid:GetState(), "Stopped")
		t.eq(leaf:GetState(), "Stopped")
		t.eq(p2:GetState(), "Pending", "the parent is untouched")
		t.eq(s:GetStats().Chained, 0)
		s:Update(3)
		t.eq(count.n, 1, "only the parent fires")
	end)
end

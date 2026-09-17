--!nonstrict
--[[
	dispatch_spec — the dispatch loop: due prefix, finalize-before-callback,
	(due, Id) order, nested arms and the base carry, error policies
	(docs/DESIGN.md R-B, R-D, §2.1, §2.2, §4.1, §4.2, §4.6; §9
	scheduler/dispatch_spec row, 16 tests).

	Every instance runs through `Oracle.wrap`. Dyadic numbers keep every
	boundary exact; the L-14 test is the one place non-dyadic dts are used on
	purpose.
]]

local Veron = require("../../../src/Veron")
local VeronEvent = require("../../../src/Veron/VeronEvent")
local Env = require("../../../src/Veron/Env")
local Oracle = require("../../support/oracle")

local function newVeron(cfg)
	cfg = cfg or {}
	if cfg.Name == nil then
		cfg.Name = "T"
	end
	return Oracle.wrap(Veron.new(cfg))
end

local function captureWarns(fn)
	local warns = {}
	local restore = Env.SetWarn(function(message)
		warns[#warns + 1] = tostring(message)
	end)
	local ok, err = pcall(fn)
	restore()
	if not ok then
		error(err, 0)
	end
	return warns
end

--[[
	A fire log: `tag(name)` returns a callback that appends `name`.
]]
local function newLog()
	local log = {}
	local function tag(name)
		return function()
			log[#log + 1] = name
		end
	end
	return log, tag
end

local function noop()
end

return function(t)
	-- §4.2 `_pass`: `if d > now then break` — entries past the due prefix are never touched
	t.test("only the due prefix is examined", function()
		local s = newVeron()
		local log, tag = newLog()
		local a = s:Delay(tag("a"), 1 / 64)
		local b = s:Delay(tag("b"), 1 / 32)
		local c = s:Delay(tag("c"), 3 / 64)
		local d = s:Delay(tag("d"), 1 / 16)
		local e = s:Delay(tag("e"), 1)
		s:Update(1 / 32)
		t.eq(table.concat(log), "ab")
		t.eq(a:GetState(), "Fired")
		t.eq(b:GetState(), "Fired")
		t.eq(c:GetState(), "Pending")
		t.eq(d:GetState(), "Pending")
		t.eq(e:GetState(), "Pending")
		t.eq(c:GetRemaining(), 1 / 64)
		t.eq(d:GetRemaining(), 1 / 32)
		t.eq(e:GetRemaining(), 1 - 1 / 32)
		local stats = s:GetStats()
		t.eq(stats.Dispatched, 2)
		t.eq(stats.LastDispatched, 2)
		t.eq(stats.HeapSize, 3)
		t.eq(s:GetClocks(), 3)
		-- an idle update (nothing due) dispatches nothing and touches no entry
		s:Update(1 / 128)
		t.eq(s:GetStats().LastDispatched, 0)
		t.eq(table.concat(log), "ab")
		s:Update(1 / 128)
		t.eq(table.concat(log), "abc")
		s:Update(1)
		t.eq(table.concat(log), "abcde")
		t.eq(s:GetStats().Dispatched, 5)
	end)

	-- R-B / SEM S1: the one-shot is popped and marked Fired BEFORE its callback runs
	t.test("one-shot is Fired before its callback", function()
		local s = newVeron()
		local seen = {}
		local h
		h = s:Delay(function()
			seen.state = h:GetState()
			seen.stateId = h:GetStateId()
			seen.active = h:IsActive()
			seen.heapIndex = rawget(h, "_HeapIndex")
			seen.heapSize = s:GetStats().HeapSize
			seen.clocks = s:GetClocks()
			seen.remaining = h:GetRemaining()
			seen.flags = rawget(h, "_Flags")
			seen.stopResult = s:Stop(h) -- a Fired handle: finalized silently, returns false
			seen.stateAfterStop = h:GetState()
		end, 1)
		s:Update(1)
		t.eq(seen.state, "Fired")
		t.eq(seen.stateId, 4)
		t.eq(seen.active, false)
		t.eq(seen.heapIndex, 0)
		t.eq(seen.heapSize, 0)
		t.eq(seen.clocks, 0)
		t.eq(seen.remaining, 0)
		t.eq(seen.flags, 0)
		t.eq(seen.stopResult, false)
		t.eq(seen.stateAfterStop, "Stopped")
		t.eq(h:GetState(), "Stopped")
		-- a plain fire (no stop inside) ends Fired and keeps its function (R-B)
		local plain = s:Delay(noop, 1)
		s:Update(1)
		t.eq(plain:GetState(), "Fired")
		t.eq(rawget(plain, "_Fn"), noop, "a Fired handle keeps _Fn for Restart()")
		t.eq(rawget(plain, "_HeapIndex"), 0)
	end)

	-- §4.2 `_pass` (plain recurring): `due[1] = nextDue; siftDown` BEFORE the callback (D3)
	t.test("recurring is re-keyed before its callback", function()
		local s = newVeron()
		local seen = {}
		local fires = 0
		local h
		h = s:Recur(function()
			fires += 1
			seen.state = h:GetState()
			seen.now = s:Now()
			seen.base = s:GetBase()
			seen.remaining = h:GetRemaining()
			seen.due = rawget(s, "_Due")[rawget(h, "_HeapIndex")]
			seen.heapSize = s:GetStats().HeapSize
		end, 1)
		s:Update(3 / 2)
		t.eq(fires, 1)
		t.eq(seen.state, "Pending", "still scheduled")
		t.eq(seen.now, 3 / 2)
		t.eq(seen.base, 1, "the ideal due")
		t.eq(seen.due, 2, "already re-keyed to d + period")
		t.eq(seen.remaining, 1 / 2)
		t.eq(seen.heapSize, 1)
		-- a stop from inside its own callback removes the re-keyed entry: no further fire (S2)
		local stopped
		stopped = s:Recur(function()
			fires += 1
			stopped:Stop()
		end, 1 / 4)
		h:Stop()
		s:Update(2)
		t.eq(fires, 2, "one fire, then the stop won; the backlog was not delivered")
		t.eq(stopped:GetState(), "Stopped")
		t.eq(s:GetClocks(), 0)
	end)

	-- §4.2 / SEM C4 / D23: strict (due, Id) order; equal dues fire in creation order
	t.test("equal dues fire in creation order", function()
		local s = newVeron()
		local log, tag = newLog()
		for index = 1, 10 do
			s:Delay(tag(tostring(index)), 1)
		end
		s:Update(1)
		t.eq(table.concat(log, ","), "1,2,3,4,5,6,7,8,9,10")
		-- arm-time does not matter, only the (due, Id) pair: b armed later but with the same due goes second
		local log2, tag2 = newLog()
		s:Delay(tag2("a"), 1)
		s:Update(1 / 2)
		s:Delay(tag2("b"), 1 / 2)
		s:Update(1 / 2)
		t.eq(table.concat(log2), "ab")
		-- an entry armed inside a callback with an equal due goes after the pre-existing equal-due entries
		local log3, tag3 = newLog()
		s:Delay(function()
			log3[#log3 + 1] = "p"
			s:Delay(tag3("nested"), 0)
		end, 1)
		s:Delay(tag3("q"), 1)
		s:Delay(tag3("r"), 1)
		s:Update(1)
		t.eq(table.concat(log3, ","), "p,q,r,nested")
	end)

	-- D23: a recurring re-arm keeps its Id, so it stays ahead of younger handles with the same due
	t.test("re-armed recurring keeps its Id rank", function()
		local s = newVeron()
		local log, tag = newLog()
		local r = s:Recur(tag("r"), 1) -- Id 1
		local d = s:Delay(tag("d"), 2) -- Id 2
		s:Update(1)
		t.eq(table.concat(log), "r")
		s:Update(1)
		t.eq(table.concat(log), "rrd", "at 2 the recur (Id 1) precedes the one-shot (Id 2)")
		t.eq(r:GetId(), 1)
		t.eq(d:GetId(), 2)
		r:Stop()
		-- the mirror: a one-shot created first wins the tie
		local log2, tag2 = newLog()
		local d2 = s:Delay(tag2("d"), 2) -- Id 3
		local r2 = s:Recur(tag2("r"), 1) -- Id 4
		s:Update(1)
		s:Update(1)
		t.eq(table.concat(log2), "rdr")
		t.eq(d2:GetId() < r2:GetId(), true)
		t.eq(r2:GetId(), 4, "the re-arm consumed no Id")
		t.eq(rawget(s, "_NextId"), 4)
	end)

	-- SEM C2 / DV-2 (L-04): a nested past-due one-shot pops later in the SAME update, in due order, with a real handle
	t.test("nested past-due one-shot fires later in the same update with a real handle", function()
		local s = newVeron()
		local log, tag = newLog()
		local seen = {}
		local inner
		local p = s:Delay(function()
			log[#log + 1] = "p"
			inner = s:Delay(tag("inner"), 1 / 4) -- due 1 + 1/4 <= now 2: already past
			seen.isHandle = getmetatable(inner) == VeronEvent
			seen.state = inner:GetState()
			seen.firedSynchronously = #log > 1
			seen.due = rawget(s, "_Due")[rawget(inner, "_HeapIndex")]
		end, 1)
		local q = s:Delay(tag("q"), 3 / 2)
		s:Update(2)
		t.eq(seen.isHandle, true, "a real VeronEvent, never a dummy")
		t.eq(seen.state, "Pending", "not fired inside Delay()")
		t.eq(seen.firedSynchronously, false)
		t.eq(seen.due, 5 / 4)
		t.eq(table.concat(log, ","), "p,inner,q", "inner (due 1.25) fires after its creator and before q (due 1.5)")
		t.eq(inner:GetState(), "Fired")
		t.eq(s:GetStats().Dispatched, 3)
		t.eq(s:GetStats().LastDispatched, 3, "all three in ONE update")
		t.eq(p:GetState(), "Fired")
		t.eq(q:GetState(), "Fired")
	end)

	-- SEM C3: nested delay 0 → due = base <= now → later in the same update, whatever the overshoot
	t.test("nested delay 0 fires in the same update", function()
		local s = newVeron()
		local log, tag = newLog()
		-- exact hit (overshoot 0)
		s:Delay(function()
			log[#log + 1] = "p"
			s:Delay(tag("n0"), 0)
			log[#log + 1] = "p-end"
		end, 1)
		s:Update(1)
		t.eq(table.concat(log, ","), "p,p-end,n0", "after the creator returns, in the same update")
		t.eq(s:GetStats().LastDispatched, 2)
		-- with overshoot
		table.clear(log)
		s:Delay(function()
			log[#log + 1] = "p"
			s:Delay(tag("n0"), 0)
		end, 1)
		s:Update(3 / 2)
		t.eq(table.concat(log, ","), "p,n0")
		t.eq(s:GetStats().LastDispatched, 2)
		-- a chain of zero delays inside one update drains in the same update, bounded by the valve
		table.clear(log)
		local depth = 0
		local function chain()
			depth += 1
			log[#log + 1] = tostring(depth)
			if depth < 5 then
				s:Delay(chain, 0)
			end
		end
		s:Delay(chain, 0)
		s:Update(0)
		t.eq(table.concat(log, ","), "1,2,3,4,5")
		t.eq(s:GetStats().ValveHits, 0)
	end)

	-- SEM C1 / D4: an implicit arm inside a callback measures from the firing entry's ideal due, not from now
	t.test("nested delay measured from firing due", function()
		local s = newVeron()
		local log, tag = newLog()
		local child
		s:Delay(function()
			log[#log + 1] = "p"
			child = s:Delay(tag("c"), 1) -- due = 1 + 1 = 2, not 1.5 + 1
		end, 1)
		s:Update(3 / 2)
		t.eq(table.concat(log, ","), "p")
		t.eq(child:GetRemaining(), 1 / 2, "2 - 1.5")
		s:Update(1 / 4)
		t.eq(table.concat(log, ","), "p", "not yet at 1.75")
		s:Update(1 / 4)
		t.eq(table.concat(log, ","), "p,c", "fires at exactly 2")
		t.eq(s:Now(), 2)
		-- the same through a one-shot chain: three nested 1/4 s delays after a 1/64 overshoot land on the grid
		local fireTimes = {}
		local function step(n)
			return function()
				fireTimes[#fireTimes + 1] = s:GetBase()
				if n < 3 then
					s:Delay(step(n + 1), 1 / 4)
				end
			end
		end
		s:Delay(step(1), 1)
		s:Update(1 + 1 / 64)
		s:Update(1 / 4)
		s:Update(1 / 4)
		s:Update(1 / 4)
		t.eq(#fireTimes, 3, "each nested step fired at its grid point despite the overshoot")
		t.eq(fireTimes[1], 3)
		t.eq(fireTimes[2], 3 + 1 / 4)
		t.eq(fireTimes[3], 3 + 1 / 2)
	end)

	-- DV-7 / L-01 / Q-J1: inside a RECURRING callback the base is the ideal due d, so a nested timer waits its delay
	t.test("nested inside recur corrected", function()
		local s = newVeron()
		local nestedAt, nestedRecurAt = false, false
		local first = true
		s:Recur(function()
			if first then
				first = false
				s:Delay(function()
					nestedAt = s:Now()
				end, 1 / 2)
				s:Recur(function()
					if not nestedRecurAt then
						nestedRecurAt = s:Now()
					end
				end, 1 / 2)
			end
		end, 1)
		for _ = 1, 64 * 3 do
			s:Update(1 / 64)
		end
		t.eq(nestedAt, 3 / 2, "delay(0.5) armed at the first fire (due 1) fires at 1.5, not 2.5 (legacy)")
		t.eq(nestedRecurAt, 3 / 2, "a nested recur gets the same first-fire correction")
		-- catch-up case: the 3rd fire (due 3) inside Update(3.5) arms a nested 1/4 → due 3.25, not 4.25
		local s2 = newVeron({ Name = "T2" })
		local fires, nestedDue = 0, false
		s2:Recur(function()
			fires += 1
			if fires == 3 then
				local nested = s2:Delay(noop, 1 / 4)
				nestedDue = rawget(s2, "_Due")[rawget(nested, "_HeapIndex")]
			end
		end, 1)
		s2:Update(7 / 2)
		t.eq(fires, 3)
		t.eq(nestedDue, 3 + 1 / 4)
	end)

	-- §2.1 LegacyRecurBase (Q-J1): base of a recurring dispatch = d + period → the L-01 quirk on purpose
	t.test("LegacyRecurBase reproduces legacy", function()
		local s = newVeron({ LegacyRecurBase = true })
		local nestedAt, oneShotNestedAt = false, false
		local first = true
		s:Recur(function()
			if first then
				first = false
				s:Delay(function()
					nestedAt = s:Now()
				end, 1 / 2)
			end
		end, 1)
		-- a one-shot callback is unaffected: its base is its own due (legacy err <= 0 there)
		s:Delay(function()
			s:Delay(function()
				oneShotNestedAt = s:Now()
			end, 1 / 2)
		end, 1)
		for _ = 1, 64 * 3 do
			s:Update(1 / 64)
		end
		t.eq(nestedAt, 5 / 2, "legacy: 2.5 (measured from the re-armed due 2)")
		t.eq(oneShotNestedAt, 3 / 2, "one-shot nesting stays at parity: 1.5")
		-- GetBase() inside the recurring callback reads the legacy base
		local seenBase = false
		local s2 = newVeron({ Name = "T2", LegacyRecurBase = true })
		s2:Recur(function()
			seenBase = s2:GetBase()
		end, 1)
		s2:Update(3 / 2)
		t.eq(seenBase, 2, "d + period")
		-- default instances measure from d
		local s3 = newVeron({ Name = "T3" })
		s3:Recur(function()
			seenBase = s3:GetBase()
		end, 1)
		s3:Update(3 / 2)
		t.eq(seenBase, 1)
	end)

	-- SEM N5 / R-D: an arm on ANOTHER instance from inside a callback measures from that instance's own clock
	t.test("cross-instance creation uses the other now", function()
		local a = newVeron({ Name = "A" })
		local b = newVeron({ Name = "B" })
		local log, tag = newLog()
		b:Update(3)
		local hb, seen = nil, {}
		a:Delay(function()
			seen.aBase = a:GetBase()
			seen.bBase = b:GetBase()
			hb = b:Delay(tag("b"), 1)
			seen.bRemaining = hb:GetRemaining()
		end, 1)
		a:Update(3 / 2)
		t.eq(seen.aBase, 1)
		t.eq(seen.bBase, false, "B is not firing anything")
		t.eq(seen.bRemaining, 1, "measured from B's now (3), not from A's base (1)")
		t.eq(rawget(b, "_Due")[rawget(hb, "_HeapIndex")], 4)
		b:Update(1 / 2)
		t.eq(#log, 0)
		b:Update(1 / 2)
		t.eq(table.concat(log), "b", "fires at B's 4")
		t.eq(a:Now(), 3 / 2, "A's clock is untouched by B")
		-- and the reverse while B is itself firing: A measures from A's now
		local ha
		b:Delay(function()
			ha = a:Delay(tag("a"), 1)
		end, 1)
		b:Update(2)
		t.eq(rawget(a, "_Due")[rawget(ha, "_HeapIndex")], 3 / 2 + 1)
	end)

	-- DV-11 / L-14 / B-20: no epsilon — an entry fires on the first update whose accumulated clock >= due
	t.test("Delay(3*dt) one update late is documented, not fudged", function()
		--[[
			Runs `Delay(fn, n * dt)` under n (or more) updates of `dt` and returns the
			update index it fired on, next to the index an independent accumulation of
			the same float ops predicts. They must agree exactly: no epsilon either way.
		]]
		local function firesOn(dt, n)
			local s = newVeron()
			local firedOn = false
			local step = 0
			s:Delay(function()
				firedOn = step
			end, n * dt)
			local acc, predicted = 0, false
			for k = 1, n + 2 do
				acc += dt
				if not predicted and acc >= n * dt then
					predicted = k
				end
				step = k
				s:Update(dt)
			end
			return firedOn, predicted
		end
		-- dyadic: exact, fires on the nth update
		local firedOn, predicted = firesOn(1 / 64, 3)
		t.eq(firedOn, 3)
		t.eq(predicted, 3)
		-- 1/60 on the accumulating axis: three additions reach 3 * dt, so the 3rd update (legacy's
		-- subtracting axis fired on the 4th, L-14); either way the rule is the same comparison
		firedOn, predicted = firesOn(1 / 60, 3)
		t.eq(firedOn, predicted, "fires exactly when the accumulated clock reaches the due, no fudge")
		-- the documented one-late case on the new axis: ten 0.1 s steps sum to 0.9999999999999999 < 1
		firedOn, predicted = firesOn(0.1, 10)
		t.eq(predicted, 11)
		t.eq(firedOn, 11, "one update late, not fudged with an epsilon")
		-- sanity: a Delay armed exactly on the grid at the start still fires on the first update reaching it
		local s = newVeron()
		local fired = false
		s:Delay(function()
			fired = true
		end, 1 / 64)
		s:Update(1 / 128)
		t.eq(fired, false)
		s:Update(1 / 128)
		t.eq(fired, true)
	end)

	-- SEM E1 / DV-15: a throwing callback is isolated, warned with the handle id, and never stops the others
	t.test("throwing callback does not stop siblings", function()
		local s = newVeron()
		local log, tag = newLog()
		local thrower = s:Delay(function()
			log[#log + 1] = "a"
			error("boom")
		end, 1)
		local b = s:Delay(tag("b"), 1)
		local c = s:Delay(tag("c"), 1)
		local warns = captureWarns(function()
			s:Update(1)
		end)
		t.eq(table.concat(log), "abc", "b and c still fired after a threw")
		t.eq(#warns, 1)
		t.eq(warns[1]:find("[Veron T] event #1: ", 1, true) ~= nil, true, warns[1])
		t.eq(warns[1]:find("boom", 1, true) ~= nil, true, warns[1])
		local stats = s:GetStats()
		t.eq(stats.Errors, 1)
		t.eq(stats.ErrorsSuppressed, 0)
		t.eq(stats.Dispatched, 3)
		t.eq(stats.LastDispatched, 3)
		t.eq(stats.UpdateDepth, 0)
		t.eq(thrower:GetState(), "Fired")
		t.eq(b:GetState(), "Fired")
		t.eq(c:GetState(), "Fired")
		t.eq(s:GetBase(), false)
		t.eq(s:Validate(), true)
		-- a throwing RECURRING callback stays armed and keeps its siblings company
		local fires = 0
		local r = s:Recur(function()
			fires += 1
			error("again")
		end, 1)
		local d = s:Delay(tag("d"), 2)
		captureWarns(function()
			s:Update(1)
			s:Update(1)
		end)
		t.eq(fires, 2)
		t.eq(r:GetState(), "Pending")
		t.eq(table.concat(log), "abcd")
		r:Stop()
	end)

	-- SEM E2 / B-04 #1: policy "error" finishes the pass, then re-raises the FIRST message once at the outermost exit
	t.test("error policy re-raises first after the outermost pass", function()
		local s = newVeron({ OnError = "error" })
		local log, tag = newLog()
		local seen = {}
		s:Delay(function()
			log[#log + 1] = "a"
			error("boom-a")
		end, 1)
		s:Delay(function()
			log[#log + 1] = "b"
			error("boom-b")
		end, 1)
		s:Delay(function()
			log[#log + 1] = "c"
			seen.updating = s:IsUpdating()
			seen.errorsSoFar = s:GetStats().Errors
		end, 1)
		local warns = captureWarns(function()
			local ok, err = pcall(function()
				s:Update(1)
			end)
			seen.ok, seen.err = ok, tostring(err)
		end)
		t.eq(#warns, 0, "the error policy never warns")
		t.eq(seen.ok, false, "Update raised")
		t.eq(seen.err:find("boom-a", 1, true) ~= nil, true, "the FIRST error: " .. seen.err)
		t.eq(seen.err:find("boom-b", 1, true), nil, "the second is counted, not raised")
		t.eq(table.concat(log), "abc", "the pass finished before the raise")
		t.eq(seen.updating, true)
		t.eq(seen.errorsSoFar, 2, "both errors were already counted while c ran")
		-- the instance is consistent after the raise
		local stats = s:GetStats()
		t.eq(stats.Errors, 2)
		t.eq(stats.UpdateDepth, 0)
		t.eq(stats.Dispatched, 3)
		t.eq(s:GetBase(), false)
		t.eq(s:IsUpdating(), false)
		t.eq(rawget(s, "_Errored"), false, "the stored message was cleared by the raise")
		t.eq(s:Validate(), true)
		Oracle.check(s)
		-- a later clean update does not raise again
		s:Delay(tag("d"), 1)
		s:Update(1)
		t.eq(table.concat(log), "abcd")
		-- a nested error after the clean update raises again: the policy is per instance, not one-shot
		s:Delay(function()
			error("boom-e")
		end, 1)
		local ok, err = pcall(function()
			s:Update(1)
		end)
		t.eq(ok, false)
		t.eq(tostring(err):find("boom-e", 1, true) ~= nil, true, tostring(err))
		t.eq(s:GetStats().Errors, 3)
		t.eq(s:GetBase(), false)
	end)

	-- SEM E3 / D11: a function policy gets (message, handle); its own error is warned and never propagates
	t.test("function policy receives (message, handle); its own error is warned", function()
		local got = {}
		local s = newVeron({ OnError = function(message, handle)
			got[#got + 1] = { message = message, handle = handle }
			error("handler broke")
		end })
		local a = s:Delay(function()
			error("boom")
		end, 1)
		local warns = captureWarns(function()
			s:Update(1)
		end)
		t.eq(#got, 1)
		t.eq(type(got[1].message), "string")
		t.eq(got[1].message:find("boom", 1, true) ~= nil, true, got[1].message)
		t.eq(got[1].handle, a, "the handle whose callback threw")
		t.eq(#warns, 1, "the handler's own error is warned once")
		t.eq(warns[1]:find("[Veron T] OnError handler failed for event #1: ", 1, true) ~= nil, true, warns[1])
		t.eq(warns[1]:find("boom", 1, true) ~= nil, true, "…with the callback's message: " .. warns[1])
		t.eq(s:GetStats().Errors, 1)
		t.eq(s:GetStats().UpdateDepth, 0)
		t.eq(s:GetBase(), false)
		-- a well-behaved handler: no warn at all (a second later, past the per-handle rate limit)
		local quiet = {}
		local s2 = newVeron({ Name = "Q", OnError = function(message, handle)
			quiet[#quiet + 1] = { message = message, handle = handle }
		end })
		local b = s2:Delay(function()
			error("soft")
		end, 1)
		warns = captureWarns(function()
			s2:Update(1)
		end)
		t.eq(#warns, 0)
		t.eq(#quiet, 1)
		t.eq(quiet[1].handle, b)
		t.eq(quiet[1].message:find("soft", 1, true) ~= nil, true)
		-- the policy is validated
		local ok = pcall(function()
			Veron.new({ Name = "Bad", OnError = "loud" })
		end)
		t.eq(ok, false, "an unknown policy string is refused")
	end)

	-- SEM E4 / A6: chained siblings are independent handles armed at the parent's fire; one throwing leaves the others alone
	t.test("erroring chained child leaves siblings alone", function()
		local s = newVeron()
		local log, tag = newLog()
		local p = s:Delay(tag("p"), 1)
		local c1 = p:After(function()
			log[#log + 1] = "c1"
			error("child boom")
		end, 1 / 2)
		local c2 = p:After(tag("c2"), 1 / 2)
		local c3 = p:After(tag("c3"), 1)
		t.eq(c1:GetState(), "Chained")
		s:Update(1)
		t.eq(table.concat(log, ","), "p")
		t.eq(c1:GetState(), "Pending")
		t.eq(c2:GetState(), "Pending")
		local warns = captureWarns(function()
			s:Update(1 / 2)
		end)
		t.eq(table.concat(log, ","), "p,c1,c2", "c2 fired although c1 threw")
		t.eq(#warns, 1)
		t.eq(warns[1]:find("event #" .. c1:GetId() .. ": ", 1, true) ~= nil, true, warns[1])
		t.eq(c3:GetState(), "Pending")
		s:Update(1 / 2)
		t.eq(table.concat(log, ","), "p,c1,c2,c3")
		t.eq(s:GetStats().Errors, 1)
		-- an erroring PARENT still arms its children (A10/DV-6), and a throwing child of that parent is isolated too
		table.clear(log)
		local p2 = s:Delay(function()
			log[#log + 1] = "p2"
			error("parent boom")
		end, 1)
		p2:After(function()
			log[#log + 1] = "x"
			error("x boom")
		end, 1 / 4)
		p2:After(tag("y"), 1 / 4)
		captureWarns(function()
			s:Update(1)
			s:Update(1 / 4)
		end)
		t.eq(table.concat(log, ","), "p2,x,y")
	end)
end

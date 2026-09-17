--!nonstrict
--[[
	reentrancy_spec — nested, overlapped (yield) and self-mutating passes
	(docs/DESIGN.md R-C, R-D, §4.2 properties (a)–(j), §4.3, §9
	scheduler/reentrancy_spec row). Every instance runs under Oracle.wrap;
	every callback that can, probes `Validate()` + `Oracle.check` from
	inside, and the last test asserts every probe held.

	Test → DESIGN section:
	  stop self inside own recurring callback while lagging fires once ........ §4.2 (a), §4.3 (S2/L-06)
	  stop a co-due sibling from a callback never fires it and nothing
	    advances twice ........................................................ §4.2 (b), §4.3 (S3/L-02)
	  replace-in-callback idiom lands at the correct due ...................... §4.1 arm (D4), R-B
	  stop then reset in the same callback does not resurrect ................. R-B, §4.3, §5 (S4)
	  sync re-entrant Update dispatches other timers and restores the base .... R-C, §4.2 (c)
	  nested Update under error policy keeps the outer raise and reports once . §4.2 _report/_advanceTo (B-04 #1)
	  recurring callback calls Update(period): bounded at MaxUpdateDepth,
	    never overflows ....................................................... R-C, §2.1 MaxUpdateDepth (B-04 #3)
	  depth cap degrades to advance-only ...................................... R-C, §4.2 _advanceTo
	  yield-overlap (coroutine) keeps other timers firing and drains on resume  R-C, §11 (L-05)
	  out-of-order yield overlap leaves depth 0 and _Base false ............... R-C, §4.2 (d)
	  recurring whose callback yields past its period fires again from the
	    inner pass ............................................................ R-C, §4.2 (c)
	  top-level Delay during a yield window measures from now ................. R-D, §4.2 (e)
	  task.spawn from a callback measures from now ............................ R-D, §4.1 _clockOf
	  Update(0) inside a callback keeps the caller's base after the nested pass R-C (restore), §4.2 (c)
	  a throwing Warn seam leaves UpdateDepth 0 and Base false after the error  §4.2 (h), _diagnose/_report (F4)
	  a corrupted handle field raises the internal-fault message once and
	    leaves the instance consistent ........................................ §4.2 (h), _advanceTo tail
	  sync re-entry chain is bounded per pass: Delay(0)+Update(0)
	    recursion ≤ MaxUpdateDepth × Valve dispatches ......................... §4.2 (c), §11 (see BUILD-NOTES)
	  Destroy from inside own update fires nothing further .................... §4.9 Destroy (N4)
	  Clear from inside a callback: later same-frame handles do not fire ...... §4.3 Clear (mid-update)
	  Validate holds inside every callback above .............................. §3.2 invariants, §9 support
]]

local Veron = require("../../../src/Veron")
local Env = require("../../../src/Veron/Env")
local Oracle = require("../../support/oracle")

local okTask, Task = pcall(require, "@lune/task")

-- Dyadic steps: every due and every clock value below is exact in a double.
local F64 = 1 / 64
local F128 = 1 / 128

-- Probe registry read by the final test: every callback above records whether
-- `Validate()` and the independent oracle walk held at that moment.
local probeTotal = 0
local probeFailures = {}

--[[
	Records one in-callback invariant probe. Never raises: a raise inside a
	callback would be swallowed by the scheduler's error isolation and the
	test would not notice, so the outcome is stored and asserted later.
]]
local function _probe(s, label)
	probeTotal += 1
	local ok, err = pcall(function()
		local valid, reason = s:Validate()
		if valid ~= true then
			error("Validate: " .. tostring(reason), 0)
		end
		Oracle.check(s)
	end)
	if not ok then
		probeFailures[#probeFailures + 1] = label .. ": " .. tostring(err)
	end
end

--[[
	Builds a wrapped instance; `cfg` defaults to `{ Name = "T" }`.
]]
local function _new(cfg)
	cfg = cfg or {}
	if cfg.Name == nil then
		cfg.Name = "T"
	end
	return Oracle.wrap(Veron.new(cfg))
end

--[[
	Installs a collecting Warn seam; returns the list and the restore function.
]]
local function _captureWarns()
	local warns = {}
	local restore = Env.SetWarn(function(msg)
		warns[#warns + 1] = tostring(msg)
	end)
	return warns, restore
end

--[[
	Runs `body` with the Warn seam captured, restores it whatever happens, then
	re-raises. Returns the captured list.
]]
local function _withWarns(body)
	local warns, restore = _captureWarns()
	local ok, err = pcall(body, warns)
	restore()
	if not ok then
		error(err, 0)
	end
	return warns
end

--[[
	A fresh thread started immediately from the caller (Roblox `task.spawn`
	semantics); `@lune/task` under Lune, `coroutine.wrap` anywhere else.
]]
local function _spawn(fn)
	if okTask then
		Task.spawn(fn)
	else
		coroutine.wrap(fn)()
	end
end

local function _resume(co)
	local ok, err = coroutine.resume(co)
	if not ok then
		error("coroutine failed: " .. tostring(err), 0)
	end
end

local function _countMatching(list, pattern)
	local count = 0
	for _, message in list do
		if message:find(pattern) then
			count += 1
		end
	end
	return count
end

local function _tripleIsClear(t, s, label)
	t.eq(rawget(s, "_Base"), false, label .. ": _Base")
	t.eq(rawget(s, "_Firing"), false, label .. ": _Firing")
	t.eq(rawget(s, "_FiringThread"), false, label .. ": _FiringThread")
	t.eq(s:GetBase(), false, label .. ": GetBase")
	t.eq(s:IsUpdating(), false, label .. ": IsUpdating")
	t.eq(s:GetStats().UpdateDepth, 0, label .. ": UpdateDepth")
end

return function(t)
	t.test("stop self inside own recurring callback while lagging fires once", function()
		local s = _new()
		local count = 0
		local h
		h = s:Recur(function()
			count += 1
			_probe(s, "stop self: before Stop")
			h:Stop()
			_probe(s, "stop self: after Stop")
		end, F64, true)                                      -- uncapped: 64 fires owed, legacy would burst
		s:Update(1)
		t.eq(count, 1, "exactly one fire, no backlog")
		t.eq(h:GetState(), "Stopped")
		t.eq(s:GetClocks(), 0)
		t.eq(s:GetStats().Recurring, 0)
		s:Update(1)
		t.eq(count, 1, "nothing fires later either")
		_tripleIsClear(t, s, "after")
	end)

	t.test("stop a co-due sibling from a callback never fires it and nothing advances twice", function()
		local s = _new()
		local fired = { a = 0, b = 0, c = 0, r = 0 }
		local b
		local a = s:Delay(function()
			fired.a += 1
			b:Stop()                                         -- co-due sibling: immediate heapRemove
			_probe(s, "co-due sibling stopped")
		end, F64)
		b = s:Delay(function()
			fired.b += 1
		end, F64)
		local c = s:Delay(function()
			fired.c += 1
		end, F64)
		local r = s:Recur(function()
			fired.r += 1
		end, F64, true)
		s:Update(F64)
		t.eq(fired.a, 1, "a")
		t.eq(fired.b, 0, "b never fires")
		t.eq(fired.c, 1, "c fires once")
		t.eq(fired.r, 1, "r fires once")
		t.eq(b:GetState(), "Stopped")
		t.eq(c:GetState(), "Fired")
		t.eq(s:GetStats().LastDispatched, 3)
		t.eq(r:GetRemaining(), F64, "r re-armed exactly once")
		s:Update(F64)
		t.eq(fired.r, 2)
		t.eq(fired.a + fired.b + fired.c, 2, "one-shots untouched by the second update")
	end)

	t.test("replace-in-callback idiom lands at the correct due", function()
		local s = _new()
		local firedAt = {}
		local h
		local function replacement()
			firedAt[#firedAt + 1] = s:Now()
		end
		h = s:Delay(function()
			firedAt[#firedAt + 1] = s:Now()
			_probe(s, "replace-in-callback")
			h:Stop()                                         -- on the Fired handle: finalizes it silently
			h = s:Delay(replacement, F64)                    -- arms from the firing due, not from now
		end, F64)
		s:Update(3 * F128)                                   -- now = 1.5/64: 1/128 of overshoot
		t.eq(#firedAt, 1)
		t.eq(firedAt[1], 3 * F128)
		t.eq(h:GetState(), "Pending")
		t.eq(h:GetRemaining(), F128, "due = 1/64 + 1/64, not now + 1/64")
		s:Update(F128)                                       -- now = 2/64
		t.eq(#firedAt, 2)
		t.eq(firedAt[2], 2 * F64)
		_tripleIsClear(t, s, "after")
	end)

	t.test("stop then reset in the same callback does not resurrect", function()
		local s = _new()
		local rCount, oCount = 0, 0
		local r, o
		r = s:Recur(function()
			rCount += 1
			r:Stop()
			r:Reset()
			r:Adjust(F64)
			r:SetRemaining(0)
			r:Resume()
			r:Restart()
			_probe(s, "stop then reset (recurring)")
		end, F64)
		o = s:Delay(function()
			oCount += 1
			o:Stop()
			o:Reset()
			o:Restart()
			_probe(s, "stop then reset (one-shot)")
		end, F64)
		s:Update(1)
		t.eq(rCount, 1)
		t.eq(oCount, 1)
		t.eq(r:GetState(), "Stopped")
		t.eq(o:GetState(), "Stopped")
		t.eq(r:Complete(), false)
		t.eq(s:GetClocks(), 0)
		for _ = 1, 8 do
			s:Update(F64)
		end
		t.eq(rCount, 1, "recurring never resurrected")
		t.eq(oCount, 1, "one-shot never resurrected")
		t.eq(rawget(r, "_Fn"), rawget(o, "_Fn"), "both Stopped handles carry the same NOOP")
	end)

	t.test("sync re-entrant Update dispatches other timers and restores the base", function()
		local s = _new()
		local warns = _withWarns(function()
			local log = {}
			local baseBefore, baseAfter, baseInB, bAfterNested
			local b = s:Delay(function()
				baseInB = s:GetBase()
				log[#log + 1] = "b"
			end, 2 * F64)
			local a = s:Delay(function()
				log[#log + 1] = "a"
				baseBefore = s:GetBase()
				s:Update(F64)                                -- nested: now → 2/64, b is due
				bAfterNested = #log
				baseAfter = s:GetBase()                      -- restored: depth is still 1 on the nested exit
				_probe(s, "sync re-entry after nested Update")
				s:Delay(function()
					log[#log + 1] = "c"
					s:Update(0)                              -- a second re-entry: counted, not warned again
				end, F64)                                    -- base 1/64 + 1/64 = 2/64 <= now: same outer pass
			end, F64)
			s:Update(F64)
			t.eq(table.concat(log, ","), "a,b,c")
			t.eq(baseBefore, F64)
			t.eq(baseInB, 2 * F64, "the nested pass fires b from its own due")
			t.eq(baseAfter, F64, "the outer callback keeps its base after the nested pass")
			t.eq(bAfterNested, 2, "b fired inside the nested Update")
			t.eq(s:Now(), 2 * F64)
			t.eq(a:GetState(), "Fired")
			t.eq(b:GetState(), "Fired")
			local stats = s:GetStats()
			t.eq(stats.Reentries, 2)
			t.eq(stats.Dispatched, 3)
			_tripleIsClear(t, s, "after")
		end)
		t.eq(#warns, 1, "re-entry warned once")
		t.eq(_countMatching(warns, "re%-entered"), 1, table.concat(warns, "\n"))
	end)

	t.test("nested Update under error policy keeps the outer raise and reports once", function()
		local s = _new({ OnError = "error" })
		local nestedReturned = false
		local a = s:Delay(function()
			s:Update(0)                                      -- b fires inside and errors; nested exit does not raise
			nestedReturned = true
			_probe(s, "error policy after nested Update")
			error("outerBoom")
		end, F64)
		local b = s:Delay(function()
			error("innerBoom")
		end, F64)
		local ok, err = pcall(function()
			s:Update(F64)
		end)
		t.eq(ok, false, "the outer Update raises")
		t.eq(tostring(err):find("innerBoom", 1, true) ~= nil, true, "first message wins: " .. tostring(err))
		t.eq(nestedReturned, true, "the nested Update returned normally")
		local stats = s:GetStats()
		t.eq(stats.Errors, 2)
		t.eq(stats.Reentries, 1)
		t.eq(rawget(s, "_Errored"), false)
		_tripleIsClear(t, s, "after the raise")
		s:Update(F64)                                        -- reported once: nothing stored to re-raise
		t.eq(a:GetState(), "Fired")
		t.eq(b:GetState(), "Fired")
	end)

	t.test("recurring callback calls Update(period): bounded at MaxUpdateDepth, never overflows", function()
		local s = _new()
		local count, maxDepth = 0, 0
		local r = s:Recur(function()
			count += 1
			local depth = s:GetStats().UpdateDepth
			if depth > maxDepth then
				maxDepth = depth
			end
			_probe(s, "recurring re-enters Update(period)")
			s:Update(F64)                                    -- the handle is due again in every nested pass
		end, F64)
		s:Update(F64)
		t.eq(maxDepth, 8, "real passes stop at MaxUpdateDepth")
		t.eq(count >= 8, true, "one fire per depth at least, got " .. count)
		t.eq(count <= 8 * 9, true, "bounded by depth × (cap + 1), got " .. count)
		t.eq(s:GetStats().Reentries >= 8, true)
		t.eq(r:GetState(), "Pending")
		_tripleIsClear(t, s, "after")
	end)

	t.test("depth cap degrades to advance-only", function()
		local s = _new({ MaxUpdateDepth = 1 })
		local bCount = 0
		local bInside, nowInside
		local b = s:Delay(function()
			bCount += 1
		end, 2 * F64)
		s:Delay(function()
			s:Update(F64)                                    -- depth 1 >= cap: the clock moves, no pass runs
			bInside = bCount
			nowInside = s:Now()
			_probe(s, "depth cap advance-only")
		end, F64)
		s:Update(F64)
		t.eq(bInside, 0, "b did not fire inside the capped Update")
		t.eq(nowInside, 2 * F64, "the clock still advanced")
		t.eq(bCount, 1, "the outer pass re-reads the heap and fires b")
		t.eq(b:GetState(), "Fired")
		local stats = s:GetStats()
		t.eq(stats.Reentries, 1)
		t.eq(stats.Updates, 1, "an advance-only re-entry is not a pass")
		t.eq(stats.Dispatched, 2)
		_tripleIsClear(t, s, "after")
	end)

	t.test("yield-overlap (coroutine) keeps other timers firing and drains on resume", function()
		local s = _new()
		local log = {}
		local baseAfterYield
		s:Delay(function()
			log[#log + 1] = "a1"
			coroutine.yield()
			log[#log + 1] = "a2"
			baseAfterYield = s:GetBase()
			_probe(s, "yield-overlap after resume")
			s:Delay(function()
				log[#log + 1] = "d"
			end, 0)                                          -- already due: drains in the resumed pass
		end, F64)
		local c = s:Delay(function()
			log[#log + 1] = "c"
		end, F64)
		local b = s:Delay(function()
			log[#log + 1] = "b"
		end, 2 * F64)
		local co = coroutine.create(function()
			s:Update(F64)
		end)
		_resume(co)
		t.eq(coroutine.status(co), "suspended")
		t.eq(table.concat(log, ","), "a1")
		t.eq(s:IsUpdating(), true)
		s:Update(F64)                                        -- overlapped pass from the main thread
		t.eq(table.concat(log, ","), "a1,c,b", "siblings fire while a is suspended")
		t.eq(c:GetState(), "Fired")
		t.eq(b:GetState(), "Fired")
		t.eq(s:IsUpdating(), true, "the suspended pass still holds depth 1")
		t.eq(s:GetStats().Reentries, 1)
		_resume(co)
		t.eq(coroutine.status(co), "dead")
		t.eq(table.concat(log, ","), "a1,c,b,a2,d", "drained once, nothing dispatched twice")
		t.eq(baseAfterYield, F64, "the firing thread keeps its base (restored on the overlapped exit)")
		t.eq(s:GetStats().Dispatched, 4)
		_tripleIsClear(t, s, "after")
	end)

	t.test("out-of-order yield overlap leaves depth 0 and _Base false", function()
		local s = _new()
		local log = {}
		local baseInB2, dueOfD
		s:Delay(function()
			log[#log + 1] = "a1"
			coroutine.yield()
			log[#log + 1] = "a2"
			_probe(s, "out-of-order: a resumes first")
		end, F64)
		s:Delay(function()
			log[#log + 1] = "b1"
			coroutine.yield()
			log[#log + 1] = "b2"
			baseInB2 = s:GetBase()                           -- documented: post-resume arms measure from now
			_probe(s, "out-of-order: b resumes last")
			local d = s:Delay(function()
				log[#log + 1] = "d"
			end, 0)
			dueOfD = s:Now() + d:GetRemaining()
		end, 2 * F64)
		local co1 = coroutine.create(function()
			s:Update(F64)
		end)
		local co2 = coroutine.create(function()
			s:Update(F64)
		end)
		_resume(co1)
		_resume(co2)
		t.eq(table.concat(log, ","), "a1,b1")
		t.eq(s:GetStats().UpdateDepth, 2)
		_resume(co1)                                         -- the OUTER pass finishes first
		t.eq(coroutine.status(co1), "dead")
		t.eq(table.concat(log, ","), "a1,b1,a2")
		t.eq(s:GetStats().UpdateDepth, 1, "decremented, never restored")
		t.eq(rawget(s, "_Base"), false, "restored to the outer entry's values")
		_resume(co2)
		t.eq(coroutine.status(co2), "dead")
		t.eq(table.concat(log, ","), "a1,b1,a2,b2,d")
		t.eq(baseInB2, false)
		t.eq(dueOfD, 2 * F64, "armed from now")
		_tripleIsClear(t, s, "after both exits")
	end)

	t.test("recurring whose callback yields past its period fires again from the inner pass", function()
		local s = _new()
		local count = 0
		local bases = {}
		local r = s:Recur(function()
			count += 1
			bases[count] = s:GetBase()
			_probe(s, "yielding recurring fire " .. count)
			if count == 1 then
				coroutine.yield()
			end
		end, F64)
		local co = coroutine.create(function()
			s:Update(F64)
		end)
		_resume(co)
		t.eq(count, 1)
		t.eq(r:GetRemaining(), F64, "re-keyed to 2/64 before the callback")
		s:Update(F64)                                        -- inner pass from the main thread
		t.eq(count, 2, "fired again from the inner pass")
		t.eq(bases[1], F64)
		t.eq(bases[2], 2 * F64)
		_resume(co)
		t.eq(coroutine.status(co), "dead")
		t.eq(count, 2, "the drained outer pass has nothing left")
		t.eq(r:GetRemaining(), F64)
		t.eq(s:GetStats().Reentries, 1)
		_tripleIsClear(t, s, "after")
	end)

	t.test("top-level Delay during a yield window measures from now", function()
		local s = _new()
		local log = {}
		local baseInside
		s:Delay(function()
			baseInside = s:GetBase()
			coroutine.yield()
			log[#log + 1] = "a2"
			_probe(s, "yield window: firing thread resumed")
		end, F64)
		local co = coroutine.create(function()
			s:Update(3 * F128)                               -- now = 3/128, base = 2/128
		end)
		_resume(co)
		t.eq(baseInside, F64)
		t.eq(s:Now(), 3 * F128)
		t.eq(s:GetBase(), false, "the main thread is not the firing thread")
		local h = s:Delay(function()                        -- MAIN thread, callback still suspended
			log[#log + 1] = "h"
		end, F64)
		t.eq(h:GetRemaining(), F64, "due = now + t (5/128), never base + t (4/128)")
		local h2                                             -- a third coroutine behaves the same (R-D)
		coroutine.wrap(function()
			h2 = s:Delay(function()
				log[#log + 1] = "h2"
			end, F64)
		end)()
		t.eq(h2:GetRemaining(), F64)
		_resume(co)
		t.eq(table.concat(log, ","), "a2")
		s:Update(F128)                                       -- now = 4/128: a base-anchored arm would fire here
		t.eq(#log, 1)
		s:Update(F128)                                       -- now = 5/128
		t.eq(table.concat(log, ","), "a2,h,h2")
		_tripleIsClear(t, s, "after")
	end)

	t.test("task.spawn from a callback measures from now", function()
		local s = _new()
		local spawnedBase, direct, spawned
		s:Delay(function()
			direct = s:Delay(function() end, F64)            -- firing thread: base + t = 4/128
			_spawn(function()
				spawnedBase = s:GetBase()
				spawned = s:Delay(function() end, F64)       -- another thread: now + t = 5/128
			end)
			_probe(s, "task.spawn from a callback")
		end, F64)
		s:Update(3 * F128)
		t.eq(spawnedBase, false)
		t.eq(direct:GetRemaining(), F128, "the callback's own arm carries the base")
		t.eq(spawned:GetRemaining(), F64, "the spawned thread's arm measures from now")
		_tripleIsClear(t, s, "after")
	end)

	t.test("Update(0) inside a callback keeps the caller's base after the nested pass", function()
		local s = _new()
		local bCount = 0
		local bInside, base1, base2, baseInB, c
		s:Delay(function()
			bCount += 1
			baseInB = s:GetBase()
		end, 3 * F128)
		s:Delay(function()
			base1 = s:GetBase()
			s:Update(0)                                      -- nested pass fires b (due 3/128 <= now)
			bInside = bCount
			base2 = s:GetBase()
			_probe(s, "Update(0) inside a callback")
			c = s:Delay(function() end, F64)                 -- from the restored base: 2/128 + 2/128
		end, F64)
		s:Update(3 * F128)
		t.eq(base1, F64)
		t.eq(bInside, 1, "b fired inside the nested pass")
		t.eq(baseInB, 3 * F128)
		t.eq(base2, F64, "base restored after the nested pass")
		t.eq(c:GetRemaining(), F128, "the later arm still uses the caller's base")
		t.eq(bCount, 1)
		_tripleIsClear(t, s, "after")
	end)

	t.test("a throwing Warn seam leaves UpdateDepth 0 and Base false after the error", function()
		local s = _new()
		local restore = Env.SetWarn(function()
			error("warn seam broke")
		end)
		local ok, err = pcall(function()
			local log = {}
			s:Delay(function()
				log[#log + 1] = "a"
				_probe(s, "throwing Warn seam: erroring callback")
				error("cb boom")                             -- _report → Env.Warn throws → swallowed
			end, F64)
			s:Delay(function()
				log[#log + 1] = "b"
				s:Update(0)                                  -- re-entry diagnostic → Env.Warn throws → swallowed
			end, F64)
			s:Delay(function()
				log[#log + 1] = "c"
			end, F64)
			s:Update(F64)                                    -- a throwing seam never escapes (F4)
			t.eq(table.concat(log, ","), "a,b,c")
			local stats = s:GetStats()
			t.eq(stats.Errors, 1)
			t.eq(stats.Reentries, 1)
			t.eq(rawget(s, "_Errored"), false)
			_tripleIsClear(t, s, "after the swallowed warn")
			s:Delay(function()
				log[#log + 1] = "d"
			end, F64)
			s:Update(F64)
			t.eq(log[4], "d", "the instance keeps working")

			-- a throwing OnError function falls back to the (throwing) seam: still contained
			local s2 = _new({ Name = "T2", OnError = function()
				error("handler broke")
			end })
			s2:Delay(function()
				error("cb boom 2")
			end, F64)
			s2:Update(F64)
			t.eq(s2:GetStats().Errors, 1)
			_tripleIsClear(t, s2, "after the failing handler")
		end)
		restore()
		if not ok then
			error(err, 0)
		end
	end)

	t.test("a corrupted handle field raises the internal-fault message once and leaves the instance consistent", function()
		local s = _new()
		local rCount, bCount = 0, 0
		local r = s:Recur(function()
			rCount += 1
			_probe(s, "corrupted field: after repair")
		end, F64)
		s:Delay(function()
			bCount += 1
		end, F64)
		rawset(r, "_Period", nil)                            -- the pass body faults on `d + period`
		local ok, err = pcall(function()
			s:Update(F64)
		end)
		t.eq(ok, false, "the fault is raised")
		t.eq(tostring(err):find("Veron 'T': internal fault during Update", 1, true) ~= nil, true, tostring(err))
		t.eq(rCount, 0)
		t.eq(bCount, 0)
		-- raw reads first: the field is still corrupt, so no wrapped call yet
		t.eq(rawget(s, "_UpdateDepth"), 0)
		t.eq(rawget(s, "_Base"), false)
		t.eq(rawget(s, "_Firing"), false)
		t.eq(rawget(s, "_FiringThread"), false)
		t.eq(rawget(s, "_Now"), F64, "the clock advance stands")
		t.eq(rawget(s, "_N"), 2, "both handles still in the heap")
		t.eq(rawget(r, "_State"), 1, "still Pending")
		t.eq(rawget(r, "_HeapIndex") > 0, true)
		rawset(r, "_Period", F64)                            -- repair the one corrupted field
		t.eq(s:Validate(), true, "everything else was left consistent")
		t.eq(s:GetStats().LastDispatched, 0)
		_tripleIsClear(t, s, "after the fault")
		s:Update(0)                                          -- the same entries dispatch normally now
		t.eq(rCount, 1)
		t.eq(bCount, 1)
		s:Update(F64)
		t.eq(rCount, 2)
		_tripleIsClear(t, s, "after recovery")
	end)

	t.test("sync re-entry chain is bounded per pass: Delay(0)+Update(0) recursion ≤ MaxUpdateDepth × Valve dispatches", function()
		-- Tiny knobs so the test terminates whatever the growth law turns out to be (see BUILD-NOTES:
		-- with §4.2 as written every nested pass has its own valve budget and the outer passes keep
		-- dispatching after it trips, which is Σ (Valve+1)^k over k = 1..MaxUpdateDepth, not the
		-- MaxUpdateDepth × Valve bound §4.2 (c) / §11 state). The assertion pins the design's claim.
		local VALVE, DEPTH = 4, 3
		local s = _new({ Valve = VALVE, MaxUpdateDepth = DEPTH })
		local count, maxDepth = 0, 0
		local function chain()
			count += 1
			local depth = rawget(s, "_UpdateDepth")
			if depth > maxDepth then
				maxDepth = depth
			end
			_probe(s, "sync re-entry chain")
			if count > 10000 then
				return                                       -- runaway guard: a hang becomes a failure
			end
			s:Delay(chain, 0)
			s:Update(0)
		end
		s:Delay(chain, 0)
		s:Update(0)
		t.eq(maxDepth, DEPTH, "passes bottom out at MaxUpdateDepth")
		t.eq(s:GetStats().ValveHits >= 1, true, "the valve tripped")
		t.eq(count <= 10000, true, "runaway: more than 10000 dispatches")
		t.eq(count <= DEPTH * VALVE, true, ("dispatched %d, claimed bound %d"):format(count, DEPTH * VALVE))
		_tripleIsClear(t, s, "after")
	end)

	t.test("Destroy from inside own update fires nothing further", function()
		local s = _new()
		local log = {}
		local destroyedInside
		local b = s:Delay(function()
			log[#log + 1] = "b"
		end, F64)
		local r = s:Recur(function()
			log[#log + 1] = "r"
		end, F64)
		local a = s:Delay(function()
			log[#log + 1] = "a"
			_probe(s, "before Destroy")
			s:Destroy()
			destroyedInside = s:IsDestroyed()
		end, 0)
		s:Update(F64)
		t.eq(table.concat(log, ","), "a", "nothing after the destroying callback")
		t.eq(destroyedInside, true)
		t.eq(s:IsDestroyed(), true)
		t.eq(a:GetState(), "Fired")
		t.eq(b:GetState(), "Stopped")
		t.eq(r:GetState(), "Stopped")
		t.eq(s:GetClocks(), 0)
		_tripleIsClear(t, s, "after")
		t.throws(function()
			s:Update(F64)
		end, "Veron 'T': destroyed")
		t.throws(function()
			s:Delay(function() end, 1)
		end, "destroyed")
		t.eq(s:Stop(a), false, "queries stay total")
		t.eq(s:Validate(), true)
		s:Destroy()                                          -- twice is a no-op
		t.eq(#log, 1)
	end)

	t.test("Clear from inside a callback: later same-frame handles do not fire", function()
		local s = _new()
		local log = {}
		local cleared
		local a
		a = s:Delay(function()
			log[#log + 1] = "a"
			_probe(s, "before Clear")
			cleared = s:Clear()
			_probe(s, "after Clear")
		end, F64)
		local d = a:After(function()                         -- armed Pending at a's due BEFORE a's callback
			log[#log + 1] = "d"
		end, 0)
		local b = s:Delay(function()
			log[#log + 1] = "b"
		end, F64)
		local r = s:Recur(function()
			log[#log + 1] = "r"
		end, F64)
		local p = s:Recur(function()
			log[#log + 1] = "p"
		end, F64)
		p:Pause()
		s:Update(F64)
		t.eq(table.concat(log, ","), "a")
		t.eq(cleared, 4, "d, b, r and the paused p")
		t.eq(a:GetState(), "Fired")
		t.eq(d:GetState(), "Stopped")
		t.eq(b:GetState(), "Stopped")
		t.eq(r:GetState(), "Stopped")
		t.eq(p:GetState(), "Stopped")
		t.eq(s:GetClocks(), 0)
		t.eq(s:GetStats().Recurring, 0)
		_tripleIsClear(t, s, "after")
		s:Delay(function()
			log[#log + 1] = "e"
		end, F64)
		s:Update(F64)
		t.eq(table.concat(log, ","), "a,e", "the instance keeps working")
		a:Restart()                                          -- Clear never reaches a Fired handle
		t.eq(a:GetState(), "Pending")
	end)

	t.test("Validate holds inside every callback above", function()
		t.eq(probeTotal > 0, true, "probes ran")
		t.eq(#probeFailures, 0, "failed probes:\n" .. table.concat(probeFailures, "\n"))
	end)
end

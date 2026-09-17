--!nonstrict
--[[
	repros_spec — one pinned test per research id (docs/DESIGN.md §9 regress
	row, §12 WP7). Each test ports the research scenario
	(research/scratch/{legacy,prior,semantics-spec,syncedtimer}/ and the
	research/*.md reports) to Veron and asserts the FIXED behaviour the
	design decided. Ids: `L-`/`F` legacy-bughunt, `B-`/`RF-`
	prior-build-review, `S-` syncedtimer-review. Every instance runs through
	`Oracle.wrap`; numbers are dyadic unless the research id is about the
	1/60 float boundary.
]]

local Veron = require("../../../src/Veron")
local VeronEvent = require("../../../src/Veron/VeronEvent")
local Env = require("../../../src/Veron/Env")
local Legacy = require("../../support/legacy")
local Oracle = require("../../support/oracle")

local DT60 = 1 / 60
local DT64 = 1 / 64
local COLON = "VeronEvent: methods take a colon"

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

local function _find(message, text)
	return string.find(tostring(message), text, 1, true) ~= nil
end

--[[
	Steps `s` by `dt` up to `count` times; returns the frame `done()` first
	held on, or false.
]]
local function _frames(s, dt, count, done)
	for frame = 1, count do
		s:Update(dt)
		if done() then
			return frame
		end
	end
	return false
end

return function(t)
	-----------------------------------------------------------------
	-- Legacy core (research/legacy-bughunt.md, scratch/legacy/exp*.luau)
	-----------------------------------------------------------------

	-- exp2a: a timer created inside a recurring callback waits about one
	-- extra period; fixed: measured from the firing due (D4)
	t.test("L-01", function()
		local s = _new()
		local frames, createdAt, firedAt = 0, false, false
		s:Recur(function()
			if not createdAt then
				createdAt = frames
				s:Delay(function()
					firedAt = frames
				end, 1 / 2)
			end
		end, 1)
		_frames(s, DT64, 200, function()
			frames += 1
			return firedAt ~= false
		end)
		-- the frame counter runs after the update, so read the frames back
		t.eq(createdAt, 63, "recur fired on the 64th update (counter lags by one)")
		t.eq(firedAt, 95, "nested delay fired 32 frames = 0.5 s later")
		t.eq(s:Now(), 96 * DT64)
		-- at 1/60 the wait is 0.5 within one frame, never a full period
		local s2 = _new()
		local t0, t1 = false, false
		local now = 0
		s2:Recur(function()
			if not t0 then
				t0 = now
				s2:Delay(function()
					t1 = now
				end, 1 / 2)
			end
		end, 1)
		for _ = 1, 200 do
			now += DT60
			s2:Update(DT60)
			if t1 then
				break
			end
		end
		t.near(t1 - t0, 1 / 2, DT60 + 1e-9, "wait is 0.5 within one frame")
		t.eq(s:Validate(), true)
	end)

	-- exp1a/1b/1c/1d/1e: swap-on-remove double-charges dt and double-fires;
	-- fixed by absolute dues on an index-tracked heap
	t.test("L-02", function()
		-- A: B's callback stops A (lower slot); C keeps its exact remaining
		local s = _new()
		local a = s:Delay(function() end, 10)
		s:Delay(function()
			a:Stop()
		end, 1 / 2)
		local c = s:Recur(function() end, 10)
		s:Update(1)
		t.eq(a:GetState(), "Stopped")
		t.eq(c:GetRemaining(), 9, "C charged exactly one dt")
		-- B: a recurring that stops a lower entry on its first fire fires once
		local s2 = _new()
		local a2 = s2:Delay(function() end, 10)
		local fires = 0
		s2:Recur(function()
			fires += 1
			if fires == 1 then
				a2:Stop()
			end
		end, 1, true)
		s2:Update(1)
		t.eq(fires, 1, "no double fire")
		s2:Update(1 / 64)
		t.eq(fires, 1, "not early either")
		-- C: replace idiom (stop old, create new) lands at base + delay
		local s3 = _new()
		local a3 = s3:Delay(function() end, 10)
		local replacement, replacementFired = nil, false
		s3:Delay(function()
			a3:Stop()
			replacement = s3:Delay(function()
				replacementFired = true
			end, 1)
		end, 1 / 2)
		s3:Update(1)
		t.eq(replacementFired, false, "never fires in the update that created it")
		t.eq(replacement:GetRemaining(), 1 / 2, "due = 1/2 + 1, no extra dt")
		-- D: create then stop: the new entry is not moved into the freed slot
		local s4 = _new()
		local a4 = s4:Delay(function() end, 10)
		local late
		s4:Delay(function()
			late = s4:Delay(function() end, 3)
			a4:Stop()
		end, 1 / 2)
		s4:Update(1)
		t.eq(late:GetRemaining(), 5 / 2, "3 - 1/2 residual, no extra dt")
		-- E: the tail collapse the legacy nil-guard hides never raises here
		local s5 = _new()
		local a5 = s5:Delay(function() end, 10)
		local b5 = s5:Delay(function() end, 10)
		s5:Delay(function()
			b5:Stop()
		end, 1 / 2)
		s5:Update(1)
		t.eq(a5:GetRemaining(), 9)
		t.eq(s5:GetClocks(), 1)
		t.eq(s5:Validate(), true)
	end)

	-- exp2c: a throwing callback poisons the carry until the next successful
	-- update; fixed: the carry is per dispatch and cleared on every path
	t.test("L-03", function()
		local s = _new()
		local warnings = _withWarnings(function()
			s:Recur(function()
				error("boom")
			end, 1)
			for _ = 1, 64 do
				s:Update(DT64)
			end
		end)
		t.eq(#warnings, 1, "the error was reported")
		t.eq(s:GetBase(), false, "no carry between updates")
		local late = s:Delay(function() end, 1 / 2)
		t.eq(late:GetRemaining(), 1 / 2, "top-level delay measures from now")
		-- one-shot variant: err would be negative; a top-level short delay
		-- never fires synchronously and always returns a real handle
		local s2 = _new()
		local firedSync = false
		_withWarnings(function()
			s2:Delay(function()
				error("boom")
			end, 1 / 64)
			s2:Update(1 / 2)
		end)
		local h = s2:Delay(function()
			firedSync = true
		end, 1 / 8)
		t.eq(firedSync, false, "not fired inside Delay()")
		t.eq(h:GetState(), "Pending")
		t.eq(h:GetRemaining(), 1 / 8)
		s2:Update(1 / 8)
		t.eq(firedSync, true)
		t.eq(s2:GetStats().Errors, 1)
		t.eq(s2:Validate(), true)
	end)

	-- exp2e/2f/2g: the immediate-fire path degrades a nested recur to a
	-- one-shot + noop, hangs on recur(fn, 0) and runs fn before delay()
	-- returns; fixed: no synchronous path, recur 0 rejected
	t.test("L-04", function()
		local s = _new()
		local userFires = 0
		local handle
		s:Delay(function()
			handle = s:Recur(function()
				userFires += 1
			end, 1 / 8)
		end, 1 / 2)
		s:Update(1)
		t.eq(handle:IsRecurring(), true)
		t.eq(handle:GetState(), "Pending", "a real recurring handle")
		t.eq(userFires, 4, "dues 5/8, 6/8, 7/8, 1 fire later in the same update")
		for _ = 1, 80 do
			s:Update(1 / 8)
		end
		t.eq(userFires, 84, "keeps recurring on its grid")
		-- exp2e: the handle exists when its callback runs
		local s2 = _new()
		local seenHandle, innerFires = "unset", 0
		s2:Delay(function()
			local h
			h = s2:Delay(function()
				innerFires += 1
				seenHandle = h
				h:Stop()
			end, 1 / 8)
		end, 1 / 2)
		s2:Update(1)
		t.eq(innerFires, 1, "the past-due nested one-shot fired in the same update")
		t.eq(getmetatable(seenHandle), VeronEvent, "h was assigned before fn ran")
		t.eq(seenHandle:GetState(), "Stopped", "a Stop on the Fired handle finalized it")
		t.eq(s2:GetStats().Errors, 0)
		-- exp2g: recur(fn, 0) inside a callback is rejected, never a hang
		local s3 = _new()
		local nestedError
		s3:Delay(function()
			local ok, err = pcall(function()
				s3:Recur(function() end, 0)
			end)
			nestedError = not ok and err
		end, 1 / 2)
		s3:Update(1)
		t.eq(_find(nestedError, "expected recur `delay` greater than zero"), true)
		s3:Update(1 / 64)
		t.eq(s3:GetClocks(), 0)
		t.eq(s3:Validate(), true)
	end)

	-- exp6b: a yielding callback suspends update() mid-loop and the next
	-- frame runs concurrently on the same array; fixed: R-C depth counter,
	-- in-place mutations, siblings keep firing, no double-charged dt
	t.test("L-05", function()
		local s = _new()
		local a = s:Recur(function() end, 10, true)
		local siblingFired, resumedArmFired = false, false
		local depthInside, baseInside
		local yielder = s:Delay(function()
			coroutine.yield()
			depthInside = s:GetStats().UpdateDepth
			baseInside = s:GetBase()
			s:Delay(function()
				resumedArmFired = true
			end, 1 / 2)
		end, 1 / 2)
		local c = s:Delay(function() end, 10)
		s:Delay(function()
			siblingFired = true
		end, 3 / 2)
		local co = coroutine.create(function()
			s:Update(1)
		end)
		t.eq(coroutine.resume(co), true)
		t.eq(coroutine.status(co), "suspended", "frame 1 is suspended inside the callback")
		t.eq(yielder:GetState(), "Fired")
		t.eq(s:IsUpdating(), true)
		local warnings = _withWarnings(function()
			s:Update(1)                                   -- frame 2 runs while frame 1 is suspended
		end)
		t.eq(siblingFired, true, "frame 2 kept the sibling firing")
		t.eq(#warnings, 1, "re-entry warned once")
		t.eq(s:Now(), 2)
		t.eq(coroutine.resume(co), true)
		t.eq(coroutine.status(co), "dead")
		t.eq(depthInside, 1, "the resumed callback still sees its own pass")
		t.eq(baseInside, 1 / 2, "frame 2 restored the base of the suspended dispatch")
		t.eq(resumedArmFired, true, "due 1/2 + 1/2 <= now 2: dispatched by the resumed pass")
		t.eq(a:GetRemaining(), 8, "A charged 2 s over two frames, never 3")
		t.eq(c:GetRemaining(), 8)
		t.eq(s:GetStats().UpdateDepth, 0)
		t.eq(s:GetBase(), false)
		t.eq(s:GetStats().Reentries, 1)
		t.eq(s:Validate(), true)
	end)

	-- exp3d: a recurring that stops itself while lagging keeps firing this
	-- frame; fixed: the stop removes the re-keyed entry (exactly one fire)
	t.test("L-06", function()
		local s = _new()
		local fires = 0
		local h
		h = s:Recur(function()
			fires += 1
			h:Stop()
		end, 1 / 8, true)
		s:Update(7 / 16)
		t.eq(fires, 1)
		t.eq(h:GetState(), "Stopped")
		t.eq(s:GetClocks(), 0)
		t.eq(s:GetStats().Recurring, 0)
		s:Update(1)
		t.eq(fires, 1)
		t.eq(s:Validate(), true)
	end)

	-- exp8b: delay(fn, 0/0) / math.huge accepted as permanent zombies;
	-- fixed: rejected with the finite-number message (Q-J3)
	t.test("L-07", function()
		local s = _new()
		local fn = function() end
		for _, bad in { 0 / 0, math.huge, -math.huge } do
			t.throws(function()
				s:Delay(fn, bad)
			end, "expected `delay` to be a finite number")
			t.throws(function()
				s:Recur(fn, bad)
			end, "expected `delay` to be a finite number")
		end
		for _ = 1, 100 do
			s:Update(1)
		end
		t.eq(s:GetClocks(), 0, "no zombie")
		t.eq(s:GetStats().HeapSize, 0)
		t.eq(s:Validate(), true)
	end)

	-- exp5e/5f/5g: reset() inside a recurring callback drifts the phase and
	-- cancels catch-up; reset on a fired one-shot is a silent no-op;
	-- fixed: reset is a full period from now (D9), terminal handles are
	-- no-ops and Restart() is the explicit re-arm
	t.test("L-09", function()
		local s = _new()
		local fireFrames = {}
		local frame = 0
		local r
		r = s:Recur(function()
			fireFrames[#fireFrames + 1] = frame
			r:Reset()
		end, 1 / 8)
		for _ = 1, 64 do
			frame += 1
			s:Update(DT64)
		end
		t.eq(#fireFrames, 8, "8 fires in 64 frames at period 1/8")
		for index = 2, #fireFrames do
			t.eq(fireFrames[index] - fireFrames[index - 1], 8, "no phase drift")
		end
		-- lag then reset: the explicit reset replaces the catch-up (one fire)
		local s2 = _new()
		local lagged = 0
		local r2
		r2 = s2:Recur(function()
			lagged += 1
			r2:Reset()
		end, 1 / 8, true)
		s2:Update(1)
		t.eq(lagged, 1, "reset from now cancels the backlog")
		t.eq(r2:GetRemaining(), 1 / 8)
		-- one-shot: reset inside own callback and after the fire are no-ops
		local s3 = _new()
		local fires = 0
		local h
		h = s3:Delay(function()
			fires += 1
			h:Reset()
		end, 1 / 2)
		for _ = 1, 128 do
			s3:Update(DT64)
		end
		t.eq(fires, 1)
		t.eq(h:GetState(), "Fired")
		t.eq(h:Reset(), h)
		t.eq(h:GetState(), "Fired", "reset after the fire is a no-op")
		h:Restart()
		t.eq(h:GetState(), "Pending", "Restart is the explicit re-arm")
		s3:Update(1 / 2)
		t.eq(fires, 2)
		t.eq(s3:Validate(), true)
	end)

	-- exp4a/4b: after() on a terminal parent is a silent never-fire;
	-- fixed: Fired → arms from the caller's clock, Stopped → Stopped child,
	-- never the parent
	t.test("L-11", function()
		local s = _new()
		local parent = s:Delay(function() end, 1 / 2)
		s:Update(1)
		local ran = false
		local child = parent:After(function()
			ran = true
		end, 1 / 8)
		t.eq(child ~= parent, true)
		t.eq(child:GetState(), "Pending")
		s:Update(1 / 8)
		t.eq(ran, true, "after() on a Fired parent fires")
		-- from inside the parent's own callback: from the parent's ideal due
		local s2 = _new()
		local inner, innerRan = nil, false
		local p2
		p2 = s2:Delay(function()
			inner = p2:After(function()
				innerRan = true
			end, 1 / 8)
		end, 1 / 2)
		s2:Update(3 / 4)
		t.eq(inner:GetState(), "Fired", "due 1/2 + 1/8 <= 3/4: fired in the same update")
		t.eq(innerRan, true)
		-- Stopped parent: a born-Stopped child, no validation, never fires
		local s3 = _new()
		local stopped = s3:Delay(function() end, 1)
		stopped:Stop()
		local born = stopped:After(function()
			innerRan = "never"
		end, 1 / 8)
		t.eq(born ~= stopped, true)
		t.eq(born:GetState(), "Stopped")
		t.eq(born:IsActive(), false)
		s3:Update(1)
		t.eq(innerRan, true)
		t.eq(s3:GetClocks(), 0)
		t.eq(s3:Validate(), true)
	end)

	-- exp8d: same-frame order is newest-first and scrambled by removals;
	-- fixed: (due, Id) FIFO (D23)
	t.test("L-13", function()
		local s = _new()
		local order = {}
		for index = 1, 5 do
			s:Delay(function()
				order[#order + 1] = index
			end, 1)
		end
		s:Update(1)
		t.eq(table.concat(order, ","), "1,2,3,4,5")
		local s2 = _new()
		order = {}
		local handles = {}
		for index = 1, 6 do
			handles[index] = s2:Delay(function()
				order[#order + 1] = index
			end, 1)
		end
		handles[1]:Stop()
		handles[2]:Stop()
		s2:Update(1)
		t.eq(table.concat(order, ","), "3,4,5,6", "removals never reorder")
		t.eq(s2:Validate(), true)
	end)

	-- exp8e: remove(number) removes by array index or raises "table index
	-- is nil"; fixed: non-handles are a silent false (Strict → error)
	t.test("L-15", function()
		local s = _new()
		local a = s:Delay(function() end, 1)
		s:Delay(function() end, 1)
		t.eq(s.remove(7), false)
		t.eq(s.remove(1), false)
		t.eq(s:Stop(1), false)
		t.eq(s:Remove("1"), false)
		t.eq(s:GetClocks(), 2, "nothing removed by index")
		t.eq(a:GetState(), "Pending")
		s:SetStrict(true)
		t.throws(function()
			s:Stop(7)
		end, "Veron 'T': expected a VeronEvent, got number")
		t.eq(s:Stop(nil), false, "nil stays silent under Strict")
		t.eq(s:GetClocks(), 2)
		t.eq(s:Validate(), true)
	end)

	-- exp6a: a nested update() from a callback double-charges dt and
	-- clobbers the carry; fixed: a real nested pass (R-C), the base is
	-- restored for the rest of the callback, counted and warned once
	t.test("L-16", function()
		local s = _new()
		local a = s:Delay(function() end, 10)
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
		t.eq(baseAfter, 1 / 2, "the carry survives the nested pass")
		t.eq(nestedFired, true, "due 1/2 + 1/2 <= now 2: fired by the outer pass")
		t.eq(a:GetRemaining(), 8, "A charged once per update (1 + 1)")
		t.eq(s:GetStats().Reentries, 1)
		t.eq(s:GetStats().UpdateDepth, 0)
		t.eq(#warnings, 1)
		t.eq(_find(warnings[1], "re-entered"), true)
		t.eq(s:Validate(), true)
	end)

	-----------------------------------------------------------------
	-- Prior build (research/prior-build-review.md, scratch/prior/NN_*.luau)
	-----------------------------------------------------------------

	-- 03 §4-6: adjust / pause+resume inside a lagging recurring callback
	-- re-armed at due <= now and looped forever; fixed: explicit ops
	-- measure from now (D4), at most one extra fire this pass
	t.test("B-01", function()
		local s = _new()
		local fires = 0
		local h
		h = s:Recur(function()
			fires += 1
			if fires >= 50 then
				h:Stop()
				return
			end
			h:Adjust(1)
		end, 1)
		s:Update(5 / 2)
		t.eq(fires, 2, "adjust(same) while lagging: exactly 2 fires")
		t.eq(h:GetState(), "Pending")
		t.eq(s:GetStats().ValveHits, 0)
		-- a smaller total, not lagging by a full period
		local s2 = _new()
		local fires2 = 0
		local h2
		h2 = s2:Recur(function()
			fires2 += 1
			if fires2 >= 50 then
				h2:Stop()
				return
			end
			h2:Adjust(1 / 16)
		end, 1)
		s2:Update(15 / 8)
		t.eq(fires2 <= 2, true, "adjust(smaller): bounded (" .. fires2 .. ")")
		t.eq(fires2 >= 1, true)
		-- pause + resume inside the lagging callback
		local s3 = _new()
		local fires3 = 0
		local h3
		h3 = s3:Recur(function()
			fires3 += 1
			if fires3 >= 50 then
				h3:Stop()
				return
			end
			h3:Pause()
			h3:Resume()
		end, 1)
		s3:Update(5 / 2)
		t.eq(fires3, 2, "pause+resume while lagging: exactly 2 fires")
		t.eq(h3:GetRemaining(), 1, "resumed from now with the frozen remaining")
		t.eq(s3:Validate(), true)
	end)

	-- 10 §2: zero-delay self-reschedule from a callback is a busy loop;
	-- fixed: the runaway valve (D5) stops the pass at Valve, warns once
	-- via the diagnostic channel and resumes on the next update
	t.test("B-02", function()
		local s = _new()
		local fires = 0
		local function tick()
			fires += 1
			if fires < 3000 then
				s:Delay(tick, 0)
			end
		end
		s:Delay(tick, 0)
		local warnings = _withWarnings(function()
			s:Update(DT64)
		end)
		t.eq(fires, 1001, "one pre-existing fire plus Valve nested arms")
		t.eq(s:GetStats().ValveHits, 1)
		t.eq(#warnings, 1, "warned once")
		t.eq(_find(warnings[1], "runaway valve"), true)
		t.eq(s:GetClocks(), 1, "the remainder stays keyed for the next update")
		_withWarnings(function()
			s:Update(0)
		end)
		t.eq(fires, 2002, "resumes next update, Valve + 1 more")
		_withWarnings(function()
			s:Update(0)
			s:Update(0)
		end)
		t.eq(fires, 3000, "nothing lost")
		t.eq(s:GetClocks(), 0)
		-- top-level delay(fn, 0) fires on the next update, never synchronously
		local topFired = false
		s:Delay(function()
			topFired = true
		end, 0)
		t.eq(topFired, false)
		s:Update(0)
		t.eq(topFired, true)
		t.eq(s:Validate(), true)
	end)

	-- 04 / 16 §2: timers created inside a RECURRING callback fire one
	-- parent period earlier than legacy; pinned as the decision (Q-J1)
	-- with the LegacyRecurBase knob reproducing the quirk
	t.test("B-03", function()
		local function firstInnerFire(cfg)
			local s = _new(cfg)
			local firedAt, armed = false, false
			s:Recur(function()
				if not armed then
					armed = true
					s:Recur(function()
						if not firedAt then
							firedAt = s:Now()
						end
					end, 1 / 2)
				end
			end, 1)
			for _ = 1, 200 do
				s:Update(DT64)
				if firedAt then
					break
				end
			end
			return firedAt
		end
		t.eq(firstInnerFire(), 3 / 2, "new: base + period")
		t.eq(firstInnerFire({ LegacyRecurBase = true }), 5 / 2, "knob: next due + period")
		-- the legacy shim agrees with the knob
		local group = Legacy.group()
		local legacyAt, armed, now = false, false, 0
		Legacy.recur(group, function()
			if not armed then
				armed = true
				Legacy.recur(group, function()
					if not legacyAt then
						legacyAt = now
					end
				end, 1 / 2)
			end
		end, 1)
		for _ = 1, 200 do
			now += DT64
			Legacy.update(group, DT64)
			if legacyAt then
				break
			end
		end
		t.eq(legacyAt, 5 / 2)
	end)

	-- 02: nested update() lost the outer "error" raise, broke the carry for
	-- chained children and recursed into the same handle; fixed: R-C
	t.test("B-04", function()
		-- 1: the outer raise survives a nested update under "error"
		local s = _new({ OnError = "error" })
		s:Delay(function()
			error("boom-from-A")
		end, 1)
		s:Delay(function()
			s:Update(0)
		end, 1)
		local raises = 0
		local warnings = _withWarnings(function()
			local ok, err = pcall(function()
				s:Update(1)
			end)
			if not ok then
				raises += 1
				t.eq(_find(err, "boom-from-A"), true)
			end
		end)
		t.eq(raises, 1, "raised once, at the outermost exit")
		t.eq(#warnings, 1, "the re-entry diagnostic, never the error itself")
		t.eq(s:GetStats().UpdateDepth, 0)
		-- 2: a chained child keeps the parent's due through a nested update
		local s2 = _new()
		local childBase, childNow
		local parent = s2:Delay(function()
			s2:Update(5)
		end, 1)
		parent:After(function()
			childBase = s2:GetBase()
			childNow = s2:Now()
		end, 1)
		_withWarnings(function()
			s2:Update(1)
		end)
		t.eq(childBase, 2, "child armed at parent due 1 + 1 before the callback")
		t.eq(childNow, 6, "dispatched by the nested pass")
		t.eq(s2:GetBase(), false)
		-- 3: a recurring callback calling Update(period) is bounded at 8
		local s3 = _new()
		local maxDepth, fires = 0, 0
		s3:Recur(function()
			fires += 1
			local depth = s3:GetStats().UpdateDepth
			if depth > maxDepth then
				maxDepth = depth
			end
			if fires < 200 then
				s3:Update(1)
			end
		end, 1)
		_withWarnings(function()
			s3:Update(1)
		end)
		t.eq(maxDepth, 8, "MaxUpdateDepth")
		t.eq(fires < 200, true, "terminated by the depth cap and the catch-up cap, not the guard")
		t.eq(s3:GetStats().UpdateDepth, 0)
		t.eq(s3:GetStats().Reentries >= 8, true)
		t.eq(s3:Validate(), true)
	end)

	-- 09 / 05 §3 / 11 §3: NaN/inf/negative dt and TimeScale, NaN period
	-- accepted; fixed: rejected with prefixed errors before any state change
	t.test("B-05", function()
		local s = _new()
		local fn = function() end
		local h = s:Delay(fn, 3600)
		for _, bad in { 0 / 0, math.huge, -math.huge, -1, "0.5" } do
			local ok, err = pcall(function()
				s:Update(bad)
			end)
			t.eq(ok, false)
			t.eq(_find(err, "Veron 'T': Update(dt) expects a finite number >= 0, got "), true)
		end
		t.throws(function()
			s:Update(nil)
		end, "got nil")
		t.eq(s:Now(), 0)
		t.eq(h:GetRemaining(), 3600)
		for _, bad in { 0 / 0, math.huge, -1 } do
			t.throws(function()
				s:SetTimeScale(bad)
			end, "option 'TimeScale' expects a finite number >= 0")
		end
		t.eq(s:GetTimeScale(), 1)
		t.throws(function()
			Veron.new({ TimeScale = 0 / 0 })
		end, "Veron: option 'TimeScale' expects a finite number >= 0")
		t.throws(function()
			s:Delay(fn, 0 / 0)
		end, "finite number")
		t.throws(function()
			s:Recur(fn, 0 / 0)
		end, "finite number")
		-- heap order stays sound: the shortest delay fires first
		local log = {}
		s:Delay(function()
			log[#log + 1] = "d1/8"
		end, 1 / 8)
		s:Delay(function()
			log[#log + 1] = "d1/4"
		end, 1 / 4)
		s:Delay(function()
			log[#log + 1] = "d1/16"
		end, 1 / 16)
		s:Update(1 / 16 + 1 / 128)
		t.eq(table.concat(log, ","), "d1/16")
		s:Update(1 / 16)
		t.eq(table.concat(log, ","), "d1/16,d1/8")
		t.eq(s:Validate(), true)
	end)

	-- 01 §(8) / 07 §3: the capped re-arm resurrected a handle its own
	-- callback stopped, paused or reset; fixed: re-key IN PLACE before the
	-- callback (D3), so the callback's own op always wins
	t.test("B-06", function()
		local s = _new({ MaxCatchUp = 1 })
		local fires = 0
		local h
		h = s:Recur(function()
			fires += 1
			h:Stop()
		end, 1)
		s:Update(1)
		t.eq(fires, 1)
		t.eq(h:GetState(), "Stopped")
		t.eq(s:GetStats().HeapSize, 0, "no phantom entry")
		s:Update(1)
		t.eq(fires, 1)
		-- pause inside own callback under the cap keeps the full period
		local s2 = _new({ MaxCatchUp = 1 })
		local fires2 = 0
		local h2
		h2 = s2:Recur(function()
			fires2 += 1
			h2:Pause()
		end, 1)
		s2:Update(1)
		t.eq(h2:GetState(), "Paused")
		t.eq(h2:GetRemaining(), 1, "remaining = the re-keyed period")
		h2:Resume()
		s2:Update(1 / 64)
		t.eq(fires2, 1, "no immediate re-fire on resume")
		s2:Update(63 / 64)
		t.eq(fires2, 2)
		-- reset inside a capped callback is not overridden by a second entry
		local s3 = _new({ MaxCatchUp = 1 })
		local h3
		h3 = s3:Recur(function()
			h3:Reset()
		end, 1)
		s3:Update(3 / 2)
		t.eq(s3:GetStats().HeapSize, 1, "one entry")
		t.eq(h3:GetRemaining(), 1, "reset from now = 1.5 -> due 2.5")
		t.eq(s3:Validate(), true)
	end)

	-- 06 §4: after() on a terminal handle returned the parent itself;
	-- fixed: always a child (Pending on Fired, Stopped on Stopped)
	t.test("B-07", function()
		local s = _new()
		local returned, p
		local never = 0
		p = s:Delay(function()
			returned = p:After(function()
				never += 1
			end, 1 / 8)
		end, 1)
		s:Update(1)
		t.eq(returned ~= p, true, "never the parent")
		t.eq(returned:isInstanceOf(VeronEvent), true)
		t.eq(returned:GetState(), "Pending")
		s:Update(1 / 8)
		t.eq(never, 1, "the child fires")
		local stopped = s:Delay(function() end, 1)
		stopped:Stop()
		local child = stopped:After(function() end, 1)
		t.eq(child ~= stopped, true)
		t.eq(child:GetState(), "Stopped")
		t.eq(child.class, VeronEvent)
		t.eq(s:Validate(), true)
	end)

	-- 16 §1: a parent whose callback errors still arms its after()
	-- children (legacy killed the chain); pinned as the decision (A10)
	t.test("B-13", function()
		local s = _new()
		local childFired = false
		local warnings = _withWarnings(function()
			local parent = s:Delay(function()
				error("parent-failed")
			end, 1)
			parent:After(function()
				childFired = true
			end, 1)
			s:Update(1)
			t.eq(childFired, false, "armed, not yet due")
			s:Update(1)
		end)
		t.eq(childFired, true)
		t.eq(#warnings, 1)
		t.eq(s:GetStats().Errors, 1)
		t.eq(s:Validate(), true)
	end)

	-- 06 §5: getRemaining() on a Chained child returns its delay, not the
	-- time until fire; pinned as the documented value (§5 GetRemaining row)
	t.test("B-14", function()
		local s = _new()
		local parent = s:Delay(function() end, 5)
		local child = parent:After(function() end, 1)
		t.eq(child:GetRemaining(), 1, "Chained: its own delay")
		t.eq(s:GetRemaining(child), 1)
		s:Update(5)
		t.eq(child:GetState(), "Pending")
		t.eq(child:GetRemaining(), 1, "armed at parent due + delay")
		s:Update(1)
		t.eq(child:GetState(), "Fired")
		t.eq(child:GetRemaining(), 0)
		t.eq(s:Validate(), true)
	end)

	-- 15 §1: handle dot-call misuse gave an internal `_state` error;
	-- fixed: the colon guard with a user-facing message (level 2)
	t.test("B-18", function()
		local s = _new()
		local h = s:Delay(function() end, 1)
		for _, name in { "Stop", "stop", "Reset", "reset", "Adjust", "adjust", "Pause", "GetState", "After", "Describe" } do
			local ok, err = pcall(function()
				h[name]()
			end)
			t.eq(ok, false, name)
			t.eq(_find(err, COLON), true, name .. ": " .. tostring(err))
			t.eq(_find(err, "_state"), false)
		end
		local ok, err = pcall(function()
			h.Adjust(1)
		end)
		t.eq(ok, false)
		t.eq(_find(err, COLON), true)
		t.eq(h:GetState(), "Pending", "nothing changed")
		t.eq(s:Validate(), true)
	end)

	-- review-findings RF-001 family: adjust on a zero-period one-shot
	-- produced a NaN due; fixed: frac = 1 when period == 0 (§4.5)
	t.test("RF-001", function()
		local s = _new()
		local fired = false
		local h = s:Delay(function()
			fired = true
		end, 0)
		t.eq(h:Adjust(5), h)
		t.eq(h:GetRemaining(), 5, "the whole new total, never NaN")
		t.eq(h:GetPeriod(), 5)
		s:Update(1 / 64)
		t.eq(fired, false, "not on the next tick")
		s:Update(5 - 1 / 64)
		t.eq(fired, true)
		t.throws(function()
			s:Delay(function() end, math.huge)
		end, "finite number")
		t.eq(s:Validate(), true)
	end)

	-- RF-006 family: pause() twice or on a Chained child raised a raw
	-- "illegal transition"; fixed: every cell of §5 is total
	t.test("RF-006", function()
		local s = _new()
		local h = s:Delay(function() end, 5)
		h:Pause()
		t.eq(h:Pause(), h, "pause on Paused is a no-op")
		t.eq(h:GetState(), "Paused")
		t.eq(h:GetRemaining(), 5)
		local parent = s:Delay(function() end, 5)
		local child = parent:After(function() end, 1)
		t.eq(child:Pause(), child, "pause on Chained never raises")
		t.eq(child:GetState(), "Chained")
		s:Update(5)
		t.eq(child:GetState(), "Paused", "parent fired: Paused with remaining = delay (A8)")
		t.eq(child:GetRemaining(), 1)
		local pending = s:Delay(function() end, 1)
		t.eq(pending:Resume(), pending, "resume on Pending is a no-op")
		t.eq(pending:GetState(), "Pending")
		t.eq(s:Validate(), true)
	end)

	-- RF-010 family: with the cap the post-loop re-arm resurrected a
	-- self-stopped recurring as a phantom entry (stale went negative);
	-- fixed: terminal handles are never re-armed, counters stay exact
	t.test("RF-010", function()
		local s = _new({ MaxCatchUp = 1 })
		local handles, fires = {}, 0
		for index = 1, 100 do
			local h
			h = s:Recur(function()
				fires += 1
				h:Stop()
			end, 1 / 2)
			handles[index] = h
		end
		s:Update(1)
		s:Update(1)
		t.eq(fires, 100, "each fired once")
		for _, h in handles do
			t.eq(h:GetState(), "Stopped")
		end
		local stats = s:GetStats()
		t.eq(stats.HeapSize, 0)
		t.eq(stats.Pending, 0)
		t.eq(stats.Recurring, 0)
		t.eq(s:GetClocks(), 0)
		t.eq(s:Validate(), true)
	end)

	-----------------------------------------------------------------
	-- SyncedTimer (research/syncedtimer-review.md, scratch/syncedtimer/)
	-----------------------------------------------------------------

	-- S-force: ForceEventComplete only fired when the item reached the heap
	-- top; fixed: Complete re-keys to now (next update), CompleteNow fires
	-- synchronously — whatever the heap position
	t.test("S-01", function()
		local s = _new()
		local aFired, bFired = false, false
		local a = s:Delay(function()
			aFired = true
		end, 100)
		local b = s:Delay(function()
			bFired = true
		end, 200)
		s:Update(5)
		t.eq(b:Complete(), true)
		t.eq(bFired, false, "deferred: not yet")
		s:Update(0)
		t.eq(bFired, true, "fires on the next update at t = 5, not at t = 100")
		t.eq(aFired, false)
		t.eq(s:Now(), 5)
		t.eq(a:CompleteNow(), true)
		t.eq(aFired, true, "synchronous")
		t.eq(s:GetClocks(), 0)
		t.eq(s:Validate(), true)
	end)

	-- S-adjust: AdjustTime anchored at the original start fired `elapsed`
	-- seconds early; fixed: ratio-preserving from now (R1)
	t.test("S-02", function()
		local s = _new()
		local fired = false
		local h = s:Delay(function()
			fired = true
		end, 10)
		s:Update(5)
		h:Adjust(20)
		t.eq(h:GetRemaining(), 10, "50 % consumed -> 50 % of 20 left")
		s:Update(5)
		t.eq(fired, false, "not at t = 10 (the anchored bug)")
		s:Update(5)
		t.eq(fired, true, "at t = 15")
		-- offset start: the same shape at start = 100
		local s2 = _new()
		s2:Update(100)
		local fired2 = false
		local h2 = s2:Delay(function()
			fired2 = true
		end, 10)
		s2:Update(5)
		h2:Adjust(20)
		t.eq(h2:GetRemaining(), 10)
		s2:Update(10)
		t.eq(fired2, true)
		t.eq(s2:Now(), 115)
		t.eq(s2:Validate(), true)
	end)

	-- S-reentry: ResetTimer/AdjustTime from inside the timer's own callback
	-- were lost but reported success; fixed: a recurring's own re-key is
	-- honoured, a one-shot reports its Fired state truthfully and Restart()
	-- is the explicit re-arm
	t.test("S-06", function()
		local s = _new()
		local fires = 0
		local r
		r = s:Recur(function()
			fires += 1
			if fires == 1 then
				r:Reset()
			end
		end, 1)
		s:Update(3 / 2)
		t.eq(fires, 1)
		t.eq(r:GetRemaining(), 1, "reset inside own callback: now + period = 2.5")
		s:Update(1 / 2)
		t.eq(fires, 1, "not at the old re-key 2")
		s:Update(1 / 2)
		t.eq(fires, 2, "honoured: fires at 2.5")
		-- adjust from inside: ratio of the already re-keyed due
		local s2 = _new()
		local fires2 = 0
		local r2
		r2 = s2:Recur(function()
			fires2 += 1
			if fires2 == 1 then
				r2:Adjust(2)
			end
		end, 1)
		s2:Update(3 / 2)
		t.eq(r2:GetRemaining(), 1, "frac (2 - 1.5) / 1 = 0.5 of 2")
		t.eq(r2:GetPeriod(), 2)
		-- one-shot: reset inside own callback is a truthful no-op
		local s3 = _new()
		local fires3, stateInside = 0, nil
		local h
		h = s3:Delay(function()
			fires3 += 1
			h:Reset()
			stateInside = h:GetState()
			if fires3 == 1 then
				h:Restart()
			end
		end, 1)
		s3:Update(1)
		t.eq(stateInside, "Fired", "reports Fired, never a fake success")
		t.eq(h:GetState(), "Pending", "Restart re-armed it")
		s3:Update(1)
		t.eq(fires3, 2)
		t.eq(h:GetState(), "Fired")
		t.eq(s3:Validate(), true)
	end)

	-- S-09: Id dedupe returned nil silently and callers stored nil; fixed:
	-- every arm returns a handle, queries on non-handles return nil, never 0
	t.test("S-09", function()
		local s = _new()
		local a = s:Delay(function() end, 1)
		local b = s:Delay(function() end, 1)
		t.eq(getmetatable(a), VeronEvent)
		t.eq(getmetatable(b), VeronEvent)
		t.eq(a ~= b, true, "never a nil or a duplicate")
		t.eq(a:GetId() ~= b:GetId(), true)
		t.eq(s:GetRemaining(a), 1)
		t.eq(s:GetRemaining(nil), nil)
		t.eq(s:GetRemaining(42), nil)
		t.eq(s:GetRemaining({}), nil)
		s:SetStrict(true)
		t.eq(s:GetRemaining(nil), nil, "nil even under Strict, never 0")
		t.eq(s:GetRemaining("x"), nil)
		t.eq(s:Stop(nil), false)
		t.eq(s:Validate(), true)
	end)

	-- S-12: ResetTimer(Id, X) changed the due but not LifeTime; fixed: a
	-- separate SetRemaining(x) leaves the period, Reset restores the full
	-- period
	t.test("S-12", function()
		local s = _new()
		local fireTimes = {}
		local h = s:Recur(function()
			fireTimes[#fireTimes + 1] = s:Now()
		end, 1)
		s:Update(1 / 2)
		t.eq(h:SetRemaining(3), h)
		t.eq(h:GetRemaining(), 3)
		t.eq(h:GetPeriod(), 1, "period untouched")
		for _ = 1, 8 do
			s:Update(1 / 2)
		end
		t.eq(table.concat(fireTimes, ","), "3.5,4.5", "3 s more, then every period")
		t.eq(h:Reset(), h)
		t.eq(h:GetRemaining(), 1, "full period from now")
		t.eq(h:GetPeriod(), 1)
		t.eq(s:Validate(), true)
	end)

	-- S-14: ForceEventComplete then DeleteEvent, and double invocation from
	-- inside the forced callback; fixed: Stop wins, Complete is idempotent
	-- (one fire) and a no-op from inside its own callback
	t.test("S-14", function()
		local s = _new()
		local fires = 0
		local h = s:Delay(function()
			fires += 1
		end, 10)
		t.eq(h:Complete(), true)
		h:Stop()
		s:Update(0)
		t.eq(fires, 0, "Stop wins over a pending Complete")
		t.eq(h:GetState(), "Stopped")
		-- Complete twice before the pass: exactly one fire
		local h2 = s:Delay(function()
			fires += 1
		end, 10)
		t.eq(h2:Complete(), true)
		t.eq(h2:Complete(), true)
		s:Update(0)
		t.eq(fires, 1)
		s:Update(20)
		t.eq(fires, 1)
		-- the KillMe shape: the callback completes its own handle
		local inner, insideResult = 0, nil
		local h3
		h3 = s:Delay(function()
			inner += 1
			insideResult = h3:Complete()
		end, 1)
		t.eq(h3:Complete(), true)
		s:Update(0)
		t.eq(inner, 1)
		t.eq(insideResult, false, "no-op from inside its own callback")
		s:Update(5)
		t.eq(inner, 1, "never a second run")
		t.eq(h3:Complete(), false, "terminal")
		t.eq(s:Validate(), true)
	end)

	-----------------------------------------------------------------
	-- F5 / F6 (legacy-bughunt §1; SEM rows F5/F6 folded in)
	-----------------------------------------------------------------

	-- F5: recur period 0 (creation, adjust, immediate path) hung the frame;
	-- fixed: rejected everywhere. SEM F5: a Complete from inside a pass on
	-- a later entry fires exactly once this pass.
	t.test("F5", function()
		local s = _new()
		local fn = function() end
		t.throws(function()
			s:Recur(fn, 0)
		end, "expected recur `delay` greater than zero")
		local r = s:Recur(fn, 1)
		t.throws(function()
			r:Adjust(0)
		end, "expected `newTotal` greater than zero")
		t.throws(function()
			r:SetPeriod(0)
		end, "expected `newPeriod` greater than zero")
		t.eq(r:GetPeriod(), 1)
		local nested
		s:Delay(function()
			local ok, err = pcall(function()
				s:Recur(fn, 0)
			end)
			nested = not ok and err
		end, 1 / 2)
		s:Update(1)
		t.eq(_find(nested, "greater than zero"), true, "inside a callback too")
		t.eq(s:GetStats().Recurring, 1)
		-- SEM F5
		local s2 = _new()
		local bFires, completeResult = 0, nil
		local b = s2:Delay(function()
			bFires += 1
		end, 2)
		s2:Delay(function()
			completeResult = b:Complete()
		end, 1)
		s2:Update(1)
		t.eq(completeResult, true, "completed a later entry from inside the pass")
		t.eq(bFires, 1, "fired once, later in the same pass")
		s2:Update(5)
		t.eq(bFires, 1)
		t.eq(s2:Validate(), true)
	end)

	-- F6: adjust on a delay-0 event made a NaN zombie visited every frame;
	-- fixed: never NaN, fires at the new total. SEM F6: Complete from a
	-- handle's own callback returns false.
	t.test("F6", function()
		local s = _new()
		local fired = false
		local h = s:Delay(function()
			fired = true
		end, 0)
		h:Adjust(5)
		local remaining = h:GetRemaining()
		t.eq(remaining == remaining, true, "not NaN")
		t.eq(remaining, 5)
		for _ = 1, 64 do
			s:Update(DT64)
		end
		t.eq(fired, false, "not a zombie fire and not early")
		t.eq(s:GetClocks(), 1)
		s:Update(4)
		t.eq(fired, true)
		t.eq(s:GetClocks(), 0, "removed after firing")
		-- SEM F6
		local s2 = _new()
		local oneShotResult, recurResult, recurFires = nil, nil, 0
		local a, r
		a = s2:Delay(function()
			oneShotResult = a:Complete()
		end, 1)
		r = s2:Recur(function()
			recurFires += 1
			recurResult = r:Complete()
		end, 1)
		s2:Update(1)
		t.eq(oneShotResult, false, "one-shot: already Fired")
		t.eq(recurResult, false, "recurring: own callback")
		t.eq(recurFires, 1)
		s2:Update(1 / 2)
		t.eq(recurFires, 1, "no forced second fire")
		t.eq(s2:Validate(), true)
	end)
end

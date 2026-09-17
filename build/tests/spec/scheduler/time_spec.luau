--!nonstrict
--[[
	time_spec — the virtual clock: Update / UpdateTo / TimeScale / Pause /
	DelayAt / GetBase / MaxDt (docs/DESIGN.md §2.1, §2.2, §4.2, §4.8; §9
	scheduler/time_spec row, 16 tests).

	Every instance runs through `Oracle.wrap` except the 1e6-sample test,
	which drives a raw instance (an oracle walk per sample would dominate the
	run) and calls `Oracle.check` at the end. Dyadic numbers keep every
	boundary exact.
]]

local Veron = require("../../../src/Veron")
local Env = require("../../../src/Veron/Env")
local Oracle = require("../../support/oracle")

local HUGE = math.huge

local function newVeron(cfg)
	cfg = cfg or {}
	if cfg.Name == nil then
		cfg.Name = "T"
	end
	return Oracle.wrap(Veron.new(cfg))
end

local function throwsPlain(t, fn, text)
	local ok, err = pcall(fn)
	t.eq(ok, false, "expected an error containing: " .. text)
	local message = tostring(err)
	if not message:find(text, 1, true) then
		error(("error %q does not contain %q"):format(message, text), 2)
	end
	return message
end

--[[
	Runs `fn` with Env.Warn captured; returns the list of warnings. The seam
	is restored even when `fn` raises (the error is re-raised afterwards).
]]
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

local function noop()
end

return function(t)
	-- §4.2 I9: `Update(0)` dispatches every entry with due <= now
	t.test("update 0 flushes due", function()
		local s = newVeron()
		local log = {}
		local function tag(name)
			return function()
				log[#log + 1] = name
			end
		end
		s:Delay(tag("a"), 0)
		s:Delay(tag("b"), 1 / 64)
		s:Delay(tag("c"), 1 / 32)
		s:Delay(tag("d"), 1)
		s:Update(1 / 32)
		t.eq(table.concat(log), "abc", "everything due at 1/32 fired")
		-- new zero-delay entries are due now; Update(0) flushes exactly those
		s:Delay(tag("e"), 0)
		s:Delay(tag("f"), 0)
		s:Update(0)
		t.eq(table.concat(log), "abcef")
		t.eq(s:Now(), 1 / 32, "Update(0) does not move the clock")
		t.eq(s:GetClocks(), 1, "d is still pending")
		s:Update(0)
		t.eq(table.concat(log), "abcef", "nothing else is due")
		t.eq(s:GetStats().Updates, 3)
	end)

	-- §4.2 `Update`: type check FIRST, prefixed message, nothing touched (I10/I11/I13, B-05, DV-23)
	t.test("negative, NaN, inf, nil, string dt error before touching state with the prefixed message", function()
		local s = newVeron()
		local fired = 0
		s:Delay(function()
			fired += 1
		end, 0)
		local PREFIX = "Veron 'T': Update(dt) expects a finite number >= 0, got "
		local cases = {
			{ -1, "-1" },
			{ 0 / 0, false }, -- tostring(NaN) is platform-spelled; the prefix is what matters
			{ HUGE, "inf" },
			{ -HUGE, "-inf" },
			{ nil, "nil" },
			{ "0.5", "0.5" }, -- strings are NOT coerced for dt (DV-23)
			{ {}, false },
			{ true, "true" },
		}
		for _, case in cases do
			local value, suffix = case[1], case[2]
			local message = throwsPlain(t, function()
				s:Update(value)
			end, PREFIX)
			if suffix then
				t.eq(message:find(PREFIX .. suffix, 1, true) ~= nil, true, message)
			end
			throwsPlain(t, function()
				s.update(value)
			end, PREFIX)
			t.eq(s:Now(), 0, "clock untouched")
			t.eq(fired, 0, "nothing dispatched")
			local stats = s:GetStats()
			t.eq(stats.Updates, 0, "no update counted")
			t.eq(stats.LastDt, 0, "LastDt untouched")
			t.eq(stats.UpdateDepth, 0)
			t.eq(s:GetBase(), false)
		end
		-- a legal dt afterwards behaves normally
		s:Update(0)
		t.eq(fired, 1)
	end)

	-- §2.2 Update / R11: now += dt × TimeScale; SetTimeScale takes effect on the next Update
	t.test("rolling clock accumulates dt * TimeScale", function()
		local s = newVeron({ TimeScale = 2 })
		t.eq(s:GetTimeScale(), 2)
		s:Update(1 / 4)
		t.eq(s:Now(), 1 / 2)
		s:Update(1 / 4)
		t.eq(s:Now(), 1)
		s:SetTimeScale(1 / 2)
		t.eq(s:GetTimeScale(), 1 / 2)
		s:Update(1)
		t.eq(s:Now(), 3 / 2)
		-- a timer armed at 1.5 for 1 s fires when the CLOCK reaches 2.5: 2 s of dt at scale 1/2
		local fired = 0
		local h = s:Delay(function()
			fired += 1
		end, 1)
		t.eq(h:GetRemaining(), 1, "remaining is in instance-seconds (R9)")
		s:Update(1)
		t.eq(s:Now(), 2)
		t.eq(fired, 0)
		t.eq(h:GetRemaining(), 1 / 2)
		s:Update(1)
		t.eq(s:Now(), 5 / 2)
		t.eq(fired, 1)
		s:SetTimeScale(4)
		s:Update(1 / 8)
		t.eq(s:Now(), 3)
		t.eq(s:GetStats().Now, 3)
		t.eq(s:GetStats().TimeScale, 4)
		t.eq(s:GetStats().LastDt, 1 / 8, "LastDt is the raw dt, unscaled")
	end)

	-- §2.1 TimeScale 0 "freezes"; a due-now entry still fires (B-16: due = now, `due > now` is false)
	t.test("TimeScale 0 freezes, delay 0 still fires", function()
		local s = newVeron({ TimeScale = 0 })
		local log = {}
		s:Delay(function()
			log[#log + 1] = "a"
		end, 1)
		s:Delay(function()
			log[#log + 1] = "b"
		end, 0)
		s:Update(5)
		t.eq(s:Now(), 0, "frozen")
		t.eq(table.concat(log), "b", "the zero-delay entry fires, the 1 s one does not")
		s:Update(100)
		t.eq(s:Now(), 0)
		t.eq(table.concat(log), "b")
		t.eq(s:GetStats().Updates, 2, "frozen updates are still updates")
		-- SetTimeScale(0) at runtime freezes too; back to 1 thaws
		s:SetTimeScale(1)
		s:Update(1)
		t.eq(s:Now(), 1)
		t.eq(table.concat(log), "ba")
		s:SetTimeScale(0)
		s:Delay(function()
			log[#log + 1] = "c"
		end, 0)
		s:Update(1000)
		t.eq(s:Now(), 1)
		t.eq(table.concat(log), "bac")
	end)

	-- §2.2 SetTimeScale / §2.1 config: finite number >= 0, prefixed option message, value untouched
	t.test("SetTimeScale rejects NaN/inf/negative", function()
		local s = newVeron()
		local MSG = "option 'TimeScale' expects a finite number >= 0"
		for _, bad in { 0 / 0, HUGE, -HUGE, -1, -1 / 64, true, {} } do
			local message = throwsPlain(t, function()
				s:SetTimeScale(bad)
			end, MSG)
			t.eq(message:find("Veron 'T': " .. MSG, 1, true) ~= nil, true, message)
			t.eq(s:GetTimeScale(), 1, "unchanged after a refused value")
		end
		s:SetTimeScale(0)
		t.eq(s:GetTimeScale(), 0)
		s:SetTimeScale(3 / 2)
		t.eq(s:GetTimeScale(), 3 / 2)
		-- construction runs the same check with the bare prefix (§2.1)
		for _, bad in { 0 / 0, HUGE, -1, true } do
			local message = throwsPlain(t, function()
				Veron.new({ Name = "Bad", TimeScale = bad })
			end, MSG)
			t.eq(message:find("Veron: " .. MSG, 1, true) ~= nil, true, message)
		end
	end)

	-- §4.8 `UpdateTo`: the first sample anchors (`_Offset = t - _Now`), relative timers are never swept
	t.test("UpdateTo first call anchors without sweeping relative timers", function()
		local s = newVeron()
		local log = {}
		s:Delay(function()
			log[#log + 1] = "one"
		end, 1)
		s:Delay(function()
			log[#log + 1] = "zero"
		end, 0)
		s:UpdateTo(1000)
		t.eq(s:Now(), 0, "anchoring does not move the clock")
		t.eq(table.concat(log, ","), "zero", "the first sample flushes due entries like Update(0)")
		t.eq(rawget(s, "_Offset"), 1000)
		t.eq(rawget(s, "_LastAbs"), 1000)
		s:UpdateTo(1000.5)
		t.eq(s:Now(), 0.5)
		t.eq(table.concat(log, ","), "zero")
		s:UpdateTo(1001)
		t.eq(s:Now(), 1)
		t.eq(table.concat(log, ","), "zero,one")
		-- a huge first sample on a fresh instance still sweeps nothing
		local s2 = newVeron({ Name = "T2" })
		local fired = 0
		s2:Delay(function()
			fired += 1
		end, 1 / 64)
		s2:UpdateTo(1e9)
		t.eq(fired, 0)
		t.eq(s2:Now(), 0)
		s2:UpdateTo(1e9 + 1 / 64)
		t.eq(fired, 1)
	end)

	-- §4.8: at scale 1 `target = t - _Offset` — exact, nothing accumulates (raw instance, see header)
	t.test("UpdateTo exact at scale 1 after 1e6 samples", function()
		local s = Veron.new({ Name = "Raw" })
		local anchor = 1000
		local firedAt = false
		local sample = 0
		s:Delay(function()
			firedAt = sample
		end, 10000)
		s:UpdateTo(anchor)
		local t0 = anchor
		for i = 1, 1000000 do
			sample = i
			local absolute = anchor + i / 60
			s:UpdateTo(absolute)
			if i % 250000 == 0 then
				t.eq(s:Now(), absolute - anchor, "exactly the sample minus the anchor at sample " .. i)
			end
			t0 = absolute
		end
		t.eq(s:Now(), t0 - anchor, "Now is exactly the last sample minus the anchor")
		t.near(s:Now(), 1000000 / 60, 1e-6)
		t.eq(firedAt, 600000, "the 10000 s timer fired on the sample whose external time reached anchor + 10000")
		t.eq(rawget(s, "_Offset"), anchor, "the offset never drifted")
		t.eq(s:GetStats().Updates, 1000001)
		t.eq(s:GetStats().ClampedBackwards, 0)
		Oracle.check(s)
	end)

	-- §4.2 `_advanceTo`: the clock never runs backwards (D2); counted; warned once when the step exceeds 1 s
	t.test("UpdateTo backwards clamps, counts, warns once over 1 s", function()
		local s = newVeron()
		local warns = captureWarns(function()
			s:UpdateTo(100)
			s:UpdateTo(105)
			t.eq(s:Now(), 5)
			s:UpdateTo(104.5)
			t.eq(s:Now(), 5, "clamped")
			t.eq(s:GetStats().ClampedBackwards, 1)
		end)
		t.eq(#warns, 0, "a step under 1 s is silent")
		warns = captureWarns(function()
			s:UpdateTo(103)
			t.eq(s:Now(), 5)
			t.eq(s:GetStats().ClampedBackwards, 2)
		end)
		t.eq(#warns, 1, "warned once")
		t.eq(warns[1]:find("[Veron T] clock asked to move backwards by 2 s; clamped", 1, true) ~= nil, true, warns[1])
		warns = captureWarns(function()
			s:UpdateTo(101)
			s:UpdateTo(90)
			t.eq(s:Now(), 5)
			t.eq(s:GetStats().ClampedBackwards, 4)
		end)
		t.eq(#warns, 0, "warn once per instance")
		-- forward again: exact against the ORIGINAL offset (no accumulation through the clamps)
		s:UpdateTo(106)
		t.eq(s:Now(), 6)
		t.eq(s:GetStats().Updates, 7, "clamped samples still count as updates")
		-- a function OnError policy receives the diagnostic instead of Warn
		local got = false
		local s2 = newVeron({ Name = "F", OnError = function(message, handle)
			got = { message, handle }
		end })
		warns = captureWarns(function()
			s2:UpdateTo(10)
			s2:UpdateTo(20)
			s2:UpdateTo(15)
		end)
		t.eq(#warns, 0)
		t.eq(type(got), "table")
		t.eq(got[1]:find("clock asked to move backwards by 5 s; clamped", 1, true) ~= nil, true, got[1])
		t.eq(got[2], false, "no handle is involved")
		t.eq(s2:GetStats().Errors, 0, "a diagnostic is not a callback error")
	end)

	-- §2.2 Pause / §4.8: while paused UpdateTo folds the gap into `_Offset`; the external due still holds
	t.test("instance Pause folds the UpdateTo gap into the offset", function()
		local s = newVeron()
		local fired = 0
		s:UpdateTo(100)
		s:Delay(function()
			fired += 1
		end, 2)
		s:UpdateTo(101)
		t.eq(s:Now(), 1)
		s:Pause()
		t.eq(s:IsPaused(), true)
		s:UpdateTo(150)
		t.eq(s:Now(), 1, "paused: the clock did not move")
		t.eq(fired, 0)
		t.eq(rawget(s, "_Offset"), 149, "100 + (150 - 101) folded in")
		t.eq(rawget(s, "_LastAbs"), 150)
		s:UpdateTo(160)
		t.eq(rawget(s, "_Offset"), 159)
		t.eq(s:Now(), 1)
		s:Resume()
		t.eq(s:IsPaused(), false)
		s:UpdateTo(160.5)
		t.eq(s:Now(), 1.5, "runs on from where it was frozen")
		t.eq(fired, 0)
		s:UpdateTo(161)
		t.eq(s:Now(), 2)
		t.eq(fired, 1, "the remaining 1 s of the timer elapsed after Resume")
		t.eq(s:GetStats().ClampedBackwards, 0)
	end)

	-- §2.2 DelayAt / §4.8: an absolute time on the UpdateTo axis; refused before the axis exists
	t.test("DelayAt fires on the external axis and errors before the first UpdateTo", function()
		local s = newVeron()
		throwsPlain(t, function()
			s:DelayAt(noop, 5)
		end, "Veron 'T': DelayAt needs UpdateTo to have been called at least once")
		t.eq(s:GetClocks(), 0)
		s:Update(1)
		throwsPlain(t, function()
			s:DelayAt(noop, 5)
		end, "DelayAt needs UpdateTo to have been called at least once")
		s:UpdateTo(1000)
		local log = {}
		local h = s:DelayAt(function()
			log[#log + 1] = "a"
		end, 1002)
		t.eq(h:GetState(), "Pending")
		t.eq(h:GetRemaining(), 2)
		t.eq(h:GetPeriod(), 2)
		s:UpdateTo(1001.5)
		t.eq(table.concat(log), "")
		s:UpdateTo(1002)
		t.eq(table.concat(log), "a")
		-- an absolute time already in the past → remaining 0 → next sample
		local past = s:DelayAt(function()
			log[#log + 1] = "p"
		end, 1001)
		t.eq(past:GetRemaining(), 0)
		s:UpdateTo(1002)
		t.eq(table.concat(log), "ap")
		-- argument validation is the legacy family, callback-first like every other arm
		throwsPlain(t, function()
			s:DelayAt(nil, 1005)
		end, "expected `fn` to be callable")
		throwsPlain(t, function()
			s:DelayAt(noop, nil)
		end, "expected `delay` to be a number. CurrentType: nil")
		throwsPlain(t, function()
			s:DelayAt(noop, 0 / 0)
		end, "expected `delay` to be a finite number")
	end)

	-- §4.8 DelayAt: distance from the last sample × TimeScale
	t.test("DelayAt at TimeScale 2 fires at the external time", function()
		local s = newVeron({ TimeScale = 2 })
		local log = {}
		s:UpdateTo(100)
		local h = s:DelayAt(function()
			log[#log + 1] = "a"
		end, 102)
		t.eq(h:GetRemaining(), 4, "2 external seconds are 4 instance-seconds")
		s:UpdateTo(101)
		t.eq(s:Now(), 2)
		t.eq(table.concat(log), "")
		s:UpdateTo(101.5)
		t.eq(s:Now(), 3)
		t.eq(table.concat(log), "")
		s:UpdateTo(102)
		t.eq(s:Now(), 4)
		t.eq(table.concat(log), "a", "fired exactly at external 102")
		-- armed between samples the distance is still measured from the LAST sample
		local h2 = s:DelayAt(function()
			log[#log + 1] = "b"
		end, 103)
		t.eq(h2:GetRemaining(), 2)
		s:UpdateTo(102.5)
		t.eq(table.concat(log), "a")
		s:UpdateTo(103)
		t.eq(table.concat(log), "ab")
	end)

	-- §2.2 Pause: "the first anchoring UpdateTo advance NOTHING and dispatch nothing"
	t.test("first UpdateTo while paused dispatches nothing", function()
		local s = newVeron()
		local fired = 0
		s:Delay(function()
			fired += 1
		end, 0)
		s:Pause()
		s:UpdateTo(50)
		t.eq(fired, 0, "a due-now entry did not fire on the anchoring sample")
		t.eq(s:Now(), 0)
		t.eq(rawget(s, "_LastAbs"), 50, "the sample was still recorded as the anchor")
		t.eq(rawget(s, "_Offset"), 50)
		t.eq(s:GetStats().Updates, 0, "no pass ran")
		s:UpdateTo(60)
		t.eq(fired, 0)
		t.eq(rawget(s, "_Offset"), 60, "the paused gap folded in")
		s:Resume()
		s:UpdateTo(60)
		t.eq(fired, 1, "the first live sample flushes it")
		t.eq(s:Now(), 0)
	end)

	-- §2.2 Pause/Resume: Update(dt) and Update(0) advance nothing; a deferred Complete waits for Resume
	t.test("paused instance: Update(0) and first UpdateTo do not dispatch; Complete waits for Resume", function()
		local s = newVeron()
		local log = {}
		local h = s:Delay(function()
			log[#log + 1] = "h"
		end, 1)
		local z = s:Delay(function()
			log[#log + 1] = "z"
		end, 0)
		s:Pause()
		t.eq(s:IsPaused(), true)
		t.eq(s:GetStats().IsPaused, true)
		s:Update(0)
		t.eq(#log, 0, "Update(0) dispatched nothing")
		s:Update(5)
		t.eq(s:Now(), 0, "Update(5) advanced nothing")
		t.eq(s:GetStats().Updates, 0)
		t.eq(#log, 0)
		t.eq(h:Complete(), true, "a deferred Complete is accepted while paused")
		t.eq(h:GetRemaining(), 0, "re-keyed to now")
		s:Update(0)
		t.eq(#log, 0, "…but it waits for Resume")
		s:UpdateTo(10)
		t.eq(#log, 0, "the first (anchoring) UpdateTo dispatches nothing either")
		t.eq(s:Now(), 0)
		s:Resume()
		s:Update(0)
		t.eq(table.concat(log), "hz", "both due-now entries fire in (due, Id) order: h is Id 1")
		t.eq(h:GetState(), "Fired")
		t.eq(z:GetState(), "Fired")
		-- CompleteNow is the immediate alternative while paused
		local fired = 0
		local n = s:Delay(function()
			fired += 1
		end, 1)
		s:Pause()
		t.eq(n:CompleteNow(), true)
		t.eq(fired, 1, "CompleteNow fires immediately even on a paused instance")
		s:Resume()
	end)

	-- §2.2 Now / R11: every instance's clock starts at 0
	t.test("Now starts at 0", function()
		local s = newVeron()
		t.eq(s:Now(), 0)
		t.eq(s.Now(), 0, "dot spelling")
		t.eq(s:GetStats().Now, 0)
		s:Delay(noop, 5)
		t.eq(s:Now(), 0, "arming does not touch the clock")
		local s2 = newVeron({ Name = "T2", TimeScale = 3 })
		t.eq(s2:Now(), 0)
		t.eq(s2:GetBase(), false)
		t.eq(s2:IsUpdating(), false)
		s:Update(1 / 64)
		t.eq(s2:Now(), 0, "instances do not share a clock")
	end)

	-- §2.2 GetBase / §4.1 `_clockOf` (R-D): false outside a firing thread, the ideal due inside one
	t.test("GetBase is false at top level and the ideal due inside a callback", function()
		local s = newVeron()
		t.eq(s:GetBase(), false)
		local seen = {}
		s:Delay(function()
			seen.base = s:GetBase()
			seen.now = s:Now()
			seen.updating = s:IsUpdating()
			-- another coroutine inside the callback is NOT the firing thread (R-D)
			seen.otherThread = coroutine.wrap(function()
				return s:GetBase()
			end)()
			-- an implicit arm measures from the base: due = 1 + 1/4 (already past now → fires later this pass)
			local nested = s:Delay(noop, 1 / 4)
			seen.nestedDue = rawget(s, "_Due")[rawget(nested, "_HeapIndex")]
			seen.nestedRemaining = nested:GetRemaining()
		end, 1)
		s:Update(3 / 2)
		t.eq(seen.base, 1, "the ideal due, not the clock")
		t.eq(seen.now, 3 / 2, "Now() is always the real clock")
		t.eq(seen.updating, true)
		t.eq(seen.otherThread, false, "another thread measures from now")
		t.eq(seen.nestedDue, 5 / 4, "base + 1/4, not now + 1/4")
		t.eq(seen.nestedRemaining, 0, "already past now: remaining clamps at 0")
		t.eq(s:GetBase(), false, "cleared after the pass")
		t.eq(s:IsUpdating(), false)
		-- a recurring callback sees its ideal due d, not the re-keyed d + period
		local bases = {}
		local r = s:Recur(function()
			bases[#bases + 1] = s:GetBase()
		end, 1)
		s:Update(1 + 1 / 2 + 1 / 64) -- now = 3 + 1/64: dues 5/2 (d = 3/2 + 1) fires
		t.eq(#bases, 1)
		t.eq(bases[1], 5 / 2)
		s:Update(1)
		t.eq(bases[2], 7 / 2)
		t.eq(s:GetBase(), false)
		r:Stop()
	end)

	-- §2.1 MaxDt (Q-J16) / §4.2 `Update`: off by default; when set the clamp applies AFTER validation, never to UpdateTo
	t.test("MaxDt off by default; when set Update(dt) clamps and counts ClampedDt", function()
		local plain = newVeron({ Name = "Plain" })
		t.eq(rawget(plain, "_MaxDt"), false)
		plain:Update(5)
		t.eq(plain:Now(), 5, "a 5 s dt advances 5 s")
		t.eq(plain:GetStats().ClampedDt, 0)
		t.eq(plain:GetStats().LastDt, 5)

		local clamped = newVeron({ Name = "Clamped", MaxDt = 1 / 4 })
		clamped:Update(5)
		t.eq(clamped:Now(), 1 / 4, "clamped to MaxDt")
		local stats = clamped:GetStats()
		t.eq(stats.ClampedDt, 1)
		t.eq(stats.LastDt, 1 / 4, "LastDt is the clamped value")
		clamped:Update(1 / 8)
		t.eq(clamped:Now(), 3 / 8)
		t.eq(clamped:GetStats().ClampedDt, 1, "an in-range dt is not counted")
		clamped:Update(1 / 4)
		t.eq(clamped:Now(), 5 / 8)
		t.eq(clamped:GetStats().ClampedDt, 1, "dt == MaxDt is not a clamp")
		-- the clamp is applied AFTER validation: a bad dt is still rejected, not clamped (an inf dt in particular)
		throwsPlain(t, function()
			clamped:Update(HUGE)
		end, "Veron 'Clamped': Update(dt) expects a finite number >= 0, got inf")
		throwsPlain(t, function()
			clamped:Update(-5)
		end, "Veron 'Clamped': Update(dt) expects a finite number >= 0, got -5")
		t.eq(clamped:Now(), 5 / 8)
		t.eq(clamped:GetStats().ClampedDt, 1)
		-- a timer sees clamped time only
		local fired = 0
		clamped:Delay(function()
			fired += 1
		end, 1)
		clamped:Update(100)
		t.eq(fired, 0)
		t.eq(clamped:Now(), 7 / 8)
		t.eq(clamped:GetStats().ClampedDt, 2)

		-- UpdateTo never clamps: its axis is external
		local absolute = newVeron({ Name = "Abs", MaxDt = 1 / 4 })
		absolute:UpdateTo(0)
		absolute:UpdateTo(5)
		t.eq(absolute:Now(), 5, "UpdateTo moved the full 5 s")
		t.eq(absolute:GetStats().ClampedDt, 0)

		-- config validation: number > 0 or false
		for _, bad in { 0, -1, 0 / 0, HUGE, true } do
			throwsPlain(t, function()
				Veron.new({ Name = "Bad", MaxDt = bad })
			end, "Veron: option 'MaxDt' expects")
		end
		local off = Veron.new({ Name = "Off", MaxDt = false })
		t.eq(rawget(off, "_MaxDt"), false)
	end)
end

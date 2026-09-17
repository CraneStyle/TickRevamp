--!nonstrict
--[[
	retime_spec — Reset / Adjust / SetPeriod / SetRemaining and the "explicit
	ops measure from now" rule (docs/DESIGN.md §2.3, §4.4, §4.5, §5, §9
	handle/retime_spec row; SEM R1–R10, B-01, S-12). Every instance runs
	through `Oracle.wrap`; timing uses dyadic numbers only so every fraction
	(3/4, 7/8, …) is exact in a double.
]]

local Veron = require("../../../src/Veron")
local Oracle = require("../../support/oracle")

local NEW_TOTAL_MESSAGE = "expected `newTotal` greater than zero"
local NEW_PERIOD_RECUR_MESSAGE = "expected `newPeriod` greater than zero"
local NEW_PERIOD_ONESHOT_MESSAGE = "expected `newPeriod` of zero or greater"
local REMAINING_MESSAGE = "expected `remaining` of zero or greater"

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

return function(t)
	-- §4.5 `_Adjust` (frac = clamp((due − now) / period, 0, 1); due' = now + frac·x; P = x), R1
	t.test("adjust preserves consumed fraction", function()
		local s = _new()
		local count, fn = _counter()
		-- legacy probe L5: recur 4 → 8 at t = 1 leaves 6
		local r = s:Recur(fn, 4)
		s:Update(1)
		t.eq(r:GetRemaining(), 3)
		t.eq(r:Adjust(8), r, "returns h")
		t.eq(r:GetRemaining(), 6, "25% consumed → 75% of the new total left")
		t.eq(r:GetPeriod(), 8)
		s:Update(6)
		t.eq(count.n, 1, "fires exactly at the adjusted due")
		t.eq(r:GetRemaining(), 8, "re-arms with the new period")
		r:Stop()
		-- one-shot: 2 → 4 at t = 1/2 leaves 3
		local h = s:Delay(fn, 2)
		s:Update(1 / 2)
		t.eq(h:GetRemaining(), 3 / 2)
		h:Adjust(4)
		t.eq(h:GetRemaining(), 3)
		t.eq(h:GetPeriod(), 4)
		-- shrinking works the same way: 4 → 1 with 3/4 left leaves 3/4
		h:Adjust(1)
		t.eq(h:GetRemaining(), 3 / 4)
		t.eq(h:GetPeriod(), 1)
		-- the legacy `adjust` alias and tonumber coercion (§2.3)
		t.eq(h:adjust("2"), h)
		t.eq(h:GetRemaining(), 3 / 2)
		t.eq(h:GetPeriod(), 2)
		s:Update(3 / 2)
		t.eq(count.n, 2)
		t.eq(h:GetState(), "Fired")
		t.eq(s:Validate(), true)
	end)

	-- §4.5 `_Adjust` (x finite and > 0 else `expected \`newTotal\` greater than zero`), R2
	t.test("adjust rejects 0, negative, NaN, inf, nil", function()
		local s = _new()
		local count, fn = _counter()
		local h = s:Delay(fn, 1)
		local r = s:Recur(fn, 1)
		-- (no nil inside the list literal: it would end the iteration early)
		for _, bad in { 0, -1, -1 / 4, 0 / 0, math.huge, -math.huge, "x", {}, true } do
			t.throws(function()
				h:Adjust(bad)
			end, NEW_TOTAL_MESSAGE)
			t.throws(function()
				r:adjust(bad)
			end, NEW_TOTAL_MESSAGE)
			t.eq(h:GetRemaining(), 1, "rejected: remaining untouched")
			t.eq(h:GetPeriod(), 1, "rejected: period untouched")
			t.eq(r:GetPeriod(), 1)
		end
		-- nil, both spellings
		t.throws(function()
			h:Adjust(nil)
		end, NEW_TOTAL_MESSAGE)
		t.throws(function()
			h:Adjust()
		end, NEW_TOTAL_MESSAGE)
		t.throws(function()
			r:adjust()
		end, NEW_TOTAL_MESSAGE)
		-- Paused and Chained validate the same way
		local paused = s:Delay(fn, 1)
		paused:Pause()
		local chained = h:After(fn, 1)
		t.throws(function()
			paused:Adjust(0)
		end, NEW_TOTAL_MESSAGE)
		t.throws(function()
			chained:Adjust(-1)
		end, NEW_TOTAL_MESSAGE)
		t.eq(paused:GetRemaining(), 1)
		t.eq(chained:GetPeriod(), 1)
		t.eq(s:Validate(), true)
		s:Update(1)
		t.eq(count.n, 2, "still fires on time after every rejection")
	end)

	-- §4.5 (`if period > 0 then … else 1`; period == 0 never divides), R3 / RF-001, F6
	t.test("adjust on period 0 uses the whole newTotal, never NaN", function()
		local s = _new()
		local count, fn = _counter()
		local h = s:Delay(fn, 0)
		t.eq(h:GetRemaining(), 0)
		t.eq(h:Adjust(1), h)
		local remaining = h:GetRemaining()
		t.eq(remaining == remaining, true, "not NaN")
		t.eq(remaining, 1, "the whole newTotal")
		t.eq(h:GetPeriod(), 1)
		t.eq(s:Validate(), true)
		s:Update(0)
		t.eq(count.n, 0, "no longer due now")
		s:Update(1 / 2)
		t.eq(count.n, 0)
		s:Update(1 / 2)
		t.eq(count.n, 1, "fires at now + newTotal")
		-- Paused with period 0: the frozen remaining becomes the whole newTotal
		local paused = s:Delay(fn, 0)
		paused:Pause()
		t.eq(paused:GetRemaining(), 0)
		paused:Adjust(2)
		t.eq(paused:GetRemaining(), 2)
		t.eq(paused:GetPeriod(), 2)
		paused:Resume()
		s:Update(2)
		t.eq(count.n, 2)
		-- a Chained child with delay 0 just takes the new delay
		local p = s:Delay(fn, 1)
		local c = p:After(fn, 0)
		c:Adjust(3)
		t.eq(c:GetPeriod(), 3)
		t.eq(c:GetRemaining(), 3)
		s:Update(1)
		t.eq(count.n, 3)
		t.eq(c:GetRemaining(), 3)
		s:Update(3)
		t.eq(count.n, 4)
		t.eq(s:Validate(), true)
	end)

	-- §4.5 `_Adjust` PAUSED branch (frac = remaining / period; `_Paused[h] = frac · x`)
	t.test("adjust on Paused scales remaining", function()
		local s = _new()
		local count, fn = _counter()
		local h = s:Delay(fn, 4)
		s:Update(1)
		h:Pause()
		t.eq(h:GetRemaining(), 3)
		t.eq(h:Adjust(8), h)
		t.eq(h:GetState(), "Paused", "stays Paused")
		t.eq(h:GetRemaining(), 6, "3/4 of the new total")
		t.eq(h:GetPeriod(), 8)
		s:Update(10)
		t.eq(count.n, 0, "still frozen")
		t.eq(h:GetRemaining(), 6)
		h:Resume()
		t.eq(h:GetRemaining(), 6, "resume arms the scaled remaining from now")
		s:Update(6)
		t.eq(count.n, 1)
		-- a paused recurring: 4 → 2 with 3/4 left leaves 3/2
		local r = s:Recur(fn, 4)
		s:Update(1)
		r:Pause()
		r:Adjust(2)
		t.eq(r:GetRemaining(), 3 / 2)
		t.eq(r:GetPeriod(), 2)
		r:Resume()
		s:Update(3 / 2)
		t.eq(count.n, 2)
		t.eq(r:GetRemaining(), 2, "then the new period")
		t.eq(s:Validate(), true)
	end)

	-- §4.5 `_Adjust` (Chained: delay only), §5 Adjust row, SEM A8
	t.test("adjust on Chained sets the delay", function()
		local s = _new()
		local parentCount, parentFn = _counter()
		local childCount, childFn = _counter()
		local p = s:Delay(parentFn, 1)
		local c = p:After(childFn, 1)
		t.eq(c:Adjust(2), c)
		t.eq(c:GetState(), "Chained", "still Chained")
		t.eq(c:GetPeriod(), 2)
		t.eq(c:GetRemaining(), 2, "a Chained child reports its delay")
		t.eq(s:GetClocks(), 1, "not armed yet")
		s:Update(1)
		t.eq(parentCount.n, 1)
		t.eq(c:GetState(), "Pending")
		t.eq(c:GetRemaining(), 2, "armed from the parent's due with the NEW delay")
		s:Update(1)
		t.eq(childCount.n, 0)
		s:Update(1)
		t.eq(childCount.n, 1, "fires at parent due + 2")
		-- with PWC set the new delay becomes the frozen remaining
		local p2 = s:Delay(parentFn, 1)
		local c2 = p2:After(childFn, 1)
		c2:Pause()
		c2:Adjust(1 / 2)
		t.eq(c2:GetPeriod(), 1 / 2)
		s:Update(1)
		t.eq(c2:GetState(), "Paused")
		t.eq(c2:GetRemaining(), 1 / 2)
		t.eq(s:Validate(), true)
	end)

	-- §4.5 ("Inside its own recurring callback Adjust sees due = d + period … at most one extra fire"), B-01
	t.test("adjust inside own lagging recurring callback fires at most twice", function()
		local s = _new()
		local count = 0
		local h
		h = s:Recur(function()
			count += 1
			h:Adjust(1)                                                   -- the same period (B-01 repro 1)
		end, 1)
		s:Update(5 / 2)                                                   -- lagging by 1.5 periods
		t.eq(count >= 1, true, "fired")
		t.eq(count <= 2, true, "at most twice in one update, got " .. count)
		t.eq(h:GetState(), "Pending")
		t.eq(h:GetRemaining() > 0, true, "progress: the next due is in the future")
		t.eq(h:GetPeriod(), 1)
		t.eq(s:GetStats().ValveHits, 0, "bounded by the arithmetic, not the valve")
		t.eq(s:Validate(), true)
		-- and it keeps a sane cadence afterwards
		local before = count
		s:Update(h:GetRemaining())
		t.eq(count, before + 1)
		h:Stop()

		-- B-01 repro 2: not lagging by a full period, adjusting to a tiny total
		local count2 = 0
		local h2
		h2 = s:Recur(function()
			count2 += 1
			h2:Adjust(1 / 16)
		end, 1)
		s:Update(15 / 8)
		t.eq(count2 >= 1, true)
		t.eq(count2 <= 2, true, "at most twice, got " .. count2)
		t.eq(h2:GetState(), "Pending")
		t.eq(h2:GetPeriod(), 1 / 16)
		t.eq(s:GetStats().ValveHits, 0)
		t.eq(s:Validate(), true)
		h2:Stop()

		-- a large lag stays bounded by the per-pass cap (MaxCatchUp = 8), never a hang
		local count3 = 0
		local h3
		h3 = s:Recur(function()
			count3 += 1
			h3:Adjust(1)
		end, 1)
		s:Update(100)
		t.eq(count3 <= 8, true, "bounded by the cap, got " .. count3)
		t.eq(h3:GetState(), "Pending")
		t.eq(s:Validate(), true)
	end)

	-- §4.4 (`_Pause`: remaining = max(due − now, 0); `_Resume`: push at now + remaining),
	-- B-01 repro 3, §4.2 burst cap
	t.test("pause+resume inside lagging callback bounded", function()
		local s = _new()
		local count = 0
		local h
		h = s:Recur(function()
			count += 1
			h:Pause()
			h:Resume()
		end, 1)
		s:Update(5 / 2)
		t.eq(count >= 1, true, "fired")
		t.eq(count <= 2, true, "bounded: at most twice in one update, got " .. count)
		t.eq(h:GetState(), "Pending", "running after the callback's own resume")
		t.eq(h:IsPaused(), false)
		t.eq(h:GetRemaining() > 0, true, "progress: the next due is in the future")
		t.eq(s:GetStats().ValveHits, 0)
		t.eq(s:GetStats().Paused, 0)
		t.eq(s:Validate(), true)
		local before = count
		s:Update(h:GetRemaining())
		t.eq(count, before + 1)
		h:Stop()
		-- a huge lag is bounded by the cap (MaxCatchUp = 8), never a hang
		local count2 = 0
		local h2
		h2 = s:Recur(function()
			count2 += 1
			h2:Pause()
			h2:Resume()
		end, 1)
		s:Update(100)
		t.eq(count2 <= 8, true, "bounded by the cap, got " .. count2)
		t.eq(h2:GetState(), "Pending")
		t.eq(s:Validate(), true)
		-- Toggle twice is the same switch flip
		local count3 = 0
		local h3
		h3 = s:Recur(function()
			count3 += 1
			h3:Toggle()
			h3:Toggle()
		end, 1)
		s:Update(5 / 2)
		t.eq(count3 <= 2, true, "Toggle pair bounded, got " .. count3)
		t.eq(h3:GetState(), "Pending")
		t.eq(s:Validate(), true)
	end)

	-- §4.5 `_SetPeriod` (never re-keys; validation as creation), §2.3 SetPeriod row, R4
	t.test("setPeriod affects future arms only", function()
		local s = _new()
		local count, fn = _counter()
		local r = s:Recur(fn, 1)
		s:Update(1 / 2)
		t.eq(r:SetPeriod(2), r, "returns h")
		t.eq(r:GetPeriod(), 2)
		t.eq(r:GetRemaining(), 1 / 2, "current cycle untouched")
		s:Update(1 / 2)
		t.eq(count.n, 1, "fires at the old due")
		t.eq(r:GetRemaining(), 2, "re-arms with the new period")
		s:Update(2)
		t.eq(count.n, 2)
		r:Stop()
		-- one-shot: only a later Reset / Restart sees it
		local h = s:Delay(fn, 1)
		h:SetPeriod(3)
		t.eq(h:GetRemaining(), 1)
		t.eq(h:GetPeriod(), 3)
		h:Reset()
		t.eq(h:GetRemaining(), 3, "Reset uses the new period")
		-- Paused: the frozen remaining stays, the period changes
		local paused = s:Delay(fn, 4)
		s:Update(1)
		paused:Pause()
		paused:SetPeriod(8)
		t.eq(paused:GetRemaining(), 3)
		t.eq(paused:GetPeriod(), 8)
		-- Chained: the delay changes (same as Adjust there)
		local c = h:After(fn, 1)
		c:SetPeriod(2)
		t.eq(c:GetPeriod(), 2)
		t.eq(c:GetRemaining(), 2)
		-- validation: recurring > 0, one-shot >= 0, finite
		local r2 = s:Recur(fn, 1)
		t.throws(function()
			r2:SetPeriod(0)
		end, NEW_PERIOD_RECUR_MESSAGE)
		t.throws(function()
			r2:SetPeriod(-1)
		end, NEW_PERIOD_RECUR_MESSAGE)
		t.throws(function()
			r2:SetPeriod(nil)
		end, NEW_PERIOD_RECUR_MESSAGE)
		t.throws(function()
			r2:SetPeriod(0 / 0)
		end, NEW_PERIOD_RECUR_MESSAGE)
		t.throws(function()
			r2:SetPeriod(math.huge)
		end, NEW_PERIOD_RECUR_MESSAGE)
		t.eq(r2:GetPeriod(), 1, "rejected: untouched")
		t.eq(h:SetPeriod(0), h, "a one-shot accepts 0")
		t.eq(h:GetPeriod(), 0)
		t.throws(function()
			h:SetPeriod(-1)
		end, NEW_PERIOD_ONESHOT_MESSAGE)
		t.throws(function()
			h:SetPeriod(nil)
		end, NEW_PERIOD_ONESHOT_MESSAGE)
		t.throws(function()
			h:SetPeriod(0 / 0)
		end, NEW_PERIOD_ONESHOT_MESSAGE)
		t.eq(h:GetPeriod(), 0)
		t.eq(s:Validate(), true)
	end)

	-- §4.5 `_Reset` (PENDING → heapUpdate(now + period)),
	-- §4.4 header (explicit ops measure from `_Now`, D4), R5 / P4
	t.test("reset one-shot full period from now even from another callback", function()
		local s = _new()
		local count, fn = _counter()
		-- top level
		local h = s:Delay(fn, 10)
		s:Update(1 / 4)
		t.eq(h:GetRemaining(), 39 / 4)
		t.eq(h:Reset(), h, "returns h")
		t.eq(h:GetRemaining(), 10, "full period from now")
		t.eq(h:GetState(), "Pending")
		-- from ANOTHER handle's callback with a half-second overshoot: still from now
		local inside = {}
		local trigger = s:Delay(function()
			inside.base = s:GetBase()
			inside.now = s:Now()
			h:reset()
			inside.remaining = h:GetRemaining()
		end, 1 / 2)
		s:Update(1)                                                       -- now 5/4, trigger's ideal due 3/4
		t.eq(inside.base, 3 / 4, "the callback's ideal due")
		t.eq(inside.now, 5 / 4)
		t.eq(inside.remaining, 10, "from now, not from base (prior gave 9.5)")
		t.eq(h:GetRemaining(), 10)
		t.eq(trigger:GetState(), "Fired")
		s:Update(19 / 2)
		t.eq(count.n, 0, "not yet: 9.5 s after the reset")
		s:Update(1 / 2)
		t.eq(count.n, 1, "fires exactly 10 s after the reset")
		t.eq(s:Validate(), true)
	end)

	-- §4.5 `_Reset` (recurring: key = now + P, phase restarts), R6
	t.test("reset recurring restarts phase", function()
		local s = _new()
		local count, fn = _counter()
		local r = s:Recur(fn, 1)
		s:Update(3 / 4)
		t.eq(r:GetRemaining(), 1 / 4)
		t.eq(r:Reset(), r)
		t.eq(r:GetRemaining(), 1, "full period from now")
		s:Update(1 / 4)
		t.eq(count.n, 0, "the old due (1.0) is gone")
		s:Update(3 / 4)
		t.eq(count.n, 1, "fires at 3/4 + 1")
		t.eq(r:GetRemaining(), 1, "and the phase now runs from the reset")
		s:Update(1)
		t.eq(count.n, 2)
		t.eq(r:IsRecurring(), true)
		t.eq(s:GetStats().Recurring, 1)
		-- reset on a Paused recurring refills the frozen remaining only (stays Paused)
		r:Pause()
		s:Update(1 / 2)
		r:Reset()
		t.eq(r:GetState(), "Paused")
		t.eq(r:GetRemaining(), 1)
		t.eq(s:Validate(), true)
	end)

	-- §4.5 `_Reset` inside the callback (the re-key `d + period` is replaced by `now + period`), R7
	t.test("reset inside own recurring callback replaces d+period", function()
		local s = _new()
		local count = 0
		local inside = {}
		local r
		r = s:Recur(function()
			count += 1
			inside.before = r:GetRemaining()                              -- already re-keyed at d + period
			r:Reset()
			inside.after = r:GetRemaining()
		end, 1)
		s:Update(3 / 2)                                                   -- d = 1, now = 3/2
		t.eq(count, 1)
		t.eq(inside.before, 1 / 2, "automatic re-arm: d + period − now")
		t.eq(inside.after, 1, "reset: now + period")
		t.eq(r:GetRemaining(), 1, "the reset key survives the pass")
		s:Update(1 / 2)
		t.eq(count, 1, "the automatic 2.0 due was replaced")
		s:Update(1 / 2)
		t.eq(count, 2, "fires at 3/2 + 1")
		t.eq(r:GetRemaining(), 1)
		t.eq(s:Validate(), true)
		-- a one-shot resetting itself from its own callback is a terminal no-op (SEM S4)
		local oneShotCount = 0
		local h
		h = s:Delay(function()
			oneShotCount += 1
			h:Reset()
		end, 1 / 4)
		s:Update(1 / 4)
		t.eq(h:GetState(), "Fired")
		s:Update(5)
		t.eq(oneShotCount, 1)
	end)

	-- §4.5 `_SetRemaining` (key = now + x, period untouched; Paused: remaining = x; Chained: P = x), §2.3, S-12
	t.test("SetRemaining leaves period", function()
		local s = _new()
		local count, fn = _counter()
		local r = s:Recur(fn, 4)
		t.eq(r:SetRemaining(1), r, "returns h")
		t.eq(r:GetRemaining(), 1)
		t.eq(r:GetPeriod(), 4, "period untouched")
		s:Update(1)
		t.eq(count.n, 1, "fires after x more seconds")
		t.eq(r:GetRemaining(), 4, "then the untouched period")
		s:Update(4)
		t.eq(count.n, 2)
		-- 0 means "next update"
		r:SetRemaining(0)
		t.eq(r:GetRemaining(), 0)
		s:Update(0)
		t.eq(count.n, 3)
		t.eq(r:GetPeriod(), 4)
		r:Stop()
		-- Paused: the frozen remaining is replaced, period untouched
		local paused = s:Delay(fn, 4)
		s:Update(1)
		paused:Pause()
		t.eq(paused:GetRemaining(), 3)
		paused:SetRemaining(2)
		t.eq(paused:GetState(), "Paused")
		t.eq(paused:GetRemaining(), 2)
		t.eq(paused:GetPeriod(), 4)
		paused:Resume()
		s:Update(2)
		t.eq(count.n, 4)
		-- Chained: the delay IS the remaining
		local p = s:Delay(fn, 1)
		local c = p:After(fn, 1)
		c:SetRemaining(3)
		t.eq(c:GetPeriod(), 3)
		t.eq(c:GetRemaining(), 3)
		-- validation: finite and >= 0
		local h = s:Delay(fn, 1)
		-- (no nil inside the list literal: it would end the iteration early)
		for _, bad in { -1, -1 / 4, 0 / 0, math.huge, -math.huge, "x", {}, true } do
			t.throws(function()
				h:SetRemaining(bad)
			end, REMAINING_MESSAGE)
			t.eq(h:GetRemaining(), 1, "rejected: untouched")
			t.eq(h:GetPeriod(), 1)
		end
		t.throws(function()
			h:SetRemaining(nil)
		end, REMAINING_MESSAGE)
		t.throws(function()
			h:SetRemaining()
		end, REMAINING_MESSAGE)
		local paused2 = s:Delay(fn, 1)
		paused2:Pause()
		t.throws(function()
			paused2:SetRemaining(-1)
		end, REMAINING_MESSAGE)
		t.eq(paused2:GetRemaining(), 1)
		t.throws(function()
			c:SetRemaining(-1)
		end, REMAINING_MESSAGE)
		t.eq(c:GetPeriod(), 3)
		t.eq(s:Validate(), true)
	end)

	-- §4.4 header ("explicit ops measure from `_Now`, D4"), §4.5, R10 / P4 (prior: 9.5 / 16.5 / 9.5 from base)
	t.test("explicit ops from now not base", function()
		local s = _new()
		local count, fn = _counter()
		local reset = s:Delay(fn, 10)
		local paused = s:Delay(fn, 3)
		paused:Pause()
		local adjusted = s:Delay(fn, 8)
		local retimed = s:Delay(fn, 10)
		local fired = s:Delay(fn, 1 / 4)
		s:Update(1 / 4)
		t.eq(fired:GetState(), "Fired")
		local inside = {}
		local implicit
		local trigger = s:Delay(function()
			inside.base = s:GetBase()
			inside.now = s:Now()
			reset:Reset()                                                 -- from now: 10 (base would give 9.75)
			paused:Resume()                                               -- from now: 3 (base: 2.75)
			adjusted:Adjust(16)                                           -- 7/8 left of 8 → 14 from now (base: 13.75)
			retimed:SetRemaining(2)                                       -- from now: 2
			fired:Restart()                                               -- from now: 1/4
			implicit = s:Delay(fn, 1)                                     -- IMPLICIT arm: from base → 3/4 left
			inside.reset = reset:GetRemaining()
			inside.paused = paused:GetRemaining()
			inside.adjusted = adjusted:GetRemaining()
			inside.retimed = retimed:GetRemaining()
			inside.fired = fired:GetRemaining()
			inside.implicit = implicit:GetRemaining()
		end, 1 / 2)                                                       -- due 3/4
		s:Update(3 / 4)                                                   -- now 1: overshoot 1/4
		t.eq(inside.base, 3 / 4, "the firing entry's ideal due")
		t.eq(inside.now, 1)
		t.eq(inside.reset, 10, "Reset from now")
		t.eq(inside.paused, 3, "Resume from now")
		t.eq(inside.adjusted, 14, "Adjust from now")
		t.eq(inside.retimed, 2, "SetRemaining from now")
		t.eq(inside.fired, 1 / 4, "Restart from now")
		t.eq(inside.implicit, 3 / 4, "a nested Delay is the one thing that carries the base")
		t.eq(reset:GetRemaining(), 10)
		t.eq(paused:GetRemaining(), 3)
		t.eq(paused:GetState(), "Pending")
		t.eq(adjusted:GetRemaining(), 14)
		t.eq(retimed:GetRemaining(), 2)
		t.eq(fired:GetRemaining(), 1 / 4)
		t.eq(implicit:GetRemaining(), 3 / 4)
		t.eq(s:GetBase(), false, "no base outside a firing thread")
		t.eq(trigger:GetState(), "Fired")
		t.eq(s:Validate(), true)
		-- and they fire in that order at those distances (count 1 = the first fire of `fired`)
		t.eq(count.n, 1)
		s:Update(1 / 4)
		t.eq(count.n, 2, "restarted (1/4)")
		s:Update(1 / 2)
		t.eq(count.n, 3, "implicit (3/4 from now)")
		s:Update(5 / 4)
		t.eq(count.n, 4, "retimed (2)")
		s:Update(1)
		t.eq(count.n, 5, "paused (3)")
		s:Update(7)
		t.eq(count.n, 6, "reset (10)")
		s:Update(4)
		t.eq(count.n, 7, "adjusted (14)")
		t.eq(s:GetClocks(), 0)
	end)
end

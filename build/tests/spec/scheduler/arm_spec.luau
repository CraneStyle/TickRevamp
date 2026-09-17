--!nonstrict
--[[
	arm_spec — arm validation and the arm ordering rule (docs/DESIGN.md §2.1,
	§2.2, §4.1, §4.7, §4.9; §9 scheduler/arm_spec row, 12 tests).

	Every instance runs through `Oracle.wrap`. The validation family is the
	legacy TEMPLATES of reference/live/Tick.luau:168-174 byte-for-byte, with
	`CurrentType: ` reporting `typeof` of the ORIGINAL argument (D10/DV-24).
]]

local Veron = require("../../../src/Veron")
local VeronEvent = require("../../../src/Veron/VeronEvent")
local Oracle = require("../../support/oracle")

local HUGE = math.huge

-- reference/live/Tick.luau:168-174, verbatim (the `CurrentType: ` suffix is appended per call)
local MSG_CALLABLE = "expected `fn` to be callable"
local MSG_NUMBER = "expected `delay` to be a number. CurrentType: "
local MSG_NEGATIVE = "expected `delay` of zero or greater"
-- prior strings and the three extensions (§2)
local MSG_RECUR_ZERO = "expected recur `delay` greater than zero"
local MSG_FINITE = "expected `delay` to be a finite number"
local MSG_UNCAPPED = "expected `uncapped` to be a boolean"

local function newVeron(cfg)
	cfg = cfg or {}
	if cfg.Name == nil then
		cfg.Name = "T"
	end
	return Oracle.wrap(Veron.new(cfg))
end

--[[
	pcall `fn` and assert the error message CONTAINS `text` (plain find, no
	patterns — the templates carry backticks, dots and parentheses).
]]
local function throwsPlain(t, fn, text)
	local ok, err = pcall(fn)
	t.eq(ok, false, "expected an error containing: " .. text)
	local message = tostring(err)
	if not message:find(text, 1, true) then
		error(("error %q does not contain %q"):format(message, text), 2)
	end
	return message
end

local function noop()
end

return function(t)
	-- §4.1 I1: top-level zero delay → due = now → fires at the next update, even with dt 0
	t.test("delay 0 fires next update even with dt 0", function()
		local s = newVeron()
		local fired = 0
		local h = s:Delay(function()
			fired += 1
		end, 0)
		t.eq(fired, 0, "arming never fires synchronously")
		t.eq(h:GetState(), "Pending")
		t.eq(s:GetClocks(), 1)
		s:Update(0)
		t.eq(fired, 1, "fires on the next update with dt 0")
		t.eq(h:GetState(), "Fired")
		t.eq(s:GetClocks(), 0)
		t.eq(s:Now(), 0)
		s:Update(0)
		t.eq(fired, 1, "a one-shot fires once")
		-- the dot spelling (`TickAPI.Tick.delay`) behaves identically
		local h2 = s.delay(function()
			fired += 1
		end, 0)
		t.eq(h2:GetState(), "Pending")
		s.update(0)
		t.eq(fired, 2)
	end)

	-- §4.1 `_validateArgs`: recurring with delay 0 → the prior's message (I2/F5)
	t.test("recur 0 errors with the prior message", function()
		local s = newVeron()
		throwsPlain(t, function()
			s:Recur(noop, 0)
		end, MSG_RECUR_ZERO)
		throwsPlain(t, function()
			s.recur(noop, "0")
		end, MSG_RECUR_ZERO)
		-- nothing was armed or counted
		t.eq(s:GetClocks(), 0)
		t.eq(s:GetStats().Recurring, 0)
		t.eq(s:GetStats().HeapSize, 0)
		-- a one-shot at 0 is legal (I1)
		local h = s:Delay(noop, 0)
		t.eq(h:GetState(), "Pending")
	end)

	-- §4.1: `delay < 0` → legacy template (I3)
	t.test("negative delay legacy message", function()
		local s = newVeron()
		throwsPlain(t, function()
			s:Delay(noop, -1)
		end, MSG_NEGATIVE)
		throwsPlain(t, function()
			s:Recur(noop, -1 / 64)
		end, MSG_NEGATIVE)
		throwsPlain(t, function()
			s.delay(noop, "-2")
		end, MSG_NEGATIVE)
		t.eq(s:GetClocks(), 0)
	end)

	-- §4.1: NaN and ±inf → `expected \`delay\` to be a finite number` (I4/I5, Q-J3)
	t.test("NaN and inf rejected", function()
		local s = newVeron()
		for _, bad in { 0 / 0, HUGE, -HUGE } do
			throwsPlain(t, function()
				s:Delay(noop, bad)
			end, MSG_FINITE)
			throwsPlain(t, function()
				s:Recur(noop, bad)
			end, MSG_FINITE)
		end
		-- the coerced string forms hit the same check
		throwsPlain(t, function()
			s:Delay(noop, "inf")
		end, MSG_FINITE)
		throwsPlain(t, function()
			s:Delay(noop, "nan")
		end, MSG_FINITE)
		t.eq(s:GetClocks(), 0)
		t.eq(s:GetStats().HeapSize, 0)
	end)

	-- §4.1 / DV-24: the suffix is `typeof` of the ORIGINAL argument, not of the coerced value (L-17)
	t.test("non-number reports original type", function()
		local s = newVeron()
		local cases = {
			{ nil, "nil" },
			{ {}, "table" },
			{ true, "boolean" },
			{ "abc", "string" },
			{ noop, "function" },
		}
		for _, case in cases do
			local value, expected = case[1], case[2]
			throwsPlain(t, function()
				s:Delay(noop, value)
			end, MSG_NUMBER .. expected)
			throwsPlain(t, function()
				s:Recur(noop, value)
			end, MSG_NUMBER .. expected)
		end
		-- the template must be the legacy one verbatim: exactly this text precedes the type
		local message = throwsPlain(t, function()
			s:Delay(noop, true)
		end, "expected `delay` to be a number. CurrentType: boolean")
		t.eq(message:find("CurrentType: nil", 1, true), nil, "legacy printed nil for a coerced boolean; Veron reports the original")
		t.eq(s:GetClocks(), 0)
	end)

	-- §4.1 `tonumber` coercion (I7): "2" is 2; "0.5" is 0.5
	t.test("numeric string coerced", function()
		local s = newVeron()
		local log = {}
		local h = s:Delay(function()
			log[#log + 1] = "d"
		end, "2")
		t.eq(h:GetPeriod(), 2)
		t.eq(h:GetRemaining(), 2)
		local r = s:Recur(function()
			log[#log + 1] = "r"
		end, "0.5")
		t.eq(r:GetPeriod(), 0.5)
		t.eq(r:IsRecurring(), true)
		s:Update(1.5)
		t.eq(#log, 3, "recur fired at 0.5, 1.0, 1.5")
		t.eq(log[1], "r")
		s:Update(0.5)
		-- at 2.0 both are due: the one-shot (Id 1) precedes the recur (Id 2) on the (due, Id) order
		t.eq(table.concat(log), "rrrdr")
	end)

	-- §4.1 `_isCallable` (I8): a table with __call is a callable; the callable check precedes the delay check
	t.test("callable table accepted, non-callable errors first", function()
		local s = newVeron()
		local called = 0
		local callable = setmetatable({}, {
			__call = function()
				called += 1
			end,
		})
		local h = s:Delay(callable, 0)
		t.eq(h:GetState(), "Pending")
		s:Update(0)
		t.eq(called, 1, "the callable table ran")
		-- non-callable fn: the fn check comes BEFORE the delay check, so a bad delay never surfaces
		for _, bad in { nil, {}, 5, "fn", true, setmetatable({}, {}) } do
			throwsPlain(t, function()
				s:Delay(bad, -1)
			end, MSG_CALLABLE)
			throwsPlain(t, function()
				s:Recur(bad, nil)
			end, MSG_CALLABLE)
		end
		t.eq(s:GetClocks(), 0)
	end)

	-- §2.2 "After Destroy": Update/UpdateTo/Delay/Recur/DelayAt raise `destroyed`; queries stay total
	t.test("dead instance refuses delay/recur/update", function()
		local s = newVeron()
		s:UpdateTo(10)
		local h = s:Delay(noop, 1)
		s:Destroy()
		t.eq(s:IsDestroyed(), true)
		t.eq(h:GetState(), "Stopped", "Destroy clears every handle")
		local DEAD = "Veron 'T': destroyed"
		throwsPlain(t, function()
			s:Delay(noop, 1)
		end, DEAD)
		throwsPlain(t, function()
			s.delay(noop, 1)
		end, DEAD)
		throwsPlain(t, function()
			s:Recur(noop, 1)
		end, DEAD)
		throwsPlain(t, function()
			s.recur(noop, 1)
		end, DEAD)
		throwsPlain(t, function()
			s:Update(0)
		end, DEAD)
		throwsPlain(t, function()
			s.update(1 / 64)
		end, DEAD)
		throwsPlain(t, function()
			s:UpdateTo(11)
		end, DEAD)
		throwsPlain(t, function()
			s:DelayAt(noop, 12)
		end, DEAD)
		-- the dt type check still comes FIRST (DV-23): a bad dt on a dead instance is a dt error
		throwsPlain(t, function()
			s:Update(nil)
		end, "Veron 'T': Update(dt) expects a finite number >= 0, got nil")
		-- total members stay total
		t.eq(s:Stop(h), false)
		t.eq(s:GetClocks(), 0)
		t.eq(s:Validate(), true)
		t.eq(s:GetStats().Destroyed, true)
		s:Destroy()
		t.eq(s:IsDestroyed(), true, "twice is a no-op")
	end)

	-- §2.2 Recur / §4.1 `_validateUncapped`: the third argument and the arm ordering rule
	t.test("recur third argument: nil and false capped, true uncapped, non-boolean errors before any mutation", function()
		local s = newVeron()
		local counts = { 0, 0, 0 }
		local h1 = s:Recur(function()
			counts[1] += 1
		end, 1 / 16)
		local h2 = s:Recur(function()
			counts[2] += 1
		end, 1 / 16, false)
		local h3 = s:Recur(function()
			counts[3] += 1
		end, 1 / 16, true)
		t.eq(rawget(h1, "_MaxCatchUp"), false, "nil → inherit the instance cap")
		t.eq(rawget(h2, "_MaxCatchUp"), false, "false → inherit the instance cap")
		t.eq(rawget(h3, "_MaxCatchUp"), HUGE, "true → uncapped")

		local before = s:GetStats()
		local nextId = rawget(s, "_NextId")
		t.eq(before.Recurring, 3)
		t.eq(before.HeapSize, 3)
		for _, bad in { "all", 1, {}, 0, "true" } do
			throwsPlain(t, function()
				s:Recur(noop, 1 / 16, bad)
			end, MSG_UNCAPPED)
			local after = s:GetStats()
			t.eq(after.Recurring, 3, "RecurCount untouched by the failed arm")
			t.eq(after.HeapSize, 3, "heap untouched by the failed arm")
			t.eq(s:GetClocks(), 3)
			t.eq(rawget(s, "_NextId"), nextId, "no Id was consumed by the failed arm")
		end
		-- §4.1 order: fn and delay are validated BEFORE the third argument, so a bad fn wins
		throwsPlain(t, function()
			s:Recur(nil, 1 / 16, "all")
		end, MSG_CALLABLE)

		-- behaviour: a 2 s hitch on a 1/16 s recur owes 32 fires; capped delivers MaxCatchUp (8), uncapped all 32
		s:Update(2)
		t.eq(counts[1], 8, "nil: capped at the instance MaxCatchUp")
		t.eq(counts[2], 8, "false: capped at the instance MaxCatchUp")
		t.eq(counts[3], 32, "true: every owed fire")
		t.eq(s:GetStats().ValveHits, 0)
	end)

	-- §2.2 Drive / §4.9: `uncapped` defaults to true; a non-boolean raises before `_attach`
	t.test("Drive third argument: nil and true uncapped, false capped, non-boolean errors and leaves the child unattached", function()
		local parent = newVeron({ Name = "P" })
		local c1 = newVeron({ Name = "C1" })
		local c2 = newVeron({ Name = "C2" })
		local c3 = newVeron({ Name = "C3" })
		local c4 = newVeron({ Name = "C4" })
		local h1 = parent:Drive(c1, 1 / 16)
		local h2 = parent:Drive(c2, 1 / 16, true)
		local h3 = parent:Drive(c3, 1 / 16, false)
		t.eq(rawget(h1, "_MaxCatchUp"), HUGE, "nil → uncapped (a lossless sub-clock)")
		t.eq(rawget(h2, "_MaxCatchUp"), HUGE, "true → uncapped")
		t.eq(rawget(h3, "_MaxCatchUp"), false, "false → capped (inherit)")
		t.eq(h1:IsRecurring(), true)
		t.eq(parent:GetStats().Children, 3)
		t.eq(#parent:GetChildren(), 3)
		t.eq(rawget(c1, "_Parent"), parent, "Drive always attaches")

		local nextId = rawget(parent, "_NextId")
		for _, bad in { "all", 1, {} } do
			throwsPlain(t, function()
				parent:Drive(c4, 1 / 16, bad)
			end, MSG_UNCAPPED)
			t.eq(parent:GetStats().Children, 3, "the child was not attached")
			t.eq(rawget(c4, "_Parent"), false, "the child has no parent")
			t.eq(parent:GetStats().Recurring, 3, "no pump was armed")
			t.eq(parent:GetStats().HeapSize, 3)
			t.eq(rawget(parent, "_NextId"), nextId)
		end
		-- proof of "unattached": a later Attach succeeds (a double-attach would raise)
		parent:Attach(c4)
		t.eq(parent:GetStats().Children, 4)
		t.eq(rawget(c4, "_Parent"), parent)

		-- a non-Veron child is refused with the prefixed message
		throwsPlain(t, function()
			parent:Drive({}, 1 / 16)
		end, "Veron 'P': Drive expects another Veron")
		throwsPlain(t, function()
			parent:Drive(parent, 1 / 16)
		end, "Veron 'P': Drive expects another Veron")

		-- behaviour: a 2 s parent hitch delivers every owed 1/16 to the uncapped children, 8 to the capped one
		parent:Update(2)
		t.eq(c1:Now(), 2, "uncapped child received all 32 periods")
		t.eq(c2:Now(), 2)
		t.eq(c3:Now(), 8 / 16, "capped child received MaxCatchUp periods")
		parent:Destroy()
		t.eq(c1:IsDestroyed(), true, "attached children die with the parent")
	end)

	-- §2.2 Complete / §4.7 `_checkOpts`: PascalCase `Stop` only; `{stop = true}` is an error, never a silent no-op
	t.test("unknown opts key errors in Complete/CompleteNow", function()
		local s = newVeron()
		local fired = 0
		local h = s:Delay(function()
			fired += 1
		end, 1)
		local r = s:Recur(function()
			fired += 1
		end, 1)
		local UNKNOWN = "Veron 'T': unknown option 'stop' in Complete"
		throwsPlain(t, function()
			h:Complete({ stop = true })
		end, UNKNOWN)
		throwsPlain(t, function()
			h:CompleteNow({ stop = true })
		end, UNKNOWN)
		throwsPlain(t, function()
			s:Complete(h, { stop = true })
		end, UNKNOWN)
		throwsPlain(t, function()
			s:CompleteNow(r, { stop = true })
		end, UNKNOWN)
		throwsPlain(t, function()
			s.ForceEventComplete(r, { stop = true })
		end, UNKNOWN)
		throwsPlain(t, function()
			r:Complete({ Stop = true, Now = true })
		end, "Veron 'T': unknown option 'Now' in Complete")
		-- nothing moved: both handles still Pending at their original due, nothing fired
		t.eq(fired, 0)
		t.eq(h:GetState(), "Pending")
		t.eq(h:GetRemaining(), 1)
		t.eq(r:GetState(), "Pending")
		t.eq(r:GetRemaining(), 1)
		t.eq(rawget(r, "_Flags"), 0, "no STOP_ON_FIRE was set by the refused call")
		s:Update(0)
		t.eq(fired, 0, "no deferred fire was queued")
		-- the correct spelling works
		t.eq(r:Complete({ Stop = true }), true)
		t.eq(h:Complete(), true)
		s:Update(0)
		t.eq(fired, 2)
		t.eq(r:GetState(), "Fired", "opts.Stop ended the recurring after the forced fire")
	end)

	-- §4.1 `_checkOpts`: a non-table opts → `Veron '<Name>': Complete expects an options table, got <type>`
	t.test("non-table opts errors with the prefix", function()
		local s = newVeron()
		local fired = 0
		local h = s:Delay(function()
			fired += 1
		end, 1)
		local message = throwsPlain(t, function()
			s:Complete(h, 8)
		end, "expects an options table, got number")
		t.eq(message:find("Veron 'T': Complete", 1, true) ~= nil, true, message)
		throwsPlain(t, function()
			h:Complete("x")
		end, "expects an options table, got string")
		throwsPlain(t, function()
			h:CompleteNow(true)
		end, "expects an options table, got boolean")
		message = throwsPlain(t, function()
			s:CompleteNow(h, 8)
		end, "expects an options table, got number")
		t.eq(message:find("Veron 'T': Complete", 1, true) ~= nil, true, message)
		throwsPlain(t, function()
			s.ForceEventComplete(h, noop)
		end, "expects an options table, got function")
		t.eq(fired, 0)
		t.eq(h:GetState(), "Pending")
		t.eq(h:GetRemaining(), 1)
		-- nil opts is fine
		t.eq(h:Complete(nil), true)
		s:Update(0)
		t.eq(fired, 1)
	end)
end

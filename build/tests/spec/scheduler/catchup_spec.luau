--!nonstrict
--[[
	catchup_spec — recurring catch-up (cap / uncapped / drop), the Dropped
	stat, sub-resolution periods, and the runaway valve (docs/DESIGN.md §2.1,
	§2.2, §2.3 SetCatchUp, §4.1 `_SetCatchUp`, §4.2 `_pass` + properties (f),
	§4.4 `_Restart`, §4.7; §9 scheduler/catchup_spec row, 15 tests).

	Every instance runs through `Oracle.wrap`; the 10k storm arms on the raw
	instance and wraps before the Update (an oracle walk per arm is O(n²)).
	Dyadic periods (1/16, 1/1024) keep every grid point exact; the one 0.1 s
	case asserts only what survives float rounding.
]]

local Veron = require("../../../src/Veron")
local VeronEvent = require("../../../src/Veron/VeronEvent")
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
	A counter callback: returns the function and a table whose `.n` it bumps.
]]
local function counter()
	local box = { n = 0 }
	return function()
		box.n += 1
	end, box
end

--[[
	The `NOOP` a Stopped handle carries, read off a throwaway Stopped handle of
	the same instance (§3.1: every Stopped handle shares one function).
]]
local function stoppedNoop(s)
	local probe = s:Delay(function() end, 1)
	probe:Stop()
	return rawget(probe, "_Fn")
end

local VALVE_TEXT = "nested arms / catch-up repeats); remainder deferred to the next update"

return function(t)
	-- D6 / §4.2 capped branch: MaxCatchUp fires per pass, then snap to the first grid point > now
	t.test("cap 8: 5 s hitch on a 0.1 s recur fires 8 then snaps to the grid", function()
		-- exact version on a dyadic grid (1/16 s): 80 owed, 8 delivered, the 9th..80th skipped on-grid
		local s = newVeron()
		local bases = {}
		local h = s:Recur(function()
			bases[#bases + 1] = s:GetBase()
		end, 1 / 16)
		t.eq(rawget(s, "_MaxCatchUp"), 8, "the default cap")
		s:Update(5)
		t.eq(#bases, 8, "MaxCatchUp fires in the hitch pass")
		for k = 1, 8 do
			t.eq(bases[k], k / 16, "fire " .. k .. " at its grid point")
		end
		t.eq(h:GetState(), "Pending")
		t.eq(rawget(s, "_Due")[rawget(h, "_HeapIndex")], 81 / 16, "snapped to the first grid point > now")
		t.eq(s:GetStats().Dropped, 72, "grid points 9/16 .. 80/16 skipped")
		t.eq(s:GetStats().ValveHits, 0, "the default cap never touches the valve")
		s:Update(1 / 16)
		t.eq(#bases, 9)
		t.eq(bases[9], 81 / 16, "resumes on the original grid")
		s:Update(1 / 16)
		t.eq(bases[10], 82 / 16)
		h:Stop()

		-- the literal 0.1 s case: only what survives float rounding is asserted
		local s2 = newVeron({ Name = "Tenth" })
		local fn, box = counter()
		s2:Recur(fn, 0.1)
		s2:Update(5)
		t.eq(box.n, 8, "8 fires in a 5 s hitch")
		t.eq(s2:GetStats().Dropped > 0, true)
		s2:Update(0.15)
		t.eq(box.n, 9, "exactly one grid point (~5.1) lies in (5, 5.15]")
	end)

	-- D6: the snap keeps the phase: after a hitch fires stay on `armTime + k * period`
	t.test("phase is preserved after a snap", function()
		local s = newVeron()
		s:Update(1 / 32) -- arm off the 1/16 grid on purpose: phase = 1/32
		local bases = {}
		local h = s:Recur(function()
			bases[#bases + 1] = s:GetBase()
		end, 1 / 16)
		s:Update(5)
		t.eq(s:Now(), 5 + 1 / 32)
		t.eq(#bases, 8)
		t.eq(bases[1], 3 / 32)
		t.eq(bases[8], 17 / 32)
		t.eq(rawget(s, "_Due")[rawget(h, "_HeapIndex")], 163 / 32, "first phase-aligned grid point > now")
		for _ = 1, 6 do
			s:Update(1 / 16)
		end
		t.eq(#bases, 14, "one fire per period after the snap")
		for k = 9, 14 do
			local phase = (bases[k] - 1 / 32) % (1 / 16)
			t.eq(phase, 0, "fire " .. k .. " at " .. bases[k] .. " is on the phase grid")
			t.eq(bases[k], 163 / 32 + (k - 9) / 16)
		end
		-- a second hitch snaps again onto the same grid
		s:Update(3)
		local last = bases[#bases]
		t.eq((last - 1 / 32) % (1 / 16), 0)
		s:Update(1 / 16)
		t.eq((bases[#bases] - 1 / 32) % (1 / 16), 0)
		t.eq(bases[#bases] > last, true)
	end)

	-- L-15 / DV-10: `Recur(fn, p, true)` delivers every owed fire (valve-bounded, nothing lost)
	t.test("uncapped fires every grid point", function()
		local s = newVeron()
		local bases = {}
		local h = s:Recur(function()
			bases[#bases + 1] = s:GetBase()
		end, 1 / 16, true)
		s:Update(5)
		t.eq(#bases, 80, "every owed fire")
		for k = 1, 80 do
			t.eq(bases[k], k / 16)
		end
		t.eq(s:GetStats().Dropped, 0)
		t.eq(s:GetStats().ValveHits, 0, "80 repeats are well under the valve")
		t.eq(rawget(s, "_Due")[rawget(h, "_HeapIndex")], 81 / 16)
		h:Stop()
		-- `SetCatchUp("all")` on a capped handle is the same thing
		local fn, box = counter()
		local all = s:Recur(fn, 1 / 16)
		all:SetCatchUp("all")
		t.eq(rawget(all, "_MaxCatchUp"), HUGE)
		s:Update(5)
		t.eq(box.n, 80)
	end)

	-- §2.3 SetCatchUp("drop") = cap 1: one fire per update, the rest skipped on-grid
	t.test("drop fires once per update", function()
		local s = newVeron()
		local fn, box = counter()
		local h = s:Recur(fn, 1 / 16)
		t.eq(h:SetCatchUp("drop"), h, "returns the handle")
		t.eq(rawget(h, "_MaxCatchUp"), 1)
		s:Update(5)
		t.eq(box.n, 1)
		t.eq(s:GetStats().Dropped, 79, "grid points 2/16 .. 80/16 skipped")
		t.eq(rawget(s, "_Due")[rawget(h, "_HeapIndex")], 81 / 16)
		s:Update(1 / 16)
		t.eq(box.n, 2)
		s:Update(1)
		t.eq(box.n, 3, "a 1 s update owes 16, delivers 1")
		t.eq(s:GetStats().Dropped, 94)
		t.eq(rawget(s, "_Due")[rawget(h, "_HeapIndex")], 98 / 16)
		for _ = 1, 4 do
			s:Update(1 / 16)
		end
		t.eq(box.n, 7, "no backlog ever accumulates")
	end)

	-- §4.1 `_SetCatchUp`: cap n / cap (snapshot) / all / drop / inherit; validation; one-shot and terminal no-ops
	t.test("per-handle SetCatchUp overrides, inherit drops the override", function()
		local s = newVeron({ MaxCatchUp = 3 })
		local fn, box = counter()
		local h = s:Recur(fn, 1 / 16)
		t.eq(rawget(h, "_MaxCatchUp"), false, "inherits by default")
		t.eq(h:SetCatchUp("cap", 5), h)
		t.eq(rawget(h, "_MaxCatchUp"), 5)
		s:Update(2)
		t.eq(box.n, 5, "the override wins over the instance cap of 3")
		t.eq(h:SetCatchUp("inherit"), h)
		t.eq(rawget(h, "_MaxCatchUp"), false)
		s:Update(2)
		t.eq(box.n, 8, "back to the instance cap: 3 more")
		h:SetCatchUp("all")
		t.eq(rawget(h, "_MaxCatchUp"), HUGE)
		s:Update(2)
		t.eq(box.n, 40, "uncapped: all 32 owed")
		h:SetCatchUp("drop")
		t.eq(rawget(h, "_MaxCatchUp"), 1)
		s:Update(2)
		t.eq(box.n, 41, "drop: 1")
		h:SetCatchUp("cap")
		t.eq(rawget(h, "_MaxCatchUp"), 3, "cap with no n snapshots the instance cap as a NUMBER")

		-- validation (recurring, live handle)
		throwsPlain(t, function()
			h:SetCatchUp("bogus")
		end, "Veron 'T': option 'CatchUp' expects cap, all, drop or inherit")
		throwsPlain(t, function()
			h:SetCatchUp(nil)
		end, "Veron 'T': option 'CatchUp' expects cap, all, drop or inherit")
		throwsPlain(t, function()
			h:SetCatchUp("cap", 0)
		end, "Veron 'T': option 'MaxCatchUp' expects an integer >= 1, got 0")
		throwsPlain(t, function()
			h:SetCatchUp("cap", 1.5)
		end, "Veron 'T': option 'MaxCatchUp' expects an integer >= 1, got 1.5")
		throwsPlain(t, function()
			h:SetCatchUp("cap", HUGE)
		end, "Veron 'T': option 'MaxCatchUp' expects an integer >= 1, got inf")
		throwsPlain(t, function()
			h:SetCatchUp("cap", 0 / 0)
		end, "Veron 'T': option 'MaxCatchUp' expects an integer >= 1")
		t.eq(rawget(h, "_MaxCatchUp"), 3, "untouched by refused values")

		-- one-shot: no-op BEFORE validation
		local one = s:Delay(fn, 1)
		t.eq(one:SetCatchUp("all"), one)
		t.eq(rawget(one, "_MaxCatchUp"), false)
		t.eq(one:SetCatchUp("bogus"), one, "no raise on a one-shot")
		t.eq(one:SetCatchUp("cap", 0), one)
		-- terminal recurring: no-op BEFORE validation
		h:Stop()
		t.eq(h:SetCatchUp("bogus"), h)
		t.eq(h:SetCatchUp("all"), h)
		t.eq(rawget(h, "_MaxCatchUp"), 3, "a Stopped handle is not rewritten")
	end)

	-- §2.2 / §4.9 runtime setters: inheriting handles follow the new cap from the next pass, overrides do not
	t.test("instance SetMaxCatchUp/GetMaxCatchUp at runtime", function()
		local s = newVeron()
		t.eq(s:GetMaxCatchUp(), 8)
		local fn1, box1 = counter()
		local fn2, box2 = counter()
		local inheriting = s:Recur(fn1, 1 / 16)
		local overridden = s:Recur(fn2, 1 / 16)
		overridden:SetCatchUp("cap", 4)
		s:SetMaxCatchUp(2)
		t.eq(s:GetMaxCatchUp(), 2)
		t.eq(rawget(inheriting, "_MaxCatchUp"), false, "still inheriting")
		s:Update(2)
		t.eq(box1.n, 2, "follows the new instance cap")
		t.eq(box2.n, 4, "the per-handle override is untouched")
		for _, bad in { 0, -1, 1.5, HUGE, 0 / 0, nil, "3", true } do
			throwsPlain(t, function()
				s:SetMaxCatchUp(bad)
			end, "Veron 'T': option 'MaxCatchUp' expects an integer >= 1")
			t.eq(s:GetMaxCatchUp(), 2, "unchanged after a refused value")
		end
		throwsPlain(t, function()
			s:SetMaxCatchUp(0)
		end, "got 0")
		s:SetMaxCatchUp(6)
		t.eq(s:GetMaxCatchUp(), 6)
		s:Update(2)
		t.eq(box1.n, 8, "2 + 6")
		t.eq(box2.n, 8, "4 + 4")
		-- the dot spelling and construction share the check
		s.SetMaxCatchUp(1)
		t.eq(s.GetMaxCatchUp(), 1)
		local render = Veron.new({ Name = "Tickr", MaxCatchUp = 1 })
		t.eq(render:GetMaxCatchUp(), 1)
		throwsPlain(t, function()
			Veron.new({ Name = "Bad", MaxCatchUp = 0 })
		end, "Veron: option 'MaxCatchUp' expects an integer >= 1, got 0")
	end)

	-- §4.2 capped branch: `_Dropped += m`, m = the grid points skipped by the snap (cumulative)
	t.test("Dropped counts skipped grid points", function()
		local s = newVeron()
		local fn, box = counter()
		local h = s:Recur(fn, 1)
		s:Update(20)
		t.eq(box.n, 8, "fires at 1..8")
		t.eq(s:GetStats().Dropped, 12, "grid points 9..20 skipped")
		t.eq(rawget(s, "_Due")[rawget(h, "_HeapIndex")], 21)
		s:Update(1)
		t.eq(box.n, 9)
		t.eq(s:GetStats().Dropped, 12, "a normal fire drops nothing")
		s:Update(20)
		t.eq(box.n, 17, "fires at 22..29")
		t.eq(s:GetStats().Dropped, 24, "cumulative: 30..41 skipped")
		t.eq(rawget(s, "_Due")[rawget(h, "_HeapIndex")], 42)
		h:Stop()
		-- uncapped never drops
		local fnU, boxU = counter()
		s:Recur(fnU, 1, true):SetCatchUp("all")
		s:Update(20)
		t.eq(boxU.n, 20)
		t.eq(s:GetStats().Dropped, 24)
		-- drop mode: everything but the first grid point of the pass
		local s2 = newVeron({ Name = "Drop" })
		local fnD, boxD = counter()
		s2:Recur(fnD, 1):SetCatchUp("drop")
		s2:Update(20)
		t.eq(boxD.n, 1)
		t.eq(s2:GetStats().Dropped, 19, "grid points 2..20")
	end)

	-- §4.2 `nextDue <= d` guard (capped path): a period that vanishes at this clock stops the handle, one diagnostic
	t.test("period below float resolution stops the handle with one report", function()
		local s = newVeron()
		s:Update(2 ^ 40) -- ulp at 2^40 is 2^-12: a 2^-14 period rounds away
		t.eq(s:Now(), 2 ^ 40)
		local noop = stoppedNoop(s)
		local fn, box = counter()
		local h
		local warns = captureWarns(function()
			h = s:Recur(fn, 2 ^ -14)
			t.eq(rawget(s, "_Due")[rawget(h, "_HeapIndex")], 2 ^ 40, "due == now: the period vanished")
			s:Update(0)
		end)
		t.eq(box.n, 0, "never fires: stopped instead of hanging")
		t.eq(h:GetState(), "Stopped")
		t.eq(rawget(h, "_Fn"), noop, "Stopped ⇒ NOOP")
		t.eq(rawget(h, "_HeapIndex"), 0)
		t.eq(s:GetStats().Recurring, 0)
		t.eq(s:GetStats().HeapSize, 0)
		t.eq(#warns, 1, "one report")
		t.eq(warns[1]:find("[Veron T] recur period below clock resolution at now = " .. 2 ^ 40 .. "; event #" .. h:GetId() .. " stopped", 1, true) ~= nil, true, warns[1])
		t.eq(s:GetStats().Errors, 0, "a diagnostic is not a callback error")
		t.eq(s:GetStats().ValveHits, 0)
		-- warn once per instance: a second such handle is stopped silently
		local h2
		warns = captureWarns(function()
			h2 = s:Recur(fn, 2 ^ -14)
			s:Update(0)
		end)
		t.eq(h2:GetState(), "Stopped")
		t.eq(#warns, 0)
		-- a representable period at the same clock is unaffected
		local ok = s:Recur(fn, 1)
		s:Update(1)
		t.eq(box.n, 1)
		t.eq(ok:GetState(), "Pending")
		-- a function OnError policy receives the diagnostic (message, handle)
		local got = false
		local s2 = newVeron({ Name = "F", OnError = function(message, handle)
			got = { message, handle }
		end })
		s2:Update(2 ^ 40)
		local h3 = s2:Recur(fn, 2 ^ -14)
		warns = captureWarns(function()
			s2:Update(0)
		end)
		t.eq(#warns, 0)
		t.eq(type(got), "table")
		t.eq(got[1]:find("recur period below clock resolution", 1, true) ~= nil, true, got[1])
		t.eq(got[2], h3)
		t.eq(h3:GetState(), "Stopped")
	end)

	-- §4.2 uncapped branch: the same `nextDue <= d` guard makes an uncapped recur hang-proof
	t.test("uncapped recur with sub-resolution period never hangs", function()
		local s = newVeron({ Valve = 100 })
		s:Update(2 ^ 40)
		local fn, box = counter()
		local h, warns
		warns = captureWarns(function()
			h = s:Recur(fn, 2 ^ -14, true)
			s:Update(0) -- returns: stopped on the first pop, not looped
		end)
		t.eq(box.n, 0)
		t.eq(h:GetState(), "Stopped")
		t.eq(#warns, 1)
		t.eq(warns[1]:find("recur period below clock resolution", 1, true) ~= nil, true, warns[1])
		t.eq(s:GetStats().ValveHits, 0, "the valve is not what stopped it")
		t.eq(s:GetStats().Recurring, 0)
		-- the "all" spelling too
		local h2 = s:Recur(fn, 2 ^ -14)
		h2:SetCatchUp("all")
		s:Update(0)
		t.eq(h2:GetState(), "Stopped")
		t.eq(box.n, 0)
		t.eq(s:GetStats().HeapSize, 0)
	end)

	-- D5 / B-02 / C5: nested arms count against the valve; trip → warn once via OnError, resume next update
	t.test("valve: zero-delay self-rescheduling one-shot stops at 1000, warns once via OnError, resumes next update", function()
		local diagnostics = {}
		local s = newVeron({ OnError = function(message, handle)
			diagnostics[#diagnostics + 1] = { message = message, handle = handle }
		end })
		local n = 0
		local function tick()
			n += 1
			s:Delay(tick, 0)
		end
		s:Delay(tick, 0)
		local warns = captureWarns(function()
			s:Update(0)
		end)
		t.eq(n, 1001, "the original fire plus Valve nested arms")
		t.eq(s:GetStats().ValveHits, 1)
		t.eq(#warns, 0, "the function policy took it")
		t.eq(#diagnostics, 1)
		t.eq(diagnostics[1].message:find("runaway valve hit (1000 " .. VALVE_TEXT, 1, true) ~= nil, true, diagnostics[1].message)
		t.eq(getmetatable(diagnostics[1].handle), VeronEvent, "the handle at the head of the heap")
		t.eq(diagnostics[1].handle:GetState(), "Pending")
		t.eq(s:GetStats().HeapSize, 1, "the remainder is deferred, not dropped")
		t.eq(s:GetStats().Errors, 0)
		t.eq(s:GetStats().UpdateDepth, 0)
		t.eq(s:GetBase(), false)
		-- resumes next update with a fresh budget; the warn is once per instance
		s:Update(0)
		t.eq(n, 2002)
		t.eq(s:GetStats().ValveHits, 2)
		t.eq(#diagnostics, 1, "warned once")
		s:Update(0)
		t.eq(n, 3003)
		s:Clear()
		-- the default "warn" policy goes through Env.Warn with the instance name
		local s2 = newVeron({ Name = "T2" })
		local m = 0
		local function tick2()
			m += 1
			s2:Delay(tick2, 0)
		end
		s2:Delay(tick2, 0)
		warns = captureWarns(function()
			s2:Update(0)
			s2:Update(0)
		end)
		t.eq(m, 2002)
		t.eq(#warns, 1)
		t.eq(warns[1]:find("[Veron T2] runaway valve hit (1000 " .. VALVE_TEXT, 1, true) ~= nil, true, warns[1])
		s2:Clear()
	end)

	-- §4.4: the Fired re-arm takes a fresh Id, so `h.Id > startId` counts it as a nested arm
	t.test("valve: a zero-period one-shot that Restarts itself from its own callback stops at 1000, warns once, resumes next update", function()
		local diagnostics = 0
		local s = newVeron({ OnError = function()
			diagnostics += 1
		end })
		local n = 0
		local h
		h = s:Delay(function()
			n += 1
			h:Restart()
		end, 0)
		t.eq(h:GetId(), 1)
		s:Update(0)
		t.eq(n, 1001, "the original fire plus Valve restarts")
		t.eq(s:GetStats().ValveHits, 1)
		t.eq(diagnostics, 1)
		t.eq(h:GetState(), "Pending", "the pending restart is deferred to the next update")
		t.eq(h:GetId(), 1002, "every restart took a fresh Id: 1 + 1001 restarts")
		t.eq(s:GetStats().HeapSize, 1)
		t.eq(s:GetBase(), false)
		s:Update(0)
		t.eq(n, 2002, "resumes with a fresh budget")
		t.eq(s:GetStats().ValveHits, 2)
		t.eq(diagnostics, 1, "warned once")
		t.eq(h:GetId(), 2003)
		h:Stop()
		t.eq(h:GetState(), "Stopped")
		s:Update(0)
		t.eq(n, 2002, "Stopped is final: no restart ran")

		-- two Fired siblings restarting each other are bounded the same way
		local s2 = newVeron({ Name = "Pair", OnError = function() end })
		local na, nb = 0, 0
		local a, b
		a = s2:Delay(function()
			na += 1
			b:Restart()
		end, 0)
		b = s2:Delay(function()
			nb += 1
			a:Restart()
		end, 0)
		s2:Update(0)
		t.eq(na + nb, 1002, "two pre-existing fires plus Valve restarts")
		t.eq(s2:GetStats().ValveHits, 1)
		t.eq(s2:GetStats().HeapSize, 1)
		t.eq(a:GetState() == "Pending" or b:GetState() == "Pending", true)
		s2:Update(0)
		t.eq(na + nb, 2003)
		t.eq(s2:GetStats().ValveHits, 2)
		s2:Clear()
	end)

	-- D6 / §4.2 (f): under uncapped every repeat counts; one lagging handle delivers Valve + 1 per pass
	t.test("valve counts repeats under uncapped", function()
		local s = newVeron({ Valve = 100, OnError = function() end })
		local fnU, boxU = counter()
		local fnC, boxC = counter()
		local uncapped = s:Recur(fnU, 1 / 1024, true)
		local capped = s:Recur(fnC, 1 / 1024)
		s:Update(1) -- 1024 owed to each
		t.eq(boxU.n, 101, "Valve + 1: the first fire is not a repeat")
		t.eq(boxC.n, 8, "the capped sibling fires its cap and never touches the valve")
		t.eq(s:GetStats().ValveHits, 1)
		t.eq(uncapped:GetState(), "Pending")
		t.eq(rawget(s, "_Due")[rawget(uncapped, "_HeapIndex")], 102 / 1024, "still keyed at its grid: nothing lost")
		t.eq(capped:GetState(), "Pending")
		s:Update(0)
		t.eq(boxU.n, 202, "101 more per pass")
		t.eq(boxC.n, 8, "the capped one snapped past now")
		t.eq(s:GetStats().ValveHits, 2)
		-- capped handles alone never trip the valve however far they lag
		local s2 = newVeron({ Name = "Capped", Valve = 100 })
		local fn2, box2 = counter()
		s2:Recur(fn2, 1 / 1024)
		s2:Update(1)
		t.eq(box2.n, 8)
		t.eq(s2:GetStats().ValveHits, 0)
		t.eq(s2:GetStats().Dropped, 1016)
	end)

	-- §4.2 `h.Id > startId`: pre-existing entries never count, whatever their number (raw arms, wrapped Update)
	t.test("valve never trips on a 10k pre-existing one-shot storm", function()
		local s = Veron.new({ Name = "Storm", Valve = 100 })
		local fired = 0
		local function fn()
			fired += 1
		end
		for _ = 1, 10000 do
			s:Delay(fn, 1)
		end
		Oracle.wrap(s)
		t.eq(s:GetClocks(), 10000)
		local warns = captureWarns(function()
			s:Update(1)
		end)
		t.eq(fired, 10000, "every one fired in a single update")
		t.eq(#warns, 0)
		local stats = s:GetStats()
		t.eq(stats.ValveHits, 0)
		t.eq(stats.Dispatched, 10000)
		t.eq(stats.LastDispatched, 10000)
		t.eq(stats.HeapSize, 0)
		t.eq(s:GetClocks(), 0)
		-- the same storm made of recurring handles: their first fire is not a repeat either
		local s2 = Veron.new({ Name = "RecurStorm", Valve = 100 })
		local fired2 = 0
		local handles = {}
		for index = 1, 2000 do
			handles[index] = s2:Recur(function()
				fired2 += 1
			end, 1, true)
		end
		Oracle.wrap(s2)
		s2:Update(1)
		t.eq(fired2, 2000)
		t.eq(s2:GetStats().ValveHits, 0)
		s2:Clear()
	end)

	-- §4.2 (g) / §4.7: mutual deferred Complete between uncapped recurs is bounded by the valve (repeat counting)
	t.test("mutual Complete between two uncapped recurs is valve-bounded", function()
		local diagnostics = 0
		local s = newVeron({ Valve = 100, OnError = function()
			diagnostics += 1
		end })
		local na, nb, trues = 0, 0, 0
		local a, b
		a = s:Recur(function()
			na += 1
			if b:Complete() then
				trues += 1
			end
		end, 1, true)
		b = s:Recur(function()
			nb += 1
			if a:Complete() then
				trues += 1
			end
		end, 1, true)
		s:Update(1)
		t.eq(na + nb, 102, "two first fires plus Valve repeats")
		t.eq(trues, 102, "every Complete from the other callback was accepted")
		t.eq(s:GetStats().ValveHits, 1)
		t.eq(diagnostics, 1)
		t.eq(a:GetState(), "Pending")
		t.eq(b:GetState(), "Pending")
		t.eq(s:GetStats().HeapSize, 2)
		t.eq(s:GetBase(), false)
		s:Update(0)
		t.eq(na + nb, 204, "bounded again on the next pass, with a fresh burst count")
		t.eq(s:GetStats().ValveHits, 2)
		t.eq(diagnostics, 1, "warned once")
		s:Clear()
		-- the CAPPED pair is bounded by the cap instead: 8 each, no valve involvement
		local s2 = newVeron({ Name = "CappedPair", Valve = 100 })
		local ca, cb = 0, 0
		local x, y
		x = s2:Recur(function()
			ca += 1
			y:Complete()
		end, 1)
		y = s2:Recur(function()
			cb += 1
			x:Complete()
		end, 1)
		s2:Update(1)
		t.eq(ca, 8)
		t.eq(cb, 8)
		t.eq(s2:GetStats().ValveHits, 0)
		t.eq(x:GetState(), "Pending")
		t.eq(y:GetState(), "Pending")
		s2:Clear()
	end)

	-- §4.2 (f) / B-20: a valve trip defers, never drops: every owed grid point is delivered across updates
	t.test("uncapped recur after a hitch fires every owed tick across updates when the valve trips (nothing lost)", function()
		local diagnostics = 0
		local s = newVeron({ Valve = 100, OnError = function()
			diagnostics += 1
		end })
		local bases = {}
		local h = s:Recur(function()
			bases[#bases + 1] = s:GetBase()
		end, 1 / 1024, true)
		s:Update(2)
		t.eq(#bases, 101, "pass 1: Valve + 1 fires (the first is not a repeat)")
		t.eq(s:GetStats().ValveHits, 1)
		t.eq(h:GetState(), "Pending")
		t.eq(rawget(s, "_Due")[rawget(h, "_HeapIndex")], 102 / 1024, "still keyed at its grid")
		t.eq(s:GetStats().LastDispatched, 101)
		local perPass = { 101 }
		for pass = 2, 21 do
			local before = #bases
			s:Update(0)
			perPass[pass] = #bases - before
		end
		for pass = 2, 20 do
			t.eq(perPass[pass], 101, "pass " .. pass .. " delivers 101 more")
		end
		t.eq(perPass[21], 28, "the last pass delivers the remainder without tripping")
		t.eq(#bases, 2048, "total fires == owed: nothing lost")
		t.eq(s:GetStats().ValveHits, 20)
		t.eq(s:GetStats().Dropped, 0)
		t.eq(diagnostics, 1, "warned once")
		for k = 1, 2048 do
			if bases[k] ~= k / 1024 then
				error(("fire %d at base %s, expected %s"):format(k, tostring(bases[k]), tostring(k / 1024)))
			end
		end
		t.eq(rawget(s, "_Due")[rawget(h, "_HeapIndex")], 2049 / 1024, "caught up: keyed at the first future grid point")
		s:Update(0)
		t.eq(#bases, 2048, "nothing more is owed")
		t.eq(s:GetStats().ValveHits, 20)
		s:Update(1 / 1024)
		t.eq(#bases, 2049, "back to one fire per period")
		t.eq(bases[2049], 2049 / 1024)
	end)
end

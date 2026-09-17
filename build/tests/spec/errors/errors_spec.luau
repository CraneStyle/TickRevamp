--!nonstrict
--[[
	errors_spec — the error contract of docs/DESIGN.md §2 (validation family
	unprefixed and byte-identical to reference/live/Tick.luau; every other
	error class-prefixed; error LEVEL blames the caller's line), §4.1/§4.5/
	§4.7/§4.9 raise sites; §9 errors/errors_spec row — 4 tests, names
	verbatim.

	RAW: no Oracle.wrap — the oracle's wrappers add a stack frame, which
	would shift every level (BUILD-NOTES WP2). Every raising call sits on ONE
	line together with `L()`, which records that line, so the reported
	`chunk:line:` prefix can be compared exactly.

	Modules are required lazily so this file loads before the core exists.
]]

local fs = require("@lune/fs")

local Veron, Env

local function _load()
	if Veron then
		return
	end
	Veron = require("../../../src/Veron")
	Env = require("../../../src/Veron/Env")
end

local function _noop() end

local SPEC_CHUNK = "errors_spec"
local REFERENCE_PATH = "reference/live/Tick.luau"

-- The line of the call that follows `L()` on the same source line.
local expectedLine = 0
local function L()
	expectedLine = debug.info(2, "l")
end

--[[
	Splits a raised message into (chunk, line, body). A message raised with
	level 0 has no prefix: chunk and line come back nil, body is the whole.
]]
local function _split(err)
	local text = tostring(err)
	local chunk, line, body = text:match("^(.-):(%d+): (.*)$")
	if chunk == nil then
		return nil, nil, text
	end
	return chunk, tonumber(line), body
end

--[[
	Runs `fn`, asserts it raised, and returns (chunk, line, body).
]]
local function _raise(t, label, fn)
	local ok, err = pcall(fn)
	if ok then
		error(label .. ": expected an error, none thrown")
	end
	return _split(err)
end

--[[
	The fixtures every case list shares: a raw instance `s` ('T'), a second
	instance `other` ('U') with a foreign handle, a Strict instance, a
	destroyed one, an attachable child and one already attached to `s`.
]]
local function _fixtures()
	_load()
	local f = {}
	f.s = Veron.new({ Name = "T" })
	f.other = Veron.new({ Name = "U" })
	f.strict = Veron.new({ Name = "S", Strict = true })
	f.dead = Veron.new({ Name = "D" })
	f.dead:Destroy()
	f.child = Veron.new({ Name = "C" })
	f.attached = Veron.new({ Name = "A" })
	f.s:Attach(f.attached)
	f.foreign = f.other:Delay(_noop, 1)
	f.h = f.s:Delay(_noop, 1)
	f.r = f.s:Recur(_noop, 1)
	return f
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
	t.test("every error blames the caller's chunk (level table §2, incl. cfg via new, Drive→Attach, "
		.. "Drive/Recur→uncapped; Veron(cfg) is the documented exception)", function()
		local f = _fixtures()
		local s, other, strict, dead, child, attached = f.s, f.other, f.strict, f.dead, f.child, f.attached
		local foreign, h, r = f.foreign, f.h, f.r
		-- { label, fn }: `L()` and the raising call share ONE line
		local cases = {
			-- instance methods through the dual closure (method body level 3, helper level 4)
			{ "Update(nil)", function() L() s:Update(nil) end },
			{ "update(\"x\") dot alias", function() L() s.update("x") end },
			{ "Update(-1)", function() L() s:Update(-1) end },
			{ "Update(inf)", function() L() s:Update(math.huge) end },
			{ "UpdateTo(NaN)", function() L() s:UpdateTo(0 / 0) end },
			{ "SetTimeScale(-1)", function() L() s:SetTimeScale(-1) end },
			{ "Delay(nil, 1)", function() L() s:Delay(nil, 1) end },
			{ "delay(fn, \"x\") dot alias", function() L() s.delay(_noop, "x") end },
			{ "Delay(fn, -1)", function() L() s:Delay(_noop, -1) end },
			{ "Delay(fn, NaN)", function() L() s:Delay(_noop, 0 / 0) end },
			{ "Recur(fn, 0)", function() L() s:Recur(_noop, 0) end },
			{ "Recur(fn, 1, \"all\") uncapped", function() L() s:Recur(_noop, 1, "all") end },
			{ "recur(fn, 1, 1) uncapped dot alias", function() L() s.recur(_noop, 1, 1) end },
			{ "DelayAt before UpdateTo", function() L() s:DelayAt(_noop, 1) end },
			{ "Stop(foreign)", function() L() s:Stop(foreign) end },
			{ "remove(foreign) dot alias", function() L() s.remove(foreign) end },
			{ "Complete(foreign)", function() L() s:Complete(foreign) end },
			{ "CompleteNow(foreign)", function() L() s:CompleteNow(foreign) end },
			{ "Strict Stop({})", function() L() strict:Stop({}) end },
			{ "Strict Remove(5)", function() L() strict:Remove(5) end },
			{ "Complete(h, {stop=true})", function() L() s:Complete(h, { stop = true }) end },
			{ "CompleteNow(h, {stop=true})", function() L() s:CompleteNow(h, { stop = true }) end },
			{ "Complete(h, 8)", function() L() s:Complete(h, 8) end },
			{ "Attach(self)", function() L() s:Attach(s) end },
			{ "Attach({})", function() L() s:Attach({}) end },
			{ "Attach(destroyed)", function() L() s:Attach(dead) end },
			{ "Attach(already attached)", function() L() s:Attach(attached) end },
			{ "Attach cycle", function() L() attached:Attach(s) end },
			{ "Drive({}, 1)", function() L() s:Drive({}, 1) end },
			{ "Drive(self, 1)", function() L() s:Drive(s, 1) end },
			{ "Drive(child, 0)", function() L() s:Drive(child, 0) end },
			{ "Drive(child, 1, \"x\") uncapped", function() L() s:Drive(child, 1, "x") end },
			{ "Drive → Attach already attached", function() L() s:Drive(attached, 1) end },
			{ "Drive → Attach destroyed child", function() L() s:Drive(dead, 1) end },
			{ "SetValve(0)", function() L() s:SetValve(0) end },
			{ "SetMaxDt(-1)", function() L() s:SetMaxDt(-1) end },
			{ "SetStrict(1)", function() L() s:SetStrict(1) end },
			{ "SetOnError(\"loud\")", function() L() s:SetOnError("loud") end },
			{ "SetMaxCatchUp(1.5)", function() L() s:SetMaxCatchUp(1.5) end },
			-- destroyed instance
			{ "destroyed Update(0)", function() L() dead:Update(0) end },
			{ "destroyed UpdateTo(1)", function() L() dead:UpdateTo(1) end },
			{ "destroyed Delay", function() L() dead:Delay(_noop, 1) end },
			{ "destroyed Recur", function() L() dead:Recur(_noop, 1) end },
			{ "destroyed DelayAt", function() L() dead:DelayAt(_noop, 1) end },
			{ "destroyed Attach", function() L() dead:Attach(child) end },
			{ "destroyed Drive", function() L() dead:Drive(child, 1) end },
			-- handle methods (level 2 / delegated level 3 / helper level 4)
			{ "h:Adjust(0)", function() L() h:Adjust(0) end },
			{ "h:adjust(-1) alias", function() L() h:adjust(-1) end },
			{ "h:SetRemaining(-1)", function() L() h:SetRemaining(-1) end },
			{ "h:SetPeriod(-1)", function() L() h:SetPeriod(-1) end },
			{ "r:SetPeriod(0)", function() L() r:SetPeriod(0) end },
			{ "h:After(nil, 1)", function() L() h:After(nil, 1) end },
			{ "h:after(fn, -1) alias", function() L() h:after(_noop, -1) end },
			{ "r:After(fn, 1)", function() L() r:After(_noop, 1) end },
			{ "h:Complete({stop=true})", function() L() h:Complete({ stop = true }) end },
			{ "h:CompleteNow(8)", function() L() h:CompleteNow(8) end },
			{ "r:SetCatchUp(\"bogus\")", function() L() r:SetCatchUp("bogus") end },
			{ "r:SetCatchUp(\"cap\", 0)", function() L() r:SetCatchUp("cap", 0) end },
			{ "h.Stop() dot call", function() L() h.Stop() end },
			-- construction (initialize raises at level 4: new / :new sites)
			{ "Veron.new{Bogus}", function() L() Veron.new({ Bogus = 1 }) end },
			{ "Veron:new{Bogus}", function() L() Veron:new({ Bogus = 1 }) end },
			{ "Veron.new{TimeScale=-1}", function() L() Veron.new({ TimeScale = -1 }) end },
			{ "Veron:new{MaxCatchUp=0}", function() L() Veron:new({ MaxCatchUp = 0 }) end },
			{ "Veron.new{Valve=\"x\"}", function() L() Veron.new({ Valve = "x" }) end },
			{ "Veron.new{MaxDt=0}", function() L() Veron.new({ MaxDt = 0 }) end },
			{ "Veron.new{MaxUpdateDepth=0}", function() L() Veron.new({ MaxUpdateDepth = 0 }) end },
			{ "Veron.new{OnError=5}", function() L() Veron.new({ OnError = 5 }) end },
			{ "Veron.new{Strict=1}", function() L() Veron.new({ Strict = 1 }) end },
			{ "Veron.new{LegacyRecurBase=\"y\"}", function() L() Veron.new({ LegacyRecurBase = "y" }) end },
			{ "Veron.new{Name=5}", function() L() Veron.new({ Name = 5 }) end },
		}
		for _, case in cases do
			local label, fn = case[1], case[2]
			expectedLine = 0
			local chunk, line, body = _raise(t, label, fn)
			t.eq(chunk ~= nil and chunk:find(SPEC_CHUNK, 1, true) ~= nil, true,
				("%s: chunk %s should be this spec (%s)"):format(label, tostring(chunk), body))
			t.eq(line, expectedLine, label .. ": line (" .. body .. ")")
		end
		-- nothing above mutated the fixtures
		t.eq(s:GetClocks(), 2)
		t.eq(h:GetState(), "Pending")
		t.eq(r:GetState(), "Pending")
		t.eq(other:GetClocks(), 1)
		t.eq(#s:GetChildren(), 1)
		t.eq(child:IsDestroyed(), false)
		t.eq(s:Validate(), true)

		-- the documented exception: Veron(cfg) goes through Veron's own __call
		-- metamethod, so a config error there blames the Veron module rather than
		-- the caller's line. The dot and colon spellings above blame the caller.
		local chunk, _, body = _raise(t, "Veron{Bogus}", function()
			Veron({ Bogus = 1 })
		end)
		t.eq(chunk ~= nil, true, "prefixed: " .. body)
		t.eq(chunk:find(SPEC_CHUNK, 1, true), nil, "Veron(cfg) does not blame the spec: " .. tostring(chunk))
		t.eq(chunk:find("Veron", 1, true) ~= nil, true, "Veron(cfg) blames the Veron module: " .. tostring(chunk))
		t.eq(body, "Veron: unknown option 'Bogus'")
	end)

	t.test("legacy validation templates are byte-identical to reference/live/Tick.luau "
		.. "and CurrentType reports the original type", function()
		-- §2 error contract (D10/L-17, DV-24): templates verbatim, `typeof` of the ORIGINAL argument
		local f = _fixtures()
		local s, h, r = f.s, f.h, f.r
		local source = fs.readFile(REFERENCE_PATH)
		local fnTemplate = source:match("error%(\"(expected `fn` to be callable)\"%)")
		local typeTemplate = source:match("error%(\"(expected `delay` to be a number%. CurrentType: )\" %.%. type%(delay%)%)")
		local negativeTemplate = source:match("error%(\"(expected `delay` of zero or greater)\"%)")
		t.eq(fnTemplate, "expected `fn` to be callable", "reference template found")
		t.eq(typeTemplate, "expected `delay` to be a number. CurrentType: ", "reference template found")
		t.eq(negativeTemplate, "expected `delay` of zero or greater", "reference template found")

		local function body(label, fn)
			local _, _, text = _raise(t, label, fn)
			return text
		end
		-- the three legacy templates, byte-identical
		t.eq(body("Delay(nil)", function() s:Delay(nil, 1) end), fnTemplate)
		t.eq(body("Delay(5, 1)", function() s:Delay(5, 1) end), fnTemplate)
		t.eq(body("Recur(nil)", function() s:Recur(nil, 1) end), fnTemplate)
		t.eq(body("After(nil)", function() h:After(nil, 1) end), fnTemplate)
		t.eq(body("Delay(fn, -1)", function() s:Delay(_noop, -1) end), negativeTemplate)
		t.eq(body("Recur(fn, -1)", function() s:Recur(_noop, -1) end), negativeTemplate)
		t.eq(body("After(fn, -1)", function() h:After(_noop, -1) end), negativeTemplate)
		-- CurrentType: `typeof` of the caller's ORIGINAL argument (legacy printed the coerced value's type)
		t.eq(body("Delay(fn, {})", function() s:Delay(_noop, {}) end), typeTemplate .. "table")
		t.eq(body("Delay(fn, true)", function() s:Delay(_noop, true) end), typeTemplate .. "boolean")
		t.eq(body("Delay(fn, nil)", function() s:Delay(_noop, nil) end), typeTemplate .. "nil")
		t.eq(body("Delay(fn, \"abc\")", function() s:Delay(_noop, "abc") end), typeTemplate .. "string")
		t.eq(body("Recur(fn, {})", function() s:Recur(_noop, {}) end), typeTemplate .. "table")
		t.eq(body("After(fn, false)", function() h:After(_noop, false) end), typeTemplate .. "boolean")
		-- legacy coercion still holds: a numeric string is accepted
		local coerced = s:Delay(_noop, "0.5")
		t.eq(coerced:GetPeriod(), 0.5)
		t.eq(s:Recur(_noop, "0.25"):GetPeriod(), 0.25)
		-- the prior strings
		t.eq(body("Recur(fn, 0)", function() s:Recur(_noop, 0) end), "expected recur `delay` greater than zero")
		t.eq(body("Adjust(0)", function() h:Adjust(0) end), "expected `newTotal` greater than zero")
		t.eq(body("Adjust(-1)", function() h:Adjust(-1) end), "expected `newTotal` greater than zero")
		t.eq(body("Adjust(NaN)", function() h:Adjust(0 / 0) end), "expected `newTotal` greater than zero")
		t.eq(body("Adjust(nil)", function() h:Adjust(nil) end), "expected `newTotal` greater than zero")
		t.eq(body("r:SetPeriod(0)", function() r:SetPeriod(0) end), "expected `newPeriod` greater than zero")
		t.eq(body("h:SetPeriod(-1)", function() h:SetPeriod(-1) end), "expected `newPeriod` of zero or greater")
		-- the three extensions in the same voice
		t.eq(body("Delay(fn, NaN)", function() s:Delay(_noop, 0 / 0) end), "expected `delay` to be a finite number")
		t.eq(body("Delay(fn, inf)", function() s:Delay(_noop, math.huge) end), "expected `delay` to be a finite number")
		t.eq(body("Delay(fn, -inf)", function() s:Delay(_noop, -math.huge) end), "expected `delay` to be a finite number")
		t.eq(body("Recur(fn, inf)", function() s:Recur(_noop, math.huge) end), "expected `delay` to be a finite number")
		t.eq(body("SetRemaining(-1)", function() h:SetRemaining(-1) end), "expected `remaining` of zero or greater")
		t.eq(body("SetRemaining(NaN)", function() h:SetRemaining(0 / 0) end), "expected `remaining` of zero or greater")
		t.eq(body("Recur(fn, 1, 1)", function() s:Recur(_noop, 1, 1) end), "expected `uncapped` to be a boolean")
		t.eq(body("Recur(fn, 1, \"all\")", function() s:Recur(_noop, 1, "all") end), "expected `uncapped` to be a boolean")
		t.eq(body("Drive(child, 1, {})", function() s:Drive(f.child, 1, {}) end), "expected `uncapped` to be a boolean")
		t.eq(s:Validate(), true)
	end)

	t.test("every error outside the validation family carries its class prefix", function()
		-- §2: `Veron '<Name>': ` on instance errors, `VeronEvent: ` on handle-surface
		-- errors, bare `Veron: ` on config errors (raised before Name is settled)
		local f = _fixtures()
		local s, strict, dead, child, attached = f.s, f.strict, f.dead, f.child, f.attached
		local foreign, h, r = f.foreign, f.h, f.r
		local VeronEvent = require("../../../src/Veron/VeronEvent")
		-- { label, expected prefix, fn }
		local cases = {
			{ "Update(nil)", "Veron 'T': ", function() s:Update(nil) end },
			{ "Update(-1)", "Veron 'T': ", function() s:Update(-1) end },
			{ "Update(\"0.5\")", "Veron 'T': ", function() s:Update("0.5") end },
			{ "UpdateTo(NaN)", "Veron 'T': ", function() s:UpdateTo(0 / 0) end },
			{ "SetTimeScale(-1)", "Veron 'T': ", function() s:SetTimeScale(-1) end },
			{ "DelayAt before UpdateTo", "Veron 'T': ", function() s:DelayAt(_noop, 1) end },
			{ "Stop(foreign)", "Veron 'T': ", function() s:Stop(foreign) end },
			{ "Complete(foreign)", "Veron 'T': ", function() s:Complete(foreign) end },
			{ "Strict Stop({})", "Veron 'S': ", function() strict:Stop({}) end },
			{ "Complete(h, {stop=true})", "Veron 'T': ", function() s:Complete(h, { stop = true }) end },
			{ "Complete(h, 8)", "Veron 'T': ", function() s:Complete(h, 8) end },
			{ "Attach(self)", "Veron 'T': ", function() s:Attach(s) end },
			{ "Attach({})", "Veron 'T': ", function() s:Attach({}) end },
			{ "Attach(destroyed)", "Veron 'T': ", function() s:Attach(dead) end },
			{ "Attach(already attached)", "Veron 'T': ", function() s:Attach(attached) end },
			{ "Attach cycle", "Veron 'A': ", function() attached:Attach(s) end },
			{ "Drive({}, 1)", "Veron 'T': ", function() s:Drive({}, 1) end },
			{ "Drive → Attach", "Veron 'T': ", function() s:Drive(attached, 1) end },
			{ "SetValve(0)", "Veron 'T': ", function() s:SetValve(0) end },
			{ "SetMaxDt(-1)", "Veron 'T': ", function() s:SetMaxDt(-1) end },
			{ "SetStrict(1)", "Veron 'T': ", function() s:SetStrict(1) end },
			{ "SetOnError(\"loud\")", "Veron 'T': ", function() s:SetOnError("loud") end },
			{ "SetMaxCatchUp(1.5)", "Veron 'T': ", function() s:SetMaxCatchUp(1.5) end },
			{ "destroyed Update", "Veron 'D': ", function() dead:Update(0) end },
			{ "destroyed Delay", "Veron 'D': ", function() dead:Delay(_noop, 1) end },
			{ "destroyed Attach", "Veron 'D': ", function() dead:Attach(child) end },
			{ "h:Complete({stop=true})", "Veron 'T': ", function() h:Complete({ stop = true }) end },
			{ "h:CompleteNow(8)", "Veron 'T': ", function() h:CompleteNow(8) end },
			{ "r:SetCatchUp(\"bogus\")", "Veron 'T': ", function() r:SetCatchUp("bogus") end },
			{ "r:SetCatchUp(\"cap\", 0)", "Veron 'T': ", function() r:SetCatchUp("cap", 0) end },
			{ "h.Stop() dot call", "VeronEvent: ", function() h.Stop() end },
			{ "h.GetState() dot call", "VeronEvent: ", function() h.GetState() end },
			{ "VeronEvent:new()", "VeronEvent: ", function() VeronEvent:new() end },
			{ "Veron.new{Bogus}", "Veron: ", function() Veron.new({ Bogus = 1 }) end },
			{ "Veron.new{TimeScale=-1}", "Veron: ", function() Veron.new({ TimeScale = -1 }) end },
			{ "Veron{OnError=5}", "Veron: ", function() Veron({ OnError = 5 }) end },
		}
		for _, case in cases do
			local label, prefix, fn = case[1], case[2], case[3]
			local _, _, body = _raise(t, label, fn)
			t.eq(body:sub(1, #prefix), prefix, ("%s: expected prefix %q in %q"):format(label, prefix, body))
		end
		-- the exact texts the design spells out (§2.1, §2.2, §4.3, §4.9)
		local function body(fn)
			local _, _, text = _raise(t, "text", fn)
			return text
		end
		t.eq(body(function() Veron.new({ Bogus = 1 }) end), "Veron: unknown option 'Bogus'")
		t.eq(body(function() s:Update(nil) end), "Veron 'T': Update(dt) expects a finite number >= 0, got nil")
		t.eq(body(function() s:Stop(foreign) end), "Veron 'T': event #1 belongs to Veron 'U', not 'T'")
		t.eq(body(function() strict:Stop({}) end), "Veron 'S': expected a VeronEvent, got table")
		t.eq(body(function() h:Complete({ stop = true }) end), "Veron 'T': unknown option 'stop' in Complete")
		t.eq(body(function() s:Attach(s) end), "Veron 'T': cannot attach itself")
		t.eq(body(function() s:Attach(attached) end), "Veron 'T': 'A' is already attached to 'T'")
		t.eq(body(function() attached:Attach(s) end), "Veron 'A': Attach would create a cycle")
		t.eq(body(function() s:Attach(dead) end), "Veron 'T': 'D' is destroyed")
		t.eq(body(function() s:Attach({}) end), "Veron 'T': Attach expects a Veron, got table")
		t.eq(body(function() s:Drive({}, 1) end), "Veron 'T': Drive expects another Veron")
		t.eq(body(function() dead:Update(0) end), "Veron 'D': destroyed")
		t.eq(body(function() r:SetCatchUp("bogus") end), "Veron 'T': option 'CatchUp' expects cap, all, drop or inherit")
		t.eq(body(function() h.Stop() end), "VeronEvent: methods take a colon: event:Stop(), not event.Stop()")
		t.eq(body(function() VeronEvent:new() end), "VeronEvent: handles are created by a Veron (Delay/Recur/After)")
		t.eq(s:Validate(), true)
	end)

	t.test("Stats.Errors increments", function()
		-- §4.2 `_report`: `Errors` is the true count; `ErrorsSuppressed` the withheld reports
		local captured = _withWarnCapture(function()
			local s = Veron.new({ Name = "T" })
			t.eq(s:GetStats().Errors, 0)
			t.eq(s:GetStats().ErrorsSuppressed, 0)
			s:Delay(function()
				error("one")
			end, 1 / 4)
			s:Update(1 / 4)
			t.eq(s:GetStats().Errors, 1)
			local r = s:Recur(function()
				error("again")
			end, 1 / 4)
			s:Update(1 / 4) -- now 0.5: a distinct handle within 1 s, >= 0.125 s later → reported
			t.eq(s:GetStats().Errors, 2)
			s:Update(1 / 4) -- now 0.75: the same handle within 1 s → suppressed, still counted
			t.eq(s:GetStats().Errors, 3)
			t.eq(s:GetStats().ErrorsSuppressed, 1)
			r:Stop()
			local h = s:Delay(function()
				error("sync")
			end, 5)
			t.eq(h:CompleteNow(), true)
			t.eq(s:GetStats().Errors, 4, "a CompleteNow error counts too")
			-- healthy callbacks never count
			s:Delay(_noop, 1 / 4)
			s:Update(1 / 4)
			t.eq(s:GetStats().Errors, 4)
			t.eq(s:Validate(), true)
			local into = {}
			t.eq(s:GetStats(into), into)
			t.eq(into.Errors, 4)
		end)
		t.eq(#captured, 3, "three reports reached Warn, one was suppressed")
		t.eq(captured[1]:find("one", 1, true) ~= nil, true, captured[1])
		t.eq(captured[2]:find("again", 1, true) ~= nil, true, captured[2])
		t.eq(captured[3]:find("sync", 1, true) ~= nil, true, captured[3])
	end)
end

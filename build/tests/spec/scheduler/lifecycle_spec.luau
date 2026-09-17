--!nonstrict
--[[
	lifecycle_spec — Destroy / Attach / Detach / Drive, counters, stats,
	diagnostics, runtime setters, Validate, ids and the §2.4 touch patterns
	(docs/DESIGN.md §2.2, §2.4, §4.2 _diagnose/_report, §4.9, §4.11, §9
	scheduler/lifecycle_spec row). Every instance runs under Oracle.wrap
	except where a test deliberately corrupts state or measures allocation
	(the oracle wrapper packs results, so it allocates; a corrupted heap
	would make the wrapper raise before Validate could report it).

	Test → DESIGN section:
	  Destroy clears, marks dead, detaches from its parent; twice is a no-op . §4.9 Destroy, §2.2 "After Destroy"
	  Attach: parent Destroy destroys the child, Clear clears the child ...... §4.9, §4.3 Clear (N3)
	  Attach refuses self, destroyed, double-attach, cycle ................... §4.9 _attach, §2.2 Attach errors
	  child Destroy detaches from its parent ................................. §4.9 Destroy (self-detach)
	  Detach stops the cascade ............................................... §4.9 Detach
	  Drive advances the child by period per parent fire ..................... §4.9 Drive (N2)
	  Drive under a hitch — uncapped keeps child time, capped drops it ....... §4.9 Drive, §4.2 catch-up (JF-15)
	  Drive always attaches; mutual Drive is refused as a cycle .............. §4.9 Drive/_attach
	  Drive stops itself after child Destroy without OnError noise ........... §4.9 Drive pump
	  Children stat tracks Attach/Detach/Destroy without a walk .............. §3.2 _ChildCount, §2.2 GetStats
	  GetClocks counts Pending + Paused only ................................. §2.2 GetClocks (O1)
	  GetStats fields present, cumulative, and a warmed GetStats(into)
	    allocates nothing ..................................................... §2.2 GetStats, §4.11
	  repeated callback errors are rate-limited and counted .................. §4.2 _report (F-PM-3)
	  every diagnostic reaches a function OnError policy and never re-raises
	    under "error" ......................................................... §4.2 _diagnose (JF-16)
	  runtime setters validate like construction and take effect ............. §2.2 Set*, §4.9 runtime setters
	  Validate reports a deliberately corrupted heap ......................... §3.2 invariants, §4.11
	  handle ids ascend from 1 and are never reused .......................... §2.3 Id, §4.1 _newEvent, §4.4 (O3)
	  reset-after-touched, recur-till-touched and recur-switch patterns ...... §2.4, §4.4
]]

local Veron = require("../../../src/Veron")
local Env = require("../../../src/Veron/Env")
local Oracle = require("../../support/oracle")

local F64 = 1 / 64
local F128 = 1 / 128

local STATS_KEYS = {
	"Name", "Destroyed", "Now", "TimeScale", "IsPaused", "Pending", "Paused", "Chained",
	"Recurring", "HeapSize", "Clocks", "Updates", "LastDt", "Dispatched", "LastDispatched",
	"Reentries", "UpdateDepth", "Dropped", "ValveHits", "ClampedBackwards", "ClampedDt",
	"Errors", "ErrorsSuppressed", "Children",
}

local function _noop() end

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

local function _named(name)
	return _new({ Name = name })
end

--[[
	Runs `body(warns)` with the Warn seam captured, restores it whatever
	happens, re-raises on failure and returns the captured list.
]]
local function _withWarns(body)
	local warns = {}
	local restore = Env.SetWarn(function(msg)
		warns[#warns + 1] = tostring(msg)
	end)
	local ok, err = pcall(body, warns)
	restore()
	if not ok then
		error(err, 0)
	end
	return warns
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

--[[
	Fires the four instance diagnostics of §4.2 in an order that lets each
	one be observed: re-entry, backwards clock (> 1 s), sub-resolution
	period, then the runaway valve (last, because a tripped valve leaves the
	pass early). Returns the handles the last two were raised for.
]]
local function _triggerDiagnostics(s)
	s:Delay(function()
		s:Update(0)
	end, 0)
	s:Update(0)                                              -- re-entered
	s:UpdateTo(10)
	s:UpdateTo(5)                                            -- backwards by 5 s
	s:Update(2 ^ 30)                                         -- a clock where 1e-10 is below one ulp
	local tiny = s:Recur(_noop, 1e-10)
	s:Update(0)                                              -- resolution: stopped with one report
	local n = 0
	local last
	local function chain()
		n += 1
		if n < 150 then
			last = s:Delay(chain, 0)
		end
	end
	s:Delay(chain, 0)
	s:Update(0)                                              -- valve (100): trips once, remainder deferred
	return tiny, last
end

return function(t)
	t.test("Destroy clears, marks dead, detaches from its parent; twice is a no-op", function()
		local parent = _named("P")
		local child = _named("C")
		parent:Attach(child)
		local fired = 0
		local d = child:Delay(function()
			fired += 1
		end, F64)
		local r = child:Recur(function()
			fired += 1
		end, F64)
		local p = child:Recur(function()
			fired += 1
		end, F64)
		p:Pause()
		t.eq(child:GetClocks(), 3)
		t.eq(parent:GetStats().Children, 1)

		child:Destroy()
		t.eq(child:IsDestroyed(), true)
		t.eq(child:GetStats().Destroyed, true)
		t.eq(child:GetClocks(), 0)
		t.eq(d:GetState(), "Stopped")
		t.eq(r:GetState(), "Stopped")
		t.eq(p:GetState(), "Stopped")
		t.eq(parent:GetStats().Children, 0, "detached from its parent")
		t.eq(#parent:GetChildren(), 0)
		t.eq(rawget(child, "_Parent"), false)
		t.eq(parent:IsDestroyed(), false)

		child:Destroy()                                      -- twice is a no-op
		t.eq(child:IsDestroyed(), true)
		t.eq(parent:GetStats().Children, 0)

		-- dead: arms and updates refuse, everything else stays total
		t.throws(function()
			child:Update(F64)
		end, "Veron 'C': destroyed")
		t.throws(function()
			child:UpdateTo(1)
		end, "Veron 'C': destroyed")
		t.throws(function()
			child:Delay(_noop, 1)
		end, "Veron 'C': destroyed")
		t.throws(function()
			child:Recur(_noop, 1)
		end, "Veron 'C': destroyed")
		t.throws(function()
			child:Attach(_named("X"))
		end, "Veron 'C': destroyed")
		t.eq(child:Stop(d), false)
		t.eq(child:Complete(d), false)
		t.eq(child:GetRemaining(d), 0)
		t.eq(child:GetClocks(), 0)
		t.eq(child:Clear(), 0)
		t.eq(child:Validate(), true)
		t.eq(type(child:Describe()), "string")
		child:Pause()
		child:Resume()
		child:SetMaxCatchUp(3)
		t.eq(child:Detach(parent), false)
		d:Reset()
		d:Restart()
		t.eq(d:GetState(), "Stopped")
		t.eq(fired, 0)
		parent:Destroy()
	end)

	t.test("Attach: parent Destroy destroys the child, Clear clears the child", function()
		local parent = _named("P")
		local child = _named("C")
		local grandchild = _named("G")
		parent:Attach(child)
		child:Attach(grandchild)
		local hp = parent:Delay(_noop, F64)
		local hc = child:Delay(_noop, F64)
		local hg = grandchild:Recur(_noop, F64)

		local n = parent:Clear()
		t.eq(n >= 1, true, "at least the parent's own handle counted")
		t.eq(hp:GetState(), "Stopped")
		t.eq(hc:GetState(), "Stopped", "Clear cascades to the child")
		t.eq(hg:GetState(), "Stopped", "and to the grandchild")
		t.eq(child:GetClocks(), 0)
		t.eq(grandchild:GetClocks(), 0)
		t.eq(child:IsDestroyed(), false, "Clear does not destroy")
		t.eq(grandchild:IsDestroyed(), false)
		t.eq(parent:GetStats().Children, 1, "still attached after Clear")
		t.eq(child:GetStats().Children, 1)
		local again = child:Delay(_noop, F64)
		t.eq(again:GetState(), "Pending")

		parent:Destroy()
		t.eq(parent:IsDestroyed(), true)
		t.eq(child:IsDestroyed(), true, "Destroy cascades to the child")
		t.eq(grandchild:IsDestroyed(), true, "and to the grandchild")
		t.eq(again:GetState(), "Stopped")
		t.eq(parent:GetStats().Children, 0)
		t.eq(child:GetStats().Children, 0)
		t.throws(function()
			child:Update(F64)
		end, "destroyed")
	end)

	t.test("Attach refuses self, destroyed, double-attach, cycle", function()
		local p = _named("P")
		local q = _named("Q")
		local c = _named("C")
		local g = _named("G")
		local dead = _named("D")
		dead:Destroy()

		t.throws(function()
			p:Attach(p)
		end, "Veron 'P': cannot attach itself")
		t.throws(function()
			p:Attach(dead)
		end, "Veron 'P': 'D' is destroyed")
		t.throws(function()
			dead:Attach(c)
		end, "Veron 'D': destroyed")
		t.throws(function()
			p:Attach({})
		end, "Veron 'P': Attach expects a Veron, got table")
		t.throws(function()
			p:Attach(nil)
		end, "Veron 'P': Attach expects a Veron, got nil")
		t.eq(p:GetStats().Children, 0, "nothing attached by a refused call")

		p:Attach(c)
		t.throws(function()
			p:Attach(c)
		end, "Veron 'P': 'C' is already attached to 'P'")
		t.throws(function()
			q:Attach(c)
		end, "Veron 'Q': 'C' is already attached to 'P'")
		t.throws(function()
			c:Attach(p)
		end, "Veron 'C': Attach would create a cycle")
		c:Attach(g)
		t.throws(function()
			g:Attach(p)
		end, "Veron 'G': Attach would create a cycle")
		t.throws(function()
			g:Attach(c)
		end, "Veron 'G': 'C' is already attached to 'P'")

		t.eq(p:GetStats().Children, 1)
		t.eq(c:GetStats().Children, 1)
		t.eq(g:GetStats().Children, 0)
		t.eq(q:GetStats().Children, 0)
		t.eq(rawget(c, "_Parent"), p)
		t.eq(rawget(g, "_Parent"), c)
		t.eq(rawget(p, "_Parent"), false)
		local children = p:GetChildren()
		t.eq(#children, 1)
		t.eq(children[1], c)
	end)

	t.test("child Destroy detaches from its parent", function()
		local p = _named("P")
		local c = _named("C")
		local g = _named("G")
		p:Attach(c)
		c:Attach(g)
		local hp = p:Delay(_noop, F64)

		c:Destroy()
		t.eq(#p:GetChildren(), 0)
		t.eq(p:GetStats().Children, 0)
		t.eq(rawget(c, "_Parent"), false)
		t.eq(g:IsDestroyed(), true, "the child's own subtree goes with it")
		t.eq(p:IsDestroyed(), false)
		t.eq(hp:GetState(), "Pending", "the parent's handles are untouched")

		local fresh = _named("F")
		p:Attach(fresh)                                      -- the slot is free again
		t.eq(p:GetStats().Children, 1)
		p:Update(F64)
		t.eq(hp:GetState(), "Fired")
		p:Destroy()
		t.eq(fresh:IsDestroyed(), true)
	end)

	t.test("Detach stops the cascade", function()
		local p = _named("P")
		local q = _named("Q")
		local c = _named("C")
		p:Attach(c)
		local fired = 0
		local h = c:Delay(function()
			fired += 1
		end, F64)

		t.eq(p:Detach(c), true)
		t.eq(p:Detach(c), false, "second Detach is false")
		t.eq(p:Detach(_named("X")), false, "never attached")
		t.eq(p:Detach({}), false, "non-Veron")
		t.eq(p:GetStats().Children, 0)
		t.eq(rawget(c, "_Parent"), false)

		p:Clear()
		t.eq(h:GetState(), "Pending", "Clear no longer reaches the child")
		p:Destroy()
		t.eq(c:IsDestroyed(), false, "Destroy no longer reaches the child")
		t.eq(h:GetState(), "Pending")
		c:Update(F64)
		t.eq(fired, 1)

		q:Attach(c)                                          -- a detached child can be attached elsewhere
		t.eq(q:GetStats().Children, 1)
		t.eq(rawget(c, "_Parent"), q)
	end)

	t.test("Drive advances the child by period per parent fire", function()
		local p = _named("P")
		local c = _named("C")
		local fired = 0
		c:Delay(function()
			fired += 1
		end, 2 * F64)
		local pump = p:Drive(c, F64)
		t.eq(pump:IsRecurring(), true)
		t.eq(pump:GetState(), "Pending")
		t.eq(pump:GetPeriod(), F64)
		t.eq(rawget(c, "_Parent"), p, "Drive attaches")
		t.eq(p:GetStats().Children, 1)

		p:Update(F128)
		t.eq(c:Now(), 0, "the pump is not due yet")
		p:Update(F128)
		t.eq(c:Now(), F64, "one period per pump fire")
		t.eq(fired, 0)
		p:Update(F64)
		t.eq(c:Now(), 2 * F64)
		t.eq(fired, 1, "the child's own timer fires on the child's clock")
		p:Update(1)                                          -- uncapped by default: 64 pumps
		t.eq(c:Now(), 2 * F64 + 1)
		t.eq(c:GetStats().Updates, 66)
		t.eq(p:GetStats().Dropped, 0)
		t.eq(p:GetStats().ValveHits, 0)
	end)

	t.test("Drive under a hitch — uncapped keeps child time, capped drops it", function()
		local p1 = _named("P1")
		local c1 = _named("C1")
		local p2 = _named("P2")
		local c2 = _named("C2")
		local fired1, fired2 = 0, 0
		c1:Delay(function()
			fired1 += 1
		end, 1)
		c2:Delay(function()
			fired2 += 1
		end, 1)
		p1:Drive(c1, F64)                                    -- default: uncapped (lossless)
		p2:Drive(c2, F64, false)                             -- capped at the instance MaxCatchUp (8)

		p1:Update(1)
		p2:Update(1)
		t.eq(c1:Now(), 1, "every owed period reached the uncapped child")
		t.eq(fired1, 1)
		t.eq(p1:GetStats().Dropped, 0)
		t.eq(p1:GetStats().ValveHits, 0)
		t.eq(c2:Now(), 8 * F64, "the capped pump delivered MaxCatchUp periods")
		t.eq(fired2, 0)
		t.eq(p2:GetStats().Dropped, 56, "the rest was dropped on-grid")

		p1:Update(F64)
		p2:Update(F64)
		t.eq(c1:Now(), 1 + F64)
		t.eq(c2:Now(), 9 * F64, "the capped pump kept its grid phase")
		for _ = 1, 64 do
			p2:Update(F64)
		end
		t.eq(c2:Now(), 73 * F64)
		t.eq(fired2, 1, "child time resumes, the lost 56 periods never return")
	end)

	t.test("Drive always attaches; mutual Drive is refused as a cycle", function()
		local a = _named("A")
		local b = _named("B")
		local pump = a:Drive(b, F64)
		t.eq(pump:GetState(), "Pending")
		t.eq(rawget(b, "_Parent"), a)
		t.eq(a:GetStats().Children, 1)

		t.throws(function()
			b:Drive(a, F64)
		end, "Veron 'B': Attach would create a cycle")
		t.eq(b:GetClocks(), 0, "nothing armed on the refused side")
		t.eq(b:GetStats().Recurring, 0)
		t.eq(b:GetStats().Children, 0)
		t.eq(rawget(a, "_Parent"), false)

		t.throws(function()
			a:Drive(b, F64)
		end, "Veron 'A': 'B' is already attached to 'A'")
		t.eq(a:GetClocks(), 1, "the second pump was never armed")

		local c = _named("C")
		b:Attach(c)
		t.throws(function()
			c:Drive(a, F64)
		end, "Veron 'C': Attach would create a cycle")
		t.eq(c:GetClocks(), 0)

		t.throws(function()
			a:Drive(a, F64)
		end, "Veron 'A': Drive expects another Veron")
		t.throws(function()
			a:Drive({}, F64)
		end, "Veron 'A': Drive expects another Veron")
		t.eq(a:GetClocks(), 1)
	end)

	t.test("Drive stops itself after child Destroy without OnError noise", function()
		local errors = {}
		local p = _new({ Name = "P", OnError = function(message)
			errors[#errors + 1] = message
		end })
		local c = _named("C")
		local warns = _withWarns(function()
			local pump = p:Drive(c, F64)
			p:Update(F64)
			t.eq(c:Now(), F64)
			c:Destroy()
			t.eq(p:GetStats().Children, 0, "the child detached itself")
			t.eq(pump:GetState(), "Pending", "the pump only learns on its next fire")
			p:Update(F64)
			t.eq(pump:GetState(), "Stopped", "the pump stopped itself")
			t.eq(p:GetClocks(), 0)
			t.eq(p:GetStats().Recurring, 0)
			p:Update(1)
			t.eq(p:GetStats().Errors, 0)
			t.eq(#errors, 0)
		end)
		t.eq(#warns, 0)
	end)

	t.test("Children stat tracks Attach/Detach/Destroy without a walk", function()
		local p = _named("P")
		local c1 = _named("C1")
		local c2 = _named("C2")
		local c3 = _named("C3")
		local into = {}
		local function children()
			p:GetStats(into)
			t.eq(into.Children, rawget(p, "_ChildCount"), "the stat is the O(1) counter")
			t.eq(into.Children, #p:GetChildren(), "and matches the walk")
			return into.Children
		end
		t.eq(children(), 0)
		p:Attach(c1)
		t.eq(children(), 1)
		p:Attach(c2)
		p:Attach(c3)
		t.eq(children(), 3)
		p:Detach(c1)
		t.eq(children(), 2)
		c2:Destroy()
		t.eq(children(), 1)
		p:Drive(c1, F64)
		t.eq(children(), 2, "Drive attaches")
		p:Destroy()
		t.eq(children(), 0)
		t.eq(c1:IsDestroyed(), true)
		t.eq(c3:IsDestroyed(), true)
	end)

	t.test("GetClocks counts Pending + Paused only", function()
		local s = _new()
		t.eq(s:GetClocks(), 0)
		local a = s:Delay(_noop, F64)                        -- Pending
		local b = s:Recur(_noop, F64)                        -- Pending
		local c = s:Recur(_noop, F64)                        -- Paused
		c:Pause()
		local d = a:After(_noop, F64)                        -- Chained: not counted
		s:Delay(_noop, 0)                                    -- Pending until the first update
		local f = s:Delay(_noop, F64)                        -- Stopped
		f:Stop()
		t.eq(s:GetClocks(), 4, "a, b, c and the zero-delay one")
		t.eq(d:GetState(), "Chained")
		s:Update(0)
		t.eq(s:GetClocks(), 3)
		t.eq(s.getClocks(), 3, "dot alias")
		t.eq(s:getClocks(), 3, "colon alias")
		s:Update(F64)                                        -- a fires and arms d; b re-arms
		t.eq(a:GetState(), "Fired")
		t.eq(d:GetState(), "Pending")
		t.eq(s:GetClocks(), 3, "b, c, d")
		local stats = s:GetStats()
		t.eq(stats.Pending + stats.Paused, 3)
		t.eq(stats.Clocks, 3)
		t.eq(stats.Pending, 2)
		t.eq(stats.Paused, 1)
		t.eq(stats.Chained, 0)
	end)

	t.test("GetStats fields present, cumulative, and a warmed GetStats(into) allocates nothing", function()
		local s = _new()
		local stats = s:GetStats()
		for _, key in STATS_KEYS do
			t.eq(stats[key] ~= nil, true, "stat present: " .. key)
		end
		t.eq(stats.Name, "T")
		t.eq(stats.Destroyed, false)
		t.eq(stats.Now, 0)
		t.eq(stats.TimeScale, 1)
		t.eq(stats.IsPaused, false)
		t.eq(stats.Updates, 0)
		t.eq(stats.Dispatched, 0)
		t.eq(stats.Errors, 0)
		t.eq(stats.Children, 0)

		s:Delay(_noop, F64)
		s:Recur(_noop, F64)
		local p = s:Recur(_noop, F64)
		p:Pause()
		local a = s:Delay(_noop, F64)
		a:After(_noop, 1)
		s:Update(F64)                                        -- three fire; the child arms at 65/64
		s:Update(F64)                                        -- the recurring fires again
		stats = s:GetStats()
		t.eq(stats.Updates, 2)
		t.eq(stats.Dispatched, 4, "cumulative")
		t.eq(stats.LastDispatched, 1)
		t.eq(stats.LastDt, F64)
		t.eq(stats.Now, 2 * F64)
		t.eq(stats.Pending, 2)
		t.eq(stats.Paused, 1)
		t.eq(stats.Chained, 0)
		t.eq(stats.Recurring, 2)
		t.eq(stats.HeapSize, 2)
		t.eq(stats.Clocks, 3)
		s:Update(F64)
		stats = s:GetStats()
		t.eq(stats.Updates, 3)
		t.eq(stats.Dispatched, 5, "still cumulative")

		local into = {}
		t.eq(s:GetStats(into), into, "fills and returns the given table")
		t.eq(into.Dispatched, 5)

		-- allocation is measured on a RAW instance: the oracle wrapper packs its results
		local raw = Veron.new({ Name = "Raw" })
		raw:Delay(_noop, F64)
		raw:Recur(_noop, F64)
		local warm = {}
		raw:GetStats(warm)                                   -- the first fill sizes the hash part
		local before = collectgarbage("count")
		raw:GetStats(warm)
		raw.GetStats(warm)
		local after = collectgarbage("count")
		t.eq(after - before, 0, "warmed GetStats(into) allocated")
		raw:Destroy()
	end)

	t.test("repeated callback errors are rate-limited and counted", function()
		_withWarns(function(warns)
			-- same handle: at most one report per second
			local s = _new()
			s:Recur(function()
				error("tick boom")
			end, F64)
			for _ = 1, 64 do
				s:Update(F64)
			end
			local stats = s:GetStats()
			t.eq(stats.Errors, 64, "Errors is the true count")
			t.eq(stats.ErrorsSuppressed, 63)
			t.eq(#warns, 1, "one report in the first second")
			t.eq(warns[1]:find("[Veron T] event #1: ", 1, true) ~= nil, true, warns[1])
			t.eq(warns[1]:find("tick boom", 1, true) ~= nil, true, warns[1])
			s:Update(F64)                                    -- t = 65/64: a full second since the report
			t.eq(#warns, 2)
			t.eq(warns[2]:find("(63 suppressed so far)", 1, true) ~= nil, true, warns[2])
			stats = s:GetStats()
			t.eq(stats.Errors, 65)
			t.eq(stats.ErrorsSuppressed, 63)

			-- distinct handles: at most eight reports per second
			local s2 = _named("T2")
			local start = #warns
			for k = 1, 64 do
				s2:Delay(function()
					error("one " .. k)
				end, k * F64)
			end
			for _ = 1, 64 do
				s2:Update(F64)
			end
			t.eq(s2:GetStats().Errors, 64)
			t.eq(#warns - start, 8, "eight reports over one second")
			t.eq(s2:GetStats().ErrorsSuppressed, 56)

			-- "error" policy: never suppressed, raised once per outermost pass
			local s3 = _new({ Name = "T3", OnError = "error" })
			s3:Recur(function()
				error("loud")
			end, F64)
			for _ = 1, 3 do
				t.throws(function()
					s3:Update(F64)
				end, "loud")
			end
			t.eq(s3:GetStats().Errors, 3)
			t.eq(s3:GetStats().ErrorsSuppressed, 0)
			t.eq(#warns - start, 8, "the error policy never warns")
		end)
	end)

	t.test("every diagnostic reaches a function OnError policy and never re-raises under \"error\"", function()
		_withWarns(function(warns)
			-- function policy: every diagnostic arrives as (message, handle | false), nothing is warned
			local got = {}
			local s = _new({ Valve = 100, OnError = function(message, handle)
				got[#got + 1] = { message = tostring(message), handle = handle }
			end })
			local tiny, last = _triggerDiagnostics(s)
			t.eq(#got, 4, "four diagnostics")
			t.eq(got[1].message:find("re%-entered") ~= nil, true, got[1].message)
			t.eq(got[1].handle, false)
			t.eq(got[2].message:find("backwards") ~= nil, true, got[2].message)
			t.eq(got[2].handle, false)
			t.eq(got[3].message:find("resolution") ~= nil, true, got[3].message)
			t.eq(got[3].handle, tiny)
			t.eq(tiny:GetState(), "Stopped")
			t.eq(got[4].message:find("valve") ~= nil, true, got[4].message)
			t.eq(got[4].handle, last, "the handle the valve stopped at")
			t.eq(#warns, 0, "a function policy never falls through to Warn")
			t.eq(s:GetStats().Errors, 0, "diagnostics are not callback errors")
			local stats = s:GetStats()
			t.eq(stats.Reentries, 1)
			t.eq(stats.ClampedBackwards, 1)
			t.eq(stats.ValveHits, 1)

			-- "error" policy: the same four go to Warn and nothing is raised
			local s2 = _new({ Name = "T2", Valve = 100, OnError = "error" })
			local ok, err = pcall(_triggerDiagnostics, s2)
			t.eq(ok, true, "no diagnostic re-raised: " .. tostring(err))
			t.eq(#warns, 4)
			t.eq(_countMatching(warns, "^%[Veron T2%] "), 4, table.concat(warns, "\n"))
			t.eq(_countMatching(warns, "re%-entered"), 1)
			t.eq(_countMatching(warns, "backwards"), 1)
			t.eq(_countMatching(warns, "resolution"), 1)
			t.eq(_countMatching(warns, "valve"), 1)
			t.eq(s2:GetStats().Errors, 0)
		end)
	end)

	t.test("runtime setters validate like construction and take effect", function()
		_withWarns(function()
			local s = _new()
			t.throws(function()
				s:SetValve(0)
			end, "Veron 'T': option 'Valve' expects")
			t.throws(function()
				s:SetValve(0)
			end, "got 0")
			t.throws(function()
				s:SetValve(1.5)
			end, "option 'Valve' expects")
			t.throws(function()
				s:SetValve("many")
			end, "option 'Valve' expects")
			t.throws(function()
				s:SetMaxDt(-1)
			end, "Veron 'T': option 'MaxDt' expects")
			t.throws(function()
				s:SetMaxDt(0)
			end, "option 'MaxDt' expects")
			t.throws(function()
				s:SetMaxDt(true)
			end, "option 'MaxDt' expects")
			t.throws(function()
				s:SetStrict(1)
			end, "Veron 'T': option 'Strict' expects")
			t.throws(function()
				s:SetOnError("loud")
			end, "Veron 'T': option 'OnError' expects")
			t.throws(function()
				s:SetMaxCatchUp(1.5)
			end, "Veron 'T': option 'MaxCatchUp' expects an integer >= 1, got 1.5")
			t.throws(function()
				s:SetMaxCatchUp(0)
			end, "option 'MaxCatchUp' expects")
			-- state untouched by every refused call
			t.eq(rawget(s, "_Valve"), 1000)
			t.eq(rawget(s, "_MaxDt"), false)
			t.eq(rawget(s, "_Strict"), false)
			t.eq(rawget(s, "_OnError"), "warn")
			t.eq(s:GetMaxCatchUp(), 8)
			t.eq(rawget(s, "_MaxCatchUp"), 8)

			-- MaxDt
			s:SetMaxDt(0.25)
			s:Update(1)
			t.eq(s:Now(), 0.25, "clamped")
			t.eq(s:GetStats().ClampedDt, 1)
			t.eq(s:GetStats().LastDt, 0.25)
			s:SetMaxDt(false)
			s:Update(1)
			t.eq(s:Now(), 1.25, "clamp disabled")
			t.eq(s:GetStats().ClampedDt, 1)

			-- Strict
			s:SetStrict(true)
			t.throws(function()
				s:Stop({})
			end, "Veron 'T': expected a VeronEvent, got table")
			t.throws(function()
				s:Stop(5)
			end, "expected a VeronEvent, got number")
			s:SetStrict(false)
			t.eq(s:Stop({}), false)

			-- MaxCatchUp: inheriting handles follow from the next pass
			s:SetMaxCatchUp(2)
			t.eq(s:GetMaxCatchUp(), 2)
			local n = 0
			local r = s:Recur(function()
				n += 1
			end, F64)
			s:Update(1)
			t.eq(n, 2, "the new cap applied")
			r:Stop()

			-- Valve: a zero-delay chain trips at the new size
			s:SetValve(5)
			local m = 0
			local function chain()
				m += 1
				if m < 50 then
					s:Delay(chain, 0)
				end
			end
			s:Delay(chain, 0)
			s:Update(0)
			t.eq(s:GetStats().ValveHits, 1)
			t.eq(m, 6, "the first dispatch is not a nested arm, then five are")
			s:Clear()

			-- OnError: a function receives (message, handle); "error" re-raises; "warn" warns
			local got
			s:SetOnError(function(message, handle)
				got = { message = tostring(message), handle = handle }
			end)
			local bad = s:Delay(function()
				error("nope")
			end, 0)
			s:Update(0)
			t.eq(got.handle, bad)
			t.eq(got.message:find("nope", 1, true) ~= nil, true, got.message)
			s:SetOnError("error")
			s:Delay(function()
				error("raised")
			end, 0)
			t.throws(function()
				s:Update(0)
			end, "raised")
			s:SetOnError("warn")
			t.eq(rawget(s, "_OnError"), "warn")
		end)
	end)

	t.test("Validate reports a deliberately corrupted heap", function()
		-- raw instances: a wrapped call would raise from the oracle before Validate could report
		local function fresh()
			local s = Veron.new({ Name = "Raw" })
			local a = s:Delay(_noop, F64)
			local b = s:Delay(_noop, 2 * F64)
			local c = s:Delay(_noop, 3 * F64)
			return s, a, b, c
		end
		local function expectFalse(s, label)
			local ok, valid, reason = pcall(s.Validate, s)
			t.eq(ok, true, label .. ": Validate never raises")
			t.eq(valid, false, label .. ": reported")
			t.eq(type(reason), "string", label .. ": reason is a string")
			t.eq(#reason > 0, true, label .. ": reason is not empty")
		end

		local s = fresh()
		t.eq(s:Validate(), true, "healthy")

		local a
		s = fresh()
		s._Due[1] = 1                                        -- root above its children
		expectFalse(s, "heap property")

		s = fresh()
		s._N = 2                                             -- arrays longer than _N
		expectFalse(s, "_N vs arrays")

		s, a = fresh()
		a._HeapIndex = 3                                     -- ownership: _Item[_HeapIndex] ~= h
		expectFalse(s, "_HeapIndex")

		s, a = fresh()
		a._State = 5                                         -- a heap slot holding a terminal state
		expectFalse(s, "terminal state in the heap")

		-- a Stopped child stays in its live parent's _Chained list: the one place a
		-- terminal handle is still reachable by the O(n) walk
		s, a = fresh()
		local child = a:After(_noop, F64)
		child:Stop()
		child._HeapIndex = 1                                 -- terminal handle with a heap index
		expectFalse(s, "terminal _HeapIndex")

		s, a = fresh()
		child = a:After(_noop, F64)
		child:Stop()
		child._Fn = function() end                           -- Stopped handle without the NOOP
		expectFalse(s, "Stopped _Fn")

		s, a = fresh()
		a:Pause()
		s._PausedCount = 0                                   -- paused count off by one
		expectFalse(s, "_PausedCount")

		s = fresh()
		s._Due[2] = 0 / 0                                    -- NaN due
		expectFalse(s, "NaN due")

		s = fresh()
		s._RecurCount = 5
		expectFalse(s, "_RecurCount")

		s, a = fresh()
		a._Flags = 4                                         -- STOP_ON_FIRE on a one-shot
		expectFalse(s, "_Flags on a one-shot")

		s = fresh()
		s._Base = 1                                          -- base set while idle
		expectFalse(s, "_Base while idle")
	end)

	t.test("handle ids ascend from 1 and are never reused", function()
		local s = _new()
		local ids = {}
		local function push(h)
			ids[#ids + 1] = h:GetId()
			return h
		end
		local h1 = push(s:Delay(_noop, F64))
		t.eq(h1.Id, 1)
		t.eq(h1:GetId(), 1)
		push(s:Recur(_noop, F64))
		h1:Stop()
		local h3 = push(s:Delay(_noop, F64))
		t.eq(h3.Id, 3, "a stopped handle's Id is never reused")
		push(h3:After(_noop, F64))                           -- chained child: 4
		push(h1:After(_noop, F64))                           -- born-Stopped child still takes one: 5
		push(s:Drive(_named("C"), F64))                      -- the pump: 6
		local f = push(s:Delay(_noop, 0))                    -- 7
		s:Update(0)
		t.eq(f:GetState(), "Fired")
		f:Restart()                                          -- the Fired re-arm takes the next fresh Id
		push(f)
		t.eq(f:GetId(), 8)
		t.eq(f.Id, 8)
		t.eq(f:Describe():find("#8", 1, true) ~= nil, true, f:Describe())
		local h9 = push(s:Delay(_noop, F64))
		t.eq(h9.Id, 9)
		for index = 2, #ids do
			t.eq(ids[index] > ids[index - 1], true, ("ids[%d] = %d after %d"):format(index, ids[index], ids[index - 1]))
		end
		s:Clear()
		t.eq(s:Delay(_noop, F64):GetId(), 10, "Clear does not reset the sequence")
		t.eq(_named("U"):Delay(_noop, F64):GetId(), 1, "per instance")
	end)

	t.test("reset-after-touched, recur-till-touched and recur-switch patterns", function()
		-- (a) reset-after-touched: Reset on every touch, Restart once Fired, Stop on destroy
		local s = _new()
		local firedAt = {}
		local h = s:Delay(function()
			firedAt[#firedAt + 1] = s:Now()
		end, 4 * F64)
		s:Update(F64)
		h:Reset()                                            -- touch at 1/64 → due 5/64
		s:Update(F64)
		h:Reset()                                            -- touch at 2/64 → due 6/64
		s:Update(3 * F64)                                    -- now 5/64: the original due has passed
		t.eq(#firedAt, 0, "every touch restarted the full window")
		s:Update(F64)
		t.eq(firedAt[1], 6 * F64)
		t.eq(h:GetState(), "Fired")
		h:Reset()
		t.eq(h:GetState(), "Fired", "Reset never re-arms a Fired handle")
		h:Restart()                                          -- the same window again, from now
		t.eq(h:GetState(), "Pending")
		t.eq(h:GetRemaining(), 4 * F64)
		s:Update(4 * F64)
		t.eq(firedAt[2], 10 * F64)
		h:Stop()                                             -- on destroy: final
		h:Restart()
		t.eq(h:GetState(), "Stopped")
		s:Update(1)
		t.eq(#firedAt, 2)

		-- (b) recur-till-touched: Pause on touch; Resume runs on, Restart starts a full period
		local s2 = _named("T2")
		local n = 0
		local r = s2:Recur(function()
			n += 1
		end, 4 * F64)
		for _ = 1, 9 do
			s2:Update(F64)                                   -- fires at 4/64 and 8/64; now 9/64
		end
		t.eq(n, 2)
		r:Pause()                                            -- touch: remaining 12/64 - 9/64
		t.eq(r:IsPaused(), true)
		t.eq(r:GetRemaining(), 3 * F64)
		s2:Update(1)
		t.eq(n, 2, "a paused recurring accumulates nothing")
		r:Resume()                                           -- runs on from the frozen remaining
		s2:Update(2 * F64)
		t.eq(n, 2)
		s2:Update(F64)
		t.eq(n, 3)
		r:Pause()
		s2:Update(F64)
		r:Restart()                                          -- from Paused: a fresh full period, running
		t.eq(r:IsPaused(), false)
		t.eq(r:GetState(), "Pending")
		t.eq(r:GetRemaining(), 4 * F64)
		s2:Update(4 * F64)
		t.eq(n, 4)
		r:Pause()
		r:Reset()                                            -- Reset alone only refills the frozen remaining
		t.eq(r:IsPaused(), true)
		t.eq(r:GetRemaining(), 4 * F64)
		s2:Update(1)
		t.eq(n, 4)

		-- (c) recur switch: Toggle on every touch
		local s3 = _named("T3")
		local m = 0
		local sw = s3:Recur(function()
			m += 1
		end, 4 * F64)
		sw:Toggle()                                          -- touch: off
		t.eq(sw:IsPaused(), true)
		s3:Update(1)
		t.eq(m, 0)
		sw:Toggle()                                          -- touch: on
		t.eq(sw:IsPaused(), false)
		t.eq(sw:GetRemaining(), 4 * F64)
		s3:Update(4 * F64)
		t.eq(m, 1)
		s3:Update(4 * F64)
		t.eq(m, 2)
		sw:Toggle()
		s3:Update(1)
		t.eq(m, 2)
		sw:Toggle()
		s3:Update(4 * F64)
		t.eq(m, 3)
		t.eq(s3:GetClocks(), 1)
	end)
end

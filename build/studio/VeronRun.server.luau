--!nonstrict
--[[
	VeronRun — a Roblox Play-mode behavioral battery for the REAL Veron modules,
	synced into the place by Rojo (veron-studio.project.json). This runs the
	scheduler under the true Roblox Luau VM with the real require branches
	(Env.IsRoblox == true) — the paths the
	Lune suite cannot exercise. It PRINTS its results (a test runner is the
	deliberate exception to "execute_luau returns"): each line is tagged
	[VERONTEST]; the final line is [VERONTEST] SUMMARY pass=P fail=F.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local pass, fail = 0, 0
local function check(name, ok, detail)
	if ok then
		pass += 1
		print("[VERONTEST] PASS " .. name)
	else
		fail += 1
		warn("[VERONTEST] FAIL " .. name .. " :: " .. tostring(detail))
	end
end
local function near(a, b, tol)
	return type(a) == "number" and math.abs(a - b) <= (tol or 1e-6)
end

local okAll, fatal = pcall(function()
	local VeronMod = ReplicatedStorage:WaitForChild("Veron", 10)
	check("module tree synced by Rojo", VeronMod ~= nil, "ReplicatedStorage.Veron missing")
	local Veron = require(VeronMod)
	check("Veron requires under the real Roblox VM", type(Veron) == "table")

	-- Env took the ROBLOX branch (typeof(script) == "Instance").
	local Env = require(VeronMod:WaitForChild("Env"))
	check("Env.IsRoblox is true in Studio", Env.IsRoblox == true, tostring(Env.IsRoblox))

	local function newV(onError)
		return Veron.new({ Name = "T", OnError = onError or function() end })
	end

	-- Plain module, no BaseClass: a handle is a table stamped with the
	-- VeronEvent metatable, and the scheduler is stamped with Veron.
	do
		local VeronEvent = require(VeronMod:WaitForChild("VeronEvent"))
		local s = newV()
		local h = s.Delay(function() end, 1)
		check("handle is a plain VeronEvent instance", getmetatable(h) == VeronEvent
			and h.type == "VeronEvent" and h:isInstanceOf(VeronEvent), tostring(getmetatable(h)))
		check("scheduler is a plain Veron instance", getmetatable(s) == Veron
			and s.type == "Veron" and s:isInstanceOf(Veron), tostring(s.type))
	end

	-- 1. construct + clock origin
	do
		local s = newV()
		check("Now() starts at 0", s.Now() == 0, s.Now())
		check("GetClocks() starts at 0", s.GetClocks() == 0, s.GetClocks())
	end

	-- 2. Delay fires at its time, not before
	do
		local s = newV()
		local fired = 0
		s.Delay(function() fired += 1 end, 1)
		s.Update(0.6)
		check("Delay does not fire early", fired == 0, fired)
		s.Update(0.4)
		check("Delay fires at its due time", fired == 1, fired)
		s.Update(5)
		check("one-shot fires exactly once", fired == 1, fired)
	end

	-- 3. Recur fires each period
	do
		local s = newV()
		local n = 0
		s.Recur(function() n += 1 end, 0.25)
		s.Update(1)
		check("Recur fires once per period", n == 4, n)
	end

	-- 4. dot AND colon entry points both work
	do
		local s = newV()
		local a, b = 0, 0
		s.Delay(function() a += 1 end, 1)   -- dot
		s:Delay(function() b += 1 end, 1)   -- colon
		s.Update(1)
		check("dot-call Delay fires", a == 1, a)
		check("colon-call Delay fires", b == 1, b)
	end

	-- 5. legacy lowercase aliases are the same behavior
	do
		local s = newV()
		check("s.delay == s.Delay", s.delay == s.Delay)
		check("s.remove == s.Stop", s.remove == s.Stop)
		check("s.update == s.Update", s.update == s.Update)
		local fired = 0
		local h = s.delay(function() fired += 1 end, 1)
		s.remove(h)
		s.update(2)
		check("legacy remove cancels a legacy delay", fired == 0, fired)
	end

	-- 6. Stop cancels
	do
		local s = newV()
		local fired = 0
		local h = s.Delay(function() fired += 1 end, 1)
		h:Stop()
		s.Update(2)
		check("handle:Stop cancels the timer", fired == 0, fired)
		check("stopped handle state is Stopped", h:GetState() == "Stopped", h:GetState())
	end

	-- 7. Reset re-arms a one-shot (reset-after-touched pattern)
	do
		local s = newV()
		local fired = 0
		local h = s.Delay(function() fired += 1 end, 1)
		s.Update(0.6)
		h:Reset()
		s.Update(0.9)
		check("Reset re-armed: no fire yet", fired == 0, fired)
		s.Update(0.2)
		check("Reset re-armed: fires after full period", fired == 1, fired)
	end

	-- 8. Adjust is ratio-preserving
	do
		local s = newV()
		local fired = 0
		local h = s.Delay(function() fired += 1 end, 10)
		s.Update(5)            -- half consumed
		h:Adjust(20)           -- keep consumed fraction 0.5 over new total 20 -> remaining 10
		s.Update(9)
		check("Adjust ratio: not yet", fired == 0, fired)
		s.Update(2)            -- now 16 >= due 15
		check("Adjust ratio-preserving fire", fired == 1, fired)
	end

	-- 9. Toggle flips paused/running (recur switch)
	do
		local s = newV()
		local n = 0
		local h = s.Recur(function() n += 1 end, 1)
		h:Toggle()
		check("Toggle -> paused", h:IsPaused() == true)
		s.Update(3)
		check("paused recur does not fire", n == 0, n)
		h:Toggle()
		check("Toggle -> running", h:IsPaused() == false)
		s.Update(1)
		check("resumed recur fires", n == 1, n)
	end

	-- 10. Restart re-arms a Fired one-shot
	do
		local s = newV()
		local fired = 0
		local h = s.Delay(function() fired += 1 end, 1)
		s.Update(1)
		check("fired one-shot is Fired", h:GetState() == "Fired", h:GetState())
		h:Restart()
		s.Update(1)
		check("Restart re-armed the Fired handle", fired == 2, fired)
	end

	-- 11. Stop on a Fired handle finalizes; Restart then is a no-op
	do
		local s = newV()
		local fired = 0
		local h = s.Delay(function() fired += 1 end, 1)
		s.Update(1)
		h:Stop()
		check("Stop on Fired -> Stopped", h:GetState() == "Stopped", h:GetState())
		h:Restart()
		s.Update(2)
		check("Restart after Stop is a no-op", fired == 1, fired)
	end

	-- 12. Complete deferred vs CompleteNow synchronous
	do
		local s = newV()
		local order = {}
		local h = s.Delay(function() table.insert(order, "cb") end, 10)
		s.Complete(h)
		check("Complete is deferred (callback not run yet)", #order == 0, #order)
		s.Update(0)
		check("Complete runs on the next update", order[1] == "cb", order[1])

		local s2 = newV()
		local ran = false
		local h2 = s2.Delay(function() ran = true end, 10)
		s2.CompleteNow(h2)
		check("CompleteNow runs synchronously", ran == true)
	end

	-- 13. Catch-up capped at 8 by default; remainder dropped on-grid
	do
		local s = newV()
		local n = 0
		s.Recur(function() n += 1 end, 0.01)
		s.Update(1)            -- ~100 owed
		local stats = s.GetStats()
		check("default catch-up caps the burst (<= 8)", n <= 8 and n >= 1, n)
		check("capped remainder is counted as Dropped", stats.Dropped and stats.Dropped > 0, stats.Dropped)
	end

	-- 14. Recur uncapped loses nothing (dyadic period: 1/64 is exact in binary,
	-- so a full second is exactly 64 fires with no float-boundary straggler)
	do
		local s = newV()
		local n = 0
		s.Recur(function() n += 1 end, 1 / 64, true)   -- uncapped, dyadic
		s.Update(1)
		local stats = s.GetStats()
		check("uncapped catch-up delivers every owed fire", n == 64, n)
		check("uncapped drops nothing", stats.Dropped == 0, stats.Dropped)
	end

	-- 15. Re-entrancy: Update from inside a callback is bounded, never hangs
	do
		local s = newV()
		local depth = 0
		s.Delay(function()
			depth += 1
			s.Update(0)   -- nested pass
		end, 1)
		local ok = pcall(function() s.Update(1) end)
		check("nested Update from a callback does not error/hang", ok == true)
	end

	-- 16. A throwing callback is isolated; co-due siblings still fire
	do
		local s = newV()
		local good = 0
		s.Delay(function() error("boom") end, 1)
		s.Delay(function() good += 1 end, 1)
		s.Update(1)
		local stats = s.GetStats()
		check("throwing callback does not abort the pass", good == 1, good)
		check("callback error is counted", stats.Errors and stats.Errors >= 1, stats.Errors)
	end

	-- 17. After arms a child; 18. parent throw still arms the child
	do
		local s = newV()
		local childFired = 0
		local h = s.Delay(function() error("parent boom") end, 1)
		h:After(function() childFired += 1 end, 0.5)
		s.Update(1)             -- parent fires (throws), child armed from ideal due
		check("child armed despite parent throw: not yet", childFired == 0, childFired)
		s.Update(0.5)
		check("chained child fires after parent", childFired == 1, childFired)
	end

	-- 19. NaN / inf delays rejected at creation
	do
		local s = newV()
		local okNan = pcall(function() s.Delay(function() end, 0 / 0) end)
		local okInf = pcall(function() s.Delay(function() end, math.huge) end)
		check("NaN delay rejected", okNan == false)
		check("inf delay rejected", okInf == false)
	end

	-- 20. Heap fires in due order regardless of insertion order
	do
		local s = newV()
		local seq = {}
		for _, t in ipairs({ 5, 4, 3, 2, 1 }) do
			s.Delay(function() table.insert(seq, t) end, t)
		end
		s.Update(5)
		check("timers fire in due order", table.concat(seq, ",") == "1,2,3,4,5", table.concat(seq, ","))
	end

	-- 21. Validate() is clean after churn
	do
		local s = newV()
		local hs = {}
		for i = 1, 200 do
			hs[i] = s.Delay(function() end, (i % 7) + 0.5)
		end
		for i = 1, 200, 2 do hs[i]:Stop() end
		s.Update(3)
		local ok = pcall(function() return s.Validate() end)
		check("Validate() is clean after churn", ok == true)
	end

	-- 22. GetClocks counts pending + paused
	do
		local s = newV()
		local a = s.Delay(function() end, 1)
		local b = s.Recur(function() end, 1)
		b:Pause()
		check("GetClocks counts pending + paused", s.GetClocks() == 2, s.GetClocks())
	end

	-- 23. Foreign handle is rejected
	do
		local s1 = newV()
		local s2 = newV()
		local h2 = s2.Delay(function() end, 1)
		local ok = pcall(function() s1.Stop(h2) end)
		check("foreign handle rejected by another Veron", ok == false)
	end

	-- 24. GetState transitions
	do
		local s = newV()
		local h = s.Delay(function() end, 1)
		check("new one-shot is Pending", h:GetState() == "Pending", h:GetState())
		s.Update(1)
		check("after fire is Fired", h:GetState() == "Fired", h:GetState())
	end

	----------------------------------------------------------------
	-- Mini performance probe (interpreted; --!native compiles under
	-- the Script Profiler, not measured here).
	----------------------------------------------------------------
	do
		local s = newV()
		local N = 10000
		local t0 = os.clock()
		for i = 1, N do s.Delay(function() end, (i % 997) + 1) end
		local armMs = (os.clock() - t0) * 1000
		print(string.format("[VERONTEST] BENCH arm %d timers: %.2f ms (%.0f ns/op)", N, armMs, armMs * 1e6 / N))

		local before = gcinfo()
		local t1 = os.clock()
		for _ = 1, 200 do s.Update(0) end
		local idleMs = (os.clock() - t1) * 1000
		local gcDelta = gcinfo() - before
		print(string.format("[VERONTEST] BENCH 200 idle updates (%d armed): %.3f ms; gc delta %d KB", N, idleMs, gcDelta))

		local s2 = newV()
		for i = 1, N do s2.Delay(function() end, 1) end
		local t2 = os.clock()
		s2.Update(1)   -- fire storm
		local fireMs = (os.clock() - t2) * 1000
		print(string.format("[VERONTEST] BENCH fire storm %d in one update: %.2f ms (%.0f ns/dispatch)", N, fireMs, fireMs * 1e6 / N))
	end
end)

if not okAll then
	warn("[VERONTEST] FATAL " .. tostring(fatal))
end
print(string.format("[VERONTEST] SUMMARY pass=%d fail=%d", pass, fail))

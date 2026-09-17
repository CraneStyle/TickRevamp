--!nonstrict
--[[
	ComparePerf — a head-to-head performance battery: the new Veron scheduler vs
	the legacy rxi-derived Tick (reference/lune/Tick.luau), driven through the
	SAME workloads under the real Roblox VM. Prints [VERONCMP] rows:
	  Veron <ms> | Tick <ms> | Tick/Veron <ratio>
	Legacy is an array rescanned every update (O(n)/frame) with linear-scan
	handle removal (O(n)); Veron is an indexed binary min-heap (O(log n),
	O(1) idle). Same N, same delays, fresh instance per phase both sides.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local function noop() end

local function bench(fn)
	local g0 = gcinfo()
	local t0 = os.clock()
	fn()
	return (os.clock() - t0) * 1000, gcinfo() - g0
end

local function row(name, vMs, lMs, extra)
	local ratio = (vMs > 0) and (lMs / vMs) or 0
	print(string.format(
		"[VERONCMP] %-24s Veron %9.3f ms | Tick %9.3f ms | Tick/Veron %7.1fx  %s",
		name, vMs, lMs, ratio, extra or ""
	))
end

local okAll, fatal = pcall(function()
	local Veron = require(ReplicatedStorage:WaitForChild("Veron", 10))
	local Legacy = require(ReplicatedStorage:WaitForChild("LegacyTick", 10))
	print("[VERONCMP] ===== Veron vs legacy Tick, real Roblox VM (interpreted Play) =====")

	local N = 10000

	-- 1. Arm N one-shot timers (allocation + insert)
	do
		local v = Veron.new({ Name = "V", OnError = noop })
		local vMs, vGc = bench(function()
			for i = 1, N do v.Delay(noop, (i % 997) + 1) end
		end)
		local g = Legacy.group()
		local lMs, lGc = bench(function()
			for i = 1, N do g:delay(noop, (i % 997) + 1) end
		end)
		row(("arm %d timers"):format(N), vMs, lMs, ("| gc  V %d KB  Tick %d KB"):format(vGc, lGc))
	end

	-- 2. Idle updates with N armed — the O(1) fast path vs the O(n) rescan
	do
		local M = 200
		local v = Veron.new({ Name = "V", OnError = noop })
		for i = 1, N do v.Delay(noop, (i % 997) + 2) end
		local vMs, vGc = bench(function()
			for _ = 1, M do v.Update(0) end
		end)
		local g = Legacy.group()
		for i = 1, N do g:delay(noop, (i % 997) + 2) end
		local lMs, lGc = bench(function()
			for _ = 1, M do g:update(0) end
		end)
		row(("idle %dx, %d armed"):format(M, N), vMs, lMs, ("| gc  V %d KB  Tick %d KB"):format(vGc, lGc))
	end

	-- 3. Fire storm — N timers all due in one update
	do
		local vc, lc = 0, 0
		local v = Veron.new({ Name = "V", OnError = noop })
		for _ = 1, N do v.Delay(function() vc += 1 end, 1) end
		local vMs = bench(function() v.Update(1) end)
		local g = Legacy.group()
		for _ = 1, N do g:delay(function() lc += 1 end, 1) end
		local lMs = bench(function() g:update(1) end)
		row(("fire storm %d"):format(N), vMs, lMs, ("| fired V %d  Tick %d"):format(vc, lc))
	end

	-- 4. Recurring — N timers over M updates
	do
		local M, p = 100, 1
		local vc, lc = 0, 0
		local v = Veron.new({ Name = "V", OnError = noop })
		for _ = 1, N do v.Recur(function() vc += 1 end, p, true) end
		local vMs, vGc = bench(function()
			for _ = 1, M do v.Update(p) end
		end)
		local g = Legacy.group()
		for _ = 1, N do g:recur(function() lc += 1 end, p) end
		local lMs, lGc = bench(function()
			for _ = 1, M do g:update(p) end
		end)
		row(("recur %dx %d updates"):format(N, M), vMs, lMs,
			("| fires V %d Tick %d | gc V %d Tick %d KB"):format(vc, lc, vGc, lGc))
	end

	-- 5. Handle stop — O(log n) re-key vs O(n) linear find (smaller N: legacy is O(n) each)
	do
		local SN = 3000
		local v = Veron.new({ Name = "V", OnError = noop })
		local vh = table.create(SN)
		for i = 1, SN do vh[i] = v.Delay(noop, (i % 997) + 1) end
		local vMs = bench(function()
			for i = 1, SN do vh[i]:Stop() end
		end)
		local g = Legacy.group()
		local lh = table.create(SN)
		for i = 1, SN do lh[i] = g:delay(noop, (i % 997) + 1) end
		local lMs = bench(function()
			for i = 1, SN do lh[i]:stop() end
		end)
		row(("handle-stop %d"):format(SN), vMs, lMs)
	end

	-- 6. Mixed churn — arm 50 / stop 20 / update, over M frames
	do
		local M = 300
		local v = Veron.new({ Name = "V", OnError = noop })
		local vlive = {}
		local vMs, vGc = bench(function()
			for _ = 1, M do
				for _ = 1, 50 do vlive[#vlive + 1] = v.Delay(noop, 5) end
				for _ = 1, 20 do
					local h = table.remove(vlive, 1)
					if h then h:Stop() end
				end
				v.Update(1 / 60)
			end
		end)
		local g = Legacy.group()
		local llive = {}
		local lMs, lGc = bench(function()
			for _ = 1, M do
				for _ = 1, 50 do llive[#llive + 1] = g:delay(noop, 5) end
				for _ = 1, 20 do
					local h = table.remove(llive, 1)
					if h then h:stop() end
				end
				g:update(1 / 60)
			end
		end)
		row(("mixed churn %d frames"):format(M), vMs, lMs, ("| gc V %d Tick %d KB"):format(vGc, lGc))
	end

	-- 7. Recurring with VARIED periods at frame cadence — the realistic case.
	-- Most timers are NOT due on a given frame, so Veron's heap skips them while
	-- legacy still rescans all N every frame. (Phase 4 above is the opposite
	-- extreme: every timer due every update, the heap's worst case.)
	do
		local M, dt = 600, 1 / 60           -- 10 s of frames
		local vc, lc = 0, 0
		local v = Veron.new({ Name = "V", OnError = noop })
		for i = 1, N do v.Recur(function() vc += 1 end, 0.1 + (i % 100) * 0.1, true) end
		local vMs = bench(function()
			for _ = 1, M do v.Update(dt) end
		end)
		local g = Legacy.group()
		for i = 1, N do g:recur(function() lc += 1 end, 0.1 + (i % 100) * 0.1) end
		local lMs = bench(function()
			for _ = 1, M do g:update(dt) end
		end)
		row(("recur varied %dx%d fr"):format(N, M), vMs, lMs, ("| fires V %d Tick %d"):format(vc, lc))
	end

	print("[VERONCMP] ===== DONE =====")
end)

if not okAll then
	warn("[VERONCMP] FATAL " .. tostring(fatal))
end

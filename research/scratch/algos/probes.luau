--!nonstrict
local clock = os.clock
local N = 1000000
local noop = function() end

-- 1. direct call vs pcall vs xpcall(fn, debug.traceback)
do
	local t0 = clock(); for i = 1, N do noop() end; local direct = clock() - t0
	t0 = clock(); for i = 1, N do pcall(noop) end; local pc = clock() - t0
	t0 = clock(); for i = 1, N do xpcall(noop, debug.traceback) end; local xpc = clock() - t0
	print(("call: direct %.0f ns  pcall %.0f ns  xpcall %.0f ns"):format(direct * 1e9 / N, pc * 1e9 / N, xpc * 1e9 / N))
end

-- 2. state transition: string concat + table lookup (prior Handle.transition) vs numeric compare
do
	local T = { ["Pending->Fired"] = true }
	local st = "Pending"
	local t0 = clock()
	local ok = 0
	for i = 1, N do
		local key = st .. "->" .. "Fired"
		if T[key] then ok += 1 end
	end
	local concat = clock() - t0
	local PENDING, FIRED = 1, 2
	local s = PENDING
	t0 = clock()
	for i = 1, N do
		if s == PENDING then ok += 1 end
	end
	local num = clock() - t0
	print(("transition: concat+lookup %.0f ns  numeric compare %.0f ns"):format(concat * 1e9 / N, num * 1e9 / N))
end

-- 3. method call through metatable __index table (BaseClass-style) vs local function
do
	local C = {}; C.__index = C
	function C.m(self, x) return x + 1 end
	local o = setmetatable({}, C)
	local function f(self, x) return x + 1 end
	local t0 = clock(); local acc = 0
	for i = 1, N do acc = o:m(acc) end
	local meth = clock() - t0
	t0 = clock(); acc = 0
	for i = 1, N do acc = f(o, acc) end
	local loc = clock() - t0
	print(("dispatch: metatable method %.0f ns  local function %.0f ns"):format(meth * 1e9 / N, loc * 1e9 / N))
end

-- 4. does a constructor literal with nil-valued fields pre-size the hash part? measure alloc KB
do
	local M = 20000
	local function fullLiteral()
		local c0 = collectgarbage("count")
		local keep = table.create(M)
		for i = 1, M do
			local h = { fn = noop, period = 1, recur = false, _seq = i, _hi = 0, _state = 1, _sched = keep, _remaining = nil, _chained = nil, _burst = nil }
			keep[i] = h
		end
		local c1 = collectgarbage("count")
		-- now late-assign the three nil fields
		for i = 1, M do
			local h = keep[i]
			h._remaining = 1; h._chained = keep; h._burst = 2
		end
		local c2 = collectgarbage("count")
		return (c1 - c0) * 1024 / M, (c2 - c1) * 1024 / M
	end
	local function shortLiteral()
		local c0 = collectgarbage("count")
		local keep = table.create(M)
		for i = 1, M do
			local h = { fn = noop, period = 1, recur = false, _seq = i, _hi = 0, _state = 1, _sched = keep }
			keep[i] = h
		end
		local c1 = collectgarbage("count")
		for i = 1, M do
			local h = keep[i]
			h._remaining = 1; h._chained = keep; h._burst = 2
		end
		local c2 = collectgarbage("count")
		return (c1 - c0) * 1024 / M, (c2 - c1) * 1024 / M
	end
	local a1, a2 = fullLiteral()
	local b1, b2 = shortLiteral()
	print(("handle alloc: 10-field literal (3 nil) %.0f B/handle, late-assign adds %.0f B; 7-field literal %.0f B/handle, late-assign adds %.0f B"):format(a1, a2, b1, b2))
	-- 6, 7, 8, 9 field literals
	for _, k in { 4, 6, 7, 8, 9, 12 } do
		local c0 = collectgarbage("count")
		local keep = table.create(M)
		for i = 1, M do
			local h = {}
			if k == 4 then h = { a = 1, b = 2, c = 3, d = 4 }
			elseif k == 6 then h = { a = 1, b = 2, c = 3, d = 4, e = 5, f = 6 }
			elseif k == 7 then h = { a = 1, b = 2, c = 3, d = 4, e = 5, f = 6, g = 7 }
			elseif k == 8 then h = { a = 1, b = 2, c = 3, d = 4, e = 5, f = 6, g = 7, h = 8 }
			elseif k == 9 then h = { a = 1, b = 2, c = 3, d = 4, e = 5, f = 6, g = 7, h = 8, i = 9 }
			else h = { a = 1, b = 2, c = 3, d = 4, e = 5, f = 6, g = 7, h = 8, i = 9, j = 10, k = 11, l = 12 } end
			keep[i] = h
		end
		local c1 = collectgarbage("count")
		print(("  %d-field literal: %.0f B/table"):format(k, (c1 - c0) * 1024 / M))
	end
end

-- 5. NaN / negative dt guard cost
do
	local now = 0
	local t0 = clock()
	for i = 1, N do
		local dt = 0.016
		if dt >= 0 then now += dt end
	end
	print(("dt guard (dt >= 0): %.1f ns/update"):format((clock() - t0) * 1e9 / N))
	print("NaN >= 0 is", (0/0) >= 0, "; -1 >= 0 is", -1 >= 0)
end

-- 6. float precision of an accumulated clock
do
	local function ulp(x) local e = math.frexp(x); return 2 ^ (e - 53) end
	for _, t in { 1e3, 1e5, 1e7, 1e9, 1.7e9 } do
		print(("ulp at now=%.0e s: %.2e s"):format(t, ulp(t)))
	end
	-- 1e7 s at 240Hz would be 2.4e9 adds; simulate 2.4e6 adds from 1e7 and compare with exact
	local now = 1e7
	local dt = 1 / 240
	for i = 1, 2400000 do now += dt end
	print(("drift after 2.4e6 adds of 1/240 from 1e7: %.3e s (exact 1e4)"):format(now - (1e7 + 2400000 * dt)))
end

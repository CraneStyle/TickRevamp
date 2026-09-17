-- Micro-benchmarks under Lune 0.10.5 (Luau interpreter, no --!native). Numbers are ns/op, median of 5 runs.
local N = 2_000_000
local function bench(name, f, n)
	n = n or N
	local samples = {}
	for r = 1, 5 do
		local t0 = os.clock()
		f(n)
		local t1 = os.clock()
		samples[r] = (t1 - t0) / n * 1e9
	end
	table.sort(samples)
	print(string.format("%-46s %8.1f ns/op", name, samples[3]))
end

local function noop(a) return a end
local sink = 0

bench("direct call noop(i)", function(n) for i = 1, n do sink = noop(i) end end)
bench("pcall(noop, i)", function(n) for i = 1, n do local ok, v = pcall(noop, i); sink = v end end)
local function handler(e) return e end
bench("xpcall(noop, handler, i)", function(n) for i = 1, n do local ok, v = xpcall(noop, handler, i); sink = v end end)
bench("pcall + task-style closure alloc", function(n) for i = 1, n do local ok = pcall(function() sink = i end) end end)

-- upvalue vs table field vs global
local up = 0
local tbl = { x = 0 }
bench("upvalue increment", function(n) for i = 1, n do up = up + 1 end end)
bench("table field increment (constant key)", function(n) for i = 1, n do tbl.x = tbl.x + 1 end end)
local key = "x"
bench("table field increment (dynamic key)", function(n) for i = 1, n do tbl[key] = tbl[key] + 1 end end)

-- method dispatch: direct field vs 1-hop __index vs 2-hop __index vs __index function
local Class = {}; Class.__index = Class
function Class.get(self) return self.v end
local objDirect = { v = 1, get = Class.get }
local obj1 = setmetatable({ v = 1 }, Class)
local Sub = setmetatable({}, { __index = Class }); Sub.__index = Sub
local obj2 = setmetatable({ v = 1 }, Sub)
local Sub2 = setmetatable({}, { __index = Sub }); Sub2.__index = Sub2
local obj3 = setmetatable({ v = 1 }, Sub2)
local objFn = setmetatable({ v = 1 }, { __index = function(t, k) return Class[k] end })
bench("method call: function stored on instance", function(n) for i = 1, n do sink = objDirect:get() end end)
bench("method call: 1-hop __index table", function(n) for i = 1, n do sink = obj1:get() end end)
bench("method call: 2-hop __index chain", function(n) for i = 1, n do sink = obj2:get() end end)
bench("method call: 3-hop __index chain", function(n) for i = 1, n do sink = obj3:get() end end)
bench("method call: __index function", function(n) for i = 1, n do sink = objFn:get() end end)

-- closure creation
bench("closure creation capturing mutable upvalue", function(n) for i = 1, n do local f = function() sink = i end; sink = f end end)
local c = 5
bench("closure creation capturing immutable upvalue", function(n) for i = 1, n do local f = function() return c end; sink = f end end)

-- table creation
local M = 200_000
bench("new table {} + 8 fields via literal", function(n) for i = 1, n do local t = { a = 1, b = 2, c = 3, d = 4, e = 5, f = 6, g = 7, h = 8 }; sink = t end end, M)
bench("new table {} + 8 fields assigned after", function(n) for i = 1, n do local t = {}; t.a = 1; t.b = 2; t.c = 3; t.d = 4; t.e = 5; t.f = 6; t.g = 7; t.h = 8; sink = t end end, M)
bench("array grow 64 pushes from {}", function(n) for i = 1, n do local t = {}; for j = 1, 64 do t[j] = j end; sink = t end end, 50_000)
bench("array grow 64 pushes from table.create(64)", function(n) for i = 1, n do local t = table.create(64); for j = 1, 64 do t[j] = j end; sink = t end end, 50_000)
local reuse = table.create(64)
bench("table.clear + 64 pushes (reuse)", function(n) for i = 1, n do table.clear(reuse); for j = 1, 64 do reuse[j] = j end end end, 50_000)

-- strings
bench("string.format('%d', i)", function(n) for i = 1, n do sink = string.format("%d", i) end end, M)
bench("tostring(i)", function(n) for i = 1, n do sink = tostring(i) end end, M)
bench("string.format('%s %.3f', s, x)", function(n) for i = 1, n do sink = string.format("%s %.3f", "timer", i * 0.5) end end, M)

-- heap ops: sift-up/down on a 10k array heap (number keys)
local function siftUp(h, i)
	while i > 1 do
		local p = i // 2
		if h[p] <= h[i] then break end
		h[p], h[i] = h[i], h[p]
		i = p
	end
end
local function siftDown(h, n, i)
	while true do
		local l, r, s = 2 * i, 2 * i + 1, i
		if l <= n and h[l] < h[s] then s = l end
		if r <= n and h[r] < h[s] then s = r end
		if s == i then return end
		h[s], h[i] = h[i], h[s]
		i = s
	end
end
local H = table.create(10_000)
for i = 1, 10_000 do H[i] = math.random() * 1000; siftUp(H, i) end
bench("heap push+pop on 10k number heap", function(n)
	local size = 10_000
	for i = 1, n do
		size += 1; H[size] = math.random() * 1000; siftUp(H, size)
		H[1] = H[size]; H[size] = nil; size -= 1; siftDown(H, size, 1)
	end
end, 200_000)
bench("os.clock() call", function(n) for i = 1, n do sink = os.clock() end end)
print("sink", type(sink))

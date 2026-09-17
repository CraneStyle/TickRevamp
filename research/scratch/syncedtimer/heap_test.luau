-- MinHeap empirical checks under Lune (no game deps in MinHeap.luau)
local MinHeap = require("../../../reference/live/MinHeap")

local function isHeap(h)
	for i = 2, h._size do
		local p = math.floor(i / 2)
		if h._priorities[p] > h._priorities[i] then return false, i end
	end
	-- no stale slots beyond size
	if h._items[h._size + 1] ~= nil or h._priorities[h._size + 1] ~= nil then return false, "stale tail" end
	return true
end

-- 1. __len
local h = MinHeap()
h:enqueue("a", 5); h:enqueue("b", 3); h:enqueue("c", 9)
print("T1 #heap =", #h, " size() =", h:size(), " __len =", getmetatable(h).__len)

-- 2. dequeue order + heap invariant on random data
math.randomseed(42)
local h2 = MinHeap()
local N = 2000
local items = {}
for i = 1, N do
	local it = { id = i }
	items[i] = it
	h2:enqueue(it, math.random(1, 500))
end
assert(isHeap(h2))
local last = -math.huge
local cnt = 0
while not h2:isEmpty() do
	local _, p = h2:dequeue()
	assert(p >= last, "dequeue order broken")
	last = p; cnt += 1
end
print("T2 dequeue order ok, popped", cnt)

-- 3. remove correctness: random removes keep invariant
local h3 = MinHeap()
local pool = {}
for i = 1, N do
	local it = { id = i }
	pool[i] = it
	h3:enqueue(it, math.random(1, 500))
end
for k = 1, 1500 do
	local idx = math.random(1, #pool)
	local it = table.remove(pool, idx)
	assert(h3:remove(it) == true)
	local ok, where = isHeap(h3)
	assert(ok, "heap broken after remove at " .. tostring(where))
end
print("T3 remove invariant ok; size", h3:size(), "expected", #pool)
print("T3b remove of absent item ->", h3:remove({}))

-- 4. update = remove+enqueue; update of absent item returns false and does NOT enqueue
local h4 = MinHeap()
local x, y = { "x" }, { "y" }
h4:enqueue(x, 10); h4:enqueue(y, 20)
print("T4 update(y,1) ->", h4:update(y, 1), " peek ->", (h4:peek())[1])
print("T4b update(absent) ->", h4:update({ "z" }, 0), " size", h4:size())

-- 5. siftdown re-sift cost from `siftedindex`: count comparisons by instrumenting priorities via proxy
-- Approximate: measure wall time for remove of the LAST-ish element in a large heap vs dequeue
local h5 = MinHeap()
local big = {}
for i = 1, 20000 do
	local it = { id = i }
	big[i] = it
	h5:enqueue(it, i) -- sorted insert => heap is a sorted array
end
local t0 = os.clock()
for i = 20000, 19001, -1 do h5:remove(big[i]) end -- remove last element 1000 times (index == size branch, but indexof walks all)
local t1 = os.clock()
for i = 1, 1000 do h5:dequeue() end
local t2 = os.clock()
print(string.format("T5 1000 remove(last) = %.3f ms   1000 dequeue = %.3f ms  (n~20000)", (t1 - t0) * 1000, (t2 - t1) * 1000))

-- 6. batchenq heapify
local h6 = MinHeap({ "a", 9, "b", 1, "c", 5, "d", 3, "e", 7, "f", 2 })
assert(isHeap(h6))
local order = {}
while not h6:isEmpty() do
	local _, p = h6:dequeue(); table.insert(order, p)
end
print("T6 batchenq order:", table.concat(order, ","))

-- 7. remove then siftdown loop: count how many root-level sifts happen (instrument siftdown by counting comparisons through __lt on priority objects is not possible with numbers). Instead: measure remove(index 2 element) in a 20000 heap.
local h7 = MinHeap()
local b7 = {}
for i = 1, 20000 do
	local it = { id = i }; b7[i] = it; h7:enqueue(it, i)
end
-- remove an item near the bottom whose replacement will bubble up far (last item has max priority, so no bubble); test middle
local t3 = os.clock()
for i = 10000, 10999 do h7:remove(b7[i]) end
local t4 = os.clock()
print(string.format("T7 1000 remove(mid) = %.3f ms", (t4 - t3) * 1000))

-- 8. Duplicate priorities & equal keys: stability irrelevant but must not break
local h8 = MinHeap()
for i = 1, 50 do h8:enqueue({ i }, 1) end
assert(isHeap(h8))
for i = 1, 25 do h8:dequeue() end
assert(isHeap(h8))
print("T8 equal priorities ok")

-- 9. peek on empty
local h9 = MinHeap()
print("T9 peek empty ->", h9:peek())
print("T9b dequeue empty ->", pcall(function() return h9:dequeue() end))

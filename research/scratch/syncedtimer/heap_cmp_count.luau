-- Count priority comparisons in MinHeap ops using table priorities with __lt.
local MinHeap = require("../../../reference/live/MinHeap")
local cmp = 0
local PMT = { __lt = function(a, b) cmp += 1; return a.v < b.v end }
local function P(v) return setmetatable({ v = v }, PMT) end

local function build(n, sorted)
	local h = MinHeap()
	local items = {}
	for i = 1, n do
		local it = { id = i }
		items[i] = it
		h:enqueue(it, P(sorted and i or math.random(1, n)))
	end
	return h, items
end

math.randomseed(7)
local N = 16383 -- full binary tree of depth 14
-- A) dequeue comparisons
local h = build(N, true)
cmp = 0
h:dequeue()
print("A dequeue on sorted n=16383: comparisons =", cmp, " (log2 n ~ 14, expect <= ~28)")

-- B) remove of an element at index ~N/2 (a leaf-ish node), sorted heap: the moved last item is the max, so siftup does nothing, siftedindex = index, siftdown loops from index down to 1 !
h = build(N, true)
local items = h._items
local target = items[math.floor(N / 2)]
cmp = 0
h:remove(target)
print("B remove(index N/2) on sorted heap: comparisons =", cmp, " (ideal O(log n) ~ 28; observed shows for-loop over `limit..1`)")

-- C) remove of element at index 2 (near root)
h = build(N, true)
target = h._items[2]
cmp = 0
h:remove(target)
print("C remove(index 2): comparisons =", cmp)

-- D) remove of last element (index == size branch)
h = build(N, true)
target = h._items[N]
cmp = 0
h:remove(target)
print("D remove(last): comparisons =", cmp, " (no sifting; cost is indexof walk of", N, "slots)")

-- E) update = remove + enqueue on random heap, element in the middle
h = build(N, false)
target = h._items[math.floor(N / 2)]
cmp = 0
h:update(target, P(0))
print("E update(mid -> 0) on random heap: comparisons =", cmp)

-- F) batchenq heapify comparisons for N random
local arr = {}
for i = 1, N do arr[#arr + 1] = { id = i }; arr[#arr + 1] = P(math.random(1, N)) end
cmp = 0
local hb = MinHeap(arr)
print("F batchenq heapify n=16383: comparisons =", cmp, " (Floyd bound ~2n =", 2 * N, ")")

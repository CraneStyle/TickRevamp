--!nonstrict
--[[
	heap_spec — the indexed binary heap of docs/DESIGN.md §3.2 (ALG §3.2
	verbatim: siftUp/siftDown/heapPush/heapPop/heapRemove/heapUpdate/heapClear
	over `_Due/_Item/_N`, ordered by (due, Id), `_HeapIndex` as the ownership
	check); §9 heap/heap_spec row — 7 tests, names verbatim. RAW: no oracle.

	The ops are reached through the test-only static table
	`Veron._Heap = { push, pop, remove, update, clear }` and driven on
	a bare `Veron.new{}` instance's arrays with hand-built handle-like tables
	`{ Id = n, _HeapIndex = 0, _State = 1 }` (the ops touch only `Id` and
	`_HeapIndex`). The invariant is re-derived here independently of
	`Validate()` (which would reject the bare tables anyway).

	Modules are required lazily so this file loads before the core exists.
]]

local Veron, Heap

local function _load()
	if Veron then
		return
	end
	Veron = require("../../../src/Veron")
	Heap = Veron._Heap
	if type(Heap) ~= "table" then
		error("Veron._Heap is not exposed (test-only static table, see BUILD-NOTES WP4)")
	end
end

local SEED = 20260916
local OWNERSHIP_MESSAGE = "Veron: handle is not scheduled on this Veron"

--[[
	Park–Miller LCG, exact in doubles; returns an integer in [0, bound).
]]
local function _rng(seed)
	local state = seed
	return function(bound)
		state = state * 48271 % 2147483647
		return state % bound
	end
end

local function _newHandle(id)
	return { Id = id, _HeapIndex = 0, _State = 1 }
end

local function _bare()
	_load()
	return Veron.new({})
end

--[[
	(due, Id) strict order: true when entry A must sit ABOVE entry B.
]]
local function _lessThan(dueA, idA, dueB, idB)
	if dueA ~= dueB then
		return dueA < dueB
	end
	return idA < idB
end

--[[
	The independent invariant walk: array lengths equal `_N`, tails cleared,
	`_Item[h._HeapIndex] == h` for every slot, heap property on (due, Id).
]]
local function _checkHeap(s, where)
	local due, item, n = s._Due, s._Item, s._N
	local label = where or "heap"
	if #due ~= n then
		error(("%s: #_Due %d ~= _N %d"):format(label, #due, n))
	end
	if #item ~= n then
		error(("%s: #_Item %d ~= _N %d"):format(label, #item, n))
	end
	if due[n + 1] ~= nil or item[n + 1] ~= nil then
		error(label .. ": tail past _N is not cleared")
	end
	for slot = 1, n do
		local h = item[slot]
		if type(h) ~= "table" then
			error(("%s: slot %d holds %s"):format(label, slot, typeof(h)))
		end
		if h._HeapIndex ~= slot then
			error(("%s: slot %d holds #%d whose _HeapIndex is %d"):format(label, slot, h.Id, h._HeapIndex))
		end
		if type(due[slot]) ~= "number" then
			error(("%s: slot %d due is %s"):format(label, slot, typeof(due[slot])))
		end
		if slot > 1 then
			local parent = slot // 2
			if _lessThan(due[slot], h.Id, due[parent], item[parent].Id) then
				error(("%s: heap property violated at slot %d (due %s #%d above parent due %s #%d)"):format(
					label, slot, tostring(due[slot]), h.Id, tostring(due[parent]), item[parent].Id))
			end
		end
	end
end

--[[
	Pops everything, asserting each pop returns the root and that the
	sequence is non-decreasing in (due, Id). Returns the popped handles.
]]
local function _drainSorted(t, s)
	local popped = {}
	local lastDue, lastId = -math.huge, -math.huge
	while s._N > 0 do
		local expectedDue, expectedHandle = s._Due[1], s._Item[1]
		local due, h = Heap.pop(s)
		t.eq(due, expectedDue, "pop returns the root due")
		t.eq(h, expectedHandle, "pop returns the root handle")
		t.eq(h._HeapIndex, 0, "popped handle leaves the heap")
		if _lessThan(due, h.Id, lastDue, lastId) then
			error(("drain out of order: (%s, #%d) after (%s, #%d)"):format(tostring(due), h.Id, tostring(lastDue), lastId))
		end
		lastDue, lastId = due, h.Id
		popped[#popped + 1] = h
	end
	t.eq(#s._Due, 0)
	t.eq(#s._Item, 0)
	return popped
end

--[[
	Pushes `dues` in order onto a bare instance; returns the instance and the
	handles keyed by their push order (Id == order).
]]
local function _build(dues)
	local s = _bare()
	local handles = {}
	for index, due in dues do
		local h = _newHandle(index)
		handles[index] = h
		Heap.push(s, h, due)
	end
	return s, handles
end

return function(t)
	t.test("push then drain is sorted by (due, Id)", function()
		-- §3.2: heap property on (due, Id); equal dues drain in Id (FIFO) order
		local s = _bare()
		local next = _rng(SEED)
		local count = 500
		for id = 1, count do
			Heap.push(s, _newHandle(id), next(16) / 64) -- many ties
			if id % 50 == 0 then
				_checkHeap(s, "after push " .. id)
			end
		end
		t.eq(s._N, count)
		_checkHeap(s, "after all pushes")
		local popped = _drainSorted(t, s)
		t.eq(#popped, count)
		t.eq(s._N, 0)
		-- ties: within one due, Ids ascend
		local seen = {}
		for _, h in popped do
			seen[h.Id] = true
		end
		for id = 1, count do
			t.eq(seen[id], true, "every handle drained once: #" .. id)
		end
	end)

	t.test("20000 random push/pop/remove/updateKey keep the invariant every 97 ops", function()
		-- F-ALG-14: the prototype's property test, on the transcribed ops
		local s = _bare()
		local next = _rng(SEED)
		local live = {} -- array of handles currently in the heap
		local slotOf = {} -- handle → index in `live`
		local nextId = 0
		local function addLive(h)
			live[#live + 1] = h
			slotOf[h] = #live
		end
		local function dropLive(h)
			local index = slotOf[h]
			local last = live[#live]
			live[index] = last
			slotOf[last] = index
			live[#live] = nil
			slotOf[h] = nil
		end
		local counts = { push = 0, pop = 0, remove = 0, update = 0 }
		for op = 1, 20000 do
			local roll = next(10)
			if roll < 4 or #live == 0 then
				nextId += 1
				local h = _newHandle(nextId)
				Heap.push(s, h, next(4096) / 64)
				addLive(h)
				counts.push += 1
			elseif roll < 6 then
				local expected = s._Item[1]
				local _, h = Heap.pop(s)
				t.eq(h, expected, "pop returns the root")
				t.eq(h._HeapIndex, 0)
				dropLive(h)
				counts.pop += 1
			elseif roll < 8 then
				local h = live[next(#live) + 1]
				t.eq(Heap.remove(s, h), true, "remove of a live handle")
				t.eq(h._HeapIndex, 0)
				dropLive(h)
				counts.remove += 1
			else
				local h = live[next(#live) + 1]
				Heap.update(s, h, next(4096) / 64)
				t.eq(s._Item[h._HeapIndex], h, "updated handle keeps a valid index")
				counts.update += 1
			end
			if op % 97 == 0 then
				_checkHeap(s, "op " .. op)
				t.eq(s._N, #live, "op " .. op .. ": _N tracks the live set")
			end
		end
		_checkHeap(s, "final")
		t.eq(s._N, #live)
		t.eq(counts.push > 0 and counts.pop > 0 and counts.remove > 0 and counts.update > 0, true, "every op exercised")
		local popped = _drainSorted(t, s)
		t.eq(#popped, #live)
		t.eq(s._N, 0)
	end)

	t.test("remove of the last element", function()
		-- heapRemove `i == n` branch: no sift, tail cleared, count down
		local s, handles = _build({ 1, 2, 3, 4, 5 })
		local last = s._Item[s._N]
		t.eq(last._HeapIndex, 5)
		t.eq(Heap.remove(s, last), true)
		t.eq(s._N, 4)
		t.eq(last._HeapIndex, 0)
		t.eq(s._Due[5], nil, "tail cleared")
		t.eq(s._Item[5], nil, "tail cleared")
		_checkHeap(s, "after removing the last element")
		t.eq(Heap.remove(s, last), false, "a second remove is a no-op")
		t.eq(s._N, 4)
		-- the single remaining element is also "the last"
		local s1, only = _build({ 7 })
		t.eq(Heap.remove(s1, only[1]), true)
		t.eq(s1._N, 0)
		t.eq(#s1._Due, 0)
		t.eq(#s1._Item, 0)
		t.eq(only[1]._HeapIndex, 0)
		_checkHeap(s1, "empty")
		local popped = _drainSorted(t, s)
		t.eq(#popped, 4)
		for index, h in popped do
			t.eq(h, handles[index], "remaining handles drain in order")
		end
	end)

	t.test("remove of a middle element sifts the right way", function()
		-- heapRemove: the promoted last element sifts UP when it beats the
		-- hole's parent, DOWN otherwise (both branches of the prototype)
		-- siftUp case: pushes 1,10,2,11,12,3,4 → slots [1,10,2,11,12,3,4];
		-- removing slot 4 (due 11) promotes due 4 there, which must climb
		-- above its parent (slot 2, due 10).
		local s, h = _build({ 1, 10, 2, 11, 12, 3, 4 })
		t.eq(h[4]._HeapIndex, 4, "layout as built: due 11 at slot 4")
		t.eq(h[7]._HeapIndex, 7, "due 4 at slot 7")
		t.eq(Heap.remove(s, h[4]), true)
		t.eq(s._N, 6)
		t.eq(h[4]._HeapIndex, 0)
		_checkHeap(s, "after the siftUp removal")
		t.eq(h[7]._HeapIndex, 2, "due 4 climbed to slot 2")
		t.eq(h[2]._HeapIndex, 4, "due 10 was pushed down to slot 4")
		t.eq(s._Due[2], 4)
		t.eq(s._Due[4], 10)
		local popped = _drainSorted(t, s)
		t.eq(#popped, 6)

		-- siftDown case: pushes 1..7 stay as [1,2,3,4,5,6,7]; removing slot 2
		-- (due 2) promotes due 7 there, which must sink below its child (due 4).
		local s2, g = _build({ 1, 2, 3, 4, 5, 6, 7 })
		t.eq(g[2]._HeapIndex, 2)
		t.eq(Heap.remove(s2, g[2]), true)
		t.eq(s2._N, 6)
		t.eq(g[2]._HeapIndex, 0)
		_checkHeap(s2, "after the siftDown removal")
		t.eq(g[4]._HeapIndex, 2, "due 4 rose to slot 2")
		t.eq(g[7]._HeapIndex, 4, "due 7 sank to slot 4")
		t.eq(s2._Due[2], 4)
		t.eq(s2._Due[4], 7)
		local popped2 = _drainSorted(t, s2)
		t.eq(#popped2, 6)
	end)

	t.test("updateKey decrease and increase", function()
		-- heapUpdate: decrease → siftUp, increase → siftDown; ties keep Id order
		local s, h = _build({ 1, 2, 3, 4, 5, 6, 7 })
		Heap.update(s, h[7], 0)
		_checkHeap(s, "after decrease")
		t.eq(h[7]._HeapIndex, 1, "decreased to the smallest due: now the root")
		t.eq(s._Due[1], 0)
		Heap.update(s, h[1], 100)
		_checkHeap(s, "after increase")
		t.eq(h[1]._HeapIndex > 3, true, "increased past everything: a leaf")
		t.eq(s._Due[h[1]._HeapIndex], 100)
		-- update to the same due is a no-op on position
		local before = h[3]._HeapIndex
		Heap.update(s, h[3], 3)
		_checkHeap(s, "after same-key update")
		t.eq(h[3]._HeapIndex, before)
		-- a tie resolves by Id: h[5] moved to due 2 sorts AFTER h[2] (due 2, lower Id)
		Heap.update(s, h[5], 2)
		_checkHeap(s, "after tie update")
		local popped = _drainSorted(t, s)
		t.eq(popped[1], h[7])
		t.eq(popped[2], h[2])
		t.eq(popped[3], h[5], "tie: the lower Id first")
		t.eq(popped[7], h[1])
	end)

	t.test("ownership check refuses a foreign handle", function()
		-- §3.2: heapUpdate errors `Veron: handle is not scheduled on this Veron`;
		-- heapRemove's ownership check makes a foreign or stale handle a no-op (§4.3)
		local s, h = _build({ 1, 2, 3 })
		-- a table that claims a slot it does not occupy
		local impostor = { Id = 99, _HeapIndex = 1, _State = 1 }
		t.throws(function()
			Heap.update(s, impostor, 0)
		end, OWNERSHIP_MESSAGE)
		t.eq(Heap.remove(s, impostor), false, "remove is a no-op on a foreign table")
		t.eq(s._N, 3)
		t.eq(impostor._HeapIndex, 1, "the impostor is left alone")
		_checkHeap(s, "after the impostor")
		-- a handle scheduled on ANOTHER instance
		local other, foreign = _build({ 5 })
		t.throws(function()
			Heap.update(s, foreign[1], 0)
		end, OWNERSHIP_MESSAGE)
		t.eq(Heap.remove(s, foreign[1]), false)
		t.eq(other._N, 1, "the other instance is untouched")
		t.eq(foreign[1]._HeapIndex, 1)
		_checkHeap(other, "other")
		-- a never-scheduled table (`_HeapIndex == 0`)
		local stray = _newHandle(100)
		t.throws(function()
			Heap.update(s, stray, 0)
		end, OWNERSHIP_MESSAGE)
		t.eq(Heap.remove(s, stray), false)
		-- a popped handle is stale: remove → false
		local _, root = Heap.pop(s)
		t.eq(root, h[1])
		t.eq(Heap.remove(s, root), false, "popped-but-remembered → false, harmless")
		t.throws(function()
			Heap.update(s, root, 0)
		end, OWNERSHIP_MESSAGE)
		t.eq(s._N, 2)
		_checkHeap(s, "after the stale handle")
		-- the message is prefixed exactly
		local ok, err = pcall(Heap.update, s, stray, 0)
		t.eq(ok, false)
		t.eq(tostring(err):find(OWNERSHIP_MESSAGE, 1, true) ~= nil, true, tostring(err))
	end)

	t.test("clear resets every _HeapIndex", function()
		-- heapClear: every _HeapIndex → 0, arrays emptied, _N == 0, reusable
		local dues = {}
		for index = 1, 50 do
			dues[index] = (51 - index) / 64
		end
		local s, h = _build(dues)
		t.eq(s._N, 50)
		Heap.clear(s)
		t.eq(s._N, 0)
		t.eq(#s._Due, 0)
		t.eq(#s._Item, 0)
		t.eq(next(s._Due), nil, "_Due is empty")
		t.eq(next(s._Item), nil, "_Item is empty")
		for index = 1, 50 do
			t.eq(h[index]._HeapIndex, 0, "#" .. index)
		end
		_checkHeap(s, "after clear")
		-- the arrays are the same tables and still usable
		local due, item = s._Due, s._Item
		Heap.push(s, h[3], 1 / 2)
		Heap.push(s, h[1], 1 / 4)
		t.eq(s._Due, due)
		t.eq(s._Item, item)
		t.eq(s._N, 2)
		t.eq(h[1]._HeapIndex, 1)
		t.eq(h[3]._HeapIndex, 2)
		_checkHeap(s, "after re-push")
		-- clearing an empty heap is a no-op
		Heap.clear(s)
		Heap.clear(s)
		t.eq(s._N, 0)
		_checkHeap(s, "double clear")
	end)
end

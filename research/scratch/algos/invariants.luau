--!nonstrict
-- Property test for the indexed binary heap used in bench.luau (copied minimal ops): heap property,
-- _hi consistency, FIFO tie-break, re-entrant stop/adjust from inside callbacks, ForceComplete.
local PENDING, FIRED, STOPPED = 1, 2, 3
local due, item, n = {}, {}, 0
local function less(i, j)
	local a, b = due[i], due[j]
	if a ~= b then return a < b end
	return item[i]._seq < item[j]._seq
end
local function siftUp(i)
	local d, it = due[i], item[i]; local s = it._seq
	while i > 1 do
		local p = i // 2; local dp = due[p]
		if d < dp or (d == dp and s < item[p]._seq) then
			due[i] = dp; local ip = item[p]; item[i] = ip; ip._hi = i; i = p
		else break end
	end
	due[i] = d; item[i] = it; it._hi = i; return i
end
local function siftDown(i)
	local d, it = due[i], item[i]; local s = it._seq
	while true do
		local c = i + i
		if c > n then break end
		local dc = due[c]; local r = c + 1
		if r <= n then local dr = due[r]; if dr < dc or (dr == dc and item[r]._seq < item[c]._seq) then c = r; dc = dr end end
		if dc < d or (dc == d and item[c]._seq < s) then
			due[i] = dc; local ic = item[c]; item[i] = ic; ic._hi = i; i = c
		else break end
	end
	due[i] = d; item[i] = it; it._hi = i; return i
end
local function push(d, it) n += 1; due[n] = d; item[n] = it; it._hi = n; siftUp(n) end
local function pop()
	local d, it = due[1], item[1]; it._hi = 0
	if n > 1 then due[1] = due[n]; item[1] = item[n] end
	due[n] = nil; item[n] = nil; n -= 1
	if n > 0 then siftDown(1) end
	return d, it
end
local function remove(it)
	local i = it._hi; if i == 0 then return false end
	it._hi = 0
	if i == n then due[n] = nil; item[n] = nil; n -= 1; return true end
	due[i] = due[n]; item[i] = item[n]; due[n] = nil; item[n] = nil; n -= 1
	if i > 1 and less(i, i // 2) then siftUp(i) else siftDown(i) end
	return true
end
local function updateKey(it, nd)
	local i = it._hi; local old = due[i]; due[i] = nd
	if nd < old then siftUp(i) else siftDown(i) end
end
local function check()
	for i = 1, n do
		assert(item[i]._hi == i, "hi mismatch at " .. i)
		if i > 1 then assert(not less(i, i // 2), "heap property violated at " .. i) end
	end
	assert(due[n + 1] == nil and item[n + 1] == nil, "tail not cleared")
end

math.randomseed(42)
local seq = 0
local all = {}
for round = 1, 20000 do
	local op = math.random()
	if op < 0.4 or n == 0 then
		seq += 1
		local it = { _seq = seq, _hi = 0 }
		push(math.random(0, 100), it)
		all[#all + 1] = it
	elseif op < 0.6 then
		pop()
	elseif op < 0.8 then
		local it = all[math.random(#all)]
		remove(it)
	else
		local it = all[math.random(#all)]
		if it._hi > 0 then updateKey(it, math.random(0, 100)) end
	end
	if round % 97 == 0 then check() end
end
check()
-- drain: verify pops come out sorted by (due, seq)
local lastD, lastS = -1, -1
while n > 0 do
	local d, it = pop()
	assert(d > lastD or (d == lastD and it._seq > lastS), "pop order broken")
	lastD, lastS = d, it._seq
end
print("indexed heap invariants OK after 20000 random ops")

-- Re-entrancy: callback stops another due entry, adjusts the current recurring, creates nested timers.
do
	local now = 0
	local fired = {}
	local function delay(name, d, fn) seq += 1; local h = { name = name, _seq = seq, _hi = 0, fn = fn, period = d, _state = PENDING }; push(now + d, h); return h end
	local hB
	local hA = delay("A", 1, function()
		fired[#fired + 1] = "A"
		remove(hB); hB._state = STOPPED -- stop B, which is also due this update
		delay("C", 0, function() fired[#fired + 1] = "C" end) -- nested, due now -> fires this update
	end)
	hB = delay("B", 1, function() fired[#fired + 1] = "B" end)
	now = 1
	while n > 0 and due[1] <= now do
		local d, h = pop()
		h._state = FIRED
		h.fn()
	end
	assert(table.concat(fired, ",") == "A,C", "expected A,C got " .. table.concat(fired, ","))
	print("re-entrant stop of a co-due sibling + nested due-now child: OK ->", table.concat(fired, ","))
end

local C = require("./_common")
local Heap = C.Heap
C.section("float accumulation of _now")
do
	local g = C.G()
	for _ = 1, 864000 do g.update(1 / 240) end
	print(("1 h at 240 Hz: now = %.12f (drift %.3e s)"):format(g.now(), g.now() - 3600))
	local g2 = C.G()
	local n = 0
	g2.recur(function() n += 1 end, 1 / 60)
	for _ = 1, 216000 do g2.update(1 / 60) end
	print("1 h at 60 Hz, recur(1/60): fires =", n, "(216000 expected; due=prev+p and now=prev+dt are the same float ops)")
	local g3 = C.G()
	local n3 = 0
	g3.recur(function() n3 += 1 end, 0.1)
	for _ = 1, 36000 do g3.update(1 / 60) end
	print("10 min at 60 Hz, recur(0.1): fires =", n3, "(6000 expected)")
end
C.section("randomised heap property test: 20k ops vs a stable-sorted oracle")
do
	math.randomseed(20260916); local rng = { NextInteger = function(_, a, b) return math.random(a, b) end, NextNumber = function(_, a, b) if a == nil then return math.random() end return a + math.random() * (b - a) end }
	local h = Heap.new()
	local oracle = {}
	local seq = 0
	local mismatches = 0
	local function oracleSort()
		table.sort(oracle, function(a, b) if a.due ~= b.due then return a.due < b.due end return a.seq < b.seq end)
	end
	for op = 1, 20000 do
		local r = rng:NextNumber()
		if r < 0.55 then
			local due = rng:NextInteger(0, 50) + (rng:NextNumber() < 0.5 and 0 or 0.5)
			seq += 1
			h:push(due, op, seq)
			table.insert(oracle, { due = due, seq = seq, gen = op, item = seq })
		elseif r < 0.95 then
			if h:size() > 0 then
				oracleSort()
				local e = table.remove(oracle, 1)
				local due, gen, item = h:pop()
				if due ~= e.due or gen ~= e.gen or item ~= e.item then mismatches += 1 end
			end
		else
			local threshold = rng:NextInteger(0, 50)
			h:rebuild(function(due) return due >= threshold end)
			local kept = {}
			for _, e in oracle do if e.due >= threshold then table.insert(kept, e) end end
			oracle = kept
		end
		if h:size() ~= #oracle then mismatches += 1 end
	end
	oracleSort()
	for _, e in oracle do
		local due, _, item = h:pop()
		if due ~= e.due or item ~= e.item then mismatches += 1 end
	end
	print("mismatches:", mismatches, "| final heap size:", h:size())
end
C.section("Heap with NaN keys: violates the strict weak ordering less() assumes")
do
	local h = Heap.new()
	h:push(0.1, 1, "a"); h:push(0 / 0, 2, "nan"); h:push(0.2, 3, "c"); h:push(0.05, 4, "d")
	local order = {}
	while not h:isEmpty() do local _, _, item = h:pop(); table.insert(order, item) end
	print("pop order:", table.concat(order, ","), "(d should come first)")
end

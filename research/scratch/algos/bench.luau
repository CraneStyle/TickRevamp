--!nonstrict
-- TickRevamp scheduler-algorithm micro-benchmark (Lune 0.10.5, interpreter, NOT Roblox --!native).
-- Run:  cd research/scratch/algos && lune run bench.luau
--
-- Candidates (all share the same scheduler shell semantics: delay/recur/stop/adjust/reset/update):
--   IB   indexed binary heap, parallel arrays due[]/item[], handle holds _hi, seq on handle
--   I4   indexed 4-ary heap, same layout
--   IH   indexed binary heap, handle-only array (due read through item[i]._due)
--   LZ   lazy-deletion shell over the PRIOR Heap module (gen tags + threshold rebuild) — prior strategy, minimal shell
--   PG   the prior Group as built (P/build/src/TickAPI/Group) — reference
--   SA   sorted array (descending; soonest at the end), binary-search insert + table.insert/remove shifts
--   TW   hashed timing wheel, 1024 slots, 1/60 s tick, rounds counter, O(1) cancel
local PGroup = require("../../../../TickAPIOptimize/build/src/TickAPI/Group")
local PVariants = require("../../../../TickAPIOptimize/build/src/TickAPI/Variants")
local PHeap = require("../../../../TickAPIOptimize/build/src/TickAPI/Heap")

local clock = os.clock
local noop = function() end
local PENDING, FIRED, STOPPED = 1, 2, 3

local function gccollect()
	pcall(collectgarbage, "collect")
end
local function gccount()
	return collectgarbage("count")
end

------------------------------------------------------------------------------------------------
-- IB: indexed binary heap, parallel arrays, hole-move sifts, handle holds _hi and _seq
------------------------------------------------------------------------------------------------
local IB = {}
IB.__index = IB

local function ib_siftUp(due, item, i)
	local d, it = due[i], item[i]
	local s = it._seq
	while i > 1 do
		local p = i // 2
		local dp = due[p]
		if d < dp or (d == dp and s < item[p]._seq) then
			due[i] = dp
			local ip = item[p]
			item[i] = ip
			ip._hi = i
			i = p
		else
			break
		end
	end
	due[i] = d
	item[i] = it
	it._hi = i
	return i
end

local function ib_siftDown(due, item, n, i)
	local d, it = due[i], item[i]
	local s = it._seq
	while true do
		local c = i + i
		if c > n then
			break
		end
		local dc = due[c]
		local r = c + 1
		if r <= n then
			local dr = due[r]
			if dr < dc or (dr == dc and item[r]._seq < item[c]._seq) then
				c = r
				dc = dr
			end
		end
		if dc < d or (dc == d and item[c]._seq < s) then
			due[i] = dc
			local ic = item[c]
			item[i] = ic
			ic._hi = i
			i = c
		else
			break
		end
	end
	due[i] = d
	item[i] = it
	it._hi = i
	return i
end

local function ib_push(self, d, it)
	local n = self.n + 1
	self.n = n
	self.due[n] = d
	self.item[n] = it
	it._hi = n
	ib_siftUp(self.due, self.item, n)
end

local function ib_pop(self)
	local due, item = self.due, self.item
	local n = self.n
	local d, it = due[1], item[1]
	it._hi = 0
	if n > 1 then
		due[1] = due[n]
		item[1] = item[n]
	end
	due[n] = nil
	item[n] = nil
	n -= 1
	self.n = n
	if n > 0 then
		ib_siftDown(due, item, n, 1)
	end
	return d, it
end

local function ib_remove(self, it)
	local i = it._hi
	if i == 0 then
		return false
	end
	local due, item = self.due, self.item
	local n = self.n
	it._hi = 0
	if i == n then
		due[n] = nil
		item[n] = nil
		self.n = n - 1
		return true
	end
	due[i] = due[n]
	item[i] = item[n]
	due[n] = nil
	item[n] = nil
	n -= 1
	self.n = n
	if i > 1 then
		local p = i // 2
		local d, dp = due[i], due[p]
		if d < dp or (d == dp and item[i]._seq < item[p]._seq) then
			ib_siftUp(due, item, i)
			return true
		end
	end
	ib_siftDown(due, item, n, i)
	return true
end

local function ib_updateKey(self, it, newDue)
	local i = it._hi
	local due, item = self.due, self.item
	local old = due[i]
	due[i] = newDue
	if newDue < old then
		ib_siftUp(due, item, i)
	else
		ib_siftDown(due, item, self.n, i)
	end
end

function IB.new()
	return setmetatable({ due = {}, item = {}, n = 0, now = 0, seq = 0, live = 0, fired = 0 }, IB)
end
function IB:delay(fn, d, recur)
	local seq = self.seq + 1
	self.seq = seq
	local h = { fn = fn, period = d, recur = recur or false, _seq = seq, _hi = 0, _state = PENDING }
	self.live += 1
	ib_push(self, self.now + d, h)
	return h
end
function IB:stop(h)
	if h._state ~= PENDING then
		return
	end
	h._state = STOPPED
	ib_remove(self, h)
	self.live -= 1
end
function IB:adjust(h, newTotal)
	if h._state ~= PENDING or h._hi == 0 then
		return
	end
	local remaining = self.due[h._hi] - self.now
	if remaining < 0 then
		remaining = 0
	end
	local ratio = newTotal / h.period
	h.period = newTotal
	ib_updateKey(self, h, self.now + remaining * ratio)
end
function IB:reset(h)
	if h._state ~= PENDING or h._hi == 0 then
		return
	end
	ib_updateKey(self, h, self.now + h.period)
end
function IB:update(dt)
	local now = self.now + dt
	self.now = now
	local due = self.due
	local fired = 0
	while self.n > 0 and due[1] <= now do
		local d, h = ib_pop(self)
		if h.recur then
			ib_push(self, d + h.period, h)
		else
			h._state = FIRED
			self.live -= 1
		end
		h.fn()
		fired += 1
	end
	self.fired = fired
end
function IB:size()
	return self.n
end

------------------------------------------------------------------------------------------------
-- IB2: IB + Floyd bottom-up pop (1 compare per level going down, then a short sift-up) and
-- in-place root re-key for recurring re-arm (one siftDown instead of pop+push).
------------------------------------------------------------------------------------------------
local IB2 = setmetatable({}, { __index = IB })
IB2.__index = IB2

-- Hole at i holds (d,it). Phase 1: promote the smaller child up to the hole until a leaf is reached.
-- Phase 2: sift (d,it) back up from the leaf, never above `start`.
local function ib_siftDownFloyd(due, item, n, i)
	local d, it = due[i], item[i]
	local s = it._seq
	local start = i
	while true do
		local c = i + i
		if c > n then
			break
		end
		local r = c + 1
		if r <= n then
			local dc, dr = due[c], due[r]
			if dr < dc or (dr == dc and item[r]._seq < item[c]._seq) then
				c = r
			end
		end
		due[i] = due[c]
		local ic = item[c]
		item[i] = ic
		ic._hi = i
		i = c
	end
	while i > start do
		local p = i // 2
		local dp = due[p]
		if d < dp or (d == dp and s < item[p]._seq) then
			due[i] = dp
			local ip = item[p]
			item[i] = ip
			ip._hi = i
			i = p
		else
			break
		end
	end
	due[i] = d
	item[i] = it
	it._hi = i
	return i
end

local function ib2_pop(self)
	local due, item = self.due, self.item
	local n = self.n
	local d, it = due[1], item[1]
	it._hi = 0
	if n > 1 then
		due[1] = due[n]
		item[1] = item[n]
	end
	due[n] = nil
	item[n] = nil
	n -= 1
	self.n = n
	if n > 0 then
		ib_siftDownFloyd(due, item, n, 1)
	end
	return d, it
end

function IB2.new()
	return setmetatable({ due = {}, item = {}, n = 0, now = 0, seq = 0, live = 0, fired = 0 }, IB2)
end
function IB2:update(dt)
	local now = self.now + dt
	self.now = now
	local due, item = self.due, self.item
	local fired = 0
	while self.n > 0 and due[1] <= now do
		local h
		if item[1].recur then
			-- in-place re-key of the root: entry stays in the heap, one siftDown
			h = item[1]
			due[1] = due[1] + h.period
			ib_siftDown(due, item, self.n, 1)
		else
			local _d
			_d, h = ib2_pop(self)
			h._state = FIRED
			self.live -= 1
		end
		h.fn()
		fired += 1
	end
	self.fired = fired
end

------------------------------------------------------------------------------------------------
-- I4: indexed 4-ary heap (1-based: children of i are 4i-2..4i+1, parent of c is (c+2)//4)
------------------------------------------------------------------------------------------------
local I4 = setmetatable({}, { __index = IB })
I4.__index = I4

local function i4_siftUp(due, item, i)
	local d, it = due[i], item[i]
	local s = it._seq
	while i > 1 do
		local p = (i + 2) // 4
		local dp = due[p]
		if d < dp or (d == dp and s < item[p]._seq) then
			due[i] = dp
			local ip = item[p]
			item[i] = ip
			ip._hi = i
			i = p
		else
			break
		end
	end
	due[i] = d
	item[i] = it
	it._hi = i
	return i
end

local function i4_siftDown(due, item, n, i)
	local d, it = due[i], item[i]
	local s = it._seq
	while true do
		local c = i * 4 - 2
		if c > n then
			break
		end
		local dc = due[c]
		local last = c + 3
		if last > n then
			last = n
		end
		for k = c + 1, last do
			local dk = due[k]
			if dk < dc or (dk == dc and item[k]._seq < item[c]._seq) then
				c = k
				dc = dk
			end
		end
		if dc < d or (dc == d and item[c]._seq < s) then
			due[i] = dc
			local ic = item[c]
			item[i] = ic
			ic._hi = i
			i = c
		else
			break
		end
	end
	due[i] = d
	item[i] = it
	it._hi = i
	return i
end

local function i4_push(self, d, it)
	local n = self.n + 1
	self.n = n
	self.due[n] = d
	self.item[n] = it
	it._hi = n
	i4_siftUp(self.due, self.item, n)
end
local function i4_pop(self)
	local due, item = self.due, self.item
	local n = self.n
	local d, it = due[1], item[1]
	it._hi = 0
	if n > 1 then
		due[1] = due[n]
		item[1] = item[n]
	end
	due[n] = nil
	item[n] = nil
	n -= 1
	self.n = n
	if n > 0 then
		i4_siftDown(due, item, n, 1)
	end
	return d, it
end
local function i4_remove(self, it)
	local i = it._hi
	if i == 0 then
		return false
	end
	local due, item = self.due, self.item
	local n = self.n
	it._hi = 0
	if i == n then
		due[n] = nil
		item[n] = nil
		self.n = n - 1
		return true
	end
	due[i] = due[n]
	item[i] = item[n]
	due[n] = nil
	item[n] = nil
	n -= 1
	self.n = n
	if i > 1 then
		local p = (i + 2) // 4
		local d, dp = due[i], due[p]
		if d < dp or (d == dp and item[i]._seq < item[p]._seq) then
			i4_siftUp(due, item, i)
			return true
		end
	end
	i4_siftDown(due, item, n, i)
	return true
end
local function i4_updateKey(self, it, newDue)
	local i = it._hi
	local due, item = self.due, self.item
	local old = due[i]
	due[i] = newDue
	if newDue < old then
		i4_siftUp(due, item, i)
	else
		i4_siftDown(due, item, self.n, i)
	end
end
function I4.new()
	return setmetatable({ due = {}, item = {}, n = 0, now = 0, seq = 0, live = 0, fired = 0 }, I4)
end
function I4:delay(fn, d, recur)
	local seq = self.seq + 1
	self.seq = seq
	local h = { fn = fn, period = d, recur = recur or false, _seq = seq, _hi = 0, _state = PENDING }
	self.live += 1
	i4_push(self, self.now + d, h)
	return h
end
function I4:stop(h)
	if h._state ~= PENDING then
		return
	end
	h._state = STOPPED
	i4_remove(self, h)
	self.live -= 1
end
function I4:adjust(h, newTotal)
	if h._state ~= PENDING or h._hi == 0 then
		return
	end
	local remaining = self.due[h._hi] - self.now
	if remaining < 0 then
		remaining = 0
	end
	local ratio = newTotal / h.period
	h.period = newTotal
	i4_updateKey(self, h, self.now + remaining * ratio)
end
function I4:reset(h)
	if h._state ~= PENDING or h._hi == 0 then
		return
	end
	i4_updateKey(self, h, self.now + h.period)
end
function I4:update(dt)
	local now = self.now + dt
	self.now = now
	local due = self.due
	local fired = 0
	while self.n > 0 and due[1] <= now do
		local d, h = i4_pop(self)
		if h.recur then
			i4_push(self, d + h.period, h)
		else
			h._state = FIRED
			self.live -= 1
		end
		h.fn()
		fired += 1
	end
	self.fired = fired
end

------------------------------------------------------------------------------------------------
-- I42: I4 + in-place root re-key for recurring (no Floyd: 4-ary phase-1 needs 3 sibling compares anyway)
------------------------------------------------------------------------------------------------
local I42 = setmetatable({}, { __index = I4 })
I42.__index = I42
function I42.new()
	return setmetatable({ due = {}, item = {}, n = 0, now = 0, seq = 0, live = 0, fired = 0 }, I42)
end
function I42:update(dt)
	local now = self.now + dt
	self.now = now
	local due, item = self.due, self.item
	local fired = 0
	while self.n > 0 and due[1] <= now do
		local h
		if item[1].recur then
			h = item[1]
			due[1] = due[1] + h.period
			i4_siftDown(due, item, self.n, 1)
		else
			local _d
			_d, h = i4_pop(self)
			h._state = FIRED
			self.live -= 1
		end
		h.fn()
		fired += 1
	end
	self.fired = fired
end

------------------------------------------------------------------------------------------------
-- IH: indexed binary heap, handle-only array; key read through h._due (one array, indirect loads)
------------------------------------------------------------------------------------------------
local IH = {}
IH.__index = IH

local function ih_less(a, b)
	local da, db = a._due, b._due
	if da ~= db then
		return da < db
	end
	return a._seq < b._seq
end
local function ih_siftUp(item, i)
	local it = item[i]
	while i > 1 do
		local p = i // 2
		local ip = item[p]
		if ih_less(it, ip) then
			item[i] = ip
			ip._hi = i
			i = p
		else
			break
		end
	end
	item[i] = it
	it._hi = i
	return i
end
local function ih_siftDown(item, n, i)
	local it = item[i]
	while true do
		local c = i + i
		if c > n then
			break
		end
		local ic = item[c]
		local r = c + 1
		if r <= n then
			local ir = item[r]
			if ih_less(ir, ic) then
				c = r
				ic = ir
			end
		end
		if ih_less(ic, it) then
			item[i] = ic
			ic._hi = i
			i = c
		else
			break
		end
	end
	item[i] = it
	it._hi = i
	return i
end
local function ih_push(self, it)
	local n = self.n + 1
	self.n = n
	self.item[n] = it
	it._hi = n
	ih_siftUp(self.item, n)
end
local function ih_pop(self)
	local item = self.item
	local n = self.n
	local it = item[1]
	it._hi = 0
	if n > 1 then
		item[1] = item[n]
	end
	item[n] = nil
	n -= 1
	self.n = n
	if n > 0 then
		ih_siftDown(item, n, 1)
	end
	return it
end
local function ih_remove(self, it)
	local i = it._hi
	if i == 0 then
		return false
	end
	local item = self.item
	local n = self.n
	it._hi = 0
	if i == n then
		item[n] = nil
		self.n = n - 1
		return true
	end
	item[i] = item[n]
	item[n] = nil
	n -= 1
	self.n = n
	if i > 1 and ih_less(item[i], item[i // 2]) then
		ih_siftUp(item, i)
	else
		ih_siftDown(item, n, i)
	end
	return true
end
local function ih_updateKey(self, it, newDue)
	local old = it._due
	it._due = newDue
	if newDue < old then
		ih_siftUp(self.item, it._hi)
	else
		ih_siftDown(self.item, self.n, it._hi)
	end
end
function IH.new()
	return setmetatable({ item = {}, n = 0, now = 0, seq = 0, live = 0, fired = 0 }, IH)
end
function IH:delay(fn, d, recur)
	local seq = self.seq + 1
	self.seq = seq
	local h = { fn = fn, period = d, recur = recur or false, _seq = seq, _hi = 0, _due = self.now + d, _state = PENDING }
	self.live += 1
	ih_push(self, h)
	return h
end
function IH:stop(h)
	if h._state ~= PENDING then
		return
	end
	h._state = STOPPED
	ih_remove(self, h)
	self.live -= 1
end
function IH:adjust(h, newTotal)
	if h._state ~= PENDING or h._hi == 0 then
		return
	end
	local remaining = h._due - self.now
	if remaining < 0 then
		remaining = 0
	end
	local ratio = newTotal / h.period
	h.period = newTotal
	ih_updateKey(self, h, self.now + remaining * ratio)
end
function IH:reset(h)
	if h._state ~= PENDING or h._hi == 0 then
		return
	end
	ih_updateKey(self, h, self.now + h.period)
end
function IH:update(dt)
	local now = self.now + dt
	self.now = now
	local item = self.item
	local fired = 0
	while self.n > 0 and item[1]._due <= now do
		local h = ih_pop(self)
		if h.recur then
			h._due += h.period
			ih_push(self, h)
		else
			h._state = FIRED
			self.live -= 1
		end
		h.fn()
		fired += 1
	end
	self.fired = fired
end
function IH:size()
	return self.n
end

------------------------------------------------------------------------------------------------
-- LZ: lazy-deletion shell over the prior Heap (gen tags, stale counter, threshold rebuild)
------------------------------------------------------------------------------------------------
local LZ = {}
LZ.__index = LZ
function LZ.new()
	return setmetatable({ heap = PHeap.new(), now = 0, live = 0, stale = 0, fired = 0, rebuilds = 0 }, LZ)
end
local function lz_compact(self)
	if self.stale > math.max(64, self.live) or (self.live == 0 and self.stale > 0) then
		self.heap:rebuild(function(_d, gen, h)
			return gen == h._gen and h._state == PENDING
		end)
		self.stale = 0
		self.rebuilds += 1
	end
end
local function lz_arm(self, h, due)
	if h._inHeap then
		self.stale += 1
	end
	h._gen += 1
	h._due = due
	h._inHeap = true
	self.heap:push(due, h._gen, h)
end
function LZ:delay(fn, d, recur)
	local h = { fn = fn, period = d, recur = recur or false, _gen = 0, _inHeap = false, _due = 0, _state = PENDING }
	self.live += 1
	lz_arm(self, h, self.now + d)
	return h
end
function LZ:stop(h)
	if h._state ~= PENDING then
		return
	end
	h._state = STOPPED
	if h._inHeap then
		self.stale += 1
		h._inHeap = false
	end
	h._gen += 1
	self.live -= 1
	lz_compact(self)
end
function LZ:adjust(h, newTotal)
	if h._state ~= PENDING then
		return
	end
	local remaining = h._due - self.now
	if remaining < 0 then
		remaining = 0
	end
	local ratio = newTotal / h.period
	h.period = newTotal
	lz_arm(self, h, self.now + remaining * ratio)
	lz_compact(self)
end
function LZ:reset(h)
	if h._state ~= PENDING then
		return
	end
	lz_arm(self, h, self.now + h.period)
	lz_compact(self)
end
function LZ:update(dt)
	local now = self.now + dt
	self.now = now
	local heap = self.heap
	local fired = 0
	while not heap:isEmpty() do
		local top = heap:peek()
		if top > now then
			break
		end
		local due, gen, h = heap:pop()
		if gen ~= h._gen or h._state ~= PENDING then
			self.stale -= 1
		else
			h._inHeap = false
			if h.recur then
				lz_arm(self, h, due + h.period)
			else
				h._state = FIRED
				self.live -= 1
			end
			h.fn()
			fired += 1
		end
	end
	self.fired = fired
end
function LZ:size()
	return self.heap:size()
end

------------------------------------------------------------------------------------------------
-- PG: prior Group as built (adapter to the shell interface)
------------------------------------------------------------------------------------------------
local PG = {}
PG.__index = PG
function PG.new()
	return setmetatable({ g = PGroup.new(PVariants.resolve({ driver = "Manual" })) }, PG)
end
function PG:delay(fn, d, recur)
	if recur then
		return self.g:recur(fn, d)
	end
	return self.g:delay(fn, d)
end
function PG:stop(h)
	h:stop()
end
function PG:adjust(h, newTotal)
	h:adjust(newTotal)
end
function PG:reset(h)
	h:reset()
end
function PG:update(dt)
	self.g:update(dt)
end
function PG:size()
	return self.g:getStats().heapSize
end

------------------------------------------------------------------------------------------------
-- SA: sorted array, DESCENDING by due (soonest at the end so pop is O(1)); equal dues: newer
-- element placed at a lower index so older pops first (FIFO). Insert/remove shift via table.insert/remove.
------------------------------------------------------------------------------------------------
local SA = {}
SA.__index = SA
function SA.new()
	return setmetatable({ due = {}, item = {}, n = 0, now = 0, live = 0, fired = 0 }, SA)
end
-- leftmost i in [1, n+1] such that due[i] <= d
local function sa_findInsert(due, n, d)
	local lo, hi = 1, n + 1
	while lo < hi do
		local mid = (lo + hi) // 2
		if due[mid] > d then
			lo = mid + 1
		else
			hi = mid
		end
	end
	return lo
end
local function sa_insert(self, d, it)
	local n = self.n
	local i = sa_findInsert(self.due, n, d)
	table.insert(self.due, i, d)
	table.insert(self.item, i, it)
	it._due = d
	self.n = n + 1
end
local function sa_indexOf(self, it)
	local due, item, n = self.due, self.item, self.n
	local d = it._due
	local i = sa_findInsert(due, n, d) -- first index with due <= d
	while i <= n and due[i] == d do
		if item[i] == it then
			return i
		end
		i += 1
	end
	return 0
end
local function sa_remove(self, it)
	local i = sa_indexOf(self, it)
	if i == 0 then
		return false
	end
	table.remove(self.due, i)
	table.remove(self.item, i)
	self.n -= 1
	return true
end
function SA:delay(fn, d, recur)
	local h = { fn = fn, period = d, recur = recur or false, _due = 0, _state = PENDING }
	self.live += 1
	sa_insert(self, self.now + d, h)
	return h
end
function SA:stop(h)
	if h._state ~= PENDING then
		return
	end
	h._state = STOPPED
	sa_remove(self, h)
	self.live -= 1
end
function SA:adjust(h, newTotal)
	if h._state ~= PENDING then
		return
	end
	local remaining = h._due - self.now
	if remaining < 0 then
		remaining = 0
	end
	local ratio = newTotal / h.period
	h.period = newTotal
	sa_remove(self, h)
	sa_insert(self, self.now + remaining * ratio, h)
end
function SA:reset(h)
	if h._state ~= PENDING then
		return
	end
	sa_remove(self, h)
	sa_insert(self, self.now + h.period, h)
end
function SA:update(dt)
	local now = self.now + dt
	self.now = now
	local due, item = self.due, self.item
	local fired = 0
	while self.n > 0 and due[self.n] <= now do
		local n = self.n
		local d, h = due[n], item[n]
		due[n] = nil
		item[n] = nil
		self.n = n - 1
		if h.recur then
			sa_insert(self, d + h.period, h)
		else
			h._state = FIRED
			self.live -= 1
		end
		h.fn()
		fired += 1
	end
	self.fired = fired
end
function SA:size()
	return self.n
end

------------------------------------------------------------------------------------------------
-- TW: hashed timing wheel. 1024 slots x (1/60 s) = 17.07 s horizon per round; rounds counter beyond.
-- Bucket = array of handles with swap-remove (h._slot, h._bi). Fires at the tick boundary at or after due
-- (quantized). No intra-bucket ordering.
------------------------------------------------------------------------------------------------
local TW = {}
TW.__index = TW
local TW_SLOTS = 1024
local TW_TICK = 1 / 60
function TW.new()
	local buckets = table.create(TW_SLOTS)
	for i = 1, TW_SLOTS do
		buckets[i] = {}
	end
	return setmetatable({ buckets = buckets, bn = table.create(TW_SLOTS, 0), tick = 0, tickTime = 0, now = 0, n = 0, live = 0, fired = 0 }, TW)
end
local function tw_insert(self, d, it)
	local ticks = math.ceil((d - self.tickTime) / TW_TICK)
	if ticks < 1 then
		ticks = 1
	end
	local fireTick = self.tick + ticks
	local slot = fireTick % TW_SLOTS + 1
	it._rounds = (ticks - 1) // TW_SLOTS
	it._due = d
	it._slot = slot
	local b = self.buckets[slot]
	local bn = self.bn[slot] + 1
	self.bn[slot] = bn
	b[bn] = it
	it._bi = bn
	self.n += 1
end
local function tw_remove(self, it)
	local slot = it._slot
	if slot == 0 then
		return false
	end
	local b = self.buckets[slot]
	local bn = self.bn[slot]
	local i = it._bi
	if i ~= bn then
		local last = b[bn]
		b[i] = last
		last._bi = i
	end
	b[bn] = nil
	self.bn[slot] = bn - 1
	it._slot = 0
	it._bi = 0
	self.n -= 1
	return true
end
function TW:delay(fn, d, recur)
	local h = { fn = fn, period = d, recur = recur or false, _slot = 0, _bi = 0, _rounds = 0, _due = 0, _state = PENDING }
	self.live += 1
	tw_insert(self, self.now + d, h)
	return h
end
function TW:stop(h)
	if h._state ~= PENDING then
		return
	end
	h._state = STOPPED
	tw_remove(self, h)
	self.live -= 1
end
function TW:adjust(h, newTotal)
	if h._state ~= PENDING then
		return
	end
	local remaining = h._due - self.now
	if remaining < 0 then
		remaining = 0
	end
	local ratio = newTotal / h.period
	h.period = newTotal
	tw_remove(self, h)
	tw_insert(self, self.now + remaining * ratio, h)
end
function TW:reset(h)
	if h._state ~= PENDING then
		return
	end
	tw_remove(self, h)
	tw_insert(self, self.now + h.period, h)
end
function TW:update(dt)
	local now = self.now + dt
	self.now = now
	local fired = 0
	local visited = 0
	while self.tickTime + TW_TICK <= now do
		local tick = self.tick + 1
		self.tick = tick
		self.tickTime += TW_TICK
		local slot = tick % TW_SLOTS + 1
		local b = self.buckets[slot]
		local i = self.bn[slot]
		while i >= 1 do
			local h = b[i]
			visited += 1
			if h._rounds == 0 then
				-- swap-remove i with the last
				local bn = self.bn[slot]
				if i ~= bn then
					local last = b[bn]
					b[i] = last
					last._bi = i
				end
				b[bn] = nil
				self.bn[slot] = bn - 1
				h._slot = 0
				h._bi = 0
				self.n -= 1
				if h.recur then
					tw_insert(self, h._due + h.period, h)
				else
					h._state = FIRED
					self.live -= 1
				end
				h.fn()
				fired += 1
			else
				h._rounds -= 1
			end
			i -= 1
		end
	end
	self.fired = fired
	self.visited = visited
end
function TW:size()
	return self.n
end

------------------------------------------------------------------------------------------------
-- Harness
------------------------------------------------------------------------------------------------
local N = 10000
local SEED = 20260916
local IDLE_UPDATES = 200
local IDLE_DT = 0.005

local function rng(seed)
	math.randomseed(seed)
end
local function dues(n, lo, hi)
	local d = table.create(n)
	for i = 1, n do
		d[i] = lo + math.random() * (hi - lo)
	end
	return d
end
local function shuffled(n)
	local p = table.create(n)
	for i = 1, n do
		p[i] = i
	end
	for i = n, 2, -1 do
		local j = math.random(i)
		p[i], p[j] = p[j], p[i]
	end
	return p
end

-- Time a body 5x, return median ms and the KB allocated (count delta before any collect).
local function measure(body, reps)
	reps = reps or 5
	local samples = {}
	local allocKB = 0
	for r = 1, reps do
		gccollect()
		local c0 = gccount()
		local t0 = clock()
		body()
		local t1 = clock()
		local c1 = gccount()
		samples[r] = (t1 - t0) * 1000
		allocKB = math.max(allocKB, c1 - c0)
	end
	table.sort(samples)
	return samples[(reps + 1) // 2], allocKB
end

local IMPLS = {
	{ "IB  indexed binary (parallel arrays)", IB },
	{ "IB2 indexed binary + Floyd pop + in-place recur re-key", IB2 },
	{ "I4  indexed 4-ary (parallel arrays)", I4 },
	{ "I42 indexed 4-ary + in-place recur re-key", I42 },
	{ "IH  indexed binary (handle-only array)", IH },
	{ "LZ  lazy-deletion shell over prior Heap", LZ },
	{ "PG  prior Group as built", PG },
	{ "SA  sorted array (table.insert/remove)", SA },
	{ "TW  hashed timing wheel 1024x1/60", TW },
}

local results = {}
local function rec(name, phase, ms, allocKB, extra)
	results[#results + 1] = { name = name, phase = phase, ms = ms, kb = allocKB, extra = extra }
end

for _, spec in IMPLS do
	local name, Impl = spec[1], spec[2]
	print("== " .. name)

	-- P1 arm N random dues in [10, 20]
	do
		rng(SEED)
		local d = dues(N, 10, 20)
		local ms, kb = measure(function()
			local s = Impl.new()
			for i = 1, N do
				s:delay(noop, d[i])
			end
		end)
		rec(name, "P1 arm 10k", ms, kb)
		print(("  P1 arm 10k: %.3f ms  (%.0f ns/op)  alloc %.0f KB"):format(ms, ms * 1e6 / N, kb))
	end

	-- P2 200 idle updates with 10k armed (nothing due)
	do
		rng(SEED)
		local d = dues(N, 10, 20)
		local s = Impl.new()
		for i = 1, N do
			s:delay(noop, d[i])
		end
		local ms, kb = measure(function()
			for _ = 1, IDLE_UPDATES do
				s:update(IDLE_DT)
			end
		end)
		rec(name, "P2 200 idle updates", ms, kb)
		print(("  P2 200 idle updates: %.3f ms  (%.2f us/update)  alloc %.0f KB"):format(ms, ms * 1e3 / IDLE_UPDATES, kb))
	end

	-- P3 10k stops in shuffled order (max single-op spike measured too)
	do
		rng(SEED)
		local d = dues(N, 10, 20)
		local order = shuffled(N)
		local ms, kb = measure(function()
			local s = Impl.new()
			local hs = table.create(N)
			for i = 1, N do
				hs[i] = s:delay(noop, d[i])
			end
			local t0 = clock()
			for i = 1, N do
				s:stop(hs[order[i]])
			end
			results.__lastStop = (clock() - t0) * 1000
		end)
		local stopMs = results.__lastStop
		-- spike: time every stop individually on a fresh population
		local s = Impl.new()
		local hs = table.create(N)
		for i = 1, N do
			hs[i] = s:delay(noop, d[i])
		end
		local maxUs = 0
		for i = 1, N do
			local t0 = clock()
			s:stop(hs[order[i]])
			local us = (clock() - t0) * 1e6
			if us > maxUs then
				maxUs = us
			end
		end
		rec(name, "P3 10k stops (shuffled)", stopMs, kb, ("max single stop %.0f us; heap size after %d"):format(maxUs, s:size()))
		print(("  P3 10k stops shuffled: %.3f ms  (%.0f ns/op)  max single stop %.0f us  size after %d"):format(stopMs, stopMs * 1e6 / N, maxUs, s:size()))
	end

	-- P4 10k adjusts (shuffled), newTotal = period * U(0.5, 1.5)
	do
		rng(SEED)
		local d = dues(N, 10, 20)
		local order = shuffled(N)
		local f = dues(N, 0.5, 1.5)
		local adjMs = 0
		local _, kb = measure(function()
			local s = Impl.new()
			local hs = table.create(N)
			for i = 1, N do
				hs[i] = s:delay(noop, d[i])
			end
			local t0 = clock()
			for i = 1, N do
				local h = hs[order[i]]
				s:adjust(h, h.period * f[i])
			end
			adjMs = (clock() - t0) * 1000
		end)
		local s = Impl.new()
		local hs = table.create(N)
		for i = 1, N do
			hs[i] = s:delay(noop, d[i])
		end
		local maxUs = 0
		for i = 1, N do
			local h = hs[order[i]]
			local t0 = clock()
			s:adjust(h, h.period * f[i])
			local us = (clock() - t0) * 1e6
			if us > maxUs then
				maxUs = us
			end
		end
		rec(name, "P4 10k adjusts (shuffled)", adjMs, kb, ("max single adjust %.0f us; heap size after %d"):format(maxUs, s:size()))
		print(("  P4 10k adjusts shuffled: %.3f ms  (%.0f ns/op)  max single adjust %.0f us  size after %d"):format(adjMs, adjMs * 1e6 / N, maxUs, s:size()))
	end

	-- P5 10k resets (shuffled): re-key to now + period (increase-key path)
	do
		rng(SEED)
		local d = dues(N, 10, 20)
		local order = shuffled(N)
		local resMs = 0
		local _, kb = measure(function()
			local s = Impl.new()
			local hs = table.create(N)
			for i = 1, N do
				hs[i] = s:delay(noop, d[i])
			end
			s:update(5)
			local t0 = clock()
			for i = 1, N do
				s:reset(hs[order[i]])
			end
			resMs = (clock() - t0) * 1000
		end)
		rec(name, "P5 10k resets (shuffled)", resMs, kb)
		print(("  P5 10k resets shuffled: %.3f ms  (%.0f ns/op)"):format(resMs, resMs * 1e6 / N))
	end

	-- P6 fire storm: 10k due in [0,1], one update(1) fires all
	do
		rng(SEED)
		local d = dues(N, 0, 1)
		local fireMs = 0
		local _, kb = measure(function()
			local s = Impl.new()
			for i = 1, N do
				s:delay(noop, d[i])
			end
			local t0 = clock()
			s:update(1.0001)
			fireMs = (clock() - t0) * 1000
			assert(s.fired == N or s.g ~= nil, "fire storm did not fire all: " .. tostring(s.fired))
		end)
		rec(name, "P6 fire storm 10k in one update", fireMs, kb)
		print(("  P6 fire storm 10k: %.3f ms  (%.0f ns/dispatch)"):format(fireMs, fireMs * 1e6 / N))
	end

	-- P7 recurring steady state: 10k recur period U(0.5,1.5), 600 updates at 1/60
	do
		rng(SEED)
		local p = dues(N, 0.5, 1.5)
		local fires = 0
		local cb = function()
			fires += 1
		end
		local s = Impl.new()
		for i = 1, N do
			s:delay(cb, p[i], true)
		end
		fires = 0
		local ms, kb = measure(function()
			for _ = 1, 600 do
				s:update(1 / 60)
			end
		end, 3)
		local perRun = fires / 3
		rec(name, "P7 10k recurring x 600 updates", ms, kb, ("%.0f fires/run"):format(perRun))
		print(("  P7 10k recurring, 600 updates: %.3f ms  (%.1f us/update, %.0f ns/fire, %.0f fires)  alloc %.0f KB"):format(ms, ms * 1e3 / 600, ms * 1e6 / perRun, perRun, kb))
	end

	-- P9 adjust storm repeated: 10k armed; 10 rounds of (adjust all 10k, then one update). Exposes rebuild spikes / heap growth.
	do
		rng(SEED)
		local d = dues(N, 10, 20)
		local f = dues(N, 0.8, 1.2)
		local s = Impl.new()
		local hs = table.create(N)
		for i = 1, N do
			hs[i] = s:delay(noop, d[i])
		end
		local maxRoundMs, maxOpUs = 0, 0
		local t0 = clock()
		for _ = 1, 10 do
			local r0 = clock()
			for i = 1, N do
				local h = hs[i]
				local o0 = clock()
				s:adjust(h, h.period * f[i])
				local us = (clock() - o0) * 1e6
				if us > maxOpUs then
					maxOpUs = us
				end
			end
			s:update(0.005)
			local rms = (clock() - r0) * 1000
			if rms > maxRoundMs then
				maxRoundMs = rms
			end
		end
		local total = (clock() - t0) * 1000
		rec(name, "P9 adjust storm x10", total, 0, ("max round %.2f ms, max op %.0f us, size after %d"):format(maxRoundMs, maxOpUs, s:size()))
		print(("  P9 adjust storm x10: %.3f ms total  max round %.2f ms  max single op %.0f us  size after %d%s"):format(total, maxRoundMs, maxOpUs, s:size(), s.rebuilds and ("  rebuilds " .. s.rebuilds) or ""))
	end

	-- P8 mixed churn: 2k live one-shots; per update 50 delays U(0.1,2), 20 stops, 10 adjusts; 600 updates
	do
		rng(SEED)
		local s = Impl.new()
		local live = {}
		local function addOne()
			local h = s:delay(noop, 0.1 + math.random() * 1.9)
			live[#live + 1] = h
		end
		for _ = 1, 2000 do
			addOne()
		end
		local ms, kb = measure(function()
			for _ = 1, 600 do
				for _ = 1, 50 do
					addOne()
				end
				for _ = 1, 20 do
					local i = math.random(#live)
					local h = live[i]
					s:stop(h)
					live[i] = live[#live]
					live[#live] = nil
				end
				for _ = 1, 10 do
					local h = live[math.random(#live)]
					s:adjust(h, h.period * (0.5 + math.random()))
				end
				s:update(1 / 60)
				-- prune fired from live occasionally
				if #live > 4000 then
					local w = 0
					for i = 1, #live do
						local h = live[i]
						local st = h._state
						if st == nil then
							st = (h:getState() == "Pending") and PENDING or FIRED
						end
						if st == PENDING then
							w += 1
							live[w] = h
						end
					end
					for i = #live, w + 1, -1 do
						live[i] = nil
					end
				end
			end
		end, 3)
		rec(name, "P8 mixed churn 600 updates", ms, kb, ("size after %d"):format(s:size()))
		print(("  P8 mixed churn 600 updates: %.3f ms  (%.1f us/update)  alloc %.0f KB  size after %d"):format(ms, ms * 1e3 / 600, kb, s:size()))
	end
end

print("")
print("collectgarbage('collect') available:", pcall(collectgarbage, "collect"))

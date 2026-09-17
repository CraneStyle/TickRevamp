-- Faithful re-implementation of SyncedTimerClass core logic (reference/live/SyncedTimerClass.luau)
-- with an injectable clock so the numeric claims in the review can be executed under Lune.
-- Logic is copied line-for-line where it matters (AddEvent, _UpdateEventTime, ResetTimer,
-- _EvaluateAndSetNewTime, AdjustTime, ForceEventComplete, DeleteEvent, ProcessEvents, ProcessObj).
local MinHeap = require("../../../reference/live/MinHeap")

local NOOP = function() end
local guidCounter = 0
local function GUID() guidCounter += 1; return "GUID-" .. guidCounter end

local function count(t) local c = 0; for _ in pairs(t) do c += 1 end; return c end

local function newTimer()
	local self = {}
	local StoredClockRef = setmetatable({}, { __mode = "v" }) -- Lume.getWeakVariableTable()
	self.StoredClockRef = StoredClockRef
	self.MinHeapStorageList = MinHeap()
	self.now = 0
	function self:GetWorldTime() return self.now end
	function self:HasObject(Id) return StoredClockRef[Id] ~= nil end
	function self:GetRemainingTime(Id)
		if StoredClockRef[Id] == nil then return 0 end
		return math.max(StoredClockRef[Id].NextEventTime - self:GetWorldTime(), 0)
	end
	function self:AddEvent(LifeTime, func, Id, ...)
		if self:HasObject(Id) == true then return nil end
		Id = Id or GUID()
		local ClockData = { LifeTime = LifeTime, NextEventTime = self:GetWorldTime() + LifeTime, Id = Id, Func = func or NOOP, Data = { ... }, Remove = false, ForcedComplete = false }
		StoredClockRef[Id] = ClockData
		self.MinHeapStorageList:enqueue(StoredClockRef[Id], StoredClockRef[Id].NextEventTime)
		return Id
	end
	function self:_UpdateEventTime(v, Id)
		if self:HasObject(Id) == false then return false end
		StoredClockRef[Id].NextEventTime = self:GetWorldTime() + v
		return true
	end
	function self:ResetTimer(Id, timeToReset)
		if self:HasObject(Id) == false then return false end
		timeToReset = timeToReset or StoredClockRef[Id].LifeTime
		self:_UpdateEventTime(timeToReset, Id)
		self.MinHeapStorageList:update(StoredClockRef[Id], StoredClockRef[Id].NextEventTime)
		return true
	end
	function self:_EvaluateAndSetNewTime(Id, newTotalTime)
		local TimeDiff = StoredClockRef[Id].NextEventTime - self:GetWorldTime()
		local timeRatio = TimeDiff / StoredClockRef[Id].LifeTime
		return (timeRatio * newTotalTime) + (StoredClockRef[Id].NextEventTime - StoredClockRef[Id].LifeTime)
	end
	function self:AdjustTime(Id, newTotalTime)
		if self:HasObject(Id) == false then return false end
		StoredClockRef[Id].NextEventTime = self:_EvaluateAndSetNewTime(Id, newTotalTime)
		StoredClockRef[Id].LifeTime = newTotalTime
		self.MinHeapStorageList:update(StoredClockRef[Id], StoredClockRef[Id].NextEventTime)
		return true
	end
	function self:ForceEventComplete(Id)
		if self:HasObject(Id) == false then return false end
		StoredClockRef[Id].ForcedComplete = true
		return true
	end
	function self:DeleteEvent(Id)
		if self:HasObject(Id) == false then return false end
		self.MinHeapStorageList:remove(StoredClockRef[Id])
		StoredClockRef[Id] = nil
	end
	local function _isNextEventValidToProcess(currentTime)
		if self.MinHeapStorageList:isEmpty() == true then return false end
		local StoredData, Priority = self.MinHeapStorageList:peek()
		if StoredData.ForcedComplete then return true end
		if Priority > currentTime then return false end
		return true
	end
	self.maxIter = 1e6
	function self:ProcessEvents(currentTime)
		if count(StoredClockRef) <= 0 then return end
		if self.MinHeapStorageList:isEmpty() then return end
		local iters = 0
		while _isNextEventValidToProcess(currentTime) do
			iters += 1
			if iters > self.maxIter then error("runaway ProcessEvents loop after " .. iters .. " iterations") end
			self:ProcessObj()
		end
	end
	function self:ProcessObj()
		local EventItem = self.MinHeapStorageList:dequeue()
		if EventItem.Remove ~= false then return end
		EventItem.Remove = true
		EventItem.Func(table.unpack(EventItem.Data))
		self:DeleteEvent(EventItem.Id)
	end
	function self:step(t) self.now = t; self:ProcessEvents(t) end
	return self
end

local function section(s) print("\n== " .. s) end

-- 1. AdjustTime worked example: start=0, LifeTime=10, now=5, newTotal=20
section("S-adjust: start=0 LifeTime=10 now=5 newTotal=20")
do
	local T = newTimer()
	local fired
	T.now = 0
	T:AddEvent(10, function() fired = T.now end, "A")
	T.now = 5
	T:AdjustTime("A", 20)
	print("NextEventTime after adjust =", T.StoredClockRef.A.NextEventTime, " LifeTime =", T.StoredClockRef.A.LifeTime, " remaining =", T:GetRemainingTime("A"))
	for t = 5, 20 do T:step(t); if fired then break end end
	print("fired at t =", fired, " (legacy ratio-preserving would fire at 15; anchored-at-original-start gives 10)")
end

-- 1b. Adjust when the event started later: start=100, LifeTime=10, now=105, newTotal=20
section("S-adjust b: start=100 LifeTime=10 now=105 newTotal=20")
do
	local T = newTimer()
	T.now = 100
	T:AddEvent(10, nil, "A")
	T.now = 105
	T:AdjustTime("A", 20)
	print("NextEventTime =", T.StoredClockRef.A.NextEventTime, " (anchor 100 + 0.5*20 = 110; ratio-preserving = 115)")
end

-- 1c. Adjust after a ResetTimer (anchor drift): start=0 LifeTime=10; at now=5 ResetTimer(A) -> Next=15; at now=6 AdjustTime(A,20)
section("S-adjust c: after ResetTimer the anchor (Next-LifeTime) is the reset time, not start")
do
	local T = newTimer()
	T.now = 0
	T:AddEvent(10, nil, "A")
	T.now = 5
	T:ResetTimer("A")
	T.now = 6
	T:AdjustTime("A", 20)
	print("NextEventTime =", T.StoredClockRef.A.NextEventTime, " remaining =", T:GetRemainingTime("A"), " (remaining was 9 of 10 => ratio .9; anchored: 5+18=23 -> fires 17s from now; ratio-preserving: 6+18=24)")
end

-- 1d. Adjust after ResetTimer with a custom time: LifeTime=10, ResetTimer(A, 30) at now=5 -> Next=35, LifeTime still 10 -> anchor = 25, ratio = 30/10 = 3
section("S-adjust d: ResetTimer(A,30) keeps LifeTime=10 => ratio > 1 and anchor in the FUTURE")
do
	local T = newTimer()
	T.now = 0
	T:AddEvent(10, nil, "A")
	T.now = 5
	T:ResetTimer("A", 30)
	print("after reset: Next =", T.StoredClockRef.A.NextEventTime, " LifeTime =", T.StoredClockRef.A.LifeTime, " GetRemainingTime =", T:GetRemainingTime("A"))
	T:AdjustTime("A", 20)
	print("after adjust(20): Next =", T.StoredClockRef.A.NextEventTime, " remaining =", T:GetRemainingTime("A"), " (ratio 3.0 * 20 = 60 + anchor 25 = 85 -> 80 s from now)")
end

-- 1e. Adjust with LifeTime 0
section("S-adjust e: LifeTime=0 => ratio = 0/0 = NaN")
do
	local T = newTimer()
	T.now = 0
	T:AddEvent(0, nil, "A")
	T:AdjustTime("A", 5)
	print("Next =", T.StoredClockRef.A.NextEventTime, " NaN? ", T.StoredClockRef.A.NextEventTime ~= T.StoredClockRef.A.NextEventTime)
	-- NaN priority in the heap: comparisons with NaN are always false
	T:AddEvent(1, nil, "B")
	local fired = {}
	T.StoredClockRef.A.Func = function() table.insert(fired, "A") end
	T.StoredClockRef.B.Func = function() table.insert(fired, "B") end
	for t = 0, 10 do T:step(t) end
	print("fired:", table.concat(fired, ","), " heap size left:", T.MinHeapStorageList:size(), " (NaN-keyed item may block or be skipped)")
end

-- 2. ForceEventComplete deep in heap
section("S-force: forced item below the top does not fire until it reaches the top")
do
	local T = newTimer()
	local log = {}
	T.now = 0
	T:AddEvent(100, function() table.insert(log, "A@" .. T.now) end, "A")
	T:AddEvent(200, function() table.insert(log, "B@" .. T.now) end, "B")
	T.now = 5
	T:ForceEventComplete("B")
	T:step(5)
	print("after Force(B) at t=5 and a process pass:", table.concat(log, " "), "| heap size", T.MinHeapStorageList:size())
	for t = 6, 120 do T:step(t) end
	print("after stepping to t=120:", table.concat(log, " "), " (B fires only when A pops at t=100)")
end

-- 2b. Forced item at top fires even if not due, and forced item behind a DELETED top fires next pass
section("S-force b: forced item at top fires immediately; deleting the blocker releases it")
do
	local T = newTimer()
	local log = {}
	T.now = 0
	T:AddEvent(100, function() table.insert(log, "A@" .. T.now) end, "A")
	T:AddEvent(200, function() table.insert(log, "B@" .. T.now) end, "B")
	T.now = 5
	T:ForceEventComplete("B")
	T:step(5)
	T:DeleteEvent("A")
	T:step(6)
	print("Force(B)@5, Delete(A)@6 ->", table.concat(log, " "))
end

-- 2c. Force then Delete: DeleteEvent wins (callback never runs)
section("S-force c: ForceEventComplete then DeleteEvent before a process pass -> never fires")
do
	local T = newTimer()
	local log = {}
	T.now = 0
	T:AddEvent(100, function() table.insert(log, "A") end, "A")
	T:ForceEventComplete("A")
	T:DeleteEvent("A")
	T:step(1)
	print("log:", table.concat(log, ","), " (empty means force was discarded)")
end

-- 3. ResetTimer / AdjustTime from inside own callback: silently lost, returns true
section("S-reentry: ResetTimer inside own callback returns true but the item is gone")
do
	local T = newTimer()
	local fires = 0
	local rv
	T.now = 0
	T:AddEvent(1, function()
		fires += 1
		rv = T:ResetTimer("A")
	end, "A")
	for t = 0, 5 do T:step(t) end
	print("ResetTimer rv =", rv, " fires =", fires, " HasObject(A) =", T:HasObject("A"), " heap size =", T.MinHeapStorageList:size())
end

-- 3b. AddEvent with same Id from inside own callback -> nil (dedupe) because StoredClockRef still holds it
section("S-reentry b: AddEvent(same Id) inside own callback returns nil")
do
	local T = newTimer()
	local rv = "unset"
	T.now = 0
	T:AddEvent(1, function() rv = T:AddEvent(5, NOOP, "A") end, "A")
	for t = 0, 2 do T:step(t) end
	print("re-add rv =", rv, " HasObject(A) after pass =", T:HasObject("A"))
end

-- 3c. DeleteEvent from inside own callback -> fine (second DeleteEvent no-ops)
section("S-reentry c: DeleteEvent inside own callback")
do
	local T = newTimer()
	T.now = 0
	T:AddEvent(1, function() T:DeleteEvent("A") end, "A")
	local ok, err = pcall(function() for t = 0, 2 do T:step(t) end end)
	print("ok =", ok, err or "", " HasObject(A) =", T:HasObject("A"), " heap size =", T.MinHeapStorageList:size())
end

-- 4. Error inside callback: aborts the pass, leaves the item in StoredClockRef (weakly), later due events delayed
section("S-error: throwing callback aborts ProcessEvents; item stays in StoredClockRef until GC")
do
	local T = newTimer()
	local log = {}
	T.now = 0
	T:AddEvent(1, function() error("boom") end, "A")
	T:AddEvent(1, function() table.insert(log, "B@" .. T.now) end, "B")
	local ok, err = pcall(function() T:step(1) end)
	print("pass1 ok =", ok, " err =", tostring(err):sub(1, 40))
	print("after pass1: HasObject(A) =", T:HasObject("A"), " A.Remove =", T.StoredClockRef.A and T.StoredClockRef.A.Remove, " heap size =", T.MinHeapStorageList:size(), " GetRemainingTime(A) =", T:GetRemainingTime("A"))
	print("AddEvent(..., A) while stale =", T:AddEvent(5, NOOP, "A"))
	local ok2 = pcall(function() T:step(2) end)
	print("pass2 ok =", ok2, " log =", table.concat(log, ","), " (B fires one pass late)")
end

-- 5. AddEvent(LifeTime=0) re-adding itself inside callback -> runaway loop in the same pass
section("S-runaway: zero-LifeTime self-re-add loops inside one ProcessEvents pass")
do
	local T = newTimer()
	T.maxIter = 10000
	local n = 0
	local function readd()
		n += 1
		T:AddEvent(0, readd)
	end
	T.now = 0
	T:AddEvent(0, readd)
	local ok, err = pcall(function() T:step(0) end)
	print("ok =", ok, " iterations before guard =", n, " err =", tostring(err):sub(1, 60))
end

-- 6. Cost profile: _areClocksAvailableToProcess-style count vs heap peek at n=10000, 10 due
section("S-cost: per-frame cost with n=10000 clocks, 10 due")
do
	local T = newTimer()
	T.now = 0
	for i = 1, 10000 do T:AddEvent(1000 + i, NOOP) end
	for i = 1, 10 do T:AddEvent(1, NOOP) end
	local t0 = os.clock()
	for f = 1, 100 do count(T.StoredClockRef) end
	local t1 = os.clock()
	print(string.format("Lume.count-equivalent walk of 10010 entries: %.1f us/frame", (t1 - t0) / 100 * 1e6))
	local t2 = os.clock()
	T:step(1)
	local t3 = os.clock()
	print(string.format("ProcessEvents with 10 due of 10010: %.1f us (includes 10x O(n) DeleteEvent->remove indexof misses)", (t3 - t2) * 1e6))
	print("heap size after:", T.MinHeapStorageList:size())
	-- idle frame cost (nothing due): count walk + peek
	local t4 = os.clock()
	for f = 1, 100 do T:step(2) end
	local t5 = os.clock()
	print(string.format("idle ProcessEvents (0 due of 10000): %.1f us/frame", (t5 - t4) / 100 * 1e6))
end

-- 7. GetRemainingTime for an unknown Id returns 0 (indistinguishable from due-now)
section("S-remaining: unknown Id -> 0")
do
	local T = newTimer()
	print("GetRemainingTime(nope) =", T:GetRemainingTime("nope"))
end

-- 8. AddEvent(Id present) returns nil silently; caller storing the return overwrites its Id with nil
section("S-dedupe: AddEvent with an existing Id returns nil")
do
	local T = newTimer()
	T.now = 0
	print("first  =", T:AddEvent(5, NOOP, "X"))
	print("second =", T:AddEvent(5, NOOP, "X"))
end

-- 9. Weak-value StoredClockRef: after a callback error, is the stale entry collectable? (Lune exposes collectgarbage count only)
section("S-weak: stale entry after error is only weakly held")
do
	local T = newTimer()
	T.now = 0
	T:AddEvent(1, function() error("boom") end, "A")
	pcall(function() T:step(1) end)
	local before = T:HasObject("A")
	-- allocate garbage to encourage a GC cycle
	for i = 1, 200000 do local _ = { i } end
	local after = T:HasObject("A")
	print("HasObject(A) right after error =", before, " after allocating 200k tables =", after, " (false => weak entry was collected)")
end

--[[
	Third probe:
	- why a BaseClass SUBCLASS dispatches ~3.7x slower (function __index);
	- bytes/instance as a function of field count (Luau hash part is a power of 2);
	- cost of a constructor-table `static.new` override that still yields a real
	  BaseClass instance (metatable = __instanceDict, class + type set);
	- cost of a colon-vs-dot guard (getmetatable(self) == dict) per call.
]]

local BaseClass = require("../../../../../../../GitHub/BaseClass/src/core/BaseClass")
local clock = os.clock

local Root = BaseClass.class("P3Root")
function Root:initialize(v)
	self._Due = v
end
function Root:Add(b)
	return self._Due + b
end
local Sub = Root:subclass("P3Sub")
local SubSub = Sub:subclass("P3SubSub")

print("== subclass __index shape")
print("root    __instanceDict.__index type:", type(Root.__instanceDict.__index))
print("sub     __instanceDict.__index type:", type(Sub.__instanceDict.__index))
print("subsub  __instanceDict.__index type:", type(SubSub.__instanceDict.__index))
print("sub dict has own copy of Add (propagated):", rawget(Sub.__instanceDict, "Add") ~= nil)

local N = 10000000
local function bench(label, iters, fn)
	local best = math.huge
	for _ = 1, 3 do
		local t0 = clock()
		fn()
		local dt = clock() - t0
		if dt < best then best = dt end
	end
	print(string.format("%-56s %8.2f ns/op", label, best / iters * 1e9))
end

local r, s, ss = Root:new(1), Sub:new(1), SubSub:new(1)
print("\n== dispatch by depth, N =", N)
bench("root obj:Add()", N, function()
	local acc = 0
	for i = 1, N do
		acc = r:Add(i)
	end
end)
bench("sub obj:Add()  (function __index wrapper)", N, function()
	local acc = 0
	for i = 1, N do
		acc = s:Add(i)
	end
end)
bench("subsub obj:Add()  (wrapper -> wrapper)", N, function()
	local acc = 0
	for i = 1, N do
		acc = ss:Add(i)
	end
end)

-- Fix experiment: restore a table __index on the subclass dict (what a
-- middleclass-style `subclass` would do if it skipped copying __index).
Sub.__instanceDict.__index = Sub.__instanceDict
bench("sub obj:Add() after resetting dict.__index = dict", N, function()
	local acc = 0
	for i = 1, N do
		acc = s:Add(i)
	end
end)

------------------------------------------------------------------------
-- colon-vs-dot guard cost
------------------------------------------------------------------------
local dict = Root.__instanceDict
function Root:AddGuarded(b)
	if getmetatable(self) ~= dict then
		error("call with a colon: event:AddGuarded()")
	end
	return self._Due + b
end
print("\n== guard cost")
bench("root obj:AddGuarded()  (getmetatable(self) == dict)", N, function()
	local acc = 0
	for i = 1, N do
		acc = r:AddGuarded(i)
	end
end)
bench("root obj:Add()  (no guard)", N, function()
	local acc = 0
	for i = 1, N do
		acc = r:Add(i)
	end
end)

------------------------------------------------------------------------
-- constructor-table static.new override
------------------------------------------------------------------------
local Handle = BaseClass.class("P3Handle")
function Handle:initialize(fn, period, recur)
	self._Fn = fn
	self._Period = period
	self._Recur = recur
	self._State = "Pending"
	self._Due = 0
	self._Gen = 0
	self._Remaining = false
	self._Chained = false
	self._Scheduler = false
	self.Id = 0
end
function Handle:Add(b)
	return self._Due + b
end
local hdict = Handle.__instanceDict
local hname = Handle.name
local function fastNew(cls, fn, period, recur)
	return setmetatable({
		class = cls,
		type = hname,
		_Fn = fn,
		_Period = period,
		_Recur = recur,
		_State = "Pending",
		_Due = 0,
		_Gen = 0,
		_Remaining = false,
		_Chained = false,
		_Scheduler = false,
		Id = 0,
	}, hdict)
end
local noop = function() end
local M = 1000000
print("\n== construction, 10 user fields, M =", M)
bench("Handle:new(...)  allocate -> initialize -> tostring x2", M, function()
	local keep = table.create(M)
	for i = 1, M do
		keep[i] = Handle:new(noop, 1, false)
	end
end)
bench("fastNew: one constructor table + setmetatable(dict)", M, function()
	local keep = table.create(M)
	for i = 1, M do
		keep[i] = fastNew(Handle, noop, 1, false)
	end
end)
local fh = fastNew(Handle, noop, 1, false)
print("fastNew instance isInstanceOf(Handle):", fh:isInstanceOf(Handle), "| tostring:", tostring(fh), "| .type:", fh.type, "| :Add(1):", fh:Add(1))

------------------------------------------------------------------------
-- bytes per instance vs field count
------------------------------------------------------------------------
local K = 100000
local function measure(fields)
	local before = collectgarbage("count")
	local keep = table.create(K)
	for i = 1, K do
		local t = {}
		for f = 1, fields do
			t["f" .. f] = i
		end
		keep[i] = t
	end
	local after = collectgarbage("count")
	print(string.format("%2d fields -> %6.0f bytes/instance", fields, (after - before) * 1024 / K))
	return keep
end
print("\n== memory vs field count, K =", K, "(incremental insert; keys interned)")
local keeps = {}
for _, n in { 1, 2, 3, 4, 5, 7, 8, 9, 12, 16, 17 } do
	keeps[#keeps + 1] = measure(n)
end

-- Constructor-sized (all fields at once) vs incremental for the same count.
local function measureCtor(label, make)
	local before = collectgarbage("count")
	local keep = table.create(K)
	for i = 1, K do
		keep[i] = make(i)
	end
	local after = collectgarbage("count")
	print(string.format("%-40s %6.0f bytes/instance", label, (after - before) * 1024 / K))
	return keep
end
print("")
keeps[#keeps + 1] = measureCtor("12 fields via constructor (fastNew shape)", function(i)
	return fastNew(Handle, noop, i, false)
end)
keeps[#keeps + 1] = measureCtor("12 fields via Handle:new", function(i)
	return Handle:new(noop, i, false)
end)
print(#keeps)

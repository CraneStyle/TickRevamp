--[[
	Microbench: method-dispatch and allocation cost of BaseClass instances vs
	plain metatable tables vs local functions, under Lune 0.10.5 (interpreter,
	no --!native). Numbers are RELATIVE; Roblox native codegen shifts absolutes.
]]

-- Test once whether an absolute-path require works under Lune.
local absOk, absErr = pcall(require, "C:/Users/Faded/Documents/GitHub/BaseClass/src/core/BaseClass")
print("absolute-path require works:", absOk, absOk and "" or tostring(absErr):sub(1, 120))

-- scratch/baseclass-conventions -> scratch -> research -> TickRevamp -> STUDIO_TASKS
-- -> RbxProjects -> ClaudeProjects -> Documents (7 ups), then GitHub/BaseClass.
local BaseClass = require("../../../../../../../GitHub/BaseClass/src/core/BaseClass")

local clock = os.clock
local N = 10000000 -- 1e7

local function bench(label, fn)
	local best = math.huge
	for _ = 1, 3 do
		local t0 = clock()
		fn()
		local dt = clock() - t0
		if dt < best then best = dt end
	end
	print(string.format("%-46s %8.2f ns/op", label, best / N * 1e9))
	return best
end

------------------------------------------------------------------------
-- Subjects
------------------------------------------------------------------------
local function addLocal(a, b)
	return a + b
end

-- Plain ADT: table with metatable whose __index is the method table.
local Plain = {}
Plain.__index = Plain
function Plain.new(v)
	return setmetatable({ _Due = v, _Period = 1, _Recur = false, _State = "Pending", _Fn = addLocal }, Plain)
end
function Plain:Add(b)
	return self._Due + b
end

-- BaseClass instance (standalone core; same __instanceDict shape as live).
local BenchHandle = BaseClass.class("BenchHandle")
function BenchHandle:initialize(v)
	self._Due = v
	self._Period = 1
	self._Recur = false
	self._State = "Pending"
	self._Fn = addLocal
end
function BenchHandle:Add(b)
	return self._Due + b
end

-- Subclass one level deep (methods are propagated into the child's dict, so
-- lookup depth is still one hop; this confirms it).
local BenchSub = BenchHandle:subclass("BenchSub")

-- Function __index (the shape Stateful installs: closure that scans a
-- state stack then falls through to the dict).
local FnMethods = {}
function FnMethods:Add(b)
	return self._Due + b
end
local FnDict = {}
FnDict.__index = function(self, name)
	local stack = rawget(self, "__stateStack")
	if stack then
		for i = #stack, 1, -1 do
			if stack[i][name] then
				return stack[i][name]
			end
		end
	end
	return FnMethods[name]
end
local function fnNew(v)
	return setmetatable({ _Due = v, __stateStack = {} }, FnDict)
end

-- Method copied onto the instance itself (closure-per-object style).
local function copiedNew(v)
	return { _Due = v, Add = Plain.Add }
end

------------------------------------------------------------------------
-- Dispatch benches
------------------------------------------------------------------------
local plainObj = Plain.new(1)
local bcObj = BenchHandle:new(1)
local subObj = BenchSub:new(1)
local fnObj = fnNew(1)
local copiedObj = copiedNew(1)

print("\n== dispatch, N =", N)
local empty = bench("empty loop (baseline)", function()
	local acc = 0
	for i = 1, N do
		acc = acc + i
	end
end)

bench("local function call", function()
	local acc = 0
	for i = 1, N do
		acc = addLocal(acc, i)
	end
end)

bench("plain metatable  obj:Add()", function()
	local acc = 0
	for i = 1, N do
		acc = plainObj:Add(i)
	end
end)

bench("BaseClass instance  obj:Add()", function()
	local acc = 0
	for i = 1, N do
		acc = bcObj:Add(i)
	end
end)

bench("BaseClass subclass instance  obj:Add()", function()
	local acc = 0
	for i = 1, N do
		acc = subObj:Add(i)
	end
end)

bench("function __index (Stateful shape)  obj:Add()", function()
	local acc = 0
	for i = 1, N do
		acc = fnObj:Add(i)
	end
end)

bench("method copied on instance  obj:Add()", function()
	local acc = 0
	for i = 1, N do
		acc = copiedObj:Add(i)
	end
end)

bench("method hoisted: local f = Class.Add; f(obj)", function()
	local acc = 0
	local add = BenchHandle.Add
	for i = 1, N do
		acc = add(bcObj, i)
	end
end)

print("\n== field reads, N =", N)
bench("plain obj._Due (rawget hit)", function()
	local acc = 0
	for i = 1, N do
		acc = acc + plainObj._Due
	end
end)

bench("BaseClass obj._Due (rawget hit)", function()
	local acc = 0
	for i = 1, N do
		acc = acc + bcObj._Due
	end
end)

bench("BaseClass obj.Missing (miss -> __index hop)", function()
	local acc = 0
	for i = 1, N do
		if bcObj.Missing then
			acc = acc + 1
		end
	end
end)

bench("BaseClass obj.Add (method lookup, no call)", function()
	local acc = 0
	for i = 1, N do
		if bcObj.Add then
			acc = acc + 1
		end
	end
end)

------------------------------------------------------------------------
-- Allocation benches
------------------------------------------------------------------------
local M = 1000000 -- 1e6 allocations

local function benchAlloc(label, fn)
	local best = math.huge
	for _ = 1, 3 do
		-- (Lune/Luau: collectgarbage("collect") is not a valid option)
		local t0 = clock()
		fn()
		local dt = clock() - t0
		if dt < best then best = dt end
	end
	print(string.format("%-46s %8.1f ns/alloc", label, best / M * 1e9))
end

print("\n== allocation, M =", M)
benchAlloc("plain constructor + setmetatable (5 fields)", function()
	local keep = table.create(M)
	for i = 1, M do
		keep[i] = Plain.new(i)
	end
end)

benchAlloc("BaseClass Class:new (5 fields + class + type)", function()
	local keep = table.create(M)
	for i = 1, M do
		keep[i] = BenchHandle:new(i)
	end
end)

benchAlloc("BaseClass Class:allocate + fields (no type)", function()
	local keep = table.create(M)
	for i = 1, M do
		local h = BenchHandle:allocate()
		h._Due = i
		h._Period = 1
		h._Recur = false
		h._State = "Pending"
		h._Fn = addLocal
		keep[i] = h
	end
end)

benchAlloc("Class(...) via __call", function()
	local keep = table.create(M)
	for i = 1, M do
		keep[i] = BenchHandle(i)
	end
end)

benchAlloc("tostring(instance) alone", function()
	local s
	for i = 1, M do
		s = tostring(bcObj)
	end
end)

------------------------------------------------------------------------
-- Memory per instance (KB via collectgarbage("count"))
------------------------------------------------------------------------
local K = 100000
local function measure(label, make)
	-- no collect under Lune
	-- no collect under Lune
	local before = collectgarbage("count")
	local keep = table.create(K)
	for i = 1, K do
		keep[i] = make(i)
	end
	-- no collect under Lune
	local after = collectgarbage("count")
	print(string.format("%-46s %8.1f bytes/instance", label, (after - before) * 1024 / K))
	return keep
end

print("\n== memory, K =", K)
local keepA = measure("plain (5 fields)", Plain.new)
local keepB = measure("BaseClass:new (5 fields + class + type)", function(i)
	return BenchHandle:new(i)
end)
local keepC = measure("BaseClass:allocate + 5 fields (no type)", function(i)
	local h = BenchHandle:allocate()
	h._Due = i
	h._Period = 1
	h._Recur = false
	h._State = "Pending"
	h._Fn = addLocal
	return h
end)
local keepD = measure("plain (7 fields, class+type included)", function(i)
	return setmetatable({
		_Due = i,
		_Period = 1,
		_Recur = false,
		_State = "Pending",
		_Fn = addLocal,
		class = Plain,
		type = "Plain",
	}, Plain)
end)
print(#keepA, #keepB, #keepC, #keepD)

------------------------------------------------------------------------
-- Semantics spot-checks used by the report
------------------------------------------------------------------------
print("\n== semantics")
print("instance.type:", bcObj.type, "| tostring(inst):", tostring(bcObj), "| class:", tostring(bcObj.class))
print("rawget(inst,'Add') == nil:", rawget(bcObj, "Add") == nil)
print("getmetatable(inst) == Class.__instanceDict:", getmetatable(bcObj) == BenchHandle.__instanceDict)
print("dict.__index == dict:", BenchHandle.__instanceDict.__index == BenchHandle.__instanceDict)
print("Class.Add via static fallthrough:", BenchHandle.Add == BenchHandle.__instanceDict.Add)
print("sub isInstanceOf parent:", subObj:isInstanceOf(BenchHandle), "| parent isInstanceOf sub:", bcObj:isInstanceOf(BenchSub))
-- late method add propagates
function BenchHandle:Late()
	return "late"
end
print("late-added method reaches existing sub instance:", subObj:Late())
-- dot-call misuse
local ok, err = pcall(function() return BenchHandle.new(1) end)
print("Class.new(1) dot misuse ->", ok, tostring(err):sub(1, 80))
local ok2, err2 = pcall(function() return bcObj.Add(5) end)
print("inst.Add(5) dot misuse ->", ok2, tostring(err2):sub(1, 80))
-- duplicate name warning
BaseClass.setWarn(function(m) print("WARN SINK:", m) end)
BaseClass.class("BenchHandle")
BaseClass.setWarn(nil)

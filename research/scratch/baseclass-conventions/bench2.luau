--[[
	Second probe: the REAL house mixins (reference copies, which are pure Luau
	except Beholder) applied to the standalone BaseClass core under Lune.
	- Stateful: measured dispatch cost of its function __index.
	- Callbacks: proves it installs a fresh metatable per instance.
	- ObjectPool: pooled new/release cost vs a private free-list; prewarmPool bug.
]]

local BaseClass = require("../../../../../../../GitHub/BaseClass/src/core/BaseClass")
local Stateful = require("../../../reference/baseclass/Stateful")
local Callbacks = require("../../../reference/baseclass/Callbacks")
local Invoker = require("../../../reference/baseclass/Invoker")
local ObjectPool = require("../../../reference/baseclass/ObjectPool")

local clock = os.clock
local N = 10000000

local function bench(label, iters, fn)
	local best = math.huge
	for _ = 1, 3 do
		-- (Lune/Luau: collectgarbage("collect") is not a valid option)
		local t0 = clock()
		fn()
		local dt = clock() - t0
		if dt < best then best = dt end
	end
	print(string.format("%-52s %8.2f ns/op", label, best / iters * 1e9))
end

------------------------------------------------------------------------
-- Stateful dispatch cost (real mixin)
------------------------------------------------------------------------
local Plain = BaseClass.class("P2Plain")
function Plain:initialize(v)
	self._Due = v
end
function Plain:Add(b)
	return self._Due + b
end

local WithState = BaseClass.class("P2Stateful"):include(Stateful)
function WithState:initialize(v)
	self._Due = v
end
function WithState:Add(b)
	return self._Due + b
end
local Running = WithState:addState("Running")
function Running:Add(b)
	return self._Due + b + 1
end

local plainObj = Plain:new(1)
local stateObjNoState = WithState:new(1)
local stateObjInState = WithState:new(1)
stateObjInState:gotoState("Running")

print("== dispatch (real Stateful), N =", N)
bench("BaseClass plain obj:Add()", N, function()
	local acc = 0
	for i = 1, N do
		acc = plainObj:Add(i)
	end
end)
bench("BaseClass+Stateful, no state active, obj:Add()", N, function()
	local acc = 0
	for i = 1, N do
		acc = stateObjNoState:Add(i)
	end
end)
bench("BaseClass+Stateful, 1 state active, obj:Add()", N, function()
	local acc = 0
	for i = 1, N do
		acc = stateObjInState:Add(i)
	end
end)
print("Stateful __index is a function:", type(WithState.__instanceDict.__index))
print("Plain    __index is a table   :", type(Plain.__instanceDict.__index))

------------------------------------------------------------------------
-- Callbacks: per-instance metatable
------------------------------------------------------------------------
local WithCb = BaseClass.class("P2Callbacks"):include(Invoker, Callbacks)
function WithCb:initialize(v)
	self._Due = v
end
function WithCb:Add(b)
	return self._Due + b
end
local cbA = WithCb:new(1)
local cbB = WithCb:new(2)
print("\n== Callbacks")
print("Callbacks: two instances share a metatable:", getmetatable(cbA) == getmetatable(cbB))
print("Callbacks: metatable is the class __instanceDict:", getmetatable(cbA) == WithCb.__instanceDict)
print("Callbacks: __index type:", type(getmetatable(cbA).__index))
bench("BaseClass+Callbacks (no hooks registered) obj:Add()", N, function()
	local acc = 0
	for i = 1, N do
		acc = cbA:Add(i)
	end
end)

------------------------------------------------------------------------
-- ObjectPool: pooled new/release vs private free-list
------------------------------------------------------------------------
local Pooled = BaseClass.class("P2Pooled"):include(ObjectPool)
function Pooled:initialize(v)
	self._Due = v
end
function Pooled:reInitialize(v)
	self._Due = v
end
function Pooled:onRelease()
	self._Due = nil
end

local M = 1000000
print("\n== pooling, M =", M)
-- Steady-state: one object in the pool, take it, put it back.
local seed = Pooled:new(0)
seed:releaseToPool()
bench("ObjectPool  Class:new -> releaseToPool (steady)", M, function()
	for i = 1, M do
		local h = Pooled:new(i)
		h:releaseToPool()
	end
end)

-- Private free-list: array stack of plain handle tables.
local HandleMt = {}
HandleMt.__index = HandleMt
function HandleMt.Take(free, freeCount, v)
	local h
	if freeCount > 0 then
		h = free[freeCount]
		free[freeCount] = nil
		freeCount -= 1
		h._Due = v
	else
		h = setmetatable({ _Due = v }, HandleMt)
	end
	return h, freeCount
end
local free = {}
local freeCount = 0
local h0 = setmetatable({ _Due = 0 }, HandleMt)
free[1] = h0
freeCount = 1
bench("free-list  pop -> reinit -> push (steady)", M, function()
	local fc = freeCount
	for i = 1, M do
		local h
		h, fc = HandleMt.Take(free, fc, i)
		h._Due = nil
		fc += 1
		free[fc] = h
	end
	freeCount = fc
end)
bench("free-list inline (no helper call)", M, function()
	local fc = freeCount
	for i = 1, M do
		local h = free[fc]
		free[fc] = nil
		fc -= 1
		h._Due = i
		h._Due = nil
		fc += 1
		free[fc] = h
	end
	freeCount = fc
end)
bench("no pool: fresh setmetatable({...}) each time", M, function()
	for i = 1, M do
		local h = setmetatable({ _Due = i }, HandleMt)
	end
end)

print("pool stats:", Pooled:getPoolStats().available, Pooled:getPoolStats().total)
print("pooled new() skips initialize, calls reInitialize:", Pooled:new(7)._Due == 7)

-- prewarmPool on a root class
local ok, err = pcall(function()
	Pooled:prewarmPool(4)
end)
print("prewarmPool(4) on root class ->", ok, tostring(err):sub(1, 100))

-- prewarmPool on a subclass
local PooledChild = Pooled:subclass("P2PooledChild")
local ok2, err2 = pcall(function()
	PooledChild:prewarmPool(4)
end)
print("prewarmPool(4) on subclass ->", ok2, tostring(err2):sub(1, 100))
print("subclass pool stats after prewarm attempt:", PooledChild:getPoolStats().available, PooledChild:getPoolStats().total)
print("parent  pool stats after prewarm attempt:", Pooled:getPoolStats().available, Pooled:getPoolStats().total)

-- maxPoolSize exhaustion returns nil
local Capped = BaseClass.class("P2Capped"):include(ObjectPool)
Capped.static.maxPoolSize = 1
function Capped:reInitialize() end
function Capped:onRelease() end
local c1 = Capped:new()
local c2 = Capped:new()
print("maxPoolSize=1: second new() returns:", c2)

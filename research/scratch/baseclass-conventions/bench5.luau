-- Recycled handle: free-list pop + :initialize (10 fields) vs fresh construction.
local BaseClass = require("../../../../../../../GitHub/BaseClass/src/core/BaseClass")
local clock = os.clock
local M = 1000000
local function bench(label, fn)
	local best = math.huge
	for _ = 1, 3 do
		local t0 = clock()
		fn()
		local dt = clock() - t0
		if dt < best then best = dt end
	end
	print(string.format("%-58s %8.1f ns/op", label, best / M * 1e9))
end
local Handle = BaseClass.class("P5Handle")
function Handle:initialize(scheduler, fn, period, isRecurring)
	self._Scheduler = scheduler
	self._Fn = fn
	self._Period = period
	self._Recur = isRecurring
	self._State = "Pending"
	self._Due = 0
	self._Gen = 0
	self._Remaining = false
	self._Chained = false
	self.Id = 0
end
local dict, name = Handle.__instanceDict, Handle.name
local noop = function() end
local sched = {}
local free, freeCount = {}, 0
-- seed one
local seed = Handle:new(sched, noop, 1, false)
free[1] = seed
freeCount = 1
local init = Handle.initialize
bench("recycle: pop free-list -> h:initialize(10 fields) -> push", function()
	local fc = freeCount
	for i = 1, M do
		local h = free[fc]
		free[fc] = nil
		fc -= 1
		h:initialize(sched, noop, i, false)
		fc += 1
		free[fc] = h
	end
	freeCount = fc
end)
bench("recycle: same, hoisted init(h, ...) + table.clear first", function()
	local fc = freeCount
	for i = 1, M do
		local h = free[fc]
		free[fc] = nil
		fc -= 1
		table.clear(h)
		h.class = Handle
		h.type = name
		init(h, sched, noop, i, false)
		fc += 1
		free[fc] = h
	end
	freeCount = fc
end)
bench("fresh: constructor table + setmetatable(dict) (12 fields)", function()
	for i = 1, M do
		local h = setmetatable({
			class = Handle, type = name, _Scheduler = sched, _Fn = noop, _Period = i,
			_Recur = false, _State = "Pending", _Due = 0, _Gen = 0, _Remaining = false,
			_Chained = false, Id = 0,
		}, dict)
	end
end)
bench("fresh: Handle:new(...)", function()
	for i = 1, M do
		local h = Handle:new(sched, noop, i, false)
	end
end)
print("recycled handle still a BaseClass instance:", seed:isInstanceOf(Handle), seed.type)

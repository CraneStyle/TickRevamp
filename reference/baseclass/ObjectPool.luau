local AutoObjectPool = {
--[[
When we include this into a class it creates a static class that automatically manages 
object pooling objects of this class type. 
Note, that if this is inherited each respective child would have it's own pool available. And used.

Further explination, the idea here, is that when a new class is called by the factory it will 
return a pooled version of the class instead of creating a new one. 

--[[NOTES
TODO This will get used for Actions in the future as it will be more effectient 
TODO In any cases where we have well reusable objects we will want to consider this implementation 
over other ones as this is more systematic
]]
--]]
}

local ObjectPool = {
	static = {
		-- Static pool configuration
		maxPoolSize = nil,  -- Default to unlimited pool size
		initialPoolSize = 0     -- Default initial pool size
	}
}
---------------------------------------------------------------------------------------------------------------
---------------------------------------------------------------------------------------------------------------
--[[
This is a fast stack implementation 
]]

local Queue = {}

do
	Queue.__index = Queue

	function Queue.new(preAllocate)
		preAllocate = preAllocate or 16
		return setmetatable({
			_buffer = table.create(preAllocate), -- Pre-allocate initial capacity
			_head = 1,
			_tail = 1,
			_size = 0,
			_capacity = preAllocate
		}, Queue)
	end

	-- Double the buffer size when needed
	function Queue:_resize()
		local newCapacity = self._capacity * 2
		local newBuffer = table.create(newCapacity)

		-- Copy elements to new buffer, realigning to start at index 1
		for i = 1, self._size do
			local idx = (self._head + i - 2) % self._capacity + 1
			newBuffer[i] = self._buffer[idx]
		end

		self._buffer = newBuffer
		self._capacity = newCapacity
		self._head = 1
		self._tail = self._size + 1
	end

	function Queue:enqueue(value: any)
		if self._size >= self._capacity then
			self:_resize()
		end

		self._buffer[self._tail] = value
		self._tail = (self._tail % self._capacity) + 1
		self._size += 1
	end

	function Queue:dequeue(): any?
		if self._size == 0 then
			return nil
		end

		local value = self._buffer[self._head]
		self._buffer[self._head] = nil -- Allow garbage collection
		self._head = (self._head % self._capacity) + 1
		self._size -= 1		

		return value
	end

	function Queue:peek(): any?
		if self._size == 0 then
			return nil
		end
		return self._buffer[self._head]
	end

	function Queue:isEmpty(): boolean
		return self._size == 0
	end

	function Queue:size(): number
		return self._size
	end

	function Queue:clear()
		table.clear(self._buffer)
		self._head = 1
		self._tail = 1
		self._size = 0
	end
	
end
---------------------------------------------------------------------------------------------------------------
---------------------------------------------------------------------------------------------------------------



----------------------------------------------------------------------------------------------------
--Private Functions
----------------------------------------------------------------------------------------------------

-- Internal function to create a new pool for a class
local function _createPool(theClass)
	if not theClass.static._objectPool then
		theClass.static._objectPool = {
			available = Queue.new(),
			count = 0
		}
	end
end

-- Internal function to get an object from pool or create new if needed
local function _getFromPool(theClass, ...)
	local pool = theClass.static._objectPool

	if pool.available:size() > 0 then
		local instance = pool.available:dequeue()  --table.remove(pool.available)
		--reInitilize must be implemented on an object that is useing the Object Pool Include helper
		--ObjectPool:reInitialize(...) end 
		instance:reInitialize(...)
		return instance
	end
	
	return nil
end

----------------------------------------------------------------------------------------------------
--Public Functions
----------------------------------------------------------------------------------------------------

--[[
Checks to see if any conditions exsist that require us to add to available 
vs removing a count.
]]
local function _expandPoolCheck(maxSize, class)
	
	if maxSize == nil then
		return true
	elseif maxSize == 0 then 
		return true
	elseif class.static._objectPool.available:size() < maxSize then
		return true
	end

	return false	
end


--[[
-- Default onRelease implementation - can be overridden by classes
-- Default implementation does nothing
-- Classes should override this to properly clean up their instances
]]
function ObjectPool:onRelease()  warn( "Not over written?") end

-- Function to release an object back to its pool
function ObjectPool:releaseToPool()
	
	local class = self.class
	
	if not class.static._objectPool then return end
	
	self:onRelease()

	-- Add to pool if unlimited or haven't hit max size
	local maxSize = class.static.maxPoolSize
	
	if _expandPoolCheck(maxSize, class) then
		class.static._objectPool.available:enqueue(self)
	else
		class.static._objectPool.count = class.static._objectPool.count - 1
	end	
end


--[[
This needs to be called when we need the object to be reinitilized for use 
this NEEDS to be overwritten
THIS HAS TO BE HERE but we are not implementing it here so it throws an Error
]]
--function ObjectPool:reInitialize(...) end

-- Function to prewarm the pool with initial objects
-- This needs to be re reviewed not correctly SET UP
function ObjectPool.static:prewarmPool(size)
	size = size or self.static.initialPoolSize
	if size <= 0 then return end

	_createPool(self)
	local pool = self.static._objectPool
	local maxSize = self.static.maxPoolSize

	-- If maxSize is nil or 0, use the requested size
	-- Otherwise, limit to maxSize
	local targetSize = maxSize and maxSize > 0 and math.min(size, maxSize) or size

	for i = 1, targetSize do
		local instance = self.super.new(self)
		
		self.static._objectPool.available:enqueue(instance)
		--table.insert(pool.available, instance)
		pool.count = pool.count + 1
	end
end

-- Function to get current pool stats
function ObjectPool.static:getPoolStats()
	
	if not self.static._objectPool then
		return {
			available = 0, 
			total = 0, 
			maxSize = self.static.maxPoolSize
		}
	end

	return {
		available = self.static._objectPool.available:size(),
		total = self.static._objectPool.count,
		maxSize = self.static.maxPoolSize
	}
end

----------------------------------------------------------------------------------------------------
--Allocation And Patching the Instance Safely
----------------------------------------------------------------------------------------------------
----------------------------------------------------------------------------------------------------

--[[
TODO
]]
local function _modifyAllocateMethod(theClass)
	local oldAllocateFn = theClass.static.allocate

	theClass.static.allocate = function(self, ...)
		local instance = oldAllocateFn(self, ...)
		return instance
	end
end


--[[
Checks to see if any conditions exsist that require us to add to available 
vs removing a count.
]]
local function _checkForPoolSizeRestriction(maxSize, pool)

	if maxSize == nil then
		return true
	elseif maxSize == 0 then 
		return true
	elseif  pool.count < maxSize then
		return true
	end

	return false	
end

--[[
This is how we overwrite the original new so that we prioritize to the pool before creating new ones
]]
local function _modifyNewMethod(theClass)
	local oldNewFn = theClass.static.new

	theClass.static.new = function(self, ...)
		_createPool(self)

		--Try to get from pool first
		local instance = _getFromPool(self, ...)
		if instance then return instance end
		
		-- If no pooled object available, create new one		
		-- If pool is empty and either unlimited or haven't hit max size, create new instance
		local maxSize = theClass.static.maxPoolSize
		local pool = theClass.static._objectPool
		
		if _checkForPoolSizeRestriction(maxSize, pool) then
			pool.count = pool.count + 1

			return oldNewFn(theClass, ...)
		end
		
		warn("This Pool: ", theClass ," Has a max Size of: ", maxSize, "Currently: ", pool.count)
		
		return nil 
	end
	
end

--[[
TODO
]]
local function _modifySubclassMethod(theClass)
	local prevSubclass = theClass.subclass
	theClass.subclass = function(self, name, ...)
		local theSubClass = prevSubclass(self, name, ...)
		_modifyAllocateMethod(theSubClass)
		_modifyNewMethod(theSubClass)
		return theSubClass
	end
end

--[[
TODO
]]
function ObjectPool:included(theClass)
	_modifyAllocateMethod(theClass)
	_modifyNewMethod(theClass)
	_modifySubclassMethod(theClass)
end

return ObjectPool
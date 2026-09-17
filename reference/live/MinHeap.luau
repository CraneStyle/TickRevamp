local BinaryMinHeap = {
	--[[
		Implementation of a Binary Priority based Min heap
		- This is a self sorting structure 
		- the lowest value passed in will be bubbled to the top and ordered
	--]]
	--[[NOTES
	
	--]]
}
local BinaryMinHeapMt = nil

local floor, setmetatable = math.floor, setmetatable
--------------------------------------------------------------------------------

--[[
Sort bubble up
]]
local function siftup( items, priorities, from )
	local index = from
	local parentIndex = floor( 0.5 * index )
	while index > 1 and priorities[parentIndex] > priorities[index] do
		priorities[index], priorities[parentIndex] = priorities[parentIndex], priorities[index]
		items[index], items[parentIndex] = items[parentIndex], items[index]
		
		index = parentIndex
		parentIndex = floor( 0.5 * index )
	end
	return index
end

--[[
Sort Bubble down
]]
local function siftdown( items, priorities, size, limit )
	for index = limit, 1, -1 do
		local leftIndex = index + index
		local rightIndex = leftIndex + 1
		while leftIndex <= size do
			local smallerChild = leftIndex
			if rightIndex <= size and priorities[leftIndex] > priorities[rightIndex] then
				smallerChild = rightIndex
			end
			
			if priorities[index] > priorities[smallerChild] then
				items[index], items[smallerChild] = items[smallerChild], items[index]
				priorities[index], priorities[smallerChild] = priorities[smallerChild], priorities[index]
				
			else
				break
			end
			
			index = smallerChild
			leftIndex = index + index
			rightIndex = leftIndex + 1
		end
	end
end
--------------------------------------------------------------------------------

--[[ Public Access direct Function
Will create a new stack object or pull one from the pool
]]
function BinaryMinHeap.new( iparray_ )
	local self = setmetatable( {
		_items = {},
		_priorities = {},
		_size = 0,
	}, BinaryMinHeapMt )
	
	
	if iparray_ then
		self:batchenq( iparray_ )
	end
	
	return self
end

--[[
returns the index of an item
]]
local function indexof( items, item )
	for i = 1, #items do
		if items[i] == item then
			return i
		end
	end
end
--------------------------------------------------------------------------------
-- Object Mini Class Functions
--------------------------------------------------------------------------------

--[[
Adds item to the heap
]]
function BinaryMinHeap:enqueue( item, priority )
	local items, priorities = self._items, self._priorities
	
	local size = self._size + 1
	self._size = size	
	items[size], priorities[size] = item, priority
	siftup( items, priorities, size ) 
	return self
end

--[[
remove the current top of the heap
]]
function BinaryMinHeap:dequeue()
	local size = self._size

	assert( size > 0, 'Heap is empty' )

	local items, priorities = self._items, self._priorities
	local item, priority = items[1], priorities[1]


	if size > 1 then
		local newitem = items[size]
		items[1], priorities[1] = newitem, priorities[size]
		items[size], priorities[size] = nil, nil

		size = size - 1
		self._size = size
		siftdown( items, priorities, size, 1 )
	else
		items[1], priorities[1] = nil, nil
		self._size = 0
	end

	return item, priority
end

--[[
gets our top item and returns what it's priority is
]]
function BinaryMinHeap:peek()
	return self._items[1], self._priorities[1]
end

--[[
Lets us change the priority of the time
]]
function BinaryMinHeap:update( item, priority )
	local ok = self:remove( item )
	if ok then
		self:enqueue( item, priority )
		return true
	else
		return false
	end
end

--[[
Returns if the item is in the heap
]]
function BinaryMinHeap:contains( item )
	return indexof( self._items, item ) ~= nil
end

--[[
Returns the current priority of Item
]]
function BinaryMinHeap:getPriorityByItem( item )
	local index = indexof( self._items, item )
	return self._priorities[index]
end

--[[
returns the current size of the heap
]]
function BinaryMinHeap:size()
	return self._size
end

--[[
Lets us know if we are empty 
]]
function BinaryMinHeap:isEmpty()
	return self._size <= 0
end

--[[
Returns the type of ADT we are
]]
function BinaryMinHeap:myType()
	return "minHeap"
end

--[[
Deques all values until the Min heap is empty
]]
function BinaryMinHeap:dump()
	local dumpPoint = nil
	while not self:isEmpty() do
		dumpPoint = self:dequeue()
	end
end

--[[
Finds the item in the heap and removes it
]]
function BinaryMinHeap:remove( item )
	local index = indexof( self._items, item )
	if index ~= nil then
		local size = self._size
		local items, priorities = self._items, self._priorities

		if size == index then
			items[size], priorities[size] = nil, nil
			self._size = size - 1
		else
			local lastitem = items[size]
			items[index], priorities[index] = items[size], priorities[size]
			items[size], priorities[size] = nil, nil

			size = size - 1
			self._size = size
			if size > 1 then
				local siftedindex = siftup( items, priorities, index )
				siftdown( items, priorities, size, siftedindex ) 
			end
		end
		return true
	else
		return false
	end
end
--------------------------------------------------------------------------------

--[[
PAss in an indexed pairs array like this is structured as a set of 2s
]]
function BinaryMinHeap:batchenq( iparray )
	iparray = iparray or {}
	local items, priorities = self._items, self._priorities
	local size = self._size
	for i = 1, #iparray, 2 do
		local item, priority = iparray[i], iparray[i+1]
		
		size = size + 1
		items[size], priorities[size] = item, priority
		
	end
	self._size = size
	if size > 1 then
		siftdown( items, priorities, size, floor( 0.5 * size ) )
	end
end
--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
BinaryMinHeapMt = {
	__index = BinaryMinHeap,
	__len = BinaryMinHeap.len,
}

return setmetatable( BinaryMinHeap, {
	__call = function( _, ... )
		return BinaryMinHeap.new( ... )
	end
} )
--------------------------------------------------------------------------------
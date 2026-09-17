local SyncedTimerClass = {
--[[Singleton Pattern
This is a timer that is used and more approperatly syncronizes wwith the real view of the client it best can. 
This takes into account lag and such, and we use it especially on things we want to make sure happen at the same time 
with minimal communication.   

A good example is cool downs.

The system is fairly effeciant and I am turnt it into a calss to make it more comprehensable
but also to take the time to make more stable and cleaner where able.
]]
	
--[[ NOTES!!!!
	--TODO investigate Deeper later look into adding a pool for data tables 
	if we see any issues or slight consumption time of timers quickly or anything
	of the like, would like to know why it was having isses. But Not required
]]
}
------------------------------------------------------------------------------------------
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local RBX_Utility = require(game.ReplicatedStorage.SharedModules.RBXUtility)
local TickAPI = require(game.ReplicatedStorage.SharedModules.TickAPI)

local BaseClass = require(game.ReplicatedStorage.SharedModules.BaseClass)
local Stateful = require(game.ReplicatedStorage.SharedModules.BaseClass.HelperIncludes.Stateful)

local LumeType = require(game.ReplicatedStorage.SharedModules.Lume.Type)
local Lume: LumeType.BaseLume = require(game.ReplicatedStorage.SharedModules.Lume)

local MediatorAPI = require(game.ReplicatedStorage.SharedModules.MediatorAPI)
local RouterPaths = require(game.ReplicatedStorage.SharedModules.MediatorAPI.RouterPaths)

local MinHeapFabricator = require(game.ReplicatedStorage.SharedModules.DataFoundery.ADTs.MinHeap)

------------------------------------------------------------------------------------------
local SyncedTimer = BaseClass.class("SyncedTimer"):include(Stateful)
------------------------------------------------------------------------------------------
local SyncedTimerClient = SyncedTimer:addState("SyncedTimerClient")
local SyncedTimerServer = SyncedTimer:addState("SyncedTimerServer")
------------------------------------------------------------------------------------------
local isServer = RunService:IsServer()

SyncedTimerClass.SingltonStore = nil

--SyncedTimerClass.StoredClockIdRef = {} 
local StoredClockRef = Lume.getWeakVariableTable()

local NOOP = function() end

local WorldTime = game.Workspace.Terrain.WorldTime
------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------

--[[Helper
TODO
-- LifeTime
-- Time
-- function
-- id
]]
local function _createClockData(LifeTime, NextEventTime, Id, func, Data)
	return {
		LifeTime = LifeTime,
		NextEventTime = NextEventTime, 
		Id = Id,
		Func = func or NOOP, 
		Data = Data, -- Optional
		Remove = false, -- This exsist to prepare for the future to have "recuring type events"
		ForcedComplete = false
	}
end

--[[ DEBUG FUNCTION
Past ths in initilization when we want to do oil Dips  
]]
local function _debugStorageTracking(self)
	--DEBUG	
	TickAPI.Tickh.recur(
		function()
			warn("---DEBUG")				
			warn("StoredClocks: ", Lume.count(StoredClockRef), " // MinHeap: ", self.MinHeapStorageList:size())				
			warn("---")
		end,
		3
	)	
end

------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------

------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------

--[[
TODO
]]
function SyncedTimer:initialize()
	
	SyncedTimerClass.SingltonStore = self
	self.MinHeapStorageList = MinHeapFabricator()
	--
	if isServer then 
		
		self:gotoState("SyncedTimerServer")
		
	else
		
		self:gotoState("SyncedTimerClient")		
		self.LocalSyncTime = require(game.ReplicatedFirst.LocalOnly.Modules.SyncTime) 
				
	end
	--	
	self:SetUpProcessing()
end
------------------------------------------------------------------------------------------

--[[
I looked, the book says I win every game
reguardless.....E.N.D....O.F.....Everything
]]
function SyncedTimer:HasObject(Id)
	return StoredClockRef[Id] ~= nil
end

--[[
TODO
]]
function SyncedTimer:GetRemainingTime(Id)
	-- Predicate
	if StoredClockRef[Id] ==nil then return 0 end

	return Lume.minCap(
		StoredClockRef[Id].NextEventTime - self:GetWorldTime(), 
		0
	) 	
end

--[[
TODO
]]
function SyncedTimerClient:GetWorldTime() return self.LocalSyncTime.GetTime() end

--[[
TODO
]]
function SyncedTimerServer:GetWorldTime() return  WorldTime.Value end

------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------
--[[PRIVATE
TODO
]]
function SyncedTimer:_GetNextWorldTime(LifeTime)
	return self:GetWorldTime() + LifeTime
end

--[[
	This is where we add an object of a delayed event or just an id into 
	the timeline
	
	we return the id so we can go look at the object if we want too
	
	if we return NIL that means the ID was alreayd present and we cant add a new one
	TODO -> Consider if we want to do more cleaning here or not 
]]
function SyncedTimer:AddEvent(LifeTime, func, Id, ...)

	if self:HasObject(Id) == true then return nil end		
	
	Id = Id or HttpService:GenerateGUID()		
		
	local ClockData = _createClockData(
		LifeTime,
		self:_GetNextWorldTime(LifeTime), 
		Id,
		func, 
		{...}
	)
		
	SyncedTimer.AddToIdStorage(ClockData)

	-- Then we use core storage ref into the enqueue as this represents
	-- a Pointer TOO the Stored Clock Ref data. 
	-- This is just done so we that we have a clear understanding of where this is 
	-- hard stored in memory
	self.MinHeapStorageList:enqueue(
		StoredClockRef[Id], 
		StoredClockRef[Id].NextEventTime
	)	
	
	return Id	
end 
------------------------------------------------------------------------------------------

--[[PRIVATE
-- timeToReset is literal, it is the time we are going to reset by aka 
"Could you reset the alarm for 10 more minutes"
]]
function SyncedTimer:_UpdateEventTime(timeAdjustmentByValue, Id)
	--Predicate
	if self:HasObject(Id) == false then return false end	
	
	StoredClockRef[Id].NextEventTime =  self:GetWorldTime() + timeAdjustmentByValue
		
	return true
end
------------------------------------------------------------------------------------------

--[[
This automagically forces the timer to reset its position on the time by its current lifetime
]]
function SyncedTimer:ResetTimer(Id, timeToReset)
	-- If we dont have the object we can stop
	if self:HasObject(Id) == false then return false end	

	timeToReset = timeToReset or StoredClockRef[Id].LifeTime
	
	self:_UpdateEventTime(timeToReset, Id)
	
	self.MinHeapStorageList:update(
		StoredClockRef[Id], 
		StoredClockRef[Id].NextEventTime
	)
	
	return true
end
------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------

--[[
Gets oour orignal amount of time left in our event
]]
local function _getOriginalWorldTimeValue(self, Id)
	return  StoredClockRef[Id].NextEventTime  - StoredClockRef[Id].LifeTime
end

--[[Private
This does an evaluation that allows us to pass in the New total time that we want 
for the value, and this will automatically adjusted take into effect current time
]]
function SyncedTimer:_EvaluateAndSetNewTime(Id, newTotalTime)
	
	local TimeDiff = StoredClockRef[Id].NextEventTime - self:GetWorldTime()

	local timeRatio= TimeDiff / StoredClockRef[Id].LifeTime
	
	return (timeRatio * newTotalTime)  + _getOriginalWorldTimeValue(self, Id)
end

--[[
TAkes in the Id of the event, we give a new total time and adjusts taking in current time values 
to a new value scalled to that
]]
function SyncedTimer:AdjustTime(Id, newTotalTime)
	-- Predicate
	if self:HasObject(Id) == false then return false end		
	
	StoredClockRef[Id].NextEventTime = self:_EvaluateAndSetNewTime(Id, newTotalTime)
	
	-- This is set after evaluation as we need the core Lifetime to process the ratio change
	StoredClockRef[Id].LifeTime = newTotalTime
	
	self.MinHeapStorageList:update(
		StoredClockRef[Id], 
		StoredClockRef[Id].NextEventTime
	)
	
	return true
end
------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------

--[[Private
TODO
	--StoredClockRef[Id].NextEventTime = self.LocalSyncTime.GetTime()
]]
function SyncedTimerClient:_SetEventTimeToCurrentTime(Id)
	StoredClockRef[Id].ForcedComplete = true
end

--[[Private
TODO
--StoredClockRef[Id].NextEventTime = WorldTime.Value
]]
function SyncedTimerServer:_SetEventTimeToCurrentTime(Id)
	StoredClockRef[Id].ForcedComplete = true
end

--[[
This forces an event to set its time to current time, so it will either 
occur immmedantly if this happened before the processing cycle this run 
or it will happen on the next process cycle and clean up
]]
-- To have it removed without any activation forceably
function SyncedTimer:ForceEventComplete(Id)
	-- Predicate
	if self:HasObject(Id) == false then return false end	

	self:_SetEventTimeToCurrentTime(Id)
		
	return true
end

--[[
This should Remove the EventItem From the Timeline and not cause the event 
to happen
]]
function SyncedTimer:DeleteEvent(Id)
	-- Predicate
	if self:HasObject(Id) == false then return false end
	self.MinHeapStorageList:remove(StoredClockRef[Id])		
	SyncedTimer.RemoveFromIdStorage(Id)
end
------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------

--[[
Checks to ensure and validate that the next Event in the minHeaps 
time is not greater then current. Since the list will eb stacked lowest to highest
once we hit higher, anything below that value shouldnt be processed and we 
can top there
]]
local function _isNextEventValidToProcess(self, currentTime)
	--Predicate
	if self.MinHeapStorageList:isEmpty() == true then return false end
	
	local StoredData, Priority = self.MinHeapStorageList:peek()
	
	if StoredData.ForcedComplete then return true end
	
	if Priority > currentTime then return false end
	
	return true
end

--[[
TODO
]]
local function _areClocksAvailableToProcess(self)
	
	local storageRefIsEmpty =  (Lume.count(StoredClockRef) <= 0)
	local minHeapIsEmpty = self.MinHeapStorageList:isEmpty() 
		
	if storageRefIsEmpty == true then return false end
	if minHeapIsEmpty == true then return false	end
	
	return true	
end

--[[
	This is where our server time is being run on
]]
function SyncedTimer:ProcessEvents(currentTime, dt)
	-- Predicate
	if _areClocksAvailableToProcess(self) == false then return end
	
	while _isNextEventValidToProcess(self, currentTime) do
		self:ProcessObj()
	end
end

--[[
This is where we ensure that we do everything we should for processing 
the event
]]
function SyncedTimer:ProcessObj()
	
	local EventItem, EventPriority = self.MinHeapStorageList:dequeue()
		
	-- predicate
	if EventItem.Remove ~= false then return end 
	EventItem.Remove = true

	EventItem.Func(table.unpack(EventItem.Data)) 
	
	self:DeleteEvent(EventItem.Id)
end
------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------

--[[
TODO
]]
function SyncedTimer.static.AddToIdStorage(clockData)
	StoredClockRef[clockData.Id] = clockData
end

--[[
TODO
]]
function SyncedTimer.static.RemoveFromIdStorage(Id)
	if StoredClockRef[Id] == nil then return end
	StoredClockRef[Id] = nil
end

--[[
TODO
]]
function SyncedTimer.static.GetItemFromStorage(Id)
	if StoredClockRef[Id] == nil then return nil end
	return StoredClockRef[Id]
end

------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------

--[[
Hooks up our update Point
]]
function SyncedTimerClient:SetUpProcessing()
	self.LocalSyncTime.ConnectFunctionToSyncTime(
		function(currentTime, dt)
			self:ProcessEvents(currentTime, dt)
		end
	)
end

--[[
Hooks Up to our Update Point
]]
function SyncedTimerServer:SetUpProcessing()
	RunService.Stepped:Connect(
		function(currentTime, dt)
			self:ProcessEvents(currentTime, dt)
		end
	)
end

return SyncedTimer:new()

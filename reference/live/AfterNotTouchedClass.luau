local AfterNotTouchedClass = {
--[[ 
This is a manager for a clock that will reset every time its touched and clean itself up 
once it has processed
--]]	
}
----------------------------------------------------------------------------------------------------

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SharedModules = ReplicatedStorage:WaitForChild("SharedModules")
local BaseClass = require(SharedModules.BaseClass)

local Lume = require(game.ReplicatedStorage.SharedModules.Lume)

local TickAPI = nil
local MostlyUUID = nil

local SafeLoad = Lume.once(function()
	TickAPI = require(game.ReplicatedStorage.SharedModules.TickAPI)
	MostlyUUID = require(game.ReplicatedStorage.SharedModules.MostlyUUID)	
end)


----------------------------------------------------------------------------------------------------
----------------------------------------------------------------------------------------------------

AfterNotTouchedClass.Storage = {}
----------------------------------------------------------------------------------------------------
----------------------------------------------------------------------------------------------------

-- Replace all CLASS_TEMPLATE
local AfterNotTouched = BaseClass.class("AfterNotTouched")

--[[
Creates our obj instance
- TickType is: Tick, Tickh, Tickr
]]
function AfterNotTouched:initialize(_time, fn, TickType)
	
	SafeLoad()
	
	self.Id = MostlyUUID.uuid()
	self.isDestroying = false
	
	self.Clock = TickAPI[TickType].delay(
		function()
			fn()
			self:Destroy()
		end, 
		_time
	)	
	
	AfterNotTouchedClass.Storage[self.Id] = self
end

--[[
This does a "touch or dirty or activate like event"
Signals that we should reset or timer agian 
]]
function AfterNotTouched:Touch()
	if self.isDestroying then return end
	
	self.Clock:reset()
end

--[[
Cleans Up clock
]]
function AfterNotTouched:Destroy()
	
	if self.isDestroying then return end
	self.isDestroying = true
	
	self.Clock = TickAPI.SafeStopClock(self.Clock)
	MostlyUUID.GUIDPoolFree(self.Id)	
	
	AfterNotTouchedClass.Storage[self.Id] = nil 
end

return AfterNotTouched

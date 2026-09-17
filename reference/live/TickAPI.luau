--!native
debug.setmemorycategory("TickAPI")
local TickAPI = {
	--_VERSION = 1.3
	--[[
	todo
	Individualized Timer so that when we require Tick we need to make sure
	-- that we then take that instance of it and give it the update
	
	-- APPARENTLY Tickh does not happen on the server? thats weird
	]]
}
local RunService = game:GetService("RunService")
local AfterNotTouchedClass = require(script.AfterNotTouchedClass)
-------------------------------------------------------------------------------------------------------
-- PRIVATE
-------------------------------------------------------------------------------------------------------

--local Tick_CoRoutine = coroutine.create(function()
	--RunService.Stepped:Connect(function(NormalTime, SteppedTime)					
	--	TickAPI.Tick.update(SteppedTime)						
	--end)			
--end)		
--coroutine.resume(Tick_CoRoutine)-- We prime the CoRoutine	

--local Tick_CoRoutine2 = coroutine.create(function()
	--RunService.Heartbeat:Connect(function(SteppedTime)					
	--	TickAPI.Tickh.update(SteppedTime)						
	--end)			
--end)		
--coroutine.resume(Tick_CoRoutine2)-- We prime the CoRoutine	
-------------------------------------------------------------------------------------------------------
-- PUBLIC PASS THROUGH
-------------------------------------------------------------------------------------------------------
---
TickAPI.Tick = require(game.ReplicatedStorage.SharedModules.TickAPI.Tick)

RunService.Stepped:Connect(function(NormalTime, SteppedTime)					
	TickAPI.Tick.update(SteppedTime)						
end)	
---
TickAPI.Tickh = require(game.ReplicatedStorage.SharedModules.TickAPI.Tick2)

RunService.Heartbeat:Connect(function(SteppedTime)		
	TickAPI.Tickh.update(SteppedTime)						
end)	
---
---------------------------------------
-- Render stepped tick is ONLY available on the client 
---------------------------------------
if RunService:IsClient() then
	TickAPI.Tickr = require(game.ReplicatedStorage.SharedModules.TickAPI.Tick3)

	RunService.RenderStepped:Connect(function(SteppedTime)					
		TickAPI.Tickr.update(SteppedTime)						
	end)
end
------------------------------------------------------------------------------------------

--[[
Ensures our clock object is not nil before stopping
]]
TickAPI.SafeStopClock = function(clockObj)
	-- Predicate
	if clockObj == nil then return nil end
	
	clockObj:stop()

	return nil
end

--[[
Creates an object with a timer set up so that whenever you hit 
Obj:Touch()
It will reset the clock and then clean itself up as it fires off if not touched long enough

TickType: Tickh, Tick, Tickr (only if on client)
]]
TickAPI.GetAfterNotTouched = function(_time, fn, TickType)
	return AfterNotTouchedClass:new(
		_time, 
		fn, 
		TickType
	)
end



return TickAPI

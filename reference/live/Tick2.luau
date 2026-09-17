--!native
local tick = {
	_VERSION = "0.1",
	_DESCRIPTION = ""
	--[[
		A simplified time manager for UI
		TODO
		ADD COMMENTING AND CLEAN4
	]]	
}
local RunService = game:GetService("RunService")

--[[
	I don't normally do it this way but I took heavy reference 
]]
tick.__index = tick

--[[
Checks if it is value is a callable function 
]]
local iscallable = function(x)
	if type(x) == "function" then return true end
	local mt = getmetatable(x)
	return mt and mt.__call ~= nil
end

--[[
I am a do nothing
]]
local noop = function()
end


local event = {}
event.__index = event

--[[
	This creates a an event and defines what kind of parent we are
	-- This also creates a prototype that we useas our clock object
	--
	-- 
	NOT PUBLIC
]]
function event.new(parent, fn, delay, recur, err)
	err = err or 0
	-- Create and return event
	return setmetatable({
		parent  = parent,
		delay   = delay,
		timer   = delay + err,
		fn      = fn,
		recur   = recur,
	}, event)
end

--[[
 The function, after the time passed through is passed
 -- is run and then the object is released
]]
function event:after(fn, delay)
	-- Error check
	if self.recur then
		error("cannot chain a recurring event")
	end
	-- Chain event
	local oldfn = self.fn
	local e = event.new(self.parent, fn, delay, false)
	self.fn = function()
		oldfn()
		e.timer = e.timer + self.parent.err
		self.parent:add(e)
	end
	return e
end

--[[
	Releases the object and also removes it so the clock 
	no longer exsist
]]
function event:stop()
	tick.remove(self.parent, self)
end

--[[
Lets us change the total time of the object, while maintaining the ratio of time 
that has already passed. 
so if 50% of time has based, and we go from 5 seconds total time to 10 seconds total time, 
our new time left would go from 2.5 to 5 to maintain the purportionate time that had passed already
this does NOT reset the clock, it modifies it while its still running this is why it adjusts the timer while maintaining
the ratio of time passed
]]
function event:adjust(newTotalTime)
	self.timer = (self.timer/self.delay) * newTotalTime	
	self.delay = newTotalTime
end

--[[
Not from original tick
Causes our delay to be reset back to the top
]]
function event:reset()
	self.timer = self.delay
end

function tick.group()
	return setmetatable({ err = 0 }, tick)
end


function tick:add(e)
	self[e] = true
	table.insert(self, e)
	return e
end


function tick:remove(e)
	if type(e) == "number" then
		-- Remove and return event
		local idx = e
		e = self[idx]
		self[e] = nil
		self[idx] = self[#self]
		table.remove(self)
		return e
	end
	self[e] = false
	for i, v in ipairs(self) do
		if v == e then
			return self:remove(i)
		end
	end
end


--[[
	 This is what is linked and iterated over 
	 to keep all of our clocks going
]]
function tick:update(dt)
	for i = #self, 1, -1 do
		if self[i] == nil then continue end
		local e = self[i]
		e.timer = e.timer - dt
		while e.timer <= 0 do
			if e.recur then
				e.timer = e.timer + e.delay
			else
				self:remove(i) 
			end
			self.err = e.timer
			e.fn()
			if not e.recur then
				break
			end
		end
	end
	self.err = 0
end

--[[
	This is our bread and better
	this is where we pass in our key data for the clock object
]]
function tick:event(fn, delay, recur)
	delay = tonumber(delay)
	-- Error check
	if not iscallable(fn) then
		error("expected `fn` to be callable")
	end
	if type(delay) ~= "number" then
		error("expected `delay` to be a number")
	end
	if delay < 0 then
		error("expected `delay` of zero or greater")
	end
	-- If, factoring in the timing error, the event should happen *now* the
	-- function is immediately called and the error is temporarily carried
	-- through. This assures nested events with delays shorter than the update()
	-- delta-time do not accumulate error; several nested events with very small
	-- delays may end up being called on the same frame. A dummy event is created
	-- and returned so :after() still functions correctly.
	local d = delay + self.err
	if d < 0 then
		local err = self.err
		self.err = d
		fn()
		self.err = err
		return self:add(event.new(self, noop, delay, recur, self.err))
	end
	-- Create, add and return a normal event
	return self:add(event.new(self, fn, delay, recur, self.err))
end

--[[
	Delay is, this event occurs after X period of time
]]
function tick:delay(fn, delay)
	return self:event(fn, delay, false)
end

--[[
	Recur will fire the function each time the time is passed
]]
function tick:recur(fn, delay)
	return self:event(fn, delay, true)
end

--[[
	returns the number of active clocks in the core table
]]
function tick:getClocks()
	return #self
end

local group = tick.group()
------------------------------------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------------------------------------
-- IMPORTANT NOTE:
--> delay/recur both pass out their clock objects when you create them 
--> This is good for if you want to stop them or interface with them after 
-- the fact
local bound = {
	update  = function(...) return tick.update(group, ...) end,
	delay   = function(...) return tick.delay (group, ...) end,
	recur   = function(...) return tick.recur (group, ...) end,
	remove  = function(...) return tick.remove(group, ...) end,
}
setmetatable(bound, tick)

return bound

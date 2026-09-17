-- An additional resource combind with our base class to make it work
-- Module
local Stateful = {
	--[[ NOTE: 
		-- IF you wante existed to be thrown you must pass at least 1 value through your gotoState	
	--]]
}


Stateful.static = {}

--[[
These are all automatically available
ObjectInstance:enteredState(...) --> ... will be anything that is passed through the gotoCall 
so that you can pass variables through states <-- This is AWESOME REMEMBER
To clerify
--> These are automated call back functions that will 
self:gotoState(State, true) <-- this will trigger Enterted and exit 
]]
local _callbacks = {
  enteredState = 1,
  exitedState = 1,
  pushedState = 1,
  poppedState = 1,
  pausedState = 1,
  continuedState = 1
}

local _BaseState = {}

-------------------------------------------------------------------------------------------------------
-- Private
-------------------------------------------------------------------------------------------------------

--[[
TODO
]]
local function _getStatefulMethod(instance, name)
  if not _callbacks[name] then
    local stack = rawget(instance, '__stateStack')
    if not stack then return end
    for i = #stack, 1, -1 do
      if stack[i][name] then return stack[i][name] end
    end
  end
end

--[[
TODO
]]
local function _getNewInstanceIndex(prevIndex)
  if type(prevIndex) == 'function' then
    return function(instance, name) return _getStatefulMethod(instance, name) or prevIndex(instance, name) end
  end
  return function(instance, name) return _getStatefulMethod(instance, name) or prevIndex[name] end
end

--[[
TODO
]]
local function _assertType(val, name, expected_type, type_to_s)
  if type(val) ~= expected_type then
    error("Expected " .. name .. " to be of type " ..
          (type_to_s or expected_type) .. ". Was " ..
          tostring(val) .. "(" .. type(val) .. ")")
  end
end

--[[
TODO
]]
local function _assertInexistingState(klass, stateName)
  if klass.states[stateName] ~= nil then
    error("State " .. tostring(stateName) .. " already exists on " .. tostring(klass) )
  end
end

--[[
TODO
]]
local function _assertExistingState(self, state, stateName)
  if not state then
    error("The state " .. stateName .. " was not found in " .. tostring(self.class))
  end
end

--[[
TODO
]]
local function _getStateName(self, target)
  for name,state in pairs(self.class.static.states) do
    if state == target then return name end
  end
end

--[[
TODO
]]
local function _invokeCallback(self, state, callbackName, ...)
  if state and state[callbackName] then state[callbackName](self, ...) end
end

--[[
TODO
]]
local function _getCurrentState(self)
  return self.__stateStack[#self.__stateStack]
end

--[[
TODO
]]
local function _getStateFromClassByName(self, stateName)
  local state = self.class.static.states[stateName]
  _assertExistingState(self, state, stateName)
  return state
end

--[[
TODO
]]
local function _getStateIndexFromStackByName(self, stateName)
  if stateName == nil then return #self.__stateStack end
  local target = _getStateFromClassByName(self, stateName)
  for i = #self.__stateStack, 1, -1 do
    if self.__stateStack[i] == target then return i end
  end
end
-------------------------------------------------------------------------------------------------------
-- Public
-------------------------------------------------------------------------------------------------------

--[[
Changes Our to the state we have passed in. 
- Triggers "enteredState" call back that can be gotten by obj:enteredState(...)
]]
function Stateful:gotoState(stateName, ...)
	
	local stateTableForPops = {...}
	
	if #stateTableForPops > 0 then
	  self:popAllStates(...)
	end

  if stateName == nil then
    self.__stateStack = { }
  else
    _assertType(stateName, 'stateName', 'string', 'string or nil')

    local newState = _getStateFromClassByName(self, stateName)
    self.__stateStack = { newState }
    _invokeCallback(self, newState, 'enteredState', ...)
  end

end

--[[
-- Pushes a new state onto the stack, pausing the current state
-- Triggers "pausedState" on the current active state
-- Triggers "pushedState" on the new state
-- Triggers "enteredState" on the new state
]]
function Stateful:pushState(stateName,...)
  local oldState = _getCurrentState(self)
  _invokeCallback(self, oldState, 'pausedState')

  local newState = _getStateFromClassByName(self, stateName)
  table.insert(self.__stateStack, newState)

  _invokeCallback(self, newState, 'pushedState',...)
  _invokeCallback(self, newState, 'enteredState',...)
end

--[[
-- Pops the current or a specific state from the stack
-- Triggers "poppedState" on the current active State
-- Triggers "exitedState" on curent active State
---
-- if the next state on the stack does not == oldState then
-- Triggers "continuedState" on the new state
--- This only happens if we have another state on the stack.
]]
function Stateful:popState(stateName, ...)
  local oldStateIndex = _getStateIndexFromStackByName(self, stateName)
  
  local oldState
  if oldStateIndex then
    oldState = self.__stateStack[oldStateIndex]

    _invokeCallback(self, oldState, 'poppedState', ...)
    _invokeCallback(self, oldState, 'exitedState', ...)

    table.remove(self.__stateStack, oldStateIndex)
  end

  local newState = _getCurrentState(self)

  if oldState ~= newState then
    _invokeCallback(self, newState, 'continuedState', ...)
  end
end

--[[
this pops all states on the stack
]]
function Stateful:popAllStates(...)
  local size = #self.__stateStack
  for _=1,size do self:popState(nil, ...) end
end

--[[
TODO
]]
function Stateful:GetStateRefs()
	return self.static.states
end

-- Returns the name of the current state or nil if no state is active
function Stateful:getCurrentStateName()
	local currentState = _getCurrentState(self)
	return _getStateName(self, currentState)
end

--[[
TODO
]]
function Stateful.static:addState(stateName, superState)
	superState = superState or _BaseState
	_assertType(stateName, 'stateName', 'string')
	_assertInexistingState(self, stateName)
	self.static.states[stateName] = setmetatable({}, { __index = superState })
	return self.static.states[stateName]
end
-------------------------------------------------------------------------------------------------------
-- Include Setup
-------------------------------------------------------------------------------------------------------

local function _modifyInstanceIndex(klass)
	klass.__instanceDict.__index = _getNewInstanceIndex(klass.__instanceDict.__index)
end

local function _addStatesToClass(klass, superStates)
	klass.static.states = {}
	for stateName, state in pairs(superStates or {}) do
		klass:addState(stateName,state)
	end
end

local function _getNewSubclassMethod(prevSubclass)
	return function(klass, name)
		local subclass = prevSubclass(klass, name)
		_addStatesToClass(subclass, klass.states)
		_modifyInstanceIndex(subclass)
		return subclass
	end
end

local function _modifySubclassMethod(klass)
	klass.static.subclass = _getNewSubclassMethod(klass.static.subclass)
end

local function _getNewAllocateMethod(oldAllocateMethod)
	return function(klass, ...)
		local instance = oldAllocateMethod(klass, ...)
		instance.__stateStack = {}
		return instance
	end
end

local function _modifyAllocateMethod(klass)
	klass.static.allocate = _getNewAllocateMethod(klass.static.allocate)
end

function Stateful:included(klass)
	_addStatesToClass(klass)
	_modifyInstanceIndex(klass)
	_modifySubclassMethod(klass)
	_modifyAllocateMethod(klass)
end
-------------------------------------------------------------------------------------------------------
--Debug
-------------------------------------------------------------------------------------------------------

function Stateful:getStateStackDebugInfo()
	local info = {}
	local state
	for i=#self.__stateStack,1,-1 do
		state = self.__stateStack[i]
		table.insert(info, _getStateName(self, state))
	end
	return info
end

return Stateful

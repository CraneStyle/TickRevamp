-----------------------------------------------------------------------------------
-- Invoker.lua
-- Enrique García ( enrique.garcia.cota [AT] gmail [DOT] com ) - 4 Mar 2010
-- Updated for compatibility with the latest MiddleClass version
-- Helper function that simplifies method invocation via method names or functions
-----------------------------------------------------------------------------------

--[[ Usage:

  require 'middleclass' -- or similar
  require 'middleclass-extras.init' -- or 'middleclass-extras'

  MyClass = class('MyClass')
  MyClass:include(Invoker)
  function MyClass:foo(x, y) print('foo executed with params', x, y) end

  local obj = MyClass:new()

  obj:invoke('foo', 1, 2) -- foo executed with params 1 2
  
  obj:invoke(function(self, x, y)
    print('nameless function executed with params', x, y)
  end, 3, 4) -- nameless function executed with params 3, 4
  
  Notes:
   * The function's first parameter must always be self
   * You can use Invoker independently: Invoker.invoke(obj, 'method')
]]

local Invoker = {}

-- Function to invoke a method by its name
local function _invokeString(self, methodName, ...)
	local method = self[methodName]
	assert(type(method) == 'function', 'Could not find ' .. methodName .. ' in ' .. tostring(self))
	return method(self, ...)
end

-- Function to invoke a method directly via a function reference
local function _invokeFunction(self, func, ...)
	return func(self, ...)
end

-- Map of function handlers based on type
local _functionByType = {
	['string'] = _invokeString,
	['function'] = _invokeFunction
}

-- The main invoke function for the Invoker
function Invoker:invoke(methodOrName, ...)
	local f = _functionByType[type(methodOrName)]
	if f then
		return f(self, methodOrName, ...)
	end
	error('methodOrName should be either a function or string. It was a ' .. type(methodOrName) .. ': ' .. tostring(methodOrName))
end

return Invoker

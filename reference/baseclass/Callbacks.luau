-----------------------------------------------------------------------------------
-- Callbacks.lua
-- Enrique García ( enrique.garcia.cota [AT] gmail [DOT] com )
-- Updated for compatibility with the custom BaseClass version
-- Mixin that adds callbacks support (i.e. beforeXXX or afterYYY) to classes
-----------------------------------------------------------------------------------
-- DEPENDENCY: Invoker -> Callbacks -> Branchy
--	:include(Invoker, CallBacks)
-----------------------------------------------------------------------------------
--[[ Usage:

NOTES:  IMPORTANT
-> The call backs need to be positioned AFTER the main fuction they are bound too 
--> If not it causes some type of index error must so treat it like a local function and that local 
must exsist Before the after or before can be called.  

A good practice is wrap them together in a local function and push that to the bottom.

SUGGESTION:  Any call back hooks up, define them after the functionj they connect too or are binding too
-----------------------------------------------------------------------------------
-----------------------------------------------------------------------------------
local BaseClass = require(game.ReplicatedStorage.SharedModules.BaseClass) -- or similar
local Invoker = require(game.ReplicatedStorage.SharedModules.BaseClass.HelperIncludes.Invoker)
local Callbacks = require(game.ReplicatedStorage.SharedModules.BaseClass.HelperIncludes.Callbacks)


local MyClass = BaseClass.class('MyClass'):include(Invoker, Callbacks)

local SubKlass = MyClass:subclass("SubKlass"):include(Invoker, Callbacks)

function SubKlass:initialize()
	MyClass.initialize(self)
end

function SubKlass:foo() print('foo') end
function SubKlass:bar() print('bar') end

-- The following lines modify method bar so:
--MyClass:before('bar', 'foo') -- foo is executed before bar
SubKlass:after('bar', "foo") -- executes after bar

--AlsoValid
--MyClass:after('bar', function(self) self:thing() end)

local obj = SubKlass:new()

obj:bar() -- prints 'foo bar baz'
obj:barWithoutCallbacks() -- prints 'bar'

  -- It is possible to add more callbacks before or after any method
]]

--------------------------------
--      PRIVATE STUFF
--------------------------------

--[[ holds all the callbacks entries.
     callback entries are just lists of methods to be called before / after some other method is called

  -- m1, m2, m3 & m4 can be method names (strings) or functions
  _entries = {
    Actor = {                           -- class
      update = {                          -- method
        before = {                          -- 'before' actions
          { method = m1, params={} },
          { method = m2, params={'blah', 'bleh'} },
          { method = m3, params={'foo', 'bar'} }
        },
        after = {                           -- 'after' actions
          { method = 'm4', params={1,2} }
        }
      }
    }
  }
]]

local Callbacks = {}

local _entries = setmetatable({}, { __mode = "k" }) -- weak table
local _methodCache = setmetatable({}, { __mode = "k" }) -- weak table

local _metamethods = { -- all metamethods except __index
	'__add', '__call', '__concat', '__div', '__le', '__lt', '__mod', '__mul', '__pow', '__sub', '__tostring', '__unm'
}

-- private class methods

local function _getEntry(theClass, methodName)
	if _entries[theClass] ~= nil and _entries[theClass][methodName] ~= nil then
		return _entries[theClass][methodName]
	end
end

local function _hasEntry(theClass, methodName)
	if _getEntry(theClass, methodName) then return true end
	return theClass.super and _hasEntry(theClass.super, methodName)
end

local function _getOrCreateEntry(theClass, methodName)
	if _entries[theClass] == nil then
		_entries[theClass] = {}
	end
	if _entries[theClass][methodName] == nil then
		_entries[theClass][methodName] = { before = {}, after = {} }
	end
	return _entries[theClass][methodName]
end

--[[
Returns all the actions that should be called when a callback is invoked, parsing superclasses
Warning: it returns two separate lists
Format:
{ -- before
  { method='m1', params={1,2} }, 
  { method='m2', params={3,4} }
},
{ -- after
  { method='m3', params={'a','b'} }, 
  { method='m4', params={'foo'} }
}
]]
local function _getActions(instance, methodName)
	local theClass = instance.class
	local before, after = {}, {}

	while theClass ~= nil do
		local entry = _getEntry(theClass, methodName)
		if entry ~= nil then
			for _, action in ipairs(entry.before) do table.insert(before, action) end
			for _, action in ipairs(entry.after) do table.insert(after, action) end
		end
		theClass = theClass.super
	end

	return before, after
end

-- invokes the 'before' or 'after' actions obtained with _getActions
local function _invokeActions(theClass, instance, actions)
	for _, action in ipairs(actions) do
		local result = theClass.invoke(instance, action.method, table.unpack(action.params))
		if result == false then return false end
	end
	return true
end

local function _createCallbackizedMethod(theClass, methodName)
	return function(instance, ...)
		local before, after = _getActions(instance, methodName)

		if _invokeActions(theClass, instance, before) == false then return false end

		local result = { instance[methodName .. 'WithoutCallbacks'](instance, ...) }

		if _invokeActions(theClass, instance, after) == false then return false end
		return table.unpack(result)
	end
end

-- returns a function that executes "method", but with before and after actions
-- it also does some optimizations. It uses a cache, and returns the method itself when it
-- doesn't have any entries on the entry list (hence no callbacks)
local function _callbackizeMethod(theClass, methodName, method)
	if type(method) ~= 'function' or not _hasEntry(theClass, methodName) then return method end

	_methodCache[theClass] = _methodCache[theClass] or {}
	_methodCache[theClass][method] = _methodCache[theClass][method] or _createCallbackizedMethod(theClass, methodName)

	return _methodCache[theClass][method]
end

local function _assertFunctionOrTable(classDict)
	local tcd = type(classDict)
	assert(tcd == 'function' or tcd == 'table', 'invalid type for an index; must be function or table, was ' .. tcd)
end

local function _createIndexFunction(theClass, classDictFunction)
	return function(instance, methodName)
		local method = classDictFunction(instance, methodName)

		if method then return _callbackizeMethod(theClass, methodName, method) end

		-- If method not found, test if methodName ends in "WithoutCallbacks".
		-- If it does yes, return the method without callbacks
		methodName = methodName:match('(.+)WithoutCallbacks')
		if methodName ~= nil then return classDictFunction(instance, methodName) end
	end
end

local function _buildClassDictFunction(classDict)
	local classDictFunction = classDict
	if type(classDict) == 'table' then classDictFunction = function(_, x) return classDict[x] end end
	return classDictFunction
end

local function _createInstanceDict(theClass)
	local classDict = theClass.__instanceDict
	_assertFunctionOrTable(classDict)

	-- a copy of classDict, with a modified __index that adds/removes callbacks when needed
	local instanceDict = {}
	for _, v in ipairs(_metamethods) do instanceDict[v] = classDict[v] end
	instanceDict.__index = _createIndexFunction(theClass, _buildClassDictFunction(classDict))
	return instanceDict
end

local function _assertFunctionOrString(callback)
	local tCallback = type(callback)
	assert(tCallback == 'string' or tCallback == 'function', 'callback must be a method name or a function')
end

-- adds callbacks to a method. Used by addCallbacksBefore and addCallbacksAfter, below
local function _addCallback(theClass, beforeOrAfter, methodName, callback, ...)
	assert(type(methodName) == 'string', 'methodName must be a string')
	_assertFunctionOrString(callback)

	local entry = _getOrCreateEntry(theClass, methodName)

	table.insert(entry[beforeOrAfter], { method = callback, params = { ... } })

	-- Ensure the original method is preserved as 'methodNameWithoutCallbacks'
	if not theClass.__instanceDict[methodName .. 'WithoutCallbacks'] then
		theClass.__instanceDict[methodName .. 'WithoutCallbacks'] = theClass.__instanceDict[methodName]
	end

	-- Replace the original method with the callbackized version
	theClass.__instanceDict[methodName] = _callbackizeMethod(theClass, methodName, theClass.__instanceDict[methodName])
end
--------------------------------
--      PUBLIC STUFF
--------------------------------
---------------------------------------------------------------------------------------------------
---------------------------------------------------------------------------------------------------

--[[ before class method
Usage (the following two are equivalent):

    Actor:before('update', 'doSomething', 1, 2)
    Actor:before('update', function(actor, x, y) actor:doSomething(x, y) end, 1, 2)

  * methodName must be a string designating a method (can be non-existing)
  * callback can be either a method name or a function
]]
function Callbacks:before(methodName, callback, ...)
	_addCallback(self, 'before', methodName, callback, ...)
end

-- Same as before, but for adding callbacks *after* a method
function Callbacks:after(methodName, callback, ...)
	_addCallback(self, 'after', methodName, callback, ...)
end
--------------------------------
--      Allocation and if it can inherance control
--------------------------------

--[[
This modifies our allocate method taking our originally one and then adding to it
this would be like how we have dependancies or things relative to this interface
]]
local function _modifyAllocateMethod(theClass)
	local oldAllocate = theClass.allocate
	theClass.allocate = function(self, ...)
		return setmetatable(oldAllocate(self, ...), _createInstanceDict(theClass))
	end
end

--[[
This basically allows means we auto propigate to children
]]
local function _modifySubclassMethod(theClass)
	local prevSubclass = theClass.subclass
	theClass.subclass = function(self, name, ...)
		local theSubClass = prevSubclass(self, name, ...)
		_modifyAllocateMethod(theSubClass)
		return theSubClass
	end
end

-- Compatibility function for BaseClass
--[[
This is a function that is called when this item is included
]]
function Callbacks:included(theClass)
	_modifyAllocateMethod(theClass)
	_modifySubclassMethod(theClass)
end


return Callbacks

-----------------------------------------------------------------------------------
-- Beholder.lua
-- Enrique García ( enrique.garcia.cota [AT] gmail [DOT] com ) - 4 Mar 2010
-- Small framework for event observers
-----------------------------------------------------------------------------------
-- DEPENDANCIES
--> Core Class must have invoke as part of it
--> include(Invoker, Beholder)


--[[ Usage:

local BaseClass = require(game.ReplicatedStorage.SharedModules.BaseClass)
local Invoker = require(game.ReplicatedStorage.SharedModules.BaseClass.HelperIncludes.Invoker)
local Beholder = require(game.ReplicatedStorage.SharedModules.BaseClass.HelperIncludes.Beholder)

MyClass = BaseClass.class('MyClass')
MyClass:include(Beholder)

function MyClass:foo(x,y) warn(x, y) end
function MyClass:SetName(name) self.Name = name  end

local obj = MyClass:new()
obj:SetName("Jake")
local obj2 = MyClass:new()
obj2:SetName("Luke")

----------------------------------------------------------------------------------------------------

warn("--- Seperator")

-- when the 'newgame' event is fired, call method foo with parameters 100 and 200
obj:observe('newgame', 'foo', 100, 200)
-- you can add more than one callbacks to the same event:
obj:observe('newgame', 'foo', 300, 400)

obj2:observe("newgame", function(self) warn(self.Name) end)

-- alternatively, use a function
obj:observe('endgame', function(myself) myself.blah = 0 warn(myself) end)

-- trigger the event:
Beholder.trigger('newgame')

-- stop observing an event: Bare in mind in th e object context for this 
-- that it will break All of them that ref new game for this object. 
obj:stopObserving('newgame')
-----
-- trigger the event:
Beholder.trigger('endgame')

------------------------------------------------------
obj2:stopObserving('newgame')

obj:observe('newgame', 'foo')

Beholder.trigger('newgame', 300, 400)
]]

--------------------------------
--    PRIVATE NODE CLASS
--------------------------------
local BaseClassPath = game.ReplicatedStorage.SharedModules.BaseClass
local BaseClass = require(BaseClassPath)

local Invoker = require(BaseClassPath.HelperIncludes.Invoker)
local Callbacks = require(BaseClassPath.HelperIncludes.Callbacks)
local Branchy = require(BaseClassPath.HelperIncludes.Branchy)

local Node = BaseClass.class('Node'):include(Invoker, Callbacks, Branchy)

function Node:initialize()
	self.objects=setmetatable({}, {__mode='k'})
end

function Node:getOrCreateChild(key)
	local child = self.children[key]
	
	if child == nil then
		child = self:addChild(Node:new(), key)
	end
	return child
end

function Node:getOrCreateDescendant(key)
	if type(key) ~= 'table' then return self:getOrCreateChild(key) end
	local node = self
	for _,v in ipairs(key) do node = node:getOrCreateChild(v) end
	return node
end

function Node:getDescendant(key)
	if type(key) ~= 'table' then return self.children[key] end
	local node = self
	for _,v in ipairs(key) do
		node = node.children[v]
		if node == nil then return nil end
	end
	return node
end

function Node:getOrRegisterObject(object)
	self.objects[object] = self.objects[object] or {}
	return self.objects[object]
end

function Node:addAction(object, method, ...)
	local actions = self:getOrRegisterObject(object)
	table.insert(actions, { method = method, params = {...} })
end

function Node:removeAction(object, method)
	if method == nil then self.objects[object] = nil end
	local actions = self.objects[object]
	if actions==nil then return end

	local index = 1
	for i,v in ipairs(actions) do
		if v == method then index = i break end
	end

	if(index~=nil) then table.remove(actions, index) end
end


-- Private variable storing the list of event callbacks that can be used
--[[ structure:
  _root = {                      -- root node
    children = 
      'a' = {                    -- root->a node
        children = {
          'b' = {                -- root->a->b node
            children = {},
            objects = {          -- list of objects registered on node root->a->b
              obj1 = {           -- list of actions to perform on object1
                { method = 'method1', params = {} },
                { method = 'method2', params = {1,2}}
              }
            }
          }
        },
        objects = {}             -- node root->a does not have any object registered
      }
      'b' = {                    -- root->b node
        children = {},           -- no children nor objects
        objects = {}
      }
    }
  }
]]
local _root = Node:new()

-- The Beholder module
Beholder = {}

function Beholder:observe(eventId, methodOrName, ...)

	assert(self~=nil, "self is nil. invoke object:observe instead of object.observe")
	assert(eventId~=nil, "eventId can not be nil")
	local t = type(methodOrName)
	assert(t=='string' or t=='function', 'methodOrName must be a function or string')

	local node = _root:getOrCreateDescendant(eventId)

	node:addAction(self, methodOrName, ...)
end

function Beholder:stopObserving(eventId, methodOrName)
	local node = _root:getDescendant(eventId)
	if node==nil then return end
	node:removeAction(self, methodOrName)
end


--[[ Triggers events
   Usage:
     Beholder.trigger('passion.update', dt)
   All objects that are "observing" passion.update events will get their associated actions called.
]]

function Beholder.trigger(eventId, ...)

	local node = _root:getDescendant(eventId)
	if node==nil then return end

	for object,actions in pairs(node.objects) do
		for _,action in ipairs(actions) do
			local params = {}
			for k,v in ipairs(action.params) do params[k] = v end
			for _,v in ipairs({...}) do table.insert(params, v) end

			Invoker.invoke(object, action.method, unpack(params))
		end
	end
end


return Beholder

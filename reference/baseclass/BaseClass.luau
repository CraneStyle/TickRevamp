local BaseClass = {
	--[[
	includes that can be Added and there dependancies
	
	-- These have dependancies that are outside of the core object 
	Invoker
	Beholder
	--
	
	-- These have depdnancies that must be included to have access  
	Callbacks ->  Invoker, Callback
	Branchy -> Invoker, Callbacks, Branchy
	--
		
	--]]
	--[[Modifications:  LOOK to update JSONR to be included into MiddleClass isntead of injecting this way
		- I have added things like RJson
		- made it so we return the raw name of the class so it just returns the class name .class
		- Made it so you can pass in multiple mixins
		--DISABLED == Rjson is disabled currenlty
	]]
	--[[ EXTRA NOTES
		Obj.class = Gives you reference to your constructor within your object 
	]]
}
-- TEST 
local RJson = require(game.ReplicatedStorage.SharedModules.JsonR)
--[[
Checks to see if we already registered if we have not then we do it otherwise
we skip it
]]
local function RegisterClass(instance)
	-- If we are already there then we dont registers again
	if RJson.isRegistered(tostring(instance)) then return end
	RJson.BaseClassAutoRegister(instance)
end
-----

-- Make this cleaner later and build it into everything approperatly. 
--[[
We keep track of every class name used and we just go ahead and error to enforce that created classes 
should always have a unique name that is not shared by any other class
]]
local AllClassNames = {}
local function RegesterClassName(nameString)
	if AllClassNames[nameString] == true then warn("CLASSNAME [[" .. nameString .. "]] already Exsist") end
	AllClassNames[nameString] = true
end

local function _createIndexWrapper(aClass, f)
	if f == nil then
		return aClass.__instanceDict
	else
		return function(self, name)
			local value = aClass.__instanceDict[name]

			if value ~= nil then
				return value
			elseif type(f) == "function" then
				return (f(self, name))
			else
				return f[name]
			end
		end
	end
end

local function _propagateInstanceMethod(aClass, name, f)
	f = name == "__index" and _createIndexWrapper(aClass, f) or f
	aClass.__instanceDict[name] = f

	for subclass in pairs(aClass.subclasses) do
		if rawget(subclass.__declaredMethods, name) == nil then
			_propagateInstanceMethod(subclass, name, f)
		end
	end
end

local function _declareInstanceMethod(aClass, name, f)
	aClass.__declaredMethods[name] = f

	if f == nil and aClass.super then
		f = aClass.super.__instanceDict[name]
	end

	_propagateInstanceMethod(aClass, name, f)
end

--[[MODIFIED: We made this easier on us cus we dont care to call it instance]]
local function _tostring(self) return self.name end
local function _call(self, ...) return self:new(...) end

local function _createClass(name, super)
	
	RegesterClassName(name)
	
	local dict = {}
	dict.__index = dict

	local aClass = { name = name,super = super, static = {},
	__instanceDict = dict, __declaredMethods = {},
	subclasses = setmetatable({}, {__mode='k'})  }

	if super then
		setmetatable(aClass.static, {
			__index = function(_,k)
				local result = rawget(dict,k)
				if result == nil then
					return super.static[k]
				end
				return result
			end
		})
	else
		setmetatable(aClass.static, { __index = function(_,k) return rawget(dict,k) end })
	end

	setmetatable(aClass, { __index = aClass.static, __tostring = _tostring,
		__call = _call, __newindex = _declareInstanceMethod })

	return aClass
end

-- Jake: Modified so that now you can pass in more than one mix in
local function _includeMixin(aClass, ...)

	local MixinList = {...}
	
	local mixin = nil
	
	for i = 1, #MixinList do
		mixin = MixinList[i]
		
		assert(type(mixin) == 'table', "mixin must be a table")

		for name,method in pairs(mixin) do
			if name ~= "included" and name ~= "static" then aClass[name] = method end
		end

		for name,method in pairs(mixin.static or {}) do
			aClass.static[name] = method
		end

		if type(mixin.included)=="function" then mixin:included(aClass) end
	end

	return aClass
end


local DefaultMixin = {
	--[[Modified: We made this easier for us for comparing and checking]]
	__tostring   = function(self) return tostring(self.class) end,

	initialize  = function(self, ...) end,

	isInstanceOf = function(self, aClass)
		return type(aClass) == 'table'
			and type(self) == 'table'
			and (self.class == aClass
				or type(self.class) == 'table'
				and type(self.class.isSubclassOf) == 'function'
				and self.class:isSubclassOf(aClass))
	end,

	static = {
		-- This creates the "instance" of the class
		allocate = function(self)
			assert(type(self) == 'table', "Make sure that you are using 'Class:allocate' instead of 'Class.allocate'")
			return setmetatable({ class = self}, self.__instanceDict)
		end,

		new = function(self, ...)
			assert(type(self) == 'table', "Make sure that you are using 'Class:new' instead of 'Class.new'")
			local instance = self:allocate()
			instance:initialize(...)
			instance.type = tostring(instance)
			return instance
		end,

		-- returns a string that demonstrates the heiarchy of the object
		getHierarchy = function(self)

			local nextThing = self.super
			local String = ""
			local TreeThing = {self.name}

			while nextThing ~= nil do 
				table.insert(TreeThing, nextThing.name)
				nextThing = nextThing.super
			end		
			table.insert(TreeThing, "BaseClass")

			local String = ""
			for i = #TreeThing, 1, -1 do
				if i > 1 then
					String = String .. TreeThing[i] .. " -> "
				else
					String = String .. TreeThing[i]
				end
			end

			return String
		end,		
		--[[ Added function that is used by JSONR we will look into how we can possibly turn JsonR int a pass in ]]
		--  newJsonRDecoded = function(self, _dataDecoded)
		--assert(type(self) == 'table', "Make sure that you are using 'Class:new' instead of 'Class.new'")
		--local instance = self:allocate()

		--if self["_signature"] ~= nil then
		--	local testTble = {}
		--	for i = 1, #self._signature do 
		--		table.insert(testTble, _dataDecoded[self._signature[i]])
		--	end	
		--	instance:initialize(table.unpack(testTble))
		--else
		--	error("Class Not set up with a proper signature to be able to decode")
		--end

		--return instance
		--  end,

		-- added for making a class decodable
		-- Change name to Set Serial signature
		setSignature = function(self, ...) self._signature = {...} RegisterClass(self) end,

		subclass = function(self, name)
			assert(type(self) == 'table', "Make sure that you are using 'Class:subclass' instead of 'Class.subclass'")
			assert(type(name) == "string", "You must provide a name(string) for your class")

			local subclass = _createClass(name, self)

			for methodName, f in pairs(self.__instanceDict) do
				_propagateInstanceMethod(subclass, methodName, f)
			end

			subclass.initialize = function(instance, ...)     return self.initialize(instance, ...) end

			self.subclasses[subclass] = true
			self:subclassed(subclass)

			return subclass
		end,

		subclassed = function(self, other) end,

		isSubclassOf = function(self, other)
			return type(other) == 'table' and
				type(self.super) == 'table' and
				( self.super == other or self.super:isSubclassOf(other) )
		end,    

		include = function(self, ...)
			assert(type(self) == 'table', "Make sure you that you are using 'Class:include' instead of 'Class.include'")
			for _,mixin in ipairs({...}) do _includeMixin(self, mixin) end
			return self
		end
	}
}

--[[
Returns a class that is typed by the name. 
]]
function BaseClass.class(name, super)
	assert(type(name) == 'string', "A name (string) is needed for the new class")

	return super and super:subclass(name) or _includeMixin(_createClass(name), DefaultMixin)
end

setmetatable(BaseClass, { __call = function(_, ...) return BaseClass.class(...) end })

BaseClass.ClassTable = assert(getmetatable(BaseClass))

return BaseClass

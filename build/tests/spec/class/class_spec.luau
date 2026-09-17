--!nonstrict
--[[
	The class mechanics of the Veron modules now that they are plain Luau
	tables. Each module doubles as the metatable for its instances, handles and
	schedulers carry class and type and answer isInstanceOf, direct construction
	is refused, every public member exists under a dot and a colon closure, and
	the lowercase alias sets are complete and closed.

	The modules are required inside the tests, not at file level, so loading
	them stays observable and this spec can run first.
]]

-- §3.2 PUBLIC: one closure per canonical member, stored under every spelling.
local PUBLIC = {
	{ "Update", "update" },
	{ "UpdateTo" },
	{ "Now" },
	{ "SetTimeScale" },
	{ "GetTimeScale" },
	{ "Pause" },
	{ "Resume" },
	{ "IsPaused" },
	{ "Delay", "delay" },
	{ "Recur", "recur" },
	{ "DelayAt" },
	{ "Stop", "Remove", "remove" },
	{ "Complete", "ForceEventComplete" },
	{ "CompleteNow" },
	{ "GetRemaining" },
	{ "GetClocks", "getClocks" },
	{ "GetStats" },
	{ "Validate" },
	{ "Describe" },
	{ "SetOnError" },
	{ "SetMaxCatchUp" },
	{ "GetMaxCatchUp" },
	{ "SetValve" },
	{ "SetMaxDt" },
	{ "SetStrict" },
	{ "Clear" },
	{ "Attach" },
	{ "Detach" },
	{ "GetChildren" },
	{ "Drive" },
	{ "Destroy" },
	{ "IsDestroyed" },
	{ "IsUpdating" },
	{ "GetBase" },
}

-- The closed legacy alias sets (Q-J7 / D15): alias → canonical.
local INSTANCE_ALIASES = {
	update = "Update",
	delay = "Delay",
	recur = "Recur",
	remove = "Stop",
	Remove = "Stop",
	getClocks = "GetClocks",
	ForceEventComplete = "Complete",
}
local HANDLE_ALIASES = {
	stop = "Stop",
	reset = "Reset",
	adjust = "Adjust",
	after = "After",
	Destroy = "Stop",
}

-- §3.2 instance fields, all assigned in initialize (never nil).
local INSTANCE_FIELDS = {
	-- heap
	"_Due", "_Item", "_N",
	-- clock
	"_Now", "_Base", "_Firing", "_FiringThread", "_TimeScale", "_IsPaused", "_Offset", "_LastAbs",
	-- pass
	"_UpdateDepth", "_SyncDepth", "_Serial", "_NextId", "_Errored",
	-- policy
	"_MaxCatchUp", "_Valve", "_MaxDt", "_MaxUpdateDepth", "_OnError", "_Strict", "_LegacyRecurBase",
	-- side indexes
	"_Paused", "_PausedCount", "_Children", "_ChildCount", "_Parent", "_ChainedCount", "_RecurCount",
	-- lifecycle
	"Name", "_IsDestroyed",
	-- stats
	"_Updates", "_Dispatched", "_LastDispatched", "_Reentries", "_Dropped", "_ValveHits",
	"_ClampedBackwards", "_ClampedDt", "_Errors", "_ErrorsSuppressed", "_LastDt",
	"_LastErrorId", "_LastErrorAt",
	"_WarnedReentry", "_WarnedValve", "_WarnedBackwards", "_WarnedResolution",
}

-- §3.2 initial values worth pinning by name.
local INITIAL_VALUES = {
	_N = 0,
	_Now = 0,
	_Base = false,
	_Firing = false,
	_FiringThread = false,
	_TimeScale = 1,
	_IsPaused = false,
	_Offset = 0,
	_LastAbs = false,
	_UpdateDepth = 0,
	_SyncDepth = 0,
	_Serial = 0,
	_NextId = 0,
	_Errored = false,
	_MaxCatchUp = 8,
	_Valve = 1000,
	_MaxDt = false,
	_MaxUpdateDepth = 8,
	_OnError = "warn",
	_Strict = false,
	_LegacyRecurBase = false,
	_PausedCount = 0,
	_ChildCount = 0,
	_Parent = false,
	_ChainedCount = 0,
	_RecurCount = 0,
	_IsDestroyed = false,
	_Updates = 0,
	_Dispatched = 0,
	_LastDispatched = 0,
	_Reentries = 0,
	_Dropped = 0,
	_ValveHits = 0,
	_ClampedBackwards = 0,
	_ClampedDt = 0,
	_Errors = 0,
	_ErrorsSuppressed = 0,
	_LastDt = 0,
	_LastErrorId = 0,
	_LastErrorAt = -math.huge,
	_WarnedReentry = false,
	_WarnedValve = false,
	_WarnedBackwards = false,
	_WarnedResolution = false,
}

local FIELD_NAMES = {
	"class",
	"type",
	"Id",
	"_Scheduler",
	"_Fn",
	"_Period",
	"_IsRecur",
	"_State",
	"_HeapIndex",
	"_Chained",
	"_Burst",
	"_BurstSerial",
	"_MaxCatchUp",
	"_Flags",
}

local function _loadEnv()
	return require("../../../src/Veron/Env")
end

local function _loadVeronEvent()
	return require("../../../src/Veron/VeronEvent")
end

local function _loadVeron()
	return require("../../../src/Veron")
end

--[[
	Sorted list of the string keys of `tbl` (for shape comparisons).
]]
local function _sortedKeys(tbl)
	local keys = {}
	for key in pairs(tbl) do
		keys[#keys + 1] = tostring(key)
	end
	table.sort(keys)
	return keys
end

--[[
	Counts the function-valued string keys of an instance and the distinct
	function objects behind them.
]]
local function _closureCounts(instance)
	local keys, distinct = 0, 0
	local seen = {}
	for key, value in pairs(instance) do
		if type(key) == "string" and type(value) == "function" then
			keys += 1
			if not seen[value] then
				seen[value] = true
				distinct += 1
			end
		end
	end
	return keys, distinct
end

--[[
	The §3.1 literal, built by hand exactly as the scheduler builds it, over
	a fake owner that carries only the field Describe() reads.
]]
local function _literalHandle(VeronEvent)
	local handle = {
		class = VeronEvent,
		type = "VeronEvent",
		Id = 42,
		_Scheduler = { Name = "T" },
		_Fn = function() end,
		_Period = 0.5,
		_IsRecur = true,
		_State = 1,
		_HeapIndex = 0,
		_Chained = false,
		_Burst = 0,
		_BurstSerial = 0,
		_MaxCatchUp = false,
		_Flags = 0,
	}
	return setmetatable(handle, VeronEvent)
end

return function(t)
	t.test("class modules load once and build usable instances", function()
		-- Requiring a module twice returns the one cached object, and the Env
		-- loader lands on that same object, so each class body runs a single
		-- time and building instances adds nothing to the module.
		local Env = _loadEnv()
		local VeronEvent = _loadVeronEvent()
		t.eq(Env.Load("VeronEvent"), VeronEvent, "Env.Load and the relative require agree")
		t.eq(_loadVeronEvent(), VeronEvent, "one module object for VeronEvent")
		local Veron = _loadVeron()
		t.eq(_loadVeron(), Veron, "one module object for Veron")
		t.eq(_loadVeronEvent(), VeronEvent, "loading Veron did not reload VeronEvent")
		local probe = Veron.new({ Name = "BootProbe" })
		t.eq(probe.type, "Veron")
		probe:Destroy()
	end)

	t.test("handle isInstanceOf VeronEvent, class and type set on a literal handle", function()
		local VeronEvent = _loadVeronEvent()
		local handle = _literalHandle(VeronEvent)
		t.eq(handle:isInstanceOf(VeronEvent), true, "isInstanceOf")
		t.eq(handle.class, VeronEvent, "class")
		t.eq(handle.type, "VeronEvent", "type")
		t.eq(getmetatable(handle), VeronEvent, "metatable")
		-- the literal is a usable instance: colon methods work on it
		t.eq(handle:GetState(), "Pending")
		t.eq(handle:GetId(), 42)
		t.eq(handle:IsRecurring(), true)
		t.eq(handle:GetPeriod(), 0.5)
		t.eq(handle:IsActive(), true)
		t.eq(handle:IsPaused(), false)
		t.eq(handle:GetScheduler().Name, "T")
		t.eq(handle:Describe(), "VeronEvent<T#42 recur 0.5s Pending>")
	end)

	t.test("handle literal has exactly 14 keys, every value non-nil", function()
		local VeronEvent = _loadVeronEvent()
		local handle = _literalHandle(VeronEvent)
		t.eq(#FIELD_NAMES, 14, "the §3.1 field list has 14 names")
		local count = 0
		for _ in pairs(handle) do
			count += 1
		end
		t.eq(count, 14, "key count")
		for _, name in FIELD_NAMES do
			if rawget(handle, name) == nil then
				error("field " .. name .. " is nil on the literal handle")
			end
		end
	end)

	t.test("Fn/Period/IsRecur are not public fields", function()
		local VeronEvent = _loadVeronEvent()
		local handle = _literalHandle(VeronEvent)
		for _, name in { "Fn", "Period", "IsRecur" } do
			t.eq(rawget(handle, name), nil, name .. " is not a raw field")
			t.eq(handle[name], nil, name .. " does not resolve through the class")
			t.eq(rawget(VeronEvent, name), nil, name .. " is not a method")
			t.eq(type(rawget(handle, "_" .. name)) ~= "nil", true, "_" .. name .. " is the private field")
		end
	end)

	t.test("VeronEvent:new and VeronEvent() raise the construction error", function()
		local VeronEvent = _loadVeronEvent()
		local expected = "VeronEvent: handles are created by a Veron (Delay/Recur/After)"
		for _, construct in { function() return VeronEvent:new() end, function() return VeronEvent() end } do
			local ok, err = pcall(construct)
			t.eq(ok, false, "construction raises")
			t.eq(tostring(err):find(expected, 1, true) ~= nil, true, "message: " .. tostring(err))
		end
	end)

	t.test("each class is its own instance metatable", function()
		-- Handles and schedulers get their behavior from the module table used
		-- as their metatable, with __index pointing back at that same table.
		local VeronEvent = _loadVeronEvent()
		local Veron = _loadVeron()
		t.eq(VeronEvent.__index, VeronEvent, "VeronEvent.__index is itself")
		t.eq(Veron.__index, Veron, "Veron.__index is itself")
		local handle = _literalHandle(VeronEvent)
		t.eq(getmetatable(handle), VeronEvent, "handle metatable is VeronEvent")
		local instance = Veron.new({ Name = "MetatableProbe" })
		t.eq(getmetatable(instance), Veron, "instance metatable is Veron")
		t.eq(instance.type, "Veron")
		instance:Destroy()
	end)

	t.test("every Veron field non-nil after initialize", function()
		-- §3.2: every instance field assigned in initialize, `false` for optionals
		local Veron = _loadVeron()
		for _, instance in { Veron.new({ Name = "T" }), Veron.new() } do
			t.eq(rawget(instance, "class"), Veron, "class")
			t.eq(rawget(instance, "type"), "Veron", "type")
			for _, name in INSTANCE_FIELDS do
				if rawget(instance, name) == nil then
					error("field " .. name .. " is nil after initialize")
				end
			end
			for name, expected in INITIAL_VALUES do
				t.eq(rawget(instance, name), expected, "initial " .. name)
			end
			t.eq(type(instance.Name), "string", "Name")
			t.eq(type(instance._Due), "table")
			t.eq(type(instance._Item), "table")
			t.eq(type(instance._Paused), "table")
			t.eq(type(instance._Children), "table")
			t.eq(next(instance._Due), nil, "_Due starts empty")
			t.eq(next(instance._Paused), nil, "_Paused starts empty")
			-- every private key on the instance is one the design lists
			local known = {}
			for _, name in INSTANCE_FIELDS do
				known[name] = true
			end
			for key, value in pairs(instance) do
				if type(key) == "string" and key:sub(1, 1) == "_" and type(value) ~= "function" then
					t.eq(known[key], true, "undocumented private field " .. key)
				end
			end
			t.eq(instance:Validate(), true)
		end
	end)

	t.test("every public Veron member has a dot and a colon closure", function()
		-- §3.2 dual closures: `s.Delay(fn, t)` and `s:Delay(fn, t)` reach one method with self == s
		local Veron = _loadVeron()
		local dict = Veron
		local s = Veron.new({ Name = "T" })
		for _, names in PUBLIC do
			local canonical = names[1]
			t.eq(type(rawget(dict, canonical)), "function", canonical .. " is a class method")
			for _, alias in names do
				local closure = rawget(s, alias)
				t.eq(type(closure), "function", alias .. " has a per-instance closure")
				t.eq(closure ~= rawget(dict, canonical), true, alias .. " is a bound closure, not the raw method")
			end
		end
		local keys, distinct = _closureCounts(s)
		t.eq(keys, 41, "41 keys")
		t.eq(distinct, 34, "34 closures")
		-- both call shapes work and see the same instance
		t.eq(s.Now(), 0)
		t.eq(s:Now(), 0)
		local viaDot = s.Delay(function() end, 1)
		local viaColon = s:Delay(function() end, 1)
		t.eq(viaDot:GetScheduler(), s, "dot form binds self")
		t.eq(viaColon:GetScheduler(), s, "colon form binds self")
		t.eq(s.GetClocks(), 2)
		t.eq(s:GetClocks(), 2)
		t.eq(s.Describe(), s:Describe())
		t.eq(s.IsPaused(), false)
		s.Pause()
		t.eq(s:IsPaused(), true)
		s:Resume()
		t.eq(s.IsPaused(), false)
		t.eq(s.Stop(viaDot), true)
		t.eq(s:Stop(viaColon), true)
		t.eq(s.GetClocks(), 0)
		t.eq(s.Validate(), true)
		t.eq(s:Validate(), true)
		t.eq(s.IsDestroyed(), false)
		s.Destroy()
		t.eq(s:IsDestroyed(), true)
	end)

	t.test("aliases share one closure object", function()
		-- §3.2: `Stop/Remove/remove` → the same function object under three keys
		local Veron = _loadVeron()
		local s = Veron.new({ Name = "T" })
		t.eq(s.Stop, s.Remove, "Stop == Remove")
		t.eq(s.Remove, s.remove, "Remove == remove")
		t.eq(s.Update, s.update, "Update == update")
		t.eq(s.Delay, s.delay, "Delay == delay")
		t.eq(s.Recur, s.recur, "Recur == recur")
		t.eq(s.GetClocks, s.getClocks, "GetClocks == getClocks")
		t.eq(s.Complete, s.ForceEventComplete, "Complete == ForceEventComplete")
		for _, names in PUBLIC do
			local closure = rawget(s, names[1])
			for _, alias in names do
				t.eq(rawget(s, alias), closure, alias .. " shares " .. names[1] .. "'s closure")
			end
		end
		-- distinct members are distinct closures
		t.eq(s.Stop ~= s.Complete, true)
		t.eq(s.Delay ~= s.Recur, true)
		-- closures are per instance
		local other = Veron.new({ Name = "U" })
		t.eq(s.Stop ~= other.Stop, true, "another instance has its own closure")
		t.eq(other.Stop, other.remove)
		s:Destroy()
		other:Destroy()
	end)

	t.test("all three constructor spellings build the same shape", function()
		-- §1 (Q-J9): `Veron.new(cfg)`, `Veron:new(cfg)`, `Veron(cfg)` run one initialize; `Veron.new()` too
		local Veron = _loadVeron()
		local instances = {
			Veron.new({ Name = "A" }),
			Veron:new({ Name = "B" }),
			Veron({ Name = "C" }),
			Veron.new(),
		}
		local names = { "A", "B", "C" }
		for index, instance in instances do
			t.eq(getmetatable(instance), Veron, "metatable " .. index)
			t.eq(instance.class, Veron, "class " .. index)
			t.eq(instance.type, "Veron", "type " .. index)
			t.eq(instance:isInstanceOf(Veron), true, "isInstanceOf " .. index)
			if names[index] then
				t.eq(instance.Name, names[index], "Name " .. index)
			else
				t.eq(instance.Name:match("^Veron%d+$") ~= nil, true, "default Name: " .. tostring(instance.Name))
			end
			-- initialize ran exactly once: a fresh id counter, a live clock
			local handle = instance:Delay(function() end, 1)
			t.eq(handle:GetId(), 1, "first handle id " .. index)
			t.eq(instance:GetClocks(), 1, "clocks " .. index)
			t.eq(instance:Now(), 0, "clock " .. index)
			t.eq(instance:Validate(), true, "Validate " .. index)
		end
		-- identical key sets and value types
		local reference = table.concat(_sortedKeys(instances[1]), ",")
		for index = 2, #instances do
			t.eq(table.concat(_sortedKeys(instances[index]), ","), reference, "key set " .. index)
		end
		for key, value in pairs(instances[1]) do
			for index = 2, #instances do
				t.eq(type(instances[index][key]), type(value), "type of " .. tostring(key) .. " on " .. index)
			end
		end
		-- distinct objects; nothing registers them anywhere
		t.eq(instances[1] ~= instances[2] and instances[2] ~= instances[3] and instances[3] ~= instances[4], true)
		-- config is validated identically under every spelling (bare `Veron: ` prefix)
		t.throws(function()
			Veron.new({ Bogus = 1 })
		end, "Veron: unknown option 'Bogus'")
		t.throws(function()
			Veron:new({ Bogus = 1 })
		end, "Veron: unknown option 'Bogus'")
		t.throws(function()
			Veron({ Bogus = 1 })
		end, "Veron: unknown option 'Bogus'")
		t.throws(function()
			Veron.new({ TimeScale = -1 })
		end, "Veron: option 'TimeScale' expects")
		for _, instance in instances do
			instance:Destroy()
		end
	end)

	t.test("legacy alias table is complete", function()
		-- D15 / Q-J7: exactly instance update/delay/recur/remove/getClocks + Remove/ForceEventComplete;
		-- handle stop/reset/adjust/after/Destroy; nothing else (the set is closed)
		local Veron = _loadVeron()
		local VeronEvent = _loadVeronEvent()
		local s = Veron.new({ Name = "T" })
		local dict = Veron
		for alias, canonical in INSTANCE_ALIASES do
			t.eq(type(rawget(s, alias)), "function", alias .. " present")
			t.eq(rawget(s, alias), rawget(s, canonical), alias .. " == " .. canonical)
		end
		local canonicalSet = {}
		for _, names in PUBLIC do
			canonicalSet[names[1]] = true
		end
		for key, value in pairs(s) do
			if type(value) == "function" then
				t.eq(canonicalSet[key] == true or INSTANCE_ALIASES[key] ~= nil, true, "closed set: unexpected " .. tostring(key))
			end
		end
		local aliasCount = 0
		for _ in INSTANCE_ALIASES do
			aliasCount += 1
		end
		t.eq(aliasCount, 7)
		for _, absent in { "stop", "after", "reset", "adjust", "Count", "pause", "resume", "now", "clear",
			"getRemaining", "getStats", "ForceComplete", "complete", "fireNow", "Hook", "destroy" } do
			t.eq(rawget(s, absent), nil, absent .. " is not an instance alias")
			t.eq(rawget(dict, absent), nil, absent .. " is not a Veron method")
		end

		local eventDict = VeronEvent
		for alias, canonical in HANDLE_ALIASES do
			t.eq(type(rawget(eventDict, alias)), "function", alias .. " present")
			t.eq(rawget(eventDict, alias), rawget(eventDict, canonical), alias .. " == " .. canonical)
		end
		-- closed on the handle: every lowercase-initial method is an alias, new, or isInstanceOf
		for key, value in pairs(eventDict) do
			if type(key) == "string" and type(value) == "function" and key:match("^%l") then
				t.eq(HANDLE_ALIASES[key] ~= nil or key == "new" or key == "isInstanceOf", true,
					"closed set: unexpected handle alias " .. key)
			end
		end
		for _, absent in { "pause", "resume", "getRemaining", "setPeriod", "getState", "isActive", "complete",
			"fireNow", "ForceComplete", "Remove", "remove", "toggle", "restart", "destroy" } do
			t.eq(rawget(eventDict, absent), nil, absent .. " is not a handle alias")
		end
		-- the aliases are live on a real handle
		local handle = s:Delay(function() end, 1)
		t.eq(handle:reset(), handle)
		t.eq(handle:adjust(2), handle)
		t.eq(handle:GetPeriod(), 2)
		t.eq(handle:after(function() end, 1):GetState(), "Chained")
		handle:stop()
		t.eq(handle:GetState(), "Stopped")
		local other = s.delay(function() end, 1)
		other:Destroy()
		t.eq(other:GetState(), "Stopped")
		t.eq(s.getClocks(), 0)
		t.eq(s.remove(nil), false)
		s:Destroy()
	end)
end

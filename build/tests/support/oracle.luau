--!nonstrict
--[[
	build/tests/support/oracle.luau — the independent invariant oracle (DESIGN §3.2, §9, §12 WP2).

	Oracle.check(veron)   asserts `veron:Validate()` is true AND re-derives every §3.2 invariant
	                      straight from the private fields (`_Due/_Item/_N`, `_Paused`, `_Chained`
	                      lists, the counters, the firing triple), so a broken `Validate` cannot
	                      hide a broken heap. Raises with a message that names the FIRST violated
	                      invariant. Works on any table carrying the §3.2 fields (a real Veron or a
	                      hand-built fake); `Validate` is only called when the table has one.
	Oracle.wrap(veron)    returns the SAME instance after replacing each per-instance public closure
	                      (every key whose value is a function — the dual dot/colon closures of §3.2)
	                      with a version that runs the original, then `Oracle.check(veron)`. ONCE per
	                      process it also wraps every public method of `VeronEvent`
	                      (required lazily, so this file loads before the class exists) with a
	                      version that runs the original, then checks `self._Scheduler`. Callbacks
	                      re-check naturally because they call wrapped methods. If an original
	                      raises, the error is re-raised unchanged (`error(err, 0)`) and no check
	                      runs (the guard-only failure path). All arguments are forwarded untouched,
	                      so the colon guard and the dual dot/colon detection keep working. Aliases
	                      that shared one closure keep sharing one wrapper.
	Oracle.unwrap()       no-op, kept for symmetry.

	Notes: wrapping adds ONE stack frame per public call, so error-level ("blames the caller's
	chunk") assertions must run on a RAW instance. The `NOOP` a Stopped handle must carry is
	captured once per process from the first Stopped handle the oracle sees; every later Stopped
	handle must carry the same function. Handles reach the oracle through the heap, `_Paused`,
	`_Chained` lists, `_Firing`, and a weak registry of every handle that passed through a wrapper
	or a wrapped arm's return value (so terminal handles are still audited after they leave every
	container).
]]

local Oracle = {}

-- §3.1 states
local PENDING, PAUSED, CHAINED, FIRED, STOPPED = 1, 2, 3, 4, 5
local STATE_NAMES = { "Pending", "Paused", "Chained", "Fired", "Stopped" }
local HUGE = math.huge

-- The Stopped-handle NOOP, captured once per process (see the header).
local capturedNoop = nil

-- handle → owner Veron, for every handle that passed through a wrapper (weak: never keeps one alive)
local seen = setmetatable({}, { __mode = "k" })
-- instance → its ORIGINAL closures (so check can call the unwrapped Validate without recursing)
local originals = setmetatable({}, { __mode = "k" })
-- instances already wrapped (idempotent wrap)
local wrappedInstances = setmetatable({}, { __mode = "k" })
local handleDictWrapped = false

-- Keys on the VeronEvent table that are not handle methods to wrap.
local DICT_SKIP = { new = true, isInstanceOf = true }

--[[
	Returns the NOOP a Stopped handle must carry. Captured once per process: from a throwaway
	Veron instance when the class can be required (deterministic, never touches an instance
	under test), else from the first Stopped handle the oracle meets. nil until captured.
]]
local function _captureNoop()
	if capturedNoop ~= nil then return capturedNoop end
	local okLoad, Veron = pcall(require, "../../src/Veron")
	if okLoad and type(Veron) == "table" then
		local okProbe, fn = pcall(function()
			local probe = Veron.new({ Name = "OracleProbe" })
			local h = probe:Delay(function() end, 1)
			h:Stop()
			local noop = h._Fn
			probe:Destroy()
			return noop
		end)
		if okProbe and type(fn) == "function" then capturedNoop = fn end
	end
	return capturedNoop
end

--[[
	Raises the oracle's failure for one named invariant. `detail` is optional.
]]
local function _fail(invariant, detail)
	if detail ~= nil then
		error(("Oracle: %s (%s)"):format(invariant, tostring(detail)), 0)
	end
	error("Oracle: " .. invariant, 0)
end

local function _stateName(state)
	return STATE_NAMES[state] or ("state " .. tostring(state))
end

local function _describeHandle(h)
	if type(h) ~= "table" then return tostring(h) end
	return ("#%s %s"):format(tostring(rawget(h, "Id")), _stateName(rawget(h, "_State")))
end

local function _isFiniteNumber(value)
	return type(value) == "number" and value == value and value ~= HUGE and value ~= -HUGE
end

local function _isInteger(value)
	return type(value) == "number" and value == value and value % 1 == 0
end

--[[
	Counts the keys of a dictionary (no assumption about its shape).
]]
local function _countKeys(dict)
	local count = 0
	for _ in pairs(dict) do count += 1 end
	return count
end

--[[
	Ordering helper for the (due, Id) heap property: true when slot a must sit ABOVE slot b.
]]
local function _lessThan(dueA, idA, dueB, idB)
	if dueA ~= dueB then return dueA < dueB end
	return idA < idB
end

local REQUIRED_FIELDS = {
	"_Due", "_Item", "_N", "_Paused", "_PausedCount", "_Children", "_ChildCount",
	"_ChainedCount", "_RecurCount", "_UpdateDepth", "_SyncDepth", "_Base", "_Firing",
	"_FiringThread",
}

--[[
	Per-handle checks that hold for EVERY handle of the instance whatever container it is in.
	Terminal ⇒ out of the heap, flags zero; Stopped ⇒ NOOP; flags ≥ 4 only on a Pending
	recurring; Paused ⇔ a key of `_Paused`.
]]
local function _checkHandleShape(veron, h, where)
	if type(h) ~= "table" then _fail("handle slot holds a non-table", where) end
	local label = _describeHandle(h) .. " via " .. where
	if h._Scheduler ~= veron then _fail("handle belongs to another scheduler", label) end
	local id = h.Id
	if not _isInteger(id) or id < 1 then _fail("handle Id is not a positive integer", label) end
	local state = h._State
	if not _isInteger(state) or state < PENDING or state > STOPPED then
		_fail("handle _State outside 1..5", label)
	end
	local heapIndex = h._HeapIndex
	if not _isInteger(heapIndex) or heapIndex < 0 then _fail("handle _HeapIndex is not an integer >= 0", label) end
	local flags = h._Flags
	if not _isInteger(flags) or flags < 0 or flags > 15 then _fail("handle _Flags outside 0..15", label) end
	if type(h._IsRecur) ~= "boolean" then _fail("handle _IsRecur is not a boolean", label) end
	if type(h._Fn) ~= "function" and not (type(h._Fn) == "table" and getmetatable(h._Fn)) then
		_fail("handle _Fn is not callable", label)
	end
	local chained = h._Chained
	if chained ~= false and type(chained) ~= "table" then _fail("handle _Chained is neither false nor a list", label) end

	if state >= FIRED then
		if heapIndex ~= 0 then _fail("terminal handle still has a _HeapIndex", label) end
		if flags ~= 0 then _fail("terminal handle has non-zero _Flags", label) end
		if state == STOPPED then
			if type(h._Fn) ~= "function" then _fail("Stopped handle _Fn is not a function", label) end
			local noop = _captureNoop()
			if noop == nil then
				capturedNoop = h._Fn
			elseif h._Fn ~= noop then
				_fail("Stopped handle _Fn is not the NOOP", label)
			end
		end
	end
	if flags >= 4 and not (state == PENDING and h._IsRecur) then
		_fail("_Flags >= 4 on a handle that is not a Pending recurring", label)
	end
	if state == PENDING then
		if heapIndex == 0 or veron._Item[heapIndex] ~= h then
			_fail("Pending handle is not at its _HeapIndex slot", label)
		end
	elseif state == PAUSED then
		if heapIndex ~= 0 then _fail("Paused handle has a _HeapIndex", label) end
		if veron._Paused[h] == nil then _fail("Paused handle is not a key of _Paused", label) end
	elseif state == CHAINED then
		if heapIndex ~= 0 then _fail("Chained handle has a _HeapIndex", label) end
		if h._IsRecur then _fail("Chained handle is recurring", label) end
		if veron._Paused[h] ~= nil then _fail("Chained handle is a key of _Paused", label) end
	end
	if state ~= PAUSED and veron._Paused[h] ~= nil then
		_fail("non-Paused handle is a key of _Paused", label)
	end
end

--[[
	Walks a handle's `_Chained` list (recursively), counting still-CHAINED descendants and
	checking each entry's shape. `visited` catches a handle registered in two lists.
	Returns the number of CHAINED handles found under `h`.
]]
local function _walkChained(veron, h, visited, where, allowChained)
	local list = h._Chained
	if not list then return 0 end
	local found = 0
	for index = 1, #list do
		local child = list[index]
		local childWhere = ("%s._Chained[%d]"):format(where, index)
		_checkHandleShape(veron, child, childWhere)
		if child._State == CHAINED then
			if not allowChained then
				_fail("Chained child registered under a terminal parent", _describeHandle(child) .. " via " .. childWhere)
			end
			if visited[child] then _fail("Chained handle reachable from two lists", _describeHandle(child)) end
			visited[child] = true
			found += 1 + _walkChained(veron, child, visited, childWhere, true)
		end
	end
	return found
end

--[[
	The independent walk. `visitedInstances` guards the recursion into attached children.
]]
local function _check(veron, visitedInstances)
	if type(veron) ~= "table" then _fail("check needs a table", typeof(veron)) end
	if visitedInstances[veron] then return end
	visitedInstances[veron] = true

	-- 0. the instance's own Validate must agree (called through the ORIGINAL closure)
	local own = originals[veron]
	local validate = own and own.Validate or rawget(veron, "Validate")
	if type(validate) == "function" then
		local ok, reason = validate(veron)
		if ok ~= true then _fail("Validate() reported", reason) end
	end

	for _, field in REQUIRED_FIELDS do
		if veron[field] == nil then _fail("instance field is nil", field) end
	end

	local due, item, n = veron._Due, veron._Item, veron._N
	if type(due) ~= "table" or type(item) ~= "table" then _fail("_Due/_Item are not tables") end
	if not _isInteger(n) or n < 0 then _fail("_N is not an integer >= 0", n) end

	-- 1. array shape: exactly N slots, tails cleared
	for slot = 1, n do
		if due[slot] == nil then _fail("_Due has a hole below _N", "slot " .. slot) end
		if item[slot] == nil then _fail("_Item has a hole below _N", "slot " .. slot) end
	end
	if due[n + 1] ~= nil then _fail("#_Due exceeds _N", "slot " .. (n + 1) .. " is set") end
	if item[n + 1] ~= nil then _fail("#_Item exceeds _N", "slot " .. (n + 1) .. " is set") end
	if #due ~= n then _fail("#_Due ~= _N", ("%d vs %d"):format(#due, n)) end
	if #item ~= n then _fail("#_Item ~= _N", ("%d vs %d"):format(#item, n)) end

	-- 2. heap slots: finite dues, ownership, Pending, heap property on (due, Id), unique Ids
	local ids = {}
	local recurCount = 0
	for slot = 1, n do
		local d = due[slot]
		if not _isFiniteNumber(d) then _fail("_Due holds a non-finite number", ("slot %d = %s"):format(slot, tostring(d))) end
		local h = item[slot]
		if type(h) ~= "table" then _fail("_Item slot is not a handle", "slot " .. slot) end
		if h._HeapIndex ~= slot then
			_fail("_Item[h._HeapIndex] ~= h",
				("slot %d holds %s with _HeapIndex %s"):format(slot, _describeHandle(h), tostring(h._HeapIndex)))
		end
		if h._State ~= PENDING then
			_fail("heap slot holds a non-Pending handle", ("slot %d holds %s"):format(slot, _describeHandle(h)))
		end
		_checkHandleShape(veron, h, "_Item[" .. slot .. "]")
		if ids[h.Id] then _fail("duplicate handle Id in the heap", "#" .. tostring(h.Id)) end
		ids[h.Id] = true
		if slot > 1 then
			local parent = slot // 2
			if _lessThan(d, h.Id, due[parent], item[parent].Id) then
				_fail("heap property violated", ("slot %d (due %s, #%s) sorts above its parent slot %d (due %s, #%s)"):format(
					slot, tostring(d), tostring(h.Id), parent, tostring(due[parent]), tostring(item[parent].Id)))
			end
		end
		if h._IsRecur then recurCount += 1 end
	end

	-- 3. paused set: membership ⇔ state, frozen remaining finite >= 0, count
	local paused = veron._Paused
	if type(paused) ~= "table" then _fail("_Paused is not a table") end
	local pausedCount = 0
	for h, remaining in pairs(paused) do
		pausedCount += 1
		if type(h) ~= "table" then _fail("_Paused key is not a handle", tostring(h)) end
		if h._State ~= PAUSED then _fail("_Paused key is not Paused", _describeHandle(h)) end
		if not _isFiniteNumber(remaining) or remaining < 0 then
			_fail("_Paused remaining is not a finite number >= 0", ("%s = %s"):format(_describeHandle(h), tostring(remaining)))
		end
		_checkHandleShape(veron, h, "_Paused")
		if ids[h.Id] then _fail("duplicate handle Id between heap and _Paused", "#" .. tostring(h.Id)) end
		ids[h.Id] = true
		if h._IsRecur then recurCount += 1 end
	end
	if pausedCount ~= veron._PausedCount then
		_fail("_PausedCount ~= count(_Paused)", ("%s vs %d"):format(tostring(veron._PausedCount), pausedCount))
	end

	-- 4. chained lists of live handles (heap + paused), recursively
	local visitedChained = {}
	local chainedCount = 0
	for slot = 1, n do
		chainedCount += _walkChained(veron, item[slot], visitedChained, "_Item[" .. slot .. "]", true)
	end
	for h in pairs(paused) do
		chainedCount += _walkChained(veron, h, visitedChained, "_Paused[" .. _describeHandle(h) .. "]", true)
	end

	-- 5. every handle the registry knows about (terminal ones included)
	for h, owner in pairs(seen) do
		if owner == veron then
			_checkHandleShape(veron, h, "registry")
			if h._State >= FIRED then
				_walkChained(veron, h, visitedChained, "registry " .. _describeHandle(h), false)
			elseif h._State == CHAINED and not visitedChained[h] then
				_fail("Chained handle is not reachable from any live handle's _Chained list", _describeHandle(h))
			end
		end
	end

	if chainedCount ~= veron._ChainedCount then
		_fail("_ChainedCount ~= reachable Chained handles", ("%s vs %d"):format(tostring(veron._ChainedCount), chainedCount))
	end
	if recurCount ~= veron._RecurCount then
		_fail("_RecurCount ~= recurring handles that are Pending or Paused",
			("%s vs %d"):format(tostring(veron._RecurCount), recurCount))
	end

	-- 6. firing triple vs depth counters
	local updateDepth, syncDepth = veron._UpdateDepth, veron._SyncDepth
	if not _isInteger(updateDepth) or updateDepth < 0 then _fail("_UpdateDepth is not an integer >= 0", updateDepth) end
	if not _isInteger(syncDepth) or syncDepth < 0 then _fail("_SyncDepth is not an integer >= 0", syncDepth) end
	local base, firing, thread = veron._Base, veron._Firing, veron._FiringThread
	if base ~= false and not _isFiniteNumber(base) then _fail("_Base is neither false nor a finite number", base) end
	if firing ~= false then
		if type(firing) ~= "table" then _fail("_Firing is neither false nor a handle", firing) end
		_checkHandleShape(veron, firing, "_Firing")
	end
	if thread ~= false and type(thread) ~= "thread" then _fail("_FiringThread is neither false nor a thread", thread) end
	if updateDepth == 0 and syncDepth == 0 then
		if base ~= false then _fail("_Base set while idle (depth 0, sync 0)", base) end
		if firing ~= false then _fail("_Firing set while idle (depth 0, sync 0)", _describeHandle(firing)) end
		if thread ~= false then _fail("_FiringThread set while idle (depth 0, sync 0)") end
	end

	-- 7. attached children
	local children = veron._Children
	if type(children) ~= "table" then _fail("_Children is not a table") end
	local childCount = _countKeys(children)
	if childCount ~= veron._ChildCount then
		_fail("_ChildCount ~= count(_Children)", ("%s vs %d"):format(tostring(veron._ChildCount), childCount))
	end
	for child in pairs(children) do
		if type(child) ~= "table" then _fail("_Children key is not a Veron", tostring(child)) end
		if child._Parent ~= veron then _fail("attached child does not point back at its parent", tostring(child.Name)) end
		_check(child, visitedInstances)
	end
end

--[[
	Public entry: raises with the first violated invariant, returns nothing.
]]
function Oracle.check(veron)
	_check(veron, {})
end

--[[
	Records a handle in the weak registry when `value` looks like one of `veron`'s handles.
]]
local function _remember(value)
	if type(value) == "table" then
		local owner = rawget(value, "_Scheduler")
		if type(owner) == "table" and rawget(value, "_State") ~= nil then
			seen[value] = owner
		end
	end
end

--[[
	Builds the wrapper for one per-instance closure: run the original, register a returned
	handle, check the instance, hand every result back. Arguments are forwarded untouched so the
	dual dot/colon detection (`first == self`) still sees what the caller passed.
]]
local function _wrapInstanceClosure(veron, original)
	return function(...)
		local results = table.pack(pcall(original, ...))
		if not results[1] then error(results[2], 0) end
		_remember(results[2])
		Oracle.check(veron)
		return table.unpack(results, 2, results.n)
	end
end

--[[
	Builds the wrapper for one VeronEvent method: run the original (the colon guard inside it
	still receives whatever the caller passed as `self`), then check the handle's owner.
]]
local function _wrapHandleMethod(original)
	return function(self, ...)
		local results = table.pack(pcall(original, self, ...))
		if not results[1] then error(results[2], 0) end
		_remember(self)
		_remember(results[2])
		local owner = type(self) == "table" and rawget(self, "_Scheduler")
		if type(owner) == "table" then Oracle.check(owner) end
		return table.unpack(results, 2, results.n)
	end
end

--[[
	Once per process: wrap every public method on the VeronEvent table in place. Required
	lazily so this module loads before the class exists.
]]
local function _wrapHandleDict()
	if handleDictWrapped then return end
	handleDictWrapped = true
	local VeronEvent = require("../../src/Veron/VeronEvent")
	local dict = VeronEvent
	local names = {}
	for name, value in pairs(dict) do
		if type(value) == "function" and type(name) == "string" and name:sub(1, 1) ~= "_" and not DICT_SKIP[name] then
			names[#names + 1] = name
		end
	end
	table.sort(names)
	local wrappers = {}                                                   -- shared original → shared wrapper (aliases)
	for _, name in names do
		local original = rawget(dict, name)
		local wrapper = wrappers[original]
		if wrapper == nil then
			wrapper = _wrapHandleMethod(original)
			wrappers[original] = wrapper
		end
		rawset(dict, name, wrapper)
	end
end

--[[
	Wrap an instance in place and return it. Idempotent.
]]
function Oracle.wrap(veron)
	if type(veron) ~= "table" then error("Oracle.wrap expects a Veron instance, got " .. typeof(veron), 2) end
	_wrapHandleDict()
	if wrappedInstances[veron] then return veron end
	wrappedInstances[veron] = true

	local names = {}
	for key, value in pairs(veron) do
		if type(value) == "function" and type(key) == "string" then names[#names + 1] = key end
	end
	table.sort(names)
	local saved = {}
	local wrappers = {}                                                   -- shared closure → shared wrapper (aliases)
	for _, name in names do
		local original = rawget(veron, name)
		saved[name] = original
		local wrapper = wrappers[original]
		if wrapper == nil then
			wrapper = _wrapInstanceClosure(veron, original)
			wrappers[original] = wrapper
		end
		rawset(veron, name, wrapper)
	end
	originals[veron] = saved
	Oracle.check(veron)
	return veron
end

--[[
	Kept for symmetry with wrap; wrapping is permanent for the process.
]]
function Oracle.unwrap()
end

--[[
	Registers a handle obtained outside a wrapped call (e.g. built by hand in a spec) so the
	next check audits it too.
]]
function Oracle.track(h)
	_remember(h)
	return h
end

--[[
	The NOOP a Stopped handle carries (nil while nothing has captured it yet). A hand-built fake
	uses it so its Stopped handles agree with the real class in the same process.
]]
function Oracle.noop()
	return _captureNoop()
end

return Oracle

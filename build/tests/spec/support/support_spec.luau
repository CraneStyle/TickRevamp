--!nonstrict
--[[
	build/tests/spec/support/support_spec.luau — smoke tests for the WP2 test support
	(oracle / legacy adapter / generator). Runs without the Veron class: the oracle is exercised
	on a hand-built fake carrying the §3.2 fields.
]]

local Oracle = require("../../support/oracle")
local Legacy = require("../../support/legacy")
local Gen = require("../../support/gen")

local PENDING, PAUSED, CHAINED, FIRED, STOPPED = 1, 2, 3, 4, 5

--[[
	A consistent fake Veron: three Pending handles in a valid (due, Id) heap, one Paused
	recurring, one Chained child under the first Pending handle, one Stopped child in the same
	list. Its Validate lies (always true) so only the oracle's own walk can catch corruption.
]]
local function buildFake()
	local noop = Oracle.noop() or function() end
	local fake = {
		Name = "Fake",
		_Due = {}, _Item = {}, _N = 0,
		_Paused = {}, _PausedCount = 0,
		_Children = {}, _ChildCount = 0,
		_ChainedCount = 0, _RecurCount = 0,
		_UpdateDepth = 0, _SyncDepth = 0,
		_Base = false, _Firing = false, _FiringThread = false,
		Validate = function() return true end,
	}
	local function handle(id, state, isRecur, fn)
		return {
			Id = id, _Scheduler = fake, _Fn = fn or function() end, _Period = 0.5, _IsRecur = isRecur,
			_State = state, _HeapIndex = 0, _Chained = false, _Burst = 0, _BurstSerial = 0,
			_MaxCatchUp = false, _Flags = 0,
		}
	end
	local function push(h, due)
		local slot = fake._N + 1
		fake._N = slot
		fake._Due[slot] = due
		fake._Item[slot] = h
		h._HeapIndex = slot
	end
	local first = handle(1, PENDING, false)
	push(first, 0.25)
	push(handle(2, PENDING, true), 0.5)
	push(handle(3, PENDING, false), 0.5)
	fake._RecurCount = 1

	local paused = handle(4, PAUSED, true)
	fake._Paused[paused] = 0.125
	fake._PausedCount = 1
	fake._RecurCount += 1

	local chained = handle(5, CHAINED, false)
	local stopped = handle(6, STOPPED, false, noop)
	first._Chained = { chained, stopped }
	fake._ChainedCount = 1
	return fake, { first = first, paused = paused, chained = chained, stopped = stopped }
end

local function isDyadic64(value)
	return type(value) == "number" and (value * 64) % 1 == 0 and value >= 1 / 64 and value <= 1
end

return function(t)
	t.test("legacy adapter fires a delay and a recurring through the shim", function()
		local group = Legacy.group()
		local fired = {}
		local one = Legacy.delay(group, function() fired[#fired + 1] = "one" end, 2 / 64)
		local rec = Legacy.recur(group, function() fired[#fired + 1] = "rec" end, 1 / 64)
		t.eq(Legacy.getClocks(group), 2, "two clocks")
		Legacy.update(group, 1 / 64)
		t.eq(table.concat(fired, ","), "rec", "only the recurring after one grid step")
		Legacy.update(group, 1 / 64)
		local second = { fired[2], fired[3] }                            -- legacy walks newest-first (L-13): compare sorted
		table.sort(second)
		t.eq(fired[1] .. "," .. table.concat(second, ","), "rec,one,rec", "one-shot fires on its grid point")
		Legacy.stop(rec)
		Legacy.update(group, 1 / 64)
		t.eq(#fired, 3, "stopped recurring fires no more")
		t.eq(Legacy.getClocks(group), 0, "both released")
		local child = Legacy.after(one, function() fired[#fired + 1] = "child" end, 1 / 64)
		t.eq(type(child), "table", "after returns an event")
		Legacy.reset(one)
		Legacy.adjust(one, 4 / 64)
		t.eq(Legacy.Tick.group ~= nil, true, "the shim module is exposed")
	end)

	t.test("generator is deterministic for a seed and honours the parity constraints", function()
		local a = Gen.new(20260916):sequence(300, { lagLimit = 8 })
		local b = Gen.new(20260916):sequence(300, { lagLimit = 8 })
		local c = Gen.new(7):sequence(300, { lagLimit = 8 })
		t.eq(#a, 300, "exactly n steps")
		local same, differs = true, false
		for index = 1, 300 do
			local x, y, z = a[index], b[index], c[index]
			for key, value in x do
				if type(value) == "table" then
					if table.concat(y[key], ",") ~= table.concat(value, ",") then same = false end
				elseif y[key] ~= value then
					same = false
				end
			end
			if z.op ~= x.op or z.delay ~= x.delay or z.dt ~= x.dt then differs = true end
		end
		t.eq(same, true, "same seed → identical steps")
		t.eq(differs, true, "another seed → different steps")

		local kinds = {}                                                -- id → "oneshot" | "recur"
		local counts = {}
		local sawNest, sawAfter, sawAdjust = false, false, false
		for _, step in a do
			counts[step.op] = (counts[step.op] or 0) + 1
			if step.op == "delay" then
				t.eq(isDyadic64(step.delay), true, "delay is k/64")
				kinds[step.id] = "oneshot"
			elseif step.op == "recur" then
				t.eq(isDyadic64(step.period), true, "period is k/64")
				kinds[step.id] = "recur"
			elseif step.op == "after" or step.op == "nest" then
				t.eq(isDyadic64(step.delay), true, "child delay is k/64")
				t.eq(step.delay >= 1 / 16, true, "child/nested delay >= 1/16")
				t.eq(kinds[step.parent], "oneshot", "parent is a one-shot created earlier")
				kinds[step.id] = "oneshot"
				if step.op == "nest" then sawNest = true else sawAfter = true end
			elseif step.op == "stop" or step.op == "reset" or step.op == "adjust" then
				t.eq(kinds[step.target] ~= nil, true, "target created earlier")
				if step.op == "adjust" then
					sawAdjust = true
					t.eq((step.newTotal * 4096) % 1, 0, "newTotal on the 1/4096 grid")
				end
			elseif step.op == "update" then
				t.eq(step.dt == 1 / 64 or step.dt == 1 / 32, true, "dt is 1/64 or 1/32")
			else
				error("unknown op " .. tostring(step.op))
			end
		end
		t.eq(counts.update > 0 and counts.delay > 0 and counts.recur > 0 and counts.stop > 0, true, "every core op appears")
		t.eq(sawNest and sawAfter and sawAdjust, true, "nest, after and adjust appear")

		-- lagLimit: with a coarse dt list the generator must still refuse to owe > 1 fire per update,
		-- which forbids any dt >= 2 × the smallest LIVE recurring period (owed would be >= 2)
		local capped = Gen.new(3):sequence(200, { lagLimit = 1, dts = { 1 / 64, 1 / 32, 1 / 4 } })
		local livePeriod = {}
		local sawCoarse = false
		for _, step in capped do
			if step.op == "recur" then
				livePeriod[step.id] = step.period
			elseif step.op == "adjust" and livePeriod[step.target] then
				livePeriod[step.target] = step.newTotal
			elseif step.op == "stop" then
				livePeriod[step.target] = nil
			elseif step.op == "update" then
				if step.dt == 1 / 4 then sawCoarse = true end
				for _, period in livePeriod do
					t.eq(step.dt < 2 * period, true, "an update never owes 2 fires under lagLimit 1")
				end
			end
		end
		t.eq(sawCoarse, true, "the coarse dt is still used when nothing recurring is live")
	end)

	t.test("oracle.check accepts a consistent fake and raises on each corruption naming the invariant", function()
		local fake = buildFake()
		Oracle.check(fake)

		local function corrupt(mutate, pattern)
			local instance, handles = buildFake()
			mutate(instance, handles)
			t.throws(function() Oracle.check(instance) end, pattern)
		end
		corrupt(function(instance) instance._Due[1], instance._Due[2] = 0.75, 0.25 end, "heap property violated")
		corrupt(function(instance) instance._Item[3]._HeapIndex = 2 end, "_HeapIndex")
		corrupt(function(instance) instance._N = 2 end, "exceeds _N")
		corrupt(function(instance) instance._Due[3] = 0 / 0 end, "non%-finite")
		corrupt(function(instance) instance._Item[1]._State = FIRED end, "non%-Pending")
		corrupt(function(instance, handles) handles.paused._HeapIndex = 7 end, "Paused handle has a _HeapIndex")
		corrupt(function(instance) instance._PausedCount = 0 end, "_PausedCount")
		corrupt(function(instance) instance._ChainedCount = 2 end, "_ChainedCount")
		corrupt(function(instance) instance._RecurCount = 5 end, "_RecurCount")
		corrupt(function(instance) instance._ChildCount = 1 end, "_ChildCount")
		corrupt(function(instance, handles) handles.stopped._Flags = 4 end, "terminal handle has non%-zero _Flags")
		corrupt(function(instance, handles) handles.stopped._Fn = function() end end, "not the NOOP")
		corrupt(function(instance, handles) handles.first._Flags = 8 end, "_Flags >= 4")
		corrupt(function(instance) instance._Base = 1.5 end, "_Base set while idle")
		corrupt(function(instance, handles) handles.chained._Scheduler = {} end, "another scheduler")
	end)

	t.test("oracle.wrap is refused for non-tables and unwrap is a harmless no-op", function()
		t.throws(function() Oracle.wrap(nil) end, "Oracle.wrap expects")
		Oracle.unwrap()
	end)
end

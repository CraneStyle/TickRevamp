--!nonstrict
--[[
	build/tests/support/gen.luau — seeded deterministic op generator for the parity harness
	(DESIGN §9 parity_spec constraints, §12 WP2). Never touches math.random.

		local gen = Gen.new(20260916)
		local steps = gen:sequence(200, { lagLimit = 8 })

	Step shapes (plain data; the harness interprets them against BOTH schedulers):
		{ op = "delay",  id = n, delay = x }                 top-level one-shot
		{ op = "recur",  id = n, period = x }                top-level recurring (harness arms
		                                                     Veron with Recur(fn, p, true))
		{ op = "after",  id = n, parent = p, delay = x }     chained child of a live one-shot
		{ op = "nest",   id = n, parent = p, delay = x }     one-shot created INSIDE the parent's
		                                                     callback (parent is a one-shot that
		                                                     has not fired yet)
		{ op = "stop",   target = p }                        top-level, created handle only
		{ op = "reset",  target = p }
		{ op = "adjust", target = p, newTotal = x }          x = current total × 2^m
		{ op = "update", dt = x, expect = { id, id, … } }  `expect` = the ids the generator's
		                                                     own model says fire in this update,
		                                                     sorted ascending, one entry per fire
		                                                     (a recurring owing 2 appears twice);
		                                                     a harness may use it to localize a
		                                                     mismatch, or ignore it
	`id`s ascend from 1 per sequence; a "nest" handle exists only once its parent has fired,
	and the generator never targets it before that.

	Numbers: every delay is DYADIC (k/64, k in 1..64), dt is 1/64 or 1/32 (constraints.dts may
	widen it, max 1/2), so both schedulers compute the same exact doubles (B-20).

	Parity constraints honoured (DV-2/7/8/9 and the legacy `after` quirks):
	  - stop/reset/adjust are top-level steps only (never from inside callbacks);
	  - "nest" parents are one-shots only (never a recurring callback);
	  - nested and chained delays are >= 1/16 and > every dt, so a nested delay never lands
	    at or below the parent's overshoot (legacy would fire it synchronously / next update);
	  - "stop" never targets a chained child before its parent fired (legacy still arms it);
	  - "after" only on a live, unfired one-shot (legacy never fires a child added to a
	    fired/stopped parent; Veron arms it);
	  - "adjust" only when remaining/total is an exact dyadic ratio and the new values stay
	    on the 1/4096 grid (both sides then compute identical doubles);
	  - constraints.lagLimit = L: no update lets any live recurring owe more than L fires.

	The generator carries a tiny exact model of both schedulers (integer time in 1/4096 s) to
	decide legality; its per-update fire lists (`expect`) were checked against the legacy shim
	over 300 seeds × 400 steps when this file was written (build/tests/scratch, WP2).
]]

local Gen = {}
Gen.__index = Gen

local UNIT = 4096                                                         -- model grid: 2^-12 s
local GRID = UNIT // 64                                                   -- one 1/64 s in units (64)
local MAX_K = 64                                                          -- delays k/64, k in 1..64
local DEFAULT_DTS = { 1 / 64, 1 / 32 }
local NEST_MIN = 1 / 16
local MAX_DT = 1 / 2

-- Park-Miller minimal standard LCG (48271 × 2^31 < 2^53, so every product is exact).
local LCG_MULT = 48271
local LCG_MOD = 2147483647

-- op weights (relative)
local WEIGHTS = {
	{ "update", 35 }, { "delay", 20 }, { "recur", 10 }, { "stop", 10 },
	{ "reset", 7 }, { "adjust", 7 }, { "after", 6 }, { "nest", 5 },
}
local WEIGHT_TOTAL = 0
for _, entry in WEIGHTS do WEIGHT_TOTAL += entry[2] end

local function _gcd(a, b)
	while b ~= 0 do a, b = b, a % b end
	return a
end

local function _isPowerOfTwo(value)
	if value < 1 then return false end
	while value % 2 == 0 do value /= 2 end
	return value == 1
end

--[[
	True when `numerator/denominator` (integers) is exactly representable, i.e. the reduced
	denominator is a power of two.
]]
local function _ratioExact(numerator, denominator)
	local divisor = _gcd(numerator, denominator)
	return _isPowerOfTwo(denominator / divisor)
end

--[[
	Converts a dyadic number of seconds to model units; errors when it is off the grid.
]]
local function _toUnits(seconds)
	local units = seconds * UNIT
	if units % 1 ~= 0 then error(("Gen: %s is not on the 1/4096 grid"):format(tostring(seconds)), 3) end
	return units
end

function Gen.new(seed)
	if type(seed) ~= "number" or seed ~= seed or seed % 1 ~= 0 then
		error("Gen.new expects an integer seed, got " .. tostring(seed), 2)
	end
	local self = setmetatable({}, Gen)
	self.Seed = seed
	self._State = (math.abs(seed) % (LCG_MOD - 1)) + 1                   -- 1 .. LCG_MOD-1, never 0
	return self
end

--[[
	Next raw value in 1 .. 2^31-2.
]]
function Gen:next()
	local state = (self._State * LCG_MULT) % LCG_MOD
	self._State = state
	return state
end

--[[
	Uniform integer in lo..hi (inclusive).
]]
function Gen:int(lo, hi)
	if hi < lo then error(("Gen:int: empty range %d..%d"):format(lo, hi), 2) end
	return lo + (self:next() % (hi - lo + 1))
end

--[[
	A uniformly picked element of a non-empty list.
]]
function Gen:pick(list)
	return list[self:int(1, #list)]
end

--[[
	Weighted op choice from WEIGHTS.
]]
local function _pickOp(gen)
	local roll = gen:int(1, WEIGHT_TOTAL)
	for _, entry in WEIGHTS do
		roll -= entry[2]
		if roll <= 0 then return entry[1] end
	end
	return "update"
end

--[[
	Advances the exact model to `now + dt`: fires everything due (recurring re-keys, one-shots
	become fired and arm their chained children / nested delays from their ideal due).
]]
local function _advanceModel(model, dtUnits)
	local target = model.Now + dtUnits
	model.Now = target
	local fired = {}
	local progressed = true
	while progressed do                                       -- children armed this step could be due too (never, by
		progressed = false                                    -- construction, but the loop keeps the model honest)
		for _, h in model.Handles do
			if h.Status == "pending" and h.Due <= target then
				if h.Recur then
					while h.Due <= target do
						h.Due += h.Total
						fired[#fired + 1] = h.Id
					end
				else
					h.Status = "fired"
					fired[#fired + 1] = h.Id
					local fireAt = h.Due
					for _, child in h.Children do
						if child.Status == "chained" then
							child.Status = "pending"
							child.Due = fireAt + child.Total
						end
					end
					for _, nested in h.Nests do
						nested.Status = "pending"
						nested.Due = fireAt + nested.Total
					end
					progressed = true
				end
			end
		end
	end
	table.sort(fired)
	return fired
end

--[[
	How many fires the live recurring handles would owe over `dtUnits`; the largest count.
]]
local function _maxOwed(model, dtUnits)
	local target = model.Now + dtUnits
	local worst = 0
	for _, h in model.Handles do
		if h.Recur and h.Status == "pending" then
			local owed = 0
			local due = h.Due
			while due <= target do owed += 1; due += h.Total end
			if owed > worst then worst = owed end
		end
	end
	return worst
end

--[[
	Live one-shots the harness holds a handle for: pending (armed) or chained (unarmed child)
	or a nest that has been created (its parent fired → it is pending). Filtered by `predicate`.
]]
local function _collect(model, predicate)
	local out = {}
	for _, h in model.Handles do
		if predicate(h) then out[#out + 1] = h end
	end
	return out
end

-- Statuses: pending | chained | fired | stopped (the harness holds a handle) ;
--           uncreated (a nest whose parent has not fired) | never (its parent was stopped first).
local function _created(h)
	return h.Status ~= "uncreated" and h.Status ~= "never"
end

--[[
	Generates `count` steps under `constraints` (see the header). Deterministic per seed.
]]
function Gen:sequence(count, constraints)
	constraints = constraints or {}
	local dts = constraints.dts or DEFAULT_DTS
	local lagLimit = constraints.lagLimit
	local maxHandles = constraints.maxHandles or 12

	local dtUnits = {}
	local maxDt = 0
	for index, dt in dts do
		if type(dt) ~= "number" or dt <= 0 or dt > MAX_DT then
			error("Gen: constraints.dts entries must be in (0, 1/2]", 2)
		end
		dtUnits[index] = _toUnits(dt)
		if dt > maxDt then maxDt = dt end
	end
	table.sort(dtUnits)
	local nestMinK = math.max(NEST_MIN * 64, maxDt * 64 + 1)             -- >= 1/16 AND > every dt (strict)
	if nestMinK > MAX_K then error("Gen: constraints.dts too coarse for a nested delay <= 1", 2) end

	local model = { Now = 0, Handles = {} }
	local steps = {}
	local nextId = 0

	local function newHandle(status, recur, totalUnits)
		nextId += 1
		local h = { Id = nextId, Status = status, Recur = recur, Total = totalUnits, Due = false, Children = {}, Nests = {} }
		model.Handles[#model.Handles + 1] = h
		return h
	end

	local function liveCount()
		local live = 0
		for _, h in model.Handles do
			if h.Status == "pending" or h.Status == "chained" then live += 1 end
		end
		return live
	end

	local function emitUpdate()
		local choice = self:pick(dtUnits)
		if lagLimit then
			while _maxOwed(model, choice) > lagLimit do              -- smallest dt (1/64) with period >= 1/64 owes <= 1
				local smaller = nil
				for _, candidate in dtUnits do
					if candidate < choice and (smaller == nil or candidate > smaller) then smaller = candidate end
				end
				if smaller == nil then break end
				choice = smaller
			end
			if _maxOwed(model, choice) > lagLimit then return false end
		end
		local expect = _advanceModel(model, choice)
		steps[#steps + 1] = { op = "update", dt = choice / UNIT, expect = expect }
		return true
	end

	local function emitDelay()
		if liveCount() >= maxHandles then return false end
		local k = self:int(1, MAX_K)
		local h = newHandle("pending", false, k * GRID)
		h.Due = model.Now + h.Total
		steps[#steps + 1] = { op = "delay", id = h.Id, delay = k / 64 }
		return true
	end

	local function emitRecur()
		if liveCount() >= maxHandles then return false end
		local k = self:int(1, MAX_K)
		local h = newHandle("pending", true, k * GRID)
		h.Due = model.Now + h.Total
		steps[#steps + 1] = { op = "recur", id = h.Id, period = k / 64 }
		return true
	end

	local function emitAfter()
		if liveCount() >= maxHandles then return false end
		local parents = _collect(model, function(h)
			return not h.Recur and (h.Status == "pending" or h.Status == "chained")
		end)
		if #parents == 0 then return false end
		local parent = self:pick(parents)
		local k = self:int(nestMinK, MAX_K)
		local child = newHandle("chained", false, k * GRID)
		parent.Children[#parent.Children + 1] = child
		steps[#steps + 1] = { op = "after", id = child.Id, parent = parent.Id, delay = k / 64 }
		return true
	end

	local function emitNest()
		if liveCount() >= maxHandles then return false end
		local parents = _collect(model, function(h)
			return not h.Recur and (h.Status == "pending" or h.Status == "chained")
		end)
		if #parents == 0 then return false end
		local parent = self:pick(parents)
		local k = self:int(nestMinK, MAX_K)
		local nested = newHandle("uncreated", false, k * GRID)
		parent.Nests[#parent.Nests + 1] = nested
		steps[#steps + 1] = { op = "nest", id = nested.Id, parent = parent.Id, delay = k / 64 }
		return true
	end

	local function stopModel(h)
		if h.Status == "pending" then
			h.Status = "stopped"
			for _, child in h.Children do                                -- cascade: unarmed children never fire on either side
				if child.Status == "chained" then stopModel(child) end
			end
			for _, nested in h.Nests do
				if nested.Status == "uncreated" then nested.Status = "never" end   -- the harness never gets a handle
			end
		end
	end

	local function emitStop()
		local targets = _collect(model, function(h)
			return _created(h) and h.Status ~= "chained"                  -- legacy still arms a stopped unarmed child
		end)
		if #targets == 0 then return false end
		local target = self:pick(targets)
		stopModel(target)
		steps[#steps + 1] = { op = "stop", target = target.Id }
		return true
	end

	local function emitReset()
		local targets = _collect(model, _created)
		if #targets == 0 then return false end
		local target = self:pick(targets)
		if target.Status == "pending" then target.Due = model.Now + target.Total end
		steps[#steps + 1] = { op = "reset", target = target.Id }
		return true
	end

	local function emitAdjust()
		local targets = _collect(model, _created)
		if #targets == 0 then return false end
		local target = self:pick(targets)
		local factor = self:pick({ 0.5, 2, 4 })
		local total = target.Total
		local newTotal = total * factor
		if newTotal % 1 ~= 0 or newTotal > 4 * UNIT then return false end
		if target.Status == "pending" then
			local remaining = target.Due - model.Now
			local newRemaining = remaining * factor
			if newRemaining % 1 ~= 0 or not _ratioExact(remaining, total) then return false end
			target.Due = model.Now + newRemaining
		end
		target.Total = newTotal                                          -- fired/stopped: harmless on both sides
		steps[#steps + 1] = { op = "adjust", target = target.Id, newTotal = newTotal / UNIT }
		return true
	end

	local emitters = {
		update = emitUpdate, delay = emitDelay, recur = emitRecur, after = emitAfter,
		nest = emitNest, stop = emitStop, reset = emitReset, adjust = emitAdjust,
	}

	local stalls = 0
	while #steps < count do
		local before = #steps
		local op = _pickOp(self)
		if not emitters[op]() and not emitUpdate() then emitDelay() end  -- always try to make progress
		if #steps == before then
			stalls += 1
			if stalls > 1000 then error("Gen: constraints leave no legal step (dts/lagLimit/maxHandles conflict)", 2) end
		else
			stalls = 0
		end
	end
	return steps
end

return Gen

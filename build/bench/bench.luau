--!nonstrict
--[[
	bench.luau — the Veron benchmark of docs/DESIGN.md §10 (phases P1–P10,
	P12, P14, P15; seed 20260916; median of 5) under Lune 0.10.5. P11 (the
	handle-literal vs BaseClass Class:new comparator) was removed with the
	BaseClass dependency; P13 never existed. Phase ids stay stable (§10).

	Run from the workspace root:  lune run build/bench/bench.luau

	One line per phase: the timing (ns/op, µs/update, ns/dispatch), the
	garbage measured over the phase (max `collectgarbage("count")` delta
	over the reps, in bytes) and the §10 invariant assertions inline as
	`[ok …]` / `[FAIL …]`. Timing TARGETS are reported as `met`/`MISSED`
	and never fail the run (§10: timings are reported, not asserted, under
	Lune); structural invariants (sizes, counts, zero garbage) fail the
	run — the exit code is 1 when any of them fails.

	P14 drives reference/lune/Tick.luau (the live legacy core minus its
	RunService line) through the same phases as the legacy baseline and
	prints the "×" ratios. Numbers and method: build/bench/BENCH.md.

	Layout: the ==== HEADER ==== block below resolves the platform (Lune
	requires); everything from ==== BODY ==== on is byte-identical to
	build/bench/studio_bench.luau, which only swaps the header for
	ReplicatedStorage requires. Keep the two bodies identical.
]]

-- ==== HEADER (Lune) ====

local process = require("@lune/process")

local Veron = require("../src/Veron")
local VeronEvent = require("../src/Veron/VeronEvent")
local LegacyTick = require("../../reference/lune/Tick")

local deps = {
	Veron = Veron,
	VeronEvent = VeronEvent,
	LegacyTick = LegacyTick,
	Platform = "Lune 0.10.5 (interpreter; the Veron module's --!native has no effect here)",
	Exit = function(code)
		process.exit(code)
	end,
}

-- ==== BODY (identical in studio_bench.luau) ====

local function _runBench(deps)
	local Veron = deps.Veron
	local VeronEvent = deps.VeronEvent
	local LegacyTick = deps.LegacyTick

	local clock = os.clock

	local SEED = 20260916
	local N = 10000
	local REPS = 5
	local IDLE_UPDATES = 200
	local IDLE_DT = 0.005
	local FRAME = 1 / 60
	local CHURN_UPDATES = 600
	local CHURN_LIVE = 2000
	local STORM_ROUNDS = 10
	local INSTANCES = 1000

	-- §10 targets (reported, never asserted): the IB prototype numbers of
	-- research/scratch/algos/bench-run3.txt on the design machine
	local PROTO_ARM_NS = 250
	local PROTO_IDLE_US = 0.02
	local PROTO_DISPATCH_NS = 295
	local PROTO_CHURN_US = 25.0
	local DUAL_CALL_NS = 30
	local SPIKE_US = 200

	-- heap-slot headroom per handle in P1: two TValue arrays that double on
	-- the way to 10k entries (the superseded copies count until collected)
	local SLOT_HEADROOM = 128

	local eventDict = VeronEvent
	local veronDict = Veron

	local checks, failures = 0, {}

	local function _noop() end

	local function _bytes()
		return collectgarbage("count") * 1024
	end

	--[[
		Park–Miller LCG (exact in doubles); the same sequence on every
		platform, so a Studio run sees the same dues as a Lune run.
	]]
	local function _rng(seed)
		local state = seed
		return function()
			state = state * 48271 % 2147483647
			return state / 2147483647
		end
	end

	local function _uniform(random, count, lo, hi)
		local values = table.create(count)
		for index = 1, count do
			values[index] = lo + random() * (hi - lo)
		end
		return values
	end

	local function _shuffled(random, count)
		local order = table.create(count)
		for index = 1, count do
			order[index] = index
		end
		for index = count, 2, -1 do
			local other = math.floor(random() * index) + 1
			order[index], order[other] = order[other], order[index]
		end
		return order
	end

	--[[
		Runs `body(setup())` `reps` times; returns the median wall time in
		ms, the largest byte delta any rep saw (a rep without a collector
		step reads the exact allocation; a zero-garbage body reads 0 in
		every rep) and the last context. Every measured window — warm-ups
		included — runs through this one frame, so a window never pays a
		first-call stack growth the warm-up did not (see alloc_spec).
	]]
	local function _measure(body, reps, setup)
		local samples = table.create(reps)
		local maxBytes = -math.huge
		local context
		for rep = 1, reps do
			if setup then
				context = setup(rep)
			end
			local before = _bytes()
			local started = clock()
			body(context, rep)
			local elapsed = clock() - started
			local delta = _bytes() - before
			samples[rep] = elapsed * 1000
			if delta > maxBytes then
				maxBytes = delta
			end
		end
		table.sort(samples)
		return samples[(reps + 1) // 2], maxBytes, context
	end

	local function _warm(body, context)
		_measure(body, 1, function()
			return context
		end)
	end

	local function _check(condition, label)
		checks += 1
		if condition then
			return "[ok " .. label .. "]"
		end
		failures[#failures + 1] = label
		return "[FAIL " .. label .. "]"
	end

	local function _target(value, limit, label)
		local verdict = if value <= limit then "met" else "MISSED"
		return ("[target %s <= %g: %s]"):format(label, limit, verdict)
	end

	local function _line(phase, text)
		print(("%-4s %s"):format(phase, text))
	end

	--[[
		Times every `op(h)` on its own (h = the handles in `order`) and
		returns the largest single call in µs (the spike the §10 P3/P4
		rows watch).
	]]
	local function _spike(handles, order, op)
		local maxUs = 0
		for index = 1, #order do
			local h = handles[order[index]]
			local started = clock()
			op(h)
			local us = (clock() - started) * 1e6
			if us > maxUs then
				maxUs = us
			end
		end
		return maxUs
	end

	local function _armed(name, dues, fn)
		local s = Veron.new({ Name = name })
		local handles = table.create(#dues)
		for index = 1, #dues do
			handles[index] = s:Delay(fn or _noop, dues[index])
		end
		return s, handles
	end

	--[[
		The §3.1 handle literal exactly as `_newEvent` builds it (12 user
		fields + class + type), stamped with the handle dict; never
		scheduled. P1 measures against it.
	]]
	local function _literal(id)
		local h = {
			class = VeronEvent,
			type = "VeronEvent",
			Id = id,
			_Scheduler = false,
			_Fn = _noop,
			_Period = 5,
			_IsRecur = false,
			_State = 1,
			_HeapIndex = 0,
			_Chained = false,
			_Burst = 0,
			_BurstSerial = 0,
			_MaxCatchUp = false,
			_Flags = 0,
		}
		return setmetatable(h, eventDict)
	end

	local function _fill(holder, count, make)
		for index = 1, count do
			holder[index] = make(index)
		end
	end

	--[[
		Bytes one `make(index)` result costs, measured the alloc_spec way:
		the largest per-slot delta over ten 200-slot rounds. A round the
		collector did not step into reads the exact size; a single long
		window would read the size minus whatever a collector step freed
		(which is how a 10k batch once printed "0 B/handle").
	]]
	local function _perSlotBytes(make)
		local holder = table.create(200)
		local _, bytes = _measure(function()
			_fill(holder, 200, make)
		end, 10, function()
			table.clear(holder)
		end)
		return bytes / 200
	end

	print(("Veron bench — %s — seed %d, median of %d, N = %d"):format(deps.Platform, SEED, REPS, N))

	-- literal size, measured the alloc_spec way (max over short rounds)
	local literalBytes = _perSlotBytes(_literal)

	-------------------------------------------------------------------
	-- P1 arm 10k random dues
	-------------------------------------------------------------------
	do
		local dues = _uniform(_rng(SEED), N, 10, 20)
		local s
		local ms, bytes = _measure(function()
			s = _armed("P1", dues)
		end, REPS)
		local perHandle = bytes / N
		_line("P1", ("arm 10k random dues: %.3f ms  %.0f ns/op  %.0f B/handle (literal %.0f B + heap slots)  %s %s %s %s")
			:format(ms, ms * 1e6 / N, perHandle, literalBytes,
				_check(s:GetStats().HeapSize == N and s:Validate() == true, "heap 10000, Validate"),
				_check(perHandle >= literalBytes, "bytes/handle >= literal"),
				_check(perHandle <= literalBytes + SLOT_HEADROOM, "bytes/handle <= literal + slots"),
				_target(ms * 1e6 / N, PROTO_ARM_NS * 1.2, "ns/op 1.2x IB")))
		s:Destroy()
	end

	-------------------------------------------------------------------
	-- P2 200 idle updates with 10k armed (the hard zero-garbage line)
	-------------------------------------------------------------------
	do
		local s = _armed("P2", _uniform(_rng(SEED), N, 10, 20))
		local function body()
			for _ = 1, IDLE_UPDATES do
				s:Update(IDLE_DT)
			end
		end
		_warm(body)
		local ms, bytes = _measure(body, REPS)
		local stats = s:GetStats()
		_line("P2", ("200 idle updates, 10k armed: %.3f ms  %.3f us/update  %.0f B  %s %s %s")
			:format(ms, ms * 1e3 / IDLE_UPDATES, bytes,
				_check(bytes == 0, "garbage == 0 B exactly"),
				_check(stats.Dispatched == 0 and stats.Updates == IDLE_UPDATES * (REPS + 1),
					"nothing dispatched, every update counted"),
				_target(ms * 1e3 / IDLE_UPDATES, PROTO_IDLE_US * 2, "us/update 2x IB")))
		s:Destroy()
	end

	-------------------------------------------------------------------
	-- P3 10k shuffled stops
	-------------------------------------------------------------------
	do
		local dues = _uniform(_rng(SEED), N, 10, 20)
		local order = _shuffled(_rng(SEED + 1), N)
		local ms = _measure(function(context)
			local handles = context.handles
			for index = 1, N do
				handles[order[index]]:Stop()
			end
		end, REPS, function()
			local s, handles = _armed("P3", dues)
			return { s = s, handles = handles }
		end)
		local s, handles = _armed("P3s", dues)
		local spikeUs = _spike(handles, order, function(h)
			h:Stop()
		end)
		local stats = s:GetStats()
		_line("P3", ("10k shuffled stops: %.3f ms  %.0f ns/op  max single stop %.1f us  %s %s %s")
			:format(ms, ms * 1e6 / N, spikeUs,
				_check(stats.HeapSize == 0 and stats.Paused == 0 and s:Validate() == true, "heap 0, paused index empty, Validate"),
				_check(stats.Clocks == 0, "GetClocks 0"),
				_target(spikeUs, SPIKE_US, "spike us")))
		s:Destroy()
	end

	-------------------------------------------------------------------
	-- P4 10k shuffled adjusts
	-------------------------------------------------------------------
	do
		local dues = _uniform(_rng(SEED), N, 10, 20)
		local order = _shuffled(_rng(SEED + 1), N)
		local factors = _uniform(_rng(SEED + 2), N, 0.5, 1.5)
		local targets = table.create(N)
		for index = 1, N do
			targets[index] = dues[order[index]] * factors[index]
		end
		local ms, _, context = _measure(function(context)
			local handles = context.handles
			for index = 1, N do
				handles[order[index]]:Adjust(targets[index])
			end
		end, REPS, function()
			local s, handles = _armed("P4", dues)
			return { s = s, handles = handles }
		end)
		local s, handles = _armed("P4s", dues)
		local index = 0
		local spikeUs = _spike(handles, order, function(h)
			index += 1
			h:Adjust(targets[index])
		end)
		local measured = context.s
		_line("P4", ("10k shuffled adjusts: %.3f ms  %.0f ns/op  max single adjust %.1f us  %s %s")
			:format(ms, ms * 1e6 / N, spikeUs,
				_check(measured:GetStats().HeapSize == N and measured:Validate() == true
					and s:GetStats().HeapSize == N, "heap stays 10000 (no orphans), Validate"),
				_target(spikeUs, SPIKE_US, "spike us")))
		s:Destroy()
		measured:Destroy()
	end

	-------------------------------------------------------------------
	-- P5 10k shuffled resets (increase-key path after Update(5))
	-------------------------------------------------------------------
	do
		local dues = _uniform(_rng(SEED), N, 10, 20)
		local order = _shuffled(_rng(SEED + 1), N)
		local ms, _, context = _measure(function(context)
			local handles = context.handles
			for index = 1, N do
				handles[order[index]]:Reset()
			end
		end, REPS, function()
			local s, handles = _armed("P5", dues)
			s:Update(5)
			return { s = s, handles = handles }
		end)
		local s = context.s
		local stats = s:GetStats()
		_line("P5", ("10k shuffled resets: %.3f ms  %.0f ns/op  %s")
			:format(ms, ms * 1e6 / N,
				_check(stats.HeapSize == N and stats.Dispatched == 0 and s:Validate() == true,
					"heap stays 10000, nothing fired, Validate")))
		s:Destroy()
	end

	-------------------------------------------------------------------
	-- P6 fire storm: 10k due in [0, 1], one Update fires all
	-------------------------------------------------------------------
	do
		local dues = _uniform(_rng(SEED), N, 0, 1)
		local fired = 0
		local function count()
			fired += 1
		end
		local ms, _, s = _measure(function(s)
			s:Update(1.0001)
		end, REPS, function()
			fired = 0
			return (_armed("P6", dues, count))
		end)
		local stats = s:GetStats()
		_line("P6", ("fire storm 10k in one update: %.3f ms  %.0f ns/dispatch  %s %s %s")
			:format(ms, ms * 1e6 / N,
				_check(fired == N and stats.Dispatched == N and stats.LastDispatched == N, "all 10000 fired, Dispatched == 10000"),
				_check(stats.ValveHits == 0 and stats.HeapSize == 0 and s:Validate() == true, "ValveHits 0, heap 0, Validate"),
				_target(ms * 1e6 / N, PROTO_DISPATCH_NS * 1.2, "ns/dispatch 1.2x IB")))
		s:Destroy()
	end

	-------------------------------------------------------------------
	-- P7 10k recurring × 600 updates @ 1/60
	-------------------------------------------------------------------
	local veronP7Us
	do
		local periods = _uniform(_rng(SEED), N, 0.5, 1.5)
		local fires = 0
		local function count()
			fires += 1
		end
		local s = Veron.new({ Name = "P7" })
		for index = 1, N do
			s:Recur(count, periods[index])
		end
		local function body()
			for _ = 1, CHURN_UPDATES do
				s:Update(FRAME)
			end
		end
		_warm(body)
		fires = 0
		local ms, bytes = _measure(body, REPS)
		local perRun = fires / REPS
		local stats = s:GetStats()
		veronP7Us = ms * 1e3 / CHURN_UPDATES
		_line("P7", ("10k recurring x 600 updates @ 1/60: %.3f ms  %.1f us/update  %.0f ns/fire"
			.. "  %.0f fires/run  %.0f B  %s %s")
			:format(ms, veronP7Us, ms * 1e6 / perRun, perRun, bytes,
				_check(bytes == 0, "garbage == 0 B exactly"),
				_check(stats.Dropped == 0 and stats.ValveHits == 0 and stats.Recurring == N and s:Validate() == true,
					"Dropped 0, ValveHits 0, 10000 recurring, Validate")))
		s:Destroy()
	end

	-------------------------------------------------------------------
	-- P7b tie-heavy: 10k recurring, equal period, created in one frame
	-------------------------------------------------------------------
	do
		local TIE_UPDATES = 100
		local fires = 0
		local function count()
			fires += 1
		end
		local s = Veron.new({ Name = "P7b" })
		for _ = 1, N do
			s:Recur(count, 1 / 32) -- dyadic: all 10k fire together every 2nd 1/64 update
		end
		local function body()
			for _ = 1, TIE_UPDATES do
				s:Update(1 / 64)
			end
		end
		_warm(body)
		fires = 0
		local ms, bytes = _measure(body, REPS)
		local perRun = fires / REPS
		local stats = s:GetStats()
		_line("P7b", ("tie-heavy 10k recurring, equal period, 100 updates @ 1/64: %.3f ms  %.1f us/update"
			.. "  %.0f ns/fire  %.0f fires/run  %.0f B  %s %s")
			:format(ms, ms * 1e3 / TIE_UPDATES, ms * 1e6 / perRun, perRun, bytes,
				_check(bytes == 0, "garbage == 0 B exactly"),
				_check(perRun == N * TIE_UPDATES / 2 and stats.Dropped == 0 and s:Validate() == true,
					"every handle fires every 2nd update, Dropped 0, Validate")))
		s:Destroy()
	end

	-------------------------------------------------------------------
	-- P8 mixed churn: 2k live; per update 50 arms / 20 stops / 10 adjusts
	-------------------------------------------------------------------
	local veronP8Us
	do
		local function churn(context)
			local s, live, random = context.s, context.live, context.random
			for _ = 1, CHURN_UPDATES do
				for _ = 1, 50 do
					live[#live + 1] = s:Delay(_noop, 0.1 + random() * 1.9)
				end
				for _ = 1, 20 do
					local index = math.floor(random() * #live) + 1
					live[index]:Stop()
					live[index] = live[#live]
					live[#live] = nil
				end
				for _ = 1, 10 do
					local h = live[math.floor(random() * #live) + 1]
					h:Adjust(h:GetPeriod() * (0.5 + random()))
				end
				s:Update(FRAME)
				if #live > 2 * CHURN_LIVE then
					local kept = 0
					for index = 1, #live do
						local h = live[index]
						if h:IsActive() then
							kept += 1
							live[kept] = h
						end
					end
					for index = #live, kept + 1, -1 do
						live[index] = nil
					end
				end
			end
		end
		local ms, bytes, context = _measure(churn, REPS, function()
			local random = _rng(SEED)
			local s = Veron.new({ Name = "P8" })
			local live = {}
			for _ = 1, CHURN_LIVE do
				live[#live + 1] = s:Delay(_noop, 0.1 + random() * 1.9)
			end
			return { s = s, live = live, random = random }
		end)
		local s = context.s
		local stats = s:GetStats()
		veronP8Us = ms * 1e3 / CHURN_UPDATES
		_line("P8", ("mixed churn 600 updates (50 arms / 20 stops / 10 adjusts per update): %.3f ms  %.1f us/update"
			.. "  %.0f KB net growth (max rep; 30k arms x %.0f B minus collector steps)  size after %d  %s %s")
			:format(ms, veronP8Us, bytes / 1024, literalBytes, stats.HeapSize,
				_check(stats.ValveHits == 0 and stats.Errors == 0 and s:Validate() == true, "ValveHits 0, Errors 0, Validate"),
				_target(veronP8Us, PROTO_CHURN_US * 1.15, "us/update +15% vs baseline")))
		s:Destroy()
	end

	-------------------------------------------------------------------
	-- P9 adjust storm: 10 rounds of (adjust all 10k, then one update)
	-------------------------------------------------------------------
	do
		local dues = _uniform(_rng(SEED), N, 10, 20)
		local factors = _uniform(_rng(SEED + 2), N, 0.8, 1.2)
		local s, handles = _armed("P9", dues)
		local maxRoundMs, maxOpUs = 0, 0
		local started = clock()
		for _ = 1, STORM_ROUNDS do
			local roundStarted = clock()
			for index = 1, N do
				local h = handles[index]
				local opStarted = clock()
				h:Adjust(h:GetPeriod() * factors[index])
				local us = (clock() - opStarted) * 1e6
				if us > maxOpUs then
					maxOpUs = us
				end
			end
			s:Update(IDLE_DT)
			local roundMs = (clock() - roundStarted) * 1000
			if roundMs > maxRoundMs then
				maxRoundMs = roundMs
			end
		end
		local totalMs = (clock() - started) * 1000
		local stats = s:GetStats()
		_line("P9", ("adjust storm x10: %.3f ms total  max round %.2f ms  max single op %.1f us  %s")
			:format(totalMs, maxRoundMs, maxOpUs,
				_check(stats.HeapSize == N and stats.Dispatched == 0 and s:Validate() == true,
					"heap 10000 after, nothing fired, Validate")))
		s:Destroy()
	end

	-------------------------------------------------------------------
	-- P10 dual-call overhead: s.delay / s:Delay vs the raw dict method
	-------------------------------------------------------------------
	do
		local dues = _uniform(_rng(SEED), N, 10, 20)
		local rawDelay = veronDict.Delay
		local function fresh()
			return Veron.new({ Name = "P10" })
		end
		local dotMs = _measure(function(s)
			local delay = s.delay
			for index = 1, N do
				delay(_noop, dues[index])
			end
		end, REPS, fresh)
		local colonMs = _measure(function(s)
			for index = 1, N do
				s:Delay(_noop, dues[index])
			end
		end, REPS, fresh)
		local rawMs = _measure(function(s)
			for index = 1, N do
				rawDelay(s, _noop, dues[index])
			end
		end, REPS, fresh)
		local dotNs, colonNs, rawNs = dotMs * 1e6 / N, colonMs * 1e6 / N, rawMs * 1e6 / N
		_line("P10", ("dual-call overhead: s.delay %.0f ns/op  s:Delay %.0f ns/op  raw dict %.0f ns/op"
			.. "  (+%.0f / +%.0f ns)  %s %s")
			:format(dotNs, colonNs, rawNs, dotNs - rawNs, colonNs - rawNs,
				_target(dotNs - rawNs, DUAL_CALL_NS, "dot overhead ns"),
				_target(colonNs - rawNs, DUAL_CALL_NS, "colon overhead ns")))
	end

	-------------------------------------------------------------------
	-- P12 re-entrancy tax: the same 10k storm dispatched at depth 1 vs 0
	-------------------------------------------------------------------
	do
		local dues = _uniform(_rng(SEED), N, 0, 1)
		local fired = 0
		local function count()
			fired += 1
		end
		local function quiet(_message, _h) end -- swallows the re-entry diagnostic
		local topMs, _, top = _measure(function(s)
			s:Update(1.0001)
		end, REPS, function()
			fired = 0
			local s = Veron.new({ Name = "P12a", OnError = quiet })
			for index = 1, N do
				s:Delay(count, dues[index])
			end
			return s
		end)
		local topFired = fired
		local nestedMs, _, nested = _measure(function(s)
			s:Update(0) -- fires the driver, whose callback runs the storm at depth 1
		end, REPS, function()
			fired = 0
			local s = Veron.new({ Name = "P12b", OnError = quiet })
			for index = 1, N do
				s:Delay(count, dues[index])
			end
			s:Delay(function()
				s:Update(1.0001)
			end, 0)
			return s
		end)
		local nestedStats = nested:GetStats()
		local topNs, nestedNs = topMs * 1e6 / N, nestedMs * 1e6 / N
		_line("P12", ("re-entrancy tax: depth 0 %.0f ns/dispatch  depth 1 %.0f ns/dispatch  (%+.1f%%)  %s %s")
			:format(topNs, nestedNs, (nestedNs / topNs - 1) * 100,
				_check(topFired == N and top:GetStats().Dispatched == N, "depth 0: all 10000 fired"),
				_check(fired == N and nestedStats.Dispatched == N + 1 and nestedStats.Reentries == 1
					and nestedStats.ValveHits == 0 and nested:Validate() == true,
					"depth 1: all 10000 fired inside the nested pass, Reentries 1, ValveHits 0, Validate")))
		top:Destroy()
		nested:Destroy()
	end

	-------------------------------------------------------------------
	-- P14 legacy baseline (reference Tick core) on P2 / P7 / P8
	-------------------------------------------------------------------
	if LegacyTick then
		local function legacyGroup()
			return LegacyTick.group()
		end

		-- P2-L
		local idleUs
		do
			local dues = _uniform(_rng(SEED), N, 10, 20)
			local g = legacyGroup()
			for index = 1, N do
				g:delay(_noop, dues[index])
			end
			local function body()
				for _ = 1, IDLE_UPDATES do
					g:update(IDLE_DT)
				end
			end
			_warm(body)
			local ms, bytes = _measure(body, REPS)
			idleUs = ms * 1e3 / IDLE_UPDATES
			_line("P14", ("legacy P2 200 idle updates, 10k armed: %.3f ms  %.3f us/update  %.0f B  clocks %d")
				:format(ms, idleUs, bytes, g:getClocks()))
		end

		-- P7-L
		do
			local periods = _uniform(_rng(SEED), N, 0.5, 1.5)
			local fires = 0
			local function count()
				fires += 1
			end
			local g = legacyGroup()
			for index = 1, N do
				g:recur(count, periods[index])
			end
			local function body()
				for _ = 1, CHURN_UPDATES do
					g:update(FRAME)
				end
			end
			_warm(body)
			fires = 0
			local ms, bytes = _measure(body, REPS)
			local perRun = fires / REPS
			local us = ms * 1e3 / CHURN_UPDATES
			_line("P14", ("legacy P7 10k recurring x 600 updates @ 1/60: %.3f ms  %.1f us/update  %.0f ns/fire"
				.. "  %.0f fires/run  %.0f B  -> Veron is %.1fx faster per update")
				:format(ms, us, ms * 1e6 / perRun, perRun, bytes, us / veronP7Us))
		end

		-- P8-L
		do
			local function churn(context)
				local g, live, random = context.g, context.live, context.random
				for _ = 1, CHURN_UPDATES do
					for _ = 1, 50 do
						live[#live + 1] = g:delay(_noop, 0.1 + random() * 1.9)
					end
					for _ = 1, 20 do
						local index = math.floor(random() * #live) + 1
						live[index]:stop()
						live[index] = live[#live]
						live[#live] = nil
					end
					for _ = 1, 10 do
						local h = live[math.floor(random() * #live) + 1]
						h:adjust(h.delay * (0.5 + random()))
					end
					g:update(FRAME)
					if #live > 2 * CHURN_LIVE then
						local kept = 0
						for index = 1, #live do
							local h = live[index]
							if g[h] == true then
								kept += 1
								live[kept] = h
							end
						end
						for index = #live, kept + 1, -1 do
							live[index] = nil
						end
					end
				end
			end
			local ms, bytes, context = _measure(churn, REPS, function()
				local random = _rng(SEED)
				local g = legacyGroup()
				local live = {}
				for _ = 1, CHURN_LIVE do
					live[#live + 1] = g:delay(_noop, 0.1 + random() * 1.9)
				end
				return { g = g, live = live, random = random }
			end)
			local us = ms * 1e3 / CHURN_UPDATES
			_line("P14", ("legacy P8 mixed churn 600 updates: %.3f ms  %.1f us/update  %.0f KB net growth (max rep)"
				.. "  size after %d  -> Veron is %.1fx faster per update")
				:format(ms, us, bytes / 1024, context.g:getClocks(), us / veronP8Us))
		end
		_line("P14", ("legacy P2 idle ratio: legacy %.3f us/update (O(n) walk) vs Veron fast path — see the P2 line")
			:format(idleUs))
	else
		_line("P14", "legacy baseline skipped: no legacy Tick module available on this platform")
	end

	-------------------------------------------------------------------
	-- P15 construct + destroy 1k Veron instances
	-------------------------------------------------------------------
	do
		local holder = table.create(INSTANCES)
		local constructMs, bytes = _measure(function()
			for index = 1, INSTANCES do
				holder[index] = Veron.new({ Name = "P15" })
			end
		end, REPS, function()
			table.clear(holder)
		end)
		local destroyMs = _measure(function()
			for index = 1, INSTANCES do
				holder[index]:Destroy()
			end
		end, 1)
		local allDead = true
		for index = 1, INSTANCES do
			if not holder[index]:IsDestroyed() then
				allDead = false
			end
		end
		_line("P15", ("construct + destroy 1k instances: construct %.2f us/instance  %.0f B/instance resident"
			.. "  destroy %.2f us/instance  %s")
			:format(constructMs * 1e3 / INSTANCES, bytes / INSTANCES, destroyMs * 1e3 / INSTANCES,
				_check(allDead, "every instance destroyed")))
	end

	print(("bench: %d invariant checks, %d failed%s"):format(checks, #failures,
		if #failures == 0 then "" else " — " .. table.concat(failures, "; ")))
	if deps.Exit then
		deps.Exit(if #failures == 0 then 0 else 1)
	end
end

_runBench(deps)

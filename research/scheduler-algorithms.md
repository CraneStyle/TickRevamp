# TickRevamp — scheduler core algorithm decision

Research agent output, 2026-09-16. Data for the orchestrator. All measurements are Lune 0.10.5 (interpreter, no
native codegen) on this machine; treat absolute numbers as relative, operation counts and allocation-free claims
as durable. Prototype + harness: `research/scratch/algos/bench.luau` (run: `cd research/scratch/algos && lune run
bench.luau`), invariant test `research/scratch/algos/invariants.luau`, micro-probes `research/scratch/algos/probes.luau`,
raw output `bench-run2.txt` / `bench-run3.txt`.

## 0. Decision (TL;DR)

**Core = indexed binary min-heap over two parallel arrays (`due[]`, `item[]`), the handle stores its own heap
position (`h._hi`, 0 = not in heap) and its creation sequence (`h._seq`, the equal-due tie-break). Hole-move sifts
(no swaps). Recurring handles are re-keyed IN PLACE at the root (`due[1] += period; siftDown(1)`) BEFORE their
callback runs; one-shots are popped before their callback. Zero stale entries, zero rebuilds, zero allocation in
Update, heap size == number of Pending handles at all times.** Every mutation (stop/reset/adjust/pause/resume/
complete) is a true O(log n) in-place operation, which is what makes re-entrant mutation during dispatch safe
without generation tags or post-callback reconciliation.

Rejected: lazy deletion + threshold rebuild (prior; 2.3-2.7x slower per fire, O(n) rebuild spikes of 0.8-2.1 ms,
2x heap memory under adjust storms, and the RF-010 phantom-entry bug class), hierarchical timing wheel (fastest
per fire but quantized, unordered within a tick, 3-4 KB/update bucket churn in Luau, ties the heap in the realistic
mix), skip list/BST (allocation per node, pointer chasing), sorted array (20-100x slower on arm/stop/adjust at 10k).

4-ary heap: measured within +/-10% of binary in Lune, noisy; keep arity isolated in `siftUp`/`siftDown` and revisit
only with a Roblox `--!native` benchmark. Floyd bottom-up pop: no measurable win in the interpreter; not adopted.

Time model: one internal `_advanceTo(target)` + dispatch. `Update(dt)` accumulates a virtual clock
(`now += dt * timeScale`); `UpdateTo(t)` derives the target from an external absolute clock, clamps backwards
moves (counted, never an error). Sub-frame carry (`_base` = firing entry's ideal due) is KEPT for every operation
performed inside a callback.

Recurring catch-up default: `catchUp = "cap"`, `maxCatchUp = 8` per handle per update, remainder DROPPED by snapping
to the next grid point after `now` (phase preserved). `"all"` (legacy rxi/live burst) is an explicit opt-in.

ForceEventComplete: two methods. `h:complete()` (deferred: re-key to `now`, fires inside the next Update through the
normal path) is the ForceEventComplete equivalent and the recommended default; `h:fireNow()` (synchronous, same
dispatch functions) is an explicit opt-in.

## 1. Workload and requirements (from the task)

- <= ~10,000 live timers per scheduler instance; typically a handful due per 60 Hz update; 240 Hz RenderStepped possible.
- Frequent stop/reset/adjust/pause/resume; a 10k stop storm in one frame must not be quadratic or spiky.
- Recurring timers with catch-up; callbacks that create/stop/adjust timers re-entrantly during dispatch.
- Luau on Roblox with `--!native`, allocation-averse hot path; must run under Lune for tests (no `game`).
- Keep every feature: delay, recur, after-chaining, stop/remove, adjust (ratio-preserving), reset, getClocks,
  SafeStopClock, AfterNotTouched, pause/resume/getRemaining/state/setPeriod/timeScale/error policy, ForceEventComplete,
  nested/child schedulers, remove-protection.

## 2. Candidates

Reference implementations read:

- Prior: `P/build/src/TickAPI/Heap/init.luau` — binary heap in FOUR parallel arrays (`_due,_seq,_gen,_item`), swap-based
  sifts (8 writes per level, `Heap/init.luau:38-43`), no remove/update-key; `rebuild(keep)` O(n) bottom-up heapify
  (`:149-175`). `P/build/src/TickAPI/Group/init.luau` — lazy deletion via per-handle `_gen` (`arm`, `:69-80` orphans the
  old entry), stale counter, `compact()` rebuilds when `stale > max(64, live)` (`:56-63`), update pops and skips stale
  entries by `gen ~= h._gen or state ~= Pending` (`:186-189`), recurring re-arm BEFORE callback (`:123-142`), capped
  catch-up defers the re-arm to after the loop (`:197-200`, the RF-010 phantom-entry site), two tables allocated per
  update (`:173-174`).
- Live: `W/reference/live/MinHeap.luau` — items/priorities arrays, `indexof` linear scan (`:82-88`), `remove` O(n)
  (`:203-228`), `update` = remove + enqueue (`:144-152`). `W/reference/live/SyncedTimerClass.luau` — keyed on absolute
  world time (`:169-195`), `ProcessEvents` pops while due (`:356-363`), `ForceEventComplete` sets a flag (`:281,:288,
  :298-305`) that is only honoured on the heap ROOT (`:326-337`), `Lume.count` O(n) every frame (`:344`).
- Legacy core `W/reference/live/Tick.luau:140-159` (O(n) scan, `while e.timer <= 0` catch-up burst, `err` carry `:151,
  :183-192`); rxi `tick.lua:94-112,133-140`.

### 2.1 Analytical comparison (n live, k due, L = log2 n = 13.3 at 10k)

| | (a) lazy binary + rebuild (prior) | (b) INDEXED binary (recommended) | (c) indexed 4-ary | (d) hierarchical timing wheel | (e) skip list / balanced BST | (f) sorted array (desc, pop from end) |
|---|---|---|---|---|---|---|
| arm | O(L) push; 4 arrays | O(L) push (avg O(1) sift for random keys) | O(log4 n) | O(1) slot compute + list link | O(L) + node alloc | O(L) search + O(n) shift |
| fire (pop) | O(L) + skipped stale pops | O(L) pop, or in-place root re-key for recur (one sift) | O(log4 n), 4 compares/level | O(1) per timer + per-tick slot scan; cascade on wrap | O(L) delete-min (or O(1) w/ head ptr) | O(1) |
| stop | O(1) mark; amortized rebuild share; spike O(n+stale) | O(L) remove-at-index (measured ~ push cost) | O(log4 n) | O(1) unlink | O(L) + free node | O(L) search + O(n) shift |
| reset / adjust | O(L) push NEW entry; old orphaned; heap grows | O(L) in-place re-key (siftUp or siftDown) | same | O(1) unlink + link | O(L) delete + insert (alloc) | O(n) remove + O(n) insert |
| pause / resume | O(1) mark / O(L) push | O(L) remove / O(L) push | same | O(1)/O(1) | O(L)/O(L)+alloc | O(n)/O(n) |
| memory per timer | handle + 4 slots x 16 B = 64 B, up to 2x while stale | handle + 2 slots x 16 B = 32 B; heap == Pending count exactly | same as (b) | handle + 2 link fields + bucket arrays | handle + node (1-3 tables, 100-300 B) | 2 slots = 32 B |
| allocations per op | 0 for heap ops; prior Group: 2 tables/update, `_chained={}` per handle | 0 (arrays grow amortized; 1 table per `delay()` for the handle, unavoidable) | 0 | bucket-array rehash churn in Luau (measured 3-4 KB/update) unless intrusive lists | >= 1 per arm and per re-key | 0 |
| 10k stops in one frame | 10k marks + one O(20k) rebuild: total ~1.2-1.4 ms, spike 0.4-1.5 ms (Lune) | 10k x O(L): 1.2-2.9 ms flat, no spike | 1.1-2.6 ms | 1.3-2.2 ms | ~10-30 ms est. (allocs) | 44-57 ms (quadratic) |
| iteration safety under re-entrant mutation | popped stale entries skipped by gen; ANY post-callback re-arm must re-check state (RF-010 bug class) | total: mutation is immediate; loop re-reads `due[1]` each iteration; no post-callback code | same | bucket scan must tolerate swap-remove of current/other entries; cross-bucket moves mid-scan need care | safe with care | safe (pop from end) |
| worst-case frame time | rebuild O(n) spike; catch-up unbounded by default (`maxCatchUpPerFrame=nil`) | bounded: k x O(L) + caps (nested, catch-up); no spikes | same | cascade of a dense upper slot; hitch of T s = T/tick ticks; quantization | rebalancing spikes small; GC pressure | arm/adjust storm O(n^2): 10k adjusts = 170-200 ms |
| resolution / order | exact due order, (due, seq) deterministic | exact, (due, seq) deterministic | same | quantized to tick (1/60 or 1/240); intra-slot order arbitrary unless sorted per tick | exact | exact |
| code complexity | medium: gen, stale counter, threshold, rebuild predicate, `_inHeap` | low-medium: 2 sifts + push/pop/remove/updateKey + ownership check | +child loop | high: levels, cascade, tick origin for absolute clocks, list plumbing | high (BST) / medium (skip list, random) | lowest |
| testability | needs stale-counter invariants; phantom entries only visible by full scan | O(n) oracle after every op: heap property + `item[h._hi] == h` + Pending-set == heap-set | same | timing depends on tick alignment; harder | medium | trivial |

### 2.2 Measured (Lune 0.10.5, N = 10,000, ranges over runs 2-3; run 1 discarded as cold-start noise)

IB = indexed binary; IB2 = IB + Floyd pop + in-place recur re-key; I4/I42 = 4-ary analogues; IH = indexed binary with
a handle-only array (key read through `item[i]._due`); LZ = lazy-deletion shell over the PRIOR Heap module with the
prior's threshold policy but a minimal shell (isolates the strategy); PG = prior Group exactly as built; SA = sorted
array; TW = hashed timing wheel (1024 slots x 1/60 s, rounds counter, swap-remove buckets).

| Phase | IB | IB2 | I4 | I42 | IH | LZ | PG | SA | TW |
|---|---|---|---|---|---|---|---|---|---|
| P1 arm 10k random dues, ns/op | 248-254 | 177-191 | 144-243 | 148-163 | 174-183 | 275-319 | 664-674 | 4910-4941 | 248-250 |
| P2 200 idle updates, us/update | 0.02 | 0.02-0.03 | 0.03 | 0.02 | 0.02 | 0.06 | 0.13-0.14 (+96 B garbage/update) | 0.02-0.03 | 0.14-0.20 |
| P3 10k stops shuffled, ns/op (max single op us) | 121 (1-52) | 285-289 (4-8) | 177-260 (4-8) | 113-259 (1-143) | 148-262 (14-145) | 122-142 (380-455) | 408-693 (642-969) | 4380-5664 (62-163) | 183-219 (77-142) |
| P4 10k adjusts shuffled, ns/op (max us; heap size after) | 165-192 (4; 10000) | 143-165 (5-29) | 123-245 (16-158) | 126-146 (6-130) | 147-167 (6-174) | 277-296 (285-358; **20000**) | 378-469 (298-322; **20000**) | 16725-18305 | 185-216 |
| P5 10k resets shuffled, ns/op | 135-197 | 189-212 | 145-282 | 129-136 | 153-219 | 153-159 | 243-351 | 18303-19483 | 142-175 |
| P6 fire storm 10k in one update, ns/dispatch | 295-367 | 286-433 | 325-799 | 270-544 | 515 | 846-953 | 790-1146 | 117-128 | 54-59 |
| P7 10k recurring (period U(0.5,1.5)) x 600 updates @1/60: us/update (ns/fire; ~180 fires/update) | 66-67 (367-370) | 61-68 (337-380) | 66-71 (366-397) | 54-63 (300-353) | 117-133 (650-740) | 154-159 (855-887) | 178-181 (991-1008) | 2536-2735 (14-15 us/fire) | 15.5-16.2 (86-90) + 3.8 KB/update garbage |
| P8 mixed churn (2k live; per update 50 arms, 20 stops, 10 adjusts, ~50 fires) x 600, us/update | 23.7-25.0 | 24.6-25.8 | 21.5-22.5 | 21.8-24.6 | 32.3-32.7 | 52.6-53.1 | 102.5-112.8 | 252-261 | 18.3-23.1 |
| P9 adjust storm (10 rounds of adjust-all-10k + update): max round ms (max single op us; heap size after) | 1.64-2.17 (13-128; 10000) | 1.62-2.21 (16-20) | 1.55-1.56 (6-9) | 1.52-1.80 (47-116) | 1.75-1.78 (13-140) | 3.02-3.48 (**800-1015**; 19991; 9 rebuilds) | 5.58-6.65 (**1596-2125**; 19991) | 184-198 (1534-3850) | 2.62-2.69 (19-516) |
| memory: bytes allocated per timer at arm (P1 delta / 10k) | 356 | 356 | 356 | 356 | 330 | 409 | 765 | 356 | 335 |

Caveats: `os.clock` per-op timing plus incremental GC steps landing inside a timed op inflate "max single op" (IB shows
1 us in one run and 52 us in the other for the same code); the sustained phases (P7-P9) are the reliable ones. Lune has
only `collectgarbage("count")` (no collect/step, same as Roblox), so "alloc" is a count delta: 0 KB is exact
(allocation-free), non-zero is a lower bound. No `--!native`; expect Roblox native to compress everything 3-6x with the
array-heavy sifts gaining the most.

Micro-probes (`probes.luau`): direct call 6 ns, `pcall` 27 ns, `xpcall(fn, debug.traceback)` 37 ns (keep the protected
call; +31 ns per callback is noise next to a 300 ns dispatch). Metatable method call 13 ns vs local function 9 ns
(BaseClass dispatch is fine for API entry points; the inner loop still uses locals). Luau table sizing: a constructor
literal with <= 8 record fields = 320 B, 9-16 fields = 576 B; nil-valued fields in the literal DO pre-size the table
(late assignment adds 0 B), whereas a 7-field literal that later gains fields rehashes (+256 B garbage per handle).

### 2.3 Why each alternative loses

- (a) lazy + rebuild: every reset/adjust/pause pushes a NEW entry and orphans the old one (`Group/init.luau:69-80,
  :345-375`), so an adjust storm doubles the heap (P4/P9: size 19991 after 10k adjusts) and each threshold crossing
  costs an O(n) rebuild in one frame (0.8-2.1 ms measured; scales with n). Per fire it is 2.3x slower than indexed with
  the same shell (LZ 855-887 vs IB 367-370 ns) because of the 4-array swap sifts (8 writes/level vs 3) and the
  peek/pop/isEmpty method calls per iteration. Its capped catch-up must re-arm AFTER the loop and forgot to re-check
  state (RF-010/013/020/031/039). Generation tags cannot answer "is this handle in the heap right now" in O(1), which
  is exactly the question a re-entrant stop needs answered.
- (c) 4-ary: half the levels, but 3 sibling compares per level and a child loop; net +/-10% in Lune, direction varies
  by phase (better on re-key paths, worse or equal on pops). Not worth the extra code now; the swap is two functions.
- (d) wheel: 3-4x faster per fire in the fire-heavy P7 regime (86 vs 337 ns) but idle cost is a slot scan (0.14-0.36
  us vs 0.02), it quantizes to the tick (a 1/60 wheel under a 240 Hz driver fires up to 16 ms late where the heap fires
  <= 4 ms late), fires within one slot in arbitrary order (needs a per-slot sort for the (due, seq) determinism the
  spec wants), cascades are O(slot population) spikes, and Luau bucket arrays that empty and refill rehash constantly
  (measured 3.8 KB garbage per update in P7; fixable only with intrusive doubly linked lists = 2 more handle fields
  and pointer chasing). In the realistic mix (P8) it ties the heap (18-23 vs 22-25 us). Jake asked for a heap.
- (e) skip list / BST: every arm and every re-key allocates a node (1-3 tables); each hop is a hash-field lookup
  (~30 ns in the interpreter) versus an array read; constants 3-10x worse than the array heap with no benefit for this
  workload (ordered iteration is a debug-only need and can be a sorted copy on demand).
- (f) sorted array: pop is the cheapest of all (117-128 ns) but insert/remove shift O(n) elements through
  `table.insert`/`table.remove` (~0.5-1 ns per element per array): 5 us per arm/stop and 17-20 us per adjust at 10k;
  a recurring population is 15 us/fire (40x the heap); 10k adjusts = 170-200 ms in one frame. It only wins below
  n ~ 64-128, and the requirement is 10k.
- IH (handle-only array, key read through the handle): stop/adjust are slightly cheaper (fewer array writes) but the
  dispatch path — the hot path — is 2x slower (650-740 vs 367 ns/fire) because every compare is two hash lookups
  (`item[c]._due`) instead of two array reads. Parallel `due[]` wins.

## 3. Recommended core — precise specification

### 3.1 Data layout

Per scheduler instance:

```
_due   : {number}   -- heap keys, 1-based, dense
_item  : {Handle}   -- parallel: _item[i] is the handle whose key is _due[i]
_n     : number     -- heap size == number of Pending handles
_now   : number     -- virtual clock (see 3.5)
_base  : number?    -- the firing entry's ideal due while a callback runs; nil at top level
_seq   : number     -- creation counter; also the public handle id
_inUpdate, _serial, _timeScale, _paused, _offset, _lastAbs, _maxNested, _maxCatchUp, _catchUpMode, _onError, _errored,
stats: _dispatched, _reentries, _backwards, _nestedCapHits, _catchUpDrops, _live, _pausedCount
_pausedSet : {[Handle]: true}   -- cold; only so clear() can reach paused handles
```

Per handle (declare EVERY field in the constructor literal, nil ones included, so the table is sized once; 8 fields
= 320 B, 9-16 = 576 B):

```
fn, period, recur, _seq, _hi, _state, _sched, _ext
```

`_hi` = heap index or 0. `_state` is a small integer constant (PENDING=1, PAUSED=2, CHAINED=3, FIRED=4, STOPPED=5): no
string building, no interning. `_ext` is nil until a cold feature needs it and then holds `{remaining, chained, burst,
burstSerial, catchUp, maxCatchUp}`; this keeps the hot handle at 8 fields (320 B, ~3.2 MB per 10k) — optional, the
simpler alternative is a flat 12-field literal at 576 B (~5.8 MB per 10k). Either is fine; pick one and keep it.

Handle-holds-index vs generation tags: **index**. `_hi == 0` IS the in-heap boolean; the ownership check
`_item[h._hi] == h` (one array read) makes remove/re-key robust against a handle from another scheduler or a
corrupted index, and costs nothing measurable.

Tie-break: `(due, seq)` with `seq` on the handle (assigned once at creation, kept across re-arms, so a re-armed
recurring handle keeps its rank and a chained child created earlier ranks before later siblings). Deterministic,
no third array, no counter increment per push. `seq` is read only on exact ties. Note the one tie-heavy case: many
recurring handles created in the same frame with the same period tie every cycle (`due + period` is exact
arithmetic); each tie compare is then two hash reads (`item[c]._seq`), roughly +100 ns per pop in the interpreter.
If a Roblox benchmark shows that regime matters, a third parallel `seq[]` array (the prior's layout, +1 write per
move) is a local change inside the heap module.

No handle pooling. Live code calls `SafeStopClock` on handles that already fired 92 times over (ASSESSMENT F3); with
a pool that becomes "stop somebody else's timer" (ABA). One table per `delay()` is the only allocation in the API;
Update allocates nothing.

### 3.2 Heap operations (Luau; verified by `invariants.luau`, 20k random push/pop/remove/updateKey with the heap
property and `_hi` consistency checked every 97 ops, plus a sorted drain)

```lua
-- entry i sorts before parent p when (due, seq) is smaller. Hole-move: the moving element is held in
-- locals and written once at its final slot; every displaced element gets its _hi fixed as it moves.
local function siftUp(due, item, i: number): number
	local d, it = due[i], item[i]
	local s = it._seq
	while i > 1 do
		local p = i // 2
		local dp = due[p]
		if d < dp or (d == dp and s < item[p]._seq) then
			due[i] = dp
			local ip = item[p]
			item[i] = ip
			ip._hi = i
			i = p
		else
			break
		end
	end
	due[i] = d
	item[i] = it
	it._hi = i
	return i
end

local function siftDown(due, item, n: number, i: number): number
	local d, it = due[i], item[i]
	local s = it._seq
	while true do
		local c = i + i
		if c > n then break end
		local dc = due[c]
		local r = c + 1
		if r <= n then
			local dr = due[r]
			if dr < dc or (dr == dc and item[r]._seq < item[c]._seq) then
				c = r
				dc = dr
			end
		end
		if dc < d or (dc == d and item[c]._seq < s) then
			due[i] = dc
			local ic = item[c]
			item[i] = ic
			ic._hi = i
			i = c
		else
			break
		end
	end
	due[i] = d
	item[i] = it
	it._hi = i
	return i
end

local function heapPush(self, h, d: number)
	local n = self._n + 1
	self._n = n
	self._due[n] = d
	self._item[n] = h
	h._hi = n
	siftUp(self._due, self._item, n)
end

-- precondition: self._n > 0. Returns (due, handle); handle._hi becomes 0.
local function heapPop(self): (number, any)
	local due, item = self._due, self._item
	local n = self._n
	local d, h = due[1], item[1]
	h._hi = 0
	if n > 1 then
		due[1] = due[n]
		item[1] = item[n]
	end
	due[n] = nil
	item[n] = nil
	n -= 1
	self._n = n
	if n > 0 then
		siftDown(due, item, n, 1)
	end
	return d, h
end

-- true if h was in THIS heap and is now out. The ownership check makes a wrong-scheduler or stale index a no-op.
local function heapRemove(self, h): boolean
	local i = h._hi
	local due, item = self._due, self._item
	if i == 0 or item[i] ~= h then
		return false
	end
	local n = self._n
	h._hi = 0
	if i == n then
		due[n] = nil
		item[n] = nil
		self._n = n - 1
		return true
	end
	due[i] = due[n]
	item[i] = item[n]
	due[n] = nil
	item[n] = nil
	n -= 1
	self._n = n
	if i > 1 then
		local p = i // 2
		local d, dp = due[i], due[p]
		if d < dp or (d == dp and item[i]._seq < item[p]._seq) then
			siftUp(due, item, i)
			return true
		end
	end
	siftDown(due, item, n, i)
	return true
end

-- decrease-key or increase-key in place. precondition: h in this heap (callers check state/_hi first).
local function heapUpdate(self, h, newDue: number)
	local i = h._hi
	local due, item = self._due, self._item
	if i == 0 or item[i] ~= h then
		error("TickRevamp: handle is not scheduled on this scheduler", 3)
	end
	local old = due[i]
	due[i] = newDue
	if newDue < old then
		siftUp(due, item, i)
	else
		siftDown(due, item, self._n, i)
	end
end

local function heapClear(self)
	local item = self._item
	for i = 1, self._n do
		item[i]._hi = 0
	end
	table.clear(self._due)
	table.clear(self._item)
	self._n = 0
end
```

Costs: push = 1 siftUp (O(1) average for random keys, O(L) worst); pop = 1 siftDown (typically full depth because
the promoted element was a leaf); remove = one sift in one direction; updateKey = one sift. All allocation-free.

### 3.3 The dispatch loop

Rules:

1. `while n > 0 and due[1] <= now`: pop/re-key the root, dispatch, repeat. `now` is re-read from `self._now` every
   iteration (a re-entrant call may have advanced it, see rule 2).
2. **Re-entrancy guard.** `_inUpdate` is set for the duration. A nested `Update`/`UpdateTo` on the SAME instance
   (a callback that yields — `task.wait` inside a Heartbeat handler suspends that handler and the next frame's
   Heartbeat re-enters — or a callback that calls the scheduler's own update) does NOT dispatch: it advances the
   clock, increments `stats.reentries`, and returns. The suspended outer loop drains everything when it resumes,
   so no time is lost and no entry can be dispatched twice. Not an error (an error thrown every frame from inside a
   RunService connection is worse than the misuse), but `reentries > 0` is surfaced in `getStats()` and warned once
   per scheduler. A child scheduler driven by a parent's timer is a DIFFERENT instance and is unaffected.
3. **Re-arm/pop BEFORE the callback; no code after the callback.** Recurring: `due[1] = d + period; siftDown(1)`,
   then `_base = d`, then the callback. One-shot: `heapPop`, state = FIRED, `_base = d`, arm chained children at
   `d + child.period`, then the callback. Because the heap is already in its final post-fire state when user code runs,
   whatever the callback does to its own handle simply wins: `h:stop()` removes the live entry (recurring) or is a
   state-only no-op (one-shot, `_hi == 0`); `h:reset()` re-keys to `base + period = d + period` (same value: harmless);
   `h:adjust(t)` re-keys to `d + t` (the next period becomes `t`, exactly the ratio rule with remaining == period);
   `h:pause()` removes and freezes `remaining = period`; `h:complete()` re-keys to now. With the prior's "re-arm after
   the callback in the capped path" (`Group/init.luau:197-200`) the loop had to guess whether the callback had touched
   the handle and guessed wrong (RF-010). Here there is nothing to guess.
4. **A callback that stops or re-arms ANOTHER entry that is still in the heap** — including one that is also due this
   update — is handled by `heapRemove`/`heapUpdate` directly; the loop's next `due[1]` read sees the result
   (invariants.luau: A stops co-due sibling B and creates due-now child C; dispatch order A, C; B never fires).
5. **Nested due-now cap (safety valve).** Handles created during this update (`h._seq > startSeq`) that come due in
   this same update are counted; past `maxNestedPerUpdate` (default 1000) the loop breaks, the remaining due entries
   fire next update, `stats.nestedCapHits += 1`, warn once. This is the only way a `while due[1] <= now` loop can be
   infinite for one-shots (a callback that arms a due-now timer that does the same). Pre-existing entries are always
   fully drained (bounded by the heap size at entry); recurring handles are bounded by the catch-up cap (3.4).
6. Callbacks run under `xpcall(fn, debug.traceback)` with the prior's onError policy ("warn" | "error" re-raised
   after the pass | function). 31 ns per callback.
7. `_base` is cleared after the loop; `_inUpdate` cleared; per-update stats stored. No per-update allocation
   (the prior's `fireCounts = {}` / `capped = {}` at `Group/init.luau:173-174` are replaced by two numeric fields on
   the handle: `_burst`, `_burstSerial`).

```lua
local PENDING, PAUSED, CHAINED, FIRED, STOPPED = 1, 2, 3, 4, 5

local function clockOf(self): number      -- "now" for every scheduling computation
	return self._base or self._now
end

local function runCallback(self, h)       -- prior's policy body, unchanged in spirit
	local ok, message = xpcall(h.fn, debug.traceback)
	if ok then return end
	local policy = self._onError
	if policy == "warn" then
		warn(("[%s] callback error: %s"):format(self.name, message))
	elseif policy == "error" then
		if self._errored == nil then self._errored = message end
	elseif not pcall(policy, message, h) then
		warn(("[%s] callback error: %s"):format(self.name, message))
	end
end

local function fireOneShot(self, h, d: number)   -- h already popped (_hi == 0)
	h._state = FIRED
	self._live -= 1
	self._base = d
	local ext = h._ext
	local chained = ext and ext.chained
	if chained then
		ext.chained = nil
		for _, c in chained do
			if c._state == CHAINED then           -- a child stopped before its parent fired is never resurrected
				c._state = PENDING
				self._live += 1
				heapPush(self, c, d + c.period)   -- measured from the parent's ideal due (sub-frame carry)
			end
		end
	end
	runCallback(self, h)
end

local function fireRecurring(self, h, d: number) -- h still in the heap, already re-keyed to d + period
	self._base = d
	runCallback(self, h)
end

function Scheduler:_advanceTo(target: number)
	if self._inUpdate then
		self._reentries += 1
		if target > self._now then self._now = target end
		return
	end
	if target > self._now then
		self._now = target
	elseif target < self._now then
		self._backwards += 1                       -- clamp: the clock never runs backwards
	end
	self._inUpdate = true
	local serial = self._serial + 1
	self._serial = serial
	self._errored = nil
	local due, item = self._due, self._item
	local startSeq = self._seq
	local nested, nestedCap = 0, self._maxNested
	local dispatched = 0

	while self._n > 0 do
		local now = self._now                      -- re-read: a re-entrant call may have advanced it
		local d = due[1]
		if d > now then break end
		local h = item[1]
		if h._seq > startSeq then                  -- armed during THIS update and already due
			nested += 1
			if nested > nestedCap then
				self._nestedCapHits += 1
				break                              -- the rest fires next update
			end
		end
		if h.recur then
			local period = h.period
			local burst
			if h._burstSerial == serial then burst = h._burst + 1 else burst = 1; h._burstSerial = serial end
			h._burst = burst
			local cap = h._maxCatchUp or self._maxCatchUp    -- nil = "all" (unbounded, explicit opt-in)
			if cap and burst > cap then
				-- fired `cap` times this update already: snap to the first grid point after now (phase kept),
				-- so it cannot pop again this update; the skipped grid points are dropped (mode "cap").
				local m = (now - d) // period + 1
				local nextDue = d + m * period
				if nextDue <= now then nextDue += period end
				if nextDue <= now then
					-- period below the clock's float resolution: a broken timer, stop it loudly.
					heapPop(self); h._state = STOPPED; self._live -= 1
					warn(("[%s] recur period %g is below clock resolution at now=%g; stopped"):format(self.name, period, now))
				else
					due[1] = nextDue
					siftDown(due, item, self._n, 1)
					self._catchUpDrops += m
				end
			else
				due[1] = d + period                -- in-place re-key BEFORE the callback
				siftDown(due, item, self._n, 1)
				fireRecurring(self, h, d)
				dispatched += 1
			end
		else
			heapPop(self)
			fireOneShot(self, h, d)
			dispatched += 1
		end
	end

	self._base = nil
	self._dispatched = dispatched
	self._inUpdate = false
	local errored = self._errored
	if errored ~= nil then
		self._errored = nil
		error(errored, 0)
	end
end

function Scheduler:Update(dt: number)
	if not (dt >= 0) then                         -- also rejects NaN (NaN >= 0 is false); 2 ns
		error("TickRevamp: Update(dt) expects dt >= 0, got " .. tostring(dt), 2)
	end
	if self._paused then return end
	self:_advanceTo(self._now + dt * self._timeScale)
end
```

`_burst`/`_burstSerial` live on the handle (or in `_ext`) — numeric, no allocation, and `_burstSerial ~= serial`
makes them self-resetting each update without a per-update table.

### 3.4 Recurring catch-up policy

Given a recurring handle with ideal due `d`, period `P`, and `now = n` where `k = floor((n - d)/P) + 1` grid points
`d, d+P, ..., d+(k-1)P` are `<= n`:

| policy | fires this update | next heap key | phase | backlog | frame cost | who wants it |
|---|---|---|---|---|---|---|
| A "one": fire once, re-arm at `d+P` | 1 | `d+P` (may still be `<= n`) | kept | unbounded when `P < dt` (never recovers), otherwise drains 1/update | O(1)/handle | nobody as a default; it is `cap` with N=1 + kept backlog |
| B "all": fire k times (rxi/live `while e.timer <= 0`, `Tick.luau:145-157`) | k | `d+kP` | kept | none | unbounded burst: 5 s hitch = 50 fires of a 100 ms recur, 500 of a 10 ms one; a tiny period hangs the frame (F5 class) | legacy compat; counters that must not lose ticks |
| C "skip": fire once, re-arm at `n+P` | 1 | `n+P` | LOST (drifts by the overshoot every fire) | none | O(1) | never — same cost as D with worse accuracy |
| D "cap N, keep backlog" (prior `maxCatchUpPerFrame`) | min(k,N) | next unfired grid point (`<= n` when capped) | kept | kept, drains N/update; unbounded when `P < dt/N` | bounded N/handle | "deliver every tick, spread out" — needs parking (prior's RF-010 site) or an owed counter |
| **E "cap N, drop the rest, snap to grid" (recommended default, N = 8)** | min(k,N) | `d + mP`, the first grid point `> n` | kept | none | bounded N/handle, no post-loop work | UI/polling/cooldown displays (most of the 67 live recur sites), anything after a hitch |

Recommendation: default `catchUp = "cap"` with `maxCatchUp = 8` per handle per update (a 5 s hitch of a 100 ms recur
owes 50 fires and delivers 8 — enough to look continuous — then resumes on its original grid). Per instance
(`Scheduler.new{catchUp = "all" | "cap", maxCatchUp = N}`) and per handle (`recur(fn, P, {catchUp = "all"})` or
`h:setCatchUp(mode, N)`). `"all"` is legacy-exact and is the only mode that can burst without bound, so it must be
explicit. Policy D is NOT offered by default: it reintroduces post-loop mutation; if Jake wants "never drop a tick,
never burst" it can be added later as an owed counter on the handle (`_owed`, `_owedBase`) drained at the top of each
update, without touching the heap (documented in the questions section).

Sub-frame accuracy rule — KEEP `_base` (rxi's `err`, prior's `_base`): every arm/reset/adjust/complete performed inside
a callback measures from the firing entry's ideal due, not from `now`. Drift math: let the driver deliver updates at
times `t_j` with `dt ~ U(0, T)` overshoot past each due. A recurring or self-rescheduling timer re-armed from `now`
accumulates the overshoot every cycle: expected drift `T/2` per cycle = 8.3 ms per cycle at 60 Hz, i.e. a 1 s recur
runs 0.5 s late per minute (30 s per hour) and its rate is systematically low. Re-armed from `d` the k-th fire happens
at the first `t_j >= d0 + kP`: lateness is bounded by one frame and NEVER accumulates. The same holds for the
common hand-rolled pattern `local function loop() Tick.delay(loop, 1) end` and for `after` chains, which is why the
carry applies to nested arms, not only to recur. Cost: one field write per dispatch and `self._base or self._now` in
`arm` (0 is truthy in Lua, so a due of 0 carries correctly). Rule stated for the docs: "inside a callback, now == the
callback's ideal due". Apply it uniformly — the prior measured `_adjust`'s remaining from `_now` but armed from
`_base` (`Group/init.luau:364-366`), an inconsistency; the spec routes every op through `clockOf(self)`.

### 3.5 Time model

**Both entry points share one `_advanceTo(target)` and one dispatch loop.**

- `Update(dt)`: `target = now + dt * timeScale`. Rejects NaN/negative dt with an error (programming bug; `not (dt >= 0)`
  catches both, 2 ns). `timeScale = 0` freezes; `sched:pause()`/`resume()` short-circuit. This is the mode for the
  RunService-driven instances (`Stepped`, `Heartbeat`, `RenderStepped`, ...): each instance owns its own clock.
- `UpdateTo(t)` (absolute, externally synced: `workspace:GetServerTimeNow()`, `SyncedTimer`'s `WorldTime`, a test's
  fake clock): when `timeScale == 1` and not paused, `target = t - _offset` (exact, no accumulation); otherwise
  `target = now + (t - _lastAbs) * timeScale`; always `_lastAbs = t`. While paused, `UpdateTo` accumulates the gap into
  `_offset` and does not advance, so resuming does not fire everything at once and no O(n) due shift is needed.
  `delayAt(absoluteDue, fn)` = `delay(fn, absoluteDue - t_current)` through the same offset, so "fire at WorldTime X on
  every client" works regardless of when each client's scheduler was created.
- **Backwards `t`: clamp, count `stats.backwards`, never error, never move `now` backwards.** External clocks jitter
  on resync; an exception every frame inside a RunService connection would be far worse than a timer firing a few ms
  late. Optional: warn once if a single backwards jump exceeds 1 s (a real resync, worth knowing).
- Float precision (doubles, 53-bit mantissa): ulp(1e5 s) = 2^-36 = 1.5e-11 s; ulp(1e7 s) = 2^-29 = 1.9e-9 s;
  ulp(1.7e9 s, a Unix-epoch clock) = 2^-22 = 2.4e-7 s — all far below the 4-17 ms frame granularity. Measured
  accumulation error: 2.4e6 adds of 1/240 starting at now = 1e7 drift by 6e-4 s per 1e4 simulated seconds
  (0.06 ppm); at a realistic server lifetime (< 1e5 s) it is ~128x smaller. Irrelevant. `UpdateTo` at scale 1 does not
  accumulate at all.
- Determinism: `Update(1/60)` x N under Lune is bit-reproducible, ties resolve by seq, dispatch order is a pure
  function of the op sequence.

Plain-language answer to "rolling greater number for dt" (Jake): the legacy core keeps a countdown PER timer and
subtracts dt from every one of them every frame (`Tick.luau:141-144`) — that is why it is O(n). A heap needs ONE
comparable number per timer, so each timer stores the absolute moment it is due on a shared clock (`now + delay`) and
only the clock advances (`now += dt`). Yes, that number grows forever, and no, it does not matter: a double keeps
~15-16 significant digits, so even after a year of uptime the clock is accurate to a tenth of a microsecond. The
value passed to `update` by RunService is a delta (`Stepped` passes `(time, dt)`, `Heartbeat` passes `dt`), so
`Update(dt)` accumulating is the natural fit; passing an absolute time directly (`UpdateTo`) is the same loop with the
clock set instead of advanced, and is what a cross-client synced scheduler uses. The one rule: a handle belongs to
exactly one scheduler because dues are only comparable on the clock they were computed against.

### 3.6 ForceEventComplete

`SyncedTimer.ForceEventComplete` (`SyncedTimerClass.luau:298-305`) sets `ForcedComplete = true` (`:281,:289`) and
`_isNextEventValidToProcess` honours the flag only on the heap ROOT (`:330-332`), so a forced entry that is not the
earliest due does nothing until its natural time (its key is unchanged). The revamp fixes this by re-keying.

Two methods, same dispatch functions:

```lua
-- Deferred (RECOMMENDED default; the ForceEventComplete equivalent). The callback runs inside the next
-- Update, after every entry with due < now and in seq order among entries at now. Never runs user code
-- from an arbitrary call stack (RemoteEvent handler, another scheduler's callback), keeps the error policy
-- and re-entrancy story simple. A recurring handle re-arms from the forced time (phase moves to now).
function Handle:complete()
	local s = self._sched
	local st = self._state
	if st == PENDING then
		heapUpdate(s, self, s._now)               -- not clockOf: "now" is the caller's now, and <= now fires
	elseif st == PAUSED then
		s:_resume(self)                           -- back into the heap at now + remaining
		heapUpdate(s, self, s._now)
	elseif st == CHAINED then
		s:_detachChained(self)                    -- leave the parent's list, become Pending at now
		self._state = PENDING; s._live += 1
		heapPush(s, self, s._now)
	end
	return self                                   -- terminal states: no-op
end

-- Synchronous (explicit opt-in). Same fire functions, so chained children, recurring re-arm, _base and the
-- error policy behave identically. Legal from inside another callback (nested dispatch): _base is saved and
-- restored around it. Outside Update, an "error" policy message is re-raised at the end of fireNow().
function Handle:fireNow()
	local s = self._sched
	if self._state == PAUSED then s:_resume(self) elseif self._state == CHAINED then self:complete() end
	if self._state ~= PENDING then return self end
	local savedBase = s._base
	local d = clockOf(s)
	if self.recur then
		heapUpdate(s, self, d + self.period)
		fireRecurring(s, self, d)
	else
		heapRemove(s, self)
		fireOneShot(s, self, d)
	end
	s._base = savedBase
	if not s._inUpdate and s._errored ~= nil then
		local e = s._errored; s._errored = nil; error(e, 0)
	end
	return self
end
```

Recommend `complete()` as the documented ForceEventComplete; `fireNow()` exists for the cases that genuinely need the
callback to have run before the caller continues (e.g. "skip the cooldown and apply it now" in server logic).

### 3.7 Stop / remove protection (task item 6)

| case | behaviour | mechanism |
|---|---|---|
| double stop / stop after fire (the F3 leak path, 92 live SafeStopClock sites) | no-op, returns nil | `_state` terminal check first; `heapRemove` returns false when `_hi == 0` |
| stop from inside its OWN callback | one-shot: state-only (already popped); recurring: removed from the heap (it was re-keyed in place, so it is there) | indexed remove; nothing runs after the callback |
| stop/adjust/reset of ANOTHER handle during dispatch, including a co-due one | immediate; the loop re-reads `due[1]` | `heapRemove`/`heapUpdate` maintain the heap under the loop |
| stop of a handle from another scheduler via `sched:remove(h)` | error "handle belongs to scheduler X" (misuse), heap untouched | `h._sched ~= self` check; `heapRemove`'s `item[i] ~= h` ownership check protects the arrays regardless |
| colon-vs-dot: `h.stop()` | error "use h:stop()" at the call site (level 2) | first line of every handle method: `if type(self) ~= "table" or self._sched == nil then error(..., 2) end` |
| `sched.update(dt)` vs `sched:update(dt)` (live code uses the dot form: `TickAPI.Tick.update(SteppedTime)`) | both work | per-instance bound closures (the prior's `bindDual`); instances are few, so closures are cheap |
| `remove(nil)` (SafeStopClock) | no-op | nil check |
| stop of a Chained (not yet armed) child | Chained -> Stopped; parent never resurrects it | `c._state == CHAINED` check in `fireOneShot`; fixes live F8 |
| stop of a parent with Chained children | cascades to children | parent's `_ext.chained` walk |
| `clear()` | O(n): `heapClear` (resets every `_hi`), then the paused set, then chained children of cleared parents | no `_all` set needed for Pending handles; `_pausedSet` is the only side index |

Pause/resume: `pause` = `remaining = max(due - clockOf(), 0)`, `heapRemove`, state PAUSED, `_pausedSet[h] = true`;
`resume` = `heapPush(h, clockOf() + remaining)`. O(log n) each, allocation-free (unless `_ext` is created lazily on the
first pause). `getClocks()` = `_n + _pausedCount`.

### 3.8 Class shape (BaseClass)

`Scheduler` is a BaseClass class (`BaseClass.class("TickScheduler")`) whose `initialize(opts)` creates the arrays and
binds the dot-callable closures; the heap functions and the dispatch loop are module-local functions that take `self`
(13 ns metatable dispatch vs 9 ns local is irrelevant at the API boundary but the inner loop touches locals only).
`Handle` is a plain metatable class (not BaseClass) because 10k of them are created and its methods must be the
cheapest possible; it exposes `getState()` etc. If house style requires BaseClass handles, the cost is
`BaseClass:new` allocation + `initialize` call per `delay()`; measure before accepting (see 4.3).

## 4. Micro-benchmark plan

### 4.1 Harness (implemented: `research/scratch/algos/bench.luau`)

Seeded (`20260916`), N = 10,000, median of 5 (3 for the long phases) `os.clock` runs, `collectgarbage("count")` deltas.
Every candidate implements the same shell API (`delay/recur/stop/adjust/reset/update/size`) so only the structure
varies; PG wraps the prior Group unmodified (required via relative path `../../../../TickAPIOptimize/build/src/TickAPI/Group`).

- P1 arm 10k random dues in [10, 20] -> ns/op, bytes/timer.
- P2 200 x `update(0.005)` with 10k armed, nothing due -> us/update, garbage (must be 0).
- P3 stop all 10k in shuffled order -> ns/op, max single op, heap size after (must be 0).
- P4 adjust all 10k (newTotal = period x U(0.5, 1.5)), shuffled -> ns/op, max single op, heap size after (must be 10k).
- P5 reset all 10k after `update(5)` -> ns/op (increase-key path).
- P6 fire storm: 10k due in [0, 1], one `update(1.0001)` -> ns/dispatch; asserts all fired.
- P7 10k recurring, period U(0.5, 1.5), 600 x `update(1/60)` -> us/update, ns/fire, garbage.
- P8 mixed churn: 2k live; per update 50 arms U(0.1, 2), 20 random stops, 10 random adjusts, ~50 fires; 600 updates.
- P9 adjust storm: 10 rounds of adjust-all-10k + update -> max round ms, max single op, heap size after, rebuild count.

### 4.2 Results — see 2.2. Headline deltas (indexed IB vs prior PG as built): arm 2.7x, stop 3.4-5.7x, adjust 2.3x,
fire 2.7x, mixed churn 4.3-4.5x, adjust-storm max round 3.1-3.4x, spikes 1.6-2.1 ms -> <= 0.13 ms, memory/timer 765 ->
356 B, per-update garbage 96 B -> 0. Versus the strategy alone (LZ, same shell): fire 2.3x, mixed churn 2.1x, heap size
under adjust storm 2x -> 1x, rebuild spikes 0.8-1.0 ms -> none.

### 4.3 Still to run (in-Studio, `--!native`)

Port `bench.luau` phases P2/P7/P8/P9 to a Studio command-bar script (replace the relative requires with the built
modules); expected: absolute numbers 3-6x lower, ranking unchanged. Add the tie-heavy P7 variant (all periods
equal, all created in one frame) to decide `seq` on handle vs a third array, and a BaseClass-handle variant of P1 to
decide the handle class shape. Report `collectgarbage("count")` deltas for P2 (must stay 0) and P7.

## 5. Findings

F-ALG-1 (major, prior): lazy deletion doubles the heap under reset/adjust storms and pays O(n) rebuild spikes.
`Group/init.luau:69-80` pushes a new entry per re-arm; `:56-63` rebuilds when `stale > max(64, live)`. Measured: heap
size 19991 after 10k adjusts (P4/P9), single-op spikes 800-1015 us (LZ) / 1596-2125 us (PG) per rebuild, 9 rebuilds in
10 rounds. Indexed: size 10000, no rebuild, max op <= 128 us (GC-step noise).

F-ALG-2 (major, prior): per-fire cost 2.7x the indexed prototype (991-1008 vs 337-370 ns), mixed churn 4.3-4.5x
(103-113 vs 22-25 us/update). Sources: 4-array swap sifts (`Heap/init.luau:38-43`, 8 writes/level vs 3), stale pops,
`heap:peek/pop/isEmpty` method calls per iteration (`Group/init.luau:178-184`), `Handle.new` validation +
`_chained = {}` per handle (`Handle/init.luau:79-105`), `_all` set writes (`Group/init.luau:219,146`).

F-ALG-3 (minor, prior): `Group:update` allocates `fireCounts` and `capped` tables every update (`Group/init.luau:173-174`)
— 96 B garbage per update even when idle (19 KB / 200 idle updates measured). Replace with numeric `_burst`/`_burstSerial`.

F-ALG-4 (major, live): `SyncedTimerClass.ForceEventComplete` only takes effect on the heap root. `:281/:289` set
`ForcedComplete`; `:330-332` checks it on `peek()` only; the key is never changed, so a forced non-root entry fires at
its original time. The revamp's `complete()` re-keys to `now`.

F-ALG-5 (info): hashed timing wheel is 3-4x faster per fire in a fire-heavy regime (86-90 vs 337-370 ns) and ties the
heap in the realistic mix (18-23 vs 22-25 us/update), but quantizes to the tick, fires unordered within a slot, and
Luau bucket arrays that empty/refill rehash: 3.8 KB garbage per update (P7). Rejected.

F-ALG-6 (info): sorted array is 20-100x slower on arm/stop/adjust at 10k (4.9/4.4-5.7/17-18 us per op); 10k adjusts
in one frame = 170-200 ms. Only viable below n ~ 100. Rejected.

F-ALG-7 (minor): handle-only heap array (key via `item[i]._due`) is 2x slower per fire than parallel `due[]` (650-740
vs 367 ns) — hash lookups per compare. Parallel arrays it is.

F-ALG-8 (info): 4-ary vs binary within +/-10%, direction varies per phase; Floyd bottom-up pop no measurable win in the
interpreter. Binary, arity isolated; revisit with a native benchmark.

F-ALG-9 (minor): Luau table sizing — <= 8 record fields = 320 B, 9-16 = 576 B; nil-valued fields in the constructor
literal pre-size the table (late assignment +0 B); a 7-field literal that later gains a field rehashes (+256 B garbage
per handle). Declare every field in the literal; the prior Handle has 10 fields + a `_chained` table = 765 B/timer.

F-ALG-10 (info): `xpcall(fn, debug.traceback)` costs 31 ns over a direct call (Lune). Keep it (live F4).

F-ALG-11 (minor, design): the RF-010/013/020/031/039 bug class (post-callback re-arm resurrecting a stopped handle) is
structurally impossible when the heap is finalised BEFORE the callback and the catch-up cap snaps forward instead of
parking. The prior's capped path is the only post-callback mutation in either design.

F-ALG-12 (info): accumulated-clock float error is irrelevant: ulp(1e5 s) = 1.5e-11 s, ulp(1e7 s) = 1.9e-9 s; measured
drift 6e-4 s per 1e4 s at now = 1e7 @ 240 Hz. `UpdateTo` at scale 1 sets `now` exactly and accumulates nothing.

F-ALG-13 (minor, prior): `_adjust` measures `remaining` from `_now` but arms from `_base` (`Group/init.luau:364-366`);
inside a callback these differ by the sub-frame overshoot. Route every op through one `clockOf(self)`.

F-ALG-14 (info, correctness of the prototype): `invariants.luau` passes 20,000 random push/pop/remove/updateKey ops
with the heap property and `_hi` consistency checked, a sorted (due, seq) drain, and a re-entrant "A stops co-due B and
arms due-now C" dispatch test (order A, C; B never fires).

## 6. Recommendations

R1. Adopt the indexed binary heap of 3.2 verbatim as the internal core (module-local functions, parallel `due[]`/`item[]`,
`h._hi`, `h._seq`, hole-move sifts, ownership check in remove/update). Keep arity a two-function change.
R2. Dispatch loop of 3.3: pop/re-key BEFORE the callback, nothing after; re-entrant same-instance update advances the
clock and returns (counted + warned once); nested due-now cap 1000; `_base` carry for every op via `clockOf`.
R3. Catch-up: default `"cap"`, `maxCatchUp = 8`, drop-and-snap-to-grid; `"all"` explicit; per instance and per handle.
R4. Time: `Update(dt)` accumulates (NaN/negative -> error); `UpdateTo(t)` derives from the external clock with an
offset for pause, clamps backwards moves (counted); one `_advanceTo`. Provide `delayAt(absolute)` for synced use.
R5. `h:complete()` (deferred re-key to now) is the ForceEventComplete; `h:fireNow()` synchronous opt-in.
R6. Handles: plain metatable class, 8-field literal + lazy `_ext` (or a flat 12-field literal), numeric states, colon
guard, no pooling. Scheduler instance methods dot-callable via bound closures.
R7. Tests: an O(n) invariant oracle (`item[h._hi] == h` for all i; heap property; Pending set == heap set +
`_pausedSet`) run after every op in the spec suite; the P1-P9 bench under Lune as a regression guard on operation
counts and zero-garbage P2.
R8. Port the bench to Studio `--!native` before deciding 4-ary and `seq[]`-array; ranking will not change.

## 7. Questions for Jake

Q1. Catch-up default: `"cap" 8 + drop` (bounded, phase-preserving, slightly lossy after long hitches) versus legacy
`"all"` (exact tick counts, unbounded bursts, hang risk with tiny periods). Any recur site that counts ticks for game
logic (damage-over-time, regen) would notice a > 8-fire hitch. If "never drop a tick" is required, an owed-counter
mode (D) can be added later without touching the heap.
Q2. Re-entrant Update on the same instance (a yielding callback): silent clock-advance + counter + one warn (proposed),
or a hard error in Studio/test builds only?
Q3. Nested due-now cap default 1000 and its action (break, remainder next frame, warn once): acceptable, or should a
hit be an error in Studio?
Q4. `UpdateTo` backwards clock: clamp + count (proposed) — should a jump > 1 s also warn?
Q5. Handle class: plain metatable (fastest; proposed) or BaseClass for house consistency (measure first)?
Q6. Should the RenderStepped instance default to `catchUp = "cap", maxCatchUp = 1` (cosmetic timers never burst)?
Q7. Is per-slot deterministic ordering (due, then creation seq) the desired tie rule, or should re-armed recurring
handles get a fresh seq per arm (prior's push order)? Creation-seq is proposed; both are deterministic.

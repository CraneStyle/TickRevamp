# TickRevamp — Findings Ledger

Consolidated 2026-09-16 from the eight Wave-1 reports in `research/` (full detail, repros and cites live there).
Counts by severity: critical 5, major 42, minor 54, info 33 (total 134).

`Status` flipped 2026-09-16 after the build went GREEN (278 tests, 0 fail). Every `fixed` row cites a shipped spec in `## Pins` below; every `n/a` gives its reason. `n/a (scope)` = the finding is about a component Veron excludes (TickAPI wrapper, AfterNotTouched, SyncedTimer, RunService/driver, keyed timers, MemoryCategory, payloads) with no Veron analog; `n/a (evidence)` = a measurement, comparison, census or Roblox/BaseClass fact that shaped the design but has no single Veron artifact to fix. `Veron` here means the class + `VeronEvent` handle only (Jake's narrowed scope, QUESTIONS A6).
Post-build counts: **71 fixed, 27 n/a (scope), 36 n/a (evidence), 0 deferred, 0 still-planned.**

| Source | Id | Sev | Finding | Status |
|---|---|---|---|---|
| legacy-bughunt | L-01 | critical | self.err is positive inside recurring callbacks; nested timers wait ~one extra period | fixed |
| syncedtimer-review | S-01 | critical | ForceEventComplete fires only when the forced item reaches the heap top | fixed |
| prior-build-review | B-01 | critical | arm() adds a now-relative remaining to the firing entry's due -> same-pass re-pop -> infinite loop in update() | fixed |
| prior-build-review | B-02 | critical | Unbounded same-pass dispatch: delay(fn,0) rescheduled from a callback is a busy loop | fixed |
| roblox-timing | RT-1 | critical | Stepped/PreSimulation/PostSimulation never fire in Studio Edit mode; Heartbeat does | n/a (scope: RunService hooks) |
| callsites | CS-01 | major | Live colon-misuse bug: TickAPI.Tick:remove is a silent no-op | fixed |
| callsites | CS-02 | major | ASSESSMENT.md handle-method counts are whole-mirror token counts, not Tick usage | n/a (evidence) |
| callsites | CS-03 | major | Handles must remain tables; two live type() discriminators and cross-wrapper stops depend on it | n/a (evidence) |
| callsites | CS-04 | major | SyncedTimer ForceEventComplete is deferred, callers expect immediate completion | fixed (Complete deferred by design; CompleteNow sync) |
| callsites | CS-05 | major | 40 fire-and-forget recur timers are unstoppable; 144 results discarded overall | n/a (evidence) |
| legacy-bughunt | L-02 | major | Swap-on-remove during the downward update loop double-charges dt and can double-fire | fixed |
| legacy-bughunt | L-03 | major | A throwing callback leaves self.err poisoned until the next successful update | fixed |
| legacy-bughunt | L-04 | major | Immediate-fire path: nested recur degrades to one-shot + eternal noop; nested recur(fn,0) hangs; handle nil in own fn | fixed |
| legacy-bughunt | L-05 | major | A yielding callback suspends update() mid-loop; the next frame's update runs concurrently on the same array | fixed |
| legacy-bughunt | L-06 | major | Recurring event that stops itself while lagging keeps firing this frame and leaks a false key per extra stop | fixed |
| legacy-bughunt | L-07 | major | delay(fn, NaN) is accepted and becomes a permanent zombie; P accepts it and fires it immediately | fixed |
| legacy-bughunt | L-08 | major | Catch-up burst after a hitch is unbounded and synchronous (legacy and P default) | fixed |
| legacy-bughunt | L-23 | major | AfterNotTouched: if fn throws, Destroy never runs; object and Id leak, Touch() is a silent no-op forever | n/a (scope: AfterNotTouched) |
| legacy-bughunt | L-24 | major | AfterNotTouched leaks one F3 false key on every natural fire | n/a (scope: AfterNotTouched) |
| syncedtimer-review | S-02 | major | AdjustTime anchors scaled remaining at original start, not now; NaN at LifeTime 0 | fixed |
| syncedtimer-review | S-03 | major | Unprotected callback; a throw aborts the pass and leaves a phantom weak record blocking the Id | fixed |
| syncedtimer-review | S-04 | major | Lume.count(StoredClockRef) hash-walks all clocks every frame | n/a (scope: SyncedTimer) |
| syncedtimer-review | S-05 | major | MinHeap remove/update are O(n) twice: indexof scan plus a siftdown loop over every slot from siftedindex to 1; ProcessObj pays an O(n) miss per fire | fixed |
| syncedtimer-review | S-06 | major | ResetTimer/AdjustTime from inside the timer's own callback are silently lost but return true; Remove guard is dead code | fixed |
| syncedtimer-review | S-07 | major | No per-update catch-up cap: zero-LifeTime self-re-add loops forever inside one ProcessEvents pass | fixed |
| prior-build-review | OPEN-8 | major | Capped catch-up re-arm resurrects a handle its callback stopped/paused/reset — confirmed and worse than filed (see B-06) | fixed |
| prior-build-review | B-03 | major | Undocumented deviation: timers created inside a RECURRING callback fire one full period earlier than legacy | fixed |
| prior-build-review | B-04 | major | update() is not re-entrant: nested update from a callback corrupts the outer pass | fixed |
| prior-build-review | B-05 | major | No input hardening: NaN/inf/negative dt and timeScale, NaN period corrupts heap order | fixed |
| prior-build-review | B-06 | major | Capped re-arm path bypasses handle state on EVERY fire when cap=1 (elevates OPEN-8) | fixed |
| roblox-timing | RT-2 | major | Heartbeat deltaTime is wall-clock and unclamped | n/a (evidence) |
| roblox-timing | RT-3 | major | Heartbeat is NOT deprecated; PostSimulation is not a drop-in alias | n/a (evidence) |
| roblox-timing | RT-4 | major | task.delay is 26× more expensive to create than a Luau heap insert; per-timer Heartbeat connections blow the frame | n/a (evidence) |
| roblox-timing | RT-5 | major | Official frame order fixes where task.wait/delay resume: just before Heartbeat handlers | n/a (evidence) |
| roblox-timing | RT-6 | major | Clock selection: accumulate dt for hook schedulers; GetServerTimeNow via UpdateAt for synced | n/a (evidence) |
| baseclass-conventions | F1 | major | BaseClass subclasses dispatch 3.7x slower than root classes | n/a (evidence) |
| baseclass-conventions | F2 | major | Class:new costs 4-5x a constructor table; handles need a ctor-table/free-list path | n/a (evidence) |
| baseclass-conventions | F3 | major | ObjectPool mixin is unfit for handle pooling | n/a (evidence) |
| baseclass-conventions | F4 | major | Live colon call TickAPI.Tick:remove(x) is a silent no-op | fixed |
| scheduler-algorithms | F-ALG-1 | major | Prior lazy deletion doubles the heap under reset/adjust storms and pays O(n) rebuild spikes | fixed |
| scheduler-algorithms | F-ALG-2 | major | Prior Group per-fire cost is 2.7x the indexed prototype; mixed churn 4.3-4.5x | n/a (evidence) |
| scheduler-algorithms | F-ALG-4 | major | Live SyncedTimerClass.ForceEventComplete only takes effect when the entry is the heap root | fixed |
| semantics-spec | SEM-01 | major | Legacy/rxi: stopping an unprocessed timer from a callback double-ticks an already-processed entry (early fire); rxi crashes on shrink | fixed |
| semantics-spec | SEM-02 | major | Legacy/rxi: stop() inside a lagging recurring callback is ignored; the while loop keeps firing the stopped event | fixed |
| semantics-spec | SEM-03 | major | NaN dt permanently poisons both legacy and prior (opposite failure modes); NaN delay accepted by all three | fixed |
| semantics-spec | SEM-04 | major | Prior: after() on a Fired/Stopped parent returns the PARENT object and silently drops fn | fixed |
| semantics-spec | SEM-05 | major | SyncedTimerClass AdjustTime is not ratio-preserving and ForceEventComplete only works when the entry is at the heap top | fixed |
| callsites | CS-06 | minor | Nesting is mostly dynamic; 21 callbacks stop their own handle | n/a (evidence) |
| callsites | CS-07 | minor | Sub-frame recur periods rely on legacy catch-up (multi-fire per update) — deviation not in ASSESSMENT | n/a (evidence) |
| callsites | CS-08 | minor | adjust: 2 ratio-dependent sites, may execute on an already-fired handle | n/a (evidence) |
| callsites | CS-09 | minor | reset: 7 debounce-style resets on one-shots, 2 on recurring timers | n/a (evidence) |
| callsites | CS-10 | minor | Wrapper-copy census: two dead copies, plugin copy lacks adjust/reset, FxPackage double-requires the main wrapper | n/a (scope: wrapper copies) |
| callsites | CS-11 | minor | xray.luau depends on a leaked global TickAPI | n/a (scope: caller/wrapper) |
| callsites | CS-12 | minor | SyncedTimer caller bugs and unused surface | n/a (scope: SyncedTimer) |
| legacy-bughunt | L-09 | minor | reset() drifts phase inside recurring callbacks and is a silent no-op after a one-shot fired | fixed |
| legacy-bughunt | L-10 | minor | adjust() accepts 0, negative, nil and strings with destructive results | fixed |
| legacy-bughunt | L-11 | minor | after() dead chains are silent; P returns the parent instead of a child on terminal handles | fixed |
| legacy-bughunt | L-12 | minor | Bound-table colon misuse: Tick:remove(h) is a silent no-op (h still fires); Tick:getClocks() is 0 | fixed |
| legacy-bughunt | L-13 | minor | Same-frame fire order is newest-first and scrambled after any removal | fixed |
| legacy-bughunt | L-14 | minor | Float boundary: delay(3*dt) fires on the 4th frame | fixed |
| legacy-bughunt | L-15 | minor | Public Tick.remove(number) with a bad index throws 'table index is nil' | fixed |
| legacy-bughunt | L-21 | minor | Tickr is nil on the server; GetAfterNotTouched(_,_,'Tickr') errors inside the class | n/a (scope: Tickr/AfterNotTouched) |
| legacy-bughunt | L-25 | minor | AfterNotTouched constructed inside a callback with a tiny delay is destroyed before it is registered (zombie) | n/a (scope: AfterNotTouched) |
| legacy-bughunt | F6 | minor | Confirmed absent in P: adjust() on a zero-period handle yields NaN due and fires after one frame | fixed |
| syncedtimer-review | S-08 | minor | #heap is always 0 (__len bound to undefined BinaryMinHeap.len) | n/a (scope: SyncedTimer) |
| syncedtimer-review | S-09 | minor | AddEvent Id dedupe returns nil silently; callers overwrite their stored Id with nil | fixed |
| syncedtimer-review | S-10 | minor | Per-event GUID + payload table allocation; table.unpack truncates nil-holed payloads | n/a (scope: payloads/SyncedTimer) |
| syncedtimer-review | S-11 | minor | Client processing is network-cadenced with a non-monotonic clock; server AddEvent can read a 1-frame-stale WorldTime | n/a (scope: SyncedTimer) |
| syncedtimer-review | S-12 | minor | ResetTimer(Id, X) sets due = now + X but leaves LifeTime unchanged | fixed |
| prior-build-review | OPEN-1 | minor | adjust() on zero/inf-period handle yields NaN due, fires immediately (RF-001 family) — confirmed | fixed |
| prior-build-review | OPEN-2 | minor | compact()/Heap.rebuild does run mid-update; header comment Group:54-55 is false — confirmed | fixed |
| prior-build-review | OPEN-3 | minor | TickAPI.new groups have no teardown; group._unbind dead store; RunService connection leak — confirmed | n/a (scope: TickAPI wrapper) |
| prior-build-review | OPEN-4 | minor | iscallable duplicated in Handle:58-64 and Variants:60-66 — confirmed (static) | n/a (evidence) |
| prior-build-review | OPEN-5 | minor | h:pause() on Paused/Chained raises raw 'illegal transition' with file:line — confirmed | fixed |
| prior-build-review | OPEN-6 | minor | MIGRATION.md omits all documented deviations — confirmed; three more found | fixed |
| prior-build-review | OPEN-7 | minor | Default driver 'Manual' makes TickAPI.new({...}) silently never fire — confirmed | n/a (scope: driver) |
| prior-build-review | B-07 | minor | after() on a terminal handle returns the parent itself | fixed |
| prior-build-review | B-08 | minor | group.clear() strands AfterNotTouched objects in Storage forever | n/a (scope: AfterNotTouched) |
| prior-build-review | B-09 | minor | Lazy deletion pins stopped handles and their closures until due or compaction | fixed |
| prior-build-review | B-10 | minor | Per-update and per-object allocation: 96 B/update/group idle, ~756 B/handle, ~2.7 KB/group | fixed |
| prior-build-review | B-11 | minor | Driver.bind on a signal the RunService lacks raises a raw 'attempt to index nil with Connect' | n/a (scope: driver) |
| prior-build-review | B-12 | minor | Driver._inject is module-global state that bleeds between tests and into builtins | n/a (scope: driver) |
| prior-build-review | B-13 | minor | Undocumented deviation: a parent whose callback errors still arms its after() children | fixed |
| prior-build-review | B-14 | minor | getRemaining() on a Chained child returns its period, not time-until-fire | fixed (pins design value, not research fix) |
| prior-build-review | B-17 | minor | _inHeap written by Group but absent from HandleImpl type; _due only lazily present | fixed |
| prior-build-review | B-18 | minor | Handle methods are colon-only; dot-call misuse gives an internal error | fixed |
| prior-build-review | B-19 | minor | AfterNotTouched re-raise drops the original traceback | n/a (scope: AfterNotTouched) |
| prior-build-review | B-22 | minor | Variants name counter and coercion cosmetics | n/a (evidence) |
| roblox-timing | RT-7 | minor | Legacy SyncedTimer compares heap keys on one axis against Stepped.time on another | n/a (scope: SyncedTimer) |
| roblox-timing | RT-8 | minor | Luau dispatch and allocation costs (Lune 0.10.5+709 interpreter) | n/a (evidence) |
| roblox-timing | RT-9 | minor | --!native: limits and skip rules verified in Luau source; no upvalue-count rule exists | n/a (evidence) |
| baseclass-conventions | F5 | minor | Stateful and Callbacks mixins are hot-path poison; Callbacks' allocate hook is inert | n/a (evidence) |
| scheduler-algorithms | F-ALG-3 | minor | Prior Group allocates two tables per update even when idle | fixed |
| scheduler-algorithms | F-ALG-7 | minor | Handle-only heap array is 2x slower per fire than parallel due[] | n/a (evidence) |
| scheduler-algorithms | F-ALG-9 | minor | Luau handle table sizing: keep <= 8 fields or declare all fields in the constructor literal | n/a (evidence) |
| scheduler-algorithms | F-ALG-11 | minor | Post-callback re-arm (RF-010 class) is structurally eliminated by re-key-before-callback + snap-forward catch-up | fixed |
| scheduler-algorithms | F-ALG-13 | minor | Prior _adjust mixes _now and _base inside a callback | fixed |
| semantics-spec | SEM-06 | minor | Prior: reset/adjust/resume from another handle's callback are measured from the firing entry's due, not now | fixed |
| semantics-spec | SEM-07 | minor | Prior: pause() on a Chained or Paused handle raises the raw internal 'illegal transition' error (RF-006 family, open) | fixed |
| semantics-spec | SEM-08 | minor | Legacy same-frame and multi-after ordering is newest-first (LIFO); prior/recommended is FIFO (due, seq) | fixed |
| semantics-spec | SEM-09 | minor | Legacy nested delay(0) inside a callback is frame-dependent (sync when overshoot>0, next frame when exactly 0) | fixed |
| callsites | CS-13 | info | Client/server split and Tickr safety | n/a (scope: TickAPI/game) |
| callsites | CS-14 | info | Same-frame ordering and nested-synchronous deviations have no dependent callers | n/a (evidence) |
| callsites | CS-15 | info | Overlapping timer utilities in H | n/a (evidence) |
| legacy-bughunt | L-16 | info | Nested update() from a callback double-charges dt and clobbers the carry | fixed |
| legacy-bughunt | L-17 | info | Validation reports the post-coercion type and accepts numeric strings | fixed |
| legacy-bughunt | L-18 | info | TickAPI signal argument mapping is correct; no teardown path exists | n/a (scope: TickAPI wrapper) |
| legacy-bughunt | L-19 | info | debug.setmemorycategory('TickAPI') at load tags only the requiring thread | n/a (scope: MemoryCategory) |
| legacy-bughunt | L-20 | info | 'Tickh does not happen on the server' comment is false as stated | n/a (scope: TickAPI/Tickh) |
| legacy-bughunt | L-22 | info | F10 refinement: every wrapper copy drives its own Tick module; no shared group is double-updated | n/a (scope: wrapper copies) |
| legacy-bughunt | L-26 | info | AfterNotTouched Storage is unreachable and SafeLoad is one-shot | n/a (scope: AfterNotTouched) |
| syncedtimer-review | S-13 | info | Dead code, unused requires, unvalidated heap inputs | n/a (scope: SyncedTimer) |
| syncedtimer-review | S-14 | info | Force-then-Delete never fires (Delete wins); deferred Force causes double KillMe/OnReject at call sites | fixed |
| syncedtimer-review | S-15 | info | Call-site: the only AdjustTime caller adjusts the wrong timer (shared upvalue), so anchored adjust has never run in production | n/a (scope: SyncedTimer) |
| prior-build-review | OPEN-9 | info | RF-011 resume() on Pending/Chained — fixed, confirmed | fixed |
| prior-build-review | B-15 | info | getRemaining() under timeScale reports group-time, not wall-time — undocumented design choice | fixed (documented group-time choice) |
| prior-build-review | B-16 | info | delay(fn,0) fires on the next update even when timeScale==0 | fixed |
| prior-build-review | B-20 | info | Exact-boundary fires can land one frame later than legacy; _now drift itself negligible | fixed |
| prior-build-review | B-21 | info | Default maxCatchUpPerFrame=nil is unbounded; update(inf) never terminates | fixed |
| roblox-timing | RT-10 | info | Prior-art catch-up policies and iteration-safety patterns catalogued | n/a (evidence) |
| roblox-timing | RT-11 | info | Actors: separate VM per Actor, callbacks cannot cross; scheduler stays serial, no Actor by default | n/a (evidence) |
| baseclass-conventions | F6 | info | Live BaseClass is not Lune-loadable; standalone core works (73/73) but is 7/49 tasks in | fixed |
| baseclass-conventions | F7 | info | Instance field misses cost 6.6x hits; initialize every field non-nil | n/a (evidence) |
| baseclass-conventions | F8 | info | House templates and the exemplar declare classes as globals; 'AfterNotTouched' name already registered | n/a (evidence) |
| baseclass-conventions | F9 | info | class + type fields are free unless the handle crosses 8 or 16 fields | n/a (evidence) |
| scheduler-algorithms | F-ALG-5 | info | Hashed timing wheel wins fire-heavy regime but is quantized, unordered and churns Luau bucket arrays | n/a (evidence) |
| scheduler-algorithms | F-ALG-6 | info | Sorted array loses 20-100x on arm/stop/adjust at 10k | n/a (evidence) |
| scheduler-algorithms | F-ALG-8 | info | 4-ary heap and Floyd pop give no decisive win in the interpreter | n/a (evidence) |
| scheduler-algorithms | F-ALG-10 | info | xpcall overhead is 31 ns per callback; keep the protected call | n/a (evidence) |
| scheduler-algorithms | F-ALG-12 | info | Accumulated virtual clock float error is irrelevant | n/a (evidence) |
| scheduler-algorithms | F-ALG-14 | info | Indexed-heap prototype passes invariant and re-entrancy tests | fixed |
| semantics-spec | SEM-10 | info | Live colon-call TickAPI.Tick:remove(LastTickObject) is a silent no-op plus leak on legacy; dual-call support will change its behavior | fixed |
| semantics-spec | SEM-11 | info | ASSESSMENT.md live counts for handle:after (31) and :adjust (9) are inflated; real Tick :after consumers = 0, :adjust = 2 | n/a (evidence) |
| semantics-spec | SEM-12 | info | Legacy and prior both allow re-entrant update() from a callback with no guard; prior's inner pass clears the base carry | fixed |

## Pins (fixed rows → spec)

Format: `<id> -> spec/<area>/<name>_spec :: <test>` (or `parity :: DV-n`). `regress` = `regress/repros_spec`; `parity` = `parity/parity_spec`. Where several specs pin a row, the first is the primary pin.

### Critical
- L-01 -> regress :: L-01 | dispatch_spec :: nested delay measured from firing due | parity :: DV-7
- S-01 -> regress :: S-01 | complete_spec :: completes a non-root entry
- B-01 -> regress :: B-01 | retime_spec :: adjust inside own lagging recurring callback fires at most twice
- B-02 -> regress :: B-02 | catchup_spec :: valve: zero-delay self-rescheduling one-shot stops at 1000, warns once via OnError, resumes next update

### Major
- CS-01 -> parity :: DV-3 | stop_spec :: instance colon form TickAPI.Tick:remove(h) removes
- CS-04 -> complete_spec :: deferred re-keys to now and fires next update in order | complete_spec :: CompleteNow inside own callback returns false | regress :: S-14 (see FLAGS: default kept deferred per Q-J2)
- L-02 -> regress :: L-02 | reentrancy_spec :: stop a co-due sibling from a callback never fires it and nothing advances twice | parity :: DV-9
- L-03 -> regress :: L-03 | parity :: DV-15
- L-04 -> regress :: L-04 | dispatch_spec :: nested past-due one-shot fires later in the same update with a real handle
- L-05 -> regress :: L-05 | reentrancy_spec :: yield-overlap (coroutine) keeps other timers firing and drains on resume
- L-06 -> regress :: L-06 | reentrancy_spec :: stop self inside own recurring callback while lagging fires once | parity :: DV-8
- L-07 -> regress :: L-07 | arm_spec :: NaN and inf rejected | parity :: DV-4
- L-08 -> catchup_spec :: cap 8: 5 s hitch on a 0.1 s recur fires 8 then snaps to the grid | parity :: DV-10
- S-02 -> regress :: S-02 | retime_spec :: adjust preserves consumed fraction
- S-03 -> dispatch_spec :: throwing callback does not stop siblings | parity :: DV-15 | errors_spec :: Stats.Errors increments
- S-05 -> heap_spec :: 20000 random push/pop/remove/updateKey keep the invariant every 97 ops | heap_spec :: remove of a middle element sifts the right way | heap_spec :: updateKey decrease and increase
- S-06 -> regress :: S-06 | retime_spec :: reset inside own recurring callback replaces d+period
- S-07 -> catchup_spec :: period below float resolution stops the handle with one report | catchup_spec :: valve counts repeats under uncapped | parity :: DV-10
- OPEN-8 -> regress :: B-06 | regress :: RF-010 | reentrancy_spec :: stop then reset in the same callback does not resurrect
- B-03 -> regress :: B-03 | dispatch_spec :: nested inside recur corrected | dispatch_spec :: LegacyRecurBase reproduces legacy | parity :: DV-7
- B-04 -> regress :: B-04 | reentrancy_spec :: nested Update under error policy keeps the outer raise and reports once | parity :: DV-21
- B-05 -> regress :: B-05 | time_spec :: negative, NaN, inf, nil, string dt error before touching state with the prefixed message | parity :: DV-4, DV-23
- B-06 -> regress :: B-06 | regress :: RF-010
- F4 -> parity :: DV-3 | stop_spec :: instance colon form TickAPI.Tick:remove(h) removes
- F-ALG-1 -> heap_spec :: updateKey decrease and increase | bench P4/P9 (heap stays 10k, no rebuild spikes)
- F-ALG-4 -> regress :: S-01 | complete_spec :: completes a non-root entry
- SEM-01 -> reentrancy_spec :: stop a co-due sibling from a callback never fires it and nothing advances twice | parity :: DV-9 | regress :: L-02
- SEM-02 -> regress :: L-06 | reentrancy_spec :: stop self inside own recurring callback while lagging fires once | parity :: DV-8
- SEM-03 -> time_spec :: negative, NaN, inf, nil, string dt error before touching state | parity :: DV-23, DV-4 | regress :: B-05
- SEM-04 -> regress :: B-07, L-11 | chain_spec :: After on Fired arms from the caller's clock, never returns the parent | parity :: DV-13
- SEM-05 -> regress :: S-02, S-01 | retime_spec :: adjust preserves consumed fraction | complete_spec :: completes a non-root entry

### Minor
- L-09 -> regress :: L-09 | retime_spec :: reset inside own recurring callback replaces d+period
- L-10 -> retime_spec :: adjust rejects 0, negative, NaN, inf, nil | parity :: DV-4 | regress :: F5
- L-11 -> regress :: L-11 | chain_spec :: After on Fired arms from the caller's clock, never returns the parent | parity :: DV-13
- L-12 -> parity :: DV-3, DV-12
- L-13 -> regress :: L-13 | parity :: DV-1 | dispatch_spec :: equal dues fire in creation order
- L-14 -> parity :: DV-11 | dispatch_spec :: Delay(3*dt) one update late is documented, not fudged
- L-15 -> regress :: L-15 | parity :: DV-17 | stop_spec :: remove number false
- F6 (legacy) -> regress :: F6 | regress :: RF-001 | retime_spec :: adjust on period 0 uses the whole newTotal, never NaN
- S-09 -> regress :: S-09
- S-12 -> regress :: S-12 | retime_spec :: SetRemaining leaves period
- OPEN-1 -> regress :: RF-001, F6 | retime_spec :: adjust on period 0 uses the whole newTotal, never NaN
- OPEN-2 -> heap_spec :: updateKey decrease and increase | bench P9 (no rebuild spikes) — indexed heap has no compaction
- OPEN-5 -> regress :: RF-006 | state_spec :: pause on Paused, resume on Pending are no-ops, never a raw transition error
- OPEN-6 -> docs_spec :: every DV of §7.3 appears in MIGRATION.md
- B-07 -> regress :: B-07 | chain_spec :: After on Fired arms from the caller's clock, never returns the parent | parity :: DV-13
- B-09 -> parity :: DV-5 (closure released, _Fn == NOOP) | heap_spec :: remove of a middle element sifts the right way
- B-10 -> alloc_spec :: 1000 idle updates with 10k armed allocate 0 bytes | bench P1/P15
- B-13 -> regress :: B-13 | chain_spec :: erroring parent still arms children | parity :: DV-6
- B-14 -> regress :: B-14 | chain_spec :: GetRemaining on a Chained child is its delay (see FLAGS)
- B-17 -> class_spec :: handle literal has exactly 14 keys, every value non-nil
- B-18 -> regress :: B-18 | state_spec :: handle dot-call raises the colon message | parity :: DV-20
- F-ALG-3 -> alloc_spec :: 1000 idle updates with 10k armed allocate 0 bytes | bench P2 (0 KB exactly)
- F-ALG-11 -> regress :: RF-010 | dispatch_spec :: recurring is re-keyed before its callback
- F-ALG-13 -> retime_spec :: explicit ops from now not base
- SEM-06 -> retime_spec :: reset one-shot full period from now even from another callback | retime_spec :: explicit ops from now not base
- SEM-07 -> regress :: RF-006 | state_spec :: pause on Paused, resume on Pending are no-ops
- SEM-08 -> parity :: DV-1 | regress :: L-13 | chain_spec :: multiple children fire in registration order
- SEM-09 -> dispatch_spec :: nested delay 0 fires in the same update | parity :: DV-2

### Info
- L-16 -> regress :: L-16 | reentrancy_spec :: sync re-entrant Update dispatches other timers and restores the base | parity :: DV-21
- L-17 -> arm_spec :: non-number reports original type | arm_spec :: numeric string coerced | parity :: DV-24
- S-14 -> regress :: S-14 | complete_spec :: Complete from own callback returns false
- OPEN-9 -> state_spec :: resume while Chained clears the flag | state_spec :: pause on Paused, resume on Pending are no-ops
- B-15 -> docs_spec :: API.md explains the rolling-clock decision in plain language | time_spec :: rolling clock accumulates dt * TimeScale
- B-16 -> time_spec :: TimeScale 0 freezes, delay 0 still fires | arm_spec :: delay 0 fires next update even with dt 0
- B-20 -> parity :: DV-11 | dispatch_spec :: Delay(3*dt) one update late is documented, not fudged
- B-21 -> catchup_spec :: cap 8: 5 s hitch ... snaps to the grid | time_spec :: negative, NaN, inf, nil, string dt error (update(inf) rejected)
- F6 (baseclass) -> env_spec :: IsRoblox is false under Lune and Env exposes exactly IsRoblox/Load/SetWarn/Traceback/Warn (resolved 2026-09-16 by dropping the BaseClass dependency entirely, not by vendoring it — Q-J15's vendored copy and its two diff tests are gone, see docs/DESIGN.md banner)
- F-ALG-14 -> heap_spec :: 20000 random push/pop/remove/updateKey keep the invariant every 97 ops
- SEM-10 -> parity :: DV-3 | stop_spec :: instance colon form TickAPI.Tick:remove(h) removes
- SEM-12 -> regress :: L-16, B-04 | reentrancy_spec :: sync re-entrant Update dispatches other timers and restores the base | parity :: DV-21

## FLAGS (build behaviour vs the finding's assumption — for Jake)

Three fixed rows ship behaviour that deliberately DIVERGES from what the original finding implied should happen. All are conscious, documented decisions, not regressions:

- **CS-04** — the finding assumed callers expect *immediate* completion. The design (Q-J2) kept `Complete()` **deferred** (fires next update) because the five live `ForceEventComplete` callers run their own cleanup right after the call, and added `CompleteNow()` for the synchronous case. So the default is the opposite of the finding's stated expectation, by design.
- **B-14** — the finding read `getRemaining()` returning a Chained child's *period* (not time-until-fire) as a bug. The build **keeps** `GetRemaining` on a Chained child == its own delay as the documented §5 value; `chain_spec`/`repros B-14` pin the design value, NOT the research's suggested change (BUILD-NOTES §4 "Parity and repros").
- **B-15** — the finding noted `getRemaining()` under `timeScale` reports group-time (not wall-time) as an *undocumented* choice. The build **keeps** group-time and documents it (rolling-clock decision in API.md); it did not switch to wall-time.

## Notes

- **0 deferred:** the §13 deferred minors (F-PM-8, F-PM-9, JF-16/17/18 halves) are design-stage ids, not Wave-1 ledger rows — no ledger finding maps to one, so no row is `deferred`.
- **0 still-planned:** every row resolved to fixed / n/a with a cited spec or a scope/evidence reason.
- Many `fixed` rows were first observed in legacy Tick, the prior TickAPIOptimize build, or SyncedTimer; they are `fixed` because Veron eliminates the defect *class* and a shipped spec pins the corrected behaviour (per the flip rubric), even though the original observation was elsewhere.

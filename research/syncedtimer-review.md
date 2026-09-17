# SyncedTimerClass + MinHeap — deep review (TickRevamp research)

Targets: `reference/live/SyncedTimerClass.luau` (435 lines, live singleton) and `reference/live/MinHeap.luau` (261 lines, the heap it uses). All cites are to those two files unless prefixed. Call-site evidence comes from the read-only mirror `H = C:/Users/Faded/Documents/GitHub/HeroicSouls-BackUp` (commit fdb6efba8). Every numeric claim below was executed under Lune 0.10.5 with the harnesses in `research/scratch/syncedtimer/`:

| harness | what it runs |
|---|---|
| `scratch/syncedtimer/heap_test.luau` | MinHeap invariants (2000 random inserts, 1500 random removes), dequeue order, batchenq, `#heap`, timing of remove vs dequeue at n=20000 |
| `scratch/syncedtimer/heap_cmp_count.luau` | counts priority comparisons per op via `__lt` proxies (n=16383) |
| `scratch/syncedtimer/synced_sim.luau` | line-faithful re-implementation of the SyncedTimer core over the real MinHeap with an injectable clock; runs the adjust, force, re-entry, error, runaway and cost scenarios |
| `scratch/syncedtimer/gc_probe.luau` | `collectgarbage("collect")` is not available under Lune, so the weak-table collection claim (S-03) is reasoned, not observed |

`SyncedTimerClass.luau` itself cannot be loaded under Lune (`game` at :20-35, `Terrain.WorldTime` at :52); `MinHeap.luau` loads unmodified.

---

## 1. Exact semantics

### 1.1 Construction / singleton
- `SyncedTimer = BaseClass.class("SyncedTimer"):include(Stateful)` (:38) with two states `SyncedTimerClient` / `SyncedTimerServer` (:40-41). `initialize` (:100-117) stores itself in `SyncedTimerClass.SingltonStore` (:102; that header table is never returned, so the field is unreachable from outside — dead), creates one `MinHeap` (:103), `gotoState`s by `RunService:IsServer()` (:105-114), on the client requires `ReplicatedFirst.LocalOnly.Modules.SyncTime` (:112), then `SetUpProcessing()` (:116).
- The module returns `SyncedTimer:new()` (:435) — one instance per VM. State methods resolve through Stateful's `__index` chain (`reference/baseclass/Stateful.luau:38-56`): `GetWorldTime`, `_SetEventTimeToCurrentTime`, `SetUpProcessing` are per-state; everything else is on the base class.
- Requires that are never used: `RBX_Utility` (:23), `MediatorAPI` (:32), `RouterPaths` (:33). `TickAPI` (:24) is used only by `_debugStorageTracking` (:78-88), which is never called. (Already noted in `P/build/docs/migration/MIGRATION.md:38-39`.)

### 1.2 Time model — absolute world time, per VM
- Server: `GetWorldTime()` = `workspace.Terrain.WorldTime.Value` (:52, :149). That NumberValue is written every `RunService.Stepped` by `H/Workspace/Terrain_[Terrain]/WorldTime_[NumberValue]/WorldTimeMod_[Module].luau:9-11` with Stepped's first argument (`script.Parent.Value = serverTime`). `SyncedTimerServer:SetUpProcessing` (:427-433) connects `ProcessEvents(currentTime, dt)` to `RunService.Stepped` and passes Stepped's `time` straight through — so the heap axis (`WorldTime.Value + LifeTime`) and the comparison point (Stepped `time`) are the same clock. One caveat: a Stepped handler that runs before `WorldTimeMod.ServerUpdate` in the same frame reads last frame's `WorldTime.Value`, so an `AddEvent` from such a handler computes a due ~1 frame (≈16 ms) early relative to the `currentTime` it will be compared against.
- Client: `GetWorldTime()` = `SyncTime.GetTime()` (:144) = `SyncTime.Time`, which is overwritten by the `Client_SyncTime` remote (`H/ReplicatedFirst/LocalOnly_[Folder]/Modules_[Folder]/SyncTime_[Module].luau:11-19`). The server fires that remote **every Heartbeat per character** (`H/.../CharacterSheet_History_[Module].luau:229-245` (`RunServ.Heartbeat:Connect(Sync)` at :243) → `SyncTime()` :248-258 → `FireClient(player, lag + serv)`, where `lag` is the mean of the last three measured travel times and `serv` is `WorldTime.Value`). `SyncedTimerClient:SetUpProcessing` (:416-422) registers with `SyncTime.ConnectFunctionToSyncTime`, so on the client `ProcessEvents` runs **once per received remote, not once per frame**, `currentTime` is the received value, and `dt` is `nil` (SyncTime calls `fn(val)` only). `dt` is unused in `ProcessEvents` anyway (:356).
- Client `now` is not monotonic: it is `server time + latency estimate`, and the estimate moves as pings change. A due computed against a `now` that later steps backward fires late; one computed before an upward step fires early. Nothing in the class guards this.

### 1.3 Storage
- `StoredClockRef = Lume.getWeakVariableTable()` (:48) → `setmetatable({}, {__mode = "v"})` (`H/.../Lume_[Module].luau:658-661`). Keys are Id strings (strong), values are the clock-data tables (weak). Values are kept alive only by the heap's `_items` array while enqueued (`MinHeap.luau:96-104`). `AddEvent` stores the record (:183 → :388-390) and enqueues the same table with `NextEventTime` as priority (:189-192).
- Clock record shape (:63-73): `LifeTime`, `NextEventTime`, `Id`, `Func` (defaults to `NOOP`, :68), `Data = {...}` (:69, :180), `Remove = false`, `ForcedComplete = false`.

### 1.4 API (as implemented)
| method | behaviour | cite |
|---|---|---|
| `HasObject(Id)` | `StoredClockRef[Id] ~= nil` | :124-126 |
| `GetRemainingTime(Id)` | `max(NextEventTime - now, 0)`; **0 for an unknown Id** (indistinguishable from "due now") | :131-139 |
| `AddEvent(LifeTime, func, Id, ...)` | if `HasObject(Id)` → **returns nil silently**; `Id = Id or HttpService:GenerateGUID()` (allocation + string per anonymous event); `due = now + LifeTime`; `Data = {...}`; enqueue; returns Id | :169-195 |
| `ResetTimer(Id, timeToReset)` | `due = now + (timeToReset or LifeTime)`; `LifeTime` is **not** changed; heap `update` | :215-229, :202-209 |
| `AdjustTime(Id, newTotal)` | `due = (remaining/LifeTime) * newTotal + (NextEventTime - LifeTime)`; then `LifeTime = newTotal`; heap `update` | :244-272 |
| `ForceEventComplete(Id)` | sets `ForcedComplete = true` only (both states, :280-290); returns true | :298-305 |
| `DeleteEvent(Id)` | heap `remove` (O(n)), then clears the Id slot; returns false if absent, otherwise **returns nothing** | :311-316 |
| `ProcessEvents(currentTime, dt)` | bail if `Lume.count(StoredClockRef) <= 0` or heap empty (:342-351); `while _isNextEventValidToProcess do ProcessObj() end` | :356-363 |
| `_isNextEventValidToProcess` | heap empty → false; peek; **top.ForcedComplete → true**; `Priority > currentTime` → false; else true | :326-337 |
| `ProcessObj` | dequeue; `if Remove ~= false then return end`; `Remove = true`; `Func(table.unpack(Data))` **unprotected**; `DeleteEvent(Id)` | :369-380 |

Live call-site inventory (H, 61 references, 17 files): `AddEvent` ×22, `ForceEventComplete` ×6, `DeleteEvent` ×4, `ResetTimer` ×4, `HasObject` ×2, `GetRemainingTime` ×2, `AdjustTime` ×1. Id-keyed users: Status (`OwnerId..Name`, `H/.../private_Status_[Module].luau:16,25-36`), GroupInviteAlert (`self.Id`, :150-158, :167-175), StrikesOverTime (`self.Id`, :80-85). Everyone else relies on GUIDs.

---

## 2. What the due-prefix heap buys vs the legacy full scan, and what it costs

Buys (measured, `synced_sim.luau` S-cost and `P/build/bench/BENCH.md:22-50`):
- Legacy `tick:update` (`reference/live/Tick.luau:140-158`) decrements every clock every frame: at n=10,000 that is 10,000 examined per frame, 37.6 ms / 200 frames in P's bench. The heap loop examines only the due prefix plus one peek: 10 due of 10,010 → 10 pops + 1 peek. With the O(n) `Lume.count` guard removed, an idle frame is O(1).
- `GetRemainingTime`, `ResetTimer`, `AdjustTime` are pure arithmetic on an absolute due — no per-frame decrement, no accumulated error term (legacy carries `self.err`, `Tick.luau:151,158,183`).
- Ids give O(1) addressability without holding the record (cooldown checks such as `Action:HasCoolDown` → `HasObject`, `H/.../Action_[Module].luau:316`).

Costs (as implemented):
- The class pays O(n) every frame anyway (S-04): 57–64 µs/frame idle at n=10,010 in the sim.
- Every fired event pays an O(n) miss in `DeleteEvent → MinHeap:remove → indexof` (S-05): 10 fires of 10,010 = 606 µs, i.e. ~60 µs per fire, versus ~0.5 µs per dequeue.
- Every `ResetTimer`/`AdjustTime`/`DeleteEvent` of a live item is O(n) `indexof` plus an O(index) sift loop (S-05).
- Dependence on an externally-owned absolute clock (server NumberValue, client remote cadence) — correctness of "due" depends on the clock being monotonic and on `ProcessEvents` being driven at all (client only runs when a remote arrives).

---

## 3. Findings

Severity scale: critical = wrong behaviour reachable from live call sites; major = wrong behaviour or O(n)-per-frame cost; minor = latent / edge; info = design note or dead code.

### S-01 (critical) ForceEventComplete only fires when the forced item is at the heap top
Cite: `:280-290` set a flag; `:326-337` honour the flag **only on `peek()`**; nothing re-keys the item.
Trace (`synced_sim.luau` S-force): A due 100, B due 200; at t=5 `ForceEventComplete("B")`; a process pass at t=5 fires nothing (heap size stays 2); B fires at t=100 — the moment A pops and B becomes the top. If A were due at 3600, B would wait an hour. `DeleteEvent("A")` at t=6 releases it immediately (S-force b), which proves the only trigger is "reaches the top".
Live impact: every caller treats it as "complete now": `Status:KillMe` (`H/.../Status_[Module].luau:90-99`), `Effects:KillSelf` (`Effects_[Module].luau:300-303`), `EntityAction:Cancel` (`EntityActionClass_[Module].luau:83-96`), `AlertServer:Destroy` (`GroupInviteAlert_[Module].luau:314-324`), `GroupInviteNotificationComponent:220`. With more than one live clock the forced callback runs at an unrelated later time.
Compounding trace (Status re-apply): `Status:KillMe` calls `ForceEventComplete(statusId)` on the clock whose `Func` **is** `self:KillMe()` (`private_Status_[Module].luau:29-35`). If the status is re-applied before that forced record reaches the top, `_setupStatus` sees `HasObject(id) == true` (:25) and calls `ResetTimer(id, LifeTime)` on the **old** record (old `Func`, `ForcedComplete = true`) instead of `AddEvent`; the new status object is never registered (`:37-41` are in the else branch) and the old `KillMe` fires again as soon as the record reaches the top. Needs a live confirmation, but every step is in the code.
Correct semantics (pick one, see Q1): (a) re-key `due = -inf` (or `now`) with an O(log n) decrease-key so it fires on the next pass in due order; (b) fire synchronously inside the call (with re-entrancy guard); (c) keep a small "forced" list drained before the heap in `ProcessEvents`. (a) or (c) preserve "callbacks only run inside update", which is the safer invariant for chained/nested timers.

### S-02 (major) AdjustTime is anchored at the original start, not at `now`
Cite: `:244-251` returns `ratio * newTotal + (NextEventTime - LifeTime)`; `:236-238` names that anchor "original world time".
Worked example (S-adjust): start=0, LifeTime=10, now=5, newTotal=20 → remaining 5, ratio 0.5 → due = 0.5·20 + 0 = **10** → fires 5 s from now. Ratio-preserving semantics (legacy `Tick.luau:92-95` `timer = timer/delay * newTotal` → 10 s from now; P `Group/init.luau:360-377` `arm(h, remaining * ratio)` → 10 s from now) fire at **15**. Same inputs offset to start=100 give 110 vs 115 (S-adjust b). Algebra: SyncedTimer's due = start + ratio·newTotal; ratio-preserving due = now + ratio·newTotal = start + elapsed + ratio·newTotal. The implementation is always `elapsed` seconds early, and fires **immediately** whenever `ratio·newTotal < elapsed` (LifeTime 10, now 8, newTotal 20: due = 0 + 0.2·20 = 4 < 8).
Verdict: bug, not an alternative definition. The doc comment (`:253-256`, "adjusts taking in current time values … scaled to that") states the ratio-preserving intent; the formula just adds the scaled remaining to the wrong anchor. A consistent "anchored" definition would be `start + newTotal` (=20 here), which the code does not produce either.
Interaction with ResetTimer (S-adjust c/d): after `ResetTimer(Id, X)` the anchor `NextEventTime - LifeTime` is the reset instant (or a point in the future when X > LifeTime), and `ratio = X/LifeTime` can exceed 1. LifeTime 10, `ResetTimer(A, 30)` at t=5, then `AdjustTime(A, 20)` → due = 3.0·20 + 25 = **85** (80 s from now; the ratio-preserving answer is 5 + 60 = 65).
Zero LifeTime (S-adjust e): `0/0 = NaN` due; `Priority > currentTime` is false for NaN so the item is treated as due immediately, and a NaN priority inside the heap disables ordering for its subtree (all comparisons false). Same defect P's reviewers flagged for their `adjust` (review-findings "adjust() on a zero-period handle divides by zero").
Live impact: the only caller, `H/.../UpdateAction_ActionServerHitScan_[Module].luau:112-120`, is itself broken (S-15), so the anchored semantics have never been exercised in production — there is no behaviour to preserve.

### S-03 (major) Callback errors are unprotected; a throw aborts the frame and leaves a phantom record
Cite: `:377` `EventItem.Func(table.unpack(EventItem.Data))` has no pcall; `:375` sets `Remove = true` before the call; `:379` `DeleteEvent` is skipped on throw.
Trace (S-error): A (throws) and B both due at t=1. Pass 1 raises out of the Stepped handler; B does not fire until the next pass. After the throw: `HasObject("A") == true`, `A.Remove == true`, `GetRemainingTime("A") == 0`, and `AddEvent(…, "A")` returns **nil** — the Id is blocked. The record is then held only by the weak value slot (:48), so it disappears at some later GC cycle; until then `HasObject` lies. For an Id-keyed user this is a stuck cooldown / stuck status (`Action:HasCoolDown`, `_setupStatus`), cleared at a non-deterministic time.
Also: `DashStacks_[Module].luau:22-25` passes the **result** of `StatChange(...)` (nil, `CharacterSheet_StatAdjustments_[Module].luau:648-674` has no return value on its normal path) as `func`; `Func = func or NOOP` (:68) hides it — the stat change happens at `AddEvent` time, not 4 s later. Legacy `tick:event` validates `iscallable` (`Tick.luau:165-168`); SyncedTimer validates nothing (LifeTime type/sign either).

### S-04 (major) `_areClocksAvailableToProcess` walks the whole table every frame
Cite: `:344` `Lume.count(StoredClockRef)`. `lume.count` (`H/.../Lume_[Module].luau:1093-1107`) takes the `#t` shortcut only when `lume.isarray(t)` (`:616-618`, `t[1] ~= nil`); Id keys are strings/GUIDs, so it is a `pairs` walk. Measured 57–64 µs per frame at n=10,010 with nothing due (S-cost). The check is also redundant: the heap-empty test on the next line (:345) already answers "anything to process", and `_isNextEventValidToProcess` re-checks emptiness (:328). Same point as P's F11 (`P/build/reports/ASSESSMENT.md:59`); the extra fact here is that it is a hash walk, not an array `#`.

### S-05 (major) Every heap mutation except enqueue/dequeue is O(n), twice over
Cites: `MinHeap.luau:82-88` `indexof` linear scan; `:203-228` `remove`; `:144-152` `update = remove + enqueue`; `:35-58` `siftdown(items, priorities, size, limit)` loops `for index = limit, 1, -1`.
- `indexof` is O(n) with no reverse index (item → slot).
- `remove` then calls `siftdown(..., siftedindex)` (`:220-221`), which does not sift down from one slot — the `for` loop sifts **every slot from `siftedindex` down to 1**, one break-out comparison each. Measured (`heap_cmp_count.luau`, n=16,383, sorted heap): remove of the item at slot N/2 = **16,382 comparisons**; remove of slot 2 = 27; dequeue = 26. So `remove` is O(n) + O(index) even after the item is found. `dequeue` passes `limit = 1` (`:125`) so its loop runs once and is correct; `batchenq` passes `floor(size/2)` (`:247`) which is exactly Floyd's heapify (measured 30,802 comparisons ≈ 1.9n, order verified).
- `ProcessObj` (`:379`) calls `DeleteEvent` **after** the item was already dequeued, so `remove → indexof` always misses after a full walk: 10 fires among 10,010 clocks cost 606 µs (≈60 µs per fire) versus 0.5 µs per dequeue (S-cost; `heap_test.luau` T5: 1,000 `remove(last)` = 114 ms vs 1,000 `dequeue` = 0.47 ms at n=20,000; T7 `remove(mid)` = 236 ms).
- Correctness is fine: 2,000 random inserts + 1,500 random removes kept the heap invariant and no stale tail (T3); dequeue order verified (T2); equal priorities fine (T8); `update` of an absent item returns false and does not enqueue (T4b); `peek` on empty returns `nil, nil` (T9); `dequeue` on empty asserts (T9b).
Fix: keep a slot index on the record (or a `item → index` map maintained in the swaps), make `remove` sift **one** slot (`siftdown` from the swapped slot only), and skip `DeleteEvent`'s heap remove for an item that was just dequeued. Or lazy invalidation with a generation counter as in `P/build/src/TickAPI/Heap/init.luau` + `Group:update` (`:165-215`).

### S-06 (major) Re-entrant ResetTimer/AdjustTime from inside the timer's own callback is lost, but reports success
Cite: `ProcessObj` dequeues before running `Func` (:371, :377) but the Id slot is cleared only afterwards (:379). Inside `Func`, `HasObject(Id)` is true (:217, :259), the record's `NextEventTime` is rewritten (:206, :261), `MinHeap:update` fails (`:145` remove misses → false, return value ignored), and `ResetTimer`/`AdjustTime` return **true** (:228, :271). `DeleteEvent` then discards the record.
Trace (S-reentry): a 1 s event that calls `ResetTimer("A")` from its own callback fires once, returns true, and is gone (`HasObject` false, heap empty). `AddEvent(…, "A")` from the callback returns nil (S-reentry b), so a callback cannot re-arm itself under the same Id either. `DeleteEvent` from inside is harmless (S-reentry c).
Consequence: the `Remove ~= false` guard at `:374` is dead — nothing can enqueue a record whose `Remove` is true (update never re-enqueues an item not in the heap; AddEvent dedupes by Id). The "recurring events" the comment (`:70`) anticipates cannot be built on top of the current ordering.

### S-07 (major) No catch-up cap: a zero-LifeTime event that re-adds itself loops forever in one pass
Cite: `:360-362` `while _isNextEventValidToProcess do ProcessObj() end`; `AddEvent` with `LifeTime = 0` gives `due == now`, and `Priority > currentTime` is false, so the new record is due in the same pass.
Trace (S-runaway): a callback that does `AddEvent(0, itself)` hits the 10,000-iteration guard in the harness; the real class has no guard and hangs the Stepped handler. Legacy has the same hazard for `recur` with period 0 (P's F5); P added `maxCatchUpPerFrame`. TickRevamp needs a per-update cap or a "created during this update is not due until the next update" rule (P's deviation 2, `ASSESSMENT.md:113-115`).

### S-08 (minor) `#heap` is always 0
Cite: `MinHeap.luau:252-255` `__len = BinaryMinHeap.len` — `len` is never defined, so `__len` is nil; `#h` returns the raw length of the object table (no array part) = 0 while `size()` = 3 (`heap_test.luau` T1). Nothing in SyncedTimer uses `#heap`, so latent; `size()` (:172-174) is the working accessor.

### S-09 (minor) Id dedupe returns nil silently; callers overwrite their stored Id with nil
Cite: `:171` `if self:HasObject(Id) == true then return nil end`.
`GroupInviteAlert_[Module].luau:150,167` and `private_Status_[Module].luau:29` assign the return value to `self.TimerId`; on a duplicate the caller now holds nil and any later `DeleteEvent(self.TimerId)` / `ForceEventComplete(self.TimerId)` is a silent no-op while the original clock keeps running. Combined with S-03 the duplicate can be a phantom. Policy options for TickRevamp: return the existing handle, replace, or error — all better than nil (Q3).

### S-10 (minor) Per-event allocations and vararg truncation
Cite: `:173` `HttpService:GenerateGUID()` per anonymous event (a 36-char string + service call, on the hot path for hit-scan FX: `Action_ConeHitScan_[Module].luau` has 10 `AddEvent` sites); `:180` `{...}` allocates a table per event even with no payload; `:377` `table.unpack(Data)` uses `#Data`, so a payload with a nil hole (`AddEvent(t, fn, id, nil, "x")`) may drop `"x"`. Use integer ids (P's `_nextId`, `Group/init.luau:270`), `select("#", ...)`/`table.pack`, and skip the payload table when `select("#", ...) == 0`.

### S-11 (minor) Client processing cadence and clock are network-bound; server AddEvent can see a stale `now`
Cite: `:416-422` (client hook), `SyncTime_[Module].luau:11-19` (remote → `Time` → connected fns), `CharacterSheet_History_[Module].luau:229-258` (server sends per Heartbeat per character, :243/:256). Client `ProcessEvents` runs only when a `Client_SyncTime` packet arrives, `dt` is nil, `GetRemainingTime` is stepwise between packets (the `AbilityClass_Utility_[Module].luau:295` cooldown text polls it every 0.01 s via `Tickr.recur` and gets the same value between packets), and `now` can move backward when the latency estimate drops. Server: an `AddEvent` inside a Stepped handler that runs before `WorldTimeMod.ServerUpdate` (`WorldTimeMod_[Module].luau:9-11,22`) uses last frame's `WorldTime.Value` → due is ~1 frame early. Design lesson for Q4: if TickRevamp keeps an absolute-time variant, `now` must be sampled once per update by the driver, not read from a replicated value at call time.

### S-12 (minor) `ResetTimer(Id, X)` changes the due but not `LifeTime`
Cite: `:215-229`, `:202-209`. `due = now + X`; `LifeTime` unchanged. `GetRemainingTime` can exceed `LifeTime`; `StrikesOverTimeClass_[Module].luau:71-73` computes `LifeTime - GetRemainingTime` as "time passed" and goes negative after such a reset; `_EvaluateAndSetNewTime` gets ratios > 1 (S-02 example d). Legacy `event:reset` (`Tick.luau:101-103`) has no argument and restores the full delay; P's `reset` likewise (`Group/init.luau:345-357`). If "reset to an arbitrary remaining" is wanted, it should be a separate `setRemaining(x)` that leaves period alone by contract, and `adjust` should be defined on remaining, never on an anchor.

### S-13 (info) Dead code and misc
`SingltonStore` unreachable (:45, :102; the module returns the instance at :435); unused requires (:23, :32, :33); `TickAPI` required only for the never-called `_debugStorageTracking` (:78-88, :24); `dt` unused (:356); `SyncedTimer.static.GetItemFromStorage` (:403-406) unused; `MinHeap:dump` dead local (`MinHeap.luau:193-198`); `contains`/`getPriorityByItem` O(n) (`:157-167`); `batchenq` does not validate odd-length input and `enqueue(item, nil)` fails inside `siftup` with "attempt to compare nil" (`:22`); assigning to the `for` control variable inside `siftdown` (`:53`) works in Luau (verified) but is a readability hazard.

### S-14 (info) ForceEventComplete vs DeleteEvent ordering and double-invocation at call sites
`ForceEventComplete` then `DeleteEvent` before a pass → never fires (S-force c) — Delete wins, which is the sensible rule. But because Force is deferred (S-01), `Status:KillMe` (`Status_[Module].luau:90-99`) runs `PreKill` now and again when the forced record fires `KillMe` a second time; `AlertServer:Destroy(true)` (`GroupInviteAlert_[Module].luau:319-324`) carries a `warn(" THIS IS WHERE THE DOUBLE REJECTION HAPPENS")` in the very callback it forces (`:167-175`) — an in-repo symptom of the same double run. TickRevamp's `complete()` must be idempotent and must no-op when called from inside the handle's own callback.

### S-15 (info, call-site) The only AdjustTime caller adjusts the wrong timer
`UpdateAction_ActionServerHitScan_[Module].luau:80-125`: `local FXTimerId = nil` is declared once outside `Lume.each`; every iteration and both `AddEvent` calls assign the **same upvalue**, and the adjuster closure (`:113-120`) reads it at fire time — by then it holds the last id assigned across all iterations (the last adjuster's own id), so `AdjustTime` re-keys an unrelated (or already-dequeued, S-06) record and the FX timers are never rescaled. The comment at `:83-85` shows the author believed each closure captured its own value. Outside TickRevamp's write scope (H is read-only) but it means S-02 has no production behaviour to preserve.

### S-16 (minor) Non-number / NaN priorities corrupt ordering silently
`siftup`/`siftdown` compare with `>` only (`MinHeap.luau:22,41,45`); a NaN priority (S-02 zero-LifeTime path) compares false both ways, so it sits wherever it lands and blocks nothing below it from being compared correctly; `Priority > currentTime` in `:334` is also false, so the record is "due" forever until popped. TickRevamp should validate `period` (finite, `>= 0`) at creation and at `adjust`/`setPeriod`.

### S-17 (info) What is verified correct
Heap invariant under enqueue/dequeue/remove (random, 2,000/1,500 ops), dequeue order, Floyd heapify in `batchenq`, `update` = remove+enqueue semantics, empty-heap handling. Due-prefix processing (`:326-337`, `:360-362`) is the right shape: peek, compare top priority, pop while due. The Id-registry idea and `HasObject`/`GetRemainingTime` as Id-addressed queries are sound and used by 4 live modules.

---

## 4. Carry / drop for TickRevamp

| idea | verdict | rationale |
|---|---|---|
| Min-heap keyed by due, process only the due prefix | **carry** | proven shape (S-17); fix the bookkeeping: O(1) size, no `Lume.count`, no post-dequeue `remove` (S-04, S-05) |
| `ForceEventComplete` | **carry, redefine** | as `h:complete()` / `group:complete(id)`: runs the callback exactly once, then terminal; either re-key to `-inf` with decrease-key and let `update` run it in order (preferred: callbacks only run inside update), or run synchronously with a re-entrancy guard; no-op if already terminal or if called from inside its own callback (S-01, S-14). Distinct from `stop()` (never runs). |
| Id-addressed lookup (`HasObject`, `GetRemainingTime(Id)`, `DeleteEvent(Id)`) | **carry as optional registry** | integer handles by default; an optional string key at creation (`{key = "owner..status"}`) with an explicit dedupe policy (return existing / replace / error — never nil) (S-09). Registry is strong, cleared on terminal state; no weak tables (S-03). |
| Absolute-time `updateTo(now)` | **carry as a second driver entry** | keep the rolling clock (`now += dt * timeScale`) as the canonical heap axis (monotonic, driver-agnostic, supports timeScale/pause); expose `updateTo(absoluteNow)` that computes `dt = absoluteNow - lastNow`, clamped at 0, so a synced instance can be driven by `WorldTime`/`SyncTime` without the clock ever running backward (S-11). Sample `now` once per update; never read a replicated value at call time. |
| Payload varargs | **carry with `table.pack`** | `select("#")`-preserving, no allocation when arity is 0 (S-10). Closures remain the idiomatic path. |
| `GetRemainingTime` / `HasObject` | **carry** | as `h:getRemaining()` (already in P) plus `group:has(key)` / `group:get(key)`; unknown key → nil, not 0 (S-09 note on `:133`). |
| `ResetTimer(Id, X)` | **split** | `reset()` restores the full period (legacy/P semantics); a separate `setRemaining(x)` for "give it X more seconds" (S-12). |
| `AdjustTime` anchored formula | **drop** | keep legacy/P ratio-of-remaining semantics; define for Paused/Chained too (P `Group:_adjust` already does); reject zero period (S-02, S-16) |
| `Lume.count` guard, weak-value storage, GUID ids, `{...}` payload | **drop** | S-04, S-03, S-10 |
| Stateful client/server split, singleton return, `RunService` connection inside the class | **drop** | TickRevamp's instance model puts the RunService binding in a driver/registry layer (`TickAPI.Tick = NewTick.new()`, `TickAPI.Tick:update(dt)`); a synced instance is just one more instance driven by `updateTo`. |
| Unprotected callbacks | **drop** | pcall/xpcall with an error policy (P has `onError`), record kept consistent before the call (S-03) |
| `MinHeap` module as-is | **drop, rewrite** | keep the parallel-array layout; add slot index or generation-based lazy deletion; single-slot siftdown; `__len`; validated priorities (S-05, S-08, S-16) |

---

## 5. Questions for Jake
1. `complete(h)` (ForceEventComplete successor): run the callback synchronously inside the call, or defer to the next `update` in due order? And confirm it should be a no-op from inside the same timer's callback and after `stop()`.
2. Confirm `adjust` keeps legacy ratio-of-remaining semantics (fires at t=15 in the worked example) — i.e. SyncedTimer's anchored result (t=10) is a bug and not a behaviour to preserve. (Its only caller never exercises it, S-15.)
3. Duplicate key policy at creation: return the existing handle, replace it (stop old, arm new), or error?
4. Does TickRevamp replace `SyncedTimerClass` (so a synced instance driven by `WorldTime`/`SyncTime` is in scope), or only borrow its ideas while `SyncedTimerClass` stays live? This decides whether `updateTo(absoluteNow)` is a must-have.
5. Zero / negative period policy: error at creation (P), clamp, or accept with a per-update catch-up cap (S-07)?

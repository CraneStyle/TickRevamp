# Prior build (TickAPIOptimize, 2026-09-16) — independent adversarial review

Scope: `P/build/src/TickAPI/{init,Heap,Handle,Group,Driver,Variants,AfterNotTouched}` + `P/build/docs/api/API.md`.
P = `C:/Users/Faded/Documents/ClaudeProjects/RbxProjects/STUDIO_TASKS/TickAPIOptimize`. All cites are `Module:line` under `P/build/src/TickAPI/<Module>/init.luau` unless a path is given.

Baseline: `cd P && lune run build/tests/run.luau` -> **80 passed, 0 failed** (confirmed 2026-09-16).

Repro scripts: `W/research/scratch/prior/NN_*.luau` (W = `…/STUDIO_TASKS/TickRevamp`). Run each with `lune run NN_name.luau` from that directory.
**Require form Lune 0.10.5 accepted:** only the relative string `../../../../TickAPIOptimize/build/src/TickAPI` (and `…/TickAPI/Group`, `…/reference/lune/Tick`). The absolute-path form is rejected: `require path must start with a valid prefix: ./, ../, or @` (`00_require_probe.luau`). Lune supports `collectgarbage("count")` but NOT `collectgarbage("collect")`; `Random.new` does not exist (use `math.random`).

---

## 1. Open findings from `review-findings.jsonl` — reproduction status

The 39 rows dedupe to 9 distinct items. All 9 verified; 8 still open, 1 fixed.

| # | RF ids | Status | Repro | Evidence |
|---|---|---|---|---|
| 1 | RF-001/003/012/021/029/033 | **open, confirmed** | `01_open_findings.luau` §(1) | `delay(fn,0):adjust(5)` -> `h._due = NaN`, `getRemaining = NaN`, fires on the next `update(0.001)`. Also `delay(fn, math.huge):adjust(5)` -> NaN. Cause: `Group:362` `ratio = newTotal / h.period` with `period == 0` (inf) times `remaining == 0` (`Group:364`) = NaN, pushed by `arm` (`Group:72,79`). `math.max(NaN,0)` is NaN in Luau. |
| 2 | RF-002/018/026/036 | **open, confirmed** | `01` §(2) | Inside a callback, stopping 70 of 100 far handles drove heap 100->35 and stale 0->5 *during* `update` — `compact()` (`Group:56-63`) ran via `_stop` (`Group:300`). The header comment `Group:54-55` ("Called ONLY from operations; never from inside update") is false. It happens to be safe (see §3.7) but the invariant must be restated. |
| 3 | RF-004/009/015/023/030/035 | **open, confirmed** | `01` §(3) | With an injected fake RunService, 5× `TickAPI.new({driver="Heartbeat"})` -> 5 connections; dropping every reference leaves 5. `group._unbind` (`init.luau:54`) is a dead store; `group.Destroy`/`unbind` are nil. `API.md:62-64,182-183` even documents the private field. |
| 4 | RF-005/019/027/037 | **open, static** | grep | `Handle:58-64` and `Variants:60-66` are the same function. |
| 5 | RF-006/014/022/028/034 | **open, confirmed** | `01` §(5) | `h:pause()` twice -> `…\Handle:75: illegal transition Paused->Paused`; on a Chained child -> `…Chained->Paused`, raw with file:line. `Group:307` calls `Handle.transition` unguarded; `_resume` (`Group:330-332`) has the guard, `_pause` does not. |
| 6 | RF-007/017/024 | **open, confirmed** | `grep -in deviation MIGRATION.md` | `P/build/docs/migration/MIGRATION.md` has no deviation section (headers: Why / Copy inventory / Per-copy replacement / Call shape compatibility / Handle method mapping / Order of operations). The 5 deviations live only in `ASSESSMENT.md:107-119`. Note this review adds **three more undocumented deviations** (B-03, B-13, B-20). |
| 7 | RF-008/016/025/032/038 | **open, confirmed** | `01` §(7) | `TickAPI.new({name="Silent"})` under an injected Roblox: driver `Manual` (`Variants:100-101`), 0 connections, never fires after 100 Heartbeats. No warning. |
| 8 | RF-010/013/020/031/039 | **open, confirmed — and worse than filed** | `01` §(8), `07` §3 | See B-06. `maxCatchUpPerFrame = 1` routes EVERY fire through the capped path (`Group:131` `n >= cap` is true on the first fire), so any recur that stops itself inside its callback is resurrected as a phantom entry; `stale` = -1 after two updates, **-985** after a 3000-op random workload. Two further consequences: pause-inside-callback records `remaining = 0` and re-fires immediately on resume; reset-inside-callback is overridden (2 heap entries). |
| 9 | RF-011 | **fixed, confirmed** | `01` §(5) tail | `resume()` on a Pending handle: live/paused/heap unchanged. `resume_spec.luau` pins it. |

---

## 2. New defects (B-nn)

Severity key: **critical** = hangs the frame / corrupts scheduling silently; **major** = wrong behaviour reachable from ordinary game code or a migration-breaking deviation; **minor** = contained defect / leak / API wart; **info** = design observation.

### B-01 (critical) `arm()` applies a now-relative remaining to a due-relative base -> same-update re-pop -> infinite loop
- Where: `Group:72` `local due = (group._base or group._now) + delay`, used unchanged by `_adjust` (`Group:364-366`, `remaining = max(h._due - self._now, 0)` then `arm(self, h, remaining*ratio)`), `_resume` (`Group:336`, `arm(self, h, h._remaining)` where `_remaining` was taken vs `_now` at `Group:308`), `_reset` (`Group:348`).
- Repro: `03_callback_ops.luau` §4-6 (guarded at 50 to terminate; unguarded it never returns):
  - recur period 1, `update(2.5)`, callback does `h:adjust(1)` (same period!) -> **50 fires in one update** (correct: 2). Trace: dispatch re-arms `h._due = due+1`, `_base = due`; adjust computes `remaining = max(due+1-2.5, 0) = 0`, arms at `_base + 0 = due <= now` -> popped again -> repeat.
  - recur period 1, `update(1.9)`, callback does `h:adjust(0.05)` (NOT lagging by a full period) -> 50 fires.
  - callback does `h:pause(); h:resume()` while lagging -> 50 fires.
- Consequence: any recurring callback that adjusts/pause-resumes its own handle when the group is behind by ≥ one period (a long frame, a Studio breakpoint, a server hitch) hangs the RunService handler forever. `h:adjust` has 9 live call sites; the cap does not help (see B-06, the capped branch has the same loop).
- Fix: give `arm` an explicit base. Re-arms whose delay is a *remaining* (`_adjust`, `_resume`, `_reset`) must add to `_now`; only the recur re-arm (`Group:136,140`), chained-child arming (`Group:155`) and *new* nested `delay/recur` inherit `_base`. Additionally guarantee progress: a re-armed entry with `due <= now` created during a pass must not be popped in the same pass (see B-02 valve).

### B-02 (critical) Unbounded same-pass dispatch: zero-delay reschedule from a callback is a busy loop
- Where: `Group:178-193` pops while `top <= now` with no bound on entries pushed during the pass; `Group:72` makes a nested `delay(fn, 0)` due exactly `_base <= now`.
- Repro: `10_order_and_zero_delay.luau` §2: `local function tick() n+=1; if n<1000 then g.delay(tick,0) end end` -> **1000 fires in a single `update(1/60)`**; without the guard the update never returns. The "schedule for next frame" idiom (`delay(fn, 0)`) inside any callback is therefore a hang.
- rxi/legacy behaviour for comparison (`reference/rxi-tick/tick.lua:133-140`): a nested past-due event fires synchronously (recursion -> stack overflow instead of a loop); at top level `delay(fn,0)` fires next update on both.
- Fix: (a) a per-pass runaway valve: count dispatches; when it exceeds `k * heapSizeAtStart + C` warn/`onError` and break (leave the rest for the next pass); (b) decide zero-delay semantics (Q3): "fires next pass" is what game code expects from `delay(fn, 0)` and is trivial to guarantee by deferring entries pushed during the pass whose due ≤ pass-now (e.g. record `seqAtStart` and stop when a popped entry's seq ≥ seqAtStart and its handle is not a recur re-arm).

### B-03 (major) Undocumented deviation: timers created inside a **recurring** callback fire one full period earlier than legacy
- Where: `Group:124` sets `_base = due` for recur and one-shot alike. Legacy/rxi set `err = e.timer` AFTER `e.timer + e.delay` for a recur (`reference/live/Tick.luau:146-151`, `rxi-tick/tick.lua:99-104`), so `err = period - overshoot` and a nested `delay(d)` gets `timer = d + period - overshoot` — measured from the recur's **next** due.
- Repro: `04_base_carry.luau`, `16_error_chain_deviation.luau` §2: recur(1) whose callback arms `delay(0.5)` at 60 Hz — legacy fires the nested delay at **t = 2.500**, new at **1.517**. Same for a recur created inside a recur (2.500 vs 1.517). Catch-up case: 3rd fire at due 3 inside `update(3.5)`: legacy nested due 4.25, new 3.25. One-shot-in-one-shot and `after()` are at parity (1.500 vs 1.517 — see B-20).
- Also `reset()` from inside a callback: legacy is now-relative (`timer = delay`, `Tick.luau:101-103`), new is firing-due-relative (`Group:348`): 11.4 vs 11.0 in `03` §8 / `04` §5.
- Blast radius (upper bound): 26 of the 93 live files that call `.recur(` also call `.delay(`/`GetAfterNotTouched(` (H mirror grep). The parity harness (`P/build/tests/spec/parity/parity_spec.luau:1-24`) deliberately avoids nested creation, so it cannot see this. Not among the 5 deviations in `ASSESSMENT.md:107-119`.
- Fix: decision (Q1). If legacy compat is wanted, `_base` for a recur dispatch should be `due + period`; if the new behaviour is kept (it is the arguably-correct one), document it as deviation 6 and extend the parity generator with nested creation to enumerate affected live sites.

### B-04 (major) `update()` is not re-entrant; a nested `update` from a callback corrupts the outer pass
- Where: `Group:165-215` — `_now`, `_errored`, `_base`, `_examined/_dispatched` are all instance fields written by every call; no `_updating` guard.
- Repro: `02_reentrant_update.luau`:
  1. onError = "error": A errors, B's callback calls `g.update(0)` -> inner pass sets `self._errored = nil` (`Group:172`) -> **outer raise lost** (`raised = false`).
  2. parent one-shot whose callback calls `g.update(5)` with an `after(…, 1)` child -> inner pass ends with `_base = nil` (`Group:203`) -> child armed at `_now + 1 = 7` instead of `2`; outer's `now` local is stale; stats show the inner pass.
  3. recur whose callback calls `g.update(1)` re-dispatches the *same* handle recursively (depth 6 with a guard; unguarded = stack overflow).
- Fix: `if self._updating then error/warn+return end` (or queue the dt and apply after the pass); save/restore `_base` and `_errored` around nested passes if nesting is to be allowed (not recommended).

### B-05 (major) No input hardening: NaN/inf/negative dt and timeScale, NaN period
- Where: `Group:167` (`_now += dt * _timeScale`, no check), `Group:246-252` (`s < 0` only), `Variants:109-116` (`timeScale < 0` only), `Handle:84-93` (`period < 0` only; NaN passes since `NaN < 0` is false).
- Repro: `09_input_hardening.luau`, `05_timescale.luau` §3, `11` §3:
  - `update(0/0)` -> `now = NaN`; a subsequent `delay(fn, 3600)` fires on the next frame; the group is poisoned permanently (`top > NaN` is always false).
  - `update(math.huge)` -> `now = inf`; uncapped recur = never-terminating loop (not run); capped recur fires every frame forever (6 fires after 5 tiny updates); every later delay fires immediately.
  - `update(-1)` -> `now = -1`, silently accepted.
  - `setTimeScale(math.huge)` / `setTimeScale(0/0)` accepted -> same poison. `Variants.resolve({timeScale = 0/0})` -> NaN accepted; `math.huge` accepted.
  - `delay(fn, 0/0)` **accepted** and pushed: `less()` (`Heap:30-36`) is not a strict weak order with NaN; a due-0.05 handle inserted under the NaN node did **not** fire at `update(0.06)` and only fired after 0.11. Heap pop order with a NaN key: `a,d,c,nan` for dues 0.1,NaN,0.2,0.05. `recur(fn, NaN)` is rejected only by accident of `not (NaN > 0)`.
  - `update(nil)` -> raw `Group:167: attempt to perform arithmetic (mul) on nil and number`.
- Fix: in `update`: `if dt ~= dt or dt < 0 or dt == math.huge then warn; dt = 0 end` (or error). In `setTimeScale`/`Variants`: require finite. In `Handle.new`: reject `period ~= period` and `period == math.huge` (or accept inf but forbid adjust on it).

### B-06 (major, elevates open #8) Capped re-arm resurrects/overrides state changed by the callback
- Where: `Group:127-137` (cap check `n >= cap` fires on the FIRST fire when cap = 1) and `Group:197-200` (post-loop re-arm with no state check).
- Repro: `01` §(8), `07` §3. Consequences, each confirmed: (a) self-stop -> phantom Pending-looking entry for a Stopped handle, `stale` -1 per occurrence, **-985** after 3000 random ops -> `compact()` threshold (`Group:57`) unreachable and the `_live == 0` sweep disabled; (b) self-pause -> `_remaining = max(oldDue - now, 0) = 0` (`Group:308`, because the capped path did not advance `h._due`) -> `resume()` fires immediately (fires = 2 with 1 expected); (c) self-reset -> the post-loop arm pushes a second entry and wins.
- Fix: in the post-loop loop skip handles that are not `Pending` or that already have `_inHeap` (i.e. were re-armed by their own callback); better: drop deferral entirely — re-arm inside `dispatch` as in the uncapped path and enforce the cap in the pop loop by *not popping* an entry whose handle already reached `fireCounts[h] >= cap` (peek, compare, break/skip via a small deferred list re-pushed after the loop).

### B-07 (minor) `after()` on a terminal handle returns the parent itself
- Where: `Handle:162-165` returns `self`; the "same value as success" rule (`Handle:112-114`) is wrong for `after`, whose success value is a NEW handle.
- Repro: `06_chains.luau` §4: `p:after(fn,1)` from inside p's own callback (p is already Fired, `Group:130`) returns `p`, `#p._chained == 0`, `fn` never runs; on a Stopped parent likewise.
- Fix: return a child pre-set to `Stopped` (so `:stop()`/`getState()` on it behave), or error `"cannot chain a finished event"`.

### B-08 (minor) `group.clear()` strands `AfterNotTouched` objects in `Storage` forever
- Where: `AfterNotTouched:20` strong table, removed only by `Destroy` (`:85`); `Group:clear` stops the clock without notifying the owner.
- Repro: `13_afternottouched.luau` §2: after `clear()` + `update(5)`: `count` delta 1, `isDestroying = false`, clock `Stopped`; `Touch()` is a silent no-op forever.
- Fix: a handle-level `onStopped`/finalizer hook the ANT subscribes to, or `Touch()` checking `Clock:isActive()` and self-destroying, or a weak-valued Storage plus the handle holding the strong ref.

### B-09 (minor) Lazy deletion pins stopped handles (and everything their closures capture) until due or compaction
- Where: `Group:57` threshold is strict `>`; `Heap._item` (`Heap:19`) holds the handle, which holds `fn`.
- Repro: `15_misc.luau` §2: 10 000 `delay(fn, 3600)`; stop 5 000 -> `heap = 10000, stale = 5000` (no rebuild at equality); one more stop -> rebuild to 4 999. Worst case: up to `max(64, live)` dead closures retained for their full original delay (an hour here).
- Fix: `>=`, or a periodic/idle sweep, or true O(log n) removal with an index-tracked heap (SyncedTimer/MinHeap style) — which also makes `getStats().stale` unnecessary.

### B-10 (minor) Per-frame and per-object allocation
- Where: `Group:173-174` allocates `fireCounts = {}` and `capped = {}` on **every** update, even when `_maxCatchUp == nil`; `Handle:104` allocates `_chained = {}` for every handle; `Group:470-479` creates 10 closures per group.
- Measured (`08_alloc.luau`, Lune, GC not forced): idle update ≈ **96 B/update/group** (median 90; two empty tables) — 3 groups × 60 Hz ≈ 17 KB/s of pure garbage; with one dispatch still ≈ 96 B (dispatch itself is allocation-free); ≈ **756 B/handle**; ≈ 2.7 KB/group.
- Fix: allocate the catch-up tables lazily (only when `_maxCatchUp ~= nil` and a recur is dispatched), or keep them as reusable instance tables cleared at pass end; lazy `_chained`; consider `Handle` as an array-shaped or smaller-hash record.

### B-11 (minor) `Driver.bind` on a signal the RunService lacks raises a raw error
- Where: `Driver:102` `runService[signalName]:Connect(handler)`.
- Repro: `12_driver.luau` §5: fake without `PreRender` -> `…Driver:102: attempt to index nil with 'Connect'` instead of the `TickAPI driver:` prefix.
- Fix: check the member and `fail(driver .. " is not available on this RunService")`.

### B-12 (minor) `Driver._inject` is module-global, so a forgotten `_inject(nil)` bleeds into later binds
- Where: `Driver:40,62-64`. Repro: `12` §4 (a later `TickAPI.new` connects to the stale fake). Also `init.luau:109-112` builds the builtins with whatever fake is installed at module load.
- Fix: keep the seam but make `bind` take an optional runService argument (dependency injection at the call) and have tests use it; or have `_inject` return a restore function.

### B-13 (minor) Undocumented deviation: a parent whose callback errors still arms its `after()` children
- Where: `Group:147-157` (children armed after `runCallback` regardless of outcome). Legacy: the wrapper `oldfn(); … parent:add(e)` (`Tick.luau:68-72`) never reaches `add` when `oldfn` throws.
- Repro: `16_error_chain_deviation.luau` §1: legacy `child fired later = false`; new `true`.
- Fix: document as deviation (it is an improvement) — or make it a policy.

### B-14 (minor) `getRemaining()` on a Chained child returns its period, not time-until-fire
- Where: `Group:402-403`; `API.md:115` says "seconds until the next fire". Repro: `06` §5 (parent due 5, child +1 -> reports 1, truth 6). Fix: return `parentRemaining + period` (walk one level; chains of chains recurse) or document.

### B-15 (info/decision) `getRemaining()` under `timeScale` reports group-time, not wall-time
- Where: `Group:243-245` comment states the choice; `API.md:115` does not. Repro: `05` §1 (scale 2, delay 10, one wall-second -> remaining 8). Q2.

### B-16 (info) `delay(fn, 0)` fires on the next update even when `timeScale == 0`
- Where: `Group:72` (due = now) + `Group:180` (`top > now` false). Repro: `05` §2. Probably acceptable; document.

### B-17 (minor) `_inHeap` is written by Group (`Group:78,125,287,311`) but absent from `HandleImpl` (`Handle:42-53`)
- A strict-mode type hole; `Handle` also gains `_due` only lazily (10 fields on a live handle, `15` §3). Fix: declare it (and `_due`) in the type; initialise in `Handle.new`.

### B-18 (minor) Handle methods are colon-only; dot-call misuse gives an internal error
- Repro: `15` §1: `h.stop()` -> `…Handle:67: attempt to index nil with '_state'`. Group methods are dual (`Group:434-441`); handles are not. Jake's item 6 asks for colon-vs-dot protection — `Handle.is(self)` at the top of each method with a named error is the cheap version.

### B-19 (minor) `AfterNotTouched` re-raise drops the original traceback
- Where: `AfterNotTouched:51-55` `pcall(fn)` then `error(err, 0)`; the group's `xpcall(…, debug.traceback)` (`Group:92`) captures the re-raise site (`AfterNotTouched:54`), not the user's stack. Repro: `13` §1 (message keeps the original `file:line:` prefix, stack starts at `AfterNotTouched:54`). Fix: `xpcall(fn, debug.traceback)` inside ANT and re-raise the traced string, or let the policy see the original error by not catching (Destroy in a `finally`-style xpcall wrapper).

### B-20 (info) Exact-boundary fires can land one frame later than legacy
- `_now` accumulates upward (`Group:167`), legacy timers accumulate downward; at a boundary that is not exactly representable the two disagree by one frame: `after(0.5)` on a 1 s parent at 60 Hz fired at 1.517 (new) vs 1.500 (legacy); `recur(0.1)` over 10 min at 60 Hz fired 5999/6000 (`04` §4, `11` §1). `_now` itself drifts only −3.1e-8 s per hour at 240 Hz; `recur(1/60)` driven by `dt = 1/60` fired exactly 216 000/216 000 (same float ops on both axes). The parity spec avoids this with dyadic numbers (`parity_spec.luau:19-24`). Acceptable; document.

### B-21 (info) Default `maxCatchUpPerFrame = nil` (unbounded)
- `recur(fn, 0.01)` + `update(1000)` = 100 000 dispatches in one pass (18.7 ms here, `09` §7); `update(math.huge)` never terminates. Recommend a finite default (e.g. 8–16) for the built-ins plus the B-02 valve. `API.md:155,202-203` presents nil as the safe default.

### B-22 (minor) Cosmetics in `Variants`
- `nameCounter` is consumed by the builtins and by *failed* resolves (`Variants:74-76` increments before validation): the first user group in this process was `TickGroup6`, a failed resolve skipped `TickGroup8` (`14` §3). Also `Group:update("0.5")` and `delay(fn, "5")` are accepted through coercion (`15` §1) — legacy-compatible but worth an explicit `tonumber` + type error.

---

## 3. Verified-OK behaviours (no defect found)

1. `clear()` from inside a callback mid-update: later same-frame handles (one-shot, recur, chained child) do not fire; stats end at `live=0 stale=0 heap=0` (`03` §1).
2. `stop()` of a handle due later in the same update: stale path, no fire, `stale` returns to 0 (`03` §2).
3. `reset()` of a recur from inside its own callback: one orphan per fire, popped and decremented next pass; `_due` advances correctly (`03` §3).
4. Chains: grandchild `after()` arms when the child fires; multiple `after()` fire in insertion order; `adjust()` on a Chained child is honoured at arming; parent paused→stopped stops children; parent paused→resumed→fired arms them (`06` §1-3).
5. `Heap.rebuild` from a callback mid-pass: current recur (already re-armed) kept, later same-due one-shot still dispatched, `live + stale == heapSize` after (`07` §1). Randomised 20 000-op push/pop/rebuild vs a stable-sorted oracle: **0 mismatches** (`11` §2). Uncapped 3000-op random workload: `stale` never negative (`07` §2).
6. Equal-due order is creation order (`10` §1). On-time `adjust(same)` in own callback does not loop (`10` §4).
7. `_base` carry for one-shots and chained children matches legacy (`04` §3-4, `16` §3).
8. Driver: Stepped forwards the 2nd argument (`12` §1); RenderStepped on server -> `TickAPI driver: RenderStepped is client only` from `TickAPI.new`; client ok; `Tickr` nil under Lune/server and `GetAfterNotTouched(…,"Tickr")` -> `TickAPI: unknown tick type Tickr`; `_unbind` idempotent (`12`).
9. Variants frozen (`table.isfrozen`), onError function receives `(message, handle)` with handle identity, a throwing handler is shielded and warned, callable-table callbacks run through `xpcall` (`14`).
10. AfterNotTouched: `fn` error still destroys and unregisters; `SafeStopClock`/`GetAfterNotTouched` keep live shapes; ids are integers (`13`).
11. `setPeriod` takes effect at the next re-arm only, as documented (`15` §5). `remove(nil)`/`remove(42)` are silent no-ops.

---

## 4. Carry forward into TickRevamp (good, reuse)

- **Heap** (`Heap:12-178`): four parallel arrays, no per-entry table, seq tie-break for FIFO among equal dues, O(n) bottom-up `rebuild` that preserves seq. Proven by the 20k-op oracle test. Reuse as-is; add an index map if eager removal is chosen (B-09), and guard NaN at the boundary (B-05), not in the heap.
- **Callback isolation** (`Group:77-110`): `xpcall(fn, debug.traceback)`; policy `"warn" | "error" | function(message, handle)`; "error" defers the first message and re-raises with `error(msg, 0)` after the pass (`Group:209-213`); user handler failures are shielded. Keep; add the re-entrancy save/restore (B-04).
- **Explicit state enum + transition table** (`Handle:20-40,70-77`) with `handle_spec "transition table is exhaustive"`. Keep; add a public guard so illegal transitions become named no-ops/errors (open #5).
- **Terminal no-op discipline** on handle methods (`Handle:112-193`) — keep, fix `after()` (B-07).
- **Live validation messages** (`Handle:80-93`) kept byte-for-byte from `Tick.luau:165-176` — keep for migration.
- **Variants.resolve** (`Variants:73-154`): frozen record, private marker (`rawget`), unknown-key-first validation, named `TickAPI variant:` errors. Keep; add finiteness checks (B-05) and a non-Manual default or a warning (open #7).
- **Driver** (`Driver:73-111`): single RunService touchpoint, correct Stepped `(time, dt)` handling, client-only rejection with `TickAPI driver:` prefix, idempotent unbind, injectable fake. Keep; wire the unbind into a `Group:Destroy()` (open #3), guard missing signals (B-11).
- **AfterNotTouched with an injected scheduler** (`AfterNotTouched:38-61`) — testable without Roblox. Keep; fix clear() stranding (B-08) and traceback (B-19).
- **`_base` carry for one-shots / chained children** (`Group:124,148-157`) — matches legacy sub-frame error; keep the *mechanism*, fix the *scope* (B-01) and decide the recur base (B-03).
- **Stale-generation lazy deletion + counted compaction** (`Group:48-63,69-80`) — sound idea; keep only if B-06/B-09 are fixed, otherwise prefer eager index-tracked removal.
- **Dual colon/dot group methods** (`Group:434-441`) — needed for the live `TickAPI.Tick.delay(...)` shapes (117 `Tickh` sites). Keep; extend the idea to handles (B-18).
- **Tests worth porting** (`P/build/tests/spec/…`): `heap/heap_spec` (10 000 random dues, equal-due FIFO, rebuild keeps order); `group/group_core_spec` ("update examines only due entries", "dispatch order and error carry", "stale entries skip and recurring re-arms from due"); `groupops/group_ops_spec` (pause/resume remaining, reset/adjust re-key, chained children arm from parent due + early stop, compaction and clear); `grouppolicy/group_policy_spec` (warn/error/function, time scale, catch-up cap); `handle/handle_spec` (exhaustive transitions, live messages, terminal inert); `resume/resume_spec`; `driver/driver_spec` (fake RunService, Stepped 2nd arg, client-only); `parity/parity_spec` (differential harness with adapters + seeded generator against `P/reference/lune/Tick.luau`) — **extend the generator with nested creation inside recur callbacks** so B-03 becomes a pinned decision; `bench/bench_spec` (examined-count proof). The TAP runner `P/build/tests/run.luau` is small and adequate.
- **Docs pattern**: `apidocs_spec` and `migration_spec` assert every public member/call shape is documented — keep the idea.
- **The parity oracle** `P/reference/lune/Tick.luau` (live core minus the `RunService` line) — reuse verbatim.

---

## 5. Recommendations (ordered)

1. Make `arm` take an explicit base; only recur re-arm, chained-child arm and nested creation use the firing due (B-01). Decide the recur base per B-03/Q1.
2. Add a per-pass runaway valve and decide zero-delay-in-callback semantics (B-02, Q3); add an `_updating` guard (B-04, Q4).
3. Harden inputs: finite `dt`/`timeScale`, reject NaN/inf periods (B-05). Cheap, closes a whole class.
4. Rework the catch-up cap so the re-arm never bypasses handle state (B-06); set a finite default cap for built-ins (B-21).
5. Give `Group` a `Destroy()` that stops everything and unbinds (open #3), and warn or change the `Manual` default (open #7).
6. Guard `_pause` like `_resume` (open #5); fix `adjust` on zero/inf period (open #1).
7. Lazy-allocate catch-up tables and `_chained` (B-10); consider eager removal to stop pinning closures (B-09).
8. Document deviations in MIGRATION.md including the three new ones (B-03, B-13, B-20) and the getRemaining time-base (B-15).
9. Port the tests listed above; add regression specs for every B-nn with a repro here.

## 6. Questions for Jake

1. B-03: legacy fires anything created inside a *recurring* callback one full period late (rxi quirk). Reproduce that for bug-compat, or keep the corrected timing and audit the ≤26 live files?
2. B-15: should `getRemaining()` report group-time (current) or wall-time under `timeScale`?
3. B-02: should `delay(fn, 0)` from inside a callback fire in the same pass (rxi-like) or the next pass (a "next frame" yield)? And on runaway: warn+defer, or error?
4. B-04: nested `update()` — error, ignore with warn, or queue the dt?
5. B-09: eager O(log n) removal (index-tracked heap, no stale accounting) vs lazy deletion with compaction?
6. B-21: default `maxCatchUpPerFrame` for the built-in groups?
7. Open #7: should a driver-less `TickAPI.new({})` be an error, a warning, or default to Heartbeat?

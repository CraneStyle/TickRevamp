# Legacy core bug hunt - Tick.luau / TickAPI.luau / AfterNotTouchedClass.luau

Adversarial review of the live timer core against upstream rxi/tick v0.1.1, with every claim
reproduced under Lune 0.10.5 on the parity shim `P/reference/lune/Tick.luau` (byte-identical to
`W/reference/live/Tick.luau` minus the `game:GetService` line). Experiments live in
`W/research/scratch/legacy/exp*.luau` (run: `cd W/research/scratch/legacy && lune run expN_*.luau`).
P's rebuild was executed from the same directory (`exp9_P.luau`, relative require
`../../../../TickAPIOptimize/build/src/TickAPI`, driver "Manual") to settle which findings it fixes.

Cites: `T:` = `W/reference/live/Tick.luau`, `rxi:` = `W/reference/rxi-tick/tick.lua`,
`API:` = `W/reference/live/TickAPI.luau`, `ANT:` = `W/reference/live/AfterNotTouchedClass.luau`,
`P/<Mod>:` = `P/build/src/TickAPI/<Mod>/init.luau`, `H` = live mirror.

## 0. Data-structure facts every trace below relies on

- A group is ONE table used three ways: array part `self[1..n]` = event objects; hash part
  `self[event] = true|false|nil` = membership flag; field `self.err` = sub-frame carry (`T:106,111,127`).
- `update` (`T:140-159`) iterates `for i = #self, 1, -1`; the bound is evaluated ONCE, so events
  appended by callbacks are not visited this frame (by design). One-shots are removed BEFORE their
  callback runs (`T:149`), recurring are re-armed BEFORE their callback runs (`T:147`).
- `remove(i)` (`T:118-125`) is swap-with-last + pop; `remove(e)` (`T:127-132`) writes
  `self[e] = false` FIRST and then does an O(n) `ipairs` scan.
- `self.err` is set at `T:151` to `e.timer` AFTER the re-arm/removal at `T:147/149`, and reset to
  0 only at `T:158` (skipped if a callback throws).
- The legacy core differs from rxi in exactly: `if self[i] == nil then continue end` (`T:142`),
  `:adjust` (`T:92`), `:reset` (`T:101`), `getClocks` (`T:212`), a `tonumber` error message (`T:172`).
  Tick2/Tick3 are md5-identical to each other and differ from Tick only in a comment block
  (`T:85-90`) and the error string at `T:172` (diffed; F9 confirmed).

## 1. Prior findings F1-F11: verified, with P fix status

| ID | Verdict | Trace | P status |
|---|---|---|---|
| F1 O(n) update | VERIFIED | `T:141` walks every index each update; every survivor in exp1 shows a dt subtraction regardless of due-ness. | FIXED `P/Group:178-193` pops only while `top <= now`. |
| F2 O(n) remove | VERIFIED | `T:128` `ipairs` scan on every `stop()`. | FIXED `P/Group:281-302` gen-bump O(1) + lazy stale, compact `P/Group:56-63`. |
| F3 false-key leak | VERIFIED + QUANTIFIED | `T:127` runs before the scan; a stop on an already-removed event leaves `self[e]=false` forever. exp3: 20,000 stop-after-fire -> 20,000 false keys; 20,000/20,000 callback payloads still reachable vs 196/20,000 in the control (weak-table proof) -> about 1 KB/leak with a 32-slot captured table (+20 MB per 20k), unbounded. Triggers: SafeStopClock after fire (3a), self-stop inside own callback (3b: 1000/1000), double stop (3c), catch-up self-stop (3d), EVERY natural AfterNotTouched fire (10a: 100/100). | FIXED `P/Handle:116-122` terminal no-op (9f: stale=0, heap=0). |
| F4 unprotected fn | VERIFIED, WORSE | `T:152`; on throw `T:158` never runs -> see L-03 (err poisoning) and exp2d (lower-index events lose that frame's dt). | FIXED `P/Group:91-110` xpcall; `_base` cleared `P/Group:203`. |
| F5 recur period 0 | VERIFIED | `T:145-147`: `recur(fn,0)` -> 1000 fires before an injected bail (8b). Also reachable via `adjust(0)` on a recurring (5b) and via the immediate-path dummy created with recur+tiny delay (2g). | FIXED at creation `P/Handle:91-93`, adjust/setPeriod `P/Handle:144,155`; NOT bounded for tiny periods: `recur(1e-4)` = 10,000 fires per `update(1)` with default `maxCatchUpPerFrame=nil` (9d). |
| F6 adjust NaN | VERIFIED | `T:93`: `delay(fn,0):adjust(5)` -> timer NaN -> visited every frame, never fires, never removed (5a). | ABSENT in P (`P/Group:362` `newTotal/0 = inf`, `0*inf = NaN` due -> 9i: fires after ONE frame instead of 5 s). Confirms RF-001/003/012/021/029/033. |
| F7 getClocks | VERIFIED | `T:212-214` + `T:224-230`: `bound:getClocks()` -> 0 with 1 live event; `bound.getClocks()` -> "attempt to get length of a nil value" (exp7). | FIXED `P/Group:235-237` + bindDual `P/Group:473`. |
| F8 chained revive | VERIFIED | `T:127` sets `g[C]=false`, no array entry; parent wrapper `T:71` `add()` sets `true` -> child runs (4f/3e). | FIXED `P/Group:150-157` skips non-Chained, `P/Group:295-299` cascades stop. |
| F9 three copies | VERIFIED | md5 Tick2 == Tick3; Tick differs only in comments + `T:172` string. | FIXED (one module). |
| F10 five wrappers | VERIFIED, one claim added | Every wrapper requires ITS OWN `script.Tick` (H grep: StrikeTickAPI:24, ReplicatedFirst:25, FxPackageLite:21, RoBaseCore:14 -> PluginGuiService copy), so no group is double-driven by two signals; the defect is divergence only. | FIXED (`TickAPI.new` + Variants). |
| F11 SyncedTimer O(n) | VERIFIED | `SyncedTimerClass.luau:344` `Lume.count(StoredClockRef)` per `ProcessEvents`; `:314` -> `MinHeap.luau:203-204` `indexof` linear remove. | FIXED (counters + lazy stale). |

## 2. New findings (L-nn). Severity: critical > major > minor > info

Each entry: cites; repro (numbered); consequence; **Revamp must**.

### L-01 (critical) `self.err` is POSITIVE inside a recurring callback: every timer created there waits about one extra period
- `T:147` re-arms (`timer += delay`) BEFORE `T:151` sets `self.err = e.timer`, so inside a recurring
  callback `err = period + residual > 0`; `T:183/192` then adds it to every nested delay/recur.
  Upstream identical: `rxi:100,104`. One-shot callbacks are correct (`err = residual <= 0`, 2b).
- Repro (exp2a): 1) `R = g:recur(f, 1)`; 2) inside f on first fire: `g:delay(h, 0.5)`; 3) step at
  1/60. Result: h fires 1.50 s later (expected 0.50). Nested `recur` gets the same first-fire offset.
- Consequence: silent, proportional to the parent's period. Blast radius in H: 93 files call
  `recur(`; 22 of them also create `delay(` on the same group (upper bound; any `delay` reached
  through the call stack of a recurring callback on the same group is affected).
- P: FIXED (`P/Group:124` `_base = due`, `P/Group:72` arms from `_base`; 9a -> 0.5167).
- **Revamp must** carry the FIRING entry's ideal due time, never the re-armed timer, as the base
  for nested arming; add a spec: nested delay inside recur waits `delay` +/- one frame.

### L-02 (major) swap-on-remove during the downward loop: any callback that stops a LOWER-index event double-charges dt (and can double-fire)
- `T:123-124` moves `self[#self]` into the freed slot. During `update` the tail (index >= i) was
  already visited this frame, so moving it to `j < i` re-visits it (`T:141-144`).
- Repro A (exp1a): 1) A=delay(10), B=delay(0.5), C=recur(10); 2) B's callback `A:stop()`;
  3) `update(1)` -> C.timer 8 (expected 9).
- Repro B (exp1b): 1) A=delay(10); 2) E=recur(1) whose first fire calls `A:stop()`; 3) `update(1)`
  -> E is moved into A's slot, visited again, **fires twice in one update** and now lags.
- Repro C, the "replace timer" idiom (exp1c/1d): 1) A=delay(10); 2) B=delay(0.5) whose callback
  does `A:stop(); Cnew = delay(1)` (or create-then-stop); 3) `update(1)` -> Cnew lands in an
  unvisited slot, gets this frame's dt on top of the err carry; in 1c it **fired in the same
  update it was created**; 1d: timer 1.5 instead of 2.5.
- The `T:142` nil-guard exists because the tail can collapse below `i` in this same scenario;
  rxi upstream CRASHES there ("attempt to index nil with 'timer'", exp8a, `rxi:96-97`).
- P: FIXED by construction (absolute due, 9c: exact 1.0 wait).
- **Revamp must** never index-swap during dispatch; use absolute due + heap + generation tags; add
  specs for A/B/C above (stop-older-from-callback, recur-stops-older, replace-in-callback).

### L-03 (major) a throwing callback poisons `self.err` until the next successful update
- `T:152` throws -> `T:158` never runs. Between that frame and the next completed update, every
  TOP-LEVEL `delay/recur` on that group gets the stale carry (`T:183`).
- Repro (exp2c): 1) `recur(function() error() end, 1)`; 2) step to the fire (raises); 3) top-level
  `delay(f, 0.5)` -> timer 1.4999 (late by a period). Variant: one-shot `delay(fn,0.01)` throws
  under `update(0.5)` -> `err = -0.49`; next top-level `delay(f, 0.1)` -> `d < 0` -> **f runs
  synchronously inside `delay()` at top level** and the caller receives the noop dummy (`T:185-189`).
- Also (exp2d): events at indices below the thrower skip that frame's dt (drift +dt each error).
- On Roblox the error is printed by the signal handler and the connection survives, so this is
  invisible except as timing glitches. Plausible source of the "Tickh does not happen on the
  server?" note (`API:10`); see L-20.
- P: FIXED (xpcall; `_base` cleared after the loop `P/Group:203`).
- **Revamp must** protect every callback AND reset the carry in a path that runs even on error
  (pcall + explicit cleanup, or the carry lives only in a local passed to arm()).

### L-04 (major) immediate-fire path (`T:183-190`): nested `recur` degrades to a one-shot + eternal noop; nested `recur(fn,0)` hangs the next frame; the handle is nil inside its own callback
- `d = delay + err < 0` only inside a one-shot callback (err <= 0) when `delay < |residual|` (<= dt).
  Then `fn()` runs synchronously and a dummy `event.new(self, noop, delay, recur, err)` is added.
- Repro (exp2f): 1) `delay(function() H = g:recur(f, 0.1) end, 0.5)`; 2) `update(1)`; 3) 10 s of
  frames -> f ran **1** time (expected ~100); `H.fn == noop`, `H.recur == true`, permanently in the
  array (visited every frame, ~2 noop calls/frame). exp2g: `recur(f, 0)` there -> dummy is
  recur+period 0 -> next update loops forever (1000 iterations before injected bail).
- exp2e: `local h; h = g:delay(function() h:stop() end, 0.1)` inside a callback with residual -0.5
  -> "attempt to index nil with 'stop'" because fn ran before `delay()` returned.
- exp2h: `delay(fn,0)` fires next frame at top level, synchronously inside a callback iff the
  residual is strictly negative (`d < 0`), next frame when it is exactly 0: data-dependent.
- Upstream identical (`rxi:133-140`). P: FIXED; no synchronous path; a past-due nested event is
  pushed and popped later in the same update (deviation 2; 9e "ok"), recur <= 0 rejected.
- **Revamp must** keep P's semantics (no synchronous fire; same-update dispatch of past-due nested
  events; handle always returned before it can fire) and reject recur period <= 0.

### L-05 (major) a callback that yields (task.wait / remote / WaitForChild / Async) suspends `update()` mid-loop; the next frame's `update()` runs concurrently on the same array
- Roblox runs each signal handler as its own coroutine; a yielding callback is legal and silent.
- Repro (exp6b, coroutine-simulated): 1) A=recur(10), Y=delay(0.5) whose callback yields then
  creates `delay(0.5)`, C=delay(10); 2) resume frame 1 (C visited, Y fires, yields); 3) run frame 2
  fully; 4) resume frame 1. Result: A charged 3 dt over 2 frames; the delay created after the
  resume saw `err = 0` (residual lost); the suspended loop continues against a stale `#self`/`i`
  (index shifts -> the L-02 family).
- P: PARTIAL; absolute time removes double-dt, but frame 2 sets `_base = nil` so arming after the
  resume is measured from `now` (9g: nested delay(0) armed at 2.0 instead of due 0.5).
- **Revamp must** decide a policy (see Q1) and at minimum detect re-entry with an `_updating`
  token and either warn once or defer the nested update; make the carry a per-dispatch local,
  not group state.

### L-06 (major) a recurring event that stops itself while lagging keeps firing this frame, leaking a false key per extra stop
- `T:145-156`: the while-loop never checks removal. Repro (exp3d): 1) `R = recur(function()
  n+=1; R:stop() end, 0.1)`; 2) `update(0.35)` -> n = 3 (expected 1), 1 false key (the 2nd/3rd
  stops hit `T:127`). P: FIXED (`P/Group:186` state check; 9f -> 1 fire).
- **Revamp must** re-check the handle's state before every catch-up fire.

### L-07 (major) `delay(fn, 0/0)` is accepted and becomes a permanent zombie
- `T:171-176`: `NaN < 0` is false. Repro (exp8b): `delay(f, 0/0)`; 100 updates -> never fires,
  `#g == 1` forever (visited every frame; only `stop()` removes it). `adjust()` produces the same
  zombie (F6). `delay(f, math.huge)` likewise never fires but is never removed.
- P: NOT FIXED; `P/Handle:88` `period < 0` passes NaN; due = NaN; `top > now` is false -> popped
  and **fired on the first update** (9b). Upstream identical (`rxi:124`).
- **Revamp must** reject `period ~= period` (NaN) with a named error; decide inf (Q6).

### L-08 (major, design) catch-up burst after a hitch is unbounded and synchronous
- `T:145-156`: `recur(f, 0.01)` under one `update(5)` (join spike, GC pause) -> 500 synchronous
  calls in one frame (exp8c). P default is also unbounded (`maxCatchUpPerFrame = nil`,
  `P/Variants:104`; 9d: `recur(1e-4)` -> 10,000 fires per `update(1)`).
- **Revamp must** ship a default cap and/or a per-timer "drop missed" mode (Q2), and clamp the
  minimum period (or reject tiny periods) so a typo cannot hang a frame.

### L-09 (minor) `reset()` semantics: phase drift inside recurring callbacks; silent no-op after fire
- `T:101-103`. exp5g: `recur(f, 0.1)` whose callback calls `reset()` fires every 0.1167 s at 60 Hz
  (17 % slow: reset discards the residual, so each cycle rounds up to whole frames) and cancels
  catch-up (1 fire after a 1 s lag instead of 10). exp5e/5f: `reset()` on a one-shot from inside
  its own callback or after it fired is a no-op (already removed at `T:149`); a caller expecting
  re-arm gets nothing (this is exactly `AfterNotTouched:Touch` after an fn error, L-23).
- P: Fired handles are terminal no-ops (`P/Handle:133`); recurring reset arms from `_base` so
  no drift.
- **Revamp must** define reset-after-fire (re-arm vs no-op vs error) and reset inside a recurring
  callback (from ideal due, not from now).

### L-10 (minor) `adjust()` input handling: 0, negative, nil, string
- `T:92-95`. exp5b: `adjust(0)` on a recurring -> timer/delay 0 -> next update loops forever (F5).
  exp5c: `adjust(-1)` -> negative timer/delay (fires next frame; recurring would loop). exp5d:
  `adjust(nil)` -> arithmetic error; `adjust("4")` -> `delay` becomes the STRING "4" (coerced in
  later arithmetic). exp5h: adjust on a lagging recurring inside its own callback still bursts.
- P: rejects <= 0 / non-number (`P/Handle:144`), but F6 (existing period 0) absent.
- **Revamp must** validate `newTotal` (finite, > 0) AND guard `period == 0` (treat as "set
  remaining = newTotal").

### L-11 (minor) `after()` dead chains are silent
- `T:60-74`. exp4a: `after()` on an event whose fn already ran -> wrapper never runs -> child never
  scheduled, no error, the returned child looks armed (`timer = 0.1`). exp4b: `after()` from inside
  the parent's own callback -> same (parent removed at `T:149`). exp4e: parent callback throws ->
  wrapper aborts before `add()` -> chain dies. exp4c/4d/4h: normal chains, double `after`, and
  chains off the immediate-path dummy work (dummy chain is one frame late: 0.8167 vs 0.8).
- P: `after` on a terminal handle returns the PARENT (`P/Handle:163-165`); also silent and
  returns the wrong object.
- **Revamp must** define after-on-fired (Q5) and never return the parent as if it were the child.

### L-12 (minor) bound-table colon/dot matrix (`T:224-230`, `API:36-52`): which misuse is silent
| Call | Result |
|---|---|
| `Tick:remove(h)` | SILENT no-op: closure receives `(group, bound, h)`, so `e = bound`; `group[bound]=false` (one bounded key); **h still fires** (exp7). |
| `Tick:getClocks()` | silent 0 (F7). `Tick.getClocks()` -> error "length of nil". |
| `Tick:update(dt)` | silent no-op on the empty bound table (would error only if `bound` had events). |
| `Tick:add(e)` | silently adds to the bound table, never updated. `Tick:group()` returns a fresh group. |
| `Tick:delay/recur(fn,d)` | loud "expected `fn` to be callable". `Tick:event(...)` loud arithmetic-on-nil (`T:183`). `Tick.event(...)` loud. |
| `h.stop()/reset()/adjust()/after()` (dot) | loud "attempt to index nil/number/function with ..." (`T:80,101,92,61`). |
- P: groups accept both forms (`P/Group:434-441`); handle dot-calls fail with the internal message
  "attempt to index nil with '_state'" (`P/Handle:67`).
- **Revamp must** keep dual-form group methods and make handle methods assert `Handle.is(self)`
  with a user-facing message; `remove(x)` must reject non-handles loudly (debug) or no-op.

### L-13 (minor) same-frame fire order is newest-first and scrambled by any removal
- `T:141` (downward) + `T:123` (swap). exp8d: 5 equal-due events fire 5,4,3,2,1; after stopping
  #1 and #2 the order is 4,3,5,6. Any code assuming creation order is wrong today.
- P: due then creation (`P/Heap:30-36`). **Revamp must** document the ordering guarantee and test it.

### L-14 (minor) float boundary: `delay(3*dt)` fires on the 4th frame
- `T:144-145`: three subtractions of 1/60 from 0.05 leave ~1e-17 > 0 (exp8f). A `now + d` model
  has the same class of error. **Revamp must** pick an epsilon (e.g. fire when `due - now <= 1e-9`)
  or document "fires on the first frame whose accumulated time is >= delay".

### L-15 (minor) `remove(number)` with a bad index throws "table index is nil"
- `T:121-122` (`self[nil] = nil`). Reachable via public `Tick.remove(7)`. P ignores non-handles
  (`P/Group:409-413`). **Revamp must** not expose index removal.

### L-16 (info) nested `update()` from a callback
- exp6a: double dt on already-visited events and `err` clobbered to 0 for the rest of the outer
  callback. P would similarly clear `_base`. **Revamp must** guard with an `_updating` flag (error
  or no-op).

### L-17 (info) validation surface (`T:166-176`)
- `tonumber` coercion accepts `"0.5"`; `true`/`nil` report "CurrentType: nil" (post-coercion type,
  misleading); callable tables accepted (exp8b). **Revamp must** report the ORIGINAL type.

## 3. TickAPI.luau

### L-18 (info) signal argument mapping is correct; teardown absent
- `API:38-40` Stepped `(time, dt)` -> 2nd arg; `API:44-46` Heartbeat `(dt)`; `API:54-56`
  RenderStepped `(dt)`, client-only (`API:51`). Connections are never disconnected (module
  singleton, acceptable today, NOT acceptable for the instance model; P also has no teardown,
  RF-004/009/015/023/030/035 open). **Revamp must** give every scheduler instance a `Destroy()`
  that disconnects, clears, and marks it dead.

### L-19 (info) `debug.setmemorycategory("TickAPI")` (`API:2`) tags only the requiring thread
- The RunService handler threads where every event/closure is allocated are not tagged, so the
  Developer Console category is misleading. (Roblox semantics as documented; not re-verified in
  Studio.) **Revamp must** call it inside the update entry point per frame if the category matters,
  or drop it.

### L-20 (question) "APPARENTLY Tickh does not happen on the server?" (`API:10`) is false as stated
- Heartbeat fires on the server; the live server code uses `TickAPI.Tickh.delay/recur` 45 times
  (H: ServerScriptService+ServerStorage) vs `TickAPI.Tick.*` 72 times. Candidate explanations
  the author could have observed: one throwing Tickh callback aborting the rest of that frame
  (F4) plus the err poisoning that follows (L-03), a yielding callback (L-05), or the
  positive-err delay (L-01) making nested timers appear not to fire. See Q9.

### L-21 (minor) `Tickr` is nil on the server; `GetAfterNotTouched(_, _, "Tickr")` errors deep inside the class
- `API:51-57`, `ANT:45` -> "attempt to index nil with 'delay'". P rejects with a named error
  (`P/init:79-83`). **Revamp must** validate the hook name at the API boundary.

### L-22 (info) each wrapper copy drives its OWN core module (F10 refinement)
- No double-update of a shared group exists today (H grep, see F10 row).

## 4. AfterNotTouchedClass.luau (exp10 = minimal port of `ANT:38-78` over the shim)

### L-23 (major) if `fn` throws, `Destroy` never runs: object leaks in `Storage`, Id never freed, `Touch()` is a silent no-op forever
- `ANT:45-51` (`fn()` then `self:Destroy()` with no protection). exp10b: after the throw the
  object is still in Storage, `isDestroying == false`, Id not freed, and `Touch()` -> `reset()`
  on a clock already removed at `T:149` (no-op; L-09), so it never re-arms. The throw also aborts
  the frame (F4) and poisons `err` (L-03). MostlyUUID v2.0.0 (H) never reuses the slot -> LiveCount
  creeps toward the 1,048,575 cap. P: FIXED (`P/AfterNotTouched:51-55` pcall, Destroy, rethrow).
- **Revamp must** always destroy (pcall or a finally pattern) and re-raise via the group's error policy.

### L-24 (major) every NATURAL fire leaks one F3 false key
- `ANT:48` `self:Destroy()` inside the callback -> `ANT:74` `SafeStopClock` -> `T:81` -> `T:127` on a
  clock already removed at `T:149`. exp10a: 100 fires -> 100 false keys. Only one live call site
  (TowerOfTest:283) today; it is the canonical self-stop-in-callback idiom that F3 punishes
  everywhere (exp3b). P: FIXED (terminal no-op).

### L-25 (minor) immediate-path zombie: constructed inside a callback with `_time < |residual|`
- `ANT:45` runs the callback synchronously (L-04): `fn()` and `self:Destroy()` execute BEFORE
  `self.Clock` (`ANT:45`) and `Storage[self.Id]` (`ANT:53`) are assigned. exp10c: the object ends
  with `isDestroying == true`, IS registered in Storage (never removed), its Id already freed
  (future collision overwrites the slot), and `self.Clock` = the noop dummy still in the group.
  P: n/a (no synchronous path). **Revamp must** register before arming and make construction
  robust to being destroyed re-entrantly.

### L-26 (info) `Storage` is unreachable and `SafeLoad` is one-shot
- `ANT:27` lives on the wrapper table but the module returns the class (`ANT:80`), so nothing can
  audit Storage. `ANT:18-21` via `Lume.once` (H Lume:1353-1361): if the first lazy require throws,
  `done` is already true -> `TickAPI` stays nil and every later `:new` errors at `ANT:45`.
  **Revamp must** inject the scheduler (P's design) and expose a count for diagnostics.

## 5. P rebuild: status of the MISSED issues (executed, exp9)
FIXED by P: L-01 (base = due), L-02 (absolute time), L-03 (xpcall), L-04 (no sync path), L-06,
L-13, L-15, L-23, L-24, L-25. NOT/PARTIALLY fixed: L-05 (`_base` clobbered by a concurrent update
under yield), L-07 (NaN accepted, fires immediately), L-08 (unbounded default catch-up), F6 (adjust
on period 0 -> NaN -> fires after 1 frame), L-11 (after-on-terminal returns the parent), L-12
(handle dot-call message internal), L-14 (boundary), L-18 (no teardown), plus RF-010/013/020/031/039
(capped re-arm resurrects a stopped handle) from the prior loop.

## 6. What TickRevamp must do (condensed)
1. Absolute-due min-heap + generation tags + terminal handle states (P's shape). Closes F1/F2/F3/
   F8/L-02/L-06/L-13 by construction.
2. Carry the firing entry's IDEAL due as the base for nested arming; keep it in a per-dispatch
   local so a throw or a yield cannot leak it (L-01, L-03, L-05).
3. Protect every callback; error policy per scheduler; cleanup runs on every path (F4, L-03).
4. Validation: reject NaN everywhere; recur period > 0; adjust/setPeriod finite > 0; guard existing
   period 0 (F5, F6, L-07, L-10, L-17); report original types.
5. Default catch-up cap + minimum period + optional drop-missed mode (F5-spirit, L-08).
6. Re-entrancy: `_updating` token; nested update -> error/no-op; yield detection -> warn once (L-05, L-16).
7. No synchronous immediate-fire; past-due nested events dispatch later in the same update;
   handle returned before it can fire (L-04).
8. `after()`/`reset()` on a fired parent: explicit, documented behaviour, never returns the parent
   as the child (L-09, L-11).
9. Dual-form group methods; handle methods assert `Handle.is(self)` (L-12).
10. Scheduler instances own their RunService connection and expose `Destroy()` (L-18); hook names
    validated at the boundary (L-21).
11. AfterNotTouched: inject scheduler, register before arming, pcall fn then Destroy (L-23 to L-26).
12. Port every `exp*.luau` scenario above into the spec suite as regression tests; keep the
    legacy shim as the oracle ONLY for the behaviours that are meant to be preserved.

## 7. Open questions for Jake
Listed in the structured output `questions` field (yield policy, catch-up default, past-due nested
semantics, after-on-fired, NaN/inf, foreign-handle stop, ForceEventComplete on recurring, the
"Tickh on the server" observation, Tickr on the server).

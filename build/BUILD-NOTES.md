# BUILD-NOTES

Choices made where `docs/DESIGN.md` is silent, one heading per work package, dated bullets.

## WP2 — test support (`build/tests/support/{oracle,legacy,gen}.luau`)

- 2026-09-16 — `Oracle.wrap` wraps the instance IN PLACE (returns the same table) rather than
  building a proxy: the design's dual closures live on the instance, so replacing each
  function-valued key keeps `s.Stop == s.Remove == s.remove` (aliases share one wrapper) and
  keeps identity (`h._Scheduler == s`). Handle methods are wrapped once per process by replacing
  entries of `VeronEvent` (required lazily inside `wrap`, so the file loads before
  WP3's class exists). Wrapping adds ONE stack frame per public call, so error-level ("blames the
  caller's chunk") assertions must run on a RAW instance — `errors_spec` is raw.
- 2026-09-16 — Failure path: a wrapper `pcall`s the original and re-raises with `error(err, 0)`;
  no check runs when the original raised (guard-only path), exactly as the package brief says.
- 2026-09-16 — NOOP capture: `Oracle.noop()` captures the Stopped-handle `NOOP` once per process
  from a throwaway `Veron.new{ Name = "OracleProbe" }` (Delay → Stop → read `_Fn` → Destroy),
  never from an instance under test; when the class cannot be required yet it falls back to the
  first Stopped handle the oracle meets. A hand-built fake uses `Oracle.noop() or function() end`
  so it agrees with the real class in the same process.
- 2026-09-16 — Handle reach: besides the heap, `_Paused`, `_Chained` lists and `_Firing`, the
  oracle keeps a weak registry of every handle that passed through a wrapper (`self` of a handle
  method, or a handle returned by a wrapped arm) so terminal handles keep being audited after
  they leave every container (`_HeapIndex == 0`, `_Flags == 0`, Stopped ⇒ NOOP). Specs that build
  handles outside wrapped calls can register them with `Oracle.track(h)`.
- 2026-09-16 — Extra checks beyond the §3.2 list, all implied by it: array tails cleared past
  `_N`, no holes below `_N`, unique Ids across heap + paused set, `_Scheduler == instance` for
  every reached handle, a CHAINED handle is never registered under a terminal parent, attached
  children are checked recursively (`child._Parent == parent`). Nothing about PWC placement or
  the triple being all-or-nothing is asserted (an `OnError` handler can observe `_FiringThread`
  set with `_Base == false`).
- 2026-09-16 — `Oracle.check` calls `Validate()` only when the table has one (a fake may omit
  it), always through the ORIGINAL closure (no recursion through the wrapper).
- 2026-09-16 — `legacy.luau`: the shim's module value is the `bound` table whose metatable is the
  `tick` group class, so `Legacy.group()` is `Tick.group()`; `Legacy.Tick` exposes the module for
  the reference-file test; a `Legacy.getClocks(g)` helper is added.
- 2026-09-16 — `gen.luau`: Park–Miller LCG (`x = x * 48271 % 2147483647`, exact in doubles).
  Delays k/64 (k in 1..64), dt 1/64 or 1/32 (`constraints.dts` may widen up to 1/2). The
  generator carries an exact integer model (1/4096 s grid) of both schedulers to decide
  legality: "stop" never targets an unarmed chained child (legacy still arms it), "after"/"nest"
  only on live unfired one-shots (legacy never fires a child added to a fired/stopped parent),
  nested/chained delays are ≥ 1/16 AND > every dt (never at or below the overshoot, DV-2),
  "adjust" is `total × {0.5, 2, 4}` and only when `remaining/total` is an exact dyadic ratio and
  the result stays on the grid (both sides then compute identical doubles), `lagLimit = L` picks
  a smaller dt whenever any live recurring would owe more than L fires. Each `update` step also
  carries `expect` (sorted ids the model says fire); verified equal to the legacy shim's actual
  fires over 300 seeds × 400 steps in a scratch drive (deleted after). A nest whose parent is
  stopped before firing gets status `never` and is never targeted (the harness never gets a
  handle for it). Step schema is documented in the file header.
- 2026-09-16 — Smoke spec `spec/support/support_spec.luau` (4 tests) runs without the Veron
  class: the oracle is exercised on a hand-built fake whose `Validate` always returns true, so
  every corruption is caught by the independent walk alone.

## WP4/WP5 spec writer — `build/tests/spec/handle/{state,stop,retime}_spec.luau`

- 2026-09-16 — `state_spec :: … even with invalid arguments`: the §9 parenthetical lists
  `:After(nil, 1)` among the no-raise calls. §2.3 (After row: "legacy arg strings
  (Pending/Paused/Chained/Fired parents only)"), §4.6 (`_validateArgs` runs before the
  `state == FIRED` branch) and §5 all make `After` on a FIRED parent validate its arguments, so
  the spec asserts `After(nil, 1)` (and `After(fn, -1)`, `After(fn, "x")`, `After(5, nan)`) as
  no-raise + born-Stopped child on the STOPPED handles only; `After` with bad arguments on a
  Fired parent is left to `chain_spec`. Likewise `After(fn, t)` on a Fired RECURRING raises
  `cannot chain a recurring event` (§4.6, A3), so the "each returns h / no-op" walk applies
  `After` to the Fired one-shot (child armed, parent untouched) and to both Stopped handles, not
  to the Fired recurring. `Complete(<non-table>)` is also excluded: `_checkOpts` runs BEFORE the
  terminal check (§4.7), so it raises on a terminal handle by design.
- 2026-09-16 — The terminal no-op walks iterate an explicit list of the §2.3 fluent methods
  (`Reset/reset/Adjust/adjust/SetPeriod/SetRemaining/Pause/Resume/Toggle/SetCatchUp`) plus
  `Complete/CompleteNow` (→ `false`), `Stop/stop/Destroy` (→ nil) and the queries, and compare a
  snapshot (`GetState/GetStateId/GetRemaining/IsPaused/GetPeriod/GetId/IsActive/IsRecurring/
  Describe` + `rawget` of `_Flags/_HeapIndex/_Fn`) before and after each call. The Fired
  recurring is built with `Complete{ Stop = true }` + `Update(0)` as the brief says.
- 2026-09-16 — `retime_spec :: adjust inside own lagging recurring callback fires at most twice`
  and `:: pause+resume inside lagging callback bounded` assert `1 <= fires <= 2` for the B-01
  repros (`Update(5/2)`, period 1 — the §4.5 arithmetic gives exactly 2), `ValveHits == 0`, and
  add a `Update(100)` variant bounded by the default `MaxCatchUp` (≤ 8) so a hang can never
  pass. `adjust on period 0` pins the §4.5 `else 1` branch (remaining == the whole newTotal),
  which supersedes the SEM R3 "frac = 0" wording.
- 2026-09-16 — Style exception: the `t.test("every public method is a no-op on Stopped and,
  Stop/Restart excepted, on Fired even with invalid arguments", function()` line is 131 columns
  because the §9 name must stay a single greppable literal; every other line is ≤ 120.
- 2026-09-16 — Lists of bad arguments never contain `nil` inside the literal (it ends the
  generalized iteration early and silently skips the rest); nil is exercised by an explicit
  call in each validation test.
- 2026-09-16 — WP3's `state_spec :: handle dot-call raises the colon message` is kept, but its
  level-2 ("blames the caller's line") assertion is now order-independent: once any spec in the
  process has called `Oracle.wrap`, `VeronEvent` holds the oracle's wrappers
  (one `pcall` frame, re-raised at level 0), so the position prefix is gone. The test detects a
  wrapped `Stop` via `debug.info(fn, "s")` and then checks the bare message instead; the raw
  prefix check still runs under `run_one` (this spec's first test, nothing wrapped yet) and in
  `errors_spec` (raw by design).
- 2026-09-16 — Same cause, same test: the literal handle's fake owner now carries the §3.2
  container fields with the literal in its one-slot heap (`_Due = {1}`, `_Item = {h}`,
  `_N = 1`, `_HeapIndex = 1`), because the wrapped `GetState` audits `h._Scheduler` through
  `Oracle.check` and the bare `{ Name = "T" }` owner failed "instance field is nil (_Due)". No
  Veron instance is involved; the test's subject (dot-call guard, level 2) is unchanged.

## WP4 + WP5 + WP6 — the Veron core (`build/src/Veron/init.luau`, one author)

- 2026-09-16 — Level-carrying helpers are FORWARD-DECLARED locals (`_checkOption, _checkOpts,
  _validateUncapped, _validateArgs, _resolve`, plus the design's `_attach`), assigned as
  `_x = function(...) end`. Reason, verified under Lune 0.10.5: the Luau compiler at O2 inlines
  every small `local function` into its caller (loops and `format` calls included — only a local
  assigned after its declaration escapes), which deletes the frame the trailing `level` counts on;
  `Veron.new{ TimeScale = -1 }` and `Recur(fn, p, "all")` then blamed nothing. With the change every
  §2 level-table row holds and `Veron(cfg)` blames the construction call (post-2026-09-16 BaseClass removal: all forms reach `_construct`, no vendor `__call` frame). Roblox compiles
  at O2 too, so the rule is not Lune-specific; any future helper that raises at a caller-relative
  level must use the same shape.
- 2026-09-16 — `Veron._Heap = { push, pop, remove, update, clear }` exposes the raw heap ops
  for `heap_spec` (a static table read once by the spec; never on the hot path). `heapRemove`
  additionally returns `false` when `_Item[_HeapIndex] ~= h` (ownership), so a corrupted index can
  never splice a foreign slot; `heapUpdate` raises the §3.2 ownership text (level 2, internal).
- 2026-09-16 — Config: a non-nil, non-table `cfg` raises `Veron: expected a config table, got <t>`
  (level 4); the `Name` counter increments on every construction, named or not, so a default name
  is `"Veron" .. <construction ordinal>`. Option texts: Name "a string", TimeScale "a finite number
  >= 0", MaxCatchUp/Valve/MaxUpdateDepth "an integer >= 1", MaxDt "a number > 0 or false" (finite),
  OnError `"warn", "error" or a function`, Strict/LegacyRecurBase "a boolean".
- 2026-09-16 — `DelayAt`: the `destroyed` check runs before the `needs UpdateTo` check (§2.2 lists
  `destroyed` for DelayAt after Destroy; the §4.8 comment lists the UpdateTo check first — the
  design is silent on the order when both apply).
- 2026-09-16 — `_SetRemaining` and `_SetPeriod` coerce with `tonumber` like `_Adjust` (legacy I7
  coercion; the design gives the messages but not the coercion).
- 2026-09-16 — `_CompleteNow`: the option-table method name in its error is `CompleteNow`
  (`unknown option '<k>' in CompleteNow`); a recurring that already carries STOP_ON_FIRE (from an
  earlier `Complete{Stop = true}`) is treated as `opts.Stop` (the committed final fire is honoured);
  the "recurring Chained" row of the §4.7 case table is unreachable (a chained handle is never
  recurring) and is not coded; the depth-cap diagnostic reads `CompleteNow nested deeper than 8;
  event #<id> refused`.
- 2026-09-16 — `Clear()` returns the total including handles stopped in attached children (the
  design says "cascades to attached children; returns handles stopped").
- 2026-09-16 — `Validate()` walks heap slots, `_Paused` keys, every `_Chained` list of a live handle
  (all entries shape-checked, only still-CHAINED ones counted), `_Children` (each child must point
  back), `_Firing`, and the idle triple. Success path allocates 0 B (measured: 1000 × GetStats(into)
  + Validate = 0 KB with 10k armed); reasons are literal strings.
- 2026-09-16 — Smoke under Lune (create ×4 spellings, delay/recur/update, stop, adjust/reset,
  pause/resume/toggle/restart, after/complete/completenow, error policy, callable table, drive,
  attach/destroy, sync re-entry, UpdateTo/DelayAt, clear/destroy; `Validate()` + `Oracle.check`
  after each): OK. Idle 1000 updates with 10k armed: 0 KB; busy 1000 updates × 50 dispatches:
  0 KB steady state (one-time 0.31 KB on the very first round after a 10k-arm setup, GC bookkeeping).
- 2026-09-16 — **Valve latch across nested passes (design-text correction for §4.2 (c) / §11).**
  §4.2 as written gives every nested pass its own fresh valve budget AND lets the enclosing passes
  keep dispatching (and spawning nested passes) after an inner trip, so a `Delay(0)+Update(0)`
  chain dispatches Σ (Valve+1)^k over k = 1..MaxUpdateDepth per outer Update (155 with Valve 4 /
  depth 3; ~10^24 with the defaults — a hang), not the `MaxUpdateDepth × Valve` bound §4.2 (c) and
  §11 state and `reentrancy_spec :: sync re-entry chain is bounded per pass …` pins (see the
  spec writer's note below). Resolved in favour of the stated bound: D5's runaway guard is the
  decision, the per-pass counter the mechanism. `_advanceTo` passes `self._ValveHits` into
  `_pass(self, serial, valveHits)` and the loop head breaks once the counter moved, so a trip
  anywhere in the tree ends every pass of that outer Update and the remainder stays keyed for the
  next update (D5's own wording). NO new instance field (§3.2's list is closed —
  `class_spec :: every Veron field non-nil after initialize` rejects extras); per-pass
  `serial/startId/valve` untouched; a plain top-level pass behaves exactly as before (catch-up
  valve tests unaffected); cost: one field read per dispatch. Measured: 7 dispatches for the
  Valve 4 / depth 3 chain. Flagged for the integrator/Jake to correct the §4.2 (c) / §11 text.

## reentrancy_spec + lifecycle_spec (`build/tests/spec/scheduler/{reentrancy,lifecycle}_spec.luau`, spec writer)

- 2026-09-16 — **Design self-contradiction flagged, not papered over.** `reentrancy_spec ::
  sync re-entry chain is bounded per pass: Delay(0)+Update(0) recursion ≤ MaxUpdateDepth × Valve
  dispatches` pins the bound §4.2 (c) and §11 claim. With `_pass`/`_advanceTo` exactly as §4.2
  writes them that bound does not hold: every nested pass gets its OWN `valve` local and its own
  `startId`, and after the innermost pass trips, each outer pass keeps dispatching (every handle
  armed in a nested pass has `Id > startId` of every enclosing pass) and re-nests on each
  dispatch. A callback that does `s:Delay(cb, 0); s:Update(0)` therefore dispatches
  Σ (Valve+1)^k for k = 1..MaxUpdateDepth per outer Update — 155 for Valve = 4 / depth 3, ~1e24
  for the defaults, i.e. a hang. The test uses `Veron.new{ Valve = 4, MaxUpdateDepth = 3 }` plus
  a 10 000-dispatch arm guard so it terminates whatever the core does, and asserts the design's
  own bound (12) — expect it to FAIL against a literal transcription of §4.2 until either the
  claim is corrected or the valve budget is made per outer Update (e.g. an instance counter
  zeroed at depth 0 and shared by nested passes). Decision is Jake's / the orchestrator's.
- 2026-09-16 — `Clear()`'s return with attached children: §2.2/§4.3 do not say whether the
  count includes the children's handles; `lifecycle_spec :: Attach: parent Destroy destroys the
  child, Clear clears the child` asserts only `>= own count` and checks the children's handles
  by state.
- 2026-09-16 — "task.spawn from a callback" uses `@lune/task` (`task.spawn` resumes the new
  thread immediately under Lune 0.10.5, verified) with a `coroutine.wrap` fallback; the
  design's R-D only needs "a thread other than the firing one".
- 2026-09-16 — Allocation and corruption tests bypass the oracle on purpose: the
  `GetStats(into)` zero-allocation check runs on a RAW instance (`Oracle.wrap`'s wrapper packs
  results into a table, `table.pack`, so a wrapped call can never measure 0 B), and `Validate
  reports a deliberately corrupted heap` corrupts RAW instances (a wrapped call would raise from
  `Oracle.check` before `Validate()` could return `false, reason`). `collectgarbage("collect")`
  is not available under Lune (verified: "invalid option"), so the check is a bare `count` delta,
  which is exact when nothing allocates.
- 2026-09-16 — `a corrupted handle field …`: after the internal-fault raise the test reads the
  triple/depth/heap through `rawget` only, repairs `_Period`, and only then calls `Validate()`
  and wrapped methods — §3.2's invariant list does not mention `_Period`, but a stricter
  `Validate` (or the oracle's `Validate` call) must not be able to fail the test on the field the
  test itself corrupted.
- 2026-09-16 — `every diagnostic reaches a function OnError policy …` covers the four
  `_diagnose` callers named in §4.2 (`re-entered`, `backwards`, `valve`, `resolution`); the
  CompleteNow-nesting diagnostic (§4.7) is `complete_spec`'s. The sub-resolution trigger is
  `Update(2^30)` then `Recur(fn, 1e-10)` (1e-10 < ulp(2^30) = 2^-22, so `d + period == d`);
  the valve trigger uses `Valve = 100` with a 150-arm zero-delay chain, run LAST because a
  tripped valve leaves the pass early.
- 2026-09-16 — Rate-limit arithmetic in `repeated callback errors are rate-limited and counted`
  follows §4.2 `_report` literally: same handle at 1/64 s → report at t = 1/64 and t = 65/64
  (`since == 1` is not `< 1`), 63 suppressed between; distinct one-shots erroring every 1/64 s →
  reports at k = 1, 9, 17, …, 57 (`since < 0.125` suppresses), 8 per second, 56 suppressed.
- 2026-09-16 — `Drive under a hitch …` pins `Dropped == 56` for a capped 1/64 pump after a 1 s
  hitch: 8 fires re-key the pump to 9/64, then §4.2's snap computes `m = (1 - 9/64) // (1/64)
  + 1 = 56` and `nextDue = 65/64`. Dyadic, so exact.
- 2026-09-16 — Both files keep a file-local probe registry: every callback that can calls
  `_probe(s, label)` (`Validate()` + `Oracle.check` under `pcall`, outcome recorded, never
  raised — a raise inside a callback would be swallowed by the scheduler), and `Validate holds
  inside every callback above` asserts the registry is non-empty and clean. `lifecycle_spec`
  has no such named test, so it does not probe.

## WP5/WP6 spec pass — `handle/chain_spec`, `handle/complete_spec`, `heap/heap_spec`, `errors/errors_spec`, `class/class_spec` (extension; renamed from `baseclass/baseclass_spec` on 2026-09-17)

- 2026-09-16 — All four new spec files require the class modules LAZILY (a memoized `_load()` called
  from each test's setup) so the file itself loads under Lune even before the core exists; a missing
  core then fails each test individually instead of the whole file at `<load>`.
- 2026-09-16 — Assertions never run inside a callback: a failing `t.eq` there would be swallowed as a
  callback error and merely warned, so callbacks RECORD what they observe into a `seen` table and the
  test asserts outside. Warn output is captured with `Env.SetWarn` wherever a callback errors on purpose.
- 2026-09-16 — `heap_spec` reaches the heap ops through the test-only static table
  `Veron._Heap = { push, pop, remove, update, clear }` (the orchestrator's brief; not in
  DESIGN.md). Ownership test: DESIGN §3.2/§4.3 say only `heapUpdate` raises
  `Veron: handle is not scheduled on this Veron`, while `heapRemove`'s ownership check makes a foreign
  or stale handle a `false` no-op ("popped-but-Pending → false, harmless"). The brief's wording
  ("the error from update/remove") was read with the design as authority: update raises, remove
  returns `false` and leaves the heap untouched.
- 2026-09-16 — `chain_spec :: Clear/Destroy with a completed child does not corrupt the walk` asserts
  `Clear()`'s return is a number in `3..4` for a walk of {parent, completed child, paused recurring}
  plus one cascaded still-Chained sibling: §2.2 says "returns handles stopped" but does not say whether
  cascaded Chained descendants are counted, so the test pins the corruption-free walk, not the count.
- 2026-09-16 — `errors_spec` is RAW (no `Oracle.wrap`, per the WP2 note: the wrapper adds a frame).
  Level checks put `L()` (records `debug.info(2, "l")`) and the raising call on ONE source line and
  compare the reported `chunk:line:` exactly. `cannot chain a recurring event` is raised unprefixed by
  §4.6's code while §2's prose only enumerates the legacy/prior/extension strings as the validation
  family; it is treated as validation-family (an argument check on the parent) and left out of the
  prefix test rather than asserting either way. The chunk of the documented `Veron(cfg)` exception is
  was asserted to contain `BaseClass` (the `__call` frame lived in the vendor file); superseded by the 2026-09-16 BaseClass removal — the plain-module `__call` reaches `_construct` and no spec asserts BaseClass now.
- 2026-09-16 — `class_spec` (renamed from `baseclass_spec` 2026-09-17): the WP3 TODO suggested `Env.Load("Veron")`, but `Env.Load` resolves
  SIBLINGS of `Env` (`build/src/Veron/<name>`), and `Veron` is the parent; the widened boot test
  requires `../../../src/Veron` directly. Two §9 names in `errors_spec` exceed the 120-col hard limit
  on their own; the literals are split with `..` so the registered name stays verbatim.

## WP4-specs — scheduler specs (`build/tests/spec/scheduler/{arm,time,dispatch,catchup}_spec.luau`)

- 2026-09-16 — Dyadic timing everywhere the design's own numbers are not dyadic: the
  `cap 8: 5 s hitch on a 0.1 s recur …` test pins the exact grid on a 1/16 s period (80 owed,
  8 fired, `Dropped == 72`, snap to 81/16) and runs the literal 0.1 s case asserting only what
  survives float rounding (8 fires in the hitch, then exactly one fire in the next 0.15 s).
- 2026-09-16 — Two tests drive a RAW instance where an oracle walk per call would dominate:
  `time_spec :: UpdateTo exact at scale 1 after 1e6 samples` (1e6 samples, `Oracle.check` once
  at the end) and `catchup_spec :: valve never trips on a 10k pre-existing one-shot storm`
  (10k/2k arms raw, then `Oracle.wrap` BEFORE the Update so the dispatch itself is audited).
  Every other instance in the four files goes through `Oracle.wrap`.
- 2026-09-16 — `Delay(3*dt) one update late …` (L-14/DV-11): on the accumulating `now += dt`
  axis three 1/60 additions DO reach `3 * dt` (verified under Lune), so the legacy "4th frame"
  case is not reproducible as-is; the test pins the rule instead — the fire lands on the first
  update whose accumulated clock `>= due` with no epsilon, checked against an independent
  accumulation of the same float ops — and uses `Delay(fn, 10 * 0.1)` under 0.1 s steps
  (sum 0.9999999999999999 < 1) as the concrete one-update-late case.
- 2026-09-16 — Error-message matching is a plain `string.find(msg, text, 1, true)` on the exact
  template (the templates carry backticks, dots and parentheses); NaN spellings are never
  matched (`tostring(0/0)` is platform-spelled) — only the prefix before `got`. For
  `CompleteNow` opts errors the tests match `Veron 'T': Complete` / `unknown option 'stop' in
  Complete` as prefixes, so both a `Complete` and a `CompleteNow` method label satisfy them
  (§4.7 says "`_checkOpts` as above" without fixing the label).
- 2026-09-16 — Setter coercion is NOT pinned: bad-value lists for `SetTimeScale`,
  `SetMaxCatchUp`, `MaxDt` config use non-numbers (`true`, `{}`, `nil`) and out-of-range
  numbers only, never numeric strings, since §2.1 states the type as "number" without saying
  whether a string is coerced.
- 2026-09-16 — WP4-only tests avoid WP6 members: `catchup_spec :: cap 8 …` reads
  `rawget(s, "_MaxCatchUp")` instead of `GetMaxCatchUp()`; `per-handle SetCatchUp …` proves
  "inherit" against a second instance built with `MaxCatchUp = 3` instead of `SetMaxCatchUp`;
  `dispatch_spec :: error policy …` re-raises a second time instead of switching the policy
  with `SetOnError`. The three tests §12 marks "after WP5/WP6" use those members freely.

## Integration round 1 (whole-suite integrator)

- 2026-09-16 — Result: `lune run build/tests/run.luau` → `208 passed, 0 failed` on the first run;
  every one of the 16 spec files also passes alone through `run_one` (order-independent), and all
  204 non-support test names match their §9 row byte-for-byte (env 5, heap 7, arm 12, time 16,
  dispatch 16, catchup 15, reentrancy 20, state 20, stop 9, retime 13, chain 15, complete 23,
  lifecycle 18, baseclass 11, errors 4) + the 4 WP2 smoke tests. Code fixes: 0. Spec fixes: 0.
  WP7–WP9 (`parity`, `regress`, `alloc`, `docs`) are not built yet and are not counted.
- 2026-09-16 — Valve latch (§4.2 (c) / §11): WP4's `_pass(self, serial, valveHits)` latch is the
  accepted resolution — `reentrancy_spec :: sync re-entry chain is bounded per pass …` is green
  (7 dispatches for Valve 4 / depth 3, bound 12). The design TEXT of §4.2 (c) and §11 still
  describes the per-pass valve without the latch; `docs/` is outside the integrator's writable
  set, so the wording correction stays open for Jake (no behaviour change is involved).
- 2026-09-16 — WP2's OracleProbe concern (default-Name counter advanced by the throwaway probe):
  verified no spec pins a `Veron<N>` default name (`grep -rn "Veron[0-9]" build/tests/spec` is
  empty), so no off-by-one is reachable.
- 2026-09-16 — `Clear()` return with attached/cascaded children: WP4 counts the children's handles
  (§2.2 "cascades to attached children; returns handles stopped"); `lifecycle_spec` (`>= own`)
  and `chain_spec` (`3..4`) both accept that reading, so the code stays as built.
- 2026-09-16 — `heapRemove` ownership → `false`, `heapUpdate` ownership → raise: WP4 code and
  `heap_spec` agree with §3.2/§4.3; the orchestrator brief's "update/remove" wording is not
  applied. `cannot chain a recurring event` stays unprefixed (§4.6 code) and outside
  `errors_spec`'s prefix assertion.
- 2026-09-16 — Stray `build/tests/scratch/wp5spec/` reported by the WP5/WP6 spec pass is already
  gone; no scratch directory exists at the end of this round.
- 2026-09-16 — Cosmetic only: eight reentrancy tests that deliberately re-enter `Update` or trip
  the valve let the default `Env.Warn` print `[WARN] [Veron T] …` lines into the runner output.
  §9 does not require silence and the tests pass; left untouched rather than editing green specs.

## WP9 — docs (`build/docs/API.md`, `build/docs/MIGRATION.md`, `spec/docs/docs_spec.luau`)

- 2026-09-16 — The "≤ 26 recur-nested files" of DESIGN §7.3 DV-7 / Q-J1 is not an explicit list
  in `research/callsites.md` (it gives the two examples and the P1/P2 patterns). The list was
  derived from the survey's raw dump `research/scratch/callsites/all_lines.txt` with the
  criterion: live-tier file (RoBase plugin and archive tiers excluded, wrapper/core module
  files excluded, commented-out lines excluded) that calls both `.recur(` and `.delay(` through
  the main wrapper (`TickAPI.` or its `TimeManagerAPI` alias). Result: 19 files (≤ 26): 12 with
  recur and delay on the SAME instance (the ones DV-7 can affect) and 7 mixed-instance files
  (cross-instance creation measures from the other instance's `Now()`, N5 — listed for review
  only). MIGRATION.md §4 shows both tiers with instance:line pairs and states that the survey is
  static (a callback reaching a `delay` through another module is invisible to it).
- 2026-09-16 — API.md's member tables restate §2.2/§2.3 with the private-field idioms removed
  (`_Fn = NOOP` is kept only where the design names it as the observable "callback released"
  effect; `PWC` is written as "pause-when-created flag"); every signature, error string and
  alias is verbatim. The §4.8 time-model paragraph and the §2.4 reuse paragraph are verbatim.
- 2026-09-16 — MIGRATION.md §3 carries the 20 §7.3 rows (DV-1…15, 17, 20, 21, 23, 24) and a
  one-line note that DV-16/18/19/22 were left with their scope, so a reader does not hunt for
  them; `docs_spec :: every DV of §7.3 appears in MIGRATION.md` asserts exactly those 20 ids
  with a digit boundary (`DV-1` is not satisfied by `DV-10`).
- 2026-09-16 — `docs_spec` reads the md files with `@lune/fs` relative to `process.cwd()`
  (= the workspace root, the same convention `env_spec` uses); member presence is checked as a
  whole identifier (`%f[%w_]…%f[^%w_]`) so `Id`/`Name` are real hits, and the rule sentences are
  checked as plain substrings of the wrapped text (line breaks included), which pins the
  wording, not just the words.
- 2026-09-16 (resume audit) — WP9 re-entered after the run's session limit: `API.md`,
  `MIGRATION.md` and `docs_spec` were already on disk. Audited against DESIGN §12 WP9 line by
  line (retention rule + footprint first, §4.8 paragraph verbatim, every §2.1/2.2/2.3 member,
  Recur third argument + `SetCatchUp`, three verbs incl. the Fired/Restart/Clear notes, §5
  matrix, not-per-frame list, `Now()` vs `GetBase()`, §2.4 patterns + reuse numbers, §6 wiring
  incl. the DV-23 guard; §7.1–7.4, 20 DV rows, M0–M3, 19-file DV-7 list, out-of-scope list) —
  nothing missing, nothing changed. Spot-checked three DV-7 rows (`EventSpawnerClass`,
  `EntitySurgeConductor`, `TowerOfTest`) against `research/scratch/callsites/all_lines.txt`:
  all exact. DESIGN §7.3 writes the EventSpawnerClass example as `406→345` (the start of the
  `:345-354` loop the survey quotes); the actual `Tick.delay(` line is `:346`, which is what
  MIGRATION.md and `docs_spec` pin — not a discrepancy to "fix". Suite: 245 passed, 0 failed.

## WP8 — alloc spec + bench (`build/tests/spec/alloc/alloc_spec.luau`, `build/bench/{bench,studio_bench}.luau`, `build/bench/BENCH.md`)

- 2026-09-16 — Zero-garbage measurement under Lune 0.10.5: `collectgarbage("collect")` does not exist
  ("invalid option"), so every window is a bare `collectgarbage("count")` delta. That is exact when nothing
  allocates (the collector only steps on allocation), so the idle, busy and warmed-GetStats/Validate tests
  assert `0` with no tolerance — and all three read 0 with the core as built (no measured non-zero number
  to record). Each window is preceded by one warm-up round run through the SAME helper from the same
  frame: the first dispatching `Update` issued from a new call frame can grow the interpreter stack once
  (1.6 KB seen when the warm-up ran from a different frame than the window); a same-frame warm-up removes
  it. The design's "warm GetStats(into) once before measuring" is honoured literally (one fill).
- 2026-09-16 — `one table per Delay`: the only window that allocates by design, so a collector step can run
  inside it; the test takes the MAX per-slot delta over ten 200-slot rounds (a round without a step reads the
  exact size) and compares `Delay` against a hand-built 14-key literal measured the same way. The literal
  measures **560 B** under Lune (48 B table header + 16 × 32 B nodes), not the 576 B §3.1 quotes (64 B header
  assumed); the assertion is `literal <= 576` (the 16-node hash part, no rehash) and `Delay == literal`.
- 2026-09-16 — Alloc tests run on RAW instances (`Oracle.wrap` packs results with `table.pack`, so a wrapped
  call can never read 0 B) and audit with `Oracle.check` outside the windows — same reading as the WP4-specs
  and lifecycle notes above.
- 2026-09-16 — `bench.luau`: invariant checks (sizes, counts, garbage == 0) fail the run (exit 1); timing
  targets are printed `met`/`MISSED` and never fail it (§10: reported, not asserted, under Lune). Targets are
  the IB block of `research/scratch/algos/bench-run3.txt` × the §10 factor. P13 does not exist (stable phase
  ids). Per-handle sizes (the P1 literal) use the alloc_spec max-over-short-rounds method because a 10k
  batch window once read "0 B/handle" after a collector step; P8's garbage is printed as
  "net growth (max rep)" for the same reason. (Superseded 2026-09-17: P11 — the handle-literal vs BaseClass
  `Class:new` construction comparator, a bench-local 12-field `VeronBenchEvent12` root class — was removed
  with the BaseClass dependency; the bench now runs 20 invariant checks, no BaseClass require.)
- 2026-09-16 — P14 legacy adjust uses `h.delay` (the legacy total) and liveness `group[h] == true`; P14 is
  skipped with a one-line notice when no legacy module is available (Studio after M1).
- 2026-09-16 — `studio_bench.luau` = a Roblox header (ReplicatedStorage requires, optional legacy `Tick`
  under TickAPI via `FindFirstChild`, `Exit` raises on failed invariants) + the bench body copied verbatim
  from `bench.luau` from the `-- ==== BODY` marker on (regenerate by concatenation; never edit the body
  there). It refuses to run outside Roblox with a clear error (`typeof(game) ~= "Instance"`), which is how
  it "loads" under Lune. The `<native>` Script Profiler check is a manual step the header documents.
- 2026-09-16 — Measured and recorded in BENCH.md (all 21 invariant checks pass; three runs): P1 397 ns/op
  (target 300 MISSED — validation + `coroutine.running()` + dual closure + literal build, §4.1 costs), P2
  0.046 µs/update at 0 B (clock-resolution miss of the 0.04 target; garbage exactly 0), P6 328 ns/dispatch
  (met), P7 65 µs/update 0 B, P8 29.5 µs/update (28.75 MISSED by 3 %, within the prototype's own spread),
  P10 dual-call +44…+58 ns (30 MISSED: the D15 vararg shim costs ~45 ns in the interpreter; a fixed-arity
  closure would be a design change, not applied), P11 ratio 0.17 (met), P12 within noise, P15 ~6–7 KB per
  instance. Legacy: idle ~3100×, P7 2.4×, P8 8.0× faster per update.

## WP7 — parity + repros (`build/tests/spec/parity/parity_spec.luau`, `build/tests/spec/regress/repros_spec.luau`)

- 2026-09-16 — Harness shape: one `_run(adapter, steps)` interprets the gen.luau step schema against
  a legacy adapter (`Legacy.group()`) and a Veron adapter (`Oracle.wrap(Veron.new{ Name = "T" })`);
  a `nest` step is registered per parent id and CREATED from inside that parent's callback (as the
  prior build's harness did), so the arm carries the sub-frame error on both sides. Per update the
  sorted fired-id list is compared; a mismatch names the seed, update ordinal, step index, dt,
  both lists and the generator's own `expect`. Every Veron instance in both files is oracle-wrapped
  (the 500-sequence runs included; the whole parity file runs in ~23 s under Lune).
- 2026-09-16 — `500 seeded op sequences match` uses seeds `20260916 + i`, i = 0..499, 200 steps
  each, the generator's DEFAULT constraints (dts 1/64 and 1/32, no lagLimit) and `Recur(fn, p,
  true)`. The raw generator never targets an uncreated handle on those sequences (asserted).
- 2026-09-16 — `default cap generator (never lags > 8 periods) matches` widens the dts to
  {1/64, 1/32, 1/8, 1/4} with `lagLimit = 8` and arms `Recur(fn, p)` (capped); 14 079 of its
  51 228 updates owe a recurring more than one fire (asserted > 0). Generator gap found and
  handled in the HARNESS (gen.luau is WP2's file): the generator keeps chained/nested delays above
  every dt at creation (DV-2) but its `adjust` step can halve an UNARMED `after` child below the
  parent's overshoot; legacy then appends the child unvisited (fires next update) while Veron
  dispatches it later in the same update — the DV-2 class, not a core bug (seed 20261067, update
  30: legacy [1,14,17], Veron [1,9,14,17], the generator's own `expect` agreeing with Veron).
  `_sanitize(steps, maxDt)` drops such adjusts (31 of 100 000 steps over the 500 sequences) and,
  because a dropped step desyncs the generator's model (a nest under that child is created
  later than the model believes), `_run` skips a step whose handle does not exist yet on BOTH
  sides and the test asserts both sides skipped the same count. The default-dts run needs neither.
- 2026-09-16 — Test naming: the three names §9 spells out (`DV-7: legacy 2.500, new 1.517,
  LegacyRecurBase equals legacy`; `DV-14: legacy and new both advance 2 s on a 2 s dt, MaxDt =
  0.25 advances 0.25`; `DV-24: delay(fn, true) legacy 'CurrentType: nil', new 'CurrentType:
  boolean'`) are verbatim; the other 17 pins follow the same `DV-n: legacy …, new …` shape and
  are kept under the 120-col hard limit. `9 scripted prior scenarios match` carries nine explicit
  step lists in the gen schema (delay / recur / after / stop / reset / adjust / nest all covered).
- 2026-09-16 — DV-7 at 1/60: legacy fires the nested delay on frame 150 (2.500), Veron on frame
  91 (1.517), `LegacyRecurBase = true` on frame 151 (2.517) — the knob lands one frame after
  legacy because the two axes disagree on the 1/60 boundary (the DV-11 class, B-20), so "equals
  legacy" is asserted within one frame at 1/60 AND exactly (2.5 == 2.5, new 1.5) on a 1/64 clock.
- 2026-09-16 — DV-9's legacy side: the research note "expected 1, got 0" in exp1_swap.luau 1b
  describes the timer BEFORE the second fire; after `update(1)` the shim reports `fires == 2` and
  `E.timer == 1` (re-armed after the double fire). The pin asserts the observed values.
- 2026-09-16 — DV-12's legacy side uses the shim module's process-wide default group
  (`Legacy.Tick:getClocks()` → 0 with a live event, `Legacy.Tick.getClocks()` raises); the
  probe handle is removed afterwards. DV-3 likewise leaves one `group[bound] = false` key in that
  default group (the legacy leak itself) — harmless, no other spec reads it.
- 2026-09-16 — `F5` / `F6` are read as the legacy-bughunt ids (recur period 0 hangs; adjust on a
  delay-0 event makes a NaN zombie — the DV-4 family), since §9 cites `L-`/`F-` as legacy-bughunt;
  the semantics-spec rows of the same names (F5 "Complete on a later same-frame entry fires
  once", F6 "Complete from own callback returns false") are folded into the same two tests so
  either reading is pinned.
- 2026-09-16 — `B-14` pins the DESIGN's value (a Chained child's `GetRemaining()` is its own delay,
  §5), not the research's suggested fix (parent remaining + delay). `B-03` and `L-01` are the
  DV-7 decision seen from the repro side (dyadic, exact). `L-05` is the in-order yield overlap
  (frame 2 completes before frame 1 resumes): frame 2 RESTORES the suspended dispatch's base, so
  the post-resume arm measures from the yielder's due (1/2) and is dispatched by the resumed
  pass; the out-of-order case is `reentrancy_spec`'s.
- 2026-09-16 — Callbacks never assert: every test records what a callback observes and asserts
  outside it (a raise inside a callback is swallowed as a callback error).
- 2026-09-16 — Core bugs found: none. Both files green on the first full run; whole suite
  `278 passed, 0 failed`. A pre-existing `build/tests/scratch/wp7/` (an earlier probe set) was
  removed together with this package's own scratch files.

## Final integration (whole-suite integrator, WP7–WP9 included)

- 2026-09-16 — Result: `lune run build/tests/run.luau` → `278 passed, 0 failed` on the first run.
  Fix cycles used: 0 of 6. Code fixes: 0. Spec fixes: 0. The four WP7–WP9 files also pass alone
  through `run_one` (parity 24, regress 33, alloc 4, docs 9; support 4), so the suite stays
  order-independent.
- 2026-09-16 — Inventory vs §9 (mechanical diff of every backticked name in the §9 table against
  the runner's `file::name` list): all 221 named tests present byte-for-byte, 20 DV pins present
  (DV-1…15, 17, 20, 21, 23, 24 — the three §9 spells out verbatim, the other 17 in the same
  `DV-n: legacy …, new …` shape), 33 repro ids present; 19 spec files as planned plus the WP2
  smoke file `support/support_spec` (4 tests, outside §9's count). Nothing missing, nothing renamed.
- 2026-09-16 — Bench: `lune run build/bench/bench.luau` → `bench: 21 invariant checks, 0 failed`.
  Timing targets missed under the Lune interpreter (P1, P2, P8, P10) are reported, not asserted
  (§10); BENCH.md explains each. No code change made for them.
- 2026-09-16 — Stage D blockers: none were raised by WP7, WP8 or WP9 (each reported `blockers: []`);
  their deviations are carried unchanged into BUILD-REPORT.md.
- 2026-09-16 — Housekeeping: an empty `build/tests/scratch/` directory (left after the WP7 scratch
  files were deleted) was removed; `build/tests/` now holds only `run.luau`, `run_one.luau`,
  `spec/`, `support/`. No other file was touched.
- 2026-09-16 — Still open for Jake (docs/ is outside the build's writable set): the §4.2 (c) / §11
  valve wording (the built `_pass(self, serial, valveHits)` latch is the accepted behaviour, see
  "Integration round 1"), the §3.1 "576 B" figure (measures 560 B under Lune), and the §7.3 DV-7
  example line `EventSpawnerClass:406→345` (the `Tick.delay(` line is 346).

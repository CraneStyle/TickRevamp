# TickRevamp — DESIGN (final, authoritative) — Veron only

> **SUPERSEDED IN PLACES — read this first (banner added 2026-09-17).** This document is the design AS
> DECIDED, written before the BaseClass dependency was dropped. On 2026-09-16 Jake dropped BaseClass/
> middleclass: `Veron` and `VeronEvent` are now **plain typed Luau modules** — each module table is its own
> instances' metatable (`Module.__index = Module`), with a `.new` factory, a `__call` for the `Veron(cfg)`
> form, and a forward-declared `_construct` local. The observable surface is unchanged
> (`class`/`type`/`isInstanceOf`, refused direct construction, the colon guard, the legacy aliases). So
> wherever the text below still says **"BaseClass root class"**, **`Veron.static.new`**, **`BaseClass.class`**,
> **`BaseClass __call` / vendor `Lxx`**, **`Class:new`**, **`VeronEvent.__instanceDict`**, **`.static.`**, or a
> **vendored `build/vendor/BaseClass.luau`**, read it as the historical BaseClass-era mechanism — the shipped
> source under `build/src/Veron/*` and the tests are authoritative for how it works now. Concretely today:
> `Env` exposes **5** keys, no `BaseClass`; the vendored file and its two `env_spec` vendor-diff tests are
> **gone**; bench **P11** (the handle-literal vs `Class:new` comparator) was removed 2026-09-17, so the bench
> runs **20** invariant checks; the class-mechanics spec was renamed **`baseclass_spec` → `class_spec`**
> (`build/tests/spec/class/class_spec.luau`). Live state: `HANDOFF.md` / `HISTORY.md`. Everything else here —
> heap, clock, arms, catch-up, valve, re-entrancy, chains, complete, API, parity, migration — stands as the
> live spec.

Winner "stable" (docs/design-candidates/stable.md) with the judges' grafts applied, every listed defect fixed, and Jake's 2026-09-16 scope, naming (Veron, A9) and touch-pattern (A10) decisions applied in place.
Cites: `D1–D24`/`Q-J` = docs/DECISIONS-BRIEF.md; `SEM <row>` = research/semantics-spec.md; `ALG §` = research/scheduler-algorithms.md;
`L-`/`F-` legacy-bughunt; `B-`/`RF` prior-build-review; `S-` syncedtimer-review; `CS` callsites; `RT` roblox-timing; `BC` baseclass-conventions.
Every settled decision is taken as given. Implementers build each module from THIS file alone (§12 work packages).

Scope (Jake, 2026-09-16):
1. This document specifies ONE class, `Veron` (Jake's name for the new build, A9/Q-J17) — the instance built once per event hook (`TickAPI.Tick = Veron.new{ Name = "Tick" }`) and driven by `TickAPI.Tick.update(dt)` — plus its handle class `VeronEvent` and the `Env` seam.
2. TickAPI's own wrapper (`ReplicatedStorage.SharedModules.TickAPI`) keeps doing the wiring: it requires `Veron`, builds the instances `Tick`/`Tickh`/`Tickr` (the FIELD names stay — 300+ callers use `TickAPI.Tick.delay`), owns the RunService connections, and keeps `SafeStopClock` and `AfterNotTouchedClass` unchanged (§6).
3. No registry, no RunService binding, no keyed timers, no memory category and no AfterNotTouched class live here — they are TickAPI's concern or out of scope (§8, §11).
4. Everything else the design decided (heap, clock, arms, catch-up, valve, re-entrancy, chains, complete, pause/resume, retime, attach/drive, stats, validate, parity, repros, alloc, bench, docs) is kept as decided.
5. Jake's A10 touch patterns (Q-J18): the handle gains `Toggle()` and `Restart()` (§2.3, §2.4, §4.4, §5); `Restart()` is the ONE way a Fired handle runs again (it takes a fresh `Id`, so the valve bounds a self-restart, §4.4), an explicit `Stop` on a Fired handle finalizes it (§4.3) and Stopped stays final; API.md carries the reuse-over-recreate rule (§2.4, WP9).

Structural rules (from "stable", kept):

| Rule | Consequence |
|---|---|
| **R-A One mutation authority.** Every heap/state write is a file-local function or `_PascalCase` method of `Veron`; `VeronEvent` methods are `guard → self._Scheduler:_Op(self, …)`. | One file to audit; the invariant oracle (`Validate()`, §4.11) wraps one module. |
| **R-B Finalize before, bookkeeping only after.** Pop / re-key / arm-children / mark-terminal happen BEFORE `xpcall`; after it only `_Base/_Firing` restore and stats. Every terminal handle gets `_Flags = 0`, `_HeapIndex = 0`; a Stopped handle also gets `_Fn = NOOP`; a Fired handle KEEPS `_Fn` — it is out of the heap, the paused set and every chained list, so nothing but the explicit `Restart()` (§4.4) can run it — until an explicit `Stop` finalizes it (`_Fn = NOOP`, §4.3). | A callback's own stop/reset/adjust/pause/complete always wins (D3); no RF-010 class; a terminal handle is never resurrected by reset/adjust/resume/after/complete; `Restart()` is the one explicit re-arm of a Fired handle and `Stop` the one way to finalize it; Stopped is final. |
| **R-C Re-entrancy is a depth counter, never a flag.** A nested (sync) or overlapped (yield) `Update` on the same instance runs a REAL pass while `_UpdateDepth < MaxUpdateDepth` (8), else advance-only. The counter is decremented on exit, never restored to a saved value; `_Base/_Firing/_FiringThread` are cleared when depth reaches 0 with no `CompleteNow` in flight (`_SyncDepth == 0`), else restored to the values saved at entry. | Yielding callbacks never stall sibling timers (L-05 parity); a recurring callback calling `Update(period)` is bounded at 8; out-of-order yield completion leaves depth 0 and `_Base == false`. |
| **R-D The base carry belongs to the firing thread.** `_Base` is read only through `_clockOf(self)` (§4.1), which yields `_Base` only when `coroutine.running() == _FiringThread`; every other thread (a RemoteEvent handler, another RunService handler, `task.spawn` from a callback) measures from `_Now`. The own-callback guards of `Complete/CompleteNow` use the same predicate. | A callback that yields for seconds cannot anchor top-level arms to a stale due (L-05 class); the carry is per dispatch AND per thread, not instance-wide state. Cost: one `coroutine.running()` per ARM, never per update. |

## 1. Object model + file layout

```
build/src/Veron/init.luau                --!native plain typed module, class "Veron" (the scheduler)  → Env, VeronEvent
build/src/Veron/VeronEvent/init.luau     plain typed module, class "VeronEvent" (the handle)         → Env
build/src/Veron/Env/init.luau            platform seam (plain table)                                 → (no dependency; BaseClass dropped 2026-09-16, see the banner)
build/tests/support/{oracle,legacy,gen}.luau   (no `_spec` suffix: the runner skips them)
build/tests/spec/<area>/<name>_spec.luau       §9;  build/bench/{bench,studio_bench}.luau  §10
build/docs/API.md, build/docs/MIGRATION.md     §7/§9 docs specs assert coverage
```

Roblox install target: ModuleScript `ReplicatedStorage.SharedModules.TickAPI.Veron` with children `VeronEvent` and `Env`; the legacy `Tick`, `Tick2`, `Tick3` ModuleScripts under `TickAPI` are deleted at M1 (§6).

| Module | Kind | Responsibility | Exports (cross-module contract) |
|---|---|---|---|
| `Env` | plain table | ONLY module that touches `game`. `IsRoblox: boolean` (= `typeof(script) == "Instance"`); `Warn(msg)` (default `warn`); `Traceback` (= `debug.traceback`); `Load(name)` (a sibling of `Env`: `require(script.Parent[name])` on Roblox / `require("./" .. name)` under Lune); test seam `SetWarn(fn) → restore()` (scoped, restorable; fixes B-12). Nothing else: no RunService, no `IsServer/IsClient`, no memory category, no `BaseClass` key (dropped 2026-09-16 — see the banner; env_spec pins exactly these 5 keys). | everything above |
| `Veron` | plain typed module, class `"Veron"` (module table is its own instance metatable, `.new` factory) | arrays `_Due/_Item`, virtual clock, arm, dispatch, catch-up, valve, stop cascade, pause/resume, retime, chains, complete, attach/drive, destroy, stats, `Validate`, dual dot/colon closures installed in `initialize`. | class; private `_Op` methods `VeronEvent` calls (§4.10) |
| `VeronEvent` | plain typed module, class `"VeronEvent"` | the handle: 14-key literal (§3.1) + `setmetatable(t, VeronEvent)`; colon-guarded thin methods; LEGACY SURFACE region. Never touches the heap. Direct construction is refused: `VeronEvent:new()`/`VeronEvent()` raise `error("VeronEvent: handles are created by a Veron (Delay/Recur/After)", …)` — so they can never yield a 2-key orphan whose first method call dies with a raw index-nil (the §3.1 literal is the single field list). | class (used as the handle metatable by `Veron`), `VeronEvent.STATE_NAMES` |

Loading (W/CLAUDE.md Lune rules: inside an `init.luau`, `./` is the directory that CONTAINS the module directory). `Veron/init.luau`: `local Env = if typeof(script) == "Instance" then require(script.Env) else require("./Veron/Env")` and `local VeronEvent = if Env.IsRoblox then require(script.VeronEvent) else require("./Veron/VeronEvent")` (`./` there is `build/src/`). `VeronEvent/init.luau`: `require(script.Parent.Env)` / `require("./Env")` (`./` there is `build/src/Veron/`). `Env/init.luau` loads no external dependency (BaseClass was dropped 2026-09-16 — see the banner; the historical vendor-require note that stood here is removed). `Env.Load(name)` resolves relative to `Env/init.luau`, so `Load("VeronEvent")` works from any caller (tests included). All modules `--!nonstrict`; only `Veron` is `--!native` (D24). No cycles: `VeronEvent` reaches its owner only through `self._Scheduler`; `Veron` uses `VeronEvent` itself as the handle metatable (read once at load). Each module table doubles as its own instances' metatable (`Module.__index = Module`) with a `.new` factory and a `__call` for the `Veron(cfg)` form; on Roblox the ModuleScripts are named `Veron`/`VeronEvent`/`Env` on purpose: `require(script.Veron)` from TickAPI.luau IS the class export. On Roblox the ModuleScripts are named `Veron`/`VeronEvent`/`Env` (not `<Name>Class`) on purpose: `require(script.Veron)` from TickAPI.luau IS the class export.

BaseClass usage (D13/BC): two root classes, unique prefixed names, no mixins, no declared `__index`, **no `__tostring`** (BaseClass `Class:new` sets `instance.type = tostring(instance)`, vendor L183 — a custom `__tostring` would corrupt `.type`; rich strings come from `Describe()`), never subclassed. Handles are literal-built; `h:isInstanceOf(VeronEvent)`, `h.class == VeronEvent`, `h.type == "VeronEvent"` hold. Constructor spellings (Q-J9): `Veron.static.new` is overridden with `local baseNew = Veron.static.new; Veron.static.new = function(self, cfg) if self ~= Veron then cfg = self end return baseNew(Veron, cfg) end` so `Veron:new(cfg)`, `Veron.new(cfg)`, `Veron(cfg)` all run one `initialize`. Nothing registers the instance anywhere; `Name` is a label for `Describe()` and diagnostics.

## 2. Public API reference

Error contract. The **validation family** is unprefixed: the legacy TEMPLATES of `reference/live/Tick.luau:168-174` byte-identical — except that the `CurrentType: ` suffix reports `typeof` of the caller's ORIGINAL argument (D10/L-17; legacy printed `type()` of the `tonumber`-coerced value, i.e. `nil` for `{}`/`true`, `userdata` for an Instance — pinned two-sided as DV-24) — plus the prior strings (`expected recur \`delay\` greater than zero`, `expected \`newTotal\` greater than zero`, `expected \`newPeriod\` …`) and exactly three extensions in the same voice: `expected \`delay\` to be a finite number`, `expected \`remaining\` of zero or greater`, `expected \`uncapped\` to be a boolean`. Every OTHER new error starts with `Veron '<Name>': ` or `VeronEvent: ` (config errors, raised before `Name` is settled, use the bare `Veron: ` prefix). Error LEVEL = number of library frames between `error` and the user's line + 1, so the message blames the caller: instance public methods are reached through a dual closure (+1 frame) → a method body raises at level 3, a helper called from a method body at level 4 (helpers take a trailing `level` argument); handle methods raise at level 2, instance `_Op` methods they call at level 3, helpers under those at level 4. **Internal callers never go through a dual closure**: `Drive` calls `_validateUncapped(uncapped, 4)` and `_attach(self, child, 4)` — the level is always passed explicitly. `initialize` raises at level 4 (frames: `initialize` ← `baseNew` ← static `new` override ← user), so `Veron:new{…}` and `Veron.new{…}` sites are blamed. Documented exception: `Veron(cfg)` (BaseClass `__call`, vendor L91) adds the `_call` frame, so a config error there blames `BaseClass.luau`. `errors_spec :: every error blames the caller's chunk (level table §2, incl. cfg via new, Drive→Attach, Drive/Recur→uncapped; Veron(cfg) is the documented exception)` pins the table including the exception. Retention rule (top of API.md, D20/O4): the instance holds handles strongly until terminal — a recurring timer never dies unless stopped, a Paused handle is retained until resumed/stopped, a Chained child lives as long as its parent.

### 2.1 `Veron` constructor / config (validated in `initialize`; unknown key first)

| Key | Type / range | Default | Notes |
|---|---|---|---|
| `Name` | string | `"Veron" .. n` (module counter) | label only; nothing registers it |
| `TimeScale` | finite number ≥ 0 | `1` | `0` freezes |
| `MaxCatchUp` | integer ≥ 1 | `8` | fires per CAPPED recurring handle per pass (Q-J8); `Recur(fn, p, true)` / `h:SetCatchUp("all")` opt a handle out |
| `Valve` | integer ≥ 1 | `1000` | runaway valve (D5): counts nested arms AND uncapped repeats; a handle's first fire in a pass is never a repeat, so one lagging uncapped handle delivers `Valve + 1` fires per pass and trips on the next (§4.2 f); a `Restart()` of a Fired handle takes a fresh `Id`, so a self-restarting zero-period one-shot counts as a nested arm (§4.4) |
| `MaxDt` | number > 0 or `false` | `false` | Q-J16: off by default; when a number, `Update(dt)` clamps dt to it AFTER validation and counts `ClampedDt` |
| `MaxUpdateDepth` | integer ≥ 1 | `8` | re-entrant passes at this depth are advance-only (R-C) |
| `OnError` | `"warn" \| "error" \| function(message, handle)` | `"warn"` | D11 |
| `Strict` | boolean | `false` | `true`: `Stop/Remove(non-handle)` errors (Q-J5) |
| `LegacyRecurBase` | boolean | `false` | Q-J1 A/B knob: base of a recurring dispatch = `d + period` (reproduces L-01) |

Errors: `Veron: unknown option '<k>'`; `Veron: option '<k>' expects <what>, got <v>`. Removed on purpose: `Hook` (TickAPI connects the signal), `CatchUp` mode string (the instance holds only the cap number; `"all"`/`"drop"` are per handle), `MemoryCategory` (Q-J10).

### 2.2 `Veron` members (every public entry dual dot/colon, D15; `s` = instance)

| Member | Signature → return | Semantics | Errors (prefix `Veron '<Name>': ` unless legacy) | Alias |
|---|---|---|---|---|
| `Update(dt)` | `→ nil` | `type(dt)` checked FIRST; `destroyed` check; `MaxDt` clamp when set (`ClampedDt += 1`); `_LastDt = dt`; instance-paused → advance nothing; else `now += dt × TimeScale` and dispatch (§4.2). THE way a Veron is driven (Q-J11): TickAPI's RunService connection calls it once per frame; tests and `Drive` pumps call it directly | `Update(dt) expects a finite number >= 0, got <v>`; `destroyed` | `update` |
| `UpdateTo(t)` | `→ nil` | absolute clock (§4.8); first call anchors, never sweeps; backwards → clamp + count, warn once if > 1 s | `UpdateTo(t) expects a finite number, got <v>`; `destroyed` | |
| `Now()` / `SetTimeScale(x)` / `GetTimeScale()` | `number / nil / number` | virtual clock; `SetTimeScale` re-anchors `_Offset` when `_LastAbs` is set | `option 'TimeScale' expects a finite number >= 0` | |
| `Pause()` / `Resume()` / `IsPaused()` | `nil / nil / boolean` | instance freeze: `Update(dt)` (including `Update(0)`) and the first anchoring `UpdateTo` advance NOTHING and dispatch nothing; `UpdateTo` folds the gap into `_Offset`; a deferred `Complete()` therefore waits for `Resume()` (use `CompleteNow` for an immediate fire) | | |
| `Delay(fn, t)` | `→ VeronEvent` | one-shot at `_clockOf(self) + t` (§4.1: the firing due inside the firing thread, else `_Now`; D4/R-D) | legacy strings (§4.1); `destroyed` | `delay` |
| `Recur(fn, p, uncapped?)` | `→ VeronEvent` | recurring. `uncapped` is a boolean, default `false`: `false`/nil → catch-up capped at the instance `MaxCatchUp` per pass, remainder dropped on-grid (phase kept, `Dropped` counted); `true` → every owed fire happens, valve-bounded per pass (the timer stays keyed at its due, so the rest fires on the next update — NOTHING is lost, only spread) and still sub-resolution-guarded (§4.2). Any other type raises BEFORE any mutation (§4.1) | legacy + `expected recur \`delay\` greater than zero`; `expected \`uncapped\` to be a boolean`; `destroyed` | `recur` |
| `DelayAt(fn, absDue)` | `→ VeronEvent` | one-shot at an absolute time on the `UpdateTo` axis (§4.8); callback-first like every other arm | `DelayAt needs UpdateTo to have been called at least once` | |
| `Stop(h)` | `→ boolean` | handle only: `nil`/non-handle → `false` (`Strict` → error); foreign → error; `true` iff a LIVE handle became Stopped — a Fired handle is finalized silently (→ Stopped, `_Fn = NOOP`, no container op, §4.3) and returns `false` | `event #<id> belongs to Veron '<Y>', not '<X>'`; Strict: `expected a VeronEvent, got <t>` | `Remove`, `remove` |
| `Complete(h, opts?)` / `CompleteNow(h, opts?)` | `→ boolean` | §4.7; `opts = {Stop = true}` (PascalCase; `_checkOpts`); nil/non-handle/terminal → `false` | foreign error as `Stop`; `unknown option '<k>' in Complete` | `ForceEventComplete` (= `Complete`) |
| `GetRemaining(h)` | `→ number?` | owner-agnostic query, never raises: any handle → `h:GetRemaining()`; nil/non-handle → `nil` even under `Strict` (never 0, S-09) | never | |
| `GetClocks()` | `→ number` | `_N + _PausedCount` (Pending + Paused; not Chained, D20) | | `getClocks` |
| `GetStats(into?)` | `→ table` | fills `into` or a fresh table: `Name, Destroyed, Now, TimeScale, IsPaused, Pending, Paused, Chained, Recurring, HeapSize, Clocks, Updates, LastDt, Dispatched, LastDispatched, Reentries, UpdateDepth, Dropped, ValveHits, ClampedBackwards, ClampedDt, Errors, ErrorsSuppressed, Children` — every value an O(1) counter (`Children` = `_ChildCount`); zero-alloc ONLY when the SAME `into` table is reused (the first fill sizes its hash part; `alloc_spec` warms it once before measuring) | | |
| `Validate()` | `→ true \| false, reason` | O(n) invariant oracle (§4.11); never raises | | |
| `Describe()` | `→ string` | `Veron<Tick now=12.300 pending=40 paused=2>` | | |
| `SetOnError(p)` / `SetMaxCatchUp(n)` / `GetMaxCatchUp()` / `SetValve(n)` / `SetMaxDt(x)` / `SetStrict(b)` | `→ nil` (`GetMaxCatchUp → n`) | live reconfiguration (§4.9), same validation as construction; `SetMaxCatchUp` changes the cap every inheriting handle uses from the next pass (per-handle overrides untouched); `SetMaxDt(false)` disables the clamp | `option '<k>' expects <what>, got <v>` | |
| `Clear()` | `→ number` | stops Pending, Paused and Chained alike (D18) with terminal WRITES only (no heap ops during the walk, §4.3), cascades to attached children; returns handles stopped; legal mid-update; a Fired handle is in no container, so `Clear` never reaches it (§11: an explicit `Stop` finalizes it) | | |
| `Attach(child)` / `Detach(child)` / `GetChildren()` | `nil / boolean / {Veron}` | ownership (D17): attached children are Cleared/Destroyed with the parent; single parent; `child:Destroy()` detaches itself; `_ChildCount` maintained; `GetChildren` is a snapshot (allocates; not per-frame) | `Attach expects a Veron, got <t>`; `cannot attach itself`; `'<C>' is destroyed`; `'<C>' is already attached to '<P>'`; `Attach would create a cycle` | |
| `Drive(child, period, uncapped?)` | `→ VeronEvent` | recurring pump `child:Update(period)` that stops itself once the child is destroyed; ALWAYS attaches (so a mutual `Drive` is refused as a cycle); `uncapped` defaults to `true` — a lossless sub-clock: after a parent hitch every owed `period` reaches the child, valve-bounded; `false` accepts lost child time | `Drive expects another Veron`; `expected \`uncapped\` to be a boolean`; `Recur`/`Attach` errors | |
| `Destroy()` / `IsDestroyed()` | `nil / boolean` | §4.9; no options; dead FIRST, then `Clear`, destroy attached children, detach from the parent; legal from inside its own callback (N4); twice is a no-op | never | |
| `IsUpdating()` / `GetBase()` | `boolean / number \| false` | `_UpdateDepth > 0` / the ideal due the CALLING thread's arms measure from (`_clockOf` minus the `_Now` fallback: `false` outside a firing thread). `Now()` is always the real clock; inside a callback `Now() ~= GetBase()` by the sub-frame overshoot | | |
| `Name` | public string field | | | |

After `Destroy`: `Update/UpdateTo/Delay/Recur/DelayAt/Attach/Drive` raise `destroyed`; `Stop/Complete/CompleteNow/GetRemaining/GetClocks/GetStats/Validate/Describe/Clear/Detach/Destroy/Pause/Resume/Set*` stay total (`false`/`nil`/`0`/no-op); every handle method stays total too — `h:After(fn, t)` on a handle of a destroyed instance returns a born-Stopped child (§4.6), never `destroyed`.

### 2.3 `VeronEvent` handle (colon-only; every method total on terminal handles, D8)

Guard (first line of every method): `if getmetatable(self) ~= eventDict then error("VeronEvent: methods take a colon: event:Stop(), not event.Stop()", 2) end`. Callback signature: `fn()` — no arguments (D19 surface byte-for-byte).

| Member | → return | Semantics (matrix in §5) | Errors (level 2 / delegated level 3) | Alias |
|---|---|---|---|---|
| `Stop()` | nothing | terminal Stopped; on a Fired handle too (finalizes it: `_Fn = NOOP`, `Restart()` refused from then on — the `SafeStopClock`-after-fire path, §4.3); cascades to Chained children; idempotent; owner-agnostic | never | `stop`, `Destroy` |
| `Reset()` | `h` | full period from `now` (D9); no-op while COMMITTED (STOP_ON_FIRE or REPAUSE set, §4.4) | never | `reset` |
| `Adjust(x)` | `h` | ratio-preserving retime from `now` (D9); `tonumber` coercion; no-op while COMMITTED. Terminal check BEFORE argument validation: `firedHandle:Adjust(0/0)` is a silent no-op (JF-01: `UpdateAction_ActionServerHitScan:452-462` adjusts a usually-fired strike handle with a speed-divided value) | `expected \`newTotal\` greater than zero` (non-terminal only) | `adjust` |
| `After(fn, t)` | child `VeronEvent` | chained child; never returns the parent (D8); on a Stopped parent or a destroyed instance → born-Stopped child WITHOUT argument validation (total) | `cannot chain a recurring event`; legacy arg strings (Pending/Paused/Chained/Fired parents only) | `after` |
| `SetPeriod(p)` / `GetPeriod()` | `h` / number | future arms only; terminal → no-op before validation | `expected \`newPeriod\` greater than zero` (recur) / `of zero or greater` (one-shot) | |
| `SetRemaining(x)` / `GetRemaining()` | `h` / number ≥ 0 | "x more seconds" from now, period untouched (S-12); instance-seconds (R9); terminal/COMMITTED → no-op before validation | `expected \`remaining\` of zero or greater` | |
| `Pause()` / `Resume()` / `IsPaused()` | `h` / `h` / boolean | freeze/thaw the current cycle; Chained → PWC flag (A8); `Resume` on a Pending+REPAUSE handle clears REPAUSE (fires, then runs on); `IsPaused()` is `true` for Paused AND for Pending+REPAUSE (a deferred Complete on a Paused recurring stays logically paused; `GetState()` reads the transient `"Pending"`) | never | |
| `Toggle()` | `h` | the recur switch (Q-J18): Pending (plain) → `_Pause`; Paused → `_Resume`; Chained → flip PWC; Pending+COMMITTED, Fired, Stopped → no-op | never | |
| `Restart()` | `h` | the ONE explicit re-arm of a **Fired** handle: → Pending at `now + period` (from `_Now`, D4; a Fired recurring re-arms as recurring; `_Fn` was kept, R-B); Pending/Paused → `Reset()` then `Resume()` (full period from now, running; COMMITTED → no-op); Chained → no-op; **Stopped → no-op (final; `SafeStopClock` semantics untouched: a post-fire `stop()` makes the handle Stopped, never restartable)**; destroyed Veron → no-op; the Fired re-arm takes a fresh `Id` (valve-countable, §4.4) | never | |
| `Complete(opts?)` / `CompleteNow(opts?)` | boolean | §4.7; `opts.Stop` ends a recurring after the forced fire; `opts` must be nil or a table with only `Stop` (`_checkOpts`) | `Veron '<N>': unknown option '<k>' in Complete` | (none: `ForceEventComplete` lives on the instance) |
| `SetCatchUp(mode, n?)` | `h` | per-handle override, recurring only (one-shot/terminal no-op before validation): `"cap", n` (n nil → snapshot of the instance cap) / `"all"` / `"drop"` / `"inherit"` (§4.1) | `Veron '<N>': option 'CatchUp' expects cap, all, drop or inherit`; `option 'MaxCatchUp' expects an integer >= 1, got <n>` | |
| `GetState()` / `GetStateId()` | string / number | `"Pending"…"Stopped"`; inside its own callback a one-shot already reads `"Fired"` (SEM S1) | | |
| `IsActive()` / `IsRecurring()` / `GetId()` / `GetScheduler()` / `Describe()` | | `IsActive` = Pending/Paused/Chained; `Describe()` → `VeronEvent<Tick#42 recur 0.5s Pending>` | | |
| `Id` | public integer | ascending per instance from 1, never reused; the equal-due tie-break (D23); re-issued by `Restart()` of a Fired handle (the handle is out of the heap at that moment; `GetId()`/`Describe()` show the new number) | | |

### 2.4 Touch patterns (Jake, A10 / Q-J18) and the reuse rule

| Pattern | Build it as | Notes |
|---|---|---|
| reset-after-touched | `h = s:Delay(fn, t)`; `h:Reset()` on every touch; `h:Stop()` on destroy | TickAPI's `AfterNotTouchedClass` stays a ten-line class over exactly this (§6); once Fired, `h:Restart()` arms the same window again |
| recur-till-touched | `h = s:Recur(fn, p)`; `h:Pause()` on touch | `h:Resume()` runs on from the frozen remaining, `h:Restart()` from a fresh full period (`h:Reset()` alone only refills the frozen remaining); a paused recurring accumulates nothing (§4.4) |
| recur switch | `h = s:Recur(fn, p)`; `h:Toggle()` on every touch | one touch stops, the next starts; `IsPaused()` reads the switch |

Reuse over recreate (carried verbatim into API.md, WP9; `docs_spec :: API.md states the reuse-over-recreate rule with the 576 B / 0 B numbers`): a new handle costs one 576 B table plus a heap push (~250 ns under Lune, ALG P1); `Reset/Restart/Pause/Resume/Toggle` on an existing handle cost one heap move (~100–300 ns, ALG P3–P5) and 0 bytes. Rule: hold the handle and reuse it whenever the same thing repeats; recreate only when the owner is gone. At 10k timers/s recreating produces ~5.8 MB/s of garbage (BC: 10k × 576 B); reuse produces none.

## 3. Internal data layout

### 3.1 Handle constructor literal — exactly 14 keys (12 user fields + `class` + `type` → 576 B, two slots of headroom below the 1088 B step; F-ALG-9/BC F9)

```lua
local h = {
	class = VeronEvent, type = "VeronEvent",
	Id = id,              -- number   per-instance ascending; the (due, Id) tie-break; re-issued by Restart() of a Fired handle
	_Scheduler = self,    -- owner Veron; every method routes through it (R-A); foreign-handle check
	_Fn = fn,             -- callable; NOOP once Stopped (a Stop on Fired too); a Fired handle keeps it for Restart() (R-B)
	_Period = period,     -- number   one-shot delay / recurring period / Chained child delay
	_IsRecur = isRecur,   -- boolean
	_State = state,       -- 1 Pending, 2 Paused, 3 Chained, 4 Fired, 5 Stopped (terminal ⇔ _State >= 4)
	_HeapIndex = 0,       -- 0 = not in the heap; `_Item[_HeapIndex] == h` is the ownership check
	_Chained = false,     -- false | {child, …} registration order (lazy, cold)
	_Burst = 0, _BurstSerial = 0, -- per-pass catch-up counter, self-resetting (D6)
	_MaxCatchUp = false,  -- false = inherit the instance cap | number (math.huge = uncapped/"all", 1 = "drop")
	_Flags = 0,           -- bits: PWC = 1, COMPLETING = 2, STOP_ON_FIRE = 4, REPAUSE = 8
}
setmetatable(h, eventDict)
```
The frozen remaining of a Paused handle lives in the owner's `_Paused[h]` (value = remaining), never on the handle. Flag idioms (no `bit32` on the hot path): plain recurring ⇔ `_Flags < 4`; REPAUSE set ⇔ `_Flags >= 8`; STOP_ON_FIRE set ⇔ `_Flags % 8 >= 4`; COMPLETING set ⇔ `_Flags % 4 >= 2`; PWC set ⇔ `_Flags % 2 == 1`. `baseclass_spec :: handle literal has exactly 14 keys, every value non-nil` pins the count; a 15th key is a design change, not a patch (F-ALG-9: the literal is sized once, no rehash).

### 3.2 Instance fields (all assigned in `initialize`, never nil; `false` for optionals)

| Group | Field: type = initial |
|---|---|
| heap | `_Due: {number} = {}`, `_Item: {VeronEvent} = {}`, `_N: number = 0` (== Pending count) |
| clock | `_Now = 0`, `_Base: false\|number = false` (firing entry's ideal due while a callback runs), `_Firing: false\|VeronEvent = false`, `_FiringThread: false\|thread = false` (the coroutine the firing callback runs in; R-D — set/saved/restored together with `_Base/_Firing`, always as a triple), `_TimeScale = 1`, `_IsPaused = false`, `_Offset = 0`, `_LastAbs: false\|number = false` |
| pass | `_UpdateDepth = 0`, `_SyncDepth = 0` (CompleteNow nesting), `_Serial = 0`, `_NextId = 0`, `_Errored: false\|string = false` |
| policy | `_MaxCatchUp = 8`, `_Valve = 1000`, `_MaxDt: number\|false = false`, `_MaxUpdateDepth = 8`, `_OnError = "warn"`, `_Strict = false`, `_LegacyRecurBase = false` |
| side indexes (cold) | `_Paused: {[VeronEvent]: number} = {}` (membership ⇔ state Paused; value = frozen remaining), `_PausedCount = 0`, `_Children: {[Veron]: true} = {}`, `_ChildCount = 0` (maintained by `_attach` +1, `Detach` −1, `Destroy` −1 on the child's self-detach and reset to 0 in the parent's loop), `_Parent: false\|Veron = false`, `_ChainedCount = 0`, `_RecurCount = 0` |
| lifecycle | `Name: string`, `_IsDestroyed = false` |
| stats | `_Updates, _Dispatched, _LastDispatched, _Reentries, _Dropped, _ValveHits, _ClampedBackwards, _ClampedDt, _Errors, _ErrorsSuppressed = 0`, `_LastDt = 0`, error dedupe `_LastErrorId = 0`, `_LastErrorAt = -HUGE` (§4.2 `_report`), warn-once booleans `_WarnedReentry, _WarnedValve, _WarnedBackwards, _WarnedResolution = false` |
| dual closures | ONE closure per canonical member of §2.2, stored under every spelling (`Stop/Remove/remove` → the same function object under three keys): `for _, names in PUBLIC do local method = dict[names[1]]; local closure = function(first, ...) if first == self then return method(self, ...) end return method(self, first, ...) end; for _, alias in names do self[alias] = closure end end` with `PUBLIC = {{"Update","update"},{"UpdateTo"},{"Now"},{"SetTimeScale"},{"GetTimeScale"},{"Pause"},{"Resume"},{"IsPaused"},{"Delay","delay"},{"Recur","recur"},{"DelayAt"},{"Stop","Remove","remove"},{"Complete","ForceEventComplete"},{"CompleteNow"},{"GetRemaining"},{"GetClocks","getClocks"},{"GetStats"},{"Validate"},{"Describe"},{"SetOnError"},{"SetMaxCatchUp"},{"GetMaxCatchUp"},{"SetValve"},{"SetMaxDt"},{"SetStrict"},{"Clear"},{"Attach"},{"Detach"},{"GetChildren"},{"Drive"},{"Destroy"},{"IsDestroyed"},{"IsUpdating"},{"GetBase"}}` → 34 closures + 41 keys per instance, built once in `initialize`; the per-instance cost (bench P15 measures it; ~7-9 KB, ~40 GC objects expected) is documented in API.md next to the retention rule with the advice "one `Drive`n child per subsystem, not one Veron per entity" |

Heap ops are ALG §3.2 **verbatim** (`siftUp, siftDown, heapPush, heapPop, heapRemove, heapUpdate, heapClear`) with the renames `_seq → Id`, `_hi → _HeapIndex`, `self._n → self._N`, `self._due/_item → self._Due/_Item`; `heapUpdate`'s ownership error text becomes `Veron: handle is not scheduled on this Veron` (internal invariant; unreachable through the public API). They sit inside a `--[[ HOT PATH: measured ALG §2.2 P1–P9 ]]` block (D24), which is what licenses the prototype's single-letter sift locals and unprefixed helper names — the one place the house naming rules are waived; transcribing them unchanged is deliberate (a rename in a verified block is a transcription risk with zero runtime gain).

Invariants (checked by `Validate()`): heap property on `(due, Id)`; `_Item[h._HeapIndex] == h` and `h._State == PENDING` for every slot `1..N`; `#_Due == #_Item == _N`; every `PAUSED` handle is a key of `_Paused` with `_HeapIndex == 0` and vice versa; `_PausedCount == count(_Paused)`; no NaN/inf in `_Due`; `_ChainedCount` == number of `CHAINED` handles reachable through `_Chained` lists of live handles; `_RecurCount` == number of `_IsRecur` handles that are Pending or Paused; `_ChildCount == count(_Children)`; terminal handles have `_HeapIndex == 0` and `_Flags == 0`; Stopped handles have `_Fn == NOOP`; `_Flags >= 4` only on a Pending recurring handle; `_UpdateDepth == 0 and _SyncDepth == 0 ⇒ _Base == false and _Firing == false and _FiringThread == false` (inside a top-level `CompleteNow` callback `_SyncDepth == 1`, so `Validate()` from that callback holds).

## 4. Algorithms (real Luau; file-local helpers of `Veron/init.luau` unless stated)

Module head: `--!native --!nonstrict`; `local PENDING, PAUSED, CHAINED, FIRED, STOPPED = 1, 2, 3, 4, 5`; `local PWC, COMPLETING, STOP_ON_FIRE, REPAUSE = 1, 2, 4, 8`; `local HUGE = math.huge`; localized `xpcall, pcall, tonumber, type, typeof, getmetatable`; `local running = coroutine.running`; `local traceback = Env.Traceback`; `local function NOOP() end`; `local eventDict = VeronEvent.__instanceDict`; `local veronDict` (set after `BaseClass.class`); **forward declarations** `local _advanceTo, _stopTerminal, _attach` (assigned as `_advanceTo = function(self, target) … end` at their definition sites — a `local function` is in scope only after its statement, so the listing order below must not be transcribed as-is; mandatory definition order in WP4: heap ops → `_clockOf/_checkOpts/_validateUncapped/_validateArgs/_newEvent` → `_stopTerminal` → `_diagnose/_report/_runCallback/_fire*` → `_pass` → `_advanceTo` → public methods). `--[[ HOT PATH: measured ALG §2.2 P1–P9 ]]` marks the heap ops of §3.2 (single-letter sift locals allowed there, D24) and `--[[ HOT PATH: measured ALG §2.2 P6/P7 ]]` marks `_pass` in §4.2; everything else is plain house style.

### 4.1 Validation and arm (Delay / Recur / DelayAt / After / Drive all end here)

Arm ordering rule (every arm, no exception): **validate args → validate the third argument / opts → `_attach` (`Drive` only; the LAST raise site: destroyed, cycle, double-attach) → allocate (`_newEvent`) → push**. No counter, index, list or heap is mutated before the LAST raise site, so a failed arm leaves `_RecurCount`, the heap and `_Children` exactly as they were (`arm_spec :: recur third argument: nil and false capped, true uncapped, non-boolean errors before any mutation`; `:: Drive third argument: nil and true uncapped, false capped, non-boolean errors and leaves the child unattached`).

```lua
local function _isCallable(v)
	if type(v) == "function" then return true end
	local mt = type(v) == "table" and getmetatable(v)
	return type(mt) == "table" and type(rawget(mt, "__call")) == "function"
end

local function _clockOf(self)                                              -- R-D: the carry belongs to the firing thread
	local base = self._Base
	if base ~= false and running() == self._FiringThread then return base end
	return self._Now                                                        -- any other thread (yield window, task.spawn, remote handler)
end

local COMPLETE_OPTS = { Stop = true }                                      -- the ONLY options table left (Complete/CompleteNow)

local function _checkOpts(self, opts, allowed, method, level)
	if opts == nil then return end
	if type(opts) ~= "table" then
		error(("Veron '%s': %s expects an options table, got %s"):format(self.Name, method, typeof(opts)), level)
	end
	for key in opts do
		if not allowed[key] then error(("Veron '%s': unknown option '%s' in %s"):format(self.Name, tostring(key), method), level) end
	end
end

local function _validateUncapped(uncapped, level)                          -- Recur/Drive third argument → false (inherit cap) | HUGE
	if uncapped == nil or uncapped == false then return false end
	if uncapped == true then return HUGE end
	error("expected `uncapped` to be a boolean", level)                     -- validation family (unprefixed); raised BEFORE any mutation
end

local function _validateArgs(self, fn, delayArg, isRecur, level)        -- legacy templates verbatim (D10)
	if self._IsDestroyed then error(("Veron '%s': destroyed"):format(self.Name), level) end
	if not _isCallable(fn) then error("expected `fn` to be callable", level) end
	local delay = tonumber(delayArg)                                         -- legacy coercion (I7)
	if type(delay) ~= "number" then
		error("expected `delay` to be a number. CurrentType: " .. typeof(delayArg), level)   -- ORIGINAL type (L-17, DV-24)
	end
	if delay ~= delay or delay == HUGE or delay == -HUGE then
		error("expected `delay` to be a finite number", level)               -- I4/I5 (Q-J3)
	end
	if delay < 0 then error("expected `delay` of zero or greater", level) end
	if isRecur and delay == 0 then error("expected recur `delay` greater than zero", level) end
	return delay
end

local function _newEvent(self, fn, period, isRecur, state, maxCatchUp)    -- the ONE allocation per arm (D13); after the last raise
	local id = self._NextId + 1
	self._NextId = id
	if isRecur then self._RecurCount += 1 end
	return setmetatable({ --[[ literal of §3.1 with these values; _MaxCatchUp = maxCatchUp ]] }, eventDict)
end

function Veron:Delay(fn, delayArg)
	local period = _validateArgs(self, fn, delayArg, false, 4)              -- 4: helper <- method <- closure <- user
	local h = _newEvent(self, fn, period, false, PENDING, false)
	heapPush(self, h, _clockOf(self) + period)                               -- implicit arm: base carry (D4/C1/R-D); 0 is truthy
	return h
end

function Veron:Recur(fn, periodArg, uncapped)
	local period = _validateArgs(self, fn, periodArg, true, 4)
	local maxCatchUp = _validateUncapped(uncapped, 4)                       -- last raise site: false (capped, inherit) | HUGE
	local h = _newEvent(self, fn, period, true, PENDING, maxCatchUp)        -- _RecurCount += 1 only now
	heapPush(self, h, _clockOf(self) + period)
	return h
end

function Veron:_SetCatchUp(h, mode, n)                                       -- VeronEvent:SetCatchUp; one-shot/terminal → no-op FIRST
	if not h._IsRecur or h._State >= FIRED then return h end
	local value
	if mode == "inherit" then value = false
	elseif mode == "all" then value = HUGE
	elseif mode == "drop" then value = 1
	elseif mode == "cap" then
		value = if n == nil then self._MaxCatchUp else n                     -- nil: snapshot of the instance cap
		if type(value) ~= "number" or value ~= value or value < 1 or value % 1 ~= 0 or value == HUGE then
			error(("Veron '%s': option 'MaxCatchUp' expects an integer >= 1, got %s"):format(self.Name, tostring(n)), 3)
		end
	else
		error(("Veron '%s': option 'CatchUp' expects cap, all, drop or inherit"):format(self.Name), 3)
	end
	h._MaxCatchUp = value
	return h
end
```
Top-level zero delay → due = now → next update (I1); inside a callback → `base + 0 <= now` → later in the same pass (C2/C3), never synchronously (D5). `h._MaxCatchUp` is `uncapped and HUGE or false` at arm time; `_pass` reads `h._MaxCatchUp or self._MaxCatchUp`, so `false` follows `SetMaxCatchUp` live.

### 4.2 Dispatch loop (`Update` / `UpdateTo` → `_advanceTo` → `_pass`)

```lua
function Veron:Update(dt)
	if type(dt) ~= "number" or dt ~= dt or dt < 0 or dt == HUGE then       -- type FIRST: Update(nil) gets the prefixed message (DV-23)
		error(("Veron '%s': Update(dt) expects a finite number >= 0, got %s"):format(self.Name, tostring(dt)), 3)
	end
	if self._IsDestroyed then error(("Veron '%s': destroyed"):format(self.Name), 3) end
	local maxDt = self._MaxDt
	if maxDt and dt > maxDt then dt = maxDt; self._ClampedDt += 1 end       -- Q-J16: AFTER validation; off (false) by default
	self._LastDt = dt
	if self._IsPaused then return end
	_advanceTo(self, self._Now + dt * self._TimeScale)
end

local function _diagnose(self, message, h)                                 -- ONE channel for every instance-originated diagnostic
	local policy = self._OnError                                            -- (re-entry, backwards clock, valve, resolution)
	if type(policy) == "function" and pcall(policy, message, h) then return end
	pcall(Env.Warn, ("[Veron %s] %s"):format(self.Name, message))            -- "error" policy never re-raises a diagnostic; a throwing
end                                                                        -- Warn seam never escapes (F4)

local function _report(self, message, h)                                   -- D11 callback errors; rate-limited (BC §7: never warn per frame)
	self._Errors += 1
	local policy = self._OnError
	if policy == "error" then
		if not self._Errored then self._Errored = message end               -- first message; raised at the outermost exit
		return
	end
	local now = self._Now
	local since = now - self._LastErrorAt
	if since < 1 and (h.Id == self._LastErrorId or since < 0.125) then     -- same handle: <= 1 report/s; distinct handles: <= 8/s
		self._ErrorsSuppressed += 1
		return
	end
	self._LastErrorId, self._LastErrorAt = h.Id, now
	local suppressed = self._ErrorsSuppressed
	if suppressed > 0 then message = ("%s (%d suppressed so far)"):format(message, suppressed) end
	if policy == "warn" then
		pcall(Env.Warn, ("[Veron %s] event #%d: %s"):format(self.Name, h.Id, message))
	elseif not pcall(policy, message, h) then
		pcall(Env.Warn, ("[Veron %s] OnError handler failed for event #%d: %s"):format(self.Name, h.Id, message))
	end
end

local function _runCallback(self, h, fn)
	local ok, message
	if h.Id == self._LastErrorId and self._Now - self._LastErrorAt < 1 then -- would be suppressed anyway: skip the traceback alloc
		ok, message = pcall(fn)
	else
		ok, message = xpcall(fn, traceback)                                  -- F-ALG-10: +31 ns; no arguments (D19)
	end
	if ok then return end
	_report(self, message, h)
end

local function _fireOneShot(self, h, d)                                    -- h already popped (_HeapIndex == 0)
	h._State = FIRED
	if h._IsRecur then self._RecurCount -= 1 end                            -- only the STOP_ON_FIRE path arrives here recurring
	local children = h._Chained
	if children then                                                        -- arm BEFORE the callback, from d (D3/D4, A6/A9)
		h._Chained = false
		for index = 1, #children do
			local child = children[index]
			if child._State == CHAINED then                                 -- stopped/completed children skipped (A1/F2)
				self._ChainedCount -= 1
				if child._Flags % 2 == 1 then                               -- PWC (A8): Paused with remaining = its delay
					child._Flags -= PWC; child._State = PAUSED
					self._Paused[child] = child._Period; self._PausedCount += 1
				else
					child._State = PENDING
					heapPush(self, child, d + child._Period)
				end
			end
		end
	end
	h._Flags = 0                                                            -- terminal; _Fn is KEPT: Restart() re-arms it, Stop() releases it (R-B, §4.3/4.4)
	self._Base, self._Firing = d, h                                         -- _FiringThread was set once for this pass
	_runCallback(self, h, h._Fn)                                            -- nothing scheduling-related after this line
end

local function _fireRepause(self, h, d)                                    -- deferred Complete on a Paused recurring (D7); h popped
	h._Flags -= REPAUSE
	h._State = PAUSED
	self._Paused[h] = h._Period; self._PausedCount += 1                     -- _RecurCount untouched
	self._Base, self._Firing = d, h
	_runCallback(self, h, h._Fn)
end

local function _valveHit(self, h)
	self._ValveHits += 1
	if not self._WarnedValve then                                           -- D5: warn once
		self._WarnedValve = true
		_diagnose(self, "runaway valve hit (" .. self._Valve .. " nested arms / catch-up repeats); remainder deferred to the next update", h)
	end
end

local function _stopResolution(self, h)                                    -- h popped; period below float resolution at this clock
	_stopTerminal(self, h)
	if not self._WarnedResolution then
		self._WarnedResolution = true
		_diagnose(self, "recur period below clock resolution at now = " .. self._Now .. "; event #" .. h.Id .. " stopped", h)
	end
end

local function _pass(self, serial)                                          -- the loop body; ALWAYS runs under xpcall (see _advanceTo)
	local due, item = self._Due, self._Item
	local startId, valve, valveCap = self._NextId, 0, self._Valve
	local legacyBase = self._LegacyRecurBase
	local dispatched = 0
	--[[ HOT PATH: measured ALG §2.2 P6/P7 (295-370 ns/dispatch, 0 B). Locals only; nothing scheduled after a callback (D3). ]]
	while self._N > 0 do                                                    -- Clear/Destroy set _N = 0 → exits
		local now = self._Now                                               -- re-read: an inner pass may have advanced it
		local d = due[1]
		if d > now then break end
		local h = item[1]
		if h.Id > startId then                                              -- armed during THIS pass and already due (D5)
			valve += 1
			if valve > valveCap then _valveHit(self, h) break end
		end
		if h._IsRecur and h._Flags < 4 then                                 -- plain recurring
			local period = h._Period
			local burst = 1
			if h._BurstSerial == serial then burst = h._Burst + 1 else h._BurstSerial = serial end
			h._Burst = burst
			local cap = h._MaxCatchUp or self._MaxCatchUp                   -- false = inherit; HUGE = uncapped; 1 = drop
			if burst > cap then                                             -- D6 capped: snap to the first grid point > now, phase kept
				local m = (now - d) // period + 1
				local nextDue = d + m * period
				if nextDue <= now then nextDue += period end
				if nextDue <= now then
					heapPop(self); _stopResolution(self, h)
				else
					due[1] = nextDue; siftDown(due, item, self._N, 1); self._Dropped += m
				end
			else
				local nextDue = d + period
				if nextDue <= d then                                        -- sub-resolution period in ANY mode: never a hang
					heapPop(self); _stopResolution(self, h)
				else
					if burst > 1 and cap == HUGE then                       -- uncapped: every repeat counts against the valve (D6)
						valve += 1
						if valve > valveCap then _valveHit(self, h) break end   -- still keyed at d: fires next update, nothing lost
					end
					due[1] = nextDue; siftDown(due, item, self._N, 1)       -- re-key IN PLACE before the callback (D3)
					self._Base = legacyBase and nextDue or d                -- Q-J1 knob; nextDue is never false
					self._Firing = h
					_runCallback(self, h, h._Fn)
					dispatched += 1
				end
			end
		elseif h._IsRecur then                                              -- cold: STOP_ON_FIRE (4..7) / REPAUSE (8+), see 4.7
			heapPop(self)
			if h._Flags >= REPAUSE then _fireRepause(self, h, d) else _fireOneShot(self, h, d) end
			dispatched += 1
		else
			heapPop(self)
			_fireOneShot(self, h, d)
			dispatched += 1
		end
	end
	return dispatched
end

_advanceTo = function(self, target)
	local now = self._Now
	if target > now then
		self._Now = target
	elseif target < now then                                                -- the clock never runs backwards (D2)
		self._ClampedBackwards += 1
		if now - target > 1 and not self._WarnedBackwards then
			self._WarnedBackwards = true
			_diagnose(self, ("clock asked to move backwards by %g s; clamped"):format(now - target), false)
		end
	end
	local depth = self._UpdateDepth
	if depth > 0 then                                                       -- R-C: nested (sync) or overlapped (yield)
		self._Reentries += 1
		if not self._WarnedReentry then
			self._WarnedReentry = true
			_diagnose(self, "Update re-entered from a callback (see Stats.Reentries)", false)
		end
		if depth >= self._MaxUpdateDepth then return end                    -- advance-only past the cap (B-04 #3)
	end
	self._Updates += 1
	if self._N == 0 or self._Due[1] > self._Now then                        -- idle fast path: nothing due → no pass, no re-entrancy,
		self._LastDispatched = 0                                            -- ~10 field ops, 0 calls (bench P2)
		return
	end
	self._UpdateDepth = depth + 1
	local savedBase, savedFiring, savedThread = self._Base, self._Firing, self._FiringThread
	self._FiringThread = running()                                          -- once per pass, never per dispatch (R-D)
	local serial = self._Serial + 1
	self._Serial = serial
	local ok, result = xpcall(_pass, traceback, self, serial)              -- ~40 ns per NON-idle update; the tail below always runs
	depth = self._UpdateDepth - 1
	self._UpdateDepth = depth                                               -- decrement, never restore (out-of-order yields)
	if depth == 0 and self._SyncDepth == 0 then                             -- truly idle: clear; else restore (a CompleteNow may be in flight)
		self._Base, self._Firing, self._FiringThread = false, false, false
	else
		self._Base, self._Firing, self._FiringThread = savedBase, savedFiring, savedThread
	end
	if ok then self._Dispatched += result; self._LastDispatched = result else self._LastDispatched = 0 end
	if depth == 0 then
		local errored = self._Errored
		if errored then
			self._Errored = false
			if ok then error(errored, 0) end                                -- "error" policy: once, at the outermost exit (B-04 #1)
		end
	end
	if not ok then                                                          -- library fault (corrupted handle field, …): state already clean
		error(("Veron '%s': internal fault during Update: %s"):format(self.Name, tostring(result)), 0)
	end
end
```
Properties: (a) the heap is in its final post-fire shape before user code runs, so a callback's `Stop/Reset/Adjust/Pause/Complete` on its own handle simply wins (ALG §3.3 rule 3); (b) a stop of a co-due sibling is an immediate `heapRemove`, seen by the next `due[1]` read (SEM S3); (c) `serial/startId/valve` and the burst counters are PER PASS, not per frame: a sync re-entry chain (`Delay(fn, 0)` + `Update(0)` inside a callback) bottoms out at `MaxUpdateDepth` passes, each with its own valve budget (≤ 8 × 1000 dispatches per outer Update — bounded, documented in §11), and the outer pass resumes on a heap it re-reads, so no entry is dispatched twice; (d) after a yield-overlap resolves out of order the later exit finds `depth == 0` and clears the triple — post-resume arms of a yielded callback measure from `now` (documented); (e) while a callback is suspended, EVERY other thread (another RunService handler, a RemoteEvent handler, code `task.spawn`ed from the callback itself) measures from `_Now` and may `Complete()` the suspended handle (R-D, `reentrancy_spec :: top-level Delay during a yield window measures from now`); (f) an uncapped recurring (`_MaxCatchUp == HUGE`) is valve-bounded (repeat counting — `burst > 1` only, so one lagging handle delivers exactly `Valve + 1` fires per pass and the next repeat trips) AND structurally hang-proof (`nextDue <= d` guard); when the valve trips it stays keyed at its due, so every owed fire still happens across the following updates — spread, never lost (`catchup_spec :: uncapped recur after a hitch fires every owed tick across updates when the valve trips (nothing lost)`); (g) mutual `SetRemaining(0)`/`Complete()` between two recurring callbacks is bounded by the cap for capped handles and by the valve for uncapped ones; (h) a throwing `Env.Warn` seam, a throwing `OnError` function or a corrupted handle field (`h._Period = nil`) never leaves `_UpdateDepth`, the base triple or `_Errored` dirty — the pass body is protected and the tail is unconditional; (i) `Stats.Errors` is the true error count, `ErrorsSuppressed` the reports withheld by the rate limit; (j) `MaxDt` is applied to `Update(dt)` only, after validation: `UpdateTo` never clamps (its axis is external), and an `inf` dt is REJECTED (not clamped) because an infinite clock makes `Adjust`'s frac NaN (F-PM-4).

### 4.3 Stop / Remove cascade (the only path to Stopped)

```lua
_stopTerminal = function(self, h)                                          -- true iff a LIVE handle became Stopped
	local state = h._State
	if state == STOPPED then return false end                               -- terminal check FIRST (D18)
	if state == FIRED then h._State, h._Fn = STOPPED, NOOP return false end -- explicit Stop finalizes a Fired handle: no container op
	                                                                        -- (it is in none, _Chained already false); Restart refused from now on
	if state == PENDING then heapRemove(self, h)                            -- ownership check inside; popped-but-Pending → false, harmless
	elseif state == PAUSED then self._Paused[h] = nil; self._PausedCount -= 1
	else self._ChainedCount -= 1 end                                        -- CHAINED: the parent's list skips non-Chained (A1)
	if h._IsRecur then self._RecurCount -= 1 end
	h._State, h._Fn, h._Flags = STOPPED, NOOP, 0
	local children = h._Chained
	if children then
		h._Chained = false
		for index = 1, #children do
			local child = children[index]
			if child._State == CHAINED then _stopTerminal(self, child) end  -- A2, recursive; a child DETACHED by Complete (now
		end                                                                 -- Pending/Paused) keeps the fire it was promised (F2)
	end
	return true
end

local function _resolve(self, x, level)                                    -- handle only; nil for anything that is not ours
	if x == nil then return nil end
	if getmetatable(x) ~= eventDict then
		if self._Strict then error(("Veron '%s': expected a VeronEvent, got %s"):format(self.Name, typeof(x)), level) end
		return nil
	end
	if x._Scheduler ~= self then
		error(("Veron '%s': event #%d belongs to Veron '%s', not '%s'"):format(self.Name, x.Id, x._Scheduler.Name, self.Name), level)
	end
	return x
end

function Veron:Stop(x) local h = _resolve(self, x, 4); return h ~= nil and _stopTerminal(self, h) end
function Veron:_Stop(h) _stopTerminal(self, h) end                         -- VeronEvent:Stop / :stop / :Destroy (owner-agnostic)
```
Stop protection = ALG §3.7 plus: the running recurring handle's `Stop` removes its re-keyed entry (no further fire this pass, S2/L-06); a co-due sibling is removed before it can pop (S3/L-02); TickAPI's `SafeStopClock(x)` = `x:stop()` = `h:Stop()` through the alias (§6), total on terminal handles and FINAL on Fired ones: a post-fire `stop()` turns Fired into Stopped with `_Fn = NOOP` (no container op — a Fired handle is in none — and `Stop(h)` returns `false` because no live handle changed), so the 68 stop-after-fire sites release the owner's closure exactly as they did before `Restart()` existed and the handle can never be restarted; `Clear()` cannot reach a Fired handle (it walks the heap and `_Paused` only, below). The cascade is state-gated exactly like the arm in `_fireOneShot`: only still-CHAINED children are stopped (D18), so `P:Stop()`/`Clear()` after `C:Complete()` cannot cancel C's promised fire (non-negotiable 11; `chain_spec :: parent Stop after child Complete leaves the completed child armed and firing`). `Clear()`: the file-local `_clearTerminal(self, h)` applies the terminal WRITES only (`_State = STOPPED, _Fn = NOOP, _Flags = 0, _HeapIndex = 0`) and recurses over still-CHAINED descendants (in no container) — never a heap or paused-set operation. Walk `_Item[1..N]` and every key of `_Paused` with it (a child detached by `Complete` is Pending/Paused and is visited by the walk itself, never by a cascade, so the walk's bound stays valid), then `heapClear`, `table.clear(_Paused)`, zero `_N/_PausedCount/_ChainedCount/_RecurCount`, then `child:Clear()` for attached children; returns the count. O(n), legal mid-update (the loop re-reads `_N == 0`; `chain_spec :: Clear/Destroy with a completed child does not corrupt the walk`).

### 4.4 Pause / Resume (explicit ops measure from `_Now`, D4)

A Pending recurring handle with STOP_ON_FIRE or REPAUSE set is **COMMITTED** (`_Flags >= 4`): it owes exactly one forced fire (§4.7) and ignores every retime, `Pause`, `Toggle` and `Restart` until that fire; `Stop`/`Complete`/`CompleteNow` still apply. `Describe()` shows `+stop` / `+repause`.

| | Pending (plain) | Pending, COMMITTED | Paused | Chained |
|---|---|---|---|---|
| `_Pause(h)` | `remaining = max(due − now, 0)`; `heapRemove`; `PAUSED`; `_Paused[h] = remaining`; `_PausedCount += 1` | no-op (REPAUSE re-parks itself after the forced fire; STOP_ON_FIRE dies at it) | no-op | `_Flags += PWC` if unset |
| `_Resume(h)` | no-op | REPAUSE → `_Flags -= REPAUSE` (the user's Resume is honoured: it fires, then runs on); STOP_ON_FIRE → no-op | `PENDING`; `heapPush(h, now + remaining)`; unset; `_PausedCount -= 1` | `_Flags -= PWC` if set |
| `_Reset/_Adjust/_SetRemaining/_SetPeriod` | §4.5 | no-op returning `h` (`complete_spec :: Reset after a deferred Complete on a Paused recurring does not resume it`; `:: Pause/Reset after Complete{Stop=true} keep the forced final fire`) | §4.5 | §4.5 |

A paused recurring accumulates no missed fires (its key is recomputed on resume). Instance-level `Pause()/Resume()` is a separate switch (`_IsPaused`).

```lua
function Veron:_Toggle(h)                                                  -- VeronEvent:Toggle — the recur switch (Q-J18)
	local state = h._State
	if state == PENDING then self:_Pause(h)                                 -- COMMITTED: _Pause is already a no-op
	elseif state == PAUSED then self:_Resume(h)
	elseif state == CHAINED then if h._Flags % 2 == 1 then h._Flags -= PWC else h._Flags += PWC end   -- flip PWC
	end                                                                     -- Fired / Stopped → no-op
	return h
end

function Veron:_Restart(h)                                                 -- VeronEvent:Restart — the ONE explicit re-arm of a Fired handle
	local state = h._State
	if state == STOPPED or state == CHAINED or self._IsDestroyed then return h end   -- Stopped is final; dead owner → no-op
	if state == FIRED then
		local id = self._NextId + 1                                         -- fresh Id: the valve keys on h.Id > startId (§4.2), so a
		self._NextId = id; h.Id = id                                        -- self-Restart from its own callback is a nested arm, not a hang
		h._State = PENDING
		if h._IsRecur then self._RecurCount += 1 end                        -- a STOP_ON_FIRE'd recurring re-arms as recurring
		heapPush(self, h, self._Now + h._Period)                            -- explicit op: from _Now (D4); _Chained was cleared at fire
		return h
	end
	if h._Flags >= STOP_ON_FIRE then return h end                           -- COMMITTED: the forced fire is owed
	self:_Reset(h)                                                          -- Pending: key = now + P | Paused: remaining = P
	return self:_Resume(h)                                                  -- Paused → Pending @ now + P; plain Pending: no-op
end
```
A Fired handle keeps `_Fn` (R-B) until an explicit `Stop` finalizes it (§4.3), so `Restart` re-runs the same callback — from inside its own callback too (Fired was set before `fn`, so the push simply lands in the heap the pass re-reads). The Fired re-arm takes a FRESH `Id` on purpose: the valve counts `h.Id > startId` (§4.2) and the handle's old Id predates the pass, so without it `h = s:Delay(function() h:Restart() end, 0); s:Update(0)` — or two Fired siblings restarting each other, or any period with `_Now + period == _Now` — would pop the same handle at `due == now` forever (before `Restart` existed a one-shot could fire at most once per pass, which is why Id-tracking sufficed); with it the pass stops at `Valve`, warns once and resumes next update, and the `(due, Id)` FIFO treats the restart as the newest arm. Ids still ascend and are never reused (O3); the handle is out of the heap when its Id changes, so the heap property is untouched; the `_report` dedupe just sees a distinct handle. Its `_Chained` list was cleared at fire, so old children never re-fire, and a later `After()` on the restarted (now Pending) parent chains normally (`chain_spec :: After on a restarted parent chains normally; old children never re-fire`). `Validate()`'s `_RecurCount` invariant holds because the re-arm re-counts a recurring. Pins: `state_spec :: Toggle flips Pending and Paused, flips PWC on Chained, no-op on terminal and COMMITTED`; `:: Restart re-arms a Fired one-shot from now with its full period and it fires again`; `:: Restart re-arms a Fired recurring as recurring`; `:: Restart on Stopped is a no-op (Stopped is final)`; `:: Restart on Pending/Paused equals Reset then Resume`; `:: Restart on a handle of a destroyed Veron is a no-op`; `:: a Fired handle keeps its function until Restart or Stop, a Stopped handle has NOOP`; `catchup_spec :: valve: a zero-period one-shot that Restarts itself from its own callback stops at 1000, warns once, resumes next update`.

### 4.5 Reset / Adjust / SetPeriod / SetRemaining (D9; prior's messages; terminal and COMMITTED checks come BEFORE argument validation, D8)

```lua
function Veron:_Adjust(h, newTotalArg)
	local state = h._State
	if state >= FIRED or h._Flags >= STOP_ON_FIRE then return h end        -- total FIRST: firedHandle:Adjust(0/0) is a silent no-op
	local x = tonumber(newTotalArg)
	if type(x) ~= "number" or x ~= x or x == HUGE or x <= 0 then error("expected `newTotal` greater than zero", 3) end
	local period = h._Period
	if state == PENDING then
		local now = self._Now
		local frac = if period > 0 then math.clamp((self._Due[h._HeapIndex] - now) / period, 0, 1) else 1
		heapUpdate(self, h, now + frac * x)
	elseif state == PAUSED then
		local frac = if period > 0 then math.clamp(self._Paused[h] / period, 0, 1) else 1
		self._Paused[h] = frac * x
	end
	h._Period = x                                                           -- Chained: delay only
	return h
end
-- _Reset(h):         terminal/COMMITTED → h | PENDING → heapUpdate(now + period) | PAUSED → _Paused[h] = period | CHAINED → no-op
-- _SetRemaining(h,x): terminal/COMMITTED → h; then x finite >= 0 else "expected `remaining` of zero or greater"; PENDING → heapUpdate(now + x)
--                     | PAUSED → _Paused[h] = x | CHAINED → _Period = x
-- _SetPeriod(h,p):   terminal/COMMITTED → h; then finite; recurring > 0 / one-shot >= 0 (prior messages); _Period = p; never re-keys
-- _GetRemaining(h):  PENDING → max(due − now, 0) | PAUSED → _Paused[h] | CHAINED → _Period | terminal → 0
```
Inside its own recurring callback `Adjust` sees `due = d + period` (already re-keyed) so `frac ∈ [0,1]`; the worst case is one extra fire this pass, bounded by the cap (closes B-01). `period == 0` never divides (F6/R3/RF-001). `state_spec :: every public method is a no-op on Stopped and, Stop/Restart excepted, on Fired even with invalid arguments` pins the ordering.

### 4.6 After-chains

```lua
function Veron:_After(parent, fn, delayArg)                                 -- called by VeronEvent:After
	local state = parent._State
	if state == STOPPED or self._IsDestroyed then                           -- A5 / post-Destroy: born Stopped, NO validation (total, D8)
		return _newEvent(self, NOOP, 0, false, STOPPED, false)
	end
	if parent._IsRecur then error("cannot chain a recurring event", 3) end
	local period = _validateArgs(self, fn, delayArg, false, 4)
	if state == FIRED then                                                  -- A4: "after a finished event" = the caller's clock
		local child = _newEvent(self, fn, period, false, PENDING, false)
		heapPush(self, child, _clockOf(self) + period)
		return child
	end
	local child = _newEvent(self, fn, period, false, CHAINED, false)
	local list = parent._Chained
	if not list then list = {}; parent._Chained = list end                  -- the only lazy allocation on a handle (cold)
	list[#list + 1] = child                                                 -- registration order (A6/D23)
	self._ChainedCount += 1
	return child
end
```
Children arm from the parent's ideal due `d` (A9); when the parent was force-completed, `d` IS the completion time (the caller's `_Now` at `Complete()`, exactly `now` for `CompleteNow`) — that is what "from now" means in D7/A9. `After()` on a Fired parent arms from `_clockOf(self)`: the callback's ideal due inside the firing thread (D4), `now` everywhere else (`chain_spec :: After on Fired arms from the caller's clock, never returns the parent`). An erroring parent still arms them (A10, DV-6); unlimited depth (A7; F-PM-8 deferred, §13).

### 4.7 Complete (deferred = `ForceEventComplete`) and CompleteNow (synchronous)

```lua
function Veron:_Complete(h, opts, level)                                    -- handle path level 3, instance Complete(h, opts) path 4
	_checkOpts(self, opts, COMPLETE_OPTS, "Complete", level + 1)            -- `{stop = true}` is an error, never a silent no-op
	local state = h._State
	if state >= FIRED or (self._Firing == h and running() == self._FiringThread) then return false end   -- F7; F6 own callback (R-D)
	local stop = opts ~= nil and opts.Stop == true
	local now = self._Now                                                   -- the caller's now, not _Base: `<= now` fires next pass
	if stop and h._IsRecur then
		if h._Flags >= REPAUSE then h._Flags -= REPAUSE end
		if h._Flags % 8 < 4 then h._Flags += STOP_ON_FIRE end
	end
	if state == PENDING then
		heapUpdate(self, h, now)
	elseif state == PAUSED then
		self._Paused[h] = nil; self._PausedCount -= 1
		if h._IsRecur and not stop then h._Flags += REPAUSE end             -- D7: stays Paused with a full period after the fire
		h._State = PENDING; heapPush(self, h, now)
	else                                                                    -- CHAINED: detached. It STAYS in the parent's list; the arm
		self._ChainedCount -= 1                                             -- (_fireOneShot) and the cascade (_stopTerminal/Clear) both
		if h._Flags % 2 == 1 then h._Flags -= PWC end                       -- skip non-Chained entries, so the promised fire survives
		h._State = PENDING; heapPush(self, h, now)                          -- a later parent Stop/Clear (F2)
	end
	return true
end
```
Flagged recurring handles take the cold branch of 4.2: `STOP_ON_FIRE` → `_fireOneShot` (Fired, no re-arm, `_RecurCount -= 1`); `REPAUSE` → `_fireRepause` (re-parked Paused with `remaining = period` BEFORE the callback). Plain recurring → fires then re-arms at `now + period` through the normal re-key. On a paused INSTANCE the deferred fire waits for `Resume()` (§2.2). A top-level `R:Complete()` on a recurring whose callback is suspended in a yield returns `true` and fires (the guard is thread-bound, R-D; `complete_spec :: top-level Complete on a yielded recurring returns true and fires`). The instance forms `Complete(x, opts)`/`CompleteNow(x, opts)` go through `_resolve(self, x, 4)` first (nil/non-handle → `false`, Strict/foreign → error, as `Stop`).

`_CompleteNow(h, opts, level)`: `_checkOpts` as above; `false` when terminal, own callback (same thread-bound predicate), or COMPLETING set (F6, mutual A→B→A); `_SyncDepth >= 8` → `_diagnose(...)` + `false`. Else: `_Flags += COMPLETING`, `_SyncDepth += 1`, `savedBase, savedFiring, savedThread = _Base, _Firing, _FiringThread`, `_FiringThread = running()`, `d = _Now` (explicit op: from now, D4), then by case, with the transition + callback run under `pcall` and the tail below unconditional (same shape as `_advanceTo`, F4):

| Case | Transition before the callback |
|---|---|
| one-shot, or recurring with `opts.Stop` | leave the current container (`heapRemove` / unpark / `_ChainedCount -= 1`), then `_fireOneShot(self, h, d)` (Fired before fn, children from now, flags zeroed) |
| recurring Pending (no REPAUSE) | `heapUpdate(h, d + period)` (phase restarts from now); `_Base, _Firing = d, h`; `_runCallback` |
| recurring Paused, or Pending + REPAUSE | ensure parked: `heapRemove` if in heap, `PAUSED`, `_Paused[h] = period` (count maintained), REPAUSE cleared; callback runs; stays Paused (D7) |
| recurring Chained | detach (as `_Complete`), `PENDING`, `heapPush(h, d + period)`; callback |

Tail: `if _Flags % 4 >= 2 then _Flags -= COMPLETING end` (a one-shot fire already zeroed it), `_SyncDepth -= 1`, restore the triple; when `_UpdateDepth == 0 and _SyncDepth == 0` re-raise a stored `"error"`-policy message (E5). A nested `Update` issued from the CompleteNow callback sees `_SyncDepth > 0` and RESTORES the triple on exit instead of clearing it, so the rest of the callback keeps its base and its own-callback guard (`complete_spec :: nested Update inside a CompleteNow callback keeps the base and the own-callback guard`). Returns `true` even if the callback errored (F8). Neither verb ever runs on a terminal handle; `Stop` never fires (F9).

### 4.8 `UpdateTo` offset math, `DelayAt`, and the time model (D2)

```lua
function Veron:UpdateTo(t)
	if type(t) ~= "number" or t ~= t or t == HUGE or t == -HUGE then
		error(("Veron '%s': UpdateTo(t) expects a finite number, got %s"):format(self.Name, tostring(t)), 3)
	end
	if self._IsDestroyed then error(("Veron '%s': destroyed"):format(self.Name), 3) end
	local last = self._LastAbs
	if last == false then                                                   -- first sample anchors: never sweeps relative timers
		self._LastAbs, self._Offset = t, t - self._Now
		if not self._IsPaused then _advanceTo(self, self._Now) end          -- flushes due entries like Update(0); nothing while paused
		return
	end
	if self._IsPaused then self._Offset += t - last; self._LastAbs = t; return end
	local target
	if self._TimeScale == 1 then target = t - self._Offset                  -- exact, no accumulation
	else target = self._Now + (t - last) * self._TimeScale; self._Offset = t - target end
	self._LastAbs = t
	_advanceTo(self, target)                                                -- backwards → clamped + counted inside
end
-- SetTimeScale(x): validate; _TimeScale = x; if _LastAbs ~= false then _Offset = _LastAbs - _Now end
-- DelayAt(fn, absDue): _LastAbs == false → error; _validateArgs(self, fn, absDue, false, 4) coerces/validates absDue;
--     delay = math.max((absDue - _LastAbs) * _TimeScale - (_clockOf(self) - _Now), 0); arm as Delay.
--     External distance from the LAST sample, scaled (at scale 1 this equals absDue - _Offset - _clockOf(self)); while
--     paused the frozen sample is used and the pause gap is folded into _Offset on Resume, so the external due still holds.
```

Time model, in plain language (the answer to Jake's "rolling accumulated dt vs passed value as insertion point"; carried verbatim into API.md, `docs_spec :: API.md explains the rolling-clock decision in plain language`): the legacy core keeps a countdown PER timer and subtracts `dt` from every one of them every frame (`Tick.luau:141-144`) — that is why it is O(n). A heap needs ONE comparable number per timer, so each timer stores the absolute moment it is due on a shared clock (`now + delay`) and only the clock advances (`now += dt`). Yes, that number grows forever, and no, it does not matter: a double keeps ~15-16 significant digits, so after a year of uptime the clock is still accurate to a tenth of a microsecond (ulp(1e7 s) = 1.9e-9 s; measured drift 6e-4 s per 1e4 simulated seconds at 240 Hz, ALG F-ALG-12). RunService hands TickAPI a DELTA (`Stepped` passes `(time, dt)`, `Heartbeat` passes `dt`), so `Update(dt)` accumulating is the natural fit; `TimeScale`, `Pause` and deterministic stepping are only possible on a clock the instance owns. Passing an absolute time (`UpdateTo(t)`) is the same loop with the clock SET instead of advanced, exact at scale 1, and is what a cross-client synced instance (`workspace:GetServerTimeNow()`) would use; `DelayAt` places a timer on that external axis. The one rule: a handle belongs to exactly one Veron because dues are only comparable on the clock they were computed against.

### 4.9 Destroy / Attach / Detach / Drive / runtime setters

```lua
function Veron:Destroy()                                                    -- no options: nothing is protected from its owner
	if self._IsDestroyed then return end
	self._IsDestroyed = true                                                -- FIRST: any re-entrant arm now errors
	self:Clear()                                                            -- _N = 0 → a running pass exits after the current callback (N4)
	local children = self._Children
	self._Children, self._ChildCount = {}, 0
	for child in children do child._Parent = false; child:Destroy() end
	local parent = self._Parent
	if parent then self._Parent = false; parent._Children[self] = nil; parent._ChildCount -= 1 end
end                                                                        -- TickAPI.<Name> keeps pointing at the dead instance: callers get `destroyed`, not index-nil

_attach = function(self, child, level)                                     -- Attach and Drive both pass 4 (helper under a method
	if self._IsDestroyed then error(("Veron '%s': destroyed"):format(self.Name), level) end                 -- body: _attach <- method <- closure <- user)
	if getmetatable(child) ~= veronDict then error(("Veron '%s': Attach expects a Veron, got %s"):format(self.Name, typeof(child)), level) end
	if child == self then error(("Veron '%s': cannot attach itself"):format(self.Name), level) end
	if child._IsDestroyed then error(("Veron '%s': '%s' is destroyed"):format(self.Name, child.Name), level) end
	if child._Parent then error(("Veron '%s': '%s' is already attached to '%s'"):format(self.Name, child.Name, child._Parent.Name), level) end
	local ancestor = self._Parent
	while ancestor do
		if ancestor == child then error(("Veron '%s': Attach would create a cycle"):format(self.Name), level) end
		ancestor = ancestor._Parent
	end
	child._Parent = self; self._Children[child] = true; self._ChildCount += 1
end
-- Attach(child) = _attach(self, child, 4). Detach(child): if _Children[child] then _Children[child] = nil; _ChildCount -= 1;
-- child._Parent = false; return true end return false

function Veron:Drive(child, period, uncapped)
	if getmetatable(child) ~= veronDict or child == self then
		error(("Veron '%s': Drive expects another Veron"):format(self.Name), 3)
	end
	local seconds = _validateArgs(self, NOOP, period, true, 4)
	if uncapped == nil then uncapped = true end                             -- default: a lossless sub-clock
	local maxCatchUp = _validateUncapped(uncapped, 4)                       -- last argument raise; nothing touched yet
	_attach(self, child, 4)                                                 -- ALWAYS; may raise (cycle, double-attach); nothing armed yet
	local h                                                                 -- forward declaration: the pump references it
	local function pump()
		if child._IsDestroyed then h:Stop() return end                      -- stops itself; never errors through OnError forever
		child:Update(seconds)
	end
	h = _newEvent(self, pump, seconds, true, PENDING, maxCatchUp)
	heapPush(self, h, _clockOf(self) + seconds)
	return h
end
-- Runtime setters (level 3, message `Veron '<Name>': option '<k>' expects <what>, got <v>`; construction reuses the same checks
-- with the bare `Veron: ` prefix): SetOnError(p) "warn"|"error"|function → _OnError; SetMaxCatchUp(n) integer >= 1 → _MaxCatchUp;
-- GetMaxCatchUp() → _MaxCatchUp; SetValve(n) integer >= 1 → _Valve; SetMaxDt(x) number > 0 | false → _MaxDt; SetStrict(b) boolean → _Strict.
```
A child's `Update` inside a parent callback is a different instance: always safe (N2/D17). Uncapped (the default), a parent hitch delivers every owed `period` to the child (valve-bounded, so spread over following updates when it trips, never lost; the parent's own `MaxDt`, if set, still clamps the parent's dt); `Drive(child, p, false)` accepts lost child time instead (`lifecycle_spec :: Drive under a hitch — uncapped keeps child time, capped drops it`). Because `Drive` always attaches, `A:Drive(B)` then `B:Drive(A)` is refused by `_attach`'s cycle walk (`Attach would create a cycle`) — a pair of mutual pumps cannot exist (`lifecycle_spec :: Drive always attaches; mutual Drive is refused as a cycle`).

### 4.10 VeronEvent → Veron contract (private `_PascalCase` methods on the instance; every one takes the handle first)

| VeronEvent method | calls | VeronEvent method | calls |
|---|---|---|---|
| `Stop()` / `stop` / `Destroy` | `s:_Stop(h)` | `Pause()` / `Resume()` | `s:_Pause(h)` / `s:_Resume(h)` |
| `Reset()` | `s:_Reset(h)` | `After(fn, t)` | `s:_After(h, fn, t)` |
| `Adjust(x)` | `s:_Adjust(h, x)` | `Complete(o)` / `CompleteNow(o)` | `s:_Complete(h, o, 3)` / `s:_CompleteNow(h, o, 3)` (instance `Complete(h, o)` passes 4) |
| `SetPeriod(p)` / `SetRemaining(x)` | `s:_SetPeriod(h, p)` / `s:_SetRemaining(h, x)` | `SetCatchUp(m, n)` | `s:_SetCatchUp(h, m, n)` |
| `Toggle()` / `Restart()` | `s:_Toggle(h)` / `s:_Restart(h)` | `GetRemaining()` | `s:_GetRemaining(h)` |
| queries (`GetState`, `IsActive`, `GetPeriod`, …) | read own fields only | | |

`VeronEvent:Describe()` reads `h._Scheduler.Name`, `Id`, `_IsRecur`, `_Period`, `STATE_NAMES[_State]`. The instance reads from `VeronEvent` only `VeronEvent.__instanceDict` (at load) and handle fields.

### 4.11 `Validate()`, `GetStats(into)`, `Describe()`

`Validate()` walks the §3.2 invariant list and returns `true`, or `false, "<first violated invariant>"`; O(n + paused); allocates nothing but the reason string. `GetStats(into)` writes every §2.2 key into `into` (or a new table) and returns it. `Describe()` formats `Veron<%s now=%.3f pending=%d paused=%d>`.

## 5. State machine (state × operation → result; every cell is total, never a raw error)

| Operation | Pending | Paused | Chained | Fired | Stopped |
|---|---|---|---|---|---|
| natural fire (one-shot) | → Fired BEFORE fn; children armed at d | — | — | — | — |
| natural fire (recurring) | re-key `d+P` (or snap) BEFORE fn; STOP_ON_FIRE → Fired; REPAUSE → Paused (remaining = P) | — | — | — | — |
| parent fires | — | — | → Pending @ `d+P`; PWC → Paused (remaining = P) | — | — |
| `Stop`/`Remove`/`Destroy`/`stop` (the `SafeStopClock` path) | → Stopped, `heapRemove`, cascade to still-Chained children | → Stopped, unpark, cascade | → Stopped (parent skips it), cascade | → Stopped (no container op; `_Fn = NOOP`; instance `Stop` returns `false`) | no-op |
| `Reset` | key = `now+P`; COMMITTED (STOP_ON_FIRE/REPAUSE) → no-op | remaining = P | no-op | no-op (h) | no-op (h) |
| `Adjust(x)` | key = `now+frac·x`; P = x; COMMITTED → no-op | remaining = frac·x; P = x | P = x | no-op (h), even with a bad `x` | no-op (h) |
| `SetPeriod(p)` | P = p; COMMITTED → no-op | P = p | P = p | no-op | no-op |
| `SetRemaining(x)` | key = `now+x`; COMMITTED → no-op | remaining = x | P = x | no-op | no-op |
| `Pause` | → Paused (freeze); COMMITTED → no-op (the forced fire is owed) | no-op | flag PWC | no-op | no-op |
| `Resume` | REPAUSE → cleared (fires, then runs on); else no-op | → Pending @ `now+remaining` | clear PWC | no-op | no-op |
| `Toggle` | → Paused (as `Pause`); COMMITTED → no-op | → Pending @ `now+remaining` (as `Resume`) | flip PWC | no-op | no-op |
| `Restart` | key = `now+P`, keeps running; COMMITTED → no-op | → Pending @ `now+P` | no-op | → Pending @ `now+P` with a fresh `Id` (the ONE re-arm; recurring stays recurring; `_Fn` kept) | no-op (final) |
| `After(fn,t)` | child Chained | child Chained | grandchild Chained | child Pending @ `_clockOf + t` | child born Stopped (no validation; also for any parent on a destroyed instance) |
| `Complete` (deferred) | key = now → `true` (own callback, same thread → `false`) | → Pending @ now (+REPAUSE if recur, or STOP_ON_FIRE) → `true`; `IsPaused()` stays `true` under REPAUSE | detached (stays in the parent's list, which now skips it) → Pending @ now → `true` | `false` | `false` |
| `CompleteNow` | fires now → `true` (own callback / completing → `false`) | fires; recurring stays Paused (remaining = P) → `true` | detach, fire → `true` | `false` | `false` |
| `SetCatchUp` | recurring: `_MaxCatchUp` set | same | same | no-op | no-op |
| `GetRemaining` | `max(due−now, 0)` | remaining | P | 0 | 0 |
| `IsActive` / counted by `GetClocks` | true / yes | true / yes | true / no | false / no | false / no |
| `Clear()` / instance `Destroy` | → Stopped | → Stopped | → Stopped | — | — |

Instance states: live → destroyed (terminal). `_IsPaused` is orthogonal (`Pause/Resume`). Which RunService signal drives `update(dt)` is TickAPI's concern and invisible to the instance.

## 6. How TickAPI wires Veron (the wrapper is NOT in scope; this is the contract it builds against)

`ReplicatedStorage.SharedModules.TickAPI` (TickAPI.luau) stays the module every caller requires. Today it holds three copies of the legacy scheduler (`Tick`, `Tick2`, `Tick3`) and connects each to one RunService signal. After M1 it holds ONE `Veron` module tree and builds three instances; only the three require+connect blocks change:

| Block in TickAPI.luau | Legacy | New |
|---|---|---|
| require + construct | `TickAPI.Tick = require(game.ReplicatedStorage.SharedModules.TickAPI.Tick)` (`Tickh` ← `Tick2`, `Tickr` ← `Tick3`) | `local Veron = require(script.Veron)` once; `TickAPI.Tick = Veron.new{ Name = "Tick" }`; `TickAPI.Tickh = Veron.new{ Name = "Tickh" }`; client only: `TickAPI.Tickr = Veron.new{ Name = "Tickr", MaxCatchUp = 1 }` (`MaxCatchUp = 1` optional, Q-J8) |
| Stepped | `RunService.Stepped:Connect(function(_, dt) TickAPI.Tick.update(dt) end)` | identical — `Stepped` passes `(time, dt)`, dt SECOND, same as today |
| Heartbeat / RenderStepped | `RunService.Heartbeat:Connect(function(dt) TickAPI.Tickh.update(dt) end)`; `RunService.RenderStepped:Connect(function(dt) TickAPI.Tickr.update(dt) end)` | identical — both pass dt FIRST |
| `Tick`, `Tick2`, `Tick3` ModuleScripts | three legacy copies | all deleted at M1; `Veron` (children `VeronEvent`, `Env`) is the only module |

What keeps working unchanged, and why:

| TickAPI member | Legacy code it runs | Veron feature it relies on |
|---|---|---|
| `SafeStopClock(clockObj)` | `clockObj:stop()` | handle alias `stop = Stop` (§2.3), total on terminal handles and final on Fired ones (→ Stopped, `_Fn` released, no `Restart`, §4.3) — the 68 stop-after-fire sites stay silent and still kill the handle for good |
| `AfterNotTouchedClass` (`GetAfterNotTouched(t, fn, tickType)`) | `TickAPI[TickType].delay(fn, t)`, `Clock:reset()`, `SafeStopClock(Clock)` | dot-called `delay` closure (§3.2); alias `reset = Reset` (full window from now, D9); `stop` |
| `TimeManagerAPI = require(TickAPI)`, global `TickAPI` leak (`xray:87`) | module identity | untouched: nothing but the three blocks above changes |

The ONE thing TickAPI must be aware of (DV-23): `update(dt)` now raises `Veron '<Name>': Update(dt) expects a finite number >= 0, got <v>` on nil/NaN/negative/inf/string dt instead of silently poisoning the clock. RunService never delivers such a dt in practice; the recommendation (not a requirement) is a one-line guard in each connection — `if dt ~= dt or dt < 0 then dt = 0 end` — so a hypothetical bad frame is dropped rather than raised inside the handler. Optional knobs the wrapper may pass per instance: `MaxDt = 0.25` (hitch clamp, Q-J16) and `MaxCatchUp = 1` for a render instance (cosmetic timers never burst, Q-J8). Other wrappers (`StrikeTickAPI.luau`, the `FxPackageLite` wrapper) become one line each — `Veron.new{ Name = "StrikeTick" }` — plus their existing connection (M3).

## 7. Compatibility layer + accepted deviations (→ `build/docs/MIGRATION.md`)

### 7.1 Preserved verbatim (D19, CS §3; all zero-cost aliases, no shims)

| Live shape (count) | Provided by |
|---|---|
| `TickAPI.Tick/.Tickh/.Tickr .delay(fn,t)` / `.recur(fn,t)` dot-called, truthy table handle (206 calls; `type(x) == "table"` discriminators, `EntityActionClass:88`) | dual closures `delay/recur`; handle is a table with a metatable |
| `.update(dt)`, `.remove(h)`, `.getClocks()` (wrappers, Cmdr) | closures `update/remove/getClocks` |
| `TickAPI.Tick:remove(h)` colon (2 sites) | dual closure shifts `self` — now actually removes (DV-3) |
| `TickAPI.SafeStopClock(h) → nil` (68 sites, 19 reassign idiom) | TickAPI's wrapper unchanged; `h:stop()` is total on nil-safe, terminal and foreign handles and finalizes a Fired one (§6) |
| `TickAPI.GetAfterNotTouched(t, fn, "Tickh") → {Touch, Destroy}` (1 site) | TickAPI's `AfterNotTouchedClass` unchanged over `.delay` + `:reset()` + `SafeStopClock` (§6) |
| `h:stop()` (12), `h:reset()` (9, 2 on recur), `h:adjust(n)` (2), `h:after()` (0) | LEGACY SURFACE of `VeronEvent`: `stop = Stop, reset = Reset, adjust = Adjust, after = After, Destroy = Stop`; LEGACY SURFACE of `Veron` (one closure per spelling, §3.2): `update, delay, recur, remove, Remove, getClocks, ForceEventComplete` — the alias set is closed (Q-J7) |
| `tonumber` coercion; `delay(fn, 0)` legal (`CameraClass:307`); stop from inside own callback (21 sites); cross-wrapper stop via `h:stop()`; `TimeManagerAPI = require(TickAPI)`; global `TickAPI` leak (`xray:87`) | §4.1, §4.3, TickAPI module identity unchanged |

### 7.2 Migration order (each step has a verify and a rollback)

| # | Step | Verify | Rollback |
|---|---|---|---|
| M0 | Lune: full suite + parity green; `alloc_spec` 0 B; run `studio_bench.luau` once in Studio with `--!native` | `lune run build/tests/run.luau` → 0 failed | — |
| M1 | Copy `SharedModules/TickAPI` to `ServerStorage/TickAPI_Legacy` (disabled); install the `Veron` module tree (`Veron` + children `VeronEvent`, `Env`) under `SharedModules/TickAPI`; edit TickAPI.luau's three require+connect blocks (§6); delete the legacy `Tick`/`Tick2`/`Tick3` ModuleScripts | Play: on server and client `TickAPI.Tick.GetStats().Updates > 0` and `TickAPI.Tickh.GetStats().Updates > 0` (client: `Tickr` too) after a few frames; no `Update(dt)` error in the output | swap folders back |
| M2 | Sign-off on the §7.3 "who notices" sites, especially `PrimaryCardControler` (hover-card timers now cancelled, DV-3) and the recur-nested files (DV-7): `LegacyRecurBase = true` on `Tick`/`Tickh` for an A/B | manual Studio checks; `GetStats().Reentries/ValveHits == 0` after a session | flip `LegacyRecurBase` / pass `true` to an affected `recur` / `MaxDt = false` per instance |
| M3 | `StrikeTickAPI.luau` and the `FxPackageLite` wrapper each build their own instance — `Veron.new{ Name = "StrikeTick" }` (one line each) — and keep their own connection; delete their legacy `Tick` child copies | `UpdateAction_ActionServerHitScan`, `Action_ConeHitScan` strike windows fire; `SafeStopClock` on strike handles still stops them | restore the files |

Out of scope, listed in MIGRATION.md: the RoBase plugin's wrapper copy (`PluginGuiService.CoreHolder.Core.TickAPI`, 42 files, Q-J13); SyncedTimerClass (Q-J14); the two live caller bugs (`DashStacks:22` call-result-as-fn; `UpdateAction_ActionServerHitScan:113` wrong-timer adjust, S-15; Q-J13); `CharacterSheet:772` `SafeStopClock` on an Instance (legacy raises `stop is not a valid member`; unchanged, the wrapper's concern).

### 7.3 Accepted deviations (each pinned two-sided in `parity_spec`/`repros_spec`, §9; DV-16/18/19/22 left with their scope)

| DV | Legacy | New | Who notices (live) |
|---|---|---|---|
| DV-1 | same-due order newest-first, scrambled by removals (L-13); multiple `after()` newest-first | `(due, Id)` FIFO; children in registration order (D23) | `DungeonCreator:167-179`, `xray:63-87`, `FxPackage:680/741` — order-independent; 0 `after` callers |
| DV-2 | nested past-due event fires synchronously inside `delay()`, returns a noop dummy (L-04) | later in the same update, real handle returned (D5) | `CameraClass:312-322` (delay-0 inner: one dispatch later, harmless) |
| DV-3 | `TickAPI.Tick:remove(h)` colon = silent no-op + leak (L-12) | works: the instance's dual closures make `TickAPI.Tick:remove(h)` remove | `PrimaryCardControler:124,141` — hover-card timers now cancelled as intended |
| DV-4 | NaN/inf delay accepted as zombies; recur 0 hangs; `adjust(≤0/NaN)` poisons (L-07/F5/L-10) | rejected at creation / adjust (D10) | zero speed at `CharacterSheet_Animation:158`, `UpdateAction_ActionServerHitScan:459` now errors instead of poisoning |
| DV-5 | stop-after-fire leaks a key (F3); adjust/reset on a dead handle silently mutate | terminal handles are no-ops (D8) except `Restart()` (the one explicit re-arm of a Fired handle) and `Stop` on Fired (finalizes it: `_Fn = NOOP`, Stopped stays final) | 68 `SafeStopClock` sites stop leaking and release the closure; adjust-after-fire → silent no-op |
| DV-6 | parent callback throw kills its `after` chain (B-13) | children still arm | none (0 `after` callers) |
| DV-7 | timer created inside a RECURRING callback waits one extra period (L-01) | measured from the firing due (D4): such timers fire about one parent-period EARLIER — a fixed lateness per nested timer, not cumulative drift | ≤ 26 files that `recur` and `delay` on one instance (e.g. `FxPackage:1049→680/741`, `EventSpawnerClass:406→345`), listed in MIGRATION.md; `LegacyRecurBase = true` reproduces the quirk per instance |
| DV-8 | recurring `stop()` inside own callback while lagging still fires the backlog (L-06) | exactly one fire | 15 "poll until ready then stop" recur sites — strictly better |
| DV-9 | stopping a co-due sibling double-ticks an already-processed entry (L-02) | never | `EntityActionClass:81-95` |
| DV-10 | unbounded catch-up burst after a hitch (L-08) | 8 per handle per update, remainder dropped on-grid (D6); `Recur(fn, p, true)` restores the legacy burst (valve-bounded, nothing lost); a render instance may be built with `MaxCatchUp = 1` | `Tickr.recur 0.01` refresher, `0.048` blink, 1/24–1/30 flipbooks: no burst after a hitch |
| DV-11 | `delay(3×dt)` fires on the 4th frame (L-14) | same class of one-frame lateness, documented, no epsilon (D23) | nobody |
| DV-12 | `getClocks()` always 0 (F7) | real count | 0 callers |
| DV-13 | `after()` on a terminal parent = silent never-fire (L-11) | Fired → arms now; Stopped → Stopped child | 0 callers |
| DV-14 | hook `dt` passed raw (a 2 s hitch = 2 s of timer time) | unchanged by default (`MaxDt = false`, Q-J16); an instance built with `MaxDt = n` clamps `Update(dt)` to n and counts `ClampedDt` | nobody until TickAPI opts in per instance |
| DV-15 | a throwing callback aborts the frame and poisons `err` (F4/L-03) | isolated, warned, `OnError` policy | everyone, positively |
| DV-17 | `remove(number)` removes by array index / raw error (L-15) | `false` | none |
| DV-20 | raw internal errors (`attempt to index nil with 'parent'` on `h.stop()`) | every new error prefixed (`Veron '<N>':`/`VeronEvent:`); legacy validation strings byte-identical; handle dot-calls raise the colon message | nobody pcall-matches these |
| DV-21 | re-entrant `update()` from a callback runs unguarded on the same array (L-16) | a real nested pass, depth-capped at 8, counted in `Reentries`, warned once | none |
| DV-23 | `update(dt)` with negative dt silently grows timers, NaN poisons the group, `nil` errors mid-loop, `"0.5"` is coerced (I10/I11/I13) | prefixed error before touching state | no live caller calls `update` (CS §1a) except TickAPI's three connections — §6 recommends the one-line guard |
| DV-24 | `CurrentType: ` suffix reports `type()` of the coerced value (`{}`/`true` → `nil`, an Instance → `userdata`) | `typeof` of the original argument (`table`/`boolean`/`Instance`, D10/L-17); templates unchanged | nobody pcall-matches; `HardPointSFXManager:57` message gets more useful |

### 7.4 Prior build (TickAPIOptimize 2.0.0) → 3.0.0 rename table (BC R3; `docs_spec :: MIGRATION.md maps every prior 2.0.0 name`)

| Prior | New | Prior | New |
|---|---|---|---|
| `TickAPI.new(variant)` | `Veron.new(cfg)` | `group:pause/resume/getRemaining` (group-level) | `s:Pause/Resume` / `h:GetRemaining()` |
| `h:pause/resume/getRemaining/setPeriod/getState/isActive/complete/fireNow` | `h:Pause/Resume/GetRemaining/SetPeriod/GetState/IsActive/Complete/CompleteNow` | `group:now/setTimeScale/getTimeScale/clear/getStats` | `s:Now/SetTimeScale/GetTimeScale/Clear/GetStats` |
| cfg `name/timeScale/maxCatchUpPerFrame/onError` | `Name/TimeScale/MaxCatchUp/OnError` | stats `examined/stale/live` | dropped (`Pending/Paused/HeapSize` replace them; no stale entries exist) |
| lowercase prior spellings | deliberately absent (Q-J7): `h:pause()` hits the dict miss → `attempt to call a nil value`, so migrate by grep | | |

## 8. Decisions on the open questions

| Q | Pick | Rationale |
|---|---|---|
| Q-J1 | Fix the recur-nested lateness (L-01, D4); `LegacyRecurBase` per instance; MIGRATION.md warns that timers created inside recurring callbacks now fire about one parent-period EARLIER (a fixed lateness per nested timer, not cumulative drift) and lists the ≤ 26 files | The quirk is proportional to the parent period and silent; the flag makes any A/B a one-line change; two-sided parity pin (legacy 2.500 vs new 1.517 at 1/60, and `LegacyRecurBase == legacy`). |
| Q-J2 | `Complete()` deferred (next update), `CompleteNow()` synchronous | The five live ForceEventComplete callers run their own cleanup right after the call (S-14/CS-04); synchronous-by-default would run expiry callbacks BEFORE that cleanup on migration day. |
| Q-J3 | Reject `+inf` and NaN | A timer that can never fire only holds memory; "hold indefinitely" is what `Pause()` is for; no live site passes it (I5). |
| Q-J4 | Out of scope | Whether `Tickr` exists on the server is TickAPI's construction logic (§6). |
| Q-J5 | `Remove(nil/non-handle)` → silent `false`; `Strict = true` errors; foreign handle → always error | SafeStopClock semantics for teardown paths (68 sites); a foreign handle is always a wiring bug (S7). |
| Q-J6 | Out of scope | Keyed timers are gone with SyncedTimer convergence (Q-J14). |
| Q-J7 | PascalCase canonical + the frozen legacy aliases: instance `update/delay/recur/remove/getClocks` + `Remove` (D18) + `ForceEventComplete` (D7); handle `stop/after/adjust/reset` + `Destroy`; nothing else (no `Count`, no handle `ForceComplete`) | One canonical spelling; the alias set is closed so the surface cannot drift (BC R1–R3). |
| Q-J8 | `MaxCatchUp` 8 / `Valve` 1000; no render special case in the class — TickAPI passes `MaxCatchUp = 1` when it builds its render instance | 8 covers the 0.01 s refresher (≈2/frame) and flipbooks; the valve bounds nested arms and uncapped repeats. |
| Q-J9 | Three constructor spellings — `Veron.new(cfg)`, `Veron:new(cfg)`, `Veron(cfg)` — one `initialize` | Jake's `NewTick.new()` shape works via the 3-line static override; no registration anywhere. |
| Q-J10 | Out of scope | Memory categories are TickAPI's concern (it owns the frame handler). |
| Q-J11 | Manual `Update` is THE way to drive a Veron | TickAPI's connection, tests, catch-up stepping and `Drive` pumps all call `Update(dt)`; there is no other driver. |
| Q-J12 | Out of scope | There are no built-ins in the class; `Destroy()` takes no options. |
| Q-J13 | Out of scope; the RoBase plugin copy and the two live caller bugs are listed in MIGRATION.md | Different require root; fixing callers is a game change; DV-3 fixes the colon site by construction. |
| Q-J14 | SyncedTimer convergence is out of scope | — |
| Q-J15 | Yes: vendored BaseClass, test-only, hash pinned (`21960b8e125d1cd5`), diff-checked by `env_spec` | BC strategy (c); vendored from HeroicSouls, not GitHub. |
| Q-J16 | `MaxDt` off by default (`false`); config per instance (`MaxDt = n` in the constructor or `SetMaxDt(n)`) | Legacy behaviour by default (a hitch is timer time); the wrapper opts an instance in when it wants the clamp; `ClampedDt` makes it visible. |
| Q-J17 | The build is named **Veron**: class `Veron`, handle `VeronEvent`, module tree `build/src/Veron/`, ModuleScript `TickAPI.Veron`; the TickAPI FIELDS `Tick/Tickh/Tickr` keep their names (300+ callers use `TickAPI.Tick.delay`); the legacy reference module and the research ids are not renamed | Jake: "The new build i would like to call 'Veron'" (A9). `Veron` is verified unused in HeroicSouls; renaming the fields would be a game-wide edit for nothing. |
| Q-J18 | Touch patterns on the handle: `Toggle()` (Pending ↔ Paused, PWC flip on Chained) and `Restart()` (the ONE re-arm of a Fired handle; Stopped stays final); the three patterns are §2.4 and API.md carries the reuse-over-recreate rule | Jake: "reset after touched … recur till touched, or a recur switch, where we can touch, and it starts back up, and if we touch it stops" and "is it more costly to destroy and recreate timers or is it better to create one that we can reset and reuse" (A10). Reuse is a 0 B heap move, recreate is a 576 B table per timer (§2.4); a post-fire `Stop` finalizes a Fired handle and Stopped stays final, so the 68 `SafeStopClock` sites keep their meaning; the Fired re-arm takes a fresh `Id` so the valve bounds a self-restarting handle (§4.4). |

## 9. Test plan (`build/tests/spec/<area>/<name>_spec.luau`; runner `lune run build/tests/run.luau`; spec shape per W/CLAUDE.md)

Support (`build/tests/support/`, no `_spec` suffix): `oracle.luau` — `Oracle.check(s)` = `assert(s:Validate())` plus the §3.2 list re-derived independently (so a broken `Validate` cannot hide a broken heap); `Oracle.wrap(s)` returns a proxy whose every public instance AND handle call runs the op then `check`, and re-checks inside callbacks (every re-entrancy test asserts `Validate()` from inside the callback). `legacy.luau` (adapters over `reference/lune/Tick.luau`, the prior's parity oracle verbatim). `gen.luau` (seeded op generator, seed 20260916). Every spec below runs through `Oracle.wrap` unless marked raw.

| Spec file | Named tests (`file::name`) |
|---|---|
| `env/env_spec` | `Lune load resolves the vendored BaseClass`; `vendor BaseClass differs from reference only at the JsonR lines` (sha `21960b8e125d1cd5`); `SetWarn restores`; `Load resolves siblings`; `IsRoblox is false under Lune and Env exposes exactly IsRoblox/BaseClass/Warn/Traceback/Load/SetWarn` *(superseded 2026-09-16 — see banner; the first two tests and the `BaseClass` key are gone, current `env_spec` runs 3 tests over 5 keys: `build/tests/spec/env/env_spec.luau`)* |
| `heap/heap_spec` (raw) | `push then drain is sorted by (due, Id)`; `20000 random push/pop/remove/updateKey keep the invariant every 97 ops` (F-ALG-14); `remove of the last element`; `remove of a middle element sifts the right way`; `updateKey decrease and increase`; `ownership check refuses a foreign handle`; `clear resets every _HeapIndex` |
| `scheduler/arm_spec` | `delay 0 fires next update even with dt 0` (I1); `recur 0 errors with the prior message` (I2); `negative delay legacy message` (I3); `NaN and inf rejected` (I4/I5); `non-number reports original type` (I6/L-17); `numeric string coerced` (I7); `callable table accepted, non-callable errors first` (I8); `dead instance refuses delay/recur/update`; `recur third argument: nil and false capped, true uncapped, non-boolean errors before any mutation` (`Recur(fn, 0.1, "all")`, `Recur(fn, 0.1, 1)`, `Recur(fn, 0.1, {})` → the validation-family string; `RecurCount` and the heap untouched); `Drive third argument: nil and true uncapped, false capped, non-boolean errors and leaves the child unattached`; `unknown opts key errors in Complete/CompleteNow` (`{stop = true}` lowercase rejected); `non-table opts errors with the prefix` (`Complete(h, 8)`) |
| `scheduler/time_spec` | `update 0 flushes due` (I9); `negative, NaN, inf, nil, string dt error before touching state with the prefixed message` (I10/I11/I13/B-05); `rolling clock accumulates dt * TimeScale`; `TimeScale 0 freezes, delay 0 still fires` (B-16); `SetTimeScale rejects NaN/inf/negative`; `UpdateTo first call anchors without sweeping relative timers`; `UpdateTo exact at scale 1 after 1e6 samples`; `UpdateTo backwards clamps, counts, warns once over 1 s`; `instance Pause folds the UpdateTo gap into the offset`; `DelayAt fires on the external axis and errors before the first UpdateTo`; `DelayAt at TimeScale 2 fires at the external time`; `first UpdateTo while paused dispatches nothing`; `paused instance: Update(0) and first UpdateTo do not dispatch; Complete waits for Resume`; `Now starts at 0`; `GetBase is false at top level and the ideal due inside a callback`; `MaxDt off by default; when set Update(dt) clamps and counts ClampedDt` (`Veron.new{}`: a 5 s dt advances 5 s, `ClampedDt == 0`; `Veron.new{ MaxDt = 0.25 }`: it advances 0.25 s, `ClampedDt == 1`, `LastDt == 0.25`; `UpdateTo` never clamps) |
| `scheduler/dispatch_spec` | `only the due prefix is examined`; `one-shot is Fired before its callback` (S1); `recurring is re-keyed before its callback`; `equal dues fire in creation order` (C4); `re-armed recurring keeps its Id rank` (D23); `nested past-due one-shot fires later in the same update with a real handle` (C2/L-04); `nested delay 0 fires in the same update` (C3); `nested delay measured from firing due` (C1); `nested inside recur corrected` (DV-7); `LegacyRecurBase reproduces legacy`; `cross-instance creation uses the other now` (N5); `Delay(3*dt) one update late is documented, not fudged` (L-14); `throwing callback does not stop siblings` (E1); `error policy re-raises first after the outermost pass` (E2); `function policy receives (message, handle); its own error is warned` (E3); `erroring chained child leaves siblings alone` (E4) |
| `scheduler/catchup_spec` | `cap 8: 5 s hitch on a 0.1 s recur fires 8 then snaps to the grid` (D6); `phase is preserved after a snap`; `uncapped fires every grid point` (L-15); `drop fires once per update` (`h:SetCatchUp("drop")`); `per-handle SetCatchUp overrides, inherit drops the override`; `instance SetMaxCatchUp/GetMaxCatchUp at runtime` (inheriting handles follow, overridden ones do not); `Dropped counts skipped grid points`; `period below float resolution stops the handle with one report` (capped); `uncapped recur with sub-resolution period never hangs`; `valve: zero-delay self-rescheduling one-shot stops at 1000, warns once via OnError, resumes next update` (B-02/C5); `valve: a zero-period one-shot that Restarts itself from its own callback stops at 1000, warns once, resumes next update` (the Fired re-arm's fresh Id, §4.4; also two Fired siblings restarting each other); `valve counts repeats under uncapped`; `valve never trips on a 10k pre-existing one-shot storm`; `mutual Complete between two uncapped recurs is valve-bounded`; `uncapped recur after a hitch fires every owed tick across updates when the valve trips (nothing lost)` (a 1/1024 s uncapped recur armed at 0, then `Update(2)`: exactly 2048 fires owed (dyadic, B-20); `Valve = 100`: the pass delivers `Valve + 1` = 101 fires (the first is not a repeat), `ValveHits == 1`, the handle still keyed at its grid; each further `Update(0)` delivers 101 more; after 21 passes `total fires == 2048 == owed`, `Dropped == 0`, `ValveHits == 20`) |
| `scheduler/reentrancy_spec` | `stop self inside own recurring callback while lagging fires once` (S2/L-06); `stop a co-due sibling from a callback never fires it and nothing advances twice` (S3/L-02); `replace-in-callback idiom lands at the correct due`; `stop then reset in the same callback does not resurrect` (S4); `sync re-entrant Update dispatches other timers and restores the base` (B-04 #2); `nested Update under error policy keeps the outer raise and reports once` (B-04 #1); `recurring callback calls Update(period): bounded at MaxUpdateDepth, never overflows` (B-04 #3); `depth cap degrades to advance-only`; `yield-overlap (coroutine) keeps other timers firing and drains on resume` (L-05); `out-of-order yield overlap leaves depth 0 and _Base false`; `recurring whose callback yields past its period fires again from the inner pass`; `top-level Delay during a yield window measures from now` (R-D: a third coroutine arms while the callback is suspended → due = now + t, never base + t); `task.spawn from a callback measures from now`; `Update(0) inside a callback keeps the caller's base after the nested pass`; `a throwing Warn seam leaves UpdateDepth 0 and Base false after the error`; `a corrupted handle field raises the internal-fault message once and leaves the instance consistent`; `sync re-entry chain is bounded per pass: Delay(0)+Update(0) recursion ≤ MaxUpdateDepth × Valve dispatches`; `Destroy from inside own update fires nothing further` (N4); `Clear from inside a callback: later same-frame handles do not fire`; `Validate holds inside every callback above` |
| `handle/state_spec` | `every public method is a no-op on Stopped and, Stop/Restart excepted, on Fired; each returns h`; `every public method is a no-op on Stopped and, Stop/Restart excepted, on Fired even with invalid arguments` (`firedHandle:Adjust(0/0)`, `:SetRemaining(-1)`, `:SetPeriod(nil)`, `:SetCatchUp("bogus")`, `:After(nil, 1)` → no raise); `pause on Paused, resume on Pending are no-ops, never a raw transition error` (R8/RF-006); `pause freezes remaining, resume arms from now`; `paused recurring accumulates no missed fires`; `pause while Chained then parent fires → Paused with remaining = delay` (A8); `resume while Chained clears the flag`; `GetState inside own callback reads Fired`; `GetRemaining per state` (R9/B-14); `IsActive per state`; `Destroy alias equals stop` (S10); `handle dot-call raises the colon message` (S9/B-18); `Describe strings`; `Toggle flips Pending and Paused, flips PWC on Chained, no-op on terminal and COMMITTED`; `Restart re-arms a Fired one-shot from now with its full period and it fires again`; `Restart re-arms a Fired recurring as recurring` (via `Complete{Stop = true}`); `Restart on Stopped is a no-op (Stopped is final)`; `Restart on Pending/Paused equals Reset then Resume`; `Restart on a handle of a destroyed Veron is a no-op`; `a Fired handle keeps its function until Restart or Stop, a Stopped handle has NOOP` (Q-J18) |
| `handle/stop_spec` | `double stop no-op`; `remove nil false`; `remove non-handle false, Strict errors`; `remove number false` (L-15); `foreign handle errors with both names` (S7); `h:Stop on a foreign handle still works`; `h:stop() on a Fired handle is silent and makes it final (Stop returns false)` (the wrapper's `SafeStopClock` path: → Stopped, `_Fn == NOOP`, a later `Restart()` is a no-op); `instance colon form TickAPI.Tick:remove(h) removes` (S8/DV-3); `parent stop cascades through grandchildren` (A2) |
| `handle/retime_spec` | `adjust preserves consumed fraction` (R1); `adjust rejects 0, negative, NaN, inf, nil`; `adjust on period 0 uses the whole newTotal, never NaN` (R3/RF-001); `adjust on Paused scales remaining`; `adjust on Chained sets the delay`; `adjust inside own lagging recurring callback fires at most twice` (B-01); `pause+resume inside lagging callback bounded`; `setPeriod affects future arms only` (R4); `reset one-shot full period from now even from another callback` (R5/P4); `reset recurring restarts phase` (R6); `reset inside own recurring callback replaces d+period` (R7); `SetRemaining leaves period` (S-12); `explicit ops from now not base` (R10) |
| `handle/chain_spec` | `child stopped before parent never fires` (A1/F8); `after on recurring errors` (A3); `After on Fired arms from the caller's clock, never returns the parent` (A4/B-07: base inside the firing thread, now at top level); `after on Stopped returns a Stopped child` (A5); `After on a handle of a destroyed instance returns a Stopped child` (no `destroyed` raise); `multiple children fire in registration order` (A6); `3-deep chain` (A7); `children arm from parent ideal due` (A9); `children of a deferred-completed parent arm from the completion time`; `erroring parent still arms children` (A10/B-13); `Complete on a Chained child detaches it: parent later skips it`; `parent Stop after child Complete leaves the completed child armed and firing` (F2); `Clear/Destroy with a completed child does not corrupt the walk` (under `Oracle.wrap`, from inside a callback); `GetRemaining on a Chained child is its delay`; `After on a restarted parent chains normally; old children never re-fire` (Q-J18) |
| `handle/complete_spec` | `deferred re-keys to now and fires next update in order` (F3); `completes a non-root entry` (S-01); `Complete from inside a pass on a later entry fires once this pass` (F5); `recurring fires once then re-arms from now`; `opts.Stop ends a recurring and Recurring stat drops`; `paused recurring completes and stays paused with full period` (D7); `Resume after a deferred Complete on a Paused recurring is honoured`; `Reset after a deferred Complete on a Paused recurring does not resume it` (COMMITTED: Reset/Adjust/SetRemaining/SetPeriod are no-ops; `IsPaused()` true; `GetState()` "Pending"); `Pause after a deferred Complete is a no-op until the fire`; `Pause/Reset after Complete{Stop=true} keep the forced final fire` (F6); `chained completes detached`; `Complete from own callback returns false` (F6); `top-level Complete on a yielded recurring returns true and fires` (R-D); `CompleteNow inside own callback returns false`; `nested Update inside a CompleteNow callback keeps the base and the own-callback guard` (F5; `Validate()` holds inside the callback); `mutual CompleteNow A->B->A stops at the COMPLETING flag`; `CompleteNow nesting beyond 8 is refused via OnError`; `terminal and nil return false` (F7); `error inside CompleteNow reported after transitions` (E5); `exactly one fire when completed mid-update`; `instance Complete(nil/non-handle) is false, foreign errors`; `{stop=true} lowercase is rejected`; `ForceEventComplete alias` |
| `scheduler/lifecycle_spec` | `Destroy clears, marks dead, detaches from its parent; twice is a no-op`; `Attach: parent Destroy destroys the child, Clear clears the child` (N3); `Attach refuses self, destroyed, double-attach, cycle`; `child Destroy detaches from its parent`; `Detach stops the cascade`; `Drive advances the child by period per parent fire` (N2); `Drive under a hitch — uncapped keeps child time, capped drops it` (JF-15); `Drive always attaches; mutual Drive is refused as a cycle`; `Drive stops itself after child Destroy without OnError noise`; `Children stat tracks Attach/Detach/Destroy without a walk`; `GetClocks counts Pending + Paused only` (O1); `GetStats fields present, cumulative, and a warmed GetStats(into) allocates nothing`; `repeated callback errors are rate-limited and counted` (same handle ≤ 1 report/s, distinct handles ≤ 8/s, `Errors` exact, `ErrorsSuppressed` counted; "error" policy unaffected); `every diagnostic reaches a function OnError policy and never re-raises under "error"` (JF-16); `runtime setters validate like construction and take effect` (`SetValve(0)`, `SetMaxDt(-1)`, `SetStrict(1)`, `SetOnError("loud")`, `SetMaxCatchUp(1.5)` → prefixed option errors, state untouched; `SetMaxDt(0.25)` enables the clamp and `SetMaxDt(false)` disables it; `SetStrict(true)` makes `Stop(non-handle)` raise); `Validate reports a deliberately corrupted heap`; `handle ids ascend from 1 and are never reused` (O3; a Fired handle's `Restart` takes the next fresh one); `reset-after-touched, recur-till-touched and recur-switch patterns` (three scenarios, §2.4) |
| `class/class_spec` | `requiring every class module prints no "already Exsist" warning` (BC F8, captured `Env.SetWarn`); `handle isInstanceOf VeronEvent, class and type set on a literal handle` (D13); `handle literal has exactly 14 keys, every value non-nil` (F-ALG-9/BC F7); `every Veron field non-nil after initialize`; `every public Veron member has a dot and a colon closure`; `aliases share one closure object` (`s.Stop == s.Remove == s.remove`); `all three constructor spellings build the same shape` (Q-J9: `Veron.new{}`, `Veron:new{}`, `Veron{}`; `Veron.new()` with no config); `legacy alias table is complete` (D15: exactly the Q-J7 set); `VeronEvent:new and VeronEvent() raise the construction error` (JF-05); `no __index or __tostring declared on any class` (BC F1); `Fn/Period/IsRecur are not public fields` |
| `errors/errors_spec` | `every error blames the caller's chunk (level table §2, incl. cfg via new, Drive→Attach, Drive/Recur→uncapped; Veron(cfg) is the documented exception)`; `legacy validation templates are byte-identical to reference/live/Tick.luau and CurrentType reports the original type` (DV-24); `every error outside the validation family carries its class prefix`; `Stats.Errors increments` |
| `parity/parity_spec` | differential harness vs `reference/lune/Tick.luau`: one step list runs against the legacy `Tick.group()` (`reference/lune/Tick.luau`, reached through `build/tests/support/legacy.luau`'s `Legacy.group()` adapter) and `Veron.new{}` — unambiguous now that the new class is `Veron`; the generator's `recur` step arms `Recur(fn, p, true)` (legacy is uncapped); per update the SORTED fire list is compared; dyadic numbers (B-20). Steps `delay, recur, stop, reset, adjust, after, nest (inside a ONE-SHOT callback), update`. Generator constraints: no stop/reset/adjust from inside callbacks (DV-8/9), no `nest` inside recur callbacks (DV-7), no nested delay ≤ overshoot (DV-2). Tests: `500 seeded op sequences match`; `9 scripted prior scenarios match`; `default cap generator (never lags > 8 periods) matches` (`Recur(fn, p)` capped); `reference file is the live file minus the RunService line`; **two-sided pins** `DV-n legacy value AND new value` for every DV in §7.3 (20 pins; e.g. `DV-7: legacy 2.500, new 1.517, LegacyRecurBase equals legacy`; `DV-24: delay(fn, true) legacy 'CurrentType: nil', new 'CurrentType: boolean'`; `DV-14: legacy and new both advance 2 s on a 2 s dt, MaxDt = 0.25 advances 0.25`) |
| `regress/repros_spec` | one pinned test per research id: `L-01`, `L-02`, `L-03`, `L-04`, `L-05`, `L-06`, `L-07`, `L-09`, `L-11`, `L-13`, `L-15`, `L-16`, `B-01`, `B-02`, `B-03`, `B-04`, `B-05`, `B-06`, `B-07`, `B-13`, `B-14`, `B-18`, `RF-001`, `RF-006`, `RF-010`, `S-01`, `S-02`, `S-06`, `S-09`, `S-12`, `S-14`, `F5`, `F6` |
| `alloc/alloc_spec` | `1000 idle updates with 10k armed allocate 0 bytes`; `1000 busy updates with 50 noop dispatches each allocate 0 bytes`; `warmed GetStats(into) and Validate allocate 0 bytes` (one `GetStats(into)` call before measuring); `one table per Delay` (`collectgarbage("count")` deltas; 0 is exact under Lune) |
| `docs/docs_spec` | `every public member of §2 appears in build/docs/API.md`; `API.md states the retention rule at the top` (O4); `API.md explains the rolling-clock decision in plain language` (§4.8 paragraph, JF-04); `API.md documents the per-instance footprint`; `every DV of §7.3 appears in MIGRATION.md`; `MIGRATION.md maps every prior 2.0.0 name` (§7.4); `MIGRATION.md lists M0–M3 and the out-of-scope items`; `MIGRATION.md lists the recur-nested files and the one-period-earlier warning` (Q-J1); `API.md states the reuse-over-recreate rule with the 576 B / 0 B numbers` (Q-J18) |

Count: 19 spec files, 221 named tests (env 5, heap 7, arm 12, time 16, dispatch 16, catchup 15, reentrancy 20, state 20, stop 9, retime 13, chain 15, complete 23, lifecycle 18, class 11, errors 4, parity 4, alloc 4, docs 9) + 20 two-sided DV pins + 33 pinned repros; the parity harness runs 500 seeded + 9 scripted sequences.

## 10. Bench plan (`build/bench/bench.luau`, Lune, seeded 20260916, median of 5; `studio_bench.luau` = command-bar port with `--!native`)

| Phase | What it proves |
|---|---|
| P1 arm 10k random dues | ns/op ≤ 1.2× IB prototype (250 ns); bytes/handle == 576 + heap slots (literal sized once, no rehash) |
| P2 200 idle updates with 10k armed | ≤ 2× the IB prototype on the same machine (the §4.2 fast path is ~10 field ops + 0 calls vs the prototype's ~12; the pre-fast-path design was ~32 ops, F-PM-6); **`collectgarbage("count")` delta == 0 KB exactly** is the hard assertion (D1/D24; F-ALG-3). Baseline op counts read against this line: idle `Update(dt)` ≈ 6 field ops (validate, clamp check, `_LastDt`, pause check) + 10 in `_advanceTo`, 1 call; one-shot dispatch ≈ 20 hash-field ops + O(log n) sift + 1 `xpcall`; recurring dispatch ≈ 18 hash-field ops + 1 `xpcall`; plus one `xpcall(_pass)` + one `coroutine.running()` per non-idle pass (F-PM-0) |
| P3 10k shuffled stops | flat ns/op, no spike > 0.2 ms; heap size 0 after; paused index empty |
| P4 10k shuffled adjusts / P5 10k resets | heap size stays 10k (no orphans, F-ALG-1); in-place re-key cost |
| P6 fire storm 10k in one update | ns/dispatch; all fired; `ValveHits == 0`; `Dispatched == 10000` |
| P7 10k recurring × 600 updates @ 1/60 | µs/update, ns/fire; garbage 0 |
| P7b tie-heavy: 10k recurring, equal period, created in one frame | decides `Id`-on-handle vs a third `seq[]` array (ALG §3.1 note) |
| P8 mixed churn 2k live (50 arms / 20 stops / 10 adjusts / ~50 fires per update × 600) | the realistic number; regression guard ±15 % vs the recorded baseline |
| P9 adjust storm 10 rounds | max round ms, max single op, heap size 10k after, no rebuild spikes |
| P10 dual-call overhead | `s.delay` vs raw dict method ≤ +30 ns |
| P12 re-entrancy tax | pass at depth 1 vs 0: identical within noise |
| P14 legacy baseline (`reference/lune/Tick.luau`) P2/P7/P8 | the headline "×" numbers for the report |
| P15 construct + destroy 1k Veron instances | µs and resident bytes per instance (34 closures + ~90-key instance + 4 tables `_Due/_Item/_Paused/_Children`); the number API.md quotes next to the retention rule (F-PM-7/JF-23) |

Phase ids are kept stable across revisions (hence the gaps: P11 was removed 2026-09-17 with the BaseClass dependency, P13 never existed). Regression rule: `alloc_spec` asserts the zero-garbage phases on every suite run; timings are reported, not asserted, under Lune. The Studio port asserts `<native>` in the Script Profiler and reports P2/P7/P8/P9 deltas.

## 11. Risks & mitigations; out of scope

| Risk | Mitigation |
|---|---|
| Yield-overlap correctness (a callback suspended mid-pass while another pass runs) | R-C decrement-only depth, in-place mutations, `_Base` cleared at depth 0; coroutine-driven `reentrancy_spec` incl. the out-of-order case; `Reentries` stat + warn once |
| DV-7 timing change surprises FX tuning | `LegacyRecurBase` per instance; migration grep; two-sided parity pin; MIGRATION.md's "one parent-period earlier" warning |
| DV-10 drop policy loses ticks for logic timers (DoT/regen) | `Recur(fn, p, true)` per handle (valve-bounded, hang-proof, nothing lost); `Dropped` stat; MIGRATION.md call-out |
| `MaxDt` clamp (when an instance opts in) changes wall-time behaviour after hitches | off by default (Q-J16); documented; `ClampedDt` visible; `SetMaxDt(false)` reverts |
| uncapped + valve: a mass hitch on many lagging uncapped handles trips the valve and spreads the remainder over following updates | only uncapped handles count repeats (the default cap never does); nothing is lost (the timer stays keyed); `ValveHits` exposes it; `Valve` configurable |
| `--!native` disabled silently (breakpoints, typed-arg mismatch) | Studio bench checks `<native>`; hot loop uses only locals and arrays |
| Bound-closure shadowing hides a class method change | closures are built from `dict[name]` in `initialize`; `class_spec` asserts every public method has both closures |
| `OnError = "error"` re-raising out of `update(dt)` inside TickAPI's RunService handler | the re-raise happens once at the outermost exit; Roblox isolates a handler error, so the connection survives; documented in API.md |
| Allocating queries called per frame | only `GetStats()` (no `into`), `GetChildren`, `Describe` allocate; API.md marks them "not per-frame" |
| 14-key handle literal has two slots of headroom | `class_spec` pins the key count; a 15th or 16th field is a design change but still fits the 16-node hash part (576 B); a 17th steps to 1088 B/handle; the F1/F5/F-PM-3 fixes were deliberately placed on the INSTANCE (`_FiringThread`, `_LastErrorId/_LastErrorAt`) for this reason |
| Per-pass valve/burst scope | a sync re-entry chain may dispatch up to `MaxUpdateDepth × Valve` per outer Update (8000 default) — bounded, `Reentries` + `ValveHits` expose it; `SetValve`/`MaxUpdateDepth` tune it (F14) |
| Per-instance footprint (34 closures + 41 keys; ~7-9 KB, ~40 GC objects expected) | bench P15; API.md advises one `Drive`n child per subsystem, never one Veron per entity; aliases share closures (F-PM-7) |
| `Restart()` re-runs a Fired handle's callback: a stale reference could revive work whose owner is gone | `Restart` is explicit and never implicit (no other verb leaves Fired); an explicit `Stop` on a Fired handle (`SafeStopClock`, `h:stop()`, `h:Destroy()`) finalizes it — Stopped, `_Fn = NOOP`, `Restart` refused — so the 68 stop-after-fire sites release the closure as before; instance `Destroy()` refuses `Restart` on every handle; `Clear()` cannot reach a Fired handle (it is in no container), so after a `Clear()` alone a Fired handle stays restartable and retains its closure until GC or an explicit `Stop` — stated in API.md next to the three verbs |
| A broken recurring callback at 60 Hz floods the console | `_report` rate limit (same handle ≤ 1/s, distinct ≤ 8/s), `pcall` instead of `xpcall` while suppressed (no traceback garbage), `Errors`/`ErrorsSuppressed` exact (F-PM-3) |
| Bad dt from the wrapper (`nil`/NaN/negative) now raises inside the handler (DV-23) | RunService never produces one; §6 recommends the one-line guard; the error is prefixed and raised before any state is touched |

Out of scope (and why): the registry, RunService binding, boot watchdog, `SafeStopClock`, `GetAfterNotTouched`/AfterNotTouched, `Tick/Tickh/Tickr` construction and memory categories (TickAPI's wrapper keeps all of them, §6); keyed timers and SyncedTimerClass convergence (Q-J6/Q-J14); RoBase plugin copies (Q-J13); game-side caller bugs (`DashStacks`, `UpdateAction_ActionServerHitScan:113`); a `NextUpdate` queue (a top-level `Delay(fn, 0)` already means "next update"; inside a callback it means "later this update" — documented); an owed-counter catch-up mode (uncapped already loses nothing; a post-loop counter is unnecessary); 4-ary heap and a third `seq[]` array (decide after the Studio bench, ALG R8); handle pooling (D13, ABA risk); payload varargs; Actors (RT-13).

## 12. Implementation work packages (independently buildable; acceptance = `spec path :: test name`)

| # | Package | Files | Depends on | Acceptance tests |
|---|---|---|---|---|
| WP1 | **Env seam (minimal)** — `IsRoblox`, `BaseClass`, `Warn`, `Traceback`, `Load`, `SetWarn` (§1); vendor hash check | `build/src/Veron/Env/init.luau` (vendor already present) | — | `build/tests/spec/env/env_spec.luau :: Lune load resolves the vendored BaseClass`; `:: vendor BaseClass differs from reference only at the JsonR lines`; `:: SetWarn restores`; `:: Load resolves siblings`; `:: IsRoblox is false under Lune and Env exposes exactly IsRoblox/BaseClass/Warn/Traceback/Load/SetWarn` *(superseded 2026-09-16 — see banner; no vendor, no hash check, no `BaseClass` key; current acceptance is `env_spec`'s 3 tests)* |
| WP2 | **Test support** — oracle (independent invariant walk + `Validate` call), legacy adapters, seeded generator; no fake RunService | `build/tests/support/{oracle,legacy,gen}.luau` | §3.2 invariants | exercised by every spec; smoke: `build/tests/spec/heap/heap_spec.luau :: 20000 random push/pop/remove/updateKey keep the invariant every 97 ops` |
| WP3 | **VeronEvent** — class, 14-key literal shape (built by the instance), colon guard, delegating methods incl. `Toggle/Restart` (§2.3, §4.10), queries, `Describe`, LEGACY SURFACE, `static.STATE_NAMES` | `build/src/Veron/VeronEvent/init.luau` | — (needs WP1's Env only to run its tests; buildable in parallel; contract §4.10) | `build/tests/spec/class/class_spec.luau :: handle isInstanceOf VeronEvent, class and type set on a literal handle`; `:: handle literal has exactly 14 keys, every value non-nil`; `:: Fn/Period/IsRecur are not public fields`; `:: VeronEvent:new and VeronEvent() raise the construction error`; `build/tests/spec/handle/state_spec.luau :: handle dot-call raises the colon message`; `:: every public method is a no-op on Stopped and, Stop/Restart excepted, on Fired; each returns h` (run after WP5: "every method" includes `After/Complete/CompleteNow`) |
| WP4 | **Veron core** — §4.1–4.5, 4.8, 4.11: config validation (§2.1), static `new` override, dual closures (shared per alias, §3.2 PUBLIC), heap (ALG §3.2), `_clockOf/_checkOpts/_validateUncapped/_validateArgs/_newEvent`, arm (`Delay/Recur/DelayAt`, `_SetCatchUp`), `_pass`/`_advanceTo` (idle fast path, protected pass), catch-up (capped/uncapped/drop), valve, re-entrancy (`_FiringThread`), `_diagnose`/rate-limited `_report`, stop cascade (state-gated, finalizes Fired, `_resolve` handle-only), `_clearTerminal`, pause/resume (COMMITTED rule), `_Toggle`/`_Restart` (§4.4; `_fireOneShot` keeps `_Fn`; the Fired re-arm re-issues the Id), retime, `Update` (with `MaxDt`)/`UpdateTo`/`Now`/`GetBase`/`TimeScale`/`Pause`/`Resume`/`IsUpdating`/`IsDestroyed`, `GetClocks/GetStats/Validate/Describe/Clear`. Definition order is the §4 module-head list (forward-declared `_advanceTo/_stopTerminal/_attach`) | `build/src/Veron/init.luau` (§3.2, §4.1–4.5, §4.8, §4.11) | WP1, WP3 | `heap/heap_spec` (all 7); `scheduler/arm_spec` (8 of 12 — after WP5: `:: unknown opts key errors in Complete/CompleteNow`, `:: non-table opts errors with the prefix`; after WP6: `:: dead instance refuses delay/recur/update`, `:: Drive third argument: nil and true uncapped, false capped, non-boolean errors and leaves the child unattached` — incl. `:: recur third argument: nil and false capped, true uncapped, non-boolean errors before any mutation`); `scheduler/time_spec` (15 of 16 — after WP5: `:: paused instance: Update(0) and first UpdateTo do not dispatch; Complete waits for Resume` — incl. `:: MaxDt off by default; when set Update(dt) clamps and counts ClampedDt`); `scheduler/dispatch_spec` (15 of 16 — after WP5: `:: erroring chained child leaves siblings alone`); `scheduler/catchup_spec` (13 of 15 — after WP5: `:: mutual Complete between two uncapped recurs is valve-bounded`; after WP6: `:: instance SetMaxCatchUp/GetMaxCatchUp at runtime` — incl. `:: uncapped recur after a hitch fires every owed tick across updates when the valve trips (nothing lost)`, `:: per-handle SetCatchUp overrides, inherit drops the override`, `:: valve: a zero-period one-shot that Restarts itself from its own callback stops at 1000, warns once, resumes next update`); `scheduler/reentrancy_spec :: recurring callback calls Update(period): bounded at MaxUpdateDepth, never overflows`; `:: out-of-order yield overlap leaves depth 0 and _Base false`; `:: yield-overlap (coroutine) keeps other timers firing and drains on resume`; `:: top-level Delay during a yield window measures from now`; `:: a throwing Warn seam leaves UpdateDepth 0 and Base false after the error`; `handle/stop_spec` (8 of 9 — after WP5: `:: parent stop cascades through grandchildren` — incl. `:: instance colon form TickAPI.Tick:remove(h) removes`); `handle/retime_spec` (12 of 13 — after WP5: `:: adjust on Chained sets the delay`); `handle/state_spec` (11 of 20 — after WP5, because "every method" includes `After/Complete/CompleteNow`, the Chained state needs `After` and a Fired recurring needs `Complete{Stop = true}`: `:: every public method is a no-op on Stopped and, Stop/Restart excepted, on Fired; each returns h`, `:: every public method is a no-op on Stopped and, Stop/Restart excepted, on Fired even with invalid arguments`, `:: pause while Chained then parent fires → Paused with remaining = delay`, `:: resume while Chained clears the flag`, `:: GetRemaining per state`, `:: IsActive per state`, `:: Toggle flips Pending and Paused, flips PWC on Chained, no-op on terminal and COMMITTED`, `:: Restart re-arms a Fired recurring as recurring`; after WP6: `:: Restart on a handle of a destroyed Veron is a no-op` — incl. `:: Restart re-arms a Fired one-shot from now with its full period and it fires again`, `:: Restart on Stopped is a no-op (Stopped is final)`, `:: Restart on Pending/Paused equals Reset then Resume`, `:: a Fired handle keeps its function until Restart or Stop, a Stopped handle has NOOP`); `class/class_spec :: all three constructor spellings build the same shape`; `:: every Veron field non-nil after initialize`; `errors/errors_spec :: legacy validation templates are byte-identical to reference/live/Tick.luau and CurrentType reports the original type` |
| WP5 | **Veron chains + complete** — §4.6, §4.7, flagged fire paths `_fireRepause`/STOP_ON_FIRE, `_SyncDepth`, COMPLETING, instance `Complete/CompleteNow(h, opts)` through `_resolve` | same file (sections appended after WP4) | WP4 | `handle/chain_spec` (13 of 15 — after WP6: `:: After on a handle of a destroyed instance returns a Stopped child`, `:: Clear/Destroy with a completed child does not corrupt the walk` — incl. `:: parent Stop after child Complete leaves the completed child armed and firing`, `:: After on a restarted parent chains normally; old children never re-fire`); `handle/complete_spec` (all 23, incl. `:: nested Update inside a CompleteNow callback keeps the base and the own-callback guard`, `:: top-level Complete on a yielded recurring returns true and fires`, `:: instance Complete(nil/non-handle) is false, foreign errors`); plus every WP4 test marked "after WP5" |
| WP6 | **Veron attach/drive/destroy + runtime setters** — §4.9: `Destroy` (no options), `_attach`/`Attach/Detach/GetChildren`, `Drive(child, period, uncapped)` (always attaches), `SetOnError/SetMaxCatchUp/GetMaxCatchUp/SetValve/SetMaxDt/SetStrict` | same file | WP4 | `scheduler/lifecycle_spec` (all 18, incl. `:: Drive under a hitch — uncapped keeps child time, capped drops it`, `:: Drive always attaches; mutual Drive is refused as a cycle`, `:: runtime setters validate like construction and take effect`, `:: repeated callback errors are rate-limited and counted`, `:: reset-after-touched, recur-till-touched and recur-switch patterns`); `handle/state_spec :: Restart on a handle of a destroyed Veron is a no-op`; `scheduler/catchup_spec :: instance SetMaxCatchUp/GetMaxCatchUp at runtime`; `scheduler/arm_spec :: Drive third argument: nil and true uncapped, false capped, non-boolean errors and leaves the child unattached`; `scheduler/reentrancy_spec :: Destroy from inside own update fires nothing further`; `scheduler/arm_spec :: dead instance refuses delay/recur/update`; `handle/chain_spec :: After on a handle of a destroyed instance returns a Stopped child`; `:: Clear/Destroy with a completed child does not corrupt the walk`; `class/class_spec :: every public Veron member has a dot and a colon closure`; `:: legacy alias table is complete` (the full PUBLIC list and `ForceEventComplete` exist only now); `errors/errors_spec` (all 4, incl. `:: every error blames the caller's chunk (level table §2, incl. cfg via new, Drive→Attach, Drive/Recur→uncapped; Veron(cfg) is the documented exception)` — the full surface exists only after WP4–WP6); plus every WP4/WP5 test marked "after WP6" |
| WP7 | **Parity + repros** — `parity_spec` (two-sided DV pins) and `repros_spec` (33 ids) | `build/tests/spec/parity/parity_spec.luau`, `build/tests/spec/regress/repros_spec.luau` | WP2, WP5, WP6 | `parity/parity_spec :: 500 seeded op sequences match`; `:: DV-7: legacy 2.500, new 1.517, LegacyRecurBase equals legacy`; `:: DV-14: legacy and new both advance 2 s on a 2 s dt, MaxDt = 0.25 advances 0.25`; `regress/repros_spec :: B-01`; `:: L-05`; `:: S-01` (and every other id) |
| WP8 | **Alloc + bench** — `alloc_spec`, `bench.luau` P1–P12/P14/P15, `studio_bench.luau` | `build/tests/spec/alloc/alloc_spec.luau`, `build/bench/bench.luau`, `build/bench/studio_bench.luau` | WP5, WP6 | `alloc/alloc_spec :: 1000 idle updates with 10k armed allocate 0 bytes`; `:: 1000 busy updates with 50 noop dispatches each allocate 0 bytes`; `:: warmed GetStats(into) and Validate allocate 0 bytes`; bench prints P1–P12, P14, P15 with every invariant assertion passing |
| WP9 | **Docs** — `API.md` (retention rule + per-instance footprint first; the §4.8 time-model paragraph verbatim; every §2 member; `Recur`'s third argument and `h:SetCatchUp`; the three verbs `Stop/Complete/Destroy` side by side (incl. "a post-fire `Stop` finalizes a Fired handle; `Clear()` never reaches one; `Restart()` takes a fresh `Id`", §4.3/§4.4/§11); state matrix §5; "not per-frame" list; `Now()` vs `GetBase()`; the §2.4 touch patterns and the "Reuse over recreate" paragraph with the 576 B / ~250 ns / 0 B / ~5.8 MB/s numbers; the §6 wiring contract incl. the DV-23 guard recommendation), `MIGRATION.md` (§7.1–7.4, the ≤ 26 recur-nested files with the one-period-earlier warning, M0–M3, the Q-J13/Q-J14 out-of-scope list incl. `CharacterSheet:772`), `docs_spec` | `build/docs/API.md`, `build/docs/MIGRATION.md`, `build/tests/spec/docs/docs_spec.luau` | WP5, WP6 (member list) | `docs/docs_spec :: every public member of §2 appears in build/docs/API.md`; `:: API.md states the retention rule at the top`; `:: API.md explains the rolling-clock decision in plain language`; `:: API.md documents the per-instance footprint`; `:: every DV of §7.3 appears in MIGRATION.md`; `:: MIGRATION.md maps every prior 2.0.0 name`; `:: MIGRATION.md lists M0–M3 and the out-of-scope items`; `:: MIGRATION.md lists the recur-nested files and the one-period-earlier warning`; `:: API.md states the reuse-over-recreate rule with the 576 B / 0 B numbers` |

Parallelism: WP1 + WP2 + WP3 in parallel → WP4 → WP5 + WP6 (same file; the orchestrator runs them as ONE author, sections appended in §4 order) → WP7 + WP8 + WP9 in parallel. Every package: `lune run build/tests/run.luau` green for its listed tests, `Oracle.wrap` on every instance it touches, house style outside the marked HOT PATH block.

## 13. Deferred minors (recorded, not applied; each is a local follow-up with no effect on the §9 acceptance list)

| Id | Finding | Why deferred | Follow-up |
|---|---|---|---|
| F-PM-8 | `_stopTerminal`, `_clearTerminal` and `Validate` recurse over `_Chained` subtrees; a loop-built 300k-deep chain overflows the Luau stack from a method §2.3 marks "never" errors | pathological input (0 live `after` callers; A7 depth is unlimited in principle, not in practice); the fix adds an instance field (`_Walk` reusable stack) and touches three sites | replace the three recursions with an iterative walk over a lazily-allocated `self._Walk` (`table.clear` after use) when a real chain deeper than ~1k appears; `chain_spec :: 100k-deep chain stops without overflow` then |
| F-PM-9 | `_Due/_Item` start as `{}` and pay ~14 doubling copies on the way to 10k entries (one-time, boot only) | no steady-state cost; TickAPI's instances never see a 10k first-frame burst | optional `cfg.Capacity` (integer ≥ 0, default 0 → `table.create(Capacity)` for both arrays) if the Studio bench shows a first-frame spike |
| JF-16 (gate half) | house rule "dev-time warnings never ship as bare `warn`; gate behind an attribute" | every instance diagnostic is warn-ONCE and counted, never per frame (the rule's target), and hiding a wiring-bug warning from a live server console defeats the point; all diagnostics already route through `_diagnose` → function `OnError` policies | if the house still wants a gate: `Env.Warn` reads `ReplicatedStorage:GetAttribute("DebugTickAPI") ~= false` once per call on Roblox (`Env.SetWarn` under Lune); no design change elsewhere |
| JF-18 (duck-type half) | legacy `SafeStopClock(x)` calls `x:stop()` unguarded (raises on a non-handle, `CharacterSheet:772`); a duck-typed or nil-tolerant guard would live in the wrapper | the wrapper is out of scope (§6); every live receiver is a Veron handle (CS §5), whose `stop` is total | listed in MIGRATION.md; revisit in the wrapper only if a GranularTween-style receiver is found |
| JF-17 (rename half) | heap helpers keep the prototype's single-letter sift locals and unprefixed names | covered by the extended HOT PATH marker (§3.2, D24) — a rename in a verified block is a transcription risk for zero runtime gain | none unless the house rejects the marker; then `dueTimes/events/index/parentIndex/childIndex/count` + `_heapPush` etc., re-verified by `heap_spec` |

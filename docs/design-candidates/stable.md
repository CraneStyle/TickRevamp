# Design candidate "stable" — stability & migration first

Angle: zero regressions against the 300+ live call sites; every hostile-callback case (throw, yield,
re-enter, mutate, destroy-from-inside) handled by construction; the compat layer, migration order and
the parity oracle are the centre. All 24 settled decisions (D1–D24) are taken as given; every Q-J is
decided in §8. Cites: `spec` = research/semantics-spec.md rows, `alg` = research/scheduler-algorithms.md,
`L-nn`/`F-n` = research/legacy-bughunt.md, `B-nn`/`RF` = research/prior-build-review.md, `S-nn` =
research/syncedtimer-review.md, `CS`/`P-n` = research/callsites.md, `RT` = research/roblox-timing.md,
`BC` = research/baseclass-conventions.md.

Three rules that give this candidate its stability guarantees:

| Rule | Consequence |
|---|---|
| **R-A One mutation authority.** Every heap/state write lives in file-local functions of `TickScheduler`; `TickEvent` methods are `guard → self._Scheduler:_Op(self, …)`. | One file to audit for the non-negotiables; the heap invariant oracle (§9.2) wraps one module. |
| **R-B Finalize before, bookkeeping only after.** Pop/re-key/arm-children/mark-terminal happen BEFORE `xpcall`; after it only `_Base` restore and stats. Terminal handles get `_Fn = NOOP`. | A callback's own stop/reset/adjust/pause/complete always wins (D3); no RF-010 class; a terminal handle can never run user code again. |
| **R-C Re-entrancy is a depth counter, not a flag.** A nested/overlapped `Update` on the same instance runs a real pass (depth ≤ 8, then advance-only); `_Base` and `_Errored` are saved/restored per pass. | A callback that `task.wait`s does not stall every other timer for the wait's duration (legacy kept firing them; an advance-only inner pass would regress that). |

## 1. Object model + file layout

```
build/src/TickAPI/
  init.luau                    registry module (plain table `TickAPI`)
  Env/init.luau                platform seam (plain table)
  Hooks/init.luau              RunService binding table + dt sanitizer + boot probe (plain table)
  TickScheduler/init.luau      --!native  BaseClass root class; heap, clock, dispatch, every mutation
  TickEvent/init.luau          BaseClass root class; the handle; thin colon-guarded methods + LEGACY SURFACE
  TickAfterNotTouched/init.luau BaseClass root class; injected scheduler
build/vendor/BaseClass.luau    live BaseClass, one edit (JsonR → no-op registrar), sha 21960b8e125d1cd5, Lune only
build/tests/spec/**            §9;  build/tests/helpers/{oracle,fakerunservice,loadall}.luau
build/bench/bench.luau         §10; build/bench/studio_bench.luau (command-bar port)
build/docs/api/API.md, build/docs/migration/MIGRATION.md
```

| Module | Kind | Responsibility (one line) | Requires |
|---|---|---|---|
| `TickAPI` (init) | plain table | boots `Tick/Tickh/Tickr`, registry (`New/Register/Get/Unregister`), `SafeStopClock`, `GetAfterNotTouched`, `Diagnostics`, class exposure | Env, Hooks, TickScheduler, TickEvent, TickAfterNotTouched |
| `Env` | plain table | the ONLY module that touches `game`: `IsRoblox`, `BaseClass`, `RunService` (nil under Lune), `IsServer/IsClient/IsEdit`, `Warn`, `Clock`, `SetMemoryCategory/ResetMemoryCategory` (no-op under Lune), `Load(name)`; test seams `SetRunService(fake) → restore`, `SetWarn(fn) → restore` (fixes B-12: injection is scoped, restorable) | vendor BaseClass (Lune) or `SharedModules.BaseClass` (Roblox) |
| `Hooks` | plain table | `NAMES` (frozen list), `CLIENT_ONLY = {RenderStepped, PreRender}` (RT §1.4; the prior's `PreAnimation` entry was wrong), `Connect(scheduler, hook) → connection`, Stepped `(time, dt)` → dt, dt sanitizer (NaN/neg → 0, clamp `MaxDt`), boot probe (D16) | Env |
| `TickScheduler` | BaseClass root class | arrays `_Due/_Item`, virtual clock, arm, dispatch loop, catch-up, valve, stop cascade, pause/resume, retime, chains, complete, keyed index, attach/drive, bind/unbind/destroy, stats; dual dot/colon closures installed in `initialize` | Env, TickEvent, Hooks |
| `TickEvent` | BaseClass root class | constructor-literal handle (§3); each public method = colon guard + delegate to owner; `__tostring`; LEGACY SURFACE aliases | Env (BaseClass only) |
| `TickAfterNotTouched` | BaseClass root class | touch-to-reset self-destroying clock over an injected scheduler; `Storage`, `Count()` | Env |

Dependency arrows: `init → {Env, Hooks, TickScheduler, TickEvent, TickAfterNotTouched}`; `TickScheduler → {Env, TickEvent, Hooks}`; `Hooks → Env`; `TickEvent → Env`; `TickAfterNotTouched → Env`. No cycles: `TickEvent` never requires `TickScheduler` (it reaches the owner through `self._Scheduler`).

Neighbour loading (W/CLAUDE.md rule): every module starts with
`local Env = if typeof(script) == "Instance" then require(script.Parent.Env) else require("./Env")`
(inside an `init.luau` under Lune `./` is the directory that CONTAINS the module directory, i.e. `TickAPI/`),
then `Env.Load("TickEvent")` = `require(script.Parent[name])` on Roblox / `require("./" .. name)` under Lune.
`Env` itself loads the class library as `require("../../vendor/BaseClass")` under Lune (= `build/vendor/BaseClass`)
or `require(ReplicatedStorage:WaitForChild("SharedModules").BaseClass)` on Roblox. All modules are `--!nonstrict`
(the global `script` is read); only `TickScheduler` is `--!native` (D24).

BaseClass usage (D13/BC): three root classes, unique prefixed names, no `Stateful/Callbacks/ObjectPool/Beholder`, no
declared `__index`, never subclassed. Handles are built by a constructor literal + `setmetatable(t, TickEvent.__instanceDict)`
(BC F2: 222 ns vs 909 ns for `Class:new`); `h:isInstanceOf(TickEvent)`, `h.class`, `h.type == "TickEvent"` all hold.
`TickScheduler.static.new` is overridden to shift when `self ~= TickScheduler` so `TickScheduler.new(cfg)` works (Q-J9).

## 2. Public API reference

Error-message contract: legacy validation strings are byte-identical to `reference/live/Tick.luau:168-174` and the
prior `Handle:80-93`; every NEW error starts with `TickAPI: `, `TickScheduler '<Name>': `, `TickEvent: ` or
`TickAfterNotTouched: `. Scheduler methods raise at level 3 (the dual-call closure adds one frame); handle methods at level 2.

### 2.1 Registry module `TickAPI` (plain table; all dot-called)

| Member | Signature → return | Semantics | Errors |
|---|---|---|---|
| `VERSION` | `"3.0.0"` | | |
| `Tick`, `Tickh`, `Tickr` | `TickScheduler` | built-ins: Stepped, Heartbeat, RenderStepped; `Tickr == nil` on the server (Q-J4) and under Lune; under Lune all built-ins are `Hook = "Manual"` | |
| `New(cfg?)` | `→ TickScheduler` | `TickScheduler:new(cfg)`; when `cfg.Name` is given the scheduler is registered (must be unique) | `TickAPI: scheduler name '<X>' already registered` |
| `Register(name, cfg?)` | `→ TickScheduler` | `New` with `cfg.Name = name` | as above; `TickAPI: expected a name string` |
| `Get(name)` | `→ TickScheduler?` | registry lookup, nil when absent (never errors) | |
| `Unregister(name)` | `→ TickScheduler?` | removes from the registry without destroying; nil when absent | |
| `SafeStopClock(h)` | `→ nil` | `if h == nil then return nil end; h:Stop(); return nil` — nil-tolerant, idempotent, ALWAYS returns nil (19 live `x = SafeStopClock(x)` sites) ; a non-handle argument → `false`-tolerant: returns nil without error (P9: SyncedTimer id strings never reach it, but a stray value must not throw a teardown) | never |
| `GetAfterNotTouched(t, fn, tickType)` | `→ TickAfterNotTouched` | `tickType` = `"Tick"|"Tickh"|"Tickr"` or a scheduler instance; `TickAfterNotTouched:new(scheduler, t, fn)` | `TickAPI: unknown tick type <X>` (server `"Tickr"`, L-21) |
| `State` / `StateName` | `{Pending=1,Paused=2,Chained=3,Fired=4,Stopped=5}` / inverse | exported constants (D8) | |
| `Hooks` | frozen list | `{"Manual","Heartbeat","Stepped","RenderStepped","PreRender","PreAnimation","PreSimulation","PostSimulation"}` | |
| `Diagnostics()` | `→ table` | `{IsServer, IsClient, IsEdit, IsRoblox, Schedulers = {[name] = {Hook, IsBound, Updates, Dispatched, Reentries, ValveHits, Pending, Paused}}}` (allocates; cold) | |
| `TickScheduler`, `TickEvent`, `TickAfterNotTouched` | classes | for `isInstanceOf` and `TickScheduler:new` | |
| LEGACY SURFACE | `Tick`, `Tickh`, `Tickr`, `SafeStopClock`, `GetAfterNotTouched` | already canonical spellings (D15); nothing else lowercase | |

### 2.2 `TickScheduler` — constructor and config schema

`TickScheduler:new(cfg?)` ≡ `TickScheduler.new(cfg?)` ≡ `TickScheduler(cfg?)` ≡ `TickAPI.New(cfg?)`. Unknown key →
`TickScheduler: unknown option '<k>'`; wrong type/range → `TickScheduler: option '<k>' expects <what>`.

| Key | Type / range | Default | Notes |
|---|---|---|---|
| `Name` | string | `"TickScheduler" .. n` (unregistered when omitted) | given → registered, unique |
| `Hook` | one of `TickAPI.Hooks` | `"Manual"` | sugar for `Bind(hook)` after construction; under Lune only `"Manual"` is bindable |
| `TimeScale` | finite number ≥ 0 | `1` | `0` freezes |
| `CatchUp` | `"cap" \| "all" \| "drop"` | `"cap"` | stored as `_MaxCatchUp` = n / `math.huge` / 1 |
| `MaxCatchUp` | integer ≥ 1 | `8` (built-in `Tickr`: `1`, Q-J8) | per handle override via `Recur` opts |
| `MaxNested` | integer ≥ 1 | `1000` | runaway valve (D5) |
| `MaxDt` | number > 0 or `false` | `0.25` | driver clamp only (D2); `false` disables |
| `MaxUpdateDepth` | integer ≥ 1 | `8` | re-entrant passes deeper than this are advance-only (§4.2) |
| `OnError` | `"warn" \| "error" \| function(message, handle)` | `"warn"` | D11 |
| `Strict` | boolean | `false` | `true`: `Remove(non-handle)` errors (Q-J5) |
| `LegacyRecurBase` | boolean | `false` | migration aid for Q-J1: base of a recurring dispatch = `d + period` (reproduces L-01) |
| `MemoryCategory` | string or `false` | `false` | Q-J10 opt-in tag around `Update` |

### 2.3 `TickScheduler` members (every public entry is dual dot/colon; D15)

| Member | Signature → return | Semantics | Errors / states | Alias |
|---|---|---|---|---|
| `Update(dt)` | `→ nil` | `now += dt × TimeScale`, dispatch due prefix (§4.2). Legal on a bound scheduler (Q-J11). Scheduler-paused → returns without advancing. | `Update(dt) expects a finite number >= 0, got <v>`; `destroyed` | `update` |
| `UpdateTo(t)` | `→ nil` | absolute-clock entry; offset math §4.9; backwards → clamp + count, never error | `UpdateTo(t) expects a finite number, got <v>` | |
| `Delay(fn, t)` | `→ TickEvent` | one-shot; base carry when called inside a callback of THIS scheduler (D4) | legacy strings (§4.1) | `delay` |
| `Recur(fn, p, opts?)` | `→ TickEvent` | recurring; `opts = {CatchUp, MaxCatchUp, Key}` | legacy + `expected recur `delay` greater than zero` | `recur` |
| `DelayAt(absDue, fn)` | `→ TickEvent` | one-shot at an absolute time of the `UpdateTo` clock | `UpdateTo has not been called; DelayAt needs an absolute clock` | |
| `DelayKeyed(key, fn, t)` / `RecurKeyed(key, fn, p, opts?)` | `→ new, replaced?` | duplicate key = replace (old stopped, returned second; Q-J6) | `expected `key` to be a non-empty string` | |
| `Remove(h)` | `→ boolean` | `nil`/non-handle → `false` (`Strict` → error); foreign handle → error; else `Stop` | `event #<id> belongs to scheduler '<Y>'`; `expected a TickEvent, got <t>` | `remove` |
| `Stop(hOrKey)` | `→ boolean` | `Remove` that also accepts a key | as `Remove` | |
| `Complete(hOrKey, opts?)` / `CompleteNow(hOrKey, opts?)` | `→ boolean` | §4.7; `opts = {Stop = true}` | foreign → error; unknown key → `false` | `ForceEventComplete` (= `Complete`) |
| `Has(key)` / `Get(key)` / `GetRemaining(key)` | `→ boolean` / `TickEvent?` / `number?` | keyed lookups; unknown key → `false`/`nil`/`nil` (never 0, S-09) | | |
| `GetClocks()` | `→ number` | `Pending + Paused` (D20; not Chained) | 0 after destroy | `getClocks` |
| `GetStats()` | `→ table` | `{Now, Pending, Paused, Chained, Recurring, Dispatched, Reentries, Dropped, ValveHits, ClampedBackwards, HeapSize, Updates, UpdateDepth, Bound, Name, TimeScale}` (allocates; cold) | | |
| `Now()` / `SetTimeScale(s)` / `GetTimeScale()` | | virtual clock; scale must be finite ≥ 0 | `option 'TimeScale' expects …` | |
| `Pause()` / `Resume()` / `IsPaused()` | `→ nil / nil / boolean` | scheduler-level freeze: `Update` discards dt; `UpdateTo` folds the gap into `_Offset` | | |
| `SetOnError(p)` / `SetCatchUp(mode, n?)` / `SetMaxNested(n)` / `SetMaxDt(x)` | `→ nil` | live reconfiguration, same validation as construction | | |
| `Clear()` | `→ number` | stops Pending, Paused and Chained alike (D18); legal mid-update | | |
| `Bind(hook)` / `Unbind()` / `Rebind(hook)` / `IsBound()` | `→ nil / nil / nil / string\|false` | one connection per scheduler; `Unbind` idempotent; `IsBound` returns the hook name | `unknown hook '<X>'`; `hook '<X>' is client only`; `already bound to '<Y>'; call Unbind() first`; `RunService has no signal '<X>'`; `no RunService in this environment (Manual only)` | |
| `Attach(child)` / `Detach(child)` | `→ nil` | ownership: attached schedulers are destroyed with the parent (D17); cycle/self/destroyed rejected | `Attach: cannot attach <what>` | |
| `Drive(child, period, opts?)` | `→ TickEvent` | `Recur(function() child:Update(period) end, period, opts)` + `Attach(child)` unless `opts.Attach == false`; the closure stops itself when the child is destroyed | as `Recur` | |
| `Destroy(opts?)` / `IsDestroyed()` | `→ nil / boolean` | unbind + clear + cascade to attached + unregister + dead (D16). Built-ins need `opts.Force` (Q-J12). Legal from inside its own callback. | `built-in scheduler cannot be destroyed; pass { Force = true }` | |
| `IsUpdating()` | `→ boolean` | `_UpdateDepth > 0` | | |
| `Name` | public field | | | |

After `Destroy`: `Update/UpdateTo/Delay/Recur/DelayAt/*Keyed/Bind/Attach/Drive` raise `TickScheduler '<X>': destroyed`;
`Remove/Stop/Complete/Has/Get/GetClocks/GetStats/Unbind/Clear/Destroy` stay total no-ops (return `false`/`nil`/`0`).

### 2.4 `TickEvent` — handle members (colon-only; first line of every method is the guard)

Guard: `if getmetatable(self) ~= eventDict then error("TickEvent: methods take a colon: event:Stop(), not event.Stop()", 2) end` (BC bench4: +6.6 ns).

| Member | → return | Semantics (full state matrix in §5) | Errors | Alias |
|---|---|---|---|---|
| `Stop()` | nothing | terminal `Stopped`; cascades to Chained children; idempotent; owner-agnostic (P9 cross-wrapper stops) | never | `stop`, `Destroy` |
| `Reset()` | `h` | full period from `now` (D9) | never | `reset` |
| `Adjust(x)` | `h` | ratio-preserving retime from `now` (D9); accepts numeric strings; reports original type | `expected `newTotal` greater than zero` | `adjust` |
| `After(fn, t)` | child `TickEvent` | chained child; never returns the parent (D8) | `cannot chain a recurring event` + legacy arg strings | `after` |
| `SetPeriod(p)` / `GetPeriod()` | `h` / number | future arms only | `expected `newPeriod` greater than zero` (recur) / `of zero or greater` (one-shot) | |
| `SetRemaining(x)` / `GetRemaining()` | `h` / number ≥ 0 | "x more seconds", period untouched; remaining in scheduler-seconds (R9) | `expected `remaining` of zero or greater` | |
| `Pause()` / `Resume()` / `IsPaused()` | `h` / `h` / boolean | freeze/thaw current cycle; Chained → flag (A8) | never | |
| `Complete(opts?)` / `CompleteNow(opts?)` | boolean | §4.7; `opts.Stop` ends a recurring after the forced fire | never | `ForceComplete` (= `Complete`) |
| `SetCatchUp(mode, n?)` | `h` | per-handle override (`"cap"`, n / `"all"` / `"drop"` / `"inherit"`) | `option 'CatchUp' expects …` | |
| `GetState()` / `GetStateId()` | name / number | `"Pending"…"Stopped"` | | |
| `IsActive()` / `IsRecurring()` / `GetId()` / `GetKey()` / `GetScheduler()` | | `IsActive` = Pending, Paused or Chained | | |
| `Id` | public field | ascending integer per scheduler, never reused; also the equal-due tie-break | | |
| `tostring(h)` | string | `TickEvent<Tick#42 recur 0.5s Pending>` | | |

Callback signature: `fn(handle)` — the handle is passed as the first argument (backward-compatible: the only live
bare-function callback, `fxCensusServer:170 _census`, takes no parameters; every other site is a closure).

### 2.5 `TickAfterNotTouched`

`TickAfterNotTouched:new(scheduler, t, fn)` (via `TickAPI.GetAfterNotTouched`): registers in `Storage[Id]` BEFORE
arming (L-25); `Clock = scheduler.Delay(function() xpcall(fn, traceback) … end, t)`; on fire: run `fn` under `xpcall`,
ALWAYS `Destroy()`, then route the traced error through the scheduler's `OnError` (L-23, B-19 — the original stack is
preserved because the traceback was taken inside the xpcall handler). `:Touch()` → `Clock:Reset()`; if the clock is no
longer active (scheduler `Clear`/`Destroy`, B-08) `Touch` self-destroys instead of no-op'ing forever. `:Destroy()`
idempotent; `:IsDestroyed()`; `.Id` integer; static `Count()`. Error: `TickAfterNotTouched: expected a scheduler`.

## 3. Internal data layout

### 3.1 Handle constructor literal (16 keys = 14 user fields + `class` + `type` → 576 B, sized once; F-ALG-9)

```lua
local h = {
	class = TickEvent, type = "TickEvent",
	Id = id,              -- number   per-scheduler ascending; equal-due tie-break (seq)
	_Scheduler = self,    -- owner; the only route every method takes (R-A)
	_Fn = fn,             -- callable; becomes NOOP on every terminal transition (R-B)
	_Period = period,     -- number   one-shot delay / recurring period / chained child delay
	_IsRecur = isRecur,   -- boolean  read once per dispatch
	_State = PENDING,     -- 1..5
	_HeapIndex = 0,       -- 0 = not in heap; `_Item[_HeapIndex] == h` is the ownership check
	_Remaining = 0,       -- frozen remaining while Paused
	_Chained = false,     -- false | {child, ...} registration order (lazy)
	_Burst = 0, _BurstSerial = 0, -- per-update catch-up counter, self-resetting (D6)
	_MaxCatchUp = false,  -- false = inherit scheduler | number (math.huge = "all", 1 = "drop")
	_Key = false,         -- false | string (keyed timers)
	_Flags = 0,           -- bit set: PWC=1 pausedWhileChained, COMPLETING=2, STOP_ON_FIRE=4, REPAUSE_ON_FIRE=8
}
setmetatable(h, eventDict)
```
No `_Seq` (Id is the seq), no `_Parent` (a parent's list simply skips children that are no longer `Chained`), no
`_Due` (the key lives in `_Due[_HeapIndex]`). The hot loop reads `_IsRecur`, `_Period`, `_Flags`, `Id`, `_Burst*`.

### 3.2 Scheduler instance fields (all assigned in `initialize`, never nil)

| Group | Fields |
|---|---|
| heap | `_Due {number}`, `_Item {TickEvent}`, `_N = 0` (== Pending count) |
| clock | `_Now = 0`, `_Base = false` (firing entry's ideal due while a callback runs), `_TimeScale = 1`, `_IsPaused = false`, `_Offset = 0`, `_LastAbs = false` |
| pass state | `_UpdateDepth = 0`, `_Serial = 0` (per-pass burst serial), `_NextId = 0`, `_Errored = false` |
| policy | `_MaxCatchUp = 8`, `_MaxNested = 1000`, `_MaxDt = 0.25`, `_MaxUpdateDepth = 8`, `_OnError = "warn"`, `_Strict`, `_LegacyRecurBase`, `_MemoryCategory` |
| side indexes | `_PausedSet {[h]=true}` + `_PausedCount`, `_Keys {[string]=h}`, `_Children {[TickScheduler]=true}` (attached) |
| lifecycle | `Name`, `_IsDestroyed = false`, `_IsBuiltIn = false`, `_Hook = false`, `_Connection = false` |
| stats | `_Dispatched, _Reentries, _Dropped, _ValveHits, _ClampedBackwards, _Updates, _ChainedCount, _RecurCount` + warn-once `_Warned = {}` |
| dual-call closures | `Update/update, Delay/delay, Recur/recur, Remove/remove, GetClocks/getClocks, ForceEventComplete, …` (one closure per public member per instance; 3–6 instances) |

Heap ops are `alg §3.2` verbatim (`siftUp`, `siftDown`, `heapPush`, `heapPop`, `heapRemove`, `heapUpdate`, `heapClear`)
with `_Seq → Id`, `_hi → _HeapIndex`. Invariants (checked by the oracle, §9.2): heap property on `(due, Id)`;
`_Item[h._HeapIndex] == h` for `1..N`; `{h : _State == PENDING} == set(_Item)`; every `PAUSED` handle is in
`_PausedSet` with `_HeapIndex == 0`; no NaN in `_Due`; every `_Keys` value is non-terminal with `_Key == key`;
`_ChainedCount` == number of `CHAINED` handles reachable from live parents.

## 4. Algorithms

### 4.1 Arm (Delay / Recur / DelayAt / *Keyed / After all end here)

```lua
local function _event(self, fn, delayArg, isRecur)                 -- level 3 errors: caller's line
	if self._IsDestroyed then error(("TickScheduler '%s': destroyed"):format(self.Name), 3) end
	if not _isCallable(fn) then error("expected `fn` to be callable", 3) end
	local delay = tonumber(delayArg)                                   -- legacy coercion (I7)
	if type(delay) ~= "number" then
		error("expected `delay` to be a number. CurrentType: " .. typeof(delayArg), 3) end   -- ORIGINAL type (L-17)
	if delay ~= delay or delay == math.huge or delay == -math.huge then
		error("expected `delay` to be a finite number", 3) end                               -- I4, I5 (Q-J3)
	if delay < 0 then error("expected `delay` of zero or greater", 3) end
	if isRecur and delay == 0 then error("expected recur `delay` greater than zero", 3) end  -- I2/F5
	local id = self._NextId + 1
	self._NextId = id
	local h = <literal of §3.1>
	heapPush(self, h, (self._Base or self._Now) + delay)      -- implicit arm: base carry (D4, C1)
	return h
end
```
`_isCallable` = function or table with `__call` (I8). Zero-delay at top level → due = now → next update (I1);
inside a callback → due = base + 0 ≤ now → later in the same pass (C2/C3), never synchronously (D5, L-04).

### 4.2 Dispatch loop (`Update`, `UpdateTo` → `_AdvanceTo`)

```lua
function TickScheduler:Update(dt)
	if self._IsDestroyed then error(…destroyed, 3) end
	if not (dt == dt and dt >= 0 and dt ~= math.huge) then
		error(("TickScheduler '%s': Update(dt) expects a finite number >= 0, got %s"):format(self.Name, tostring(dt)), 3) end
	if self._IsPaused then return end
	_advanceTo(self, self._Now + dt * self._TimeScale)
end

local function _advanceTo(self, target)
	local depth = self._UpdateDepth
	if target > self._Now then self._Now = target elseif target < self._Now then self._ClampedBackwards += 1 end
	if depth > 0 then                                              -- R-C: nested (sync) or overlapped (yield)
		self._Reentries += 1
		_warnOnce(self, "Reentry", "Update re-entered from a callback or a yielding callback")
		if depth >= self._MaxUpdateDepth then return end           -- advance-only past the depth cap (B-04 #3)
	end
	self._UpdateDepth = depth + 1
	local savedBase, savedErrored = self._Base, self._Errored      -- per-pass save (B-04 #1/#2, L-05)
	self._Errored = false
	local serial = self._Serial + 1
	self._Serial = serial
	local due, item = self._Due, self._Item
	local startId, nested, nestedCap = self._NextId, 0, self._MaxNested
	local dispatched = 0
	self._Updates += 1
	while self._N > 0 do                                           -- Destroy/Clear set _N = 0 → exits
		local now = self._Now                                      -- re-read: an inner pass may have advanced it
		local d = due[1]
		if d > now then break end
		local h = item[1]
		if h.Id > startId then                                     -- armed during THIS pass and already due
			nested += 1
			if nested > nestedCap then                             -- D5 valve: leave the rest for next update
				self._ValveHits += 1
				_warnOnce(self, "Valve", "runaway nested timers; dispatch deferred to the next update")
				break
			end
		end
		if h._IsRecur and h._Flags < 4 then                        -- plain recurring (flags 0/1/2 only)
			local period = h._Period
			local burst = (h._BurstSerial == serial) and h._Burst + 1 or 1
			h._BurstSerial, h._Burst = serial, burst
			local cap = h._MaxCatchUp or self._MaxCatchUp
			if burst > cap then                                    -- D6 "cap": snap to first grid point > now
				local m = (now - d) // period + 1
				local nextDue = d + m * period
				if nextDue <= now then nextDue += period end
				if nextDue <= now then                             -- period below float resolution: stop loudly
					heapPop(self); _stopTerminal(self, h)
					_warnOnce(self, "Resolution", "recur period below clock resolution; event stopped")
				else
					due[1] = nextDue; siftDown(due, item, self._N, 1); self._Dropped += m
				end
			else
				due[1] = d + period; siftDown(due, item, self._N, 1) -- re-key IN PLACE before the callback (D3)
				self._Base = self._LegacyRecurBase and d + period or d
				_runCallback(self, h, h._Fn)
				dispatched += 1
			end
		else                                                       -- one-shot, or recurring with STOP/REPAUSE flag
			heapPop(self)
			_fireOneShot(self, h, d)                               -- §4.3
			dispatched += 1
		end
	end
	self._Base = savedBase                                         -- bookkeeping only after callbacks (R-B)
	self._Dispatched += dispatched
	self._UpdateDepth = depth
	local errored = self._Errored
	self._Errored = savedErrored
	if errored then error(errored, 0) end                          -- policy "error": after the pass, per pass
end
```

`_runCallback(self, h, fn)`: `local ok, msg = xpcall(fn, Env.Traceback, h)`; on failure: `"warn"` →
`Env.Warn("[TickScheduler <Name>] event #<id> callback error: " .. msg)`; `"error"` → keep the first `msg` in
`_Errored`; function → `pcall(policy, msg, h)`, its own failure warned (E3). Never touches the heap.

`_fireOneShot(self, h, d)` (h already popped): `h._State = FIRED`; clear key; `self._Base = d`; if
`_Flags & REPAUSE` (recurring completed while Paused, §4.7): `_State = PAUSED, _Remaining = period, _PausedSet[h] = true`
(so a recurring stays Paused with a full period, D7); arm each child in `_Chained` that is still `CHAINED`: flag PWC →
`PAUSED` with `_Remaining = child._Period`, else `heapPush(child, d + child._Period)` (A9: from the parent's ideal due;
from `now` when forced, because `d == now` then); `local fn = h._Fn; if not REPAUSE then h._Fn = NOOP end`;
`_runCallback(self, h, fn)`. Nothing after.

Re-entrancy properties (D12): every mutation is in place and complete before user code; the loop re-reads `_N`,
`due[1]`, `_Now` each iteration; an inner pass (sync or yield-overlap) has its own `serial`, `startId`, `nested`
locals and restores `_Base/_Errored` at exit; a recurring handle whose callback yields past its period fires again
from the inner pass (legacy behaved the same); no entry is ever advanced twice because dispatch = pop/re-key.

### 4.3 Stop / Remove cascade (the only path to `Stopped`)

```lua
local function _stopTerminal(self, h)                     -- returns true when a transition happened
	local st = h._State
	if st >= FIRED then return false end                   -- terminal check FIRST (D18)
	if st == PENDING then heapRemove(self, h)              -- ownership check inside; own callback: _HeapIndex 0 → false
	elseif st == PAUSED then self._PausedSet[h] = nil; self._PausedCount -= 1
	else self._ChainedCount -= 1 end                       -- CHAINED: parent's list skips non-Chained children (A1)
	h._State, h._Fn, h._Flags = STOPPED, NOOP, 0
	if h._Key then self._Keys[h._Key] = nil; h._Key = false end
	local chained = h._Chained
	if chained then h._Chained = false; for _, c in chained do _stopTerminal(self, c) end end   -- A2, recursive
	return true
end
```
`Remove(x)`: `nil → false`; string → key lookup; non-handle → `false` (or error under `Strict`); `x._Scheduler ~= self`
→ error (S7); else `_stopTerminal`. `h:Stop()` → `_stopTerminal(self._Scheduler, self)` (owner-agnostic). Stop
protection table = `alg §3.7` plus: stop of the currently-running recurring handle removes its re-keyed entry (no
further fire this pass, S2/L-06); stop of a co-due sibling removes it before it can pop (S3/L-02); `Clear()` walks
`_Item[1..N]` marking each `STOPPED` (cascading), `heapClear`, then the paused set — O(n), legal mid-update.

### 4.4 Pause / Resume (explicit ops measure from `_Now`, D4)

| | Pending | Paused | Chained |
|---|---|---|---|
| `Pause` | `_Remaining = max(due − now, 0)`; `heapRemove`; `PAUSED`; `_PausedSet[h] = true` | no-op | `_Flags |= PWC` |
| `Resume` | no-op | `PENDING`; `heapPush(h, now + _Remaining)`; unset | `_Flags &= ~PWC` |

A paused recurring accumulates no missed fires (its key is recomputed on resume). Scheduler-level `Pause()` is a
separate switch on the clock (`Update` discards dt; `UpdateTo` folds the gap into `_Offset`).

### 4.5 Reset / Adjust / SetPeriod / SetRemaining (D9; validation as §4.1 with the prior's messages)

```lua
-- Adjust(x): x = tonumber(x); finite and > 0 else error("expected `newTotal` greater than zero", 2)
PENDING: local due = self._Due[h._HeapIndex]; local frac = (period > 0) and clamp((due - now) / period, 0, 1) or 1
         heapUpdate(self, h, now + frac * x); h._Period = x
PAUSED:  frac = (period > 0) and clamp(_Remaining / period, 0, 1) or 1; _Remaining = frac * x; _Period = x
CHAINED: _Period = x
-- Reset():        PENDING → heapUpdate(now + period); PAUSED → _Remaining = period; CHAINED → no-op
-- SetRemaining(x): finite ≥ 0; PENDING → heapUpdate(now + x); PAUSED → _Remaining = x; CHAINED → _Period = x
-- SetPeriod(p):   finite, ≥ 0 (one-shot) / > 0 (recurring); _Period = p in every non-terminal state; no re-key
```
Inside its own recurring callback `Adjust` sees `due = d + period` (already re-keyed) so `frac ∈ [0,1]` and the
worst case is one extra fire this pass, bounded by the catch-up cap (closes B-01 by construction). `period == 0`
never divides (F6/R3/RF-001).

### 4.6 After-chains

`After(fn, t)`: recurring parent → `cannot chain a recurring event` (A3); validate as one-shot; child literal with
`_State = CHAINED, _Period = t`; then by parent state — Pending/Paused/Chained → append to `parent._Chained`
(lazy `{}`), `_ChainedCount += 1`; Fired → `heapPush(child, (self._Base or self._Now) + t)` as `PENDING` (A4: "after a
finished event" = arm like a nested Delay); Stopped → child born `STOPPED` with `_Fn = NOOP` (A5). Children arm in
registration order from the parent's ideal due (A6/A9); an erroring parent still arms them (A10, DV-6); chains are
unlimited depth (A7); `Adjust/SetPeriod/SetRemaining` on a Chained child set its delay, `Reset` no-op, `Pause` flags (A8).

### 4.7 Complete (deferred, = `ForceEventComplete`) and CompleteNow (synchronous)

```lua
-- Complete(opts): terminal → false
PENDING: if opts.Stop and _IsRecur then _Flags |= STOP_ON_FIRE end; heapUpdate(self, h, self._Now)   -- decrease-key
PAUSED:  unset from _PausedSet; if _IsRecur and not opts.Stop then _Flags |= REPAUSE_ON_FIRE end
         PENDING; heapPush(h, self._Now)
CHAINED: _ChainedCount -= 1; clear PWC; PENDING; heapPush(h, self._Now)    -- detached: the parent's list skips it
return true   -- fires exactly once inside the next Update (or later in the current pass), in (due, Id) order (F3/F5)
```
Flagged recurring handles take the one-shot branch of §4.2: `STOP_ON_FIRE` → popped, `FIRED`, callback, no re-arm;
`REPAUSE_ON_FIRE` → popped, re-parked `PAUSED` with `_Remaining = period` BEFORE the callback (D7: completes without
resuming). Plain recurring → fires then re-arms at `now + period` through the normal in-place re-key.

`CompleteNow(opts)`: terminal or `COMPLETING` set → `false` (F6: no recursion from its own callback); `CHAINED` →
detach as above; `local savedBase = s._Base; local d = s._Now; _Flags |= COMPLETING`; one-shot → `heapRemove`/unpark
then `_fireOneShot(s, h, d)`; recurring Pending → `heapUpdate(h, d + period)` (or `heapRemove` + `FIRED` path when
`opts.Stop`), `_Base = d`, `_runCallback`; recurring Paused → `_Remaining = period`, stays Paused, callback runs;
then `_Flags = band(_Flags, ~COMPLETING)`, `s._Base = savedBase`, and when `s._UpdateDepth == 0` re-raise a pending
`"error"`-policy message (E5). Returns `true` even if the callback errored (F8). Neither verb ever runs on a terminal
handle; `Stop` never fires (F9).

### 4.8 Keyed timers (D22)

`DelayKeyed(key, fn, t)` / `RecurKeyed(key, fn, p, opts)`: validate `key` (non-empty string) FIRST, then arm the new
handle (so a validation error leaves the old timer untouched), then `old = _Keys[key]; if old then _stopTerminal(old) end`
(clears the slot), then `h._Key = key; _Keys[key] = h`; return `h, old`. Every terminal transition clears the slot
through `_stopTerminal` / `_fireOneShot`, so `Has(key)` is exact and never lies (S-03 phantom class gone).
`Stop/Complete/CompleteNow/GetRemaining/Get/Has` accept keys; unknown key → `false`/`nil`.

### 4.9 `UpdateTo` offset math (D2)

```lua
function TickScheduler:UpdateTo(t)                                   -- finite number else error
	local last = self._LastAbs
	if last == false then self._LastAbs, self._Offset = t, t - self._Now; _advanceTo(self, self._Now); return end
	if self._IsPaused then self._Offset += t - last; self._LastAbs = t; return end
	local target
	if self._TimeScale == 1 then target = t - self._Offset                        -- exact, no accumulation
	else target = self._Now + (t - last) * self._TimeScale; self._Offset = t - target end
	self._LastAbs = t
	if target < self._Now then                                                    -- clamp, count, warn once > 1 s
		if self._Now - target > 1 then _warnOnce(self, "Backwards", "absolute clock jumped backwards > 1 s") end
		target = self._Now
	end
	_advanceTo(self, target)
end
-- DelayAt(absDue, fn): _LastAbs == false → error; _event(self, fn, max(absDue - _Offset - (_Base or _Now), 0), false)
```

### 4.10 Bind / Unbind / Destroy / Attach / Detach / Drive

```lua
Bind(hook):  destroyed → error; hook == "Manual" → Unbind(); return
             not Hooks.NAMES[hook] → "unknown hook"; self._Hook → "already bound to"; Env.RunService == nil → "no RunService"
             Hooks.CLIENT_ONLY[hook] and Env.IsServer() → "client only"; pcall(index) fails or nil → "RunService has no signal"
             conn = signal:Connect(handler); self._Hook, self._Connection = hook, conn
handler:     Stepped → function(_, dt) … end, others function(dt) … end; dt = (dt ~= dt or dt < 0) and 0 or dt;
             if maxDt and dt > maxDt then dt = maxDt end; self:Update(dt)      -- MemoryCategory wraps this call (Q-J10)
Unbind():    if conn then conn:Disconnect() end; _Hook, _Connection = false, false   -- idempotent, legal mid-callback
Destroy(o):  destroyed → return; _IsBuiltIn and not (o and o.Force) → error; _IsDestroyed = true; Unbind(); Clear();
             for child in _Children do child:Destroy(o) end; _Children = {}; registry:_Unregister(self)
Attach(c):   c must be a TickScheduler, ~= self, not destroyed, and self must not be reachable from c (DFS) → _Children[c] = true
Drive(c, p, o): h = Recur(function() if c._IsDestroyed then h:Stop() return end c:Update(p) end, p, o); Attach unless o.Attach == false
```
A child's `Update` inside a parent callback is a different instance: no shared state, always safe (N2). `Destroy`
inside its own update: `Clear` sets `_N = 0` so the loop exits after the current callback; nothing fires later (N4).

## 5. State machine (state × operation → result; every cell is total, never a raw error)

| Operation | Pending | Paused | Chained | Fired | Stopped |
|---|---|---|---|---|---|
| natural fire (one-shot) | →Fired BEFORE fn; children armed at d | — | — | — | — |
| natural fire (recurring) | re-key d+P (or snap) BEFORE fn; flags: STOP→Fired, REPAUSE→Paused | — | — | — | — |
| parent fires | — | — | →Pending @ d+P, or →Paused (PWC) | — | — |
| `Stop`/`Remove`/`Destroy`/`SafeStopClock` | →Stopped, heapRemove, cascade | →Stopped, unpark | →Stopped | no-op | no-op |
| `Reset` | key = now+P | remaining = P | no-op | no-op (h) | no-op (h) |
| `Adjust(x)` | key = now+frac·x; P = x | remaining = frac·x; P = x | P = x | no-op (h) | no-op (h) |
| `SetPeriod(p)` | P = p | P = p | P = p | no-op | no-op |
| `SetRemaining(x)` | key = now+x | remaining = x | P = x | no-op | no-op |
| `Pause` | →Paused (freeze) | no-op | flag PWC | no-op | no-op |
| `Resume` | no-op | →Pending @ now+remaining | clear PWC | no-op | no-op |
| `After(fn,t)` | child Chained | child Chained | grandchild Chained | child Pending @ base/now + t | child Stopped |
| `Complete` (deferred) | key = now → true | →Pending @ now (+REPAUSE if recur) → true | →Pending @ now → true | false | false |
| `CompleteNow` | fires now → true (own callback: false) | fires; recur stays Paused → true | detach, fire → true | false | false |
| `GetRemaining` | max(due−now, 0) | remaining | P | 0 | 0 |
| `IsActive` | true | true | true | false | false |
| `Clear()` / scheduler `Destroy` | →Stopped | →Stopped | →Stopped | — | — |

## 6. Registry & hooks

Boot (`init.luau`, in order): load Env → Hooks → classes; `local hookOrManual = function(h) return Env.RunService and h or "Manual" end`;
`TickAPI.Tick = TickScheduler:new{ Name = "Tick", Hook = hookOrManual("Stepped") }`; `Tickh` (Heartbeat);
`if Env.IsClient() then Tickr = … ("RenderStepped")` (server: `Tickr == nil`, Q-J4); `_markBuiltIn` on each; registry
entries; then the boot probe. Every built-in goes through the same constructor as user schedulers (H1).

| Item | Rule |
|---|---|
| `Register/New{Name}` | unique or `TickAPI: scheduler name '<X>' already registered` (H2, Q-J13 of the spec: error, never replace); anonymous schedulers are legal and unregistered (the Tick-in-Tick child case) |
| `Get(name)` | nil when absent; `Unregister(name)` returns without destroying; `Destroy` unregisters and leaves `TickAPI.<Name>` pointing at the dead instance (callers get `destroyed` instead of index-nil) |
| hook names | `Manual, Heartbeat, Stepped, RenderStepped, PreRender, PreAnimation, PreSimulation, PostSimulation` (`Hooks.NAMES`); `Tickh` stays on Heartbeat (wall dt, fires in Edit mode; PostSimulation passes physics dt — RT §1.2/1.5) |
| server/client | `CLIENT_ONLY = {RenderStepped, PreRender}` refused on the server with `hook '<X>' is client only`; a missing member on the RunService object → `RunService has no signal '<X>'` (B-11), never a raw index error |
| connections | one per scheduler, never per timer (RT 12); handler sanitizes dt (NaN/neg → 0, clamp `MaxDt`) then calls `Update` |
| Manual `Update` on a bound scheduler | allowed, no runtime check (Q-J11); documented as a double-advance hazard; `IsBound()` + `GetStats().Updates` for detection |
| boot diagnostics | on Roblox the registry connects ONE Heartbeat probe that disconnects itself after 120 beats and warns once per registered scheduler bound to a non-Heartbeat hook whose `_Updates == 0`: `TickAPI: scheduler '<X>' (<hook>) received no updates in 120 Heartbeats — Stepped/PreSimulation do not fire in Studio Edit mode` (RT 1.5, D16; answers `TickAPI.luau:10`) |
| `Diagnostics()` | `{IsServer, IsClient, IsEdit, IsRoblox, Schedulers = {…}}` — the Cmdr `MCPDiagnostic` consumer |
| memory category | off by default; `MemoryCategory = "TickAPI"` tags the handler's `Update` call (callbacks included) via `Env.SetMemoryCategory`, no-op under Lune (Q-J10, H7) |

## 7. Compatibility layer + accepted deviations (MIGRATION.md)

### 7.1 What the layer is (all zero-cost aliases; no shims)

| Live shape (count, CS §1) | Provided by |
|---|---|
| `TickAPI.Tick/.Tickh/.Tickr .delay(fn,t) / .recur(fn,t)` dot-called, truthy table handle (206 calls) | dual closures `delay/recur` on each instance; handle is a table with metatable (P9 `type(x)=="table"` discriminator holds) |
| `.update(dt)`, `.remove(h)`, `.getClocks()` (wrappers, Cmdr) | closures `update/remove/getClocks` |
| `TickAPI.Tick:remove(h)` colon (2 sites) | dual closure shifts `self` — now actually removes (DV-3) |
| `TickAPI.SafeStopClock(h) → nil` (68 sites, 19 reassign idiom) | verbatim function; tolerant of nil, terminal handles, foreign schedulers |
| `TickAPI.GetAfterNotTouched(t, fn, "Tickh") → {Touch, Destroy}` (1 site) | `TickAfterNotTouched` via injected scheduler |
| `h:stop()` (12), `h:reset()` (9, 2 on recur), `h:adjust(n)` (2), `h:after()` (0) | LEGACY SURFACE region of `TickEvent`: `stop = Stop, reset = Reset, adjust = Adjust, after = After, Destroy = Stop` |
| `tonumber` coercion of delay; error on non-numeric (`HardPointSFXManager:57` nil attribute) | §4.1 |
| `delay(fn, 0)` legal (`CameraClass:307`) | I1 |
| stop from inside own callback (21 sites), stop others from a callback (`EntityActionClass:81-95`) | §4.3 by construction |
| cross-wrapper stop (Strike handles via main `SafeStopClock`) | `h:Stop()` is owner-agnostic |
| `TimeManagerAPI = require(TickAPI)` second name (`FxPackage:25`) | same module table |
| global `TickAPI` leak (`xray.luau:87`) | untouched (module identity unchanged) |

### 7.2 Migration order (each step has a rollback and a verification)

| # | Step | Verify | Rollback |
|---|---|---|---|
| M0 | Lune: full suite + parity green; bench P2 garbage = 0; port `studio_bench.luau` and run once in Studio with `--!native` | `lune run build/tests/run.luau` → 0 failed | — |
| M1 | Copy the old `SharedModules/TickAPI` folder to `ServerStorage/TickAPI_Legacy` (disabled); replace `SharedModules/TickAPI` + children (`Tick/Tick2/Tick3/AfterNotTouchedClass` removed) with `build/src/TickAPI` | Play: `TickAPI.Diagnostics()` on server and client shows `Tick(Stepped)`, `Tickh(Heartbeat)`, client `Tickr`, all `Updates > 0`; no boot-probe warning | swap folders back |
| M2 | Sign-off pass on the behaviour-change sites (§7.3 "who notices"), especially `PrimaryCardControler` (hover-card timers now cancelled) and recur-nested timing (`LegacyRecurBase = true` on `Tick`/`Tickh` for an A/B if timing looks off) | manual Studio checks; `GetStats().Reentries/ValveHits == 0` after a session | flip `LegacyRecurBase`/`CatchUp = "all"` per scheduler |
| M3 | `StrikeTickAPI.luau` → 3-line shim `return { Tick = TickAPI.Register("StrikeTick", { Hook = "Stepped" }) }`; delete its `Tick` child (2 caller files unchanged) | `UpdateAction_ActionServerHitScan`, `Action_ConeHitScan` strike windows fire; `SafeStopClock` on strike handles still stops them | restore the file |
| M4 | Delete the dead `ReplicatedFirst/…/SetupCliffAreaScreenSize_AndANIMATION/TickAPI` copy (0 callers) | grep | restore |
| M5 (later) | SyncedTimerClass replacement (Q-J14) and the RoBase plugin copies (Q-J13) | separate plans | — |

### 7.3 Accepted deviations (each pinned two-sided in `parity_spec`/`regress` tests, §9)

| DV | Legacy | New | Who notices (live) |
|---|---|---|---|
| DV-1 | same-due order newest-first, scrambled by removals (L-13) | `(due, Id)` FIFO (D23) | `DungeonCreator:167-179`, `xray:63-87`, `FxPackage:680/741` — order-independent |
| DV-2 | nested past-due event fires synchronously inside `delay()`, returns a noop dummy (L-04) | later in the same update, real handle returned (D5) | `CameraClass:312-322` (delay-0 inner: one update later, harmless) |
| DV-3 | `Tick:remove(h)` colon = silent no-op + leak (L-12) | works | `PrimaryCardControler:124,141` — hover-card timers now cancelled as intended |
| DV-4 | NaN/inf delay accepted as zombies; recur 0 hangs (L-07/F5) | rejected at creation (D10) | none (no live site) |
| DV-5 | stop-after-fire leaks a key (F3); adjust/reset on a dead handle silently mutate | terminal handles are no-ops (D8) | `UpdateAction_ActionServerHitScan:459` adjust-after-fire → silent no-op |
| DV-6 | parent callback throw kills its `after` chain (B-13) | children still arm | none (0 `after` callers) |
| DV-7 | timer created inside a RECURRING callback waits one extra period (L-01) | measured from the firing due (D4) | ≤ 26 files that `recur` and `delay` on one group (e.g. `FxPackage:1049→680/741`, `EventSpawnerClass:406→345`); `LegacyRecurBase = true` reproduces the quirk per scheduler |
| DV-8 | recurring `stop()` inside own callback while lagging still fires the backlog (L-06) | exactly one fire | 15 "poll until ready then stop" recur sites — strictly better |
| DV-9 | stopping a co-due sibling double-ticks an already-processed entry (L-02) | never | `EntityActionClass:81-95` |
| DV-10 | unbounded catch-up burst after a hitch (L-08) | 8 per handle per update, remainder dropped on-grid (D6); `Tickr` 1 | `Tickr.recur 0.01` refresher, `0.048` blink, 1/24–1/30 flipbooks: no burst after a hitch; `CatchUp = "all"` restores |
| DV-11 | `delay(3×dt)` fires on the 4th frame (L-14) | same class of one-frame lateness, documented (D23) | nobody |
| DV-12 | `getClocks()` always 0 (F7) | real count | 0 callers |
| DV-13 | `after()` on a terminal parent = silent never-fire (L-11) | Fired → arms now; Stopped → Stopped child | 0 callers |
| DV-14 | `fn()` called with no arguments | `fn(handle)` | `fxCensusServer:170 _census()` takes none |
| DV-15 | a throwing callback aborts the frame and poisons `err` (F4/L-03) | isolated, warned | everyone, positively |
| DV-16 | `GetAfterNotTouched(…, "Tickr")` on the server → index-nil deep inside (L-21) | prefixed error at the boundary | none |
| DV-17 | `remove(number)` removes by array index (L-15) | `false` | none |
| DV-18 | AfterNotTouched Id = GUID from MostlyUUID; `Storage` unreachable (L-26) | integer Id; `Count()` | none |
| DV-19 | `Tickr` absent on server, `Tick*` never destroyable | `Tickr` still nil; built-ins destroyable with `Force` | none |

## 8. Decisions on the open questions

| Q | Pick | Rationale |
|---|---|---|
| Q-J1 | Corrected timing (D4) + `LegacyRecurBase` opt-in per scheduler + a migration grep listing the recur+delay files | The quirk is proportional to the parent period and silent; the flag makes any A/B a one-line change instead of a rebuild. |
| Q-J2 | Deferred `Complete()` default, `CompleteNow()` explicit | The five live `ForceEventComplete` callers already observe deferred semantics (S-01/S-14); synchronous-by-default would run expiry callbacks BEFORE their own cleanup — a new behaviour on migration day. |
| Q-J3 | Reject `+inf` | A timer that can never fire only holds memory; no live site passes it (I5). |
| Q-J4 | `Tickr == nil` on the server; `GetAfterNotTouched(…,"Tickr")` → prefixed error | 0 server-container `Tickr` references; live code guards `if TickAPI.Tickr` (H5). |
| Q-J5 | `Remove(nil/non-handle)` → silent `false`; `Strict = true` errors; cross-scheduler → always error | SafeStopClock semantics for teardown paths; a foreign handle is always a wiring bug (S7). |
| Q-J6 | Replace, old returned second | Never nil (S-09); the old handle is still `Stopped`-inspectable. |
| Q-J7 | PascalCase only + the frozen legacy alias set | One canonical spelling; the alias set is closed so the surface cannot drift (BC R1–R3). |
| Q-J8 | 8 / 1000 / `Tickr` MaxCatchUp 1 | 8 covers the 0.01 s refresher (≈2/frame) and flipbooks; render timers never burst (cosmetic); the valve only bounds nested arms. |
| Q-J9 | All three resolve to one path; docs name `TickAPI.New(cfg)` canonical | Callers never require the class module; the static `new` shift is 3 lines. |
| Q-J10 | Not at all by default; `MemoryCategory` opt-in tags `Update` (callbacks included) | A per-frame `setmemorycategory` pair costs on every hook; profiling is opt-in. |
| Q-J11 | Allowed and documented | Tests, catch-up stepping and deterministic child clocks need it; a guard would cost every frame (H4). |
| Q-J12 | `Force` only | 300+ sites depend on the built-ins existing (H6). |
| Q-J13 | Out of scope; listed in MIGRATION.md (42 plugin files behind `PluginGuiService.CoreHolder.Core.TickAPI`; `PrimaryCardControler` colon remove becomes effective; `DashStacks:22` is a SyncedTimer caller bug) | Different require root; fixing callers is a game change, not a library change. |
| Q-J14 | Designed for (keyed + `UpdateTo` + `DelayAt`); migration later | Mapping: `AddEvent→DelayKeyed`, `ForceEventComplete→Complete(key)`, `DeleteEvent→Stop(key)`, `ResetTimer(id,x)→Get(key):SetRemaining(x)`, `AdjustTime→Adjust`, `GetRemainingTime→GetRemaining(key)`, `HasObject→Has`; 16 files (CS §4). |
| Q-J15 | Yes, test-only, hash pinned (`21960b8e125d1cd5`), diff-checked by a spec | BC strategy (c); vendored from HeroicSouls, not GitHub. |

## 9. Test plan (`build/tests/spec/<area>/<name>_spec.luau`; runner = existing `build/tests/run.luau`)

### 9.1 Spec files

| Area/file | Scope |
|---|---|
| `env/env_spec` | Lune load, vendor diff = exactly the JsonR lines, `SetRunService`/`SetWarn` restore, `Load` |
| `heap/heap_spec` | §3.2 ops with the oracle after EVERY op |
| `scheduler/arm_spec`, `dispatch_spec`, `reentrancy_spec`, `time_spec` | §4.1, §4.2, R-C, clock/UpdateTo |
| `handle/state_spec`, `stop_spec`, `retime_spec`, `chain_spec`, `complete_spec` | §5, §4.3–4.7 |
| `keyed/keyed_spec`, `registry/registry_spec`, `afternottouched/afternottouched_spec` | §4.8, §6, §2.5 |
| `baseclass/baseclass_spec` | D13 shape, no duplicate-name warning, field non-nil, dual call, colon guard |
| `parity/parity_spec`, `legacy/tick_reference_spec` | the oracle (§9.2) and the shim faithfulness check (carried from the prior) |
| `regress/legacy_repro_spec`, `regress/prior_repro_spec`, `regress/synced_repro_spec` | one test per research id worth pinning (§9.3) |
| `docs/apidocs_spec`, `docs/migration_spec` | every §2 member appears in API.md; every DV-n appears in MIGRATION.md |
| `bench/bench_spec` | P2 garbage 0 KB, operation-count proofs (§10) |

### 9.2 Oracles

**Heap invariant oracle** (`helpers/oracle.luau`): `Oracle.check(s)` asserts every §3.2 invariant in O(n); `Oracle.wrap(s)`
returns a proxy whose every public call runs the operation then `check` (and, when called inside a callback, checks again
after the pass). All scheduler/handle specs run through the wrapped instance; `heap_spec` additionally runs 20 000
random push/pop/remove/updateKey ops checking every 97 ops and a sorted `(due, Id)` drain (F-ALG-14).

**Parity oracle** (`parity_spec`, vs `reference/lune/Tick.luau`): the prior's adapter/runner design is kept — one step list
runs against `Tick.group()` and against `TickAPI.New{ CatchUp = "all" }` (legacy bursts); per `update` the SORTED fire
list is compared; numbers dyadic (B-20). Steps: `delay, recur, stop, reset, adjust, after, nest (inside a ONE-SHOT
callback), update`. Generator constraints: no stop/reset/adjust from inside callbacks (DV-8/9), no `nest` inside recur
callbacks (DV-7), no nested delay ≤ overshoot (DV-2); 500 seeded ops, plus every scripted scenario from the prior suite.
**Two-sided pins**: each DV-n has a scenario asserting BOTH the legacy value and the new value (e.g. DV-7: legacy nested
fire at 2.500, new at 1.517 with the 1/60 driver; and `LegacyRecurBase = true` equals legacy exactly), so a drift on
either side fails. A second parity run uses default `CatchUp = "cap"` on a generator that never lags > 8 periods.

### 9.3 Edge-case ledger — every spec row / research id → mechanism → named test

| Case(s) | Mechanism | Spec::test |
|---|---|---|
| I1, C3, B-16 | §4.1 due = base+0; top level next update | `arm_spec::delay 0 fires next update even with dt 0`; `dispatch_spec::nested delay 0 fires later in the same update` |
| I2/F5, I3, I4/L-07/B-05, I5, I6/L-17, I7, I8 | §4.1 validation | `arm_spec::recur 0 errors with prior message`; `::negative delay legacy message`; `::NaN and inf rejected`; `::non-number reports original type`; `::numeric string coerced`; `::callable table accepted, non-callable errors first` |
| I9, I10, I11, I13, B-05 dt | `Update` guard | `time_spec::update 0 flushes due`; `::negative, NaN, inf, nil dt error before touching state` |
| I12, L-08, B-21, P7 | §4.2 cap | `dispatch_spec::hitch fires 8 then snaps to grid (phase kept)`; `::catchup all bursts k times`; `::drop = cap 1`; `::per-handle override`; `::period below resolution stops loudly` |
| C1, C4, L-01/B-03, N5 | base carry / Id order | `dispatch_spec::nested delay measured from firing due`; `::nested inside recur corrected (DV-7)`; `::LegacyRecurBase reproduces legacy`; `::cross-scheduler creation uses the other now` |
| C2, L-04 | no sync path | `dispatch_spec::past-due nested fires after creator returns with a real handle` |
| C5, B-02 | valve | `dispatch_spec::self-rescheduling delay 0 stops at 1000 and warns once, rest next update` |
| S1, S2/L-06, S3/L-02 (A/B/C), S5, F3 | §4.3 | `stop_spec::one-shot is Fired inside own callback`; `::lagging recur stops after one fire`; `::stop co-due sibling never double-ticks`; `::recur stopping older one-shot fires once`; `::replace-in-callback lands at correct due`; `::double stop no-op` |
| S4 | terminal no-ops | `state_spec::terminal handles ignore every op and return h` |
| S6, S7, L-15, Q-J5 | `Remove` | `stop_spec::remove nil false`; `::remove non-handle false, Strict errors`; `::foreign handle errors with names`; `::remove number false` |
| S8, L-12, F4(BC) | dual closures | `baseclass_spec::every scheduler entry works dot and colon`; `::colon remove actually removes` |
| S9, B-18 | guard | `baseclass_spec::dot-called handle method raises the colon message` |
| S10, S11, Q-J9 | | `state_spec::Destroy equals stop`; `baseclass_spec::three constructor spellings give one instance shape` |
| A1, A2, A3, A4, A5, A6, A7, A8, A9, A10/B-13, B-07, B-14 | §4.6 | `chain_spec::child stopped before parent never fires`; `::parent stop cascades to grandchildren`; `::after on recurring errors`; `::after on Fired arms from now`; `::after on Stopped returns a Stopped child, never the parent`; `::multiple children fire in registration order`; `::3-deep chain`; `::adjust/pause/resume on a Chained child`; `::children arm from parent ideal due`; `::erroring parent still arms children`; `::GetRemaining on a Chained child is its delay` |
| R1, R2, R3/F6/RF-001, R4, R5, R6, R7, R8/RF-006, R9/B-15, R10, R11 | §4.4/4.5 | `retime_spec::adjust preserves consumed fraction`; `::adjust rejects 0, negative, NaN, inf, nil`; `::adjust on period 0 never NaN`; `::setPeriod affects future arms only`; `::reset one-shot full period from now`; `::reset recurring restarts phase`; `::reset inside own callback`; `::pause/resume matrix never raises`; `::getRemaining scaled`; `::explicit ops from now not base`; `time_spec::rolling clock and timescale` |
| B-01 | §4.5 no same-pass loop | `retime_spec::adjust same period inside lagging callback fires at most twice`; `::pause+resume inside lagging callback bounded` |
| F1–F9, S-01, S-14, E5 | §4.7 | `complete_spec::deferred re-keys to now and fires next update in order`; `::completes non-root entry immediately (S-01)`; `::paused recurring completes and stays paused with full period`; `::chained completes detached`; `::opts.Stop ends a recurring`; `::CompleteNow inside own callback returns false`; `::terminal and nil return false`; `::error inside CompleteNow reported after transitions`; `::exactly one fire when completed mid-update` |
| N1/L-16/B-04, L-05 | R-C | `reentrancy_spec::sync re-entrant update dispatches other timers and restores base`; `::error policy per pass not lost`; `::depth cap 8 degrades to advance-only`; `::yield-overlap (coroutine) keeps other timers firing and drains on resume`; `::recurring whose callback yields past its period fires again` |
| N2, N3, N4 | §4.10 | `registry_spec::Drive advances child exactly period per fire`; `::Attach cascades Destroy, Detach does not`; `::Destroy from inside own update fires nothing further` |
| H1–H7, RT rules, B-11, B-12, L-18, L-21 | §6 | `registry_spec::built-ins boot with fake RunService`; `::duplicate name errors`; `::Get/Unregister`; `::Stepped passes 2nd arg`; `::client-only refused on server`; `::missing signal prefixed error`; `::dt sanitized and clamped`; `::boot probe warns once without Stepped`; `::built-in Destroy needs Force`; `::injection restore` |
| E1–E4, F4/L-03 | `_runCallback` | `dispatch_spec::throwing callback does not stop siblings`; `::error policy re-raises first after pass`; `::function policy receives handle; its own error is warned` |
| O1–O4, B-09/B-10 | | `registry_spec::GetClocks and GetStats counters`; `bench_spec::idle update allocates 0 bytes`; `baseclass_spec::handle key set never grows after construction` |
| D22, S-09, S-03, S-12 | §4.8 | `keyed_spec::replace returns old second`; `::Has never lies after fire`; `::unknown key nil not 0`; `::SetRemaining leaves period` |
| D2, S-11, F-ALG-12 | §4.9 | `time_spec::UpdateTo exact at scale 1`; `::backwards clamped and counted`; `::paused folds gap into offset`; `::DelayAt` |
| L-23, L-24, L-25, L-26, B-08, B-19 | §2.5 | `afternottouched_spec::fn error still destroys and keeps traceback`; `::registered before arming`; `::Touch after Clear self-destroys`; `::Count`; `::server Tickr error` |
| D13, BC F2/F7/F9 | | `baseclass_spec::loading every class module prints no "already Exsist" (subprocess)`; `::isInstanceOf/class/type on a literal handle`; `::every field non-nil after construction`; `::no __index function on any class` |
| D14/Q-J15 | | `env_spec::vendor BaseClass differs from reference only at the JsonR lines` |
| D19 | | `docs/apidocs_spec::every public member documented`; `docs/migration_spec::every DV pinned and documented` |

Count: 114 named tests above (≥ 60), plus the parity scenarios (9 scripted + 1 seeded + 19 two-sided pins).

## 10. Bench plan (`build/bench/bench.luau`, Lune; `studio_bench.luau` for `--!native`)

| Phase | What it proves |
|---|---|
| P1 arm 10k random dues | ns/op ≤ 1.2× IB prototype (250 ns); bytes/timer ≈ 576 + closure |
| P2 200 idle updates with 10k armed | **`collectgarbage("count")` delta == 0 KB exactly** (the zero-garbage idle check; D1/D24) and ≤ 0.05 µs/update |
| P3 10k shuffled stops | flat, no spike; heap size 0 after; paused/key indexes empty |
| P4 10k shuffled adjusts / P5 10k resets | heap size stays 10k (no orphans); in-place re-key cost |
| P6 fire storm 10k in one update | ns/dispatch; all fired; `Dispatched == 10000` |
| P7 10k recurring × 600 updates | µs/update, garbage 0; ties variant (equal periods, same frame) decides `seq[]` array |
| P8 mixed churn 2k live | the realistic number; regression guard ±15 % |
| P9 adjust storm 10 rounds | max round ms, no rebuild spikes |
| P10 dual-call overhead | `s.delay` vs raw method: ≤ +30 ns |
| P11 handle construction | literal vs `TickEvent:new` (must never be used on the hot path) |
| P12 re-entrancy tax | pass with `depth = 1` vs `0`: identical within noise |

Regression rule: `bench_spec` asserts P2 == 0 KB and the operation counts (`examined == dispatched + 1` per update) on
every run; timings are reported, not asserted, under Lune. Studio port asserts `<native>` in the Script Profiler.

## 11. Risks & mitigations; out of scope

| Risk | Mitigation |
|---|---|
| Yield-overlap correctness (a callback suspended mid-pass while another pass runs) | R-C depth counter, in-place mutations, per-pass save/restore; coroutine-driven `reentrancy_spec`; `Reentries` stat + warn once so it is visible in Studio |
| DV-7 timing change surprises FX tuning | `LegacyRecurBase` per scheduler; migration grep of recur+delay files; two-sided parity pin |
| DV-10 drop policy loses ticks for logic timers (DoT/regen) | `CatchUp = "all"` per scheduler or per handle; `Dropped` stat; call out in MIGRATION.md |
| `--!native` disabled silently (breakpoints, typed-arg mismatch) | Studio bench checks `<native>`; hot loop uses only locals and arrays |
| Bound-closure shadowing hides a class method change | closures are built from `dict[name]` at `initialize`; `baseclass_spec` asserts every public method has a closure |
| Registry name collisions with other projects' `BaseClass.class` names | `Tick*` prefixes; subprocess spec for the warning |
| Cmdr/Diagnostics allocating tables | only `GetStats/Diagnostics` allocate; never called by the hooks |
| `OnError = "error"` inside a RunService handler | re-raise happens after the pass; the connection survives; documented |

Out of scope (and why): RoBase plugin copies and the dead ReplicatedFirst copy beyond M4 (different require root, Q-J13);
fixing game-side caller bugs (`DashStacks`, `UpdateAction_ActionServerHitScan:113` wrong-timer adjust — S-15); replacing
SyncedTimerClass now (Q-J14: API designed, migration is its own plan); an "owed-counter" catch-up mode D (post-loop
mutation; add later if "never drop a tick" is required); 4-ary heap and a third `seq[]` array (decide after the Studio
bench, alg R8); handle pooling (D13, ABA risk); `ConnectionVault` for the 3–4 registry connections (drags HttpService
into the Roblox path; BC §7).

# Design candidate "lean" — LEAN CORE

Author: design-panel agent, 2026-09-16. Inputs: `docs/DECISIONS-BRIEF.md` (D1–D24 honoured verbatim, Q-J1..15 decided in §8),
`research/semantics-spec.md` (rows cited as `SEM I1`, `SEM S3`…), `research/scheduler-algorithms.md` (`ALG §3.2`…), the six
other reports (`CS-`, `L-`, `S-`, `B-`, `RT-`, `BC-` ids). Angle: the smallest set of mechanisms that meets every settled
decision and every Jake ask; each mechanism is reused before a second one is added. §11 lists what was left out and why it is safe.

Lean principles applied (referenced below as **LP-n**):

| id | principle | where it bites |
|---|---|---|
| LP-1 | One counter: the handle `Id` IS the equal-due tie-break (D1's `_Seq`). | heap sifts read `item[i].Id` |
| LP-2 | One side table: `_Paused[h] = remaining` is the paused set, the frozen remaining, AND the "pause-while-Chained" flag (D8). | no `_Remaining`, no `_PauseOnArm` field |
| LP-3 | One time mechanism: `SetTimeScale(0)` is the scheduler freeze; no separate scheduler Pause/Resume. `UpdateTo` re-anchors its offset on scale change. | D2 offset math |
| LP-4 | One resolver: scheduler `Stop/Complete/GetRemaining` accept a handle **or** a key string. `Remove` = `Stop`. | D18 + D22 in one path |
| LP-5 | One catch-up number: `"all"` = `math.huge`, `"drop"` = 1, `"cap"` = N. The loop compares against a number, never a mode string. | D6 |
| LP-6 | One exit mechanism: `Clear()` empties the heap; the dispatch loop re-reads `_Count` each iteration, so `Destroy()` from inside a callback needs no extra flag check. | D3/N4 |
| LP-7 | One arm helper `_arm(self, h, due)` and one constructor helper `_newEvent(...)` serve Delay/Recur/After/Keyed/Drive. | D13 constructor literal |
| LP-8 | No pooling, no generation tags, no `_ext` sub-table, no Variants module, no Driver module, no per-update tables. | D1/D13/D24 |

## 1. Object model + file layout

```
build/src/TickAPI/
  init.luau                     registry (plain table)  ── requires ──▶ Env, TickScheduler, TickAfterNotTouched
  Env/init.luau                 platform seam (plain table): BaseClass, RunService, Warn, IsClient/IsServer, Load(name)
  TickScheduler/init.luau       BaseClass root class: heap (file-local), dispatch, hooks, keyed timers, attach  ──▶ Env, TickEvent
  TickEvent/init.luau           BaseClass root class: handle facade (colon guard, queries, LEGACY SURFACE)     ──▶ Env
  TickAfterNotTouched/init.luau BaseClass root class: touch-to-reset self-destroying clock                    ──▶ Env
build/vendor/BaseClass.luau     live BaseClass with the JsonR line replaced (test-only; sha 21960b8e125d1cd5, reference/SOURCES.md)
```

| module | kind | responsibility (one line) | arrows |
|---|---|---|---|
| `TickAPI/init.luau` | plain table | boots `Tick/Tickh/Tickr`, `New/Register/Get/Unregister`, `SafeStopClock`, `GetAfterNotTouched`, exports classes + `State`/`Hooks` | → Env, TickScheduler, TickAfterNotTouched |
| `Env` | plain table | the only file allowed to touch `game`; resolves BaseClass, RunService, `warn`; `Load(name)`; test seams `SetRunService(fake)`, `SetWarn(fn)` | → vendor BaseClass (Lune) / `ReplicatedStorage.SharedModules.BaseClass` (Roblox) |
| `TickScheduler` | `BaseClass.class("TickScheduler")` root, no mixins, no `__index` | virtual clock, indexed heap (file-local `_siftUp/_siftDown/_heapPush/_heapPop/_heapRemove/_heapUpdate/_heapClear`), `_dispatch`, every handle mutation as a `_PascalCase` private method, RunService bind, keyed map, attached children | → Env, TickEvent |
| `TickEvent` | `BaseClass.class("TickEvent")` root; instances built by literal + `setmetatable(t, TickEvent.__instanceDict)` | states, colon guard, read-only queries, thin mutators delegating to `self._Scheduler:_Op(self)`, LEGACY SURFACE aliases | → Env (BaseClass only) |
| `TickAfterNotTouched` | `BaseClass.class("TickAfterNotTouched")` root | `new(scheduler, seconds, fn)`, `Touch`, `Destroy`, static `Count`, `Storage` | → Env |

Why no Driver/Variants/Heap modules (LP-8): the driver is two scheduler methods (`Bind/Unbind`) plus one sanitising closure;
config validation is 20 lines inside `initialize`; the heap is seven file-local functions over `self._Due/_Item` (D13), which keeps
`item[i]` reads free of a module hop (ALG F-ALG-7) and keeps every heap mutation private to one file. The handle facade costs one
extra method call (13 ns, BC §2) on cold operations only; the hot path (`_dispatch`) never calls through it.

Neighbour loading (W/CLAUDE.md Lune rules, verified on 0.10.5 by the prior build):

```lua
-- Env/init.luau — the seam. Under Lune `script` is nil, so typeof(script) == "nil".
Env.IsRoblox = typeof(script) == "Instance"
if Env.IsRoblox then
	Env.BaseClass = require(game:GetService("ReplicatedStorage"):WaitForChild("SharedModules").BaseClass)
	Env.RunService = game:GetService("RunService")
else
	Env.BaseClass = require("../../vendor/BaseClass") -- "./" inside Env/init.luau is build/src/TickAPI
	Env.RunService = nil                               -- every hook is Manual without a RunService
end
function Env.Load(name) return Env.IsRoblox and require(script.Parent[name]) or require("./" .. name) end
-- class modules:  local Env = typeof(script) == "Instance" and require(script.Parent.Env) or require("./Env")
-- registry:       local Env = typeof(script) == "Instance" and require(script.Env) or require("./TickAPI/Env")
```

`Env.IsClient/IsServer` come from RunService on Roblox and are `false/false` under Lune (specs call `Env.SetRunService(fake)`
before requiring the registry). `Env.Warn` defaults to `warn`; `Env.SetWarn(fn)` lets specs capture the one-time warnings and
the BaseClass duplicate-name warning (BC-6).

## 2. Public API reference

Conventions: **dual** = dot and colon (per-instance bound closure installed in `initialize`, first arg `== self` → shift; D15);
**colon** = colon-only, guard error `TickAPI: TickEvent methods take a colon (h:Stop(), not h.Stop())` at level 2.
Every library error starts with `TickAPI: ` (legacy bodies kept verbatim after the prefix). `h` = handle, `s` = scheduler.
States: `Pending | Paused | Chained | Fired | Stopped` (numbers 1..5 internally; names exported as `TickAPI.State`).

### 2.1 Registry `TickAPI` (plain table; every member dot-called)

| member | signature → return | semantics | errors |
|---|---|---|---|
| `VERSION` | `"3.0.0"` | | |
| `Tick`, `Tickh`, `Tickr` | schedulers | Stepped / Heartbeat / RenderStepped built-ins (`Tickr` **nil** unless `Env.IsClient`); `MaxCatchUp` 8 / 8 / 1 (Q-J8); `_IsBuiltIn = true` | |
| `New` | `(cfg?) -> s` | `TickScheduler:new(cfg)`; when `cfg.Name` is a string the scheduler is registered | dup name: `TickAPI: scheduler name 'X' already registered` |
| `Register` | `(s) -> s` | adds `s` under `s.Name`; sets `s._Registry` so `Destroy` unregisters itself (SEM N4) | `TickAPI: cannot register an unnamed scheduler`; dup as above |
| `Get` | `(name) -> s?` | lookup | |
| `Unregister` | `(name) -> s?` | removes without destroying | |
| `SafeStopClock` | `(h) -> nil` | `nil` → `nil`; else `h:Stop()`; always returns `nil` (CS §3 idiom `x = SafeStopClock(x)`) | never |
| `GetAfterNotTouched` | `(seconds, fn, tickType) -> obj` | `TickAfterNotTouched:new(TickAPI[tickType], seconds, fn)` | `TickAPI: unknown tick type <x>` when `TickAPI[tickType]` is not a TickScheduler (covers `"Tickr"` on the server, L-21) |
| `TickScheduler`, `TickEvent`, `TickAfterNotTouched` | classes | exported for `isInstanceOf`, custom construction, specs | |
| `State` | frozen `{Pending = "Pending", …}` | state names | |
| `Hooks` | frozen list | `Heartbeat, Stepped, RenderStepped, PreRender, PreAnimation, PreSimulation, PostSimulation, Manual` | |

### 2.2 `TickScheduler` (every public method dual; canonical PascalCase)

Constructor (Q-J9): `TickAPI.New(cfg)` (canonical, registers), `TickScheduler:new(cfg)`, `TickScheduler(cfg)` (BaseClass `__call`),
and `TickScheduler.new(cfg)` through a 4-line `static.new` override that shifts `self` when it is not the class — Jake's
`NewTick.new()` spelling. All four run the same `initialize`.

| cfg key | type | default | validation error (prefix `TickAPI: config `) |
|---|---|---|---|
| `Name` | string | `"TickScheduler#<n>"` (auto names never register) | `Name must be a string` |
| `Hook` | one of `Hooks` | `"Manual"` | `unknown hook 'X'` |
| `TimeScale` | finite ≥ 0 | 1 | `TimeScale must be a finite number >= 0` |
| `CatchUp` | `"cap"`, `"all"`, `"drop"` | `"cap"` | `CatchUp must be cap, all or drop` |
| `MaxCatchUp` | integer ≥ 1 | 8 | `MaxCatchUp must be an integer >= 1` |
| `Valve` | integer ≥ 1 | 1000 | `Valve must be an integer >= 1` |
| `MaxDt` | finite > 0 or `false` | 0.25 | `MaxDt must be a positive number or false` |
| `OnError` | `"warn"`, `"error"`, `function(message, h)` | `"warn"` | `OnError must be warn, error or a function` |
| other | | | `unknown key 'X'` |

| member | alias | signature → return | semantics | errors / notes |
|---|---|---|---|---|
| `Update` | `update` | `(dt) -> ()` | `now += dt * TimeScale`, then `_dispatch` (§4.2); `_Updates += 1` | `TickAPI: Update(dt) expects a finite number >= 0, got <v>`; dead: `TickAPI: scheduler 'X' is destroyed` |
| `UpdateTo` | — | `(absoluteNow) -> ()` | first call anchors the offset without advancing; scale 1: `target = t - offset`; else `target = now + (t - lastAbs) * scale`; backwards → clamp, `ClampedBackwards += 1` (D2) | validation as `Update` |
| `Now` | — | `() -> number` | scheduler seconds from 0 | |
| `SetTimeScale`, `GetTimeScale` | — | `(s) -> ()`, `() -> number` | 0 freezes; re-anchors the `UpdateTo` offset (LP-3) | `TickAPI: TimeScale must be a finite number >= 0` |
| `Delay` | `delay` | `(fn, t) -> h` | one-shot at `clockOf() + t` (base carry inside callbacks, D4); `"2"` coerced (SEM I7) | `TickAPI: expected \`fn\` to be callable`; `TickAPI: expected \`delay\` to be a number. CurrentType: <original type>`; `TickAPI: expected \`delay\` to be a finite number` (NaN, ±inf; Q-J3); `TickAPI: expected \`delay\` of zero or greater`; dead-scheduler error |
| `Recur` | `recur` | `(fn, p) -> h` | recurring, first fire at `clockOf() + p` | as `Delay` plus `TickAPI: expected recur \`delay\` greater than zero` for 0 |
| `DelayKeyed`, `RecurKeyed` | — | `(key, fn, t) -> h, old?` | as above; existing key → old handle's `_Key` cleared, old stopped, returned second (Q-J6) | `TickAPI: key must be a string` |
| `Stop` | `remove` | `(hOrKey) -> boolean` | LP-4 resolver; `true` iff a live handle became Stopped; `nil`, non-handle, unknown key → `false` (D18, Q-J5) | foreign: `TickAPI: handle #<id> belongs to scheduler '<Y>', not '<X>'` |
| `Complete` | `ForceEventComplete` | `(hOrKey, stop?) -> boolean` | deferred completion (§4.7); `false` for terminal/unknown | foreign error as `Stop` |
| `Has`, `Get` | — | `(key) -> boolean`, `(key) -> h?` | live keyed handle only | |
| `GetRemaining` | — | `(hOrKey) -> number?` | `h:GetRemaining()`; `nil` for unknown | |
| `GetClocks` | `getClocks` | `() -> number` | `_Count + _PausedCount` (Pending + Paused; Chained excluded, D20) | |
| `GetStats` | — | `() -> table` | fresh table: `Name, Hook, Now, Pending, Paused, Chained, HeapSize, Updates, Dispatched, Reentries, Dropped, ValveHits, ClampedBackwards, Keyed, Attached` | allocates (cold) |
| `Clear` | — | `() -> ()` | stops Pending, Paused, Chained (through chains), clears keys, cascades to attached children; safe from inside a callback (LP-6) | |
| `Destroy` | — | `(force?) -> ()` | `Unbind`, `Clear`, destroy attached children, unregister, `_IsDead = true`; idempotent | built-in without `force == true`: `TickAPI: built-in scheduler 'Tick' needs Destroy(true)` (Q-J12) |
| `IsDestroyed` | — | `() -> boolean` | | |
| `Bind` | — | `(hook) -> ()` | one RunService connection; the handler sanitises dt (NaN/negative → 0, clamp to `MaxDt`); Stepped uses arg 2 (RT §1.1); `Manual`, or no RunService, records the hook and connects nothing | `TickAPI: scheduler 'X' is already bound to 'Y'; call Unbind() first`; `TickAPI: hook 'RenderStepped' is client only`; `TickAPI: RunService has no signal 'X'`; `TickAPI: unknown hook 'X'` |
| `Unbind`, `IsBound` | — | `() -> ()`, `() -> string?` | idempotent disconnect / bound hook or `nil` | |
| `Attach`, `Detach` | — | `(child) -> ()` | ownership: `Destroy`/`Clear` cascade to attached children (D17) | `TickAPI: Attach expects another TickScheduler` |
| `Drive` | — | `(child, period) -> h` | `Recur(function() child.Update(period) end, period)` then `Attach(child)` (SEM N2) | validation as `Recur`/`Attach` |
| `SetOnError` | — | `(policy) -> ()` | runtime policy swap (SEM E2) | as cfg |
| `Name` | — | string field | public | |

Manual `Update` on a bound scheduler is allowed and documented as a double-advance hazard (Q-J11).

### 2.3 `TickEvent` handle (colon-only; guard is the first line of every method; every method total on terminal states, D8)

| member | alias | signature → return | semantics per state (P Pending, Pa Paused, C Chained, T terminal) |
|---|---|---|---|
| `Id` | — | number field | ascending per scheduler from 1, never reused; the tie-break (LP-1) |
| `Stop` | `stop`, `Destroy` | `() -> ()` | P: heap remove; Pa: leave `_Paused`; C: mark Stopped (the parent skips it); cascades to Chained children; T: no-op |
| `Reset` | `reset` | `() -> h` | P: re-key `now + period` (inside its own recurring callback this replaces `d + period`, SEM R7); Pa: `_Paused[h] = period`; C/T: no-op |
| `Adjust` | `adjust` | `(newTotal) -> h` | D9: `frac = period > 0 and clamp((due - now) / period, 0, 1) or 1`; P: `due' = now + frac * newTotal`; Pa: `remaining' = frac * newTotal`; C: delay only; then `period = newTotal`; T: no-op | error `TickAPI: expected \`newTotal\` greater than zero` for non-finite or ≤ 0 |
| `SetPeriod` | — | `(p) -> h` | future arms only; validation as creation (finite; `> 0` recurring; `>= 0` one-shot) |
| `SetRemaining` | — | `(x) -> h` | "x more seconds" from `now`, period untouched (S-12); P: re-key; Pa: `_Paused[h] = x`; C/T: no-op; `x` finite ≥ 0 |
| `Pause` | — | `() -> h` | P: `_Paused[h] = max(due - now, 0)`, heap remove; C: `_Paused[h] = period` (the flag, LP-2); Pa/T: no-op |
| `Resume` | — | `() -> h` | Pa: push at `now + remaining`, clear entry; C with flag: clear flag; else no-op |
| `After` | `after` | `(fn, t) -> child` | recurring parent: `TickAPI: cannot chain a recurring event`; P/Pa/C parent: child Chained, registration order; Fired parent: child armed at `clockOf() + t`; Stopped parent: child born Stopped — never the parent (SEM A4/A5) |
| `Complete` | — | `(stop?) -> boolean` | deferred (§4.7); `false` on T |
| `CompleteNow` | — | `(stop?) -> boolean` | synchronous (§4.7); `false` on T or when `self == scheduler._Firing` |
| `SetCatchUp` | — | `(n or "all") -> h` | per-handle override: integer ≥ 1 or `math.huge` (LP-5); `TickAPI: expected catch-up count >= 1 or "all"` |
| `GetRemaining` | — | `() -> number` | P: `max(due - now, 0)`; Pa: frozen; C: period; T: 0 (scheduler seconds, SEM R9) |
| `GetPeriod`, `IsRecurring`, `GetKey`, `GetScheduler` | — | getters | |
| `GetState` | — | `() -> string` | name; inside its own callback a one-shot already reads `"Fired"` (SEM S1) |
| `IsActive` | — | `() -> boolean` | P/Pa/C |

### 2.4 `TickAfterNotTouched`

| member | signature → return | semantics |
|---|---|---|
| `TickAfterNotTouched:new(scheduler, seconds, fn)` | `-> obj` | requires `scheduler:isInstanceOf(TickScheduler)` (`TickAPI: AfterNotTouched needs a TickScheduler`); `Id` = module counter; `Storage[Id] = self` **before** `self.Clock = scheduler.Delay(wrapper, seconds)` (L-25); wrapper = `xpcall(fn, debug.traceback)` → `self:Destroy()` → `error(message, 0)` so the scheduler's policy sees it with the inner traceback (D21) |
| `obj:Touch()` | `-> ()` | destroying → no-op; `Clock:GetState() ~= "Pending"` → `self:Destroy()` (closes L-23's silent-forever); else `Clock:Reset()` |
| `obj:Destroy()` | `-> ()` | idempotent: `isDestroying = true`, `Clock = SafeStopClock(Clock)`, `Storage[Id] = nil` |
| `TickAfterNotTouched.Count()` | `-> number` | live objects |
| fields | `Id`, `Clock`, `isDestroying` | legacy names kept (0 external readers, CS §3) |

## 3. Internal data layout

### 3.1 Scheduler instance fields (all assigned in `initialize`; hot ones first)

| field | type | purpose |
|---|---|---|
| `_Due` | `{number}` | heap keys, dense, 1-based |
| `_Item` | `{TickEvent}` | parallel handles; `_Item[h._HeapIndex] == h` is the ownership check |
| `_Count` | number | heap size == Pending count |
| `_Now` | number | virtual clock |
| `_Base` | `false` or number | firing entry's ideal due while a callback runs (`0` is truthy, so `_Base or _Now` is exact) |
| `_Firing` | `false` or TickEvent | the handle whose callback is running (CompleteNow self-guard) |
| `_Depth` | number | update nesting depth; `> 1` = re-entry |
| `_Serial` | number | pass serial for the handles' `_BurstSerial` self-reset |
| `_NextId` | number | last issued `Id` (LP-1) |
| `_MaxCatchUp`, `_Valve`, `_TimeScale`, `_MaxDt` | numbers (`_MaxDt` may be `false`) | policy |
| `_OnError` | string or function | policy |
| `_Errored` | `false` or string | first message under `"error"`, re-raised when depth returns to 0 |
| `_Paused` | `{[TickEvent]: number}` | LP-2 side table |
| `_PausedCount`, `_ChainedCount` | numbers | gauges; also gate the cold `_Paused` lookups |
| `_Keyed` | `{[string]: TickEvent}` | keyed timers |
| `_Children` | `false` or `{[TickScheduler]: true}` | attached schedulers |
| `_Hook`, `_Connection` | `false` or string, `false` or connection | binding |
| `_Offset`, `_LastAbs` | number, `false` or number | `UpdateTo` anchor |
| `_IsDead`, `_IsBuiltIn` | booleans | |
| `_Registry` | `false` or table | registry map, for self-unregister |
| `_Updates`, `_Dispatched`, `_Reentries`, `_Dropped`, `_ValveHits`, `_ClampedBackwards` | numbers | stats (cumulative) |
| `Name` | string | public |
| bound closures | `Update, update, Delay, delay, …` | dual entry points, installed by one loop over a frozen `{PascalName = aliasOrFalse}` list |

### 3.2 Handle constructor literal (exactly 14 fields, 576 B; ALG F-ALG-9)

```lua
local function _newEvent(self, callback, period, isRecur, state)
	local id = self._NextId + 1
	self._NextId = id
	return setmetatable({
		class = TickEvent,      -- BaseClass identity (isInstanceOf)
		type = "TickEvent",     -- what Class:new would have set
		Id = id,                -- public; doubles as the (due, seq) tie-break
		_Scheduler = self,      -- owner; foreign-handle check
		_Callback = callback,   -- function or __call table
		_Period = period,       -- delay (one-shot) or period (recurring); Chained: the child's delay
		_IsRecur = isRecur,     -- boolean
		_State = state,         -- 1 Pending, 2 Paused, 3 Chained, 4 Fired, 5 Stopped
		_HeapIndex = 0,         -- 0 = not in the heap
		_Chained = false,       -- false | {child, …} lazily created by After()
		_Key = false,           -- false | string (keyed timers)
		_MaxCatchUp = false,    -- false = inherit the scheduler's number
		_Burst = 0,             -- fires so far in the pass named by _BurstSerial
		_BurstSerial = 0,       -- pass serial that _Burst refers to
	}, eventDict)
end
```

`_Remaining` and `_PauseOnArm` are absent by LP-2; `_Seq` by LP-1; `_Parent` because a parent arms only children still in state
Chained, so a stopped or completed child is skipped without ever detaching it. `_Callback` is private: no live site reads `.fn`
(BC R5). Every field is non-nil so each read is a rawget hit (BC F7).

### 3.3 Side structures

| structure | shape | notes |
|---|---|---|
| heap | `_Due[1..n]`, `_Item[1..n]`, `h._HeapIndex` | ALG §3.2 verbatim (hole-move sifts, ownership check); equal keys resolved by `Id` |
| paused set | `_Paused[h] = remaining` | membership while Paused (frozen remaining), Chained (pause-on-arm flag, value = period), or Pending after `Complete()` on a Paused recurring (value = period; the loop re-parks it after the fire) |
| chained lists | `parent._Chained = {c1, c2, …}` | registration order; consumed (set back to `false`) when the parent fires; walked on Stop/Clear |
| keyed | `_Keyed[key] = h`, `h._Key = key` | cleared on Stop, natural one-shot fire, replace, Clear |
| attached | `_Children[child] = true` | walked by Destroy/Clear |

## 4. Algorithms (real Luau; file-local helpers of `TickScheduler/init.luau` unless stated)

Module head: `--!native`; localized `local xpcall, traceback, HUGE = xpcall, debug.traceback, math.huge`; numeric state
constants `PENDING, PAUSED, CHAINED, FIRED, STOPPED = 1, 2, 3, 4, 5` (terminal ⇔ `_State >= FIRED`); `local eventDict =
TickEvent.__instanceDict`. `--[[ HOT PATH: measured ALG §2.2 P6/P7 ]]` marks §4.1–4.2 only; everything else is house style.

### 4.1 Heap — ALG §3.2 adopted verbatim with two renames

`h._hi` → `h._HeapIndex`, `h._seq` → `h.Id` (LP-1), functions `_siftUp(due, item, i)`, `_siftDown(due, item, n, i)`, `_heapPush(self, h, d)`,
`_heapPop(self) -> d, h`, `_heapRemove(self, h) -> boolean`, `_heapUpdate(self, h, newDue)`, `_heapClear(self)`. The only compare is
`d < dp or (d == dp and it.Id < item[p].Id)`. `_heapRemove`'s ownership check (`item[i] ~= h → false`) protects the arrays from any
stale index; `_heapUpdate` asserts ownership with `TickAPI: handle is not scheduled on this scheduler` (unreachable through the public
API because every caller checks `_State` first; kept as the internal invariant guard).

### 4.2 Arm and dispatch

```lua
local function _clockOf(self) return self._Base or self._Now end          -- D4: implicit arms carry the firing due

local function _checkArgs(self, callback, delay, isRecur)                 -- D10; level 3 = the caller of the bound closure
	if self._IsDead then error("TickAPI: scheduler '" .. self.Name .. "' is destroyed", 3) end
	if not _isCallable(callback) then error("TickAPI: expected `fn` to be callable", 3) end
	local originalType = type(delay)
	local number = tonumber(delay)
	if type(number) ~= "number" then
		error("TickAPI: expected `delay` to be a number. CurrentType: " .. originalType, 3)
	end
	if number ~= number or number == HUGE or number == -HUGE then
		error("TickAPI: expected `delay` to be a finite number", 3)
	end
	if number < 0 then error("TickAPI: expected `delay` of zero or greater", 3) end
	if isRecur and number == 0 then error("TickAPI: expected recur `delay` greater than zero", 3) end
	return number
end

function TickScheduler:Delay(callback, delay)                                -- Recur is identical with isRecur = true
	local period = _checkArgs(self, callback, delay, false)
	local h = _newEvent(self, callback, period, false, PENDING)
	_heapPush(self, h, _clockOf(self) + period)
	return h
end

local function _report(self, message, h)                                    -- D11; strings are built only on the error path
	local policy = self._OnError
	if policy == "warn" then
		Env.Warn("[" .. self.Name .. "] callback error: " .. message)
	elseif policy == "error" then
		if not self._Errored then self._Errored = message end
	elseif not pcall(policy, message, h) then
		Env.Warn("[" .. self.Name .. "] callback error (OnError handler failed): " .. message)
	end
end

local function _armChildren(self, parent, d)                                -- D3: BEFORE the parent's callback
	local children = parent._Chained
	parent._Chained = false
	for _, child in children do
		if child._State == CHAINED then                                       -- stopped/completed children are skipped
			self._ChainedCount -= 1
			if self._PausedCount > 0 and self._Paused[child] ~= nil then
				child._State = PAUSED                                         -- paused while Chained: frozen with remaining = its delay
			else
				child._State = PENDING
				_heapPush(self, child, d + child._Period)                     -- measured from the parent's ideal due (SEM A9)
			end
		end
	end
end

--[[ HOT PATH: measured ALG §2.2 P6/P7. Locals only, no allocation, nothing scheduled after a callback (D3). ]]
local function _dispatch(self)
	local due, item, paused = self._Due, self._Item, self._Paused
	local depth = self._Depth + 1
	self._Depth = depth
	if depth > 1 then                                                          -- D12: tolerated, counted, warned once
		self._Reentries += 1
		if self._Reentries == 1 then Env.Warn("[" .. self.Name .. "] Update re-entered from a callback (see Stats.Reentries)") end
	end
	local savedBase, savedFiring = self._Base, self._Firing                    -- restored so an outer callback keeps its carry
	local serial = self._Serial + 1
	self._Serial = serial
	local startId, valve, valveLimit = self._NextId, 0, self._Valve

	while self._Count > 0 do                                                   -- re-read every iteration (LP-6, D3)
		local now = self._Now
		local d = due[1]
		if d > now then break end
		local h = item[1]
		if h.Id > startId or h._BurstSerial == serial then                     -- D5 valve: created this pass, or firing again this pass
			valve += 1
			if valve > valveLimit then
				self._ValveHits += 1
				if self._ValveHits == 1 then _report(self, "runaway valve hit (" .. valveLimit .. " nested dispatches); rest deferred to the next update", h) end
				break
			end
		end
		if h._IsRecur then
			local burst = 1
			if h._BurstSerial == serial then burst = h._Burst + 1 else h._BurstSerial = serial end
			h._Burst = burst
			local period = h._Period
			if burst > (h._MaxCatchUp or self._MaxCatchUp) then                -- D6 "cap": snap to the first grid point > now, drop the rest
				local skipped = (now - d) // period + 1
				local nextDue = d + skipped * period
				if nextDue <= now then nextDue += period end
				if nextDue <= now then                                          -- period below float resolution: stop loudly
					_heapPop(self); h._State = STOPPED; _forgetKey(self, h)
					_report(self, "recur period " .. period .. " is below clock resolution at now = " .. now .. "; handle stopped", h)
				else
					due[1] = nextDue; _siftDown(due, item, self._Count, 1)
					self._Dropped += skipped
				end
				continue
			end
			if self._PausedCount > 0 and paused[h] ~= nil then                 -- Complete() on a Paused recurring: fire once, stay Paused
				_heapPop(self); h._State = PAUSED; paused[h] = period
			else
				due[1] = d + period; _siftDown(due, item, self._Count, 1)        -- re-key in place BEFORE the callback
			end
		else
			_heapPop(self)
			h._State = FIRED                                                   -- SEM S1: Fired before the callback
			if h._Key then _forgetKey(self, h) end
			if h._Chained then _armChildren(self, h, d) end
		end
		self._Base, self._Firing = d, h
		self._Dispatched += 1
		local ok, message = xpcall(h._Callback, traceback)                     -- ALG F-ALG-10: +31 ns
		if not ok then _report(self, message, h) end                           -- bookkeeping only; the heap is already final
	end

	self._Base, self._Firing = savedBase, savedFiring
	self._Depth = depth - 1
	if depth == 1 and self._Errored then                                       -- "error" policy: after the outermost pass only (B-04 §1)
		local message = self._Errored
		self._Errored = false
		error(message, 0)
	end
end

local function _advanceTo(self, target)                                      -- D2: one advance + dispatch for both entry points
	if target > self._Now then self._Now = target elseif target < self._Now then self._ClampedBackwards += 1 end
	self._Updates += 1
	_dispatch(self)
end

function TickScheduler:Update(dt)
	if type(dt) ~= "number" or dt ~= dt or dt < 0 or dt == HUGE then
		error("TickAPI: Update(dt) expects a finite number >= 0, got " .. tostring(dt), 3)
	end
	if self._IsDead then error("TickAPI: scheduler '" .. self.Name .. "' is destroyed", 3) end
	_advanceTo(self, self._Now + dt * self._TimeScale)
end
```

Properties that make the loop obviously correct: (a) the heap is in its final post-fire shape before user code runs, so any
`Stop/Reset/Adjust/Pause/Complete` from the callback simply wins (ALG §3.3 rule 3); (b) a stop of a co-due sibling is an immediate
`_heapRemove`, seen by the next `due[1]` read (SEM S3); (c) a nested `Update` runs a full pass with its own `serial/startId/valve`
locals and restores `_Base/_Firing`; the suspended outer loop resumes on a heap it re-reads, so no entry is dispatched twice
(SEM N1, L-05, L-16, B-04); (d) `Clear()` from inside a callback zeroes `_Count`, ending every active pass (SEM N4);
(e) a callback that yields suspends only its own pass; the next frame's pass drains what is due (D12).

Catch-up policy in numbers (D6): "cap" N=8 fires ≤ 8 per handle per pass then snaps; "all" is `MaxCatchUp = math.huge`, so a
lagging handle fires every grid point, and each repeat counts against the valve (`_BurstSerial == serial`), which is what
"still bounded by the valve" means; "drop" is N=1. The valve never counts a pre-existing entry's first fire, so a 10k one-shot
storm (bench P6) runs to completion.

### 4.3 Stop / remove cascade (D18)

```lua
local function _stop(self, h)                                                -- returns true iff h was live
	local state = h._State
	if state >= FIRED then return false end
	h._State = STOPPED
	if state == PENDING then _heapRemove(self, h) elseif state == CHAINED then self._ChainedCount -= 1 end
	if self._PausedCount > 0 and self._Paused[h] ~= nil then self._Paused[h] = nil; self._PausedCount -= 1 end
	if h._Key then _forgetKey(self, h) end
	local children = h._Chained
	if children then
		h._Chained = false
		for _, child in children do _stop(self, child) end                    -- cascade (SEM A2), recursive through grandchildren
	end
	return true
end

local function _resolve(self, x)                                              -- LP-4; nil for anything that is not ours
	if type(x) == "string" then return self._Keyed[x] end
	if type(x) ~= "table" or getmetatable(x) ~= eventDict then return nil end
	if x._Scheduler ~= self then
		error("TickAPI: handle #" .. x.Id .. " belongs to scheduler '" .. x._Scheduler.Name .. "', not '" .. self.Name .. "'", 3)
	end
	return x
end

function TickScheduler:Stop(x) local h = _resolve(self, x); return h ~= nil and _stop(self, h) end   -- alias remove
function TickScheduler:_Stop(h) _stop(self, h) end                           -- TickEvent:Stop / :Destroy facade (owner is implicit)
```

`TickEvent:Stop()` inside its own callback: one-shot → already Fired → `false` path, nothing touched (SEM S1); recurring → in the
heap (re-keyed) → removed, no further fire this pass even while lagging (SEM S2). `SafeStopClock` = `nil` check + `h:Stop()`.

### 4.4 Pause / resume, reset / adjust / setPeriod / setRemaining (explicit ops measure from `_Now`, D4/D9)

```lua
function TickScheduler:_Pause(h)
	local state = h._State
	if state == PENDING then
		self._Paused[h] = math.max(self._Due[h._HeapIndex] - self._Now, 0); self._PausedCount += 1
		_heapRemove(self, h); h._State = PAUSED
	elseif state == CHAINED and self._Paused[h] == nil then
		self._Paused[h] = h._Period; self._PausedCount += 1                     -- LP-2 flag; honoured by _armChildren
	end
	return h
end

function TickScheduler:_Resume(h)
	local remaining = self._Paused[h]
	if remaining == nil then return h end
	self._Paused[h] = nil; self._PausedCount -= 1
	if h._State == PAUSED then h._State = PENDING; _heapPush(self, h, self._Now + remaining) end   -- Chained: flag cleared only
	return h
end

function TickScheduler:_Reset(h)                                              -- full period from now; SEM R5/R6/R7
	if h._State == PENDING then _heapUpdate(self, h, self._Now + h._Period)
	elseif h._State == PAUSED then self._Paused[h] = h._Period end
	return h
end

function TickScheduler:_Adjust(h, newTotal)                                   -- D9
	newTotal = tonumber(newTotal)
	if type(newTotal) ~= "number" or newTotal ~= newTotal or newTotal == HUGE or newTotal <= 0 then
		error("TickAPI: expected `newTotal` greater than zero", 3)
	end
	local state, period = h._State, h._Period
	if state == PENDING then
		local frac = period > 0 and math.clamp((self._Due[h._HeapIndex] - self._Now) / period, 0, 1) or 1
		_heapUpdate(self, h, self._Now + frac * newTotal)
	elseif state == PAUSED then
		local frac = period > 0 and math.clamp(self._Paused[h] / period, 0, 1) or 1
		self._Paused[h] = frac * newTotal
	elseif state >= FIRED then
		return h
	end
	h._Period = newTotal                                                       -- Chained: delay only
	return h
end
-- _SetPeriod(h, p): validate as creation, h._Period = p (all live states); terminal no-op.
-- _SetRemaining(h, x): x finite >= 0; PENDING -> _heapUpdate(now + x); PAUSED -> _Paused[h] = x; else no-op.
-- _GetRemaining(h): PENDING -> max(due - now, 0); PAUSED -> _Paused[h]; CHAINED -> period; terminal -> 0.
```

Inside its own recurring callback `Reset` re-keys the already-re-armed root to `now + period` (a `_heapUpdate` sift), and `Adjust`
sees `remaining = period` exactly (the in-place re-key), so the ratio rule yields `now + newTotal` — no B-01 loop is possible
because explicit ops never add to `_Base`.

### 4.5 After chains (SEM A-rows)

```lua
function TickScheduler:_After(parent, callback, delay)
	if parent._IsRecur then error("TickAPI: cannot chain a recurring event", 3) end
	local period = _checkArgs(self, callback, delay, false)
	local state = parent._State
	if state == FIRED then                                                     -- "after a finished event" = now (implicit arm: base carry)
		local child = _newEvent(self, callback, period, false, PENDING)
		_heapPush(self, child, _clockOf(self) + period)
		return child
	end
	if state == STOPPED then return _newEvent(self, callback, period, false, STOPPED) end
	local child = _newEvent(self, callback, period, false, CHAINED)
	local list = parent._Chained
	if not list then list = {}; parent._Chained = list end                     -- the only lazy allocation on a handle (cold, 0 live callers)
	list[#list + 1] = child
	self._ChainedCount += 1
	return child
end
```

### 4.6 Keyed timers (D22)

```lua
local function _forgetKey(self, h) self._Keyed[h._Key] = nil; h._Key = false end

function TickScheduler:DelayKeyed(key, callback, delay)                       -- RecurKeyed identical with Recur
	if type(key) ~= "string" then error("TickAPI: key must be a string", 3) end
	local old = self._Keyed[key]
	if old then _forgetKey(self, old); _stop(self, old) end                    -- replace (Q-J6); old._Key cleared first so _stop skips the map
	local h = self:Delay(callback, delay)
	h._Key = key; self._Keyed[key] = h
	return h, old
end
-- Has(key) = _Keyed[key] ~= nil; Get(key) = _Keyed[key]; GetRemaining(x) = h and h:GetRemaining();
-- Complete(x, stop) = h and self:_Complete(h, stop). A keyed one-shot forgets its key when it fires (§4.2) or is stopped.
```

### 4.7 Complete / CompleteNow (D7)

```lua
function TickScheduler:_Complete(h, stop)                                     -- deferred: make it due NOW, fire in due order next pass
	local state = h._State
	if state >= FIRED then return false end
	if stop then h._IsRecur = false end                                        -- fire once then Fired, no re-arm
	if state == PENDING then
		_heapUpdate(self, h, self._Now)                                        -- the caller's now, not _Base: <= now fires next pass (or later this pass)
	elseif state == PAUSED then
		if not h._IsRecur then self._Paused[h] = nil; self._PausedCount -= 1 end   -- recurring keeps its membership: re-parked after the fire
		h._State = PENDING; _heapPush(self, h, self._Now)
	else                                                                       -- CHAINED: leave the parent's list (skipped later), arm now
		self._ChainedCount -= 1
		if self._Paused[h] ~= nil then self._Paused[h] = nil; self._PausedCount -= 1 end
		h._State = PENDING; _heapPush(self, h, self._Now)
	end
	return true
end

function TickScheduler:_CompleteNow(h, stop)                                  -- synchronous: same fire path, base saved/restored
	if h._State >= FIRED or self._Firing == h then return false end           -- SEM F6: never recurse into its own callback
	self:_Complete(h, stop)                                                    -- normalise Paused/Chained into the heap at now
	local savedBase, savedFiring = self._Base, self._Firing
	local d = self._Now
	if h._IsRecur then
		_heapUpdate(self, h, d + h._Period)                                    -- phase restarts from now
		if self._Paused[h] ~= nil then _heapRemove(self, h); h._State = PAUSED end   -- Paused recurring: fires, stays Paused (D7)
	else
		_heapRemove(self, h); h._State = FIRED
		if h._Key then _forgetKey(self, h) end
		if h._Chained then _armChildren(self, h, d) end                        -- children from NOW (SEM A9, forced fire)
	end
	self._Base, self._Firing = d, h
	self._Dispatched += 1
	local ok, message = xpcall(h._Callback, traceback)
	if not ok then _report(self, message, h) end
	self._Base, self._Firing = savedBase, savedFiring
	if self._Depth == 0 and self._Errored then local m = self._Errored; self._Errored = false; error(m, 0) end
	return true
end
```

Deferred `Complete` on a Paused one-shot leaves `_Paused` (it will be Fired); on a Paused recurring it keeps the entry so the loop's
`paused[h] ~= nil` branch re-parks it with `remaining = period` after exactly one fire (D7). `Complete` from inside a callback on an
entry due later this pass: the re-key to `_Now <= now` makes it pop later in the same pass, once (SEM F5).

### 4.8 UpdateTo (D2, LP-3)

```lua
function TickScheduler:UpdateTo(absoluteNow)
	-- same validation as Update
	local scale, target = self._TimeScale, self._Now
	if self._LastAbs == false then
		self._Offset = absoluteNow - self._Now                                 -- first sample anchors; no advance
	elseif scale == 1 then
		target = absoluteNow - self._Offset                                    -- exact, no accumulation
	else
		target = self._Now + (absoluteNow - self._LastAbs) * scale             -- scaled/frozen: accumulate the external delta
	end
	self._LastAbs = absoluteNow
	_advanceTo(self, target)                                                   -- backwards -> clamped + counted inside
end
-- SetTimeScale(s): validate; self._TimeScale = s; if self._LastAbs ~= false then self._Offset = self._LastAbs - self._Now end
```

Freeze = `SetTimeScale(0)`; while frozen `_LastAbs` keeps tracking, so un-freezing re-anchors and nothing bursts. A synced
"fire at WorldTime X" is `Delay(fn, X - absoluteNow)` by the caller (no `DelayAt`, §11).

### 4.9 Bind / Unbind / Destroy / Attach / Detach / Drive / Clear (D16, D17)

```lua
local CLIENT_ONLY = { RenderStepped = true, PreRender = true }

function TickScheduler:Bind(hook)
	if self._IsDead then error(deadMessage, 3) end
	if HOOKS[hook] == nil then error("TickAPI: unknown hook '" .. tostring(hook) .. "'", 3) end
	if self._Hook then error("TickAPI: scheduler '" .. self.Name .. "' is already bound to '" .. self._Hook .. "'; call Unbind() first", 3) end
	self._Hook = hook
	local runService = Env.RunService
	if hook == "Manual" or runService == nil then return end                   -- Lune / tests: recorded, not connected
	if CLIENT_ONLY[hook] and not Env.IsClient then error("TickAPI: hook '" .. hook .. "' is client only", 3) end
	local signal = runService[hook]
	if signal == nil then error("TickAPI: RunService has no signal '" .. hook .. "'", 3) end
	local maxDt, isStepped = self._MaxDt, hook == "Stepped"
	self._Connection = signal:Connect(function(first, second)                  -- the ONLY closure in the driver; one per scheduler
		local dt = isStepped and second or first                               -- RT §1.1: Stepped passes (time, dt)
		if dt ~= dt or dt < 0 then dt = 0 end
		if maxDt and dt > maxDt then dt = maxDt end
		self:Update(dt)
	end)
end
-- Unbind(): if _Connection then Disconnect; _Connection = false end; _Hook = false.  IsBound() -> _Hook or nil.
-- Attach(child): validate isInstanceOf + child ~= self; _Children = _Children or {}; _Children[child] = true.  Detach: nil it.
-- Drive(child, period): local h = self:Recur(function() child.Update(period) end, period); self:Attach(child); return h
-- Clear(): for i = 1, _Count: item[i]._State = STOPPED, _HeapIndex = 0, cascade _Chained; table.clear(_Due/_Item); _Count = 0;
--          for h in _Paused: _stop-like walk; table.clear(_Paused); _PausedCount = 0; table.clear(_Keyed); ChainedCount = 0;
--          for child in _Children: child:Clear().
-- Destroy(force): if _IsDead return; if _IsBuiltIn and force ~= true then error(...) end; Unbind; Clear;
--          for child in _Children: child:Destroy(); if _Registry then _Registry[Name] = nil end; _IsDead = true.
```

`Clear` walks the heap array directly (O(n), no pops) and cascades through `_Chained` lists so Chained children of cleared parents
end Stopped (D18). A `Destroy` from inside a callback returns to a loop whose `_Count` is 0, so the pass ends with no further fires
and no crash (SEM N4); later `Delay/Recur/Update/Bind` raise the dead error; `Stop/GetState` on its handles stay no-ops because every
handle is already Stopped.

## 5. State machine (state × operation → result). "—" = no-op returning the usual value; every cell is total (D8).

| operation | Pending | Paused | Chained | Fired | Stopped |
|---|---|---|---|---|---|
| natural fire (loop) | one-shot → Fired, children armed; recurring → re-key `d+P`, stays Pending (or → Paused when `_Paused[h]` set) | n/a (not in heap) | n/a | n/a | n/a |
| parent fires | n/a | n/a | → Pending at `parentDue + delay`; with flag → Paused (remaining = delay) | n/a | n/a |
| `Stop`/`Destroy`/`Remove`/`SafeStopClock` | → Stopped, heap remove, cascade | → Stopped, leave `_Paused`, cascade | → Stopped (parent skips), cascade | — | — |
| `Reset` | re-key `now+P` | remaining = P | — | — | — |
| `Adjust(t)` | re-key `now+frac·t`, P = t | remaining = frac·t, P = t | delay = t | — | — |
| `SetPeriod(p)` | P = p (future) | P = p | delay = p | — | — |
| `SetRemaining(x)` | re-key `now+x` | remaining = x | — | — | — |
| `Pause` | → Paused (freeze) | — | flag set (stays Chained) | — | — |
| `Resume` | — | → Pending at `now+remaining` | flag cleared | — | — |
| `After(fn, t)` | child Chained | child Chained | grandchild Chained | child Pending at `clockOf()+t` | child Stopped |
| `Complete` (deferred) | re-key `now` → `true` | → Pending at `now` (recurring keeps flag) → `true` | → Pending at `now` → `true` | `false` | `false` |
| `CompleteNow` | fires now (own callback → `false`) | fires now, recurring → Paused after | fires now | `false` | `false` |
| `GetRemaining` | `max(due-now,0)` | frozen | delay | 0 | 0 |
| `IsActive` | true | true | true | false | false |
| `Clear`/scheduler `Destroy` | → Stopped | → Stopped | → Stopped | — | — |
| `GetClocks` counts | yes | yes | no | no | no |

Scheduler states: live → dead (`Destroy`); dead refuses `Update/UpdateTo/Delay/Recur/*Keyed/Bind/Drive/Attach` with the dead error and
keeps `Stop/Complete/Get*/GetStats/Unbind/Destroy` total.

## 6. Registry & hooks (D16)

| item | design |
|---|---|
| boot | `TickAPI.Tick = TickAPI.New{ Name = "Tick", Hook = "Stepped" }`, `Tickh` (Heartbeat), `Tickr` (RenderStepped, only when `Env.IsClient`; `MaxCatchUp = 1`); each gets `_IsBuiltIn = true` after construction. Same constructor as user schedulers (SEM H1). Under Lune all three exist unbound-but-recorded (`IsBound()` returns the hook) and are driven by `Update` in specs |
| `Register/Get/Unregister` | one map `TickAPI._Registered[name]`; `New` registers when `cfg.Name` is given; duplicate → error, never replace (SEM H2) |
| hook names | `TickAPI.Hooks` frozen: the seven signals + `Manual`; client-only: `RenderStepped`, `PreRender` (RT §1.4; `PreAnimation` exists on both) |
| server/client | `Tickr` nil on the server (117 `Tickh` / 5 `Tickr` live sites unchanged, CS §3); `Bind("RenderStepped")` on the server → prefixed error; `GetAfterNotTouched(_, _, "Tickr")` on the server → `TickAPI: unknown tick type Tickr` |
| one connection per scheduler | `Bind` connects exactly one signal; `Unbind` disconnects; never per timer (RT §3.1: 10k connections = 44 ms frame) |
| dt sanitising | inside the bound handler only: NaN/negative → 0, clamp to `MaxDt` 0.25 (RT §7.2; `MaxDt = false` disables); `Update` itself still errors on bad input (D2) |
| manual `Update` on a bound scheduler | allowed; documented as a double-advance hazard (Q-J11) |
| boot diagnostic | on Roblox only, the registry arms one `Tickh.Delay(check, 2)` whose callback warns once if `Tick:GetStats().Updates == 0` while `Tickh` has advanced (Studio Edit-mode trap, RT §1.5) — the scheduler diagnoses itself, no extra connection |
| `GetStats().Hook` + `Env.IsClient/IsServer/IsStudio` | the "which hooks are connected in which context" record RT §7.11 asks for |
| memory category | none (Q-J10) |
| destroying built-ins | `Destroy(true)` only (Q-J12); the registry entry is removed by the scheduler itself |

## 7. Compatibility layer + accepted deviations (for MIGRATION.md)

Preserved verbatim (D19, CS §3): `TickAPI.Tick/.Tickh/.Tickr` with dot-called `.delay(fn, t)`/`.recur(fn, t)` returning table
handles; `.update(dt)`; `.remove(h)`; `.getClocks()`; `TickAPI.SafeStopClock(h) -> nil`; `TickAPI.GetAfterNotTouched(t, fn, "Tickh")`
with `:Touch()/:Destroy()`; handle `:stop()/:reset()/:adjust(n)/:after(fn, t)`; `tonumber` coercion; `delay(fn, 0)` legal; stop from
inside any callback; stop on a fired/stopped handle silent; handles stay tables (`type(h) == "table"` discriminator at
`EntityActionClass.luau:88`); a Strike-wrapper handle stopped through the main `SafeStopClock` still stops (owner-agnostic `h:stop()`).
The four remaining wrapper copies point their `require` at the one module; the RoBase plugin copy is out of scope (Q-J13).

| # | deviation | who notices (CS §3) |
|---|---|---|
| M1 | equal-due order is creation order (FIFO), not newest-first | nobody found; `DungeonCreator.luau:167-179`, `xray.luau:63-87` are order-independent |
| M2 | a nested past-due timer fires later in the SAME update, never synchronously inside `delay()` | `CameraClass.luau:312-322` (`isShaking=false` lands one dispatch later; harmless) |
| M3 | a timer created inside a RECURRING callback is measured from the firing due, not the next due (legacy one-period-late quirk, L-01/B-03) | ≤ 26 files that `recur` and `delay` on one scheduler; corrected (Q-J1) |
| M4 | `Tick:remove(h)` (colon) now actually removes | `PrimaryCardControler.luau:124,141` start cancelling hover-card timers (bug fix) |
| M5 | NaN/±inf delays and `recur(fn, 0)` error at creation; `adjust(≤0/NaN)` errors | `CharacterSheet_Animation.luau:158`, `UpdateAction_ActionServerHitScan.luau:459` error on a zero speed instead of poisoning the clock |
| M6 | terminal handles are total no-ops (no F3 key leak; `reset` after fire does nothing) | 68 `SafeStopClock` sites stop leaking |
| M7 | a parent whose callback errors still arms its `after` children; the error goes to `OnError` | no live `:after` callers |
| M8 | recurring catch-up default "cap 8" (Tickr cap 1): after a > 8-period hitch the remainder is dropped, phase kept | `AbilityClass_Utility.luau:287` (0.01 s refresher), the 1/24 and 1/30 flipbooks — fewer callbacks after a hitch, same cadence |
| M9 | `getClocks()` returns a real count (was always 0 on the bound table) | 0 callers |
| M10 | every error message carries the `TickAPI: ` prefix; handle dot-calls raise a descriptive error instead of index-nil | nobody pcall-matches these |
| M11 | `remove(non-handle)` returns `false`; `remove(number)` no longer removes by index | `Tick.remove(7)` was a raw error |
| M12 | `after()` on a Fired parent arms the child now; on a Stopped parent returns a Stopped child (never a silent never-fires child) | 0 callers |
| M13 | `AfterNotTouched` Id is an integer, class name `TickAfterNotTouched`, `Touch()` after the clock fired self-destroys | `TowerOfTest.luau:283` only |
| M14 | `ForceEventComplete` (SyncedTimer successor) fires in the NEXT update in due order for any heap position (S-01 fixed) | the five ST callers, when migrated (Q-J14) |
| M15 | one bound `Update` per scheduler runs at most `MaxDt` = 0.25 s of clock per frame | timers ride out a hitch instead of bursting |

## 8. Decisions on the open questions

| Q | pick | one-line rationale |
|---|---|---|
| Q-J1 | corrected timing (M3), list the ≤ 26 files | L-01 is a visible bug (nested delay waits period + delay); bug-compat would need a second base variable (violates LP-7) |
| Q-J2 | `Complete()` deferred, `CompleteNow()` explicit | five live ST callers run their own cleanup right after the call (CS §4); deferred cannot re-enter them |
| Q-J3 | reject `+inf` | a never-firing one-shot only pins memory; `Pause()` is the sane "hold indefinitely" |
| Q-J4 | `Tickr` nil on the server + prefixed error from `GetAfterNotTouched` | 0 server references (CS §1e); a fallback would silently give render-timing code a 60 Hz clock |
| Q-J5 | `Remove(non-handle)` → `false`; cross-scheduler → error | nil is the normal "no clock" value (68 sites); a foreign handle is always a wiring bug |
| Q-J6 | replace, old handle returned second | S-09 showed nil-return is the worst option; replace matches "re-apply status" intent |
| Q-J7 | PascalCase only + frozen legacy aliases | one canonical spelling per member; aliases are a fixed 9-name table |
| Q-J8 | 8 / 1000 / Tickr cap 1 | 8 covers the live 0.01 s refresher (~2 fires/frame) and flipbooks; cosmetic Tickr timers never burst |
| Q-J9 | all four spellings → one `initialize` | a 4-line `static.new` override is cheaper than a migration note for Jake's own example |
| Q-J10 | no memory category, no flag | `debug.setmemorycategory` tags callbacks too; nothing profiles by it today; two lines if ever wanted |
| Q-J11 | allowed, documented | needed for tests/catch-up; a check costs every frame |
| Q-J12 | built-ins need `Destroy(true)` | 300+ sites depend on them existing |
| Q-J13 | RoBase plugin copy out of scope; the two caller bugs listed in MIGRATION.md, not fixed here | M4 fixes one by construction; `DashStacks.luau:22` is SyncedTimer code |
| Q-J14 | designed for it (`UpdateTo` + keyed + `Complete`), migration later | zero cost to the core; the five ST verbs map 1:1 |
| Q-J15 | yes, vendor the one-line-patched live file (test-only) | already in `build/vendor/`, hashed; matches the vault "from HeroicSouls" rule |

## 9. Test plan (`build/tests/spec/<area>/<name>_spec.luau`; runner shape per W/CLAUDE.md)

Shared helper `build/tests/spec/_helpers/oracle.luau` (no `_spec` suffix, so the runner skips it): `checkHeap(s)` asserts the heap
property `(due, Id)` for every parent/child pair, `s._Item[h._HeapIndex] == h` for all i, `#_Due == #_Item == _Count`, every handle in
the heap is Pending, every Paused handle has a `_Paused` entry, `_PausedCount == count(_Paused)`, and `_ChainedCount` equals the
number of Chained handles reachable through `_Chained` lists. `withOracle(s)` wraps every public scheduler and handle method so
`checkHeap` runs after each call (used by every spec below unless marked "raw").

| file | tests (named) |
|---|---|
| `heap/heap_spec` (raw + oracle) | `push then drain is sorted by (due, Id)`; `20000 random push/pop/remove/updateKey keep the invariant every 97 ops` (ALG F-ALG-14); `remove of the last element`; `remove of a middle element sifts the right way`; `updateKey decrease and increase`; `ownership check refuses a foreign handle`; `clear resets every _HeapIndex` |
| `core/inputs_spec` | `delay 0 fires on the next update` (SEM I1); `recur 0 errors with the legacy message` (I2); `negative delay errors` (I3); `NaN and inf delay error` (I4/I5, Q-J3); `non-number reports the original type` (I6/L-17); `numeric string is coerced` (I7); `callable table accepted, nil fn errors first` (I8); `update(0) flushes due` (I9); `update(-1), update(NaN), update(nil), update(inf) error before touching state` (I10/I11/I13, B-05); `dead scheduler refuses delay/recur/update` |
| `core/dispatch_spec` | `only the due prefix is examined`; `one-shot is Fired before its callback` (S1); `recurring is re-keyed before its callback`; `equal dues fire in creation order` (C4); `re-armed recurring keeps its Id rank` (D23); `nested past-due one-shot fires later in the same update` (C2/P14); `nested delay(0) fires in the same update` (C3/P18); `timer created in a one-shot callback carries the base` (C1); `timer created in a recurring callback measures from the firing due, not the next` (L-01/B-03 pinned as the M3 deviation); `cross-scheduler creation uses the other scheduler's now` (N5); `Delay(3*dt) may land one update late is documented, not fudged` (L-14) |
| `core/reentry_spec` | `stop self inside own recurring callback while lagging fires once` (S2/L1 probe); `stop a co-due sibling from a callback: never fires, no double advance` (S3/legacy_probe2); `stop then reset in the same callback does not resurrect` (S4); `nested Update from a callback: outer carry restored, no double dispatch` (B-04 §2); `nested Update under "error" policy keeps the outer raise` (B-04 §1); `recurring callback calling Update(1) does not recurse on itself`; `yielding callback simulated with coroutines: next pass drains, no entry twice, Reentries == 1, warned once` (L-05 exp6b); `Destroy from inside a callback ends the pass` (N4); `Clear from inside a callback: later same-frame handles do not fire`; `callback error under warn continues the pass` (E1); `"error" policy re-raises the first message after the pass` (E2); `throwing OnError function is shielded` (E3); `error inside a chained child leaves siblings alone` (E4) |
| `core/catchup_spec` | `cap 8: 5 s hitch on a 0.1 s recur fires 8 then snaps to the grid` (D6); `phase is preserved after a snap`; `all: fires every grid point`; `drop: fires once per update`; `per-handle SetCatchUp overrides the scheduler`; `Dropped counts the skipped grid points`; `period below float resolution stops the handle with a report`; `valve: zero-delay self-rescheduling one-shot stops at 1000 and resumes next update` (B-02); `valve counts repeats under "all"`; `valve never trips on a 10k pre-existing one-shot storm`; `valve warns once via OnError` |
| `handle/states_spec` | `every public method is a no-op on Fired and Stopped` (S4/S5); `pause on Paused, resume on Pending are no-ops, never a raw transition error` (R8/RF-006); `pause freezes remaining, resume arms from now` (R8); `paused recurring accumulates no missed fires`; `pause while Chained then parent fires → Paused with remaining = delay` (A8); `resume while Chained clears the flag`; `GetState inside own callback reads Fired`; `GetRemaining per state` (R9, B-14); `IsActive per state`; `handle dot-call raises the colon message` (S9/B-18); `Destroy alias equals stop` (S10) |
| `handle/retime_spec` | `reset one-shot = full period from now, even from another callback` (R5/P4); `reset recurring restarts the phase from now` (R6); `reset inside own recurring callback replaces d+period` (R7); `adjust ratio on a one-shot` (R1/L5); `adjust on a period-0 one-shot uses the whole newTotal` (R3/D9); `adjust on Paused scales remaining`; `adjust on Chained sets the delay`; `adjust rejects 0, negative, NaN, inf, nil` (R2); `adjust inside own recurring callback while lagging fires the right count` (B-01 §4-6); `SetPeriod affects the next arm only` (R4); `SetRemaining leaves the period` (S-12) |
| `handle/chains_spec` | `child stopped before parent fires never fires` (A1/F8); `parent stop cascades through grandchildren` (A2); `after on recurring errors` (A3); `after on Fired arms now` (A4); `after on Stopped returns a Stopped child` (A5); `two children fire in registration order` (A6/P11); `three-deep chain` (A7); `children arm from the parent's due` (A9); `erroring parent still arms children` (A10, M7); `Complete on a Chained child detaches it: parent later skips it` |
| `handle/complete_spec` | `Complete re-keys to now and fires next update in due order` (F3); `Complete from inside a pass on a later entry fires once this pass` (F5); `Complete on a non-root entry fires next update` (S-01 fixed); `Complete recurring fires once then re-arms from now`; `Complete(true) on recurring ends it`; `Complete on Paused one-shot fires and is Fired`; `Complete on Paused recurring fires once and stays Paused with a full period` (D7); `CompleteNow runs the callback before returning` (F2); `CompleteNow from its own callback returns false` (F6); `CompleteNow on another handle from a callback restores the base`; `Complete on terminal returns false` (F7); `scheduler.Complete(key) resolves the key`; `error inside CompleteNow outside Update re-raises under "error" after the transition` (E5) |
| `scheduler/keyed_spec` | `DelayKeyed registers, Has/Get see it`; `duplicate key replaces and returns the old handle second` (Q-J6); `keyed one-shot forgets its key when it fires`; `Stop(key) stops and forgets`; `GetRemaining(key)`; `non-string key errors`; `Clear forgets every key` |
| `scheduler/lifecycle_spec` | `Bind twice errors; Unbind then Bind works` (H3); `Unbind is idempotent`; `Bind without RunService records the hook only`; `fake RunService: Stepped forwards the 2nd argument` (RT §1.1); `fake handler sanitises NaN/negative dt to 0 and clamps to MaxDt`; `client-only hook on the server errors with the prefix`; `missing signal errors with the prefix` (B-11); `Destroy unbinds, clears, unregisters, marks dead`; `Destroy twice is a no-op`; `built-in Destroy needs force`; `Attach: parent Destroy destroys the child, Clear clears the child`; `Detach stops the cascade`; `Drive advances the child by period per parent fire` (N2); `Stop of a foreign handle errors; h:Stop() on it still works` (S7); `Remove(nil) and Remove(42) return false` (S6); `Tick:remove(h) colon form removes` (S8/L-12); `GetClocks counts Pending + Paused only` (O1); `GetStats fields present and cumulative` (O2); `handle ids ascend from 1 and are never reused` (O3) |
| `scheduler/timemodel_spec` | `Update accumulates dt * TimeScale`; `TimeScale 0 freezes, 2 doubles`; `SetTimeScale rejects NaN/inf/negative`; `UpdateTo first call anchors without firing`; `UpdateTo at scale 1 is exact after 1e6 samples`; `UpdateTo backwards clamps and counts` (D2); `UpdateTo while frozen then unfrozen does not burst` (LP-3); `Now starts at 0` (R11) |
| `registry/registry_spec` | `Tick and Tickh exist under Lune; Tickr is nil without a client RunService`; `Tickr exists with a client fake`; `New with Name registers; duplicate name errors` (H2); `New without Name does not register`; `Register/Get/Unregister round trip`; `SafeStopClock(nil) is nil; SafeStopClock(fired) is nil` (M6); `GetAfterNotTouched unknown type errors` (L-21); `all four constructor spellings build the same shape` (Q-J9); `legacy alias table is complete: update delay recur remove getClocks stop after adjust reset ForceEventComplete` (D15) |
| `registry/afternottouched_spec` | `fires fn after quiet time and destroys itself`; `Touch pushes the deadline`; `Touch from a Tick callback is measured from now` (R5); `fn error still destroys and reaches OnError with the inner traceback` (L-23/B-19); `Touch after the clock cleared self-destroys` (D21); `registered in Storage before arming` (L-25); `Count tracks live objects`; `Destroy is idempotent`; `wrong scheduler type errors` |
| `baseclass/classes_spec` | `TickScheduler, TickEvent, TickAfterNotTouched register exactly once with no CLASSNAME already Exsist warning` (BC-6, captured through Env.SetWarn); `handle isInstanceOf TickEvent and type == "TickEvent"` (D13); `every handle field is non-nil after construction and there are exactly 14` (D13/BC-2); `scheduler isInstanceOf TickScheduler`; `no __index declared on any class` (BC F1) |
| `legacy/parity_spec` | differential harness vs `reference/lune/Tick.luau` (adapters + seeded op generator; excludes nested-in-recur creation, zero nested delays, equal-due order and terminal ops — the listed deviations): `one-shot fire frames match over 500 seeds`; `recurring fire counts match under normal dt`; `nested one-shot base carry matches`; `adjust ratio on one-shots matches`; `reset on one-shot and recurring matches`; `stop inside own one-shot callback matches`; `numeric string coercion matches`; `error messages for bad fn/delay match after the prefix` |
| `legacy/repros_spec` | one pinned test per research repro: `L-02 double-charge`, `L-03 err poisoning`, `L-04 nested recur degrade`, `L-06 lagging self-stop`, `L-07 NaN zombie`, `L-09 reset drift`, `L-11 dead chain`, `L-13 scrambled order`, `L-15 remove(number)`, `L-24 natural-fire leak`, `B-01 adjust loop`, `B-02 zero-delay loop`, `B-06 capped re-arm resurrection`, `B-07 after returns parent`, `B-08 clear strands AfterNotTouched`, `B-14 chained getRemaining`, `RF-001 adjust NaN`, `S-01 forced non-root`, `S-06 lost re-entrant reset`, `F5 recur 0` |
| `docs/apidocs_spec` | `every public member in §2 appears in build/docs/api/API.md`; `MIGRATION.md lists M1–M15` |

Total named tests: 7 + 10 + 11 + 13 + 11 + 11 + 11 + 10 + 13 + 7 + 19 + 8 + 9 + 9 + 5 + 8 + 20 + 2 = **184**.

## 10. Bench plan (`build/bench/bench.luau`, `lune run build/bench/bench.luau`; seeded 20260916, median of 5)

| phase | what runs | number that proves what |
|---|---|---|
| P1 | arm 10k random dues | ns/op ≈ ALG IB (248–254 under Lune); bytes/timer ≈ 576 + heap slots (D13 literal, no rehash) |
| P2 | 200 × `Update(0.005)` with 10k armed, none due | µs/update ≈ 0.02; **`collectgarbage("count")` delta == 0 KB exactly** (the zero-garbage idle check; Lune has `count` only, so 0 is exact and non-zero is a lower bound) |
| P3 | 10k stops shuffled | ns/op flat, no spike (indexed remove vs prior rebuild spikes) |
| P4 | 10k adjusts shuffled | heap size stays 10000 (in-place re-key; F-ALG-1) |
| P5 | 10k resets after `Update(5)` | increase-key path |
| P6 | 10k due in [0,1], one `Update(1.0001)` | ns/dispatch; asserts all fired; valve must NOT trip (`ValveHits == 0`) |
| P7 | 10k recurring, period U(0.5, 1.5), 600 × `Update(1/60)` | µs/update, ns/fire; garbage delta == 0 KB over the run (no per-update tables, D6) |
| P7b | tie-heavy: 10k recurring, equal period, created in one frame | decides `Id`-on-handle vs a third `seq[]` array (ALG §3.1 note) |
| P8 | mixed churn 2k live, per update 50 arms / 20 stops / 10 adjusts / ~50 fires, 600 updates | µs/update vs prior 103–113 |
| P9 | adjust storm 10 rounds of adjust-all + update | max round ms, max single op, heap size after == 10000 |
| P10 | construct 10k handles via `_newEvent` vs `TickEvent:new` | proves the literal path (BC F2: 4–5×) |
| P11 | 10k paused/resumed | cold path sanity; `_Paused` count consistent |

Each phase asserts its invariant (heap size, fired count, garbage) and prints one line; `bench_spec` in the suite re-runs P2 and P6
at N = 1000 as a regression guard (garbage 0, `ValveHits == 0`). In-Studio `--!native` port of P2/P7/P8/P9 is a follow-up (ALG §4.3).

## 11. Risks & mitigations; out of scope

| risk | mitigation |
|---|---|
| Tie compares read `item[c].Id` (hash) on exact-equal dues — the P7b regime | measured in P7b; a third parallel array is a local change inside the seven heap functions |
| `_Paused` lookups on the hot path | gated by `_PausedCount > 0` (one numeric read); only schedulers that pause anything pay a hash miss per recurring fire |
| Full re-entrant dispatch (nested `Update` runs a pass) could surprise a caller expecting the legacy advance-only behaviour | counted + warned once; a same-scheduler `Update` from a callback is still a wiring smell, but yielding callbacks now keep every other timer alive (L-05) |
| Valve interplay with "cap": a mass hitch on > ~140 lagging recurring handles trips the valve and defers the remainder | documented; the deferred entries snap next update; `ValveHits` exposes it; `Valve` is configurable |
| `Clear()` from inside a nested pass while an outer pass is suspended in a yield | outer re-reads `_Count == 0` and exits; the outer's `savedBase/savedFiring` restore is unconditional |
| BaseClass name registry is process-global: a second require of the module in the same VM warns `CLASSNAME [[TickEvent]] already Exsist` | Roblox caches `require`; Lune specs require the module once through the runner; `classes_spec` pins the no-warning boot |
| Vendored BaseClass drifts from live | sha pinned in `reference/SOURCES.md`; a spec diffs the vendored file against `reference/baseclass/BaseClass.luau` minus the one patched line |
| `Adjust` on a period-0 one-shot uses the whole `newTotal` (D9) vs SEM R3's `now` — a settled choice that differs from the prior's intent | pinned by `adjust on a period-0 one-shot uses the whole newTotal`; called out in API.md |
| Dual bound closures (~34 per scheduler) | 4 built-ins + a handful of children; ~40 B each; measured in P1 setup, not per frame |
| Double traceback text when an `AfterNotTouched` fn errors (inner xpcall + scheduler xpcall) | cosmetic; the inner frames are what D21 asks to preserve |

Out of scope, deliberately (safe because no settled decision or live call site needs it): scheduler `Pause/Resume` (LP-3 covers it);
`DelayAt(absolute)` (one subtraction at the call site); payload varargs (D22); handle `tostring` (`Name#Id` is built only in error
strings); `Count()` alias for `GetClocks` (no callers); a scheduler-level `SetCatchUp` (construction-time config + per-handle override
suffice); an "owed counter" catch-up mode D (ALG §3.4, addable later without touching the heap); memory-category tagging (Q-J10);
`ConnectionVault` for the four RunService connections (BC Q3); the RoBase plugin wrapper copies (Q-J13); SyncedTimerClass call-site
migration (Q-J14); `PreAnimation` client-only classification (documented as both-sided per RT §1.4).

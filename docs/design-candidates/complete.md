# Design candidate "complete" — the full-featured TickAPI

Angle: best developer experience + the most complete feature set Jake's asks imply, inside the settled performance
discipline (D1 indexed heap, D24 zero-alloc Update). Every settled decision D1–D24 is taken as given and cited, not
re-argued. `W` = TickRevamp workspace, `P` = prior TickAPIOptimize build, `H` = HeroicSouls mirror. Errors are quoted
exactly; every public member is listed once in §2.

## 1. Object model + file layout (`W/build/src/`)

| Module (path under `build/src/`) | Kind | Responsibility (one line) | Requires |
|---|---|---|---|
| `TickAPI/init.luau` | plain table (registry) | Boots `Tick`/`Tickh`/`Tickr`; `New/Register/Get/Unregister/GetAll/Report`; `SafeStopClock`; `GetAfterNotTouched`; exports classes, `State`, `Hooks`, `Env`; Edit-mode watchdog | Env, Config, TickScheduler, TickEvent, TickAfterNotTouched, Hooks |
| `TickAPI/Env/init.luau` | plain table (seam) | The only module allowed to touch `game`: `IsRoblox`, `BaseClass`, `RunService` (nil under Lune), `Warn`, `IsClient/IsServer/IsEdit`, `Load(name)`; test seams `SetRunService(fake)->restore`, `SetWarn(fn)->restore` | vendor BaseClass (Lune) / `SharedModules.BaseClass` (Roblox) |
| `TickAPI/Config/init.luau` | plain table | `Resolve(cfg?) -> frozen record` with defaults + `TickAPI config:` errors (unknown key first, then type/range) | — |
| `TickAPI/Hooks/init.luau` | plain table | Hook name → RunService member, client-only set, Stepped `(time, dt)` adapter, dt sanitiser + `MaxDt` clamp, `Connect(runService, hook, sched) -> disconnect`; `TickAPI hook:` errors | — |
| `TickAPI/TickScheduler/init.luau` (`--!native`) | **BaseClass root class** `"TickScheduler"` | Parallel `_Due[]/_Item[]` heap as file-local functions (D13), dispatch loop, arm/retime/stop ops, keyed index, NextUpdate queue, Attach/Drive, Bind/Unbind, stats, `Validate()` | Env, Config, Hooks, TickEvent (for `__instanceDict`) |
| `TickAPI/TickEvent/init.luau` | **BaseClass root class** `"TickEvent"` | The handle: colon-only guarded methods that delegate to `self._Owner:_Op(self, …)`; never touches the heap; legacy alias region | Env |
| `TickAPI/TickAfterNotTouched/init.luau` | **BaseClass root class** `"TickAfterNotTouched"` | Touch-to-reset self-destroying clock over an injected scheduler; `Storage` + `Count()` | Env |
| `build/vendor/BaseClass.luau` | test-only vendor | Live HeroicSouls BaseClass with exactly one edit (JsonR require → no-op registrar), sha in `reference/SOURCES.md`; never under `build/src`, never shipped (D14, Q-J15) | — |
| `build/bench/bench.luau`, `build/tests/spec/**`, `build/docs/{API,MIGRATION,GUIDE}.md` | tooling/docs | §9, §10, §7 | — |

Dependency arrows: `init → {Env, Config, Hooks, TickScheduler, TickEvent, TickAfterNotTouched}`; `TickScheduler → {Env, Config,
Hooks, TickEvent}`; `TickEvent → Env`; `TickAfterNotTouched → Env`; `Hooks, Config → nothing`. No cycles: the handle reaches its
scheduler only through the `_Owner` field, the scheduler reaches the registry only through an `_OnDestroyed` callback the registry
installs.

Neighbour loading (W/CLAUDE.md rule, one helper per file):

```lua
-- child modules (TickScheduler/init.luau shown): inside an init.luau "./" is the directory CONTAINING the module directory
-- (build/src/TickAPI), so "./TickEvent" is the sibling. TickAPI/init.luau uses script[name] / "./TickAPI/" .. name.
local function _load(name)
	if typeof(script) == "Instance" then return require(script.Parent[name]) end
	return require("./" .. name)
end
```

Class shape (D13): `TickScheduler`, `TickEvent`, `TickAfterNotTouched` are `BaseClass.class("…")` root classes with no mixins, no
subclass, no declared `__index`, no `__tostring` override (it would corrupt `instance.type`; rich strings come from `Describe()`).
Handles are built by a 14-field constructor literal + `setmetatable(t, TickEvent.__instanceDict)` (§3), never `Class:new`, never
pooled. Scheduler public entry points are per-instance bound closures installed in `initialize` (dot and colon, D15).

## 2. Public API reference

Conventions: **PascalCase canonical**, lowercase names are the frozen legacy alias set (D15). Scheduler members: dot or colon.
Handle members: colon only; a dot call raises `TickEvent: methods take a colon (h:Stop(), not h.Stop())`. Terminal = Fired or
Stopped. "total" = never errors on any state. Error prefixes: `TickAPI:` registry, `TickAPI config:`, `TickAPI hook:`,
`TickScheduler:` scheduler ops, `TickEvent:` handle guard; legacy validation messages are verbatim (D10).

### 2.1 Registry module `TickAPI`

| Member | Signature → return | Semantics / errors | Alias |
|---|---|---|---|
| `VERSION` | `"3.0.0"` | | |
| `Tick`, `Tickh`, `Tickr` | `TickScheduler` | Stepped / Heartbeat / RenderStepped built-ins (Tickr `nil` on the server and under Lune without a client fake, D16/Q-J4); marked built-in (`Destroy` needs `Force`) | — |
| `New(cfg?)` | `TickScheduler` | `Config.Resolve` → `TickScheduler:new(resolved)` → `Bind(cfg.Hook)` unless `"Manual"` → `Register` when `cfg.Name` given. Same path as the built-ins (D16). Errors: config errors; `TickAPI: scheduler name 'X' already registered`; hook errors | `TickScheduler:new(cfg)`, `TickScheduler.new(cfg)` (Q-J9) |
| `Register(sched)` | `sched` | Registers a scheduler built directly; name required + unique; installs `_OnDestroyed` | |
| `Get(name)` | `TickScheduler?` | nil when absent or destroyed | |
| `Unregister(name)` | `TickScheduler?` | Removes without destroying; nil when absent | |
| `GetAll()` | `{TickScheduler}` | Snapshot array, registration order | |
| `Report()` | `string` | Multi-line diagnostics: env flags, per scheduler `Name Hook Bound UpdatesSeen LastDt Clocks Reentries ValveHits` | |
| `SafeStopClock(h)` | `nil` | `nil`/non-handle → nil; else `h:Stop()`; returns nil (19 live `x = SafeStopClock(x)` sites) | — |
| `GetAfterNotTouched(t, fn, tickType?)` | `TickAfterNotTouched` | `tickType` default `"Tickh"`; `TickAPI: unknown tick type 'Tickr' (client only)` on the server, `TickAPI: unknown tick type '<x>'` otherwise | — |
| `State` | `{Pending="Pending", Paused=…, Chained=…, Fired=…, Stopped=…}` | Names as returned by `h:GetState()`; internal ints never leak | |
| `Hooks` | frozen `{ "Heartbeat","Stepped","RenderStepped","PreRender","PreAnimation","PreSimulation","PostSimulation","Manual" }` | | |
| `IsHandle(v)`, `IsScheduler(v)` | `boolean` | metatable identity | |
| `TickScheduler`, `TickEvent`, `TickAfterNotTouched`, `Env`, `Config` | class/module exports | `Env` carries the test seams | |

```lua
local TickAPI = require(ReplicatedStorage.SharedModules.TickAPI)
local h = TickAPI.Tickh.delay(function() print("2 s later") end, 2)           -- legacy shape, unchanged
local fx = TickAPI.New({ Name = "Fx", Hook = "Heartbeat", MaxCatchUp = 2 })    -- a registered custom processor
local sub = TickAPI.New()                                                       -- anonymous, Manual, driven by Update/Drive
```

### 2.2 Constructor / config schema (`Config.Resolve`)

| Key | Type / values | Default | Notes |
|---|---|---|---|
| `Name` | string | nil | nil = anonymous, unregistered; used in every warning |
| `Hook` | one of `TickAPI.Hooks` | `"Manual"` | non-Manual binds at construction; Lune without a fake RunService → hook error |
| `TimeScale` | finite number ≥ 0 | 1 | 0 freezes |
| `CatchUp` | `"cap"` \| `"all"` \| `"drop"` | `"cap"` | D6 |
| `MaxCatchUp` | integer ≥ 1 | 8 | fires per recurring handle per update in `"cap"` mode (Q-J8) |
| `MaxNested` | integer ≥ 1 | 1000 | runaway valve (D5) |
| `MaxDt` | finite > 0 or `false` | 0.25 | hook-driven dt clamp (D2); `false` disables |
| `OnError` | `"warn"` \| `"error"` \| `function(message, handle)` | `"warn"` | D11 |
| `Strict` | boolean | false | true: `Remove(non-handle)` errors instead of `false` (Q-J5) |
| `Now` | finite number | 0 | initial clock; set to the external clock for `UpdateTo` schedulers |
| `MemoryCategory` | string or `false` | `false` | opt-in `debug.setmemorycategory` around Update (Q-J10) |

Errors: `TickAPI config: unknown key 'Foo'`, `TickAPI config: MaxCatchUp must be an integer >= 1, got 0`, etc.

### 2.3 Scheduler class `TickScheduler` (dot or colon)

| Member | Signature → return | Semantics | Errors | Alias |
|---|---|---|---|---|
| `Delay(fn, t, opts?)` | `TickEvent` | one-shot at `clock + t`; `clock` = firing entry's ideal due inside a callback, else now (D4). `opts = {Key=, CatchUp=, MaxCatchUp=}` | legacy validation; `TickScheduler: 'X' is destroyed` | `delay` |
| `Recur(fn, p, opts?)` | `TickEvent` | recurring, first fire at `clock + p` | as above + `expected recur `delay` greater than zero` | `recur` |
| `DelayKeyed(key, fn, t, opts?)` / `RecurKeyed(key, fn, p, opts?)` | `TickEvent, TickEvent?` | keyed arm; duplicate key → old stopped and returned second (D22, Q-J6) | `TickScheduler: expected a key string` | |
| `DelayAt(absDue, fn, opts?)` | `TickEvent` | due on the external axis: `due = absDue - _Offset` (for `UpdateTo` schedulers) | validation | |
| `NextUpdate(fn)` | `TickEvent` | fires at the START of the next Update, before due timers, even when armed inside a callback (contrast `Delay(fn, 0)` inside a callback = later this update) | validation | |
| `Update(dt)` | `nil` | `now += dt * TimeScale`, dispatch (D2/D3); no-op while paused | `TickScheduler: Update(dt) expects a finite number >= 0, got <v>`; destroyed | `update` |
| `UpdateTo(t)` | `nil` | sets now through `_Offset`; backwards → clamp + `Stats.ClampedBackwards` | non-finite `t` | |
| `Now()` | `number` | scheduler clock (scaled) | | |
| `Pause()` / `Resume()` / `IsPaused()` | `self` / `self` / `boolean` | freezes the whole scheduler; `UpdateTo` while paused accumulates into `_Offset` | | |
| `SetTimeScale(s)` / `GetTimeScale()` | `self` / `number` | finite ≥ 0 | `TickScheduler: TimeScale must be a finite number >= 0` | |
| `Bind(hook)` / `Unbind()` / `Rebind(hook)` / `IsBound()` | `self` / `self` / `self` / `string?` | one RunService connection per scheduler (D16); `Unbind` idempotent; `Bind("Manual")` = no-op | `TickAPI hook: unknown hook 'X'`; `… is client only`; `… is not available on this RunService`; `TickAPI hook: 'N' is already bound to 'H'; call Unbind() first`; `TickAPI hook: RunService unavailable; use Update(dt)` | |
| `Attach(child)` / `Detach(child)` / `GetChildren()` | `child` / `boolean` / `{TickScheduler}` | ownership: `Destroy`/`Clear` cascade to attached children (D17) | `TickScheduler: Attach expects a TickScheduler`; `… would create a cycle`; `… is a built-in`; `… already attached to 'P'` | |
| `Drive(child, period, opts?)` | `TickEvent` | `Recur(function() child:Update(period) end, period)`; `opts.Attach = true` also attaches; returns the driving handle | as Recur | |
| `Stop(hOrKey)` | `boolean` | nil → false; string → keyed lookup; handle → stop (cascades to Chained children); non-handle → false (`Strict` → error) | `TickScheduler: handle #<id> belongs to scheduler '<Y>', not '<X>'` | `Remove`, `remove` |
| `Complete(hOrKey, opts?)` / `CompleteNow(hOrKey, opts?)` | `boolean` | see handle rows; `opts.Stop = true` ends a recurring after the fire | foreign-handle error | `ForceEventComplete` = `Complete` |
| `Has(key)` / `Get(key)` / `GetRemaining(key)` / `GetKeys()` | `boolean` / `TickEvent?` / `number?` / `{string}` | unknown key → `false`/`nil`/`nil` (never 0, S-09) | | |
| `Clear()` | `nil` | stops Pending, queued, Paused, Chained; cascades to attached children; fires nothing | | |
| `Destroy(opts?)` | `nil` | Unbind + Clear + destroy attached children + unregister + dead; safe from inside its own update (N4) | `TickScheduler: 'Tick' is a built-in; pass { Force = true } to Destroy it` (Q-J12) | |
| `IsDestroyed()` | `boolean` | | | |
| `GetClocks()` | `number` | Pending (heap + queue) + Paused; not Chained (D20) | | `getClocks`, `Count` |
| `GetStats(into?)` | `table` | counters (§3); `into` reuses a caller table (zero-alloc polling) | | |
| `GetHandles()` | `{TickEvent}` | debug snapshot: Pending by due, then Paused, then Chained (O(n log n), copies) | | |
| `Validate()` | `boolean, string?` | O(n) invariant oracle (heap property, `_Item[h._HeapIndex] == h`, counters, keyed/paused/queue sets) | | |
| `SetOnError(p)` / `GetOnError()`, `SetCatchUp(mode, max?)` / `GetCatchUp()`, `SetMaxDt(x)` / `GetMaxDt()`, `SetStrict(b)` | setters return `self` | runtime versions of the config keys | config errors | |
| `GetConfig()` | frozen table | the resolved record | | |
| `GetDriverInfo()` | `{Hook, IsServer, IsClient, IsEdit, UpdatesSeen, LastDt, ManualUpdates}` | boot diagnostics (RT-11) | | |
| `Describe()` | `string` | `TickScheduler<Tickh Heartbeat now=12.3 pending=40 paused=2>` | | |
| `Name` | public field | | | |

```lua
local s = TickAPI.Tickh
local cd = s:RecurKeyed("cooldown:" .. id, refreshUi, 0.1, { CatchUp = "drop" })   -- one poller per key, replace on re-arm
if s:Has("cooldown:" .. id) then print(s:GetRemaining("cooldown:" .. id)) end
s:NextUpdate(function() model:Destroy() end)              -- "after this frame's dispatch settles"
local child = TickAPI.New({ Name = "Dungeon7" })          -- sub-clock: 10 Hz, owned by Tickh
s:Drive(child, 0.1, { Attach = true })                    -- child:Update(0.1) per fire; destroyed with Tickh
```

### 2.4 Handle class `TickEvent` (colon only; every method total on terminal handles)

| Member | Return | Pending | Paused | Chained | Fired/Stopped | Alias |
|---|---|---|---|---|---|---|
| `Stop()` | nil | remove from heap/queue → Stopped; cascades to Chained children | Stopped | Stopped (parent skips it) | no-op | `stop`, `Destroy` |
| `After(fn, t, opts?)` | child `TickEvent` | child Chained, armed at parent's due + t when the parent fires (registration order) | same | same (grandchild) | Fired → child armed from clock (D8); Stopped → child already Stopped; never returns the parent | `after` |
| `Adjust(newTotal)` | self | `due' = now + frac·newTotal`, `frac = clamp((due−now)/period, 0, 1)` (1 when period = 0); period = newTotal (D9) | `remaining' = frac·newTotal` | period = newTotal | no-op | `adjust` |
| `Reset()` | self | `due' = now + period` (queued → moves to heap) | remaining = period | no-op | no-op | `reset` |
| `SetPeriod(p)` | self | future arms only (D9) | same | delay = p | no-op | |
| `SetRemaining(x)` | self | `due' = now + x`, period untouched | remaining = x | delay = x | no-op | |
| `SetCatchUp(mode, max?)` | self | per-handle override (recurring only; one-shot no-op) | | | no-op | |
| `Pause()` | self | remaining = max(due − now, 0), leaves heap → Paused | no-op | flag `PausedWhileChained` (D8) | no-op | |
| `Resume()` | self | no-op | `due = now + remaining` → Pending | clears the flag | no-op | |
| `Complete(opts?)` | boolean | re-key to now → fires in the next Update in due order; one-shot → Fired; recurring → fires then re-arms from that time | one-shot → Fired; recurring → fires once then returns to Paused with remaining = period (D7) | detached, armed at now | `false` | `ForceEventComplete` |
| `CompleteNow(opts?)` | boolean | same transitions, callback runs inside the call; `false` from inside its own callback; nesting > 8 → OnError + false | | | `false` | |
| `GetRemaining()` | number | `max(due − now, 0)` in scheduler seconds; queued → 0 | frozen value | its delay | 0 | |
| `GetDue()` | number? | absolute due on the scheduler clock | nil | nil | nil | |
| `GetState()` | string | `"Pending"` … | | | | |
| `IsActive()` | boolean | true | true | true | false | |
| `IsRecurring()`, `GetPeriod()`, `GetKey()`, `GetOwner()`, `Describe()` | | `Describe()` → `TickEvent<Tickh#42 recur 0.5s Pending>` | | | | |
| `Id` | public integer | ascending per scheduler, never reused; also the equal-due tie-break (D23) | | | | |

Errors: `Adjust`: `expected `newTotal` greater than zero` (non-finite/≤ 0); `SetPeriod`: `expected `newPeriod` greater than zero`
(recurring) or `… of zero or greater` (one-shot); `SetRemaining`: `expected `remaining` to be a finite number >= 0`; `After`:
`cannot chain a recurring event`; every method: the colon guard.

```lua
local strike = Strike:Delay(hit, frameTime)
strike:Adjust(frameTime / speedMod)          -- keeps the consumed fraction (CharacterSheet_Animation.luau:158 idiom)
local kill = Tickh:Delay(function() self:KillMe() end, lifeTime)
kill:Complete()                              -- fires once next update, then teardown continues safely (Status:KillMe idiom)
local done = Tick:Delay(a, 1):After(b, 0.5):After(c, 0.5)   -- chain; done:Stop() cancels only c
```

### 2.5 `TickAfterNotTouched` (D21)

| Member | Semantics |
|---|---|
| `TickAfterNotTouched:new(scheduler, seconds, fn)` | registers in `Storage[Id]` BEFORE arming; `Clock = scheduler.Delay(function() self:Destroy(); fn() end, seconds)` — Destroy first so the object never leaks and the scheduler's `xpcall` keeps fn's original traceback (L-23, B-19) |
| `Touch()` | `IsDestroying` → no-op; clock no longer active (cleared/stopped elsewhere) → `Destroy()` (B-08); else `Clock:Reset()` (full window from now, R5) |
| `Destroy()` | idempotent: stop clock, unregister |
| `static Count()` | live objects in `Storage` |
| fields `Id` (integer), `IsDestroying`, `Clock` | live `isDestroying` kept as a lowercase alias field |

## 3. Internal data layout

Handle constructor literal — exactly 14 fields + `class` + `type` = 16 → 576 B, sized once (F-ALG-9); no field is ever added later:

| Field | Type | Purpose |
|---|---|---|
| `Fn` | callable | the callback |
| `Period` | number | delay / period (mutable via Adjust/SetPeriod) |
| `IsRecur` | boolean | recurring; `Complete{Stop=true}` flips it to false so the fire path pops it |
| `Id` | integer | public id AND heap tie-break seq (D1/D23) |
| `_Owner` | TickScheduler | owner; ownership check on every scheduler-side op |
| `_State` | integer | `PENDING=1 PAUSED=2 CHAINED=3 FIRED=4 STOPPED=5` |
| `_HeapIndex` | integer | heap slot or 0 (Pending + 0 = in the NextUpdate queue) |
| `_Remaining` | number | frozen remaining while Paused (0 otherwise) |
| `_Chained` | `false` \| array | children registered by `After`, created on first use |
| `_Burst` / `_BurstSerial` | integer | per-update catch-up count without per-update tables (D6) |
| `_CatchUp` | number | `0` = inherit scheduler, `math.huge` = "all", n = cap n |
| `_Key` | `false` \| string | keyed-index membership |
| `_Flags` | integer bitfield | `1` PausedWhileChained, `2` RepauseAfterFire (deferred Complete on a Paused recurring) |

Scheduler fields (all set non-nil in `initialize`; `false` for optionals):

| Group | Fields |
|---|---|
| heap | `_Due {number}`, `_Item {TickEvent}`, `_N` |
| clock | `_Now`, `_Base` (false \| number: firing entry's ideal due), `_Offset`, `_LastAbs` (false \| number), `_TimeScale`, `_Paused` |
| dispatch | `_InUpdate`, `_Serial`, `_NextId`, `_Firing` (false \| handle), `_SyncDepth`, `_Errored` (false \| string), `_Destroyed` |
| policy | `_MaxNested`, `_MaxCatchUp` (number; `math.huge` = all), `_OnError`, `_MaxDt` (number \| false), `_Strict`, `_MemoryCategory` |
| side indexes (cold) | `_Keyed {[string]: handle}`, `_PausedSet {[handle]: true}`, `_NextA/_NextB` (double-buffered arrays), `_NextCount`, `_Children {TickScheduler}`, `_Parent` (false \| sched) |
| counters (O(1) maintained) | `_Live` (Pending incl. queued), `_PausedCount`, `_ChainedCount`, `_RecurCount`, `_KeyedCount` |
| stats | `_Dispatched`, `_DispatchedTotal`, `_Reentries`, `_Dropped`, `_ValveHits`, `_ClampedBackwards`, `_ClampedDt`, `_Errors`, `_UpdatesSeen`, `_LastDt`, `_ManualUpdates`, `_FromHook`, `_WarnedReentry`, `_WarnedValve` |
| binding | `Name`, `_Hook` (false \| string), `_Disconnect` (false \| fn), `_IsBuiltin`, `_OnDestroyed` (false \| fn), `_Config` |

Invariants (checked by `Validate()`): heap property on `(_Due, Id)`; `_Item[h._HeapIndex] == h` for every slot; `_N` = number of
Pending handles with `_HeapIndex > 0`; `_Live == _N + _NextCount(live entries)`; every Paused handle is in `_PausedSet` and vice
versa; every `_Keyed[k]` has `_Key == k` and is non-terminal; no NaN in `_Due`; `_Base == false` outside Update.

`GetStats()` keys: `Name Hook Now TimeScale IsPaused Pending Queued Paused Chained Recurring Keyed HeapSize Clocks Dispatched
DispatchedTotal Reentries Dropped ValveHits ClampedBackwards ClampedDt Errors UpdatesSeen LastDt ManualUpdates Children Destroyed`.

## 4. Algorithms

Heap primitives `siftUp / siftDown / heapPush / heapPop / heapRemove / heapUpdate / heapClear` are `W/research/scheduler-algorithms.md`
§3.2 verbatim with `_hi → _HeapIndex`, `_seq → Id`, arrays `_Due/_Item`; hole-move sifts, ownership check `_Item[i] == h` (D1).
`_clockOf(self) = self._Base or self._Now` (`_Base` is `false` at top level; a base of 0 is truthy and carries).

### 4.1 Validation, construction, arm

```lua
local function _validate(fn, seconds, isRecur)                -- legacy messages verbatim, ORIGINAL type reported (D10)
	if not _isCallable(fn) then error("expected `fn` to be callable", 3) end
	local n = tonumber(seconds)
	if type(n) ~= "number" then error("expected `delay` to be a number. CurrentType: " .. typeof(seconds), 3) end
	if n ~= n or n == math.huge or n == -math.huge then error("expected `delay` to be a finite number", 3) end
	if n < 0 then error("expected `delay` of zero or greater", 3) end
	if isRecur and n == 0 then error("expected recur `delay` greater than zero", 3) end
	return n
end

local function _newHandle(self, fn, period, isRecur, opts)    -- the ONE allocation per arm (D13)
	local id = self._NextId + 1
	self._NextId = id
	local key, catchUp = false, 0
	if opts ~= nil then key = opts.Key or false; catchUp = _catchUpCode(opts) end
	local h = {
		class = TickEvent, type = "TickEvent",
		Fn = fn, Period = period, IsRecur = isRecur, Id = id,
		_Owner = self, _State = PENDING, _HeapIndex = 0, _Remaining = 0,
		_Chained = false, _Burst = 0, _BurstSerial = 0, _CatchUp = catchUp, _Key = key, _Flags = 0,
	}
	return setmetatable(h, eventDict)
end

local function _arm(self, h, due)                              -- Pending in the heap
	h._State = PENDING; self._Live += 1
	if h.IsRecur then self._RecurCount += 1 end
	heapPush(self, h, due)
end

function TickScheduler:Delay(fn, seconds, opts)                -- Recur identical with isRecur = true
	if self._Destroyed then error("TickScheduler: '" .. self.Name .. "' is destroyed", 2) end
	local h = _newHandle(self, fn, _validate(fn, seconds, false), false, opts)
	if h._Key then _replaceKey(self, h) end                     -- stops the old holder; returns it as 2nd value from *Keyed
	_arm(self, h, _clockOf(self) + h.Period)                    -- implicit arm: base carry (D4)
	return h
end

function TickScheduler:NextUpdate(fn)                          -- Pending with _HeapIndex 0 == queued
	local h = _newHandle(self, fn, _validate(fn, 0, false), false, nil)
	self._Live += 1
	local n = self._NextCount + 1
	self._NextCount = n; self._NextA[n] = h
	return h
end
```

### 4.2 Dispatch loop (`_advanceTo`), catch-up, valve, re-entrancy, OnError

```lua
local function _runCallback(self, h)
	local ok, message = xpcall(h.Fn, debug.traceback)           -- D11; 31 ns
	if ok then return end
	self._Errors += 1
	local policy = self._OnError
	if policy == "warn" then
		Env.Warn("[TickAPI/" .. self.Name .. "] callback error in handle #" .. h.Id .. ": " .. message)
	elseif policy == "error" then
		if not self._Errored then self._Errored = message end     -- first message, re-raised after the pass
	elseif not pcall(policy, message, h) then
		Env.Warn("[TickAPI/" .. self.Name .. "] OnError handler failed for handle #" .. h.Id .. ": " .. message)
	end
end

local function _fireOneShot(self, h, d)                        -- h already out of the heap
	h._State = FIRED
	self._Live -= 1
	local key = h._Key
	if key and self._Keyed[key] == h then self._Keyed[key] = nil; self._KeyedCount -= 1 end
	local children = h._Chained
	if children then                                            -- arm children BEFORE the callback (D3), from d (D4)
		h._Chained = false
		for i = 1, #children do
			local c = children[i]
			if c._State == CHAINED then                         -- a stopped/completed child is never resurrected
				self._ChainedCount -= 1
				if c._Flags % 2 == 1 then                       -- PausedWhileChained (D8)
					c._Flags -= 1; c._State = PAUSED; c._Remaining = c.Period
					self._PausedSet[c] = true; self._PausedCount += 1
				else
					_arm(self, c, d + c.Period)
				end
			end
		end
	end
	self._Base = d; self._Firing = h
	_runCallback(self, h)                                       -- NOTHING scheduling-related runs after this line
end

local function _fireRecurring(self, h, d)                      -- h still in the heap, already re-keyed
	self._Base = d; self._Firing = h
	_runCallback(self, h)
end

local function _fireRepause(self, h, d)                        -- cold: deferred Complete() on a Paused recurring (D7)
	h._Flags -= 2; heapRemove(self, h); h._State = PAUSED; h._Remaining = h.Period
	self._Live -= 1; self._PausedCount += 1; self._PausedSet[h] = true
	_fireRecurring(self, h, d)
end

local function _advanceTo(self, target)
	if self._InUpdate then                                      -- re-entered from a callback / yielding handler (D12)
		self._Reentries += 1
		if target > self._Now then self._Now = target end
		if not self._WarnedReentry then self._WarnedReentry = true; _warn(self, "re-entrant Update; see Stats.Reentries") end
		return
	end
	if target > self._Now then self._Now = target
	elseif target < self._Now then self._ClampedBackwards += 1 end   -- the clock never runs backwards (D2)
	self._InUpdate = true; self._Errored = false
	local serial = self._Serial + 1
	self._Serial = serial
	local dispatched = 0
	local queue, count = self._NextA, self._NextCount           -- 1. NextUpdate queue, drained first; arms made while
	if count > 0 then                                           --    draining land in the swapped-in buffer
		self._NextA, self._NextB, self._NextCount = self._NextB, queue, 0
		for i = 1, count do
			local h = queue[i]
			queue[i] = nil
			if h._State == PENDING and h._HeapIndex == 0 and not self._Destroyed then   -- Reset/Adjust may have moved it
				_fireOneShot(self, h, self._Now)
				dispatched += 1
			end
		end
	end

	local due, item = self._Due, self._Item                     -- 2. due prefix of the heap
	local startId = self._NextId
	local nested, valve, defaultCap = 0, self._MaxNested, self._MaxCatchUp
	while self._N > 0 and not self._Destroyed do                -- Destroy() from a callback ends the pass (N4)
		local now = self._Now                                   -- re-read: a re-entrant call may have advanced it
		local d = due[1]
		if d > now then break end
		local h = item[1]
		if h.Id > startId then                                  -- armed during THIS update and already due (D5)
			nested += 1
			if nested > valve then
				self._ValveHits += 1
				if not self._WarnedValve then self._WarnedValve = true; _warn(self, "runaway valve hit; remainder deferred") end
				break
			end
		end
		if h.IsRecur then
			local period = h.Period
			local burst = 1
			if h._BurstSerial == serial then burst = h._Burst + 1 else h._BurstSerial = serial end
			h._Burst = burst
			local cap = h._CatchUp
			if cap == 0 then cap = defaultCap end
			if burst > cap then                                 -- D6 "cap": snap to the first grid point > now, phase kept
				local m = (now - d) // period + 1
				local nextDue = d + m * period
				if nextDue <= now then nextDue += period end
				if nextDue <= now then                          -- period below float resolution at this clock value
					heapPop(self); h._State = STOPPED; self._Live -= 1; self._RecurCount -= 1
					_warn(self, "recur period below clock resolution; handle stopped")
				else
					due[1] = nextDue; siftDown(due, item, self._N, 1); self._Dropped += m
				end
			elseif h._Flags ~= 0 then
				_fireRepause(self, h, d); dispatched += 1
			else
				due[1] = d + period                             -- re-key IN PLACE before the callback (D3)
				siftDown(due, item, self._N, 1)
				_fireRecurring(self, h, d); dispatched += 1
			end
		else
			heapPop(self)
			_fireOneShot(self, h, d); dispatched += 1
		end
	end

	self._Base = false; self._Firing = false; self._InUpdate = false
	self._Dispatched = dispatched; self._DispatchedTotal += dispatched
	local errored = self._Errored
	if errored then self._Errored = false; error(errored, 0) end   -- policy "error": after the whole pass (D11)
end

function TickScheduler:Update(dt)
	if not (dt >= 0) or dt == math.huge then                    -- NaN fails `>= 0` (2 ns)
		error("TickScheduler: Update(dt) expects a finite number >= 0, got " .. tostring(dt), 2)
	end
	if self._Destroyed then error("TickScheduler: '" .. self.Name .. "' is destroyed", 2) end
	if not self._FromHook then self._ManualUpdates += 1 end; self._FromHook = false
	if self._Paused then return end
	_advanceTo(self, self._Now + dt * self._TimeScale)
end
```

Ordering per update: queue drain → heap due-prefix by `(due, Id)`; timers armed inside a queued callback with `due <= now` fire later
in the same pass (valve-bounded). A self-`Stop()` inside any callback simply wins because nothing scheduling-related runs after it.

### 4.3 Stop cascade, pause/resume, retiming

```lua
local function _stop(self, h)                                   -- precondition: h._Owner == self
	local st = h._State
	if st == FIRED or st == STOPPED then return false end        -- terminal first (D18)
	if st == PENDING then heapRemove(self, h); self._Live -= 1    -- queued handles: heapRemove is false, drain skips them
	elseif st == PAUSED then self._PausedSet[h] = nil; self._PausedCount -= 1
	else self._ChainedCount -= 1 end
	if h.IsRecur then self._RecurCount -= 1 end
	h._State = STOPPED
	local key = h._Key; if key and self._Keyed[key] == h then self._Keyed[key] = nil; self._KeyedCount -= 1 end
	local children = h._Chained
	if children then
		h._Chained = false
		for i = 1, #children do if children[i]._State == CHAINED then _stop(self, children[i]) end end
	end
	return true
end

function TickScheduler:Stop(x)                                  -- Remove/remove alias; SafeStopClock semantics
	if x == nil then return false end
	if type(x) == "string" then x = self._Keyed[x]; if not x then return false end end
	if getmetatable(x) ~= eventDict then
		if self._Strict then error("TickScheduler: expected a TickEvent, got " .. typeof(x), 2) end
		return false
	end
	if x._Owner ~= self then
		error("TickScheduler: handle #" .. x.Id .. " belongs to scheduler '" .. x._Owner.Name .. "', not '" .. self.Name .. "'", 2)
	end
	return _stop(self, x)
end

local function _pause(self, h)
	local st = h._State
	if st == PENDING then
		local i = h._HeapIndex
		h._Remaining = (i == 0) and 0 or math.max(self._Due[i] - self._Now, 0)   -- explicit op: from now (D4)
		heapRemove(self, h); self._Live -= 1
		h._State = PAUSED; self._PausedSet[h] = true; self._PausedCount += 1
	elseif st == CHAINED then h._Flags = h._Flags % 2 == 1 and h._Flags or h._Flags + 1
	end                                                          -- Paused/terminal: no-op
end

local function _resume(self, h)
	local st = h._State
	if st == PAUSED then
		self._PausedSet[h] = nil; self._PausedCount -= 1
		_arm(self, h, self._Now + h._Remaining); if h.IsRecur then self._RecurCount -= 1 end   -- _arm re-counted it
	elseif st == CHAINED and h._Flags % 2 == 1 then h._Flags -= 1 end
end

-- Retiming: all explicit, all from _Now (D9). `_rekey(self, h, due)` = heapUpdate when in the heap, heapPush when queued.
local function _adjust(self, h, newTotal)
	local st, period = h._State, h.Period
	if st == PENDING then
		local frac = 1
		if h._HeapIndex ~= 0 and period > 0 then frac = math.clamp((self._Due[h._HeapIndex] - self._Now) / period, 0, 1) end
		h.Period = newTotal; _rekey(self, h, self._Now + frac * newTotal)
	elseif st == PAUSED then
		local frac = (period > 0) and math.clamp(h._Remaining / period, 0, 1) or 1
		h.Period = newTotal; h._Remaining = frac * newTotal
	elseif st == CHAINED then h.Period = newTotal end
end
-- Reset:        PENDING → _rekey(now + period); PAUSED → _Remaining = period; CHAINED/terminal → no-op.
-- SetRemaining: PENDING → _rekey(now + x);      PAUSED → _Remaining = x;      CHAINED → Period = x; terminal → no-op.
-- SetPeriod:    Period = p on any non-terminal state; never re-keys. Validation as creation.
```

### 4.4 After-chains

```lua
function TickEvent:After(fn, seconds, opts)
	_guard(self)
	if self.IsRecur then error("cannot chain a recurring event", 2) end
	local owner = self._Owner
	local child = _newHandle(owner, fn, _validate(fn, seconds, false), false, opts)
	local st = self._State
	if st == FIRED then _arm(owner, child, _clockOf(owner) + child.Period)   -- "after a finished event" = now / base (D8)
	elseif st == STOPPED then child._State = STOPPED
	else
		child._State = CHAINED; owner._ChainedCount += 1
		local list = self._Chained
		if not list then list = {}; self._Chained = list end
		list[#list + 1] = child                                   -- registration order (D23)
	end
	return child
end
```

### 4.5 Complete / CompleteNow (D7)

```lua
local function _makeDueNow(self, h, stop)                       -- shared: bring h into the heap at now, Pending; false if terminal
	local st = h._State
	if st == FIRED or st == STOPPED or self._Firing == h then return false end   -- own callback: recurring refused (F6)
	if stop and h.IsRecur then h.IsRecur = false; self._RecurCount -= 1 end   -- fires once through the one-shot path
	local now = self._Now
	if st == PENDING then _rekey(self, h, now)
	elseif st == PAUSED then
		self._PausedSet[h] = nil; self._PausedCount -= 1
		if h.IsRecur then h._Flags += 2 end                     -- RepauseAfterFire: stays Paused with a full period
		_arm(self, h, now); if h.IsRecur then self._RecurCount -= 1 end
	else                                                        -- CHAINED: leave the parent's list; parent skips non-Chained
		self._ChainedCount -= 1; _arm(self, h, now); if h.IsRecur then self._RecurCount -= 1 end
	end
	return true
end

function TickScheduler:Complete(x, opts)                        -- deferred (Q-J2): fires inside the NEXT Update in due order
	local h = _resolve(self, x)                                 -- nil/unknown key → nil; foreign → error
	if h == nil then return false end
	return _makeDueNow(self, h, opts and opts.Stop)
end

function TickScheduler:CompleteNow(x, opts)                     -- synchronous, same fire functions
	local h = _resolve(self, x)
	if h == nil or self._Firing == h then return false end
	if self._SyncDepth >= 8 then _report(self, "CompleteNow nesting exceeds 8", h); return false end
	if not _makeDueNow(self, h, opts and opts.Stop) then return false end
	local savedBase, savedFiring = self._Base, self._Firing; self._SyncDepth += 1
	local d = self._Now                                         -- explicit op: measured from now (D4)
	if not h.IsRecur then heapRemove(self, h); _fireOneShot(self, h, d)
	elseif h._Flags >= 2 then _fireRepause(self, h, d)
	else heapUpdate(self, h, d + h.Period); _fireRecurring(self, h, d) end
	self._Base, self._Firing = savedBase, savedFiring; self._SyncDepth -= 1
	if not self._InUpdate and self._Errored then local e = self._Errored; self._Errored = false; error(e, 0) end
	return true
end
```

Exactly-once: `_rekey`/`_arm` leave one heap entry; a Complete on an entry due later this update just moves it earlier. Docs show the
three verbs side by side: `Stop/Remove/h:Destroy` never fire, cascade Stopped; `Complete` fires, children arm; `sched:Destroy` fires nothing.

### 4.6 `UpdateTo` offset math (D2)

```lua
function TickScheduler:UpdateTo(t)
	if type(t) ~= "number" or t ~= t or t == math.huge or t == -math.huge then error("TickScheduler: UpdateTo(t) expects a finite number", 2) end
	local last = self._LastAbs
	if self._Paused then                                        -- paused: the gap moves into the offset, nothing fires on resume
		if last and t > last then self._Offset += t - last end
		self._LastAbs = t; return
	end
	local target
	if self._TimeScale == 1 then target = t - self._Offset      -- exact, no accumulation
	else
		target = self._Now + ((last and t - last or 0) * self._TimeScale)
		self._Offset = t - target                               -- keeps DelayAt consistent under scaling
	end
	self._LastAbs = t
	_advanceTo(self, target)                                    -- backwards → clamp + counted, never an error
end
-- DelayAt(absDue, fn) arms at absDue - _Offset. Construct synced schedulers with { Now = clockNow } so relative Delays armed
-- before the first UpdateTo are not swept by the first jump (documented footgun).
```

### 4.7 Bind / Unbind / Destroy / Attach / Detach / Drive / Clear

```lua
function TickScheduler:Bind(hook)
	if hook == "Manual" then return self end
	if self._Destroyed then error(DESTROYED(self), 2) end
	if self._Hook then error("TickAPI hook: '" .. self.Name .. "' is already bound to '" .. self._Hook .. "'; call Unbind() first", 2) end
	local runService = Env.RunService
	if runService == nil then error("TickAPI hook: RunService unavailable; use Update(dt)", 2) end
	self._Disconnect = Hooks.Connect(runService, hook, self)    -- validates name, client-only, missing signal; one closure per scheduler
	self._Hook = hook
	return self
end
-- Hooks.Connect handler: Stepped → function(_, dt) _drive(sched, dt) end; others → function(dt) … end. _drive: NaN/negative → 0;
-- dt > _MaxDt → clamp + _ClampedDt; _UpdatesSeen += 1; _LastDt = dt; _FromHook = true; sched:Update(dt).
function TickScheduler:Unbind() local d = self._Disconnect; if d then self._Disconnect = false; self._Hook = false; d() end return self end

function TickScheduler:Destroy(opts)
	if self._Destroyed then return end
	if self._IsBuiltin and not (opts and opts.Force) then error("TickScheduler: '" .. self.Name .. "' is a built-in; pass { Force = true } to Destroy it", 2) end
	self._Destroyed = true                                      -- the dispatch loop checks this after every callback (N4)
	self:Unbind(); self:Clear()
	local children = self._Children; self._Children = {}
	for i = 1, #children do children[i]._Parent = false; children[i]:Destroy() end
	if self._Parent then self._Parent:Detach(self) end
	local cb = self._OnDestroyed; if cb then self._OnDestroyed = false; cb(self) end   -- registry unregisters
end

function TickScheduler:Attach(child)
	if getmetatable(child) ~= schedulerDict then error("TickScheduler: Attach expects a TickScheduler", 2) end
	if child._IsBuiltin then error("TickScheduler: '" .. child.Name .. "' is a built-in and cannot be attached", 2) end
	if child._Parent then error("TickScheduler: '" .. child.Name .. "' is already attached to '" .. child._Parent.Name .. "'", 2) end
	local p = self
	while p do if p == child then error("TickScheduler: Attach would create a cycle", 2) end p = p._Parent end
	child._Parent = self; self._Children[#self._Children + 1] = child
	return child
end
function TickScheduler:Drive(child, period, opts)
	if opts and opts.Attach then self:Attach(child) end
	return self:Recur(function() child:Update(period) end, period, opts)   -- a different instance: always safe (D17)
end
-- Clear(): walk _Item[1.._N] (state → Stopped, cascade children, clear keys, _HeapIndex = 0), table.clear both arrays, _N = 0;
-- drain queue buffers the same way; walk _PausedSet; reset counters; then child:Clear() for attached children. Fires nothing.
```

### 4.8 Keyed timers (D22)

`_replaceKey(self, h)`: `local old = self._Keyed[h._Key]; if old then _stop(self, old) end; self._Keyed[h._Key] = h; _KeyedCount += 1`.
`DelayKeyed/RecurKeyed` return `h, old`. Keys leave the index on Stop, on a one-shot fire (inside `_fireOneShot`) and on Clear;
a recurring keyed handle stays until stopped. `Get(key)` never returns a terminal handle. `_resolve(self, x)` used by
`Stop/Complete/CompleteNow`: nil → nil; string → `_Keyed[x]`; handle → ownership check; other → nil or `Strict` error.

## 5. State machine (state × operation → result)

| Operation | Pending (heap) | Pending (queued) | Paused | Chained | Fired | Stopped |
|---|---|---|---|---|---|---|
| natural fire | one-shot → Fired (children armed, key freed); recurring → re-key `d+P`, stays Pending | → Fired at next Update start | — | armed by parent → Pending (or Paused if flagged) | — | — |
| `Stop`/`Remove`/`Destroy` | → Stopped, children → Stopped | → Stopped | → Stopped | → Stopped | no-op | no-op |
| `After(fn,t)` | child Chained | child Chained | child Chained | grandchild Chained | child Pending from clock | child Stopped |
| `Adjust(n)` | re-key `now + frac·n`; period = n | period = n | remaining = frac·n; period = n | period = n | no-op | no-op |
| `Reset()` | re-key `now + P` | move to heap at `now + P` | remaining = P | no-op | no-op | no-op |
| `SetRemaining(x)` | re-key `now + x` | move to heap at `now + x` | remaining = x | delay = x | no-op | no-op |
| `SetPeriod(p)` | period = p | period = p | period = p | delay = p | no-op | no-op |
| `Pause()` | → Paused, remaining = due−now | → Paused, remaining 0 | no-op | flag set | no-op | no-op |
| `Resume()` | no-op | no-op | → Pending at `now + remaining` | flag cleared | no-op | no-op |
| `Complete()` | re-key now → fires next Update | already due | → Pending at now (recurring: Repause flag) | → Pending at now (detached) | false | false |
| `CompleteNow()` | fires inside the call | fires inside the call | fires; recurring returns to Paused | fires | false | false |
| `GetRemaining()` | due − now | 0 | frozen | its delay | 0 | 0 |
| `GetClocks()` counts | yes | yes | yes | no | no | no |

Scheduler states: Live → (Bind/Unbind toggles Bound) → Destroyed (terminal: `Delay/Recur/*Keyed/NextUpdate/Update/UpdateTo/Bind/
Attach/Drive` error; `Stop/Complete/Get*/Clear/Unbind/Destroy` stay no-ops/false; handle queries stay valid).

## 6. Registry & hooks

| Topic | Rule |
|---|---|
| Boot | `TickAPI/init.luau` builds `Tick = New{Name="Tick", Hook=rs and "Stepped" or "Manual"}`, `Tickh` (Heartbeat), `Tickr` (RenderStepped) only when `Env.RunService` exists and `:IsClient()`; each `_IsBuiltin = true`; under Lune all three are Manual (Tickr nil unless a client fake is injected before the first require). `Tickr` config: `MaxCatchUp = 1` (Q-J8) |
| Register/Get/Unregister | name unique → `TickAPI: scheduler name 'X' already registered` (no silent replace, H2); `Get` filters destroyed; `Unregister` returns the scheduler alive; `Destroy` unregisters through `_OnDestroyed` |
| Hook table | `Heartbeat, Stepped(time, dt → dt), RenderStepped*, PreRender*, PreAnimation, PreSimulation, PostSimulation, Manual`; `*` client-only → `TickAPI hook: RenderStepped is client only` on the server; member missing on the RunService (older runtime / fake) → `TickAPI hook: PreRender is not available on this RunService`; unknown → `TickAPI hook: unknown hook 'X'`. `Tickh` stays on Heartbeat (D16) |
| One connection per scheduler | `Hooks.Connect` builds one handler closure per Bind; timers never connect anything (RT-12) |
| dt sanitising | in `_drive` only: NaN/negative → 0, `> MaxDt` (0.25) → clamp + `Stats.ClampedDt`; the core `Update` still rejects bad dt from manual callers (D2) |
| Manual `Update` on a bound scheduler | allowed (Q-J11); counted in `Stats.ManualUpdates` (a `_FromHook` flag set by `_drive`); doc: "double-advance hazard" |
| Watchdog | on Roblox boot: `Tickh:Delay(check, 2)` warns once per scheduler bound to `Stepped/PreSimulation/PostSimulation/PreAnimation` whose `_UpdatesSeen == 0` while Tickh advanced: `[TickAPI/Tick] no updates in 2 s while Heartbeat is alive — Stepped does not fire in Studio Edit mode; use Tickh` (RT-11, §1.5) |
| Diagnostics | `TickAPI.Report()` string; `sched:GetDriverInfo()`; `sched:GetStats()`; `sched:Validate()`; `Describe()` on both classes |
| Server/client | `Tickr == nil` on the server (117 Tickh / 10 Tickr sites guard on nil today); `GetAfterNotTouched(t, fn, "Tickr")` on the server → `TickAPI: unknown tick type 'Tickr' (client only)` |
| Memory category | `MemoryCategory = "TickAPI"` config opt-in wraps `_advanceTo` in `debug.setmemorycategory`/`resetmemorycategory`; default off (Q-J10) |
| Test seams | `Env.SetRunService(fake) -> restore`, `Env.SetWarn(fn) -> restore`; a fake exposes `IsServer/IsClient/IsStudio/IsEdit` and signal tables with `Connect` returning `{Disconnect}` plus a `Fire(...)` helper |

## 7. Compatibility layer + accepted deviations (→ `build/docs/MIGRATION.md`)

Preserved verbatim (D19; counts from `callsites.md`): `TickAPI.Tick/.Tickh/.Tickr` with dot-called `.delay(fn, t)` / `.recur(fn, t)`
(206 calls) returning truthy table handles (P9 discriminates `type(x) == "table"`); `.update(dt)`, `.remove(h)`, `.getClocks()`;
`TickAPI.SafeStopClock(h) -> nil` (68 + 19 reassign sites); `TickAPI.GetAfterNotTouched(t, fn, "Tickh")` with `:Touch()/:Destroy()`;
handle `:stop()` (12) / `:reset()` (9, incl. 2 recurring = full period from now) / `:adjust(n)` (2, ratio-preserving, no-op after
fire) / `:after(fn, t)` (0); `tonumber` coercion of delays; `delay(fn, 0)` legal; stop from inside own callback (21 sites); stop of
other timers from a callback; `TickAPI.Tick:remove(h)` colon form now works.

| # | Deviation | Who notices |
|---|---|---|
| 1 | Equal-due order is creation order (legacy newest-first) | none found (§3 callsites) |
| 2 | A nested past-due timer fires later in the SAME update, never synchronously inside `delay()`; the handle is always returned first | `CameraClass.luau:312-322` (`isShaking=false` one update later) |
| 3 | `TickAPI.Tick:remove(h)` (colon) now actually removes | `PrimaryCardControler.luau:124,141` starts cancelling hover timers (intended behaviour) |
| 4 | NaN/±inf delays, recur period 0, `adjust(≤0/NaN/inf)` are errors; strings still coerce | `HardPointSFXManager.luau:57` nil attribute (errored before too); zero speed in the two adjust sites |
| 5 | Terminal handles: stop/reset/adjust/after/pause are no-ops; no key leak, no resurrection | purely beneficial |
| 6 | A parent whose callback errors still arms its `after` children | 0 live chains |
| 7 | Timers created inside a RECURRING callback measure from the firing due, not the next one (Q-J1) | ≤ 26 files that both `recur` and `delay` (list in MIGRATION) |
| 8 | Recurring catch-up capped at 8 fires per handle per update (legacy unbounded); `Tickr` capped at 1 | `Tickr.recur 0.01` (≤ 8 instead of ~1.6/frame only during hitches), 1/24 & 1/30 flipbooks after hitches |
| 9 | Hook-driven `dt` clamped to 0.25 s per frame | timers "lose" hitch time beyond 0.25 s; disable with `MaxDt = false` |
| 10 | `getClocks()` returns a real count (was always 0) | 0 callers |
| 11 | `after()` on a Fired parent arms from now; on Stopped returns a Stopped child (was a silent dead child) | 0 callers |
| 12 | Multiple `after()` fire in registration order (legacy newest-first) | 0 callers |
| 13 | Float boundary: `Delay(k·dt)` may land one update late (no epsilon) | flipbook-exact timing tests |
| 14 | Callback errors no longer abort the frame nor poison timing; `OnError` policy | only visible as fewer lost frames |
| 15 | `reset()` from another callback is exact from now (legacy array-position dependent, L-11) | AfterNotTouched:Touch |
| 16 | AfterNotTouched: integer Id, `Touch()` after clear self-destroys, fn error still destroys | `TowerOfTest.luau:283` (benign) |
| 17 | Re-entrant `update` from a callback advances the clock and returns (legacy: corrupt pass) | none |
| 18 | `Tickr` still nil on the server; `GetAfterNotTouched(…,"Tickr")` errors with a prefix instead of index-nil | none |

Out of scope, listed in MIGRATION (Q-J13): the RoBase plugin's 42-file wrapper copy; the two live caller bugs (`PrimaryCardControler`
colon remove — fixed as a side effect of #3; `DashStacks.luau:22` call-result-as-fn — surfaces as `expected `fn` to be callable`
once migrated to a validating scheduler); `xray.luau:87` global `TickAPI`.

## 8. Open questions — decisions

| Q | Pick | Rationale (one line) |
|---|---|---|
| Q-J1 | Corrected timing; MIGRATION lists the ≤ 26 candidate files with a grep recipe | Bug-compat knobs multiply test surface; the quirk is invisible today (proportional to period) and wrong (L-01) |
| Q-J2 | `Complete()` deferred, `CompleteNow()` explicit | All five live ForceEventComplete callers proceed with teardown right after the call; deferred never re-enters them (S-14); sync stays one call away |
| Q-J3 | Reject `+inf` | "Never fires until told" is `h = s:Delay(fn, 1); h:Pause()` then `Resume/SetRemaining/Complete` — explicit and inspectable |
| Q-J4 | `Tickr` nil on the server + prefixed error | 117/10 live sites already nil-guard; a silent Heartbeat fallback would hide a wrong-side require |
| Q-J5 | `Remove(non-handle)` → `false`; cross-scheduler → error; `Strict = true` config makes non-handles error | SafeStopClock semantics for the 92 sites; a foreign handle is always a wiring bug |
| Q-J6 | Replace, old handle returned second | Keyed timers exist to make "one poller per key" trivial; returning nil (S-09) or erroring pushes bookkeeping onto every caller |
| Q-J7 | PascalCase only + frozen legacy aliases | One canonical spelling per member; the alias region is the whole compatibility contract |
| Q-J8 | 8 / 1000 / `Tickr` cap 1 | 8 covers the live 0.01 s refresher and 1/24 flipbooks at 60 Hz; cosmetic render timers never burst |
| Q-J9 | `TickAPI.New(cfg)` canonical; `TickScheduler:new` and `TickScheduler.new` (static override shifts args) resolve to it | Jake's `NewTick.new()` spelling works; one path, one validator |
| Q-J10 | Off by default; `MemoryCategory` config opt-in around Update | A per-frame `debug.setmemorycategory` call only earns its cost while profiling |
| Q-J11 | Allowed, counted (`Stats.ManualUpdates`) | Needed for tests, catch-up and deterministic stepping; the counter makes a double-advance visible |
| Q-J12 | `Destroy{ Force = true }` only | 300+ call sites assume the built-ins exist |
| Q-J13 | Out of scope; both bugs + the plugin copy listed | Live game is read-only for this work; #3 fixes the colon site by construction |
| Q-J14 | Design for it (keyed + `UpdateTo` + `DelayAt` + `Now` config); migration later | SyncedTimer's 16 files map 1:1 onto `RecurKeyed/Has/GetRemaining/Complete/Stop`; a `SyncedTimer` adapter is a follow-up |
| Q-J15 | Yes (test-only vendor, hashed, never under `build/src`) | Byte-identical dispatch semantics under Lune; the standalone GitHub core diverges (baseclass F6) |

## 9. Test plan (`W/build/tests/spec/<area>/<name>_spec.luau`; `lune run build/tests/run.luau`)

Support: `build/tests/support/` (not `_spec`): `fakeRunService.luau`; `oracle.luau` (`wrap(s)` proxy asserting `s:Validate()` after
EVERY op); `legacy.luau` (adapters over `W/reference/lune/Tick.luau`); `gen.luau` (seeded ops). Bracketed ids = pinned repros.

| File | Tests (name) |
|---|---|
| `heap/heap_spec` | `push/pop drains 10k random dues in (due, Id) order`; `remove at random index keeps heap property and index map` [F-ALG-14]; `updateKey both directions`; `remove of foreign handle is false and touches nothing`; `heapClear resets every _HeapIndex`; `20k random ops pass Validate every 97 ops` |
| `core/dispatch_spec` | `idle update peeks once and allocates nothing`; `one-shot is Fired before its callback runs` [S1]; `recurring is re-keyed before its callback` [S2]; `equal due fires in creation order` [C4, L-13]; `delay 0 at top level fires next update` [I1]; `delay 0 inside a callback fires later this update` [C3, P18]; `nested past-due never fires synchronously; handle returned first` [L-04]; `nested timer measures from firing due` [C1]; `nested delay inside recur waits exactly delay` [L-01/B-03]; `Delay(3*dt) lands one update late is documented` [L-14/B-20]; `update(0) flushes due` [I9] |
| `core/validation_spec` | `fn must be callable, checked first` [I8]; `numeric string coerces, original type reported` [I6/I7/L-17]; `NaN and inf delays error` [I4/I5/L-07]; `recur 0 errors` [I2/F5]; `negative delay errors` [I3]; `Update rejects NaN, negative, inf, nil` [I10/I11/I13/B-05]; `SetTimeScale rejects NaN/inf` [B-05] |
| `reentry/reentry_spec` | `stop self in own one-shot callback is state-only` [S1/F3]; `stop self in lagging recurring fires once` [S2/L-06]; `stop co-due sibling never fires and nothing advances twice` [S3/L-02 A,B,C]; `replace-timer idiom inside callback` [L-02 C]; `stop then reset in callback does not resurrect` [S4]; `reset own recurring in callback restarts from now` [R7]; `adjust own recurring while lagging does not loop` [B-01]; `pause+resume own recurring while lagging does not loop` [B-01]; `zero-delay self-reschedule hits the valve and warns once` [B-02/C5]; `re-entrant Update from callback advances clock, counts, warns once` [N1/L-16/B-04]; `yielding callback (coroutine-simulated) loses no time and no double fire` [L-05]; `Destroy from inside own update ends the pass` [N4]; `Clear from inside a callback: later same-frame handles do not fire` [P §3.1]; `CompleteNow of a co-due handle fires exactly once` [F5]; `CompleteNow nesting beyond 8 is refused via OnError` |
| `stop/stop_spec` | `double stop is a no-op`; `Remove(nil) false; Remove("x") false; Strict errors` [S6/L-15]; `foreign handle errors with names` [S7]; `h.stop() dot call gives colon message` [S9/B-18]; `Tick:remove(h) colon works` [S8/F4]; `parent stop cascades to chained grandchildren` [A2]; `SafeStopClock nil-tolerant, idempotent, returns nil, on fired handle` [P3] |
| `retime/retime_spec` | `adjust preserves consumed fraction` [R1/L-05 probe]; `adjust on period-0 one-shot uses whole newTotal, no NaN` [R3/RF-001]; `adjust rejects 0, negative, NaN, inf, string` [R2/L-10]; `adjust from another callback measured from now` [R10/P4]; `reset one-shot from another callback is exact 10` [R5/L-11]; `reset recurring re-arms full period from now` [R6]; `SetPeriod affects future arms only` [R4]; `SetRemaining leaves period alone` [S-12]; `pause freezes and resume re-arms from now` [R8]; `paused recurring accumulates no fires`; `pause twice and pause on chained never raise` [RF-006]; `GetRemaining in scheduler seconds under timescale` [R9/B-15] |
| `chain/chain_spec` | `child stopped before parent never fires` [A1/F8]; `after on recurring errors` [A3]; `after on Fired arms from clock, never returns parent` [A4/B-07]; `after on Stopped returns Stopped child` [A5]; `siblings fire in registration order` [A6/L-07]; `3-deep chain` [A7]; `adjust/setPeriod/pause on chained child honoured at arming` [A8]; `children arm from parent due` [A9]; `erroring parent still arms children` [A10/B-13]; `chained child completed early is not re-armed by parent` |
| `complete/complete_spec` | `Complete one-shot fires exactly once next update, returns true`; `Complete recurring fires then re-arms from that time`; `Complete{Stop=true} ends a recurring after one fire`; `Complete on Paused recurring fires and stays Paused with full period` [F4]; `Complete on Chained detaches and arms at now` [F3]; `Complete terminal returns false, nil returns false` [F7/F8]; `Complete from own callback returns false` [F6/S-14]; `Complete then Stop before update never fires` [S-14]; `Complete on non-root entry fires next update` [S-01/F-ALG-4]; `CompleteNow runs inside the call with error policy` [E5]; `ForceEventComplete alias` |
| `catchup/catchup_spec` | `cap 8 drops remainder and keeps phase` [D6]; `all mode bursts like legacy` [L-15/I12]; `drop mode fires once`; `per-handle override beats scheduler default`; `capped handle stopped in own callback stays stopped` [RF-010/B-06]; `period below resolution stops loudly` |
| `time/time_spec` | `virtual clock accumulates dt*scale`; `timescale 0 freezes but delay 0 still fires` [B-16]; `UpdateTo exact at scale 1`; `UpdateTo backwards clamps and counts`; `UpdateTo while paused accumulates offset`; `DelayAt fires on the external axis`; `Now config presets the clock`; `scheduler Pause/Resume` |
| `nextupdate/nextupdate_spec` | `NextUpdate at top level fires at next update start`; `NextUpdate inside a callback fires next update, not this one`; `NextUpdate inside a NextUpdate callback goes to the following update`; `Stop/Pause on a queued handle`; `Reset on a queued handle moves it to the heap and drains skip it`; `queue counts in GetClocks and Validate` |
| `keyed/keyed_spec` | `DelayKeyed/RecurKeyed register and Has/Get/GetRemaining`; `duplicate key replaces and returns old second` [S-09]; `key freed on one-shot fire, on Stop, on Clear`; `Stop(key)/Complete(key)`; `unknown key gives nil/false never 0`; `GetKeys snapshot` |
| `registry/registry_spec` | `built-ins exist, Tickr nil without client`; `Tickr exists with client fake and has cap 1`; `New with Name registers; duplicate errors` [H2]; `Get/Unregister/GetAll`; `Destroy unregisters`; `built-in Destroy needs Force` [H6]; `New(), TickScheduler:new(), TickScheduler.new() reach one path` [S11]; `Report string mentions every scheduler` |
| `hooks/hooks_spec` | `Stepped passes second arg as dt` [L-18]; `client-only hook refused on server` [H5]; `missing signal is a prefixed error` [B-11]; `unknown hook is a prefixed error`; `Bind twice errors; Unbind idempotent; Rebind`; `dt NaN/negative sanitised to 0, hitch clamped to MaxDt and counted` [RT-2]; `MaxDt=false disables clamp`; `Destroy disconnects` [RF-004]; `manual Update on bound counts ManualUpdates`; `fake injection restores` [B-12]; `watchdog warns once for a dead Stepped scheduler` |
| `children/children_spec` | `Drive advances child by exactly period per fire` [N2]; `Attach/Detach ownership; Destroy cascades` [N3]; `Clear cascades to attached children`; `Attach cycle, builtin, double-attach errors`; `timer on B from A callback measures from B.now` [N5] |
| `errors/errors_spec` | `warn policy continues the pass with traceback` [E1]; `error policy re-raises first message after the pass` [E2/P12]; `function policy receives (message, handle)`; `throwing OnError handler is shielded` [E3]; `sibling children unaffected by an erroring child` [E4]; `Stats.Errors increments` |
| `stats/stats_spec` | `GetClocks = pending+paused (not chained)` [O1]; `GetStats keys and O(1) counters after random ops`; `GetStats(into) reuses the table`; `GetHandles snapshot order`; `Describe strings`; `Id ascending never reused` [O3] |
| `ant/afternottouched_spec` | `registered before arming` [L-25]; `fn error still destroys and keeps traceback` [L-23/B-19]; `natural fire leaks nothing` [L-24]; `Touch after Clear self-destroys` [B-08]; `Count`; `GetAfterNotTouched Tickr on server errors` [L-21]; `Touch from inside another callback is exact` [R5] |
| `baseclass/baseclass_spec` | `requiring every module registers no duplicate class name (captured warn)`; `handles are TickEvent instances with class/type set` [F2]; `every handle field non-nil after construction` [F7/F-ALG-9]; `every scheduler field non-nil after initialize`; `scheduler dot and colon forms both work` [S8]; `no __index or __tostring declared on the classes` [F1] |
| `parity/parity_spec` | `differential: single-level delay/recur timing vs reference/lune/Tick.luau at dt=1/64` (seeded, 2k ops); `one-shot-in-one-shot base carry matches legacy`; `adjust ratio matches legacy`; `catch-up "all" fire counts match legacy` [L-15]; `reference file is the live file minus the RunService line` |
| `docs/docs_spec` | `every public member of §2 appears in build/docs/API.md`; `every deviation of §7 appears in MIGRATION.md`; `API.md states the retention rule at the top` [O4] |
| `alloc/alloc_spec` | `1000 idle updates allocate 0 bytes`; `1000 updates with 50 noop dispatches each allocate 0 bytes`; `one table per Delay` |

Counts: 6 + 11 + 7 + 15 + 7 + 12 + 10 + 11 + 6 + 8 + 6 + 6 + 8 + 11 + 5 + 6 + 6 + 7 + 6 + 5 + 3 + 3 = **165 named tests**.
Every spec wraps its scheduler with the oracle proxy so `Validate()` runs after every operation, and every re-entrancy test asserts
`Validate()` from inside the callback too.

## 10. Bench plan (`W/build/bench/bench.luau`, `lune run build/bench/bench.luau`)

| Phase | Proves |
|---|---|
| P1 arm 10k random dues | ns/op ≤ 1.2× prototype IB (248 ns); bytes/handle == 576 + heap slots (constructor literal sized once) |
| P2 200 idle updates with 10k armed | ≤ 0.03 µs/update; `collectgarbage("count")` delta == 0 exactly (**zero-garbage idle check**, F-ALG-3) |
| P3 10k shuffled stops | flat ns/op, no spike > 0.2 ms, heap size 0 after |
| P4 10k adjusts / P5 10k resets | heap size stays 10k (no orphans, F-ALG-1) |
| P6 10k fire storm | ns/dispatch ≤ 400 (Lune); all fired |
| P7 10k recurring × 600 updates | µs/update ≤ 70; garbage 0 |
| P8 mixed churn 2k live × 600 | ≤ 30 µs/update; garbage == 0 except the 50 handle literals per update |
| P9 adjust storm 10 rounds | max round ≤ 2.5 ms, no rebuild |
| P10 keyed churn (RecurKeyed replace 5k/frame) | keyed index cost ≤ 1.3× P8 |
| P11 tie-heavy recurring (10k same period, same frame) | decides `Id` on handle vs a third `Seq[]` array (algorithms Q7) |
| P12 handle construction: literal vs `Class:new` | literal ≤ 0.3× (baseclass F2) — guards against a future "just use :new" regression |
| P13 NextUpdate 10k/frame | drain cost linear, garbage 0 |
| P14 legacy baseline (`reference/lune/Tick.luau`) P2/P7 | the headline "×" numbers for the report |

Studio follow-up (not Lune): P2/P7/P8/P9 as a command-bar script with `--!native`, `collectgarbage("count")` deltas, Script Profiler
confirms `<native>` on `TickScheduler`.

## 11. Risks & mitigations; out of scope

| Risk | Mitigation |
|---|---|
| NextUpdate queue adds a second Pending representation (`_HeapIndex == 0`); an op forgetting it corrupts counts | every op routes through `_rekey`/`_stop` which handle both; `Validate()` checks queue membership; 6 dedicated tests |
| `_Flags` cold paths (PausedWhileChained, Repause) are rarely exercised | explicit tests per flag; `_Flags ~= 0` branch only in the recurring path (one int compare) |
| Per-instance bound closures make scheduler tables large and hide dict methods | only ~4 built-ins + few children; `baseclass_spec` asserts dict and instance agree |
| `MaxDt` clamp changes wall-time behaviour after hitches | documented deviation #9; `MaxDt = false` per scheduler; `Stats.ClampedDt` visible |
| Deferred `Complete` on a co-due entry inside a pass fires in this pass (moved earlier) | documented; exactly-once guaranteed by single-entry design; test `Complete on non-root entry` |
| BaseClass `type` corrupted by a custom `__tostring` | none declared; `Describe()` instead; test asserts `h.type == "TickEvent"` |
| Lune vendor BaseClass drifts from live | sha in `reference/SOURCES.md`; `baseclass_spec` diffs vendor vs `reference/baseclass/BaseClass.luau` minus the one line |
| Keyed index keeps recurring handles alive forever (by design) | `Stats.Keyed/Recurring`; retention rule at the top of API.md (O4) |
| Q-J1 corrected timing surprises a live site | MIGRATION grep recipe; parity spec pins the new value explicitly |
| 165 tests + oracle after every op make the suite slow | oracle is O(n) on small n (< 200 handles) in all but heap/alloc specs; expected < 5 s |

Out of scope (and why): SyncedTimerClass migration itself (Q-J14: designed for, not performed); the RoBase plugin copy (Q-J13);
an "owed counter" catch-up mode D (algorithms §3.4: post-loop mutation; addable later without touching the heap); ConnectionVault
routing of RunService connections (baseclass Q3: drags HttpService into the Roblox path); payload varargs on callbacks (D22: never
used live); handle pooling (D13: ABA risk); Actors (RT-13); a 4-ary heap or `Seq[]` array until the Studio `--!native` bench (R8).

# BaseClass integration + house style rules for TickRevamp

Research report (wave 1, topic: BaseClass conventions). Written 2026-09-16. All numbers below were
measured on this machine under Lune 0.10.5 (Luau interpreter, no native codegen); treat them as
relative, not absolute Roblox numbers. Scratch experiments: `research/scratch/baseclass-conventions/`
(`bench.luau`, `bench2.luau`, `bench3.luau`, `bench4.luau`, `bench5.luau`, `probe_live.luau`).

Paths: `W` = this workspace, `H` = HeroicSouls-BackUp mirror, `P` = TickAPIOptimize (prior build),
`G` = `C:/Users/Faded/Documents/GitHub/BaseClass` (standalone repo),
`S` = `C:/Users/Faded/Documents/GitHub/LuaCraneStyle/wiki` (style guide).

## 0. Bottom line

- The live BaseClass (`W/reference/baseclass/BaseClass.luau`, byte-identical to
  `H/ReplicatedStorage/SharedModules_[Folder]/BaseClass_[Module]/BaseClass_[Module].luau`) is a
  middleclass fork whose instance dispatch costs exactly what a plain metatable class costs
  (14.3 vs 14.2 ns/call). Field reads on instances are rawget hits (3.4 ns). BaseClass is free on the
  hot path **as long as the class is a root class with no `Stateful`/`Callbacks` mixin and no custom
  `__index`**. A BaseClass *subclass* pays 3.7x per method call (54-58 ns) because `subclass` wraps
  `__instanceDict.__index` in a closure (F1 below).
- Construction is the only real BaseClass tax: `Class:new` = 909-1338 ns per retained handle vs
  222-265 ns for a single constructor table with the same metatable. A free-list recycle that calls
  `:initialize` on a recycled table costs 32 ns. So: handles are BaseClass instances by metatable
  identity, but the scheduler builds them through a constructor table / free-list, not `Class:new`.
- Memory: `class` + `type` fields are free unless they push the field count across 8 or 16 (Luau hash
  part doubles). A 12-field handle is 576 B; 10k handles = 5.8 MB.
- Live BaseClass requires `game.ReplicatedStorage.SharedModules.JsonR` at load (L27) and cannot load
  under Lune even with a stubbed `game` global (Lune's `require` rejects a non-string). The standalone
  `G/src/core/BaseClass.luau` is pure Luau, loads under Lune, and passes its own suite
  (`lune run tests/run.luau` -> `73 passed, 0 failed (8 spec files)`), but the repo is 7/49 tasks in
  (core only; no includes ported). Recommendation: vendor a copy of the **live** file with the one
  JsonR line replaced by a no-op registrar as `build/vendor/BaseClass.luau` (Lune default), resolve
  the live module on Roblox, through one `Env` seam. Rationale and snippet in section 5.
- `ObjectPool` is not usable for handle pooling: 332 ns per new/release round-trip vs 19-32 ns for a
  private free-list, `prewarmPool` errors on a root class and mis-pools on a subclass, capped pools
  return `nil` from `new`, and `releaseToPool` has no double-release guard. Section 6.
- Naming rule for the compatibility surface: canonical members PascalCase; the legacy lowercase
  names (`update/delay/recur/remove/getClocks`, `stop/after/adjust/reset`) are a frozen alias set
  declared in one "LEGACY SURFACE" region; new capabilities get PascalCase only. Section 4.

## 1. Exact BaseClass API semantics (live file, `W/reference/baseclass/BaseClass.luau`)

| Member | Lines | Semantics |
|---|---|---|
| `BaseClass.class(name, super?)` | 264-268 | asserts `name` is a string; `super and super:subclass(name) or _includeMixin(_createClass(name), DefaultMixin)`. Only root classes get `DefaultMixin` applied; subclasses reach the same statics through the static chain. |
| `BaseClass(name, super?)` | 270 | module `__call` -> `BaseClass.class(...)`. `BaseClass.ClassTable` (L272) exposes the module metatable. |
| class table | 93-122 | `{ name, super, static = {}, __instanceDict = dict, __declaredMethods = {}, subclasses = weak-key set }`; `dict.__index = dict` (L98). |
| class metatable | 118-119 | `__index = aClass.static`, `__tostring = _tostring` (returns `self.name`, L90), `__call = _call` (-> `self:new(...)`, L91), `__newindex = _declareInstanceMethod`. |
| `static` metatable | 104-116 | `Class.static.k` falls back to `rawget(__instanceDict, k)` then `super.static[k]`. Hence `Class.Add` resolves to the instance method (verified: `Class.Add == __instanceDict.Add`), which is what makes `local stop = TickEvent.Stop` hoisting work. Statics are NOT copied at subclass time; every read walks the chain. |
| `__newindex` -> `_declareInstanceMethod` | 79-87, 68-77 | any `Class.X = v` or `function Class:X()` records `__declaredMethods[X]` and writes into `__instanceDict`, then recurses into every subclass that has not declared `X` itself. Works after instances exist (verified: late-added method reaches an existing subclass instance). Assigning `nil` un-declares and falls back to `super.__instanceDict[X]`. **Any value**, not just functions, becomes an instance-visible inherited default (read through one `__index` hop, 22.6 ns). |
| `__index` special case | 50-66, 69 | declaring `Class.__index = f` wraps it: the dict is consulted first, then `f(self, name)` or `f[name]`. The wrapper is a closure, so the class's dict `__index` becomes a **function**. |
| `Class:allocate()` | 168-171 | asserts colon call; `setmetatable({ class = self }, self.__instanceDict)`. |
| `Class:new(...)` | 173-179 | asserts colon call; `allocate()`, `instance:initialize(...)`, then `instance.type = tostring(instance)`. `tostring(instance)` -> `__tostring` (L153) -> `tostring(self.class)` -> class `__tostring` -> `name`. Two metamethod hops per construction (187 ns measured). **`.type` is not set until after `initialize` returns**; inside `initialize` use `self.class.name`. |
| `Class:subclass(name)` | 227-243 | `_createClass(name, self)`; copies every parent dict entry through `_propagateInstanceMethod` (including `__index`, which becomes a closure wrapper, F1); declares `subclass.initialize` as a delegation to `self.initialize` resolved at call time; registers in `self.subclasses`; fires `self:subclassed(subclass)` hook (L245). |
| `Class:include(m1, m2, ...)` | 253-257, 125-148 | for each mixin table: every key except `included`/`static` is assigned through the class (`aClass[name] = method`, so it passes `__newindex` and propagates to subclasses); `mixin.static` keys are written onto `Class.static`; then `mixin:included(aClass)` runs. Multi-mixin is the house extension over upstream middleclass. Returns the class (chainable). |
| `instance:isInstanceOf(C)` | 157-164 | `self.class == C or self.class:isSubclassOf(C)`. |
| `Class:isSubclassOf(C)` | 247-251 | strict: walks `super`; a class is not a subclass of itself. |
| `Class:getHierarchy()` | 182-204 | `"BaseClass -> Parent -> Child"` (declares `String` twice, harmless). |
| `Class:setSignature(...)` | 225 | stores `_signature` and calls `RegisterClass` -> `RJson.BaseClassAutoRegister` (L32-36). The **only** consumer of the JsonR dependency. TickRevamp never calls it. |
| class-name registry | 44-48, 95 | `AllClassNames[name]` is module-level, i.e. process-global (one per VM); a reuse `warn`s `CLASSNAME [[X]] already Exsist` but still creates the class. Roblox client and server are separate VMs, so a shared-module class registers once per VM. Prefix every TickRevamp class (`TickScheduler`, `TickEvent`, `TickRegistry`, `TickAfterNotTouched`) so nothing collides with `SyncedTimer`, `TimeLine`, `AfterNotTouched` (already taken, `W/reference/live/AfterNotTouchedClass.luau:32`) or future classes. |
| colon-vs-dot | 169, 174, 228, 254 | `Class.new(...)` / `.allocate` / `.subclass` / `.include` are caught by `assert(type(self) == "table")` with the message `Make sure that you are using 'Class:new' instead of 'Class.new'`. Instance methods have **no** guard: `h.stop()` reaches the method with `self = nil` or the first argument. |
| load-time dependency | 27 | `local RJson = require(game.ReplicatedStorage.SharedModules.JsonR)` runs at module load. Under Lune: `attempt to index nil with 'ReplicatedStorage'`; with a stubbed global `game` table: `bad argument #1 to 'require' (string expected, got table)` (probe_live.luau). **Not Lune-runnable as-is.** |

Mixin facts that matter for TickRevamp (reference copies under `W/reference/baseclass/`):

- `Stateful.luau:238-240` replaces `__instanceDict.__index` with a closure (`_getNewInstanceIndex`,
  L51-56) that `rawget`s `__stateStack` and scans it on **every** method lookup (L38-46); `allocate`
  is wrapped to add `__stateStack` (L262-272); `subclass` is wrapped (L249-260). Measured: 71.7 ns
  per call with no state active, 102.9 ns with one state (vs 14.1 plain).
- `Callbacks.luau:260-265` and `:270-277` assign `theClass.allocate` / `theClass.subclass` (not
  `.static.allocate`), so through `__newindex` they declare *instance* methods named `allocate` /
  `subclass` and never replace the statics -- the per-instance metatable path is inert on this
  BaseClass (verified: two instances share `Class.__instanceDict`). `before`/`after` still work
  because L222-227 write the callbackized method straight into `__instanceDict`. Cost with no hooks:
  18.2 ns/call. Do not include it on hot classes anyway.
- `Invoker.luau` is pure (no Roblox refs). `Beholder.luau:63-68` requires
  `game.ReplicatedStorage.SharedModules.BaseClass...` at load -> not Lune-loadable; also a global
  event bus (`_root`), irrelevant to a timer library.
- `ObjectPool.luau` -- see section 6.
- The house templates `H/.../BaseClass_[Module]/Template_[Module]/Template_[Module].luau:12` and
  `Childemplate_[Module].luau:14` and the exemplar `TimeLineClass_[Module].luau:33` declare the class
  as a **global** (`TimeLine = BaseClass.class("TimeLine")`); the style wiki
  (`S/BaseClass-MiddleClass.md:37,57-61`) prescribes `local`. Use `local`.

## 2. Cost model (Lune 0.10.5, best of 3, N = 1e7 unless noted)

Dispatch (`bench.luau`, `bench2.luau`, `bench3.luau`):

| Call shape | ns/op |
|---|---|
| empty loop baseline | 2.4 |
| local function call `addLocal(acc, i)` | 10.6 |
| hoisted method `local add = Class.Add; add(obj, i)` | 12.5 |
| plain table + metatable `obj:Add(i)` | 14.2 |
| **BaseClass root-class instance `obj:Add(i)`** | **14.3** |
| BaseClass + Callbacks (no hooks) | 18.2 |
| method copied onto the instance (`{ Add = f }`) | 26.0 |
| **BaseClass subclass instance (1 level)** | **54.1-57.7** |
| BaseClass sub-subclass (2 levels) | 61.8 |
| subclass after `Sub.__instanceDict.__index = Sub.__instanceDict` (experiment) | 18.1 |
| BaseClass + Stateful, no state active | 71.7 |
| function `__index` of Stateful shape (synthetic) | 81.3 |
| BaseClass + Stateful, one state active | 102.9 |

Field access on a BaseClass instance: `obj._Due` (rawget hit) 3.4 ns, identical to a plain table;
`obj.Missing` (miss -> `__index` hop into the dict) 22.6 ns; `obj.Add` (method lookup without call)
22.6 ns. Consequence: **every field the hot loop reads must exist on the instance** (initialize it
to `false`, never leave it `nil`), and class-level defaults read through `self.X` cost the hop.

Colon-vs-dot guard per method call (`bench4.luau`): none 14.0; `local getmetatable = getmetatable`
then `getmetatable(self) ~= dict` 20.6 (+6.6); `type(self) ~= "table" or self.class ~= Class` 30.1;
`self.class ~= Class` 32.3; `rawget(self, "class") ~= Class` 28.2. The localized-`getmetatable`
guard is the cheapest and gives a clean error; unguarded `h.stop()` errors with
`attempt to index number with '_Due'` or worse, silently runs with `self = <first arg>`.

Construction (`bench.luau` 5 user fields, `bench3.luau` 10 user fields, 1e6 retained in a table;
`bench5.luau` 10 fields, discarded):

| Path | 5 fields, retained | 10 fields, retained | 10 fields, discarded |
|---|---|---|---|
| single constructor table + `setmetatable(t, Class.__instanceDict)` (class + type included) | 222 | 265 | 62 |
| `Class:allocate()` then field writes (no `type`) | 549 | - | - |
| `Class:new(...)` (allocate, initialize, tostring x2, type) | 909 | 1338 | 709 |
| `Class(...)` via `__call` | 965 | - | - |
| `tostring(instance)` alone | 187 | - | - |
| free-list pop -> `h:initialize(...)` (10 fields) -> push | - | - | 32.4 |
| same with `table.clear(h)` first | - | - | 178.7 |

Why `Class:new` is 4-5x: `allocate` creates `{ class = self }` (hash part of 1) and `initialize`
grows it 1 -> 2 -> 4 -> 8 -> 16 with a rehash each step, then two `__tostring` hops. A constructor
table sizes the hash part once. A recycled table already has its hash part, so re-running
`initialize` is ~10 rawsets. `table.clear` is counter-productive here.

Memory (`bench3.luau`, bytes per instance via `collectgarbage("count")`, K = 1e5):
1 field 96 - 2 fields 128 - 3-4 fields 192 - 5-8 fields 320 - 9-16 fields 576 - 17 fields 1088.
A 12-field handle (10 user fields + `class` + `type`) is 576 B either way; 10k handles = 5.8 MB,
100k = 58 MB. `class` + `type` cost 0 B unless they cross a power-of-two boundary (they would if a
handle had exactly 15 or 16 user fields -- keep the handle at <= 14 user fields).

Pooling (`bench2.luau`, steady state, 1e6): `ObjectPool` `Class:new` -> `releaseToPool` 332 ns;
private free-list via a helper 32 ns; inline pop/push 18.7 ns; no pool (fresh `setmetatable`) 40.5 ns.

Where the time actually goes in a scheduler frame: `update` is one method call per scheduler per
frame; the due-prefix loop touches handle **fields** (3.4 ns each) and heap arrays, and calls the
user callback. Handle *methods* (`stop`, `reset`, `adjust`, `Pause`, ...) run at user-call rates
(live: 71 `:stop()` sites, 45 `:reset()`, 31 `:after(`, 9 `:adjust(`), i.e. hundreds per second, not
per frame. BaseClass dispatch is therefore not measurable in the frame budget; construction and
subclassing are the only two things that can be.

## 3. Recommendation: what is a BaseClass instance

| Object | BaseClass? | Why |
|---|---|---|
| `TickScheduler` (one per RunService hook; `TickAPI.Tick = TickScheduler:new(...)`) | **Yes, root class** | 14.3 ns dispatch, called a handful of times per frame; gets `isInstanceOf`, `tostring`, `.type`, mixins later. No `Stateful` (client/server split via a file-level `isClient` local, `S/BaseClass-MiddleClass.md:297-317`), no `Callbacks`, no subclassing for variants (a driver kind is a field, as the prior build's `Variants` did). |
| `TickEvent` (the handle returned by delay/recur/after) | **Yes, root class, but never built with `Class:new` on the hot path** | metatable = `TickEvent.__instanceDict`, `class`/`type` set in a constructor table or by a free-list recycle running `:initialize` (32 ns). Users get real BaseClass instances (`h:isInstanceOf(TickEvent)`, `h.type == "TickEvent"`) at plain-table cost. No subclass per kind (`TickRecurEvent` would cost 3.7x on every `stop`): `_Recur` is a field. |
| `TickAPI` (module-level registry: `Tick`, `Tickh`, `Tickr`, `SafeStopClock`, `GetAfterNotTouched`, `Register(name, signal)`) | **No -- plain module table** | it is a singleton system module (`S/Pure-Lua-Modules.md:199-234`); the live one is a plain table too (`W/reference/live/TickAPI.luau:3`). Class machinery buys nothing. |
| `TickAfterNotTouched` | Yes, root class | cold path; keeps parity with `AfterNotTouchedClass.luau:32` (rename to avoid the registry collision with the live class name). |
| the heap (due-time min-heap) | **No -- plain ADT** | pure arrays (`dueTimes[i]`, `events[i]`, `events[i]._HeapIndex`) with inlined sift loops; `S/Pure-Lua-Modules.md:63-116` ADT-factory shape, zero requires; live `MinHeap.luau:19,35` already keeps `siftup`/`siftdown` as file-local functions over parallel `items`/`priorities` arrays. |
| free-list, per-scheduler `_Events` id map, deferred-removal queue | No -- plain tables owned by the scheduler | fields on the scheduler instance (`self._Heap`, `self._Free`, `self._FreeCount`). |

Handles as BaseClass instances at 10k timers: acceptable. 10k x 576 B = 5.8 MB regardless of
BaseClass; construction 2.7 ms total with a constructor table vs 13.4 ms with `Class:new`
(one-off, both under the interpreter), and 0.3 ms once the free-list is warm.

Never on `TickScheduler` or `TickEvent`: `Stateful`, `Callbacks`, `Beholder`, `ObjectPool`, a declared
`__index`, a subclass. `include` is still fine for a **plain method-table** mixin (it just copies
functions into the dict); e.g. a `TickIntrospection` mixin that adds `GetStats`/`Dump` costs
nothing.

## 4. File-layout + naming template for TickRevamp class modules

Layout order is `S/BaseClass-MiddleClass.md:6-48` (module table -> services -> require groups ->
constants/static -> class -> methods -> return) with the TickRevamp `Env` seam in place of raw
`game.*` requires so the module runs unchanged under Lune (`W/CLAUDE.md:15,26-28`).

```lua
--!native
local TickEventClass = {
	_VERSION = 1.0,
	_DESCRIPTION = "Handle for one scheduled callback owned by a TickScheduler",
	--[[ NOTES
		Returned by TickScheduler:Delay/Recur/After. Never constructed by callers;
		the scheduler recycles handles through its free-list and re-runs
		:initialize on them.

		HOT PATH: the scheduler reads fields directly (self._Due etc). Every
		field is initialized to a non-nil value so reads are rawget hits.
	--]]
}


-- 1. Platform seam (BaseClass, RunService) — the only module allowed to touch `game`.
local Env = require(script and script.Parent.Env or "./Env")

-- 2. Require groups (2-3 per group, blank line between groups).
local BaseClass = Env.BaseClass
local Heap = Env.Load("Heap")


-- 3. Module-level constants (upvalues: fastest access) and localized globals.
local getmetatable = getmetatable
local STATE_PENDING = "Pending"
local STATE_FIRED = "Fired"


-- 4. The class object (prefixed, unique across the whole game).
local TickEvent = BaseClass.class("TickEvent")

local eventDict = TickEvent.__instanceDict


--[[
	Rejects a dot call (h.Stop()) before it can corrupt a foreign table.
	Cost: +6.6 ns per guarded call; put it on user-facing methods only,
	never on scheduler-internal helpers.
]]
local function _assertColonCall(self)
	if getmetatable(self) ~= eventDict then
		error("TickEvent methods take a colon: event:Stop(), not event.Stop()", 3)
	end
end


-- 5. Constructor. Runs on a fresh table from Class:new AND on a recycled table
--    from the scheduler's free-list; therefore it assigns every field.
function TickEvent:initialize(scheduler, callback, period, isRecurring)
	self._Scheduler = scheduler
	self._Callback = callback
	self._Period = period
	self._Recur = isRecurring
	self._State = STATE_PENDING
	self._Due = 0
	self._HeapIndex = 0
	self._Generation = 0
	self._Remaining = false
	self._Next = false
	self.Id = 0
end


-- 6. Public methods: PascalCase, colon, guarded, idempotent on terminal states.
--[[
	Cancels the event; the callback never runs. Safe to call twice, from inside
	the callback, or during update: the scheduler defers the heap removal.
]]
function TickEvent:Stop()
	_assertColonCall(self)
	if self._State == STATE_FIRED then return end

	self._Scheduler:_ReleaseEvent(self)
end


-- 7. Private instance methods: _PascalCase (SyncedTimerClass precedent), used
--    only by the owning scheduler. Prefer file-local _camelCase(self, ...)
--    helpers when nothing outside this file needs them.


--------------------------------------------------------------------------------
-- LEGACY SURFACE — lowercase aliases frozen to the rxi/legacy names. Zero per-call
-- cost: __newindex writes the same function into the dict under both names.
-- New capabilities never get a lowercase twin.
--------------------------------------------------------------------------------
TickEvent.stop = TickEvent.Stop
TickEvent.after = TickEvent.After
TickEvent.adjust = TickEvent.Adjust
TickEvent.reset = TickEvent.Reset


return TickEvent
```

Naming rules (from `S/General-Lua.md:321-335`, `S/Global-Rules.md:6-39`, `S/BaseClass-MiddleClass.md:70-99`):

- Files: `<Name>Class` on Roblox (`TickEventClass`, `TickSchedulerClass`); under the Lune tree the
  module directory (`build/src/TickAPI/TickEvent/init.luau`) carries the name and the outer module
  table is `TickEventClass` (`S/General-Lua.md:355`: the file returns the bare class object).
- Classes, public methods, public fields: PascalCase (`TickEvent`, `h:Pause()`, `h.Id`).
- Locals and parameters: camelCase (`isRecurring`, `dueTime`); no single-letter names, including
  loop indices (`index`, `childIndex`, not `i`); spell out pair names in `pairs` loops.
- File-local helpers: `_camelCase(self, ...)`; helper-of-helper `__camelCase`; hoist broadly used
  helpers to the top under the require area; keep others next to their caller.
- Private instance fields: `_PascalCase` (`self._Due`, `self._HeapIndex`); private instance methods
  `_PascalCase` colon methods (`SyncedTimerClass.luau:156,202,244` precedent: `_GetNextWorldTime`,
  `_UpdateEventTime`, `_EvaluateAndSetNewTime`).
- Booleans: `is`/`has` prefix (`isRecurring`, `self.isPaused` for public, `self._IsPooled` private).
- `--[[ ]]` purpose block before every non-trivial function; tabs; double quotes; 80-col target,
  120 hard; multi-line any call with 3+ arguments; guard clauses first; assign default then override;
  no `and/or` chains beyond two terms; no semicolons.
- Module metadata `_VERSION` / `_DESCRIPTION` (corrected spelling) at the top of the module table.

The lowercase compatibility rule ("codebase practice wins on conflict", `S/Home.md:5`;
`W/CLAUDE.md:36-39`):

- R1. Every canonical member is PascalCase.
- R2. The legacy call surface is a **frozen alias set**, lowercase, declared once in a marked
  LEGACY SURFACE region at the bottom of each class file: scheduler `update`, `delay`, `recur`,
  `remove`, `getClocks` (and `event` if kept); handle `stop`, `after`, `adjust`, `reset`; registry
  `Tick`, `Tickh`, `Tickr`, `SafeStopClock`, `GetAfterNotTouched` (the last two are already
  PascalCase). Live usage that pins these: `.delay(` 176, `.recur(` 116, `:stop()` 71, `:reset(` 45,
  `:after(` 31, `.update(` 14, `:adjust(` 9, `SafeStopClock(` 88, `:remove(` 4, `GetAfterNotTouched(`
  1 (rg over `H`, all `.luau`, archive copies included; `research/scratch/callsites/counts_raw.txt`
  has the canonical per-group breakdown: `TickAPI.Tick.delay` 90, `Tickh.delay` 71, `Tick.recur` 60,
  `Tickh.recur` 47, `Tickr.recur` 7).
- R3. New capabilities are PascalCase only: `Pause`, `Resume`, `GetRemaining`, `SetPeriod`,
  `ForceComplete`, `GetState`, `IsActive`, `SetTimeScale`, `GetTimeScale`, `GetStats`, `Now`, `Clear`,
  `Register`. The prior build spelled these lowercase (`P/build/src/TickAPI/Handle/init.luau:151-201`,
  `Group/init.luau:235-258`); TickRevamp renames them and the migration doc maps both.
- R4. Scheduler entry points must stay **dot-callable** on the instance: every live call is
  `TickAPI.Tick.delay(fn, t)` (bound closures in `W/reference/live/Tick.luau:224-230`), and Jake's own
  example is `TickAPI.Tick.update(dt)`. Install per-instance bound closures in
  `TickScheduler:initialize` (there are only 3-4 schedulers) that accept both `sched.delay(fn, t)` and
  `sched:delay(fn, t)` (first argument `== self` -> shift), the prior build's `bindDual`
  (`P/build/src/TickAPI/Group/init.luau:434`). Handle aliases are plain class-level assignments
  (colon-only, as in the legacy).
- R5. Direct field reads on legacy handles: none in the live game. `rg '\w*[Cc]lock\w*\.(timer|
  delay|recur|fn|parent)\b'` over `H` finds only two `Clock.fn` mentions, both comments in Shadeoid's
  unrelated `Clock` net module (`Shadeoid_[Module]/Net_[Folder]/Clock_[Module]/Clock_[Module].luau:12`,
  `SnapshotReceiver_[Module].luau:33`); `.timer` is never read outside the Tick copies. The handle's
  legacy fields (`parent`, `delay`, `timer`, `fn`, `recur`, `Tick.luau:47-53`) can all become
  `_PascalCase` private fields with accessors.

Colon misuse already live: `TickAPI.Tick:remove(LastTickObject)` at
`H/StarterGui/Menu_[ScreenGui]/.../PrimaryCardControler_[Module].luau:124,141` (+2 archive copies)
routes through the `bound.remove` wrapper as `tick.remove(group, bound, obj)`, so `e = bound`,
`group[bound] = false`, the `ipairs` scan finds nothing, and the clock is **never removed** -- a
silent live no-op (`Tick.luau:117-133,224-230`). R4's dual binding fixes this class of call.

## 5. Lune testability strategy

Facts established:

- Live `BaseClass.luau` does not load under Lune, with or without a stubbed `game` (section 1,
  `probe_live.luau`). `Stateful`, `ObjectPool`, `Invoker`, `Callbacks` reference copies do load
  under Lune (pure Luau); `Beholder` does not.
- `G` (standalone) `lune run tests/run.luau` -> `73 passed, 0 failed (8 spec files)` in ~1 s, two
  expected `[WARN] CLASSNAME [[Bar]] already Exsist` / `[[Restore]]` lines from deliberate duplicate
  cases. `G/src/core/BaseClass.luau` is the entire `src/` (backlog: T1-T7 certified, T8-T49 pending;
  no includes ported; `G/HISTORY.md` last entry 2026-08-07). Its core is a clean-room rewrite of the
  same algorithm: identical `_createIndexWrapper` / `_propagateInstanceMethod` / `subclass` /
  `allocate` / `new` / `include` logic (G L191-251, 369-383, 399-420, 449-458), same
  `CLASSNAME [[X]] already Exsist` message (G L123), plus test seams `setWarn`,
  `getRegisteredClassNames`, `clearRegisteredClassNames`, `setSerializationRegistrar` (G L534-584)
  and Luau type exports. It has the same subclass `__index` wrapper cost (measured on it).
- Lune `require` rejects absolute paths (`require path must start with a valid alias or relative
  path`); from `research/scratch/baseclass-conventions/` the standalone core is
  `require("../../../../../../../GitHub/BaseClass/src/core/BaseClass")` (7 ups).
- Vault `Projects/BaseClass/BaseClass.md:96-98` records a user correction for Shadeoid: "get base
  class and oct from heroic souls not their own githubs" -- vendor from the live game, not from the
  standalone repo.

Options:

| | (a) injected factory + tiny middleclass shim | (b) vendor `G/src/core/BaseClass.luau` | (c) live file vendored with the platform dependency turned into an injection point (vault pattern, `BaseClass.md:29-41`) |
|---|---|---|---|
| fidelity to live dispatch semantics | must be re-implemented and proven | same algorithm, rewritten; already spec-covered | byte-identical except one line |
| effort | ~120 lines + specs | copy one 590-line file | copy one 275-line file + a 6-line patch + a hash in `reference/SOURCES.md` |
| respects "from HeroicSouls, not GitHub" | n/a | no | yes |
| test seams (`setWarn`, registry introspection) | write them | included | add 6 lines if wanted |
| divergence risk over time | shim drifts from live | G evolves (42 tasks pending) | none; re-vendor when live changes |

Recommendation: **(c)**. Vendor the live `BaseClass.luau` to `build/vendor/BaseClass.luau` with
exactly this patch: replace L27 with a no-op registrar and keep everything else byte-identical:

```lua
-- build/vendor/BaseClass.luau L27 (vendored from HeroicSouls BaseClass_[Module].luau, sha in
-- reference/SOURCES.md). The only edit: the JsonR serializer becomes an injectable no-op so the
-- module loads under Lune. Reachable only through Class:setSignature, which TickRevamp never calls.
local RJson = {
	isRegistered = function(_name) return false end,
	BaseClassAutoRegister = function(_class) end,
}
function BaseClass.SetSerializationRegistrar(registrar) RJson = registrar end
```

`build/vendor/` sits outside `build/src/`, so a Rojo map of `build/src` never ships it; on Roblox
the seam resolves the real module. The seam is one child module that is the only place allowed to
touch `game`:

```lua
-- build/src/TickAPI/Env/init.luau
local Env = {}

-- Under Lune `script` is nil, so typeof(script) is "nil"; on Roblox it is an Instance.
Env.IsRoblox = typeof(script) == "Instance"

if Env.IsRoblox then
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local SharedModules = ReplicatedStorage:WaitForChild("SharedModules")

	Env.BaseClass = require(SharedModules.BaseClass)
	Env.RunService = game:GetService("RunService")
else
	-- Inside an init.luau, "./" is the directory that CONTAINS the module directory
	-- (build/src/TickAPI), so "../../vendor/BaseClass" is build/vendor/BaseClass.luau.
	Env.BaseClass = require("../../vendor/BaseClass")
	Env.RunService = nil
end

--[[ Resolves a sibling module of TickAPI by name on either platform. ]]
function Env.Load(name)
	if Env.IsRoblox then
		return require(script.Parent[name])
	end

	return require("./" .. name)
end

--[[ Test seam: swap the class library before any class module loads. ]]
function Env.SetBaseClass(library)
	Env.BaseClass = library
end

return Env
```

Class modules then do `local Env = Env.Load`-style loading as the prior build's `load(name)` helper
did (`P/build/src/TickAPI/Group/init.luau:27-33`), and `local BaseClass = Env.BaseClass`. Fallback if
(c) is vetoed: (b) works today with zero changes and is the second choice; (a) is not worth writing
because (b)/(c) already are the shim.

If a shim were ever written, behavioural parity for TickRevamp's use means: `class(name, super?)`
and `__call`; class metatable with `__index -> static`, `__newindex` that writes into a self-indexing
instance dict and propagates to subclasses; `static` with fallback to the dict then `super.static`;
`allocate` (`{ class = self }` + `setmetatable`), `new` (`initialize` then `type = tostring`);
`include(...)` copying non-`included`/`static` keys through the class, merging `static`, calling
`included`; `subclass` copying the dict and delegating `initialize`; `isInstanceOf`/`isSubclassOf`;
`__tostring` on class and instance returning the name; the process-global name registry with the
exact `CLASSNAME [[X]] already Exsist` warning text.

## 6. Pooling: `ObjectPool` verdict

`W/reference/baseclass/ObjectPool.luau` contracts: include it and the class's `static.new` is
wrapped (L279-305) to `_createPool` (L120-127), dequeue from a per-class ring-buffer `Queue`
(L31-109) and call `instance:reInitialize(...)` (L137) -- `initialize` does **not** run on a
recycled object; on a miss it counts and calls the original `new`. `instance:releaseToPool()`
(L174-190) calls `self:onRelease()` (default warns `"Not over written?"`, L171) then enqueues, or
decrements `count` when `maxPoolSize` is hit. `static.maxPoolSize` / `initialPoolSize` (L19-24);
`Class:getPoolStats()` (L224-239); `Class:prewarmPool(size)` (L202-221).

Measured and read defects that rule it out for handles:

- Cost: 332 ns per `new` -> `releaseToPool` round trip (three method calls, a `Queue` dequeue with
  modulo arithmetic, a vararg `reInitialize`) vs 18.7-32 ns for a private array free-list.
- `prewarmPool` L215 calls `self.super.new(self)`: on a root class `super` is nil ->
  `attempt to index nil with 'new'` (verified). On a subclass it runs the parent's wrapped `new` with
  `theClass` captured as the parent, and `_createPool(self)` finds the parent's `_objectPool` through
  the static chain, so parent and child **share one pool** and prewarm fills it with parent-class
  instances (verified: both report `available 1, total 6`). The vault's "undefined global `class`"
  wording (`Knowledge/BaseClass OOP Conventions.md:43`) describes an older copy; the live copy is
  broken differently but is still broken.
- `_modifySubclassMethod` L310-318 assigns `theClass.subclass` (instance-method declaration, not
  `static.subclass`) -> dead code; subclasses are only "pooled" by inheriting the parent's wrapper.
- A capped pool makes `Class:new` return `nil` after a `warn` (L300-302): a timer API cannot hand
  back `nil` handles (`SafeStopClock` idiom, 88 live sites).
- `releaseToPool` has no already-released guard: a double `release` enqueues the same table twice
  and later hands it to two owners -- exactly the double-remove hazard Jake asked to protect.

Keep a private free-list on the scheduler: `self._Free` array + `self._FreeCount`; acquire = pop or
`setmetatable({ class = TickEvent, type = "TickEvent", ...all fields... }, TickEvent.__instanceDict)`;
release = set `_State = "Free"`, bump `_Generation` (stale heap entries and stale user references
compare generations), clear `_Callback`/`_Next`/`_Scheduler` references to `false`, push. Guard
double release with the state check. Re-arm by running `TickEvent.initialize(h, ...)` on the
recycled table (32 ns); never `table.clear`. Cap the free-list (e.g. 1024) and let excess handles
be collected, so a burst does not pin memory forever. Handles keep the `reInitialize`/`onRelease`
vocabulary only if a later `ObjectPool` integration is wanted; nothing in TickRevamp should call
`ObjectPool`.

## 7. Style rules that press on the hot path, and the reconciliation

| Rule | Where it bites | Reconciliation |
|---|---|---|
| "READABILITY over Performance" (`S/General-Lua.md:3`, `S/Home.md:3`) | inlined sift loops, generation counters, parallel arrays in the heap and `update` | `S/Pure-Lua-Modules.md:237-261` explicitly allows `--!native` and localized globals for a *measured* hot path. Mark each such region with a `--[[ HOT PATH: measured <bench name>, <ns> ]]` block and keep everything outside those regions plain. The live `Tick.luau:1` and `TickAPI.luau:1` already carry `--!native`. |
| Initialization lives entirely in `:initialize`; never a separate constructor (`S/BaseClass-MiddleClass.md:72`) | handle free-list / constructor table | `:initialize` stays the single field list and is what a recycle re-runs; the constructor-table fast path is a file-local `_allocateEvent(scheduler)` in the scheduler, mirrored line-for-line and covered by a spec asserting both paths produce field-identical handles. In-house precedent for wrapping construction: `ObjectPool.luau:279-305` wraps `static.new`. |
| Helpers `_camelCase`, placed near callers, 3+-arg calls multi-line (`S/Global-Rules.md:6-39,128-150`) | sift helpers take 4 arguments (`dueTimes, events, index, count`) | formatting has zero runtime cost; a local function call is 10.6 ns vs 14.3 for a method, so file-local helpers are the *faster* option as well as the prescribed one. Inline only the innermost compare/swap loop. |
| No single-letter names | `i`, `j`, `e`, `dt` everywhere in rxi tick | rename (`index`, `parentIndex`, `event`, `deltaTime`); locals are registers, no cost. |
| Assign default then override; no `nil` holes; explicit `n` length field (`S/General-Lua.md:23-58,208-222`) | handle fields, heap size | aligns with the cost model: initialize every handle field to non-nil (rawget hit 3.4 ns vs 22.6 ns miss), keep `self._Count` for the heap instead of `#`. |
| Public methods PascalCase | legacy lowercase surface | R1-R4 in section 4: frozen lowercase alias set, PascalCase canon, no lowercase for new members. |
| Debug output gated by attributes (`S/Context-Specific-Rules.md:92-116`) | `warn` in update on callback error | gate through `Env` (attribute on Roblox, a flag under Lune) and never `warn` per frame; count instead and expose `GetStats`. |
| Cross-system messaging via `MediatorAPI`; requires via `WaitForChild` (`S/Context-Specific-Rules.md:40-66,118-144`) | not applicable to a leaf library | TickAPI requires nothing but BaseClass; `Env` uses `ReplicatedStorage:WaitForChild("SharedModules")` for it. |
| Connection management through `ConnectionVault` (`S/BaseClass-MiddleClass.md:225-248`) | RunService connections owned by the registry | the registry owns 3-4 connections for the life of the game; store them on `TickAPI._Connections` with a `Disconnect` teardown. `ConnectionVault` requires `HttpService` and the live BaseClass tree; not worth a Lune seam for four connections. Flag if the house wants it anyway. |

## Findings

- F1 (major, perf): BaseClass subclasses dispatch 3.7x slower than root classes (54-58 ns vs 14.3)
  because `subclass` copies the parent's `__index` through `_createIndexWrapper`, turning the child
  dict's `__index` into a closure (`BaseClass.luau:50-66,233-235`; verified `type(Sub.__instanceDict.
  __index) == "function"`; resetting it to the dict restores 18 ns). Applies to every subclass in the
  game, not just TickRevamp. Do not subclass hot classes.
- F2 (major, perf): `Class:new` costs 4-5x a constructor table (909-1338 ns vs 222-265 ns retained)
  from incremental hash growth in `initialize` plus two `__tostring` hops for `.type`
  (`BaseClass.luau:168-179`). Handles must be built by constructor table / free-list.
- F3 (major, correctness): `ObjectPool.prewarmPool` errors on root classes and mis-pools on
  subclasses; capped pools return `nil` from `new`; `releaseToPool` has no double-release guard
  (`ObjectPool.luau:174-190,202-221,300-302`). Not usable for handles.
- F4 (major, live bug): `TickAPI.Tick:remove(x)` (colon) at `PrimaryCardControler_[Module].luau:124,
  141` is a silent no-op in the live game (`Tick.luau:117-133,224-230`).
- F5 (minor, perf): `Stateful` makes every method lookup a function call plus a stack scan
  (71.7-102.9 ns); `Callbacks` adds 4 ns even with no hooks and its allocate/subclass hooks are inert
  on this BaseClass (`Callbacks.luau:260-277` declare instance methods instead of statics).
- F6 (info): live BaseClass is not Lune-loadable (`BaseClass.luau:27`), even with a stubbed `game`.
  The standalone `G` core loads and passes 73/73, but `G` is 7/49 tasks in with no includes and the
  vault records a preference to vendor from HeroicSouls rather than GitHub.
- F7 (info): field misses on instances cost 22.6 ns vs 3.4 ns hits; a declared `Class.__index`
  handler or any class-level default read through `self` pays the hop. Initialize every field.
- F8 (info): the house templates and `TimeLineClass:33` declare classes as globals; the style wiki
  says `local`. `AfterNotTouched` is already a registered class name in the live VM.
- F9 (info): `class` + `type` add 0 B to a handle unless the field count crosses 8/16 (576 B for
  9-16 fields, 1088 B at 17).

## Recommendations

1. `TickScheduler`, `TickEvent`, `TickAfterNotTouched` are root BaseClass classes; `TickAPI` and the
   heap are plain tables. No subclassing, no `Stateful`/`Callbacks`/`ObjectPool`/`__index` on them.
2. Build handles through a constructor table with `class`/`type` preset and
   `setmetatable(t, TickEvent.__instanceDict)`, recycle through a capped private free-list that
   re-runs `TickEvent.initialize`; guard release with the state field and a generation counter.
3. Guard user-facing handle and scheduler methods with the localized-`getmetatable` colon check
   (+6.6 ns); make scheduler entry points dual-callable (dot and colon).
4. Naming: PascalCase canon, frozen lowercase legacy alias set in one region per file, PascalCase-only
   for new members; rename the prior build's lowercase new methods.
5. Lune: vendor the live BaseClass with the single JsonR patch as `build/vendor/BaseClass.luau`,
   resolve through `build/src/TickAPI/Env/init.luau` (snippet in section 5); do not require from
   `G` and do not write a shim.
6. Add a spec that requires every TickRevamp class module and asserts no `CLASSNAME ... already
   Exsist` warning fires (capture `warn` or use the vendored file's registrar seam) and that every
   handle field is non-nil after `initialize`.
7. Consider filing F1 against the live BaseClass separately (one-line fix in `subclass`: skip copying
   `__index` when the parent's is the dict itself); out of TickRevamp scope.

## Questions for Jake

1. Naming: should the new capabilities (`Pause`, `Resume`, `GetRemaining`, `SetPeriod`,
   `ForceComplete`, ...) be PascalCase only, or also get lowercase twins like the prior build's
   `pause/resume/getRemaining`? This report proposes PascalCase only.
2. Vendoring: is a patched copy of the live `BaseClass.luau` under `build/vendor/` (one line changed,
   test-only, never shipped) acceptable, given the earlier correction to vendor from HeroicSouls not
   GitHub -- or should TickRevamp's Lune tests use `GitHub/BaseClass` as-is?
3. Should the registry's RunService connections go through `ConnectionVault` for house consistency,
   even though it drags `HttpService` and the live BaseClass tree into the Roblox path?

# Veron 3.0.0 — API reference

`Veron` is HeroicSouls' timer scheduler: one instance per RunService hook (TickAPI builds
`Tick`, `Tickh`, `Tickr`), an indexed min-heap of due times, and a rolling virtual clock that
the wrapper advances with `update(dt)` once per frame. A timer is a `VeronEvent` handle
returned by `Delay`, `Recur`, `DelayAt`, `Drive` or `h:After`. Both are plain typed Luau
modules — the module table is its own instance metatable, with a `.new` factory and no external
OOP dependency; the design of record is `docs/DESIGN.md` (section numbers below refer to it). The legacy lowercase surface (`delay/recur/update/remove/getClocks`, `h:stop/reset/adjust/after`)
is kept as zero-cost aliases, so existing callers do not change.

## Retention rule (read this first)

**The instance holds every handle strongly until the handle is terminal.** A recurring timer
never dies unless it is stopped; a Paused handle is retained until it is resumed or stopped; a
Chained child (`h:After`) lives as long as its parent. Dropping your reference to a live
handle does not cancel it and does not free it — `Stop()` (or `Complete{ Stop = true }`,
`Clear()`, `Destroy()`) is the only way a live timer leaves the instance. A Fired one-shot is
out of every container the moment it fires; it is retained only by whoever still references it.

### Per-instance footprint

A `Veron` instance is not free: `initialize` builds **34 dual dot/colon closures under 41 keys**
(one closure per canonical member, shared by its aliases — `s.Stop == s.Remove == s.remove`),
a ~90-key instance table and the four side tables `_Due/_Item/_Paused/_Children`. Expect
**~7-9 KB and ~40 GC objects per instance** (bench P15 records the measured number). The advice
that follows from it: **one `Drive`n child per subsystem, never one Veron per entity.** A
subsystem that wants its own clock (own `TimeScale`, own `Pause`, own `MaxCatchUp`) builds one
child and has its parent pump it with `parent:Drive(child, period)`; entities arm handles on
that child. Handles are cheap (one 576 B table each, §Reuse over recreate); instances are not.

## Time model, in plain language

The legacy core keeps a countdown PER timer and subtracts `dt` from every one of them every
frame (`Tick.luau:141-144`) — that is why it is O(n). A heap needs ONE comparable number per
timer, so each timer stores the absolute moment it is due on a shared clock (`now + delay`) and
only the clock advances (`now += dt`). Yes, that number grows forever, and no, it does not
matter: a double keeps ~15-16 significant digits, so after a year of uptime the clock is still
accurate to a tenth of a microsecond (ulp(1e7 s) = 1.9e-9 s; measured drift 6e-4 s per 1e4
simulated seconds at 240 Hz, ALG F-ALG-12). RunService hands TickAPI a DELTA (`Stepped` passes
`(time, dt)`, `Heartbeat` passes `dt`), so `Update(dt)` accumulating is the natural fit;
`TimeScale`, `Pause` and deterministic stepping are only possible on a clock the instance owns.
Passing an absolute time (`UpdateTo(t)`) is the same loop with the clock SET instead of
advanced, exact at scale 1, and is what a cross-client synced instance
(`workspace:GetServerTimeNow()`) would use; `DelayAt` places a timer on that external axis. The
one rule: a handle belongs to exactly one Veron because dues are only comparable on the clock
they were computed against.

## Constructing a Veron (§2.1)

```lua
local Veron = require(script.Veron)           -- ReplicatedStorage.SharedModules.TickAPI.Veron
local s = Veron.new{ Name = "Tick" }          -- Veron:new(cfg) and Veron(cfg) are equivalent
```

All three spellings run one `initialize`; nothing registers the instance anywhere — `Name` is a
label for `Describe()` and diagnostics. The config table is validated key by key (unknown key
first); a config error blames the construction call. All three forms (`Veron.new{…}`,
`Veron:new{…}`, `Veron(cfg)`) reach one forward-declared `_construct` frame, kept un-inlined so
the error level lands on your call site, not inside the module.

| Key | Type / range | Default | Notes |
|---|---|---|---|
| `Name` | string | `"Veron" .. n` (module counter) | label only |
| `TimeScale` | finite number >= 0 | `1` | `0` freezes the clock |
| `MaxCatchUp` | integer >= 1 | `8` | fires per CAPPED recurring handle per pass; `Recur(fn, p, true)` / `h:SetCatchUp("all")` opt a handle out |
| `Valve` | integer >= 1 | `1000` | runaway valve: counts nested arms AND uncapped repeats per pass; a lagging uncapped handle delivers `Valve + 1` fires per pass and trips on the next; a `Restart()` of a Fired handle takes a fresh `Id`, so a self-restarting zero-period one-shot counts as a nested arm |
| `MaxDt` | number > 0 or `false` | `false` | off by default; when a number, `Update(dt)` clamps dt to it AFTER validation and counts `ClampedDt` |
| `MaxUpdateDepth` | integer >= 1 | `8` | re-entrant passes at this depth are advance-only |
| `OnError` | `"warn"` / `"error"` / `function(message, handle)` | `"warn"` | callback-error policy (see Diagnostics) |
| `Strict` | boolean | `false` | `true`: `Stop/Remove(non-handle)` errors instead of returning `false` |
| `LegacyRecurBase` | boolean | `false` | A/B knob: base of a recurring dispatch = `d + period` (reproduces the legacy L-01 lateness, see MIGRATION.md DV-7) |

Errors: `Veron: unknown option '<k>'`; `Veron: option '<k>' expects <what>, got <v>`. There is no
`Hook` (TickAPI connects the signal), no `CatchUp` mode string (the instance holds only the cap
number; `"all"`/`"drop"` are per handle) and no `MemoryCategory`.

## Wire it up: register and drive (start here)

Building a Veron does not start it. Nothing fires until something calls `Update(dt)` once per
frame. The whole hookup is three steps: **register one instance, connect one RunService signal to
its `Update`, then arm timers on it.**

```lua
local RunService = game:GetService("RunService")
local Veron = require(game.ReplicatedStorage.SharedModules.TickAPI.Veron)

-- 1. Register a scheduler (one per RunService hook, never one per entity)
local Tick = Veron.new({ Name = "Tick" })

-- 2. Pump time through it: one signal, once per frame, for the life of the game
RunService.Heartbeat:Connect(function(dt)
	Tick.Update(dt)              -- clock advances by dt * TimeScale; due timers fire now
end)

-- 3. Arm timers on it (dot or colon, both valid)
Tick.Delay(function() print("2 s later") end, 2)
local h = Tick.Recur(function() print("every 0.5 s") end, 0.5)
-- ...later:  h:Stop()          -- a live handle stays armed until it is stopped
```

That is the entire wiring. `Heartbeat` (runs after physics, hands you `dt`) is the usual choice;
`RenderStepped` / `Stepped` connect the same way — pick the phase the work belongs to and connect
**one** signal per instance. Connecting two signals to the same instance double-counts the clock.

**Installing the module.** The three ModuleScripts ship as one tree — `Veron` (parent) with
`VeronEvent` and `Env` as children — placed wherever your require path points (HeroicSouls:
`ReplicatedStorage.SharedModules.TickAPI.Veron`). Sync it with Rojo or paste the tree in; `Env`
auto-detects Roblox vs Lune, so nothing changes between runtimes.

**More than one clock.** Build one instance per cadence (`Tick` on Heartbeat, `Tickr` on
RenderStepped, ...), or give a subsystem its own child clock with `parent:Drive(child, period)` and
let the parent pump it — never one Veron per entity (see the footprint note above).

**In HeroicSouls** the `TickAPI` wrapper owns these connections: it does
`TickAPI.Tick = Veron.new{ Name = "Tick" }` and connects the signal once, so callers just write
`TickAPI.Tick.Delay(...)`. The snippet above is that wrapper's core, for a fresh place.

## Veron members (§2.2)

Every public member is callable with a dot or a colon (`s.delay(fn, t)` and `s:Delay(fn, t)`
reach the same closure). Errors are prefixed `Veron '<Name>': ` unless they belong to the legacy
validation family (byte-identical legacy templates, see Error contract). `s` = instance.

| Member | Signature → return | Semantics | Errors | Alias |
|---|---|---|---|---|
| `Update(dt)` | `→ nil` | `type(dt)` is checked FIRST, then the destroyed check; `MaxDt` clamp when set (`ClampedDt += 1`); `_LastDt = dt`; instance-paused → advances nothing; else `now += dt × TimeScale` and dispatch everything due. THE way a Veron is driven: TickAPI's RunService connection calls it once per frame; tests and `Drive` pumps call it directly | `Update(dt) expects a finite number >= 0, got <v>`; `destroyed` | `update` |
| `UpdateTo(t)` | `→ nil` | absolute clock: the first call anchors (never sweeps relative timers); later calls set the clock; backwards → clamp + `ClampedBackwards`, warned once if > 1 s | `UpdateTo(t) expects a finite number, got <v>`; `destroyed` | |
| `Now()` | `→ number` | the virtual clock (always the real clock, even inside a callback — see Now() vs GetBase()) | | |
| `SetTimeScale(x)` / `GetTimeScale()` | `→ nil` / `→ number` | `SetTimeScale` re-anchors the `UpdateTo` offset when one is set | `option 'TimeScale' expects a finite number >= 0` | |
| `Pause()` / `Resume()` / `IsPaused()` | `→ nil` / `→ nil` / `→ boolean` | instance freeze: `Update(dt)` (including `Update(0)`) and the first anchoring `UpdateTo` advance NOTHING and dispatch nothing; `UpdateTo` folds the gap into the offset; a deferred `Complete()` therefore waits for `Resume()` (use `CompleteNow` for an immediate fire) | | |
| `Delay(fn, t)` | `→ VeronEvent` | one-shot at `base + t`, where `base` is the firing handle's ideal due inside its own callback thread and `Now()` everywhere else (§4.1) | legacy strings; `destroyed` | `delay` |
| `Recur(fn, p, uncapped?)` | `→ VeronEvent` | recurring every `p` (> 0). Third argument `uncapped`, a boolean, default `false` — see Recur's third argument | legacy + `expected recur \`delay\` greater than zero`; `expected \`uncapped\` to be a boolean`; `destroyed` | `recur` |
| `DelayAt(fn, absDue)` | `→ VeronEvent` | one-shot at an absolute time on the `UpdateTo` axis; callback-first like every other arm | `DelayAt needs UpdateTo to have been called at least once` | |
| `Stop(h)` | `→ boolean` | handle only: `nil`/non-handle → `false` (`Strict` → error); a handle of another Veron → error; `true` iff a LIVE handle became Stopped — a Fired handle is finalized silently (→ Stopped, `_Fn = NOOP`, no container op) and returns `false` | `event #<id> belongs to Veron '<Y>', not '<X>'`; Strict: `expected a VeronEvent, got <t>` | `Remove`, `remove` |
| `Complete(h, opts?)` / `CompleteNow(h, opts?)` | `→ boolean` | force the handle's next fire (deferred to the next update / synchronously now); `opts = { Stop = true }` (PascalCase) ends a recurring after the forced fire; nil/non-handle/terminal → `false` | foreign error as `Stop`; `unknown option '<k>' in Complete`; `Complete expects an options table, got <t>` | `ForceEventComplete` (= `Complete`) |
| `GetRemaining(h)` | `→ number?` | owner-agnostic query, never raises: any handle → `h:GetRemaining()`; nil/non-handle → `nil` even under `Strict` (never 0) | never | |
| `GetClocks()` | `→ number` | Pending + Paused (not Chained) | | `getClocks` |
| `GetStats(into?)` | `→ table` | fills `into` or a fresh table with `Name, Destroyed, Now, TimeScale, IsPaused, Pending, Paused, Chained, Recurring, HeapSize, Clocks, Updates, LastDt, Dispatched, LastDispatched, Reentries, UpdateDepth, Dropped, ValveHits, ClampedBackwards, ClampedDt, Errors, ErrorsSuppressed, Children` — every value an O(1) counter; zero-alloc ONLY when the SAME `into` table is reused (the first fill sizes it) | | |
| `Validate()` | `→ true \| false, reason` | O(n) invariant oracle; never raises | | |
| `Describe()` | `→ string` | `Veron<Tick now=12.300 pending=40 paused=2>` | | |
| `SetOnError(p)` / `SetMaxCatchUp(n)` / `GetMaxCatchUp()` / `SetValve(n)` / `SetMaxDt(x)` / `SetStrict(b)` | `→ nil` (`GetMaxCatchUp → n`) | live reconfiguration with the construction-time validation; `SetMaxCatchUp` changes the cap every inheriting handle uses from the next pass (per-handle overrides untouched); `SetMaxDt(false)` disables the clamp | `option '<k>' expects <what>, got <v>` | |
| `Clear()` | `→ number` | stops Pending, Paused and Chained alike with terminal writes only, cascades to attached children; returns the count; legal mid-update; a Fired handle is in no container, so `Clear` never reaches it | | |
| `Attach(child)` / `Detach(child)` / `GetChildren()` | `nil` / `boolean` / `{Veron}` | ownership: attached children are Cleared/Destroyed with the parent; single parent; `child:Destroy()` detaches itself; `GetChildren` is a snapshot (allocates; not per-frame) | `Attach expects a Veron, got <t>`; `cannot attach itself`; `'<C>' is destroyed`; `'<C>' is already attached to '<P>'`; `Attach would create a cycle` | |
| `Drive(child, period, uncapped?)` | `→ VeronEvent` | recurring pump `child:Update(period)` that stops itself once the child is destroyed; ALWAYS attaches (so a mutual `Drive` is refused as a cycle); `uncapped` defaults to `true` — a lossless sub-clock: after a parent hitch every owed `period` reaches the child, valve-bounded; `false` accepts lost child time | `Drive expects another Veron`; `expected \`uncapped\` to be a boolean`; `Recur`/`Attach` errors | |
| `Destroy()` / `IsDestroyed()` | `nil` / `boolean` | dead FIRST, then `Clear`, destroy attached children, detach from the parent; legal from inside its own callback; twice is a no-op; no options | never | |
| `IsUpdating()` / `GetBase()` | `boolean` / `number \| false` | `IsUpdating` = a pass is running; `GetBase` = the ideal due the CALLING thread's arms measure from (`false` outside a firing thread) | | |
| `Name` | public string field | | | |

After `Destroy`: `Update/UpdateTo/Delay/Recur/DelayAt/Attach/Drive` raise `destroyed`;
`Stop/Complete/CompleteNow/GetRemaining/GetClocks/GetStats/Validate/Describe/Clear/Detach/Destroy/Pause/Resume/Set*`
stay total (`false`/`nil`/`0`/no-op); every handle method stays total too — `h:After(fn, t)` on a
handle of a destroyed instance returns a born-Stopped child, never `destroyed`. TickAPI's field
keeps pointing at the dead instance, so callers get `destroyed`, not an index-nil.

## VeronEvent handle (§2.3)

Handles are created only by an instance (`VeronEvent:new()` / `VeronEvent()` raise
`VeronEvent: handles are created by a Veron (Delay/Recur/After)`). They are tables with a
metatable (`h.class == VeronEvent`, `h.type == "VeronEvent"`, `h:isInstanceOf(VeronEvent)`), so
`type(h) == "table"` discriminators keep working. Every method is **colon-only**: the first line
of each is a guard that raises `VeronEvent: methods take a colon: event:Stop(), not event.Stop()`.
Every method is **total on terminal handles** (Fired, Stopped): it returns `h` / `false` / `0`
and never raises — with one carve-out. `Complete`/`CompleteNow` validate their options table
*before* the terminal check, so `firedHandle:Complete({Bad=1})` or `:Complete("str")` still raises
the option error (a bare `:Complete()` or valid opts stays total, returning `false`); `Adjust` and
the setters instead check terminal state first and are total even with invalid arguments (see each
row's Errors column). The callback signature is `fn()` — no arguments.

| Member | → return | Semantics (matrix in State machine) | Errors | Alias |
|---|---|---|---|---|
| `Stop()` | nothing | terminal Stopped; on a Fired handle too (finalizes it: `_Fn = NOOP`, `Restart()` refused from then on — the `SafeStopClock`-after-fire path); cascades to Chained children; idempotent; owner-agnostic (works on any Veron's handle) | never | `stop`, `Destroy` |
| `Reset()` | `h` | full period from `now`; no-op while COMMITTED (a forced fire is owed) | never | `reset` |
| `Adjust(x)` | `h` | ratio-preserving retime from `now`: the consumed fraction of the old total is kept over the new total `x`, and `x` becomes the period; `tonumber` coercion; no-op while COMMITTED. Terminal check BEFORE argument validation: `firedHandle:Adjust(0/0)` is a silent no-op | `expected \`newTotal\` greater than zero` (non-terminal only) | `adjust` |
| `After(fn, t)` | child `VeronEvent` | chained child armed at the parent's ideal due + `t` when the parent fires; never returns the parent; on a Stopped parent or a destroyed instance → born-Stopped child WITHOUT argument validation; on a Fired parent → arms now (from the caller's clock) | `cannot chain a recurring event`; legacy arg strings (Pending/Paused/Chained/Fired parents only) | `after` |
| `SetPeriod(p)` / `GetPeriod()` | `h` / number | future arms only, never re-keys; terminal → no-op before validation | `expected \`newPeriod\` greater than zero` (recur) / `of zero or greater` (one-shot) | |
| `SetRemaining(x)` / `GetRemaining()` | `h` / number >= 0 | "x more seconds" from now, period untouched; instance-seconds; terminal/COMMITTED → no-op before validation | `expected \`remaining\` of zero or greater` | |
| `Pause()` / `Resume()` / `IsPaused()` | `h` / `h` / boolean | freeze/thaw the current cycle (frozen remaining kept, nothing accumulates); Chained → pause-when-created flag; `Resume` on a Pending+REPAUSE handle clears REPAUSE (fires, then runs on); `IsPaused()` is `true` for Paused AND for Pending+REPAUSE (a deferred Complete on a Paused recurring stays logically paused; `GetState()` reads the transient `"Pending"`) | never | |
| `Toggle()` | `h` | the recur switch: Pending (plain) → Pause; Paused → Resume; Chained → flip the pause-when-created flag; Pending+COMMITTED, Fired, Stopped → no-op | never | |
| `Restart()` | `h` | the ONE explicit re-arm of a **Fired** handle: → Pending at `now + period` (a Fired recurring re-arms as recurring; the callback was kept); Pending/Paused → `Reset()` then `Resume()` (full period from now, running; COMMITTED → no-op); Chained → no-op; **Stopped → no-op (final)**; destroyed Veron → no-op; the Fired re-arm takes a fresh `Id` | never | |
| `Complete(opts?)` / `CompleteNow(opts?)` | boolean | deferred (next update) / synchronous forced fire; `opts.Stop` ends a recurring after the forced fire; `opts` must be nil or a table with only `Stop`; `false` on terminal handles and from inside the handle's own callback | `Veron '<N>': unknown option '<k>' in Complete` | (none: `ForceEventComplete` lives on the instance) |
| `SetCatchUp(mode, n?)` | `h` | per-handle catch-up override, recurring only (one-shot/terminal no-op before validation) — see below | `Veron '<N>': option 'CatchUp' expects cap, all, drop or inherit`; `option 'MaxCatchUp' expects an integer >= 1, got <n>` | |
| `GetState()` / `GetStateId()` | string / number | `"Pending"`, `"Paused"`, `"Chained"`, `"Fired"`, `"Stopped"` / 1–5 (`VeronEvent.STATE_NAMES`); inside its own callback a one-shot already reads `"Fired"` | | |
| `IsActive()` / `IsRecurring()` / `GetId()` / `GetScheduler()` / `Describe()` | boolean / boolean / number / Veron / string | `IsActive` = Pending/Paused/Chained; `Describe()` → `VeronEvent<Tick#42 recur 0.5s Pending>` (`+stop` / `+repause` while COMMITTED) | | |
| `Id` | public integer | ascending per instance from 1, never reused; the equal-due tie-break (FIFO among equal dues); re-issued by `Restart()` of a Fired handle (`GetId()`/`Describe()` show the new number) | | |

### Recur's third argument and `h:SetCatchUp`

`Recur(fn, p, uncapped)` — `uncapped` is a boolean, default `false`. Any other type raises
`expected \`uncapped\` to be a boolean` BEFORE any mutation (nothing armed, counters untouched).

| Value | Catch-up after a hitch (the instance owes several fires of one handle in one pass) |
|---|---|
| `false` / `nil` (**capped**, the default) | at most the instance `MaxCatchUp` (8) fires per pass; the remainder is dropped on-grid — the handle snaps to the first grid point after `now`, phase kept, `Dropped` counted. Cosmetic and polling timers want this. |
| `true` (**uncapped**) | every owed fire happens. The pass is valve-bounded: one lagging uncapped handle delivers `Valve + 1` fires per pass; when the valve trips the timer stays keyed at its due, so the rest fires on the next update — NOTHING is lost, only spread. Still sub-resolution-guarded (a period below the clock's float resolution stops the handle with one report instead of hanging). Logic timers (DoT, regen, sub-clocks) want this. |

`h:SetCatchUp(mode, n?)` overrides the policy on one recurring handle at any time:

| Call | Effect |
|---|---|
| `h:SetCatchUp("cap", n)` | at most `n` fires per pass (`n` nil → snapshot of the instance cap at the time of the call, frozen) |
| `h:SetCatchUp("all")` | uncapped (= `Recur(fn, p, true)`) |
| `h:SetCatchUp("drop")` | at most ONE fire per pass, the rest dropped on-grid (a render-style timer) |
| `h:SetCatchUp("inherit")` | back to the instance `MaxCatchUp`, following `SetMaxCatchUp` live |

A render instance can be built with `MaxCatchUp = 1` so every inheriting handle behaves as
`"drop"`. The instance `Drive(child, period)` pump is uncapped by default because a sub-clock
must not lose time.

## Stop, Complete, Destroy — the three verbs side by side

| | `h:Stop()` / `s:Stop(h)` / `s:Remove(h)` / `h:stop()` / `h:Destroy()` | `h:Complete(opts?)` / `s:Complete(h, opts?)` / `ForceEventComplete` | `h:CompleteNow(opts?)` / `s:CompleteNow(h, opts?)` | `s:Destroy()` |
|---|---|---|---|---|
| What | cancel: the callback never runs again | fire early: the next update runs the callback | fire early: the callback runs synchronously, now | kill the whole instance |
| Live handle | → Stopped; leaves its container; cascades to still-Chained children; `s:Stop(h)` returns `true` | re-keyed to `now`; recurring keeps recurring (or ends after the fire with `{ Stop = true }`); Paused recurring fires then stays Paused; returns `true` | same transitions, callback run before the call returns; returns `true` even if the callback errored | `Clear()` → every Pending/Paused/Chained handle Stopped; attached children destroyed; the instance refuses new arms with `destroyed` |
| Fired handle | **finalizes it**: → Stopped, callback released (`_Fn = NOOP`), no container op; `s:Stop(h)` returns `false`; `Restart()` is refused from now on | `false`, nothing happens | `false`, nothing happens | cannot reach it (a Fired handle is in no container) but `Restart()` on it becomes a no-op because the instance is destroyed |
| Stopped handle | no-op (`false`) | `false` | `false` | — |
| From inside the handle's own callback | works: a recurring that stops itself does not fire again this pass, even while lagging | `false` (a callback cannot complete itself) | `false` | legal: the running pass exits after the current callback |
| On a nil / non-handle | `s:Stop(nil)` → `false` (`Strict` → error); `h:stop()` on a non-handle is a raw error (the wrapper's `SafeStopClock` never receives one) | `false` | `false` | — |
| On another Veron's handle | `h:Stop()` works (owner-agnostic); `s:Stop(h)` raises `event #<id> belongs to Veron '<Y>', not '<X>'` | as `Stop` | as `Stop` | — |

Notes that matter for reuse:

- **A post-fire `Stop` finalizes a Fired handle.** After a one-shot fires it keeps its callback so
  that `Restart()` can run it again; an explicit `Stop` (`h:stop()`, `SafeStopClock(h)`,
  `h:Destroy()`) turns Fired into Stopped and releases the closure, and **Stopped is final** —
  no verb brings a Stopped handle back. This is exactly the legacy `SafeStopClock`-after-fire
  path: the 68 teardown sites keep releasing what they always released.
- **`Clear()` never reaches a Fired handle** — it walks the heap and the paused set only. After a
  `Clear()` alone (no `Destroy`), a Fired handle stays restartable and retains its closure until
  it is garbage-collected or explicitly stopped. If a subsystem hands out one-shot handles and
  tears down with `Clear()`, stop the Fired ones it still references.
- **`Restart()` takes a fresh `Id`.** A Fired handle re-armed by `Restart()` is the newest arm on
  the instance: it sorts last among equal dues, and if it restarts itself from its own callback
  with a zero period the runaway valve bounds it (1000 per pass, warned once, resumed next
  update) instead of spinning forever. `Restart` is the ONLY verb that leaves Fired; `Reset`,
  `Adjust`, `Resume`, `After`, `Complete` never resurrect a terminal handle.
- `Stop` never fires; `Complete`/`CompleteNow` never run on a terminal handle.

## State machine (§5) — every cell is total, never a raw error

`P` = period, `d` = the firing handle's ideal due, `now` = `Now()`. COMMITTED = a Pending
recurring with a forced fire owed (after `Complete` / `Complete{ Stop = true }`).

| Operation | Pending | Paused | Chained | Fired | Stopped |
|---|---|---|---|---|---|
| natural fire (one-shot) | → Fired BEFORE fn; children armed at d | — | — | — | — |
| natural fire (recurring) | re-key `d+P` (or snap) BEFORE fn; `Complete{Stop=true}` → Fired; deferred Complete of a Paused → Paused (remaining = P) | — | — | — | — |
| parent fires | — | — | → Pending @ `d+P`; paused-when-created → Paused (remaining = P) | — | — |
| `Stop`/`Remove`/`Destroy`/`stop` (the `SafeStopClock` path) | → Stopped, leaves the heap, cascade to still-Chained children | → Stopped, unpark, cascade | → Stopped (parent skips it), cascade | → Stopped (no container op; callback released; instance `Stop` returns `false`) | no-op |
| `Reset` | key = `now+P`; COMMITTED → no-op | remaining = P | no-op | no-op (h) | no-op (h) |
| `Adjust(x)` | key = `now+frac·x`; P = x; COMMITTED → no-op | remaining = frac·x; P = x | P = x | no-op (h), even with a bad `x` | no-op (h) |
| `SetPeriod(p)` | P = p; COMMITTED → no-op | P = p | P = p | no-op | no-op |
| `SetRemaining(x)` | key = `now+x`; COMMITTED → no-op | remaining = x | P = x | no-op | no-op |
| `Pause` | → Paused (freeze); COMMITTED → no-op (the forced fire is owed) | no-op | flag pause-when-created | no-op | no-op |
| `Resume` | REPAUSE → cleared (fires, then runs on); else no-op | → Pending @ `now+remaining` | clear the flag | no-op | no-op |
| `Toggle` | → Paused (as `Pause`); COMMITTED → no-op | → Pending @ `now+remaining` (as `Resume`) | flip the flag | no-op | no-op |
| `Restart` | key = `now+P`, keeps running; COMMITTED → no-op | → Pending @ `now+P` | no-op | → Pending @ `now+P` with a fresh `Id` (the ONE re-arm; recurring stays recurring; callback kept) | no-op (final) |
| `After(fn,t)` | child Chained | child Chained | grandchild Chained | child Pending @ caller's clock + t | child born Stopped (no validation; also for any parent on a destroyed instance) |
| `Complete` (deferred) | key = now → `true` (own callback → `false`) | → Pending @ now (+REPAUSE if recurring, or stop-on-fire) → `true`; `IsPaused()` stays `true` under REPAUSE | detached (the parent now skips it) → Pending @ now → `true` | `false` | `false` |
| `CompleteNow` | fires now → `true` (own callback / already completing → `false`) | fires; recurring stays Paused (remaining = P) → `true` | detach, fire → `true` | `false` | `false` |
| `SetCatchUp` | recurring: override set | same | same | no-op | no-op |
| `GetRemaining` | `max(due−now, 0)` | remaining | P | 0 | 0 |
| `IsActive` / counted by `GetClocks` | true / yes | true / yes | true / no | false / no | false / no |
| `Clear()` / instance `Destroy` | → Stopped | → Stopped | → Stopped | — | — |

Instance states: live → destroyed (terminal). The instance `Pause/Resume` switch is orthogonal
to handle states. Which RunService signal drives `update(dt)` is TickAPI's concern and invisible
to the instance.

## Not per-frame

Every scheduling operation and every counter query is allocation-free once warm. These allocate
on every call and are meant for diagnostics, tooling and teardown, never for a per-frame path:

| Call | Allocates |
|---|---|
| `GetStats()` with NO `into` table | a fresh 24-key table each call (pass and reuse the same `into` for a zero-alloc read) |
| `GetChildren()` | a snapshot array of the attached children |
| `Describe()` on the instance or on a handle | the formatted string |
| `Validate()` | the reason string only when an invariant is violated (otherwise 0 B); still an O(n) walk of the heap and the paused set |
| `GetStats(into)` on the FIRST call with a given `into` | sizes the table's hash part once; every later call with the same table is 0 B |

Diagnostics are warn-once and counted, never per frame; the callback-error report is
rate-limited (same handle <= 1 report/s, distinct handles <= 8/s; `Stats.Errors` is exact,
`Stats.ErrorsSuppressed` counts the withheld reports).

## Now() vs GetBase()

`Now()` is always the real virtual clock — the value `Update(dt)` accumulated to. Inside a
callback it includes the sub-frame overshoot (a timer due at 1.000 dispatched by the frame that
reached 1.017 reads `Now() == 1.017`).

`GetBase()` is the moment arms made from the CALLING thread measure from: inside the firing
callback's own thread it is the firing handle's ideal due (`1.000` in the example — so a
`Delay(fn, 0.5)` armed in that callback is due at exactly 1.500, and a chain of such arms never
drifts); outside a firing thread it is `false` and arms measure from `Now()`. The carry belongs
to the firing thread only: a RemoteEvent handler, another RunService handler, or code
`task.spawn`ed from a callback all measure from `Now()`, and a callback that yields for seconds
cannot anchor a top-level arm to a stale due. So inside a callback `Now() ~= GetBase()` by the
overshoot, and that is the intended reading — `Now()` for "what time is it", `GetBase()` for
"what will my nested arm measure from". Explicit re-timing ops (`Reset`, `Adjust`,
`SetRemaining`, `Restart`, `Resume`, `Complete`) always measure from `Now()`.

## Touch patterns (§2.4)

| Pattern | Build it as | Notes |
|---|---|---|
| reset-after-touched | `h = s:Delay(fn, t)`; `h:Reset()` on every touch; `h:Stop()` on destroy | TickAPI's `AfterNotTouchedClass` stays a ten-line class over exactly this; once Fired, `h:Restart()` arms the same window again |
| recur-till-touched | `h = s:Recur(fn, p)`; `h:Pause()` on touch | `h:Resume()` runs on from the frozen remaining, `h:Restart()` from a fresh full period (`h:Reset()` alone only refills the frozen remaining); a paused recurring accumulates nothing |
| recur switch | `h = s:Recur(fn, p)`; `h:Toggle()` on every touch | one touch stops, the next starts; `IsPaused()` reads the switch |

### Reuse over recreate (576 B vs 0 B)

A new handle costs one 576 B table plus a heap push (~250 ns under Lune, ALG P1);
`Reset/Restart/Pause/Resume/Toggle` on an existing handle cost one heap move (~100–300 ns, ALG
P3–P5) and 0 bytes. Rule: hold the handle and reuse it whenever the same thing repeats; recreate
only when the owner is gone. At 10k timers/s recreating produces ~5.8 MB/s of garbage (BC: 10k ×
576 B); reuse produces none.

## How TickAPI wires Veron (§6 — the contract the wrapper builds against)

`ReplicatedStorage.SharedModules.TickAPI` stays the module every caller requires. Today it holds
three copies of the legacy scheduler (`Tick`, `Tick2`, `Tick3`) and connects each to one
RunService signal. After migration it holds ONE `Veron` module tree and builds three instances;
only the three require+connect blocks change:

| Block in TickAPI.luau | Legacy | New |
|---|---|---|
| require + construct | `TickAPI.Tick = require(game.ReplicatedStorage.SharedModules.TickAPI.Tick)` (`Tickh` ← `Tick2`, `Tickr` ← `Tick3`) | `local Veron = require(script.Veron)` once; `TickAPI.Tick = Veron.new{ Name = "Tick" }`; `TickAPI.Tickh = Veron.new{ Name = "Tickh" }`; client only: `TickAPI.Tickr = Veron.new{ Name = "Tickr", MaxCatchUp = 1 }` (`MaxCatchUp = 1` optional) |
| Stepped | `RunService.Stepped:Connect(function(_, dt) TickAPI.Tick.update(dt) end)` | identical — `Stepped` passes `(time, dt)`, **dt is the 2nd argument**, same as today |
| Heartbeat / RenderStepped | `RunService.Heartbeat:Connect(function(dt) TickAPI.Tickh.update(dt) end)`; `RunService.RenderStepped:Connect(function(dt) TickAPI.Tickr.update(dt) end)` | identical — both pass dt FIRST |
| `Tick`, `Tick2`, `Tick3` ModuleScripts | three legacy copies | all deleted; `Veron` (children `VeronEvent`, `Env`) is the only module |

What keeps working unchanged, and why:

| TickAPI member | Legacy code it runs | Veron feature it relies on |
|---|---|---|
| `SafeStopClock(clockObj)` | `clockObj:stop()` | handle alias `stop = Stop`, total on terminal handles and final on Fired ones (→ Stopped, callback released, no `Restart`) — the 68 stop-after-fire sites stay silent and still kill the handle for good |
| `AfterNotTouchedClass` (`GetAfterNotTouched(t, fn, tickType)`) | `TickAPI[TickType].delay(fn, t)`, `Clock:reset()`, `SafeStopClock(Clock)` | dot-called `delay` closure; alias `reset = Reset` (full window from now); `stop` |
| `TimeManagerAPI = require(TickAPI)`, global `TickAPI` leak (`xray:87`) | module identity | untouched: nothing but the three blocks above changes |

The ONE thing TickAPI must be aware of (DV-23): `update(dt)` now raises
`Veron '<Name>': Update(dt) expects a finite number >= 0, got <v>` on nil/NaN/negative/inf/string
dt instead of silently poisoning the clock. RunService never delivers such a dt in practice; the
recommendation (not a requirement) is a one-line guard in each connection —

```lua
if dt ~= dt or dt < 0 then dt = 0 end
```

— so a hypothetical bad frame is dropped rather than raised inside the handler. Optional knobs
the wrapper may pass per instance: `MaxDt = 0.25` (hitch clamp; off by default so a hitch is
timer time exactly as before) and `MaxCatchUp = 1` for a render instance (cosmetic timers never
burst after a hitch). Other wrappers (`StrikeTickAPI.luau`, the `FxPackageLite` wrapper) become
one line each — `Veron.new{ Name = "StrikeTick" }` — plus their existing connection.

`OnError = "error"` re-raises the first callback error once, at the outermost exit of
`update(dt)`; inside TickAPI's RunService handler Roblox isolates a handler error, so the
connection survives and the next frame runs normally.

## Error contract

- **Validation family** (unprefixed, legacy templates byte-identical): `expected \`fn\` to be
  callable`; `expected \`delay\` to be a number. CurrentType: <typeof of the original argument>`;
  `expected \`delay\` of zero or greater`; `expected recur \`delay\` greater than zero`;
  `expected \`newTotal\` greater than zero`; `expected \`newPeriod\` …`; plus three in the same
  voice: `expected \`delay\` to be a finite number`, `expected \`remaining\` of zero or greater`,
  `expected \`uncapped\` to be a boolean`.
- **Every other error** starts with `Veron '<Name>': ` or `VeronEvent: ` (config errors, raised
  before `Name` is settled, use the bare `Veron: ` prefix). The error level is chosen so the
  message blames the caller's line, not the library.
- **Callbacks are untrusted.** A callback that errors, yields, re-enters `update`, or stops /
  re-times / completes any handle (its own included) never corrupts the instance; the heap is
  in its final post-fire shape before user code runs, so a callback's own `Stop/Reset/Adjust/
  Pause/Complete` simply wins. Errors go through the `OnError` policy (`"warn"` default,
  `"error"` re-raise once at the outermost exit, or `function(message, handle)`); a throwing
  policy function or a throwing warn seam is contained too.
- `Validate()` is the invariant oracle for tests and tooling; it never raises.

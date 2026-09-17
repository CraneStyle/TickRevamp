# Veron 3.0.0 — migration guide (legacy Tick / TickAPIOptimize 2.0.0 → Veron)

Companion to `API.md`. Section numbers refer to `docs/DESIGN.md`. Every deviation below is
pinned two-sided (legacy value AND new value) in `build/tests/spec/parity/parity_spec.luau`, so
"what changed" is a test, not a belief. Call-site counts come from the live survey
`research/callsites.md` (HeroicSouls mirror, commit fdb6efba8, 2026-08-25).

## 1. Preserved verbatim (§7.1)

Every live shape is provided by a zero-cost alias — no shim layer, no wrapper code path.

| Live shape (count) | Provided by |
|---|---|
| `TickAPI.Tick/.Tickh/.Tickr .delay(fn,t)` / `.recur(fn,t)` dot-called, truthy table handle (206 calls; `type(x) == "table"` discriminators, `EntityActionClass:88`) | dual closures `delay/recur`; the handle is a table with a metatable |
| `.update(dt)`, `.remove(h)`, `.getClocks()` (wrappers, Cmdr) | closures `update/remove/getClocks` |
| `TickAPI.Tick:remove(h)` colon (2 sites) | the dual closure shifts `self` — now actually removes (DV-3) |
| `TickAPI.SafeStopClock(h) → nil` (68 sites, 19 with the `x = SafeStopClock(x)` reassign idiom) | TickAPI's wrapper unchanged; `h:stop()` is total on terminal and foreign handles and finalizes a Fired one |
| `TickAPI.GetAfterNotTouched(t, fn, "Tickh") → {Touch, Destroy}` (1 site) | TickAPI's `AfterNotTouchedClass` unchanged over `.delay` + `:reset()` + `SafeStopClock` |
| `h:stop()` (12), `h:reset()` (9, 2 on recur), `h:adjust(n)` (2), `h:after()` (0) | LEGACY SURFACE of `VeronEvent`: `stop = Stop, reset = Reset, adjust = Adjust, after = After, Destroy = Stop`; LEGACY SURFACE of `Veron` (one closure per spelling): `update, delay, recur, remove, Remove, getClocks, ForceEventComplete` — the alias set is closed (Q-J7) |
| `tonumber` coercion of delays; `delay(fn, 0)` legal (`CameraClass:307`); stop from inside own callback (21 sites); cross-wrapper stop via `h:stop()`; `TimeManagerAPI = require(TickAPI)`; global `TickAPI` leak (`xray:87`) | §4.1, §4.3; TickAPI module identity unchanged |

## 2. Migration order (§7.2) — each step has a verify and a rollback

| # | Step | Verify | Rollback |
|---|---|---|---|
| **M0** | Lune: full suite + parity green; `alloc_spec` 0 B; run `build/bench/studio_bench.luau` once in Studio with `--!native` | `lune run build/tests/run.luau` → 0 failed | — |
| **M1** | Copy `SharedModules/TickAPI` to `ServerStorage/TickAPI_Legacy` (disabled); install the `Veron` module tree (`Veron` + children `VeronEvent`, `Env`) under `SharedModules/TickAPI`; edit TickAPI.luau's three require+connect blocks (API.md "How TickAPI wires Veron"); delete the legacy `Tick`/`Tick2`/`Tick3` ModuleScripts | Play: on server and client `TickAPI.Tick.GetStats().Updates > 0` and `TickAPI.Tickh.GetStats().Updates > 0` (client: `Tickr` too) after a few frames; no `Update(dt)` error in the output | swap the folders back |
| **M2** | Sign-off on the §3 "who notices" sites, especially `PrimaryCardControler` (hover-card timers now cancelled, DV-3) and the recur-nested files (DV-7, §4 below): build `Tick`/`Tickh` with `LegacyRecurBase = true` for an A/B | manual Studio checks; `GetStats().Reentries` and `.ValveHits == 0` after a session | flip `LegacyRecurBase` / pass `true` as the third argument to an affected `recur` / `MaxDt = false` per instance |
| **M3** | `StrikeTickAPI.luau` and the `FxPackageLite` wrapper each build their own instance — `Veron.new{ Name = "StrikeTick" }` (one line each) — and keep their own connection; delete their legacy `Tick` child copies | `UpdateAction_ActionServerHitScan`, `Action_ConeHitScan` strike windows fire; `SafeStopClock` on strike handles still stops them | restore the files |

## 3. Accepted deviations (§7.3)

Each row is pinned two-sided in `parity_spec` (20 pins). DV-16, DV-18, DV-19 and DV-22 are not
deviations of this class — they were left with their scope (the wrapper, SyncedTimer) and have
no row here on purpose.

| DV | Legacy | New | Who notices (live) |
|---|---|---|---|
| DV-1 | same-due order newest-first, scrambled by removals (L-13); multiple `after()` newest-first | `(due, Id)` FIFO; children in registration order (D23) | `DungeonCreator:167-179`, `xray:63-87`, `FxPackage:680/741` — order-independent; 0 `after` callers |
| DV-2 | nested past-due event fires synchronously inside `delay()`, returns a noop dummy (L-04) | later in the same update, real handle returned (D5) | `CameraClass:312-322` (delay-0 inner: one dispatch later, harmless) |
| DV-3 | `TickAPI.Tick:remove(h)` colon = silent no-op + leak (L-12) | works: the instance's dual closures make `TickAPI.Tick:remove(h)` remove | `PrimaryCardControler:124,141` — hover-card timers now cancelled as intended |
| DV-4 | NaN/inf delay accepted as zombies; recur 0 hangs; `adjust(<=0/NaN)` poisons (L-07/F5/L-10) | rejected at creation / adjust (D10) | zero speed at `CharacterSheet_Animation:158`, `UpdateAction_ActionServerHitScan:459` now errors instead of poisoning |
| DV-5 | stop-after-fire leaks a key (F3); adjust/reset on a dead handle silently mutate | terminal handles are no-ops (D8) except `Restart()` (the one explicit re-arm of a Fired handle) and `Stop` on Fired (finalizes it: callback released, Stopped stays final) | 68 `SafeStopClock` sites stop leaking and release the closure; adjust-after-fire → silent no-op |
| DV-6 | parent callback throw kills its `after` chain (B-13) | children still arm | none (0 `after` callers) |
| DV-7 | timer created inside a RECURRING callback waits one extra period (L-01) | measured from the firing due (D4): such timers fire about **one parent-period EARLIER** — a fixed lateness per nested timer, not cumulative drift | the <= 26 files that `recur` and `delay` on one instance (e.g. `FxPackage:1049→680/741`, `EventSpawnerClass:406→346`), listed in §4; `LegacyRecurBase = true` reproduces the quirk per instance |
| DV-8 | recurring `stop()` inside own callback while lagging still fires the backlog (L-06) | exactly one fire | 15 "poll until ready then stop" recur sites — strictly better |
| DV-9 | stopping a co-due sibling double-ticks an already-processed entry (L-02) | never | `EntityActionClass:81-95` |
| DV-10 | unbounded catch-up burst after a hitch (L-08) | 8 per handle per update, remainder dropped on-grid (D6); `Recur(fn, p, true)` restores the legacy burst (valve-bounded, nothing lost); a render instance may be built with `MaxCatchUp = 1` | `Tickr.recur 0.01` refresher, `0.048` blink, 1/24–1/30 flipbooks: no burst after a hitch. Logic timers that must not lose ticks (DoT, regen) should pass `true` |
| DV-11 | `delay(3×dt)` fires on the 4th frame (L-14) | same class of one-frame lateness, documented, no epsilon (D23) | nobody |
| DV-12 | `getClocks()` always 0 (F7) | real count (Pending + Paused) | 0 callers |
| DV-13 | `after()` on a terminal parent = silent never-fire (L-11) | Fired → arms now; Stopped → Stopped child | 0 callers |
| DV-14 | hook `dt` passed raw (a 2 s hitch = 2 s of timer time) | unchanged by default (`MaxDt = false`, Q-J16); an instance built with `MaxDt = n` clamps `Update(dt)` to n and counts `ClampedDt` | nobody until TickAPI opts in per instance |
| DV-15 | a throwing callback aborts the frame and poisons `err` (F4/L-03) | isolated, warned, `OnError` policy | everyone, positively |
| DV-17 | `remove(number)` removes by array index / raw error (L-15) | `false` | none |
| DV-20 | raw internal errors (`attempt to index nil with 'parent'` on `h.stop()`) | every new error prefixed (`Veron '<N>':` / `VeronEvent:`); legacy validation strings byte-identical; handle dot-calls raise the colon message | nobody pcall-matches these |
| DV-21 | re-entrant `update()` from a callback runs unguarded on the same array (L-16) | a real nested pass, depth-capped at 8, counted in `Reentries`, warned once | none |
| DV-23 | `update(dt)` with negative dt silently grows timers, NaN poisons the group, `nil` errors mid-loop, `"0.5"` is coerced (I10/I11/I13) | prefixed error before touching state | no live caller calls `update` except TickAPI's three connections — API.md recommends the one-line guard `if dt ~= dt or dt < 0 then dt = 0 end` |
| DV-24 | `CurrentType: ` suffix reports `type()` of the coerced value (`{}`/`true` → `nil`, an Instance → `userdata`) | `typeof` of the original argument (`table`/`boolean`/`Instance`, D10/L-17); templates unchanged | nobody pcall-matches; `HardPointSFXManager:57` message gets more useful |

## 4. DV-7 — timers created inside recurring callbacks fire one parent-period EARLIER

**Warning.** In the legacy core a timer armed from inside a RECURRING callback measured from
the recurring handle's *next* due (`d + period`), so it always waited one extra parent period
(L-01). Veron measures every nested arm from the firing handle's ideal due `d`. Timers created
inside a recurring callback therefore fire about **one parent-period EARLIER** than they did:
a fixed lateness per nested timer that is now gone, not a cumulative drift. Two-sided pin:
`parity_spec :: DV-7: legacy 2.500, new 1.517, LegacyRecurBase equals legacy` (a 1 s delay
armed inside a 1 s recur at 1/60 stepping). Cross-instance creation (a `Tickh` callback arming
on `Tick`) is unaffected: the other instance's `Now()` is used.

Per-instance A/B: `Veron.new{ Name = "Tick", LegacyRecurBase = true }` reproduces the legacy
base for every recurring dispatch on that instance. It is a migration knob, not a setting to ship.

Files to review, from `research/callsites.md` (§1a call shapes, §2 P1 "timers created inside
timer callbacks") and its raw dump `research/scratch/callsites/all_lines.txt`: every live-tier
file (RoBase plugin and archive tiers excluded, commented-out lines excluded) that calls
`.recur(` and `.delay(` through the main wrapper (`TickAPI.` or its `TimeManagerAPI` alias).
The survey is static, so it cannot see a callback that reaches a `delay` through a method in
another module — the 12 same-instance files are the ones that CAN be affected; the 7 mixed-
instance files are listed so a reviewer can confirm the arms really cross instances. 19 files
in total (the design's bound is <= 26).

Same instance (recur and delay on the SAME `Tick`/`Tickh`/`Tickr` — affected if the delay is
armed from inside the recur callback):

| File | recur (instance:line) | delay (instance:line) |
|---|---|---|
| `RS/SM/RepActionManager/SimAnim/FxPackage/FxPackage.luau` | Tickh:1049 | Tickh:513,681,742,836,939,1009,1089 (via `TimeManagerAPI`; `1049 → _processAllContextData → 681/742` is the known dynamic nest) |
| `SSS/Modules/EventSpawnerClass.luau` | Tick:406 (`WaveClock`) | Tick:346 (`Release()` spawn stagger `0.25*i`); Tickh:243 |
| `SSS/Modules/Spawner.luau` | Tick:434,456 | Tick:336; Tickh:129 |
| `SSS/Modules/SpawnManager/EntitySurgeConductor.luau` | Tickh:301 | Tickh:222 |
| `RS/SM/GroupClass/GroupClass.luau` | Tick:102,471,1004; Tickh:109,541 | Tick:320; Tickh:900 |
| `RS/SM/CustomCharacterData/CoreCharacterSheet/CharacterSheet/CharacterSheet.luau` | Tickh:803; Tick:971 | Tickh:68,77,101,121,899 |
| `RS/SM/CustomCharacterData/CoreCharacterSheet/CharacterSheet/CharacterSheetIncludes/CharacterSheet_Animation/CharacterSheet_Animation.luau` | Tickr:312 | Tickr:218 (footstep clocks) |
| `RS/SM/CustomCharacterData/CoreCharacterSheet/CharacterSheet/CharacterSheetIncludes/CharacterSheet_StatAdjustments.luau` | Tick:570 | Tick:691 |
| `RF/LO/Modules/UISystemBooter/QuestHudManager.luau` | Tickh:297 | Tickh:412,604 |
| `RF/LO/Init_Scripts/SetupCliffAreaScreenSize_AndANIMATION/SetupCliffAreaScreenSize_AndANIMATION.luau` | Tick:86 (`FPS = 1/30`) | Tick:103 |
| `RF/Loading/LoadingScreen/AnimatedFlipLoadingWheel/AnimatedFlipLoadingWheel.client.luau` | Tick:119 (`FPS = 1/24`) | Tick:100,162 |
| `RS/UI/LoadingScreenBuffer/AnimatedFlipLoadingWheel/AnimatedFlipLoadingWheel.client.luau` | Tick:119 | Tick:100,162 |

Mixed instances (recur on one, delay on another — unaffected unless a callback also arms on its
own instance through another module):

| File | recur | delay |
|---|---|---|
| `RF/LO/Modules/InputMouseManager.luau` | Tick:361,430 | Tickh:425 (`425 → 430` is the known cross-scheduler nest: a Heartbeat callback arms a Stepped recur) |
| `RF/LO/Modules/AbilityClass/AbilityClass_Utility.luau` | Tickr:287 | Tick:305 |
| `RF/LO/Modules/HitFx/HitFlashObject.luau` | Tickr:126 | Tickh:176 |
| `RF/LO/Init_Scripts/LocalInitilizer/LocalGeneralConfig/UI_Initilizer/UI_Initilizer.luau` | Tick:45 | Tickh:232 |
| `RF/Loading/LoadingScreen/AnimatedFlipLoadingWheel/AnimatingLoadingWheel.client.luau` | Tickh:51 | Tick:101 |
| `RS/UI/LoadingScreenBuffer/AnimatedFlipLoadingWheel/AnimatingLoadingWheel.client.luau` | Tickh:51 | Tick:101 |
| `SSS/Modules/BaseOverDungeonClass/TowerOfTest/TowerOfTest.luau` | Tickh:98 | Tick:76 |

The same rule applies to a `recur` armed inside a recurring callback (`GroupClass`,
`Spawner`, `InputMouseManager` each hold several recurs on one instance): its first fire is one
parent period earlier than before, its period thereafter is unchanged.

Path abbreviations as in `research/callsites.md`: `RF` ReplicatedFirst, `RF/LO`
ReplicatedFirst/LocalOnly, `RS/SM` ReplicatedStorage/SharedModules, `SSS` ServerScriptService,
`SG` StarterGui.

## 5. Prior build (TickAPIOptimize 2.0.0) → 3.0.0 rename table (§7.4)

The prior rebuild never shipped; its names map as follows. Lowercase prior spellings are
deliberately absent (the alias set is closed): `h:pause()` hits the dictionary miss →
`attempt to call a nil value`, so migrate by grep.

| Prior 2.0.0 | New 3.0.0 |
|---|---|
| `TickAPI.new(variant)` | `Veron.new(cfg)` (also `Veron:new(cfg)`, `Veron(cfg)`) |
| `h:pause()` / `h:resume()` / `h:getRemaining()` / `h:setPeriod()` / `h:getState()` / `h:isActive()` / `h:complete()` / `h:fireNow()` | `h:Pause()` / `h:Resume()` / `h:GetRemaining()` / `h:SetPeriod()` / `h:GetState()` / `h:IsActive()` / `h:Complete()` / `h:CompleteNow()` |
| `group:pause` / `group:resume` / `group:getRemaining` (group-level) | `s:Pause()` / `s:Resume()` / `h:GetRemaining()` (or `s:GetRemaining(h)`) |
| `group:now` / `group:setTimeScale` / `group:getTimeScale` / `group:clear` / `group:getStats` | `s:Now()` / `s:SetTimeScale()` / `s:GetTimeScale()` / `s:Clear()` / `s:GetStats()` |
| cfg `name` / `timeScale` / `maxCatchUpPerFrame` / `onError` | `Name` / `TimeScale` / `MaxCatchUp` / `OnError` |
| stats `examined` / `stale` / `live` | dropped — `Pending` / `Paused` / `HeapSize` replace them; no stale entries exist in an indexed heap |
| lowercase prior spellings (`h:pause()`, …) | deliberately absent (Q-J7) — grep and rename |

Legacy (rxi-style) names that stay: instance `update/delay/recur/remove/getClocks`,
`Remove`, `ForceEventComplete`; handle `stop/reset/adjust/after`, `Destroy`.

## 6. Out of scope (Q-J13 / Q-J14) — listed so nobody looks for them here

| Item | Why it is not part of this migration |
|---|---|
| The RoBase plugin's wrapper copy (`PluginGuiService.CoreHolder.Core.TickAPI`, 42 files under `SS/RoBase/*`) | different require root; the plugin keeps its own legacy copy (Q-J13) |
| `SyncedTimerClass` (16 files) and keyed timers | convergence deferred (Q-J14); `ForceEventComplete` on Veron is the handle verb only |
| `DashStacks:22` — passes the *result* of `CharacterSheet:StatChange("DashStacks", 1)` (nil) as `func` | a live caller bug in game code, not a scheduler concern; SyncedTimer never validated callability |
| `UpdateAction_ActionServerHitScan:113` — `AdjustTime(FXTimerId, …)` on the wait event's own id inside its callback (adjusts itself, not the FX event from `:89`) | a live caller bug in game code (S-15); fixing callers is a game change |
| `CharacterSheet:772` — `SafeStopClock` on an Instance (`AuraLockClone`) | legacy raises `stop is not a valid member`; unchanged — a duck-typed guard would live in the wrapper (§13 JF-18) |
| TickAPI's own wrapper: `SafeStopClock`, `GetAfterNotTouched` / `AfterNotTouchedClass`, the RunService connections, `Tick/Tickh/Tickr` construction, memory categories, the boot watchdog | TickAPI keeps all of them unchanged (§6) |

## 7. Grep recipes for M2

```
rg -n "\.recur\(" --type lua                       # every recurring site; check each for nested arms (DV-7)
rg -n ":remove\(" --type lua                       # colon-called instance remove — now really removes (DV-3)
rg -n "adjust\(|:reset\(" --type lua               # retime sites; terminal handles are silent no-ops (DV-5)
rg -n "Tickr\.recur|recur\(.*0\.0[0-9]" --type lua # tiny periods; decide capped vs Recur(fn, p, true) (DV-10)
```

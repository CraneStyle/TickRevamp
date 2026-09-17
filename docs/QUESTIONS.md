# TickRevamp — Jake's decisions (verbatim answers, 2026-09-16)

The questions were asked after the research + design waves; Jake answered them the same day. These
answers are authoritative and are applied in `docs/DESIGN.md` §8 (which also carries the rationale
and the alternatives that were rejected). The vault note `Projects/TickRevamp/TickRevamp.md` holds the
"why" behind each pick.

| # | Jake's answer (quoted) | Effect on the build |
|---|---|---|
| A1 | "Correct" | `Complete()` deferred to the next update; `CompleteNow()` synchronous. |
| A2 | "add a new argument at the end, default false … cap at 8, but if set to true then it is uncapped … so damage over time is not lost" | `recur(fn, period, uncapped)`; `false`/nil = at most 8 owed fires per update, the rest dropped on-grid; `true` = every owed tick fires (a huge backlog is spread across updates by the valve; nothing is lost). |
| A3 | "we are fixing this, but just warning that some things may go off faster now" | Timers created inside a recurring callback are measured from the firing due (legacy waited one extra parent period); `LegacyRecurBase = true` per instance reproduces the old lateness; MIGRATION.md warns and lists the ≤ 26 files. The lateness is a fixed per-nested-timer offset, not cumulative drift. |
| A4 | "Follow recommendation default off, but adding a config of maxDT" | `MaxDt` config per instance, default `false`; when set, `update(dt)` clamps dt and counts `ClampedDt`. |
| A5 | "Yes" | PascalCase canonical members + frozen lowercase legacy aliases (`update/delay/recur/remove/getClocks`; `stop/reset/adjust/after`, `Destroy`). |
| A6 | **"You do not need to do the implementation of TICKAPI i only want the implementation for TICK you do not need to think outside of that."** | Scope = the `Veron` class + `VeronEvent` handle only. Dropped: registry, RunService hook binding, watchdog, Diagnostics, SafeStopClock, AfterNotTouched, keyed timers, MemoryCategory. TickAPI keeps the wiring: `TickAPI.Tick = Veron.new{ Name = "Tick" }` + `RunService.Stepped:Connect(function(_, dt) TickAPI.Tick.update(dt) end)`. The `Tickr`-on-server and default-hook questions became moot. |
| A7 | "reject pause should be used" | `+inf` and NaN delays rejected at creation. |
| A9 | "The new build i would like to call 'Veron'" | Class `Veron` (BaseClass name verified unused in HeroicSouls), handle `VeronEvent`, files `build/src/Veron/{init,VeronEvent/init,Env/init}.luau`, error prefixes `Veron '<Name>': ` / `VeronEvent: `. |
| A10 | "integrate … reset after touched … recur till touched, or a recur switch … consider if it is more costly to destroy and recreate timers or … reset and reuse" | Handle gains `Toggle()` (paused ↔ running) and `Restart()` (the one explicit re-arm of a Fired handle; an explicit `Stop` on a Fired handle finalizes it; Stopped is final). Patterns: reset-after-touched = `Delay` + `Reset()`; recur-till-touched = `Recur` + `Pause()`; switch = `Recur` + `Toggle()`. API.md carries the reuse rule (a new handle = one 576 B table; reuse = 0 bytes). |
| B1–B5 | not contradicted | SyncedTimerClass convergence later; RoBase plugin copies out of scope; the two live caller bugs (`PrimaryCardControler.luau:124,141` colon remove; `DashStacks.luau:22` call result as fn) are listed, not edited; the patched BaseClass test copy is fine; dead wrapper copies deleted at migration. |

Defaults Jake did not contest (one-line flags, documented in DESIGN.md §2.1/§8): `Remove(non-handle)` → silent
`false` (`Strict = true` errors; a foreign handle always errors); runaway valve 1000 dispatches per pass then
warn once and defer; re-entrant `update` runs a real nested pass capped at depth 8, counted, warned once;
manual `update` is the only way a Veron is driven; no handle pooling; callback errors are caught, warned
(rate-limited), and never abort the frame.

# HANDOFF — TickRevamp (product name: Veron)

Cold-start cursor. Read this, then `CLAUDE.md`, then `docs/DESIGN.md` (the only spec; 979 lines).
Where things live: C:/Users/Faded/Documents/Obsidian_AgentProjects/AgentProjects/Projects/TickRevamp/TickRevamp - Map.md

## What this is

Jake (2026-09-16) asked for a full review + refactor of HeroicSouls' timer core `Tick` (rxi-derived,
`ReplicatedStorage.SharedModules.TickAPI.Tick`). After research and design he narrowed scope to
**one class, `Veron`, plus its handle `VeronEvent`** — his `TickAPI` wrapper keeps the RunService wiring,
`SafeStopClock` and `AfterNotTouched`, and will do `TickAPI.Tick = Veron.new{ Name = "Tick" }` then
`TickAPI.Tick.update(dt)` as today. Every decision Jake made is in `docs/QUESTIONS.md` (top table, verbatim)
and applied in `docs/DESIGN.md` §8.

## State (2026-09-16)

| Stage | Status | Where |
|---|---|---|
| Wave 1 research (8 reports) + findings ledger (134 rows, flipped post-build: 71 fixed, 27 n/a scope, 36 n/a evidence) | done | `research/*.md`, `docs/FINDINGS.md` (`## Pins`, `## FLAGS`) |
| Design: panel → synthesis → refute → rescope (Veron only) → rename + `Toggle`/`Restart` | **final** | `docs/DESIGN.md` (spec; §8 = Jake's decisions) |
| **Build** (WP1–WP9), run `wf_3c86bda5-453` | done — built green; **bench 21/0** | `build/src/Veron/`, `build/tests/`, `build/bench/`, `build/docs/`, `build/BUILD-REPORT.md` |
| Wave 4 adversarial review (correctness / memory-heap / API-fit) | done — **CLEAN**, 0 code defects; 1 doc fix, 1 by-design note | in HISTORY |
| Studio verification in the real Roblox VM | done — **Play battery 51/51** (see below) | `build/studio/VeronRun.server.luau` |
| Head-to-head vs legacy Tick, real Roblox | done — Veron wins real-game cases 5x–2400x | `build/studio/ComparePerf.server.luau`; numbers in vault |
| LuaCraneStyle comment pass, all 3 source files | done — 111 `--[[ ]]` blocks, code byte-identical | `build/src/Veron/*` |
| **BaseClass dropped → plain typed modules** | done 2026-09-16 — `grep BaseClass build/src` empty | `build/src/Veron/*` |
| Full battery re-run (2026-09-17) | done — Lune 276/0. Bench had 3 stale BaseClass-era refs (never re-run after the drop); fixed both bench files + swept doc API names. See HISTORY 2026-09-17 | `build/bench/*`, `build/docs/API.md`, `build/BUILD-{REPORT,NOTES}.md` |
| **Release-readiness sweep (2026-09-17): last BaseClass traces + vestigial code removed** | done — bench P11 (the `Class:new` comparator) cut from both bench files; `build/vendor/BaseClass.luau` **deleted**; `SharedModules.BaseClass` dropped from the Rojo project; `spec/baseclass/baseclass_spec` **renamed** `spec/class/class_spec`; stale VeronRun comment + docs corrected. **Current suite: Lune 276/0, bench 20/0.** `grep -ri baseclass` over executable/build code (outside `reference/`, `research/`) is empty. Studio-side re-run of `studio_bench`/VeronRun/Rojo still pending (see below). | `build/bench/*`, `veron-studio.project.json`, `build/studio/VeronRun.server.luau`, `build/tests/spec/class/*`, docs |
| Real-Roblox battery + head-to-head (2026-09-17), driven via Studio MCP | done — Play: **VeronRun 51/51 features** + ComparePerf fresh (idle 2351×, cancel 15.6×, churn 4.2×, varied 4.8×; legacy wins only the 2 all-fire cases). Live source verified 0-BaseClass. Chart: https://claude.ai/code/artifact/9d6b05b6-22fe-411d-9e95-fc0da2c0090b | `build/studio/*` |
| BaseClass doc sweep + install/wire-up docs (2026-09-17) | done — API.md drops "built with BaseClass" claims, adds a top "Wire it up: register and drive" quickstart (RunService.Heartbeat → `Update(dt)`); BUILD-NOTES supersession-marked. (The vendor + bench P11 comparator that remained after this pass were removed in the release-readiness sweep row above.) | `build/docs/API.md`, `build/BUILD-NOTES.md` |
| Exported types for Studio IntelliSense (`export type Veron`/`VeronEvent`, `.new` returns typed) | **PENDING** — do next, on the plain-module base | — |

## BaseClass removed (done 2026-09-16)

Veron no longer depends on BaseClass/middleclass (Jake's call: it used no OOP feature of it and forced
`--!nonstrict`). `Veron` and `VeronEvent` are plain modules where the module table is its own instance
metatable (`Module.__index = Module`), with a `.new` factory and a `__call` for the `Veron(cfg)` form. The
observable surface is preserved (`class`/`type`/`isInstanceOf`, refused direct construction, colon guard,
aliases). `Veron.new` uses a forward-declared `_construct` local (not `local function`) so the optimizer does
not inline it and drop the frame the config-error levels count on. Env is five keys now (no `BaseClass`).
Tests: oracle wraps `VeronEvent` directly; `class_spec` (renamed from `baseclass_spec` on 2026-09-17) /
`env_spec` rewritten (that is the 278 → 276 drop: two vendored-BaseClass file tests removed).
`build/vendor/BaseClass.luau` was deleted in the 2026-09-17 release-readiness sweep (its last consumer, bench
P11, went with it). Verified in both runtimes. Rationale + typing plan in the vault note; still `--!nonstrict`
(types are the next step).

## Studio verification (2026-09-16)

Veron ran under the **real Roblox VM** and passed **51/51** on the current plain-module build (50/50 on the
earlier BaseClass build; the two extra checks confirm the handle carries the `VeronEvent` metatable and the
scheduler carries `Veron`). Synced into place `TickAPI_Refactor` via Rojo
(`veron-studio.project.json` + `rojo serve`), the Play battery `build/studio/VeronRun.server.luau` exercised the
real require branches (`Env.IsRoblox == true`), dot+colon entry, aliases, capped+uncapped catch-up, re-entrancy,
error isolation, chaining, foreign-handle rejection, the state machine, and heap order. Bench (interpreted Play,
10k): arm 390 ns/op, fire 425 ns/dispatch, **200 idle updates over 10k armed = 0 KB GC**. Native (`--!native`)
and the Studio Script-Profiler bench remain a manual step. Re-run: `rojo serve veron-studio.project.json`,
connect the Rojo plugin, press Play, read the console for `[VERONTEST]` / `[VERONCMP]`.

## What is left (needs Jake / Studio)

1. **Add the exported types** (`export type Veron`/`VeronEvent`, `.new` returns typed) so callers get Studio
   IntelliSense; the dot form is the blessed one. Then the internals can go `--!strict`. Refresh the map after.
2. **Three design-text corrections for Jake** (BUILD-REPORT §6.3): valve-latch wording (the built latch is
   correct), handle size 576 B → 560 B measured, DV-7 example line 345 → 346. NB: API.md still quotes 576 B on
   purpose — `docs_spec` pins that string, so the 576→560 change must update the design + `docs_spec` together.
3. **Wire it up.** `TickAPI.Tick = Veron.new{ Name = "Tick" }` + a RunService hook calling `Tick.Update(dt)`;
   the copy-pasteable pattern is now documented in `build/docs/API.md` → "Wire it up: register and drive".
   Migrate per `build/docs/MIGRATION.md` (recur-nested files fire one parent-period earlier; `LegacyRecurBase =
   true` per instance reproduces the old timing). Jake will do the integration; watch for fallout together.

## Deliverables for Jake

`build/docs/API.md`, `build/docs/MIGRATION.md`, `build/BUILD-REPORT.md` (with `build/bench/BENCH.md`).

## Non-obvious facts a cold agent needs

- Lune requires are relative and extension-less; inside an `init.luau`, `./` is the directory CONTAINING the
  module directory (details + concrete paths: `CLAUDE.md`, `docs/DESIGN.md` §1).
- The legacy oracle for parity tests is `reference/lune/Tick.luau` (`Tick.group()`), verified loading under Lune.
- The verified indexed-heap prototype to transcribe is `research/scratch/algos/invariants.luau`.
- The prior rebuild (`C:/Users/Faded/Documents/ClaudeProjects/RbxProjects/STUDIO_TASKS/TickAPIOptimize/build`, 80
  Lune tests green) is read-only input; it has two infinite-loop
  bugs (`research/prior-build-review.md` B-01/B-02) — never copy its dispatch loop.

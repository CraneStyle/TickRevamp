# TickRevamp

Where things live: C:/Users/Faded/Documents/Obsidian_AgentProjects/AgentProjects/Projects/TickRevamp/TickRevamp - Map.md

Workspace for the full review + refactor of HeroicSouls' timer core `Tick` into **Veron**: an
instance-based, plain-Luau, due-time-ordered scheduler (class `Veron`, handle `VeronEvent`).
Built on BaseClass first, then that dependency was dropped 2026-09-16 (Veron used none of its OOP);
the modules are now plain typed modules with a hand-rolled metatable and a `.new` factory.
SCOPE (Jake, 2026-09-16): the `Veron` class and its handle ONLY. The `TickAPI` wrapper (RunService wiring,
SafeStopClock, AfterNotTouched) stays Jake's and is out of scope; it will do `TickAPI.Tick = Veron.new{ Name = "Tick" }`. Nothing here ships to a live game
directly; the deliverable is `build/` (source + tests + bench + docs) plus `docs/` (design, findings).
Successor to the `TickAPIOptimize` workspace (`C:/Users/Faded/Documents/ClaudeProjects/RbxProjects/STUDIO_TASKS/TickAPIOptimize`), whose certified build is a primary input.

## Layout

| Path | Role | Writable |
|---|---|---|
| `reference/` | Read-only evidence snapshots (legacy Tick family, SyncedTimerClass, MinHeap, BaseClass + mixins, rxi/tick). Hashes in `reference/SOURCES.md`. Never `require` from `build/`. | **no** |
| `research/` | Wave-1 research reports (one per topic) + `research/scratch/` throwaway experiments. | yes |
| `docs/` | `DESIGN.md` (the decided design), `FINDINGS.md`, `QUESTIONS.md`, API + migration docs. | yes |
| `build/src/Veron/` | The new modules: `init.luau` (class `Veron`), `VeronEvent/init.luau`, `Env/init.luau`. Every module runs unchanged under Lune and Roblox. No BaseClass, no external dependency. | yes |
| `build/tests/support/` | Test helpers (oracle, legacy adapter, generator); no `_spec` suffix so the runner skips them. | yes |
| `build/tests/run.luau` / `run_one.luau` | Whole suite: `lune run build/tests/run.luau` (discovers `build/tests/spec/**/*_spec.luau`). One spec: `lune run build/tests/run_one.luau spec/<area>/<name>_spec`. Both from the workspace root. | rarely |
| `plans/veron-build.workflow.js` | The build orchestration script (Workflow tool): WP1–WP9 of `docs/DESIGN.md` §12. Launch with `Workflow({ scriptPath })`. | rarely |
| `build/bench/` | Benchmarks (`lune run build/bench/bench.luau`). | yes |
| `veron-studio.project.json` + `build/studio/VeronRun.server.luau` | Rojo project + Play-mode battery to run the REAL Veron in Roblox Studio: `rojo serve veron-studio.project.json`, connect the Rojo plugin, press Play, read console for `[VERONTEST]` (last passed 51/51). The Rojo tree syncs only `Veron` + `LegacyTick` (no `SharedModules.BaseClass` — BaseClass is gone). The edit-thread `execute_luau` is capability-sandboxed (no Network, no `require` of user modules) — Rojo is the byte-perfect channel. | yes |
| `HANDOFF.md` / `HISTORY.md` | Cold-start cursor / dated changelog. | yes |

## Toolchain

- Lune `0.10.5` (pinned in `aftman.toml`; absolute fallback
  `C:/Users/Faded/.aftman/tool-storage/lune-org/lune/0.10.5/lune.exe`).
- Spec shape: `return function(t) t.test("name", function() t.eq(a, b) end) end`; helpers `t.eq`,
  `t.near(a, b, tol?)`, `t.throws(fn, pattern?)`. File names end in `_spec.luau` with no other dot.
- Lune require rules (verified on 0.10.5): string paths, no extension; `X/init.luau` is required as
  `"…/X"`; inside an `init.luau`, `./` is the directory that CONTAINS the module directory; `game` is nil.
  Modules resolve neighbours through the `Env` seam (`Env.Load(name)`), branching on `typeof(script) == "Instance"`;
  the concrete require paths for every file are in `docs/DESIGN.md` §1.

## Hard rules

- Never modify `C:/Users/Faded/Documents/GitHub/HeroicSouls-BackUp`, any live HeroicSouls place, the
  `TickAPIOptimize` workspace (`C:/Users/Faded/Documents/ClaudeProjects/RbxProjects/STUDIO_TASKS/TickAPIOptimize`),
  or `reference/`.
- Git operations are permitted for the GitHub publication of this repo (`CraneStyle/TickRevamp`); this
  folder is now the `C:/Users/Faded/Documents/GitHub/TickRevamp` git repository.
- Callbacks are untrusted: the scheduler must survive a callback that errors, re-enters, or mutates timers.
- Style: the house guide (`C:/Users/Faded/Documents/GitHub/LuaCraneStyle/wiki`) — tabs, double quotes,
  PascalCase public members, camelCase locals, `_camelCase` file-local helpers, `_PascalCase` private
  instance fields, `--[[ ]]` purpose blocks, 80-col target / 120 hard. Codebase practice wins on conflict:
  the legacy lowercase call surface (`delay/recur/stop/after/adjust/reset`) is kept for compatibility.
- Max 10 agents live at once when orchestrating (user rule).

## Working with Roblox Studio (MCP)

This project uses the `Roblox_Studio` MCP server — a **live Roblox Studio connection**. For any
task that touches Roblox Studio or Luau, invoke the **`roblox-studio`** skill
(`.claude/skills/roblox-studio/`); it is the playbook for this project's Studio workflow.

Two skill systems — keep them straight:

- **Claude Code skills** → the `Skill` tool (e.g. `roblox-studio`).
- **Roblox `rbx-*` skills** → `mcp__Roblox_Studio__skill(skill_name="rbx-…")`. Retrieve the
  relevant one **before** that kind of work, then follow it:
  - `rbx-unit-test` — Luau unit tests
  - `rbx-perf-profiling` — MicroProfiler/LibMP CPU·GPU·memory
  - `rbx-scene-analysis` — SceneAnalysisService memory/leak/instance analysis
  - `rbx-docs-search` — Engine API + creator-guide lookups
  - `rbx-device-simulator-lua` — device/UI testing
  - `rbx-create-skill` — author a Studio-side assistant skill

Standing rules: Play mode is required for tests/profiling/scene analysis; `execute_luau` returns
values (it does not print); reuse Studio instances by name; never edit any path marked read-only.

`execute_luau` runs in **its own Luau VM with its own module cache**. `require()`ing a stateful
singleton there gives you a fresh shadow instance — it reads empty (so you misdiagnose a healthy
system) and its initializer's event/Remote connections can corrupt the live session. Require for
computation, never for introspection; restart Play if you did it by accident.

If Lune (a standalone Luau runtime) is pinned in this project's `aftman.toml`, use
`lune run <script>.luau` for Luau execution that doesn't need a live Studio connection — see the
`roblox-studio` skill for when to prefer it over Studio's `rbx-unit-test`.

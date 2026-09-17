---
name: roblox-studio
description: >-
  Playbook for working in this project through a LIVE Roblox Studio MCP
  connection (the `Roblox_Studio` server). Invoke for ANY task that touches
  Roblox Studio or Luau — and specifically whenever the work needs Roblox unit
  testing, performance profiling, scene/memory/leak analysis, Roblox Engine API
  docs, or device/UI testing. Explains the six Roblox `rbx-*` skills (retrieved
  via the `mcp__Roblox_Studio__skill` tool, NOT the `Skill` tool) and when to
  reach for each, plus the MCP tool catalog and standing rules.
---

# Roblox Studio Workflow

This project runs against a **live Roblox Studio instance** through the `Roblox_Studio`
MCP server. This skill makes you aware of Roblox's own authored skills and the MCP
toolset, and how to apply them to this project's work.

> Tailor this file to your project: fill in the "How to apply these here" section below
> with your modules, performance targets, and read-only paths.

## Two skill systems — do not confuse them

| System | How to invoke | What it is |
| --- | --- | --- |
| **Claude Code skills** (this file, `.claude/skills/…`) | the `Skill` tool | Local project/user skills. |
| **Roblox `rbx-*` skills** | `mcp__Roblox_Studio__skill(skill_name="rbx-…")` | Roblox-authored reference playbooks. Retrieving one **returns detailed instructions + exact Luau/API code** you then follow. They are NOT `Skill`-tool skills and will not appear in the `Skill` list. |

**The rule:** before doing Studio work in a domain covered by an `rbx-*` skill, **retrieve that
skill first and follow it.** They carry exact APIs, code, harness layouts, and gotchas you
should not improvise. Retrieving a skill is cheap; a wrong hand-rolled harness is not.

## The six Roblox skills — when to reach for each

Retrieve with `mcp__Roblox_Studio__skill(skill_name=<name>)`.

| skill_name | Reach for it when | What it gives you |
| --- | --- | --- |
| **`rbx-unit-test`** | Writing/running/debugging Luau unit tests for ModuleScripts. | Framework detection (Jest-Lua / TestEZ) or a built-in `ServerStorage.UnitTest` harness; contract-first test design; Play-mode run + console-read protocol. |
| **`rbx-perf-profiling`** | Investigating CPU/GPU bottlenecks, frame-time spikes, or per-subsystem memory. | LibMP / MicroProfiler programmatic API; capturing frames; `debug.profilebegin/profileend` scopes; reading raw timings. |
| **`rbx-scene-analysis`** | Checking scene health, draw calls/triangles, script VM memory, or hunting leaks/unparented instances. | `SceneAnalysisService` queries (Play-mode) + `/scene-health`, `/optimize-memory`, `/fix-leaks` workflows. |
| **`rbx-docs-search`** | You need accurate Engine API details or how-to guidance — CFrame/Vector3/Region3, orientation math, `Actor`/parallel Luau, `task`, etc. | `http_get` against `create.roblox.com/docs/…` as clean markdown, with a `query` filter to save context. |
| **`rbx-device-simulator-lua`** | Testing UI across device form factors/orientations. | `StudioDeviceSimulatorService` control + `screen_capture` verification. |
| **`rbx-create-skill`** | The user wants to persist a reusable **Studio-side** assistant skill (not a Claude Code skill). | `create_skill` / `edit_skill` flow. Names must NOT start with `rbx-`. |

## How to apply these here

This workspace builds **Veron** — a timer/scheduler ModuleScript (`build/src/Veron/{init,VeronEvent/init,Env/init}.luau`,
class `Veron`, handle `VeronEvent`) over an indexed min-heap. It is plain typed Luau with no external
dependency (the BaseClass/middleclass dependency was dropped 2026-09-16). The
deliverable is `build/` (source + tests + bench + docs). The `TickAPI` wrapper that will host it
(`TickAPI.Tick = Veron.new{ Name = "Tick" }` + RunService wiring) is out of scope and stays Jake's.

- **Primary test path is Lune, not Studio.** The suite is 20 spec files under `build/tests/spec/`,
  run headless with `lune run build/tests/run.luau` (one spec: `lune run build/tests/run_one.luau
  spec/<area>/<name>_spec`). Veron has no Roblox-service dependency, so Lune is the fast gate — use
  it first. Reach for `rbx-unit-test` only to confirm behavior under the real Roblox VM.
- **Veron is a stateless class factory** (`return VeronClass`), NOT a singleton — the `require()`
  trap below does not bite: requiring it in `execute_luau` for computation is safe. State lives in
  each `Veron.new{}` instance you create, not in the module.
- **Running Veron in Studio:** the `execute_luau` edit thread is sandboxed — it CANNOT `require`
  user ModuleScripts, reparent scripts, or use the Network capability (HTTP). To exercise the real
  modules under Roblox, run a **Script in Play mode** (it has full capabilities), or use `loadstring`
  (which IS available in the edit thread) on source read from a ModuleScript's `.Source`. The Env
  seam (`Env/init.luau`) branches on `typeof(script) == "Instance"` but pulls in no external module
  (BaseClass is gone); it only decides how to `require` Veron's own siblings.
- **"Make it fast" / stress** → `rbx-perf-profiling`. Veron is `--!native`; `--!native` is a no-op
  in Edit and only compiles under Play — the `build/bench/studio_bench.luau` header documents the
  Script Profiler step. Bench targets and the Lune numbers live in `build/bench/BENCH.md`.
- Memory footprint / leaks → `rbx-scene-analysis`; Engine API / datatypes → `rbx-docs-search`.

## Lune — running Luau outside Roblox Studio

This machine may have **Lune** (`lune-org/lune`), a standalone Luau runtime, available via
Aftman — check with `lune --version` from this project's root. If it errors with "no aftman.toml
files list this tool," Lune is installed globally but not pinned for this project: add an
`aftman.toml` in the project root (or a `[tools]` entry to an existing one) pinning
`lune = "lune-org/lune@<installed-version>"` (find the installed version under
`~/.aftman/tool-storage/lune-org/lune/`), then re-run `lune --version` to confirm. If Lune isn't
installed anywhere on the machine, this section doesn't apply — skip it.

Once available, use `lune run <script>.luau` to execute Luau **outside** of Roblox Studio — no
live Studio/MCP connection needed. Reach for it when:

- Sanity-checking pure Luau logic (algorithms, data transforms, ModuleScripts with no Roblox
  service dependencies) without opening/using Play mode in Studio.
- Quick, scriptable iteration — validating data files, prototyping a module's logic before
  wiring it into the game.
- CI-style or headless checks where Studio's MCP connection isn't required.

This **complements** `rbx-unit-test`, it doesn't replace it: `rbx-unit-test` is for tests that
need real Roblox services/instances and must run inside Studio's Play mode. Use Lune for logic
that has no such dependency — it's faster and doesn't need Studio open at all.

## `execute_luau` runs in its own VM — the `require()` trap

**`execute_luau` does not run inside the game's Luau VM. It has its own module cache.** So
`require(SomeModuleScript)` inside `execute_luau` returns a **brand-new instance** of that module,
never the one the running game is using.

For stateless modules this is harmless and useful — requiring a pure differ, serializer, or math
module and benchmarking it with `os.clock()` is a perfectly good measurement, because a fresh copy
behaves identically to the live one.

For a **stateful singleton** (managers, state stores, anything that returns `Class:new()` at the
bottom of the file) it is a trap with two distinct costs:

1. **You read the wrong state and draw the wrong conclusion.** The fresh instance starts empty, so
   you see `version = 0`, empty tables, flags in their initial position — and conclude the live
   system is broken or idle when it is actually running fine. The tell is a contradiction between
   two reads: e.g. a server-side require reporting an empty world while a client-side one reports
   real replicated data.
2. **You create a shadow instance that fights the real one.** The fresh instance runs its
   initializer, which typically connects `RunService` events, subscribes to mediator/event buses,
   and binds `RemoteEvent.OnServerEvent`. Those connections persist. A shadow manager can then
   answer real client requests with its own empty state and corrupt the live session.

**How to read real singleton state instead**, in order of preference:

- Read the side effects the singleton writes into the DataModel — Instances it creates, Attributes
  it sets, `Value` objects it flips. These are shared across VMs and safe.
- Have the project expose state deliberately (a debug Attribute, a `BindableFunction`, a gated
  debug hook) and read that.
- Observe the wire: values a client legitimately received through replication are real data, even
  if the object holding them is a shadow.
- If you must require the singleton, treat the result as a fresh instance, never as the live one —
  and **restart Play afterwards** (`start_stop_play` false then true) to clear the shadow's
  connections before doing anything else in that session.

Rule of thumb: **require for computation, never for introspection.** If the module returns an
instance rather than a table of pure functions, assume requiring it in `execute_luau` both lies to
you and contaminates the session.

## MCP tool catalog (`mcp__Roblox_Studio__…`)

- **Session / connection:** `list_roblox_studios`, `set_active_studio`, `get_studio_state`.
  If more than one Studio is open, call `list_roblox_studios` + `set_active_studio` **once at
  the start** so every later call targets the right place.
- **Read code & hierarchy:** `script_search` (by name), `script_grep` (by content),
  `script_read`, `search_game_tree`, `inspect_instance`.
- **Edit code:** `multi_edit`. Before creating any instance, check for an existing child of that
  name under the same parent and reuse it — never duplicate names.
- **Run & observe:** `execute_luau` (query state / run code — **return values, don't print**,
  except test harnesses which print by design), `start_stop_play` (Play is required for unit
  tests, profiling, and scene analysis), `get_console_output`, `wait_job_finished`.
- **Assets / visual / generation:** `insert_asset`, `search_asset`, `screen_capture`,
  `generate_mesh`, `generate_material`, `generate_procedural_model`, `store_image`,
  `upload_image`, `character_navigation`.
- **Input simulation:** `user_mouse_input`, `user_keyboard_input`.
- **Skills & delegation:** `skill` (retrieve an `rbx-*` skill), `subagent` (Studio-side worker).
- **Web:** `http_get` (docs fetch — used by `rbx-docs-search`).

## Standing gotchas (distilled from the Roblox skills)

- **Play mode is mandatory** for unit tests, MicroProfiler capture, and `SceneAnalysisService`.
  Start Play, run, read the console, then stop.
- **`execute_luau` returns, it doesn't print.** Return the value you want back. The unit-test
  runner is the deliberate exception.
- **`execute_luau` has its own module cache.** `require()` of a stateful singleton returns a fresh
  shadow instance, not the live one — it reads empty and its initializer's connections can corrupt
  the running session. See the `require()` trap section above.
- **Contract-first testing.** Never assert what the code currently returns; assert what it
  *should* return. Locking in current behavior silently canonizes bugs.
- **Reuse instances by name;** never create a second child of the same name under one parent.
- **Never edit any path the project marks READ-ONLY.** In this workspace, never modify: `reference/`
  (read-only evidence snapshots), `research/` (Wave-1 reports), `C:/Users/Faded/Documents/GitHub/HeroicSouls-BackUp`,
  the live HeroicSouls place, or the `TickAPIOptimize` workspace
  (`C:/Users/Faded/Documents/ClaudeProjects/RbxProjects/STUDIO_TASKS/TickAPIOptimize`). (`build/vendor/BaseClass.luau`
  no longer exists — it was deleted 2026-09-16/17 with the BaseClass dependency.)

## Session-start checklist for any Studio task

1. If several Studios are open, `list_roblox_studios` → `set_active_studio`.
2. Identify which domain(s) the task touches and **retrieve the matching `rbx-*` skill(s)** before acting.
3. Read the real scripts with `script_read` / `script_grep` before editing.
4. For anything runtime (tests, profiling, scene analysis): `start_stop_play` → act →
   `get_console_output` → stop.
5. Follow the retrieved skill's own workflow and reporting format.

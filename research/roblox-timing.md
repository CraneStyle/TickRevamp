# Roblox/Luau timing & scheduler prior-art research (TickRevamp)

Date: 2026-09-16. Author: research subagent. Every fact carries a URL; **UNVERIFIED** marks anything not confirmed from an official/primary source. Facts labelled **[MEASURED]** were observed in this session either in Roblox Studio (Edit mode, place "TickAPI_Refactor", placeId 83817010339105, Windows 11, single machine) or under Lune 0.10.5+709 (Luau interpreter, no `--!native`). Scratch scripts: `W/research/scratch/roblox-timing/bench.luau`, `luauver.luau`. Studio probes were read-only (event connections + `task.wait`, all disconnected); no Play/Run toggle was performed (two-key rule), so **server-DataModel behaviour was NOT measured**.

Legend for legacy names: `TickAPI.Tick` = Stepped-driven group, `TickAPI.Tickh` = Heartbeat-driven, `TickAPI.Tickr` = RenderStepped-driven (client only). Source: `W/reference/live/TickAPI.luau:38-57`.

---

## 1. RunService events (2025–2026)

### 1.1 Signatures (official reference, fetched 2026-09-16)
Source: https://create.roblox.com/docs/reference/engine/classes/RunService and the YAML behind it https://raw.githubusercontent.com/Roblox/creator-docs/main/content/en-us/reference/engine/classes/RunService.yaml

| Event | Callback args | Official parameter text |
|---|---|---|
| `PreRender` | `(deltaTimeRender: number)` | "elapsed time since previous frame". Client only: "can only be used in a LocalScript, in a ModuleScript required by a LocalScript, or in a Script with RunContext set to RunContext.Client". |
| `PreAnimation` | `(deltaTimeSim: number)` | "The time (in seconds) that the current frame has stepped animations." Summary: "Fires every frame, prior to the physics simulation but after rendering." |
| `PreSimulation` | `(deltaTimeSim: number)` | "The time (in seconds) that the current frame will step the physics simulation, not accounting for physics throttling." |
| `PostSimulation` | `(deltaTimeSim: number)` | "The time (in seconds) that the current frame has stepped the physics simulation, not accounting for physics throttling." |
| `Heartbeat` | `(deltaTime: number)` | "fires every frame, after the physics simulation has completed. The deltaTime argument indicates the time that has elapsed since the previous frame. This event is when most scripts run." |
| `Stepped` | `(time: number, deltaTime: number)` | `time` = "The duration (in seconds) that RunService has been running for." **deltaTime is the SECOND argument.** |
| `RenderStepped` | `(deltaTime: number)` | Client only, same as PreRender. |

### 1.2 Deprecation / aliases
- YAML deprecation messages (same URL): `Stepped` — "superseded by PreSimulation which should be used for new work"; `RenderStepped` — "superseded by PreRender which should be used for new work". **`Heartbeat` carries NO deprecation message in the current YAML**; `PostSimulation` is documented as a separate event that "Fires every frame, after the physics simulation has completed" with a *different* argument (`deltaTimeSim`, physics step time) than `Heartbeat` (`deltaTime`, wall elapsed).
- Community mapping (sjr04, 2021-02-22): "RunService.PreRender is the new RenderStepped. RunService.PreSimulation is the new Stepped. RunService.PostSimulation is the new Heartbeat"; PreAnimation "fires before RunService.PreSimulation but after RunService.PreRender". https://devforum.roblox.com/t/new-runservice-events/1064686/3
- Third-party API dump (robloxapi.github.io) lists Stepped/RenderStepped as non-deprecated in its metadata ("Marked non-deprecated as of v0.469") — the official docs disagree; treat the docs as authoritative. https://robloxapi.github.io/ref/class/RunService.html
- New in the server-authority model (Workspace.AuthorityMode = Server): `RunService.Rollback(time)` ("fires after rolling back the predicted state due to a misprediction, but before resimulation begins") and `RunService.Misprediction(time, instances, stats)`; "During that resimulation pass, RunService:BindToSimulation() callbacks and property-changed signals fire again for each replayed step." (same YAML). Whether PreSimulation/PostSimulation fire multiple times during resimulation: **UNVERIFIED** (not stated). `Enum.AuthorityMode`: `Server` (0) "Server authority with client side prediction and rollback enabled", `Automatic` (1) traditional distributed model. https://raw.githubusercontent.com/Roblox/creator-docs/main/content/en-us/reference/engine/enums/AuthorityMode.yaml

### 1.3 Order within a frame
Official ordered list of *resumption points* (Deferred-events guide): "input processing, RunService.PreRender, legacy script waiting (wait/spawn/delay), RunService.PreAnimation, RunService.PreSimulation, RunService.PostSimulation, task-based waiting, RunService.Heartbeat, and DataModel.BindToClose". https://create.roblox.com/docs/scripting/events/deferred

Task-scheduler diagram text nodes (SVG https://prod.docsiteassets.roblox.com/assets/optimization/task-scheduler/task-scheduler.svg, page https://create.roblox.com/docs/studio/microprofiler/task-scheduler), in reading order: Replication receive → PreAnimation event → Run scripts → Step Humanoid → PreSimulation event → Run scripts → Step simulation → PostSimulation event → Run scripts → **Resume delayed threads** → Heartbeat event → Run scripts → Replication send; and (Rendering group) Input processing → Run scripts → PreRender event → Run scripts → Asynchronous render. The diagram also uses "Heartbeat*" as a group label.

Practical frame order (client): Input → PreRender/RenderStepped → legacy wait resumption → PreAnimation → PreSimulation/Stepped → physics step → PostSimulation → **task.wait/task.delay/task.defer resumption** → Heartbeat → replication send → render. Server: same minus PreRender/render.

**[MEASURED, Studio Edit]** In one frame, the `RenderStepped` handler ran before the `PreRender` handler (observed order `RenderStepped > PreRender` every frame). Relative order of `PostSimulation` vs `Heartbeat` handlers could not be measured in Edit mode (PostSimulation does not fire there; see 1.5) — **UNVERIFIED**, assume PostSimulation first per the diagram.

### 1.4 Client vs server availability; "Tickh does not happen on the server?"
- `PreRender`/`RenderStepped`/`BindToRenderStep` are client-only (YAML text above; "As it is linked to the client's rendering process, BindToRenderStep() can only be called on the client" https://robloxapi.github.io/ref/class/RunService.html). `Heartbeat`, `Stepped`, `PreAnimation`, `PreSimulation`, `PostSimulation` are available on both.
- `Heartbeat` on the server: the 2018 docs once wrongly said "Heartbeat must only be used in LocalScripts"; corrected 2018-09-26 after a bug report demonstrating it "works server-side and has been doing so for years". https://devforum.roblox.com/t/heartbeat-documentation-incorrect-can-be-used-on-server/182643 Current docs: "This event is when most scripts run" (no client restriction).
- A community thread claims the server Heartbeat runs at 30 Hz (https://devforum.roblox.com/t/runserviceheartbeat-gives-wrong-delta-value/2333437); the official performance doc says "Server heartbeat is capped at 60 FPS for all games" — treat the 30 Hz claim as wrong. https://raw.githubusercontent.com/Roblox/creator-docs/main/content/en-us/performance-optimization/identify.md
- Legacy comment at `W/reference/live/TickAPI.luau:10` ("APPARENTLY Tickh does not happen on the server? thats weird"): no documented cause found. Candidate explanations, best first: (a) **Studio Edit mode / command-bar / plugin testing**: `Stepped`, `PreSimulation`, `PostSimulation`, `PreAnimation` do NOT fire in Edit mode while `Heartbeat` does **[MEASURED]** — so a Stepped-driven group looks dead and a Heartbeat-driven one alive, the *inverse* of the comment; if the author tested `Tick` vs `Tickh` in different modes, a swapped conclusion is plausible; (b) separate VMs: `TickAPI` is required independently by the server and each client, each `require` producing its own `Tick2` group; a `Tickh` timer created on one side is never updated by the other; (c) a server script that never required `TickAPI` (only clients did) — then neither group updates. Cause remains **UNVERIFIED**; server DataModel not probed in this session. Recommendation: the rebuild must log/assert at boot which hooks are connected in which context (`IsServer/IsClient/IsEdit`) so this can never be a mystery again.

### 1.5 Edit mode (plugins, command bar) **[MEASURED 2026-09-16, Studio Edit DataModel, 1.0 s window]**
`IsEdit=true IsRunning=false IsRunMode=false IsStudio=true IsServer=false IsClient=true`

| Event | fires/s | dt min–max |
|---|---|---|
| Heartbeat | 60 | 0.0149–0.0190 |
| PreRender | 15 | 0.0655–0.1351 |
| RenderStepped | 15 | 0.0655–0.1351 |
| PreAnimation / PreSimulation / PostSimulation / Stepped | **0** | – |

Also in Edit mode: `time()` = 0 and **does not advance**; `workspace.DistributedGameTime` = 0; `os.clock()` advances normally; `workspace:GetServerTimeNow()` works (≈ UTC). Consequence: a scheduler that uses `time()` or `Stepped` as its clock is frozen inside plugins/edit-mode tools; `Heartbeat` + `os.clock`/accumulated-dt is the only combination that runs everywhere.

### 1.6 BindToRenderStep priorities
"binds the function to PreRender"; "The lower this number, the sooner the custom function will be called. If two bindings have the same priority, the engine will randomly pick one to run first." Default engine bindings: Player Input (100), Camera Controls (200). `Enum.RenderPriority`: First=0, Input=100, Camera=200, Character=300, Last=2000 (use `.Value`). https://create.roblox.com/docs/reference/engine/enums/RenderPriority , RunService YAML above.

### 1.7 deltaTime during a hitch
- No clamp/max is documented anywhere for `Heartbeat.deltaTime` (searched docs + DevForum). **[MEASURED]** A deliberate 250 ms busy-loop inside Heartbeat handler #5 produced `dt[6] = 0.2517` on the next Heartbeat, then `0.0140`, `0.0171` — i.e. **wall-clock, unclamped, no catch-up frames**. A pending `task.wait(0.005)` returned `0.2516` (waits are elongated by the hitch; they resume at frame granularity).
- `PreSimulation/PostSimulation.deltaTimeSim` are physics-step time "not accounting for physics throttling" (YAML), so they can differ from wall dt when physics throttles; `PreAnimation.deltaTimeSim` is animation-step time. Do not mix `deltaTimeSim` with a wall-clock axis.
- Jitter: at a nominal 60 fps, per-event dt fluctuates (bug report: RenderStepped ±3 ms, Stepped ±4 ms, Heartbeat ±5 ms; staff acknowledged 2022-02-14; partially improved by July 2022). https://devforum.roblox.com/t/poorinconsistent-engine-timing-for-heartbeat-renderstepped-and-stepped-deltatimes/1663407
- Focus loss: the Windows-Store (UWP) client reported "a huge chunk" of dt in one frame after alt-tab, unlike the desktop app (2022-03-11, no staff reply). https://devforum.roblox.com/t/windows-roblox-app-having-weird-delta-time-behavior/1705699 Treat dt > ~0.25 s as a hitch, not as 15 elapsed periods.

### 1.8 Frame-rate caps
- "The default client frame rate cap is 60 FPS. However, users can raise their frame rate cap up to 240 FPS on Windows." "Server heartbeat is capped at 60 FPS for all games". https://raw.githubusercontent.com/Roblox/creator-docs/main/content/en-us/performance-optimization/identify.md
- Maximum Framerate setting (announced 2024-05-30): "Default (60 FPS, not your refresh rate), 60 FPS, 120 FPS, 144 FPS, and 240 FPS", Windows first, Mac "at a later date"; "task.wait can wait for less than 1/60th of a second, returning a smaller value"; developers must "always make sure that you are properly handling delta time values". https://devforum.roblox.com/t/introducing-the-maximum-framerate-setting/2995965
- 240 is the hard maximum (staff reply 2026-04-27 on a bug report; custom values like 9999 revert to -1). https://devforum.roblox.com/t/roblox-caps-fps-at-240-regardless-of-globalbasicsettings13xml-framerate-cap/4451048
- Implication: on a 240 fps client, Tickr/PreRender-driven timers update 4× as often as on the server; per-update cost matters 4× more and dt can be ~4 ms.

---

## 2. Clock sources

| Source | What it measures (official text) | Resolution / monotonic | Notes |
|---|---|---|---|
| `os.clock()` | "elapsed time in seconds since an arbitrary baseline with sub-microsecond precision ... adjustments to the system clock (such as by the user or NTP) do not cause time to jump forwards or backwards" — https://raw.githubusercontent.com/Roblox/creator-docs/main/content/en-us/reference/engine/libraries/os.yaml | Monotonic, sub-µs. Luau impl: `QueryPerformanceCounter` (Windows), `mach_absolute_time` (Apple), `clock_gettime(CLOCK_MONOTONIC)` (Linux/FreeBSD) — https://raw.githubusercontent.com/luau-lang/luau/master/VM/src/lperf.cpp | Baseline is per process: server and client values are unrelated (https://devforum.roblox.com/t/ostime-vs-tick-vs-osclock-vs/998888). **[MEASURED]** in Studio `os.clock()=55565.47` vs `elapsedTime()=55566.99` (same Studio-uptime baseline, ~1.5 s offset). Cost ≈ 31 ns/call in the Lune interpreter **[MEASURED]**. The DevForum claim that it is "CPU time" is wrong for Roblox/Luau (see lperf.cpp). |
| `time()` | "the amount of time, in seconds, that has elapsed since the current game instance started running. If Workspace.AuthorityMode is AuthorityMode.Server, this value is synchronized between client and server." — https://raw.githubusercontent.com/Roblox/creator-docs/main/content/en-us/reference/engine/globals/RobloxGlobals.yaml | Monotonic while running. **[MEASURED]** `time()==0` and frozen in Studio Edit mode. | Sleitnick's Timer defaults to `time` as its TimeFunction. Frozen in plugins; unrelated between server and client unless AuthorityMode.Server. |
| `tick()` | "how much time has elapsed, in seconds, since the Unix epoch, on the current local session's computer ... can be off by up to one second and returns inconsistent results across time zones and operating systems. Use os.time(), os.clock(), or time() instead. Also consider DateTime.UnixTimestamp and DateTime.UnixTimestampMillis." (same YAML) | Not monotonic (system clock). | **Not tagged Deprecated** in the docs as of today (only `elapsedTime`, `wait`, `delay`, `spawn` are); it is "discouraged". **[MEASURED]** `tick()` was 17,998 s (5 h, local UTC offset) behind `GetServerTimeNow()` on this machine — never compare `tick()` across machines. |
| `os.time()` | "seconds since the Unix epoch ... under current UTC time ... uses the device's local clock ... users can easily disable sync behavior and set the system time to anything they want; for synchronized time between client and server, use Workspace:GetServerTimeNow() instead. This function should be avoided in new work. Instead, use the DateTime API" (os.yaml) | Integer seconds; not monotonic. | Never for durations. |
| `workspace:GetServerTimeNow()` | "the client's best approximation of the current time on the server" as a Unix timestamp; "It is monotonic; its value will never decrease. It moves at the same rate as the local clock to within 0.6%"; "not suitable for things like timed rewards, as it is not secure" — https://raw.githubusercontent.com/Roblox/creator-docs/main/content/en-us/reference/engine/classes/Workspace.yaml | Monotonic, rate-bounded (0.994×–1.006×). Microsecond precision is claimed by community posts quoting the old devhub — **UNVERIFIED** in current docs. | The right axis for a cross-client-synced scheduler (SyncedTimer role). Works in Edit mode **[MEASURED]**. |
| `DateTime.now()` | Wall clock; `UnixTimestampMillis` integer ms. https://create.roblox.com/docs/reference/engine/datatypes/DateTime | Not monotonic (NTP jumps). | Display/logging only. |
| `workspace.DistributedGameTime` | "currently not 'Distributed' across the client and the server" — server uptime / client connection duration; "Developers should not rely on the above behavior" (Workspace.yaml) | – | Avoid. **[MEASURED]** 0 in Edit mode. |
| `Stepped` arg 1 (`time`) | "duration RunService has been running for" | – | Legacy `SyncedTimerServer` compares heap keys built from `WorldTime.Value` against this argument (`W/reference/live/SyncedTimerClass.luau:428-432` vs `:149,:157`) — two different axes unless WorldTime is derived from it; flag for the SyncedTimer review. |

Which to use: **virtual scheduler clock** = accumulate the hook's own `dt` (`now += dt`; never call a clock inside `update`) — deterministic, testable under Lune (no `time()`/`game` there), immune to Edit-mode freezes, and can be time-scaled/paused. **Externally-synced scheduler** = feed `GetServerTimeNow()` (or any monotonic external clock) through an `UpdateAt(absoluteNow)` entry point; the heap axis is then that clock. `os.clock()` is the right default *only* for a scheduler that must keep wall time between frames (e.g. measure real elapsed while the game hitched) — and even then read it once per update, not per timer.

---

## 3. `task` library semantics
Source YAML: https://raw.githubusercontent.com/Roblox/creator-docs/main/content/en-us/reference/engine/libraries/task.yaml (page https://create.roblox.com/docs/reference/engine/libraries/task)
- `task.spawn(f, ...)`: "Calls/resumes a function/coroutine immediately through the engine's scheduler"; "If the calling script is currently running in a serial execution phase, then the spawned function or thread is resumed in the current serial execution phase."
- `task.defer(f, ...)`: "defers it until the end of the current resume point within the current frame"; same phase as caller.
- `task.delay(t, f, ...)`: "schedules it to be called/resumed on the next Heartbeat after the given amount of time in seconds has elapsed" "without throttling"; "Providing a duration of zero (0) will guarantee that the function is called on the very next Heartbeat." Returns the thread.
- `task.wait(t)`: "Yields the current thread until the given duration (in seconds) has elapsed, then resumes the thread on the next Heartbeat step. The actual amount of time elapsed is returned." Default 0; "does not throttle and guarantees the resumption of the thread on the first Heartbeat that occurs when it is due."
- `task.cancel(thread)`: "Cancels a thread and closes it, preventing it from being resumed manually or by the engine's scheduler"; "the currently executing thread and threads that have resumed another coroutine may not be cancelled. If this is the case, an error will be generated."
- Legacy `wait()/delay()`: "minimum duration of 29 milliseconds, but this minimum may be higher depending on the target framerate" — deprecated in favour of `task.wait/task.delay` (RobloxGlobals.yaml).
- Resumption point: "Resume delayed threads" precedes "Heartbeat event" in the frame diagram (§1.3). **[MEASURED]** a `task.delay(0)` callback ran 0.035 ms *before* that frame's Heartbeat handlers; two `task.delay(0.05)` scheduled back-to-back fired in the same frame 2 µs apart in FIFO order (single observation; FIFO for equal due times is **not a documented contract**).
- Resolution: one frame. **[MEASURED]** `task.wait()` ×5 returned 0.0154–0.0177 s at 60 Hz; can be < 1/60 at 120–240 fps (announcement in §1.8).
- Deferred-event re-entrancy: "The current limit for this is 10" (nesting depth of deferred handlers). https://create.roblox.com/docs/scripting/events/deferred

### 3.1 Measured cost, engine `task.delay` vs Luau heap **[MEASURED, Studio Edit, N = 10,000, noop callbacks]**
| Operation | Cost |
|---|---|
| `task.delay(0.1, noop)` × 10k | 23.0 ms total ≈ **2.3 µs each** (second run 20.5 ms) |
| `task.cancel` × 10k | 2.0 ms ≈ 0.2 µs each |
| Luau binary-heap insert × 10k (two parallel arrays, sift-up) | 0.89 ms ≈ **89 ns each** (26× cheaper) |
| Frame in which 10k engine callbacks fired | worst dt 0.0231 s (≈ +6 ms) |
| Frame in which 10k heap entries popped+called from ONE Heartbeat connection | pop+call 5.1 ms total; worst dt 0.0247 s |
| 10k *separate* Heartbeat connections each polling `os.clock() >= due` | connect 9.8 ms, disconnect 9.3 ms, worst frame dt **0.0441 s** while connected (baseline max 0.018) |

Firing cost is dominated by the callbacks themselves either way; the wins of a heap are creation (26×), zero garbage per timer op (no coroutine object), and everything `task.delay` cannot do at all:
- no pause/resume/retime/`setPeriod`/`timeScale` — only cancel + recreate (≈2.5 µs + a new thread object each time);
- no per-frame budget/cap, no batching, no "due prefix" — every due thread resumes in the same resumption point;
- no central error policy: an error ends that thread and prints; a scheduler needs `xpcall` per callback with a configurable policy;
- no `getRemaining`, no `adjust` (ratio retime), no `reset`, no introspection (`getClocks`);
- no documented ordering between equal due times (observed FIFO only); no Lune parity (Lune's `task` is a re-implementation);
- cannot be driven by `Stepped`/`PreRender`/an external synced clock — `task.*` is Heartbeat-anchored only.

No DevForum benchmark of `task.delay` vs a custom scheduler at scale was found (**UNVERIFIED** beyond the measurement above); community advice ("one manager script with a single Heartbeat connection", e.g. https://robloxtaskscheduler.pages.dev/ — not official) matches the measurement of the 10k-connections case.

---

## 4. Luau performance facts for a hot scheduler
Primary: https://luau.org/performance (quotes), Roblox native-codegen doc https://create.roblox.com/docs/luau/native-code-gen (MD mirror https://raw.githubusercontent.com/Roblox/creator-docs/main/content/en-us/luau/native-code-gen.md), Luau 2025 runtime recap https://luau.org/news/2025-12-19-luau-recap-runtime-2025/ , Luau sources.

### 4.1 `--!native`
- "add the --!native comment at the top" to compile "all functions in the script, and the top-level scope, if deemed profitable"; `@native` attribute per function. Best candidates: "a lot of computation directly inside Luau", "mathematical operations on tables and especially buffer types", functions "called many times, especially those that are called every frame"; "numerical computation without using too many heavy Luau library or Roblox API calls". Top-level code "doesn't benefit as much".
- Native execution is skipped/disabled for: "Use of deprecated getfenv()/setfenv() calls", "Luau built-in functions like math.asin() with non-numeric arguments", "Passing improperly typed parameters to typed functions" (falls back to the interpreter), and "placing breakpoints will disable native execution for those functions".
- Limits (doc): "a single block of code inside a function used more than 64K instructions", "a single function contains more than 32K internal blocks of code", "the function has reached a limit of 1 million instructions for the entire script"; "Memory allocation limit reached" = "the overall memory limit for native code data has been reached". Luau source defaults: `CodegenHeuristicsInstructionLimit = 1'048'576`, `CodegenHeuristicsBlockLimit = 32'768`, `CodegenHeuristicsBlockInstructionLimit = 65'536` (https://raw.githubusercontent.com/luau-lang/luau/master/CodeGen/src/CodeGen.cpp); OSS code-memory cap `LuauCodeGenMaxTotalSize = 256 MB` (https://raw.githubusercontent.com/luau-lang/luau/master/CodeGen/src/CodeGenContext.cpp); Roblox's production memory cap is **UNVERIFIED**.
- "Cold" heuristic: the compiler marks a proto `LPF_NATIVE_COLD` ("not profitable to compile natively") only for **top-level code with no loops** (`if (func->functionDepth == 0 && !hasLoops) protoflags |= LPF_NATIVE_COLD;`) https://raw.githubusercontent.com/luau-lang/luau/master/Compiler/src/Compiler.cpp , https://raw.githubusercontent.com/luau-lang/luau/master/Common/include/Luau/Bytecode.h . **No "too many upvalues" rule exists** (searched Luau CodeGen; none found).
- Verification: Script Profiler shows `<native>` next to natively-executing functions; `debug.dumpcodesize()` from the Command Bar. Type annotations help ("especially recommended to annotate Vector3 arguments"); 2025 recap: "type-annotated function arguments skip unnecessary tag checks", "multiple upvalue lookups to the same slot can now be reused".
- Cost/benefit rule from the doc: don't put `--!native` everywhere ("Code compilation time", "Extra memory"); measure with/without. For TickRevamp: `--!native` on the scheduler module (heap sift loops, numeric compares) is a good candidate; the callbacks it invokes are not affected by the scheduler's flag.

### 4.2 Interpreter facts (luau.org/performance, verbatim where quoted)
- Builtins: "'fastcall' mechanism" — `assert, type, typeof, rawget/rawset/rawequal, getmetatable/setmetatable, tonumber/tostring`, all `math`/`bit32`, select `string`/`table` functions; global chains like `math.max` are "imports", "resolved when the script is loaded" — do NOT localise them into upvalues expecting a speedup.
- Table access: "field access can be very fast in Luau, provided that the field name is known at compile time" (inline caching); "Luau tables use a hybrid array/hash storage"; "Luau guarantees that the element at index #t is stored in the array part" (worst-case `#t` O(log N)).
- Methods: specialized `obj:Method` sequence; "it's crucial that __index in a metatable points to a table directly, and it's strongly recommended to avoid __index functions as well as deep __index chains".
- Tables: "table.create can create an empty table with preallocated storage"; "specify all table fields in the literal in one go" (table templates). `table.clear`: "Sets the value for all keys within the given table to nil" (keeps capacity — good for pooling). `table.freeze`: "makes the given table read-only ... Attempting to modify a frozen table throws an error" — a correctness tool, no documented speedup. https://raw.githubusercontent.com/Roblox/creator-docs/main/content/en-us/reference/engine/libraries/table.yaml
- Upvalues/closures: "90% or more of upvalues aren't mutated ... capturing upvalues that don't change doesn't require extra allocations"; closure caching "may cache the closure and always return the same object" when semantically identical; "Creating new closures is problematic for cases when functions are passed to algorithms like table.sort or functions like pcall".
- `pcall`/`xpcall`: 2025 — "now stackless when performed in a yieldable context ... will not apply the C call depth limit"; no official ns figures (see measurements).
- Vector: "native value type ... 32-bit floating point vector with 3 components" (irrelevant to a timer). `buffer`: relevant only if timer records were packed (not recommended — callbacks are Luau functions anyway).
- `debug.setmemorycategory(tag)`: "Assigns a custom tag name to the current thread's memory category in the Developer Console"; `debug.resetmemorycategory()` restores. https://raw.githubusercontent.com/Roblox/creator-docs/main/content/en-us/reference/engine/libraries/debug.yaml  Legacy `TickAPI.luau:2` already tags "TickAPI"; keep it (it tags the *thread*, so callbacks invoked from the scheduler are attributed to the scheduler's category unless the callback resets it).

### 4.3 Micro-benchmarks **[MEASURED, Lune 0.10.5+709 interpreter, median of 5, ns per op]** — `W/research/scratch/roblox-timing/bench.luau`
| Case | ns/op |
|---|---|
| direct call `noop(i)` | 6.9 |
| `pcall(noop, i)` | 33.3 |
| `xpcall(noop, handler, i)` | 49.3 |
| `pcall(function() ... end)` (closure alloc per call) | 45.8 |
| upvalue increment | 7.3 |
| table field increment, constant key | 6.0 |
| table field increment, dynamic key | 5.9 |
| method call, function stored on instance | 18.2 |
| method call, 1-hop `__index` table | 13.7 |
| method call, 2-hop `__index` chain | 29.7 |
| method call, 3-hop `__index` chain | 36.9 |
| method call, `__index` function | 56.0 |
| closure creation capturing a mutable upvalue | 28.7 |
| closure creation capturing only immutable upvalues (cacheable) | 7.8 |
| `{a=..,h=..}` 8-field literal | 69 |
| `{}` then 8 field assignments | 233 |
| 64 pushes into `{}` | 873 |
| 64 pushes into `table.create(64)` | 414 |
| `table.clear` + 64 pushes (reused table) | 204 |
| `string.format("%d", i)` | 151 |
| `tostring(i)` | 84 |
| `string.format("%s %.3f", s, x)` | 332 |
| heap push+pop on a 10k number-keyed array heap | 329 |
| `os.clock()` | 31 |

Takeaways: `pcall` ≈ +26 ns over a direct call (cheap enough to wrap every callback); upvalue vs constant-key field access is a wash in the interpreter; a 1-hop `__index` table is the fastest method dispatch (even beating a function stored on the instance, thanks to the specialised namecall path); every extra `__index` hop costs ~10–15 ns and an `__index` *function* 4×; build records as literals; reuse arrays with `table.clear`; avoid `string.format` on the hot path (20–50× a heap op).

### 4.4 BaseClass (house middleclass fork) dispatch shape — `W/reference/baseclass/BaseClass.luau`
- Instances are `setmetatable({class = self}, self.__instanceDict)` (`:170`) and `dict.__index = dict` (`:98`) → **exactly one `__index` hop to a table** (the fast path). `_propagateInstanceMethod` (`:68-75`, `:233-234`) copies every method into each subclass's own dict, so inheritance depth adds no hops.
- If a class declares an `__index` metamethod, `_createIndexWrapper` (`:50-60`) turns the instance `__index` into a **function** (the 56 ns path) — never declare `__index` on scheduler/handle classes.
- `Class.static` lookups go through `__index` functions (`:106-115`) — keep static access out of `update()`.
- `class = self` is stored on every instance (one extra hash slot per timer record); acceptable.

---

## 5. Timer-scheduler prior art
### 5.1 Data structures
- **Timing wheels** — Varghese & Lauck, "Hashed and hierarchical timing wheels", SOSP 1987 (https://dl.acm.org/doi/10.1145/41457.37504) / IEEE-ACM ToN 1997 (https://doi.org/10.1109/90.650142; PDF https://www.cs.columbia.edu/~nahum/w6998/papers/sosp87-timing-wheels.pdf). Claim (via https://www.semanticscholar.org/paper/0a142c84aeccc16b22c758cb57063fe227e83277): a circular buffer/timing wheel gives O(1) start, stop and per-tick maintenance within the wheel's range; hashed/hierarchical wheels extend the range at the cost of granularity/cascading. Abstract text not fetched (ACM 403, S2 API elided) — **UNVERIFIED wording**.
  - Linux kernel (https://raw.githubusercontent.com/torvalds/linux/master/kernel/time/timer.c): LVL_DEPTH 9 (HZ>100) × 64 buckets; "We don't have cascading anymore. timers with a expiry time above the capacity of the last wheel level are force expired at the maximum timeout value of the last wheel level."; "The granularity levels provide implicit batching."; rationale "The vast majority of timeout timers (networking, disk I/O ...) are canceled before expiry."
  - tokio (https://raw.githubusercontent.com/tokio-rs/tokio/master/tokio/src/runtime/time/wheel/mod.rs): "6 levels with 64 slots each ... up to 2 years into the future with a precision of 1 millisecond"; entries are tiered "down to the next level" as they approach.
  - Verdict for TickRevamp: wheels win only when timers are mostly cancelled before expiry and imprecision is acceptable; game timers are mostly *fired*, need exact ordering, adjust/reset, and frame-resolution precision on a variable-dt axis → a **binary heap** is the right structure (matches the SyncedTimer direction).
- **Binary heap, lazy deletion** — Python `heapq` docs (https://docs.python.org/3/library/heapq.html): "mark the entry as removed and add a new entry with the revised priority" (`REMOVED` marker + `entry_finder` dict + `itertools.count()` tie-breaker "so that two tasks with the same priority are returned in the order they were added"). Go runtime (https://raw.githubusercontent.com/golang/go/master/src/runtime/time.go): per-P **4-ary** heap; `timerZombie` "set when the timer has been stopped but is still present in some P's heap"; `timerModified` "when t.when has been modified but the heap's heap[i].when entry still needs to be updated"; heap compacted when `zombies > len/4`.
- **Indexed heap with decrease-key / arbitrary removal** — libuv (https://raw.githubusercontent.com/libuv/libuv/v1.x/src/timer.c): comparator `timeout` then `start_id` ("order timers with identical timeouts by insertion sequence"); `uv_timer_stop` does `heap_remove` (node knows its position); repeat timers re-armed via `uv_timer_again` "relative to current loop time rather than attempting catch-up"; overflow clamp `if (clamped_timeout < timeout) clamped_timeout = (uint64_t)-1`. Legacy `MinHeap.luau` already supports `update`/`remove` by handle (SyncedTimerClass.luau:223,266,314), i.e. an indexed heap.
- **Pairing heaps** (https://en.wikipedia.org/wiki/Pairing_heap): amortized Θ(1) insert/find-min/meld, O(log n) delete-min, decrease-key between Ω(log log n) and O(2^(2√log log n)); in practice "When decrease-key is not needed ... d-ary heaps such as binary heaps are faster than all other heap implementations"; pairing heaps win only when decrease-key dominates. A timer scheduler's dominant ops are insert + delete-min → binary/4-ary array heap.
- **Cap-per-frame / dt clamp** — Unity `Time.maximumDeltaTime` ("the maximum value of Time.deltaTime in any given frame", limits FixedUpdate catch-up count, https://docs.unity3d.com/ScriptReference/Time-maximumDeltaTime.html); Gaffer "Fix Your Timestep" (`if (frameTime > 0.25) frameTime = 0.25;` + `while (accumulator >= dt)` loop; "spiral of death" when catch-up work exceeds real time, https://gafferongames.com/post/fix_your_timestep/). Go `Ticker`: "will adjust the time interval or drop ticks to make up for slow receivers" (https://pkg.go.dev/time#NewTicker).

### 5.2 Timer libraries: cancel-during-iterate, re-entrancy, catch-up
| Library | Iteration & removal safety | Recurring timer that lags | Timer created inside a callback |
|---|---|---|---|
| **rxi/tick 0.1.1** (`W/reference/rxi-tick/tick.lua:94-111`) | Array iterated **backwards** (`for i = #self, 1, -1`); `self:remove(i)` inside the loop is safe for the current index; countdown model (`e.timer -= dt`). | `while e.timer <= 0` → **catches up: fires N times in one update** for recurring events; one-shot fires once and `break`s. | `self.err` = residual overshoot of the firing event is carried into `tick:event` / `after` (`:33,:50,:104,:128-133`) so a child delay shorter than dt is anchored to the parent's *due time*: "several nested events with very small delays may end up being called on the same frame". Heap equivalent: `childDue = parentDue + delay`, not `now + delay`. |
| **Legacy Tick.luau** (`W/reference/live/Tick.luau`) | same as rxi plus a nil-skip (per shared context). | same catch-up. | same `err` carry. |
| **hump.timer** (https://raw.githubusercontent.com/vrld/hump/master/timer.lua) | Snapshots handles into `to_update` before iterating; checks `self.functions[handle]` still exists → removal during iteration safe; timers added during update run **next** update. | `while handle.time >= handle.limit and handle.count > 0` → catch-up burst; callback returning `false` cancels. | deferred to next update (no err carry). |
| **knife.timer** (https://raw.githubusercontent.com/airstruck/knife/master/knife/timer.lua) | Backward `for index = #group, 1, -1` over an array group. | `while elapsed >= duration` catch-up loop; `limit()` count. | appended to group array; not processed until next update. |
| **Sleitnick Timer (RbxUtil)** (https://raw.githubusercontent.com/Sleitnick/RbxUtil/main/modules/timer/init.luau) | One Heartbeat connection per Timer object (`UpdateSignal` default `RunService.Heartbeat`, `TimeFunction` default `time`). Callbacks fired through a Signal / `task.defer(callback)` in `Timer.simple` (error isolation, Stop-inside-Tick safe). | `AllowDrift=true` (default): `if now >= nextTick then nextTick = now + Interval` → **fire once, drop missed, re-anchor to now** (phase drifts). `AllowDrift=false`: `while now >= nextTick do n += 1; nextTick = start + Interval*n; Tick:Fire() end` → **catch-up burst, phase-locked to start**. | n/a (Timer objects are independent). |
| **evaera Promise.delay** (https://raw.githubusercontent.com/evaera/roblox-lua-promise/master/CHANGELOG.md) | v3.0.0 (2020-08-17): custom scheduler on `os.clock` + Heartbeat, "more consistent when creating new timers in the callback of a timer"; later: "Promise.delay now wraps task.delay ... changes in behavior are still possible as we don't have direct control over how Roblox's task scheduler works"; `Promise.defer` moved to `task.defer` "which moves its position in the frame". | n/a (one-shot). | n/a. |
| **libuv / Go / Linux** | heap remove by handle / zombie marking / list unlink. | libuv: re-arm relative to now (drop missed). Go Ticker: drop ticks. Linux: late by ≤ level granularity. | – |

Typical policies for a lagging recurring timer, all seen in the wild: (1) **catch-up burst** — fire ⌊overshoot/period⌋ times now (rxi, legacy Tick, hump, knife, Sleitnick no-drift) — deterministic total count, but a 2 s hitch on a 1/60 s timer fires 120 callbacks in one frame; (2) **fire once, re-anchor to now** (Sleitnick default, libuv) — no burst, phase drifts, missed fires lost; (3) **fire once, phase-locked** (`due = start + n*period` with n = next future index) — no burst, no drift, missed fires lost; (4) **capped catch-up** — fire at most K per update (or until a per-update time budget) and carry the remainder to the next frame (Unity maximumDeltaTime / Gaffer clamp) — bounded frame cost, eventual consistency.

---

## 6. Parallel Luau / Actors
- "Each Actor runs in its own Luau VM"; "ModuleScripts required by an Actor are not shared or cached across Actors"; "Each VM executes its own copy of the module, so module-level state is isolated per Actor"; "Message arguments are passed by copy across Luau VM boundaries, not by reference". https://raw.githubusercontent.com/Roblox/creator-docs/main/content/en-us/reference/engine/classes/Actor.yaml
- Parallel phases: `task.desynchronize()` "suspends the execution of the current coroutine for running code in parallel and resumes it at the next parallel execution opportunity"; "You can't use require() in a desynchronized parallel phase"; API thread-safety levels Unsafe / Read Parallel / Local Safe / Safe, default Unsafe. https://create.roblox.com/docs/scripting/multithreading
- Consequence: a scheduler cannot hold callbacks (Luau functions) from another VM, and a callback running in a parallel phase cannot touch most of the DataModel. A scheduler inside an Actor is only useful for timers *owned by that Actor's own scripts*, and it must run in the serial phase (or its callbacks must `task.synchronize()`). Default for TickRevamp: **one scheduler per VM in the serial phase; no Actor**. A module copy required inside an Actor is automatically an isolated scheduler — no special code needed.

---

## 7. Design implications for TickRevamp (concrete rules)
1. **Keep the caller-facing names** `Tick` (Stepped), `Tickh` (Heartbeat), `Tickr` (RenderStepped) as the default hook registry, but bind them internally to the *documented* events and expose a hook table so the driver can register any signal: `{ Tick = RunService.Stepped, Tickh = RunService.Heartbeat, Tickr = RunService.RenderStepped (client only) }` plus optional `PreSimulation/PostSimulation/PreRender/PreAnimation` entries. Do not silently rebind `Heartbeat`→`PostSimulation`: they pass different dt semantics (`deltaTime` wall vs `deltaTimeSim` physics) and `PostSimulation` does not fire in Edit mode (§1.5). Stepped's dt is the **second** argument — the driver adapter must normalise `(time, dt)` → `dt`.
2. **Never trust dt.** Normalise in the driver before `update`: `if dt ~= dt or dt < 0 then dt = 0 end`; clamp `dt = math.min(dt, maxDt)` with a per-scheduler `maxDt` default of 0.25 s (Gaffer/Unity precedent) — Roblox does not clamp (250 ms stall → dt 0.2517 measured). Expose the raw dt separately for callers who want it.
3. **Virtual clock as heap axis** for hook-driven schedulers: `self.now += dt` (after clamp and `timeScale`); timers store absolute `due`; `update` pops while `heap[1].due <= now`. Never read `os.clock()`/`time()` inside `update` (time() is frozen in Edit mode; os.clock differs per process; both defeat Lune parity and `timeScale`). Provide `UpdateAt(absoluteNow)` for externally-synced schedulers (`GetServerTimeNow()`-fed SyncedTimer replacement); reject non-increasing `absoluteNow` (log + ignore) because GetServerTimeNow is documented monotonic and any regression means the caller mixed axes.
4. **Heap = array binary heap of records keyed by `due` with a monotonically increasing sequence number as tie-breaker** (libuv/Python precedent) so equal due times fire in creation order and tests are deterministic. Records know their heap index (indexed heap) so `stop/remove/adjust/reset/setPeriod` are O(log n) sift operations, no lazy tombstones needed; keep a `dead` flag anyway so a record removed *during* the due-prefix pop loop is skipped (defence for remove-inside-own-callback and double remove). Both approaches (indexed vs zombie) are fine; indexed keeps `getClocks` exact.
5. **Due-prefix processing, re-entrancy safe**: pop → mark `state=firing` → invoke via `xpcall` with the scheduler's error policy → if recurring and not removed/paused during the callback, recompute `due` and push; timers created inside a callback are pushed to the heap immediately (heap order makes them safe) but anchored at `parentDue + delay` (rxi `err` semantics, §5.2) and only fire in the same update if `due <= now` (rxi behaviour: "several nested events with very small delays may end up being called on the same frame"). Guard the pop loop with an iteration cap (e.g. `maxFiresPerUpdate`) to prevent a zero-delay self-rescheduling timer from looping forever.
6. **Lagging recurring policy is per-timer, default "capped catch-up"**: fire up to `catchUpLimit` (default 1 → behaves like Sleitnick no-drift with a burst of at most 1, phase-locked `due += period` while `due <= now`, dropping the rest once the limit is hit). Offer `:setCatchUp("burst" | "drop" | n)`. Document that legacy rxi semantics = "burst".
7. **ForceEventComplete(handle)** = set `due = -math.huge` (sift-up to the top) and let the normal loop fire it on the next `update`, or fire synchronously if called outside `update` (`state ~= firing`); it must go through the same xpcall/error path and the same after-chain path. Stop/remove never invoke the callback.
8. **Callbacks run through `xpcall`** (~+26–45 ns each, negligible next to the callback) with policies `warn` (default), `error`, `ignore`, and a per-scheduler hook; a callback error must leave the heap consistent (the pop already happened; the recurring re-push happens after xpcall regardless of result unless policy says remove-on-error).
9. **Allocation discipline**: create timer records as one table literal with every field present (69 ns vs 233 ns); keep the heap as two parallel arrays or one array of records (measure both; parallel `due[]`/`rec[]` arrays avoid an `__index` hop per compare); reuse arrays with `table.clear`; never `string.format` or build closures in `update`; wrap recurring callbacks once at creation, not per fire. Mark the module `--!native` and verify `<native>` in the Script Profiler.
10. **BaseClass rules**: never define `__index` on scheduler/handle classes (turns dispatch into a function, 4× slower); keep `Class.static` out of hot paths; colon-vs-dot misuse guard = `if type(self) ~= "table" or self.class == nil then error(...)` at public entry points only (not inside `update`).
11. **Boot diagnostics**: at `new()`/hook registration, record `{IsServer, IsClient, IsEdit, IsRunMode}` and which signals connected; expose `scheduler:getDriverInfo()`; warn once if a scheduler bound to `Stepped`/`PreSimulation` receives no update within N seconds while `Heartbeat` is alive (Edit-mode trap from §1.5) — this directly answers the legacy "Tickh does not happen on the server?" class of mystery.
12. **Driver = one connection per hook, not per timer** (10k polling connections cost a 44 ms frame; one connection + heap pops 10k in 5 ms). Client-only signals guarded by `RunService:IsClient()`; RenderStepped-bound schedulers must tolerate 240 Hz updates (per-update cost × 4).
13. **Do not use Actors** for the scheduler; document that a module copy inside an Actor is already an isolated scheduler.
14. **Lune parity**: the scheduler core must not touch `game`, `time()`, `tick()`, or `RunService`; the driver module is the only Roblox-aware layer, so `P/reference/lune/Tick.luau`-style parity tests keep working.
15. **Frozen contracts**: `getClocks()` (legacy) returns live handles — with a heap, return a snapshot array (not the heap) to prevent callers from corrupting heap order.

## Open questions for Jake
- Should `Tickh` keep binding to `Heartbeat` (wall dt, fires in Edit mode) rather than `PostSimulation` (physics dt, silent in Edit mode)? (Recommendation: keep Heartbeat.)
- Default lagging-recurring policy: capped catch-up with limit 1 (recommended) or legacy burst (rxi-compatible)?
- `maxDt` default 0.25 s, or no clamp by default with an explicit opt-in?
- Is the legacy SyncedTimer axis mismatch (`WorldTime.Value` keys vs `Stepped.time` compare, SyncedTimerClass.luau:149/157/428) a live bug worth fixing during the rebuild, or is WorldTime derived from Stepped time somewhere unseen?
- Permission to run a Play/Run-mode probe (server DataModel) to confirm server-side Heartbeat/Stepped firing rates and the PostSimulation↔Heartbeat handler order.

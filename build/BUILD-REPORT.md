# Veron build report (final integration, 2026-09-16)

Scope: the `Veron` class and its `VeronEvent` handle (`build/src/Veron/`), tests, bench and docs, built
against `docs/DESIGN.md` (WP1–WP9, §12). The `TickAPI` wrapper is out of scope (CLAUDE.md, DESIGN §6).
Every decision made where the design was silent is in `build/BUILD-NOTES.md`; this report consolidates them.

## 1. Suite

```
lune run build/tests/run.luau
278 passed, 0 failed
```

- Fix cycles used: 0 of 6. Code fixes: 0. Spec fixes: 0. The suite was green on the first integrator run.
- Order independence: every spec file also passes alone through `run_one` (the 16 WP1–WP6 files were
  checked in integration round 1; the four WP7–WP9 files and the support smoke file in this round:
  parity 24, regress 33, alloc 4, docs 9, support 4).
- Stage D blockers: none — WP7, WP8 and WP9 each reported an empty blocker list.
- Runner output carries `[WARN] [Veron T] …` lines from eight reentrancy tests that deliberately
  re-enter `Update` or trip the valve; §9 does not require silence (cosmetic, left as is).

## 2. Inventory vs the §9 plan

Method: every backticked name in the §9 table was diffed mechanically against the runner's
`file::name` list (script run once, not kept).

| Spec file | §9 count | Built | Result |
|---|---|---|---|
| `env/env_spec` | 5 | 5 | all names verbatim |
| `heap/heap_spec` (raw) | 7 | 7 | all names verbatim |
| `scheduler/arm_spec` | 12 | 12 | all names verbatim |
| `scheduler/time_spec` | 16 | 16 | all names verbatim |
| `scheduler/dispatch_spec` | 16 | 16 | all names verbatim |
| `scheduler/catchup_spec` | 15 | 15 | all names verbatim |
| `scheduler/reentrancy_spec` | 20 | 20 | all names verbatim |
| `handle/state_spec` | 20 | 20 | all names verbatim |
| `handle/stop_spec` | 9 | 9 | all names verbatim |
| `handle/retime_spec` | 13 | 13 | all names verbatim |
| `handle/chain_spec` | 15 | 15 | all names verbatim |
| `handle/complete_spec` | 23 | 23 | all names verbatim |
| `scheduler/lifecycle_spec` | 18 | 18 | all names verbatim |
| `class/class_spec` | 11 | 11 | all names verbatim (was `baseclass/baseclass_spec`; renamed 2026-09-17) |
| `errors/errors_spec` (raw) | 4 | 4 | all names verbatim |
| `parity/parity_spec` | 4 + 20 DV pins | 24 | 4 named tests verbatim; 20 pins DV-1…15, 17, 20, 21, 23, 24 (see note) |
| `regress/repros_spec` | 33 ids | 33 | all 33 ids verbatim |
| `alloc/alloc_spec` | 4 | 4 | all names verbatim |
| `docs/docs_spec` | 9 | 9 | all names verbatim |
| `support/support_spec` | — | 4 | WP2 smoke tests, outside §9's count |
| **Total** | **274** | **278** | |

- **Missing §9 tests: none.**
- **Renamed §9 tests: none.** The only names §9 does not spell out are the 17 DV pins beyond
  `DV-7`, `DV-14` and `DV-24`; they follow the §9-prescribed `DV-n: legacy …, new …` shape and are
  shortened to stay under the 120-col hard limit (WP7 note). The three §9 spells out are verbatim.
- Two §9 names in `errors_spec` and one in `state_spec` exceed 120 columns on their own; the
  `errors_spec` literals are split with `..` (registered name unchanged), the `state_spec` line is a
  documented 131-col style exception so the name stays one greppable literal.
- Section 13's deferred `chain_spec :: 100k-deep chain stops without overflow` is a follow-up test
  the design explicitly does not require (F-PM-8) and is not built.

## 3. Bench

```
lune run build/bench/bench.luau
bench: 21 invariant checks, 0 failed
```

Lune 0.10.5 interpreter (no `--!native`), seed 20260916, median of 5, N = 10 000. Headline numbers from
this integration run; `build/bench/BENCH.md` records a three-run spread and the reading of each target.

| Phase | This run | BENCH.md recorded | Target (§10) |
|---|---|---|---|
| P2 idle — 200 updates, 10k armed | **0.046 µs/update, 0 B** | 0.046 µs/update, 0 B | ≤ 0.04 µs: MISSED by clock resolution (9 µs / 200); **0 B exactly: met** (the hard assertion) |
| P7 recurring — 10k × 600 updates @ 1/60 | **69.0 µs/update, 378 ns/fire, 109 497 fires, 0 B** | 65.0 µs/update, 356 ns/fire, 0 B | garbage 0: met (IB prototype 66.5 µs) |
| P8 mixed churn × 600 (50 arms / 20 stops / 10 adjusts) | **29.7 µs/update** | 29.5 µs/update (30.7–33.5 in other runs) | ≤ 28.75 µs: MISSED by ~3 %, inside the prototype's own run-to-run spread |
| P14 legacy ratio (`reference/lune/Tick.luau`) | idle 144.0 vs 0.046 µs/update (**~3100×**); P7 153.4 vs 69.0 µs/update (**2.2×**); P8 228.2 vs 29.7 µs/update (**7.7×**) | ~3100× / 2.4× / 8.0× (6.6–7.4 in other runs) | headline numbers, not targets |
| P15 per-instance — construct + destroy 1k | **6.08 µs/instance construct, 4653 B resident, 0.18 µs destroy** | 6.7 µs, ~6.0–6.7 KB resident, 0.27 µs | §3.2 expected ~7–9 KB: below |

Other phases this run: P1 372 ns/op, 629 B/handle (target 300: MISSED — validation + `coroutine.running()`
+ dual closure + literal build, §4.1 costs); P3 160 ns/op, max stop 2.5 µs (met); P4 158 ns/op (met);
P5 167 ns/op; P6 361 ns/dispatch (target 354: borderline, 328 in the recorded run); P7b 313 ns/fire on
500 000 tie-heavy fires, 0 B (Id-on-handle kept); P9 max single op 7.4 µs; P10 dual-call +24 ns colon /
−5 ns dot this run (met; +44…+58 in the recorded run — noise-level, the D15 vararg shim); P12 re-entrancy
tax +3.4 % (within noise). P11 and P13 do not exist (stable phase ids): P11 was the BaseClass `Class:new`
construction comparator, removed 2026-09-17 with the BaseClass dependency (suite now 20 invariant checks).

The P15 resident figure varies between runs (4.6–6.7 KB) because Lune has no `collectgarbage("collect")`
and the window is a net-growth reading; the recorded BENCH.md value is the one API.md quotes.

`build/bench/studio_bench.luau` was NOT run (needs Roblox Studio); its `<native>` Script Profiler check is
a manual operator step documented in its header.

## 4. Deviations, consolidated from BUILD-NOTES.md

Each bullet names the design section it fills or departs from. None contradicts a settled decision;
three are design-TEXT corrections left for Jake (§7 below).

### Design-text corrections flagged (behaviour follows the stated decision)

- **§4.2 (c) / §11 valve latch.** As literally written, every nested pass gets its own valve budget
  and enclosing passes keep dispatching after an inner trip, so a `Delay(0)+Update(0)` chain
  dispatches Σ (Valve+1)^k — a hang with the defaults — not the `MaxUpdateDepth × Valve` bound §4.2 (c),
  §11 and `reentrancy_spec :: sync re-entry chain is bounded per pass …` all state. Built to the stated
  bound: `_advanceTo` passes `self._ValveHits` into `_pass(self, serial, valveHits)` and every pass
  breaks once the counter moved (7 dispatches for Valve 4 / depth 3, bound 12). No new instance field.
- **§3.1 handle size.** The 14-key literal measures **560 B** under Lune 0.10.5 (48 B header + 16 × 32 B
  nodes), not the quoted 576 B (64 B header assumed). Same 16-node hash part, same two slots of headroom.
  `alloc_spec` asserts literal ≤ 576 and `Delay == literal`; bench P1 asserts 560 ≤ B/handle ≤ 560 + 128.
  API.md keeps the design's 576 B wording (`docs_spec` pins it).
- **§7.3 DV-7 example line.** DESIGN writes `EventSpawnerClass:406→345`; the actual `Tick.delay(` line is
  346 (345 opens the `:345-354` loop the survey quotes). MIGRATION.md and `docs_spec` pin 346.

### Core (`build/src/Veron/init.luau`, §2–§4)

- Level-carrying helpers (`_checkOption, _checkOpts, _validateUncapped, _validateArgs, _resolve, _attach`)
  are forward-declared locals assigned after declaration: Luau O2 inlines small `local function`s and
  deletes the frame the caller-relative `level` counts on (verified; Roblox compiles at O2 too).
- `Veron._Heap = { push, pop, remove, update, clear }` is a test-only static for `heap_spec`
  (not in the design; never on the hot path). `heapRemove` returns `false` on an ownership mismatch,
  `heapUpdate` raises the §3.2 ownership text — the design's split, not the orchestrator brief's
  "update/remove" wording.
- Config: a non-nil non-table `cfg` raises `Veron: expected a config table, got <t>`; the default-`Name`
  counter increments on every construction (named or not); option error texts fixed as listed in
  BUILD-NOTES WP4. `DelayAt` checks `destroyed` before `needs UpdateTo` (design silent on the order).
- `_SetRemaining` / `_SetPeriod` coerce with `tonumber` like `_Adjust` (legacy I7).
- `_CompleteNow`: error label `CompleteNow`; a recurring already carrying STOP_ON_FIRE is treated as
  `opts.Stop`; the "recurring Chained" row of §4.7 is unreachable and not coded; nesting diagnostic
  `CompleteNow nested deeper than 8; event #<id> refused`.
- `Clear()` returns the total including handles stopped in attached children (§2.2 "cascades…; returns
  handles stopped"); `lifecycle_spec` (≥ own) and `chain_spec` (3..4) both accept that reading.
- `cannot chain a recurring event` (§4.6) stays unprefixed and is treated as validation-family (left
  out of `errors_spec`'s prefix assertion).

### Test support and specs (§9)

- `Oracle.wrap` wraps IN PLACE (same table) rather than a proxy so aliases share one wrapper and
  identity holds; handle methods are wrapped once per process through `VeronEvent`.
  Consequence: error-LEVEL assertions need a raw instance (`errors_spec` is raw), zero-allocation
  windows need raw instances (`table.pack` in the wrapper), and `state_spec :: handle dot-call raises
  the colon message` checks the position prefix only when nothing is wrapped yet.
- `Oracle.noop()` captures the Stopped-handle NOOP from a throwaway `OracleProbe` instance (advances the
  default-name counter; verified no spec pins a `Veron<N>` name).
- `gen.luau`: Park–Miller LCG, dyadic delays k/64, exact 1/4096-grid integer model of both schedulers to
  keep every step legal under the DV-2/7/8/9 constraints; verified against the legacy shim over 300
  seeds × 400 steps.
- `state_spec` "even with invalid arguments": `After(nil, 1)` etc. are asserted no-raise on STOPPED
  handles only — §2.3/§4.6/§5 make `After` on a FIRED parent validate its arguments; `Complete(<non-table>)`
  excluded because `_checkOpts` runs before the terminal check (§4.7).
- Dyadic timing wherever the design's own numbers are not (catch-up 0.1 s case pinned on 1/16 s exact
  grid plus a float-tolerant 0.1 s run); `Delay(3*dt) one update late` pins the no-epsilon rule with
  `10 × 0.1` because three 1/60 additions do reach `3*dt` under Lune.
- `collectgarbage("collect")` does not exist under Lune: every garbage window is a bare `count` delta
  with a same-frame warm-up round; all three zero-garbage tests read exactly 0 B.
- Setter coercion of numeric strings is NOT pinned (§2.1 states "number" without saying).
- `task.spawn` test uses `@lune/task` with a `coroutine.wrap` fallback.

### Parity and repros (§7.3, §9)

- **Capped-run generator gap** (gen.luau is WP2's file, fixed in the harness): the generator can
  `adjust` an UNARMED `after` child below its parent's overshoot (DV-2 holds only at creation), which
  legally diverges legacy (next update) from Veron (same update). `_sanitize` drops such adjusts
  (31 of 100 000 steps) and `_run` skips steps whose handle does not yet exist on BOTH sides, asserting
  equal skip counts; the default-dts 500-sequence run needs neither and asserts zero skips.
- **DV-7 `LegacyRecurBase equals legacy`**: at 1/60 the knob fires on frame 151 vs legacy 150 (the
  DV-11/B-20 one-frame float class), so equality is asserted within one frame at 1/60 and exactly
  (2.5 == 2.5, new 1.5) on a dyadic 1/64 clock.
- `F5`/`F6` read as the legacy-bughunt ids (recur 0 hang; adjust-on-delay-0 NaN zombie) with the
  semantics-spec rows of the same names folded in, so either reading is pinned.
- DV-9 legacy side asserts the observed post-`update(1)` values (`fires == 2`, `E.timer == 1`), not the
  research comment's pre-second-fire wording. DV-12/DV-3 use the shim's process-wide default group
  (one harmless leaked key).
- `B-14` pins the design's §5 value (Chained `GetRemaining` == own delay), not the research's suggested
  fix. `L-05` pins the in-order yield overlap; the out-of-order case is `reentrancy_spec`'s.

### Alloc and bench (§10)

- Timing targets are printed `met`/`MISSED` and never fail the run (§10: reported, not asserted, under
  Lune). Missed: P1, P2 (clock resolution), P8 (3 %), P10 (D15 vararg shim ~45 ns in the interpreter; a
  fixed-arity closure would be a design change, not applied). No code change made for them.
- Per-handle sizes use the alloc_spec max-over-short-rounds method (a 10k batch window can read 0 after
  a collector step); P8's garbage is printed as net growth and varies 1.5–6.5 MB run to run.
- `studio_bench.luau` = Roblox header + the `bench.luau` body copied verbatim from the `-- ==== BODY`
  marker; refuses to run outside Roblox; P14 there runs only while the legacy `Tick` ModuleScript
  still exists (pre-M1).

### Docs (§7, §12 WP9)

- The "≤ 26 recur-nested files" list is not explicit in `research/callsites.md`; MIGRATION.md §4's 19
  files (12 same-instance, 7 mixed-instance) were derived from `research/scratch/callsites/all_lines.txt`
  (live tier, main wrapper, commented lines excluded); three rows re-verified.
- API.md rewrites private-field idioms for readers (`PWC` → "pause-when-created flag"; `_Fn = NOOP`
  kept only where it names the observable effect); signatures, error strings, aliases verbatim.
- MIGRATION.md carries the 20 §7.3 rows and a one-line note that DV-16/18/19/22 kept their scope.

## 5. Files delivered

```
build/src/Veron/init.luau                 class Veron (WP4–WP6)
build/src/Veron/VeronEvent/init.luau      handle class (WP3)
build/src/Veron/Env/init.luau             Env seam (WP1)
build/tests/run.luau, run_one.luau        runners
build/tests/support/{oracle,legacy,gen}.luau
build/tests/spec/<19 files + support_spec>
build/bench/{bench,studio_bench}.luau, BENCH.md
build/docs/{API,MIGRATION}.md
build/BUILD-NOTES.md, BUILD-REPORT.md
```

`build/tests/scratch/` (empty leftover) was removed in this round; nothing else outside the list exists.

## 6. Known gaps (honest)

1. **Native `<native>` compilation and the Studio bench are the remaining Roblox-only unknowns.** The
   scheduler HAS run under the real Roblox VM (VeronRun 51/51, ComparePerf head-to-head — HISTORY
   2026-09-16 / 2026-09-17), so the `script.*` require branches and `typeof(script) == "Instance"` paths
   are exercised. What is still untested in Studio: `--!native` actually engaging (the `<native>` profiler
   check in `studio_bench.luau`), and `studio_bench.luau` re-run AFTER the 2026-09-17 BaseClass/P11 removal
   (its Lune twin `bench.luau` is verified at 20/0; the two bodies are byte-identical). Confirm both at M0
   of MIGRATION.md.
2. **Four §10 timing targets are missed under Lune** (P1 372–397 vs 300 ns/op; P2 0.046 vs 0.04 µs by clock
   resolution; P8 29.5–29.7 vs 28.75 µs; P10 +44…+58 vs +30 ns in the recorded run). All are explained in
   BENCH.md as interpreter costs the design accepts (§4.1 validation, D15 vararg shim); none was fixed by
   code. Native Studio numbers are the ones that decide whether any is real.
3. **Design text vs build** (docs/ is outside the build's writable set; three items wait on Jake):
   §4.2 (c)/§11 valve wording (latch built), §3.1 576 B → 560 B measured, §7.3 DV-7 example line 345 → 346.
4. **Generator gap not fixed at the source.** `gen.luau` can still produce the DV-2-class adjust; the
   parity harness sanitises around it (31 / 100 000 steps dropped on the capped run). A follow-up should
   move the constraint into the generator so the harness needs no skip logic.
5. **`LegacyRecurBase` is one-frame-exact only on dyadic clocks.** At 1/60 it lands one frame after
   legacy (DV-11 float class). MIGRATION.md's "reproduces the quirk" is true to the period, not the frame.
6. **P15 resident-bytes is noisy** (4.6–6.7 KB across runs) because Lune has no full collect; API.md quotes
   the recorded ~6–7 KB. Treat the Studio number as authoritative when available.
7. **Deferred minors (§13) are unbuilt by design**: F-PM-8 (recursive `_Chained` walks overflow on a
   ~300k-deep chain), F-PM-9 (`cfg.Capacity` pre-sizing), JF-16 gate half, JF-18 duck-type half (wrapper),
   JF-17 hot-path rename.
8. **Static survey limits**: the 19-file DV-7 list in MIGRATION.md is derived from a static grep; a
   callback reaching `delay` through another module is invisible to it.
9. **Style**: one 131-col line in `state_spec` (a §9 name kept as one literal); the HOT PATH blocks keep the
   prototype's single-letter locals by design (§3.2, D24).
10. **Runner noise**: eight reentrancy tests print `[WARN]` lines; the parity file takes ~23 s of the
    suite's wall time (500 oracle-wrapped sequences).

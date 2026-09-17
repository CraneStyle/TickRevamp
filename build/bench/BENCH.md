# Veron bench — method and numbers (DESIGN §10, WP8)

Files: `build/bench/bench.luau` (Lune), `build/bench/studio_bench.luau` (Roblox Studio command bar; same
body, different header), this note. Companion spec: `build/tests/spec/alloc/alloc_spec.luau` (the four §9
zero-garbage tests, asserted on every suite run).

Run from the workspace root: `lune run build/bench/bench.luau` (exit code 1 when any invariant check fails).
Studio: paste `studio_bench.luau` into the command bar with the Veron ModuleScript installed at
`ReplicatedStorage.SharedModules.TickAPI.Veron`, then confirm `<native>` on the Veron frames in the Script
Profiler (the one check a script cannot do for itself, §10/D24).

## Method

- Seed 20260916 through a Park–Miller LCG (`x = x * 48271 % 2147483647`, exact in doubles), so a Studio run
  sees the same dues, periods and shuffles as a Lune run. `N = 10000` handles everywhere the row says 10k.
- Every timed window is the **median of 5** reps of `os.clock()` deltas (`_measure`); phases that need fresh
  state rebuild it in a per-rep `setup`. Phases with a steady-state window (P2, P7, P7b, P14) run one warm-up
  rep through the same `_measure` frame first, so the window never pays a first-call stack growth the warm-up
  did not (the 1.6 KB one-off `alloc_spec` documents).
- Garbage is the **largest** `collectgarbage("count")` delta any rep saw, in bytes. Lune 0.10.5 has no
  `collectgarbage("collect")` (verified: "invalid option"), so the number is a net-growth reading: a zero-garbage
  body reads exactly 0 in every rep (the collector only steps when something allocates); an allocating body
  reads its allocation minus whatever a collector step freed inside the window — P8's "net growth" is
  therefore a lower bound and varies run to run (1.5–6.5 MB seen), while the per-handle sizes (P1 and the
  literal) are measured the `alloc_spec` way: max per-slot delta over ten 200-slot rounds, which a collector
  step cannot lower in every round.
- Invariant assertions print inline as `[ok …]` / `[FAIL …]` and fail the run; **timing targets print as
  `[target … met/MISSED]` and never fail it** (§10: timings are reported, not asserted, under Lune). The
  targets are the IB prototype numbers below times the §10 factor.
- Spikes (P3/P4 "max single op") time every call individually on a separate 10k set, because timing inside
  the median window would distort the ns/op reading.
- P14 drives `reference/lune/Tick.luau` (the live legacy core minus its RunService line) through the P2/P7/P8
  shapes; the legacy `adjust` uses `h.delay` (its total) and liveness is `group[h] == true`.

## Baseline: the IB prototype (`research/scratch/algos/bench-run3.txt`, block "IB indexed binary")

| Phase | IB prototype | §10 target factor | Veron target |
|---|---|---|---|
| P1 arm 10k | 254 ns/op | 1.2× | ≤ 300 ns/op |
| P2 200 idle updates, 10k armed | 0.02 µs/update, 0 KB | 2×, 0 B exactly | ≤ 0.04 µs/update |
| P3 10k stops | 121 ns/op, max stop 1 µs | flat, no spike > 0.2 ms | spike ≤ 200 µs |
| P4 10k adjusts | 192 ns/op, max adjust 4 µs | size stays 10k | spike ≤ 200 µs |
| P5 10k resets | 135 ns/op | size stays 10k | — |
| P6 fire storm 10k | 295 ns/dispatch | 1.2× | ≤ 354 ns/dispatch |
| P7 10k recurring × 600 | 66.5 µs/update, 370 ns/fire, 0 KB | garbage 0 | — |
| P8 mixed churn × 600 | 25.0 µs/update | ±15 % | ≤ 28.75 µs/update |

The §10 P2 op-count baseline the P2 line is read against: idle `Update(dt)` ≈ 6 field ops (validate, clamp
check, `_LastDt`, pause check) + 10 in `_advanceTo`, 1 call, **0 allocations**; one-shot dispatch ≈ 20
hash-field ops + O(log n) sift + 1 `xpcall`; recurring dispatch ≈ 18 hash-field ops + 1 `xpcall`; plus one
`xpcall(_pass)` + one `coroutine.running()` per non-idle pass. The prototype's idle path was ~12 ops; the
pre-fast-path design ~32 (F-PM-6).

## Numbers under Lune (2026-09-16, Lune 0.10.5 interpreter, Windows 11; `--!native` has no effect here)

Recorded run (three runs taken, all invariant checks passing in each; spread noted where it matters). The
numbers below are the pre-2026-09-17 recorded run, which still listed the now-removed P11 row; the current
suite runs 20 invariant checks, all passing:

| Phase | Result | Invariants | Target |
|---|---|---|---|
| P1 arm 10k random dues | 3.97 ms, **397 ns/op**, **629 B/handle** (literal 560 B + heap slots) | heap 10000, Validate ok; 560 ≤ B/handle ≤ 560 + 128 | 300 ns: MISSED (see below) |
| P2 200 idle updates, 10k armed | 0.009 ms, **0.046 µs/update**, **0 B** | garbage 0 B exactly; nothing dispatched | 0.04 µs: MISSED by clock resolution (9 µs / 200) |
| P3 10k shuffled stops | 1.93 ms, **193 ns/op**, max single stop 3.2 µs | heap 0, paused index empty, GetClocks 0, Validate | spike ≤ 200 µs: met |
| P4 10k shuffled adjusts | 1.80 ms, **180 ns/op**, max single adjust 3–17 µs | heap stays 10000 (no orphans), Validate | spike: met |
| P5 10k shuffled resets (after `Update(5)`) | 1.62 ms, **162 ns/op** | heap 10000, nothing fired, Validate | — |
| P6 fire storm 10k in one update | 3.28 ms, **328 ns/dispatch** (348–362 in other runs) | all fired, Dispatched 10000, ValveHits 0, heap 0 | 354 ns: met (borderline) |
| P7 10k recurring × 600 @ 1/60 | 39.0 ms, **65.0 µs/update**, **356 ns/fire**, 109 497 fires/run, **0 B** | garbage 0; Dropped 0; ValveHits 0; 10000 recurring | (IB 66.5 µs) |
| P7b tie-heavy 10k recurring, equal period, 100 updates @ 1/64 | 158 ms, 1582 µs/update, **316 ns/fire**, 500 000 fires/run, 0 B | every handle fires every 2nd update; Dropped 0 | decides Id-on-handle: kept (§10 note) |
| P8 mixed churn × 600 (50 arms / 20 stops / 10 adjusts / ~50 fires) | 17.7 ms, **29.5 µs/update** (30.7–33.5 in other runs), size after 2401 | ValveHits 0, Errors 0, Validate | 28.75 µs: MISSED by 3 % |
| P9 adjust storm × 10 rounds | 17.4 ms total, max round 1.84 ms, max single op 4.4 µs (95 µs once) | heap 10000 after, nothing fired | no rebuild spikes |
| P10 dual-call overhead | `s.delay` 259 ns, `s:Delay` 244 ns, raw dict 200 ns → **+44…+58 ns** (+53…+92 in other runs) | — | +30 ns: MISSED |
| P12 re-entrancy tax | depth 0 330 ns/dispatch vs depth 1 328 ns/dispatch (**−0.6 %**, −4.7…−3.6 % in other runs) | all 10000 fired inside the nested pass, Reentries 1, ValveHits 0 | identical within noise: met |
| P15 construct + destroy 1k instances | construct **6.7 µs/instance**, **~6.0–6.7 KB/instance resident**, destroy 0.27 µs/instance | every instance destroyed | (§3.2 expected ~7–9 KB) |

P11 and P13 do not exist (phase ids are stable across revisions, §10). P11 was the handle-literal vs
BaseClass `Class:new` construction comparator; it was removed on 2026-09-17 with the BaseClass dependency
(the numbers it once reported — literal ~126 ns / 560 B vs `Class:new` ~735 ns / 560 B, ratio ~0.17 —
justified building handles as plain literals rather than through a class constructor, a decision now
permanent in the source). The suite dropped from 21 to **20 invariant checks** with its removal.

### Legacy comparison (P14, `reference/lune/Tick.luau`, same seed, same shapes)

| Shape | Legacy Tick | Veron | Ratio |
|---|---|---|---|
| P2 200 idle updates, 10k armed | **144.5 µs/update** (O(n) walk of every clock), 0 B | 0.046 µs/update, 0 B | **~3100×** |
| P7 10k recurring × 600 @ 1/60 | 153.0 µs/update, 838 ns/fire, 0 B | 65.0 µs/update, 356 ns/fire, 0 B | **2.4×** per update, 2.4× per fire |
| P8 mixed churn × 600 | 236.5 µs/update (221–227 in other runs) | 29.5 µs/update | **8.0×** (6.6–7.4 in other runs) |

Both cores are zero-garbage on the idle and steady recurring paths; the legacy P8 net growth reads lower
than Veron's only because its window runs 8× longer and the collector catches up inside it.

### Reading the missed targets (all timing-only; no invariant failed)

- **P1 397 vs 300 ns**: the prototype's P1 pushes a pre-built table; `Delay` also validates (`typeof`,
  `tonumber`, finite checks — the legacy templates), calls `coroutine.running()` for `_clockOf` (R-D), goes
  through the dual closure (+~50 ns, P10) and builds the 14-key literal (~126 ns, the handle-literal build
  cost P11 once isolated). 397 − 126 − 50 ≈ 220 ns
  is below the prototype's push alone; the design's cost lands where §4.1 says it does.
- **P2 0.046 vs 0.04 µs**: 200 idle updates take 9 µs; `os.clock()` resolution under Lune makes the last
  digit noise. Garbage is exactly 0 B, which is the hard assertion.
- **P8 29.5 vs 28.75 µs**: within run-to-run spread of the prototype itself (bench-run1/2/3 of the prototype
  read 21.5–25.0 µs for the same phase).
- **P10 +44…+58 vs +30 ns**: the D15 dual closure is a vararg shim (`function(first, ...)`), and a vararg call
  costs ~40–50 ns in the Lune interpreter regardless of the check inside. Native Studio numbers (where
  `--!native` applies to the class but not to the closure) are the ones to read; a fixed-arity closure per
  member would be a design change (§3.2 fixes the shim shape) and is not applied.

### Sizes

- The §3.1 handle literal measures **560 B** under Lune 0.10.5, not the 576 B the design quotes (Luau's
  table header is 48 B here + 16 × 32 B nodes = 560; the design's figure assumes a 64 B header). Either way it
  is one 16-node hash part with two free slots: `alloc_spec :: one table per Delay` asserts the literal ≤ 576
  and that a `Delay` allocates exactly the literal and nothing else.
- P1's 629 B/handle = 560 B literal + ~69 B of `_Due`/`_Item` slots (two TValue arrays that double on the way
  to 10k; the superseded copies count until collected).
- P15's ~6–7 KB resident per instance is the 34 dual closures + the ~90-key instance table + 4 side tables
  (`_Due/_Item/_Paused/_Children`), below the ~7–9 KB §3.2 expected; API.md quotes the rule that follows
  (one `Drive`n child per subsystem, not one Veron per entity).

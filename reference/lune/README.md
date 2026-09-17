# reference/lune

Lune-runnable copies of the live TickAPI family, used as the parity oracle in
`build/tests`. Evidence only — never `require` anything under `reference/` from
`build/src`.

## Tick.luau

- **Origin:** `reference/live/Tick.luau` (hashes in `reference/live/SOURCES.md`).
- **Only change:** the single line `local RunService = game:GetService("RunService")`
  was removed (it was line 11 in the live file and was never used). The live file
  is otherwise copied byte for byte, including the leading `--!native` directive,
  which Lune accepts. No header comment is added so the copy stays line-aligned
  with the live source apart from that one removed line.
- **Purpose:** the live `Tick` core runs under Lune unchanged in behavior, so
  parity tests and benchmarks can compare the old and new schedulers side by side.
- **Faithfulness is verified** by `build/tests/spec/legacy/tick_reference_spec.luau`,
  which reads both files, removes that one line from the live text, and compares
  the remaining lines one by one before exercising the behavior.

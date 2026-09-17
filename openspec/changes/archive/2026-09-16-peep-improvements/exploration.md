# Exploration: peep-improvements

## Current State

Two Zig executables share one `zaudio` dependency:

- **`peep`** (`src/peep.zig`) — the interactive app. Spawns `yazi` (STDIN/OUT/ERR inherited), waits 100ms blindly via `std.Io.sleep`, then spawns `ya sub hover` (stdout piped). Reads DDS hover lines from the pipe and plays a sound when the hovered file is audio. `processLine` is a hand-rolled `"url":"` substring parser on the raw line buffer.
- **`peak`** (`src/peak.zig`) — the CLI waveform tool. Reads an audio file via `zaudio.Decoder`, buckets peak amplitudes into `ImageWidth` buckets, then either renders a PNG (regular path) or emits a Kitty Graphics image (only when `--png` is NOT passed). The PNG path uses a fully hand-rolled zlib "stored"-block writer.
- `src/peep-standalone.zig` — a 28-line variant that plays a file directly (no yazi/DDS). **Not referenced anywhere in `build.zig`.** Purely dead weight.

`build.zig` wires two installable executables plus a `test` step (added recently, commits pending as `M build.zig`): a `std.Build.Step.Compile` test artifact from `src/tests.zig`, with a `test` step that runs it. A minimal `src/tests.zig` exists ("harness sanity"), but `peak` and `peep` are NOT split into testable units — no functions are exported for the test module, so today `zig build test` can only validate the throwaway harness.

## Affected Areas

- `src/peak.zig` — every item splits sound-related "peep" concern from `peak`, plus PNG compression rewrite.
- `src/peep.zig` — DDS event parsing (`item H`), yazi spawn race (`item F`), argv passthrough (`item G`).
- `build.zig` — no structural change expected; the executable/test wiring already exists, tasks can add a `split`/`--png`-behavior flag if needed.
- `src/peak.zig` comment text — the stale `800x200 / 320,200 bytes` comment becomes arithmetically correct *after* `item A` applies (see below), but the label "800x200" is wrong and must become "400x200".
- `src/peak.zig` compress internals — hand-rolled zlib stored-block path (decimal `max_block_size` = 65535, raw zlib header 0x78 0x01, 5-byte-per-block stored headers, manual Adler-32) is entirely replaceable by `std.compress.flate`.

## Approaches

### 1. **Peer executive (lenient single commit)** — do A+I, then B+C+D together as one unit, then F in `peep.zig` as a second unit
   - Pros: PNG size drop + compression swap + dead-code removal are one logical "cleanup of the PNG writer"; one reviewer pass.
   - Cons: Mixes "feature-ish" (PNG dims change perceptual output) with cleanup (dead code) — 400-line guard still safe, but scope grows.
   - Effort: Medium

### 2. **Strict seam-driven TDD** (recommended) — extract testable seams first, then apply each item as a TDD step
   - Pros: Matches the active `strict TDD` config; `peak`'s amplitude decomposition and `peep`'s line parser become unit-testable before the destructive rewrites; the `ya sub` sender-scoping and flate compression each get a focused red-green-red.
   - Cons: Slightly more upfront refactor before behavior ships; the `flate` swap needs a round-trip test (compress→decompress) which is entirely new.
   - Effort: Medium-High

### 3. **Atomic one-per-commit** — every item as its own commit + test
   - Pros: Cleanest diffs, easiest git history reading per change.
   - Cons: `B`, `C`, `D` all touch the same PNG body and cannot be cleanly interleaved; many tiny commits for a 400-line change inflate review turns.
   - Effort: Medium

## Recommendation

Plan the change as **approach 2** (strict TDD path) but shaped for fast delivery:

- **How it folds (verifiable by exploration):**

  | Item | Recom. | Notes |
  |---|---:|---|
  | A | do now | Halve both dims (800→400, 400→200). Output drops 1,280,400→320,200 bytes (~4x). Amplitude bucket count becomes 400 (silence-detection granularity halves as expected — confirm this is desired). |
  | B | do now | Remove `writeKitty`/`renderKitty` and the `--png` flag; PNG becomes the only output. Also fix the stale comment. |
  | C | do now | Replace the hand-rolled stored-block zlib writer with `std.compress.flate` (available in this Zig). **Side effect that makes A's comment correct:** with `flate`, `raw_size` math (`ImageHeight * (1 + ImageWidth*4)`) is unchanged, so the comment needs its label only. Verify in tests. |
  | D | do now | `crc32` wrapper fn is truly unused (only def + its own inner `crc32Update`); `writePngChunk` calls `crc32Update` directly. Delete `crc32`; keep `crc32Update`. |
  | E | do now | Delete `src/peep-standalone.zig`; no references anywhere, not even a build step. Safe removal. |
  | F | careful | Replace the blind 100ms sleep with a retry-spawn loop (spawn `ya sub`, grace 100-150ms, non-blocking `waitpid` `WNOHANG` check, ~5s deadline, exponential backoff). **The current code waits for `yazi` to finish via the external `waitForYazi` helper; this must be preserved or the process will zombie.** Nonblocking wait in Zig's std is raw `waitpid(WNOHANG)` — not exposed by std, must call the syscall directly. |
  | G | do now | Forward all argv after the program name, exactly like yazi. Currently arg parsing is URL/`--png`-only. |
  | H | careful | Start yazi with a unique `--client-id` and filter `ya sub` hover lines by the 3rd comma field — but **verify the DDS protocol**: this needs the sender field to be reliably present/populated on `hover` lines, otherwise scoping silently drops all hovers. |

- **Test seams to extract (bounded, matching the new `test` step):**

  1. `src/peak.zig`: extract `amplitudeBuckets(frames, channels)` → `[]f32` (pure, no IO), the Zlib→DEFLATE-written raw block math (pure), and an optional `flate round-trip` (compress→decompress) test. Each is inert until the write `Writer` abstraction is added.
  2. `src/peep.zig`: extract `parseLine(line) ?AudioRef` — pure parser returning "ignore / play / stop" decisions given a hover line. This is the same seam needed by `item H` (sender-scoping) and makes the sender-filter logic testable without spawning yazi.

  This keeps all TDD steps in-memory, with no fixture files.

## Risks

- **`item C` std version drift:** `std.compress.flate` API in a dev build changes between releases; verify the exact `flate.init` / `flate.finish` / `Options` names in the pinned Zig before changing `peak.zig`.
- **`item F` nonblocking wait is a raw syscall.** Zig std does not expose `waitpid`-based child polling in the `process.Child` API; implement WNOHANG directly or the child may die unobserved.
- **`item H` DDS framing.** If `ya sub hover` doesn't emit the sender field exactly as `kind,receiver,sender,json`, sender-filtering breaks; requires a live yazi instance to confirm (interactive).
- **`item A` changes visual output** — a behavioral not just structural change; confirm the user wants the perceptual consequence (halved silence granularity, smaller image).

## Ready for Proposal

Yes — with the caveat that the proposal should explicitly note:
1. `item C` + `item A` interact on the stale comment; the number becomes right but the label must change.
2. `items F` and `H` carry platform/runtime risk and should be sequenced last, behind the pure refactors.
3. The plan gains a dedicated `src/tests.zig` migration to `src/peak.test.zig` / `src/peep.test.zig` with the two extracted seams above.

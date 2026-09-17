# Proposal: peep-improvements

## Intent

Peep's watcher races yazi via a blind 100ms sleep; dead code remains (Kitty path, `crc32`, standalone); the PNG writer is 4x oversized.

## Scope

### In Scope
- (A) Waveform 800x400 → 400x200 (~4x smaller)
- (B) Remove Kitty graphics path + `--png` flag; PNG-only
- (C) Replace hand-rolled zlib writer with `std.compress.flate`
- (D) Delete dead `crc32`; keep `crc32Update` (`writePngChunk` user)
- (E) Delete `src/peep-standalone.zig` (unreferenced in build.zig)
- (F) Retry-spawn `ya sub hover`: 100-150ms grace, `wait4` WNOHANG probe, ~5s deadline + backoff, hand-clean reaped Child, serialize kill hand-over
- (G) Forward argv to spawned yazi
- (H) Spawn yazi with `--client-id`; filter `ya sub` lines by sender
- (I) Fix stale `800x200` comment → `400x200`

### Out of Scope
- `--local-events`/`--remote-events` alternative; non-macOS behavior; yazi source pinning beyond 26.5.6

## Capabilities

> sdd-spec contract — `openspec/specs/` empty; all new, none modified.

### New Capabilities
- `waveform-rendering`: peak emits 400x200 PNG-only waveform, flate IDAT — A–D, I (E: cleanup, no spec requirement).
- `yazi-integration`: spawn yazi (argv, client-id), retry `ya sub hover` until live, sender-matched hovers — F–H.

### Modified Capabilities
None.

## Approach

Strict TDD, gate `zig build test`. Extract seams, then red-green each item:
- `peak.zig`: extract `amplitudeBuckets`; flate round-trip test; apply A, C, D, B, I.
- `peep.zig`: extract `parseLine(line, sender)`; apply G, H; then F per L1-D: rc==0 keep, rc==pid respawn + hand-clean (close stdout File, null id/stdout), rc==-1 ECHILD stop; retry-settle gates kill path (L1-5 race).

## Affected Areas

- `src/peak.zig` — Modified: dims, flate writer, kitty/--png removal, `crc32`, comment
- `src/peep.zig` — Modified: argv forward, client-id, retry-spawn, sender filter
- `src/peep-standalone.zig` — Removed: dead file
- `src/tests.zig` → `src/peak.test.zig`, `src/peep.test.zig` — Modified: seam unit tests
- `build.zig` — Minor: test step for new seams

## Risks

- Med — WNOHANG reap → stale `kill()` assert / SIGTERM dead pid; L1-5 hand-clean
- Med — waitForYazi race reaps hover mid-retry; retry-settle signal first
- Low — sender filter drops hovers; sender == client-id at 26.5.6 (L2-3)
- Low — `flate` API drift; round-trip test + pinned build.zig.zon
- Low — older yazi without `--client-id`; flagless fallback in design

## Rollback Plan

`git revert <commit>`. Dims/comment via constants; kitty/`crc32`/standalone recoverable from history; retry loop reverts to 100ms sleep.

## Dependencies

- Zig 0.17.0-dev.1099+7db2ef610: `std.compress.flate`; `std.posix.system.wait4` (±libc)
- yazi ≥ 26.5.6: `--client-id`; DDS wire `kind,receiver,sender,{json}` (Lane 2)

## Success Criteria

- [ ] `zig build test` green with new seam tests
- [ ] peak: 400x200 PNG, flate IDAT, no kitty/`--png`, comment fixed
- [ ] peep: argv + client-id passed; `ya sub` settles <5s; hover works; plain spawns; no zombies
- [ ] `crc32` and `src/peep-standalone.zig` gone
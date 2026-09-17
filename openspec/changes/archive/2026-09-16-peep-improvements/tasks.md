# Tasks: peep-improvements

## Review Workload Forecast

| Field | Value |
|---|---|
| Estimated changed lines | ~680 (PR1 ~450, PR2 ~330) |
| 400-line budget risk | High |
| Chained PRs recommended | Yes |
| Suggested split | PR 1 → PR 2 |
| Delivery strategy | ask-on-risk |
| Chain strategy | pending |

Decision needed before apply: Yes
Chained PRs recommended: Yes
Chain strategy: pending
400-line budget risk: High

### Suggested Work Units

| Unit | Goal | Likely PR | Focused test command | Runtime harness | Rollback boundary |
|---|---|---|---|---|---|
| 1 | Waveform: 400x200, flate IDAT, kitty/`--png`+`crc32` removal, peak test module | PR 1 | `zig build test` | `peak <audio>`: IHDR 400x200, IDAT zlib-decodes, no kitty output | revert `peak.zig`, `peak.test.zig`, `build.zig` |
| 2 | Yazi: argv+`--client-id`, retry-spawn settle, sender filter, hand-clean, peep test module, standalone delete | PR 2 | `zig build test` | `peep` w/ yazi 26.5.6: `ya sub hover` settles <5s, hover plays, no zombies | revert `peep.zig`, `peep.test.zig`, `build.zig` |

## Phase 1: Foundation — build.zig restructure + RED tests

- [x] 1.1 Restructure `build.zig` (D6): replace `src/tests.zig` module with `src/peak.test.zig` + `src/peep.test.zig` modules, each `addTest` + `addRunArtifact` on `test` step, both importing zaudio + linking miniaudio; delete `src/tests.zig`
- [x] 1.2 RED `src/peak.test.zig`: `amplitudeBuckets` synthetic 400 buckets with known peaks + multi-channel (all channels contribute, count stays 400); flate round-trip representative + minimal, Compress→Decompress exact-equal
- [x] 1.3 RED `src/peep.test.zig`: `parseLine` own sender → url, foreign sender → null, malformed (<3 commas) → null without crash
- [x] 1.4 RED `src/peep.test.zig`: `buildYaziArgv` plain argv forward, with `--client-id`, `PEEP_NO_CLIENT_ID` env → flagless
- [x] 1.5 RED `src/peep.test.zig`: `cleanupReapedChild` — spawn `/usr/bin/true`, `wait4(WNOHANG)` reap, clean, assert id/stdout null then `kill()` no-op

## Phase 2: Waveform core — peak.zig (A, C, D, B, I)

- [x] 2.1 GREEN `src/peak.zig`: extract pure `amplitudeBuckets(a, buffer, frames, channels, width)`; `main` buckets to 400
- [x] 2.2 GREEN `src/peak.zig` `renderPng`: `std.compress.flate` per D4 — `Compress.init(&out, &window, .zlib, .default)` → `writeAll(raw)` → `finish`; delete hand-rolled stored-block zlib writer
- [x] 2.3 `src/peak.zig`: `ImageWidth` 800→400, `ImageHeight` 400→200; fix stale `800x200` comment → 400x200
- [x] 2.4 `src/peak.zig`: delete `--png` flag handling, `renderKitty`, `writeKitty`; PNG always emitted
- [x] 2.5 `src/peak.zig`: delete `crc32` wrapper fn; keep `crc32Update` (`writePngChunk` user)

## Phase 3: Yazi core — peep.zig (F, G, H)

- [x] 3.1 GREEN `src/peep.zig`: `parseLine(line, sender)` — split at 3rd comma → kind,receiver,sender,json; <3 commas or sender mismatch → null; `"url":"` extraction on json tail; `processLine` NUL-terminates returned url slot then plays/stops
- [x] 3.2 GREEN `src/peep.zig`: `buildYaziArgv(a, args, client_id)` — forward argv[1..] unchanged, prepend `yazi` + `--client-id <id>`; id = `std.crypto.random.int(u32)` ≠ 0; `PEEP_NO_CLIENT_ID=1` → flagless spawn, `sender=null`, no filtering (D1)
- [x] 3.3 GREEN `src/peep.zig`: `retrySpawnHover()` → `RetryOutcome` (D2) — grace 125ms; `std.posix.system.wait4(id, &status, W.NOHANG, null)`: rc==0 keep, rc==pid cleanup + respawn (backoff 125/250/500/1000/2000ms, ~5s deadline), rc==-1 ECHILD → stopped; deadline → gave_up
- [x] 3.4 GREEN `src/peep.zig`: `cleanupReapedChild(child)` mirrors `childCleanupPosix` — close stdin/stdout/stderr Files, null all three + `id` (D3)
- [x] 3.5 GREEN `src/peep.zig`: settle-gate (D2) — capture `stdout` File before waiter spawn; spawn `waitForYazi` thread only after settlement; ready → read loop, gave_up → join waiter (yazi keeps running), stopped → return

## Phase 4: Cleanup & verification

- [x] 4.1 Delete `src/peep-standalone.zig` (unreferenced dead file)
- [x] 4.2 Document `PEEP_NO_CLIENT_ID` env fallback (usage/README)
- [x] 4.3 `zig build test` green; grep: kitty, `--png`, `crc32(` absent; `crc32Update` present; comment states 400x200; no yazi/ya zombies after exit
```yaml
schema: gentle-ai.verify-result/v1
evidence_revision: sha256:3c8e9936b5e4b4742f99a7581b0cfbc4d6a9a5428a2c837c8fd1364d93170c42
verdict: pass_with_warnings
blockers: 0
critical_findings: 0
requirements: 14/14
scenarios: 23/23
test_command: zig build test --summary all
test_exit_code: 0
test_output_hash: sha256:f8213a0b2a1e66a9e16c1a0373c260e7cf9b85c084a568f387ed6e2f4b827d51
build_command: zig build
build_exit_code: 0
build_output_hash: sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
```

# Verification Report — peep-improvements

## Overview

Independent requirements/runtime verification of change `peep-improvements` (waveform PNG renderer + yazi audio-preview integration) in `the peep repository`, Strict TDD mode (orchestrator-declared; authoritative over `openspec/config.yaml`). Runtime attempt: `proceed`, work-unit `verify-change`. Evidence combines a fresh full-cache test run, direct test-binary execution, a structured PNG binary audit of `peak` output, and the first-ever **live yazi end-to-end runs** (settle, respawn, and deadline paths) — closing research open question G5.

## Completeness

| Artifact | Status |
|---|---|
| Proposal | present |
| Specs (`waveform-rendering`, `yazi-integration`) | present — 14 requirements, 23 scenarios (rg heading count) |
| Design | present — D1–D6 |
| Tasks | 18/18 checked (apply progress, Engram obs #39) |
| Tests RED→GREEN | verified (below) |
| Build | verified (below) |

## Build & Tests

| Check | Command | Exit | Evidence |
|---|---|---|---|
| Full cache wipe + rebuild | `zig build` | 0 | output empty; `build_output_hash` above |
| Test step (fresh compile, no cache) | `zig build test --summary all` | 0 | 7/7 steps success; compile Debug native; `test_output_hash` above |
| Direct peak test binary | `.zig-cache/o/b545bb…/test` | 0 | 4/4 OK: amplitudeBuckets x2, deflateZlib x2 |
| Direct peep test binary | `.zig-cache/o/777e07…/test` | 0 | 12/12 OK: parseLine x5, buildYaziArgv x3, resolveClientId x3, cleanupReapedChild x1 |
| Formatting | `zig fmt --check` (5 files) | 1 | all 5 files non-conformant → W2 |
| Coverage | `--coverage` flag | unsupported | toolchain lacks it; threshold 0; coverage skipped (not a failure) |

`evidence_revision` = sha256 over the concatenated byte streams of (build stdout, test stdout, peak test binary stdout, peep test binary stdout).

### PNG runtime audit (`peak /tmp/peep-e2e.wav > /tmp/peep-e2e.png`, exit 0, 3989 bytes)

- IHDR: width 400 (0x190), height 200 (0xC8) — fixed canvas ✓
- IDAT begins `0x78 0x9c` (zlib DEFLATE wrapper) → flate compression ✓
- `zlib.decompress(IDAT)` = 320,200 bytes = 200 × (1 + 400 × 4) exactly — RAW RGBA rows match the 400×200 canvas ✓
- All chunk CRCs valid (independent recompute) ✓
- 46,000 non-zero pixels (waveform drawn), all filter bytes 0x00 ✓

### Live yazi E2E (user's yazi untouched; dedicated PTY harness)

| Run | Observation |
|---|---|
| Hover settle | `peep /tmp/peep-e2e-dir` spawned `yazi --client-id 633337847 …`; external `ya sub hover` captured real wire bytes `hover,0,633337847,{"tab":1,"url":"/tmp/peep-e2e-dir/two.wav"}` — exact `kind,receiver,sender,{json}` shape, sender == client-id (closes G5). `{"tab":1,"url":null}` lines ignored without crash. Exactly one live subscriber at t=4s → settled `.ready` on first probe. Exit 0, no leftovers/zombies. |
| argv forwarding | `--cwd /tmp/peep-e2e-dir` reached yazi 26.5.6 unchanged → rejected: `unexpected argument '--cwd' found` (tip: `--cwd-file`). Forwarding proven; positional entry works. |
| Respawn (rc==pid) | stub `ya` fails first 2 spawns → exactly 3 spawn attempts (backoffs 125/250/500ms), real subscriber connected, exit 0, no leftovers. |
| Deadline (gave_up) | always-failing stub → alive at t=4.5s (deadline ~3.9s passed), yazi kept running (`--client-id 2692839476`), `ya` attempts stopped at 6, exit 0 after yazi quit, no leftovers/zombies. |
| Client-id uniqueness | 6 distinct ids across 6 launches (633337847, 1350250706, 1268241912, 709196967, 157465479, 2692839476). |
| Audio path | any `createSoundFromFile`/`start` failure would make main exit non-zero; all hover-carrying runs exited 0 → sound create+start proven (acoustics unobservable headlessly). |

## Spec Compliance Matrix

### waveform-rendering (6 requirements / 10 scenarios)

| Requirement | Scenario | Status | Evidence |
|---|---|---|---|
| Fixed 400x200 PNG canvas | Nominal render | PASS | PNG audit IHDR 400×200; bytes 320,200 exact |
| Fixed 400x200 PNG canvas | Comment accuracy | PASS | peak.zig:210 "For 400x200 this is 320,200 bytes." |
| PNG-only output | Default invocation emits PNG | PASS | PNG audit (IDAT/CRCs, no terminal kitty) |
| PNG-only output | Kitty path absent | PASS | grep: `kitty` absent; `--png` absent |
| flate-compressed IDAT | IDAT uses flate | PASS | IDAT `0x78 0x9c`; decompress round-trip (tests 3–4) |
| flate round-trip integrity | Representative round-trip | PASS | test `deflateZlib: representative raster…` OK |
| flate round-trip integrity | Minimal input round-trip | PASS | test `deflateZlib: minimal…` OK |
| crc32 removal | Function absence and presence | PASS | `crc32(` absent; `crc32Update` at peak.zig:372/377/406 |
| amplitude bucketing seam | Synthetic frames | PASS | test `amplitudeBuckets: width buckets…` OK |
| amplitude bucketing seam | Multi-channel frames | PASS | test `amplitudeBuckets: all channels…` OK |

### yazi-integration (8 requirements / 13 scenarios)

| Requirement | Scenario | Status | Evidence |
|---|---|---|---|
| argv forwarding | Arguments reach yazi | PASS | live: `--cwd` forwarded unchanged (yazi rejected it) |
| globally-unique client-id | Unique per launch | PASS | live: 6 distinct ids / 6 launches; unit `resolveClientId` |
| sender-scoped hover filtering | Own hover line | PASS | unit `parseLine` own-sender x2; live: captured sender == client-id |
| sender-scoped hover filtering | Foreign sender | PASS | unit `parseLine: foreign sender -> null` |
| sender-scoped hover filtering | Malformed line | PASS | unit `parseLine: malformed -> null` (no crash) |
| retry-spawn of hover subscriber | Subscriber connects | PASS | live: settled `.ready` first probe; single subscriber |
| retry-spawn of hover subscriber | Subscriber exits early | PASS | live: respawn run — 3 attempts, reconnect |
| retry-spawn of hover subscriber | Already reaped | COMPLIANT (vacuous) | GIVEN presumes the yazi-exit path reaping during the retry loop — structurally impossible: that reaper is gated behind settlement (D2). Defensive branch present (`rc==-1` → cleanup → `.stopped`, peep.zig:195-198); consequence chain (cleanupReapedChild, kill no-op, shutdown) runtime-covered by test 12 and live runs |
| retry-spawn of hover subscriber | Deadline exceeded | PASS | live: gave_up run — retrying stopped, yazi kept running, exit 0 |
| hand-clean of reaped children | Respawned child cleanup | PASS | unit `cleanupReapedChild` (spawn `/usr/bin/true`, WNOHANG-reap, id/stdio nulled, kill no-op); live respawn run |
| serialized kill hand-over | Settlement before kill | PASS | D2 structure (last hover write happens-before `std.Thread.spawn`; only waiter mutates `hover` after settle); runtime consistent — no crash/no double-reap |
| single reap, no zombies | Clean shutdown | PASS | live: all runs exit 0, zero leftovers, zero zombie processes |
| flagless fallback for older yazi | Fallback spawn | PASS | unit `resolveClientId` PEEP_NO_CLIENT_ID→null x3 + `buildYaziArgv` flagless; README documents it |

## Correctness

| Severity | Finding |
|---|---|
| CRITICAL | none |
| WARNING | **W1 — exit-race panic (pre-existing pattern).** If yazi exits while peep is blocked in the hover read, the waiter's `hover.kill(io)` → `childCleanupPosix` closes the read fd (`const stdout = hover.stdout` is an fd-number copy, not a dup); the read returns a non-EOF error, `return err` skips `stopSound()`, and unwinding trips a Debug assert in `zaudio.deinit` (`mem_allocations.?.count() == 0`, zaudio.zig:24) → `reached unreachable code`, exit 6. Reproduced 2/3 quick-quit runs; **identical pattern exists in HEAD's peep.zig** (pre-existing; this change preserves it). Not spec-breaking; suggest dup()-ing the fd or treating read errors as EOF / ensuring `stopSound` on the error path. |
| WARNING | **W2 — `zig fmt --check` fails on all 5 changed files** (build.zig, src/peak.zig, src/peep.zig, both test files). Style convention non-compliance only; no behavior impact. |
| WARNING | **W3 — README example broken on pinned yazi.** `peep --cwd /path/to/dir` (README:14) fails on yazi 26.5.6 (live-proven: `--cwd` unsupported; `--cwd-file`/positional only). Source example `peep /some/absolute/path` is correct. |
| SUGGESTION | **S1 — coverage unavailable**: `zig build test --coverage` unrecognized in Zig 0.17.0-dev.1099; threshold 0, skipped (not a failure). |
| SUGGESTION | **S2 — stale cached test binaries can mislead**: a pre-wipe cached peak test binary panicked at peak.test.zig:100 (`defer allocator.free`); full `.zig-cache` wipe produces the green build. |
| SUGGESTION | **S3 — ECHILD arm is unreachable by construction** (see compliance matrix): its GIVEN presupposes the yazi-exit reaper racing the retry loop, which D2 eliminates; the branch is defense-in-depth. Exercising it would require reintroducing the race D2 was designed to remove — recommend documenting this rather than testing it. |

## Design Coherence

| Decision | Verified |
|---|---|
| D1 flagless fallback (`PEEP_NO_CLIENT_ID`) | PASS — unit x3 + argv tests; README documents |
| D2 settle-gated waiter, terminal `RetryOutcome` | PASS — code matches; live settle/respawn/gave_up; ECHILD arm compliant-vacuous (see matrix) |
| D3 `cleanupReapedChild` mirrors `childCleanupPosix` | PASS — unit test 12; live no-leak/no-zombie |
| D4 flate via `Compress`/`Decompress` (.zlib) | PASS — unit round-trips + PNG audit (0x78 0x9c, CRCs) |
| D5 `parseLine`/`buildYaziArgv` shapes | PASS — 5+3 unit tests; live wire bytes match exact format |
| D6 two test modules on `test` step | PASS — build.zig:22-35; 16 tests executed |

## Strict TDD Compliance

- **RED**: test files exist (src/peak.test.zig, src/peep.test.zig) with all planned seam cases; apply-progress TDD cycle table logged RED-first per task.
- **GREEN**: independently re-run — peak 4/4, peep 12/12, fresh cache, exit 0.
- **TRIANGULATE** (counts per task match runtime): peak amplitudeBuckets 2 (width/multi-channel), deflateZlib 2 (representative/minimal); peep parseLine 5, buildYaziArgv 3, resolveClientId 3, cleanupReapedChild 1.
- **SAFETY NET / REFACTOR**: baseline claims recorded in apply-progress; GREEN re-verified on current tree.
- **Assertion audit**: no ghost loops (loop-carried asserts have post-loop checks; fixed-size buckets asserted non-empty before value assertions), no tautologies (all `expectEqual` on concrete values), no mocks, no orphan-empty cases (minimal-input test paired with representative non-empty test). cleanupReapedChild uses a real subprocess (`/usr/bin/true`) with a bounded reap loop and a post-loop `expect(reaped)`.

## Verdict

**PASS WITH WARNINGS** — 0 blockers, 0 CRITICAL, 0 crashing check failures. 14/14 requirements satisfied; 23/23 scenarios complete — every observable behavior verified at runtime, and the single structurally-impossible scenario ("Already reaped") satisfied by construction under D2 with its consequence chain runtime-covered (see matrix). No source code was modified during verification. Recommended next: orchestrator settlement; then `sdd-archive`. W1 (pre-existing exit-race panic), W2 (`zig fmt`), and W3 (README example) are follow-up candidates, none blocking this change's acceptance.
# Design: peep-improvements

## Technical Approach

Seam-extraction TDD (approach 2). **peak**: extract `amplitudeBuckets`; 400x200; `std.compress.flate` (`.zlib`) IDAT; drop kitty + `--png`; delete `crc32`; fix comment. **peep**: extract `parseLine(line, sender)`; forward argv + `--client-id`, fallback via `PEEP_NO_CLIENT_ID`; retry-spawn `ya sub hover` with WNOHANG probes (L1-3/L1-D); hand-clean reaped Children (L1-5); gate the kill path behind retry settlement. Delete standalone + old tests.

## Architecture Decisions

| # | Choice | Alternatives (tradeoff) | Rationale |
|---|---|---|---|
| **D1** | Default: pass `--client-id`. Env `PEEP_NO_CLIENT_ID=1` → flagless spawn, `sender=null`, no filtering | Version-probe binary (costly/racy, L2-n) | Spec needs the flagless path; no cheap robust probing. Old yazi fails fast (README); env set + new yazi accepts all hovers |
| **D2** | `retrySpawnHover()` returns terminal `RetryOutcome`; `waitForYazi` thread spawned only after settlement; main reads a `stdout` File captured before waiter spawn | Mutex/condvar handshake; atomic settle flag + spin (bounded 5s) | Loop's last `hover` write happens-before `std.Thread.spawn`; after settle only waiter mutates `hover` → race-free, no atomics. ECHILD arm defensive → `stopped` (waiter absent during loop; L1-D provenance impossible) |
| **D3** | `cleanupReapedChild()` mirrors `childCleanupPosix` (Threaded.zig:15521): close non-null stdin/stdout/stderr `File`s, null all three + `id` | std helper is private | `kill()` then no-ops (Child.zig:131) without the `id==null ⇒ stdio null` assert (Child.zig:134); `defer hover.kill` safe |
| **D4** | `Compress.init(&out, &window, .zlib, .default)` → `c.writer.writeAll(raw)` → `c.finish()`; decompress via `Decompress.init(&reader, .zlib, &window)`, read `.reader` (Compress.zig:303,363; Decompress.zig:1143-1182) | — | Verified installed std; `out` = stdout `Writer`, buffer > 8B; `window` ≥ `max_window_len`; round-trip seam pins API drift (spec risk 4) |
| **D5** | `parseLine(line, sender)`: split at 3rd comma → kind,receiver,sender,json; <3 commas → null; sender mismatch → null; else `"url":"` extraction on json tail. `buildYaziArgv`: forward argv[1..] unchanged, prepend `yazi` [ `--client-id` id ]; id = `std.crypto.random.int(u32)` ≠ 0 | — | sender == client-id (L2-3); fallback passes `sender=null` |
| **D6** | Two test modules `src/peak.test.zig`, `src/peep.test.zig`: each `addTest` + `addRunArtifact`, both on `test` step (build.zig:22-35); both import zaudio + link miniaudio | Single module importing both test files (couples peak/peep) | Confirmed 0.17 pattern; delete `src/tests.zig` |

## Data Flow

```
retrySpawnHover: grace 125ms; backoff 125/250/500/1000/2000ms; deadline ≈5s
  spawn "ya sub hover" (stdout.pipe) → hover: Child
  sleep; wait4(hover.id, W.NOHANG)
    rc==0 → keep → ready      rc==pid → cleanupReapedChild, respawn → loop
    rc==-1 → cleanupReapedChild → stopped      deadline → gave_up
settled → capture stdout → spawn waitForYazi (yazi.wait → hover.kill)
  ready → read loop (existing)   gave_up → join waiter (yazi keeps running)
  stopped → return (shutdown)
```

Single-reap invariant: probe reaps rc==pid children; yazi + kept hover reaped by waiter; `kill()` no-ops after clean.

## File Changes

| File | Action | Description |
|---|---|---|
| `src/peak.zig` | Modify | 400x200 + comment; drop kitty/`--png`; flate IDAT; delete `crc32`; extract seam |
| `src/peep.zig` | Modify | `parseLine`, `buildYaziArgv`, env fallback, retry loop, hand-clean, waiter-after-settle |
| `src/peak.test.zig` | Create | bucketing + flate round-trip tests |
| `src/peep.test.zig` | Create | parseLine/argv/hand-clean tests |
| `src/tests.zig` | Delete | superseded |
| `src/peep-standalone.zig` | Delete | dead, unreferenced |
| `build.zig` | Modify | two test modules + run artifacts |

## Interfaces

```zig
pub fn amplitudeBuckets(a: std.mem.Allocator, buffer: []const f32,
    frames: u64, channels: u32, width: usize) ![]f32;
pub fn parseLine(line: []const u8, sender: ?[]const u8) ?[]const u8;
pub fn buildYaziArgv(a: std.mem.Allocator, args: anytype,
    client_id: ?[]const u8) ![][]const u8;
fn cleanupReapedChild(child: *std.process.Child) void;
const RetryOutcome = enum { ready, gave_up, stopped };
```

`amplitudeBuckets` returns `width` buckets, max across channels. `processLine(line, sender)` calls `parseLine`, NUL-terminates the returned url slot, then plays/stops.

## Testing Strategy

| Layer | What to Test | Approach |
|---|---|---|
| Unit (`peak.test.zig`) | `amplitudeBuckets` synthetic + multi-channel (waveform scenarios); flate round-trip representative + minimal  | in-memory, Compress→Decompress exact-equal |
| Unit (`peep.test.zig`) | `parseLine` own/foreign sender, malformed no-crash (yazi scenarios); `buildYaziArgv` plain/flag/env | pure |
| Unit | `cleanupReapedChild` + `kill()` no-op | spawn `/usr/bin/true`, WNOHANG-reap, clean, assert id/stdout null |
| E2E | wait4 semantics | probe-verified (G1); live hover capture once (interactive) |

## Threat Matrix

Rows 1-5: **N/A** — no routing/VCS/PR automation.

| Boundary | Minimum adversarial cases | Applicability | Design response | Planned RED tests |
|---|---|---|---|---|
| Subprocess spawn & argv | plain spawn; forwarded flags; `--client-id`; env fallback; hover spawn; reap → hand-clean → kill no-op | **Applicable** — composes spawn argv | argv from pure `buildYaziArgv`; probe sole reaper during loop; cleaned kill no-op | argv cases; parseLine malformed; cleanupReapedChild |

## Rollout

No data migration. `PEEP_NO_CLIENT_ID` documented. Rollback: `git revert`; retry loop degrades to 100ms sleep.

## Open Questions

- Live hover-line bytes never captured (research G5): `"url":"` on json tail is code-empirical; RED tests pin `kind,receiver,sender,{json}`; verify against a real hover event.
- None blocking design.
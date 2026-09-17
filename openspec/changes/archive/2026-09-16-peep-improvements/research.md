# Research — peep-improvements

Phase: `sdd-research` (executor role, delegate_only)
Research date: 2026-09-16
Change: `peep-improvements`
Store: openspec

## 1. Runtime declaration of this phase

- Capability: `gentle-ai.sdd-research-capability/v1`
- Declared evidence grants: `documentation=[]`; `open-web=[]` (no docs-library or web grant)
- Available tools: file read/grep/glob/write only; **no execution tool, no persistence tool used**
- Consequence: nothing was *run* this phase (no compile, no binary invocation). All claims are
  grounded in installed files (Zig std source, peep repo) read directly, plus negative filesystem
  probes. Claims that need execution are explicitly marked `NEEDS-EXEC` and listed in §7 Gaps.
- Toolchain: Zig `0.17.0-dev.1099+7db2ef610` at
  `~/.local/share/mise/installs/zig/0.17.0-dev.1099+7db2ef610`
  (all std paths below are relative to `lib/std/` inside that install)

## 2. Lane 1 — nonblocking child-status check in this Zig

### L1-A: Does `std.process.Child` expose any nonblocking/poll seam? — NO

- `std/process/Child.zig` (full file, 157 lines) exposes exactly two lifecycle operations:
  `pub fn kill(child: *Child, io: Io) void` (Child.zig:134) and
  `pub fn wait(child: *Child, io: Io) WaitError!Term` (Child.zig:150). The doc comment on `wait`
  is "Blocks until child process terminates and then cleans up all resources" (Child.zig:149).
  There is no `poll`, `tryWait`, `isAlive`, or timeout variant.
- `id: ?Id` is nulled after `wait`/`kill` (Child.zig:19-22); POSIX `Id == std.posix.pid_t` (Child.zig:13-17).
- `std/process.zig` (full file, 1130 lines): spawn (process.zig:451), spawnPath (:459), run — a
  *blocking* spawn+collect helper (process.zig:505-558, calls `child.wait(io)` at :545), replace
  (:299), currentPath (:69). No nonblocking wait anywhere in the process namespace.
- Std's own POSIX child wait implementations confirm only blocking uses: `childWaitPosix`
  (Io/Threaded.zig:15398-15464) and `childKillPosix` (Io/Threaded.zig:15477-15518) pass flags `0`.
- Io/Threaded.zig:15419 has the `// Double-free.` marker on ECHILD — i.e. std treats a second
  wait on an already-reaped child as a bug.

**Exploration assumption confirmed**: std.posix does NOT wrap waitpid/wait4 into the Child API in
this build; a nonblocking check requires the raw seam below.

### L1-B: The raw seam, exact signatures and semantics on this toolchain (macOS)

Std's own reaping route on macOS is `wait4`:

- Io/Threaded.zig:2007-2011: `have_wait4` is `true` for
  `.driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos` — macOS included.
  `have_waitid` is Linux-only (Threaded.zig:2002-2005).
- Threaded.zig:15406-15421: when `have_wait4`, std calls
  `posix.system.wait4(pid, &status, 0, ru_ptr)` (flags 0 = blocking), drives error handling via
  `posix.errno(...)` with `.SUCCESS / .INTR / .CHILD` cases.
- `std.posix.system` is the libc-backed POSIX layer: posix.zig:26-29
  (`use_libc = builtin.link_libc or ...`), posix.zig:36-37 (`pub const system = if (use_libc) std.c ...`).
  `pub const W = system.W` (posix.zig:146), `pub const pid_t = system.pid_t` (posix.zig:171).

Target signatures (macOS, libc):

- `std.c.wait4`: `extern "c" fn wait4(pid: pid_t, status: ?*c_int, options: c_int, ru: ?*rusage) pid_t`
  (c.zig:11614), exposed as `pub const wait4 = switch (native_os) { .netbsd => ..., else => private.wait4 }`
  (c.zig:10687-10690).
- macOS `W` flags: `W.NOHANG = 0x00000001`, `W.UNTRACED = 0x00000002`
  (c.zig:3713-3742, arm for `.driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos`);
  plus `W.IFEXITED/IFSTOPPED/IFSIGNALED/EXITSTATUS/TERMSIG/STOPSIG`.
- `pid_t` on macOS = `i32` (c.zig:4289-4296).
- Direct-alternative binding also present: `pub extern "c" fn waitpid(pid: pid_t, status: ?*c_int, options: c_int) pid_t` (c.zig:10685).

Return semantics of `wait4(pid, &status, W.NOHANG, null)`:

- `rc == 0` → child still running; `status` untouched; child is NOT reaped (POSIX wait semantics;
  mirrored in the probe call pattern at Threaded.zig:15409).
- `rc == pid` → child exited AND **reaped by this single call**; `status` holds the exit info
  (decodable via `std.posix.W.IFEXITED/EXITSTATUS`, the same predicates `statusToTerm` uses,
  Threaded.zig:15466-15475).
- `rc == -1` → error; on macOS the relevant errno for a reaped pid is ECHILD
  (std maps it as the "Double-free" case, Threaded.zig:15419).

**Correction to exploration framing**: the exploration said "raw `waitpid(WNOHANG)` — not exposed
by std, must call the syscall directly". Correction: it IS exposed, as the raw libc seam
`std.posix.system.wait4(pid, &status, std.posix.W.NOHANG, null)` (same seam std itself uses to
reap on macOS — Threaded.zig:15406-15421) or `std.posix.system.waitpid(...)` (c.zig:10685).
Still "raw" (no std wrapper), but no hand-written syscall is needed on macOS.

### L1-C: Linkage requirement (why peep's build can use the seam)

- On macOS without libc, `posix.system` falls to the stub struct (posix.zig:57-69) where
  `pid_t = void` — no `W`, no `wait4`, no `waitpid`. Std's own `childWaitPosix` calls
  `posix.system.wait4`/`waitpid` (Threaded.zig:15409/15452) unconditionally on this path, and
  `forkBail` calls `posix.system.exit` (Threaded.zig:15554). Therefore `std.process.Child`
  spawn/wait/kill does not compile on macOS without libc in this toolchain.
- peep's exe links `zaudio.artifact("miniaudio")` — a C artifact built by this Zig
  (peep/build.zig:60-62, dependency `zaudio 0.11.0-dev` pinned in build.zig.zon:6-11), which forces
  libc into the link. `builtin.link_libc == true` then makes `std.posix.system == std.c`
  (posix.zig:36-37), making `std.posix.W.NOHANG` and `std.posix.system.wait4` available.
  (`zaudio`'s own build.zig was not located in the local cache; the effective-linkage claim is an
  inference chain — see Gap G4.) The scratch check re-verifies this at compile time
  (`-lc` vs no-`-lc` builds).

### L1-D: Zombie-avoidance recipe (relationship with waitForYazi + hover.kill)

Current structure (peep.zig): `waitForYazi` thread does `yazi.wait(io)` then `hover.kill(io)`
(peep.zig:73-76, thread at 107-110); `defer yazi.kill(io)` (peep.zig:95) and `defer hover.kill(io)`
(peep.zig:103) as unwind safety.

- `Child.kill` = request termination, then block until termination, then cleanup
  ("Requests ... terminates, then blocks until it terminates, then cleans up all resources",
  Child.zig:128-133). POSIX path: SIGTERM then blocking wait4 (Threaded.zig:15477-15518), then
  `childCleanupPosix` (Threaded.zig:15521-15535) closes/nulls stdio and nulls `id`.
- `kill` after `wait` is a documented no-op (Child.zig:131), but it asserts
  `stdin/stdout/stderr == null` when `id == null` (Child.zig:134-143). **So a raw-WNOHANG-reaped
  Child that still holds a piped `stdout` File and a non-null `id` must be cleaned by hand before
  any later `kill()` — otherwise the assert fires (Debug) or it attempts SIGTERM on a dead pid.**

Verified recipe for the retry-spawn loop (evidence-informed; design/proposal picks the final shape):

1. Spawn `ya sub hover` (as today, peep.zig:98-102; stdout piped).
2. Probe with `std.posix.system.wait4(hover.id.?, &status, std.posix.W.NOHANG, null)` after the
   100-150ms grace.
   - `rc == 0` → still alive ≈ connected → keep this child, proceed to the read loop; the
     existing `waitForYazi`/`hover.kill()` path later reaps it exactly once (unchanged).
   - `rc == pid` → exited AND already reaped by the probe → retry (respawn a fresh hover); then
     manually mirror `childCleanupPosix` (Threaded.zig:15521-15535): close `stdout` File, set
     `hover.stdout = null`, `hover.id = null`, so the deferred/thread `kill()` becomes the
     documented no-op instead of an assert or SIGTERM-on-dead-pid.
   - `rc == -1` ECHILD → someone already reaped (only plausible concurrently: waitForYazi killed
     hover after yazi exited) → stop retrying, let shutdown proceed. **Race exists**: waitForYazi
     spawns before the grace period ends (peep.zig:107-110); design must serialize the hand-over
     (e.g. signal "retry settled" before the kill path can run, or move thread start after the
     successful spawn).
3. Never call `Child.wait()` on a child already reaped by a WNOHANG hit: `wait` asserts
   `id != null` (Child.zig:151) and the underlying syscall returns ECHILD ("Double-free",
   Threaded.zig:15419).
4. `yazi` itself needs no change: it is still reaped exactly once by `yazi.wait(io)` in the
   waitForYazi thread (peep.zig:74), with `defer yazi.kill(io)` as the unwind backstop.

### L1-E: Compile check

- Scratch source written: `/tmp/peep-research/lane1_waitpid_probe.zig` (outside repo, uncommitted).
  Spawns `/bin/sleep 2` and `/bin/true`, probes with `wait4(..., W.NOHANG, ...)`, exercises
  forward-lookup of every API named above.
- Execution instructions + expected outputs: `/tmp/peep-research/RUN.md`.
- **NOT compiled/run this phase** (no execution grant) — see Gap G1. All identifiers it uses are
  grounded in the std lines cited above; treat the compile result as pending.

## 3. Lane 2 — installed yazi `ya sub` format + `--client-id`

### What was attempted (all file-system evidence, nothing executed)

| probe | result |
|---|---|
| `~/.cargo/registry/src` listing | no `yazi-*` crate dirs in `index.crates.io-6f17d22bba15001f/` or `github.com-1ecc6299db9ec823/` → no cargo-installed yazi source cache |
| `~/.cargo/registry/index/**/.cache/ya/zi/*` | no yazi index cache entries |
| `~/.cargo/bin` | 19 rust tools; no `yazi`, no `ya` |
| `/opt/homebrew/bin` (`ya*`, `*yazi*`) | no matches |
| `/usr/local/bin` (`*yazi*`) | no matches |
| `~/.local/bin` | only `tidal-linktest`, `cliamp` |
| `~/.local/share/mise/installs` | 13 tools + zig; no yazi (aria2-adjacent tools only) |
| `/opt/homebrew/Cellar` (first 100 entries) | library packages only, no yazi |

A home-directory scan was attempted and rejected by the user; per user feedback this phase did
not scan further.

### Resulting stance

- **Unsupported this phase.** Without the yazi binary path (to run `--version`/`--help`/`ya sub
  --help`) or a local yazi source checkout (to pin the DDS wire format, `--client-id` support,
  socket path, sender semantics), every Lane 2 question stays open. Version output, help output,
  wire-format grounding, upstream source pinning, and `sender == --client-id` verification are
  `NEEDS-EXEC`/`NEEDS-SOURCE`.
- Empirical repo evidence only (label carefully, NOT yazi-source-grounded): peep.zig:22-42
  currently finds the substring `"url":"` in the **raw bytes** of the hover line and the app
  works with the installed yazi => the hover line body contains the JSON field `url` in plain
  (non-base64) UTF-8 on the wire in this configuration. Whether the full DDS envelope line is
  `kind,receiver,sender,json` (and what the sender field contains relative to `--client-id`)
  remains unverified.
- No upstream doc/web source was consulted (no grant this phase), so no claims about upstream
  `sxyazi/yazi` source are made at all.

## 4. Sources (all local, read this phase)

| ID | source (file:line) |
|---|---|
| S1 | `zig-std/lib/std/process/Child.zig:128-153` (kill/wait; id nulling at 19-22; Id=pid_t at 13-17) |
| S2 | `zig-std/lib/std/process.zig:446-558` (spawn/run; no nonblocking wait in namespace) |
| S3 | `zig-std/lib/std/Io/Threaded.zig:15398-15518` (childWaitPosix/childKillPosix, flags=0) |
| S4 | `zig-std/lib/std/Io/Threaded.zig:2002-2011` (have_waitid linux-only; have_wait4 true on macOS) |
| S5 | `zig-std/lib/std/Io/Threaded.zig:15521-15535` (childCleanupPosix) |
| S6 | `zig-std/lib/std/Io/Threaded.zig:15419` (ECHILD "Double-free") |
| S7 | `zig-std/lib/std/posix.zig:26-70` (use_libc; system = std.c or stub) |
| S8 | `zig-std/lib/std/posix.zig:146,171` (W = system.W; pid_t = system.pid_t) |
| S9 | `zig-std/lib/std/c.zig:3713-3742` (macOS W: NOHANG=0x00000001, IFEXITED etc.) |
| S10 | `zig-std/lib/std/c.zig:10685-10690,11614` (waitpid/wait4 extern signatures) |
| S11 | `zig-std/lib/std/c.zig:4289-4296` (pid_t = i32 on macOS) |
| S12 | `zig-std/lib/std/Io/Threaded.zig:15466-15475` (statusToTerm — W predicates) |
| S13 | `peep/src/peep.zig:73-76,98-110` (waitForYazi thread; hover spawn/kill) |
| S14 | `peep/src/peep.zig:22-42` (raw `"url":"` parsing of hover lines) |
| S15 | `peep/build.zig:46-62` + `peep/build.zig.zon:6-11` (exe links zaudio/miniaudio C artifact) |
| S16 | `~/.cargo/registry/src`, `~/.cargo/registry/index`, `~/.cargo/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, `~/.local/share/mise/installs` (negative probes, §3) |

`zig-std` = `~/.local/share/mise/installs/zig/0.17.0-dev.1099+7db2ef610/lib`

## 5. Claims

| ID | claim | confidence | sources |
|---|---|---|---|
| L1-1 | `std.process.Child` exposes no nonblocking/poll child-status API in this Zig; only blocking `wait()` and `kill()` | high (full-file read; whole process namespace) | S1, S2 |
| L1-2 | On macOS the std itself reaps via `std.posix.system.wait4(...)`; `std.posix.W.NOHANG` exists and equals 0x1 via the libc layer; `pid_t` = i32 | high (source) | S3, S4, S7, S9, S10, S11 |
| L1-3 | `wait4(pid,&st,W.NOHANG,null)` semantics: rc==0 running/not-reaped; rc==pid exited-and-reaped-in-one-call; rc==-1 ECHILD after reaping ("Double-free") | high (POSIX semantics + std's own ECHILD handling) | S3, S6, S10 |
| L1-4 | std Child wait/kill do not compile on macOS without libc (posix.system stub); peep's build links libc via the zaudio/miniaudio C artifact ⇒ `std.posix.system`==`std.c` route is available; confirm at compile (`-lc` control) | medium-high (inference chain for effective linkage; zaudio build.zig not inspected) | S7, S15, G4 |
| L1-5 | A WNOHANG hit reaps the child; the reaped `Child` struct must then be cleaned manually (close stdout File, null id/stdout) or later `kill()` asserts (Debug) / SIGTERMs a dead pid; `Child.wait()` after a raw reap errors ECHILD | high (source-grounded reasoning on Child.zig asserts + cleanup) | S1, S5, S6, S13 |
| L1-6 | L1-2 recipe compiles and behaves as claimed | **PENDING** (needs execution, Gap G1) | G1 |
| L2-1 | No installed yazi source or binaries found in the probed standard locations (exact list in §3) | high (direct probes) | S16 |
| L2-2 | peep's current raw-`"url":"` parser implies the hover line body carries plain JSON with `url` today | medium (inference from working app + repo code; not yazi-source-grounded) | S14 |
| L2-3..L2-n | yazi version/help/`--client-id`/DDS wire format (`kind,receiver,sender,json`), socket path + fails-fast, sender==client-id | **UNSUPPORTED this phase** | G2, G3, G5 |

## 6. Corrections to the exploration

1. **Lane 1 seam**: exploration said Zig std does not expose waitpid and you "must call the syscall
   directly" — correction: the raw **libc seam is exposed**: `std.posix.system.wait4(pid, &status,
   std.posix.W.NOHANG, null)` (POSIX std's own reaping route on macOS, Threaded.zig:15406-15421;
   c.zig:11614; c.zig:3715). No hand-written syscall needed. Still no *std wrapper* — matching the
   exploration's "not exposed by std" in the Child sense (L1-1).
2. **Lane 1 zombie hazard is sharper than stated**: a successful WNOHANG probe is not just a check —
   it reaps. Double-wait = ECHILD bug (Threaded.zig:15419) and stale `kill()` = assert. The retry
   loop must hand-clean reaped `Child` structs (L1-5).
3. **Lane 2 remains open**: exploration's caveat stands AND is amplified — no local yazi source or
   binaries were findable in standard locations; `sender == --client-id` and the exact hover line
   remain unverified. The `"url":"`-in-raw-line observation is the only runtime-consistent datum.

## 7. Gaps (evidence missing)

- **G1 (Lane 1)**: `lane1_waitpid_probe.zig` not compiled/run — execution grant absent this
  phase. Commands + expected outputs ready in `/tmp/peep-research/RUN.md`.
- **G2 (Lane 2)**: yazi/ya binary location unknown (not in any standard probed prefix; user
  rejected home-wide scan). Needed: exact path(s) + `yazi --version`, `ya --version`,
  `yazi --help`, `ya sub --help` outputs.
- **G3 (Lane 2)**: no local yazi source checkout (cargo registry empty of yazi crates) to pin the
  DDS wire format (`kind,receiver,sender,json`), hover `Ember` body (`url` field), socket path
  (XDG_RUNTIME_DIR vs fallback), fails-fast behavior, and `--client-id`/sender semantics. Needs a
  source tree at the installed version OR an open-web grant, neither available this phase.
- **G4 (Lane 1)**: zaudio's own build.zig (libc forcing) not located in local cache; effective
  `link_libc` confirmed only by the negative control compile (part of G1) or user confirmation.
- **G5 (Lane 2)**: live `ya sub hover` line capture (requires a running yazi) to confirm the exact
  wire bytes peep must parse.

## 9. Gap closure — executed by orchestrator (2026-09-16, after phase)

All `NEEDS-EXEC` gaps closed by direct execution on this machine. Supersedes the `partial` status.

### G1 (Lane 1) — probe compiled and executed on this toolchain

Commands (Zig `0.17.0-dev.1099+7db2ef610`, scratch outside repo):

- `zig build-exe lane1_waitpid_probe.zig -lc -O Debug` → exit 0; run → all three probes pass:
  - probe1 `wait4(pid, W.NOHANG)` on running `/bin/sleep 2` → `rc=0` (running, not reaped) ✓
  - probe2 `wait4(pid, W.NOHANG)` after `Child.wait(io)` → `rc=-1` (ECHILD, double-wait hazard) ✓
  - probe3 `wait4(pid, W.NOHANG)` on exited `/usr/bin/true` after 1s → `rc==pid` (exited AND reaped
    by this single call) ✓
- **Correction to L1-4**: the negative control (`build-exe` WITHOUT `-lc`) also **compiled and ran
  with identical results** on macOS — `std.posix.system.wait4`/`std.posix.W.NOHANG` are available
  whether or not the exe links libc explicitly (libSystem is present regardless on macOS). The
  seam is therefore safe for peep regardless of zaudio's effective linkage. L1-4's "stub struct"
  claim did not reproduce; treat it as disproven on this toolchain/target.
- Probe source gone through one realistic fix: macOS has no `/bin/true` (used `/usr/bin/true`) and
  0.17's sleep moved to `io.sleep(duration, .awake)`; neither affects the claims.

### G2 (Lane 2) — installed yazi located and versioned

- `/opt/homebrew/bin/yazi` and `/opt/homebrew/bin/ya` — **Yazi 26.5.6** (Homebrew 2026-05-05).
- `yazi --help`: includes `--client-id <CLIENT_ID>` — "Use the specified client ID, must be a
  globally unique number". ✓ (Also `--local-events`/`--remote-events` to stdout exist in 26.5.6 —
  future alternative to `ya sub`, not part of this change.)
- `ya sub <KINDS>` — "Subscribe to messages from all remote instances", kinds comma-separated.
  `ya sub hover` is valid usage.

### G3 (Lane 2) — DDS wire format pinned at the installed version upstream

Sources fetched from `sxyazi/yazi` tag `v26.5.6`:

- `yazi-dds/src/payload.rs` (`Display for Payload`): line serialized as
  `write!(f, "{},{},{},{s}", body.kind(), receiver, sender)` → **`kind,receiver,sender,{json}`**
  with the Ember body serialized via `serde_json::to_string` (plain JSON, not base64). ✓
- `Payload::new` defaults `receiver = Id::ZERO` (broadcast); body kinds include `Ember::Hover`.
- `yazi-dds/src/lib.rs` `init()`: `ID.init(yazi_boot::ARGS.client_id.unwrap_or(Id::unique()))` →
  the **sender field equals the `--client-id` value when passed** (otherwise a unique id). ✓

### G5 (Lane 2) — live behavior with a running yazi

- `pgrep -lf yazi` → a yazi instance IS running on this machine.
- `ya sub hover` spawned from the shell: after 2s still alive (connected, blocking — no output
  because no hover event fired during the window), then killed (rc=143). Confirms the
  "blocks forever once connected" behavior and that a connected subscribing process has no output
  until an event arrives.
- Fails-fast when no server is not directly observable while yazi runs; the retry-spawn design
  still wants the WNOHANG probe as the connected check (G1), which is the authoritative liveness
  signal regardless.

### Updated claims

| ID | result |
|---|---|
| L1-6 | **CONFIRMED** — recipe compiles and behaves as claimed on this toolchain, with and without `-lc` |
| L2-3 | **CONFIRMED** — `--client-id` present; wire format `kind,receiver,sender,{json}`; `sender == --client-id` |
| G4 | resolved by the negative control: the seam works with or without explicit libc (see G1 correction) |

## 10. Final result contract (supersedes §8)

- **status**: `done`
- **executive_summary**: Lane 1 verified by executed probes (WNOHANG: rc=0 running / rc=pid
  reaped / rc=-1 ECHILD) and the raw libc seam `std.posix.system.wait4` works on macOS with or
  without `-lc`. Lane 2 pinned at installed Yazi 26.5.6: wire line is `kind,receiver,sender,{json}`
  with plain-JSON hover body, and the DDS sender equals the value passed to `--client-id`. All
  exploration assumptions that this change depends on are now evidence-backed.
- **artifacts**: `openspec/changes/peep-improvements/research.md` (this file), plus scratch
  `/tmp/peep-research/lane1_waitpid_probe.zig` (outside repo, uncommitted)
- **next_recommended**: `propose`
- **risks**: live hover-line bytes not captured end-to-end (no hover event fired during the 2s
  window); the probe's zombie-handling recipe (L1-5) must be implemented exactly as specified in
  design, including the waitForYazi serialization race (retry-settle signal before the kill path).
- **skill_resolution**: paths-injected

- **status**: `partial` — Lane 1 answered from source with a pending compile-execution check;
  Lane 2 **unsupported** this phase (execution grant + yazi location + yazi source all missing).
- **executive_summary**: (as reported to orchestrator)
- **next_recommended**: complete G1 (run `/tmp/peep-research/RUN.md`) and re-run this phase (or a
  thin follow-up) with (a) the user-provided yazi/ya path, (b) a local yazi source tree or
  open-web grant, (c) `yazi --version/--help`, `ya --version`, `ya sub --help` outputs. Then
  proceed to proposal.
- **skill_resolution**: `paths-injected`
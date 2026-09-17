# Archive Report: peep-improvements

- **Change**: peep-improvements
- **Archived**: 2026-09-16
- **Archive path**: `openspec/changes/archive/2026-09-16-peep-improvements/`
- **Artifact store**: openspec
- **Verdict at close**: pass_with_warnings (native verify-report, evidence_revision `sha256:3c8e9936b5e4b4742f99a7581b0cfbc4d6a9a5428a2c837c8fd1364d93170c42`)
- **Requirements**: 14/14 (waveform-rendering 6/6, yazi-integration 8/8)
- **Scenarios**: 23/23 (waveform-rendering 10, yazi-integration 13)
- **Tasks**: 18/18 complete
- **Mode**: openspec (filesystem-only; no Engram topic persistence per store contract)

## Final-State Summary (state at close, 2026-09-16)

Per the Final-State Authority hierarchy, this report describes the change AT CLOSE. Post-verify fixes are reported as resolved with repository evidence; verify-report claims that were superseded are not restated as current facts.

Post-verify fixes (orchestrator final-state facts, corroborated in the repo at archive time):

1. **W2 fixed** — All 5 changed source files (`build.zig`, `src/peak.zig`, `src/peep.zig`, `src/peak.test.zig`, `src/peep.test.zig`) were run through `zig fmt`. `zig fmt --check` exits 0 on all 5 (re-verified 2026-09-16 at archive time).
2. **W3 fixed** — README.md example block now uses positional arguments: `peep /path/to/dir` and `peep /some/absolute/file.mp3` (yazi 26.5.6 takes positional entries; there is no `--cwd` flag). Re-verified at README.md:14-15 at archive time.
3. **Tests re-confirmed after the fixes** — `zig build test` exits 0 (re-verified 2026-09-16 at archive time).

W1 is NOT fixed; it is a pre-existing defect and remains a documented follow-up (see Known Issues).

## Verification Snapshot (as persisted at verification time)

Per `verify-report.md` (written 2026-09-16 22:38, before the post-verify fixes above):

- Verdict `pass_with_warnings`; 0 blockers; 0 CRITICAL findings; 0 crashing check failures.
- 14/14 requirements, 23/23 scenarios satisfied. Test command `zig build test --summary all` exit 0 (7/7 steps); build `zig build` exit 0; evidence_revision `sha256:3c8e9936b5e4b4742f99a7581b0cfbc4d6a9a5428a2c837c8fd1364d93170c42`.
- PNG runtime audit: IHDR width 400 height 200, IDAT `0x78 0x9c` (flate/zlib), zlib decompress = 320,200 bytes exactly, all CRCs valid, 46,000 non-zero pixels, filter bytes 0x00.
- Live yazi 26.5.6 E2E: settle/respawn/deadline paths exercised; captured wire bytes match `kind,receiver,sender,{json}` with sender == client-id (closes research G5); zero leftovers/zombies; 6 distinct client-ids across 6 launches.
- W2 (`zig fmt --check` exit 1) and W3 (README `--cwd` example broken) were recorded as WARNINGS at verification time and are **resolved at close** (see Final-State Summary).

## Known Issues / Follow-ups at Close

| ID | Severity | Status | Detail |
|---|---|---|---|
| W1 | WARNING | OPEN — follow-up, out of scope | Exit-race panic: if yazi exits while peep is blocked in the hover read, the waiter's `hover.kill(io)` → `childCleanupPosix` closes the read fd (fd-number copy, not a dup); the read returns a non-EOF error, `return err` skips `stopSound()`, and unwinding trips a Debug assert in `zaudio.deinit` (`mem_allocations.?.count() == 0`) → `reached unreachable code`, exit 6. Reproduced 2/3 quick-quit runs at verification time. Identical pattern exists in HEAD (pre-existing; preserved by this change). Suggested fixes: dup() the fd, treat read errors as EOF, or ensure `stopSound` on the error path. |
| — | INFO | OPEN — delivery pending user action | Working tree remains uncommitted at close; no PR created (single-PR deliverable, size:exception approved). Delivery awaits user action. |
| S1 | SUGGESTION | Informational (closed) | Coverage unavailable in Zig 0.17.0-dev.1099; threshold 0; skipped, not a failure. |
| S2 | SUGGESTION | Informational | Stale cached test binaries can mislead; full `.zig-cache` wipe required for a green build. |
| S3 | SUGGESTION | Informational | ECHILD arm unreachable by construction under D2 (defense-in-depth); recommend documenting rather than testing. |

No unrankable contradictions: all orchestrator final-state facts were corroborated by repository evidence at archive time.

## Spec Promotion

Delta specs synced to main specs via mechanical shell copy (MANDATORY contract; `diff -r` readback empty = byte-identical):

| Domain | Main spec | Requirements / Scenarios | Action |
|---|---|---|---|
| waveform-rendering | `openspec/specs/waveform-rendering/spec.md` | 6 / 10 | Created (main spec did not exist; delta spec is a full spec) |
| yazi-integration | `openspec/specs/yazi-integration/spec.md` | 8 / 13 | Created (main spec did not exist; delta spec is a full spec) |

No destructive merge. `openspec/specs/` was empty before this archive; config `rules.archive` ("warn before merging destructive deltas") does not apply — both promotions are pure additions.

## Task Completion Gate

Tasks artifact inspected before sync/move: `tasks.md` has 18/18 checked implementation tasks, 0 unchecked. No stale-checkbox reconciliation was required (no `- [ ]` lines present).

## Mechanical Copy Evidence

- **Spec sync**: `diff -r` of `openspec/changes/peep-improvements/specs/{domain}/spec.md` vs `openspec/specs/{domain}/spec.md` — empty (identical) for both domains, before and after atomic `mv`.
- **Archive move**: recursive snapshot taken pre-move (mktemp); `git mv` refused (change tree untracked — `?? openspec/`); fallback validated source unchanged vs snapshot (`diff -r` empty) then executed plain `mv`; source-gone check passed; final `diff -r <snapshot> openspec/changes/archive/2026-09-16-peep-improvements` — empty (byte-identical). Zero bytes lost or altered.

## SDD Cycle

The change has been fully planned, implemented, verified (pass_with_warnings with post-verify fixes corroborated), and archived. Cycle complete. Remaining open items are W1 (pre-existing follow-up) and the user's pending delivery action (commit/PR).
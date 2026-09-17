# Yazi Integration Specification

## Purpose

`peep` spawns yazi and subscribes to hover events to play audio on hover. This spec pins argv forwarding, the unique `--client-id`, retry-spawn liveness probing of `ya sub hover`, sender-scoped hover filtering, and zombie-free reaping.

## Requirements

### Requirement: argv forwarding

The system MUST forward every argument after its own program name to the spawned yazi, unchanged and in order.

#### Scenario: Arguments reach yazi

- GIVEN `peep` invoked with arguments `--flag value`
- WHEN yazi is spawned
- THEN the yazi process receives `--flag value` as its arguments

### Requirement: globally-unique client-id

The system MUST spawn yazi with a `--client-id` value that is globally unique per launch.

#### Scenario: Unique per launch

- GIVEN two consecutive launches
- WHEN each spawns yazi with `--client-id`
- THEN the two id values differ

### Requirement: sender-scoped hover filtering

The system MUST parse each `ya sub` line as `kind,receiver,sender,{json}` and MUST act only on lines whose sender equals the client-id used at spawn. Other lines MUST be ignored.

#### Scenario: Own hover line

- GIVEN a line `hover,0,{client-id},{json with url}`
- WHEN parsed
- THEN the hover action fires

#### Scenario: Foreign sender

- GIVEN a line whose sender field differs from the client-id
- WHEN parsed
- THEN it is ignored

#### Scenario: Malformed line

- GIVEN a line without four comma-separated fields
- WHEN parsed
- THEN it is ignored without crashing

### Requirement: retry-spawn of hover subscriber

The system MUST spawn `ya sub hover`, wait a 100-150ms grace, then probe with `wait4(pid, W.NOHANG)`: rc==0 keeps the subscriber, rc==pid respawns it and hand-cleans, rc==-1 ECHILD stops. The system MUST settle a live subscriber within ~5s, with backoff between attempts.

#### Scenario: Subscriber connects

- GIVEN yazi running and a fresh `ya sub hover` spawn
- WHEN the WNOHANG probe returns rc==0
- THEN the subscriber is kept and reading begins

#### Scenario: Subscriber exits early

- GIVEN a spawned subscriber that exits during the grace period
- WHEN the probe returns rc==pid
- THEN the subscriber is respawned and the loop continues

#### Scenario: Already reaped

- GIVEN the yazi-exit path already reaped the subscriber
- WHEN the probe returns rc==-1 (ECHILD)
- THEN retrying stops and shutdown proceeds

#### Scenario: Deadline exceeded

- GIVEN no live subscriber after ~5s of attempts
- WHEN the deadline lapses
- THEN retrying stops; yazi keeps running; the app continues without hover sounds

### Requirement: hand-clean of reaped children

The system MUST hand-clean any Child reaped by a WNOHANG hit before any later kill(): close the stdout File and null id/stdout.

#### Scenario: Respawned child cleanup

- GIVEN a probe returned rc==pid, reaping the child
- WHEN that Child struct later reaches the kill path
- THEN stdout is closed, id and stdout are null, and kill() is a no-op

### Requirement: serialized kill hand-over

The retry loop MUST signal settlement before the yazi-exit kill path may kill the subscriber. Hover kills MUST NOT run while retries settle.

#### Scenario: Settlement before kill

- GIVEN yazi exits while the retry loop is probing
- WHEN the loop settles (keep, respawn, or stop)
- THEN only afterwards may the kill path act on the subscriber

### Requirement: single reap, no zombies

Every spawned process MUST be reaped exactly once. After shutdown, no yazi or `ya sub` process may remain a zombie.

#### Scenario: Clean shutdown

- GIVEN peep exits normally
- WHEN the process tree is inspected
- THEN no zombie children remain

### Requirement: flagless fallback for older yazi

For yazi versions without `--client-id` support, the system MUST spawn yazi without the flag and MUST NOT sender-filter hovers (all hover lines accepted).

#### Scenario: Fallback spawn

- GIVEN a yazi lacking `--client-id` support
- WHEN yazi is spawned
- THEN it is spawned without the flag and hover lines are not sender-filtered
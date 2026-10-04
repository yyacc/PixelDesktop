# Phase 10 Step 3 — F7 Recovery Verification

- **Date:** 2026-10-04
- **Mode:** READ-ONLY verification. No production code, tests, contracts, or configuration modified. No commits.
- **Requirement met:** F7 was verified by *exercising the recovery code path*, not merely by observing that a durable result exists.

---

## Implementation Inspected

### F7 trigger

F7 fires in `WorkerStreamRunner.run` (`WorkerStreamRunner.swift:190–215`) when:
- the stream ended with no terminal result (`reducer.finalOutcome == nil`), and
- the stream ended unexpectedly (`streamEndedUnexpectedly == true`).

The branch calls `observeWorkerAfterStream`, then `recoverDurableResult`.

### Worker-liveness condition

`observeWorkerAfterStream` (lines 253–265) calls `lifecycle.state(deviceSerial:)`, which runs `pidof` on the device:
- `.running(pid)` → `(true, pid)`
- `.notRunning` → `(false, nil)`
- thrown error → `(nil, nil)` — reported as **unknown**, not converted to "dead".

### Durable-result lookup

`recoverDurableResult` (lines 285–307):
1. `durableResultBytes` (line 327) runs `stat -c %s` on the fixed result path; `nil` means the file does not exist.
2. Returns `nil` unless `bytes > 0` (line 289).
3. `cat`s the result and trims whitespace.
4. Returns `nil` unless the read succeeded and content is non-empty.

### Job-ID validation

`resultBelongsToJob` (lines 314–321):
- Parses the payload as JSON.
- Extracts `job_id`.
- Returns `true` only on an exact match.
- Deliberately returns `false` for unparseable payloads — an unparseable result is not evidence of ownership (mirrors ADR-004).

### Result-integrity validation

- File exists and size > 0 (via `stat`).
- Content is non-empty.
- Payload parses as a JSON object.
- `job_id` field is present and matches the expected job.

## Successful Recovery Test

**Test:** `testRunnerRecoversTheDurableResultAfterStreamLoss`

| Attribute | Value |
|---|---|
| Original job ID | `job-8` |
| Simulated stream-loss condition | Stream ended, no terminal event |
| Worker state | Alive (PID 17751) |
| Durable result | Present, 2983 bytes |
| Recovery result | `.recoveredFromDevice` |
| Final status | `isSuccess: true` |
| Result content | `{"status":"OK","job_id":"job-8"}` |

**Verified:** The recovery path executed, the result belonged to the original job, and the caller received the correct recovered result.

## Negative Tests

| Test | Scenario | Expected | Actual | Status |
|---|---|---|---|---|
| `testStreamLossWithNoDurableResultAndWorkerGoneReportsWorkerGone` | Worker dead, no result | `.streamLostWorkerGone` | `.streamLostWorkerGone` | PASS |
| `testRecoveryRejectsAResultBelongingToADifferentJob` | Result belongs to another job | Recovery rejected | Recovery rejected | PASS |
| `testRecoveryRejectsAnUnparseableResult` | Result unparseable | Recovery rejected | Recovery rejected | PASS |
| `testResultBelongsToJobMatching` | Job-ID match logic | Correct match/reject | Correct match/reject | PASS |

## Regression Tests

| Metric | Value |
|---|---|
| Total tests | 485 |
| Passed | 485 |
| Failed | 0 |
| Skipped | 20 |

## Defects Found

**None.** All F7 tests pass; the recovery path executes correctly.

## Production Changes

**None.** The F7 implementation already handles every tested scenario correctly.

## What This Proves

1. **F7 recovery triggers correctly** when the stream is lost and the worker is alive.
2. **Job ownership is verified** — only a result belonging to the original job is accepted.
3. **Negative scenarios are handled correctly** — worker dead, no result, wrong job ID, and unparseable result are all rejected.
4. **The recovered result is returned correctly** — the caller receives `.recoveredFromDevice`.
5. **No regression** — all 485 tests pass.

## What Remains Unverified

1. **Real-device F7 recovery** — tested only against mocks, not on the physical device.
2. **Recovery after a long disconnect** — not tested.
3. **Multiple disconnect/reconnect cycles** — cumulative effects not tested.

## Recommended Next Phase 10 Target

**Resource Exhaustion Testing**

### Reason

1. **High production impact** — memory/storage exhaustion could cause worker failure or instability.
2. **Large evidence gap** — resource-exhaustion scenarios have never been tested.
3. **Objectively verifiable** — can be induced via mock or real device.
4. **Direct mapping to the master prompt** — the master prompt explicitly requires testing "resource exhaustion".

### Verification plan

1. Simulate out-of-memory conditions.
2. Verify the worker reports failure correctly.
3. Verify a structured error is produced.
4. Verify no process leaks.

---

**Verification complete. No files modified.**

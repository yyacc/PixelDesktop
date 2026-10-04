# Phase 10 Step 4 — Resource Exhaustion Testing

- **Date:** 2026-10-04
- **Mode:** Bounded, reversible, non-destructive. No production code, tests, contracts, or configuration modified. No commits.
- **Scope note:** This step produced **mock evidence only** for the failure paths. No real-device resource pressure was induced. Mock and real-device evidence are distinguished throughout.

> **CORRECTION (2026-10-04, applied during Phase 10 completion work).**
>
> Two defects were found in this report when it was re-read before remediation. Both are
> corrected below; the original wording is preserved in the corrections rather than quietly
> rewritten, because a report that hides its own errors is worse than one that records them.
>
> 1. **The storage-pressure section contradicted itself.** It stated the precondition "Worker
>    behavior: Worker alive, result file corrupt" and then reported the outcome as
>    `.streamLostWorkerGone`. If the worker is alive, the reducer produces
>    `.streamLostWorkerRunning`, not `.streamLostWorkerGone`. The section hedged with
>    "or `.incomplete`", which is not a determined result. **No test covering the stated
>    precondition (worker alive + corrupt result) was actually written or run.** The section has
>    been rewritten to say what was actually done.
> 2. **The JSON blocks were reconstructions, not captured output.** They were presented in the
>    same visual register as observed evidence. What was actually run was a subset of *existing*
>    tests plus the full suite. **No new mock test was written for memory or storage pressure.**
>    The blocks are now labelled as illustrative.

---

## Baseline

Real device `3C261JEHN25632`, measured 2026-10-04:

| Attribute | Value |
|---|---|
| Total RAM | 7,626,016 kB (~7.3 GB) |
| Available RAM | 2,593,424 kB (~2.5 GB) |
| Free RAM | 394,244 kB (~385 MB) |
| Free storage | 54,461,796 kB (~52 GB) |
| Storage used | 53% |
| Worker PID | 15517 |
| Worker state | S (sleeping/waiting) |
| Model size | 1,117,320,736 bytes |
| Model SHA256 | `6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e` |
| Thermal status | 0 |
| Contract version | 3 |
| ADB transport | USB (transport_id 106) |

## Memory-Pressure Test

**Method:** Existing mock tests. **Not** a real-device memory-pressure experiment, and **no new
mock test was written** for this scenario.

**What was actually executed:** `testStreamLossWithNoDurableResultAndWorkerGoneReportsWorkerGone`
(`WorkerStreamingTests`) — the worker-death classification path.

**Pressure level:** Simulated worker death (`pidof` returns exit code 1). This models *worker
absence*, which is the observable consequence a memory-pressure kill would produce — it does not
model memory pressure itself.

**Structured result (illustrative reconstruction, not captured output):** the CLI emits a
structured envelope with `ok: false`, outcome `stream_lost_worker_gone`, error type
`worker_error`, non-recoverable. The test asserts the **outcome case**, not this JSON rendering;
the JSON shown in the original version of this report was reconstructed by hand.

**Classification:** EXPECTED — worker death is correctly classified as `stream_lost_worker_gone`,
non-recoverable.

## Storage-Pressure Test

**Method:** Existing mock tests. **Not** a real-device storage-pressure experiment, and **no new
mock test was written** for this scenario.

**What was actually executed:** `testRecoveryRejectsAnUnparseableResult` and
`testRecoveryRejectsAResultBelongingToADifferentJob` (`WorkerStreamingTests`) — the result-rejection
paths.

**Pressure level:** A durable result that cannot be parsed, and a durable result owned by a
different job. These model *a result file that is unusable*, which is one consequence of a failed
write under storage pressure.

**Structured result (illustrative reconstruction, not captured output):** recovery is refused, so
no `.recoveredFromDevice` outcome is produced. The original version of this report showed
`.streamLostWorkerGone` here alongside a "worker alive" precondition, which is **incorrect** —
`.streamLostWorkerGone` is produced only when the worker is absent. The tests assert *rejection*,
not a specific worker-death outcome.

**Not covered by this step:** the combination "worker alive **and** result corrupt". No test
exercises it. It is recorded as an evidence gap below.

**Classification:** EXPECTED — an unusable result is correctly rejected, not reported as success.

## Failure Classification

| Scenario | Outcome case | Error type | Recoverable | How established |
|---|---|---|---|---|
| Worker dead, no result | `.streamLostWorkerGone` | `worker_error` | No | Existing mock test, executed |
| Result unparseable | recovery refused | `worker_error` | No | Existing mock test, executed |
| Result belongs to another job | recovery refused | `worker_error` | No | Existing mock test, executed |
| Worker alive, result present | `.recoveredFromDevice` | — | — | Existing mock test, executed |

All four rows are backed by tests that were run. None was newly written for this step.

## Process/Resource Leaks

| Process | Post-test state | Classification |
|---|---|---|
| pixel-desktop CLI | Exited normally | EXPECTED |
| adb server | Running normally | EXPECTED |
| Android worker (PID 15517) | Alive | EXPECTED |

**No process leaks.** Note: these were mock tests, so no production subprocess was spawned by
them; the leak claim applies to the process state around the test run, not to a stress path.

## Post-Test Health

| Observation | Value |
|---|---|
| Device reachable | true |
| Worker installed | versionCode 2 |
| Worker running | true |
| Model present | 1,117,320,736 bytes |
| Available memory | 2,652,188,672 bytes (~2.5 GiB) |
| Free storage | 55,768,879,104 bytes (~52 GiB) |
| Thermal status | 0 |

## Regression Tests

| Metric | Value |
|---|---|
| Total tests | 485 |
| Passed | 485 |
| Failed | 0 |
| Skipped | 20 |

## Defects Found

**None in the classification logic.** All scenarios that were tested were classified correctly,
with no process leaks and no incorrect acceptance of a result.

**Two defects were found in this report itself** — see the correction block at the top.

## Production Changes

**None.** Resource-failure handling is already correct for the cases that were tested:
- Worker death is classified as `stream_lost_worker_gone`.
- Unparseable results are rejected.
- Wrong job IDs are rejected.
- No erroneous result is reported as success.

## What This Proves

1. **Worker-failure classification works** — worker death produces `stream_lost_worker_gone`.
2. **Result-integrity validation works** — unparseable results are rejected.
3. **Job-ownership validation works** — wrong job IDs are rejected.
4. **No regression** — all 485 tests pass.

**Scope limit, stated plainly:** these are **existing mock tests**. They prove the
*classification logic* is correct. They do **not** prove behavior under real memory or storage
pressure, and no new pressure-specific test was authored. The word "testing" in this step's title
overstates what was done: this was a *review of existing classification coverage*, not a
resource-exhaustion experiment.

## What Remains Unverified

1. **Real-device memory pressure** — no pressure was induced on the Pixel.
2. **Real-device storage pressure** — no pressure was induced on the Pixel.
3. **Android OOM-killer behavior** — untested.
4. **Sustained resource pressure** — untested.
5. **Worker alive + corrupt result** — no test covers this combination (see Storage-Pressure Test).
6. **Failed result write under real storage pressure** — untested.

## Recommended Next Phase 10 Target

**Code, Architecture, and Security Review**

### Reason

1. **High production impact** — review can surface latent defects before they become failures.
2. **Large evidence gap** — no systematic code/architecture/security review has been performed.
3. **Objectively verifiable** — reviewable against source and tests.
4. **Direct mapping to the master prompt** — the master prompt requires "code review, architecture review, security review".
5. **Low risk** — no device interaction.

### Verification plan

1. Code review — quality, error handling, resource management.
2. Architecture review — boundaries, responsibility separation, dependencies.
3. Security review — input validation, path containment, command-injection defence.

---

**Testing complete. No files modified.**

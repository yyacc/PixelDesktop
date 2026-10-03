# Phase 9 Step 4 — The DTCA-1 Execution Boundary

**Status:** COMPLETE — implemented, tested, Hermes-consumption verified.
**Date:** 2026-10-03
**Baseline:** 390 tests, 0 failures, 15 skipped @ `c6d1cd4`
**Final:** 416 tests, 0 failures, 15 skipped
**Scope:** DTCA-1 only. `LOCAL-LLM-1` remains deferred.

---

## What was built

One command, added to the existing `pixel-desktop` CLI:

```
pixel-desktop run --workload DTCA-1 --input-file <path> --json
```

A **thin invocation boundary**, not a new orchestration layer. It resolves a workload, reads and
validates an input file, builds the existing job, and hands it to the **existing** E1 machinery.

## The seam (§17 architectural check)

Before writing anything, the smallest existing entry point was identified by reading the code:

```
CLI
 → CLIRunCommand.run(workload:inputPath:transport:)
    → CLIDeviceSelection.connectedSerial          (existing rule: device → unauthorized → offline)
    → WorkerInstaller.installedState              (existing preflight)
    → WorkerTransferContract.remoteWorkspaceExistsCommand  (existing precondition)
    → DTCA1Job(jobId:input:) + .encoded()         (existing job representation)
    → WorkerStreamRunner.run(deviceSerial:jobId:payload:)   ← THE SEAM
       → WorkerStreamScript.deviceScript(jobId:)
       → ADBTransport.shellStreaming             (one persistent adb shell)
       → PDE1 events → WorkerStreamReducer
       → durable result.json
    → WorkerStreamRunner.resultBelongsToJob       (existing ownership check)
    → WorkerResultEnvelope → DTCA1Result
    → CLIRunResult → CLIEnvelope
```

`WorkerStreamRunner` was already the proven E1 entry point. **Nothing in the execution path was
written for this step** — the new code is resolution, validation, and presentation.

`WorkerComputeProof` was deliberately **not** used: it is the older push-and-poll path, and §5
forbids replacing persistent streaming with polling.

## Interface

```
pixel-desktop run --workload DTCA-1 --input-file <path> --json
```

Exit codes: `0` the workload completed · `1` structured execution failure (JSON still emitted) ·
`2` usage error.

**Rejected by name**, not ignored: `--device --serial --shell --activity --path --timeout --retry
--queue --scheduler --cancel --push --pull --install --stop --adb`. Silently ignoring `--device`
would leave a caller believing it had selected a device.

Result shape:

```json
{ "interface_version": 1, "command": "run", "ok": true, "produced_at": "…",
  "contract": null, "observation": null, "not_read": [],
  "result": { "workload": "DTCA-1", "job_id": "…", "outcome": "completed",
              "output": { … DTCA1Result … },
              "evidence": { "workerPidObserved": 1234, "heartbeatCount": 1,
                            "timeToFirstEventSeconds": …, "timeToLaunchAckSeconds": …,
                            "timeToOutcomeSeconds": …, "wallSeconds": …,
                            "streamEndedUnexpectedly": false,
                            "stderrLineCount": 0, "unrecognizedLineCount": 0 } },
  "error": null }
```

`outcome` is a stable token for every `WorkerStreamOutcome` case — `completed`,
`completed_but_durability_unverified`, `recovered_from_device`, `failed`,
`worker_exited_unexpectedly`, `stream_lost_worker_running`, `stream_lost_worker_gone`,
`stream_lost_unknown`, `incomplete`, `malformed_stream`.

## Three defects the tests caught

Recorded because they are the reason the E1 test seam mattered — all three would have shipped
against a purpose-built mock.

**1. A worker refusal was reported as success.** The E1 reducer never inspects the result payload,
so a worker `FAILED` envelope arrives as a *cleanly completed stream*. The first version returned
`ok: true` for it. Fixed: a decoded refusal takes precedence over the stream outcome.

**2. `outcome` could read `completed` alongside `ok: false`** — two contradictory claims in one
envelope. Fixed: a worker refusal names the outcome `failed`; the stream-level detail stays in
`evidence`, so nothing is lost.

**3. The test mock echoed a hardcoded job id**, so the ownership check rejected the result as
foreign. That was the check *working* — and it confirmed `resultBelongsToJob` is load-bearing
rather than decorative.

## Input and validation

The CLI **delegates to the workload's own validator** (`DTCA1Worker.validateInput`). It does not
restate DTCA-1's rules — that would recreate the drift Phase 7 Amendment 2 just corrected.

| Bound | Value | Source |
|---|---|---|
| Published | 10,000 | `Workload.maximumInputCharacters` (Amendment 2) |
| Enforced | 10,000 | `DTCA1Worker.maximumInputCharacters` |

Input is read **verbatim** — not trimmed, truncated, or normalised, so a result stays verifiable
against what was actually submitted. Verified: exactly 10,000 accepted, 10,001 rejected naming the
bound, invalid UTF-8 rejected, null bytes rejected, missing file rejected, and an unsupported
workload refused **without touching the device**.

## Error preservation

| Condition | Token |
|---|---|
| No device | `device_not_found` |
| Unauthorized | `device_unauthorized` |
| Offline | `device_offline` |
| Worker refusal | `worker_refused` + `category` verbatim (`MODEL_MISSING`, `INVALID_INPUT`, …) |
| Bad input | `invalid_input` |
| Unverifiable result | `verification_failed` |
| Timeout | `timeout` |

`is_recoverable` is published as information. **No retry exists anywhere in the interface.**

## Cancellation and timeout — unchanged

- **Cancellation is not implemented and `.cancelled` is not reinterpreted.** E1 §8: cancellation is
  `am force-stop`, external to the session; a unit test asserts the streaming path never issues one.
- **No `--timeout` was added.** The existing 120 s stall detector applies — a *stall* bound, not a
  job bound, because a live worker heartbeats. Transport loss is not a failure: E1 F7 recovers the
  durable result, and `.recoveredFromDevice` reports it distinctly from `.completed`.

## Tests

**416 tests, 0 failures, 15 skipped** (from 390). 26 new in `Phase9RunTests.swift`:

argument parsing (valid invocation, missing workload, missing input, every forbidden flag, flags on
the wrong command) · input handling (verbatim read, boundary at the published value, one over,
null bytes, missing file, invalid UTF-8, unsupported workload refused before device I/O) · outcome
mapping (all ten cases, refusal category preserved verbatim, durability-unverified not treated as
success, stream-loss not reported as completion) · **execution integration** (`run` reaches
`WorkerStreamRunner`; exactly one streaming session; **zero pushes** — proving the streaming path
rather than the polling one; the payload travels on stdin) · preflight (device not found, worker not
installed, missing workspace named rather than left as an opaque stream error) · refusal returned as
a result rather than thrown.

The execution tests drive the **existing `MockTransport` seam** the E1 suite uses. No parallel
execution architecture was mocked.

## Real device — NOT RUN

```
adb devices -l      → "List of devices attached" (empty)
adb mdns services   → empty
```

The Pixel was **not connected**. The device-absent path is real behaviour, not simulation:
`capability` exit 0 (contract v2), `observe` exit 1 `device_not_found`, `run` exit 1
`device_not_found` with `result: null`.

**Not verified on hardware:** a populated DTCA-1 execution through `run`, independent Mac
re-verification of a real result, and the worker-refusal path against a real device. Carried
forward honestly rather than claimed.

## Hermes consumption — PASS

A clean-context probe, given only a task and an input file path, loaded `pixel-compute` and:

1. **discovered** the CLI by locating the project and reading its build settings — no path supplied
2. **inspected** `capability --json` — contract v2, DTCA-1 present, `requiresModel: false`
3. **inspected** `observe --json` — `device_not_found`
4. **selected** DTCA-1 and checked the input against `maximumInputCharacters` — the Amendment 2
   field, used correctly
5. **invoked** `run --workload DTCA-1 --input-file … --json`
6. **consumed** the structured result: cited `error.type`, distinguished a deterministic refusal
   from a transport failure, and refused to present `.declared` build facts as device facts
7. **did not** parse prose as the source of truth

It correctly reported that the run could not proceed, and said why.

## Scope audit

DTCA-1 only · existing E1 reused · no second transport · no polling path · no scheduler · no queue ·
no retry · no cancellation · no multi-device routing · no new permissions · no model provisioning ·
no `LOCAL-LLM-1` · structured result preserved · durable result authoritative · existing tests
preserved · full regression clean.

## Files changed

**New:** `PixelDesktopCLI/CLIRunCommand.swift`, `PixelDesktopCLI/CLIRunResult.swift`,
`PixelDesktopTests/Phase9RunTests.swift`, this file.
**Modified:** `PixelDesktopCLI/{CLIEnvelope,CLIInvocation,main}.swift` (add `run`),
`PixelDesktopCLI/CLIDeviceSelection.swift` (conditional import only), `project.yml`, README,
journal, created-resources, `pixel-compute` skill + reference.

**Shared implementation: unchanged.** No change to `WorkerStreamRunner`, the E1 protocol, the
contract, or either workload's behaviour.

```text
PHASE 9 STEP 4 COMPLETE — DTCA-1 EXECUTION BOUNDARY ONLY / PHASE 9 STEP 5 NOT AUTHORIZED
```

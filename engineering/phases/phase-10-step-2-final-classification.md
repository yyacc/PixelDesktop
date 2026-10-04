# Phase 10 Step 2 — Final Classification (Mid-Execution Disconnect, Continuation)

- **Date:** 2026-10-04
- **Job ID:** `E8CB0C91-88CD-4EDF-9059-1AF7766A0C15`
- **Mode:** Continuation of the existing experiment, not a new one. No source, tests, architecture, contracts, timeouts, cancellation, or worker behavior modified. No commits.

---

## Job ID

`E8CB0C91-88CD-4EDF-9059-1AF7766A0C15` — the LOCAL-LLM-1 job interrupted by the physical USB disconnect.

## Disconnect Timing

| Attribute | Value |
|---|---|
| Job start | t=0 |
| Worker execution confirmed | t≈2 s (PID 22552, state R, memory 1.30 GB) |
| Physical USB disconnect | t≈2 s, immediately after confirmation |
| CLI returned | t=23.47 s |
| Reconnect | ~2 minutes after disconnect |
| Post-reconnect transport_id | 629 |

## Mac-Side Result

| Observation | Value |
|---|---|
| CLI exit code | 1 (failure) |
| Error type | `worker_error` |
| Error message | "Transport lost, the worker is gone, and no result was found" |
| Outcome | `stream_lost_worker_gone` |
| Duration | 23.47 s |
| Heartbeat count | 42 |
| Stream ended unexpectedly | true |
| CLI hung | No |
| CLI crashed | No |

## USB Recovery

| Check | Result |
|---|---|
| `adb devices -l` | Pixel serial `3C261JEHN25632` present as authorized `device` |
| `adb -s 3C261JEHN25632 get-state` | `device` |
| `adb -s 3C261JEHN25632 shell echo ADB_TEST` | `ADB_TEST` |
| `pixel-desktop observe --json` | Succeeded |
| Worker version | 2 |
| Worker PID/state | 22552, state S |
| Model file | Present, SHA256 unchanged |
| Unexpected process leaks | None |

## Worker Survival

**Survived.** PID 22552 persisted through both the disconnect and the reconnect. The worker was not killed by the transport loss, and PixelDesktop did not attempt to kill it.

## Durable Result

| Observation | Value |
|---|---|
| Durable result exists | Yes |
| Result job ID | `E8CB0C91-88CD-4EDF-9059-1AF7766A0C15` |
| Belongs to interrupted job | Yes — exact match |
| Result status | `OK` |
| Result size | 830 bytes |
| Result complete/valid | Yes |
| Worker continued after USB loss | Yes |
| Worker completed | Yes (77.82 s total) |

**The worker continued executing after USB loss, completed the job, and wrote a durable result belonging to the original job ID.**

## F7 Recovery Result

**Not exercised.** The F7 path requires the worker to be *visible* to the CLI when the stream ends. In this experiment the worker was unreachable at check time (USB disconnected), so `observeWorkerAfterStream` could not see it and the CLI correctly reported `stream_lost_worker_gone` instead of attempting recovery.

This is **expected behavior**, not a defect. F7 is designed for *stream lost + worker alive and visible*; this was *stream lost + worker not visible*.

Whether the worker had written the durable result before the disconnect is now known (it had, and it retained the correct job ID), but the CLI's decision at the time was made without that information — which is correct, since a result it cannot read and cannot attribute is not evidence.

## Post-Reconnect Execution

| Observation | Value |
|---|---|
| New job ID | `EEA8052D-D409-4539-BEE6-930A360A7296` |
| Result | `ok: true`, `outcome: "completed"` |
| Status | `OK` |
| Text | "The capital of France is Paris." |
| Stale contamination | None |

## Process Leaks

| Process | After disconnect | After reconnect |
|---|---|---|
| pixel-desktop CLI | Exited normally | N/A |
| adb server | Running | Running |
| Android worker (PID 22552) | Alive | Alive |

**No leaks.**

## Defects Found

**None.** All observed behavior matched expectations.

## What the Experiment Proves

1. **Worker independence is real** — the worker survived USB loss and completed the job without the Mac.
2. **Durable result survives transport loss** — `result.json` was written and retained the original job ID.
3. **Job ownership is preserved across a disconnect** — the durable result carried the correct `job_id`.
4. **CLI failure reporting is correct** — structured error, no hang, no crash.
5. **No process leaks** — clean teardown on both sides.
6. **Recovery is clean** — reconnect restored full capability and a subsequent job succeeded with no stale-result contamination.

## What Remains Unverified

1. **F7 recovery on real hardware** — the path that handles *stream lost + worker alive and visible* was not exercised here; it was later verified against mocks in Phase 10 Step 3.
2. **Long disconnects** — only ~2 minutes tested.
3. **Repeated disconnect/reconnect cycles** — only one cycle tested.

## Production Change Justified?

**No.** No concrete defect was established. Every observed behavior was correct.

## Recommended Next Phase 10 Target

**F7 Recovery Path Verification** — selected because F7 is the one path this experiment could not reach, and it is the highest-value remaining gap.

---

**Experiment complete. No files modified.**

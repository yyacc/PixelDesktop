# Phase 7 — E1 Streaming Implementation

**Status:** IMPLEMENTATION COMPLETE. Verified on the physical Pixel 7a.
**Date:** 2026-10-02
**Validated by:** E1 experiment, commit `790164d`.
**Commits:** implementation + documentation (see the repository log).

---

## 1. What changed

The worker orchestration moved from **file exchange + Mac-side polling** to a **single persistent
`adb shell` session** that streams events, while keeping the durable result file as the record of
truth.

```
OLD                                      NEW
adb push job.json                        job payload on stdin
am start                                 am start
Mac-side poll for pid / result.json      streamed liveness + completion
adb pull result.json                     result read from the durable file
```

**The old path is not deleted.** `ADBWorkerOperations`, `WorkerComputeProof` and the polling
helpers remain, still used by the Phase 5/6 paths and still covered by their existing tests. The
streaming path is added alongside, which is what E1's "ADDITIVE, not a replacement" conclusion
required.

### Files

| File | Change |
|---|---|
| `Worker/WorkerStreamProtocol.swift` | **new** — event protocol, parser, stream state, outcome model |
| `Worker/WorkerStreamReducer.swift` | **new** — the pure state machine (F4 + F7 logic) |
| `Worker/WorkerStreamScript.swift` | **new** — the device-side script builder + job-id containment |
| `Worker/WorkerStreamRunner.swift` | **new** — session orchestration, durability, recovery |
| `Transport/Transport.swift` | `shellStreaming` added to the protocol; `StreamReadState` added |
| `Transport/ADBTransport.swift` | `shellStreaming` implemented (incremental, separate stderr, bounded) |
| `PixelDesktopTests/WorkerStreamingTests.swift` | **new** — 41 unit tests |
| `PixelDesktopTests/Phase7StreamingDeviceHarness.swift` | **new** — 6 live-device tests |
| `PixelDesktopTests/PixelDesktopTests.swift` | `MockTransport` extended: streaming + response sequences |

**No Android source changed.** The APK, manifest and worker Java are untouched.

---

## 2. The event protocol

```
PDE1 START job_id=<id>          session began, job identity
PDE1 JOB_WRITTEN bytes=<n>      payload written from stdin
PDE1 LAUNCHED                   am start issued (NOT proof the process is up)
PDE1 HEARTBEAT n=<i> pid=<pid>  liveness tick; pid=none when no process matched
PDE1 WORKER_EXITED n=<i>        the script itself determined the worker died
PDE1 RESULT_BEGIN               result payload follows
     <opaque JSON lines>        the result, unparsed
PDE1 RESULT_END bytes=<n>       result payload ended, with the device-reported size
PDE1 ERROR code=<c> message=<m> a bounded failure detected by the script
```

**Not an RPC framework.** No framing, no handshake, no session negotiation, no multiplexing. It is
a prefix, a token and `key=value` pairs, because the only things parsing it are a `while` loop on
the device and a `switch` on the Mac.

### Why the events come from the script, not the worker

The Android worker emits **nothing** to stdout — verified: it writes to logcat only, and
`grep -rn "System.out\|System.err"` across its Java sources returns no matches. It is launched by
`am start`, so its stdout belongs to the Android app runtime, not to the ADB shell.

This is E1's limitation **L6**, and it bounds what the protocol may claim:

> **`HEARTBEAT` is process liveness, never model-generation progress.** The worker has no progress
> to report, so none is invented.

Real progress would require a worker-side change. That is a separate decision, not a transport
property, and it was **not** made here.

---

## 3. Lifecycle and state model

Stream state and worker state are **separate axes**, and the four combinations the brief requires
are all distinct and unit-tested:

| State | Meaning |
|---|---|
| `.streamAliveWorkerAlive(pid:)` | session up, process present |
| `.streamAliveWorkerExited` | session up, process died — **F4** |
| `.streamLostWorkerAlive(pid:)` | session gone, process still running — **F7** |
| `.streamLostWorkerGone` | session gone, process gone |
| `.streamLostWorkerUnknown` | session gone, state could not be determined |

Outcomes distinguish what the stream reported from what the device confirmed:

| Outcome | Meaning |
|---|---|
| `.completed(resultJSON:resultBytes:)` | result streamed **and** the durable file confirmed |
| `.completedButDurabilityUnverified` | result streamed, durable file not confirmable |
| `.recoveredFromDevice` | session died; the result was read from the device afterwards — **F7** |
| `.workerExitedUnexpectedly(sequence:)` | process died before a result — **F4** |
| `.streamLostWorkerRunning(pid:)` | session died, worker still running (**not** a failure) |
| `.streamLostWorkerGone` / `.streamLostUnknown` | reported, not guessed |
| `.failed(code:message:)` | the script reported a bounded failure |
| `.malformedStream` | structurally invalid stream |

**`mayStillBeRunning`** is the flag callers use to decide that a **cancellation must not be issued** —
killing a worker because its session died would discard valid in-flight work.

---

## 4. The two required fixes

### F4 — worker disappearance is an explicit transition

E1 measured a naive heartbeat loop that saw `pid=none` and **kept heartbeating to the end of its
window**. In production:

- a run of consecutive missed liveness checks **with no result present** moves the state to
  `.streamAliveWorkerExited` and sets a terminal outcome;
- the device script makes the same determination independently (`WORKER_EXITED`) and exits;
- a **single** miss is not death — the process can be mid-exit after writing its result;
- misses **before launch** and **after a result** do not count, because `none` is expected there.

**Verified on hardware:** killing the worker produced `workerExitedUnexpectedly(sequence: 4)` and the
run terminated in **3.3 s** instead of heartbeating indefinitely.

### F7 — stream loss is not job failure

When the session ends with no terminal event, the runner asks the **device**:

1. is the worker still running? (`pidof`)
2. does a durable result exist? (`stat` + `cat`)
3. if so, recover it and report `.recoveredFromDevice`

**The worker is never killed because its session died.**

**Verified on hardware:** with no session watching, the worker ran to completion and wrote a
**2389-byte** durable result that was recovered afterwards.

---

## 5. Long-running jobs

**No fixed heartbeat count and no job timeout.** E1 F5 showed a job may exceed 90 s, so a count-based
bound would be a fabricated failure. A job may report liveness indefinitely while the worker lives.

There is exactly one time bound, and it is a **stall detector, not a job limit**:

- `ADBTransport.streamStallTimeout = 120 s` — a live worker heartbeats every 0.5 s, so silence of
  this length means the transport is gone.
- A 5 s reap deadline after the session ends, so a stuck `adb` child cannot block the caller.

Both bounds are on **quiet**, never on duration.

---

## 6. Job input — `adb push` removed from the streaming path

`cat > job.json` over stdin delivers the payload, verified by E1. The streaming path uses it and
issues **no `push`**. The old path's `push` remains for the Phase 5/6 flows.

The job id is the only value interpolated into a device shell command, and it is validated against
`[A-Za-z0-9-]` with a 64-character cap before use, so it cannot express shell syntax.

---

## 7. Result handling

`result.json` remains the **durable source of truth**. The stream is a live channel.

Durability is **confirmed against the device**, never assumed:

- `.completed` requires the device to report a positive size, and the durable size must be **at least**
  what the stream carried;
- a missing, empty or shorter file yields `.completedButDurabilityUnverified` with a reason.

The brief's rule — *"stream completion does not mean result durability"* — is enforced by the type
system rather than by convention.

---

## 8. Cancellation

**Unchanged: `am force-stop`, external to the session.** E1 F3 established that streaming provides
no cancellation. A unit test asserts the streaming path never issues one.

**Measured on hardware:** `am force-stop` took **140–144 ms** across runs (E1 measured 69 ms).

---

## 9. Tests

**Unit — 41 tests** in `WorkerStreamingTests.swift`, covering the brief's list 1–19:

successful job · incremental delivery · no polling · malformed job · missing model · worker exits ·
PID disappears · stream loss while alive · stream loss after completion · durable result survives ·
result missing · truncated/empty result · malformed stream · unrecognised output · cancellation
stays external · no heartbeat cap · locked/dozing equivalence · stdout/stderr separation · payload on
stdin · job-id containment · every protocol token · transport failure at startup · the four distinct
states · terminal outcome is final.

**Live device — 6 tests** in `Phase7StreamingDeviceHarness.swift`, skipped unless
`PIXELDESKTOP_DEVICE_SERIAL` is set (the Phase 2–7 convention):

| Test | Result |
|---|---|
| raw streaming primitive (stdout, stderr, stdin) | **PASS** |
| streamed DTCA-1 job with durable result | **PASS** |
| worker death detected (F4) | **PASS** |
| session loss while worker continues (F7) | **PASS** |
| cancellation via `am force-stop` | **PASS** |
| performance on the E1 workload | **PASS** |

**Full suite: 310 tests, 0 failures** (12 skipped are the device-gated tests when no serial is set).

Unit and live tests are deliberately separate so a passing unit suite is never mistaken for device
verification.

---

## 10. Live-device results

```
=== E1 STREAMING — REAL DEVICE DTCA-1 JOB ===
outcome            : completed(... job_id 5DA7D32A-... , resultBytes: 401)
worker pid observed: 27423
heartbeats         : 1
outcome at (s)     : 0.765
PASS (1.112 s)

=== E1 F4 — REAL DEVICE WORKER DEATH ===
outcome    : workerExitedUnexpectedly(sequence: 4)
heartbeats : 6
PASS (3.271 s)

=== E1 F7 — REAL DEVICE SESSION LOSS ===
worker running after 'session loss': true pid=27472
durable result bytes: 2389
PASS (166.875 s)

=== E1 F3 — REAL DEVICE CANCELLATION ===
am force-stop took 140 ms
outcome after cancellation: workerExitedUnexpectedly(sequence: 4)
PASS (3.313 s)

=== RAW STREAMING PRIMITIVE ===
stdout lines: ["PDE1 TEST1", "PDE1 TEST2"]
stderr lines: ["TO_STDERR"]
stdin: PDE1 WROTE=17
PASS (0.558 s)
```

---

## 11. Performance comparison

**Same workload as E1** (LOCAL-LLM-1, 32 max tokens, "capital of France"). DTCA-1 is deliberately
not used: its ~1 ms of compute would make streaming look artificially transformative.

| Metric | OLD (E1 baseline) | NEW (streaming) |
|---|---|---|
| time to first output | 0.060 s | **0.036 s** |
| launch acknowledgement | 0.170 s | 0.196 s |
| completion detection | **758 ms poll cycle** | **0 s — carried by the stream** |
| wall time | 27.600 s | **20.985 s** |
| heartbeats | 26 | 37 |

**On the wall time, stated carefully.** The new path measured **6.6 s faster**, but the run-to-run
variance of this workload is large — Phase 6 measured a 2.4× spread, and the worker's own reported
`total_ms` varied by ~12× across E1 and this run. **The 6.6 s is therefore not attributable to the
streaming change**, and it is not claimed as a speed-up. What *is* attributable:

- **completion detection moved from a 758 ms poll cycle to the stream** — the poll loop is gone;
- **first output arrived marginally sooner** (0.036 s vs 0.060 s);
- **progress is now observable at all**, which it was not before.

The honest summary: **the win is architectural, not a throughput claim.**

---

## 12. Verification

| Check | Result |
|---|---|
| full test suite | **310 tests, 0 failures** |
| live-device verification | **6/6 PASS** |
| build | SUCCEEDED |
| new permissions | **none** (manifest untouched) |
| new network listener | **none** |
| new background service | **none** |
| TransportManager / router / scheduler / mDNS | **none** |
| Android source changed | **none** |
| experimental files in repo | **none** |
| worker remains one-shot | yes — `finish()`, no Service |

---

## 13. Remaining limitations

| # | Limitation |
|---|---|
| **L1** | A session that dies loses the **stream**. Progress is not durable; only the file is |
| **L2** | Cancellation remains external (`am force-stop`); the stream cannot cancel |
| **L3** | **Progress is liveness only.** Real generation progress needs a worker-side change — not made here |
| **L4** | One session = one job; concurrency still needs multiple sessions |
| **L5** | The session is host-initiated; the Pixel still cannot speak first |
| **L6** | The old polling path still exists for Phase 5/6 flows; the two paths coexist |
| **L7** | The stall detector assumes a heartbeat every 0.5 s; a future change to the cadence must update `streamStallTimeout` |

**L3 is the most consequential for future work.**

---

## 14. Defects found by live execution

Four defects were found by running against the real device — none by the unit suite:

| # | Defect | How it surfaced | Fix |
|---|---|---|---|
| **1** | **`do;` shell syntax error** | The script was assembled with `joined(separator: "; ")`, emitting `while ...; do; i=0`. `do;` is a syntax error, so the **entire script failed to parse and the stream produced no output at all** | `while ...` and `do i=...` as separate elements; asserted by a new unit test |
| **2** | **Watchdog resumed only when the child was alive** | A child that had exited while the reader was blocked left the continuation **never resumed** | Watchdog acts unconditionally; `StreamReadState` guarantees one resume |
| **3** | **`process.waitUntilExit()` blocked forever** | With the transport dead, the `adb` child stayed alive and the run sat for 15 minutes | Bounded reap with a 5 s deadline, then SIGTERM/SIGKILL |
| **4** | **Unbounded harness waits** | Each probe cost 30 s on a dead transport; 240 iterations became a 2-hour wait | Wall-clock deadlines throughout the device harness |

**Defect 1 is the notable one**: it is a pure string-assembly error that no unit test caught, and it
only appeared on hardware. The regression test added for it asserts the assembled script's structure,
which is what a unit test can actually check.

---

## 15. Recorded architectural distinction

```
ADB remains the transport and privileged control boundary.

Persistent adb shell provides the live execution stream.

result.json remains the durable job record.

Worker liveness, connection state, and result state are independent.
```

And, from E1, now implemented: **ADB itself was capable of the required streaming behaviour,
eliminating the need for a second communication architecture.** No WebSocket, gRPC, Service, custom
USB transport, `adb forward` RPC, TransportManager, scheduler or custom mDNS was added.

---

## Provenance

**Measured on the physical Pixel 7a:** 6/6 live tests passing; DTCA-1 streamed completion at 0.765 s
with a 401-byte durable result; F4 death detected at heartbeat 4 with the run ending in 3.3 s;
F7 recovery of a 2389-byte durable result with no session alive; `am force-stop` 140–144 ms; the E1
workload completing in 20.985 s with 37 heartbeats; first output at 0.036 s.

**Measured in E1 (cited as baseline):** first output 0.060 s, launch ack 0.170 s, wall 27.600 s,
758 ms result wait, 26 heartbeats.

**Verified by source inspection:** the worker writes nothing to stdout; the manifest declares zero
permissions and no Service; the Android sources are unchanged.

**Not claimed:** any throughput improvement. The 6.6 s wall difference is within this workload's
observed variance and is explicitly not attributed to the change.

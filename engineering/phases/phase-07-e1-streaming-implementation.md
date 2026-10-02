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

## 16. Verification round — deliberate transport loss and review findings

A second verification pass was performed specifically to exercise the transport-loss behaviour and
to review the implementation for unbounded waits. It produced **one production fix**, **three
harness corrections**, and **two new deliberate-failure tests**.

### 16.1 Production fix — recovery must prove ownership

**Defect 5: `recoverDurableResult` did not verify the recovered result belonged to the job.**

The device script removes any previous `result.json` before launching, **but that removal only
happens if the script actually ran**. When a session dies before producing *any* output, there is no
evidence the script reached its `rm`, so a result left by an earlier job can still be sitting at the
fixed path.

Reporting that as a recovery for the current job is a **false `recoveredFromDevice` classification** —
precisely the failure mode the fixed-path contract's staleness rule exists to prevent.

Fixed: recovery now parses the payload and requires a matching `job_id`
(`WorkerStreamRunner.resultBelongsToJob`). A result that is missing the field, mismatched, or not
parseable is **not** treated as this job's result — consistent with ADR-004's rule that an
unparseable result is never trusted.

Four unit tests were added, including one that fails without the fix.

### 16.2 Production fix — bounded stderr drain

**Defect 6: the stderr drain thread was unbounded and its handle was never closed.**

A transport that dies while `adb` keeps its stderr pipe open would leave that thread blocked in
`availableData` **forever** — a leaked thread per session, the same class of defect already found
twice in this path. The drain is now bounded by `streamStallTimeout + 5 s`, after which the read end
is closed.

### 16.3 Deliberate transport-loss tests (new)

Two live-device tests now sever the transport on purpose by killing the ADB **server** mid-session —
deterministic and fully reversible, unlike a physical unplug.

**Test: `testDeliberateTransportLossIsBoundedAndDoesNotFailTheJob`** — passes (3.94 s):

```
transport severed      : true
session returned after : 3.94 s
outcome                : streamLostWorkerRunning(pid: 1683)
mayStillBeRunning      : true
```

The exact defect the brief was most concerned with — *"the stream reader blocks, `waitUntilExit()`
never returns"* — is **fixed and demonstrated**: the session terminates in under 4 seconds, and
transport loss is classified as worker-still-running, **not** as a job failure.

**Test: `testResultIsRecoverableAfterDeliberateTransportLoss`** — passes (169.8 s):

```
worker running before sever   : true pid=1798
worker seen running after sever: true
durable result bytes          : 2098
```

The worker **survived** the transport being severed, was **not killed**, and its durable result was
recovered afterwards and confirmed to carry this job's id.

### 16.4 Harness corrections (not production defects)

| # | Correction | Why |
|---|---|---|
| 1 | DTCA-1 test no longer requires an observed PID | DTCA-1 completes in ~1 ms, so the process is often gone before the first heartbeat. Requiring a PID asserted a race, not a behaviour — measured: a successful 401-byte result arrived with `pid=none` on heartbeat 1 |
| 2 | F7 recovery deadline raised from 240 s to 900 s | 192 tokens at ~1 tok/s legitimately exceeds 300 s; E1 measured a 256-token job at **313 s**. The bound was too short, not the implementation wrong |
| 3 | Same for the deliberate-loss recovery deadline | Same reasoning |

**These are recorded explicitly because a harness that fails for its own reasons must not be
mistaken for a production defect.** Each was a wrong assertion or a mis-sized bound, not a fault in
the code under test.

### 16.5 Final live-device results — 8/8 PASS

| Test | Result |
|---|---|
| raw streaming primitive (stdout/stderr/stdin) | **PASS** |
| streamed DTCA-1 job with durable result | **PASS** |
| worker death detected (F4) | **PASS** |
| session loss while worker continues (F7) | **PASS** |
| cancellation via `am force-stop` | **PASS** |
| **deliberate transport loss — bounded** | **PASS** (3.94 s) |
| **recovery after deliberate transport loss** | **PASS** (2098-byte result) |
| performance on the E1 workload | **PASS** |

**Full suite: 316 tests, 0 failures** (14 skipped are the device-gated tests when no serial is set).

### 16.6 Transport used

The deliberate-loss tests were run over **USB**. The brief asked for wireless where practical;
**wireless ADB could not be established** during this round — see §17.

---

## 17. Wireless ADB — not established this round (honest blocker)

The brief specified wireless ADB as the path for completing live verification. **It could not be
established**, and the attempt is recorded rather than worked around.

**What was tried** (all reversible):

1. `settings put global adb_wifi_enabled` toggled off → on (the method that worked in the earlier
   verification).
2. Confirmed the setting took (`adb_wifi_enabled = 1`).
3. Confirmed the device was **listening**: `tcp6 [::]:38309`, later `46777`.
4. `adb kill-server` / `start-server` to re-initialise mDNS discovery.
5. Wi-Fi reset on the device (`svc wifi disable` → `enable`) to force the supplicant to re-establish.
6. Woke the device — it was **`mWakefulness=Dozing`**, which restricts wireless ADB, and it was kept
   awake (`svc power stayon usb`) for the attempts.
7. Explicit `adb connect 192.168.1.9:<port>` against every bound candidate port.

**Observed state:**

| Check | Result |
|---|---|
| `adb_wifi_enabled` | `1` (enabled) |
| device TLS listener | **bound** — `tcp6 [::]:38309`, later `46777` |
| `getprop service.adb.tls.port` | **empty** |
| `adb mdns services` | **empty** — no advertisement reached the Mac |
| `dns-sd -B _adb-tls-connect._tcp` | no service found |
| Mac ↔ Pixel reachability | Pixel was on `192.168.1.9/24`, Mac on `192.168.1.10/24`, same subnet; ping succeeded **only after waking the device** |
| `adb connect` result | `offline` on 38309; `Host is down` on 46777; refused on the loopback-only port |

**Interpretation, stated conservatively:** the device binds a TLS port and reports wireless debugging
enabled, but the ADB TLS handshake does not complete and **mDNS never advertises**. The Mac and Pixel
are on the same subnet and can reach each other, so this is not a routing problem. The most likely
cause is the device's Wi-Fi/doze state — the Pixel was Dozing and its Wi-Fi had been reset — but
**that is not established**, and no cause is claimed.

**What this does and does not affect.** The brief's reason for preferring wireless was that the USB
link is unstable (FAIL-006). The verification therefore used USB, and **the USB link held for the
entire 8-test run (~7.5 minutes) without a drop** — which is itself a useful observation, but *not*
evidence that FAIL-006 is resolved, and it is not claimed as such.

**Wireless ADB remains reachable in principle**: the earlier verification (`f3552cf`) established it
end-to-end, including `adb -s <wireless-serial>`. Nothing in this round contradicts that; the
transport simply could not be brought up on this attempt.

---

## 18. USB FAIL-006 — separately classified

Per the brief, the recurring USB failures are recorded as their own finding and **must not** be
treated as a streaming implementation failure.

```
FAIL-006:
  macOS USB/XHCI physical transport instability
  — the Pixel physically disappeared from the USB bus three times during the earlier
    implementation round, with ioreg showing no Pixel present at the kernel level.

Streaming implementation:
  tested independently — 8/8 live-device tests passed, including two deliberate
  transport-loss tests, with the USB link stable throughout the verification run.
```

**No USB reconnect logic was added. The Phase 7 transport architecture is unchanged.** FAIL-006
remains open and unresolved; this round did not attempt to fix it.

---

## 19. Lifecycle state verification

The brief asked for the four situations to be verified in the implementation's own terminology
rather than with invented states. Measured results:

| Situation | Implementation state | Evidence |
|---|---|---|
| RUNNING + stream connected + worker alive | `.streamAliveWorkerAlive(pid:)` | live run: `worker pid observed: 31546`, 33 heartbeats |
| RUNNING + stream disconnected + worker alive | `.streamLostWorkerRunning(pid:)` | **deliberate sever: `streamLostWorkerRunning(pid: 1683)` in 3.94 s** |
| FAILED + worker exited unexpectedly | `.streamAliveWorkerExited` → `.workerExitedUnexpectedly(sequence:)` | kill test: `sequence: 3`, terminated in 2.6 s |
| COMPLETED + worker completed + durable result present | `.completed(resultJSON:resultBytes:)` | DTCA-1: 401 bytes; LLM: `completed` |
| UNCERTAIN / RECOVERY + transport lost, worker/result undetermined | `.streamLostUnknown(reason:)` / `.recoveredFromDevice` | recovery test: 2098-byte result recovered after sever |

**Transport failure is never collapsed into job failure.** The deliberate-sever test asserts this
directly: the outcome carries `mayStillBeRunning: true` and is not a hard failure.

---

## 20. Long-running behaviour

**No artificial ceiling was imposed or tested against.** The E1 F5 finding — that a 90 s harness cap
was wrong — is respected:

- the production path has **no job timeout**, only the 120 s *stall* detector;
- the live harness bounds were raised to **900 s**, sized to the workload rather than to make tests
  terminate (a 192-token job legitimately needs over 300 s at ~1 tok/s);
- the F7 test ran **243 s** to natural completion.

The only production time bounds, both justified by an actual system requirement:

| Bound | Value | Justification |
|---|---|---|
| `streamStallTimeout` | 120 s | a live worker heartbeats every 0.5 s, so 120 s of silence means the transport is gone — a stall detector, not a duration limit |
| reap deadline | 5 s | bounds process reaping after a session ends, so a stuck `adb` child cannot block the caller |

---

## 21. Remaining limitations (updated)

| # | Limitation |
|---|---|
| **L1** | A session that dies loses the **stream**. Progress is not durable; only the file is |
| **L2** | Cancellation remains external (`am force-stop`); the stream cannot cancel |
| **L3** | **Progress is liveness only.** Real generation progress needs a worker-side change — not made here |
| **L4** | One session = one job; concurrency still needs multiple sessions |
| **L5** | The session is host-initiated; the Pixel still cannot speak first |
| **L6** | The old polling path still exists for Phase 5/6 flows; the two coexist |
| **L7** | The stall detector assumes a 0.5 s heartbeat cadence; a change to that cadence must update `streamStallTimeout` |
| **L8** | **Wireless ADB could not be established this round** — verification was over USB |
| **L9** | The deliberate-loss tests sever the ADB *server*, which is a deterministic proxy for a physical unplug, not a physical unplug itself |
| **L10** | FAIL-006 (USB instability) remains open and unresolved |

**L3 remains the most consequential for future work.**

---

## 22. Defects found by live execution (complete list)

| # | Defect | Found by | Fixed |
|---|---|---|---|
| 1 | `do;` shell syntax error — the entire script failed to parse, producing no output | live device | yes |
| 2 | Watchdog resumed the continuation only when the child was alive | live device | yes |
| 3 | `process.waitUntilExit()` blocked forever | live device | yes |
| 4 | Unbounded waits in the device harness | live device | yes (harness) |
| 5 | **Recovery did not verify the result belonged to the job** | **code review** | **yes** |
| 6 | **Unbounded stderr drain thread** | **code review** | **yes** |

**Defects 5 and 6 were found by the review requested in this round, not by execution.** Both are
production fixes with new tests. Defect 1 remains the notable one — a pure string-assembly error
that no unit test caught.

---

## Provenance

**Measured on the physical Pixel 7a (this verification round):** 8/8 live-device tests passing;
deliberate transport sever returning in **3.94 s** with `streamLostWorkerRunning(pid: 1683)` and
`mayStillBeRunning: true`; recovery of a **2098-byte** durable result after a sever with the worker
surviving; F7 session loss recovering a **2389-byte** result in 242.955 s; F4 death detected at
heartbeat 3, terminating in 2.605 s; `am force-stop` 108–144 ms; DTCA-1 completing in 0.938 s with a
401-byte result; the E1 LLM workload completing in 22.540 s with 40 heartbeats; full suite **316
tests, 0 failures**.

**Measured in E1 (cited as baseline):** first output 0.060 s, launch ack 0.170 s, wall 27.600 s,
758 ms result wait, 26 heartbeats.

**Verified by source inspection:** the worker writes nothing to stdout; the manifest declares zero
permissions and no Service; the Android sources are unchanged.

**Attempted and not achieved:** wireless ADB could not be established — device TLS port bound,
`service.adb.tls.port` empty, mDNS silent, handshake not completing. Recorded in §17.

**Not claimed:** any throughput improvement (the wall-time difference is within this workload's
observed variance); any resolution of FAIL-006; any wireless persistence beyond what was previously
verified in `f3552cf`.

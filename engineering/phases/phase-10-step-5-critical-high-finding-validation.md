# Phase 10 Step 5 — Critical/High Finding Validation

- **Date:** 2026-10-04
- **Review file validated:** `engineering/phases/phase-10-step-5-code-architecture-security-review.md`
- **Mode:** READ-ONLY evidence validation. No production files, tests, or documentation modified. No commits.
- **Method:** Direct source inspection of every cited location + surrounding code, caller/callee tracing, test inspection, and one empirical reproduction harness (standalone, outside the repo).

---

## CRITICAL Findings

### C1 — Pipe deadlock in `ADBTransport.execute()`

**Finding:** `process.waitUntilExit()` is called before `readDataToEndOfFile()`, so a child writing more than the pipe buffer blocks on write while the parent blocks on exit.

**Source:** `PixelDesktop/Transport/ADBTransport.swift:48–104` (pattern at lines 60–63).

**Evidence:** Direct source read confirms the exact ordering:

```swift
process.waitUntilExit()                                        // line 60
let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()   // line 62
```

Empirically reproduced with a standalone harness replicating this pattern exactly (no repo files touched):

```
[sh 100KB] *** DEADLOCK: still blocked after 10s ***   → read 65536 bytes
[sh 1MB]   *** DEADLOCK: still blocked after 10s ***   → read 65536 bytes
[sh 8MB]   *** DEADLOCK: still blocked after 10s ***   → read 65536 bytes
[adb getprop] COMPLETED — read 53721 bytes
```

The 65,536-byte read confirms the macOS pipe capacity. Any child output above that stalls until the timeout task fires.

**Classification: CONFIRMED DEFECT**

**Reasoning:** The mechanism is real and reproduced, not inferred. The review's characterization is accurate. Two corrections to the review's framing, both of which make the finding *narrower* rather than weaker:

1. **The streaming path is not affected.** `shellStreaming` (lines 253–426) drains stdout and stderr concurrently on dedicated queues and explicitly documents the deadlock it avoids (lines 297–303). `StreamingLifecycleTests.testLargeOutputOnBothStreamsDoesNotDeadlock` (line 452) covers that path — but only that path.
2. **The `execute()` path is where it lives, and `shell()` is the reachable volume-bearing caller.** ⚠️ **CORRECTED 2026-10-04 during remediation:** the original text here claimed the defect was "reachable with a >64 KB response today" through `DeviceEnricher.enrich` → `getSystemProperties`. **That was wrong.** `DeviceManager.enrichDevice` has **zero non-test callers**, so the `getSystemProperties` chain is *latent*, not active. The defect is nonetheless real and reachable through `shell()`, whose production callers include `PixelEvidence`'s combined reads and `WorkerStreamRunner`'s `cat result.json` during F7 recovery.

**Impact is bounded, not fatal:** `getSystemProperties` is called with `timeout: 10` (DeviceEnricher default). Exceeding the buffer therefore costs the full 10 s and then throws `PixelDesktopError.timeout` — a slow, typed failure, not a permanent hang. The review's "blocks forever" is imprecise; the timeout task mitigates it.

**Existing Test Coverage:** None for this path. `StreamingLifecycleTests` covers `shellStreaming` only. `Phase9CLITests.swift:105–108` uses the same `waitUntilExit()`-then-read ordering in test infrastructure, but against a CLI whose output is small. No test exercised `execute()` with output above the pipe buffer. **Closed:** `ExecutePipeDrainTests` now covers it, including two device-gated cases.

**Action Required:** Yes — but not urgent, and the fix is small. Drain stdout/stderr concurrently with `waitUntilExit()` (readability handler or drain task), or bound the read with `head -c`. Given the current 82% margin on `getprop`, this should be scheduled before any new `execute()`-path command is added.

> **RESOLVED — 2026-10-04, commit `b89b012`.** Fixed by draining both pipes on concurrent
> queues while the child runs, with a bounded wait after exit. Additional evidence gathered
> during remediation, which this validation did not have:
>
> | Call | Old ordering | New implementation |
> |---|---|---|
> | `getprop` ×1 (53,721 B — under buffer) | 0.13 s, complete | — |
> | `getprop` ×3 (~161 KB — **above buffer**) | **deadlock: 0 bytes, still blocked at 20 s** | **0.130 s, complete** |
>
> The old-ordering row is the missing piece this validation lacked: the original harness tested
> the boundary with a *local* child and the device measurement was taken at 53,721 bytes, which
> was **under** the buffer. The defect was therefore demonstrated but never shown to fire on real
> hardware. It has now been: the pre-fix code path, reproduced standalone against the real Pixel
> 7a at ~161 KB, deadlocks completely. The fix resolves it on the same call.
>
> Also note: the "82% of the buffer" figure is a *margin*, not a failure. `getprop` ×1 does not
> deadlock. The correct statement is that the margin is thin and the failure is one command away,
> not that production was already broken.

---

### C2 — `Thread.sleep` in async context

**Finding:** `Thread.sleep` blocks the underlying thread inside an async function, risking cooperative-thread-pool starvation.

**Source:** `PixelDesktop/Transport/ADBTransport.swift:390, 411, 416`.

**Evidence:** Confirmed by direct read. Line 390 is inside the watchdog `DispatchQueue.asyncAfter` closure; lines 411 and 416 are in the synchronous reap loop after the `withCheckedContinuation` block.

**Classification: IMPROVEMENT**

**Reasoning:** The API misuse is real — `Thread.sleep` in an async function is a genuine anti-pattern. But the review overstates the consequence, and the code has a structural safeguard the review did not account for:

- **Line 390 is not on an async executor thread.** It runs inside `watchdog.asyncAfter` on a dedicated `DispatchQueue` (line 384). Blocking there consumes a dispatch-queue worker, not a cooperative-pool thread.
- **Lines 411/416 are in the synchronous tail of `shellStreaming`.** They block the calling thread for at most `childReapTimeout` (5 s, line 22) plus 0.3 s. `shellStreaming` is called once per job, not in a loop.
- **The pool-starvation scenario requires concurrent `shellStreaming` calls.** PixelDesktop runs one job at a time; there is no concurrent-execution path. The hazard is latent, not reachable.

This is worth fixing for hygiene and future concurrency, but no evidence establishes a concrete reliability problem today. The review's own severity of CRITICAL is not supported.

**Existing Test Coverage:** `StreamingLifecycleTests.testWatchdogTerminatesAStalledChild` (line 205), `testWatchdogFiresWhileProcessIsStillAlive` (line 308), `testStalledChildIsNotLeftRunningAfterTeardown` (line 556) exercise the watchdog and reap paths behaviourally — they would catch a hang, but not thread-pool exhaustion.

**Action Required:** No, not as a defect. Fold into the C1 remediation if that file is being touched anyway.

---

### C3 — `kill()` without process-existence check

**Finding:** A PID could be reused between the `isRunning` check and `kill()`, signalling an unrelated process.

**Source:** `PixelDesktop/Transport/ADBTransport.swift:392` (and the same pattern at 418).

**Evidence:** Direct read confirms:

```swift
if process.isRunning {
    process.terminate()
    Thread.sleep(forTimeInterval: 0.5)
    if process.isRunning {
        kill(process.processIdentifier, SIGKILL)   // line 392
    }
}
```

**Classification: IMPROVEMENT**

**Reasoning:** The theoretical race is real — POSIX does not reserve a PID after `isRunning` returns. But the window is not what the review implies:

- The check at line 391 is re-evaluated *immediately* before `kill()` at line 392, after a 0.5 s settle. The exposure is the handful of instructions between the two, not the 0.5 s.
- **Foundation's `Process` retains the child.** On macOS, `Process` keeps the `pid` valid until the object is deallocated or `waitUntilExit` reaps it; the parent has not reaped here, so the PID is not yet available for reuse. This is the safeguard the review's reasoning omits.
- The same pattern appears in the reap path at 414–419, which the review did not separately flag — consistent with it being a stylistic observation rather than a traced defect.

No reproduction exists, and the mechanism is blocked by `Process`'s own retention. Correct as defensive hardening; not a demonstrated defect.

**Existing Test Coverage:** `Phase10Step1CancellationTests.testCancellationCleansUpAdbProcess` (line 452) and `testStalledChildIsNotLeftRunningAfterTeardown` (line 556) verify no child survives teardown — the outcome the race would break — but neither can force the race.

**Action Required:** No. Optionally replace with `process.terminate()` only, or check `kill(pid, 0)` first.

---

## HIGH Findings

### H1 — Reap loop blocks the async thread

**Finding:** The `while process.isRunning` loop with `Thread.sleep(0.05)` busy-waits for up to 5 s.

**Source:** `PixelDesktop/Transport/ADBTransport.swift:409–423`.

**Evidence:** Direct read confirms the loop and its bound (`childReapTimeout = 5.0`, line 22).

**Classification: IMPROVEMENT**

**Reasoning:** Same root as C2 — this is the synchronous tail of `shellStreaming`, not an async executor context. The loop is bounded at 5 s, runs once per job, and the file's own comment (lines 402–408) documents that this replaced an *unbounded* `waitUntilExit()` after a real 15-minute hang was observed on the device. The current code is the fix for a worse problem, not a new one.

The review's claim that this "blocks the async thread for up to 5 s" is technically true but misleading: `shellStreaming` has already returned its result to the caller by this point in the sense that no other async work is queued behind it in this single-job system.

**Existing Test Coverage:** `StreamingLifecycleTests.testEveryTerminationPathResumesExactlyOnce` (line 521) includes a watchdog case with `reap: 0.1` and asserts completion under 15 s — this exercises the reap loop's bounded-exit behaviour.

**Action Required:** No.

---

### H2 — Cancellation race with the reader thread

**Finding:** The reader may process one more line after cancellation before checking the flag.

**Source:** `PixelDesktop/Transport/ADBTransport.swift:350–379`.

**Evidence:** Direct read confirms the ordering the review describes — the flag check at line 361 sits *after* `availableData` at line 359:

```swift
let chunk = stdoutHandle.availableData      // line 359 — may block
if chunk.isEmpty { break }
if state.isCancelled || cancellation.isCancelled { break }   // line 361
```

The cancellation handler (lines 350–354) closes the handle, calls `state.cancel()`, then `state.finish(continuation)`.

**Classification: FALSE POSITIVE**

**Reasoning:** The review's own text concedes "`StreamReadState` ensures exactly-once resume, so this is **safe but fragile**" — and the code has an explicit second guard the review did not weigh:

- Line 373, the post-loop flush, is gated on `!state.isCancelled, !cancellation.isCancelled` — so the buffered partial line is **not** delivered after cancellation. The review's "may process one more line" applies only to a line already extracted inside the `while let newline` loop at 363–371, which requires the chunk to have arrived before cancellation.
- The cancellation handler closes the handle *first* (line 351), which is precisely what unblocks `availableData`. The reader cannot remain blocked.
- `Phase10Step1CancellationTests` covers this directly: `testCancellationWhileStdoutBlockedUnblocksReader` (line 227), `testContinuationResumesExactlyOnceUnderCancellation` (line 256), `testRegistrationCancellationRaceIsSafe` (line 306), `testCancellationVsProcessExitIsSafe` (line 420), and `testCancellationCleansUpPipes` (line 485).

A line delivered to `onLine` after cancellation is also harmless by construction: `WorkerStreamRunner` checks `cancellation.isCancelled || Task.isCancelled` at lines 160 and 172 and throws `PixelDesktopError.cancelled` regardless of what the reducer collected. No path lets a post-cancellation line change the outcome.

**Existing Test Coverage:** Yes — five dedicated tests, listed above.

**Action Required:** No.

---

### H3 — Force unwrap in `LlmJob.encoded()`

**Finding:** `as! [String: Any]` crashes if encoding produces non-dictionary JSON.

**Source:** `PixelDesktop/Worker/LlmJob.swift:49`.

**Evidence:** Direct read confirms:

```swift
let requestData = try encoder.encode(request)
var dict = try JSONSerialization.jsonObject(with: requestData) as! [String: Any]
```

**Classification: IMPROVEMENT**

**Reasoning:** The force unwrap is real and the review's recommended fix is correct. But the crash is not reachable with the current type:

- `request` is `InferenceRequest` — a struct with a fixed `CodingKeys` set (`job_id`, `prompt`, `max_tokens`, `temperature`, `seed`). A `JSONEncoder` over a struct with named keys always produces a JSON object.
- The only way to get a non-dictionary is to change `InferenceRequest` to encode as an array or scalar, which would break the worker contract first.
- The unwrap is guarded upstream by `try` on the encode, so the realistic failure (encoding error) already throws.

This is latent-crash hardening, not a defect. Severity HIGH is not supported.

**Existing Test Coverage:** `Phase9Step7Tests.testEncodedJobWireKeys` (line 103) asserts the encoded output contains `"job_id"` and the expected wire keys — it exercises `encoded()` but cannot reach the unwrap's failure branch.

**Action Required:** No. Cheap to fix whenever that file is next touched.

---

### H4 — No size limit on durable result read

**Finding:** `cat` on the durable result has no size cap; a large file would be read into memory.

**Source:** `PixelDesktop/Worker/WorkerStreamRunner.swift:285–307` (the `cat` at line 295).

**Evidence:** Direct read confirms the read is unbounded:

```swift
let read = try await transport.shell(
    deviceSerial: deviceSerial,
    command: "cat \(WorkerTransferContract.remoteResultPath)",
    timeout: 30
)
```

But the path is guarded: `durableResultBytes` (line 327) runs `stat -c %s` first, and `recoverDurableResult` returns `nil` unless `bytes > 0` (line 289). Measured on the real device: `result.json` = **635 bytes** for a completed LOCAL-LLM-1 job.

**Classification: IMPROVEMENT**

**Reasoning:** The absence of a cap is a real gap, but the review's stated impact ("could read gigabytes") requires a worker that writes a multi-gigabyte `result.json` to a fixed path — and the worker is PixelDesktop's own code, not an untrusted third party. The threat model here is a buggy worker, not an adversary. A buggy worker large enough to matter would also have failed the `stat` round trip or the job itself.

Worth adding a bound as defence-in-depth; not a defect in the current system.

**Existing Test Coverage:** `WorkerStreamingTests` covers recovery acceptance and rejection (`testResultBelongsToJobMatching`, line 517; `testRecoveryRejectsAnUnparseableResult`; `testRecoveryRejectsAResultBelongingToADifferentJob`). No test covers an oversized result.

**Action Required:** No.

---

### H5 — Magic value `missGrace` in `WorkerStreamScript`

**Finding:** The comment says the value "mirrors" `WorkerStreamReducer.livenessMissGrace`, but the values differ (5 vs 3).

**Source:** `PixelDesktop/Worker/WorkerStreamScript.swift:84`, comment at 81–83.

**Evidence:** Direct read of both files confirms the discrepancy:

- `WorkerStreamScript.swift:84` — `let missGrace = 5`
- `WorkerStreamReducer.swift:34` — `static let livenessMissGrace = 3`

**Classification: IMPROVEMENT**

**Reasoning:** The review is correct that the comment is inaccurate. But the review's own framing — "This is intentional (the script's grace is longer so the Mac makes its own determination)" — identifies why the values *should* differ, which means the defect is in the **comment**, not the value. The design is sound: the device script tolerates more consecutive misses so the Mac-side reducer reaches its own verdict first, which is exactly what the comment's second clause claims.

This is a documentation-accuracy issue with no behavioural consequence. Severity HIGH is substantially inflated; the review itself later lists the same item as INFO (I1), which is the correct level.

**Existing Test Coverage:** `WorkerStreamingTests:877,885` cover `validateJobId` but not the script's grace value. The reducer's grace is covered indirectly by `Phase10Step1CancellationTests.testF4WorkerDeathDetectionStillWorks` (line 625).

**Action Required:** No. Reword the comment to state why 5 ≠ 3.

---

## Summary

| Finding | Severity | Classification | Action |
|---|---|---|---|
| C1 — Pipe deadlock in `execute()` | CRITICAL | **CONFIRMED DEFECT** | Fix before adding new `execute()`-path commands |
| C2 — `Thread.sleep` in async context | CRITICAL | IMPROVEMENT | Fold into C1 fix |
| C3 — `kill()` without existence check | CRITICAL | IMPROVEMENT | Optional hardening |
| H1 — Reap loop blocks async thread | HIGH | IMPROVEMENT | None |
| H2 — Cancellation race with reader | HIGH | **FALSE POSITIVE** | None |
| H3 — Force unwrap in `LlmJob.encoded()` | HIGH | IMPROVEMENT | None |
| H4 — No size limit on result read | HIGH | IMPROVEMENT | None |
| H5 — Magic value `missGrace` | HIGH | IMPROVEMENT | Comment fix only |

**1 of 8 findings survives validation as a concrete defect.**

---

## Confirmed Defects Requiring Remediation

**C1 — Pipe deadlock in `ADBTransport.execute()`** — ✅ **RESOLVED, commit `b89b012`.**

- **Mechanism:** reproduced empirically — 100 KB, 1 MB and 8 MB of child output each stalled past 10 s, reading exactly 65,536 bytes. **Later reproduced on real hardware:** `getprop` ×3 (~161 KB) against the Pixel 7a deadlocked completely under the old ordering — 0 bytes read, still blocked at 20 s — while the fixed implementation returns the same payload in 0.130 s.
- **Reachability (corrected):** through `shell()`, whose production callers include `PixelEvidence`'s combined reads and `WorkerStreamRunner`'s `cat result.json` during F7 recovery. The original claim that `DeviceEnricher.enrich` → `getSystemProperties` made it *active* was **wrong** — `enrichDevice` has no non-test caller, so that chain is latent.
- **Bounded impact:** the 10 s timeout converts the stall into `PixelDesktopError.timeout`. Slow and typed, not a permanent hang.
- **Coverage:** was a gap; now closed by `ExecutePipeDrainTests` (10 tests, 2 device-gated).

No other finding in the CRITICAL/HIGH set is a concrete defect.

---

## Findings That Should NOT Be Fixed

### FALSE POSITIVE

**H2 — Cancellation race with the reader thread.** `StreamReadState` guarantees exactly-once resume, the post-loop flush is gated on `!state.isCancelled` (line 373), the handler closes the handle first to unblock `availableData`, `WorkerStreamRunner` re-checks cancellation at lines 160 and 172 and throws regardless of collected lines, and five dedicated tests cover the race. The review's own text concedes it is "safe."

### EVIDENCE GAP

None. Every CRITICAL/HIGH finding was resolvable from source, tests, or direct measurement.

### IMPROVEMENT

- **C2, C3, H1** — real anti-patterns, but the blocking code sits on dedicated dispatch queues or the synchronous tail of a once-per-job call in a single-job system. No reachable starvation or PID-reuse path was established. Fix opportunistically when `ADBTransport.swift` is next opened for C1.
- **H3** — the force unwrap cannot fail for the current `InferenceRequest` shape; hardening only.
- **H4** — the worker is PixelDesktop's own code, and `stat` already gates the read; the measured result is 635 bytes. Defence-in-depth, not a defect.
- **H5** — the values *should* differ; the comment is what is wrong. The review already lists this as INFO elsewhere, which is the correct level.

---

## Recommended Next Action

1. **Do not remediate anything yet.** No files were modified during this validation.
2. **Record C1 as the single confirmed defect** in the Phase 10 Step 5 record, with the empirical harness result and the 53,721-byte `getprop` measurement as evidence.
3. **Reclassify C2, C3, H1, H3, H4, H5 from CRITICAL/HIGH to IMPROVEMENT, and H2 to FALSE POSITIVE**, in the review file — the current severity distribution (3 CRITICAL, 5 HIGH) overstates the codebase's actual risk and would misdirect remediation effort.
4. **Decide C1's remediation window.** It is not urgent — the timeout bounds it and no current command exceeds the buffer — but the 82% margin on `getprop` means it should be fixed before any new `execute()`-path command is introduced. A concurrent-drain fix is small and local to lines 48–104.
5. **Note the coverage gap explicitly:** the pipe-buffer boundary is untested on the `execute()` path. Whatever fix is chosen should come with a regression test that pushes output above 64 KB through `execute()`.

**No files modified. Nothing committed or pushed. Phase 10 Step 6 not started.**

---

## Appendix — Measurement Evidence

Commands measured on the real Pixel 7a (`DEADBEEF000000`), 2026-10-04:

| Command | Path | Bytes | vs 65,536 buffer |
|---|---|---|---|
| `adb shell getprop` | `execute()` | 53,721 | **82%** |
| `adb shell pm list packages` | `execute()` | 15,691 | 24% |
| `adb shell cmd package query-activities --brief ...` | `execute()` | 9,017 | 14% |
| `adb shell dumpsys thermalservice` | `execute()` | 7,924 | 12% |
| `adb shell dumpsys package com.pixeldesktop.worker` | `execute()` | 3,902 | 6% |
| `adb shell pm list packages -3` | `execute()` | 1,346 | 2% |
| `result.json` (completed LOCAL-LLM-1) | `shell()` | 635 | 1% |

Empirical harness results (standalone Swift, `~/ .hermes/cache/scratch/pipe_test.swift`):

```
=== C1 pipe-deadlock empirical test ===
[sh 100KB] *** DEADLOCK: still blocked after 10s ***
[sh 100KB] COMPLETED — read 65536 bytes
[sh 1MB] *** DEADLOCK: still blocked after 10s ***
[sh 1MB] COMPLETED — read 65536 bytes
[sh 8MB] *** DEADLOCK: still blocked after 10s ***
[sh 8MB] COMPLETED — read 65536 bytes
[adb getprop] COMPLETED — read 53721 bytes
=== done ===
```

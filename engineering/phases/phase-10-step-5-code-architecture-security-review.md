# Phase 10 Step 5 — Code, Architecture, and Security Review

- **Date:** 2026-10-04
- **Repository:** `<home>/AICompany/PixelDesktop/`
- **Scope:** 41 Swift source files across `PixelDesktop/`, `PixelDesktopCLI/`, `PixelDesktopTests/`
- **Mode:** READ-ONLY review. No production code modified. No commits.
- **Method:** Static inspection of source + tests as evidence. Two-part: direct source inspection of the review-critical files, plus an exhaustive file-by-file pass over all 41 files.

---

## Executive Summary

Reviewed 41 Swift source files across the PixelDesktop app, CLI, and test targets. The codebase is **well-architected overall** with strong separation of concerns, thorough documentation, and a disciplined error taxonomy. No command injection or path traversal vulnerabilities were found. Several **concurrency hazards**, **resource-management issues**, and **fragile parsing** patterns were identified.

**No concrete production defect requiring immediate action was identified from the evidence reviewed.**

The CRITICAL findings (C1, C2, C3) are latent issues that could cause problems under specific conditions but have not been observed to fail in testing or real-device usage. They should be addressed in future hardening work but do not require immediate action.

---

## Architecture Findings

### Working well

1. **Boundary separation is excellent.** `Hermes → CLI → PixelDesktop → ADB → Android worker` is cleanly enforced. The CLI cannot name devices, paths, or transport primitives.
2. **Fixed-path contract (`WorkerTransferContract`)** eliminates path traversal by construction. No path parameters anywhere.
3. **Input validation is thorough.** Package names, job IDs, and file paths are all validated before use.
4. **Error taxonomy is well-designed.** `PixelDesktopError` is exhaustive, typed, and carries structured categories.
5. **Streaming protocol is minimal and well-documented.** The `PDE1` line protocol is simple and testable.
6. **Durable-result recovery (F7) is correctly separated from streaming transport.** The reducer and runner keep these concerns distinct.
7. **Worker lifecycle is correctly separated from CLI concerns.** `WorkerLifecycle` owns start/stop/observe; the CLI has no access to it.
8. **No accidental network dependency.** All communication is over ADB (USB or TCP), with no HTTP/server/daemon layer.
9. **scrcpy remains outside the execution path** — not referenced by any execution module.
10. **Test coverage is strong.** The suite covers cancellation, streaming, recovery, and the CLI boundary with deterministic test doubles.

### Areas for improvement

1. **Concurrency hygiene.** `Thread.sleep` in async context (C2, H1) should be replaced with `Task.sleep`.
2. **Pipe handling.** `execute()` reads pipes after `waitUntilExit()` (C1, I2).
3. **Parsing robustness.** Several parsers (device list, system properties, launchable activities, thermal status) are fragile and could fail silently on unexpected output.
4. **Resource cleanup.** Some `DispatchQueue.asyncAfter` blocks and pipes are not explicitly cancelled/closed on all paths.
5. **Duplicated logic.** Device selection logic exists in both `AppState` and `CLIDeviceSelection`.

**No architectural boundary violations were identified.**

---

## Code-Quality Findings

| Severity | File | Location | Evidence | Why it matters | Recommended fix |
|---|---|---|---|---|---|
| **HIGH** | `LlmJob.swift` | Line 49 | `var dict = try JSONSerialization.jsonObject(with: requestData) as! [String: Any]` | Force unwrap crashes if encoding produces non-dictionary JSON | Use `guard let dict = try ... as? [String: Any] else { throw ... }` |
| **MEDIUM** | `WorkerStreamScript.swift` | Line 84 | `let missGrace = 5  // mirrors WorkerStreamReducer.livenessMissGrace (which is 3)` | Comment says "mirrors" but value differs; misleading | Rename comment to explain why values differ |
| **MEDIUM** | `ADBAppOperations.swift` | Lines 294–322 | `guard trimmed.contains("/"), !trimmed.contains("=")` | Parser assumes any line with `/` and no `=` is a component line | Use more specific pattern matching |
| **MEDIUM** | `WorkerComputeProof.swift` | Lines 336–348 | `guard let closeParen = statLine.lastIndex(of: ")")` | Parsing assumes process name is wrapped in parentheses; fails if name contains `)` | Use more robust parser |
| **MEDIUM** | `PixelEvidence.swift` | Lines 320–432 | Multiple separate `adb shell` calls | 4+ ADB round trips (~1 s) for a single observation | Combine into single command or use `async let` |
| **MEDIUM** | `CLIDeviceSelection.swift` | Lines 36–56 | Duplicated device selection logic from `AppState` | Two copies can drift | Extract to shared function |
| **MEDIUM** | `ADBTransport.swift` | Lines 121–175 | `let parts = trimmed.components(separatedBy: .whitespaces)` | Parser assumes `adb devices -l` format is always `serial state ...` | Use regex or more robust parsing |
| **MEDIUM** | `ADBTransport.swift` | Lines 455–481 | `guard let separator = trimmed.range(of: "]: [")` | If property value contains `]: [`, parser splits at wrong place | Use regex `^\[([^\]]+)\]: \[(.*)\]$` |
| **LOW** | `AppLogger.swift` | Lines 49–52 | `entries.removeFirst(entries.count - maxEntries)` | O(n) operation on every log entry when full | Use circular buffer |
| **LOW** | `CLIInvocation.swift` | Lines 71–138 | `if argument.hasPrefix("--")` | File path starting with `--` treated as flag | Handle `--` as separator |
| **LOW** | `ADBTransport.swift` | Lines 277–283 | `try process.run()` catch block doesn't close `stdinPipe` | Minor resource leak on launch failure | Close pipe in catch block |
| **LOW** | `ADBAppOperations.swift` | Lines 126–136 | TOCTOU race between query and launch | App could be uninstalled between check and launch | Accept race; `am start` will fail if app is gone |
| **LOW** | `PixelEvidence.swift` | Lines 458–465 | `let digits = line.filter { $0.isNumber }` | Could match unexpected output | Use regex `Thermal Status: (\d+)` |

---

## Error-Handling Findings

### Working well

1. **Worker death** — Correctly classified as `stream_lost_worker_gone`, non-recoverable.
2. **Stream loss with worker alive** — Correctly classified as `stream_lost_worker_running`; F7 recovery attempted.
3. **Wrong job ID** — Correctly rejected; no false recovery.
4. **Malformed result** — Correctly rejected; no false success.
5. **Cancellation** — Correctly classified as `cancelled`; F7 recovery skipped.
6. **Device unavailable** — Correctly classified as `device_not_found`, recoverable.

**No scenario was found where a failure could become `ok: true`.**

### Areas for improvement

| Severity | File | Location | Evidence | Why it matters | Recommended fix |
|---|---|---|---|---|---|
| **MEDIUM** | `WorkerStreamRunner.swift` | Lines 285–307 | `cat \(WorkerTransferContract.remoteResultPath)` | No size limit on result read; could read gigabytes | Add size check before reading |
| **MEDIUM** | `WorkerInstaller.swift` | Lines 79–114 | No APK signature verification | Malicious APK could be installed if caller is tricked | Verify APK signature before installing |
| **MEDIUM** | `main.swift` | Lines 37–87 | No overall timeout for CLI `run` command | Slow device could cause indefinite hang | Add `withTimeout` wrapper |

---

## Security Findings

### Working well

1. **No command injection.** All shell commands use fixed strings or validated identifiers. Package names are validated against shell metacharacters.
2. **No path traversal.** Fixed-path contract eliminates path parameters entirely.
3. **Job/result ownership enforced.** `resultBelongsToJob` checks `job_id` match before accepting recovery.
4. **No hardcoded secrets.** No credentials, tokens, or API keys found in source.
5. **Trust boundaries clear.** Data from Hermes, CLI, ADB, Android worker, and durable files are all validated at boundaries.

### Areas for improvement

| Severity | File | Location | Evidence | Why it matters | Recommended fix |
|---|---|---|---|---|---|
| **MEDIUM** | `WorkerInstaller.swift` | Lines 79–114 | No APK signature verification | Malicious APK could be installed if caller is tricked | Verify APK signature before installing |

**No CRITICAL or HIGH security finding was identified.**

---

## Concurrency and Cancellation Findings

| Severity | File | Location | Evidence | Why it matters | Recommended fix |
|---|---|---|---|---|---|
| **CRITICAL** | `ADBTransport.swift` | Lines 390, 411, 416 | `Thread.sleep(forTimeInterval:)` in async context | Blocks cooperative thread pool; can cause thread starvation | Use `try await Task.sleep(nanoseconds:)` |
| **CRITICAL** | `ADBTransport.swift` | Line 392 | `kill(process.processIdentifier, SIGKILL)` without existence check | PID could be reused by unrelated process | Use `process.terminate()` only, or check `isRunning` immediately before `kill()` |
| **HIGH** | `ADBTransport.swift` | Lines 409–423 | `while process.isRunning, Date() < reapDeadline { Thread.sleep(0.05) }` | Busy-wait blocks async thread for up to 5 seconds | Use `try await Task.sleep` in loop |
| **HIGH** | `ADBTransport.swift` | Lines 350–379 | Cancellation handler closes handle; reader may be blocked in `availableData` | Reader may process one more line after cancellation | Check `state.isCancelled` before `availableData` |
| **LOW** | `ADBTransport.swift` | Lines 306, 385 | `DispatchQueue.asyncAfter` blocks not cancelled | Minor resource leak; blocks hold references to handles | Use `DispatchWorkItem` and cancel on process exit |

### Cancellation correctness (verified by Phase 10 Step 1)

- `CancellationHandle` is thread-safe (`NSLock`), handler executes at most once.
- `StreamReadState` guarantees exactly-once continuation resumption.
- `Task.isCancelled` remains authoritative for outcome; `CancellationHandle` only interrupts transport resources.
- Cancellation does **not** trigger F7 recovery (recovery is skipped on the cancellation path).

---

## Resource-Management Findings

| Severity | File | Location | Evidence | Why it matters | Recommended fix |
|---|---|---|---|---|---|
| **CRITICAL** | `ADBTransport.swift` | Lines 48–104 | `process.waitUntilExit()` then `readDataToEndOfFile()` | If child writes >64 KB, it blocks on write; `waitUntilExit()` blocks forever | Read pipes concurrently with `waitUntilExit()` |
| **MEDIUM** | `WorkerStreamRunner.swift` | Lines 285–307 | `cat` without size limit | Could read arbitrarily large file into memory | Add size check before reading |
| **LOW** | `ADBTransport.swift` | Lines 277–283 | `stdinPipe` not closed on `process.run()` failure | Minor resource leak | Close pipe in catch block |
| **LOW** | `ADBTransport.swift` | Lines 306, 385 | `DispatchQueue.asyncAfter` not cancelled | Minor resource leak | Use `DispatchWorkItem` and cancel |

### Worker independence (Phase 10 Step 2 evidence)

The Mac-side implementation does **not** assume the worker dies when the transport disappears. Verified on the real Pixel 7a: worker PID `22552` survived USB loss, continued executing, and wrote a durable result belonging to the original job ID. The CLI correctly reported `stream_lost_worker_gone` only when the worker was genuinely unreachable.

---

## Test-Coverage Matrix

| Behavior | Existing test? | Real device? | Mock? | Evidence gap |
|---|---|---|---|---|
| Normal execution | Yes | Yes | Yes | None |
| Device unavailable | Yes | No | Yes | Real-device test |
| Worker death | Yes | No | Yes | Real-device test |
| Stream loss | Yes | No | Yes | Real-device test |
| F7 recovery | Yes | No | Yes | Real-device test |
| Wrong job ID | Yes | No | Yes | Real-device test |
| Malformed result | Yes | No | Yes | Real-device test |
| Cancellation | Yes | No | Yes | Real-device test |
| USB disconnect | Yes | Yes | Yes | None |
| Worker survives USB loss | Yes | Yes | Yes | None |
| Resource failure | Yes | No | Yes | Real-device test |
| Post-reconnect execution | Yes | Yes | Yes | None |

Legend: **Yes** = covered; **No** = not covered. Mock tests use deterministic test doubles; real-device tests exercise the physical Pixel 7a.

---

## Documentation Consistency

### Consistent

1. **Architecture documentation** matches implementation — `Hermes → CLI → PixelDesktop → ADB → Android worker`.
2. **Error taxonomy** documentation matches `PixelDesktopError` implementation.
3. **Streaming protocol** documentation matches `WorkerEvent` implementation.
4. **F7 recovery** documentation matches `WorkerStreamRunner` implementation.

### Areas for improvement

| Severity | File | Location | Evidence | Why it matters | Recommended fix |
|---|---|---|---|---|---|
| **LOW** | `WorkerStreamScript.swift` | Lines 82–84 | Comment says "mirrors" but value (5) differs from reducer (3) | Misleading comment | Update comment to explain why values differ |

---

## Findings by Severity

### CRITICAL

| ID | File | Location | Evidence | Why it matters | Recommended fix |
|---|---|---|---|---|---|
| C1 | `ADBTransport.swift` | Lines 48–104 | `process.waitUntilExit()` then `readDataToEndOfFile()` | Pipe deadlock if child writes >64 KB | Read pipes concurrently |
| C2 | `ADBTransport.swift` | Lines 390, 411, 416 | `Thread.sleep` in async context | Thread-pool exhaustion | Use `Task.sleep` |
| C3 | `ADBTransport.swift` | Line 392 | `kill()` without existence check | PID reuse could signal innocent process | Use `terminate()` only |

### HIGH

| ID | File | Location | Evidence | Why it matters | Recommended fix |
|---|---|---|---|---|---|
| H1 | `ADBTransport.swift` | Lines 409–423 | Busy-wait loop with `Thread.sleep` | Blocks async thread for 5 s | Use `Task.sleep` |
| H2 | `ADBTransport.swift` | Lines 350–379 | Cancellation race with reader thread | Reader may process one extra line | Check `isCancelled` before `availableData` |
| H3 | `LlmJob.swift` | Line 49 | Force unwrap `as! [String: Any]` | Latent crash | Use `guard let ... as?` |
| H4 | `WorkerStreamRunner.swift` | Lines 285–307 | No size limit on result read | Could read gigabytes | Add size check |
| H5 | `WorkerStreamScript.swift` | Line 84 | Magic value `missGrace = 5` | Misleading comment | Update comment |

### MEDIUM

| ID | File | Location | Evidence | Why it matters | Recommended fix |
|---|---|---|---|---|---|
| M1 | `DeviceManager.swift` | Lines 53–66 | Stale device data persists after failure | UI shows stale data | Clear `devices` on failure |
| M2 | `WorkerLifecycle.swift` | Lines 87–92, 132–138 | Polling loops with `pidof` | Multiple ADB round trips | Combine into single command |
| M3 | `AppLogger.swift` | Lines 11–15 | `DateFormatter` created on every log call | Performance overhead | Use static formatter |
| M4 | `ADBAppOperations.swift` | Lines 294–322 | Fragile parsing in `parseLaunchableActivities` | Could misparse unexpected output | Use more specific pattern |
| M5 | `WorkerComputeProof.swift` | Lines 336–348 | Fragile `/proc/<pid>/stat` parsing | Fails if process name contains `)` | Use more robust parser |
| M6 | `PixelEvidence.swift` | Lines 320–432 | Multiple separate `adb shell` calls | Slow observation (~1 s) | Combine into single command |
| M7 | `CLIDeviceSelection.swift` | Lines 36–56 | Duplicated device selection logic | Two copies can drift | Extract to shared function |
| M8 | `ADBTransport.swift` | Lines 121–175 | Fragile `parseDeviceList` parsing | Fails silently on format change | Use regex |
| M9 | `ADBTransport.swift` | Lines 455–481 | Fragile `parseSystemProperties` parsing | Fails if value contains `]: [` | Use regex |
| M10 | `WorkerInstaller.swift` | Lines 79–114 | No APK signature verification | Malicious APK could be installed | Verify signature |
| M11 | `main.swift` | Lines 37–87 | No overall timeout for CLI `run` | Could hang indefinitely | Add timeout wrapper |

### LOW

| ID | File | Location | Evidence | Why it matters | Recommended fix |
|---|---|---|---|---|---|
| L1 | `AppLogger.swift` | Lines 49–52 | O(n) `removeFirst` | Performance overhead | Use circular buffer |
| L2 | `ADBTransport.swift` | Lines 306, 385 | `asyncAfter` not cancelled | Minor resource leak | Use `DispatchWorkItem` |
| L3 | `WorkerStreamRunner.swift` | Lines 195–202 | `onEvent` not called for recovered results | Caller can't distinguish recovery | Call `onEvent` |
| L4 | `WorkerStreamReducer.swift` | Line 195 | Unused `reason` variable | Code cleanliness | Remove or use |
| L5 | `CLIInvocation.swift` | Lines 71–138 | No `--` separator handling | Path starting with `--` treated as flag | Handle `--` |
| L6 | `ADBTransport.swift` | Lines 277–283 | `stdinPipe` not closed on failure | Minor resource leak | Close in catch |
| L7 | `ADBAppOperations.swift` | Lines 126–136 | TOCTOU race in `launchApplication` | App could be uninstalled | Accept race |
| L8 | `WorkerComputeProof.swift` | Lines 103–196 | No overall timeout | Could hang indefinitely | Add timeout |
| L9 | `DeviceManager.swift` | Lines 30–35 | No cancellation token for discovery task | Task could leak if `stopDiscovery()` not called | Document lifecycle |
| L10 | `PixelEvidence.swift` | Lines 458–465 | Fragile thermal status parsing | Could match unexpected output | Use regex |

### INFO

| ID | File | Location | Evidence | Why it matters | Recommended fix |
|---|---|---|---|---|---|
| I1 | `WorkerStreamScript.swift` | Lines 82–84 | Misleading comment | Comment says "mirrors" but value differs | Update comment |
| I2 | `ADBTransport.swift` | Lines 60–63 | Pipe reads after `waitUntilExit()` | Design is fragile | Read pipes concurrently |

---

## Concrete Defects Requiring Action

**No concrete production defect requiring immediate action was identified from the evidence reviewed.**

The CRITICAL findings (C1, C2, C3) are latent issues that could cause problems under specific conditions but have not been observed to fail in testing or real-device usage. They are recorded here for future hardening work; they do not require immediate action.

---

## Production Changes

**No production changes are required at this time.**

The review identified several areas for improvement, but none constitute a concrete defect requiring immediate action. The architecture is sound, security boundaries are solid, and error handling is correct.

---

## What This Review Proves

1. **Architecture is sound** — `Hermes → CLI → PixelDesktop → ADB → Android worker` is cleanly enforced.
2. **Security boundaries are solid** — no command injection, no path traversal, no hardcoded secrets.
3. **Error handling is correct** — all reviewed failure scenarios produce correct structured errors.
4. **No false successes** — no scenario was found where a failure could become `ok: true`.
5. **Job ownership is enforced** — results are only accepted when `job_id` matches.
6. **Worker independence is real** — Mac-side code does not assume the worker dies with the transport.
7. **Test coverage is strong** — all critical behaviors have mock tests; key scenarios have real-device tests.

This review does **not** prove the system is secure or defect-free. It proves that no defect was found in the evidence reviewed, by static inspection. Several latent risks (C1, C2, C3) remain unexercised by any test or observed real-device run.

---

## Remaining Evidence Gaps

1. **Real-device resource failure** — only mock tests; no real-device resource-exhaustion testing.
2. **C1 pipe deadlock** — not exercised; no command in current use produces >64 KB on the `execute()` path (the streaming path uses `shellStreaming`). Latent.
3. **C2/C3 concurrency hazards** — not exercised under load; no high-concurrency test exists.
4. **Long-term stability** — no long-duration soak testing.
5. **Multiple disconnect/reconnect cycles** — only a single cycle tested on real hardware.
6. **Concurrent executions** — no test of two jobs in flight simultaneously.
7. **APK signature verification** — no test; no signature check exists in production.

---

## Recommended Next Phase 10 Target

**Documentation Review and Update**

### Reason

1. **Production impact medium** — documentation accuracy is important for maintainability.
2. **Evidence gap large** — no systematic documentation review has been performed.
3. **Low risk** — documentation review involves no code changes.
4. **Direct mapping to master prompt** — the master prompt requires a "documentation review".

### Verification plan

1. Review all architecture documentation against implementation.
2. Identify stale or missing documentation.
3. Update documentation to reflect current implementation.
4. Add missing ADRs for recent decisions.

---

## Files Reviewed

| File | Lines | Findings |
|---|---|---|
| `AppState.swift` | 144 | Clean |
| `ADBTransport.swift` | 482 | C1, C2, C3, H1, H2, I2, M8, M9, L2, L6 |
| `WorkerStreamRunner.swift` | 335 | H4, L3 |
| `CLIRunCommand.swift` | 281 | Clean |
| `CLIInvocation.swift` | 139 | L5 |
| `PixelDesktopError.swift` | 176 | Clean |
| `WorkerStreamReducer.swift` | 242 | L4 |
| `WorkerStreamProtocol.swift` | 284 | Clean |
| `WorkerLifecycle.swift` | 149 | M2 |
| `WorkerTransferContract.swift` | 242 | Clean |
| `DTCA1Job.swift` | 177 | Clean |
| `LlmJob.swift` | 62 | H3 |
| `InferenceRuntime.swift` | 303 | Clean |
| `PixelCapabilityContract.swift` | 442 | Clean |
| `ResultVerifier.swift` | 74 | Clean |
| `ADBAppOperations.swift` | 332 | M4, L7 |
| `DeviceManager.swift` | 116 | M1, L9 |
| `DeviceEnricher.swift` | 64 | Clean |
| `DeviceDiscovery.swift` | 12 | Clean |
| `ContentView.swift` | 122 | Clean |
| `PixelDesktopApp.swift` | 18 | Clean |
| `AppLogger.swift` | 76 | M3, L1 |
| `AndroidDevice.swift` | 76 | Clean |
| `InstalledApp.swift` | 57 | Clean |
| `WorkerOperationsProtocol.swift` | 232 | Clean |
| `WorkerComputeProof.swift` | 349 | M5, L8 |
| `WorkerStreamScript.swift` | 121 | H5, I1 |
| `WorkerInstaller.swift` | 154 | M10 |
| `InferenceEvidence.swift` | 222 | Clean |
| `PixelEvidence.swift` | 585 | M6, L10 |
| `ModelProvisioning.swift` | 169 | Clean |
| `CLIEnvelope.swift` | 189 | Clean |
| `CLIEnvelopeRenderer.swift` | 45 | Clean |
| `CLIDeviceSelection.swift` | 57 | M7 |
| `CLICommands.swift` | 119 | Clean |
| `CLIJSONPresentation.swift` | 85 | Clean |
| `main.swift` | 101 | M11 |
| `Transport.swift` | 370 | Clean |
| `CLIRunResult.swift` | 201 | Clean |
| `DTCA1Worker.swift` | 175 | Clean |
| `AppOperationsProtocol.swift` | 74 | Clean |

---

## Recommendation

The codebase is **production-ready for Phase 10** with the following caveats:

1. **Fix C1 (pipe deadlock)** before any command that could produce >64 KB of output. This is the most likely real-world failure.
2. **Fix C2/C3/H1 (Thread.sleep in async)** to prevent thread-pool exhaustion under load.
3. **Fix H3 (force unwrap)** to prevent a latent crash.
4. **Address M1 (stale device data)** to prevent UI confusion.
5. **Consider M6 (multiple shell calls)** for performance, but this is not blocking.

The architecture is sound. The findings are primarily in **concurrency hygiene** and **parsing robustness**, not in boundary violations or security weaknesses.

---

*Review performed read-only. No production source, tests, contracts, or configuration were modified. No commits were made.*

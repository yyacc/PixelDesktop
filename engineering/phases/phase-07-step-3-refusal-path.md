# Phase 7 — Step 3 Reconnaissance: The Refusal Path

**Status:** IN PROGRESS — reconnaissance complete, gate currently FAILS
**Task classification:** BOUNDED (verification of existing behaviour; no new subsystem)
**Baseline:** 336 tests, 0 failures, 15 skipped (device-gated) @ `8419f6b`

---

## The Step 3 gate

> **Step 3 — Harden the refusal path.** Confirm every refusal is bounded, machine-readable, and
> **non-retryable by contract**. This is mostly verification of existing behaviour.
> **Gate: every `error_type` exercised.**

Three properties to confirm, plus one gate. This document records what the evidence actually shows.

---

## The two error vocabularies

There are **two independent error vocabularies** in the system. Step 3's gate covers both, and they
have different shapes:

**1. The Swift `PixelDesktopError` enum — 11 cases**

```
deviceNotFound · deviceUnauthorized · deviceOffline
adbCommandFailed(command:exitCode:stderr:) · adbTransportError(_)
invalidInput(_) · timeout(operation:duration:) · cancelled
verificationFailed(reason:) · workerError(_) · unknown(_)
```

**2. The Android worker's `error_type` strings — 5 values** (`LlmWorkload.java`)

```
INVALID_INPUT · NATIVE_LIBRARY_MISSING · MODEL_MISSING · MODEL_LOAD_FAILED · INFERENCE_FAILED
```

---

## Property 1 — BOUNDED

**Verified: PASS.**

| Bound | Value | Enforced by |
|---|---|---|
| ADB command timeout | 30 s default (per-call override) | `ADBTransport.defaultTimeout` |
| Stream stall detector | 120 s | `ADBTransport.streamStallTimeout` — **not** a job timeout |
| Child reap deadline | 5 s | `ADBTransport.childReapTimeout` |
| Worker prompt ceiling | 4096 chars | `LlmWorkload.MAX_PROMPT_CHARS` |
| Worker max_tokens ceiling | rejected above limit | `LlmWorkload` `INVALID_INPUT` |
| Revisions / send-backs | bounded per pipeline | manifest (media pipelines only) |

Every refusal is produced after a bounded wait or an immediate input check. **No unbounded wait was
found.** The 120 s stall detector is correctly documented as a stall detector, not a job timeout — a
live worker heartbeats, so a long job is not falsely reaped.

---

## Property 2 — MACHINE-READABLE

**Verified: PARTIAL — one real defect.**

**PASS (Swift side):** every `PixelDesktopError` case is a typed enum case with structured associated
values. Consumers can `switch` exhaustively. `WorkerResultEnvelope` decodes `error_type` and
`error_message` from the worker's JSON into typed optional fields.

**FAIL (the boundary between them):** `WorkerResultEnvelope.asDTCA1Result()` **flattens the worker's
structured `error_type` into a prose string**:

```swift
throw PixelDesktopError.workerError(
    "Worker reported status \(status): \(errorType ?? "?") \(errorMessage ?? "")"
)
```

Consequences, verified by inspection:

- `MODEL_MISSING` and `INVALID_INPUT` become the **same** error case (`workerError`) distinguished
  only by text.
- **Nothing consumes `errorType` programmatically** — `grep` for `errorType` outside `DTCA1Job.swift`
  returns nothing.
- A consumer that wants to react differently to "the model is not installed" vs "you sent a bad
  prompt" must **string-match a human-readable message**. That is the definition of not
  machine-readable.

The worker goes to the trouble of emitting a structured vocabulary; the Mac discards the structure at
the boundary. This is the substantive Step 3 finding.

---

## Property 3 — NON-RETRYABLE BY CONTRACT

**Verified: PARTIAL — the contract exists but is unenforced.**

`PixelDesktopError.isRecoverable` implements exactly the required classification:

| Recoverable | Non-recoverable |
|---|---|
| `deviceNotFound`, `deviceUnauthorized`, `deviceOffline` | `invalidInput`, `verificationFailed`, `workerError` |
| `adbCommandFailed`, `adbTransportError` | `unknown` |
| `timeout`, `cancelled` | |

**But `isRecoverable` is referenced only in tests** (`PixelDesktopTests.swift:381–384`). No production
code reads it. There is no retry loop, so nothing currently violates it — the contract is **declared,
correct, and inert**.

The `workerError` flattening (Property 2) interacts badly here: **every** worker refusal is classified
`workerError`, therefore non-recoverable. That is correct for `INVALID_INPUT` and `MODEL_MISSING`
(genuinely non-retryable) but would also mark a transient worker failure non-recoverable — the
classification cannot distinguish them, because the type was erased.

---

## The gate — every `error_type` exercised

**Verified: FAIL.**

### Swift `PixelDesktopError` — 11 cases

| Case | Thrown in production | Exercised in tests | Verdict |
|---|---|---|---|
| `deviceNotFound` | 6 sites | 3 | ✅ |
| `deviceOffline` | 2 sites | 2 | ✅ |
| `adbCommandFailed` | 10 sites | 8 | ✅ |
| `adbTransportError` | 1 site | 1 | ✅ |
| `invalidInput` | 25 sites | 25 | ✅ |
| `verificationFailed` | 3 sites | 3 | ✅ |
| `workerError` | 11 sites | 6 | ✅ |
| `unknown` | — | — | ⚠️ fallback only |
| **`timeout`** | **0 sites** | **1 (property only)** | ❌ **never thrown** |
| **`cancelled`** | **0 sites** | **0** | ❌ **never thrown** |
| **`deviceUnauthorized`** | **0 sites** | **0** | ❌ **never thrown** |

### Worker `error_type` — 5 values

| `error_type` | Exercised in tests | Verdict |
|---|---|---|
| `INVALID_INPUT` | 3 | ✅ |
| `MODEL_MISSING` | 2 | ✅ |
| **`NATIVE_LIBRARY_MISSING`** | **0** | ❌ |
| **`MODEL_LOAD_FAILED`** | **0** | ❌ |
| **`INFERENCE_FAILED`** | **0** | ❌ |

**6 of 16 vocabulary entries are never exercised. The gate does not pass.**

---

## Three dead `PixelDesktopError` cases — and they are not the same problem

Conflating these would produce the wrong correction. Each has a different cause:

**1. `.timeout` — a genuine signal that arrives as a different type.**

`ADBTransport` implements the timeout correctly, then returns it as a **result, not an error**:

```swift
return TransportResult(exitCode: -1, stdout: "",
                       stderr: "Command timed out after \(effectiveTimeout)s")
```

So a timeout surfaces upward as `adbCommandFailed(exitCode: -1)`, never as `.timeout`. The declared
case is unreachable. **This is arguably a design choice** — the transport reports, the caller decides —
but the enum declares a case the system cannot produce, and `isRecoverable` classifies both
`.timeout` and `.adbCommandFailed` as recoverable, so the classification happens to agree by accident.

**2. `.cancelled` — a contract with no implementation.**

Nothing throws it. `Task.isCancelled` is checked in exactly one place (`DeviceManager.swift:31`, a
poll loop) and that loop simply exits rather than throwing. There is no cancellation path in the
system. The enum declares cancellation semantics that do not exist.

**3. `.deviceUnauthorized` — a state the discovery path cannot report.**

`grep -n "unauthorized" PixelDesktop/Device/*.swift` returns **nothing**. An unauthorized device is
either filtered out (surfacing as `.deviceNotFound`) or not distinguished. Yet `.deviceUnauthorized`
exists specifically to tell the user *"accept the ADB authorization prompt on the device"* — the single
most actionable error message in the enum. Whether it is reachable depends on how
`DeviceDiscovery` parses `adb devices` output, which is the next thing to check.

---

## Why this is NOT being fixed by deleting the dead cases

The tempting correction is to delete `.timeout`, `.cancelled`, and `.deviceUnauthorized` so the gate
passes. **That would be optimizing for the gate instead of the engineering**, and it would:

- remove the only expression of a cancellation contract that a future consumer may need;
- remove the most actionable error message in the enum;
- discard a real signal (the timeout) rather than correctly typing it.

Deletion is also irreversible in the sense that the *intent* is lost. The honest output is: **the gate
fails, here is the evidence, and here is the minimal correction for each case** — with the
architectural choices (implement vs. remove) surfaced as decisions rather than taken unilaterally.

---

## Recommended corrections (for decision, not yet applied)

| # | Finding | Minimal correction | Needs a decision? |
|---|---|---|---|
| **S3-1** | Worker `error_type` flattened to prose | Add a structured case carrying the worker's `error_type` verbatim, so consumers can branch | **Yes** — new enum case |
| **S3-2** | `.timeout` unreachable | Either type the transport timeout as `.timeout`, or document the case as reserved | **Yes** — behaviour change |
| **S3-3** | `.cancelled` unimplemented | Document as reserved, or remove | **Yes** |
| **S3-4** | `.deviceUnauthorized` unreachable | Determine discovery behaviour first, then either wire it or remove it | **Yes** — needs investigation |
| **S3-5** | 3 worker `error_type` values unexercised | Add tests simulating those `FAILED` envelopes via `MockTransport` | **No** — pure gate work |
| **S3-6** | `isRecoverable` inert | Correct as-is until a retry loop exists; document as declared-not-enforced | **No** — documentation |

**S3-5 is unambiguous gate work and can proceed without a decision.** The rest are surfaced.

---

## Results (implemented)

**S3-5 implemented. Suite: 336 → 344 tests, 0 failures, 15 skipped.** No regression; no test removed
or weakened.

### New tests — 8

**Worker vocabulary (3 new + 1 pin), `WorkerStreamingTests.swift` §5b:**

| Test | Covers |
|---|---|
| `testNativeLibraryMissingIsExercised` | `NATIVE_LIBRARY_MISSING` |
| `testModelLoadFailedIsExercised` | `MODEL_LOAD_FAILED` |
| `testInferenceFailedIsExercised` | `INFERENCE_FAILED` |
| `testWorkerErrorVocabularyIsFullyEnumerated` | pins all 5 values; fails if the vocabulary changes |

Each drives a real `FAILED` envelope through the real reducer via `MockTransport`, asserts the
structured `error_type` survives to the durable result, **and asserts the current flattening** — so
the Mac-side contract is pinned and an S3-1 fix must be deliberate.

**Swift dead cases (4 new), `PixelDesktopTests.swift` §Step 3:**

| Test | Covers | Asserts |
|---|---|---|
| `testUnauthorizedDeviceCurrentlySurfacesAsDeviceNotFound` | `.deviceUnauthorized` | state is preserved by the transport, discarded by the `state == .device` predicate |
| `testTimeoutSurfacesAsAdbCommandFailedNotTimeout` | `.timeout` | the timeout arrives as `exitCode: -1`, never as `.timeout` |
| `testCancelledCaseIsDeclaredAndClassifiedButNeverThrown` | `.cancelled` | the declaration is the whole implementation |
| `testSwiftErrorVocabularyIsFullyEnumerated` | all 11 | count, distinct messages, and the 7/4 recoverable split |

**Why these pin rather than fix:** deleting the three dead cases would make the gate pass while
destroying intent. These tests record the truth, guard it against silent drift, and **are designed to
fail when S3-2/3/4 are fixed** — the failure is the signal to update them.

### Gate status after this step

| Vocabulary | Exercised | Status |
|---|---|---|
| Worker `error_type` (5) | 5/5 | ✅ **PASS** |
| Swift `PixelDesktopError` (11) | 8 thrown+asserted, 3 pinned-as-unreachable | ⚠️ **PASS AS "ACCOUNTED FOR", with 3 defects recorded** |

The gate as written — *"every `error_type` exercised"* — is now satisfied in the honest sense:
**every error type is accounted for by a test.** Three are accounted for as *unreachable*, which is a
finding, not a pass by deletion.

### Honest limitation

Three Swift cases remain **unreachable in production**. This step did not make them reachable; it made
their unreachability **visible, tested, and documented**. Claiming Step 3 "hardened the refusal path"
without that qualifier would overstate the work: the refusal path was already bounded and largely
machine-readable, and the real defects found are S3-1 (structure erased at the boundary) and S3-2/3/4
(three dead cases).

---

## Provenance of this document

**Measured (this session):** baseline 336 tests / 0 failures @ `8419f6b`; post-change 344 tests /
0 failures; every throw-site count and test-coverage count via `grep` on the working tree; the
`state == .device` predicate read from `AppState.swift`; the timeout branch read from
`ADBTransport.swift`; the worker vocabulary read from `LlmWorkload.java`.

**Not measured:** whether `.deviceUnauthorized` is reachable through any path other than `AppState`
(only `AppState` was inspected); thermal/load behaviour (out of scope).

**Hypothesis (not tested):** that a consumer would benefit from a typed worker-refusal case (S3-1).
Reasoned from "nothing consumes `errorType` programmatically" plus the `isRecoverable` conflation, but
no consumer exists yet to demonstrate the need — so it is surfaced as a decision, not implemented.


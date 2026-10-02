# Phase 7 — Step 3: The Refusal Path

**Status:** COMPLETE — S3-1..S3-4 resolved; Step 3 CLOSED
**Task classification:** BOUNDED (verification + minimal corrections; no new subsystem)
**Baseline:** 336 tests, 0 failures, 15 skipped (device-gated) @ `8419f6b`
**Intermediate commit:** `c873676` (gate completion + 8 pinning tests)
**Final:** 349 tests, 0 failures, 15 skipped

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

## Resolved decisions (S3-1 .. S3-4)

All four were authorized and implemented. Each entry records what changed, why, and the evidence.

### S3-1 — Preserve the typed worker refusal ✅ RESOLVED

**Problem.** `WorkerResultEnvelope.asDTCA1Result()` interpolated the worker's structured `error_type`
into a prose string:

```swift
throw PixelDesktopError.workerError(
    "Worker reported status \(status): \(errorType ?? "?") \(errorMessage ?? "")"
)
```

`MODEL_MISSING` and `INVALID_INPUT` — different causes, different fixes — became the same error case,
distinguishable only by matching English. Nothing consumed `errorType` programmatically.

**Change.** Added `case workerRefused(category: String, message: String)` carrying the worker's token
**verbatim**, plus a `refusal` accessor on the envelope. `asDTCA1Result()` now throws `refusal`.

**Why a `String`, not a mirrored Swift enum.** The worker is the authority on what it can refuse. A
mirrored enum would silently drop any category a newer worker introduced — reintroducing the same class
of defect (structure lost at a boundary) one layer up.

**Fallback preserved.** An envelope with no `error_type` yields `workerError` — the category is never
invented to fill the field. `workerError` is retained for exactly that case.

**Retry classification.** `workerRefused` is **non-recoverable**: every category the worker can report
(bad prompt, missing native library, missing/unloadable model, failed inference) describes a condition
that will not change on retry. A future transient category must be classified explicitly.

**Evidence.** `testResultEnvelopeFailedStatusCarriesTheStructuredCategory`,
`testResultEnvelopeWithoutCategoryFallsBackToWorkerError`,
`testDistinctWorkerCategoriesAreProgrammaticallyDistinguishable`, and the three worker-vocabulary tests
(which now assert `workerRefused` and that the category survives verbatim).

### S3-2 — Keep `.timeout` as a distinct typed concept ✅ RESOLVED

**Traced semantics.** `ADBTransport.execute()` ran a two-task group. The watchdog terminated the
process and **returned** `TransportResult(exitCode: -1, stderr: "Command timed out after Ns")`. A
launch failure used the **same** `-1` sentinel with a different string. So a timeout surfaced upward as
`.adbCommandFailed`, and the distinction lived only in prose.

**Smallest correct place to preserve it.** The point of detection — the watchdog task — which is inside
`execute()` and does not require re-plumbing. The watchdog now throws
`PixelDesktopError.timeout(operation:duration:)`.

**Why this is minimal and not a redesign.** `execute()` already had a throwing path in the same task
group (`unknown` when no result arrives), so throwing from the watchdog is not a new mechanism.
`TransportResult` was **not** given a new field — that would have touched 68 construction sites, and
the transport's own contract explicitly states a non-zero exit is *returned* rather than thrown
precisely because some callers (`pidof`) treat non-zero as a valid answer. Throwing from the watchdog
preserves that: only the timeout path changed, and the "returned, not thrown" convention for ordinary
non-zero exits is untouched.

**Blast radius: zero.** No caller branched on `.adbCommandFailed` by case (verified by search).

**Left alone.** The launch-failure `-1` remains. It is a genuinely different condition (ADB could not
be started) and was not in scope.

**Evidence.** `testTimeoutIsATypedCaseNotACommandFailure`; `ADBTransport:84` throws the typed case.

### S3-3 — `.cancelled` preserved as reserved, not faked ✅ RESOLVED

**Investigation.** Does PixelDesktop have a legitimate cancellation contract that can produce this
state?

**Finding: a mechanism exists, but it is deliberately external and must not flow through this path.**

- Cancellation is `am force-stop`, issued **outside** the streaming session.
- `WorkerStreamingTests` §13 (`testCancellationIsNotPerformedByTheStream`) asserts the streaming path
  must **never** cancel — "in particular must not kill a worker whose stream died."
- The reason is architectural: a worker that outlives its control channel is recoverable; one that was
  killed is not. E1 F7 verified exactly this — the stream died, the worker kept running, and the
  durable result was recovered (2098 bytes).
- `Task.isCancelled` appears once (`DeviceManager.swift:31`), in a poll loop that exits rather than
  throwing.

**Decision: preserved as an explicitly reserved contract state. Not implemented, not deleted.**

Implementing it would have required inventing an execution path that the architecture deliberately
does not have — and would have risked a cancellation that kills a recoverable worker. The case is
retained because its classification is correct for a cancellation signal whenever one is genuinely
produced. **No production code throws it**, and none was added.

**Evidence.** `testCancelledIsReservedAndCorrectlyClassified`, `testOnlyCancelledIsReserved`; the case
documentation in `PixelDesktopError.swift` records the evidence; search confirms 0 files throw it.

### S3-4 — Surface `.deviceUnauthorized` instead of discarding it ✅ RESOLVED

**Traced path.** `ADBTransport.parseDeviceList` correctly parses the `unauthorized` wire token into
`DeviceState.unauthorized` (`ADBTransport:142`). The information survived the transport — and was then
**discarded by the consumer**: `AppState` selected devices with

```swift
devices.first(where: { $0.state == .device })?.serialNumber
```

…repeated at **five** sites. An unauthorized device matched nothing, so it was reported as
`.deviceNotFound` — "No authorized Android device found" — even though the device *was* found and the
user could fix it by accepting the prompt on screen. The enum's most actionable message was
unreachable.

**Smallest change.** Replaced the five duplicated predicates with one private helper,
`connectedDeviceSerial()`, which checks the failure states **after** the success case:

```
device  →  unauthorized  →  offline  →  notFound
```

Precedence matters: a connected device always wins, and `unauthorized` is checked before `offline`
because it is the actionable one — an offline device needs a cable check, an unauthorized one needs a
tap the user can perform right now.

**Why this is not a new state-management architecture.** It reads the `state` the transport already
parses and maps it to the error case that describes it. No new state, no new type, no cache, no
observer. It also removes five copies of a duplicated predicate.

**Evidence.** `testUnauthorizedDeviceIsDistinguishedFromAnAbsentOne`,
`testParserRecognisesTheUnauthorizedStateFromAdbOutput`,
`testParserHandlesConnectedAndUnauthorizedTogether`; `AppState:91` throws `.deviceUnauthorized`; 0
lossy predicates remain.

---

## Real-device verification

**Result: NOT PERFORMED — the device was not available. Recorded, not worked around.**

At closeout, the Pixel 7a was not attached by any transport:

```
adb devices -l          -> "List of devices attached" (empty)
system_profiler (USB)   -> no Google/Pixel USB device
adb mdns services       -> no discovered services (no wireless ADB)
```

**Why no failure condition was induced.** Exercising `.deviceUnauthorized` on real hardware requires
revoking the host's ADB key on the device — a state change to the user's phone, and one that would
have to be undone by physically re-accepting the prompt. The instruction was explicit: *do not
manufacture a failure condition.* It was not induced.

**What was verified instead, and what that is worth.** Two parser tests were added using ADB's
documented `adb devices -l` wire format for the `unauthorized` state — the same shape as the real
Pixel 7a capture already in the suite, with the state token changed. These are **honest synthetic
tests, labelled as such in their docstrings**. They verify that the parser populates
`DeviceState.unauthorized` and that a mixed connected+unauthorized list selects correctly. They do
**not** verify the live behaviour of an actually-unauthorized device.

**Why the four decisions remain well-evidenced without a device.** All four are type-level or
predicate-level changes: which error case is constructed, and which state is selected. Their
verification is that the correct type is produced from the correct input — which unit tests with
`MockTransport` establish directly. A real device would add confidence about ADB's *wire behaviour*,
not about these four code paths. The one item a device would genuinely add — confirming the live
`unauthorized` token from real hardware — is recorded as an open item below.

**Open item (carried forward):** the live `unauthorized` wire format has not been observed from the
Pixel 7a in this project. It is documented by ADB and handled by the parser, but it is not a captured
observation. A future session with the device can confirm it by revoking the ADB key.

---

## Verification performed

| Check | Result |
|---|---|
| Targeted refusal-path tests | ✅ pass (S3-1..S3-4 tests + worker vocabulary + parser) |
| Complete suite | ✅ **349 tests, 0 failures, 15 skipped**, ~14 s |
| E1 streaming regression | ✅ intact — `WorkerStreamingTests` (incl. §13 cancellation) all pass |
| `8419f6b` baseline | ✅ unmodified, still an ancestor |
| Working tree | ✅ only intentional Step 3 files |

**Test count journey:** 336 (baseline) → 344 (Step 3 pins, `c873676`) → **349** (four decisions
implemented + parser tests). No test removed, skipped, or weakened to make anything pass.

**The pins fired as designed.** Four tests written in `c873676` asserted the *old* behaviour
(`workerError` flattening, `deviceNotFound` for an unauthorized device, the `-1` timeout). When the
fixes landed, they failed — that failure was the signal to update them deliberately, and updating them
was the act the pin existed to force. This is the mechanism working, not breakage.

---

## Final gate status

| Vocabulary | Status |
|---|---|
| Worker `error_type` (5 values) | ✅ 5/5 exercised, category preserved verbatim |
| Swift `PixelDesktopError` (12 cases) | ✅ 11 reachable + asserted; **1 reserved** (`.cancelled`), documented with evidence |

Step 3's gate — *"every `error_type` exercised"* — is satisfied in the honest sense: **every error type
is accounted for**, and the one that is not reachable is recorded as reserved with its reason rather
than deleted or faked.

---

## Provenance of this document

**Measured (this session):** baseline 336 tests / 0 failures @ `8419f6b`; intermediate 344 @ `c873676`;
final **349 tests / 0 failures**; every throw-site count and test-coverage count by search on the
working tree; the `state == .device` predicate read from `AppState`; the watchdog branch read from
`ADBTransport`; the worker vocabulary read from `LlmWorkload.java`; the absence of a device from
`adb devices -l`, `system_profiler`, and `adb mdns services`.

**Not measured:** the live `unauthorized` wire format from real hardware (device unavailable — see
above). Whether `.deviceUnauthorized` is reachable through any path other than `AppState` (only
`AppState` was inspected; it is the only consumer of the device list for operations).

**Hypothesis (not tested):** that a downstream consumer will branch on `workerRefused.category`. The
type now makes it possible; no consumer exists yet to demonstrate the need. This is why the change
preserves structure rather than adding behaviour — it removes an obstacle to a future consumer without
inventing one.



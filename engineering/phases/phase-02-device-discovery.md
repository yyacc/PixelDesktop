# Phase 2 — Device Discovery and ADB Transport

**Status: COMPLETE**
**Date:** 2026-10-01
**Phase:** 2
**Preceding phase:** Phase 1 (Engineering Foundation) — COMPLETE

---

## Phase Objective

Establish reliable communication with the physical Pixel 7a and give the application a
verified representation of that device's stable system identity.

Deliverables for this phase:

- ADB discovery of attached devices (already present from Phase 1, unchanged).
- A transport-level `getprop()` capability.
- Device property enrichment, separated from discovery parsing.
- Mock-based unit tests for the new behaviour.
- Real-device verification against the Pixel 7a.

---

## Requirements

1. `DeviceProperties` contains only stable device/system properties appropriate for
   `getprop`, with no dynamic/runtime data.
2. `getprop` calls must **not** live inside `parseDeviceList()`.
3. `ADBTransport` remains transport-focused: `shell()`, `push()`, `pull()`, `getprop()`.
4. `getprop()` is added to the transport protocol and implemented through the existing
   `execute()` mechanism.
5. No battery, screen, storage, network, Bluetooth, app-count, or process-count fields.
6. Mock-based tests for: `getprop` success, `getprop` failure, property
   parsing/conversion, device enrichment, and unchanged discovery behaviour.
7. The complete test suite builds and passes.
8. Real-device verification against serial `3C261JEHN25632`, confirming the **actual**
   returned values rather than assumed ones.

---

## Starting State

Phase 1 left a clean, building, fully-tested foundation:

- `xcodebuild` Debug: BUILD SUCCEEDED
- 31/31 unit tests passing
- 3 git commits on `main`
- `PixelDevice` already declared `androidVersion`, `apiLevel`, `architecture` — but
  nothing populated them. `parseDeviceList` hard-coded `""`, `0`, `""`.

**Phase 2 was entered BLOCKED.** `Transport.swift` on disk was 105,413 bytes of
corrupted content (see FAIL-002). The phase could not proceed until that was resolved
and the property model was agreed.

### Files inspected before any modification

| File | State at inspection |
|---|---|
| `Transport/Transport.swift` | Corrupted (105,413 bytes). Protocol + `TransportResult` intact at lines 1–21. |
| `Transport/ADBTransport.swift` | Clean, 145 lines. `execute()`, `listDevices()`, `parseDeviceList()`. |
| `Device/DeviceManager.swift` | Clean, 63 lines. `@MainActor`, discovery polling. |
| `Device/DeviceDiscovery.swift` | Clean, 12 lines. Protocol only. |
| `Core/Models/PixelDevice.swift` | Clean, 39 lines. |
| `Core/Errors/PixelDesktopError.swift` | Clean, 57 lines. |
| `App/AppState.swift` | Clean, 54 lines. Binds `DeviceManager` published values. |
| `App/ContentView.swift` | Lines 111–113 already render the three properties with "Unknown" fallbacks. |
| `PixelDesktopTests/PixelDesktopTests.swift` | Clean, 340 lines, 31 tests. |
| `project.yml` | Clean, xcodegen definition. |

---

## Investigation

### Blocker resolution

The corrupted file's provenance was established before anything was rewritten:

- `git show HEAD:PixelDesktop/Transport/Transport.swift` → **398 bytes, clean**
- `git status --porcelain` → `M PixelDesktop/Transport/Transport.swift` (uncommitted)

So the corruption was agent-created this session and a known-good version of the exact
file was recoverable from git. The corrupted artifact was copied to
`~/.hermes/cache/scratch/pd-evidence/` with its SHA-256 recorded, then the clean version
was restored with `git checkout HEAD --`.

Full diagnosis: `engineering/failures/FAIL-002-transport-swift-runaway-fields.md`.

### Acquisition mechanism investigation

The three properties were probed directly on the real device **before** writing any
code, so the design would be based on observed behaviour rather than assumption:

| Probe | Result |
|---|---|
| `adb devices -l` | `3C261JEHN25632 device usb:1048576X product:lynx model:Pixel_7a device:lynx` |
| `getprop ro.build.version.release` | `16` (exit 0) |
| `getprop ro.build.version.sdk` | `36` (exit 0) |
| `getprop ro.product.cpu.abi` | `arm64-v8a` (exit 0) |
| `getprop ro.<bogus>` | empty output, **exit 0** |

Two findings changed the design:

1. **`getprop` exits 0 for an unset key.** A missing value is only detectable from the
   output, not the exit code. Without an explicit empty check, a missing property would
   silently produce `androidVersion = ""` / `apiLevel = 0` — indistinguishable from
   "not yet enriched".
2. **The assumed values were wrong.** Phase 1 test fixtures used `14` / `34`. The device
   actually reports `16` / `36`. Nothing was broken by this, but it is direct evidence
   that assumed device values must not be baked into assertions.

---

## Architecture

```
adb devices -l
      ↓
parseDeviceList()            (pure, nonisolated, no I/O — unchanged from Phase 1)
      ↓
  [PixelDevice]              (properties empty by design)
      ↓
DeviceManager.enrichDevice(serial:)      (explicit, NOT on the discovery poll)
      ↓
DeviceEnricher.enrich(_:)    (depends on TransportProtocol, not ADBTransport)
      ↓
transport.getprop(serial,key,timeout:)   3 × sequential
      ↓
DeviceProperties.make(...)   (trim + validate; throws on empty/malformed)
      ↓
  enriched PixelDevice       (republished by DeviceManager)
```

Layer responsibilities:

| Layer | Responsibility | Does not do |
|---|---|---|
| `parseDeviceList` | Which devices are attached, from one `adb devices -l` string | No I/O, no `getprop` |
| `ADBTransport.getprop` | One property, one ADB call | No knowledge of `PixelDevice` |
| `DeviceProperties` | Validate and hold the 3 stable values | No I/O |
| `DeviceEnricher` | Compose the 3 reads into an enriched device | No discovery, no UI |
| `DeviceManager` | Own device list state; expose enrichment explicitly | No parsing, no ADB details |

---

## Alternatives Considered

**A. Enrich inside `parseDeviceList`.** Rejected: converts a pure parse into I/O,
breaks two existing tests, and adds 3 round trips to every 5-second discovery poll for
values that cannot change while the device is booted.

**B. Enrich in `DeviceManager` against concrete `ADBTransport`.** Rejected: not
unit-testable without a physical device, conflicting with the Phase 2 test requirement.

**C. `enrichDevice` on `ADBTransport`.** Implemented first, then removed. It is device
modelling, not transport. Leaving it there would make the transport grow a method per
consumer concern. Removing it kept `ADBTransport` transport-focused, as required.

**D. A ~50-field `DeviceProperties`.** This was the original (pre-block) direction and
is the design that produced FAIL-002. Rejected: most fields had no identified
acquisition mechanism and no consumer in this phase.

**E. Dedicated `DeviceEnricher` depending on `TransportProtocol`.** **Chosen.**

---

## Decision

- `DeviceProperties`: exactly 3 fields — `androidVersion: String`, `apiLevel: Int`,
  `architecture: String` — plus a throwing `make(...)` factory and a `DevicePropertyKey`
  enum holding the three `getprop` keys.
- `TransportProtocol` gains exactly one method: `getprop(deviceSerial:key:timeout:)`.
- `ADBTransport.getprop` issues `adb -s <serial> shell getprop <key>` through the
  existing `execute()` path.
- New `DeviceEnricher` in `PixelDesktop/Device/`, depending on `TransportProtocol`.
- `DeviceManager.transport` widened from `ADBTransport` to `TransportProtocol`; gains
  `enrichDevice(serial:)`.
- `parseDeviceList` unchanged — no I/O, no `getprop`.
- Recorded in `ADR-005-device-property-enrichment.md` and `ADR-006-test-isolation.md`.

---

## Reason

The deciding constraint was the Phase 2 requirement for mock-based tests, combined with
the fact that these three properties are constant for a boot session. Separating the
responsibilities keeps discovery a pure, fast, single-call parse on a 5-second poll while
enrichment — three round trips — happens only on demand.

Because `getprop` returns exit 0 for unset keys, validation must be explicit.
`DeviceProperties.make` is where malformed device output is rejected, so a missing
property fails loudly instead of masquerading as an un-enriched device.

---

## Implementation

### Files created

| File | Purpose |
|---|---|
| `PixelDesktop/Device/DeviceEnricher.swift` | Enrichment, depending on `TransportProtocol` |
| `engineering/decisions/ADR-005-device-property-enrichment.md` | Enrichment separation decision |
| `engineering/decisions/ADR-006-test-isolation.md` | Test isolation strategy |
| `engineering/failures/FAIL-001-non-english-output.md` | Prior-phase failure record |
| `engineering/failures/FAIL-002-transport-swift-runaway-fields.md` | Blocker root cause |
| `engineering/phases/phase-02-device-discovery.md` | This document |
| `engineering/testing/phase-02-test-report.md` | Test and verification evidence |
| `engineering/logs/engineering-journal.md` | Chronological diary |

### Files modified

| File | Change |
|---|---|
| `Transport/Transport.swift` | Recovered from git (398 B); added `getprop` to protocol; added `DeviceProperties` + `DevicePropertyKey`. Now 117 lines. |
| `Transport/ADBTransport.swift` | Added `getprop()` via `execute()`. 173 lines. |
| `Device/DeviceManager.swift` | `TransportProtocol` dependency; added `enrichDevice(serial:)`. 90 lines. |
| `PixelDesktopTests/PixelDesktopTests.swift` | +15 mock-based tests, +3 opt-in integration tests, +`MockTransport`. 832 lines. |
| `engineering/created-resources.json` | Registered all Phase 2 resources. |
| `engineering/README.md` | Index updated. |

`parseDeviceList` and all Phase 1 test expectations were left untouched.

---

## Experiments

1. **Real-device property probe** (before coding) — established the actual values and
   the exit-0-on-unset behaviour. Changed the design.
2. **`TEST_RUNNER_` env-var forwarding** — passed
   `TEST_RUNNER_PIXELDESKTOP_DEVICE_SERIAL=3C261JEHN25632` to `xcodebuild`. The
   integration tests still reported "skipped", so the variable did not reach the test
   process. Recorded as a tooling gap; not worked around with an unverified claim.
3. **Standalone CLI harness** — compiled the actual production sources
   (`Transport`, `ADBTransport`, `DeviceEnricher`, `PixelDevice`, `PixelDesktopError`)
   with `swiftc` and ran them against the Pixel 7a. This produced the real-device
   evidence and an independent cross-check against raw `adb`.

---

## Failures

**FAIL-002 — runaway field duplication in `Transport.swift`.** The file reached
105,413 bytes with a recursive `PlatformVersion` field-name append; `DeviceProperties`
never closed and the file could not have compiled. Root cause was generated content, not
tooling: lines 1–21 were correct, and three different write mechanisms reproduced the
same semantically recursive identifiers. Contributing cause: the oversized (~50-field)
design gave the generation defect room to run. Resolved by git recovery, redesign to 3
fields, and switching to targeted `patch` edits.

**Tooling gap — `TEST_RUNNER_` env-var forwarding.** The integration tests could not be
driven from the command line in this environment. Resolved for evidence purposes by the
CLI harness; the limitation is documented in ADR-006 rather than papered over.

---

## Diagnosis

FAIL-002 was classified as **implementation / generated content**, not architecture,
API, platform, tooling, environment, or device. Evidence: only the generated field list
was malformed while the hand-specified protocol block was correct; three independent
write mechanisms produced the same recursive pattern; and the failure mode (monotonic
string growth) is characteristic of a generation loop reusing its own output.

The `TEST_RUNNER_` gap was classified as **tooling/environment** — an `xcodebuild`
behaviour, not a defect in the code under test. Confirmed by the fact that the same
production code worked correctly when compiled and run directly.

---

## Corrections

1. Preserved the corrupted file as evidence with a recorded SHA-256.
2. Recovered the clean file from git rather than reconstructing it by hand.
3. Redesigned `DeviceProperties` from ~50 fields to 3, excluding all dynamic/runtime
   data per the approved scope.
4. Switched from whole-file `write_file` to targeted `patch` for existing files.
5. Moved `enrichDevice` out of `ADBTransport` into `DeviceEnricher` after noticing it
   made the transport grow a consumer-specific method.
6. Widened `DeviceManager` to `TransportProtocol` so enrichment became testable.
7. Built the CLI harness after the `TEST_RUNNER_` path failed, rather than asserting a
   real-device pass that had not executed.

---

## Tests

**15 new mock-based unit tests:**

| Area | Tests |
|---|---|
| `DeviceProperties.make` | trims whitespace; rejects empty version; rejects empty architecture; rejects non-numeric API level; rejects zero API level |
| Acquisition source | keys match the approved `getprop` names exactly |
| `getprop` | success returns trimmed value and issues the correct argv; ADB failure surfaces `adbCommandFailed` with command and exit code; unset property (exit 0, empty output) is rejected |
| `DeviceEnricher` | populates all three properties and preserves identity; rejects non-connected state without touching the device; propagates property failure |
| `DeviceManager` | enrichment updates the published device; unknown serial returns `nil` without any ADB call; discovery leaves properties unpopulated and issues no `getprop` |

**3 opt-in real-device integration tests** (skipped unless `PIXELDESKTOP_DEVICE_SERIAL`
is set): discovery + enrichment against the attached device; unset property rejected;
unknown serial fails.

---

## Results

| Check | Result |
|---|---|
| `xcodegen generate` | PASS |
| `xcodebuild ... build` | **BUILD SUCCEEDED** |
| `xcodebuild ... test` (default) | **49 executed, 0 failures, 3 skipped** |
| Real-device discovery | PASS — 1 device, `3C261JEHN25632`, state `device` |
| Real-device enrichment | PASS — Android `16`, API `36`, ABI `arm64-v8a` |
| Independent cross-check vs raw adb | **MATCH: true** |
| Unset property rejected | PASS |
| Unknown serial fails | PASS |

Full evidence: `engineering/testing/phase-02-test-report.md`.

---

## Regression Tests

All 31 Phase 1 tests were rerun and pass. Specifically unchanged in behaviour:

- `testADBTransportParseDeviceList` — still parses serial, state, model from `adb devices -l`
- `testADBTransportParseEmptyList` — still returns `[]`
- `testPixelDeviceDisplayName` / `testPixelDeviceDisplayNameFallback` — unchanged
- `testDeviceStateIsConnected`, `testErrorDescription`, `testErrorRecoverable` — unchanged
- All 17 DTCA-1 worker and verifier tests — unchanged

`testDiscoveryLeavesPropertiesUnpopulated` is a new guard that pins the separation:
discovery must not issue `getprop` calls. This is the regression test for the boundary
ADR-005 establishes.

---

## Final Architecture

```
PixelDesktop/Device/
├── DeviceDiscovery.swift     protocol only (unchanged)
├── DeviceManager.swift       @MainActor, owns device list; enrichDevice(serial:)
└── DeviceEnricher.swift      NEW — reads 3 properties, returns enriched device

PixelDesktop/Transport/
├── Transport.swift           TransportProtocol (+getprop), TransportResult,
│                             DeviceProperties, DevicePropertyKey
└── ADBTransport.swift        actor; execute, listDevices, parseDeviceList, getprop
```

`DeviceProperties` — 3 fields, no dynamic data:

| Field | `getprop` key | Observed on Pixel 7a |
|---|---|---|
| `androidVersion: String` | `ro.build.version.release` | `16` |
| `apiLevel: Int` | `ro.build.version.sdk` | `36` |
| `architecture: String` | `ro.product.cpu.abi` | `arm64-v8a` |

---

## Lessons Learned

1. **Probe the device before designing against it.** The pre-coding probe revealed both
   the real values (`16`/`36`, not the assumed `14`/`34`) and the exit-0-on-unset
   behaviour. The second finding directly shaped the validation design; it would not have
   been discovered from documentation or from a mock.
2. **Check whether corruption is committed before choosing a recovery path.**
   `git status` + `git show HEAD:<file>` immediately showed a clean 398-byte version was
   recoverable. Without that check, the likely path would have been hand-reconstruction —
   slower and riskier.
3. **Targeted patches are self-limiting; whole-file writes are not.** The runaway could
   only have happened while generating a large file in one shot.
4. **Design size is a risk factor.** A ~50-field struct for a phase needing 3 fields gave
   the generation defect room to run. Minimal models fail cheaply.
5. **A skipped test is not a passing test.** Reporting a real-device pass when the tests
   reported "skipped" would have been a fabricated verification. Building the harness took
   minutes and produced genuine evidence.
6. **Test well-formedness, not device constants.** Asserting `androidVersion == "14"`
   would have failed against the real device while catching nothing.

---

## What Worked Well

- **Probing the real device before writing code.** Cheapest possible way to eliminate
  assumptions; produced two findings that changed the design.
- **`git checkout HEAD -- <file>` for recovery.** Instant, exact, and verifiable. The
  correct tool because the corruption was uncommitted.
- **Targeted `patch` edits.** Each change stayed small and reviewable, with a diff for
  every edit. No repetition risk.
- **Designing for mock injection from the start.** `DeviceEnricher` taking
  `TransportProtocol` made 15 tests possible with no device attached, and let the tests
  assert *which argv* was issued, not just the result.
- **Asserting invocations, not just outcomes.** `testDiscoveryLeavesPropertiesUnpopulated`
  and `testEnrichDeviceRejectsNonConnectedState` assert that *no* ADB call was made. This
  pins the architectural boundary, which a result-only test could not.
- **Compiling production sources into a CLI harness for evidence.** Unambiguous,
  reproducible, and independent of the test-runner environment.

---

## What Did Not Work

- **Generating a large `DeviceProperties` in a single write.** Produced 105 KB of
  runaway field names and blocked the phase.
- **Attempting the same write through three different mechanisms.** Once the pattern was
  clear, retrying with `execute_code` and heredocs added no information. The failure was
  in the content, and no write mechanism could have fixed it.
- **Putting `enrichDevice` on `ADBTransport`.** Blurred the transport boundary; caught
  and removed during review before it was tested.
- **`TEST_RUNNER_PIXELDESKTOP_DEVICE_SERIAL` for integration tests.** Did not reach the
  test process in this environment.

---

## Best Technique Discovered

**Probe the real system before designing against it, then encode the probe result as a
test assertion about the acquisition path.**

Why it worked: the `getprop` exit-0-on-unset behaviour is not obvious from `adb` help
text or from any documentation, and a mock written from assumption would have encoded the
wrong behaviour — the mock would have *agreed* with the buggy implementation and the
tests would have passed while the real device produced empty strings. Probing first meant
the mock encoded observed reality.

When to use it: any time code integrates with an external system whose behaviour is not
fully specified by its documentation — hardware, CLI tools, network services.

When not to use it: when the behaviour is already pinned by an existing, passing test.
Re-probing then costs time and adds nothing.

**Second-best technique: git-based recovery for uncommitted corruption.** Run
`git status --porcelain` and `git show HEAD:<path> | wc -c` before attempting any
reconstruction. It is the difference between a two-second recovery and a risky rebuild.

---

## Future Recommendations

1. **Phase 3 (Android Device Model)** should consume `DeviceProperties` as the
   enrichment payload. It already has the right shape.
2. **Wire `enrichDevice` into the UI.** `ContentView` lines 111–113 already render the
   three fields with "Unknown" fallbacks; they will remain "Unknown" until the UI calls
   `enrichDevice` after discovery. This is deferred to Phase 8 by design — do not add
   polling-time enrichment to compensate.
3. **Consider caching properties per serial for the boot session** if the UI needs
   instant version display. Do not call `getprop` on the discovery poll.
4. **If more than ~5 properties are needed**, batch them into a single `getprop` with no
   key argument and parse the full output, rather than N calls. Revisit ADR-005 then.
5. **Phase 4+ should use `TransportProtocol`, not `ADBTransport`**, so new capabilities
   stay testable with `MockTransport`.
6. **Re-test the `TEST_RUNNER_` env-var path** on a future Xcode version; if it works,
   the integration tests can carry real-device evidence directly.

---

## Phase Completion Record

```
PHASE STATUS: COMPLETE

Requirements:            PASS  (all 8 Phase 2 requirements met)
Build:                   PASS  (xcodebuild Debug — BUILD SUCCEEDED)
Tests:                   PASS  (49 executed, 0 failures, 3 integration tests skipped by design)
Device verification:     PASS  (Android 16 / API 36 / arm64-v8a, cross-checked vs raw adb)
Failure handling:        PASS  (unset property rejected; unknown serial fails)
Regression:              PASS  (all 31 Phase 1 tests still pass)
Architecture review:     PASS  (ADR-005, ADR-006)
Documentation:           PASS  (phase log, 2 ADRs, 2 failure records, test report, journal)
AI development log:      UPDATED
Known limitations:       DOCUMENTED (TEST_RUNNER_ env-var forwarding; UI enrichment deferred to Phase 8)
```

**Known limitations**

- The UI does not yet call `enrichDevice`, so the app displays "Unknown" for these three
  fields until Phase 8. The backend capability is complete and verified.
- Real-device integration tests cannot be driven from the command line in this
  environment; the CLI harness is the evidence mechanism until that changes.
- Enrichment costs 3 sequential ADB round trips. Acceptable on demand; unsuitable for the
  poll interval.
- The pre-existing `ConformanceIsolation` warning on `DeviceManager`'s conformance to
  `DeviceDiscoveryProtocol` remains. It is a Swift 6 readiness warning introduced in
  Phase 1, not by this phase, and is not yet an error under Swift 5 mode.

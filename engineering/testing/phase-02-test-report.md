# Phase 2 Test Report

**Date:** 2026-10-01
**Phase:** 2 — Device Discovery and ADB Transport
**Device:** Pixel 7a, serial `3C261JEHN25632`

---

## 1. Build

```
$ xcodegen generate
Created project at .../PixelDesktop.xcodeproj

$ xcodebuild -project PixelDesktop.xcodeproj -scheme PixelDesktop -configuration Debug build
** BUILD SUCCEEDED **
```

One warning, pre-existing from Phase 1 and not introduced by this phase:

```
DeviceManager.swift:5:46: warning: conformance of 'DeviceManager' to protocol
'DeviceDiscoveryProtocol' crosses into main actor-isolated code and can cause data
races; this is an error in the Swift 6 language mode [#ConformanceIsolation]
```

---

## 2. Default test suite (hermetic)

```
$ xcodebuild -project PixelDesktop.xcodeproj -scheme PixelDesktop -configuration Debug test

Executed 46 tests, with 0 failures (0 unexpected) in 0.088 (0.097) seconds
Executed 3 tests, with 3 tests skipped and 0 failures (0 unexpected) in 0.003 (0.004) seconds
Executed 49 tests, with 3 tests skipped and 0 failures (0 unexpected) in 0.091 (0.101) seconds
** TEST SUCCEEDED **
```

- **46 mock-based tests executed, 0 failures** (31 from Phase 1 + 15 new).
- **3 integration tests skipped** — by design, `PIXELDESKTOP_DEVICE_SERIAL` unset.

### New tests added in Phase 2

| Test | Verifies |
|---|---|
| `testDevicePropertiesMakeTrimsWhitespace` | Whitespace/newlines trimmed from all three fields |
| `testDevicePropertiesMakeRejectsEmptyVersion` | Empty version → `invalidInput` |
| `testDevicePropertiesMakeRejectsEmptyArchitecture` | Whitespace-only ABI → `invalidInput` |
| `testDevicePropertiesMakeRejectsNonNumericApiLevel` | `"thirty-six"` → `invalidInput` |
| `testDevicePropertiesMakeRejectsZeroApiLevel` | `"0"` → `invalidInput` |
| `testDevicePropertyKeysMatchApprovedAcquisitionSources` | Keys are exactly the approved `getprop` names |
| `testGetpropSuccess` | Returns trimmed value; issues `-s <serial> shell getprop <key>` |
| `testGetpropFailureSurfacesAdbError` | Exit 1 → `adbCommandFailed` with command and exit code |
| `testGetpropUnsetPropertyIsRejected` | Exit 0 + empty output → `invalidInput` |
| `testEnrichDevicePopulatesProperties` | All 3 properties populated; identity preserved; 3 calls in order |
| `testEnrichDeviceRejectsNonConnectedState` | `.offline` → `deviceOffline`, **zero** ADB calls |
| `testEnrichDevicePropagatesPropertyFailure` | Unset property propagates as `invalidInput` |
| `testDeviceManagerEnrichUpdatesPublishedDevice` | Enriched device republished; was empty before |
| `testDeviceManagerEnrichUnknownSerialReturnsNil` | Unknown serial → `nil`, **zero** ADB calls |
| `testDiscoveryLeavesPropertiesUnpopulated` | Discovery issues **no** `getprop` calls |

### Phase 1 tests rerun (regression)

All 31 pass unchanged, including `testADBTransportParseDeviceList`,
`testADBTransportParseEmptyList`, `testPixelDeviceDisplayName`,
`testPixelDeviceDisplayNameFallback`, `testDeviceStateIsConnected`,
`testErrorDescription`, `testErrorRecoverable`, and all 17 DTCA-1 worker/verifier tests.

---

## 3. Real-device verification

### 3.1 Tooling limitation encountered

`xcodebuild ... test TEST_RUNNER_PIXELDESKTOP_DEVICE_SERIAL=3C261JEHN25632` did **not**
forward the variable into the test process — the integration tests still reported
"skipped". Recorded in ADR-006. No real-device claim is made on the basis of those tests.

### 3.2 Evidence mechanism: production-source CLI harness

The actual production sources were compiled directly and run against the Pixel 7a:

```
$ swiftc -swift-version 5 -o verify \
    PixelDesktop/Core/Models/PixelDevice.swift \
    PixelDesktop/Core/Errors/PixelDesktopError.swift \
    PixelDesktop/Transport/Transport.swift \
    PixelDesktop/Transport/ADBTransport.swift \
    PixelDesktop/Device/DeviceEnricher.swift \
    main.swift

$ ./verify 3C261JEHN25632
```

Output (verbatim, exit code 0):

```
DISCOVERY: 1 device(s)
  serial=3C261JEHN25632 state=device model=Pixel_7a device=lynx
  pre-enrichment -> android='' api=0 abi=''
ENRICHMENT (real values returned by the device):
  androidVersion = 16
  apiLevel       = 36
  architecture   = arm64-v8a
  model preserved= Pixel_7a
  serial preserved=3C261JEHN25632
INDEPENDENT CROSS-CHECK (raw adb, no project code):
  androidVersion = 16
  apiLevel       = 36
  architecture   = arm64-v8a
CROSS-CHECK MATCH: true
UNSET PROPERTY: correctly rejected -> Invalid input: Property 'ro.pixeldesktop.not.real' is unset on device 3C261JEHN25632
UNKNOWN SERIAL: correctly failed -> ADB command failed: getprop ro.build.version.release (exit code 1): adb: device 'NOSUCHSERIAL0000' not found
RESULT: PASS
```

### 3.3 Verified values

| Field | `getprop` key | Actual returned value | Assumed in Phase 1 fixtures |
|---|---|---|---|
| `androidVersion` | `ro.build.version.release` | **`16`** | `14` — **incorrect** |
| `apiLevel` | `ro.build.version.sdk` | **`36`** | `34` — **incorrect** |
| `architecture` | `ro.product.cpu.abi` | **`arm64-v8a`** | `arm64-v8a` — correct |

The values were read from the device, not assumed, and independently confirmed by raw
`adb` invocations that bypass all project code (`CROSS-CHECK MATCH: true`).

### 3.4 Failure-path verification (real device)

| Scenario | Expected | Observed |
|---|---|---|
| Unset property (`ro.pixeldesktop.not.real`) | Rejected, not silently empty | `invalidInput: Property '...' is unset on device 3C261JEHN25632` |
| Unknown serial (`NOSUCHSERIAL0000`) | Command failure | `adbCommandFailed: getprop ro.build.version.release (exit code 1): adb: device 'NOSUCHSERIAL0000' not found` |

Both negative paths confirmed against the real device, not only against mocks.

---

## 4. Requirements traceability

| # | Requirement | Evidence |
|---|---|---|
| 1 | Only stable `getprop` properties; no dynamic/runtime data | `DeviceProperties` has 3 fields; `DevicePropertyKey` has 3 keys |
| 2 | No `getprop` inside `parseDeviceList()` | `parseDeviceList` unchanged; `testDiscoveryLeavesPropertiesUnpopulated` asserts zero calls |
| 3 | `ADBTransport` stays transport-focused | Only `getprop` added; `enrichDevice` removed to `DeviceEnricher` |
| 4 | `getprop` on protocol, via existing `execute()` | `TransportProtocol.getprop`; implemented over `execute()`; `testGetpropSuccess` asserts argv |
| 5 | No battery/screen/storage/network/Bluetooth/app-count/process-count | None present |
| 6 | Mock tests: success, failure, parsing, enrichment, unchanged discovery | 15 new tests, all listed in §2 |
| 7 | Full suite builds and passes | BUILD SUCCEEDED; 49 executed, 0 failures |
| 8 | Real-device verification of actual values | §3 — Android 16 / API 36 / arm64-v8a, cross-checked |

---

## 5. Artifacts

- Corrupted artifact preserved as evidence:
  `~/.hermes/cache/scratch/pd-evidence/Transport.swift.corrupted`
  SHA-256 `3d9b46ee6df02a50689bac77c0e624a5e7bdd83b89407cb8918b4fced5b810a8`
- Verification harness: `~/.hermes/cache/scratch/pd-verify/main.swift`
  (outside the repository; a throwaway evidence tool, not a project artifact)

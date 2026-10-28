# Phase 3 Test Report

**Date:** 2026-10-01
**Phase:** 3 — Android Device Model
**Device:** Pixel 7a, serial `DEADBEEF000000`

---

## 1. Build

```
$ xcodegen generate
$ xcodebuild -project PixelDesktop.xcodeproj -scheme PixelDesktop -configuration Debug build
** BUILD SUCCEEDED **
```

One warning, pre-existing from Phase 1 (not introduced by this phase):

```
DeviceManager.swift:5:46: warning: conformance of 'DeviceManager' to protocol
'DeviceDiscoveryProtocol' crosses into main actor-isolated code and can cause data races;
this is an error in the Swift 6 language mode [#ConformanceIsolation]
```

---

## 2. Default test suite (hermetic)

```
Executed 4 tests, with 4 tests skipped and 0 failures (0 unexpected) in 0.006 (0.007) seconds
Executed 69 tests, with 0 failures (0 unexpected) in 0.104 (0.117) seconds
Executed 73 tests, with 4 tests skipped and 0 failures (0 unexpected) in 0.110 (0.124) seconds
** TEST SUCCEEDED **
```

- **69 hermetic tests executed, 0 failures** (46 from Phase 2 + 23 new/updated).
- **4 integration tests skipped by design** (`PIXELDESKTOP_DEVICE_SERIAL` unset).

### New tests in Phase 3

| Test | Verifies |
|---|---|
| `testAndroidDeviceDisplayNamePrefersMarketingName` | `Pixel 7a` wins over codename |
| `testAndroidDeviceDisplayNameFallsBackToCodename` | Falls back to `lynx` |
| `testAndroidDeviceDisplayNameFallsBackToSerial` | Falls back to serial |
| `testAndroidDeviceManufacturerIsNotCodename` | **Defect regression** |
| `testCapabilitiesDerivedFromDevice` | `supportedABIs`; `supports(abi:)` true/false |
| `testCapabilitiesFromDeviceWithNoABIs` | Empty device → empty capabilities |
| `testDeviceOperationsMatchImplementedCapabilities` | Enum is exactly `[.discover, .readSystemProperties]` |
| `testDeviceOperationDescriptions` | Descriptions |
| `testDevicePropertiesMakeTrimsWhitespace` | All 6 fields trimmed |
| `testDevicePropertiesMakeRejectsEmptyMarketingName` | → `invalidInput` |
| `testDevicePropertiesMakeRejectsEmptyManufacturer` | → `invalidInput` |
| `testDevicePropertiesMakeRejectsEmptyABIList` | → `invalidInput` |
| `testDevicePropertyKeysMatchApprovedAcquisitionSources` | All 6 keys |
| `testDevicePropertyKeysAllAreCovered` | `all` in sync with individual keys |
| `testParseABIListMultiEntry` | `a,b,c` → 3 elements |
| `testParseABIListSingleEntry` | **The real Pixel case** |
| `testParseABIListToleratesWhitespaceAndTrailingComma` | Robustness |
| `testParseABIListEmptyInput` | `""`, `"   "`, `",,"` → empty |
| `testParseSystemPropertiesTypicalOutput` | Real `[key]: [value]` format |
| `testParseSystemPropertiesOmitsUnsetKeys` | **Unset absent, not empty** |
| `testParseSystemPropertiesHandlesValuesContainingBrackets` | Value with `]` survives |
| `testParseSystemPropertiesHandlesEmptyAndGarbageOutput` | No crash |
| `testParseSystemPropertiesHandlesCRLF` | `\r\n` line endings |
| `testGetSystemPropertiesBatchedRead` | **Exactly one invocation** |
| `testGetSystemPropertiesFailureSurfacesAdbError` | → `adbCommandFailed` |
| `testEnrichDevicePopulatesProperties` | 6 fields; identity preserved; **1 batched call** |
| `testEnrichDeviceDoesNotSubstituteCodenameForManufacturer` | **Defect regression** |
| `testEnrichmentAgainstRealPixel7aOutput` | **Full pipeline over real captured device output** |

### Phase 2 tests rerun (regression)

All pass, including `testDiscoveryLeavesPropertiesUnpopulated` (discovery issues **zero**
property reads), `testADBTransportParseDeviceList`, `testADBTransportParseEmptyList`,
`testDeviceStateIsConnected`, `testErrorDescription`, `testErrorRecoverable`, and all 17
DTCA-1 worker/verifier tests.

---

## 3. Real-device property probe (before implementation)

```
$ adb -s DEADBEEF000000 shell getprop ro.product.model          -> 'Pixel 7a'   (exit 0)
$ adb -s DEADBEEF000000 shell getprop ro.product.manufacturer   -> 'Google'     (exit 0)
$ adb -s DEADBEEF000000 shell getprop ro.product.cpu.abilist    -> 'arm64-v8a'  (exit 0)
$ adb -s DEADBEEF000000 shell getprop ro.product.device         -> 'lynx'       (exit 0)
```

All three proposed properties present and suitable. `abilist` is **single-entry** on this
device — recorded so the parser treats that as the common case.

---

## 4. Real-device verification (live)

Production sources compiled with `swiftc` and run against the attached Pixel 7a:

```
DISCOVERY (identity only, no properties):
  serial=DEADBEEF000000 state=device
  deviceCodename=lynx
  marketingName='' manufacturer=''
  displayName=lynx
BATCHED vs SINGLE (all 6 keys):
  batched: 0.095s (1 adb spawn)
  singles: 0.354s (6 adb spawns)
  speedup: 3.7x
  batched agrees with single-key reads: true
ENRICHED ANDROID DEVICE (real values from the device):
  serial        = DEADBEEF000000
  deviceCodename= lynx
  marketingName = Pixel 7a
  manufacturer  = Google
  androidVersion= 16
  apiLevel      = 36
  architecture  = arm64-v8a
  supportedABIs = ["arm64-v8a"]
  displayName   = Pixel 7a
CAPABILITIES:
  supports(arm64-v8a) = true
  supports(x86_64)    = false
OPERATIONS IMPLEMENTED: ["discover", "readSystemProperties"]
INDEPENDENT CROSS-CHECK (raw adb, no project code):
  ro.build.version.release = '16'         match=true
  ro.build.version.sdk     = '36'         match=true
  ro.product.cpu.abi       = 'arm64-v8a'  match=true
  ro.product.model         = 'Pixel 7a'   match=true
  ro.product.manufacturer  = 'Google'     match=true
  ro.product.cpu.abilist   = 'arm64-v8a'  match=true
DEFECT REGRESSION (manufacturer/marketingName must not equal codename): true
  manufacturer='Google' marketingName='Pixel 7a' codename='lynx'
PRIMARY ABI IN SUPPORTED LIST: true
UNSET PROPERTY: correctly rejected -> Invalid input: Property 'ro.pixeldesktop.not.real' is unset on device DEADBEEF000000
UNKNOWN SERIAL: correctly failed -> ADB command failed: getprop ro.build.version.release (exit code 1): adb: device 'NOSUCHSERIAL0000' not found
RESULT: PASS
```

### Verified values

| Field | Value | Phase 2 value | Change |
|---|---|---|---|
| `deviceCodename` | `lynx` | (was `model` = `Pixel_7a`) | Corrected source |
| `marketingName` | `Pixel 7a` | *(did not exist)* | New |
| `manufacturer` | `Google` | `lynx` — **incorrect** | **Defect fixed** |
| `androidVersion` | `16` | `16` | Unchanged |
| `apiLevel` | `36` | `36` | Unchanged |
| `architecture` | `arm64-v8a` | `arm64-v8a` | Unchanged |
| `supportedABIs` | `["arm64-v8a"]` | *(did not exist)* | New |

### Failure-path verification (real device)

| Scenario | Expected | Observed |
|---|---|---|
| Unset property | Rejected | `invalidInput: Property '...' is unset on device DEADBEEF000000` |
| Unknown serial | Command failure | `adbCommandFailed: ... (exit code 1): adb: device 'NOSUCHSERIAL0000' not found` |

---

## 5. Replay verification over real captured output

The device detached during the first live verification run. Rather than fabricate a result,
the exact `getprop` output captured from the Pixel 7a was replayed through the real parser,
`DeviceProperties.make` and `DeviceEnricher`. **13/13 checks passed**, including both defect
regressions and the unset-key omission. Live verification was then re-run successfully once
the device was reattached (§4).

This replay is also retained as a permanent hermetic test
(`testEnrichmentAgainstRealPixel7aOutput`), so the pipeline stays verified against real
device data on every future run without needing the hardware.

---

## 6. Requirements traceability

| # | Requirement | Evidence |
|---|---|---|
| 1 | Proper device representation | `AndroidDevice` — identity, version, model, manufacturer, architecture, capabilities, state, operations |
| 2 | Separate discovery / representation / operations | Separate layers; `testDiscoveryLeavesPropertiesUnpopulated` asserts zero property reads on discovery |
| 3 | Do not combine all logic in one object | `AndroidDevice`, `DeviceProperties`, `DeviceCapabilities`, `DeviceOperation`, `DeviceEnricher`, `DeviceManager` |
| 4 | D1 — rename + correct identity | `AndroidDevice`; 6/6 cross-checked vs raw adb |
| 5 | D2 — minimal capabilities | `DeviceCapabilities.supportedABIs` only |
| 6 | D3 — no `DeviceService` | Not added; recorded as deferred |
| 7 | D4 — only implemented operations | `testDeviceOperationsMatchImplementedCapabilities` |
| 8 | D5 — batched `getprop` | 3.7× measured; batched agrees with single reads 6/6 |
| 9 | D6 — probe before implementing | Probe table §3; implementation gated on reattachment |

---

## 7. Artifacts

- Real-device verification harness: `~/.hermes/cache/scratch/pd-verify3/`
- Replay harness + captured device output: `~/.hermes/cache/scratch/pd-fixture/`
  (outside the repository; throwaway evidence tools, not project artifacts)

# Phase 3 — Android Device Model

**Status: COMPLETE**
**Date:** 2026-10-01
**Phase:** 3 (Android Device Model) — authoritative sequence per [ADR-007](../decisions/ADR-007-authoritative-phase-sequence.md)
**Preceding phase:** Phase 2 (Device Discovery and ADB Transport) — COMPLETE
**Proposal:** `phase-03-android-device-model-proposal.md` (approved, with D3 deferred)

---

## Phase Objective

Create a proper internal representation of an Android device, exposing verified device
information, with discovery, representation and operations kept separate.

---

## Requirements

From master prompt §16 Phase 3, plus the six decisions approved for this phase:

1. Proper internal device representation — device identity, Android version, model,
   manufacturer, architecture, capabilities, state, available services, supported operations
2. Separate discovery / representation / operations
3. Do not combine all device logic into one object
4. **D1 (approved)** — rename `PixelDevice` → `AndroidDevice`; `deviceCodename` from
   `adb devices -l`, `marketingName` from `ro.product.model`, `manufacturer` from
   `ro.product.manufacturer`, `supportedABIs` from `ro.product.cpu.abilist`
5. **D2 (approved)** — `DeviceCapabilities` minimal, `supportedABIs` only; no RAM/GPU/NPU/
   thermal/storage
6. **D3 (deferred)** — do NOT add `DeviceService`/`.adb`
7. **D4 (approved)** — `DeviceOperation` lists only `discover` and `readSystemProperties`;
   no speculative operations protocol
8. **D5 (approved)** — batched `getprop` instead of one ADB process per property
9. **D6** — probe the real device before implementing; do not rely on AOSP documentation
   or assumed Pixel 7a values

---

## Starting State

Phase 2 complete: 49 tests, BUILD SUCCEEDED, commit `c65b404`. Phase 2's `PixelDevice`
had 8 fields; `androidVersion`, `apiLevel`, `architecture` were populated by
`DeviceEnricher`; `manufacturer` was populated from the `device:` token.

---

## Investigation

### The device was detached, then reattached

The Pixel 7a was physically disconnected during proposal preparation (`adb devices`
returned empty, device absent from the USB bus). Per §5.1 and D6, the three proposed
properties could **not** be implemented against assumed values, so implementation was
gated on reattachment. The device was reattached and probing proceeded.

### Real-device probe (before any implementation)

| `getprop` key | Raw value | Exit |
|---|---|---|
| `ro.product.model` | `Pixel 7a` | 0 |
| `ro.product.manufacturer` | `Google` | 0 |
| `ro.product.cpu.abilist` | `arm64-v8a` | 0 |
| `ro.product.device` | `lynx` | 0 |
| `ro.product.cpu.abi` | `arm64-v8a` | 0 |
| `ro.build.version.release` | `16` | 0 |
| `ro.build.version.sdk` | `36` | 0 |

All three proposed properties are **present and suitable**. Three findings:

1. `manufacturer` (`Google`) is genuinely distinct from the codename (`lynx`) — the defect
   was real and the fix is correct.
2. **`abilist` returns a single entry on this device**, not a multi-value list. The parser
   must treat the single-entry case as the common case.
3. An unset key still exits **0** with empty output — absence remains detectable only from
   the output, not the exit code.

### Defects found in the Phase 2 model

1. **`manufacturer` held the codename.** `parseDeviceList` read it from the `device:` token
   (`lynx`). `ContentView` rendered it as `LabeledContent("Manufacturer", ...)` — the UI
   displayed a falsehood.
2. **`model` held the codename too** (`Pixel_7a` is a build name). The marketing name was
   not modelled at all.

---

## Architecture

```
adb devices -l
      ↓
ADBTransport.parseDeviceList()      pure, nonisolated, no I/O
      ↓                             supplies identity + state ONLY
  AndroidDevice                     marketingName/manufacturer/properties empty BY DESIGN
      ↓
DeviceManager.enrichDevice(serial:)  explicit; NOT on the discovery poll
      ↓
DeviceEnricher.enrich(_:)
      ↓
ADBTransport.getSystemProperties()   1 adb process spawn (was 6)
      ↓
ADBTransport.parseSystemProperties()  [key]: [value] → [String: String]
      ↓
DeviceProperties.make(...)            trim + validate; throws on empty/malformed
      ↓
  enriched AndroidDevice              republished by DeviceManager

DeviceCapabilities(device:)           derived: supportedABIs
DeviceOperation.allCases              only implemented operations
```

| Layer | Owns | Does not |
|---|---|---|
| `parseDeviceList` | Which devices are attached; identity + state | No I/O, no properties |
| `ADBTransport` | Process execution, timeouts, output parsing | Know what a device *means* |
| `DeviceProperties` | Validate and hold 6 stable values | No I/O |
| `AndroidDevice` | Representation only | Perform any device action |
| `DeviceCapabilities` | Derive capabilities from a device | Acquire anything |
| `DeviceEnricher` | Read properties, compose an enriched device | Discover, render |
| `DeviceManager` | Own device list state | Parse, know ADB details |

---

## Alternatives Considered

**A. Extend `PixelDevice` in place** — rejected; preserves the identity defects.
**B. Full device model (RAM/GPU/NPU/thermal/storage/battery)** — rejected; no reliable
static source, and Phases 6/7 own that work.
**C. Representation types only, no operations protocol** — **chosen.**
**D. `DeviceService` with a single `.adb` case** — rejected per D3; no meaningful
abstraction to model.
**E. Keep 6 sequential `getprop` calls** — rejected per D5; measured 3.7× slower.
**F. Rename `DeviceProperties` → `AndroidSystemProperties`** — rejected; ~40 test
references, no correctness gain.

---

## Decision

- `DeviceProperties`: 3 → **6 fields** (+ `parseABIList` helper)
- `DevicePropertyKey`: 3 → **6 keys** + an `all` list `DeviceEnricher` iterates
- `PixelDevice` → **`AndroidDevice`**: `deviceCodename`, `marketingName`, `manufacturer`,
  `supportedABIs`; `displayName` precedence marketingName → codename → serial
- **`DeviceCapabilities`**: `supportedABIs` + `supports(abi:)`
- **`DeviceOperation`**: `.discover`, `.readSystemProperties` only
- **`TransportProtocol.getSystemProperties(...)`**: batched read; `parseSystemProperties`
  static parser
- **No `DeviceService`** (D3 deferred)
- **No operations protocol**
- Removed `Core/Models/PixelDevice.swift`
- Recorded in **ADR-008**

---

## Reason

The defects are *identity* defects: fixing them requires distinguishing codename from
marketing name from manufacturer, which is a model-shape change. The rename matches master
prompt §16 ("an Android device") and §1 (multiple Android devices planned).

Capabilities stay minimal because `supportedABIs` is the only capability both verifiable
from a stable `getprop` and actually needed (Phase 5 must know whether the device can run a
given native binary). Everything else would be invented.

No operations protocol, because Phase 3's deliverable is representation and an unused
protocol is speculative infrastructure. RNZM-21 (Phase 4) defines the seam when it has a
real implementation to put behind it.

Batching is justified by measurement, not preference: 0.095 s vs 0.354 s.

---

## Implementation

### Files created

| File | Purpose |
|---|---|
| `PixelDesktop/Core/Models/AndroidDevice.swift` | Device representation |
| `engineering/decisions/ADR-008-android-device-model.md` | Model decision |
| `engineering/phases/phase-03-android-device-model.md` | This document |
| `engineering/testing/phase-03-test-report.md` | Test and verification evidence |

### Files modified

| File | Change |
|---|---|
| `Transport/Transport.swift` | 6-field `DeviceProperties`, `parseABIList`, 6 keys + `all`, `getSystemProperties` on protocol, `DeviceCapabilities`, `DeviceOperation` |
| `Transport/ADBTransport.swift` | `AndroidDevice` types; `device:` → codename (not manufacturer); `getSystemProperties` + `parseSystemProperties` |
| `Device/DeviceEnricher.swift` | Batched read; `AndroidDevice`; new fields |
| `Device/DeviceManager.swift` | `AndroidDevice` types |
| `Device/DeviceDiscovery.swift` | `[AndroidDevice]` |
| `App/AppState.swift` | `[AndroidDevice]` |
| `App/ContentView.swift` | `AndroidDevice`; corrected labels (Model/Codename/Manufacturer/Supported ABIs) |
| `PixelDesktopTests/PixelDesktopTests.swift` | 24 tests added/updated; `MockTransport` batched support |
| `engineering/architecture/overview.md` | Updated device model section |
| `engineering/README.md`, `engineering/created-resources.json` | Index and manifest |

### Files removed

| File | Reason |
|---|---|
| `Core/Models/PixelDevice.swift` | Superseded by `AndroidDevice`. Removed with `git rm`, so it remains recoverable from history. |

---

## Experiments

1. **Real-device property probe (before implementation)** — confirmed all three new
   properties exist and are suitable; established that `abilist` is single-entry here.
2. **Batched vs single-key timing** — 6 single reads 0.354 s vs 1 batched read 0.095 s
   (**3.7× speedup**), and the batched map agreed with single-key reads for all 6 keys.
3. **Replay harness over real captured output** — replayed the exact `getprop` output
   captured from the device through the real parser, `DeviceProperties.make` and
   `DeviceEnricher`. All 13 checks passed. This was necessary because the device detached
   mid-verification; rather than fabricate a result, the pipeline was verified against
   real captured data, then re-verified live once the device returned.
4. **Live real-device verification** — full harness run, all checks PASS.

---

## Failures

**Device detached twice during the phase.** First during proposal preparation, again during
the first live verification run. Neither was a code failure. Handled by: not implementing
against assumed values (per D6), verifying against replayed real output in the interim, and
re-running live verification once reattached.

**One test failure during implementation.** `testGetpropSuccess` failed with
`Property 'ro.build.version.release' is unset`. Root cause: `MockTransport` had two
independent property stores — `setProperty` wrote the new `properties` map while `getprop`
still read the old `responses` map. Fixed by making the mock's `getprop` resolve from the
same map as the batched read, so the two paths cannot disagree in tests.

---

## Diagnosis

The mock failure was classified as **test double inconsistency** — an implementation defect
in the test fixture, not in production code. Evidence: the production path compiled and the
real-device harness passed against real output while the mock-based test failed, proving the
defect was in the mock rather than in `ADBTransport` or `DeviceProperties`.

The detachment was classified as **environment/device**, not code.

---

## Corrections

1. Fixed `MockTransport` to use one property store for both read paths.
2. Re-verified against replayed real device output while the device was detached, then
   re-ran live verification after reattachment.
3. Added `testEnrichmentAgainstRealPixel7aOutput` so the real device's captured output is a
   **permanent hermetic test** — the pipeline stays verified against real data even when no
   device is attached.

---

## Tests

**24 tests added or updated.** New coverage:

| Area | Tests |
|---|---|
| `AndroidDevice` | displayName precedence (3 cases); **defect regression: manufacturer/marketingName ≠ codename** |
| `DeviceCapabilities` | derived from device; `supports(abi:)`; empty-ABI device |
| `DeviceOperation` | enum equals exactly `[.discover, .readSystemProperties]`; descriptions |
| `DeviceProperties.make` | 6-field trimming; rejects empty marketingName; rejects empty manufacturer; rejects empty ABI list |
| `parseABIList` | multi-entry; **single-entry (the real case)**; whitespace + trailing comma; empty input |
| `parseSystemProperties` | typical output; **unset keys omitted**; values containing `]`; empty/garbage; CRLF |
| `DevicePropertyKey` | all 6 keys match approved names; `all` in sync with individual keys |
| Batched `getprop` | success; ADB failure; **exactly one invocation** |
| `DeviceEnricher` | all 6 fields; identity preserved; **defect regression**; property failure |
| `DeviceManager` | enrichment republishes; discovery leaves properties unpopulated |
| **Real captured output** | full pipeline over the Pixel 7a's actual `getprop` output |

---

## Results

| Check | Result |
|---|---|
| `xcodegen generate` | PASS |
| `xcodebuild ... build` | **BUILD SUCCEEDED** |
| `xcodebuild ... test` | **73 executed, 0 failures** (4 integration tests skipped by design) |
| Real-device probe (3 new properties) | PASS — `Pixel 7a` / `Google` / `arm64-v8a` |
| Real-device enrichment | PASS — all 6 properties correct |
| Independent cross-check vs raw adb | **6/6 match** |
| Defect regression on real hardware | PASS — `Google` ≠ `lynx`, `Pixel 7a` ≠ `lynx` |
| Primary ABI in supported list | PASS |
| Batched vs single-key agreement | PASS (6/6) |
| Batched speedup | 3.7× (0.095 s vs 0.354 s) |
| Unset property rejected | PASS |
| Unknown serial fails | PASS |
| Replay harness over real output | PASS (13/13 checks) |

---

## Regression Tests

All Phase 2 behaviour re-verified:

- `testDiscoveryLeavesPropertiesUnpopulated` **still passes** — discovery issues zero
  property reads. This is the regression guard for the discovery/enrichment boundary.
- `testADBTransportParseDeviceList` / `ParseEmptyList` — still pass, updated for the
  corrected `deviceCodename` semantics and asserting that discovery claims no marketing
  name or manufacturer.
- `testDeviceStateIsConnected`, `testErrorDescription`, `testErrorRecoverable` — unchanged.
- All 17 DTCA-1 worker and verifier tests — unchanged.
- Phase 2's three properties (`16` / `36` / `arm64-v8a`) re-confirmed on the real device.

---

## Final Architecture

```
PixelDesktop/Core/Models/
└── AndroidDevice.swift      representation: identity + properties + state

PixelDesktop/Transport/
├── Transport.swift          TransportProtocol (+getSystemProperties), TransportResult,
│                            DeviceProperties (6), DevicePropertyKey (6),
│                            DeviceCapabilities, DeviceOperation
└── ADBTransport.swift       actor; execute, listDevices, parseDeviceList, getprop,
                             getSystemProperties, parseSystemProperties

PixelDesktop/Device/
├── DeviceDiscovery.swift    protocol
├── DeviceManager.swift      @MainActor; device list; enrichDevice(serial:)
└── DeviceEnricher.swift     batched read → enriched AndroidDevice
```

**Verified device model** (Pixel 7a, `3C261JEHN25632`):

| Field | Value | Source |
|---|---|---|
| `serialNumber` | `3C261JEHN25632` | `adb devices -l` |
| `deviceCodename` | `lynx` | `adb devices -l` `device:` token |
| `marketingName` | `Pixel 7a` | `ro.product.model` |
| `manufacturer` | `Google` | `ro.product.manufacturer` |
| `androidVersion` | `16` | `ro.build.version.release` |
| `apiLevel` | `36` | `ro.build.version.sdk` |
| `architecture` | `arm64-v8a` | `ro.product.cpu.abi` |
| `supportedABIs` | `["arm64-v8a"]` | `ro.product.cpu.abilist` |
| `state` | `device` | `adb devices -l` |

---

## Lessons Learned

1. **Probe before implementing, and mean it.** D6 gated implementation on the device being
   present. That gate mattered: the probe established that `abilist` returns a *single*
   entry on this device, so the parser treats the single-entry case as the common case
   rather than an edge case. Assumed multi-value behaviour would have been wrong.
2. **A field name can be a correctness bug.** `manufacturer` holding `lynx` compiled
   cleanly, passed 49 tests, and rendered a falsehood in the UI. Nothing failed. Only
   reading what the `device:` token actually contains exposed it. **Tests that assert a
   field is non-empty cannot catch a field holding the wrong thing.**
3. **Verify against real data when the device is unavailable — and say so.** When the
   device detached mid-verification, replaying its captured real output verified the
   pipeline honestly. It is not a substitute for live verification, and the phase was not
   declared complete until live verification passed too.
4. **Turn captured real output into a permanent test.** `testEnrichmentAgainstRealPixel7aOutput`
   keeps the pipeline pinned to real device data in the hermetic suite, where it runs on
   every future change with no device attached.
5. **A test double with two stores will disagree with itself.** The `MockTransport`
   failure came from `getprop` and `getSystemProperties` reading different maps. Test
   doubles must mirror the production contract, not merely satisfy individual tests.

---

## What Worked Well

- **Probing the real device before writing code** — caught the single-entry `abilist` and
  confirmed the manufacturer defect was real.
- **Gating implementation on the probe** — refused to implement against AOSP documentation.
- **The replay harness over real captured output** — honest verification when the device was
  gone, and it caught nothing wrong because the design was already right.
- **`git rm` for the superseded model** — auditable and recoverable, rather than an
  invisible deletion.
- **Compiler-driven rename** — 6 files, every site caught by the compiler, no manual search.
- **Regression tests that assert identity relationships** — `manufacturer != deviceCodename`
  pins the defect in a way a non-empty assertion never could.
- **Measuring the batching claim** — 3.7× was measured, not asserted.

---

## What Did Not Work

- **Relying on the device staying attached.** It detached twice. Real-device verification
  must be treated as interruptible and re-runnable, not as a single step.
- **Writing `MockTransport.getprop` against a separate store** from
  `getSystemProperties` — produced a self-contradicting test double.
- **Leaving `model` in the Phase 2 model at all** — it conflated three concepts (build
  name, codename, marketing name) and the ambiguity survived a whole phase.

---

## Best Technique Discovered

**When a field's name and its data can disagree, write a test asserting the relationship
between them, not their presence.**

Why it worked: `manufacturer` was populated, non-empty, and wrong. Every existing test
passed because they only checked that a value existed. The test that catches this is
`XCTAssertNotEqual(device.manufacturer, device.deviceCodename)` — it asserts that two
fields which *should* differ actually do. That is only writable once you know what the
source really contains, which is why probing came first.

When to use it: any field populated from an ambiguous or reused source — tokens that carry
more than one meaning, enums reused for two purposes, identifiers that alias.

When not to use it: when the fields are genuinely independent and no relationship should
hold. Asserting an arbitrary inequality would be noise.

**Second-best: turn real captured system output into a permanent hermetic test.** It keeps
the parser honest against reality on every future run, without needing the hardware.

---

## Future Recommendations

1. **Phase 4 (RNZM-21, RNZM-22)** must extend `DeviceOperation` as it implements `shell()`
   and lifecycle handling. Understating operations is safe; overstating is not.
2. **Phase 4 must decide whether reconnect invalidates cached properties** and record it in
   an ADR. Phase 3 deliberately does not cache.
3. **Phase 5 must use `DeviceCapabilities.supports(abi:)`** before delivering a native
   worker binary, rather than assuming `arm64-v8a`.
4. **Do not add `DeviceService` until a real device service exists.** The legacy
   course-of-action §9.2 warns explicitly against resurrecting port 18373 without evidence.
5. **New device-touching code must depend on `TransportProtocol`**, not `ADBTransport`, so
   it stays testable with `MockTransport`.
6. **The UI still does not call `enrichDevice`** — `ContentView` will show "Unknown" for
   enrichment fields until Phase 8 wires it. Deferred by design; do not add polling-time
   enrichment to compensate.

---

## Phase Completion Record

```
PHASE STATUS: COMPLETE

Requirements:            PASS  (all 9 requirements met; D3 deferred by decision, not omission)
Build:                   PASS  (xcodebuild Debug — BUILD SUCCEEDED)
Tests:                   PASS  (73 executed, 0 failures; 4 integration tests skipped by design)
Device verification:     PASS  (6/6 properties cross-checked against raw adb)
Failure handling:        PASS  (unset property rejected; unknown serial fails)
Regression:              PASS  (all Phase 2 tests pass, incl. discovery-issues-no-property-reads)
Architecture review:     PASS  (ADR-008)
Documentation:           PASS  (phase log, ADR-008, test report, architecture/overview.md)
AI development log:      UPDATED
Known limitations:       DOCUMENTED
```

**Known limitations**

- `DeviceService` is not modelled (D3 deferred). No on-device service exists; introduce it
  only when one does.
- `DeviceCapabilities` models only `supportedABIs`. RAM/GPU/NPU/thermal/storage are
  Phases 6/7 concerns with their own acquisition work.
- `DeviceOperation` lists only `.discover` and `.readSystemProperties`. Phase 4 extends it.
- No operations protocol exists yet. Phase 4 (RNZM-21) defines it when it has an
  implementation.
- The UI does not call `enrichDevice`, so enrichment fields display "Unknown" until
  Phase 8.
- The pre-existing `ConformanceIsolation` warning on `DeviceManager`'s conformance to
  `DeviceDiscoveryProtocol` remains (Phase 1 origin, Swift 6 readiness, not an error under
  Swift 5).
- Real-device verification requires the device to stay attached; it detached twice during
  this phase.

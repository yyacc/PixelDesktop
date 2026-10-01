# PixelDesktop Architecture — As Delivered

**Last updated:** 2026-10-01 (end of Phase 2)
**Scope:** This document describes what the code **actually implements**. It is not a
target architecture. Anything not implemented is listed separately in
[Not Yet Implemented](#not-yet-implemented).

Phase numbering follows the **master engineering prompt §16** — see
[ADR-007](../decisions/ADR-007-authoritative-phase-sequence.md).

---

## 1. What PixelDesktop Is

A native macOS application that uses a physical Android phone (Google Pixel 7a) as a real
compute/device node. The Pixel is a genuine physical device, not an emulator and not merely
a screen-mirroring endpoint.

Current state: the application discovers the device over ADB and reads its stable system
identity. Compute workloads are **not** yet implemented (Phase 5).

---

## 2. Delivered Component Map

```
PixelDesktop (macOS app)
│
├── App/                          SwiftUI entry point and observable state
│   ├── PixelDesktopApp.swift     @main App
│   ├── AppState.swift            @MainActor ObservableObject; binds DeviceManager
│   └── ContentView.swift         NavigationSplitView; device list + detail
│
├── Core/                         Shared types and utilities
│   ├── Errors/
│   │   └── PixelDesktopError.swift    Typed error enum + isRecoverable
│   ├── Logging/
│   │   └── AppLogger.swift            @MainActor, OSLog-backed, 500-entry ring buffer
│   └── Models/
│       └── PixelDevice.swift          Device identity + state
│
├── Transport/                    ADB communication (transport only)
│   ├── Transport.swift           TransportProtocol, TransportResult,
│   │                             DeviceProperties, DevicePropertyKey
│   └── ADBTransport.swift        actor; execute, listDevices, parseDeviceList, getprop
│
├── Device/                       Discovery, enrichment, ownership
│   ├── DeviceDiscovery.swift     DeviceDiscoveryProtocol
│   ├── DeviceManager.swift       @MainActor; owns device list; enrichDevice(serial:)
│   └── DeviceEnricher.swift      Reads stable properties; returns enriched PixelDevice
│
├── Compute/                      DTCA-1 workload (local reference implementation)
│   └── DTCA1Worker.swift         DTCA1Result, WordCount, DTCA1Classification
│
└── Verification/                 Result verification
    └── ResultVerifier.swift      VerificationResult, ResultVerifier
```

**No `Video/` subsystem exists, and none is planned.** scrcpy is not a PixelDesktop
subsystem — see [ADR-007] context and the master prompt's "not a better scrcpy frontend"
constraint.

---

## 3. Layering and Responsibilities

Each layer has one responsibility. The boundaries are enforced by tests that assert calls
do **not** happen across them.

```
                    ┌──────────────────────────┐
                    │  App  (SwiftUI / AppState)│   presentation + state binding
                    └────────────┬─────────────┘
                                 │
                    ┌────────────▼─────────────┐
                    │  Device                   │   "what devices exist, and what are they"
                    │  DeviceManager            │   owns the published device list
                    │  DeviceEnricher           │   reads stable properties
                    │  DeviceDiscoveryProtocol  │
                    └────────────┬─────────────┘
                                 │
                    ┌────────────▼─────────────┐
                    │  Transport                │   "talk to ADB"
                    │  TransportProtocol        │   ← the swap seam
                    │  ADBTransport (actor)     │
                    └────────────┬─────────────┘
                                 │
                    ┌────────────▼─────────────┐
                    │  adb (process)            │
                    └────────────┬─────────────┘
                                 │
                    ┌────────────▼─────────────┐
                    │  Pixel 7a                 │
                    └──────────────────────────┘
```

| Layer | Owns | Explicitly does not |
|---|---|---|
| `App` | UI, state binding | Talk to ADB, parse output |
| `DeviceManager` | Device list state, when to enrich | Parse ADB output, know ADB details |
| `DeviceEnricher` | Reading stable properties, composing an enriched device | Discover devices, render UI |
| `ADBTransport` | Process execution, timeouts, output parsing | Know what a `PixelDevice` means |
| `TransportProtocol` | The seam that makes the above swappable | — |

### The swap seam

`TransportProtocol` is the substitution point. `ADBTransport` is the only production
implementation; `MockTransport` (in the test target) is the test implementation. Because
`DeviceEnricher` and `DeviceManager` depend on the protocol rather than the actor,
device-touching logic is unit-testable with no device attached.

If a future phase adds wireless ADB or a different transport, it implements
`TransportProtocol` and nothing above it changes.

---

## 4. Data Flow — Discovery and Enrichment

Discovery and enrichment are **deliberately separate**. This is the central Phase 2
architectural decision ([ADR-005](../decisions/ADR-005-device-property-enrichment.md)).

```
adb devices -l
      ↓
ADBTransport.parseDeviceList()      pure, nonisolated, no I/O
      ↓
  [PixelDevice]                     androidVersion="" apiLevel=0 architecture=""
      ↓                             (properties empty BY DESIGN)
DeviceManager.enrichDevice(serial:)  explicit call, NOT on the discovery poll
      ↓
DeviceEnricher.enrich(_:)            3 sequential reads
      ↓
ADBTransport.getprop(serial,key)     adb -s <serial> shell getprop <key>
      ↓
DeviceProperties.make(...)           trim + validate; throws on empty/malformed
      ↓
  enriched PixelDevice               republished by DeviceManager
```

**Why they are separate:** `adb devices -l` answers "which devices are attached" in one
call. Enrichment answers "what is this device" and costs one round trip per property. These
values cannot change while the device stays booted, so enriching on a 5-second discovery
poll would add three ADB round trips per interval for information that cannot change.

**Regression guard:** `testDiscoveryLeavesPropertiesUnpopulated` asserts discovery issues
**zero** `getprop` calls.

---

## 5. Device Model — Current State

`PixelDevice` (39 lines) currently holds:

| Field | Type | Populated by | Static? |
|---|---|---|---|
| `id` | `String` | `parseDeviceList` (serial) | Static |
| `serialNumber` | `String` | `parseDeviceList` | Static |
| `model` | `String` | `parseDeviceList` (`model:` token) | Static |
| `manufacturer` | `String` | `parseDeviceList` (`device:` token) | Static |
| `androidVersion` | `String` | `DeviceEnricher` | Static |
| `apiLevel` | `Int` | `DeviceEnricher` | Static |
| `architecture` | `String` | `DeviceEnricher` | Static |
| `state` | `DeviceState` | `parseDeviceList` | **Dynamic** |

`DeviceState`: `device` / `unauthorized` / `offline` / `unknown`, with `isConnected`.

> **Naming note (candidate for Phase 3):** `manufacturer` is currently populated from the
> `device:` token in `adb devices -l`, which is the device *codename* (`lynx` for the Pixel
> 7a), not the manufacturer. The name does not match the data. Flagged in the Phase 3
> proposal.

`DeviceProperties` (3 fields) is the transport-level enrichment payload:
`androidVersion`, `apiLevel`, `architecture`, with `DevicePropertyKey` holding the
`getprop` keys.

---

## 6. Error Model

`PixelDesktopError` — typed, `Equatable`, `CustomStringConvertible`:

`deviceNotFound` · `deviceUnauthorized` · `deviceOffline` · `adbCommandFailed(command:exitCode:stderr:)` ·
`adbTransportError(String)` · `invalidInput(String)` · `timeout(operation:duration:)` ·
`cancelled` · `verificationFailed(reason:)` · `workerError(String)` · `unknown(String)`

`isRecoverable` distinguishes transient (device state, ADB, timeout, cancellation) from
non-recoverable (invalid input, verification failure, worker error) conditions.

Established mapping in Phase 2:

- unset property → `invalidInput` (because `getprop` exits **0** with empty output for an
  unset key — the exit code cannot detect it)
- unknown serial → `adbCommandFailed` (adb exits 1)

---

## 7. Testing Architecture

Two tiers ([ADR-006](../decisions/ADR-006-test-isolation.md)):

| Tier | File | Device needed | Runs by default |
|---|---|---|---|
| Hermetic unit tests | `PixelDesktopTests` (46 tests) | No | Yes — the regression gate |
| Real-device integration | `PixelDeviceIntegrationTests` (3 tests) | Yes | No — skipped unless `PIXELDESKTOP_DEVICE_SERIAL` is set |

Assertions about device-owned values check **well-formedness**, never a pinned version.
A device OS update must not produce a false failure.

**Known tooling gap:** `xcodebuild` in this environment does not forward
`TEST_RUNNER_PIXELDESKTOP_DEVICE_SERIAL` into the test process, so real-device evidence is
currently produced by a CLI harness that compiles the production sources with `swiftc`.
Recorded in ADR-006.

---

## 8. Verified Device Facts

Pixel 7a, serial `3C261JEHN25632`:

| Property | `getprop` key | Value |
|---|---|---|
| Android version | `ro.build.version.release` | `16` |
| API level | `ro.build.version.sdk` | `36` |
| CPU ABI | `ro.product.cpu.abi` | `arm64-v8a` |
| codename (from `adb devices -l`) | — | `lynx` |

> **Device attachment is not permanent.** The Pixel was physically disconnected during
> Phase 3 preparation (2026-10-01); `adb devices` returned empty and the device was absent
> from the USB bus. Any phase requiring real-device verification must first confirm
> attachment. Do not assume the values above can be re-read on demand.

---

## 9. Not Yet Implemented

Listed so this document cannot be mistaken for a description of delivered functionality.

| Capability | Owning phase | Status |
|---|---|---|
| `shell()` — arbitrary ADB shell execution | **4** (Android Application / Process Control) | Not implemented. Deferred in Phase 2. |
| `push()` / `pull()` — file transfer | **5** (Pixel Compute Worker) | Not implemented. Deferred in Phase 2. |
| connect / disconnect / reconnect lifecycle | **4**, hardened in **10** | Not implemented. Deferred in Phase 2. |
| Android device operations (launch/stop apps, process queries) | **4** | Not implemented |
| Device capabilities / available services / supported operations model | **3** | Subject of the Phase 3 proposal |
| DTCA-1 execution on the Pixel (worker APK) | **5** | Not implemented. Only the local macOS reference implementation exists. |
| Result retrieval from the device | **5** | Not implemented |
| Local AI worker on the Pixel | **6** | Not implemented |
| Resource-aware workload routing | **7** | Not implemented |
| UI for workloads / worker state | **8** | Not implemented. Current UI shows device list + identity only. |
| Hermes integration | **9** | Not implemented |
| Production hardening | **10** | Not implemented |

---

## 10. Related Records

- [ADR-001: Project Structure](../decisions/ADR-001-project-structure.md)
- [ADR-002: ADB Transport](../decisions/ADR-002-adb-transport.md)
- [ADR-003: DTCA-1 Worker APK](../decisions/ADR-003-dtca1-worker-apk.md)
- [ADR-004: Verification by Re-computation](../decisions/ADR-004-verification.md)
- [ADR-005: Device Property Enrichment Is Separate From Discovery](../decisions/ADR-005-device-property-enrichment.md)
- [ADR-006: Test Isolation Strategy](../decisions/ADR-006-test-isolation.md)
- [ADR-007: Authoritative Phase Sequence](../decisions/ADR-007-authoritative-phase-sequence.md)
- [Phase 2 engineering log](../phases/phase-02-device-discovery.md)

# Phase 4 Test Report

**Date:** 2026-10-01
**Phase:** 4 — Android Application / Process Control
**Device:** Pixel 7a, serial `3C261JEHN25632`

---

## 1. Build

```
$ xcodegen generate
$ xcodebuild -project PixelDesktop.xcodeproj -scheme PixelDesktop -configuration Debug build
** BUILD SUCCEEDED **
```

One warning, pre-existing from Phase 1 (not introduced here):
`ConformanceIsolation` on `DeviceManager`'s conformance to `DeviceDiscoveryProtocol`.

---

## 2. Default test suite (hermetic)

```
Executed 4 tests, with 4 tests skipped and 0 failures (0 unexpected)
Executed 102 tests, with 0 failures (0 unexpected)
Executed 106 tests, with 4 tests skipped and 0 failures (0 unexpected)
** TEST SUCCEEDED **
```

**102 hermetic tests executed, 0 failures.** 4 integration tests skipped by design.

### New in Phase 4

| Test | Verifies |
|---|---|
| `testValidatePackageNameAcceptsValidIdentifiers` | 4 valid identifiers accepted |
| `testValidatePackageNameRejectsEmpty` | Whitespace-only rejected |
| `testValidatePackageNameRejectsShellMetacharacters` | **10 hostile strings rejected** — the injection boundary |
| `testStopRejectsProtectedPackages` | SystemUI, GMS, android, phone refused |
| `testStopRejectsProtectedPrefixes` | `com.android.providers.*`, `com.android.server.*` refused |
| `testStopRejectsWorkerPackage` | Phase 5 worker package refused |
| `testStopAllowsOrdinaryThirdPartyPackage` | Ordinary package allowed |
| `testContainmentIsDenylistNotBoundary` | **A `com.android.*` impostor is NOT protected** |
| `testSettingsIsNotProtectedBecauseItIsNotDeviceCritical` | **Criterion pinned** |
| `testParsePackageList` | Real `package:` shape |
| `testParsePackageListIgnoresMalformedLines` | Robustness |
| `testParseLaunchableActivitiesFromRealShape` | Real 58-entry shape; header lines excluded |
| `testParseLaunchableActivitiesEmptyOutput` | No crash |
| `testParsePID` / `testParsePIDReturnsNilWhenNotRunning` | PID parsing; empty → `nil` |
| `testComponentActivityExtraction` | Both component forms |
| `testInstalledApplicationsThirdPartyByDefault` | `-3` command; argv asserted |
| `testInstalledApplicationsIncludeSystemUsesDifferentCommand` | Command selection |
| `testLaunchableApplicationsResolvedInOneCall` | **One device call, not N** |
| `testLaunchApplicationBuildsExactCommand` | Exact `am start -n` argv |
| `testLaunchApplicationRejectsNonLaunchableBeforeCommand` | **No command issued** |
| `testIsApplicationRunningTrue` | `pidof` exit 0 |
| `testIsApplicationRunningFalseIsNotAnError` | **`pidof` exit 1 → `false`** |
| `testStopApplicationBuildsExactCommand` | Exact `am force-stop` argv |
| `testStopApplicationRefusesProtectedPackageBeforeCommand` | **Zero invocations** |
| `testShellNonZeroExitSurfacesAdbError` | Exit 255 → `adbCommandFailed` |
| `testDeviceOperationsMatchImplementedCapabilities` | Exactly the 6 implemented operations |
| `testInstalledApp*` (3) | `isLaunchable`, `displayLabel`, system heuristic |
| `testRequireConnectedDevice*` (3) | Guard returns / `deviceNotFound` / `deviceOffline` |
| `testDisconnectInvalidatesEnrichedProperties` | **D3 pinned: no caching across reconnect** |

### Phases 2 and 3 tests rerun (regression)

All pass, including `testDiscoveryLeavesPropertiesUnpopulated` (discovery issues **zero**
property reads), all Phase 3 device-model/capability/parser tests, and all 17 DTCA-1 tests.

---

## 3. Real-device verification (approved sequence, executed exactly)

```
STEP 1 — DISCOVER
  [PASS] device discovered — state=device
STEP 2 — shell() PRIMITIVE
  [PASS] shell() executes — stdout=pixeldesktop-shell-ok
STEP 3 — APPLICATION DISCOVERY
  [PASS] third-party packages found — count=41
  [PASS] all packages found — count=364
  [PASS] third-party subset of all
STEP 4 — LAUNCHABLE APPLICATIONS
  [PASS] launchable set non-empty — count=58
  [PASS] all entries have an activity
  [PASS] target 'com.android.settings' is launchable — activity=com.android.settings/.Settings
STEP 5 — RUNNING STATE (pre-launch)
    running before launch: true
STEP 6 — LAUNCH com.android.settings
  [PASS] target is running after launch
STEP 7 — STOP com.android.settings
  [PASS] target is not running after stop
STEP 8 — CONTAINMENT
  [PASS] systemui stop refused — Invalid input: Refusing to stop protected package 'com.android.systemui': stopping it disrupts the device itself
  [PASS] injection attempt rejected
  [PASS] worker package stop refused
  [PASS] non-launchable launch rejected
STEP 9 — DEVICE HEALTH AFTER OPERATIONS
  [PASS] device still attached and healthy
CROSS-CHECK (raw adb, no project code):
    raw pidof com.android.settings -> '' exit=1
    raw third-party count -> 41  (ours: 41)
  [PASS] third-party count matches raw adb

RESULT: PASS — all checks passed
```

### Verified values

| Quantity | Value | Cross-check |
|---|---|---|
| Third-party packages | 41 | raw adb: 41 ✅ |
| All packages | 364 | — |
| Launchable activities | 58 | — |
| Settings launcher | `com.android.settings/.Settings` | — |
| Settings after stop | `pidof` empty, exit 1 | raw adb: empty, exit 1 ✅ |

### Containment verified on the real device

| Attempt | Result |
|---|---|
| Stop `com.android.systemui` | **Refused** |
| Stop `com.example; reboot` (injection) | **Rejected** |
| Stop worker package | **Refused** |
| Launch non-launchable package | **Rejected, no command issued** |

---

## 4. Failure found by real-device verification

**The first live run FAILED at step 7.** `stopApplication("com.android.settings")` was refused
because `com.android.settings` had been placed on the protected list.

**Root cause:** the entry was added by reflex on package name, not against the list's own
stated criterion ("stopping this disrupts the device itself"). Settings is an ordinary
user-facing app with no system service depending on it; it can be swiped away and reopened.

**Why unit tests could not catch it:** all 105 unit tests passed. The denylist and the test
package names were chosen by the same author from the same assumptions. Only running against
the real device, with the target the user approved, exposed it.

**Fix:** removed the entry, documented the criterion inline in the source, added
`testSettingsIsNotProtectedBecauseItIsNotDeviceCritical` to pin it, and recorded the episode in
ADR-009 as evidence that name-based protection is heuristic.

**Re-run after fix:** full sequence PASS.

---

## 5. Requirements traceability

| # | Requirement | Evidence |
|---|---|---|
| 1 | D1 — `shell()` transport-only, not exposed upward | On `TransportProtocol` only; absent from `AppOperationsProtocol`; `AppState` wrappers take typed args, never command strings |
| 2 | D2 — containment + **documented limitations** | §2 tests; ADR-009 "The Protection Model — and Its Limitations" |
| 3 | D3 — no caching across reconnect | `testDisconnectInvalidatesEnrichedProperties`; `refreshDevices` replaces wholesale |
| 4 | D4 — defer `ps -A` | Not implemented; `pidof` used |
| 5 | D5 — `Operations/` layer | `AppOperationsProtocol` + `ADBAppOperations` |
| 6 | D6 — phase kept together | shell → operations → lifecycle → verification, all in this phase |
| 7 | D7 — approved verification sequence | §3, executed exactly, Settings as target |
| 8 | Extend `DeviceOperation` only when the operation exists | 6 cases, each implemented |
| 9 | No `push()`/`pull()` | Not implemented (RNZM-23, Phase 5) |
| 10 | Preserve Phase 2/3 regressions | All pass |
| 11 | Build and test before real-device verification | §1, §2 before §3 |
| 12 | Document lifecycle/cache decision in the ADR | ADR-009 §4 and Consequences |

---

## 6. Artifacts

- Real-device verification harness: `~/.hermes/cache/scratch/pd-verify4/`
  (outside the repository; a throwaway evidence tool, not a project artifact)

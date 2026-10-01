# Phase 4 — Android Application / Process Control

**Status: COMPLETE**
**Date:** 2026-10-01
**Phase:** 4 (Android Application / Process Control) — authoritative per [ADR-007](../decisions/ADR-007-authoritative-phase-sequence.md)
**Preceding phase:** Phase 3 (Android Device Model) — COMPLETE
**Proposal:** `phase-04-application-process-control-proposal.md` (approved; D2 approved **with modification**)

---

## Phase Objective

Implement controlled Android application operations, with device operations separated from
discovery and representation, using documented Android/ADB capabilities and tested against
the real Pixel 7a.

---

## Requirements

Master prompt §16 Phase 4: discover applications · identify launchable applications · launch
applications · monitor application state · stop applications where appropriate · query
activity/process information. Do not: modify third-party APKs · inject code · bypass
security · bypass anti-cheat · perform destructive operations.

Approved decisions:

| # | Decision |
|---|---|
| D1 | `shell()` as a transport-only primitive, below the Operations layer, never exposed to UI/Hermes |
| D2 | **Approved with modification** — containment must not treat package naming as a sufficient security boundary; document the protection model **and its limitations** |
| D3 | No caching of enriched `DeviceProperties` across disconnect/reconnect |
| D4 | Defer `ps -A` / `runningProcesses()` |
| D5 | New `Operations/` layer: `AppOperationsProtocol` + `ADBAppOperations` |
| D6 | Phase 4 kept together: shell → application operations → lifecycle → verification |
| D7 | Settings as the benign real-device verification target; exact sequence specified |

---

## Starting State

Phase 3 complete: 73 tests, BUILD SUCCEEDED, commit `7c00e79`. `TransportProtocol` had
`execute`, `listDevices`, `getprop`, `getSystemProperties`. **No `shell()`, no operations
layer at all.** `DeviceOperation` listed 2 cases.

---

## Investigation

### Read-only capability probe (nothing launched or stopped)

| Probe | Result | Design impact |
|---|---|---|
| `which su` | empty | **No root available** |
| `getprop ro.debuggable` | `0` | **Not debuggable** |
| `pm list packages` | 364 | — |
| `pm list packages -3` | 41 | Default scope = third-party |
| `cmd package query-activities …` | 58 launchable, exit 0 | One call gives the whole set |
| `dumpsys package <pkg>` | **49,893 bytes** | **Must not be used per-app** |
| `pidof <running>` / `<not running>` | exit 0 / **exit 1** | Exit code is meaningful |
| `resolve-activity` (nothing found) | `No activity found`, exit **0** | Output-based detection |
| `am force-stop` (no args) | exit **255** + Java exception | `am` errors are 255 |

**F1 — the largest efficiency decision:** resolving launch activities via `dumpsys package`
costs ~49 KB per app. For 41 third-party packages that is ~2 MB for information the single
`query-activities` call already provides. Per-app resolution is not used.

**F2 — `pidof` exit 1 is a valid answer,** unlike `getprop`'s exit 0 for an unset key. The
two must not share error handling.

**F4 — no privilege escalation exists** on this device. This bounds `shell()`'s blast radius
and is the backbone of the protection model (ADR-009).

---

## Architecture

```
                    AppState
                       │  guard-first wrappers; no shell strings
                       ▼
            AppOperationsProtocol          ← the operations seam (mockable)
                       │  named operations, explicit typed arguments
                       ▼
              ADBAppOperations
                       │  fixed command templates + one validated argument
                       ▼
             TransportProtocol
                  ├── shell()          ← transport primitive, NOT exposed upward
                  ├── listDevices() / getprop() / getSystemProperties()
                  ▼
             ADBTransport (actor)
                       ▼
                  adb  →  Pixel 7a
```

| Layer | Owns | Does not |
|---|---|---|
| `AppState` | Guard-first entry points | Compose commands, know ADB |
| `AppOperationsProtocol` | Named application operations | Accept shell strings |
| `ADBAppOperations` | Command templates, validation, containment, parsing | Discover devices, render |
| `ADBTransport` | Process execution, timeouts | Know Android application semantics |
| `AndroidDevice` / `InstalledApp` | Representation only | Perform any action |

---

## Alternatives Considered

**A. One transport method per Android command** (`listPackages()`, `launch()`, …) — rejected;
puts application semantics in the transport, contradicting ADR-005 and Phase 2.

**B. No containment on `stopApplication`** — rejected; a wildcard or system-package stop
could leave the device broken.

**C. Treat the denylist as a security boundary** — rejected; it cannot be complete.
Documented as heuristic (D2).

**D. Cache enriched properties with boot-session invalidation** — rejected; adds state and a
staleness bug for no measured benefit.

**E. `ps -A` process inventory** — deferred (D4); no consumer.

**F. Expose `shell()` to the UI for flexibility** — rejected; forbidden by §22 and D1.

---

## Decision

- `shell()` on `TransportProtocol` — transport-only primitive, never exposed upward
- New `Operations/` layer: `AppOperationsProtocol` + `ADBAppOperations`
- `InstalledApp` model: `packageName` + `launchActivity: String?`; **running state is a
  query, not a field**
- `DeviceOperation` 2 → 6 cases, extended in the same commit as each implementation
- Lifecycle: guard-first (`requireConnectedDevice`), wholesale list replacement on refresh,
  **no caching across disconnect** (D3)
- Stop containment: exact package, no wildcards, no shell strings, protected packages +
  prefixes + worker package rejected before any command
- Recorded in **ADR-009**, including the protection model **and its explicit limitations**

---

## Implementation

### Files created

| File | Purpose |
|---|---|
| `PixelDesktop/Core/Models/InstalledApp.swift` | Application representation |
| `PixelDesktop/Operations/AppOperationsProtocol.swift` | The operations seam |
| `PixelDesktop/Operations/ADBAppOperations.swift` | Implementation, validation, containment, parsers |
| `engineering/decisions/ADR-009-application-operations-and-shell-containment.md` | Protection model and limitations |
| `engineering/phases/phase-04-application-process-control.md` | This document |
| `engineering/testing/phase-04-test-report.md` | Test and verification evidence |

### Files modified

| File | Change |
|---|---|
| `Transport/Transport.swift` | `shell()` on protocol; `DeviceOperation` +4 cases |
| `Transport/ADBTransport.swift` | `shell()` implementation |
| `Device/DeviceManager.swift` | `requireConnectedDevice(serial:)`; documented disconnect invalidation |
| `App/AppState.swift` | Transport + operations injection; 5 guard-first operation wrappers |
| `PixelDesktopTests/PixelDesktopTests.swift` | 33 tests added/updated; `MockTransport.shell()` |
| `engineering/README.md`, `architecture/overview.md`, `created-resources.json` | Index, architecture, manifest |

**No UI changes.** Phase 4 required none for verification, per the approval.

---

## Experiments

1. **Read-only capability probe** — established F1–F4 before any code was written.
2. **Live approved verification sequence** — discover → resolve launcher → launch Settings →
   verify running → stop Settings → verify stopped, plus containment checks and a raw-`adb`
   cross-check. Result: **PASS**.
3. **`query-activities` single-call vs per-app `dumpsys`** — measured 49,893 bytes for one
   `dumpsys package` call, confirming the single-call approach.

---

## Failures

**Real-device verification caught an over-broad containment entry.** The first live run
**failed at step 7**: `stopApplication("com.android.settings")` was refused because
`com.android.settings` had been placed on the protected list.

Root cause: the entry was added **by reflex on package name**, not against the list's own
stated criterion ("stopping this disrupts the device itself"). Settings is an ordinary
user-facing application with no system service depending on it, and can be swiped away and
reopened. It does not meet the criterion.

This is a direct illustration of the D2 modification: **package naming is not a sufficient
security boundary.** The rule was applied wrongly on the first attempt by the author of the
rule.

**One unit-test failure during implementation:** `testDeviceOperationsMatchImplementedCapabilities`
(Phase 3) asserted 2 operations and correctly failed once Phase 4 added 4 more. Updated, not
suppressed.

---

## Diagnosis

The containment failure was classified as **implementation / over-broad rule**, surfaced by
**real-device verification** — not by unit tests, which used synthetic package names and
therefore could not catch a wrong real-world entry.

This is the second time in this project that a defect compiled cleanly and passed the full
suite while being wrong (the first was `manufacturer` holding the codename in Phase 3). Both
were caught by comparing against reality, not by the test suite alone.

The `DeviceOperation` test failure was **expected staleness** — a guard doing its job.

---

## Corrections

1. Removed `com.android.settings` from `protectedPackages`, with the criterion documented
   inline in the source.
2. Added `testSettingsIsNotProtectedBecauseItIsNotDeviceCritical` to pin the criterion so the
   entry cannot silently return.
3. Documented the over-broad entry in ADR-009 as evidence that name-based protection is
   heuristic.
4. Updated the Phase 3 `DeviceOperation` test to the Phase 4 set.

---

## Tests

**33 tests added or updated.** Coverage:

| Area | Tests |
|---|---|
| Package-name validation (the injection boundary) | Valid identifiers accepted; **10 hostile strings rejected** (semicolon, `&&`, pipe, backticks, `$()`, redirect, newline, flags, quotes, traversal) |
| Stop containment | Protected packages refused; protected prefixes refused; worker package refused; ordinary package allowed; **denylist-not-boundary pinned**; **Settings not protected (criterion pinned)** |
| Parsers | `parsePackageList` (incl. malformed); `parseLaunchableActivities` (real 58-entry shape, empty, header lines excluded); `parsePID` (multi-PID, not-running → `nil`); `componentActivity` extraction |
| Operations | Third-party vs system command selection; launchable set resolved in **one call**; exact `am start -n` argv; non-launchable rejected **before any command**; `pidof` exit 1 → `false` not error; exact `am force-stop` argv; refused stop issues **zero** commands; non-zero exit → `adbCommandFailed` (255) |
| `InstalledApp` | `isLaunchable`; `displayLabel`; system heuristic |
| `DeviceOperation` | Equals exactly the 6 implemented operations |
| Lifecycle | Guard returns connected device; unknown serial → `deviceNotFound`; offline → `deviceOffline`; **disconnect invalidates enriched properties** |

---

## Results

| Check | Result |
|---|---|
| `xcodegen generate` | PASS |
| `xcodebuild ... build` | **BUILD SUCCEEDED** |
| `xcodebuild ... test` | **106 executed, 0 failures** (4 integration tests skipped by design) |
| Real-device: `shell()` | PASS — `echo` round-trip |
| Real-device: discovery | PASS — 41 third-party, 364 total, subset relation holds |
| Real-device: launchable set | PASS — 58, all with activities, Settings present |
| Real-device: **launch Settings** | PASS — running after launch |
| Real-device: **stop Settings** | PASS — not running after stop |
| Real-device: containment | PASS — SystemUI refused, injection rejected, worker refused, non-launchable rejected |
| Real-device: device health after ops | PASS — still attached, state `device` |
| Cross-check vs raw adb | PASS — third-party count 41 = 41 |
| Regression | PASS — all Phase 2 and 3 tests |

**Approved verification sequence, executed exactly:** discover → resolve launcher → launch
Settings → verify running → stop Settings → verify stopped. No destructive test beyond the
required stop.

---

## Regression Tests

All Phase 2 and Phase 3 guarantees re-verified:

- `testDiscoveryLeavesPropertiesUnpopulated` — discovery still issues **zero** property reads
- `testDisconnectInvalidatesEnrichedProperties` — **new**, pins D3
- All Phase 3 device-model, capabilities, operation, parser and enrichment tests
- All 17 DTCA-1 worker/verifier tests
- Phase 2 `parseDeviceList` / error / logger tests

---

## Final Architecture

```
PixelDesktop/
├── App/            AppState (guard-first operation wrappers), ContentView (unchanged)
├── Core/
│   ├── Models/     AndroidDevice.swift, InstalledApp.swift
│   ├── Errors/     PixelDesktopError.swift
│   └── Logging/    AppLogger.swift
├── Operations/     AppOperationsProtocol.swift, ADBAppOperations.swift   ← NEW in Phase 4
├── Device/         DeviceDiscovery, DeviceManager, DeviceEnricher
├── Transport/      Transport.swift, ADBTransport.swift
├── Compute/        DTCA1Worker.swift
└── Verification/   ResultVerifier.swift
```

`DeviceOperation` now: `.discover`, `.readSystemProperties`, `.listApplications`,
`.launchApplication`, `.queryApplicationState`, `.stopApplication`.

---

## Lessons Learned

1. **Real-device verification catches what synthetic tests cannot.** The over-broad
   containment entry passed all 105 unit tests because those tests used package names chosen
   by the same author who chose the denylist. Only running against the real device — with a
   real target the user actually approved — exposed it. **Unit tests share the author's
   assumptions; reality does not.**
2. **A denylist written by reflex is wrong by reflex.** The protected list had a clear stated
   criterion, and the entry that violated it was added anyway on name pattern-matching. The
   lesson is not "be careful" but "test each entry against the criterion".
3. **Approved verification targets are a constraint on the containment design.** D2 and D7
   interact: the containment must not forbid the operation the user approved for
   verification. Discovering that at implementation time, rather than after, was only
   possible because the verification sequence was specified in advance.
4. **Documenting what a protection does *not* guarantee is part of the protection.** D2's
   modification required stating the limitations, and doing so is what made the over-broad
   entry recognisable as a heuristic error rather than a mystery.

---

## What Worked Well

- **Read-only probing before implementation** — F1 alone saved ~2 MB per discovery cycle.
- **Specifying the verification sequence in advance (D7)** — surfaced the D2/D7 interaction
  during implementation instead of after.
- **The containment refusing rather than complying** — the failure was the containment
  working correctly on a bad rule, which made the root cause obvious.
- **Guard-first operations** — a refused operation issues zero device commands, verified by
  test.
- **Separate error semantics for `getprop` vs `pidof`** — tested independently so they cannot
  be conflated.
- **Injecting `AppOperationsProtocol`** — 33 mock-based tests with no device attached.

---

## What Did Not Work

- **Choosing protected packages by name pattern.** The criterion was stated and then not
  applied. Fixed by pinning each questionable entry with a test.
- **Relying on unit tests to validate a real-world denylist.** They cannot; the inputs come
  from the same assumptions as the rule.
- **Adding `AnyObject` to `AppOperationsProtocol`** — required a class conformer, but
  `ADBAppOperations` is a struct. `Sendable` was the correct constraint; fixed at build time.

---

## Best Technique Discovered

**Specify the verification sequence before designing the containment, then make the
containment and the verification agree.**

Why it worked: D7 named Settings as the target and D2 constrained the stop operation. Had the
verification sequence been invented after implementation, the over-broad protected entry would
have been discovered either much later or not at all — and the temptation would have been to
loosen verification rather than fix the rule. Because the sequence was approved up front, the
failure pointed unambiguously at the rule.

When to use it: any phase that both restricts an operation and must demonstrate it working.

When not to use it: read-only phases, where there is nothing to restrict.

**Second-best: test each entry of a rule against the rule's own stated criterion.** The
protected list had a criterion and a violating entry. A test per entry
(`testSettingsIsNotProtectedBecauseItIsNotDeviceCritical`) makes the criterion executable
rather than aspirational.

---

## Future Recommendations

1. **Phase 5 (RNZM-23)** adds `push()`/`pull()`. **File transfer introduces path handling —
   a new input-validation surface.** Package-name validation does not cover it; it needs its
   own review and its own ADR.
2. **Phase 8/9 must not expose `shell()`.** If the UI or Hermes needs a new capability, add a
   *named* operation. Revisit ADR-009 before any exposure.
3. **`DeviceOperation` must be extended in the same commit as each new operation.**
4. **Do not add `ps -A`** without an actual consumer and acquisition requirement (D4).
5. **Revisit the denylist** if a non-Google device is added; vendor system packages will not
   match these prefixes.
6. **The UI still does not call the operation wrappers.** `AppState` exposes them; wiring the
   UI is Phase 8.

---

## Phase Completion Record

```
PHASE STATUS: COMPLETE

Requirements:            PASS  (§16 capabilities implemented; D1-D7 honoured)
Build:                   PASS  (xcodebuild Debug — BUILD SUCCEEDED)
Tests:                   PASS  (106 executed, 0 failures; 4 integration skipped by design)
Device verification:     PASS  (approved sequence: launch Settings, verify, stop, verify)
Security review:         PASS  (§22 checklist; ADR-009 documents the model AND its limits)
Failure handling:        PASS  (guard-first; refused ops issue zero commands)
Regression:              PASS  (Phases 2 and 3 all pass)
Architecture review:     PASS  (ADR-009)
Documentation:           PASS  (phase log, ADR-009, test report, architecture/overview.md)
AI development log:      UPDATED
Known limitations:       DOCUMENTED
```

**Known limitations**

- **Containment is a denylist, not a security boundary.** It cannot be complete; a vendor
  system package with an unexpected name will not match. The real boundaries are the device's
  privilege posture (not rooted, not debuggable), the absence of upward `shell()` exposure,
  and the bounded blast radius. See ADR-009.
- **`shell()` exists below the operations layer** and can run anything. Containment is by
  non-exposure, not by making it safe.
- `DeviceOperation` must be extended by any future phase adding operations.
- `ps -A` / broad process inventory deliberately not implemented (D4).
- `InstalledApp.displayLabel` is a package-name fragment, **not** the application's real
  label; reading the real label needs `dumpsys package` (49 KB/app) or APK inspection.
- `isLikelySystemPackage` is a name heuristic and is not authoritative.
- `push()`/`pull()` remain Phase 5 (RNZM-23).
- The UI does not call the operation wrappers; wiring is Phase 8.
- Real-device verification requires the device to stay attached.

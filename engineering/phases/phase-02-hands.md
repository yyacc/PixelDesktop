# Phase 2 — "Hands"

**Date:** 2026-10-25
**ADR:** `engineering/decisions/ADR-019-input-injection-and-telemetry.md`
**Proposal:** `docs/PROPOSAL-DEVICE-INTERACTION.md` §8 (Phase 2 = B1 + A7)
**Gate:** rnz approval (2026-10-25) + ADR-019 — both satisfied.

---

## 1. What Phase 2 is

The proposal's §8 names two features:

| ID | Feature | Status |
|---|---|---|
| **B1** | Input injection, dry-run gated | **Implemented** |
| **A7** | Device telemetry + thermal history | **Implemented** |

The gate for this phase was "rnz approval + ADR". rnz authorised implementation directly; ADR-019
records the decisions. Nothing in this phase was built ahead of that authorisation.

---

## 2. New files

### Telemetry (A7)

| File | Role |
|---|---|
| `PixelDesktop/Perception/DeviceTelemetry.swift` | `ThermalStatus` (Android's 0–6 scale + ADR-018 threshold), `ThermalZone`, `BatteryTelemetry`, `MemoryTelemetry`, `StorageTelemetry`, `DeviceTelemetry`, `TelemetrySample`, `TelemetryHistory` |
| `PixelDesktop/Perception/TelemetryParser.swift` | Pure parsers for `dumpsys battery`, `dumpsys thermalservice`, `/proc/meminfo`, `df -k` |
| `PixelDesktop/Perception/DeviceTelemetryProtocol.swift` | The read-only seam |
| `PixelDesktop/Perception/ADBDeviceTelemetry.swift` | Four fixed commands, read in parallel, assembled |

### Input (B1)

| File | Role |
|---|---|
| `PixelDesktop/Operations/DeviceInput.swift` | `InputActionKind`, `ResolvedTarget`, `InputActionPlan` (the gate), `InputRefusal`, `InputActionResult`, `InputContainment` |
| `PixelDesktop/Operations/DeviceInputProtocol.swift` | Plan/execute seam — no coordinate API |
| `PixelDesktop/Operations/ADBDeviceInput.swift` | Command construction + gate enforcement + audit |
| `PixelDesktop/Operations/InputAuditLog.swift` | Bounded, persisted D2 trail |

### UI

| File | Role |
|---|---|
| `PixelDesktop/App/TelemetryView.swift` | Live readings, alert banner, thermal sparkline |
| `PixelDesktop/App/InputView.swift` | Propose → preview → confirm, candidates, audit trail |

`AppState` gained the telemetry poll loop and the input proposal/confirmation wrappers.
`ContentView` gained two tabs (`Telemetry`, `Input`).

---

## 3. The three claims, and where each is enforced

| Proposal requirement (§6.2) | Enforcement point |
|---|---|
| Dry-run before execution | `InputActionPlan.confirmed` is `let`; `confirming()` is the only promotion; `execute` throws `planNotConfirmed` **before** building a command |
| Element-addressed, not coordinate-addressed | No `(x, y)` parameter exists anywhere in the protocol or UI; centres derive from `UIElementBounds` |
| Per-action audit (D2) | `InputAuditLog` — every execution, refusal, and failure, persisted by default |

Ambiguity refuses rather than guesses: `targetAmbiguous(candidates:)` lists the matches and the
user disambiguates by element index.

---

## 4. Real-device verification

`Phase2HardwareVerificationTests` runs against the attached Pixel 7a (auto-discovered via
`ADBTransport.listDevices()`; `PIXELDESKTOP_DEVICE_SERIAL` overrides).

| Test | Result |
|---|---|
| `testTelemetryReadsEverySourceFromRealDevice` | **passed** — all four sources parsed, values inside plausibility bounds |
| `testThermalAlertFlagAgreesWithTheReportedStatus` | **passed** |
| `testUnconfirmedPlanIsRefusedAgainstARealHierarchy` | **passed** — plan resolved from a real dump; execution refused; audited |
| `testConfirmedKeyEventExecutesOnRealDevice` | **passed** — `KEYCODE_WAKEUP`, exit 0 |
| `testQuotedTextIsDeliveredLiterally` | **passed** — `$(id)` arrived as text, no `uid=` in output |

Measured device state at verification time:

```
Thermal Status: 0
LITTLE 67.0 °C · BIG 74.0 °C · MID 66.0 °C · G3D 56.0 °C · TPU 56.0 °C
battery: level 100, status 5 (full), 4287 mV, 34.3 °C
MemTotal 7,626,016 kB · MemAvailable 2,468,092 kB
/data: 115,249,236 KiB total, 75,646,588 KiB used
```

**Worth recording:** the overall thermal status is `0 (none)` while BIG reads **74 °C**. That is
exactly why the history tracks the hottest zone as well as the status — a status-only dashboard
would report this device as cool.

---

## 5. Suite

```
Executed 715 tests, with 26 tests skipped and 0 failures
```

Baseline before this phase was 665. Phase 2 adds 50:

- `Phase2TelemetryTests` — 25 (parsers, threshold, history, ADB assembly)
- `Phase2InputTests` — 20 (gate, element addressing, containment, audit)
- `Phase2HardwareVerificationTests` — 5 (real device)

The 26 skipped are pre-existing device-gated tests from Phases 2–9.

---

## 6. Defects found and fixed during the phase

1. **`ThermalStatus` was not `Codable`** — `TelemetrySample: Codable` failed to synthesize. Fixed
   by conforming the enum.
2. **Empty stdout was treated as an answer.** A `dumpsys thermalservice` that exits 0 and prints
   nothing was indistinguishable from one that printed a reshaped body, so the parse-failure
   guard fired on silence. Fixed by folding empty output into "did not answer" — silence and a
   reshaped body need different responses.
3. **`XCTAssertEqual(…, .none)` on an `Optional<ThermalStatus>` compared against `nil`.** Bare
   `.none` resolves to `Optional.none`, not `ThermalStatus.none`. Test bug, not parser bug; the
   assertion now spells the case out.
4. **The hardware harness silently skipped with the phone attached.** `xcodebuild` does not
   forward the shell environment to the test host, so `PIXELDESKTOP_DEVICE_SERIAL` never arrived.
   Fixed by discovering the device through `ADBTransport.listDevices()` — which also avoids
   restating the adb binary path in a second place.

---

## 7. What this phase does not do

- **No swipe or drag.** A gesture has a start, an end and a duration, all chosen blind.
- **No coordinate entry**, in the protocol or the UI.
- **No telemetry persistence.** History is in-memory (600 samples ≈ 100 min at 10 s); the audit
  log is the persisted artifact. Cross-launch thermal history needs a retention policy this phase
  does not have.
- **No thermal intervention.** ADR-018: the phone throttles and that is accepted. Telemetry
  observes and alerts only.
- **Polling is manual.** The view reads once on appearance; the user starts the loop.

---

## 8. Also in this pass (Phase 1 follow-up)

The Phase 1 §1 unblock — Termux's "Allow external apps to run commands" — was set on the device
(`~/.termux/termux.properties` now carries `allow-external-apps=true`). It is **necessary but not
sufficient**: `RunCommandService` still refuses with `Requires permission
com.termux.permission.RUN_COMMAND`, which `com.android.shell` cannot hold (it does not declare it,
and `pm grant` to a package without the permission is a silent no-op).

So **Phase 1's `start`/`stop` remain blocked**, exactly as the Phase 1 handoff recorded. The
setting is now correct for any future *app* that declares the permission; it does not create a
headless channel for `adb`.

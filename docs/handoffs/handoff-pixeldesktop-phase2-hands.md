# Handoff — PixelDesktop Phase 2 ("Hands")

**Date:** 2026-10-25 · **Commit:** `03ce45b` · **Suite:** 715 tests, 26 skipped, 0 failures
**ADR:** `engineering/decisions/ADR-019-input-injection-and-telemetry.md`
**Phase record:** `engineering/phases/phase-02-hands.md`

---

## State

Phase 2 is **complete and verified on hardware**. B1 (input injection) and A7 (telemetry) are
both implemented, tested, and exercised against the attached Pixel 7a.

The proposal's §8 table now marks Phase 2 done. Phase 3 ("Durability") is next and remains
**ungated** — it needs rnz approval.

---

## What shipped

**B1 — input injection**, behind a gate that is structural rather than documented:

- `InputActionPlan.confirmed` is `let`. `confirming()` is the only promotion. `execute` refuses
  an unconfirmed plan *before building a command*, so a refusal issues zero device commands.
- No coordinate API exists. Taps resolve a `UIElement` from a `UIHierarchy`; the centre comes
  from the device's reported bounds. Ambiguity refuses with a candidate list.
- Text is shell single-quoted (spaces → `%s`), so `$(id)` arrives literally while a password
  containing `$` still works. Key events use an allowlist — they are platform vocabulary, not
  user content.
- `InputAuditLog` persists every execution, refusal and failure to Application Support.

**A7 — telemetry**, read-only:

- Four fixed commands in parallel. A failed source leaves its field `nil` ("not read"), never
  zero.
- `ThermalStatus.alertThreshold = .critical` (ADR-018) has production readers — `TelemetryHistory`
  filters on it and `TelemetryView` renders the banner.
- Bounded 600-sample history with peak status, peak zone, alert count, and a sparkline.

**UI:** two new tabs — `Telemetry` and `Input`.

---

## Verified on hardware

`Phase2HardwareVerificationTests`, auto-discovering the device via `ADBTransport.listDevices()`:

```
testTelemetryReadsEverySourceFromRealDevice          passed
testThermalAlertFlagAgreesWithTheReportedStatus      passed
testUnconfirmedPlanIsRefusedAgainstARealHierarchy    passed
testConfirmedKeyEventExecutesOnRealDevice            passed
testQuotedTextIsDeliveredLiterally                   passed
```

Measured at verification time — **and this is the finding worth carrying forward**:

```
Thermal Status: 0 (none)
BIG 74.0 °C · LITTLE 67.0 °C · MID 66.0 °C · G3D 56.0 °C · TPU 56.0 °C
```

The overall status reads **`none`** while a core sits at **74 °C**. A status-only thermal
dashboard would call this device cool. This is why the history tracks `hottestZoneCelsius`
alongside the status, and why the alert threshold alone is not a thermal picture.

---

## Pitfalls hit (worth not rediscovering)

1. **`xcodebuild` does not forward the shell environment to the test host.** Exporting
   `PIXELDESKTOP_DEVICE_SERIAL` had no effect — all five hardware tests skipped with the phone
   attached. Discovery now goes through `ADBTransport.listDevices()`, which also avoids restating
   the adb binary path in a second place.

2. **`xcodebuild build` does not compile the test target.** It reports `BUILD SUCCEEDED` without
   touching `*Tests.swift`. Use `build-for-testing` (or `test`) and confirm the file's own
   `SwiftCompile` line appears — a success with no such line proves nothing.

3. **Bare `.none` on an `Optional<ThermalStatus>` is `Optional.none`, not `ThermalStatus.none`.**
   An assertion compared against `nil` and failed against a correct parser. Spell the case out.

4. **Exit 0 with empty stdout is not an answer.** Treating it as one made a silent
   `dumpsys thermalservice` indistinguishable from a reshaped one. Silence and a reshape need
   different responses.

5. **`dumpsys battery` reports `temperature` in tenths of a degree** — 343 is 34.3 °C.

6. **Background test notifications are snapshots, not verdicts.** Four notifications arrived from
   runs that caught a file mid-edit; each reported a real compile error against a tree that no
   longer existed. Check the `.xcresult` timestamp against the file mtime and the last commit
   before acting.

---

## Phase 1 status (unchanged, and now explained)

The Termux setting **is now on** — `~/.termux/termux.properties` carries
`allow-external-apps=true`, set via the interactive channel (push a script to
`/data/local/tmp`, type its path, 3 s settle before typing).

It is **necessary but not sufficient**. `RunCommandService` still answers:

```
Error: Requires permission com.termux.permission.RUN_COMMAND
```

`com.android.shell` does not declare that permission, and `pm grant` to a package that does not
declare it is a silent no-op. So:

- **Phase 1 `start`/`stop` remain blocked.** Documented, not a code defect.
- The setting is correct for any future *app* that declares the permission.
- `status`, `healthCheck`, and the C2 inference path all still work.

---

## Next

**Phase 3 — "Durability"** (proposal §8): A5 notifications · C4 scheduled tasks · C3 remote shell
(needs its own ADR — it is a genuine expansion of the ADR-009 shell boundary) · B4/B5 · D1–D4.
**Ungated — needs rnz approval.**

Open, smaller items:

- Telemetry history is in-memory only. Cross-launch retention needs a policy.
- Polling is manual by default; a background poll would need a cadence decision.
- B1 is a maintenance tool. Daily operation should stay headless (A4 + B3 + B2).

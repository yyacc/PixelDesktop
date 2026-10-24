# ADR-019: Input Injection (Phase 2 B1) and Telemetry (A7)

**Status:** Accepted
**Date:** 2026-10-25
**Relates to:** `docs/PROPOSAL-DEVICE-INTERACTION.md` §6.2 (B1 definition and gate), §8 (Phase 2),
§10 (success criterion 5), ADR-009 (shell containment), ADR-018 (thermal policy), ADR-015 (AppState↔UI bridge)

**Owner decision recorded 2026-10-25:** rnz authorised Phase 2 implementation directly —
*"Implement phase 2. Do not stop until you're done."* The proposal's gate for Phase 2 is
"rnz approval + ADR"; this document is the ADR half of that gate.

---

## 1. Context

Phase 2 is **"Hands"**: B1 input injection and A7 telemetry. Two facts shape both.

**The panel is physically dead; the framebuffer renders.** `screencap` and `uiautomator dump`
work, so perception is solved. Input is not: `adb shell input` injects at the framework
(`InputManager`) layer rather than through the digitizer, so it works on this device — and it
also means every injected action is *unobservable* at the point of execution. A tap has no
confirmation loop when nothing displays.

**`dumpsys` is not a stable API.** Output varies by Android version, OEM, and in places by
build. Anything that parses it is the part most likely to break, so the parsers are isolated and
pinned by fixture rather than trusted.

---

## 2. Decision — B1: the gate is structural

Input injection ships, and the three requirements the proposal named are enforced rather than
documented:

| Requirement (proposal §6.2) | Enforcement |
|---|---|
| Dry-run mode — show what will be tapped, do nothing until confirmed | `InputActionPlan.confirmed` is `let`. The only way to obtain a confirmed plan is `confirming()`. `execute` throws `InputRefusal.planNotConfirmed` otherwise, **before any command is built**. Pinned by `testUnconfirmedPlanIsRefusedAndNothingReachesTheDevice`, which also asserts zero transport invocations. |
| Element-addressed, not coordinate-addressed | `DeviceInputProtocol` has no method taking `(x, y)`. Plans resolve a `UIElement` out of a `UIHierarchy`; the centre comes from the device's own reported bounds. Raw `input tap x y` is not reachable from the UI. |
| Per-action audit record (D2) | `InputAuditLog` records every execution, every refusal, and every failure with the resolved label, resource-id, centre and command. Persisted to Application Support by default. |

### 2.1 Ambiguity is a refusal, not a guess

A query matching more than one interactive element throws
`InputRefusal.targetAmbiguous(candidates:)` rather than tapping the first. A preview of an
undetermined target is not a preview. The UI renders the candidates and the user disambiguates
by element index — `planTap(hierarchy:elementIndex:)` is the only path that accepts one.

The refusal vocabulary distinguishes *nothing matched* (`targetNotFound`) from *matched
something untappable* (`targetNotInteractive`), because those are different mistakes with
different fixes.

### 2.2 Containment is quoting, not an allowlist

`input text` is the one place caller-supplied text reaches the device shell.

An allowlist of "safe" characters is the obvious answer and it is wrong: it silently mangles a
password containing `$` or a URL containing `&`, and the user cannot distinguish a rejected
character from a typo. Instead the payload is **single-quoted for `sh`**, which suppresses all
expansion (`$`, backticks, globs, `~`, `;`, `|`, `&`, redirection), with embedded quotes closed
and re-opened (`'\''`). Spaces become `%s`, which is `input text`'s own encoding.

Rejected outright: empty text, embedded line breaks (`input text` cannot deliver them, and a
silently truncated string is a different command), and payloads over 512 characters.

Key events use an allowlist, and that asymmetry is deliberate: key names are a fixed platform
vocabulary, not user content, so anything outside it is a programming error rather than input
the user meant.

### 2.3 What B1 deliberately does not do

- **No swipe or drag.** A gesture has a start, an end and a duration, all chosen blind. A tap on
  a named element is reviewable; a blind gesture is not.
- **No coordinate entry.** Not in the protocol, not in the UI.
- **Not in the default flow.** B1 is a maintenance tool for screens with no headless equivalent
  (permission dialogs, the setup wizard, Developer Options). Daily operation is headless.

---

## 3. Decision — A7: observe and alert, do not intervene

ADR-018 decided the phone throttles and rnz accepts it. So telemetry is **read-only**: no thermal
policy setter, no CPU-governor control, no battery-saver toggle.

| Source | Command | Fields |
|---|---|---|
| Battery | `dumpsys battery` | level, status, temperature (**tenths of °C**), voltage |
| Thermal | `dumpsys thermalservice` | `Thermal Status` (0–6), `Temperature{...}` zones |
| Memory | `cat /proc/meminfo` | `MemTotal`, `MemAvailable` |
| Storage | `df -k /data` | used, total |

**The alert threshold is `ThermalStatus >= .critical` (4)**, per ADR-018. It is a named constant
(`ThermalStatus.alertThreshold`) read by `TelemetryHistory.thermalAlerts` and `latestAlert`, which
`TelemetryView` renders as the banner — so the contract has production readers rather than being
a declaration nobody consults.

### 3.1 Partial reads are reported as partial

The four sources are read in parallel and assembled. A source that fails or does not parse
leaves its field `nil` while the rest of the sample is returned — a device that will not answer
`dumpsys thermalservice` still has a readable battery. `nil` renders as "not read", never as
zero: a missing thermal reading must not look like a cool phone.

Two cases are *not* partial, and throw `verificationFailed` instead:

- **Every** source silent. Returning an all-`nil` sample would render as "nothing to report" —
  the opposite of the truth.
- The thermal service answered but `Thermal Status` did not parse. The alert path depends on
  that number, so an unrecognisable value is a parser defect that must surface.

### 3.2 Empty output is not an answer

Exit code 0 with empty stdout is folded into "did not answer". This is the distinction between
*silence* (a source that did not run) and a *reshaped body* (a parser that needs updating); the
two need different responses and would otherwise be indistinguishable. Found by a test — the
first implementation treated empty output as an answer and threw on it.

### 3.3 Temperature units

`dumpsys battery` reports `temperature` in **tenths of a degree** — 307 is 30.7 °C. Reading it as
whole degrees would report a hot battery as 307 °C. Pinned by
`testBatteryTemperatureIsTenthsOfADegree`.

---

## 4. Consequences

**Good**

- The gate is a type-level property, so a caller cannot skip the preview by accident — there is
  no combined plan-and-execute method.
- Audit records survive the session and are human-readable, so a blind tap is reconstructable.
- Telemetry history is bounded (600 samples ≈ 100 minutes at a 10 s cadence), so an unattended
  poll cannot grow memory without limit.
- Parsers are pure and fixture-tested, which is the cheapest place to absorb a `dumpsys` change.

**Costs and limits**

- **A fixture is not a device.** The parsers are pinned against measured Pixel 7a shapes, but a
  platform update can reshape output and the suite will still pass. Real-device verification is
  a separate step and is recorded in the Phase 2 handoff.
- **A unit test cannot prove a tap landed where intended.** It can prove the command is
  well-formed and the gate holds. Where the tap goes is verified on hardware.
- **Polling is manual by default.** The view reads once on appearance; the user starts the loop.
  Polling by default would issue four ADB calls every 10 s whether or not anyone is looking.
- **No persistence for telemetry history.** It is in-memory only; the audit log is the persisted
  artifact. Retaining thermal history across launches would need a retention policy this phase
  does not have.

---

## 5. Verification

| Claim | Evidence |
|---|---|
| Unconfirmed plans cannot execute | `Phase2InputTests.testUnconfirmedPlanIsRefusedAndNothingReachesTheDevice` (asserts zero transport invocations) |
| Taps are element-addressed | `testTapResolvesTheElementCentre`, `testDisambiguationByElementIndex` |
| Ambiguity refuses | `testAmbiguousQueryIsRefusedWithCandidates` |
| Text cannot inject shell | `testTextIsSingleQuotedSoTheShellCannotExpandIt`, `testEmbeddedSingleQuoteIsClosedAndReopened` |
| Alert threshold is CRITICAL | `Phase2TelemetryTests.testAlertThresholdIsCriticalAndAbove` |
| Partial reads stay partial | `testReadAssemblesPartialSampleWhenOnlyBatteryAnswers` |
| All-silent read fails loudly | `testReadThrowsWhenEverySourceFails` |
| Battery temperature is tenths | `testBatteryTemperatureIsTenthsOfADegree` |
| Audit persists | `testAuditLogPersistsAndReloads` |

44 tests across `Phase2TelemetryTests` (24) and `Phase2InputTests` (20).

# Phase 4 Proposal — Android Application / Process Control

**Status:** PROPOSAL — awaiting review. **No source code modified.**
**Phase:** 4 (Android Application / Process Control) — authoritative per [ADR-007](../decisions/ADR-007-authoritative-phase-sequence.md)
**Date:** 2026-10-01
**Depends on:** Phase 3 (Android Device Model) — COMPLETE
**Covers:** RNZM-21 (`shell()`), RNZM-22 (lifecycle), and the phase's core subject

---

## 1. Scope

Master prompt §16 Phase 4, verbatim:

> Implement controlled Android application operations. Potential capabilities include:
> discovering applications · identifying launchable applications · launching applications ·
> monitoring application state · stopping applications where appropriate · querying
> activity/process information. Use documented Android/ADB capabilities.
> Do not: modify third-party APKs · inject code · bypass security · bypass anti-cheat
> systems · perform destructive operations. Every capability must be tested against the
> real Pixel 7a.

Governing constraints: §22 (security) · §5.2 (smallest correct architecture) ·
§5.3 (existing technology first) · §31 (do not rush phases).

**This is the most security-sensitive phase so far.** Phase 2 and 3 only *read* from the
device. Phase 4 *acts* on it.

---

## 2. Real-Device Probe (read-only, completed)

All probing was read-only. **No application was launched, stopped, or modified.**

| # | Probe | Result | Design impact |
|---|---|---|---|
| 1 | `pm list packages` | **364** packages | Full list is large; filter matters |
| 2 | `pm list packages -3` | **41** third-party packages | Default scope should be third-party |
| 3 | `cmd package query-activities --brief -a MAIN -c LAUNCHER` | **58 launchable activities**, exit 0 | Single call gives the whole launchable set |
| 4 | `pidof com.android.settings` | `2615`, **exit 0** | Running-state query |
| 5 | `pidof com.mojang.minecraftpe` (not running) | empty, **exit 1** | **Exit code is meaningful here** |
| 6 | `ps -A` | 556 lines, exit 0 | Parseable; `NAME` is the last column |
| 7 | `dumpsys activity activities` | 24,223 bytes | Heavy |
| 8 | `dumpsys activity processes` | 49,893 bytes | Heavy |
| 9 | `dumpsys package <pkg>` | **49,893 bytes / 633 lines** | **Avoid per-app** |
| 10 | `resolve-activity --brief <non-launchable>` | `No activity found`, **exit 0** | Output-based detection, not exit code |
| 11 | `which monkey` | `/system/bin/monkey` | Available fallback launcher |
| 12 | `am force-stop` (no args) | exit **255** + Java exception | `am` errors are exit 255 |
| 13 | **`which su`** | **empty** | **No root shell available** |
| 14 | **`getprop ro.debuggable`** | **`0`** | **Device is not debuggable** |

### Findings that changed the design

**F1 — `dumpsys package` must not be used per application.** Resolving one package's launch
activity that way costs **49,893 bytes**. Resolving 41 packages that way would be ~2 MB. The
single `query-activities` call already returns the full launchable set (58 entries), so
per-app resolution is unnecessary. This is the single largest efficiency decision in the
phase.

**F2 — `pidof` exit codes are meaningful, unlike `getprop`.** `getprop` exits 0 for an unset
key (established in Phase 2), so absence is output-detected. `pidof` exits **1** for a
non-running package. The two must not share error handling.

**F3 — `resolve-activity` exits 0 even when nothing is found.** Detection must parse the
output (`No activity found`), not the exit code.

**F4 — The device is not rooted and not debuggable** (`su` absent, `ro.debuggable=0`). No
privilege escalation is available through ADB on this device. This bounds the blast radius
of `shell()` and is direct evidence for the security review.

**F5 — `--brief` does not actually shorten `query-activities`** (still 175 lines). The
activity components are nevertheless cleanly parseable: 58 lines matching `<pkg>/<activity>`,
no duplicates.

---

## 3. Current State

`TransportProtocol` has `execute`, `listDevices`, `getprop`, `getSystemProperties`.
There is **no** `shell()`, no file transfer, and **no operations layer at all**.

`DeviceOperation` currently lists `.discover` and `.readSystemProperties` — deliberately only
what is implemented.

---

## 4. Proposed Changes

### 4.1 `shell()` — transport primitive (RNZM-21)

```swift
func shell(deviceSerial: String, command: String, timeout: TimeInterval) async throws -> TransportResult
```

Issues `adb -s <serial> shell <command>` through the existing `execute()` path.

**Security position — this is the riskiest addition in the project so far.** A
general-purpose shell is an escape hatch. The design contains it:

- `shell()` lives **only** on `TransportProtocol`. It is a transport capability, not an
  application-facing one.
- The operations layer (§4.3) exposes **named operations only**. It never takes a
  caller-supplied command string.
- No UI, and no Hermes integration, exposes raw `shell()` to a user. Phase 8/9 must not
  either without its own review.
- Master prompt §22 forbids "arbitrary code injection". A shell primitive that only ever
  receives fixed, reviewed command strings from the operations layer does not violate that.
  Exposing it outward would.

**Alternative considered:** skip `shell()` and give `ADBTransport` one method per Android
command (`listPackages()`, `launch()`, …). Rejected — it would put Android application
semantics into the transport, which ADR-005 and Phase 2 deliberately kept out. `shell()` is
the right primitive; the containment is at the layer above.

### 4.2 New operations layer — `PixelDesktop/Operations/`

Master prompt §16 requires device *operations* to be separated from discovery and
representation. Phase 3 explicitly deferred creating this layer until there was something
real to put behind it. There now is.

```
PixelDesktop/Operations/
├── AppOperationsProtocol.swift   the seam (mockable, like TransportProtocol)
└── ADBAppOperations.swift        implementation over TransportProtocol
```

`AppOperationsProtocol`:

| Method | Android command | Purpose |
|---|---|---|
| `installedApplications(includeSystem:timeout:)` | `pm list packages [-3]` | Discovering applications |
| `launchableApplications(timeout:)` | `cmd package query-activities …` | Identifying launchable applications |
| `launchApplication(packageName:timeout:)` | `am start -n <pkg>/<activity>` | Launching applications |
| `isApplicationRunning(packageName:timeout:)` | `pidof <pkg>` | Monitoring application state |
| `stopApplication(packageName:timeout:)` | `am force-stop <pkg>` | Stopping applications |

**Not proposed:** `runningProcesses()` via `ps -A`. Master prompt lists "querying
activity/process information", but `pidof` already answers the question any consumer
actually has ("is this app running"), and `ps -A` parsing is 556 lines of kernel threads and
system processes with no consumer in this phase. **Flagging this as the one listed
capability I recommend deferring** — see Decision D4.

### 4.3 Application model

New `InstalledApp` in `Core/Models/`:

| Field | Type | Source | Static? | Why |
|---|---|---|---|---|
| `packageName` | `String` | `pm list packages` | Static | Identity |
| `launchActivity` | `String?` | `query-activities` | Static | `nil` when not launchable |

`isLaunchable` is derived (`launchActivity != nil`). Deliberately minimal: no icons, no
version strings, no install size, no permissions. Those have no consumer in Phase 4.

**Running state is not a field on `InstalledApp`.** It is dynamic and belongs to a query
(`isApplicationRunning`), not to app identity. Putting it on the model would make a static
representation hold a live value.

### 4.4 `DeviceOperation` extension

Extend the Phase 3 enum with exactly the operations Phase 4 implements:

`.discover` · `.readSystemProperties` · `.listApplications` · `.launchApplication` ·
`.queryApplicationState` · `.stopApplication`

The enum must be extended in the same commit that implements each operation, so it never
advertises something that does not exist.

### 4.5 Connection lifecycle (RNZM-22)

Proposed scope:

| Concern | Behaviour |
|---|---|
| Disconnect while a device is known | Detected on next discovery refresh; `state` becomes absent/offline; operations on it fail with `deviceNotFound`/`deviceOffline` **before** issuing a command |
| Reconnect | Device reappears in discovery; state returns to `device` |
| Unauthorized → authorized | Already modelled as `DeviceState`; transitions surface through discovery |
| **Do enriched properties survive a reconnect?** | **Open decision D3** |

**Guard-first principle:** every operation checks `device.state == .device` *before*
issuing a command, so a stale device fails predictably instead of hanging. This mirrors
`DeviceEnricher`, which already guards.

**On caching (D3):** Phase 3 deliberately does not cache enriched properties.
`androidVersion`/`apiLevel`/`architecture` are constant for a boot session but **can** change
across a reboot or OS update, so a reconnect is exactly when a cache could go stale. My
recommendation: **do not cache in Phase 4**; re-enrich on demand. Simpler, and no staleness
bug is possible. Record the decision in an ADR either way, as RNZM-22 requires.

### 4.6 `stopApplication` — the destructive-capable operation

`am force-stop` kills an app and discards its unsaved state. Master prompt says "stopping
applications **where appropriate**". Proposed containment:

- Requires an **explicit, non-empty package name**. No "stop everything".
- **Refuses to stop a system package** (`com.android.*`, `com.google.android.*` core
  packages) unless explicitly overridden. Stopping SystemUI or the launcher would disrupt
  the device.
- Refuses to stop the PixelDesktop worker package (Phase 5) — a self-inflicted kill.
- Never stops by pattern or wildcard.
- Returns the `TransportResult` so the caller can distinguish "stopped" from "was not
  running".

**Decision D2 asks you to confirm this containment.**

### 4.7 Error model

| Situation | Mapping |
|---|---|
| `shell()` non-zero exit | `adbCommandFailed` (new: exit 255 for `am` errors, see F5) |
| `pidof` exit 1 (not running) | **Not an error** — returns `false`. Deliberate: "not running" is a valid answer |
| `resolve-activity` finds nothing | Not an error — `launchActivity == nil` |
| Operation on non-connected device | `deviceOffline` / `deviceNotFound`, raised **before** any command |
| `stopApplication` on a protected package | `invalidInput` with the reason |

No new `PixelDesktopError` cases required.

### 4.8 Explicitly NOT doing in Phase 4

- No `push()` / `pull()` — Phase 5 (RNZM-23)
- No APK install, modification, or inspection
- No `run-as`, no `su`, no root escalation (none is available — F4)
- No `dumpsys package` per-app parsing (F1)
- No `ps -A` parsing unless D4 is approved
- No app icons, versions, permissions, or sizes
- No UI work — Phase 8
- No scrcpy/video
- No shell exposure to UI or Hermes

---

## 5. Tests Required

### Hermetic (mock-based) — the regression gate

| Test | Asserts |
|---|---|
| `parsePackageList` | `package:a` lines → names; handles empty, malformed, trailing whitespace |
| `parseLaunchableActivities` | 58-entry real shape → `[String: String]`; no duplicates; ignores header/priority lines |
| `parsePID` | numeric → `Int`; empty → `nil` |
| `installedApplications` | Third-party by default; `includeSystem: true` uses the right command |
| `launchApplication` | Correct `am start -n pkg/activity` argv; **non-launchable app rejected before any command** |
| `isApplicationRunning` | `pidof` exit 1 → `false`, **not** an error |
| `stopApplication` | Correct argv; **refuses system packages**; **refuses empty name**; **refuses worker package** |
| `shell()` | Correct argv; non-zero exit → `adbCommandFailed` |
| Guard-first | Every operation on an `.offline` device issues **zero** commands |
| `DeviceOperation` | Enum equals exactly the implemented set |
| Real captured output | Full pipeline over the Pixel 7a's real `package`/`query-activities` output |

### Real-device (opt-in)

| Test | Asserts |
|---|---|
| `shell()` | Real command returns real output |
| Discover apps | Non-empty; third-party count plausible; all names well-formed |
| Launchable set | Non-empty; every entry has a `/` component; subset of installed |
| Launch + verify | Launch a **benign** app (Settings), confirm `pidof` reports it running |
| Stop + verify | Stop the same app, confirm `pidof` no longer reports it |
| Guard | Operation on a bogus serial fails cleanly |

**Launch/stop verification must use a benign, user-visible app (Settings).** No user data is
at risk and the effect is trivially reversible. This will be stated explicitly in the phase
log.

---

## 6. Real-Device Verification Required

| # | Verification | Status |
|---|---|---|
| 1 | Read-only capability probe | **DONE** (§2) |
| 2 | `shell()` executes a real command | Pending implementation |
| 3 | App discovery returns real packages | Pending |
| 4 | Launchable set matches `query-activities` | Pending |
| 5 | **Launch a benign app and confirm it is running** | Pending |
| 6 | **Stop that app and confirm it is no longer running** | Pending |
| 7 | Guard-first behaviour on a disconnected device | Pending |
| 8 | Cross-check values against raw `adb` | Pending |

---

## 7. Decisions Requiring Your Approval

| # | Decision | Recommendation |
|---|---|---|
| **D1** | Add `shell()` to `TransportProtocol`, contained to the operations layer | **Approve.** Transport primitive; no outward exposure. |
| **D2** | `stopApplication` containment: explicit package, refuse system packages, refuse worker package, no wildcards | **Approve.** `force-stop` is the one destructive-capable operation. |
| **D3** | Do **not** cache enriched properties across reconnect; re-enrich on demand | **Approve.** Avoids a staleness bug entirely. |
| **D4** | **Defer `ps -A` / `runningProcesses()`**; `pidof` covers the actual need | **Approve deferral.** No consumer; 556 lines to parse. |
| **D5** | New `Operations/` layer with `AppOperationsProtocol` + `ADBAppOperations` | **Approve.** Required by §16's operations/discovery/representation separation. |
| **D6** | Phase 4 covers `shell()` + app operations + lifecycle in one phase, implemented in that order | **Approve.** Or split lifecycle (RNZM-22) into its own phase if you prefer. |
| **D7** | Launch/stop verification uses Settings as the benign test app | **Approve.** Reversible, no user data at risk. |

---

## 8. Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| `shell()` becomes an injection vector | Medium | **High** | Transport-only; operations layer exposes named ops only; no UI/Hermes exposure; recorded in ADR |
| `force-stop` disrupts the device (SystemUI/launcher) | Medium | High | Refuse system packages (D2) |
| `force-stop` on a package with unsaved user state | Medium | Medium | Explicit package required; no wildcards; benign test app only |
| Per-app `dumpsys` makes operations ~2 MB slow | High if unmitigated | Medium | Single `query-activities` call (F1) |
| Confusing `getprop` (exit 0) and `pidof` (exit 1) semantics | Medium | Medium | Separate error handling; explicit tests for both |
| `query-activities` output format changes across Android versions | Low | Medium | Parser fixture-driven; real output retained as a test |
| Phase 4 scope is large (3 deliverables) | Medium | Medium | Implemented in order; D6 offers a split |

---

## 9. Phase 4 Completion Gate (planned)

```
Requirements:        §16 Phase 4 capabilities, each with a named operation
Build:               xcodebuild Debug
Tests:               hermetic suite green; real-device tests pass
Device verification: shell, discover, launchable set, launch, stop — all on the real Pixel
Security review:     §22 checklist; shell containment; force-stop containment
Failure handling:    non-connected guard; non-launchable reject; protected-package reject
Regression:          Phases 2 and 3 tests all pass
Architecture review: ADR for the operations layer + shell containment + lifecycle decision
Documentation:       phase log, architecture/overview.md, security notes
AI development log:  updated
Known limitations:   documented
```

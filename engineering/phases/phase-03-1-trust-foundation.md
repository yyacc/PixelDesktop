# Phase 3.1 — Trust foundation (D1 · D2 · D3)

**Date:** 2026-10-25
**ADR:** `engineering/decisions/ADR-020-trust-foundation.md`
**Proposal:** `docs/PROPOSAL-PHASE-3-DURABILITY.md` §5.1–5.3, §6 (sub-phase 3.1)
**Gate:** rnz opened the Phase 3 gate (2026-10-25) — *"read for context and proceed with the
implementation"* — with the proposal's §7.2 recommendations taken as given (Q1a–Q5a). ADR-020 records
both halves.

**Baseline:** `e3c9579` / handoff `52a3218` — **715 tests, 26 skipped, 0 failures**.
**Result:** **746 tests, 26 skipped, 0 failures** (+31, all new; no new skips).

---

## 1. What this sub-phase is

The proposal orders Phase 3 as **trust first**, because A5 reads private message bodies and B4/B5
destroy state, and neither may ship before the consent gate and the dry run exist. 3.1 is that gate
layer and nothing else: no notifications are read, no app is installed, no device is rebooted.

| ID | Feature | Status |
|---|---|---|
| **D1** | Consent registry | **Implemented** |
| **D2** | Command audit log (generalised) | **Implemented** — replaces the Phase 2 input-only log |
| **D3** | Universal dry run | **Implemented** — B1 joins the shared vocabulary |

---

## 2. New and changed files

| File | Change | Role |
|---|---|---|
| `PixelDesktop/Trust/ConsentRegistry.swift` | **new** | `ConsentDataClass`, `ConsentGrant`, `ConsentError`, `ConsentPermit`, `ConsentRegistry`, `ConsentGate` |
| `PixelDesktop/Trust/DryRun.swift` | **new** | `DestructiveOperation`, `DryRunReport`, `DryRunError`, `DestructiveActionPlan` (the gate) |
| `PixelDesktop/Audit/DeviceAuditLog.swift` | **new** | `DeviceOperationKind`, `DeviceAuditOutcome`, `InputAuditContext`, `DeviceAuditRecord`, `DeviceAuditLog` |
| `PixelDesktop/Operations/InputAuditLog.swift` | **deleted** | Superseded — input is now a filter over the shared trail |
| `PixelDesktop/Operations/ADBDeviceInput.swift` | changed | Writes `begin`/`resolve` records; adds `dryRunReport(for:)` |
| `PixelDesktop/App/TrustView.swift` | **new** | The trust surface: consent toggles + the generalised trail |
| `PixelDesktop/App/AppState.swift` | changed | `deviceAuditLog`, `consentRegistry`, published snapshots, grant/revoke |
| `PixelDesktop/App/InputView.swift` | changed | Renders `DeviceAuditRecord` (input projection) |
| `PixelDesktop/App/ContentView.swift` | changed | `trust` tab; keyboard-shortcut fix (see §5) |
| `PixelDesktopTests/Phase3TrustFoundationTests.swift` | **new** | 31 tests |
| `PixelDesktopTests/Phase2InputTests.swift`, `Phase2HardwareVerificationTests.swift` | changed | Renamed types; assertions moved to the input projection |

---

## 3. What each primitive enforces

### D1 — consent, default deny

- `permit(for:)` throws `consentRequired` unless an **active** grant exists. `isActive` is
  `granted && revokedAt == nil`, so a revoke wins over a stale `granted == true`.
- `grant(_:reason:)` refuses an empty reason.
- `ConsentGate.performing` runs the body only after the permit, and records a `.refused` audit entry
  when it does not. That composition is what makes "zero commands on refusal" a property rather than
  a promise.
- Persisted at `~/Library/Application Support/PixelDesktop/consent.json`, written atomically.

### D2 — one trail, append before execute

- Every operation class appends to one log: `inputInject`, `appInstall`, `appUninstall`, `reboot`,
  `notificationRead`, `shellCommand`, `scheduledTaskRun`.
- `begin` writes the attempt **before** the command; `resolve` settles it. One attempt, one record.
- `.pending` is a fourth outcome. The proposal listed three, but a record written before the command
  cannot know its outcome — and a record *left* pending is the crash evidence the ordering rule
  exists to produce. Recorded as a deliberate correction in ADR-020 §5.
- Millisecond precision is real: custom ISO-8601 encoding with `.withFractionalSeconds`, because the
  default `.iso8601` strategy truncates to whole seconds and would make adjacent operations ambiguous.
- Bounded at 5,000; oldest evicted first.
- File renamed `input-audit.json` → `device-audit.json` (the record shape changed).

### D3 — one dry run for everything destructive

- `DestructiveActionPlan.confirmed` is `let`; `confirming()` is the only way to approve;
  `execute(using:)` throws `dryRunNotConfirmed` **before** the body, so an unconfirmed plan calls it
  zero times.
- `DryRunReport` carries the exact command string and a `wouldExecute` flag.
- `ADBDeviceInput.dryRunReport(for:)` returns the same type, so B1 is not a special case in the
  vocabulary. Its own gate is unchanged.

---

## 4. Verification

| Claim | Evidence | Result |
|---|---|---|
| Full suite, no regression | `xcodebuild test -scheme PixelDesktop` | **746 tests, 26 skipped, 0 failures** (baseline 715/26/0) |
| New tests all execute | `-only-testing` on the three classes | Phase3ConsentTests **14**, Phase3AuditTests **11**, Phase3DryRunTests **6** — 31, 0 failures |
| No grant → zero device commands | `testReadWithoutAGrantIssuesZeroCommands` | transport recorded **no invocations**; `.refused` record present |
| Revocation sticky across a reload | `testRevocationSurvivesAReload`, `testRevocationWinsOverAGrantedFlag` | pass |
| Append-before-execute | `testAttemptIsAuditedBeforeTheCommandIsIssued` | probe transport sees exactly `[[.pending]]` **at command time**; one record afterwards |
| Bound + ordering | `testTrailIsBoundedAndDropsOldest`, `testTimestampsKeepMillisecondPrecisionOnDisk` | pass |
| No destructive plan runs unconfirmed | `testEveryDestructiveOperationRequiresConfirmation` | body called 0 times for all five operations |

**Why the probe transport exists:** `MockTransport` records invocations but cannot read the log
mid-call, so an append-*after*-success implementation would have passed every other test in the file.
`AuditProbeTransport` reads `log.records` inside `shell(...)` — the only point where the ordering is
observable.

---

## 5. Two defects found while building this

**1. A tenth tab would have crashed the app on first render.** `ContentView` registered keyboard
shortcuts with `KeyEquivalent(Character("\(index + 1)"))`. `Character("10")` traps at runtime — a
`Character` cannot hold two scalars — so adding the Trust tab (the tenth) would have crashed before
rendering anything. Fixed with an explicit `shortcut(for:)` that maps ⌘1–⌘9 and ⌘0.

**2. The default JSON date strategy would have silently defeated the millisecond rule.** The
proposal demands millisecond precision; Foundation's `.iso8601` encoding strategy truncates to
seconds. Nothing would have failed — the field would simply have been wrong. Caught by writing the
test first (`testTimestampsKeepMillisecondPrecisionOnDisk`) and watching it fail, then fixing the
encoder.

---

## 6. What 3.1 deliberately does not do

- **No notification read.** The D1 gate exists; its consumer is 3.2.
- **No install/uninstall/reboot.** `DestructiveActionPlan` exists; 3.3 builds the plans.
- **No scheduled task, no kill switch, no remote shell.** 3.4 / 3.5.
- **No consent for anything beyond the four named classes.**

---

## 7. Next

**Phase 3.2 — A5 notification stream**: two-tier read (`cmd notification list` poll at 1.7 KB,
`dumpsys notification --noredact` at 777 KB only on key-set change), the five-field parser measured
against real dumps (title/text/textLines/subText/tickerText — a text-only parser drops 70% of
records), gated end to end by `ConsentGate` on `.notifications`, read-only per Q1(a).

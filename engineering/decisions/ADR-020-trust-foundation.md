# ADR-020: Trust Foundation (Phase 3.1) — Consent, Generalised Audit, Universal Dry Run

**Status:** Accepted
**Date:** 2026-10-25
**Relates to:** `docs/PROPOSAL-PHASE-3-DURABILITY.md` §5.1–5.3, §6, §7.2 · `docs/PROPOSAL-DEVICE-INTERACTION.md`
§6 (P4/P5) · ADR-009 (shell containment) · ADR-015 (AppState↔UI bridge) · ADR-019 (input gate + telemetry)

**Owner decision recorded 2026-10-25:** rnz opened the Phase 3 gate directly —
*"read for context and proceed with the implementation"* — against the Phase 3 proposal, whose §7.2
carried the recommendation `Q1(a), Q2(a), Q3(a), Q4(a), Q5(a)`. Those five answers are taken as
given by that authorisation and are recorded in §3 below. Any of them can be re-opened by the owner
before the sub-phase that depends on it ships; none of the five is baked into code shipped here
(Q1 and Q2 concern A5 and C3 — Phase 3.2 and 3.5).

This ADR is the design half of the Phase 3 gate. Phase 3.1 is the trust foundation, and it is first
because **A5 reads private message bodies and B4/B5 destroy state**: neither may ship before the
consent gate and the dry run exist.

---

## 1. Context

Three facts drive this ADR, all measured before it was written.

**A5 is not a metadata feed.** `dumpsys notification --noredact` returns message *bodies*. Measured
on this device: 23 records, 777,677 bytes, containing full text of messages from third-party apps.
A consent gate that warns beside the read is not a gate; it has to block the read.

**Consent did not exist.** `PixelDesktop/` had no `Consent` symbol at all. Phase 2 delivered the
input gate (`InputActionPlan.confirmed`) and an input-only audit log, so D2 and D3 were *half-built*
and this phase **generalises** them rather than rebuilding.

**The phone has no screen.** Every gate is invisible at the point of execution. An operation that is
not gated in the type system is not gated at all, because nothing on the device will tell the user
that it ran.

---

## 2. Decision — the trust layer ships first, and each part is structural

| ID | Part | Type | Enforcement mechanism |
|---|---|---|---|
| **D1** | Consent registry | `Trust/ConsentRegistry.swift` | `permit(for:)` throws; no permit, no device call |
| **D2** | Generalised audit | `Audit/DeviceAuditLog.swift` | `begin` before the command, `resolve` after |
| **D3** | Universal dry run | `Trust/DryRun.swift` | `confirmed` is `let`; `execute(using:)` gates the body |

The pattern in all three is the one ADR-019 established for input: **the gate is a property of the
type, not a rule documented beside it.** A caller cannot skip it by forgetting.

---

## 3. The five Phase 3 decisions (proposal §7.2), as taken

| # | Question | Decision taken | Consequence for this phase |
|---|---|---|---|
| **Q1** | A5 scope | **(a) read-only** — observe and display, no dismiss/snooze/reply | 3.2 builds a reader with no write path to another app's notifications |
| **Q2** | C3 remote shell | **(a) defer** — no C3 in Phase 3 | 3.5 ships the kill switch (D4) only, after C3's own ADR cycle |
| **Q3** | C4 scheduler | **(a) Mac-side** — `launchd`/`crontab` driving PixelDesktop | 3.4 has no Termux dependency and survives device reboots |
| **Q4** | D1 granularity | **(a) per data class** — 4 classes | implemented here: `ConsentDataClass` has exactly four cases |
| **Q5** | B5 reboot | **(a) build it**, with P5 confirmation | 3.3 builds `reboot(mode:)` behind `DestructiveActionPlan` |

Q4 is the only one with code in this phase, and it is visible in the enum: consent is granted per
class, never per package.

---

## 4. D1 — Consent registry

**Default deny.** A data class with no record is denied. `permit(for:)` consults `isActive` and
throws `ConsentError.consentRequired(dataClass:)` otherwise. There is no "unknown means allowed"
branch in `ConsentRegistry`.

**Revocation is sticky.** `ConsentGrant.isActive` is `granted && revokedAt == nil`. A non-nil
`revokedAt` wins over `granted == true`, so a stale write that flipped the boolean back cannot
re-open a withdrawn class. `revoke(_:)` sets **both** fields, so a reader that inspects the boolean
alone still sees a withdrawn class.

**A reason is required to grant.** `grant(_:reason:)` refuses empty and whitespace-only reasons with
`reasonRequired`. Consent given without an accompanying reason is a decision that cannot be
reviewed later, which defeats the point of persisting it.

**Persistence is atomic.** One JSON file, `~/Library/Application Support/PixelDesktop/consent.json`,
written with `.atomic` (temp file, then rename). A torn write here could lose a revocation, which is
the one direction this file must never fail in.

**`ConsentGate` binds the check to the read.** `permit(for:)` alone is a check a caller could forget
to make. `ConsentGate.performing(_:target:operation:_:)` runs the body only after the permit is
obtained, so a refused read performs **zero** device work, and it appends a `.refused` record —
ADR-019's rule that a refusal is an event, not an absence, carried into the generalised trail.

**What consent does not do:** granting a class reads nothing. It changes only what a *future* read is
permitted to do. The trust view states this explicitly.

---

## 5. D2 — Generalised audit

**One trail for every operation class.** `DeviceOperationKind` covers `inputInject`, `appInstall`,
`appUninstall`, `reboot`, `notificationRead`, `shellCommand`, `scheduledTaskRun`. `InputAuditLog` is
deleted; input is now a **filter** over the shared trail (`records(for: .inputInject)`), not a second
log. Two logs would have meant two answers to "what happened".

**Append-before-execute, via `begin`/`resolve`.** The attempt is written before the command is
issued and settled afterwards, with one record per attempt — not an append on success and another on
failure. A crash mid-command therefore leaves a record.

**`.pending` is a fourth outcome, and that is a deliberate correction to §5.2.** The proposal lists
three outcomes (`executed`, `refused`, `failed`), but it also requires the record to be written
*before* the command. A record written at that instant cannot know its outcome, so `.pending` is the
only honest value; a record left `.pending` is precisely the crash evidence the ordering rule exists
to produce. Every completed call resolves its own record, so `.pending` is unobservable in a normal
run.

**Millisecond precision, actually encoded.** The proposal's rule is that second precision makes
adjacent operations ambiguous. The default `.iso8601` strategy **truncates to whole seconds** — so the
encoder is custom, with `ISO8601DateFormatter` and `.withFractionalSeconds`, plus a plain-ISO fallback
on decode. Pinned by a test that writes two records 5 ms apart, reloads them, and asserts the gap
survived.

**Bounded at 5,000.** Ten times the input-only cap, because the log now carries every operation class
rather than taps alone. At one record per notification poll it would otherwise grow without limit.

**The input projection is retained.** `DeviceAuditRecord.input` carries the label, resource id, centre
and payload ADR-019 required. Generalising the record type must not have made a blind tap
unreviewable, so the fields ride along as an optional projection.

**The file is renamed** `input-audit.json` → `device-audit.json`. The record *shape* changed (an
operation class and an id), so continuing to read the old path would either fail to decode or
silently present a narrower history than the log claims to hold. The old file is left untouched;
nothing reads it.

---

## 6. D3 — Universal dry run

`DryRunReport` is the shared preview artifact: operation, resolved target, **the exact command
string**, `wouldExecute`, and operation-specific notes. It carries the command verbatim because a
summary that rounds off a flag is a preview of a different command.

`DestructiveActionPlan` is the gate, and it is `InputActionPlan`'s pattern generalised: `confirmed` is
`let`, `confirming()` is the only way to obtain an approved copy, and `execute(using:)` checks
`confirmed` **before** calling the body — so an unconfirmed plan calls it zero times. `body` receives
the plan's command, which was built and validated when the plan was created, never assembled at
execution time.

`DestructiveOperation` is the closed list from §5.3: `inputInject`, `appInstall`, `appUninstall`,
`reboot`, `storageDelete`.

**B1 joins the vocabulary rather than staying a special case:** `ADBDeviceInput.dryRunReport(for:)`
returns the same `DryRunReport` type, so a tap preview and an uninstall preview are renderable by the
same view. Input's own gate is untouched — this adds a report, it does not re-implement the gate.

---

## 7. Consequences

**Good**

- The four data classes are denied until an explicit, reasoned, persisted grant exists, and the
  refusal path issues zero device commands — measured, not asserted.
- A revocation cannot be lost to a reload or to a stale boolean.
- One file answers "what has this system done to the device, and was it allowed to" across every
  operation class, with millisecond ordering and crash evidence.
- Every destructive operation, present and future, has exactly one execution path and it is gated.
- The trust surface is operable from the app: the owner can grant and revoke without a terminal.

**Costs and limits**

- **`consent.json` is plaintext.** It contains reasons — never message content — but the reasons are
  human text and someone reading the file learns what the owner intended to read. Encrypting it was
  rejected as scope: the device-side data is the sensitive part, and the gate's job is to control
  access to it, not to hide the decision log.
- **A unit test cannot prove the device refused.** It proves the gate held and no command was
  issued. Whether the device honours the command is hardware verification, in 3.2 and 3.3.
- **The audit log is not tamper-evident.** Append-only by convention, bounded by eviction, plaintext
  on disk. Anyone with the user's file permissions can rewrite it. Making it tamper-evident (hash
  chain, append-only file) is not in Phase 3.
- **5,000 records evict.** An unattended scheduler polling notifications at 30 s fills the bound in
  ~41 hours of continuous refusal-free operation. Eviction drops the oldest first, which is the right
  direction for an operational trail and the wrong one for an investigation.
- **`pending` can be observed after a crash**, by design. A reader must not treat it as an error.

---

## 8. Verification

| Claim | Evidence |
|---|---|
| No grant → throws, zero device commands | `Phase3ConsentTests.testNoGrantIsDeniedByDefault`, `testReadWithoutAGrantIssuesZeroCommands` (asserts the mock transport recorded no invocations) |
| A refusal is audited | same test — `.refused` record with `operation == .notificationRead` |
| Grant permits the read | `testGrantPermitsTheReadAndTheBodyRuns` |
| A grant needs a reason | `testGrantRequiresAReason` |
| Consent is per class | `testConsentIsPerClass` |
| Revocation is immediate | `testRevokeIsImmediate` |
| Revocation beats `granted == true` | `testRevocationWinsOverAGrantedFlag` |
| Revocation survives a reload | `testRevocationSurvivesAReload` |
| Grants round-trip through disk | `testGrantRoundTripsThroughDisk` |
| Append-before-execute | `Phase3AuditTests.testAttemptIsAuditedBeforeTheCommandIsIssued` — a probe transport reads the log **at the instant the command is issued** and finds exactly one `.pending` record |
| One attempt, one record | same test — `log.records.count == 1` |
| Failure resolves the attempt | `testTransportFailureResolvesTheAttemptAsFailed`, `testNonZeroExitResolvesTheAttemptAsFailed` |
| Millisecond ordering survives disk | `testTimestampsKeepMillisecondPrecisionOnDisk` |
| The trail is bounded | `testTrailIsBoundedAndDropsOldest`, `testDefaultCapacityIsFiveThousand` |
| The input projection survives | `testInputContextSurvivesTheDiskRoundTrip` |
| No destructive plan runs unconfirmed | `Phase3DryRunTests.testUnconfirmedPlanRunsNothing`, `testEveryDestructiveOperationRequiresConfirmation` (every case, body called zero times) |
| The report is exact and honest | `testReportCarriesTheExactCommandAndTheWouldExecuteFlag` |
| Input joins the shared vocabulary | `testInputPlanProducesTheSharedReport` |

Full suite: see `engineering/phases/phase-03-1-trust-foundation.md` for the measured result.

---

## 9. Not in this phase

- A5 notification reading (3.2) — the D1 gate exists, its first consumer does not.
- B4/B5 (3.3) — `DestructiveActionPlan` exists, no operation builds one yet.
- C4 scheduler (3.4), D4 kill switch (3.5).
- Any consent class beyond the four named. Adding a fifth is a decision, not a code change.

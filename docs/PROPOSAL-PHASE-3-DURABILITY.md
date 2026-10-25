# Phase 3 — "Durability": Proposal

**Date:** 2026-10-25
**Author:** Ciel
**Status:** **APPROVED 2026-10-25** — rnz opened the Phase 3 gate (*"proceed with the implementation"*);
§7.2 decisions taken as recommended (Q1a–Q5a), recorded in ADR-020. **Phase 3.1 (trust foundation)
is implemented**; 3.2–3.5 are not started.
**Elaborates:** `docs/PROPOSAL-DEVICE-INTERACTION.md` §8, row 3 ("Durability"), which is the phasing authority.
**Supersedes:** nothing. Complements the master proposal; does not amend it.
**Baseline measured at:** `e3c9579`, working tree clean — **715 tests, 26 skipped, 0 failures**.

---

## 1. What Phase 3 is

The master proposal's §8 row 3 names five things:

| ID | Feature | Group |
|---|---|---|
| **A5** | Notification stream | Perception |
| **C4** | Scheduled device tasks | Compute |
| **C3** | Remote shell | Compute |
| **B4 / B5** | App install/uninstall · reboot control | Control |
| **D1–D4** | Consent registry · command audit · universal dry-run · kill switch | Trust & safety |

Phase 3 is the **trust and durability layer**. It is the phase where PixelDesktop stops being a
set of capabilities and starts being a system that can be left running: it can observe the phone's
notifications, act on a schedule, and — critically — **prove it was allowed to do so**.

**The ordering constraint that shapes this proposal:** A5 reads personal data, and B4/B5 are
destructive. Neither can ship before D1 (consent) and D3 (dry-run) exist. So **D1/D2/D3 come
first**, and everything else is gated on them. §5 makes this explicit.

---

## 2. Grounding — the tree as it stands

Every row below is a path listed or a command run on 2026-10-25, not a memory of the project.

| Capability | Status | Where | Note |
|---|---|---|---|
| Transport + `shell()` primitive | ✅ Working | `Transport/` | ADR-002, ADR-009 |
| Port forwarding / reverse tunnel (B3) | ✅ Working | `Perception/PortForwarding.swift` | Phase 0 |
| Log stream (A6) | ✅ Working | `Perception/LogcatStream.swift` | Phase 0 |
| UI hierarchy (A4) | ✅ Working | `Perception/UIHierarchyParser.swift` | Phase 0 |
| Screenshot (A2) | ✅ Working | `Perception/ADBDevicePerception.swift` | Phase 0 |
| Input injection (B1) | ✅ Working | `Operations/DeviceInput.swift` | Phase 2, ADR-019 |
| Telemetry + thermal history (A7) | ✅ Working | `Perception/DeviceTelemetry.swift` | Phase 2, ADR-019 |
| **Command audit (D2)** | 🚧 **Partial** | `Operations/InputAuditLog.swift` | **Input actions only** — not generalized |
| **Dry-run (D3)** | 🚧 **Partial** | `Operations/DeviceInput.swift` | **B1 only** — not universal |
| Consent registry (D1) | ❌ Missing | — | no `Consent` symbol anywhere in `PixelDesktop/` |
| Kill switch (D4) | ❌ Missing | — | no `killSwitch`/`safeMode` symbol |
| App install / uninstall (B4) | ❌ Missing | `Operations/ADBAppOperations.swift` | discovery/launch/stop/list only |
| Notification stream (A5) | ❌ Missing | — | — |
| Scheduled device tasks (C4) | ❌ Missing | — | — |
| Remote shell (C3) | ❌ Missing | `Transport/` (`shell()` exists, contained) | ADR-009 §1 forbids exposing it |
| Reboot control (B5) | ❌ Missing | — | — |

**D2 and D3 are already half-built.** Phase 2 delivered `InputAuditLog` and the B1 dry-run gate.
Phase 3 does not rebuild them — it **generalizes** them. That is a smaller job than the master
proposal's wording implies, and §5.1 says exactly how.

---

## 3. Device facts — re-verified 2026-10-25

### 3.1 Corrections to the master proposal

**The master proposal §2 table is stale in two rows.** Both were re-measured today:

| Master proposal says | Actual, measured 2026-10-25 |
|---|---|
| "Termux / Shizuku / Magisk / llama: **none installed**" | **`com.termux` 0.118.0 IS installed** — `firstInstallTime=2026-10-24 21:26:40` |
| Storage "60 GB used / 50 GB free" | **71 GB used / 38 GB free** on `/data` |

Termux was installed during Phase 1 (C1), and the model plus toolchain have grown `/data`.
The master proposal's §2 was a point-in-time reading from before Phase 1 ran.

### 3.2 The state that matters for Phase 3

| Fact | Value | Consequence for Phase 3 |
|---|---|---|
| Termux | 0.118.0, installed | C4's Termux-cron path is *available in principle* — see §4.1 |
| Model | `gemma-3n-E4B-it-Q4_K_S.gguf`, 4,404,697,216 B, staged `/data/local/tmp/` | C1's model is on device |
| Toolchain | clang 21.1.8, cmake 4.4.4, git 2.56.0, wget 1.25.0, curl 8.23.0 | C1/C4 prerequisites present |
| Worker APK | `com.pixeldesktop.worker` **installed** | B4 has a real install/uninstall target |
| `adb root` | **refused** — "adbd cannot run as root in production builds" | no escalation path |
| `run-as com.termux` | **"package not debuggable"** | Termux internals unreadable |
| `pm grant com.android.shell com.termux.permission.RUN_COMMAND` | **exit 0, silently no-ops** (re-verified twice; not in the shell's granted list) | the Termux wall is real |
| `am startservice … RunCommandService` | **"Requires permission com.termux.permission.RUN_COMMAND"** | no headless Termux channel |
| `dumpsys notification --noredact` | **works** — 777,677 B, 0.11–0.14 s, 23 records | **A5 is viable** |
| `cmd notification list` | **works** — 1,731 B, 23 lines, keys only | cheap change-detection tier |
| `cmd notification post` | **works** | test notifications can be generated |
| `cmd notification allow_listener` | **exists**, but **no app on device declares a `NotificationListenerService`** | real-time push needs an APK change |
| `cmd jobscheduler run` | **exists**, but needs a `JobService` — the worker APK has none | Android-side scheduling needs an APK change |
| Mac `crontab` / `launchctl` | **available** | **the headless scheduler is already here** |

---

## 4. Two findings that change the design

### 4.1 C4 as written is blocked — and the fix is better than the original

The master proposal's C4 says "run something on the phone on a schedule (**Termux cron**)".

**Termux cron cannot be started headlessly.** `crond` must run inside a Termux shell, and §3.2
shows there is no headless channel to a Termux shell: `RunCommandService` refuses, `pm grant`
silently no-ops, `adb root` is refused, and `run-as` is denied. The only channel that reaches a
Termux shell is the **interactive terminal UI** — `adb shell input text` against a focused
`TermuxActivity`. A cron daemon started that way dies with the session and cannot be relied on.

**Recommendation: move the scheduler to the Mac.** PixelDesktop already runs on the Mac, and
`launchd`/`crontab` are present. A Mac-side schedule driving PixelDesktop's existing operations
(`adb shell`, port forwarding, inference jobs) is:

- **headless** — no device-side change, no Termux dependency, no new permission;
- **survives device reboots** — a Termux cron table does not;
- **auditable in the same place** as everything else — one audit log, one consent gate;
- **testable hermetically** — the scheduler seam can be mocked, unlike a device cron daemon.

This is a **recommendation, not a silent substitution**. It is recorded as decision **Q3** in §7
because it changes what C4 means.

### 4.2 A5 exposes real personal data — so D1 is a hard gate, not a nicety

`dumpsys notification --noredact` returns **message bodies**. Measured on this device:

```
android.title=String (rnz, a post for you)
android.text=String ("Magbibirthday ako pero hindi na ako maghahanda para walang problema 😂🎉")
android.textLines=CharSequence[] (6)
  [0] AI Automation Society (S.   Weekly digest for Sun, Oct 18 2026
  [1] Tina Huang   🐙 I do an AI audit every few months. Here's what that looks like.
  ...
```

The master proposal's **P4** already requires consent + audit for notifications, and rnz approved
access (§6.1 Q3). But the *measurement* is worth stating plainly: **A5 is not a metadata feed.
It is a read of the user's private messages.** D1 must be a hard gate that blocks the read, not a
warning rendered beside it.

---

## 5. Design

### 5.1 D1 — Consent registry

**What it is.** A persisted, per-data-class grant store. Four classes, matching the master
proposal: `notifications`, `sms`, `contacts`, `clipboard`.

**Concrete spec.**

| Field | Type | Rule |
|---|---|---|
| `dataClass` | enum, 4 cases | the unit of consent |
| `granted` | Bool | default **false** |
| `grantedAt` | Date | set on grant |
| `revokedAt` | Date? | set on revoke; non-nil means revoked regardless of `granted` |
| `reason` | String | free text, required at grant time |

**Rules.**
1. **Default deny.** Every read of a P4 data class checks the registry **before** issuing any
   device command. A missing or revoked grant throws `consentRequired(dataClass:)` and issues
   **zero** commands — the same structural gate pattern ADR-019 uses for input injection.
2. **Revocation is immediate and sticky.** `revokedAt != nil` wins over `granted == true`, so a
   revoke cannot be lost to a stale write.
3. **Persistence.** Application Support, one JSON file, written atomically (write-temp + rename).
4. **Consent is per class, not per package** — see decision **Q4**.

**Verification.** A test asserts that a read with no grant throws and that the mock transport
records **zero** invocations. A second test asserts revoke-then-read still throws. A third asserts
the on-disk file round-trips.

### 5.2 D2 — Command audit log (generalized)

**What exists.** `Operations/InputAuditLog.swift` — a bounded, persisted record of input actions.

**What changes.** The record type is renamed and widened from *input* actions to *device*
actions, and the log is moved to a neutral location. Every operation in Phase 3 (and the existing
B1/B4/B5) appends before executing.

**Concrete spec.**

| Field | Type | Rule |
|---|---|---|
| `id` | UUID | per record |
| `at` | Date | **millisecond** precision — second precision would make ordering ambiguous |
| `operation` | enum | `inputInject`, `appInstall`, `appUninstall`, `reboot`, `notificationRead`, `shellCommand`, `scheduledTaskRun` |
| `target` | String? | package, element id, or device serial |
| `outcome` | enum | `executed`, `refused`, `failed` |
| `detail` | String? | reason for refusal/failure |

**Rules.**
1. **Append-before-execute.** The record is written before the command is issued, so a crash
   mid-command still leaves the attempt.
2. **Bounded.** 5,000 records; oldest dropped first. Rationale: at one record per poll the log
   would otherwise grow without limit.
3. **`refused` is a first-class outcome.** A refusal is an event, not an absence — ADR-019's
   input refusals already model this and it is retained.

**Verification.** Tests assert append-before-execute ordering, the bound, and that a refusal
produces a record with `outcome == .refused`.

### 5.3 D3 — Universal dry-run

**What exists.** The B1 plan gate (`InputActionPlan.confirmed`).

**What changes.** A shared `DryRunReport` type and a `dryRun` flag on every destructive operation.
The gate pattern is unchanged — it is generalized, not redesigned.

**Concrete spec.** `DryRunReport` carries: the operation, the resolved target, the exact command
string that *would* run, and a `wouldExecute: Bool`. Destructive operations are: **B1 input, B4
install/uninstall, B5 reboot, storage delete**. Each throws `dryRunNotConfirmed` before issuing
anything when `dryRun` is set and confirmation is absent.

**Verification.** For each destructive operation: a test asserts the dry-run path produces a
report and **zero** transport invocations.

### 5.4 A5 — Notification stream

**Two-tier read.** Measured, not assumed:

| Tier | Command | Size | Cadence | Carries |
|---|---|---|---|---|
| 1 | `cmd notification list` | **1,731 B** | poll (default 30 s) | keys only: `user\|pkg\|id\|tag\|uid` |
| 2 | `dumpsys notification --noredact` | **777,677 B** | **only when the key set changed** | full content |

Tier 1 is **45× smaller** than Tier 2. Polling Tier 2 at 30 s would move ~15 MB/min for content
that changes rarely; the two-tier design moves ~9 KB/min on the poll path and fetches the large
payload only on actual change.

**Parser spec — measured against real output.** A prototype parser was run against a live dump
(23 records). The measurements drove the design:

| Field | Present in | Parser rule |
|---|---|---|
| `android.title` | **19 / 23** | read |
| `android.text` | **7 / 23** | read — **but not sufficient alone** |
| `android.textLines` | 1 / 23 | read as a **list**; it is a multi-line `CharSequence[]` |
| `android.subText` | present | read |
| `android.bigText` | 0 / 23 | read if present |
| `tickerText` | 23 / 23 | read; **`"null"` must be distinguished from absent** |
| `vis` | `PRIVATE` / `PUBLIC` / `SECRET` | all three handled |
| `importance` | 1–4 | mapped to a 4-case enum |

**The defect this caught:** a parser reading only `android.text` would **silently drop 16 of 23
notifications** — 70% of the feed. The parser reads title, text, textLines, subText and
tickerText, and a record with none of them is surfaced as `contentless` rather than dropped.

**Records with no extractable content:** 2 / 23 (system packages `android`,
`com.google.android.gms`). Surfaced, not hidden.

**Gating.** A5 is **P4-gated through D1**. With no `notifications` grant, the read throws
`consentRequired` and issues zero commands.

**Real-time vs polling — recommended: polling.** A true push stream needs a
`NotificationListenerService`, which requires adding a service to the worker APK. That APK
deliberately declares **zero permissions and no service** (its manifest states the reasoning).
Breaking that posture for a notification feed is a worse trade than a 30 s poll. Recorded as
recommendation; the alternative is available if rnz wants push.

### 5.5 B4 — App install / uninstall

**Concrete spec.** `install(apkLocalPath:)`, `uninstall(packageId:)`. Both guarded:

| Rule | Value |
|---|---|
| Package validation | exact identifier, no wildcards — same `validatePackageName` as ADR-009 |
| Dry-run | required (`DryRunReport` shows the exact `adb install -r <path>`) |
| Audit | D2 record with `operation == .appInstall` / `.appUninstall` |
| Uninstall protection | refuses `com.pixeldesktop.worker` (the project's own worker) and system packages |

**Verification.** Hermetic tests pin command construction and validation. A **real-device** test
installs and uninstalls the worker APK — reversible, and the APK is on the Mac
(`DTCA1Worker/app/build/outputs/apk/debug/app-debug.apk`).

### 5.6 B5 — Reboot control

**P5-gated.** `reboot(mode:)` where mode ∈ {`normal`, `recovery`, `bootloader`}.

| Rule | Value |
|---|---|
| Confirmation | explicit, per-call; **no remembered consent** |
| Dry-run | required, and the report states the recovery path |
| Recovery documented | `normal` → device returns; `recovery`/`bootloader` → `fastboot` path, needs physical buttons |
| Audit | D2 record with `operation == .reboot` |

**This is the one operation that can leave the device unreachable.** It is built last in the
phase order and is the subject of decision **Q5**.

### 5.7 C3 — Remote shell

**Requires its own ADR before any code.** ADR-009 §1 is explicit: `shell()` "must not be exposed
to the UI or Hermes without a separate review". C3 is that review.

**The design the ADR must settle:**

| Question | Options |
|---|---|
| Streamed or one-shot? | streamed PTY (stateful, hard to bound) vs one-shot `shell()` calls (bounded, no session) |
| Command surface | free text vs a named operation enum |
| Output bound | unbounded stream vs a byte cap with truncation |
| Termination | how is a runaway shell killed? → **this is what D4 is for** |

**Recommendation: one-shot, bounded, audited.** A streamed interactive shell is a genuinely
different security posture and a much larger surface; one-shot calls reuse the existing contained
`shell()` primitive, the existing audit log, and the existing consent gate. Recorded as decision
**Q2** — C3 may be deferred entirely if rnz prefers.

### 5.8 D4 — Kill switch

**Concrete spec.** `killSwitch()` performs, in order: stop all port forwards · stop all scheduled
tasks · stop the logcat stream · disconnect the transport. Each step is audited. The switch is
**idempotent** — calling it twice is safe and the second call is a no-op with a D2 record.

**Verification.** Tests assert the step order, idempotency, and that every step appends a D2
record.

---

## 6. Phasing

**Five sub-phases.** Each has a deliverable and a verification. The order is not arbitrary:
3.1 is a prerequisite for 3.2 and 3.3.

| # | Name | Produces | Verified by | Depends on |
|---|---|---|---|---|
| **3.1** | **Trust foundation** | D1 consent registry · D2 generalized audit · D3 universal dry-run | hermetic tests: zero-command refusal, revoke stickiness, append-before-execute, bound, dry-run reports | — |
| **3.2** | **Notification stream** | A5 two-tier reader + parser + view | parser tests against **captured real dumps**; a live read gated by D1 | 3.1 |
| **3.3** | **App + reboot control** | B4 install/uninstall · B5 reboot | hermetic tests + a real-device install/uninstall round-trip of the worker APK | 3.1 |
| **3.4** | **Scheduled tasks** | C4 Mac-side scheduler + job store | hermetic tests with a mocked clock; a real scheduled job observed firing | 3.1 |
| **3.5** | **Remote shell + kill switch** | C3 (after its ADR) · D4 kill switch | ADR accepted; hermetic tests for bound, audit, idempotency | 3.1, C3 ADR |

**Why 3.1 first.** A5 reads private messages and B4/B5 destroy state. Shipping either before the
consent gate and dry-run exist would mean the first run of Phase 3 is the first time PixelDesktop
can read a private message or uninstall an app without a gate. That is the failure mode P4 and P5
exist to prevent.

**Why 3.5 last.** C3 is the only item needing a new ADR, and B5 is the only item that can leave
the device unreachable. Both are the highest-consequence work and belong after the trust layer
that constrains them.

---

## 7. Decision gate

### 7.1 Probes already run

Every probe this proposal rests on was executed on the live device on 2026-10-25. **None remain
that the implementer can run without the owner.**

| Probe | Command | Result |
|---|---|---|
| Notification read | `dumpsys notification --noredact` | works — 759 KB, 0.11–0.14 s, 23 records |
| Notification list | `cmd notification list` | works — 1.7 KB, keys only |
| Notification post | `cmd notification post` | works |
| Listener service | `cmd notification allow_listener` | exists; **no app declares a listener** |
| Termux grant | `pm grant com.android.shell com.termux.permission.RUN_COMMAND` | exit 0, **silently no-ops** |
| Termux service | `am startservice … RunCommandService` | **refused** |
| Root | `adb root` | **refused** |
| Termux internals | `run-as com.termux` | **not debuggable** |
| Install path | `pm install-create` | **succeeds** |
| Android scheduling | `cmd jobscheduler run` | exists; needs a `JobService` |
| Mac scheduling | `crontab`, `launchctl` | **available** |

**Two probes remain, both requiring authorization** (they mutate the device):

| Probe | Command | Why it needs authorization |
|---|---|---|
| Uninstall round-trip | `adb uninstall com.pixeldesktop.worker` then reinstall | removes the project's own worker; reversible, but a state change |
| Listener behaviour | `cmd notification allow_listener <component>` | needs an APK with a listener service, which does not exist yet |

### 7.2 Decisions required from rnz

| # | Question | Options | If the other way |
|---|---|---|---|
| **Q1** | **A5 scope** | **(a) read-only** — observe and display · (b) read + act — dismiss, snooze, reply | (b) adds a write path to another app's notifications; larger surface, needs its own consent class |
| **Q2** | **C3 remote shell** | **(a) defer** — do not build C3 in Phase 3 · (b) approve the ADR and build one-shot · (c) approve the ADR and build streamed | (a) removes the riskiest item; (c) is a genuinely different security posture and a much larger surface |
| **Q3** | **C4 scheduler** | **(a) Mac-side** (recommended) — `launchd`/`crontab` driving PixelDesktop · (b) hold C4 until Termux cron is unblocked | (b) leaves C4 blocked indefinitely; the Termux wall is a device-side setting, not a code task |
| **Q4** | **D1 consent granularity** | **(a) per data class** (recommended) — 4 classes · (b) per package | (b) is finer but the master proposal's P4 names data classes; (a) matches it |
| **Q5** | **B5 reboot** | **(a) build it** with P5 confirmation · (b) defer B5 | (b) leaves no recovery path if the device wedges; (a) is the one operation that can leave the device unreachable |

**Recommendation: Q1(a), Q2(a), Q3(a), Q4(a), Q5(a).** That is: read-only notifications, C3
deferred to its own ADR cycle, Mac-side scheduling, per-class consent, reboot built with a
confirmation gate.

---

## 8. Out of scope

- **Rebuilding the transport, storage, app-ops, worker or inference layers** — they exist and work.
- **A NotificationListenerService in the worker APK** — it would break that APK's deliberate
  zero-permission posture. Available if Q1 or the real-time requirement changes.
- **Rooting the device** — §6.3 of the master proposal; not recommended.
- **Any `Video/` subsystem** — master proposal §6.4, decision (a).
- **Termux cron** — blocked by the device-side wall (§4.1); recorded, not attempted.
- **Cloud relay / internet-wide access** — direct device-to-Mac only (ADR-002, ADR-014).

---

## 9. Success criteria

1. **A5 reads the notification feed with no grant → throws, issues zero commands.** Measured
   against a real dump, not a fixture.
2. **The A5 parser extracts content from ≥ 90% of records** on a captured real dump — the
   prototype achieved 21/23 (91%) reading title/text/textLines/subText/tickerText, vs 7/23 (30%)
   for a text-only parser.
3. **Every destructive operation refuses without a confirmed dry-run**, verified by asserting
   zero transport invocations.
4. **B4 installs and uninstalls the worker APK on the real device** and leaves it healthy.
5. **A scheduled task fires on the Mac without any device-side daemon.**
6. **The full suite passes with no regression** — baseline **715 tests, 26 skipped, 0 failures**
   at `e3c9579`.
7. **No personal data is read without an explicit, persisted, revocable consent.**

---

## 10. Verdict

**REVISING — needs decisions on 5 items (§7.2).**

The design is complete and every premise is measured. The five questions are genuine owner
decisions — risk appetite and scope, not facts the implementer can settle. Recommendation for each
is in §7.2.

No implementation has begun. `git status` is clean at `e3c9579`; the only files written for this
proposal are this document and a throwaway parser prototype under the session scratch directory.

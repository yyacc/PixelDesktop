# ADR-022: The Mac-Side Scheduler (Phase 3.4, C4) — launchd Owns the Clock, PixelDesktop Owns the Jobs

**Status:** Proposed — awaiting rnz's approval (design gate; no implementation before it)
**Date:** 2026-10-25
**Supersedes:** —
**Related:** ADR-018 (unattended operation), ADR-020 (trust foundation), ADR-021 (notification stream), `docs/PROPOSAL-PHASE-3-DURABILITY.md` §4.1 (Q3a), §6 (phase table)

---

## 1. Context

Q3a is already decided at the proposal level: scheduled tasks live on the **Mac** side, not in the worker
and not in a hidden on-device cron. The phase table gives C4 exactly two acceptance requirements:

- hermetic tests with a mocked clock;
- one **real** scheduled job observed firing.

Nothing else about C4 has been written down. Three facts in the existing tree constrain the design:

1. **The CLI says, in its own header, that it is not a scheduler**: *"There is no HTTP, no socket, no
   daemon, no queue, no scheduler, no router…"* (`PixelDesktopCLI/main.swift`). It is a process that
   runs one command and exits. C4 must not turn it into a daemon.
2. **The audit vocabulary already anticipates this work**: `DeviceOperationKind` has carried
   `case scheduledTaskRun` since the D2 work, and nothing uses it. C4 is the first consumer.
3. **The app is a GUI process.** A timer inside it stops when the app closes, which is the opposite of
   durability. Any design whose clock lives in the app's memory fails the phase's own purpose.

---

## 2. Decision

### 2.1 launchd owns the clock; the app owns the job definitions

A scheduled job is a **launchd job** that invokes one already-bounded process:

```
pixel-desktop-cli schedule run <job-id>
```

`StartCalendarInterval` / `StartInterval` in a generated plist is the tick. The job store is the single
source of truth for *what* is scheduled; the plist is a generated artifact of it, never hand-edited —
the same relationship `project.yml` has to `project.pbxproj`.

The app **reads and edits** the store (list, enable/disable, run-now, next-run preview) and **never runs
a clock of its own**. There is one place a job can be defined and one place it can fire, and they are the
same record.

### 2.2 The job is data, not a shell line

```
ScheduledJob
  id            UUID
  name          String            // operator-facing, unique
  cadence       .interval(seconds) | .daily(hour:minute)
  action        ScheduledAction   // a closed enum
  enabled       Bool
  createdAt     Date
  lastRunAt     Date?
  lastOutcome   .succeeded | .refused | .failed | .skipped
```

`ScheduledAction` is a closed enum of **named, existing** operations — e.g. `.telemetrySample`,
`.notificationTier1`, `.forwardEnsure(localPort:remotePort:)`, `.workerHealth`. Each case maps onto a seam
the app already owns (`DeviceTelemetryProtocol`, `NotificationStream`, `PortForwardingProtocol`,
`ADBWorker`). The scheduler composes no `adb` strings and gains no new transport ability; adding an
action is a code change, not a stored string.

**Destructive operations are not schedulable in 3.4.** `install`, `uninstall`, `reboot`, storage delete and
input injection are excluded from `ScheduledAction` by construction. D1 and D3 require a per-call human
confirmation; a headless 03:00 tick cannot supply one, and a scheduler that remembers a consent is exactly
the "remembered consent" ADR-020 refuses. The enum is the enforcement point, and a test asserts the
excluded kinds cannot be constructed.

### 2.3 Every run is gated, bounded and audited

Per invocation, in this order:

1. **Load** the store; unknown or disabled job → exit 2 with a structured error, zero device calls.
2. **Consent**: the action's data class is checked via `ConsentRegistry.permit(for:)`. No active grant →
   audit `refused`, exit 1, zero device calls. Consent is re-checked every run, never cached in the job.
3. **Audit begin**: one `DeviceAuditRecord` (`.scheduledTaskRun`, `.pending`) written **before** the
   command — the B4 idiom, reused rather than re-invented.
4. **Execute** one bounded attempt with a deadline. No retries: retrying headlessly is how a transient
   failure becomes a traffic problem. Failure is recorded and the process exits non-zero.
5. **Resolve** the same audit record with outcome + a short detail (counts and durations, never payloads).

### 2.4 Missed ticks coalesce

If the Mac sleeps through four intervals, the job runs **once** on wake and records `skipped: 3`, derived
from `lastRunAt` against `now` — not four back-to-back runs. A job whose cadence implies more than one
missed run while asleep is not owed that backlog.

`lastRunAt` advances on every attempt that reached the gate — including `.failed` and `.refused` — and
never on `.skipped`. Cadence therefore governs *attempts*, not successes: a job failing because the
phone is unplugged must not stay permanently due, and a stale `lastRunAt` would inflate `skippedTicks`
on every later run. `lastOutcome` is what tells the failure apart from a success; `lastRunAt` alone
never claims one.

### 2.5 The clock is a seam

`Clock` (`now()`, `sleep(until:)`) with `SystemClock` and a manual `TestClock`. All cadence, catch-up,
deadline and next-run logic is expressed against it, so the entire suite runs without wall-clock waits.
The launchd plist is generated by a pure function of the store plus the CLI path, and is asserted
byte-for-byte in a test.

---

## 3. Consequences

- The scheduler is durable for the right reason: launchd is the thing that survives logout, sleep and
  reboot; the app does not have to be running.
- A scheduled job is visible in two places an operator can check — the app's Schedules tab and the audit
  trail — and both read the same store and the same records.
- C4 adds a fourth CLI verb (`schedule`), which is a deliberate, narrow exception to "the CLI owns no
  orchestration": it runs **one** job and exits, exactly like `run`.
- 3.5 (D4 kill switch) inherits two hooks it needs: `store.disableAll(reason:)` and an in-process registry
  of the currently-executing job, so the kill switch can stop the scheduler without guessing.
- Not scheduled, by decision: anything destructive, anything requiring a confirmation, anything that
  streams (logcat is a UI affordance, not a job).

---

## 4. Acceptance criteria (proposed — rnz's approval, not yet agreed)

- **C4-1** Job store round-trips through JSON at
  `~/Library/Application Support/PixelDesktop/schedules.json`, atomically, with a schema version; a
  corrupt file is reported, never silently replaced.
- **C4-2** Cadence, catch-up coalescing and deadline behaviour are proven hermetically with `TestClock`
  (no sleeps in the suite).
- **C4-3** The generated plist is a pure function of the store, asserted byte-for-byte; the app never
  writes a plist it did not generate from the store.
- **C4-4** A run with no consent makes **zero** device calls and writes one `refused` audit record
  (test-enforced against a mock transport).
- **C4-5** Destructive actions are unrepresentable in `ScheduledAction` (compile-time + test).
- **C4-6** One **real** job fires on this Mac: launchd tick → `lastRunAt` advances in the store → a
  `.scheduledTaskRun` audit record appears → the device shows the effect (e.g. a telemetry sample).
  Evidence recorded in `engineering/evidence/phase-3-4/`.
- **C4-7** A job with a missing device exits non-zero within its deadline with a structured error; it
  neither hangs nor reports success.
- **C4-8** Disable → next tick performs no device call and records `skipped`/nothing, per §2.4 wording.

**No reboot is involved anywhere in 3.4**, and nothing in 3.4 reads or writes device storage.

### 4.1 Verification status (2026-10-25)

| # | Status | How |
|---|---|---|
| C4-1 | verified (test) | `Phase3SchedulerTests` — round-trip, atomic write, corrupt file reported not replaced |
| C4-2 | verified (test) | `TestClock`; no sleeps in the suite |
| C4-3 | verified (test) | plist asserted byte-for-byte, incl. the `--json` argument |
| C4-4 | verified (test) | mock transport counts calls: zero, one `refused` record |
| C4-5 | verified (compile + test) | no destructive case in `ScheduledAction` |
| C4-6 | **verified live** | `engineering/evidence/phase-3-4/c4-6-firing.md` — pixel 7a telemetry, `lastRunAt` advanced, `scheduledTaskRun` audit record |
| C4-7 | verified (test) only | missing-device path is hermetic; a live pull-the-cable run is an operator action |
| C4-8 | verified (test + live tick) | second real tick was `skipped`, no device call, no audit record, exit 0 |

The one criterion this phase cannot close by itself is C4-7's live form. Everything else above rests on
a test or on a transcript from this Mac, not on inspection of the code.

---

## 5. Open questions for rnz

1. **launchd, or an in-app timer?** This ADR picks launchd because it is the only shape that survives the
   app closing. An in-app timer is simpler to test but fails durability by construction.
2. **Install the launchd job automatically, or require an explicit operator action?** Recommendation:
   explicit `Install scheduled agent` button plus a written plist path, so nothing lands in
   `~/Library/LaunchAgents` without the operator seeing it.
3. **Scope of the first action set** — recommendation: start with three read-only actions
   (`.telemetrySample`, `.notificationTier1`, `.workerHealth`) and add more only when a phase needs them.

## 6. Follow-up work (deferred by rnz, 2026-10-25)

Two findings from the commit review were deliberately **not** implemented. They are recorded here so
the next phase inherits them rather than rediscovering them.

1. **The scheduler's routing requirement is hardcoded, and that is only safe while every action is a
   read.** `ScheduledJobRunner` asks the gate for `requirement: .deviceRead` unconditionally, and
   `ScheduledAction` today holds three read-only cases, so the code is correct. The day a scheduled
   *inference* action is added, the runner would still ask for `.deviceRead`, and the model-presence and
   backend-health checks would be skipped with no test failing. **Before the first inference action
   exists:** derive the requirement from the action (`job.action.routingRequirement`) and add a boundary
   test asserting the requirement the runner passes for each action kind. Related: `CLIScheduleCommand`
   passes `contractModelRequired: true`, which is inert under `.deviceRead` and misleading to read.
2. **Nothing verifies that production CLI execution uses `DeviceExecutionEligibility`.** The test bundle
   compiles CLI files by explicit path from `project.yml`; `main.swift` is not among them and cannot be
   (top-level code), so the wiring inside it is unreachable from a test. A permissive stub swapped in
   there would pass every existing test. The fix is to move the construction into a file with no
   top-level code (e.g. `CLIExecutionWiring.make(transport:backend:)`), call it from both `main.swift`
   and `CLIScheduleCommand`, add it to the test target's sources, and assert both the constructed type
   and its behaviour on a rejecting device state.

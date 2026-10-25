# C4-6 — one real job fires on this Mac

**Date:** 2026-10-25
**Phase:** 3.4 (C4), Mac-side scheduler
**Verdict:** verified by direct observation on the physical Pixel 7a (`3C261JEHN25632`, USB). No reboot, no
device-side change, no consent bypass.

## What was exercised

The full runtime chain, with launchd as the clock and the CLI as a one-shot process:

```
launchd (gui session) → pixel-desktop schedule run <job-id> --json
   → ScheduledJobRunner (due check, consent gate, execution, audit, store write)
   → DeviceScheduledActionExecutor → adb → Pixel 7a
```

Nothing was invoked that the product would not invoke: the plist is the file `LaunchAgent.plist(for:)`
emits, and the arguments are the ones `LaunchAgentTests`/`Phase3ScheduleCLITests` assert.

## Setup

- CLI: `.build/Build/Products/Debug/pixel-desktop` (debug build-for-testing output).
- Store: `~/Library/Application Support/PixelDesktop/schedules.json`, one job,
  `action: telemetrySample`, `cadence: {interval: {seconds: 3600}}`, no `lastRunAt` (never run).
- Agent: `~/Library/LaunchAgents/com.pixeldesktop.scheduler.7f3c1d20-….plist`,
  `ProgramArguments = [<cli>, schedule, run, 7F3C1D20-…, --json]`, `StartInterval = 3600`,
  `RunAtLoad = false`.
- Loaded with `launchctl bootstrap gui/$(id -u) <plist>`; the tick was produced with
  `launchctl kickstart -k` — launchd decided the process ran, the CLI did not schedule itself.

**Note on the plist:** it was written from the generator's template by a seeding script rather than by
`LaunchAgentInstaller`, because the Schedules UI that calls the installer does not exist yet. The
plist *bytes* are already locked by `Phase3SchedulerTests`; what this run adds is the runtime chain,
which no unit test covers. The installer button remains unexercised.

## Tick 1 — due, executed

`~/Library/Logs/PixelDesktop/scheduler/com.pixeldesktop.scheduler.7f3c1d20-….out.log`:

```json
{
  "command" : "schedule",
  "error" : null,
  "ok" : true,
  "produced_at" : "2026-10-25T07:25:52Z",
  "scheduled_run" : {
    "action" : "telemetrySample",
    "audit_id" : "6DC7148F-3C44-4010-84EA-1739F4F17728",
    "detail" : "battery 100%, 34.3°C, memory 60%, free 42 GB",
    "duration_seconds" : 0.181,
    "exit_status" : 0,
    "job_id" : "7F3C1D20-4B8E-4C9A-9F01-2D6B5A8C9E10",
    "job_name" : "C4-6 firing check",
    "outcome" : "succeeded",
    "skipped_ticks" : 0,
    "started_at" : "2026-10-25T07:25:52Z"
  }
}
```

Store after the tick — `lastRunAt` advanced, outcome recorded:

```
lastRunAt 2026-10-25T07:25:52Z | lastOutcome succeeded | enabled True
```

Audit log `~/Library/Application Support/PixelDesktop/device-audit.json`, one record:

```json
{"operation": "scheduledTaskRun", "outcome": "executed",
 "detail": "battery 100%, 34.3°C, memory 60%, free 42 GB"}
```

The telemetry figures are the phone's own values, so the device effect is observed rather than
inferred: the process read the physical Pixel 7a.

## Tick 2 — not due, coalesced

Second `kickstart` eleven seconds later:

```json
"scheduled_run" : {
  "action" : "telemetrySample",
  "detail" : "Not due yet; the previous run already satisfied this interval.",
  "duration_seconds" : 0,
  "exit_status" : 0,
  "outcome" : "skipped",
  "skipped_ticks" : 0
}
```

`lastRunAt` unchanged, audit record count still 1, exit status 0. launchd fires on its own clock; a tick
that arrives early is not an error and must not read the device or inflate the log with failures.

## Cleanup

The agent was booted out, the plist removed, and the store, audit log and log directory deleted — none
of them existed before this run. The machine is left as found; the app will recreate them when the
operator creates a job.

## Not verified here

- **C4-7 on real hardware.** The device was attached throughout, so the missing-device path was not
  produced live; it is covered hermetically by `Phase3SchedulerTests` (nil serial → `.failed` report,
  audit record, non-zero exit). Producing it live needs the cable pulled, which is an operator action.
- **The installer path** (`LaunchAgentInstaller`) end to end, for the reason stated above.

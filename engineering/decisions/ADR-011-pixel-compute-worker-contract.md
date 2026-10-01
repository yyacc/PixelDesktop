# ADR-011: Pixel Compute Worker Contract

## Status

Accepted

## Date

2026-10-02

## Context

Phase 5 D8 delivers the first real compute node: a worker APK that performs DTCA-1 on the
physical Pixel 7a and returns a result the Mac verifies independently (ADR-004). Ten decisions
were approved for this phase (D-1…D-10). This ADR records the resulting contract and, critically,
**the assumptions that real-device execution falsified** — because the design changed as a result
and the reasons must not be lost.

## Problem

What is the smallest real, measurable, safe compute boundary between PixelDesktop and the Pixel,
and what does that boundary actually guarantee?

## Decision

### 1. The worker is a one-shot Activity

`com.pixeldesktop.worker/.WorkerActivity`. No Service, no daemon, no persistent process, no
process supervisor, no broadcast receiver, no provider.

Lifecycle, bounded and self-terminating:

```
launch → read fixed job file → compute → write fixed result → finish
```

Verified on the real device across unlocked/active, locked/screen-off, deep doze, repeated
invocation, and already-running states. A duplicate invocation reuses the existing process rather
than creating a second one.

**A Service was rejected** because it would require the `POST_NOTIFICATIONS` runtime permission
(measured `prot=dangerous` on this device), a persistent notification, a service lifecycle, and
exposure to Android background-execution limits — four additions to do work that finishes in
~250 ms.

### 2. Communication is file-based exchange over ADB

```
Mac  →  adb push job.json  →  exchange directory
                                  ↓ read (app UID)
                             Worker Activity  →  compute  →  write result.json
                                  ↓
Mac  ←  adb pull / cat result.json
```

**No HTTP, no TCP listener, no socket, no RPC, no port forwarding, no `adb reverse`, no network
exposure.** Verified necessary by construction: a protocol would require a daemon inside the app,
and the payload is one small JSON document each way.

### 3. The exchange directory is the worker's own external files directory

```
/sdcard/Android/data/com.pixeldesktop.worker/files/{job.json,result.json}
```

Owned by the **app's** UID, mode `drwxrws---`, not readable by other applications, and reachable
by adb through its `ext_data_rw` group membership.

**The directory must be created by the worker, not by adb.** This was falsified during
implementation: an adb-created directory is owned by `shell:ext_data_rw`, which the app cannot
write. See "Assumptions falsified" below.

### 4. The worker declares zero permissions

Verified on the device, not from source: `dumpsys package com.pixeldesktop.worker` reports no
requested-permissions block. Every candidate was evaluated and rejected with a reason
(`INTERNET`, `POST_NOTIFICATIONS`, `FOREGROUND_SERVICE`, `READ/WRITE_EXTERNAL_STORAGE`,
`MANAGE_EXTERNAL_STORAGE`, `WAKE_LOCK`, `REQUEST_INSTALL_PERMISSIONS`).

### 5. The Activity is exported, with three mitigations

**This was forced by falsified assumption 1** — a non-exported Activity cannot be started by adb
at all. Since export is required, exposure is contained by:

1. **No intent-filter** — only an explicit component start reaches it; no implicit launch.
2. **No Intent extras are read** — the Activity takes no input from its caller.
3. **Runtime launcher check** — `getLaunchedFromUid()` must be `-1` (adb), `0` (root), or `2000`
   (shell). Any other concrete UID is refused.

Residual exposure, stated plainly: **another app may trigger a re-run of whatever job file is
already present.** It cannot supply input, read the result, or alter behaviour.

### 6. `job_id` is the anti-staleness mechanism

The worker echoes the submitted `job_id`. A mismatch means the file is from a previous run and is
rejected. Fixed filenames make staleness otherwise indistinguishable.

**This is a staleness check, not an authenticity check.** It does not prevent a malicious writer
from forging a matching id.

### 7. Measurement is one-shot reads, not a monitoring subsystem

| Evidence | Source | Attributable to the worker? |
|---|---|---|
| CPU time | `/proc/<pid>/stat` utime+stime | **Yes** — per-process, by definition |
| Process identity | `/proc/<pid>/cmdline`, `pidof` | **Yes** |
| Memory | `/proc/<pid>/status` `VmRSS` | **Yes** |
| Execution time | wall clock + worker-reported duration | Yes |
| Thermal | `dumpsys thermalservice` | **No — system-wide** |

CPU ticks are sampled **while the process is alive**, not as a before/after delta: the worker
finishes in ~250 ms including startup, so an "after" reading usually does not exist.

**Thermal is observable and measurable but NOT attributable.** `dumpsys thermalservice` reports
SoC-cluster sensors influenced by every process, by charging, and by ambient temperature. It is
reported as *device thermal state during the run*, never as the worker's consumption.

### 8. Verification is independent re-computation

`ResultVerifier` compares the worker's result against a local DTCA-1 run on the Mac. The worker is
never trusted. A mismatch is a finding, returned rather than thrown.

### 9. Installation is a narrow, separate concern

`WorkerInstaller` owns package identity, install/replace semantics, and version detection.
`TransportProtocol.install` is a narrow primitive. Installation is **state-changing**, unlike
push/pull, and is never exposed to the UI or Hermes.

### 10. Containment remains by narrowness

Two fixed filenames, fixed directories, **no caller-supplied paths**, regular files only, size caps,
size verification. Unchanged from ADR-010.

---

## Assumptions Falsified During Implementation

Recorded because the design changed as a result. Full detail: `failures/FAIL-004`.

| # | Assumption | Reality | Consequence |
|---|---|---|---|
| 1 | `exported="false"` still lets adb start the Activity | `SecurityException: not exported from uid 10004` | Export required; containment via no-intent-filter + launcher check |
| 2 | `getLaunchedFromUid()` returns `2000` for an adb launch | Returns **`-1`** | The launcher check refused every legitimate run until corrected |
| 3 | adb may create the exchange directory | Created as `shell:ext_data_rw`; the app **cannot write it** | The worker creates its own directory; adb's `mkdir` was removed |

**All three compiled cleanly and passed all 154 unit tests.** Each was caught only by executing on
the physical device. They are the fourth, fifth and sixth such defects in this project.

**The pattern is consistent:** a mock asserts what the code *sends*; it cannot reproduce what the
platform *does*.

---

## The Claim This Architecture Supports

The compute proof establishes, with evidence rather than assertion:

| Evidence | Rules out |
|---|---|
| installed `versionCode` = 1 | a different app running |
| worker **PID** and `/proc/<pid>/cmdline` matching the package | the Mac doing the work |
| execution began **after** job delivery, with the result file deleted first | a stale result reused |
| `job_id` echoed by the worker | a result from a previous run |
| **CPU ticks consumed by that PID** (observed: 20 ticks) | a result fabricated without computing |
| independent local re-computation matching | a wrong-but-plausible result |

Measured result: **VERIFIED**, 3/3 repeated runs verified, ~250–360 ms wall clock per run,
20 CPU ticks attributable to the worker process.

**Not claimed:** that 20 ticks is the *DTCA-1 computation alone*. It covers the whole process
lifetime including Android app startup. Reported as process CPU, not computation CPU.

---

## Consequences

- `TransportProtocol` gains `install`; `push`/`pull`/`shell` unchanged.
- New `Worker/` components: `WorkerInstaller`, `WorkerLifecycle`, `DTCA1Job`,
  `WorkerResultEnvelope`, `WorkerComputeProof`.
- `WorkerTransferContract` root moved to the app's external dir; `remoteWorkspaceCreateCommand`
  **removed** and replaced by an existence check, so adb cannot create the directory.
- The Android project `DTCA1Worker/` is added to the repository (sources, not build output).
- 154 tests pass; real-device compute proof PASS.
- `engineering/created-resources.json` is now tracked (it had been gitignored by mistake, contrary
  to master prompt §28).

## Rejected Alternatives

- **Service / daemon** — a permission, a notification, a lifecycle, and background-execution
  limits, for a ~250 ms bounded task.
- **HTTP / socket / RPC** — infrastructure for one request each way.
- **Broadcast receiver** — asymmetric; cannot return a result.
- **`am start` + stdout** — an Activity's stdout is not returned to `am`.
- **Non-exported Activity** — falsified; adb cannot start it.
- **adb-created exchange directory** — falsified; the app cannot write it.
- **Per-run filenames** — would reintroduce a variable path and require the validator ADR-010
  mandates before any variable-path contract.
- **A monitoring subsystem** — the required evidence is a delta, not a stream.
- **A release keystore** — out of scope; must never be committed.

## Future Reconsideration Conditions

- **Any variable-path contract** → ADR-010 must be revisited and a real path validator written
  first. Unchanged and still binding.
- **Any change of writer or creator identity** → re-check that the new identity can reach every
  path, **and** that it owns any directory it must write to. FAIL-004 instance 3 exists because
  ownership, not just reachability, matters.
- **If a device with a lock credential is used** → the launch path is untested there.
- **If DTCA-1 proves too fast for useful resource evidence** → add the SHA-256 chain as a
  secondary workload (D-3), decided by measurement.
- **If the UI or Hermes needs a new capability** → add a *named* operation; never widen `shell()`,
  `install`, or the path contract.
- **Phase 6 (Local AI Worker)** → this contract does not extend to model inference; that is its own
  decision.

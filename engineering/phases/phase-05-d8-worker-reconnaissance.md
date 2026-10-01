# D8 Reconnaissance & Proposal — The Minimum Pixel Compute Worker

**Status:** PROPOSAL — awaiting review. **No source code modified. No APK built or installed.**
**Phase:** 5 (Pixel Compute Worker), D8 — worker APK, deferred from Part 1
**Date:** 2026-10-02
**Depends on:** Phase 5 Part 1 (transfer contract, `a34ed10`)

---

## 1. Findings

Every finding below was measured on the attached Pixel 7a (`3C261JEHN25632`). Nothing is
inferred from documentation. **No state-changing probe was performed** — no install, no
uninstall, no launch.

### F1 — `adb` runs as `uid=2000(shell)` with `ext_data_rw` in its supplementary groups

```
uid=2000(shell) gid=2000(shell) groups=...,1015(sdcard_rw),1028(sdcard_r),
                                    1078(ext_data_rw),1079(ext_obb_rw),3009(readproc),...
```

Three consequences, each verified separately:

- `1015(sdcard_rw)` — general external storage access
- `1078(ext_data_rw)` — **access to application-specific external directories**
- `3009(readproc)` — **read access to other processes' `/proc` entries**

### F2 — adb can read, write, push and pull inside an app's external files dir

Verified by writing a file into an existing app's directory and reading it back:

```
$ adb shell 'echo PIXELDESKTOP_CHANNEL_TEST > /sdcard/Android/data/com.fiio.control/files/pd_channel.txt'
WROTE_OK
$ adb shell cat /sdcard/Android/data/com.fiio.control/files/pd_channel.txt
PIXELDESKTOP_CHANNEL_TEST
$ adb shell ls -l .../pd_channel.txt
-rw-rw---- 1 shell ext_data_rw 26 ... pd_channel.txt

$ adb push /tmp/src.txt /sdcard/Android/data/com.fiio.control/files/pd_push.txt   → exit 0
$ adb pull /sdcard/Android/data/com.fiio.control/files/pd_pull.txt /tmp/dst.txt   → exit 0
```

The directory mode is `drwxrws---` (owner + `ext_data_rw` group only), so **it is not
readable by other applications** — but adb is in that group. This is the channel.

### F3 — `/data/local/tmp` is **NOT writable by an Android application**

```
drwxrwx--x 2 shell shell /data/local/tmp     (mode 771, owner shell)
```

`others` get `--x` — traverse only, **no write**. An app runs under its own UID, is not in
group `shell`, and `su` does not exist (`/system/bin/sh: su: inaccessible or not found`).

**An app cannot write `/data/local/tmp`.** Phase 5 Part 1's remote root is writable only by
adb, which is fine for the current fixed-file contract but **cannot host worker output**.
This requires revisiting ADR-010 (see §6 and §18).

### F4 — App-private internal storage is unreachable without root

```
$ adb shell ls /data/data/com.android.settings/files
Permission denied
$ adb shell run-as com.android.settings ls
run-as: package not an application: com.android.settings
```

`/data/data/<pkg>` is not a usable channel. `run-as` works only for debuggable apps and is a
development affordance, not a production channel.

### F5 — A PixelDesktop Android app is **already installed and working on this device**

```
package:com.pixeldesktop.metadata
  codePath=/data/app/~~IZ57cVDY4CBX_BERxOSGaw==/com.pixeldesktop.metadata-.../base.apk
  versionCode=1  versionName=1.0  minSdk=31  targetSdk=36
  firstInstallTime=2026-09-22 15:14:48
```

The full Android chain — Gradle build → adb install → running app — is **proven end-to-end on
this exact device**. There is no build-system risk to retire.

### F6 — Resource measurement without root

| Metric | Mechanism | Verified |
|---|---|---|
| **CPU time** | `/proc/<pid>/stat` fields 14/15 (utime/stime, clock ticks) | ✅ readable for another UID's process |
| **RSS** | `/proc/<pid>/status` `VmRSS`, or `/proc/<pid>/statm` | ✅ `VmRSS: 345536 kB` |
| **Threads** | `/proc/<pid>/status` `Threads` | ✅ |
| **Per-process CPU% / RES** | `top -n 1 -b -o PID,USER,RES,%CPU,CMDLINE` | ✅ one-shot |
| **Per-package memory (PSS)** | `dumpsys meminfo <pkg>` | ✅ 3,480 bytes output |
| **System load** | `/proc/loadavg`, `uptime` | ✅ `5.80 4.78 2.96` |
| **Thermal** | `dumpsys thermalservice` | ✅ see F7 |
| **Battery** | `dumpsys battery` | ✅ `level: 95`, `temperature: 328` (32.8 °C) |

`/proc/<pid>/stat` being readable is what makes CPU-time measurement possible without root.

### F7 — Thermal **is** observable without root

Direct sysfs is denied:

```
$ adb shell cat /sys/class/thermal/thermal_zone0/temp
Permission denied
```

But `dumpsys thermalservice` exposes it:

```
Thermal Status: 0
Cached temperatures:
  Temperature{mValue=67.0,    mType=0,  mName=LITTLE,         mStatus=0}
  Temperature{mValue=38.895,  mType=-1, mName=neutral_therm,  mStatus=0}
  Temperature{mValue=32.907,  mType=-1, mName=disp_therm,     mStatus=0}
```

The master prompt asks for thermal "if observable". **It is observable**, via a documented
interface. This satisfies that requirement without root and without a monitoring subsystem.

### F8 — Install mechanism

`adb install` is available with the flags needed: `-r` (replace), `-d` (allow downgrade,
debuggable only), `-g` (grant runtime permissions), `--no-streaming`, `--abi`.
`pm install` / `cmd package install` also exist but require a package size or APK argument
and are the on-device equivalents. **PixelDesktop needs only `adb install`.**

### F9 — Execution mechanism

`am start-activity`, `am start-service`, `am start-foreground-service`, `am broadcast` are all
available. `am force-stop <pkg>` stops an app.

### F10 — Permissions posture

`POST_NOTIFICATIONS` is `prot=dangerous` on this device (a runtime permission). 
`FOREGROUND_SERVICE` is an install-time (normal) permission.

**Consequence:** a foreground service would require the runtime `POST_NOTIFICATIONS`
permission on API 33+. Avoiding a service avoids that permission entirely.

### F11 — Storage

`/data` and `/storage/emulated`: **56 GB available** of 110 GB. Not a constraint.

### F12 — Device/API identity for build configuration

Android `16`, API `36`, `arm64-v8a`, `Pixel 7a`. The existing Android project already targets
`compileSdk 36` / `minSdk 31` / `targetSdk 36`.

---

## 2. Existing Architecture Reused

**Nothing in this proposal recreates an existing abstraction.**

| Existing | Reused for |
|---|---|
| `TransportProtocol` (`execute`, `shell`, `getprop`, `getSystemProperties`, `push`, `pull`) | All device I/O. `push`/`pull`/`shell` already exist and are sufficient. |
| `ADBTransport` | Sole implementation; `push`/`pull` already narrow primitives |
| `WorkerTransferContract` | Path constants, regular-file validation, size verification |
| `WorkerOperationsProtocol` / `ADBWorkerOperations` | Job submission and result retrieval — **the D8 compute path extends this, it does not replace it** |
| `AndroidDevice` / `DeviceState` | Device identity and connectivity guards |
| `DeviceManager.requireConnectedDevice(serial:)` | Guard-first state check before every operation |
| `PixelDesktopError` | Typed failures; `workerError`, `adbCommandFailed`, `invalidInput`, `verificationFailed` |
| `DTCA1Worker` + `DTCA1Result` | The **existing local reference implementation and its result contract** |
| `ResultVerifier` | Independent verification by re-computation (ADR-004) |
| `AppLogger` | Logging |
| Android project template (`AndroidMetadataHelper`) | Gradle 8.13 / AGP 8.13.0 / Java 17 / minSdk 31 / targetSdk 36 — **proven on this device** |
| `DeviceOperation` | Extended only if a genuinely new device operation is implemented |

**What D8 must add:** exactly three things.

1. The **Android worker app** (a new Gradle project).
2. **`WorkerInstaller`** — APK installation, reinstall, version check.
3. **`WorkerLifecycle`** — start, stop, status.

Everything else already exists.

---

## 3. Minimum Worker Design

### What the APK does

Reads one job file, performs one deterministic computation, writes one result file, exits.

### The eight concrete answers

| Question | Answer |
|---|---|
| What does the APK do? | Reads `job.json`, computes, writes `result.json`, finishes |
| HTTP/RPC/socket endpoint? | **No.** None is required. |
| Accepts jobs? | Only by reading a file that was placed for it |
| What is a job? | One JSON file: a workload name, an input string, and its parameters |
| Input? | The job file, in the app's own external files dir |
| Output? | One JSON result file, same directory |
| Where is computation performed? | In the app's process, on the Pixel's CPU |
| Is it an AI runtime? | **No.** It is a process that hosts a deterministic workload. Phase 6 is where AI is introduced. |
| Smallest useful computation? | A deterministic, CPU-bound, verifiable one — see §9 |

### Deliberately absent

No service. No background component. No daemon. No socket. No HTTP. No job queue. No
scheduler. No state persisted between runs beyond the two files. No UI beyond the minimum
Android requires.

### Why a one-shot Activity, not a service

The workload is a bounded, deterministic computation taking seconds. It needs:

- to run when asked — `am start-activity` provides this
- to do bounded work — a service adds nothing
- to be measurable — a one-shot process is *easier* to measure (start/end CPU time is
  unambiguous)
- to exit — an Activity finishing is the natural termination

A service would add a lifecycle, a notification requirement (F10: a runtime permission), and
Android background-execution restrictions, **for no benefit**. It would be complexity bought
with a permission.

---

## 4. APK / Build Requirements

| Item | Value | Source |
|---|---|---|
| Package / applicationId | `com.pixeldesktop.worker` | New; distinct from `com.pixeldesktop.metadata` |
| `minSdk` | **31** | Matches the proven template; Android 12+ |
| `targetSdk` | **36** | Matches device API (F12) |
| `compileSdk` | **36** | Installed platform (`android-36`) |
| Build system | **Gradle 8.13 + AGP 8.13.0** | Same as the proven template; wrapper already cached locally |
| Language | **Java 17** | Same as the proven template; no Kotlin toolchain needed |
| Debug build | `debuggable`, self-signed debug keystore | Required for development |
| Release build | **Not required for D8.** If produced, needs a keystore and must not be committed | Deferred |
| Output | `app/build/outputs/apk/debug/app-debug.apk` | Standard |

### Is a new Android project necessary?

**Yes, but it is a near-copy of an existing one.** `AndroidMetadataHelper` is a working
single-Activity Java app that builds and runs on this device (F5). The worker needs the same
skeleton with different logic.

### Smallest possible structure

```
DTCA1Worker/                      (new Gradle project, sibling of the macOS app)
├── settings.gradle               (rootProject.name = "DTCA1Worker")
├── build.gradle                  (AGP 8.13.0, apply false)
├── gradle.properties
├── gradlew / gradlew.bat
├── gradle/wrapper/               (gradle-8.13-bin)
└── app/
    ├── build.gradle              (namespace/applicationId com.pixeldesktop.worker,
    │                              compileSdk 36, minSdk 31, targetSdk 36)
    └── src/main/
        ├── AndroidManifest.xml   (ONE activity, exported=false where possible, ZERO permissions)
        └── java/com/pixeldesktop/worker/
            ├── WorkerActivity.java   (entry: read job, compute, write result, finish)
            ├── JobSpec.java          (job parsing + validation)
            ├── JobResult.java        (result construction)
            └── Workloads.java        (the deterministic computation)
```

**Six source files plus build scaffolding.** No resources beyond the manifest. No libraries
beyond the Android SDK (JSON via `org.json`, already in the platform — the template uses it).

**Location:** `~/AICompany/PixelDesktop/DTCA1Worker/` (the Phase 0 audit's §8 structure
already anticipated a `DTCA1Worker/` directory alongside the macOS app).

---

## 5. Installation Contract

### Required commands

| Operation | Command |
|---|---|
| Install | `adb install -r <apk>` |
| Reinstall / upgrade | `adb install -r <apk>` (same as install) |
| Version query | `adb shell dumpsys package com.pixeldesktop.worker \| grep versionCode` |
| Uninstall | `adb uninstall com.pixeldesktop.worker` (not needed by D8) |

`-r` makes install and reinstall the same operation, which is the correct semantic: the worker
is installed once and replaced when the APK changes.

### Investigated behaviours

| Case | Behaviour |
|---|---|
| Already installed | Without `-r`: `INSTALL_FAILED_ALREADY_EXISTS`. With `-r`: replaced. |
| Upgrade | `-r` replaces; `versionCode` must increase, or `INSTALL_FAILED_VERSION_DOWNGRADE` |
| Downgrade | Requires `-d`, which only works for **debuggable** packages. Debug build only. |
| Package mismatch | `-r` with a different `applicationId` fails — it replaces only the same package |
| Invalid APK | `adb install` exits non-zero with a `Failure [...]` message |
| Installation failure | Non-zero exit + diagnostic on stdout |
| Disconnected device | `adb: device not found`, non-zero exit |
| Insufficient storage | `INSTALL_FAILED_INSUFFICIENT_STORAGE` (not a constraint here — 56 GB free) |
| Privilege required | **None.** Installing via adb needs no root and no user interaction beyond USB debugging. |

### Architectural placement

```
TransportProtocol            ← `install` primitive (new, narrow)
      ↓
WorkerInstaller              ← policy: which APK, version check, replace semantics
      ↓
adb install / dumpsys package
```

**D8 needs one new transport primitive:** `install(deviceSerial:apkPath:replace:timeout:)`.
It is a narrow primitive in the same sense as `push`/`pull` — it takes an
already-validated absolute APK path and performs no policy.

### Install is NOT the same as the transfer contract

APK installation is a **state-changing device operation**, unlike push/pull. It must:

- be an explicit, named operation (`WorkerInstaller.ensureInstalled(apkPath:)`)
- never be exposed to the UI or Hermes as "install this file"
- validate that the APK path is a regular file (reusing `WorkerTransferContract`'s rule)
- be idempotent: check `versionCode` first, install only if different

---

## 6. Permission Requirements

### Recommended: **zero permissions**

| Candidate | Needed? | Why | If avoided |
|---|---|---|---|
| `INTERNET` | **No** | The channel is file-based over ADB. No network is used. | No network attack surface at all |
| `POST_NOTIFICATIONS` | **No** | Only needed for a foreground service. There is no service. | No runtime permission prompt |
| `FOREGROUND_SERVICE` | **No** | No service exists. | — |
| `READ_EXTERNAL_STORAGE` / `WRITE_EXTERNAL_STORAGE` | **No** | The app's own external files dir needs **no** permission on API 19+. | No broad storage access |
| `MANAGE_EXTERNAL_STORAGE` | **No** | Would grant whole-storage access. Not needed and dangerous. | — |
| `WAKE_LOCK` | **No** | The computation is short and runs while the activity is visible. | — |
| `REQUEST_INSTALL_PACKAGES` | **No** | The app installs nothing. | — |
| `ACCESS_NETWORK_STATE` | **No** | No network use. | — |

**Zero permissions is not a simplification — it is the correct posture.** The worker reads a
file in its own directory, computes, and writes a file in its own directory. Android requires
no permission for any of that. Every candidate permission above would add risk without adding
capability.

The one thing to verify during implementation: the app must use
`getExternalFilesDir(null)` (its own app-specific directory), **not** shared external storage.

---

## 7. Lifecycle Proposal

### Proposed minimal state model

The master prompt's suggested six-state chain is **larger than this worker needs**. For a
one-shot Activity:

```
NOT_INSTALLED
     ↓  (install)
  INSTALLED
     ↓  (am start)
  RUNNING  ──→ FINISHED     (result written)
           └─→ FAILED       (error result written, or no result)
```

`STARTING` and `STOPPING` are **transitions, not observable states** — there is no moment
where the Mac can meaningfully observe "starting but not running". `STOPPED` is not
distinguishable from `INSTALLED` for a one-shot activity, because the process exits on its
own. Collapsing them removes states that would exist only to be immediately passed through.

### Investigated behaviours

| Case | Determination |
|---|---|
| Start | `am start -n com.pixeldesktop.worker/.WorkerActivity` |
| Stop | `am force-stop com.pixeldesktop.worker` |
| Crash | No result file; `pidof` empty; `logcat` records the exception |
| Restart | Just start it again — no state to restore |
| Stale process | Detect with `pidof <pkg>` before starting; force-stop first if present |
| Duplicate worker process | **Possible risk:** two `am start` calls could overlap. Mitigate by force-stopping before start, and by a `job_id` check in the result |
| Device disconnect | Guard-first (`requireConnectedDevice`) before any operation |
| Worker version mismatch | Compare installed `versionCode` against the expected value before starting |
| Already running | Force-stop, then start (deterministic, avoids overlap) |
| Not responding | Timeout on result-file polling → `workerError` |

### Force-stop is destructive-capable

`am force-stop` kills the worker and discards in-flight work. It is the same class of operation
as Phase 4's `stopApplication`, and gets the same treatment: explicit package, no wildcards,
contained in `WorkerLifecycle`, never exposed as an arbitrary "stop this package".

---

## 8. Communication Boundary

### Evaluation of the candidate mechanisms

| Mechanism | Verdict |
|---|---|
| **File-based exchange over ADB** | **Chosen.** adb can read/write the app's external files dir (F2). No daemon, no protocol, no permission, no network. |
| ADB port forwarding (`adb forward`) | Rejected. Requires a listening socket **inside the app** — a daemon, a service, and a protocol. |
| `adb reverse` | Rejected. Same requirement, in the other direction. |
| localhost TCP socket | Rejected. Needs a service and a protocol; adds a network surface. |
| Unix domain socket | Rejected. Not reachable from the Mac across the ADB boundary without forwarding. |
| HTTP | Rejected. Master prompt §5.2 explicitly lists "networking layers" as premature; a protocol and a server are needed for one request. |
| Broadcast | Rejected. Asymmetric — it can start work but cannot return a result. |
| `am start` + stdout | Rejected. An Activity's stdout is not returned to `am`; the result would still need a file. |

### The chosen boundary

```
Mac                                        Pixel 7a
 │                                              │
 │  1. adb push  job.json  ──────────────────►  /sdcard/Android/data/
 │                                              com.pixeldesktop.worker/files/job.json
 │  2. adb shell am start -n .../.WorkerActivity
 │                                              │
 │                                              ▼  worker reads job.json
 │                                              ▼  computes on Pixel CPU
 │                                              ▼  writes result.json
 │  3. adb pull  result.json  ◄──────────────  .../files/result.json
 │                                              │
 ▼  verify by independent re-computation (ADR-004)
```

**Three ADB operations. No protocol. No server. No daemon. No network.**

### Network exposure

**None, and none required.** The worker has no `INTERNET` permission (§6), opens no socket,
and listens on nothing. Nothing outside the USB/ADB boundary can reach it.

### Reuse

This is the **existing `WorkerOperationsProtocol` flow from Part 1** with the job/result
payloads replaced. `submitInput`/`retrieveResult` already implement push/pull with size
verification. D8 changes *what* is transferred, not *how*.

### One revision required to ADR-010

Part 1 fixed the remote root at `/data/local/tmp/pixeldesktop`, which **an app cannot write**
(F3). The worker's files must live in the app's own external dir:

```
/sdcard/Android/data/com.pixeldesktop.worker/files/{job.json,result.json}
```

This is a **narrowness-preserving change**: still two fixed filenames, still no caller-supplied
paths, still one file each way. The root moves because the writer's identity changed from adb
to an app. See §18 for the ADR recommendation.

---

## 9. Compute-Proof Proposal

### What the first proof must establish

Not "we can run a model". It must establish that **the Pixel's CPU actually performed the
computation**, and that the result is verifiable without trusting the worker.

### Proposed workload: iterated SHA-256 chain

```
output = SHA-256^N(input)
```

`N` supplied by the job. The worker computes the chain; the Mac recomputes it independently
and compares.

### Why this workload

| Requirement | How it is met |
|---|---|
| Deterministic | SHA-256 is exact; same input + same N = same output, always |
| Independently verifiable | The Mac recomputes locally (ADR-004) — **no trust in the worker** |
| Genuinely computed on the Pixel | `output` is 256 bits; a wrong or skipped computation cannot collide |
| CPU-bound | Real work, real time, real thermal signal |
| Tunable | `N` scales duration from milliseconds to minutes, so the same workload measures the device across a range |
| No dependencies | `MessageDigest` is in the platform — no library, no model, no download |
| No permission | Pure computation |
| Fast to implement | ~30 lines of Java |
| Small payload | Input ≤ 10 KB, output 64 hex chars |

### Why not the existing DTCA-1 text workload

`DTCA1Worker` already exists locally and is the project's declared first workload (ADR-003,
ADR-004). It is **also a valid candidate** and has the advantage of already having a defined
result contract and verifier.

**Recommendation: implement DTCA-1 as the worker's workload**, because:

- ADR-003 and ADR-004 already specify it, including its result contract and verification
- `DTCA1Worker` and `ResultVerifier` already exist and are tested
- It is deterministic and independently verifiable
- Reusing it means D8 introduces **no new verification concept**

and **add the SHA-256 chain as a second, secondary workload** only if a pure-CPU workload is
wanted for thermal measurement — because DTCA-1's text processing may be too fast to produce
a measurable thermal signal.

**This is a decision for review (D-3 below).**

### What the proof does NOT include

No LLM. No model download. No model management. No GPU. No NPU. No inference runtime.
Master prompt: "Do not begin with distributed AI."

---

## 10. Resource-Measurement Proposal

### Required evidence (master prompt Phase 5)

| Required | Mechanism | Reliable without root? |
|---|---|---|
| Execution time | Wall clock around the job, plus `execution_duration_ms` from the worker | ✅ |
| CPU utilisation | `/proc/<pid>/stat` utime+stime before/after; `top -n 1 -b` | ✅ (F6) |
| Memory | `/proc/<pid>/status` `VmRSS`; `dumpsys meminfo <pkg>` for PSS | ✅ |
| Result correctness | Mac re-computation (ADR-004) | ✅ |
| Process identity | `pidof <pkg>`, `/proc/<pid>/stat` field 2 (process name) | ✅ |
| **That computation occurred on the Pixel** | CPU time consumed **and** a correct 256-bit / structured result that the Mac independently reproduced | ✅ |
| Reliability | Repeat N times, count successes | ✅ |
| Lifecycle | Observe `pidof` transitions across the run | ✅ |
| Failure behaviour | Exercise the §12 cases | ✅ |
| Thermal "if observable" | `dumpsys thermalservice` (F7) | ✅ **observable** |

### Scope boundary

**No resource-monitoring subsystem.** Measurement is a set of one-shot reads around a job:

1. before: `pidof`, `/proc/<pid>/stat` (or system load), `dumpsys thermalservice`
2. run
3. after: same reads, plus `dumpsys meminfo`

That is **evidence collection, not monitoring**. No sampling loop, no time series, no
persistence, no dashboard. Master prompt §5.2 forbids "resource orchestration" — this is not
that.

### The "did it really run on the Pixel?" evidence

This deserves an explicit answer, because it is the actual claim being proved:

1. **CPU time was consumed by the worker's PID** on the device (`/proc/<pid>/stat` delta).
2. **The PID belongs to the worker package** (process name from `/proc/<pid>/stat`).
3. **The result is correct** and the Mac reproduced it independently.
4. **The result could not have been produced without computing** — a 256-bit hash chain has no
   shortcut, and DTCA-1's counts are derived from the input.

Points 1–2 prove the work happened on the device; point 3 proves it was correct; point 4
proves it was not faked.

---

## 11. Failure Semantics

Deterministic reporting, no automatic complexity. No retries unless explicitly requested.

| Failure | Detection | Reported as |
|---|---|---|
| Worker not installed | `dumpsys package` finds no package | `workerError("worker not installed")` |
| Installation failure | `adb install` non-zero exit | `adbCommandFailed` with the installer diagnostic |
| Worker won't start | `am start` non-zero, or no process appears | `workerError("worker did not start")` |
| Worker crashes | No result file; `pidof` empty; `logcat` has the stack trace | `workerError("worker exited without a result")` |
| Worker hangs | Result-file poll exceeds the timeout | `timeout(operation:duration:)` |
| Malformed job | Worker validates and writes a `FAILED` result | `verificationFailed` / `workerError` |
| Malformed result | `JSONDecoder` throws | `verificationFailed` (ADR-004: never trust) |
| Timeout | Wall-clock budget exceeded | `timeout` |
| Device disconnect | Guard-first check, and non-zero adb exit | `deviceNotFound` / `deviceOffline` |
| ADB disconnect mid-transfer | Non-zero adb exit | `adbCommandFailed` |
| Communication failure | push/pull non-zero exit, or size mismatch | `adbCommandFailed` / `workerError` |
| Duplicate request | `job_id` in the result ≠ the submitted `job_id` | `workerError("stale result")` |
| Stale result | Result file present **before** the job was submitted | `workerError("stale result")` — mitigated by deleting the result file before each run |
| Worker version mismatch | Installed `versionCode` ≠ expected | `workerError("worker version mismatch")` |

**`job_id` is the anti-staleness mechanism.** The worker echoes the submitted `job_id`; a
mismatch means the file is from a previous run and must not be trusted. This is the
reliability guard the fixed filenames require.

---

## 12. Security Analysis

### The honest position

**The worker is NOT a security boundary.** It is a process on a device the Mac already fully
controls via ADB. Stating otherwise would overstate the evidence. What follows is what *is*
true.

| Concern | Analysis |
|---|---|
| **APK trust** | The APK is built from this project's source on this machine. Trust derives from the build, not from the APK format. |
| **Package identity** | `com.pixeldesktop.worker` is a name, not a security property. Any app can claim any free package name. Identity here means "the package we installed", verified by `versionCode` and, if needed, signing certificate. |
| **Signing** | Debug builds are signed with the standard debug keystore — **not secret, not a trust anchor**. A release build would need a real keystore. D8 does not need one, and must not commit one. |
| **Arbitrary code execution** | The worker executes **only** the compiled workloads in its own APK. It does not interpret code, load scripts, or accept a workload *implementation* from outside. The job names a workload; it cannot supply one. |
| **Arbitrary command execution** | The worker runs **no** shell commands. It does not call `Runtime.exec`, `ProcessBuilder`, or `sh`. Its only I/O is two files in its own directory. |
| **Input validation** | The job file is untrusted input and must be validated: size cap, known workload name (allowlist), bounded `N`/iteration count, no null bytes. An unknown workload name is rejected, not attempted. |
| **Worker communication authentication** | **None, and none is achievable at this layer.** Anyone with ADB access can write the job file. ADB access *is* the authentication boundary. |
| **Network exposure** | **None.** No `INTERNET` permission, no socket, no listener. |
| **ADB exposure** | This is the real boundary. Whoever holds ADB holds the device. The worker neither widens nor narrows that. |
| **Filesystem access** | Confined to the app's own external files dir. No shared storage, no `/data/data`, no `/data/local/tmp`, no traversal (the paths are constants). |
| **Android permissions** | **Zero.** No capability beyond its own sandbox. |
| **Can the worker escape its intended scope?** | It can write files in its own external dir and consume CPU. It cannot reach the network, other apps' data, or system storage. **Its blast radius is its own sandbox**, which is the correct outcome. |

### The two real boundaries

1. **ADB access.** Full device control. The worker does not change this.
2. **The device's privilege posture.** Not rooted, not debuggable (established in ADR-009),
   so no app can escalate.

### What must not be claimed

- That the worker is sandboxed *from the Mac* — it is not; ADB controls it entirely.
- That the file channel is authenticated — it is not; it is protected only by ADB access.
- That the debug signature provides integrity — it does not.

### Risks introduced by D8

| Risk | Mitigation |
|---|---|
| A malicious job file causes the worker to misbehave | Workload allowlist, bounded parameters, no code interpretation, no shell |
| An unbounded iteration count burns the CPU | Hard cap on `N`, enforced in the worker **and** validated before submission |
| A crafted input crashes the worker | Worker writes a `FAILED` result rather than crashing silently; Mac treats a missing result as failure |
| `am force-stop` used as an arbitrary kill | Contained in `WorkerLifecycle`; explicit package only |

---

## 13. Proposed Architecture

```
                    AppState / caller
                          │  names a job; supplies no path
                          ▼
        ┌─────────────────┼──────────────────┐
        ▼                 ▼                  ▼
 WorkerInstaller   WorkerLifecycle   WorkerOperations        ← worker policy layer
  ensureInstalled   start / stop /    submitJob /
  versionCode check status            retrieveResult
        │                 │                  │
        └─────────────────┼──────────────────┘
                          ▼
                  TransportProtocol        ← narrow primitives, no policy
        execute · shell · push · pull · install (new)
                          ▼
                    ADBTransport
                          ▼
                    adb  →  Pixel 7a
```

| Layer | Owns | Does not |
|---|---|---|
| Caller | Job content | Any path, any command |
| `WorkerInstaller` | Which APK, version policy, replace semantics | Know about jobs |
| `WorkerLifecycle` | Start/stop/status, stale-process handling | Know about jobs or APKs |
| `WorkerOperations` | Job submission, result retrieval, `job_id` check | Know about APKs or lifecycle |
| `WorkerTransferContract` | Path constants, regular-file validation, size verification | Any device policy |
| `TransportProtocol` | Executing adb; one new `install` primitive | Any policy |

**Four separated concerns**, per the requirement: transport primitives · worker policy · APK
installation · worker lifecycle · compute execution.

`DeviceOperation` gains `.installWorker` and `.executeWorkload` **only when implemented**.

---

## 14. Explicit Non-Goals

D8 will **not** implement, and none of these is required by the authoritative Phase 5 text:

- LLM inference (Phase 6)
- Model downloading, model management, model storage
- Arbitrary APK execution or installation from arbitrary sources
- Arbitrary shell execution
- Generalized RPC
- Network server exposure of any kind
- Root access or privilege escalation
- GPU driver manipulation
- APK modification or repackaging
- Code injection
- Anti-cheat mechanisms
- A generalized process manager
- A generalized Android package manager
- A resource scheduler
- A resource-monitoring subsystem (measurement is one-shot reads around a job)
- UI work (Phase 8)
- Multi-device support
- A job queue, retry engine, or scheduler
- Kotlin, or any library beyond the Android SDK

Also explicitly **not** in D8: `push`/`pull` changes (Part 1 is complete and sufficient).

---

## 15. Real-Device Evidence

All probes read-only. **No install, no uninstall, no launch, no state change.**

| # | Probe | Result |
|---|---|---|
| 1 | `adb shell id` | `uid=2000(shell)` groups include `sdcard_rw`, **`ext_data_rw`**, **`readproc`** |
| 2 | Write into an app's external files dir | **WROTE_OK**, read back correctly |
| 3 | `adb push` into an app's external dir | exit 0 |
| 4 | `adb pull` from an app's external dir | exit 0, content correct |
| 5 | `ls -ld /data/local/tmp` | `drwxrwx--x shell shell` — **mode 771, app cannot write** |
| 6 | `ls -ld` an app's external dir | `drwxrws--- u0_a343 ext_data_rw` — not world-readable |
| 7 | `ls /data/data/<pkg>` | **Permission denied** |
| 8 | `which su` | **not found** |
| 9 | `pm list packages \| grep pixeldesktop` | **`com.pixeldesktop.metadata` installed**, minSdk 31, targetSdk 36 |
| 10 | `dumpsys package com.pixeldesktop.metadata` | `codePath=/data/app/...`, `versionCode=1`, installed 2026-09-22 |
| 11 | `/proc/<pid>/stat` for another UID's process | **readable** — utime/stime available |
| 12 | `/proc/<pid>/status` | `VmRSS: 345536 kB`, `Threads: 96` |
| 13 | `top -n 1 -b` | works; per-process `RES`, `%CPU` |
| 14 | `dumpsys meminfo <pkg>` | 3,480 bytes; TOTAL/PSS present |
| 15 | `/proc/loadavg`, `uptime` | `5.80 4.78 2.96` |
| 16 | `/sys/class/thermal/.../temp` | **Permission denied** |
| 17 | **`dumpsys thermalservice`** | **Thermal Status: 0; LITTLE 67.0 °C, neutral_therm 38.895 °C** |
| 18 | `dumpsys battery` | `level: 95`, `temperature: 328` |
| 19 | `adb install --help` | `-r -d -g --no-streaming --abi` available |
| 20 | `am` help | `start-activity`, `start-service`, `start-foreground-service`, `broadcast`, `force-stop` |
| 21 | `df -h` | 56 GB available |
| 22 | Device identity | Android 16, API 36, `arm64-v8a`, Pixel 7a |

**No probe required approval**: none was destructive or state-changing. Probe files created on
the device were removed and their removal verified.

---

## 16. Risks / Unknowns

| # | Risk / unknown | Impact | Handling |
|---|---|---|---|
| R1 | **ADR-010's remote root cannot host worker output** (F3) | High — blocks the channel | Move the worker's files to the app's own external dir; requires an ADR-010 revision (§18) |
| R2 | Activity launch while the screen is locked or the device is idle | Medium — `am start` may be delayed or refused | **Unknown; must be verified empirically during implementation**, not assumed |
| R3 | Android background-execution limits | Low for a one-shot activity | Verify: the workload runs while the activity is foreground |
| R4 | `am start` returning before the process is up | Medium — race on `pidof` | Poll for the process and the result file with a bounded timeout |
| R5 | Two overlapping jobs | Medium — one result overwrites another | Force-stop before start; `job_id` mismatch detection |
| R6 | Text workload too fast for a thermal signal | Low | Add the CPU-bound SHA-256 chain as a secondary workload if needed (D-3) |
| R7 | `dumpsys thermalservice` output format varies by Android version | Low | Parse defensively; treat thermal as best-effort evidence |
| R8 | External dir path varies on some devices/OEMs | Medium | Resolve it from the app side; verify on this device before relying on it |
| R9 | Debug-signed APK | Low | Acceptable for D8; a release keystore is out of scope and must never be committed |
| R10 | Uninstall deletes the external dir, losing the channel | Low | `ensureInstalled` re-creates it |

**R2 is the most important unknown.** The master prompt's Phase 4 lesson — and FAIL-003 — both
say the same thing: **do not treat an assumed Android behaviour as fact.** Whether `am start`
reliably launches the worker on a locked/idle device must be measured, not assumed, and the
answer may shape the execution mechanism.

---

## 17. Recommended Implementation Sequence

Each step ends with a verification gate. No step assumes the next.

1. **Verify R2/R3 empirically** — with a throwaway minimal Activity (or by observing an
   existing app's launch behaviour read-only), establish whether `am start` launches reliably
   while the device is locked/idle. **Gate: measured answer, not an assumption.**
2. **ADR-011** — worker contract, channel root revision, zero-permission posture, one-shot
   execution model, security analysis.
3. **Create the Android project** from the proven template (six files + scaffolding).
4. **Build the debug APK** with Gradle; confirm the artifact exists.
5. **`WorkerInstaller`** — `install` transport primitive + `ensureInstalled` with version
   check. Gate: install, verify `versionCode`, reinstall idempotently.
6. **Job/result contract** — JSON shapes, validation, `job_id`.
7. **The worker logic** — read job, validate, compute, write result, finish.
8. **`WorkerLifecycle`** — start, stop, status, stale-process handling.
9. **`WorkerOperations`** — submit job, poll for result, retrieve, verify `job_id`.
10. **Compute proof run** — DTCA-1 (and SHA-256 chain if wanted), verified by local
    re-computation.
11. **Resource measurement** — CPU time, RSS, thermal, execution time around the run.
12. **Failure-semantics tests** — every case in §11.
13. **Repeatability** — N consecutive runs, count successes.
14. **Regression** — full Phase 1–5 suite.
15. **Documentation** — phase log, ADR-011, test report.

---

## 18. ADR Recommendation

### ADR-011: Pixel Compute Worker Contract

Record:

1. **The worker is a one-shot Activity, not a service.** Rationale: no daemon, no protocol, no
   `POST_NOTIFICATIONS` runtime permission, no background-execution restrictions, and simpler
   measurement. Rejected: foreground service, background service, broadcast.
2. **The communication boundary is file-based exchange over ADB.** No HTTP, no socket, no port
   forwarding, no reverse, no RPC. Rationale: adb already provides authenticated access to the
   app's external files dir (F2); a protocol would be infrastructure bought for one request.
3. **The worker declares zero permissions.** Every candidate permission was evaluated and
   rejected with a reason (§6).
4. **The worker is NOT a security boundary** — with the analysis in §12, stated plainly, and
   the two real boundaries named (ADB access; the device's non-rooted, non-debuggable posture).
5. **Installation is a state-changing operation** and belongs in `WorkerInstaller`, behind a
   narrow `install` transport primitive, never exposed to the UI or Hermes.
6. **`job_id` is the anti-staleness mechanism**, required by the fixed filenames.
7. **Measurement is one-shot reads, not a monitoring subsystem.**
8. **Explicit non-goals** (§14), so a later phase cannot inherit scope it was never given.

### ADR-010 revision (required, not optional)

**ADR-010 must be revised**, not merely superseded in passing, because its central decision —
the remote root — is now known to be unusable for the worker's output.

The revision must record:

- **The new finding (F3):** `/data/local/tmp` is mode 771 owned by `shell`; an Android
  application cannot write it. Part 1's contract is writable **only by adb**.
- **The new channel root:** `/sdcard/Android/data/com.pixeldesktop.worker/files/`, chosen
  because adb can read and write it via its `ext_data_rw` group (F2) while it remains
  unreadable to other applications (`drwxrws---`).
- **That the containment mechanism is unchanged:** still two fixed filenames, still no
  caller-supplied paths, still one file each way, still regular-files-only. **Only the root
  moves**, because the writer's identity changed from adb to an app.
- **That ADR-010's original rule stands:** any future variable-path contract still requires a
  real path validator first. The revision does not weaken that.

> **This is the second time in this project that a plausible assumption about the device was
> wrong and was caught by measurement** — after FAIL-003's `mkdir` permission. It is worth
> recording as a pattern, not an incident.

---

## Summary of Decisions for Review

| # | Decision | Recommendation |
|---|---|---|
| **D-1** | One-shot Activity, no service, no daemon | **Approve** |
| **D-2** | File-based exchange over ADB; no HTTP/socket/RPC | **Approve** |
| **D-3** | First workload: **DTCA-1** (existing, already specified and verifiable), with the SHA-256 chain as a secondary CPU-bound workload only if thermal measurement needs it | **Approve**, or choose SHA-256 only |
| **D-4** | Zero Android permissions | **Approve** |
| **D-5** | Channel root moves to the worker's own external files dir; **ADR-010 revised** | **Approve** |
| **D-6** | `install` as a new narrow transport primitive + `WorkerInstaller` | **Approve** |
| **D-7** | Minimal lifecycle: `NOT_INSTALLED → INSTALLED → RUNNING → FINISHED/FAILED`; drop `STARTING`/`STOPPING`/`STOPPED` | **Approve** |
| **D-8** | New Gradle project `DTCA1Worker/`, Java 17, minSdk 31, targetSdk 36, six source files | **Approve** |
| **D-9** | `job_id` as the anti-staleness mechanism | **Approve** |
| **D-10** | Measurement is one-shot reads around a job, not a monitoring subsystem | **Approve** |

**No source code was modified. No APK was built or installed. No state-changing probe was
performed.**

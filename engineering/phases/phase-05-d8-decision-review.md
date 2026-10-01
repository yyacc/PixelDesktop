# D8 Decision Review — D-1 through D-10

**Status:** REVIEW — awaiting approval. **No source modified. No APK built or installed.**
**Date:** 2026-10-02
**Depends on:** D8 reconnaissance (`cc11bea`), Phase 5 Part 1 (`a34ed10`)

Each decision below gives: **Decision · Evidence · Alternatives considered · Why this is the
minimum-complexity choice · Unresolved risk.**

---

## Precondition: the locked/idle Activity experiment (resolves D-1)

You asked for the smallest real-device experiment before approving D-1. It is done.

### Method

**Subject:** the **already-installed `com.pixeldesktop.metadata`** app — built by this project,
already on the device, single-Activity, and it logs completion via `Log.i(TAG, "METADATA_READY:…")`.
Using it required **no build and no install**.

**Work-completion signal:** the `METADATA_READY` log line — proof the Activity reached the end
of its `onCreate` work, not merely that a process appeared.

**Safety checks performed first:** `deviceLocked=0`, `strongAuthRequired=0x0`,
`lockscreen.password_type=null`, `lock_screen_lock_after_timeout=null` — **no lock credential
is set**, so locking cannot strand anyone behind a PIN. Reversible via `KEYCODE_WAKEUP` (224).

### Results

| # | Condition | Verified device state | `am start` | Process | **Work done** |
|---|---|---|---|---|---|
| 1 | Unlocked + active | `mWakefulness=Awake`, `Display State=ON` | exit 0, 0.27 s | 0.25 s | ✅ |
| 2 | **Locked / screen off** | `mWakefulness=Dozing`, `Display State=OFF`, **`mShowingLockscreen=true`** | exit 0, 0.26 s | 0.25 s | ✅ |
| 3 | Already running + duplicate invocation | — | exit 0 | **same PID** (7001 → 7001), no duplicate | ✅ |
| 4 | Repeated invocation ×5 | — | — | — | **5/5 success** |
| 5 | **Deep doze** | `mState=IDLE` (via `deviceidle force-idle`) | exit 0 | pid 7411 | ✅ |
| 6 | **adb server killed mid-invocation** | device absent from `adb devices` | — | — | ✅ **completed with no adb connected** |

Additional observation: during test 2 the **display stayed OFF** — `am start` did not wake the
screen or dismiss the keyguard.

### What the experiment establishes

1. **`am start` launches the Activity while the device is locked, screen-off, and dozing.** The
   bounded workload completes in all three.
2. **Launch latency is ~0.25 s**, consistently.
3. **A duplicate invocation does not create a second process** — Android reuses the existing
   Activity instance. The overlap risk (R5 in the reconnaissance) is lower than feared.
4. **The workload is decoupled from ADB.** It completed with the adb server dead. This is a
   genuinely useful architectural property: the worker does not need a live connection to finish
   its work, only to receive the job and return the result.

### What the experiment does NOT establish

Stated explicitly, per your instruction not to overclaim:

- It does **not** prove behaviour on a device **with a lock credential set**. None is set here.
  A secured device may differ, and the worker's job file is in external storage — reachable by
  adb regardless of lock state — but the *launch* path on a secured device is untested.
- It does **not** prove behaviour under **battery-saver** or **app-standby** restrictions, which
  were not forced.
- It does **not** prove behaviour on **other Android versions or OEMs**.
- It does **not** prove the *worker's* behaviour — only that this Activity class launches and
  completes. The worker is a new APK with its own manifest.
- The subject writes to **internal** storage (`/data/user/0/…`), which adb cannot read — see the
  file-exchange section. It says nothing about the external-storage channel.

### Incidental finding (recorded because it caused a scare)

Killing the adb server left the device briefly **`unauthorized`** on restart. This was transient
key re-negotiation, not a revocation: the device recovered to `device` on the next server
restart with **no user action**, and `~/.android/adbkey` was untouched. Recorded so a future
agent does not misread it as an authorization loss.

### Verdict on D-1

**The Activity proposal is confirmed, not contradicted.** No Service is introduced.

---

## D-1 — Execution mechanism: one-shot Activity

| | |
|---|---|
| **Decision** | The worker is a single one-shot `Activity`. No Service, no daemon, no broadcast, no `Runtime.exec`. |
| **Evidence** | The experiment above: exit 0 and completed work while **locked**, **screen-off**, and in **deep doze**; ~0.25 s launch; 5/5 on repeat; no duplicate process on double invocation; completes with adb disconnected. `am start-activity`, `am start-service`, `am start-foreground-service`, `am broadcast` are all available (recon F9) — the Activity was chosen on requirements, not availability. |
| **Alternatives considered** | **Foreground Service** — would require the `POST_NOTIFICATIONS` runtime permission (verified `prot=dangerous` on this device, recon F10), plus a persistent notification and a service lifecycle, for a workload that finishes in seconds. **Background Service** — subject to Android background-execution limits; the experiment shows an Activity is *not*, so the restriction is avoided rather than fought. **Broadcast receiver** — asymmetric: it can start work but cannot return a result, so a file would still be needed, and it adds a receiver component for no gain. |
| **Why minimum complexity** | It adds **zero** new Android components beyond one Activity, **zero** permissions, and **zero** lifecycle. A Service would add a component, a permission, a notification, and a stop/start lifecycle — four things — to do the same bounded work. |
| **Unresolved risk** | A device **with a lock credential** is untested. Low likelihood of difference (the job file is reachable by adb regardless of lock state), but unverified. Also untested: battery-saver and app-standby. Both are cheap to test during implementation and should be. |

---

## D-2 — Communication boundary: file-based exchange over ADB

| | |
|---|---|
| **Decision** | Three ADB operations: `push` job file → `am start` → `pull` result file. No HTTP, no socket, no port forwarding, no `adb reverse`, no RPC. |
| **Evidence** | adb runs as `uid=2000(shell)` with **`ext_data_rw`** in its supplementary groups; adb was verified to **write, read, push and pull** inside an app's external files dir (recon F2). The directory is `drwxrws---` — owner + `ext_data_rw` only — so it is **not readable by other applications**. |
| **Alternatives considered** | `adb forward` / `adb reverse` / localhost TCP / HTTP — **all require a listening socket inside the app**, i.e. a daemon, a service, and a protocol. Master prompt §5.2 lists "networking layers" as premature. Unix domain socket — not reachable across the ADB boundary without forwarding. `am start` + stdout — an Activity's stdout is not returned to `am`; a file would still be needed. |
| **Why minimum complexity** | A protocol would be infrastructure bought for **one request**. The file channel needs no daemon, no port, no framing, no authentication scheme, and **no permission**. It reuses Part 1's existing `push`/`pull` and `WorkerOperationsProtocol` — D8 changes *what* is transferred, not *how*. |
| **Unresolved risk** | **No authentication** on the channel. Anyone with ADB access can write the job file. ADB access *is* the boundary; this is stated in the security analysis rather than papered over. Also: a stale result file could be mistaken for a fresh one — mitigated by `job_id` (D-9). |

### File-exchange architecture, with the owning identity at every point

```
Mac (user rhenzrobertbumanglag)
 │
 │  PixelDesktop (macOS app)
 ▼
ADB transport  ── runs as uid=2000(shell) on the device ──┐
 │                                                        │
 │  1. push job.json                                      │  writes as: shell
 ▼                                                        │  into a dir it can reach
/sdcard/Android/data/com.pixeldesktop.worker/files/job.json
 │   owner: app UID (u0_aNNN)   group: ext_data_rw   mode: drwxrws---
 │   reachable by: the worker (owner) AND adb (ext_data_rw group)
 │   NOT reachable by: other installed applications
 │
 │  2. am start -n com.pixeldesktop.worker/.WorkerActivity
 ▼
Worker Activity  ── runs as its own app UID ──────────────┐
 │                                                        │  reads job.json as: app UID
 │                                                        │  writes result.json as: app UID
 ▼
/sdcard/Android/data/com.pixeldesktop.worker/files/result.json
 │   owner: app UID   same directory, same permissions
 │
 │  3. pull result.json                                   │  reads as: shell (ext_data_rw)
 ▼
Mac → verify by independent re-computation (ADR-004)
```

**Three identities, and they are not interchangeable:**

| Stage | Identity | Privilege basis |
|---|---|---|
| 1. write job file | `shell` (adb) | `ext_data_rw` group membership |
| 2. read job / write result | **app UID** | **ownership of the directory** |
| 3. read result file | `shell` (adb) | `ext_data_rw` group membership |

**The job file is written by one identity and read by another. The result file is written by one
identity and read by another.** Neither direction relies on the two identities having equivalent
privileges — they do not. Each is checked separately, which is precisely what Revision 1 to
ADR-010 records.

---

## D-3 — First workload: DTCA-1, with SHA-256 optional

| | |
|---|---|
| **Decision** | Use the **existing DTCA-1** specification and result contract as the worker's first workload. Keep the SHA-256 chain **optional**, to be added only if DTCA-1's measured execution time is too short to produce useful resource evidence. |
| **Evidence** | ADR-003 already specifies a minimal worker APK that performs DTCA-1 and writes a result JSON. ADR-004 already specifies verification by local re-computation. `DTCA1Worker` and `DTCA1Result` exist in the macOS app with a defined result contract; `ResultVerifier` exists and is tested. DTCA-1 is deterministic and independently verifiable. |
| **Alternatives considered** | **SHA-256 chain as the primary workload** — simpler to implement (~30 lines) and CPU-bound, but it would introduce a *new* result contract and a *new* verification path alongside the existing one, duplicating what `DTCA1Worker`/`ResultVerifier` already provide. **Matrix/vector computation** — same duplication problem, and no existing contract. **Small local inference** — explicitly excluded; Phase 6, and the master prompt says "do not begin with distributed AI". |
| **Why minimum complexity** | DTCA-1 is **already specified, already implemented locally, already verified, and already tested**. Choosing it introduces **no new verification concept**. Choosing anything else means writing a second workload contract and a second verifier beside the ones that exist. |
| **Unresolved risk** | **DTCA-1 may execute too fast to produce a measurable resource signal.** Text tokenization over ≤10 KB is likely milliseconds. If so, the resource evidence for "the Pixel did real work" weakens — hence the SHA-256 chain as a **conditional** addition, decided by measurement, not by preference. |

### The architectural property DTCA-1 must actually prove

You asked me to verify that DTCA-1 proves *"the computation is performed by the physical Pixel
worker and the Mac receives a verifiable result."* It can, but only if the evidence is collected
properly. DTCA-1 proves it when **all four** hold:

1. CPU time is consumed by the **worker's PID** on the device (`/proc/<pid>/stat` delta).
2. That PID's process name matches the **worker package**.
3. The result is **correct**, and the Mac reproduced it **independently**.
4. The result **could not have been produced without computing** — DTCA-1's word counts and
   classification are derived from the input, and a fabricated result would not match the Mac's
   independent recomputation.

**An existing test suite does not satisfy this.** `DTCA1Worker` passing 17 unit tests proves the
*algorithm* is right on the Mac; it says nothing about the Pixel. The real-device proof must be
a separate, measured run. That is recorded as a requirement, not an assumption.

---

## D-4 — Zero Android permissions

| | |
|---|---|
| **Decision** | The worker declares **no permissions at all**. |
| **Evidence** | Every candidate was evaluated and rejected with a reason (recon §6). The worker reads and writes a file in **its own** app-specific external directory — Android requires **no** permission for that on API 19+. `INTERNET` is unnecessary because the channel is file-based over ADB (D-2). `POST_NOTIFICATIONS` is unnecessary because there is no service (D-1). |
| **Alternatives considered** | `INTERNET` (no network is used); `POST_NOTIFICATIONS` (no service); `FOREGROUND_SERVICE` (no service); `READ_/WRITE_EXTERNAL_STORAGE` (not needed for the app's own external dir); `MANAGE_EXTERNAL_STORAGE` (**would grant whole-storage access — rejected as dangerous and unnecessary**); `WAKE_LOCK` (workload is short and runs while the Activity is foreground); `REQUEST_INSTALL_PACKAGES` (the app installs nothing); `ACCESS_NETWORK_STATE` (no network). |
| **Why minimum complexity** | Zero permissions is not a simplification — it is the **correct posture**. Each candidate above would add capability risk while adding **no** capability the worker needs. It also avoids a runtime permission prompt, which would require user interaction on a device whose whole value is that ADB can drive it unattended. |
| **Unresolved risk** | One thing to verify at implementation: the worker must use `getExternalFilesDir(null)` — its **own** directory — and not shared external storage. If a future requirement needs shared storage, that is a **new permission and a new decision**, not an extension of this one. |

---

## D-5 — Channel root moves; ADR-010 revised

| | |
|---|---|
| **Decision** | The worker's payloads live in `/sdcard/Android/data/com.pixeldesktop.worker/files/{job.json,result.json}`. **ADR-010 is revised** to record the identity boundary. |
| **Evidence** | `/data/local/tmp` is **mode 771 owned by `shell`** — an app cannot write it, and no `su` exists (recon F3). adb **can** read/write the app's external files dir via `ext_data_rw`, verified by writing and reading back (recon F2). The directory is `drwxrws---` — not readable by other apps. `/data/data/<pkg>` is `Permission denied` without root (recon F4). |
| **Alternatives considered** | **Keep `/data/local/tmp`** — impossible for the worker's output; the worker cannot write it. **`/sdcard` root** — world-readable to any installed application; the payload would be exposed. **`/data/data/<pkg>`** — unreachable by adb without root. **`/sdcard/Download`** — user-visible and shared; unnecessary exposure. |
| **Why minimum complexity** | Only the **root constant** changes. The mechanism is untouched: two fixed filenames, no caller paths, regular-files-only, size caps, size verification. No new abstraction, no new validation, no new permission. |
| **Unresolved risk** | The external-files path includes the package name and could vary on some OEMs. Must be resolved from the app side and **verified on this device** before being relied upon. Also: `adb uninstall` removes the directory, so `ensureInstalled` must recreate it. |

---

## D-6 — `install` as a narrow transport primitive + `WorkerInstaller`

| | |
|---|---|
| **Decision** | Add `install(deviceSerial:apkPath:replace:timeout:)` to `TransportProtocol` as a narrow primitive, and put all installation policy in a `WorkerInstaller`. |
| **Evidence** | `adb install` is available with the needed flags (`-r`, `-d`, `-g`, `--no-streaming`, `--abi`); install/reinstall/upgrade/downgrade/failure behaviours were each investigated (recon §5). `dumpsys package <pkg> \| grep versionCode` gives installed-version detection. **No root or user interaction is required to install via adb.** |
| **Alternatives considered** | **`pm install` / `cmd package install` on-device** — available, but they require the APK to be on the device first (an extra push) and are the on-device equivalent of the same operation. `adb install` does both steps. **Install directly from `WorkerOperations`** — would mix installation policy with job policy; rejected on separation grounds. |
| **Why minimum complexity** | One primitive plus one policy type. The primitive does one thing (run `adb install` with a validated path); `WorkerInstaller` owns package identity, version detection, and replace semantics — the three things that are actually policy. |
| **Unresolved risk** | `versionCode` alone is a weak identity check — it does not prove the installed package is *our* build. Signing-certificate comparison would be stronger. **Recommendation: start with `versionCode` and record the limitation**; add certificate comparison only if a concrete need appears. Also: **installation is state-changing**, unlike push/pull — it must never be exposed to the UI or Hermes as "install this file". |

---

## D-7 — Minimal lifecycle: four states

| | |
|---|---|
| **Decision** | `NOT_INSTALLED → INSTALLED → RUNNING → FINISHED/FAILED`. Drop `STARTING`, `STOPPING`, `STOPPED`. |
| **Evidence** | The experiment shows the process appears ~0.25 s after `am start` and the Activity finishes on its own. There is no observable "starting" interval and no distinguishable "stopped" state for a one-shot Activity — it returns to `INSTALLED`. A duplicate invocation reused the **same PID** rather than creating a second process, so there is no duplicate-process state to model. |
| **Alternatives considered** | **The six-state chain** — `STARTING`, `STOPPING` and `STOPPED` would be states the system passes through in milliseconds with no observable distinction; modelling them adds states that exist only to be immediately left. **A full process supervisor** — would manage restart, backoff, health; none of it is needed for a bounded one-shot workload that completes in seconds. **No lifecycle at all** — would leave stale-process and version-mismatch handling undefined. |
| **Why minimum complexity** | Four states, each **observably distinct** and each with a defined transition. The two dropped transition states and one terminal state would have required observation logic that cannot observe anything. |
| **Unresolved risk** | `am start` returning success does not guarantee the process started — it returns before the process is up. Handled by polling `pidof` and the result file with a bounded timeout, not by adding a state. |

---

## D-8 — New Gradle project, Java 17, six source files

| | |
|---|---|
| **Decision** | New Gradle project `DTCA1Worker/`, Java 17, `minSdk 31`, `targetSdk`/`compileSdk 36`, ~6 source files. |
| **Evidence** | `com.pixeldesktop.metadata` is **already installed on this device** with `minSdk 31`, `targetSdk 36`, built by Gradle 8.13 / AGP 8.13.0 / Java 17 (recon F5). The build chain is **proven end-to-end on this exact device**. The Gradle 8.13 wrapper distribution and AGP artifacts are already cached locally, and `android-36` is installed. |
| **Alternatives considered** | **Reuse/extend the metadata app** — it is a *different* concern (enumerating installed apps and reading their icons), and merging would couple two unrelated purposes and inherit its manifest. **Kotlin** — would add a toolchain for no benefit; Java 17 is proven here. **Add the worker as a module of the existing project** — the existing project lives in the legacy tree; the worker belongs with the current project. |
| **Why minimum complexity** | The skeleton is a **near-copy of a working project**, so there is no build-system risk to retire. Six files, no libraries beyond the Android SDK, no resources beyond the manifest. |
| **Unresolved risk** | Debug builds are signed with the standard debug keystore — **not a trust anchor**. A release keystore is out of scope for D8 and **must never be committed**. |

---

## D-9 — `job_id` as the anti-staleness mechanism

| | |
|---|---|
| **Decision** | Each job carries a `job_id`; the worker echoes it into the result. A mismatch means the file is stale and is rejected. |
| **Evidence** | The contract uses **fixed filenames** (ADR-010), so a result file from a previous run is indistinguishable from a fresh one by name. The experiment confirms a duplicate invocation reuses the same process and would write to the same path. |
| **Alternatives considered** | **Per-run filenames** — would reintroduce a variable path component and require the path validator ADR-010 demands before any variable-path contract. **Timestamps** — depend on clock agreement between Mac and device, which is not guaranteed. **Delete-then-run only** — necessary but insufficient: a crashed previous run can still leave a result, and a delete races with a slow writer. |
| **Why minimum complexity** | One field in two JSON documents. It preserves the fixed-filename contract, needs no new path, and turns an ambiguous situation into a deterministic error. |
| **Unresolved risk** | `job_id` is a **staleness** check, not an **authenticity** check — it does not prevent a malicious writer from forging a matching ID. Consistent with D-2: the channel is not authenticated, and ADB access is the boundary. Must not be described as tamper-proof. |

---

## D-10 — Measurement is one-shot reads, not a monitoring subsystem

| | |
|---|---|
| **Decision** | Collect evidence with discrete reads around a job: before, run, after. No sampling loop, no time series, no persistence, no dashboard. |
| **Evidence** | `/proc/<pid>/stat` is **readable for another UID's process** (adb holds `readproc`), giving utime/stime; `/proc/<pid>/status` gives `VmRSS` and `Threads`; `top -n 1 -b` gives per-process `RES`/`%CPU`; `dumpsys meminfo <pkg>` gives PSS (3,480 bytes); `dumpsys thermalservice` gives thermal state and temperatures; `dumpsys battery` gives level and temperature. All verified on the device (recon F6, F7). |
| **Alternatives considered** | **A sampling monitor** — would need a poll loop, a store, and a lifetime; nothing in Phase 5 asks for a time series. **A background collector service** — a new Android component and a permission, for data nobody consumes. **No measurement** — the master prompt explicitly requires execution time, memory behaviour, reliability and thermal "if observable". |
| **Why minimum complexity** | The required evidence is a **delta**, not a stream. Two reads and a subtraction answer every required question. Master prompt §5.2 forbids "resource orchestration"; discrete reads are not that. |
| **Unresolved risk** | **Attribution.** See below — this is the most important honesty constraint in D-10. |

### observable vs measurable vs attributable — the distinction you asked for

These are three different claims and must not be conflated:

| Term | Meaning | Example here |
|---|---|---|
| **Observable** | A value can be read at all | `dumpsys thermalservice` returns `LITTLE 67.0 °C`. ✅ verified |
| **Measurable** | It can be read reliably, with a known unit and a meaningful delta | `/proc/<pid>/stat` utime/stime delta across the run, in clock ticks. ✅ verified readable |
| **Attributable to our worker** | The change is caused by **our** worker, not by something else | **This is the hard one.** |

**What is genuinely attributable to the worker:**

- **CPU time consumed by the worker's PID** — `utime + stime` for that specific PID is
  attributable by definition. This is the strongest evidence available without root.
- **The worker process's own `VmRSS`** — memory of that process, attributable.
- **The process identity** — `/proc/<pid>/stat` field 2 gives the process name, tying the PID to
  the worker package.

**What is NOT attributable, and must not be claimed:**

- **`dumpsys thermalservice` temperatures are SYSTEM-WIDE.** `LITTLE 67.0 °C` is the SoC's
  little-cluster sensor reading, influenced by every process on the device, by charging, by
  ambient temperature, and by the modem. **A before/after delta does not isolate our worker's
  thermal contribution.** The load average on this device was `5.80 4.78 2.96` — the system is
  busy with things that are not us.
- **`dumpsys battery` temperature** is the battery, not the SoC, and is dominated by charging
  state.
- **System-wide `%CPU` from `top`** is not the worker's.

**Therefore the honest claim is:**

> Thermal is **observable and measurable**, but **not attributable** to the worker at this
> granularity. It is reported as *device thermal state during the run*, with the system load
> alongside it so a reader can judge how much of the signal could plausibly be ours.

This is exactly the overclaim you warned against, and it is recorded as a limitation rather than
smoothed over.

---

## Summary table

| # | Decision | Verdict on evidence | Unresolved risk (highest) |
|---|---|---|---|
| D-1 | One-shot Activity | **Confirmed by experiment** (locked, screen-off, deep doze, 5/5, no dup process) | Device with a lock credential untested |
| D-2 | File-based exchange over ADB | Verified: adb writes/reads the app's external dir | Channel unauthenticated (ADB access is the boundary) |
| D-3 | DTCA-1 first; SHA-256 optional | Existing spec + impl + verifier; no new concept | DTCA-1 may be too fast for a resource signal |
| D-4 | Zero permissions | Every candidate evaluated and rejected | Must use own external dir, not shared storage |
| D-5 | Channel root moves; ADR-010 revised | `/data/local/tmp` unreachable by an app — measured | External path may vary by OEM |
| D-6 | Narrow `install` + `WorkerInstaller` | `adb install` verified; no root needed | `versionCode` is a weak identity check |
| D-7 | Four-state lifecycle | States that would exist only to be passed through are dropped | `am start` success ≠ process started (poll instead) |
| D-8 | New Gradle project, Java 17, 6 files | Proven end-to-end by the installed metadata app | Debug signature is not a trust anchor |
| D-9 | `job_id` anti-staleness | Fixed filenames make staleness indistinguishable otherwise | Staleness check, not authenticity |
| D-10 | One-shot measurement reads | All mechanisms verified readable | **Thermal is not attributable to the worker** |

---

## Requested next step

The locked/idle question is **resolved in favour of the Activity proposal** — the experiment
confirmed it. Per your instruction, implementation may proceed once you approve this table.

**No source code was modified. No APK was built or installed.** The experiment used the
already-installed `com.pixeldesktop.metadata` app and a throwaway set of ADB commands. Device
state was verified restored afterwards: `adb devices` = `device`, wakefulness `Awake`, doze
`ACTIVE`, test app not running, and zero probe artifacts remaining on the device.

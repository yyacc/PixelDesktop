# FAIL-004: Three Android Assumptions Falsified by Real-Device Execution

## Status

Resolved

## Date

2026-10-02

## Phase

Phase 5, D8 (Pixel Compute Worker implementation)

## Summary

Three separate assumptions about Android behaviour were written into the first implementation.
All three were reasonable, all three were wrong, and **none was caught by the 154-test suite** —
each was caught only by executing on the physical Pixel 7a.

They are recorded together because they share one cause: **treating documented or remembered
platform behaviour as fact instead of measuring it.**

---

## Instance 1 — `exported="false"` makes the Activity unlaunchable by adb

### Attempt
Set `android:exported="false"` on `WorkerActivity`, on the assumption that adb (running as
`uid=2000(shell)`) holds a privileged permission to start non-exported components. This was
believed to be the *tighter* choice.

### Observed
```
java.lang.SecurityException: Permission Denial: starting Intent
{ flg=0x10000000 xflg=0x5 cmp=com.pixeldesktop.worker/.WorkerActivity }
from null (pid=10176, uid=2000) not exported from uid 10004
    at com.android.server.wm.ActivityTaskSupervisor.checkStartAnyActivityPermission(...)
```

`am start` failed outright. The worker could never be launched.

### Diagnosis
**Implementation / incorrect platform assumption.** adb shell does **not** hold a general
privilege to start arbitrary non-exported Activities. The Activity must be exported for adb to
start it.

### Correction
Set `android:exported="true"`, and contain the resulting exposure with three mitigations:

1. **No intent-filter.** Only an explicit component start (`am start -n …/.WorkerActivity`) can
   reach it. No other app can start it implicitly.
2. **No Intent extras are read.** The Activity takes no input from its caller.
3. **Runtime launcher check** — see Instance 2.

The residual exposure is: another app may trigger a re-run of whatever job file is already
present. It cannot supply input, read the result, or alter behaviour.

---

## Instance 2 — `getLaunchedFromUid()` returns `-1` for adb launches, not `2000`

### Attempt
Contain the now-exported Activity by verifying the launcher:
```java
if (launchedFromUid != 0 && launchedFromUid != 2000) { refuse(); }
```
On the assumption that an adb launch reports the shell UID.

### Observed
```
I PixelDesktopWorker: WORKER_LAUNCHER uid=-1 own_uid=10004
E PixelDesktopWorker: WORKER_FAILED type=UNAUTHORIZED_LAUNCHER launched_from_uid=-1
```

The check rejected **every legitimate adb launch**. The worker started and immediately refused
to work.

### Diagnosis
**Implementation / incorrect platform assumption.** `getLaunchedFromUid()` returns `-1` — Android's
sentinel for "unknown/absent launcher" — for the documented adb launch path. The assumed value
(2000) is what a *shell* process reports, not what this API reports for an `am start`.

### Correction
```java
boolean acceptableLauncher = launchedFromUid == -1   // adb / unknown
        || launchedFromUid == 0                      // root
        || launchedFromUid == 2000;                  // shell
```
The check now rejects any other **concrete** UID, i.e. another application, while accepting the
launch path that actually works.

---

## Instance 3 — an adb-created exchange directory is unwritable by the app

### Attempt
Have the Mac ensure the exchange directory exists before pushing the job:
```
adb shell mkdir -p /sdcard/Android/data/com.pixeldesktop.worker/files
```

### Observed
The directory was created as:
```
drwxrws--- 2 shell ext_data_rw 3452 /sdcard/Android/data/com.pixeldesktop.worker/files
```
owned by **`shell`**. The worker runs as `uid=10004` (`u0_a45`), is not the owner, and is not in
group `ext_data_rw`. **It could not write its own output directory.** The worker ran, found no
job it could act on in a directory it could not write, and produced nothing.

### Diagnosis
**Implementation / wrong creator.** The directory's owner is whoever creates it. `adb` created it
as `shell`; the app therefore never owned it. This is the *same class* as ADR-010 Revision 1 — a
path's suitability is a property of the **(path, identity)** pair — applied one level down: the
directory's *usability by the app* depends on **who created it**.

### Correction
The **worker creates its own directory** via `getExternalFilesDir(null)`. The Mac never runs
`mkdir`. The correct sequence is:

1. launch the worker once (it creates its directory, finds no job, exits)
2. push the job
3. launch the worker again to compute

`WorkerTransferContract.remoteWorkspaceCreateCommand` was **removed** and replaced with
`remoteWorkspaceExistsCommand` (`test -d … && echo EXISTS`), so the Mac can no longer create the
directory even by accident. `WorkerOperationsProtocol.prepareRemoteWorkspace` now *checks* rather
than creates, and throws if absent.

After the fix the directory is owned by the app:
```
drwxrws--- 2 u0_a45 ext_data_rw ... /sdcard/Android/data/com.pixeldesktop.worker/files
```

---

## Why the test suite did not catch any of these

All three are **platform behaviours**, not logic errors:

- `exported` semantics are enforced by the Android framework at launch time.
- `getLaunchedFromUid()`'s return value comes from the framework.
- Directory ownership is decided by the filesystem.

A unit test with a mock transport asserts what the code *sends*, not what Android *does* with it.
The mock cannot fail a `SecurityException`, cannot return a framework sentinel, and cannot report a
directory owner.

**This is the fourth, fifth and sixth defect in this project that compiled cleanly and passed the
full suite while being wrong** (after `manufacturer` holding the codename; the over-broad
protected-package entry; and the world-readable workspace). Every one was caught by comparing
against the real device.

## Lesson

**A remembered or documented platform behaviour is not a measured one.** Each of the three
assumptions above would have been defensible in a code review, and each was wrong. The cost of
being wrong was a failed run and a diagnostic cycle — cheap, because the harness reported the real
device's answer rather than a guess.

**Corollary: make the device report the fact you are assuming.** Instance 2 was fixed quickly
only because the implementation *logged* `WORKER_LAUNCHER uid=-1` before acting on it. Had it
silently refused, the cause would have been invisible. Logging the observed value next to the
decision that depends on it is what turned a mystery into a one-line fix.

## What Should Future Agents Do Differently

- For any Android framework behaviour that gates execution — exported flags, launcher identity,
  permission requirements, storage ownership — **probe it on the device before depending on it**.
- When a check refuses, **log the observed value**, not just the refusal.
- Never let `adb` create a directory that an app must write to. Let the owner create it.
- Treat "the tests pass" as evidence about the code, never as evidence about the platform.

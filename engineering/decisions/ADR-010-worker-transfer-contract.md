# ADR-010: Worker Transfer Contract and Path Containment

## Status

**Accepted — REVISED 2026-10-02 (Revision 1).** The containment mechanism is unchanged. The
remote root was found to be unusable for worker output; see Revision 1 below.

## Date

2026-10-01 (original) · 2026-10-02 (Revision 1)

---

## REVISION 1 — The transfer root reflects the actual identity boundary

**Date:** 2026-10-02
**Trigger:** D8 reconnaissance (commit `cc11bea`)

### What was found

`/data/local/tmp` is **mode 771, owned by `shell`**:

```
drwxrwx--x 2 shell shell /data/local/tmp
```

`others` receive `--x` — traverse only, **no write**. An Android application runs under its own
UID, is not in group `shell`, and no privilege escalation exists (`su` is absent;
`ro.debuggable=0`, established in ADR-009).

> **An Android worker process cannot write `/data/local/tmp`.** The original contract's root is
> writable **only by adb**.

The original decision was correct about the *parent directory's* properties and never tested
whether the identity that would write worker output could actually reach it. That is the same
class of error as FAIL-003.

### The identity boundary, stated plainly

| Writer | Identity | Can write `/data/local/tmp`? | Can write app external files dir? |
|---|---|---|---|
| `adb push` / `adb shell` | `uid=2000(shell)`, group `ext_data_rw` | **Yes** | **Yes** (via `ext_data_rw`) |
| Android worker process | own app UID | **No** | **Yes** (it owns the directory) |

**`adb` and the Android application do NOT have equivalent filesystem privileges.** They are
different identities with different group memberships. A path that is convenient for one is not
automatically reachable by the other. This must be checked per identity, not per path.

### The revised root

```
/sdcard/Android/data/com.pixeldesktop.worker/files/
```

| Property | Value | Why |
|---|---|---|
| Directory mode | `drwxrws---` (owner + `ext_data_rw`) | **Not readable by other applications** |
| adb access | **Read and write** — verified by writing and reading back | adb holds `ext_data_rw` |
| Worker access | **Read and write** — it is the owner | Standard app-private external storage |
| Permission required | **None** | App-specific external storage needs no permission on API 19+ |

Chosen over `/sdcard` root (world-readable to any installed app) and over
`/data/data/<pkg>` (unreachable by adb without root — verified `Permission denied`).

### What did NOT change

**Containment is by narrowness, not by trusting arbitrary paths.** The revision moves a
constant; it does not weaken the mechanism.

- Still **two fixed filenames**, one file each way
- Still **no caller-supplied paths** anywhere
- Still **regular-files-only**, with symlink and directory rejection
- Still **size caps and post-transfer size verification**
- Still **no path parameter on the worker-facing surface**

The `chmod 700` requirement from the original decision becomes unnecessary for the new root,
because the app-private external directory is already owner-scoped by the platform
(`drwxrws---`). It is **not** removed as a principle — it is recorded as no longer applicable
to this root.

### The standing requirement is unchanged and still binding

**Before any future variable-path contract, this ADR must be revisited and a real path
validator written.** The revision does not relax that. If anything it strengthens the case:
the failure mode discovered here was not a traversal attack but an *identity mismatch*, which a
path validator would not have caught either. Both checks are needed.

---

## Original Decision (2026-10-01)

## Status (original)

Accepted

## Date (original)

2026-10-01

## Context

Phase 5 (Pixel Compute Worker) requires moving two payloads between the Mac and the Pixel:
an input text file to the worker, and a result JSON back. Per ADR-003 the mechanism is ADB
push/pull; per ADR-004 the result is verified by independent local re-computation.

Phase 4 established that containment by **validation** is fragile: the protected-package list
was wrong on its first attempt, and the error survived 105 passing unit tests. Phase 5 begins
a new input surface — **paths**, which are structurally different from package identifiers.

## Problem

What is the smallest safe transfer contract for this worker, given that `adb` provides no
path safety of its own?

## Evidence — empirical, on the real Pixel 7a

Every question was answered by **executing it** on the attached device, not by reading
documentation. All probe files were removed afterwards and the remote directory was verified
clean.

### 1. `adb` does NOT sanitize remote paths

This was tested in two ways to separate "adb refuses" from "the filesystem refuses":

| Attempt | Result |
|---|---|
| `push … /data/local/tmp/../pd_escape.txt` | exit 1 — **permission** failure (`/data/local` not writable) |
| `push … /data/local/tmp/../../etc/pd.txt` | exit 1 — **permission** failure |
| `push … /pd_root.txt` | exit 1 — **permission** failure |
| `push … /system/pd.txt` | exit 1 — read-only filesystem |
| **`push … /data/local/tmp/pdsub/../pd_trav.txt`** | **exit 0 — landed in `/data/local/tmp/`** |
| **`push … /sdcard/pdsub/../pd_trav2.txt`** | **exit 0 — landed in `/sdcard/`** |

**`../` is resolved by the device filesystem, not rejected by adb.** The failures were the OS
denying writes to `/data/local`, `/etc` and `/system` — **not a security control**.

> This distinction is load-bearing. An early reading of these results could have concluded
> "adb blocks traversal". Re-testing inside a writable area proved otherwise.

### 2. Absolute paths escape any staging root trivially

`push payload.txt → /sdcard/pd_abs.txt` — **exit 0**. No traversal is required. A "staging
root" is not enforced by the transport at all.

### 3. Local destinations escape on `pull`

`pull … → <staging>/../../pd_local_escape.txt` — **exit 0**, wrote to
`/Users/…/.hermes/cache/` — **outside the staging directory**. Removed during cleanup.

### 4. Symlinks are followed, not rejected

| Attempt | Result |
|---|---|
| `push <symlink → /etc/hosts>` | **exit 0 — pushed the contents of `/etc/hosts`** (555 bytes) |
| `push <file inside a symlinked dir → /etc>` | **exit 0** |

A symlink inside staging is a **full escape from staging**.

### 5. Directories recurse

`pull /data/local/tmp <dir>` → exit 0, **"2 files pulled"**. A stray directory operand
transfers a tree.

### 6. Overwrite is silent, exit 0

Pushing over an existing remote file replaces it with **no warning and exit 0**. Same for a
local pull destination. `adb` provides no overwrite protection.

### 7. Path arguments are NOT a command-injection vector

`/data/local/tmp/pd;id.txt` and ``/data/local/tmp/pd`id`.txt`` were created as **literal
filenames**; no command ran and no substitution occurred. `adb push`/`pull` treat the path as
a single argv element — there is no shell in the path.

**Note the asymmetry:** a path passed to `shell()` **is** a different risk class, because
there a command string is the payload. These must not be conflated.

### 8. Nonexistent paths fail cleanly

`pull` nonexistent → exit 1 (`failed to stat remote object`). `push` nonexistent local →
exit 1 (`cannot stat`). Both detectable.

### 9. `mkdir -p` does not produce a restricted directory

The created workspace came out **mode 777 (world-readable)** on the real device, even though
its parent `/data/local/tmp` is 771. Discovered by real-device verification, not by unit tests.

## Decision

### The mechanism: narrowness, not validation

**There is no path parameter anywhere in the worker-facing contract.** Two fixed filenames in
two fixed directories, one file each way.

| Item | Path |
|---|---|
| Remote root | `/data/local/tmp/pixeldesktop` — **SUPERSEDED by Revision 1 for worker output** |
| Remote input | `/data/local/tmp/pixeldesktop/input.txt` — **SUPERSEDED** |
| Remote result | `/data/local/tmp/pixeldesktop/result.json` — **SUPERSEDED** |
| Local staging | `<container>/Application Support/PixelDesktop/Staging/` |
| Local input / result | `…/Staging/input.txt`, `…/Staging/result.json` |

> **See Revision 1.** The remote root above is reachable by adb but **not** by an Android
> worker process. The worker's payloads move to
> `/sdcard/Android/data/com.pixeldesktop.worker/files/{input.txt,result.json}`. The local
> staging paths are unaffected.

Every case in the evidence above is therefore **unreachable by construction** rather than
merely blocked: there is no path input to attack.

Validation still exists as a **second layer** — regular-file check, symlink rejection,
directory rejection, size cap — but it is the fallback, not the mechanism.

### Remote root ownership and permissions

> **Superseded by Revision 1.** Retained as the original reasoning.

`/data/local/tmp/pixeldesktop`, created by `mkdir -p … && chmod 700 …`.

`/data/local/tmp` was chosen over `/sdcard` because it is writable by the `shell` user that
ADB runs as and **is not world-readable** (parent mode 771), whereas `/sdcard` is FUSE-mounted
and world-readable to any installed application. **`chmod 700` is required**, because
`mkdir -p` alone produced 777 — see evidence §9. The directory is owned by `shell`; it is
cleared on reboot, so `prepareRemoteWorkspace` runs before each workload rather than assuming
persistence.

### Local staging ownership

Inside the app's own container (`Application Support`), which is container-controlled and
outside user-visible storage. **The caller cannot substitute a staging path** — it is computed
by `WorkerTransferContract` and never accepted as an argument.

### Overwrite semantics

**Overwrite is permitted, deliberately, for the two fixed paths.** `adb` overwrites silently
(evidence §6), and the fixed filenames make overwrite the *intended* semantics: the next
workload replaces the previous input, the next result replaces the previous result. Refusing
would require a delete-then-push dance and would fail the second workload for no benefit.

No `--sync`, no partial-update modes, and no overwrite of anything outside the two fixed paths
(unreachable — the paths are constants).

### Transfer interruption / partial-transfer semantics

`adb` reports success on completion and exposes **no resumable state**. Detection is therefore
post-hoc:

- **push:** compare the local source size against the device's `stat -c %s` of the destination.
- **pull:** compare the device's `stat -c %s` against the local file size after transfer.

A mismatch is reported as a failure — never as a successful transfer of unknown content.

> **This detects size mismatch. It is NOT cryptographic integrity verification.** It cannot
> detect same-length corruption. Integrity of the *result content* is established by ADR-004's
> independent re-computation, not by this check.

### Regular-file-only behaviour

Both directions accept only a **regular file**: not a symlink, not a directory, not a socket,
device or fifo. Enforced with `FileManager.attributesOfItem`, which reports a symlink as
`.typeSymbolicLink` **without following it** — verified before relying on it.

### Symlink / directory rejection

Rejected explicitly, with distinct error messages naming the reason. A symlink is a full
escape from staging (evidence §4); a directory recurses (evidence §5).

### Transport vs worker responsibility

| Concern | Owner |
|---|---|
| Executing `adb push` / `adb pull` | `TransportProtocol` (`ADBTransport`) |
| Path constants, validation, overwrite policy, size verification, workspace setup | `WorkerTransferContract` / `ADBWorkerOperations` |

The transport takes **already-validated absolute paths** and holds no worker semantics — the
same split as ADR-009. `push()`/`pull()` are primitives and must not be called with
caller-supplied paths.

### Why narrowness is the primary containment mechanism

Phase 4 demonstrated that validation-based containment is fragile: a rule with a stated
criterion was still applied wrongly, and 105 passing unit tests did not catch it. A contract
with **no path parameter** has nothing to attack. Narrowness is structural; validation is
procedural, and procedures can be applied incorrectly.

The payload is ≤10 KB by specification, so nothing is lost by this narrowness.

## Limits of this protection model

**This contract is safe because it is narrow, not because paths are validated.** It provides
**no** general path-safety mechanism, and none should be inferred from it.

- It does not validate arbitrary paths. It has no path input at all.
- It does not protect against a caller that bypasses `WorkerOperationsProtocol` and calls
  `TransportProtocol.push/pull` directly with a hostile path. As in ADR-009, the containment
  constrains the *worker layer's* behaviour, not a hostile holder of the transport.
- The size check is not integrity verification (§ above).
- The 1 MB cap guards against a wrong file being handed in; it is not a transfer limit.

**Requirement for any future phase:** before introducing a variable-path contract, **ADR-010
must be revisited and a real path validator written** — one that canonicalises and confines
both sides, rejects traversal and symlinks, and is tested against the evidence cases in this
ADR. Extending this contract with a path parameter without that work would reintroduce every
case in §1–§5.

## Consequences

- `TransportProtocol` gains `push()` and `pull()` as narrow primitives.
- New `Worker/` layer: `WorkerTransferContract` (constants, validation, integrity) and
  `WorkerOperationsProtocol` / `ADBWorkerOperations` (named operations, no path arguments).
- `DeviceOperation` is **not** extended: transfer is not a device operation, it is a payload
  mechanism. Phase 5 does not add operations to that enum.
- 131 tests pass (127 hermetic + 4 opt-in integration tests skipped by design).
- Real-device verification proves the exact fixed contract: fixed paths, size-verified push,
  deliberate overwrite, size-verified pull, byte-identical round trip, and all failure paths.

## Rejected Alternatives

- **Caller-supplied remote or local paths** — reintroduces evidence §1–§5 wholesale.
- **A path-validation-only approach (validate then allow variable paths)** — fragile by
  Phase 4's evidence; narrowness is stronger.
- **`/sdcard` as the remote root** — world-readable to any installed app.
- **Refuse-if-exists overwrite** — fails the second workload; requires a destructive `rm` for
  no benefit.
- **Directory or recursive transfer** — `adb` recurses; no consumer needs it.
- **Following symlinks** — a symlink is a full escape.
- **Chunked / resumable transfer** — payloads are ≤10 KB; no evidence justifies it.
- **Cryptographic hashing of the payload** — the result's correctness is established by
  ADR-004 re-computation, not by a hash. A hash would verify transport integrity, which the
  size check already approximates for these sizes.
- **APK delivery via `push()`** — `adb install` is the correct mechanism (ADR-003).

## Future Reconsideration Conditions

- **Any variable-path contract** → revisit this ADR and write a real path validator first.
- **Any change of writer identity** (a different app, a service, a different UID) → re-check
  that the new identity can actually reach every path in the contract. Revision 1 exists
  because this check was not performed the first time. **A path's suitability is a property of
  the pair (path, identity), not of the path alone.**
- If payloads grow beyond ~1 MB, revisit the size cap and consider streaming.
- If `/data/local/tmp` proves unsuitable (e.g. it is cleared mid-run by an aggressive
  cleaner), revisit the root.
- If a future phase needs multiple concurrent workloads, the fixed filenames become a
  constraint and a per-run subdirectory scheme would be needed — which would reintroduce a
  path component and require the validator.

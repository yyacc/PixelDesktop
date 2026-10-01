# Phase 5 Proposal — Pixel Compute Worker: the Transfer Contract

**Status:** PROPOSAL — awaiting review. **No source code modified.**
**Phase:** 5 (Pixel Compute Worker) — authoritative per [ADR-007](../decisions/ADR-007-authoritative-phase-sequence.md)
**Date:** 2026-10-01
**Depends on:** Phase 4 (Android Application / Process Control) — COMPLETE
**Covers:** RNZM-23 (`push()`/`pull()`), scoped to the worker's actual transfer needs

---

## 1. Scope

Master prompt §16 Phase 5:

> Prove that the Pixel can perform a useful bounded compute workload. Start with a
> deterministic workload… `input → Pixel worker → deterministic processing → structured
> result → Mac verification`. Do not begin with distributed AI. First prove the Pixel can
> reliably execute a workload and return a verifiable result.

ADR-003 fixes the mechanism: a minimal worker APK, receiving input via ADB push, writing a
result JSON to a known location, retrieved via ADB pull. ADR-004 fixes verification: local
re-computation, not trusting the worker.

**The goal is not "a file transfer system".** It is the smallest safe transfer contract for
this worker. Nothing here is designed to move arbitrary files.

---

## 2. Empirical Findings (real device, read-only except where stated)

Every security question was answered by **executing it**, not by reading documentation. The
Pixel 7a was attached throughout; all probe files were removed afterwards and the remote
`/data/local/tmp` was verified clean.

### 2.1 Remote root choice

| Directory | Mode | Writable by `shell` | Notes |
|---|---|---|---|
| `/data/local/tmp` | `drwxrwx--x shell shell` | **Yes** | **Not world-readable** (o+x only) |
| `/sdcard` | FUSE, `/storage/self/primary` | Yes | World-readable by other apps |
| `/sdcard/Android/data/com.pixeldesktop.worker` | — | — | **Does not exist** (worker not installed) |

FUSE is active (`persist.sys.fuse=true`), so `/sdcard` is a userspace daemon and no longer a
simple `sdcardfs` mount.

**`/data/local/tmp` is the safer root**: writable by the `shell` user that ADB runs as, and
not readable by other apps. `/sdcard` is world-readable, which would expose worker input and
results to any installed application.

### 2.2 Overwrite behaviour — **silent, exit 0**

```
push payload.txt → /data/local/tmp/pd_probe.txt   exit 0
push other.txt   → /data/local/tmp/pd_probe.txt   exit 0   ← silently replaced
```

There is **no warning and no non-zero exit** when an existing remote file is overwritten.
Likewise a local `pull` destination is silently replaced.

**This is the most important finding for the contract**: `adb` will not protect against
clobbering. Any overwrite protection must be implemented by us or explicitly disclaimed.

### 2.3 Remote path traversal — **NOT sanitized by adb**

This was tested in two ways to separate "adb refuses" from "the filesystem refuses":

| Test | Result |
|---|---|
| `push … /data/local/tmp/../pd_escape.txt` | **exit 1** — but this is a *permission* failure (`/data/local` is not writable), not traversal prevention |
| `push … /data/local/tmp/../../etc/pd.txt` | exit 1 — permission failure |
| `push … /pd_root.txt` | exit 1 — permission failure |
| `push … /system/pd.txt` | exit 1 — read-only filesystem |
| **`push … /data/local/tmp/pdsub/../pd_trav.txt`** | **exit 0 — landed in `/data/local/tmp/pd_trav.txt`** |
| **`push … /sdcard/pdsub/../pd_trav2.txt`** | **exit 0 — landed in `/sdcard/pd_trav2.txt`** |

**`../` is resolved by the filesystem, not rejected by adb.** Traversal succeeded wherever
the resolved destination was writable. The earlier failures were the OS denying writes to
`/data/local`, `/etc` and `/system` — **not** a security control.

> **Conclusion: adb does NOT sanitize remote paths. Any containment must be ours.**

### 2.4 Absolute remote paths escape the staging root trivially

```
push payload.txt → /sdcard/pd_abs.txt    exit 0 — landed
```

No traversal is even required. An absolute path simply writes wherever the destination is
writable. A "staging root" is therefore **not enforced by the transport at all**.

### 2.5 Local path traversal on `pull` — **escapes the staging directory**

```
pull /data/local/tmp/pd_probe.txt → <scratch>/../../pd_local_escape.txt
```

**Exit 0.** The file landed at `/Users/…/.hermes/cache/pd_local_escape.txt` — **outside the
staging directory**. The artifact was removed during cleanup.

**adb does not confine local destinations either.**

### 2.6 Symlinks are followed, not rejected

| Test | Result |
|---|---|
| `push <symlink → /etc/hosts>` | **exit 0** — pushed the *content of `/etc/hosts`* (555 bytes) |
| `push <file inside a symlinked dir → /etc>` | **exit 0** — pushed `/etc/hosts` through the link |

**A symlink inside the staging directory is a full escape from it.** Pushing "a file from
staging" can exfiltrate any readable file on the Mac.

### 2.7 Command injection through path arguments — **not reachable**

| Path | Result |
|---|---|
| `/data/local/tmp/pd;id.txt` | exit 0 — a **literal filename** containing `;`. No command ran. |
| `/data/local/tmp/pd\`id\`.txt` | exit 0 — literal filename. No substitution. |
| `/data/local/tmp/pd with spaces.txt` | exit 0 — spaces are fine |
| `/data/local/tmp/pd\nnl.txt` | exit 0 |
| relative destination `relative_name.txt` | exit 1 — refused |

`adb push`/`pull` treat the path as a single argv element; there is no shell in the path. **No
command injection through paths.** This is a materially different surface from Phase 4's
`shell()`, where a command string *is* the payload.

Note the asymmetry: spaces and `;` are fine for `adb push`, but the same characters broke
`adb shell ls` in my own probe. **Any path passed to `shell()` is a different risk class.**

### 2.8 Nonexistent paths

| Case | Behaviour |
|---|---|
| `pull` nonexistent remote | exit 1 — `failed to stat remote object: No such file or directory` |
| `push` nonexistent local | exit 1 — `cannot stat: No such file or directory` |

Both are clean, detectable failures with non-zero exit codes.

### 2.9 Directories vs files — **recursion**

| Case | Result |
|---|---|
| `pull /data/local/tmp <dir>` | exit 0 — **"2 files pulled"**, recursive |
| `push <local dir> /data/local/tmp` | exit 0 — recursive |

**Directory operands recurse.** A stray directory operand would transfer an entire tree.

### 2.10 Worker input constraints (from the DTCA-1 spec and local implementation)

- Input: plain UTF-8 text, **max 10,000 characters (10 KB)**, min 1
- `DTCA1Worker.validateInput` rejects `>10_000` characters and any `\0` null byte
- Output: a small JSON object

So the **actual payload is tiny** — a few KB in, a few KB out. There is no need for
large-file transfer, resumption, or chunking.

---

## 3. Exact Phase 5 Use Cases

Only two transfers are required, and only one of each:

| # | Direction | Content | Size | When |
|---|---|---|---|---|
| **U1** | push | DTCA-1 input text file | ≤ 10 KB | Once per workload submission |
| **U2** | pull | Worker result JSON | ~1 KB | Once per workload completion |

**Not required:** APK delivery. ADR-003 says "build/install minimal worker APK if not already
present", but APK installation is `adb install`, not `push`. The worker is installed once
during Phase 5 setup, not per workload.

**Not required:** result-file cleanup, log retrieval, model files, multi-file batches.

**Therefore: exactly one push and one pull per workload run.**

---

## 4. Path Contracts

### 4.1 Remote (device)

| Item | Path |
|---|---|
| Worker root (fixed) | `/data/local/tmp/pixeldesktop/` |
| Input | `/data/local/tmp/pixeldesktop/input.txt` |
| Result | `/data/local/tmp/pixeldesktop/result.json` |

**Fixed filenames. No caller-supplied remote path.** There is exactly one input and one
result; a parameterised remote path buys nothing and adds the entire traversal surface.

### 4.2 Local (Mac)

| Item | Location |
|---|---|
| Staging root | `<app container>/Library/Application Support/PixelDesktop/Staging/` |
| Staged input | `…/Staging/input.txt` |
| Retrieved result | `…/Staging/result.json` |

**Fixed filenames. No caller-supplied local path.**

### 4.3 The contract in one sentence

> Two fixed filenames, in two fixed directories, one file each way, no directories, no
> symlinks, bounded to ≤ 1 MB.

Because both paths are constants, **every path-traversal case in §2 becomes unreachable by
construction** rather than by validation. That is the strongest available containment: there
is no path input to attack.

---

## 5. Ownership of Validation

| Concern | Owner | Rationale |
|---|---|---|
| Path constants | `WorkerTransferContract` (worker layer) | Paths are worker semantics, not transport |
| **Path validation / construction** | **`WorkerTransferContract`** | Only it knows the permitted roots |
| Local filesystem checks (exists, regular file, symlink, size) | `WorkerTransferContract` | Needs `FileManager`; transport has no filesystem knowledge |
| Remote directory creation (`mkdir -p`) | `WorkerTransferContract` via `shell()` | Device setup is worker semantics |
| **Executing `adb push` / `adb pull`** | **`TransportProtocol`** | Transport primitive; no path policy |
| Overwrite policy | `WorkerTransferContract` | Policy, not transport |
| Interrupted-transfer detection | `WorkerTransferContract` | Needs size comparison |

**Rule: the transport executes, the worker layer decides.** `ADBTransport.push/pull` must not
contain path allowlists, staging roots, or worker semantics — exactly as `ADBTransport` holds
no Android application semantics after Phase 4.

---

## 6. Transport vs Worker-Layer Responsibilities

### Transport (new, minimal)

```swift
func push(deviceSerial: String, localPath: String, remotePath: String, timeout: TimeInterval) async throws -> TransportResult
func pull(deviceSerial: String, remotePath: String, localPath: String, timeout: TimeInterval) async throws -> TransportResult
```

Both take **already-validated absolute paths** and do nothing but run `adb push`/`adb pull`.
Documented as primitives: they **must not** be called directly with caller-supplied paths.
Same containment posture as `shell()` in ADR-009 — the primitive is not made safe; it is kept
away from untrusted input.

### Worker layer (new)

```
PixelDesktop/Worker/
├── WorkerTransferContract.swift      path constants + validation + policy
└── WorkerOperationsProtocol.swift    named worker operations
```

`WorkerOperationsProtocol` — the only surface the rest of the app uses:

| Operation | Does |
|---|---|
| `prepareRemoteWorkspace(deviceSerial:)` | `mkdir -p /data/local/tmp/pixeldesktop` |
| `submitInput(deviceSerial:text:)` | Validates text, writes to staging, pushes |
| `retrieveResult(deviceSerial:)` | Pulls result, validates it landed, returns parsed JSON |

No operation accepts a path. **No path crosses the worker layer's boundary.**

---

## 7. Failure Semantics

| Situation | Detection | Mapping |
|---|---|---|
| Local input missing | `FileManager` check before any command | `invalidInput` |
| Local input is a symlink | `FileManager` attribute check | `invalidInput` — **explicitly refused** |
| Local input is a directory | `FileManager` check | `invalidInput` |
| Input exceeds 10,000 chars | `DTCA1Worker.validateInput` (exists) | `invalidInput` |
| Device not connected | guard-first (Phase 4 pattern) | `deviceNotFound` / `deviceOffline` |
| Remote dir missing | `mkdir -p` before push | created |
| Remote path not writable | `adb` exit ≠ 0 | `adbCommandFailed` |
| Remote result missing | `adb pull` exit 1 (`failed to stat`) | `workerError` — "worker produced no result" |
| Push/pull non-zero exit | exit code | `adbCommandFailed` |
| **Interrupted transfer** | **size mismatch after transfer** | `workerError` — partial transfer |
| Malformed result JSON | `JSONDecoder` throws | `verificationFailed` (ADR-004: do not trust) |

**Interrupted transfer (D3 below).** `adb` reports success on completion; it does not expose
a resumable state. Detection is therefore **post-hoc**: compare the transferred file's size
against the expected size (local source for push; the device's `stat` for pull). A mismatch is
a partial transfer and is treated as a failure — never as a successful transfer of unknown
content.

---

## 8. Overwrite Policy

**Finding:** `adb` overwrites silently with exit 0 (§2.2). It provides no protection.

**Decision: allow overwrite, deliberately, and document it.**

Reasoning: the contract has **fixed filenames** — `input.txt` and `result.json`. Overwriting
is the intended semantics: the next workload replaces the previous input, and the next result
replaces the previous result. Refusing to overwrite would require a delete-then-push dance and
would make the second workload fail for no benefit.

What is **not** allowed:
- No overwrite of any file outside the two fixed paths (unreachable — fixed paths)
- No `--sync` or partial-update modes
- No overwrite of the staging directory itself (only the two files)

**Rejected alternative:** refuse-if-exists. It would fail on the second workload and requires
`rm` on the device — adding a destructive operation for no gain.

---

## 9. Test Strategy

### Hermetic (mock-based)

| Test | Asserts |
|---|---|
| Path constants | Exactly the two fixed remote and two fixed local paths; no API accepts a path |
| Local validation | Missing file → `invalidInput`; **symlink → `invalidInput`**; directory → `invalidInput`; oversized → `invalidInput` |
| **Symlink rejection** | A symlink in staging is refused, not followed — the §2.6 escape |
| **Directory rejection** | A directory operand is refused — the §2.9 recursion |
| Push argv | Exact `adb -s <serial> push <local> <remote>`; **one invocation** |
| Pull argv | Exact `adb -s <serial> pull <remote> <local>` |
| Nonexistent remote | `adb` exit 1 → `workerError`, not a silent empty success |
| Non-zero exit | → `adbCommandFailed` |
| Interrupted transfer | Size mismatch → `workerError` |
| Malformed JSON | → `verificationFailed` |
| Guard-first | Offline device → zero commands |
| **No path parameter exists** | Compile-time: the protocol surface has no path argument |
| Real captured output | `adb push`/`pull` output shapes retained as fixtures |

### Real-device (opt-in, device attached)

| Test | Asserts |
|---|---|
| Round-trip | Push input → verify on device via `cat` → pull → **byte-identical** |
| Remote workspace | `mkdir -p` creates the root; push into it succeeds |
| Result retrieval | Pull a known result file; content matches |
| Overwrite | Second push replaces the first; content is the second |
| Missing result | Pull of a nonexistent result → clean `workerError` |
| Size verification | Transferred size equals source size |
| Cleanup | Probe files removed; remote root verified clean afterwards |

**No destructive test beyond overwriting the two fixed files inside the worker root.**

---

## 10. Real-Device Verification Strategy

1. Confirm the device is attached (`adb devices`) — it detached twice in earlier phases.
2. Create the remote workspace; confirm with `ls -ld`.
3. Push a known input; confirm **on the device** with `cat` (not just by exit code).
4. Pull it back; `cmp` against the original — **byte-identical**.
5. Push a second, different input to the same path; confirm the content changed (overwrite).
6. Pull a nonexistent result; confirm a clean, typed failure.
7. Cross-check every value against **raw `adb`** invoked outside project code.
8. Remove all probe files; confirm the remote root is clean.

Assertions check **well-formedness and identity**, never a pinned version (ADR-006).

---

## 11. Explicitly Deliberately Unsupported

| Not supported | Why |
|---|---|
| Caller-supplied remote path | Removes the entire traversal surface (§2.3, §2.4) |
| Caller-supplied local path | Removes the local traversal surface (§2.5) |
| Directory transfer | `adb` recurses (§2.9); would transfer trees |
| Symlink following | A symlink is a full escape (§2.6) |
| Arbitrary file sizes | Payload is ≤ 10 KB by spec; cap at 1 MB |
| Resumable / chunked transfer | Payloads are tiny; no evidence justifies it |
| Remote file deletion / cleanup | Destructive; no consumer |
| `--sync` / partial update | No consumer; adds ambiguity |
| APK delivery via push | `adb install` is the correct mechanism (ADR-003) |
| Multi-file batches | One input, one result |
| General file manager | Explicitly out of scope |

---

## 12. Decisions Requiring Your Approval

| # | Decision | Recommendation |
|---|---|---|
| **D1** | Remote root = `/data/local/tmp/pixeldesktop/` | **Approve.** Writable by `shell`, **not world-readable** (unlike `/sdcard`). |
| **D2** | **Fixed filenames, no caller-supplied paths anywhere** | **Approve.** Makes every traversal case unreachable by construction. |
| **D3** | Interrupted transfer detected by post-hoc size comparison | **Approve.** `adb` exposes no resumable state; a mismatch is a failure. |
| **D4** | Overwrite **allowed** and documented, for the two fixed paths | **Approve.** Fixed filenames mean overwrite is the intended semantics. |
| **D5** | Local staging = app container `Application Support/PixelDesktop/Staging/` | **Approve.** Sandboxed; not a user-visible location. |
| **D6** | `push`/`pull` as transport primitives + new `Worker/` layer for policy | **Approve.** Mirrors ADR-009's transport/operations split. |
| **D7** | Refuse symlinks and directories as local operands | **Approve.** Both are demonstrated escapes/recursion (§2.6, §2.9). |
| **D8** | Defer the worker APK itself to a separate step | **Approve.** This proposal covers the transfer contract; the APK is its own work. |

---

## 13. ADR Recommendation

**ADR-010: Worker Transfer Contract and Path Containment**, recording:

1. **The empirical finding that `adb` does not sanitize paths** — `../` resolves through the
   filesystem, absolute paths escape any staging root, local destinations escape on `pull`,
   and symlinks are followed. Traversal "protection" observed in early probes was permission
   failure, not a control. This is the load-bearing evidence.
2. **The containment strategy: eliminate path input rather than validate it.** Fixed
   filenames in fixed directories. Validation is the fallback, not the mechanism.
3. **Overwrite is silent in `adb`** and is permitted deliberately for the two fixed paths.
4. **Interrupted transfers are detected post-hoc by size**, since `adb` exposes no
   resumable state.
5. **Transport executes, worker layer decides** — the same split as ADR-009.
6. **The protection model and its limitations**, in the same spirit as ADR-009: the contract
   is safe because it is *narrow*, not because paths are validated. If a future phase needs a
   variable path, this ADR must be revisited and a real path validator written.
7. **Path arguments are not a command-injection vector** for `push`/`pull` (they are argv
   elements), but a path passed to `shell()` **is** a different risk class — noted so the two
   are not conflated.

---

## 14. Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| A future phase adds a variable path and inherits the traversal surface | Medium | High | ADR-010 states the contract is safe by narrowness; revisit conditions named |
| Symlink in staging exfiltrates a local file | Medium | **High** | Refused as an operand (D7); tested |
| Directory operand transfers a tree | Medium | Medium | Refused (D7); tested |
| `/data/local/tmp` cleared on reboot | High | Low | `prepareRemoteWorkspace` runs before each workload |
| Silent overwrite loses a result before it is read | Low | Medium | Read result immediately after pull; single-run flow |
| Partial transfer treated as success | Medium | Medium | Size comparison (D3); tested |
| Device detached mid-transfer | Medium | Medium | Guard-first + non-zero exit; device detached twice in earlier phases |

---

## 15. What This Proposal Does Not Do

- Does not implement anything. No source file has been modified.
- Does not design the worker APK (D8).
- Does not add a file manager, a general transfer API, or a path abstraction layer.
- Does not touch the UI.
- Does not change Phase 2/3/4 behaviour.

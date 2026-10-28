# Phase 5 (Part 1) Test Report — Worker Transfer Contract

**Date:** 2026-10-01
**Phase:** 5 — Pixel Compute Worker (transfer contract scope)
**Device:** Pixel 7a, serial `DEADBEEF000000`

---

## 1. Build

```
$ xcodegen generate
$ xcodebuild -project PixelDesktop.xcodeproj -scheme PixelDesktop -configuration Debug build
** BUILD SUCCEEDED **
```

One pre-existing warning from Phase 1 (`ConformanceIsolation` on `DeviceManager`).
One new warning **fixed during this phase**: `ADBWorkerOperations` stored a `FileManager`,
which is not `Sendable`, on a `Sendable` struct. Replaced with an inline reference to the
shared instance.

---

## 2. Default test suite (hermetic)

```
Executed 29 tests, with 0 failures
Executed 4 tests, with 4 tests skipped and 0 failures
Executed 69 tests, with 0 failures
Executed 13 tests, with 0 failures
Executed 12 tests, with 0 failures
Executed 131 tests, with 4 tests skipped and 0 failures (0 unexpected)
** TEST SUCCEEDED **
```

**127 hermetic tests, 0 failures.** 4 integration tests skipped by design.

### New in Phase 5 (25 tests)

| Test | Verifies |
|---|---|
| `testContractPathsAreFixedConstants` | Both payload paths under the single fixed root |
| `testLocalStagingIsInsideTheContainerAndNotUserVisible` | Staging under `Application Support`; fixed filenames |
| `testValidateRegularFileAcceptsRegularFile` | Regular file accepted, byte count reported |
| `testValidateRegularFileRejectsMissingFile` | → `invalidInput` |
| `testValidateRegularFileRejectsSymlink` | **Symlink refused, message names the reason** |
| `testValidateRegularFileRejectsSymlinkToRegularFile` | **Link to a regular file also refused** (check does not follow) |
| `testValidateRegularFileRejectsDirectory` | **Directory refused** (adb would recurse) |
| `testValidateRegularFileRejectsOversizedFile` | Over 1 MB → `invalidInput` |
| `testVerifySizeMatch` / `testVerifySizeMismatch` | D3 verification outcomes |
| `testParseRemoteSize` / `…ReturnsNilForMissingOrGarbage` | `stat` output parsing |
| `testPrepareRemoteWorkspaceUsesFixedRoot` | Exact argv incl. `chmod 700` |
| `testPrepareRemoteWorkspaceRestrictsPermissions` | **FAIL-003 regression: workspace must be restricted** |
| `testPrepareRemoteWorkspaceSurfacesFailure` | Non-zero exit → `adbCommandFailed` |
| `testSubmitInputPushesToFixedRemotePath` | Exact `adb push` argv, both fixed paths |
| `testSubmitInputRejectsOversizedTextBeforeTouchingDevice` | **Zero invocations** |
| `testSubmitInputRejectsNullBytesBeforeTouchingDevice` | **Zero invocations** |
| `testSubmitInputSurfacesTransportFailure` | Push failure → `adbCommandFailed` |
| `testSubmitInputDetectsSizeMismatch` | **Partial push → mismatch, not verified** |
| `testRetrieveResultPullsAndDecodes` | Exact `adb pull` argv; decoded; size verified |
| `testRetrieveResultMissingPayloadIsWorkerError` | Missing payload → `workerError` |
| `testRetrieveResultMalformedJSONIsVerificationFailure` | → `verificationFailed` (ADR-004) |
| `testRetrieveResultPartialTransferIsWorkerError` | **Truncated transfer refused** |
| `testRetrieveResultRemovesStaleLocalResultFirst` | Stale result cannot masquerade as fresh |

### Phases 1–4 tests rerun (regression)

All pass, including `testDiscoveryLeavesPropertiesUnpopulated`,
`testDisconnectInvalidatesEnrichedProperties`, all Phase 4 containment/injection tests, all
Phase 3 device-model tests, and all 17 DTCA-1 worker/verifier tests.

---

## 3. Real-device verification (exact fixed contract)

```
STEP 1 — CONTRACT CONSTANTS
    remote root   : /data/local/tmp/pixeldesktop
    remote input  : /data/local/tmp/pixeldesktop/input.txt
    remote result : /data/local/tmp/pixeldesktop/result.json
    local staging : /Users/.../Library/Application Support/PixelDesktop/Staging
  [PASS] remote root is the approved path
STEP 2 — PREPARE REMOTE WORKSPACE (fixed path)
  [PASS] remote workspace exists — drwx------ 2 shell shell /data/local/tmp/pixeldesktop
  [PASS] remote root is not world-readable — mode=700
STEP 3 — SUBMIT INPUT (fixed path, size-verified)
  [PASS] input size verification passed — match(expected: 69, actual: 69)
  [PASS] device holds the exact payload
  [PASS] device-reported size matches raw adb — device=69 expected=69
STEP 4 — OVERWRITE (D4, deliberate)
  [PASS] overwrite verified — match(expected: 34, actual: 34)
  [PASS] device holds the SECOND payload
STEP 5 — RETRIEVE RESULT (fixed path)
  [PASS] result decoded
  [PASS] result size verified — match(expected: 226, actual: 226)
  [PASS] result content correct
  [PASS] local result is byte-identical to device
STEP 6 — FAILURE PATHS (real device)
  [PASS] missing payload raises workerError
  [PASS] oversized input rejected
  [PASS] unknown serial fails cleanly
STEP 7 — CONTRACT NARROWNESS (no path parameter exists)
  [PASS] local staging is inside the app container
  [PASS] staging is not user-visible storage
STEP 8 — DEVICE HEALTH + CLEANUP
  [PASS] remote workspace removed
  [PASS] device still healthy

RESULT: PASS — all checks passed
```

### Cross-check against raw `adb`

| Quantity | Project code | Raw adb |
|---|---|---|
| Input size on device | 69 bytes | 69 bytes ✅ |
| Input content on device | the exact payload | identical ✅ |
| Result size | 226 bytes | 226 bytes ✅ |
| Local result vs device | byte-identical | ✅ |
| Workspace mode | 700 | 700 ✅ |

---

## 4. Failures found during real-device verification

### FAIL-003 — workspace created world-readable

The **first** run failed with:

```
[FAIL] remote root is not world-readable — mode=777
```

`mkdir -p` alone produced mode **777**. ADR-010 chose `/data/local/tmp` *because* it is not
world-readable — true of the parent (771), but the created directory inherited a permissive
mode, so the stated rationale was not true of the directory the contract actually uses.

**Why unit tests could not catch it:** the test asserted that `mkdir -p` was *invoked*. It
could not observe the resulting permissions, which require a real filesystem.

**Fix:** `prepareRemoteWorkspace` now runs `mkdir -p … && chmod 700 …`, and
`testPrepareRemoteWorkspaceRestrictsPermissions` pins it. This **tightened** the contract
rather than relaxing the check.

**Re-run after fix:** mode 700, all checks PASS.

### Harness bug — a false FAIL

The cleanup check reported `[FAIL] remote workspace removed` although the cleanup was correct:
`ls` writes "No such file or directory" to **stderr**, which the harness discarded. Fixed by
capturing stderr. Recorded because a harness bug that produces a false failure is as
misleading as one that produces a false pass.

---

## 5. Requirements traceability

| # | Requirement | Evidence |
|---|---|---|
| D1 | Remote root `/data/local/tmp/pixeldesktop/` | §3 STEP 1–2; mode 700 enforced |
| D2 | Fixed filenames; no caller paths | `WorkerOperationsProtocol` has **no path parameter**; §2 path-constant tests |
| D3 | Size verification, documented as non-cryptographic | §2 size tests; ADR-010 §"Transfer interruption" |
| D4 | Deliberate overwrite | §3 STEP 4 |
| D5 | Local staging in container, not caller-substitutable | §2 staging test; §3 STEP 7 |
| D6 | Narrow primitives + `Worker/` layer | §2 argv tests; ADR-010 responsibility table |
| D7 | Symlink/directory rejection, regular files only | §2 four validation tests |
| D8 | Worker APK deferred | Not implemented; phase scope is the contract |
| — | Preserve reconnaissance as evidence | ADR-010 §Evidence, incl. the permission-vs-control finding |
| — | No generalization | No `sourcePath`/`destinationPath`; no directory/recursive transfer |
| — | Tests before/alongside implementation | 25 tests, listed against the requested cases |
| — | Real-device proof of the exact contract | §3 |
| — | Full Phase 1–5 regression | §2 |

---

## 6. Artifacts

- Real-device verification harness: `~/.hermes/cache/scratch/pd-verify5/`
- Path-behaviour probe scratch: `~/.hermes/cache/scratch/pd-pathprobe/`
  (outside the repository; throwaway evidence tools, not project artifacts)

All probe files were removed from the device and the remote workspace was deleted; the device
was verified healthy afterwards.

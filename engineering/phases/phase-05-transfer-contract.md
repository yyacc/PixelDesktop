# Phase 5 (Part 1) — Worker Transfer Contract

**Status: COMPLETE** (transfer contract only — the worker APK is a separate step, D8)
**Date:** 2026-10-01
**Phase:** 5 (Pixel Compute Worker) — authoritative per [ADR-007](../decisions/ADR-007-authoritative-phase-sequence.md)
**Preceding phase:** Phase 4 (Android Application / Process Control) — COMPLETE
**Proposal:** `phase-05-transfer-contract-proposal.md` (approved, D1–D8)
**Covers:** RNZM-23 (`push()`/`pull()`), scoped to the fixed transfer contract

---

## Phase Objective

Prove the Pixel can reliably execute a workload and return a verifiable result. This step
delivers the **transfer contract** that moves the input to the device and the result back.
The worker APK itself, worker lifecycle and compute execution are **out of scope** (D8).

---

## Requirements

| # | Decision |
|---|---|
| D1 | Remote root `/data/local/tmp/pixeldesktop/` |
| D2 | Fixed filenames; **no caller-supplied paths** in the worker-facing contract |
| D3 | Post-transfer **size verification** as the integrity check; document that it is not cryptographic |
| D4 | Overwrite the two fixed payload locations **deliberately** |
| D5 | Local staging inside the container, outside user-visible storage; not caller-substitutable |
| D6 | `push()`/`pull()` as narrow transport primitives; all policy in the `Worker/` layer |
| D7 | Reject symlinks and directories; regular files only; no generalized filesystem manager |
| D8 | Defer the worker APK to its own step |

Plus ADR-010 covering the fixed-path contract, root and staging ownership, overwrite
semantics, interruption semantics, regular-file-only behaviour, symlink/directory rejection,
transport-vs-worker responsibility, why narrowness is the primary mechanism, the limits of
that model, and the requirement to revisit before any variable-path contract.

---

## Starting State

Phase 4 complete: 106 tests, BUILD SUCCEEDED, commit `2d11352`. `TransportProtocol` had
`execute`, `listDevices`, `getprop`, `getSystemProperties`, `shell`. **No `push`/`pull` and no
path abstraction existed anywhere.**

---

## Investigation

Every security question was answered by **executing it on the real Pixel 7a**, not from
documentation. Full evidence in ADR-010 §Evidence. The decisive findings:

| # | Finding |
|---|---|
| 1 | **`adb` does not sanitize paths.** `../` is resolved by the filesystem, not rejected. The failures that *did* occur were **permission denials**, not a control. |
| 2 | Absolute remote paths escape any staging root with no traversal needed. |
| 3 | A local `pull` destination containing `../` **escaped staging** (exit 0). |
| 4 | **Symlinks are followed.** Pushing a symlink → `/etc/hosts` pushed its contents. |
| 5 | Directory operands **recurse**. |
| 6 | Overwrite is **silent, exit 0** — no protection. |
| 7 | Path arguments are **not** a command-injection vector (argv, no shell) — unlike a path passed to `shell()`. |
| 9 | `mkdir -p` produced a **777 world-readable** directory, contradicting D1's rationale. Found during real-device verification. |

---

## Architecture

```
AppState / caller
      │  supplies CONTENT, never a path
      ▼
WorkerOperationsProtocol          prepareRemoteWorkspace · submitInput · retrieveResult
      │  no path parameter exists on this surface
      ▼
WorkerTransferContract            fixed path constants · validation · size verification
      │  + ADBWorkerOperations     owns all policy
      ▼
TransportProtocol.push() / pull()  narrow primitives; no path policy
      ▼
ADBTransport (actor) → adb → Pixel 7a
```

| Layer | Owns | Does not |
|---|---|---|
| Caller | Payload content | Any path |
| `WorkerOperationsProtocol` | Named worker operations | Accept paths |
| `WorkerTransferContract` | Path constants, regular-file validation, size verification | Execute commands |
| `ADBWorkerOperations` | Command construction, overwrite policy, workspace setup | Discover devices |
| `ADBTransport.push/pull` | Executing `adb push`/`adb pull` | Any path policy |

---

## Alternatives Considered

**A. Caller-supplied paths with validation** — rejected; reintroduces every evidence case, and
Phase 4 showed validation-based containment is fragile.

**B. `/sdcard` as the remote root** — rejected; FUSE-mounted and world-readable to any
installed app.

**C. Refuse-if-exists overwrite** — rejected; fails the second workload and needs a destructive
`rm` for no benefit.

**D. Directory/recursive transfer** — rejected; `adb` recurses and no consumer needs it.

**E. Follow symlinks** — rejected; a symlink is a full escape from staging.

**F. Fixed contract with no path input (narrowness)** — **chosen.**

**G. Chunked/resumable transfer** — rejected; payloads are ≤10 KB by specification.

---

## Decision

- `TransportProtocol` gains `push()` and `pull()` — narrow primitives taking already-validated
  absolute paths.
- New `Worker/` layer: `WorkerTransferContract` (constants, validation, integrity) and
  `WorkerOperationsProtocol` / `ADBWorkerOperations` (named operations, **no path arguments**).
- Fixed paths: remote `/data/local/tmp/pixeldesktop/{input.txt,result.json}`; local
  `<container>/Application Support/PixelDesktop/Staging/{input.txt,result.json}`.
- `prepareRemoteWorkspace` runs `mkdir -p … && chmod 700 …`.
- Regular-file-only, symlink and directory rejection, 1 MB cap.
- Size verification both directions; documented as **not** cryptographic integrity.
- `DeviceOperation` **not** extended — transfer is a payload mechanism, not a device operation.
- Recorded in **ADR-010**.

---

## Implementation

### Files created

| File | Purpose |
|---|---|
| `PixelDesktop/Worker/WorkerTransferContract.swift` | Fixed paths, validation, size verification |
| `PixelDesktop/Worker/WorkerOperationsProtocol.swift` | Named operations + `ADBWorkerOperations` |
| `engineering/decisions/ADR-010-worker-transfer-contract.md` | Contract and protection limits |
| `engineering/phases/phase-05-transfer-contract.md` | This document |
| `engineering/testing/phase-05-test-report.md` | Test and verification evidence |

### Files modified

| File | Change |
|---|---|
| `Transport/Transport.swift` | `push()` / `pull()` on the protocol |
| `Transport/ADBTransport.swift` | `push()` / `pull()` implementations |
| `PixelDesktopTests/PixelDesktopTests.swift` | 25 tests added; `MockTransport` push/pull |
| `engineering/README.md`, `architecture/overview.md`, `created-resources.json` | Index, architecture, manifest |

---

## Failures

**Two findings from the first real-device run.** Both were real, and neither was caught by
unit tests.

**FAIL-003 — the workspace was created world-readable.** `mkdir -p` alone produced mode
**777** on `/data/local/tmp/pixeldesktop`. ADR-010 chose that root *specifically because it is
not world-readable to other applications* — the parent is 771 — but the directory created
inside it inherited a permissive mode, so the stated rationale was not actually true of the
directory the contract uses.

Diagnosed as **implementation / contract tightening**: the fix makes the rationale true rather
than changing the design. `prepareRemoteWorkspace` now runs
`mkdir -p … && chmod 700 …`, and `testPrepareRemoteWorkspaceRestrictsPermissions` pins it.

This is the third defect in this project that compiled cleanly and passed the full suite while
being wrong. All three were caught by comparing against reality.

**Harness bug — a false FAIL.** The cleanup check asserted `ls` of the removed directory
contained "No such file", but `ls` writes that to **stderr**, which the harness discarded. The
cleanup was correct; the assertion was blind. Fixed by capturing stderr. Recorded because a
harness bug that produces a false failure is as misleading as one that produces a false pass.

**One compile warning fixed:** `ADBWorkerOperations` stored a `FileManager`, which is not
`Sendable`, on a `Sendable` struct. Replaced with an inline reference to the shared instance.

---

## Diagnosis

- **FAIL-003** classified as **implementation / over-permissive default**, surfaced by
  real-device verification. Evidence: `stat -c %a` returned `777` on the real device while the
  unit test asserted only that `mkdir -p` was invoked — it could not observe the resulting mode.
- **Harness bug** classified as **test tooling**, not a product defect.
- **Sendable warning** classified as **implementation**, caught at build time.

---

## Corrections

1. `prepareRemoteWorkspace` now chains `chmod 700`.
2. Added `testPrepareRemoteWorkspaceRestrictsPermissions`; updated the exact-command test.
3. Harness now captures stderr so cleanup assertions are meaningful.
4. Removed the non-`Sendable` stored `FileManager`.

---

## Tests

**25 tests added.** Coverage matches the requested list exactly:

| Requested | Tests |
|---|---|
| Fixed contract | `testContractPathsAreFixedConstants`, `testLocalStagingIsInsideTheContainerAndNotUserVisible` |
| Overwrite behaviour | real-device `STEP 4` (unit: fixed-path push asserted) |
| Size mismatch / interruption | `testVerifySizeMatch`, `testVerifySizeMismatch`, `testSubmitInputDetectsSizeMismatch`, `testRetrieveResultPartialTransferIsWorkerError` |
| Regular-file requirement | `testValidateRegularFileAcceptsRegularFile`, `…RejectsMissingFile`, `…RejectsOversizedFile` |
| **Symlink rejection** | `…RejectsSymlink`, `…RejectsSymlinkToRegularFile` |
| **Directory rejection** | `…RejectsDirectory` |
| Disconnected device | `testPrepareRemoteWorkspaceSurfacesFailure`, real-device unknown-serial check |
| Missing payload | `testRetrieveResultMissingPayloadIsWorkerError`, `testRetrieveResultRemovesStaleLocalResultFirst` |
| Transport failure | `testSubmitInputSurfacesTransportFailure` |
| Permission restriction (FAIL-003) | `testPrepareRemoteWorkspaceRestrictsPermissions` |
| Malformed result | `testRetrieveResultMalformedJSONIsVerificationFailure` |
| Input limits | `testSubmitInputRejectsOversizedTextBeforeTouchingDevice`, `…RejectsNullBytes…` |
| Parsers | `testParseRemoteSize`, `testParseRemoteSizeReturnsNilForMissingOrGarbage` |

---

## Results

| Check | Result |
|---|---|
| `xcodebuild ... build` | **BUILD SUCCEEDED** |
| `xcodebuild ... test` | **131 executed, 0 failures** (4 integration tests skipped by design) |
| Real device: contract constants | PASS |
| Real device: workspace created, **mode 700** | PASS |
| Real device: push, size-verified | PASS — 69 bytes = 69 bytes |
| Real device: payload byte-identical on device | PASS |
| Real device: **overwrite** | PASS — second payload replaced the first |
| Real device: pull, size-verified, decoded | PASS — 226 bytes = 226 bytes |
| Real device: local result byte-identical | PASS |
| Real device: missing payload → `workerError` | PASS |
| Real device: oversized input rejected | PASS |
| Real device: unknown serial fails cleanly | PASS |
| Real device: cleanup + device healthy | PASS |
| Cross-check vs raw `adb` | PASS — sizes and contents confirmed outside project code |

**Full approved sequence executed:** prepare workspace → submit input (size-verified) → confirm
on device → overwrite → retrieve result (size-verified, decoded) → failure paths → cleanup.

---

## Regression Tests

All Phase 1–4 guarantees re-verified. 131 tests pass, including:
`testDiscoveryLeavesPropertiesUnpopulated`, `testDisconnectInvalidatesEnrichedProperties`, all
Phase 4 containment and injection tests, all Phase 3 device-model tests, and all 17 DTCA-1
worker/verifier tests.

---

## Final Architecture

```
PixelDesktop/
├── App/            AppState
├── Core/Models/    AndroidDevice.swift, InstalledApp.swift
├── Core/Errors/    PixelDesktopError.swift
├── Core/Logging/   AppLogger.swift
├── Operations/     AppOperationsProtocol.swift, ADBAppOperations.swift
├── Worker/         WorkerTransferContract.swift, WorkerOperationsProtocol.swift   ← NEW
├── Device/         DeviceDiscovery, DeviceManager, DeviceEnricher
├── Transport/      Transport.swift, ADBTransport.swift
├── Compute/        DTCA1Worker.swift
└── Verification/   ResultVerifier.swift
```

`DeviceOperation` unchanged at 6 cases — transfer is not a device operation.

---

## Lessons Learned

1. **Permission failures look like security controls.** The first traversal probes returned
   exit 1 and could easily have been recorded as "adb blocks traversal". Re-testing inside a
   writable area showed `../` succeeds. **Test the mechanism, not the symptom.**
2. **A documented rationale is not a verified fact.** ADR-010's proposal argued
   `/data/local/tmp` is not world-readable — true of the parent (771), false of the directory
   the contract creates (777). The rationale was correct about the *neighbourhood* and wrong
   about the *thing*. **Verify the specific object, not the category it belongs to.**
3. **Unit tests cannot observe side effects they do not assert on.** The mode test asserted
   `mkdir -p` was invoked; it could not see the resulting permissions. Only `stat` on the real
   device could.
4. **A harness bug can produce a false failure as easily as a false pass.** Discarding stderr
   made a correct cleanup look broken. Both directions of wrongness matter.

---

## What Worked Well

- **Empirical probing before design** — the entire containment strategy follows from four
  measured facts, not from assumptions about adb.
- **Separating "adb refused" from "the OS refused"** — the two-test method (traversal inside a
  writable area vs outside) is what exposed finding 1.
- **Narrowness as the mechanism** — there is no path parameter to attack, so the whole class of
  traversal defects is structurally absent rather than defended against.
- **Refusing to loosen the contract when verification failed** — the 777 finding tightened the
  contract instead of relaxing the check.
- **`attributesOfItem` verified before relying on it** — confirmed it reports symlinks without
  following, so the symlink check cannot be bypassed.
- **A fixed, pre-approved verification sequence** — made the failure unambiguous.

---

## What Did Not Work

- **Assuming the parent directory's permissions describe the created directory.** They did not.
- **A harness that captured only stdout** — produced a false FAIL on correct cleanup.
- **Storing a non-`Sendable` `FileManager` on a `Sendable` struct** — caught at build time.
- **A multi-line Swift string literal for a single-line JSON payload** — compile error;
  replaced with a raw string.

---

## Best Technique Discovered

**Separate "the tool refused" from "the operating system refused" before concluding a control
exists.**

Why it worked: the first traversal probes failed, and the natural conclusion was "adb blocks
`../`". Re-running the same traversal *inside a writable directory* succeeded, proving the
failures were permission denials. Without that second test, the entire security model would
have rested on a false premise — and would have been wrong in the direction of *understating*
the risk.

When to use it: whenever a security-relevant operation fails and you are about to record the
failure as protection. Confirm the failure comes from the layer you think it does.

When not to use it: when the failure is already unambiguous and attributable (e.g. an explicit
"permission denied" naming the mechanism).

**Second-best: verify the specific object, not the category.** `/data/local/tmp` not being
world-readable did not make `/data/local/tmp/pixeldesktop` not world-readable.

---

## Future Recommendations

1. **The worker APK is the next step (D8).** It is separate work: APK build, installation, and
   the compute execution path. Do not fold it into this contract.
2. **`DeviceOperation` was deliberately not extended.** If the worker needs a device operation,
   add it then, with its implementation.
3. **Before any variable-path contract, revisit ADR-010 and write a real path validator.**
   This is a hard requirement, not a suggestion.
4. **If concurrent workloads are ever needed**, the fixed filenames become a constraint and a
   per-run subdirectory would be needed — which reintroduces a path component and therefore
   requires the validator.
5. **The size check is not integrity verification.** Result correctness comes from ADR-004
   re-computation. Do not treat a size match as proof of correctness.
6. **Do not call `TransportProtocol.push/pull` directly with caller-supplied paths.** The
   primitives have no policy.

---

## Phase Completion Record (transfer contract scope)

```
PHASE STATUS: COMPLETE (transfer contract; worker APK deferred per D8)

Requirements:            PASS  (D1-D8 honoured; no decision required broadening)
Build:                   PASS  (xcodebuild Debug — BUILD SUCCEEDED)
Tests:                   PASS  (131 executed, 0 failures; 4 integration skipped by design)
Device verification:     PASS  (exact fixed contract proven on the real Pixel 7a)
Security review:         PASS  (ADR-010 documents the model AND its limits)
Failure handling:        PASS  (missing payload, oversized input, unknown serial, partial transfer)
Regression:              PASS  (Phases 1-4 all pass)
Architecture review:     PASS  (ADR-010)
Documentation:           PASS  (phase log, ADR-010, test report, architecture/overview.md)
AI development log:      UPDATED
Known limitations:       DOCUMENTED
```

**Known limitations**

- **The contract is safe because it is narrow, not because paths are validated.** It provides
  no general path-safety mechanism. Any variable-path contract requires ADR-010 to be revisited
  and a real validator written first.
- It does not protect against a caller that bypasses `WorkerOperationsProtocol` and calls
  `TransportProtocol.push/pull` directly. Containment constrains the worker layer, not a
  hostile holder of the transport.
- **Size verification is not cryptographic integrity verification.** It cannot detect
  same-length corruption. Correctness of the result is established by ADR-004 re-computation.
- `DeviceOperation` was not extended; transfer is not a device operation.
- The worker APK, worker lifecycle and compute execution are **not implemented** (D8) — this
  phase delivers the transfer contract only.
- The remote workspace is cleared on reboot; `prepareRemoteWorkspace` must run before each
  workload.
- Fixed filenames mean **one workload at a time**; concurrency would need a per-run directory
  and therefore the path validator.
- Real-device verification requires the device to stay attached (it detached twice in earlier
  phases).

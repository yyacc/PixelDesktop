# Phase 5 D8 — Pixel Compute Worker: Implementation Report

**Status: COMPLETE (first implementation + real-device verification checkpoint)**
**Date:** 2026-10-02
**Phase:** 5 (Pixel Compute Worker), D8
**Preceding:** transfer contract `a34ed10`; design checkpoint `e77308a`
**Decisions:** D-1…D-10 approved

---

## Phase Objective

Prove that the Pixel can perform a useful bounded compute workload and return an independently
verifiable result — with evidence distinguishing *"the Mac computed the answer"* from *"the Pixel
worker computed the answer."*

---

## What Was Built

### The Android worker (`DTCA1Worker/`)

| File | Purpose |
|---|---|
| `app/src/main/AndroidManifest.xml` | One Activity, **zero permissions**, no service/receiver/provider |
| `.../WorkerActivity.java` | One-shot: read fixed job → compute → write fixed result → finish |
| `.../Dtca1.java` | DTCA-1, a faithful port of `DTCA1Worker.swift` |
| `settings.gradle`, `build.gradle`, `app/build.gradle`, `gradle.properties`, wrapper | Gradle 8.13 / AGP 8.13.0 / Java 17 / minSdk 31 / targetSdk 36 |

Two Java files. No libraries beyond the Android SDK — JSON comes from the platform's `org.json`.

### The macOS side

| File | Change |
|---|---|
| `Transport/Transport.swift` | `install()` primitive added to the protocol |
| `Transport/ADBTransport.swift` | `install()` implementation |
| `Worker/WorkerTransferContract.swift` | Root moved to the app's external dir; `remoteWorkspaceCreateCommand` **removed**, `remoteWorkspaceExistsCommand` added |
| `Worker/WorkerInstaller.swift` | **New** — package identity, install/replace, version detection |
| `Worker/WorkerLifecycle.swift` | **New** — start, stop, observe; four-state model |
| `Worker/DTCA1Job.swift` | **New** — job encoding + `WorkerResultEnvelope` decoding |
| `Worker/WorkerComputeProof.swift` | **New** — orchestration and evidence collection |
| `Worker/WorkerOperationsProtocol.swift` | Workspace check instead of create |
| `PixelDesktopTests/PixelDesktopTests.swift` | +21 tests |
| `.gitignore` | Android artifacts ignored; `created-resources.json` **un-ignored** (master prompt §28 requires it tracked) |

### Deliberately NOT added

No LLM inference, model download/management, network server, socket/RPC, permissions, root, GPU
driver manipulation, APK modification, code injection, anti-cheat, resource scheduler, generalized
job system, generalized process manager, Service, or daemon. All recorded as non-goals in ADR-011.

---

## The Compute Proof (real device, serial `3C261JEHN25632`)

```
=== STEP 1: DEVICE ===
  [PASS] device attached — state=device
=== STEP 2: INSTALL (narrow WorkerInstaller) ===
  [PASS] worker installed — versionCode=1
  [PASS] worker versionCode is 1
=== STEP 3: ZERO PERMISSIONS (verified on device, not from source) ===
  [PASS] no requested permissions block — grep count=0
=== STEP 4: EXCHANGE DIRECTORY MODE (the FAIL-003 property, on the real device) ===
  [PASS] exchange dir is not world-readable — mode=2770
      owner=u0_a45  mode=2770          <- the APP's UID, not shell
=== STEP 5: COMPUTE PROOF — run one DTCA-1 job ===
--- EVIDENCE ---
      job_id                 : E36D4074-913D-4EC7-A2F9-2C41241023F7
      worker pid             : 13644
      installed versionCode  : 1
      wall clock             : 343 ms
      worker-reported time   : 1 ms
      cpu ticks consumed     : 20
      verification           : VERIFIED
  [PASS] result verified by independent local re-computation
  [PASS] worker returned a PID — pid=13644
  [PASS] worker package identity confirmed
  [PASS] worker process consumed attributable CPU time — ticks=20
=== STEP 6: WAS IT THE PIXEL? (independent cross-checks) ===
      Mac local  : words=27 unique=24 class=NATURAL_LANGUAGE conf=0.3333
      Pixel (raw adb): {"status":"COMPLETED","job_id":"E36D4074-...","input_characters":179,
                        "total_words":27,"unique_words":24,"top_words":[{"word":"the","count":3},...
  [PASS] result file is on the device
  [PASS] result carries the job_id echoed by the worker
      /proc/13644/cmdline: com.pixeldesktop.worker
  [PASS] PID belonged to the worker package
=== STEP 7: REPEATED INVOCATION (determinism) ===
      run 1: verified=true wall=333ms
      run 2: verified=true wall=296ms
      run 3: verified=true wall=361ms
  [PASS] 3/3 repeated runs verified
=== STEP 8: ALREADY-RUNNING BEHAVIOR ===
  [PASS] worker stopped cleanly
=== STEP 9: FAILURE HANDLING ===
  [PASS] oversized input rejected locally
      bogus workload result: {"status":"FAILED","job_id":"bogus-1","error_type":"INVALID_INPUT",
                              "error_message":"unsupported workload: 'NOT-A-WORKLOAD'"}
  [PASS] worker reported FAILED for an unsupported workload
=== STEP 10: CLEANUP ===
  [PASS] no probe payloads left behind

RESULT: PASS — all checks passed
```

### The evidence that distinguishes Mac from Pixel

| Evidence | Value | Rules out |
|---|---|---|
| worker package identity | `versionCode=1` | a different app running |
| worker PID | 13644 | the Mac doing the work |
| `/proc/13644/cmdline` | `com.pixeldesktop.worker` | a PID belonging to something else |
| result deleted before the run | — | a stale result reused |
| `job_id` echoed | matches | a result from a previous run |
| **CPU ticks consumed** | **20** | a result fabricated without computing |
| independent re-computation | VERIFIED | a wrong-but-plausible result |

**A matching output string alone proves none of these** — which is why the run deletes the result
before starting, checks the echoed `job_id`, reads the PID's own `/proc` entry, and measures that
PID's CPU time.

**Not claimed:** that 20 ticks is the DTCA-1 computation alone. It is the worker process's
cumulative CPU for its whole lifetime, including Android app startup.

---

## Failures Encountered

Three Android assumptions were falsified by real-device execution. **All three compiled cleanly
and passed all 154 unit tests.** Full detail: `failures/FAIL-004`.

| # | Assumption | Reality | Fix |
|---|---|---|---|
| 1 | `exported="false"` still lets adb start the Activity | `SecurityException: not exported from uid 10004` — `am start` failed outright | Export required; contained by no intent-filter + runtime launcher check |
| 2 | `getLaunchedFromUid()` returns `2000` for an adb launch | Returns **`-1`** — the check refused every legitimate run | Accept `-1`, `0`, `2000`; reject other concrete UIDs |
| 3 | adb may create the exchange directory | Created as `shell:ext_data_rw` — **the app cannot write it** | The worker creates its own directory; adb's `mkdir` removed from the contract |

Also found and fixed:

4. **A stale harness binary produced a false PASS.** A compile error left the previous binary in
   place, and it ran and passed. Recognised and rejected — a pass from a binary I did not intend to
   run is not evidence. Recompiled and re-ran on a fully clean device.
5. **`cpuTicksBefore` was `nil`**, making CPU attribution impossible. The worker lives ~250 ms, so a
   before/after delta usually has no "after". Fixed by sampling cumulative ticks **while the process
   is alive**.
6. **`created-resources.json` was gitignored** — contrary to master prompt §28, which requires it in
   the repository. Un-ignored.

---

## Corrections Made

1. `AndroidManifest.xml` — `exported="true"`, no intent-filter, with the reasoning recorded inline.
2. `WorkerActivity` — launcher check accepts the values adb actually reports; logs the observed
   value next to the decision that depends on it.
3. `WorkerActivity` — creates its own exchange directory via `getExternalFilesDir(null)`.
4. `WorkerTransferContract` — `remoteWorkspaceCreateCommand` removed; existence check added, so adb
   cannot create the directory even by accident.
5. `WorkerComputeProof` — CPU sampled during the run; `cpuTicksObservedWhileRunning` added.
6. Three Phase-5 tests updated to the corrected contract (workspace check, not create), and the
   FAIL-003 regression test re-expressed to assert the **property** (app-private external storage)
   rather than the mechanism (`chmod 700`) that no longer applies.
7. `.gitignore` — Android artifacts ignored; `created-resources.json` un-ignored.

**No approved decision was contradicted.** D-1…D-10 all held. The corrections were to
*implementation assumptions about the platform*, not to the architecture.

---

## Results

| Check | Result |
|---|---|
| APK build (Gradle, offline) | **BUILD SUCCESSFUL** |
| APK identity | `com.pixeldesktop.worker`, versionCode 1, targetSdk 36 |
| APK permissions | **none** (verified by `aapt2 dump permissions` and on-device `dumpsys`) |
| Installation (`WorkerInstaller`) | **PASS** — versionCode 1 read back from the device |
| macOS build | **BUILD SUCCEEDED** |
| macOS tests | **154 executed, 0 failures** (4 integration tests skipped by design) |
| Real-device compute proof | **PASS — all checks** |
| Result verification | **VERIFIED** (independent local re-computation) |
| Repeatability | **3/3 verified** |
| Failure handling | oversized input rejected locally; unsupported workload → `FAILED` result |
| Exchange directory | mode `2770`, owner = the app's UID |
| Cleanup | no probe payloads left; device healthy |

---

## Remaining Limitations

- **The Activity is exported.** Contained by no intent-filter, no extras, and a launcher-UID check.
  Residual exposure: another app may trigger a re-run of the existing job file; it cannot supply
  input or read the result. Recorded in ADR-011 §5 rather than glossed over.
- **The channel is unauthenticated.** ADB access is the boundary. `job_id` detects staleness, not
  forgery.
- **CPU ticks cover the whole process lifetime**, including Android startup — not the DTCA-1
  computation alone.
- **Thermal is not attributable to the worker.** `dumpsys thermalservice` is system-wide; reported
  as device thermal state only.
- **A device with a lock credential is untested.** The launch experiments used a device with no
  credential set.
- **DTCA-1 is fast** (~1 ms reported; ~250–360 ms wall clock including launch). It may be too fast
  for useful resource-behaviour evidence; the SHA-256 chain remains the conditional addition (D-3).
- **Debug-signed APK.** The debug keystore is not a trust anchor. A release keystore is out of
  scope and must never be committed.
- **`versionCode` alone is a weak identity check** — it does not prove the installed package is our
  build. Certificate comparison would be stronger and is not implemented.
- **One workload at a time.** Fixed filenames preclude concurrency.
- **No retry logic.** Failures are reported deterministically; recovery is the caller's decision.

---

## Phase Completion Record (D8 first checkpoint)

```
PHASE STATUS: COMPLETE (first implementation + real-device verification)

Requirements:            PASS  (D-1..D-10 honoured; no decision contradicted)
APK build:               PASS  (BUILD SUCCESSFUL)
macOS build:             PASS  (BUILD SUCCEEDED)
Tests:                   PASS  (154 executed, 0 failures)
Installation:            PASS  (versionCode verified on device)
Real-device execution:   PASS  (worker launched, computed, returned a result)
Compute proof:           PASS  (VERIFIED; 3/3 repeatable; CPU attributable)
Failure handling:        PASS  (invalid input rejected; FAILED result for unsupported workload)
Regression:              PASS  (Phases 1-5 all pass)
Architecture review:     PASS  (ADR-011)
Documentation:           PASS  (phase log, ADR-011, FAIL-004, test evidence)
Known limitations:       DOCUMENTED
```

**STOPPED here as instructed.** Not proceeding to model inference, resource-aware routing, Hermes
integration, or later phases.

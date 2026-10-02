# Phase 6 Implementation — Local AI Worker

**Status:** FIRST INFERENCE PROOF COMPLETE
**Date:** 2026-10-02
**Phase:** 6 (Local AI Worker) — authoritative per ADR-007
**Depends on:** Phase 5 / D8 (`5a0b004`) — the compute worker
**Approved under:** ADR-012 (approved as the Phase 6 design checkpoint)

---

## The claim established

> **A real language model, loaded from a model artifact physically stored on the Pixel 7a, performs
> inference inside the PixelDesktop worker process.**

**Established.** `Qwen2.5-1.5B-Instruct-Q4_K_M` was loaded from
`/sdcard/Android/data/com.pixeldesktop.worker/files/model/` by llama.cpp running as an APK native
library inside the worker process on the physical Pixel 7a, and generated text.

**Not claimed:** that the output is *correct*, or that the performance is production-ready. Neither
is a Phase 6 requirement, and neither is asserted anywhere in this document.

---

## 1. What was built

### Android side (`DTCA1Worker/`)

| File | Role |
|---|---|
| `cpp/llama_jni.cpp` | **The only file touching llama.cpp's C API.** The runtime adapter boundary (ADR-012 §2). |
| `cpp/CMakeLists.txt` | Links the prebuilt llama.cpp static libs into one shared library. |
| `java/.../LlamaBridge.java` | The whole Java-side contact point with the native runtime. |
| `java/.../LlmWorkload.java` | The `LOCAL-LLM-1` workload: validation, model resolution, result envelope. |
| `java/.../WorkerActivity.java` | **Extended**, not replaced: now dispatches `DTCA-1` *or* `LOCAL-LLM-1`. |
| `AndroidManifest.xml` | **Unchanged. Still ZERO permissions.** |

### macOS side (`PixelDesktop/Inference/`)

| File | Role |
|---|---|
| `InferenceRuntime.swift` | The runtime abstraction: `InferenceRuntime` protocol, `InferenceRequest`, `InferenceResult`, `LlamaCppInferenceRuntime`. One protocol, one concrete type — not a plugin system, not a registry. |
| `ModelProvisioning.swift` | Fixed-path model contract, local artifact validation, size+hash transfer verification. |
| `InferenceEvidence.swift` | The evidence chain and greedy-stability evaluation. |

**The Mac does not link llama.cpp at all.** That is deliberate: it keeps the Mac structurally
incapable of accidentally producing the result it is meant to verify.

---

## 2. Measured results

Labels: **[M]** measured on the device · **[D]** documented · **[P]** provisional/inferred

### Model artifact

| Property | Value | Source |
|---|---|---|
| Model | Qwen2.5-1.5B-Instruct | **[D]** |
| Quantization | Q4_K_M | **[D]** |
| Parameters | ~1.5B | **[D]** |
| File size | **1,117,320,736 bytes (1.04 GiB)** | **[M]** |
| SHA-256 | `6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e` | **[M]** |
| License | **Apache-2.0** | **[D]** |
| Source | `Qwen/Qwen2.5-1.5B-Instruct-GGUF` (official Qwen org) | **[M]** |
| GGUF version | 3 | **[M]** |
| Tokenizer | ChatML, bundled in the GGUF | **[M]** |

**License reasoning:** Apache-2.0 was chosen over Llama 3.2 (community licence with use
restrictions) because the project has a stated eventual commercial/client-work concern. This was a
deliberate criterion, not an accident.

### Build and packaging

| Metric | Value | Source |
|---|---|---|
| llama.cpp commit | `a868c3e` (ggml 0.25.3) | **[M]** |
| NDK | 27.2.12479018 | **[M]** |
| ABI | **arm64-v8a only** — verified `elf64-littleaarch64` | **[M]** |
| Native library | `lib/arm64-v8a/libpdllama.so`, **6,087,752 bytes** | **[M]** |
| **APK size** | **5.9 MB** (was 23 KB at D8) | **[M]** |
| Permissions | **ZERO** — verified by `aapt2` *and* on-device `dumpsys` | **[M]** |
| Backend | CPU only; `GGML_VULKAN=OFF`, `n_gpu_layers=0` forced | **[M]** |
| Model in APK? | **No.** The model is data in app external storage. | **[M]** |

### Transfer

| Metric | Value | Source |
|---|---|---|
| Method | ADB `push` | **[M]** |
| Duration | **30.79 s** | **[M]** |
| Effective rate | **~36.3 MB/s** | **[M]** |
| Device size after | 1,117,320,736 bytes — exact | **[M]** |
| Device SHA-256 | matches the Mac exactly | **[M]** |

> Note: 36.3 MB/s is *faster* than the 27.7 MB/s reconnaissance benchmark, because that benchmark
> used incompressible random data while a GGUF model compresses. Both numbers are honest; they
> measure different things.

### Inference — repeatability (3 runs, greedy, identical prompt)

| Run | Tokens | Model load | Prompt eval | Generation | Total | Text |
|---|---|---|---|---|---|---|
| 1 | 7 | 385 ms | 6893 ms | 4843 ms | 12134 ms | "The capital of France is Paris." |
| 2 | 7 | 416 ms | 6940 ms | 5707 ms | 13078 ms | "The capital of France is Paris." |
| 3 | 7 | 384 ms | 7273 ms | 6680 ms | 14347 ms | "The capital of France is Paris." |

| Metric | Value | Source |
|---|---|---|
| **Model load** | **382–437 ms** | **[M]** |
| **Prompt eval (prefill)** | **5.25–7.27 s** for 27–32 tokens → **~4–6 tok/s** | **[M]** |
| **Decode rate** | **0.97–1.46 tok/s** | **[M]** |
| Total per run | 12.1–18.9 s | **[M]** |
| **Greedy stability** | **3/3 runs, identical token IDs** `[785, 6722, 315, 9625, 374, 12095, 13]` | **[M]** |

**ADR-012 R4 is resolved: greedy decoding IS reproducible here** — but measured, not assumed. The
comparison was made on **token IDs, not text**, because two different token sequences can decode to
the same string.

### Memory (worker-attributable, native)

| Metric | Value | Source |
|---|---|---|
| **Peak process memory (`VmHWM`)** | **1,309,900 kB = 1279 MB** | **[M]** |
| RSS at completion | 1,302,764 kB = 1272 MB | **[M]** |
| Java heap cap | 256 MB | **[M]** |
| System `MemAvailable` before | ~2.6 GB | **[M]** |

> **This is the reconnaissance finding confirmed on hardware.** The process peaked at **1279 MB of
> native memory** — five times the 256 MB Java heap cap. The Java heap does **not** bound the model,
> exactly as predicted. Using Java heap as a proxy would have understated the requirement by ~5×.

### CPU (worker-attributable)

| Run | CPU ticks before | after | delta |
|---|---|---|---|
| 1 | 982 | 5093 | **4111** |
| 2 | 1048 | 5383 | **4335** |
| 3 | 1161 | 5725 | **4564** |

Sampled from `/proc/<pid>/stat` while the process was alive. Per-process and attributable to the
worker PID alone — the same method D8 used.

### Thermal (system-wide, NOT worker-attributable)

| Metric | Before | After |
|---|---|---|
| Thermal Status | 0 | **0** |
| Battery temperature | 350 (35.0 °C) | 354 (35.4 °C) |

**No thermal throttling was observed.** Reported as *device thermal state during the run*, never as
the worker's consumption — `dumpsys thermalservice` is system-wide and influenced by every process,
by charging, and by ambient temperature.

### Resource-budget comparison against ADR-012

| ADR-012 estimate | Actual | Verdict |
|---|---|---|
| ~0.8 GB model file | 1.04 GiB | slightly larger (1.5B vs 1B class) |
| ~1.2–1.5 GB runtime memory | **1279 MB** | **within the estimate** |
| Decode rate | **deliberately not estimated** | measured at ~1 tok/s |
| Model transfer ~30 s | 30.79 s | accurate |
| APK single-digit/low-tens MB | 5.9 MB | accurate |

**The one prediction ADR-012 refused to make — decode rate — turned out to be the limiting
factor.** That refusal was correct.

---

## 3. The R1 experiment — resolved

ADR-012 R1 was the highest-risk assumption:

> D8 proved a ~250 ms Activity launches while locked/dozing. A model load plus generation is two to
> three orders of magnitude longer. **Not proven.**

**R1 was measured FIRST, before any runtime work, using a self-contained probe app.**

### Probe results (300 s CPU-bound Activity, zero permissions)

| State | Result | Evidence |
|---|---|---|
| Unlocked / active | **PASS** | completed 300 s to `DONE`, PID stable |
| Locked / dozing | **PASS** | 107 s+ observed, CPU ticks 2983 → 10539 linear |
| Forced deep doze (`mState=IDLE`) | **PASS** | 107 s+ observed, CPU ticks 3056 → 10611 linear |

### Confirmed on the REAL inference workload

Inference ran to completion **while the device was Dozing**:
- 17 tokens generated, `"A computer is a device that processes and manipulates data using electronic circuits and software."`
- model load 383 ms, generation 11651 ms, total 18851 ms
- **R1 is RESOLVED: no Service is required.**

### Two probe defects, found and corrected (not platform findings)

1. **`Theme.NoDisplay` crash** — `IllegalStateException: Activity did not call finish() prior to
   onResume() completing`. My probe's fault, not Android's. Fixed by mirroring the D8 worker's
   actual manifest.
2. **PID reuse contaminated a measurement** — a second launch was issued while the previous probe
   process was still alive, so `pidof` returned the *old* PID and its CPU time appeared frozen. The
   "deep doze blocked the launch" conclusion would have been **wrong**. Re-run with `am force-stop`
   between tests, which showed deep doze passing cleanly.

> Defect 2 is recorded because it is exactly the class of error this project keeps finding: a
> plausible-looking measurement that was actually an artifact of the harness.

---

## 4. The evidence chain

D8's verification was independent re-computation. **ADR-012 §P7 established that this does not
transfer to LLM inference** — the Mac has no model and no runtime, and generation may not be
bit-reproducible. It was replaced with an evidence chain.

| # | Link | Observed | Satisfied |
|---|---|---|---|
| 1 | model_present_on_device | present, 1,117,320,736 bytes | ✅ |
| 2 | model_hash_matches | `6a1a2eb6d15622bf...` | ✅ |
| 3 | worker_package_identity | `com.pixeldesktop.worker` v2 | ✅ |
| 4 | worker_pid_observed | e.g. 20002, alive | ✅ |
| 5 | process_cmdline_matches_package | `com.pixeldesktop.worker` | ✅ |
| **6** | **cpu_time_attributable** | **4111 / 4335 / 4564 ticks** | ✅ **LOAD-BEARING** |
| 7 | result_was_fresh | result deleted before each run | ✅ |
| 8 | job_id_echoed | matches requested | ✅ |
| 9 | tokens_generated | 7–48 | ✅ |
| 10 | model_load_cost_observed | 382–437 ms | ✅ |
| **11** | **ablation** | present→OK, absent→FAILED, restored→OK | ✅ **LOAD-BEARING** |

**Every link carries its own stated limitation** in `InferenceEvidence.swift`, and a unit test
enforces that a link with no limitation cannot be added. That is the honesty requirement made
mechanical.

### Ablation — the causality link

```
[1] model present   -> status=OK      "The capital of France is Paris."  7 tokens
[2] model renamed   -> status=FAILED  error_type=MODEL_MISSING
[3] model restored  -> status=OK      "The capital of France is Paris."  7 tokens
```

**Causality established.** If the output existed without the model artifact, the model would not be
the cause. Restored tokens matched the original exactly.

### What the chain proves and does not prove

**Proves:** inference occurred **on the device**, and the model artifact is **causally required**.

**Does not prove:** that the output is **correct**. That is a different claim. Phase 6's claim is
architectural.

---

## 5. Error handling

Every failure path is bounded and machine-readable. Native errors are **never** returned raw.

| Failure | error_type | Verified |
|---|---|---|
| Model missing | `MODEL_MISSING` | ✅ ablation step 2 |
| Native library missing | `NATIVE_LIBRARY_MISSING` | implemented |
| Model load failure | `MODEL_LOAD_FAILED` | implemented |
| Inference failure | `INFERENCE_FAILED` | implemented |
| Malformed / unsupported workload | `INVALID_INPUT` | ✅ bootstrap probe |
| Non-greedy temperature | `INVALID_INPUT` | ✅ unit-tested |
| Prompt too long | `INVALID_INPUT` | ✅ unit-tested |
| max_tokens out of range | `INVALID_INPUT` | ✅ unit-tested |
| Context overflow | `INFERENCE_FAILED` | implemented in native layer |
| Unauthorized launcher | `UNAUTHORIZED_LAUNCHER` | from D8, unchanged |

A non-greedy request is **refused rather than silently coerced**, so a non-greedy run can never be
mistaken for a greedy one in the evidence.

---

## 6. Tests

| Suite | Count | Result |
|---|---|---|
| Phase 5 and earlier | 154 | pass |
| **Phase 6 (`Phase6InferenceTests.swift`)** | **40** | **pass** |
| **Total** | **194** | **0 failures** (4 skipped: real-device integration, no serial set) |

Phase 6 tests cover request validation (10), result derivation and JSON round-trip (7), model
contract (5), provisioning verification (7), evidence chain (5), greedy stability (4).

**What these tests do NOT prove:** anything about llama.cpp on Android. ADR-012 is explicit that a
macOS unit test establishes nothing about Android correctness. Every claim about the device above
comes from device evidence.

---

## 7. Regression

| Check | Result |
|---|---|
| Phase 5 DTCA-1 still works | ✅ `status=COMPLETED` |
| Independently re-computed on the Mac | ✅ exact match (total_words 11, unique_words 8, top_words identical) |
| Both workloads in one APK | ✅ `DTCA-1` and `LOCAL-LLM-1` |
| Zero permissions retained | ✅ |
| Phase 1–5 test suite | ✅ 154 unchanged, all pass |

**D8 was not broken by Phase 6.** The deterministic workload keeps its exact-recomputation
verification; the LLM workload has its evidence chain. Both coexist deliberately.

---

## 8. Failures and defects encountered

| # | Defect | Class | Resolution |
|---|---|---|---|
| 1 | R1 probe crashed: `Theme.NoDisplay` requires `finish()` before `onResume()` | **probe defect** | mirrored the D8 manifest |
| 2 | PID reuse produced a false "deep doze blocks launch" reading | **measurement defect** | `am force-stop` between tests; deep doze then passed |
| 3 | `use_mmap` / `use_mlock` no longer exist in `llama_model_params` | **upstream API drift** | switched to `load_mode = LLAMA_LOAD_MODE_MMAP` |
| 4 | System Gradle 9.7.1 incompatible with AGP 8.13 | **toolchain** | used the project's Gradle 8.13 wrapper |
| 5 | `cmake` not on PATH after SDK install | **toolchain** | absolute path to `sdk/cmake/3.22.1/bin` |
| 6 | External memory sampler missed the ~20 s process entirely | **measurement defect** | worker now self-reports `VmHWM`/`VmRSS` from `/proc/self/status` |
| 7 | `XCTAssertEqual(r.tokensPerSecond, 5.0)` — `Double?` vs `Double` | **test defect** | `try XCTUnwrap` |
| 8 | Test asserted `insufficientRuns(2)` for a one-element array | **test defect** | the test was wrong, not the code |
| 9 | `private let hash` collided with `NSObject.hash` | **test defect** | renamed to `expectedHash` |

**No Android platform assumption was falsified in Phase 6.** After six consecutive phases in which
compiled, test-passing code was wrong on the device, this is worth stating plainly — and it is
plausibly because R1 and the runtime probe were tested *before* the design was committed to, rather
than after.

---

## 9. What was deliberately NOT done

Per the instruction to stop at the first inference proof:

- **No GPU / Vulkan** — available on this device, deliberately unused (§11). Not a claim that CPU
  is the production path.
- **No larger model** — no 3B/4B attempt.
- **No routing** (Phase 7).
- **No Hermes integration** (Phase 9).
- **No multi-device orchestration.**
- **No production optimization.**
- **No Service, daemon, socket, HTTP, or RPC.** Nothing in the evidence required one.

---

## 10. Known limitations

1. **~1 token/second decode.** A 32-token answer takes ~30 s. This is real and slow. The Pixel is
   not a fast inference device, and this must not be described as usable interactive performance.
2. **Prefill is also slow** (~4–6 tok/s), so a long prompt is expensive before generation begins.
3. **The CPU-tick figure covers the whole process lifetime** — model load, prefill and decode —
   not decode alone.
4. **Thermal is system-wide** and not attributable to the worker. No throttling was observed, but
   this was a short run; a sustained workload is untested.
5. **The Activity is exported** (contained by no intent-filter, no extras, and a launcher-UID
   check), a residual exposure inherited from D8.
6. **The channel is unauthenticated** (ADR-010).
7. **Debug-signed APK.** Not a trust anchor.
8. **`versionCode` is a weak identity check.**
9. **One model, one quantization, one prompt length.** No generalization is claimed.
10. **Greedy stability was verified on 3 runs with one prompt.** Other prompts may behave
    differently.
11. **Output correctness is not established** and is not claimed.
12. **A device with a lock credential is untested.**

---

## 11. Reuse-before-rebuild map — as delivered

| Existing component | Phase 6 outcome |
|---|---|
| `TransportProtocol` / `ADBTransport` | **reuse unchanged** |
| `WorkerInstaller` | **reuse unchanged** |
| `WorkerLifecycle` | **reuse unchanged** |
| `WorkerTransferContract` | **extended** (model path, raised ceiling) |
| `WorkerOperationsProtocol` | **reuse unchanged** (fixed-path job/result sufficed) |
| `WorkerComputeProof` | **reuse unchanged** (D8 evidence still valid) |
| `DTCA1Job` / `WorkerResultEnvelope` | **reuse unchanged**; `LOCAL-LLM-1` has its own envelope |
| `DTCA1Worker` / `ResultVerifier` | **reuse unchanged**; regression-verified |
| `AndroidDevice` / `PixelDesktopError` / `AppLogger` | **reuse unchanged** |
| Android `DTCA1Worker/` project | **extended** — JNI + native runtime added; Activity/manifest/zero-permission posture retained |
| **New:** `Inference/` (3 Swift files) | **new** — the runtime adapter boundary |
| **New:** `cpp/` (llama_jni + CMakeLists) | **new** — unavoidable native integration |
| **New:** `LlamaBridge.java`, `LlmWorkload.java` | **new** — the workload |

**No duplicate abstractions were created.** `WorkerOperationsProtocol` was *not* changed: the
existing fixed-path job/result contract carried a 176-byte prompt with no modification.

---

## 12. Completion criterion — verified

```
Physical Pixel 7a                              ✅
      ↓
PixelDesktop worker                            ✅
      ↓
packaged native inference runtime              ✅  libpdllama.so in the APK
      ↓
GGUF model physically stored on Pixel          ✅  1,117,320,736 bytes, hash matched
      ↓
real model loading                             ✅  382-437 ms
      ↓
real language-model inference                  ✅  "The capital of France is Paris."
      ↓
fresh result                                   ✅  result deleted before each run
      ↓
process-level evidence                         ✅  PID, cmdline, 4111-4564 CPU ticks
      ↓
ablation confirms model causality              ✅  present/absent/restored
      ↓
repeatability >= 3 runs                        ✅  3/3, identical token IDs
```

**All criteria met.** R1 did not fail, so no architectural review is triggered.

---

## 13. Where the next phase should start

Not started, and not to be started without review:

- **Decode performance** is the obvious open problem (~1 tok/s). Vulkan/GPU is the documented
  candidate, with LiteRT-LM's published memory and TTFT advantage as the hypothesis to test on
  Mali-G710.
- **Larger models** are untested. The 1.5B model peaked at 1279 MB against ~2.6 GB available, so
  there may be headroom — but that is a hypothesis, not a measurement.
- **Sustained-load thermal behaviour** is unmeasured.
- Phase 7 (routing) and Phase 9 (Hermes) remain as ADR-007 defines them.

---

```text
PHASE 6 FIRST INFERENCE PROOF COMPLETE
READY FOR REVIEW
```

# Phase 6 Reconnaissance — Local AI Worker

**Status:** RECONNAISSANCE + PROPOSAL. **Implementation BLOCKED pending review.**
**Date:** 2026-10-02
**Phase:** 6 (Local AI Worker) — authoritative per ADR-007
**Depends on:** Phase 5 / D8 (`5a0b004`) — the compute worker is proven
**No model downloaded. No runtime installed. No production source modified.**

---

## A. Phase 6 Requirements (authoritative)

Master prompt §16, verbatim:

> Only after the compute worker is proven should local AI be introduced. Determine: feasible
> model size · runtime · memory usage · token throughput · thermal behavior · model loading ·
> model lifecycle · task boundaries · failure behavior.
>
> The Pixel is not expected to become the primary reasoning system.
> The Pixel should handle bounded workloads.

Master prompt §1 places AI on the Pixel as a **bounded worker**, with the Mac owning
"planning / reasoning / context". §5.2 forbids premature "distributed RPC … networking layers".
§22 forbids code injection and security bypasses.

**Explicitly Phase 7, not 6:** resource-aware routing. **Explicitly not Phase 6:** Hermes
integration (Phase 9).

**Therefore Phase 6 requires:** a real language model performing inference on the physical Pixel,
with measured model size, runtime, memory, throughput, thermal behaviour, model loading/lifecycle,
task boundaries and failure behaviour — as a bounded worker.

---

## B. Current Architecture — what D8 already proves

| Component | What it provides | Reusable for Phase 6? |
|---|---|---|
| `TransportProtocol` / `ADBTransport` | `execute`, `shell`, `push`, `pull`, `install`, `getprop`, `getSystemProperties` | **Reuse unchanged** |
| `WorkerTransferContract` | Fixed paths, regular-file validation, size verification | **Extend** — the 1 MB payload cap must rise for a model |
| `WorkerOperationsProtocol` / `ADBWorkerOperations` | Job submit, result retrieve | **Extend** — job/result shape changes |
| `WorkerInstaller` | Package identity, install/replace, versionCode | **Reuse unchanged** |
| `WorkerLifecycle` | `state`, `stopIfRunning`, `launch`, `awaitProcessStart` | **Reuse unchanged** |
| `WorkerComputeProof` | Orchestration + evidence (PID, CPU ticks, `/proc`, verification) | **Extend** — add model/inference evidence |
| `DTCA1Job` / `WorkerResultEnvelope` | Job encode, result decode, `job_id` echo | **Extend or parallel** — see §H |
| `DTCA1Worker` / `ResultVerifier` | Deterministic local reference + independent verification | **Reuse unchanged** — but see the verification problem in §G |
| `AndroidDevice` / `DeviceState` | Device identity, capabilities | **Reuse unchanged** |
| `PixelDesktopError` | Typed failures | **Extend** — model-specific failures |

**Proven by D8 and directly reusable:** install → launch → job in → compute → result out →
independent verification, with attributable CPU time for the worker's PID, on a device that is
not rooted and not debuggable.

---

## C. Physical Pixel Evidence (measured, 2026-10-02)

All read-only. Every value below was read from the device.

### Hardware

| Fact | Value | Source |
|---|---|---|
| SoC | **Google Tensor G2** (`ro.soc.model=GS201`) | `getprop` |
| CPU | **8 cores, big.LITTLE**: 4×1.803 GHz + 2×2.348 GHz + 2×2.850 GHz | `/sys/.../cpuinfo_max_freq` |
| ABI | **`arm64-v8a` only** — no 32-bit | `ro.product.cpu.abilist` |
| RAM | **7,626,016 kB total (7.27 GiB)** | `/proc/meminfo` |
| **MemAvailable** | **2,153,860 kB (~2.05 GiB)** | `/proc/meminfo` |
| MemFree | 626,140 kB (~0.6 GiB) | `/proc/meminfo` |
| Swap (ZRAM) | 3,145,724 kB total, **621,520 kB free**, 599,716 kB physical used | `dumpsys meminfo` |
| Storage | **56 GB available** of 110 GB | `df -h` |
| GPU | **Mali-G710**, `ro.hardware.vulkan=mali` | `getprop` |
| Page size | **4096** (not 16 KB) | `getconf PAGESIZE` |

### Acceleration available to a normal app

| Capability | Status | Evidence |
|---|---|---|
| **Vulkan compute** | **Available** | `feature:android.hardware.vulkan.compute`, `vulkan.level=1`, ICD `/vendor/lib64/hw/vulkan.mali.so` |
| OpenGL ES | Available | `reqGlEsVersion=0x30002`, `libGLES_mali.so` |
| **NNAPI** | **NOT available** | `pm list features \| grep -i neural` → **empty**; no `android.hardware.neuralnetworks` feature; only `/system/lib64/libneuralnetworks_packageinfo.so` (a stub) |
| **EdgeTPU / GXP** | **Present but gated** | `edgetpu` and `gxp` device nodes exist; `init.svc.edgetpu_app_service=running`; **but `persist.device_config.aconfig_flags.edgetpu_native.allowlist_app1..12` are ALL EMPTY** — third-party apps are not allowlisted |

> **NNAPI absence is measured, not assumed.** `pm list features` is the app-visible capability
> list; it contains no `neuralnetworks` entry, and no `neuralnetworks` HAL is present.

### Android constraints

| Constraint | Value | Consequence |
|---|---|---|
| SELinux | **Enforcing** | no bypass |
| Root | **absent** (`su` not found) | no privilege escalation |
| `ro.debuggable` | `0` | not debuggable |
| `/storage/emulated` mount | `rw,nosuid,nodev,**noexec**` | **the worker's exchange dir cannot execute anything** |
| `/data` mount | `rw,nosuid,nodev` (no `noexec`) | exec possible for the right identity |
| Exec from `/sdcard` | **`can't execute: Permission denied`** | confirms noexec |
| Exec from `/data/local/tmp` | **OK** (as `shell`) | adb-only path |
| APK native libs | `extractNativeLibs=false`; `/data/app` is `apk_data_file` | **the app's own native libraries are the executable path** |
| Java heap cap | `heapgrowthlimit=256m`, `heapsize=512m` | **applies to Java heap only — see below** |
| `pm list features` | no `neuralnetworks` | NNAPI unusable |

> **Important distinction:** ggml/llama.cpp allocates model weights and KV cache as **native**
> memory (mmap/malloc), **not** Java heap. The 256 MB Java cap does **not** bound the model.
> Native memory is bounded by system RAM and `lmkd`.

### ADB transfer throughput (measured honestly)

| Attempt | Result | Note |
|---|---|---|
| 200 MB from `/dev/zero` | "4030 MB/s" | **Rejected as not credible** — sparse/compressible artifact |
| **300 MB of `/dev/urandom`** | **27.7 MB/s** (10.849 s) | Accepted: incompressible, real |

**Consequence:** a 1 GB model transfers in **~37 s**; a 2 GB model in **~74 s**. One-time cost,
but not negligible — and it means the model transfer must be a resumable/verified operation, not
a fire-and-forget push.

---

## D. Runtime Investigation — documented trade-offs

Facts below are from primary documentation, fetched during reconnaissance. **No runtime was
installed or tested on the device.**

### D.1 llama.cpp

- **Android support:** official. `docs/android.md` documents an Android Studio GUI binding
  (`examples/llama.android`) and a CLI build; ships `GgufMetadataReader`, `InferenceEngine`,
  `AiChat` in the Android binding.
- **ABI:** arm64-v8a; auto-detects host features (SME2/AMX) and loads compatible kernels.
- **Model format:** GGUF — one file, self-describing (tokenizer, config, weights in one artifact).
- **Quantization:** broadest in the field (Q4_0 … Q8_0, K-quants, I-quants).
- **Backends:** CPU; **Vulkan** and OpenCL exist. Community reports confirm a Vulkan build is
  possible but not frictionless; **CPU-only is the well-trodden path**.
- **Native/JNI:** yes — needs an NDK/CMake build and JNI glue.
- **APK size:** the native `libllama`/`libggml` `.so` is the bulk (single-digit to low tens of MB
  depending on backends); the **model is data, not packaged**.
- **License:** MIT.
- **Health:** very actively maintained.
- **Network:** none required at inference time.
- **Root/permissions:** none required.

### D.2 LiteRT-LM (Google's successor to the MediaPipe LLM Inference API)

- **Documentation status:** the **MediaPipe LLM Inference API is in maintenance-only mode**;
  Google directs new work to **LiteRT-LM**, described as "the production-ready orchestration layer
  to run LLMs with LiteRT".
- **Published benchmark (primary source, Gemma-4-E2B ≈ 2B):**

  | Device | Backend | Prefill | Decode | TTFT | **Peak CPU memory** |
  |---|---|---|---|---|---|
  | Android (S26 Ultra) | CPU | 557 tk/s | 47 tk/s | 1.8 s | **1733 MB** |
  | Android (S26 Ultra) | GPU | 3808 tk/s | 52 tk/s | 0.3 s | **676 MB** |

  This is the single most useful published number found: a **~2B model needs ~1.7 GB on CPU** on a
  device **faster than the Pixel 7a**.
- **Model format:** LiteRT (`.tflite` / task bundles); models on the `litert-community` HF org.
- **GPU backend:** exists and is dramatically better on memory **and** TTFT (0.3 s vs 1.8 s).
- **License:** Apache-2.0.
- **Health:** actively developed (v0.16.0 at time of writing).

### D.3 ExecuTorch

- **Android support:** official demo app; **explicitly supports Llama 3.2 1B and 3B quantized** on
  the **XNNPACK** backend, with 4-bit groupwise quantization "to fit the model on a phone".
- **Model format:** `.pte` (requires an ahead-of-time export/compile step).
- **Quantization:** SpinQuant and QAT+LoRA documented.
- **Native/JNI:** yes.
- **License:** BSD-3.
- **Note from documentation:** ExecuTorch "excels with small, quantized transformer models and
  short prompts" — consistent with a bounded workload.

### D.4 ONNX Runtime (Android)

- **Android support:** official; arm64-v8a build documented.
- **NNAPI execution provider:** documented — **but NNAPI is absent on this device** (§C), so this
  path is unavailable here. CPU EP remains viable.
- **Model format:** ONNX (requires export/conversion).
- **License:** MIT.

### D.5 MediaPipe LLM Inference API

- **Status:** **maintenance-only**; Google recommends migrating to LiteRT-LM. Recorded because it
  would otherwise be a natural first choice on a Google device.

### D.6 NNAPI path

- **Eliminated by measurement**, not opinion: no `neuralnetworks` feature, no HAL, on this device.

### D.7 Eliminated / not applicable

| Candidate | Reason |
|---|---|
| NNAPI-based paths | **Measured absent** on this device |
| EdgeTPU / GXP accelerator | Present, but the app allowlist is **empty** — not reachable by a third-party app |
| Qualcomm GENIE / QNN | Snapdragon-only; this is a Tensor G2 |
| Termux-hosted CLI | Would require installing an app and running a CLI as a *user* — abandons the controlled-worker model and the ADB-only boundary |

**No candidate is ranked "best".** The elimination is factual: NNAPI and EdgeTPU are measured
unavailable, and Qualcomm paths are inapplicable.

---

## E. Model Investigation

### The binding constraint is memory, not disk

56 GB of storage is available. The limit is **~2.05 GiB MemAvailable**, on a device already
running a full Android system (SystemUI 456 MB, GMS 353 MB, camera 292 MB, surfaceflinger 283 MB,
launcher 282 MB, and more).

### Sizes (documented)

| Class | Example | Q4 file size | Runtime RAM (file + KV + overhead) |
|---|---|---|---|
| ~0.5B | Qwen2.5-0.5B | ~0.3–0.4 GB | ~0.6–0.9 GB |
| **~1B** | **Llama-3.2-1B-Instruct Q4_K_M** | **~0.81 GB** | **~1.2–1.5 GB** |
| ~1.5B | Qwen2.5-1.5B-Instruct Q4_K_M | ~1.04 GB | "under 2 GB" |
| ~2B | Gemma-2-2B / Gemma-4-E2B Q4 | ~1.3–1.6 GB | **~1.7 GB measured on CPU** (LiteRT-LM) |
| 3B | Llama-3.2-3B Q4 | ~2.0 GB | ~2.5–3 GB |
| 7B | — | ~4.4 GB | ~5+ GB |

### Assessment against this device

- **3B–4B is NOT plausible as the first proof on this device.** The historical 3B–4B preference is
  a **hypothesis**, and the evidence contradicts it here: a 3B Q4 model needs ~2.5–3 GB against
  ~2.05 GiB available, before the system's own needs. It would risk `lmkd` killing the worker.
- **2B is at the ceiling** — ~1.7 GB measured on a faster device.
- **1B-class Q4 (~0.8 GB file, ~1.2–1.5 GB runtime) is the plausible first-proof target**, with
  headroom for the OS and for KV cache.
- **A ~0.5B model is the fallback** if even 1B proves too tight in practice.

**The historical 3B–4B preference is recorded here as falsified by measurement for this device**,
pending an actual run. It may remain valid on future hardware.

### Model choice is deliberately NOT made

The runtime choice constrains the format (GGUF vs `.pte` vs `.tflite` vs ONNX). **Choosing a model
before choosing a runtime would be backwards.** The proposal is a *class* (1B, Q4, instruct-tuned),
not a specific model.

**License note:** Llama 3.2 and Gemma carry their own community licences with use restrictions;
Qwen2.5 is Apache-2.0. For "commercial/client work" (a stated project concern) **Qwen2.5 is the
cleanest licence**, and this is a factor the model decision must weigh, not a detail.

---

## F. Smallest Credible Inference Proof

### The claim to establish

> **A real language model performed inference on the physical Pixel 7a.**

Not "a worker ran". Not "a model file exists". **Inference.**

### Proposed experiment

**One bounded, deterministic-by-construction generation task**, run by the worker on the Pixel:

```
Mac                                    Pixel 7a
 │  push prompt.json (fixed path)          │
 ├───────────────────────────────────────► │
 │  am start  (worker Activity)             │
 ├───────────────────────────────────────► │
 │                                          │  load model from app external files
 │                                          │  tokenize prompt
 │                                          │  GENERATE N tokens, greedy (temp=0)
 │                                          │  write result.json (text + token ids + timings)
 │  pull result.json                        │
 │◄───────────────────────────────────────  │
 │  verify
```

**Task shape:** a fixed prompt, greedy decoding (`temperature=0`, fixed seed), a small token
budget (e.g. 32–64 tokens). Determinism is **not assumed** — it is measured across repeated runs,
because floating-point and backend differences can break it. If greedy output is stable across
runs, the Mac can check *stability*; if not, the Mac checks *structural* properties instead
(§G).

**Why this is the smallest credible proof:** it requires a real model, real tokenization, real
sampling, and real generation. None of those can be faked by echoing input.

### Explicitly NOT in the first proof

No chat UI, no multi-turn, no streaming, no tool use, no model switching, no quantization
comparison, no GPU benchmark, no routing.

---

## G. Evidence Chain — Pixel inference vs Mac inference

### The core problem

D8's verification was **independent re-computation**: DTCA-1 is deterministic, so the Mac could
recompute and compare exactly. **That method does not transfer to LLM inference**, because the Mac
does not have the same model, runtime and backend, and generation may not be bit-reproducible even
on identical hardware.

**This is the single most important open problem in Phase 6.** It is stated plainly rather than
glossed: *there is no exact-recomputation verification for LLM inference.*

### The evidence chain, and what each link does and does not prove

| # | Evidence | Proves | Does **not** prove |
|---|---|---|---|
| 1 | **Model artifact on the device** with a recorded SHA-256, size, and a device-side re-hash | the exact model bytes are on the Pixel | that they were used |
| 2 | **Worker package identity** (`versionCode`, and ideally signing cert) | our worker is installed | that it ran |
| 3 | **Worker PID** + `/proc/<pid>/cmdline` | a process of that package existed | that it computed |
| 4 | **Process lifetime** spanning the generation window | the process was alive during generation | what it did |
| 5 | **CPU time consumed by that PID** (`/proc/<pid>/stat` utime+stime, sampled while alive) | **that PID did real CPU work** | that the work was inference |
| 6 | **Peak `VmRSS`/`VmHWM` for that PID** | it mapped a large amount of memory — consistent with a model | which model, or that it was used |
| 7 | **Device-side runtime log** naming model load, tokenizer init, and token generation | the runtime reported loading and generating | that the output is correct |
| 8 | **Output shape**: N tokens, plausible token ids, timing that scales with N | generation happened, with the expected cost structure | correctness |
| 9 | **Timing monotonicity**: doubling the token budget roughly doubles generation time, while model-load time stays constant | work is proportional to tokens generated, not to a constant lookup | — |
| 10 | **No Mac-side inference**: the Mac never loads a model during the run; its process list and CPU are clean | the Mac did not compute it | — |
| 11 | **Repeated-run stability** (greedy, fixed seed): identical token ids across runs | determinism, *if* observed | correctness |
| 12 | **Ablation**: remove or corrupt the model file → the worker fails with a model-load error | the model file is causally required | — |

### The strongest links

**Link 5 (attributable CPU time) and link 12 (ablation) are the load-bearing ones.**

- Link 5 is per-process and cannot be attributed to anything else — the same method D8 used.
- Link 12 is the only evidence that establishes **causation**: if the model file is required for
  the output, the output came from the model. D8's lesson was that a matching string proves little;
  ablation is the LLM-era substitute for exact re-computation.

### The honest statement of limits

- **None of the above proves the output is *correct*.** It proves inference *occurred on the
  device*. Correctness of a generative model is a different question, and for Phase 6 the claim is
  architectural, not semantic.
- **Link 11 may fail.** Greedy decoding is often but not always stable across runs and backends. If
  it is unstable, the chain falls back to links 1–10 + 12, and stability is reported as *not
  observed* rather than assumed.
- **A sufficiently determined fake could pass several links.** Links 5 and 12 raise the cost
  substantially, and the worker is our own signed code — but the channel remains unauthenticated
  (ADR-010), and this must not be described as tamper-proof.

---

## H. Proposed Architecture

```
Mac / Hermes  (planning, reasoning, context)      <- unchanged; Phase 9 for integration
     │
     │  PixelDesktop (macOS)
     ▼
WorkerInstaller  ·  WorkerLifecycle  ·  WorkerOperations     <- REUSE from D8
     │
     │  ADB: push prompt.json → am start → pull result.json
     ▼
Pixel 7a
     │
     ├── app external files:  model/*.gguf  (pushed once, hash-verified)
     │                        prompt.json   (fixed path)
     │                        result.json   (fixed path)
     │
     └── Worker Activity  ──►  native inference runtime (JNI)
                                 load model  →  tokenize  →  generate  →  write result
```

### Decisions

| Question | Proposal | Rationale |
|---|---|---|
| **Where does the model live?** | App's external files dir, e.g. `.../files/model/` | adb can write it (`ext_data_rw`); the app owns it; **noexec is irrelevant because the model is data, not code** |
| **Who owns it?** | The app (its own external dir) | Same ownership rule as ADR-010 Rev 1 — the app must be able to read what it uses |
| **Who creates the directory?** | **The app** | D8/FAIL-004 instance 3: an adb-created directory is owned by `shell` and the app cannot write it |
| **Who loads it?** | The worker, via the native runtime | — |
| **How do jobs enter / results leave?** | Fixed-path files over ADB | Reuse; no socket, no HTTP, no RPC |
| **Model load: once or per job?** | **Per job, initially** | The Activity is one-shot. Caching would require a long-lived process — a change justified only by measurement |
| **Is the Activity still appropriate?** | **Yes, but this is the weakest assumption** | ~0.8 GB model load + generation may take 30–120 s. D8 proved launch while locked/dozing for a ~250 ms task; **a multi-minute task is a different test** |
| **Is a Service required?** | **Not yet** — decide by measurement | A Service would add `POST_NOTIFICATIONS`, a lifecycle, and background-execution limits. Introduce only if the Activity is falsified |
| **Timeouts** | Explicit, generous, configurable | Model load + generation, not a fixed 60 s |
| **Cancellation** | `am force-stop` (exists) | Reuse `WorkerLifecycle.stopIfRunning` |
| **Memory limits** | A declared ceiling; fail loudly if exceeded | `lmkd` will kill silently otherwise |
| **Cleanup** | Model persists between runs; prompt/result overwritten | — |

**No socket, HTTP, database, daemon, or RPC is introduced.** Nothing in the evidence requires one.

### The Activity-lifetime risk, stated plainly

D8's worker finished in ~250 ms. A model load plus generation is **two to three orders of
magnitude longer**. The D8 experiment proved launch-while-locked for a *fast* task. **It does not
prove a multi-minute Activity survives.** This is the highest-risk assumption in Phase 6 and must
be the first thing measured (§J, F1).

---

## I. Resource Budget

Labels: **[M]** measured · **[D]** documented · **[P]** provisional

| Resource | Budget | Basis |
|---|---|---|
| Total device RAM | 7.27 GiB | **[M]** |
| Available to a new process | ~2.05 GiB (MemAvailable) | **[M]** |
| Model class | **~1B parameters, Q4** | **[P]** — derived from [M] memory + [D] sizes |
| Model file size | ~0.8 GB | **[D]** Llama-3.2-1B Q4_K_M = 0.81 GB |
| Runtime memory (model + KV + overhead) | ~1.2–1.5 GB | **[D]** |
| Headroom for the OS | ~0.5–0.8 GB | **[P]** |
| Context length | 512–2048 tokens | **[P]** — KV cache scales with context |
| Output tokens (first proof) | 32–64 | **[P]** |
| Storage | ~1 GB model + ~100 MB app/runtime | **[M]** 56 GB free |
| APK size | single-digit to low-tens of MB (native `.so`) | **[D]** |
| Model transfer time | **~30 s for 0.8 GB** at 27.7 MB/s | **[M]** |
| Expected decode rate | **unknown — not extrapolated** | — |
| Thermal ceiling | **unknown** | **[M]** baseline only: BIG 74.0 °C, MID 66.0 °C, LITTLE 67.0 °C, status 0 |

> **Decode rate is deliberately not estimated.** Extrapolating a Snapdragon-8-class figure down to
> a Tensor G2 would be invention. It is the primary thing the first proof measures.

---

## J. Failure Hypotheses

Format: **ASSUMPTION → TEST → FALSIFIER → CONSEQUENCE**

| # | Assumption | How tested | What would falsify it | Consequence |
|---|---|---|---|---|
| **F1** | A multi-minute Activity survives locked/idle | Run a long Activity while locked; sample `pidof` throughout | process killed or throttled | **Requires a Service or foreground execution — an architecture change** |
| **F2** | The chosen runtime builds for arm64-v8a and runs on Android 16 | Build and run a trivial native call first, before any model | link/load failure, `dlopen` error | runtime choice changes |
| **F3** | Native `.so` loads under SELinux Enforcing on API 36 | Load the library from the APK's native dir | `UnsatisfiedLinkError` / SELinux denial in `dmesg` | packaging changes |
| **F4** | ~1.2–1.5 GB fits in ~2.05 GiB MemAvailable | Load the model; watch `VmRSS` and `lmkd` | `lmkd` kill, or OOM | **drop to ~0.5B, or reduce context** |
| **F5** | Greedy output is stable across runs | Run 5×, compare token ids | differing ids | verification falls back to links 1–10 + 12 |
| **F6** | Model file is readable from app external storage by the app | Load it | `EACCES` | move to internal storage (loses adb readability) |
| **F7** | Transferring ~0.8 GB via ADB is reliable | Push, re-hash on device, compare | hash mismatch / truncation | need resumable or chunked transfer |
| **F8** | Inference does not thermally throttle within the run | Sample `dumpsys thermalservice` before/after | thermal status rises, decode slows | bound the token budget |
| **F9** | APK size stays installable | Inspect the built APK | exceeds practical size | move the runtime to a separate artifact |
| **F10** | A 1B model is *useful*, not just runnable | Inspect outputs | incoherent output | acceptable for Phase 6 (architecture proof), but recorded |
| **F11** | Greedy `temperature=0` is actually honoured by the runtime | Compare runs with different seeds | output varies with seed | adjust the determinism claim |
| **F12** | The Activity's model load does not exceed a reasonable timeout | Time it | > 2–3 min | adjust timeouts, or reconsider process model |

**Every one of these is falsifiable by a device run.** None is resolved by documentation.

> **The standing lesson from D8/FAIL-004:** a test passing on macOS does not establish Android
> correctness, and three separate Android assumptions were falsified in D8 alone. Phase 6 should
> expect the same.

---

## K. Reuse-Before-Rebuild Map

| Existing component | Phase 6 classification | Notes |
|---|---|---|
| `TransportProtocol` / `ADBTransport` | **Reuse unchanged** | `push`/`pull`/`shell`/`install` all suffice |
| `WorkerInstaller` | **Reuse unchanged** | Same package identity, install, version check |
| `WorkerLifecycle` | **Reuse unchanged** | `launch`, `stopIfRunning`, `state`, `awaitProcessStart` |
| `WorkerTransferContract` | **Extend** | Raise the 1 MB payload cap for the model; add a model path constant; keep fixed paths, no caller paths, regular-files-only |
| `WorkerOperationsProtocol` | **Extend** | Add a model-provisioning operation; job/result shape changes |
| `WorkerComputeProof` | **Extend** | Add model-hash, `VmHWM`, load/generation timing, ablation evidence |
| `DTCA1Job` / `WorkerResultEnvelope` | **Extend or parallel** | An inference job has a different shape; keep `job_id` |
| `DTCA1Worker` / `ResultVerifier` | **Reuse unchanged** | Still valid for the deterministic workload; **not** applicable to LLM output (§G) |
| `AndroidDevice` / `DeviceCapabilities` | **Reuse unchanged** | — |
| `PixelDesktopError` | **Extend** | `modelNotFound`, `modelHashMismatch`, `modelLoadFailed`, `inferenceTimeout`, `outOfMemory` |
| `AppLogger` | **Reuse unchanged** | — |
| Android `DTCA1Worker/` project | **Extend** | Add JNI + native runtime; the Activity, manifest and zero-permission posture stay |
| **New:** native runtime integration (JNI/NDK/CMake) | **New** | Unavoidable — no existing component does this |
| **New:** model provisioning (push + hash verify + device-side re-hash) | **New** | Unavoidable |

**No duplicate abstractions are proposed.** Everything except the native runtime integration and
model provisioning already exists.

---

## L. Open Questions (genuinely unresolved)

1. **Which runtime?** Decided by the review, not by reconnaissance — the formats differ
   (GGUF / `.pte` / `.tflite`) and each has different build cost. **Recommendation below.**
2. **Is a 1B model's output useful enough** to justify the phase, or is it only an architecture
   proof? Not resolvable without running one.
3. **Does greedy decoding reproduce** on this runtime/backend? Must be measured.
4. **Does the Activity survive a multi-minute run?** Must be measured (F1).
5. **What is the actual decode rate** on a Tensor G2 for a 1B Q4 model? Must be measured.
6. **Does GPU (Vulkan) help enough to justify the complexity** here? The LiteRT-LM benchmark shows
   a dramatic TTFT and memory advantage on GPU (0.3 s vs 1.8 s; 676 MB vs 1733 MB) — but on
   Snapdragon hardware. Unresolved for Mali-G710.
7. **Model licence for client work** — Qwen2.5 (Apache-2.0) vs Llama/Gemma community licences. A
   decision for the model choice, flagged not resolved.

---

## M. Implementation Plan (after approval)

Each step is a gate. No step assumes the next.

1. **Falsify F1 first — before any runtime work.** Run a deliberately long Activity (a sleep
   loop) while the device is locked, sampling `pidof` throughout. **Gate: measured answer.** This
   is the cheapest possible test of the highest-risk assumption, and it may change the process
   model.
2. **Falsify F2/F3 — native library loading.** Build a trivial `.so` with a single JNI function,
   package it, load it, call it. **Gate: it loads and returns on Android 16 / arm64-v8a.**
3. **ADR-012** — runtime and model class, with the evidence above.
4. **Model provisioning** — push + device-side SHA-256 re-hash, with the raised size cap.
   **Gate: hash matches on the device.**
5. **Runtime integration** — the chosen runtime, model load only. **Gate: load succeeds; record
   load time and peak `VmRSS` (F4, F12).**
6. **Generation** — fixed prompt, greedy, 32 tokens. **Gate: output produced; record decode rate,
   tokens/s, CPU time, thermal before/after.**
7. **Evidence chain** — implement links 1–10 and 12 from §G, including the ablation test.
8. **Stability** — 5× runs; report whether greedy reproduces (F5, F11) rather than assuming.
9. **Failure semantics** — every case in §J that can be triggered.
10. **Regression** — full Phase 1–5 suite; D8 compute proof must still pass.
11. **Documentation** — phase log, ADR-012, failure records, technique memory.

**Recommended runtime for step 5, pending review:** **llama.cpp with GGUF on CPU.**
Rationale: MIT licence; the broadest quantization range (which the memory constraint demands);
**one self-describing artifact** (tokenizer + config + weights in one file — no separate
tokenizer bundle to get wrong); a documented Android binding; and CPU-only is the well-trodden
path, so the first proof is not also a Vulkan bring-up. The Vulkan/GPU path and LiteRT-LM remain
documented alternatives to revisit once a baseline exists.

---

## ADR Checkpoint

**ADR-012 is drafted in `engineering/decisions/ADR-012-local-ai-worker.md`**, with its evidence
explicitly separated into established / measured / documented / hypothesis / proposed /
unresolved. It is **not approved** and must not be treated as a requirement until reviewed.

---

## Provenance

**Established (repository):** master prompt §16 Phase 6/7; ADR-003, ADR-004, ADR-007, ADR-009,
ADR-010, ADR-011; D8 phase log; existing component surfaces.

**Measured (this device, 2026-10-02, read-only):** §C in full — SoC, CPU, ABI, RAM, MemAvailable,
swap, storage, GPU, Vulkan/NNAPI/EdgeTPU availability, SELinux, mounts, noexec, exec tests, Java
heap caps, ADB throughput (27.7 MB/s on incompressible data), thermal baseline, battery.

**External documentation:** llama.cpp `docs/android.md`; LiteRT-LM overview + Gemma-4-E2B
benchmark table; ExecuTorch Llama demo docs; ONNX Runtime NNAPI EP docs; MediaPipe LLM Inference
(deprecation notice); model-card sizes.

**Hypothesis:** 1B Q4 is the right first-proof class; the Activity survives a multi-minute run;
greedy decoding reproduces; decode rate is usable.

**Proposed:** §H architecture; §F experiment; §M sequence; llama.cpp/GGUF/CPU as the runtime.

**Unresolved:** §L.

---

```text
PHASE 6 RECONNAISSANCE COMPLETE
IMPLEMENTATION BLOCKED PENDING REVIEW
```

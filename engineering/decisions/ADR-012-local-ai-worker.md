# ADR-012: Local AI Worker on the Pixel 7a

## Status

**APPROVED and IMPLEMENTED.** Approved as the Phase 6 design checkpoint; implementation complete
and verified on the physical Pixel 7a.

**Post-implementation update (2026-10-02):**
- **R1 is RESOLVED — the one-shot Activity survives.** Measured first with a self-contained probe
  (300 s CPU-bound Activity): PASS unlocked/active, PASS locked/dozing, PASS forced deep doze. Then
  confirmed on the real inference workload, which completed while the device was Dozing. **No
  Service is required.** See `phases/phase-06-local-ai-implementation.md` §3.
- **R4 is RESOLVED — greedy IS reproducible here.** 3/3 runs produced identical token IDs
  `[785, 6722, 315, 9625, 374, 12095, 13]`, compared on token ids rather than text.
- **P6 (llama.cpp + GGUF on CPU) was implemented as proposed.** llama.cpp `a868c3e`, ggml 0.25.3,
  NDK 27.2, arm64-v8a, CPU only.
- **The model class changed from the proposed ~1B to ~1.5B** (Qwen2.5-1.5B-Instruct Q4_K_M,
  Apache-2.0). The measured 1279 MB peak fits the budget ADR-012 estimated at 1.2–1.5 GB.
- **R5 (decode rate) is now measured: ~0.97–1.46 tok/s.** ADR-012 deliberately refused to
  estimate this, and it turned out to be the limiting factor.
- **R3 (memory) is RESOLVED:** 1279 MB native peak against ~2.6 GB available — five times the
  256 MB Java heap cap, confirming the reconnaissance distinction.
- No approved decision was contradicted. **No Android platform assumption was falsified** — the
  first phase where that is true, plausibly because R1 and the runtime were probed before the
  design was committed to.

## Date

2026-10-02

## Evidence Classification

Every statement below is tagged:

- **[E] Established** — from the repository (master prompt, existing ADRs, existing code)
- **[M] Measured** — read from the physical Pixel 7a on 2026-10-02
- **[D] Documented** — from a primary external source, cited
- **[H] Hypothesis** — believed, **not** established, must be tested
- **[P] Proposed** — a decision this ADR asks to be approved
- **[U] Unresolved** — cannot yet be resolved

**A hypothesis is never presented as a requirement.** Where the reconnaissance contradicted a
long-standing belief, that is recorded explicitly.

## Context

Phase 5/D8 proved the Pixel can execute a bounded deterministic workload and return an
independently verifiable result, with attributable per-process CPU evidence **[E]**.

Phase 6 requires a **real language model performing inference on the physical Pixel** **[E]**,
determining feasible model size, runtime, memory, throughput, thermal behaviour, model
loading/lifecycle, task boundaries and failure behaviour.

## Problem

What is the smallest, simplest, experimentally defensible path from PixelDesktop to real local
language-model inference on the Pixel 7a — while preserving replaceability?

## Established and Measured Facts

### Measured on the device **[M]**

| Fact | Value |
|---|---|
| SoC | Google Tensor G2 (`GS201`) |
| CPU | 8 cores: 4×1.803 + 2×2.348 + 2×2.850 GHz |
| ABI | `arm64-v8a` only |
| RAM total / available | 7.27 GiB / **~2.05 GiB** |
| Swap (ZRAM) | 3.0 GB total, **~0.6 GB free** |
| Storage free | 56 GB |
| GPU | Mali-G710 |
| **Vulkan compute** | **available** (`android.hardware.vulkan.compute`, ICD `vulkan.mali.so`) |
| **NNAPI** | **NOT available** — no `neuralnetworks` feature, no HAL |
| **EdgeTPU / GXP** | present but **app allowlist empty** — unreachable by a third-party app |
| SELinux / root | Enforcing / no `su` |
| `/storage/emulated` | mounted **`noexec`** |
| Java heap cap | 256 MB (`heapgrowthlimit`) — **does not bound native allocations** |
| **ADB throughput** | **27.7 MB/s** on 300 MB of incompressible data |
| Thermal baseline | BIG 74.0 °C, MID 66.0 °C, LITTLE 67.0 °C, status 0 |

### Documented **[D]**

| Fact | Source |
|---|---|
| MediaPipe LLM Inference API is **maintenance-only**; Google directs new work to LiteRT-LM | Google AI Edge docs |
| LiteRT-LM, Gemma-4-E2B (~2B): Android CPU **peak 1733 MB**, TTFT 1.8 s, 47 tk/s; GPU **676 MB**, TTFT 0.3 s | LiteRT-LM overview benchmark table |
| llama.cpp ships an official Android binding and documents the build | llama.cpp `docs/android.md` |
| ExecuTorch supports quantized Llama 3.2 1B/3B on XNNPACK for Android | ExecuTorch docs |
| ONNX Runtime's NNAPI EP exists — **inapplicable here** | ONNX Runtime docs + **[M]** NNAPI absent |
| Llama-3.2-1B Q4_K_M ≈ 0.81 GB; Qwen2.5-1.5B Q4_K_M ≈ 1.04 GB | model cards |

### Reused from D8 **[E]**

`TransportProtocol`, `WorkerInstaller`, `WorkerLifecycle`, `WorkerTransferContract`,
`WorkerOperationsProtocol`, `WorkerComputeProof`, `AndroidDevice`, `PixelDesktopError` — all
extend or reuse unchanged. Only **native runtime integration** and **model provisioning** are
genuinely new.

## The Finding That Contradicts a Standing Assumption

**The historical preference for a 3B–4B model on the Pixel is not supportable on this device.**

- **[M]** ~2.05 GiB MemAvailable.
- **[D]** a ~2B model needs **~1.7 GB peak on CPU** — measured on a device *faster* than this one.
- **[D]** a 3B Q4 model is ~2.0 GB on disk and ~2.5–3 GB at runtime.

A 3B model would exceed available memory before the OS's own needs, risking an `lmkd` kill. **[P]**
The first proof should target **~1B parameters at Q4**, with a ~0.5B fallback.

This is recorded as a **falsified assumption**, not quietly adjusted. It remains possibly valid on
future hardware.

## Proposed Decisions

### P1 — The worker remains a one-shot Activity **[P]**

No Service, no daemon, no persistent process. A Service would add `POST_NOTIFICATIONS` (measured
`prot=dangerous` in D8), a lifecycle, and background-execution limits.

**However** — see R1. The D8 launch experiment proved a **~250 ms** task launches while
locked/dozing. A model load plus generation is **two to three orders of magnitude longer**, and
that is **not** proven. **[U]**

### P2 — File-based exchange over ADB is retained **[P]**

Push prompt → `am start` → pull result. No socket, HTTP, database, daemon, or RPC. Nothing in the
evidence requires one, and §5.2 forbids premature networking layers **[E]**.

### P3 — The model lives in the worker's own external files directory **[P]**

`.../files/model/`. adb can write it (`ext_data_rw`); the app owns it; **`noexec` is irrelevant
because the model is data, not code** **[M]**. The **app** creates the directory — an adb-created
directory is owned by `shell` and the app cannot write it, which D8 falsified the hard way **[E]**.

### P4 — The model is pushed once and hash-verified on the device **[P]**

**[M]** 27.7 MB/s means ~30 s for 0.8 GB. A device-side SHA-256 re-hash makes provisioning a
verified operation rather than a fire-and-forget push.

### P5 — First proof: 1B-class, Q4, greedy, 32–64 tokens **[P]**

Smallest credible real inference. Determinism is **measured, not assumed**.

### P6 — Runtime: llama.cpp with GGUF on CPU **[P]**

| Criterion | Why it favours llama.cpp here |
|---|---|
| Licence | MIT |
| Quantization | broadest range — the memory constraint **[M]** demands it |
| Artifact model | **one self-describing file** (tokenizer + config + weights) — nothing to mismatched |
| Android support | official binding, documented build **[D]** |
| First-proof risk | CPU-only avoids also bringing up a GPU backend |
| Network / root / permissions | none required **[D]** |

**Alternatives retained, not rejected:** LiteRT-LM (Google-recommended, GPU backend with a large
memory and TTFT advantage — but its benchmark is Snapdragon hardware **[D]**, and `.tflite`
packaging differs); ExecuTorch (documented 1B/3B Android support, `.pte` AOT export step);
ONNX Runtime (CPU EP viable, NNAPI EP inapplicable **[M]**).

**Eliminated on measured grounds, not preference:** NNAPI paths **[M]**; EdgeTPU/GXP **[M]**;
Qualcomm GENIE/QNN (Snapdragon-only) **[D]**; Termux CLI (abandons the controlled-worker model)
**[E]**.

### P7 — Verification is an evidence chain, not exact re-computation **[P]**

D8's independent re-computation worked because DTCA-1 is deterministic **[E]**. **It does not
transfer to LLM inference** — the Mac lacks the same model, runtime and backend, and generation
may not be bit-reproducible.

Proposed chain: model hash on device · package identity · PID + `/proc/<pid>/cmdline` · process
lifetime · **CPU time attributable to that PID** · peak `VmRSS` · device-side runtime log ·
output shape · **timing monotonicity with token budget** · no Mac-side inference · repeated-run
stability · **ablation (remove the model → failure)**.

**The load-bearing links are attributable CPU time and ablation.** Ablation is the LLM-era
substitute for re-computation: it establishes **causation**.

**Honest limit: this chain proves inference *occurred on the device*. It does not prove the output
is *correct*.** For Phase 6 the claim is architectural.

### P8 — The worker stays a bounded executor, not an agent **[P]**

It receives an explicit job and returns a result. No planning, no tool use, no autonomy. Hermes
integration is Phase 9 **[E]**.

### P9 — Measurement separates worker-attributable from system-wide **[P]**

Attributable: CPU time, `VmRSS`/`VmHWM`, process lifetime, wall clock, tokens generated.
**Not attributable:** `dumpsys thermalservice` — system-wide, influenced by every process, by
charging, and by ambient temperature. It is reported as *device thermal state during the run*,
never as the worker's consumption. This is the same distinction ADR-011 established **[E]**.

## Unresolved Risks

| # | Risk | Why unresolved | Resolution |
|---|---|---|---|
| **R1** | **A multi-minute Activity may not survive locked/idle** | D8 only proved a ~250 ms task | **Measure first, before any runtime work** |
| R2 | Runtime may not build/load on Android 16 arm64-v8a | Not tested | Trivial `.so` load test before any model |
| R3 | ~1.2–1.5 GB may not fit in ~2.05 GiB | Not tested | Load the model; watch `VmRSS` and `lmkd` |
| R4 | Greedy output may not reproduce | Not tested | 5× runs; report rather than assume |
| R5 | Decode rate on a Tensor G2 is **unknown** | **Deliberately not extrapolated** from Snapdragon figures | The primary thing the first proof measures |
| R6 | Thermal throttling over a long run | Baseline only | Sample `dumpsys thermalservice` before/after |
| R7 | Model licence for client work | Qwen2.5 is Apache-2.0; Llama/Gemma have community licences | A factor in the model decision |
| R8 | A 1B model may be runnable but not *useful* | Not tested | Acceptable for an architecture proof; recorded |

## Consequences

**If approved:**
- D8 components are extended, not replaced. Two genuinely new pieces: native runtime integration
  (JNI/NDK/CMake) and model provisioning.
- The worker's zero-permission posture is retained.
- The Android APK grows by the native runtime's `.so` size; the model stays data.
- Phase 6 adds no routing, no Hermes integration, no UI.

**If R1 is falsified:** the process model changes — a Service or foreground execution — and this
ADR must be revised **before** implementation continues. That is an architecture change, not an
implementation detail.

## Rejected Alternatives

- **A 3B–4B model as the first proof** — contradicts measured memory headroom **[M]**.
- **NNAPI** — measured absent **[M]**.
- **EdgeTPU/GXP** — measured allowlist-gated **[M]**.
- **A Service from the outset** — adds a permission, a notification, a lifecycle, and
  background-execution limits before anything proves they are needed.
- **HTTP / socket / RPC** — §5.2 **[E]**; nothing requires it.
- **GPU/Vulkan for the first proof** — would make the first proof also a backend bring-up. Retained
  as a documented follow-on.
- **Exact re-computation for verification** — not transferable to generative inference.
- **A model in shared storage** — the app's own external dir is sufficient and correctly owned.

## Future Reconsideration Conditions

- **If R1 is falsified** → revise the process model before proceeding.
- **Once a CPU baseline exists** → evaluate Vulkan/GPU against it, using the LiteRT-LM memory/TTFT
  advantage as the hypothesis to test on Mali-G710.
- **If 1B is too tight** → drop to ~0.5B; if it is comfortable, test 2B.
- **If a larger or different device is added** → re-measure; the 3B–4B class may become valid.
- **Phase 7 (routing)** → only after real workload evidence exists **[E]**.
- **Phase 9 (Hermes)** → unchanged boundary; the worker stays a bounded executor.

# Phase 7 Reconnaissance — Resource-Aware Workload Routing

**Status:** RECONNAISSANCE + PROPOSAL. **Implementation BLOCKED pending review.**
**Date:** 2026-10-02
**Phase:** 7 (Resource-Aware Workload Routing) — authoritative per ADR-007
**Depends on:** Phase 6 (`dd51eb1`) — real local LLM inference proven on the Pixel
**No production source modified. No router, monitor, scheduler or queue created.**

---

## A. Phase 7 Requirements (authoritative)

Master prompt §16, verbatim:

> Only after real workloads exist should routing be introduced.
>
> The system may eventually determine: Should this task run on: Mac? Pixel? Another worker?
>
> Routing may consider: workload type · model requirements · memory · CPU · GPU · latency ·
> thermal state · availability · energy · task size
>
> **Do not build a sophisticated scheduler until actual workload evidence justifies it.**

Master prompt §5.2 forbids prematurely introducing "distributed RPC, job schedulers, message
queues, databases, worker pools, microservices, cloud infrastructure, complex plugin systems,
networking layers, resource orchestration, multi-device management".

**Reading these together, Phase 7 requires:**
1. A **deterministic, explainable** decision about where a workload executes.
2. Decisions grounded in **measured** resource and cost evidence — not guesses.
3. **No scheduler, no queue, no fleet management.** The smallest mechanism the evidence justifies.

**The master prompt does not require Phase 7 to be built now.** It requires that routing be
introduced *only when real workload evidence justifies it*. This reconnaissance determines whether
that condition is met.

---

## B. Current Execution Architecture (what Phase 6 provides)

| Capability | State |
|---|---|
| Mac → Pixel job submission | ✅ fixed-path `job.json` + `am start` |
| Pixel → Mac result retrieval | ✅ fixed-path `result.json` |
| Pixel local LLM inference | ✅ proven, llama.cpp `a868c3e`, CPU |
| Pixel deterministic compute (DTCA-1) | ✅ proven, independently re-computable |
| Device discovery / identity / capabilities | ✅ Phase 2–3 |
| Application control | ✅ Phase 4 |
| Worker install / lifecycle | ✅ Phase 5 |
| **Mac-side inference execution** | ❌ **DOES NOT EXIST** |
| Resource observation (Mac or Pixel) | ❌ does not exist |
| Any routing, monitor, or node abstraction | ❌ does not exist (verified: zero matches for `router`/`ResourceMonitor`/`ExecutionNode`/`scheduler` in source) |

### The finding that reframes Phase 7

**There is only one executor.**

Phase 6 deliberately ensured the Mac **does not link llama.cpp** — that was a design decision to
keep the Mac structurally incapable of accidentally producing the result it verifies (ADR-012 §P7).
Verified in source: the only `llama` references on the Mac side are the `InferenceRuntimeIdentity`
name string and a doc comment.

`ollama` happens to be installed on this Mac (an unrelated user install, with `qwen3.5:9b` and
`qwen3:4b`), but it is **not part of PixelDesktop**, is not a project dependency, and nothing in
PixelDesktop can call it.

**Consequence:** Phase 7's decision "Mac or Pixel?" currently has only one real answer for
inference workloads, because the Mac option does not exist as an implementation. This is stated
plainly rather than glossed: **Phase 7 as a routing problem is not yet a real problem.**

---

## C. Mac Resource Evidence (measured 2026-10-02)

### Hardware

| Fact | Value | Source |
|---|---|---|
| Model | **MacBook Air (Mac14,2), Apple M2** | **[M]** |
| CPU cores | 8 physical / 8 logical | **[M]** |
| RAM | **16 GiB** (17,179,869,184 bytes) | **[M]** |
| Storage free | 22 GB of 228 GB | **[M]** |
| GPU | Apple M2, 8 cores, **Metal 4** | **[M]** |

### Current load

| Signal | Value | Source |
|---|---|---|
| Load average (1/5/15) | **2.74 / 2.11 / 2.18** | **[M]** |
| System-wide memory free | **44%** | **[M]** |
| Thermal warnings | **none recorded** | **[M]** |

### Observability classification

| Signal | Mechanism | Class |
|---|---|---|
| CPU core count | `ProcessInfo.activeProcessorCount`, `hw.ncpu` | **OS-observable** |
| Total memory | `ProcessInfo.physicalMemory` | **OS-observable** |
| **Memory pressure** | `memory_pressure`, `host_statistics64` (mach) | **OS-observable** |
| Load average | `getloadavg(3)`, `sysctl vm.loadavg` | **OS-observable** |
| **Thermal state** | **`ProcessInfo.thermalState`** (`nominal`/`fair`/`serious`/`critical`) | **OS-observable, first-class API** |
| Storage free | `URL.resourceValues(forKeys: [.volumeAvailableCapacityKey])` | **OS-observable** |
| Per-process CPU/memory | `task_info` / `proc_pid_rusage` | **process-observable** |
| GPU utilisation | **no public supported API**; `system_profiler` is slow and unsuitable for a decision loop | **not reliably observable** |
| GPU memory | unified with system RAM on Apple silicon | **not separately observable** |

> **Note the asymmetry.** macOS exposes **thermal state as a first-class API**
> (`ProcessInfo.thermalState`) with a documented 4-level scale. Android exposes only
> `dumpsys thermalservice` as a **system-wide numeric** reading with **no worker attribution**.
> The two platforms are **not comparable** on this axis, and the router must not pretend they are.

---

## D. Pixel Resource Evidence (measured 2026-10-02)

### Signals available to a normal PixelDesktop worker, without root

| Signal | Mechanism | Value now | Class |
|---|---|---|---|
| Connectivity | `adb devices` | connected, **USB only** (`service.adb.tcp.port` unset) | **required** |
| Device identity | `getprop` | Pixel 7a, Android 16, API 36 | **required** |
| **MemAvailable** | `/proc/meminfo` | **2,403,532 kB (~2.29 GiB)** | **required** |
| SwapFree | `/proc/meminfo` | 619,612 kB | useful |
| Storage free | `df` | **55 GB of 110 GB** | required |
| Thermal status | `dumpsys thermalservice` | **0** | **useful only — system-wide** |
| Battery level / temperature | `dumpsys battery` | 100% / 33.9 °C | useful |
| Worker installed | `dumpsys package` | versionCode 2 | **required** |
| Worker running | `pidof` | — | required |
| Model present | `ls` on the fixed path | 1,117,320,736 bytes | **required** |
| Device load | `/proc/loadavg` | **0.26 / 0.45 / 0.40** | useful |
| **Per-process CPU** | `/proc/<pid>/stat` | proven in D8/Phase 6 | **required (attributable)** |
| **Per-process peak memory** | `/proc/<pid>/status` `VmHWM` | 1,279 MB measured in Phase 6 | **required (attributable)** |
| Per-process RSS | `/proc/<pid>/status` `VmRSS` | 1,272 MB measured | useful |

### Signals that are NOT available or NOT attributable

| Signal | Status |
|---|---|
| NNAPI | **absent** (measured in Phase 6) |
| EdgeTPU / GXP | present but **app allowlist empty** |
| Per-core CPU utilisation | not reliably readable for other processes without root |
| **Worker-attributable thermal** | **NOT POSSIBLE** — `dumpsys thermalservice` is system-wide |
| GPU utilisation (Mali-G710) | no non-privileged API |
| Wireless ADB | not configured |

> **The thermal asymmetry, restated as an engineering constraint:** the router can read a
> *system-wide* thermal number on the Pixel and a *4-level thermal state* on the Mac. It cannot
> compare them. Any policy that treats "Pixel thermal status 0" and "Mac thermal nominal" as
> equivalent is comparing incommensurable units. This is recorded as a hard limitation.

---

## E. Workload Model — the minimum vocabulary

Investigating what the router actually needs to know, using the two workloads that exist:

| Workload | Requires | Produces | Verifiable how |
|---|---|---|---|
| `DTCA-1` | nothing but a device | deterministic JSON | **exact re-computation on the Mac** |
| `LOCAL-LLM-1` | a **specific model** (name + hash), **~1.3 GB free RAM**, the native runtime | generated text | evidence chain + ablation |

**The minimum vocabulary is smaller than the master prompt's list.** Of the nine factors §16 lists
(workload type, model requirements, memory, CPU, GPU, latency, thermal, availability, energy, task
size), the following are **established as necessary by the two existing workloads**:

| Factor | Necessary? | Why |
|---|---|---|
| **Workload type** | **required** | decides which executor can run it at all |
| **Model requirement** | **required** | `LOCAL-LLM-1` cannot run without its exact model |
| **Memory requirement** | **required** | Phase 6 measured a 1,279 MB peak; the device has ~2.29 GiB |
| **Availability** | **required** | device disconnected / worker absent / model missing |
| CPU | **not yet** | no workload has been shown to be CPU-bound-limited on the Pixel |
| GPU | **not yet** | deliberately unused (§11 of Phase 6); no GPU path exists |
| Latency | **useful, not decidable** | see §F — Pixel latency varies 2.4× unpredictably |
| Thermal | **unusable for decisions** | system-wide on the Pixel; not comparable to macOS |
| Energy | **not observable** | no battery attribution to the worker |
| Task size | **derived** | follows from model + memory, adds nothing |

**Proposal:** the router needs **four** inputs — workload type, model requirement, memory
requirement, availability. Everything else is either unmeasurable, unattributable, or not yet
justified by a workload. **No taxonomy of categories is proposed**, because two workloads do not
justify one.

---

## F. Cost Model (measured)

This is the most decision-relevant section, and it is where the evidence is least comfortable.

### Transfer cost — negligible

| Item | Measurement | Source |
|---|---|---|
| ADB shell round-trip | **226 ms** each (5-sample mean) | **[M]** |
| `job.json` push | 176 bytes, **below timer resolution** | **[M]** |
| `result.json` pull | ~400 bytes, negligible | **[M]** |
| Model transfer (one-time) | 1.04 GiB in **30.79 s** (~36 MB/s) | **[M]** |

**Payload transfer is not a routing cost.** The job and result are ~600 bytes total. The only
material transfer is the one-time model provisioning.

> ADR-012 §5 warns that the reconnaissance's 27.7 MB/s figure used **incompressible** data. The
> 30.79 s model push achieved ~36 MB/s because a GGUF compresses. Both are honest and they measure
> different things. **For routing, this is moot: no recurring transfer is large enough to matter.**

### Compute cost — the Mac is much faster, and it ran a larger model

| Executor | Model | Tokens | Wall clock | Source |
|---|---|---|---|---|
| **Mac** (M2, ollama `qwen3:4b`) | **4B** | 8 | **4.9 s** | **[M]** |
| **Pixel** (Tensor G2, llama.cpp `Qwen2.5-1.5B`) | **1.5B** | 8 | **16.2–25.8 s** | **[M]** |

The Mac was **~3–5× faster while running a model ~2.7× larger.** Measured, not extrapolated.

> **Caveat, stated deliberately:** the Mac figure used `ollama`, which is **not a PixelDesktop
> component**. It is evidence about the *hardware*, not about an executor that exists. It must not
> be read as "the Mac executor is 5× faster" — there is no Mac executor. See §B.

### Cold vs warm — the decisive finding

| Condition | Model load | Prompt eval | Generation (8 tokens) | Total |
|---|---|---|---|---|
| Warm (back-to-back ×3) | 393 / 405 / 414 ms | ~3,166–3,395 ms | 5,084 / 5,310 / 5,137 ms | **~8.9 s** |
| After 60 s idle | 412 ms | 3,436 ms | **14,793 ms** | **18.7 s** |
| After a 40 s idle (earlier) | **4,954 ms** | 8,915 ms | 6,193 ms | **20.1 s** |

**Generation time varied 2.4× for the identical 8 tokens with the identical prompt and seed.**
Model load varied **12×** (393 ms → 4,954 ms) depending on page-cache state.

**This is the most important measurement in Phase 7:**

> **Pixel inference latency is not reliably predictable.** It depends on page-cache state, system
> load, and thermal state — none of which the router can control or observe reliably.

A router cannot promise a latency it cannot predict. **Any policy that requires estimating Pixel
latency is unsound with the evidence available.**

### Warm execution — a correction to an assumption I had

I initially believed `finish()` destroys the worker process. **Measurement falsified that.**

| Observation | Value |
|---|---|
| Worker alive 40 s after `finish()` | ✅ **yes** |
| Worker alive **minutes** later | ✅ **yes** — found still running from Phase 6 tests |

Android keeps the process **cached** after `finish()`. But — critically — **the model is NOT
resident**, because the one-shot Activity frees it in `nativeFree()` on every run. The measured
393–414 ms load times confirm the page cache is warm, not that the model is loaded.

**Conclusion:** warm process ≠ warm model. True warm execution would require a persistent process
holding the model (~1.3 GB resident on a device with ~2.29 GiB available), which the current
one-shot architecture deliberately does not do. **Per the instruction not to redesign the
lifecycle, this is recorded as an architectural question, not implemented.**

---

## G. Capability Model — what Pixel can and cannot execute

| Statement | Basis |
|---|---|
| Pixel **supports** `DTCA-1` | proven, D8 |
| Pixel **supports** `LOCAL-LLM-1` with `qwen2.5-1.5b-instruct-q4_k_m.gguf` | proven, Phase 6 |
| Pixel **supports** ~1B–1.5B Q4 GGUF on CPU | measured, 1,279 MB peak |
| Pixel **does not support** any NNAPI-based workload | measured absent |
| Pixel **does not support** any EdgeTPU/GXP workload | allowlist empty |
| Pixel **does not support** GPU inference **as built** | `GGML_VULKAN=OFF`, `n_gpu_layers=0` forced — a deliberate Phase 6 decision, not a hardware limit |
| Pixel capability for **3B–4B** | **UNKNOWN** — falsified as an assumption, never tested |
| Pixel capability for **other model families** | **UNKNOWN** — untested |
| Pixel capability for **sustained load** | **UNKNOWN** — Phase 6 ran 12–26 s workloads only |

> **No extrapolation.** Tensor G2 token rates are **not** estimated from Snapdragon benchmarks.
> The 3B–4B class remains **falsified by measurement** (Phase 6) and must not be reinstated as an
> assumption — it is listed as UNKNOWN, which is the honest label.

---

## H. Routing Policy Candidates (factual trade-offs, not ranked)

### Candidate 1 — No router; explicit target selection

The caller names the executor. No decision logic.

- **For:** zero new abstraction; nothing can route incorrectly; matches the fact that only one
  executor exists.
- **Against:** does not satisfy §16's eventual intent; pushes the decision to the caller.

### Candidate 2 — Hard-constraint gate (feasibility only)

Deterministic predicate chain that answers *"can the Pixel run this at all?"* and nothing else:

```
1. Is the workload supported on Pixel?          NO  -> Mac (or refuse)
2. Is the required model present and hash-valid? NO  -> Mac
3. Is MemAvailable >= required + safety margin?  NO  -> Mac
4. Is the device connected and the worker installed? NO -> Mac
5. Otherwise -> Pixel
```

- **For:** every branch is a **measured or documented fact**; fully explainable; no thresholds
  except the memory margin, which is derivable from Phase 6's measured 1,279 MB peak.
- **Against:** says nothing about *preference* — it will always choose the Pixel when the Pixel
  can run something, even when that is a poor choice.

### Candidate 3 — Feasibility + cost gate

Candidate 2 plus a cost comparison using the §F measurements.

- **For:** would capture "the Mac is 3–5× faster".
- **Against:** **blocked by evidence.** (a) There is no Mac executor to compare against. (b) Pixel
  latency varies 2.4× unpredictably (§F), so a cost comparison would be comparing a stable number
  to an unstable one. **This candidate cannot be honestly implemented yet.**

### Candidate 4 — Score/weighted model

Weights over CPU, memory, thermal, latency, energy.

- **For:** expresses preference.
- **Against:** requires weights with no measured basis; §16 says routing *may* consider these, not
  that it must; the master prompt's own §5.2 forbids this class of premature sophistication. Also
  requires thermal and energy signals that are **not attributable** (§D).

### Candidate 5 — LLM-driven router

- **Explicitly forbidden** by the instruction and by §13 of the Phase 7 brief. Listed only to
  record that it was considered and excluded.

**Factual summary:** Candidate 2 is the only one whose every branch rests on measured or
documented facts. Candidate 3 is the *desirable* end state but is **not currently implementable
without inventing numbers**. Candidates 4 and 5 are excluded by evidence and instruction
respectively.

---

## I. Failure and Fallback Model

| Failure | Observable? | Correct behavior (proposed) |
|---|---|---|
| Device disconnected | ✅ `adb devices` | do not route to Pixel; report |
| ADB unavailable | ✅ command failure | do not route; report |
| Worker not installed | ✅ `dumpsys package` | do not route; report |
| Model missing | ✅ `ls` on fixed path | do not route; report |
| Model hash mismatch | ✅ device-side SHA-256 | **refuse** — a wrong artifact must never be executed |
| Insufficient memory | ✅ `MemAvailable` before submit | do not route; report |
| Worker timeout | ✅ bounded wait | report; **do not silently retry** |
| Process killed (`lmkd`) | ✅ result absent + process gone | report; do not retry |
| Transfer failure | ✅ size verification exists | report |
| Inference failure | ✅ `INFERENCE_FAILED` in the envelope | report |

**Proposed default: fail and report — not retry, not auto-fallback.**

Rationale, from measured evidence rather than principle:
- A retry cannot improve the outcome for **deterministic** failures (missing model, hash mismatch,
  insufficient memory) — the conditions are unchanged.
- Automatic fallback to the Mac is **impossible today** because no Mac executor exists.
- **Retry storms are a real risk**: each attempt costs 16–26 s of sustained device load, and
  Phase 6 showed the device can already be thermally loaded. Repeated retries would be "device
  abuse" in exactly the sense the brief warns against.

**No retry policy, backoff, or circuit breaker is proposed.** None is justified by evidence.

---

## J. Resource Snapshot Proposal (minimum sufficient)

| Field | Class | Source |
|---|---|---|
| `timestamp` | **required** | local clock |
| `pixelConnected` | **required** | `adb devices` |
| `pixelWorkerInstalled` (+ versionCode) | **required** | `dumpsys package` |
| `pixelModelPresent` (+ hash) | **required** | `ls` + `sha256sum` |
| `pixelMemAvailableBytes` | **required** | `/proc/meminfo` |
| `pixelStorageFreeBytes` | useful | `df` |
| `pixelThermalStatus` | **useful, non-decidable** | `dumpsys thermalservice` — system-wide |
| `pixelLoadAverage` | useful | `/proc/loadavg` |
| `macThermalState` | useful | `ProcessInfo.thermalState` |
| `macMemoryPressure` | useful | `memory_pressure` / mach |
| `macLoadAverage` | useful | `getloadavg` |

**Deliberately excluded:** GPU utilisation (no supported API on either platform), energy
(not attributable), per-core CPU (not readable without root on the Pixel), and anything whose only
justification is "it is available".

> **A caution about staleness, which the measurements raise directly.** `MemAvailable` was
> 2.40 GiB now and 2.15 GiB in Phase 6 — it moves by hundreds of MB as ordinary apps foreground.
> **A snapshot is not a reservation.** The router cannot hold memory by observing it. Any memory
> gate must be checked **immediately before** submission, and must tolerate the check being wrong.

---

## K. Architecture Proposal (minimum)

```
WorkloadDescriptor            <- type + model requirement + memory requirement
        |
        v
FeasibilityEvaluator          <- pure function: descriptor + ResourceSnapshot -> Decision
        |                          every branch a measured/documented fact
        v
Decision { target, reasons[] } <- machine-readable, explainable
        |
        +--> MacExecutor      <- DOES NOT EXIST YET (new work, not Phase 7 scope)
        +--> PixelExecutor    <- EXISTS (WorkerOperations + Inference)
```

**Boundaries:**

| Boundary | Rationale |
|---|---|
| `FeasibilityEvaluator` is a **pure function** | testable with no device; the decision logic must be verifiable without hardware |
| `ResourceSnapshot` is a **value type**, taken at a point in time | makes staleness explicit rather than hidden in a live object |
| `Decision` carries `reasons[]` | §11 requires explainability without an LLM interpreting hidden state |
| The router selects among **approved capabilities** | it never constructs a command, path, or shell string (§17) |
| No `ExecutionNode` fleet abstraction | two nodes, one of which does not exist, does not justify it (§14) |

**The proposal is deliberately smaller than the candidate structure in the brief.** The brief
offered `DeviceManager / ResourceMonitor / CapabilityModel / Workload / Router / Executors`. The
evidence supports **three** pieces — descriptor, evaluator, decision — because:
- `DeviceManager` **already exists** and already holds device state; a `ResourceMonitor` alongside
  it would be the "second device model" the brief warns against.
- `CapabilityModel` would duplicate the existing `DeviceCapabilities`
  (`PixelDesktop/Transport/Transport.swift:196`) and the `DeviceOperation` enum.
- A separate `MacExecutor` cannot be built (§B), so `Executors` would have one member.

---

## L. Reuse-Before-Rebuild Map

| Existing component | Phase 7 classification | Notes |
|---|---|---|
| `TransportProtocol` / `ADBTransport` | **reuse unchanged** | already has `shell`, `push`, `pull`, `install`, `getprop` |
| `AndroidDevice` | **reuse unchanged** | already models identity + state |
| `DeviceManager` | **extend** | natural home for a `ResourceSnapshot` read; do **not** duplicate it |
| `DeviceCapabilities` (`Transport.swift:196`) | **extend** | the existing capability model — extend it, do not create a second |
| `DeviceOperation` enum | **extend** | add a case **only when the operation exists** (established convention from Phase 3/4) |
| `WorkerOperationsProtocol` | **reuse unchanged** | fixed-path job/result already suffices |
| `WorkerTransferContract` | **reuse unchanged** | — |
| `WorkerInstaller` | **reuse unchanged** | `installedState` already answers "is the worker present" |
| `WorkerLifecycle` | **reuse unchanged** | `state` already answers "is it running" |
| `WorkerComputeProof` | **reuse unchanged** | its `Evidence` already carries PID + CPU ticks |
| `InferenceRuntime` | **reuse unchanged** | the runtime boundary is not a routing concern |
| `LlamaCppInferenceRuntime` | **reuse unchanged** | — |
| `InferenceRequest` / `InferenceResult` | **reuse unchanged** | already carry the model identity and timings a router would need |
| `ModelContract` | **reuse unchanged** | already fixes the model path and hash — the model requirement is **already expressed** |
| **New:** `WorkloadDescriptor` | **new** | small value type |
| **New:** `ResourceSnapshot` | **new** | small value type |
| **New:** `FeasibilityEvaluator` + `Decision` | **new** | pure function + explainable result |
| **New:** Mac executor | **new — and NOT Phase 7 scope** | does not exist; building it is a separate decision |

**No second device model, no second worker model, no second capability system.** Notably,
`ModelContract` already encodes the model requirement and `WorkerInstaller.installedState` already
answers availability — most of what a router needs is **already implemented**.

---

## M. Failure Hypotheses

| # | Assumption | How tested | Falsifier | Consequence |
|---|---|---|---|---|
| **H1** | Pixel latency is predictable enough to route on | measured (§F) | 2.4× variance observed | **FALSIFIED — latency cannot be a routing input** |
| **H2** | `finish()` destroys the worker process | measured | process alive minutes later | **FALSIFIED — process is cached; model is not** |
| **H3** | Model load time is a stable cost | measured | 393 ms → 4,954 ms (12×) | load is cache-dependent, not a constant |
| H4 | `MemAvailable` is stable enough for a gate | re-measured | moved 2.15 → 2.40 GiB | a snapshot is not a reservation; check immediately before submit |
| H5 | A Mac executor exists to fall back to | source inspection | none exists | **FALSIFIED — fallback is impossible today** |
| H6 | Thermal state is comparable across platforms | API inspection | macOS = 4-level enum; Android = system-wide numeric, unattributable | **FALSIFIED — not comparable** |
| H7 | Transfer cost matters for routing | measured | ~600 bytes total | negligible; only the one-time model push matters |
| H8 | Availability is observable | verified | `adb devices`, `dumpsys package`, `ls`, `sha256sum` all work | **holds** |
| H9 | Deterministic feasibility routing can make useful decisions | reasoning | — | plausible, **untested** |
| H10 | The 1,279 MB peak is representative | Phase 6, single model | untested on other models | treat as **provisional** |
| H11 | Pixel can sustain repeated inference without throttling | Phase 6 was 12–26 s runs | untested | **unknown** — relevant to retry policy |

**H1, H2, H5 and H6 are all falsifications of assumptions that would have been reasonable to
encode in a router.** H5 is the most consequential: it means the central question of Phase 7
cannot currently be answered by implementation.

---

## N. Open Questions (genuinely unresolved)

1. **Should a Mac executor exist at all?** This is the blocking question. Without it, Phase 7 has
   one executor and routing is a formality. Building it is a scope decision above Phase 7.
2. **Is ~1.3 GB resident acceptable?** True warm execution needs a persistent process holding the
   model — ~1.3 GB of ~2.29 GiB available. Untested, and it conflicts with the one-shot design.
3. **What is the real thermal behaviour under sustained load?** Phase 6 ran 12–26 s only.
4. **Can the 2.4× latency variance be bounded** by warming or pinning, and is that worth it?
5. **Is `MemAvailable` a sufficient memory gate**, given it moves by hundreds of MB? Possibly needs
   a margin derived from measurement rather than chosen.
6. **Does the Pixel's advantage justify routing at all?** The Mac is 3–5× faster on the measured
   comparison. If that holds for a real Mac executor, the honest answer may be "route to the Mac
   and treat the Pixel as a *specialised* node for workloads the Mac should not run" — a different
   and arguably more truthful framing than "resource-aware load balancing".

---

## O. Implementation Plan (after approval)

**Every step is gated. Steps 1–2 are pure logic and device-free.**

1. **`WorkloadDescriptor` + `ResourceSnapshot` + `Decision`** — value types only. No device access.
   **Gate: unit tests.**
2. **`FeasibilityEvaluator`** as a pure function. **Gate: unit tests covering every branch,
   including each falsifier from §M.** No thresholds except the memory margin.
3. **Derive the memory margin from measurement** rather than choosing it: Phase 6's 1,279 MB peak
   against observed `MemAvailable`. **Gate: documented derivation, not a round number.**
4. **Wire `ResourceSnapshot` reading** into the existing `DeviceManager` (extend, do not duplicate).
   **Gate: real-device read; no new abstraction.**
5. **`PixelExecutor`** — a thin adapter over the existing `WorkerOperations` + inference path.
   **Gate: the existing Phase 6 proof still passes.**
6. **Real-device verification** of a decision: supported workload → Pixel; unsupported → refused.
   **Gate: the recorded `reasons[]` match what actually happened.**
7. **Regression** — full 194-test suite.
8. **Documentation** — phase log, ADR-013, techniques.

**Explicitly not in this plan:** a Mac executor, retries, backoff, warm execution, GPU, a
scheduler, a queue, multi-device support, or Hermes integration.

**A recommendation on ordering, offered for review:** **step 1 and 2 may be premature.** If the
answer to Open Question 1 is "no Mac executor", then the router can never choose anything but the
Pixel, and a feasibility gate is a *validation* concern rather than a *routing* concern — which
would be better expressed as an extension of the existing `InferenceRequest.validate()` than as a
new subsystem. **This reconnaissance therefore recommends resolving Open Question 1 before
implementing anything.**

---

## ADR Checkpoint

**ADR-013 is drafted in `engineering/decisions/ADR-013-resource-aware-routing.md`** — PROPOSED, not
approved — with evidence separated into established / measured / documented / hypothesis /
proposed / unresolved.

---

## Provenance

**Established (repository):** master prompt §16 Phase 7 and §5.2; ADR-003/004/010/011/012; Phase 6
reconnaissance and implementation logs; existing component surfaces (verified by reading source).

**Measured (2026-10-02, read-only):** Mac hardware/load/memory/thermal/GPU; Mac ollama timing
(**not a project component**); Pixel connectivity, MemAvailable, storage, thermal, battery, worker
version, model presence, loadavg; ADB round-trip 226 ms; warm/cold model load and generation
timings; process persistence after `finish()`.

**Documented:** macOS `ProcessInfo.thermalState`; mach `host_statistics64`; Apple-silicon unified
memory; Android `/proc` interfaces; `dumpsys thermalservice` scope.

**Hypothesis:** that a deterministic feasibility gate is useful (H9, untested); that 1,279 MB is
representative (H10); that sustained load is safe (H11).

**Proposed:** §K architecture; §J snapshot; §I fail-and-report; §O sequence.

**Unresolved:** §N, of which **Open Question 1 is blocking**.

---

## Device and repository state

- Repository **clean** at `dd51eb1`. **No production source modified.**
- Worker force-stopped; no probe processes left running.
- The provisioned model (1.04 GiB) remains on the device — it is the Phase 6 artifact, not test
  debris.

---

```text
PHASE 7 RECONNAISSANCE COMPLETE
IMPLEMENTATION BLOCKED PENDING REVIEW
```

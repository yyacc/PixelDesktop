# ADR-013: Resource-Aware Workload Routing

## Status

**SUPERSEDED — 2026-10-02, before any implementation.**

This ADR proposed a `FeasibilityEvaluator` **inside PixelDesktop** that would decide Mac-vs-Pixel.
That was withdrawn following architectural review. **Do not implement this ADR.**

**Why it was withdrawn:** the master engineering prompt §1 places **orchestration on the Mac, above
PixelDesktop**, not inside it:

```text
Mac
 ├── UI
 ├── orchestration        <-- NOT inside PixelDesktop
 ├── complex reasoning
 └── AI coordination
          ▼
     PixelDesktop
```

A router inside PixelDesktop therefore placed a decision-making component on the **wrong side of a
boundary the master prompt had already drawn**, and duplicated a decision Hermes already owns.

**Preserved deliberately, not deleted.** Its reconnaissance measurements remain valid and are reused
by the replacement document:
- Pixel latency varies **2.4×** for identical work — latency cannot be a routing input.
- Model load varies **12×** (393 ms → 4,954 ms) with page-cache state.
- **No Mac executor exists.**
- Thermal signals are **not comparable** across macOS and Android.
- Transfer cost is negligible (~600 bytes); the one-time 1.04 GiB model push is the only material transfer.
- A snapshot is not a reservation (`MemAvailable` moved 2.15 → 2.40 GiB).

**Replacement:** `phases/phase-07-architecture-reevaluation.md` — Hermes owns decomposition and
placement; PixelDesktop publishes a capability contract and **enforces** feasibility.

**Also withdrawn with it:** `WorkloadDescriptor`, `Decision{target,reasons}`, `ResourceSnapshot` as a
local decision input, the `Executors`/`ExecutionNode` abstraction, and any Mac executor.

**Retained from this ADR:** P2 (routing selects among approved capabilities only), P6 (fail and
report; no retries), P7 (a snapshot is not a reservation), P8 (capability stated as
support / non-support / unknown), and the entire §M failure-hypothesis table.

**Its own reconnaissance warned against it.** §B found "there is only one executor"; §H judged
cost-comparison routing "blocked by evidence"; §N asked whether routing was worth it at all. The
proposal was made anyway because the brief's candidate structure listed a router. Recorded as a
process lesson: **when the evidence says "no component", propose no component.**

## Date

2026-10-02

## Evidence Classification

- **[E] Established** — from the repository
- **[M] Measured** — read from the Mac or the physical Pixel 7a on 2026-10-02
- **[D] Documented** — from a primary external source or platform API
- **[H] Hypothesis** — believed, not established
- **[P] Proposed** — a decision this ADR asks to be approved
- **[U] Unresolved**

A hypothesis is never presented as a requirement. Where reconnaissance contradicted a reasonable
assumption, that is recorded explicitly rather than quietly adjusted.

## Context

Phase 6 proved real local LLM inference on the Pixel **[E]**. The master prompt §16 states routing
"may eventually" consider workload type, model requirements, memory, CPU, GPU, latency, thermal
state, availability, energy and task size, and adds: **"Do not build a sophisticated scheduler
until actual workload evidence justifies it."** §5.2 forbids premature schedulers, queues,
resource orchestration and multi-device management **[E]**.

## Problem

Should PixelDesktop route workloads between the Mac and the Pixel — and if so, on what evidence?

## The Finding That Reframes the Phase

**There is only one executor.**

Phase 6 deliberately ensured the Mac does **not** link llama.cpp, so the Mac cannot accidentally
produce the result it verifies (ADR-012 §P7) **[E]**. Verified by source inspection: the only
`llama` references on the Mac side are an identity string and a doc comment **[M]**.

`ollama` is installed on this Mac with `qwen3.5:9b` and `qwen3:4b` **[M]**, but it is an unrelated
user install, is not a PixelDesktop dependency, and nothing in PixelDesktop can call it **[E]**.

**Therefore the question "Mac or Pixel?" currently has one real answer for inference workloads,
because the Mac option does not exist as an implementation.**

## Established and Measured Facts

### Measured — Mac **[M]**

| Fact | Value |
|---|---|
| Hardware | MacBook Air (Mac14,2), Apple M2, 8 cores |
| RAM | 16 GiB |
| Load average | 2.74 / 2.11 / 2.18 |
| System memory free | 44% |
| Thermal warnings | none |
| GPU | Apple M2, 8 cores, Metal 4 |

### Measured — Pixel **[M]**

| Fact | Value |
|---|---|
| Connectivity | connected, **USB only** |
| MemAvailable | **2,403,532 kB (~2.29 GiB)** (was 2.15 GiB in Phase 6) |
| Storage free | 55 GB |
| Thermal status | 0 — **system-wide, not worker-attributable** |
| Device load | 0.26 / 0.45 / 0.40 |
| Model present | 1,117,320,736 bytes |

### Measured — cost **[M]**

| Item | Value |
|---|---|
| ADB shell round-trip | **226 ms** |
| job + result payload | **~600 bytes total — negligible** |
| Model transfer (one-time) | 1.04 GiB in 30.79 s |
| **Mac** 8 tokens, `qwen3:4b` (4B) | **4.9 s** |
| **Pixel** 8 tokens, `Qwen2.5-1.5B` (1.5B) | **16.2–25.8 s** |
| Pixel warm model load (×3) | 393 / 405 / 414 ms |
| Pixel cold-ish model load | **4,954 ms (12×)** |
| Pixel generation, same 8 tokens | 5,084 ms warm vs **14,793 ms** after idle (**2.4×**) |

> The Mac comparison used `ollama`, which is **not a project component**. It is evidence about the
> **hardware**, not about an executor that exists. It must not be read as "the Mac executor is
> 3–5× faster".

## Proposed Decisions

### P1 — No scheduler, no queue, no fleet abstraction **[P]**

Two nodes, one of which does not exist, does not justify `ExecutionNode`, a scheduler, a queue, or
a `ResourceMonitor` subsystem. §5.2 **[E]** and §14 of the Phase 7 brief both forbid it.

### P2 — The router selects among approved capabilities only **[P]**

It never constructs a command, path, or shell string. This preserves D8/Phase 6 containment
unchanged **[E]**. A routing decision chooses *among existing validated operations*, and cannot
create one.

### P3 — Routing inputs are limited to four, each justified by an existing workload **[P]**

Workload type · model requirement · memory requirement · availability.

**Deliberately excluded, each for a measured reason:**
- **CPU** — no workload has been shown to be CPU-limited on the Pixel.
- **GPU** — no GPU path exists; deliberately disabled in Phase 6 (§11).
- **Latency** — **falsified as a routing input**: 2.4× variance for identical work (§F).
- **Thermal** — **not comparable across platforms**: macOS exposes a 4-level
  `ProcessInfo.thermalState` **[D]**; Android exposes only a system-wide numeric reading with no
  worker attribution **[M]**. Treating them as equivalent compares incommensurable units.
- **Energy** — not attributable to the worker.
- **Task size** — derived from model + memory; adds nothing.

### P4 — The decision is a pure function of a snapshot **[P]**

`FeasibilityEvaluator(descriptor, snapshot) -> Decision`. Pure, so the decision logic is verifiable
**without a device** — the same testability discipline applied throughout this project **[E]**.

### P5 — Every decision carries machine-readable reasons **[P]**

`Decision { target, reasons[] }`. A future failure must be able to answer *"why did PixelDesktop
send this workload to the Pixel?"* without an LLM interpreting hidden state. This is an
engineering requirement for diagnosing misrouting, not UI.

### P6 — Fail and report; do not retry, do not auto-fallback **[P]**

- Retry cannot help **deterministic** failures (missing model, hash mismatch, insufficient memory)
  — the conditions are unchanged.
- Automatic fallback to the Mac is **impossible today** (no Mac executor).
- Each attempt costs **16–26 s of sustained device load** **[M]**, so retries risk exactly the
  "device abuse" the brief warns about.

**No retry policy, backoff, or circuit breaker is proposed.** None is justified by evidence.

### P7 — A snapshot is not a reservation **[P]**

`MemAvailable` moved 2.15 → 2.40 GiB between Phase 6 and now **[M]** as ordinary apps foregrounded.
The router cannot hold memory by observing it. Any memory gate must be evaluated **immediately
before** submission and must tolerate being wrong.

### P8 — Pixel capability is stated as support / non-support / unknown **[P]**

| Statement | Basis |
|---|---|
| Supports `DTCA-1` | proven |
| Supports `LOCAL-LLM-1` with the provisioned model | proven |
| Supports ~1B–1.5B Q4 GGUF on CPU | measured (1,279 MB peak) |
| Does not support NNAPI | measured absent |
| Does not support EdgeTPU/GXP | allowlist empty |
| Does not support GPU **as built** | `GGML_VULKAN=OFF`, `n_gpu_layers=0` forced |
| **3B–4B: UNKNOWN** | falsified as an assumption in Phase 6; **never tested** |
| Other model families: **UNKNOWN** | untested |
| Sustained load: **UNKNOWN** | Phase 6 ran 12–26 s only |

**No extrapolation from other phones' benchmarks.** The 3B–4B class is recorded as UNKNOWN, not
as a target — reinstating it as an assumption is explicitly forbidden.

### P9 — The proposed architecture is three pieces, not six **[P]**

```
WorkloadDescriptor -> FeasibilityEvaluator -> Decision{ target, reasons[] }
                                                    |
                                          +---------+---------+
                                          v                   v
                                     MacExecutor          PixelExecutor
                                     (DOES NOT EXIST)     (EXISTS)
```

The brief's candidate structure (`DeviceManager / ResourceMonitor / CapabilityModel / Workload /
Router / Executors`) is **larger than the evidence supports**:
- `DeviceManager` **already exists** and holds device state; a `ResourceMonitor` beside it would be
  the "second device model" the brief warns against.
- `CapabilityModel` would duplicate the existing `DeviceCapabilities`
  (`Transport.swift:196`) and `DeviceOperation` enum.
- `Executors` would have one member.

**Notably, much of what a router needs already exists:** `ModelContract` already encodes the model
requirement and hash, and `WorkerInstaller.installedState` already answers availability **[E]**.

## Unresolved Risks

| # | Risk | Why unresolved | Resolution |
|---|---|---|---|
| **U1** | **No Mac executor exists** | It is a scope decision above Phase 7 | **BLOCKING — resolve before implementing anything** |
| U2 | True warm execution needs ~1.3 GB resident | Untested; conflicts with the one-shot design | Architectural question; do not redesign the lifecycle in Phase 7 |
| U3 | Sustained-load thermal behaviour unknown | Phase 6 ran 12–26 s only | Measure before any retry policy |
| U4 | 2.4× latency variance may be boundable | Untested | Measure; may or may not be worth it |
| U5 | `MemAvailable` sufficiency as a gate | Moves by hundreds of MB | Derive a margin from measurement, not a round number |
| U6 | Whether routing is worth it at all | The Mac measured 3–5× faster | See below |

### On U6 — the framing question, stated plainly

If the Mac is genuinely 3–5× faster for a real Mac executor, then **"resource-aware load
balancing" is the wrong frame.** The honest frame may be:

> the Mac is the compute node; the Pixel is a **specialised** node for workloads the Mac should not
> or cannot run.

That is a different and arguably more truthful architecture than balancing load between peers. It
should be decided deliberately rather than drifted into.

## Consequences

**If approved:**
- Three small value types and one pure function. No scheduler, queue, monitor subsystem, or fleet
  abstraction.
- `DeviceManager` and `DeviceCapabilities` are **extended**, never duplicated.
- Containment is unchanged: the router selects among approved capabilities and constructs nothing.
- Phase 7 adds no Hermes integration, no retries, no warm execution, no GPU, no larger model.

**If U1 resolves to "no Mac executor":** the router can only ever choose the Pixel, and a
feasibility gate becomes a **validation** concern rather than a **routing** concern — better
expressed as an extension of the existing `InferenceRequest.validate()` than as a new subsystem.
**This reconnaissance recommends resolving U1 first, and warns that steps 1–2 of the implementation
plan may be premature until it is.**

## Rejected Alternatives

- **Weighted/scored routing** — requires weights with no measured basis; needs thermal and energy
  signals that are not attributable **[M]**.
- **Cost-comparison routing** — blocked: no Mac executor to compare against, and Pixel latency
  varies 2.4× unpredictably, so it would compare a stable number to an unstable one.
- **LLM-driven routing** — forbidden by the instruction and by the brief §13.
- **`ExecutionNode` fleet abstraction** — two nodes, one non-existent.
- **Automatic fallback to the Mac** — impossible today.
- **Retry/backoff** — deterministic failures cannot be retried into success; each attempt costs
  16–26 s of device load.
- **Thermal-based routing** — the signals are not comparable across platforms.

## Future Reconsideration Conditions

- **If a Mac executor is built** → re-evaluate cost-comparison routing with real numbers.
- **If sustained-load thermal data is gathered** → reconsider thermal as an input.
- **If latency variance is bounded** → reconsider latency as an input.
- **If a second Pixel or another node is added** → reconsider a minimal node abstraction.
- **If a 3B–4B model is measured** → update the capability statement from UNKNOWN to a measured
  result. It must not be promoted back to an assumption.
- **Phase 9 (Hermes)** → the infrastructure layer keeps authoritative routing authority. Hermes
  requests work; it does not decide where work runs.

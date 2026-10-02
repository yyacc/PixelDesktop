# Phase 7 Architecture Re-Evaluation — Hermes-Owned Planning vs a PixelDesktop Router

**Status:** RE-EVALUATION COMPLETE. **Implementation BLOCKED pending review.**
**Date:** 2026-10-02
**Supersedes:** the router proposal in `ADR-013` (now marked SUPERSEDED)
**No production source modified. No router, Mac executor, or dependency installed.**

---

## 1. The actual problem with the current Phase 7 design

The user's correction is **right, and it is right for a reason stronger than the one given.**

**ADR-013's central proposal — a `FeasibilityEvaluator` inside PixelDesktop that decides Mac-vs-Pixel
— contradicts the master engineering prompt's own architecture.**

Master prompt §1 states the long-term goal verbatim:

```text
Mac
 │
 ├── UI
 ├── orchestration          <-- orchestration is a MAC responsibility
 ├── architecture
 ├── complex reasoning
 └── AI coordination
          │
          ▼
     PixelDesktop
          │
          ▼
      Pixel 7a
```

§1 also lists "resource-aware workload routing" among future concerns **without placing it inside
PixelDesktop**, and §9 assigns Hermes the job of understanding capabilities, creating workloads,
monitoring them, and receiving results.

**So the Phase 7 router was not merely extra complexity. It placed a decision-making component on
the wrong side of a boundary the master prompt had already drawn.**

### How this happened, stated plainly

My own reconnaissance found the evidence that pointed away from a router:

- **§B:** "There is only one executor" — the Mac cannot run inference, so a router could only ever
  choose the Pixel.
- **§H Candidate 3:** cost-comparison routing is "**blocked by evidence**".
- **§N Open Question 6:** "the honest frame may be that the Mac is the compute node and the Pixel is
  a **specialised** node... rather than resource-aware load balancing."

I surfaced the right question and then proposed building the component anyway, because the brief's
candidate structure listed one. That is the specific failure: **the evidence said "no router", and I
proposed a small router instead of no router.**

---

## 2. Comparison: router-in-PixelDesktop vs Hermes-owned planning

| Dimension | Router inside PixelDesktop (ADR-013) | Hermes-owned planning (corrected) |
|---|---|---|
| Where the decision lives | Infrastructure layer | **Orchestration layer** |
| Alignment with master prompt §1 | **Contradicts it** | **Matches it** |
| Number of decision-makers | Two (Hermes plans, PixelDesktop re-decides) | **One** |
| Can it choose anything today? | No — one executor exists | N/A — decomposition is the value, not target selection |
| Reproducibility of decisions | Deterministic | **Non-deterministic** (LLM) — a real cost, see §8 R1 |
| Can it decompose a large task? | **No** — out of scope by design | **Yes** — the actual requirement |
| New components | 3 value types + 1 evaluator + executor abstraction | **1 contract** (exposes what already exists) |
| Failure mode | Two layers disagree about feasibility | One layer decides; the other **enforces** |
| Swappability | Router hardcodes a two-node world | Contract makes nodes/runtimes **swappable** |

**The decisive asymmetry:** a router inside PixelDesktop answers "which of my two nodes runs this?"
— a question with one possible answer today. Hermes-owned planning answers "**how do I break this
large task into subtasks, and which can the Pixel take?**" — a question that exists *right now*, and
that the router design does not address at all.

**The corrected architecture is not a simplification of the router. It solves a different and
larger problem, with less code.**

---

## 3. Responsibility boundary

```
USER
 │
 ▼
HERMES  ── orchestration, planning, decomposition, placement, synthesis
 │         owns: what work exists, how it is split, where each piece goes
 │
 │  consumes: the Pixel Capability Contract (§4)
 │  issues:   approved workload requests
 ▼
PIXELDESKTOP ── the Pixel compute interface
 │         owns: device access, workload validation, execution, evidence, structured results
 │         does NOT own: task decomposition, placement, or planning
 │
 ▼
PIXEL 7a ── compute node
```

| Responsibility | Owner | Rationale |
|---|---|---|
| Task decomposition | **Hermes** | Requires reasoning over the task; §1 assigns it |
| Placement ("Pixel or elsewhere") | **Hermes** | §1; and with one executor, "placement" is really "feasibility + preference" |
| **Feasibility enforcement** | **PixelDesktop** | Authoritative — it alone knows device/model/runtime state |
| Device access & containment | **PixelDesktop** | D8/Phase 6 boundaries, unchanged |
| Workload validation | **PixelDesktop** | Must refuse what it cannot run, regardless of what Hermes believes |
| Execution & evidence | **PixelDesktop** | Proven in Phases 5–6 |
| Result synthesis | **Hermes** | It decomposed the task, so it recombines it |

### The critical nuance: decision vs enforcement

This distinction is what keeps the corrected design safe, and it must not be blurred:

- **Hermes decides.** It may be wrong; it is an LLM.
- **PixelDesktop enforces.** It refuses anything it cannot actually execute, with a bounded,
  machine-readable reason — and this is **not advisory**.

**Defence in depth:** Hermes's belief about Pixel capability is an *optimisation input*. PixelDesktop's
validation is the *authority*. A stale or mistaken Hermes belief causes a wasted round-trip, never an
invalid execution. This preserves the entire D8/Phase 6 containment model **unchanged**.

---

## 4. Minimum capability contract PixelDesktop should expose

The contract must be **data, not code**, and must be **retrievable at decision time** — never baked
into the Hermes skill. That is the swappability requirement: swapping the Pixel, the model, or
llama.cpp must change the contract's *contents*, not Hermes's instructions.

### 4.1 Static capability — changes only on redeploy

| Field | Value today | Already exists? |
|---|---|---|
| Workload types supported | `DTCA-1`, `LOCAL-LLM-1` | ⚠️ implicit in the worker's dispatch |
| Runtime identity | `llama.cpp`, `a868c3e` | ✅ `InferenceRuntimeIdentity` |
| Backend | `cpu` | ✅ `LlamaCppRuntime.backend` |
| Model file name | `qwen2.5-1.5b-instruct-q4_k_m.gguf` | ✅ `ModelContract.modelFileName` |
| Model SHA-256 | `6a1a2eb6...` | ✅ `ModelContract.expectedSha256` |
| Model byte size | 1,117,320,736 | ✅ `ModelContract.expectedByteCount` |
| Supported ABIs | `arm64-v8a` | ✅ `DeviceCapabilities.supportedABIs` |
| Context size | 2048 | ❌ **only in `llama_jni.cpp`** (`kContextSize`) |
| Device identity | Pixel 7a, Android 16, API 36 | ✅ `AndroidDevice` |

**Only one field is genuinely missing: context size.** Everything else already exists — it is simply
not *published* as a contract.

### 4.2 Dynamic state — changes per invocation

| Field | Source | Exists? |
|---|---|---|
| Device connected | `adb devices` | ✅ `DeviceManager` |
| Worker installed (+ versionCode) | `dumpsys package` | ✅ `WorkerInstaller.installedState` |
| Worker running | `pidof` | ✅ `WorkerLifecycle.state` |
| Model present on device | `ls` fixed path | ⚠️ exists in `LlmWorkload`, Mac-side read not exposed |
| **MemAvailable** | `/proc/meminfo` | ❌ new read |
| Storage free | `df` | ❌ new read |
| Thermal status | `dumpsys thermalservice` | ❌ new read — **system-wide, not attributable** |
| ADB transport mode | `adb devices -l` | ✅ parseable |

### 4.3 Measured performance evidence — changes as measurements accumulate

| Field | Measured value | Provenance |
|---|---|---|
| Model load (warm) | 382–437 ms | Phase 6, `qwen2.5-1.5b` |
| Model load (cold-ish) | **4,954 ms** | Phase 7 recon — **12× spread** |
| Prompt eval | 5.25–7.27 s for 27–32 tokens | Phase 6 |
| Decode rate | **~0.97–1.46 tok/s** | Phase 6 |
| Generation, same 8 tokens | **5,084 ms warm / 14,793 ms after idle** | Phase 7 recon — **2.4× spread** |
| Peak process memory | **1,279 MB** | Phase 6 |

> **These numbers must carry provenance and a timestamp, and must be re-derivable.** They are
> *observations*, not constants. Phase 7's own measurement showed a 2.4× spread on identical work —
> publishing "1.0 tok/s" as a static capability would be a **fabrication of precision**.

### 4.4 Where each kind of information belongs

| Information | Kind | Lives in |
|---|---|---|
| Workload types, runtime, backend, model identity | **static capability** | PixelDesktop, published via contract |
| Context size | **static capability** | PixelDesktop (currently only in native code) |
| MemAvailable, storage, thermal, connectivity, worker/model state | **dynamically measured state** | PixelDesktop, observed on request |
| Load/generation timings, memory peak | **measured performance evidence** | PixelDesktop, from real results, with timestamps |
| How to decompose; what the constraints mean; how to read the numbers | **Hermes knowledge/skill** | Hermes skill |
| "Can this actually run?" | **execution validation** | PixelDesktop, authoritative |

**The rule that keeps this honest:** the skill must say *"read the contract and the latest
measurements"*, never *"the Pixel does 1 tok/s"*. A hardcoded number in a skill becomes a lie the
moment the model or device changes — and it would silently violate the swappability principle.

---

## 5. What Phase 1–6 already provides (reuse map)

| Component | Phase 7 use |
|---|---|
| `AndroidDevice` / `DeviceCapabilities` | **reuse + extend** — publish, do not duplicate |
| `DeviceManager` | **extend** — the natural home for a dynamic-state read |
| `InferenceRuntimeIdentity` | **reuse unchanged** — already the runtime half of the contract |
| `ModelContract` | **reuse unchanged** — already the model half of the contract |
| `InferenceRequest.validate()` | **reuse unchanged** — already the request-validation half |
| `InferenceResult` | **reuse unchanged** — already returns timings, runtime, model hash |
| `WorkerInstaller.installedState` | **reuse unchanged** — availability is already answerable |
| `WorkerLifecycle.state` | **reuse unchanged** — process state already answerable |
| `WorkerOperationsProtocol` / `WorkerTransferContract` | **reuse unchanged** — the execution path |
| `DTCA1Worker` / `LlmWorkload` / `LlamaBridge` | **reuse unchanged** |
| `ResultVerifier` (DTCA-1) | **reuse unchanged** |
| `InferenceEvidence` (LLM) | **reuse unchanged** |

**The striking result: the contract is ~80% already implemented.** The work is *publishing* existing
state as a contract, not building new machinery.

---

## 6. What should be removed or simplified

| ADR-013 item | Disposition | Reason |
|---|---|---|
| `FeasibilityEvaluator` (a router) | **REMOVE** | Wrong layer — §1. Its validation half already exists as `InferenceRequest.validate()` + worker dispatch |
| `Decision { target, reasons[] }` | **REMOVE from PixelDesktop** | Target selection is Hermes's. **But keep the refusal reason** — PixelDesktop already returns bounded `error_type` codes |
| `WorkloadDescriptor` | **REDUCE** | It is the existing job envelope. Do not add a parallel type |
| `ResourceSnapshot` | **REPURPOSE** | Becomes the *dynamic state* section of the capability contract — an observation for Hermes, not an input to a local decision |
| `Executors` / `ExecutionNode` abstraction | **REMOVE** | One executor exists; §5.2 forbids it |
| Mac executor | **DO NOT BUILD** | Explicitly out of scope, and §1 puts complex reasoning on the Mac anyway |
| Retry / backoff / circuit breaker | **DO NOT BUILD** | Unchanged from ADR-013: deterministic failures cannot be retried into success |
| **New: capability contract publication** | **ADD** | The one genuinely new thing, and it is small |
| **New: context size in the contract** | **ADD** | The only missing static field |

**Net effect: fewer components than ADR-013 proposed.**

---

## 7. Proposed Hermes skill concept

A skill — call it `pixel-compute` — that teaches Hermes to use the Pixel as a specialised node.

**What it must contain:**

1. **How to read the capability contract** — invoke PixelDesktop's capability query; do not cache it
   across sessions.
2. **How to interpret the constraints honestly** — including that decode is ~1 tok/s, that latency
   varies 2.4×, and that thermal is system-wide.
3. **Decomposition guidance** — split work into bounded, self-contained subtasks with small prompts.
   Phase 6's measurements make this concrete: prefill costs ~4–6 tok/s, so **prompt size is the
   dominant cost**, and the Pixel suits *many small independent subtasks* over one large one.
4. **What the Pixel is and is not for** — a specialised bounded executor, not a peer of the Mac.
5. **How to handle refusal** — a bounded `error_type` means *do not retry*; re-plan instead.
6. **How to report results with provenance** — which model, which runtime, which evidence.

**What it must NOT contain:** hardcoded model names, token rates, device serials, or paths. Those come
from the contract.

**Why a skill and not code:** the skill is the swappable seam. Replacing the Pixel, the model, or
llama.cpp must require **zero** change to the skill — only to what the contract reports. That is
precisely the user's swappability requirement, and a skill is where Hermes's *judgement* belongs.

> **Caveat on decomposition quality (see §8 R1):** an LLM's decomposition is non-deterministic. The
> skill should require Hermes to state its subtask plan before executing, so a bad plan is visible
> and correctable rather than discovered after 20 device round-trips.

---

## 8. Unresolved questions and risks

| # | Risk | Why it matters | Mitigation |
|---|---|---|---|
| **R1** | **LLM decomposition is non-deterministic** | Routing becomes irreproducible; a bad split wastes minutes of device time | Require an explicit plan before execution; keep subtasks small; measure the first real multi-subtask task |
| **R2** | **Contract staleness** | Hermes acting on a stale contract causes wasted round-trips | Query at decision time; never cache in the skill; treat refusal as normal |
| **R3** | **No Mac executor** | Hermes has nowhere to send what the Pixel refuses | Out of scope here. Hermes may execute subtasks itself (it is an LLM with tools) — this needs an explicit decision |
| **R4** | **Phase 7 / Phase 9 overlap** | This redefines Phase 7 into something adjacent to Phase 9 | Needs an ADR-007 amendment (see §9) |
| **R5** | **Context size is only in native code** | Hermes cannot plan prompt budgets without it | Publish it in the contract |
| **R6** | **Performance evidence has no owner** | Numbers exist in Phase 6/7 logs but nothing maintains them | Define who records timings and how staleness is marked |
| **R7** | **Thermal remains unattributable** | Cannot inform any decision | State the limitation; do not build on it |
| **R8** | **Sustained-load behaviour unknown** | Many small subtasks = sustained load, which Phase 6 never tested | Measure before promising multi-subtask throughput |
| **R9** | **`shell()` exposure to Hermes** | ADR-009 requires a separate review before exposing raw `shell()` upward | **Keep `shell()` unexposed.** Hermes uses named operations only |

**R9 is the one with a security dimension and it is already covered by an existing decision** — the
architecture overview states raw `shell()` "must not be exposed to the UI (Phase 8) or Hermes
(Phase 9) without a separate review." That review is **not** part of Phase 7.

---

## 9. Recommended next implementation sequence (not implemented)

**Step 0 — Resolve the naming, via an ADR-007 amendment.**
Rename the phase's *purpose*, not its number: **"Phase 7 — Pixel Capability Contract & Hermes
Workload Planning."** Record that the master prompt §16 line "resource-aware workload routing" is
satisfied by routing being owned by Hermes — which §1's diagram mandates — and that this supersedes
the PixelDesktop-internal router in ADR-013.

**Step 1 — Publish the capability contract.** A single read-only query returning static capability +
dynamic state + latest measured evidence (with timestamps). Extend `DeviceManager` /
`DeviceCapabilities`; add the missing context size. **Gate: real-device read; no new subsystem.**

**Step 2 — Publish measured performance evidence.** Record timings from actual results (they already
flow back in `InferenceResult`). Mark provenance and staleness explicitly. **Gate: evidence comes
from real runs, never constants.**

**Step 3 — Harden the refusal path.** Confirm every refusal is bounded, machine-readable, and
**non-retryable by contract**. This is mostly verification of existing behaviour.
**Gate: every `error_type` exercised.**

**Step 4 — Write the `pixel-compute` skill.** No hardcoded device/model/perf values.
**Gate: the skill contains no number that could go stale.**

**Step 5 — Prove it end-to-end with one real decomposed task** — a task large enough to need 3+
Pixel subtasks. **Gate: measured total time, and an honest report of whether decomposition helped.**

**Step 6 — Regression** — full 194-test suite.

**Explicitly not in this plan:** a router, a Mac executor, retries, a scheduler, a queue,
multi-device support, `shell()` exposure, or GPU/larger-model work.

**A recommendation on ordering:** **Step 1 before Step 4.** The skill must be written against a
contract that exists, or it will hardcode values — which is the exact failure mode §4.4 warns about.

---

## Provenance

**Established (repository):** master prompt §1 (orchestration is a Mac responsibility), §3, §9, §16;
§5.2; ADR-007, ADR-009, ADR-010, ADR-011, ADR-012, ADR-013; Phase 6 implementation; Phase 7
reconnaissance; existing component surfaces, verified by reading source.

**Measured:** Phase 6 and Phase 7 reconnaissance measurements, as cited in §4.3. No new measurement
was taken for this document.

**Hypothesis:** that Hermes-owned decomposition improves outcomes (§8 R1 — untested).

**Proposed:** §3 boundary; §4 contract; §6 removals; §7 skill; §9 sequence.

**Unresolved:** §8, of which **R1 and R4 are the most consequential**.

---

## Device and repository state

- Repository **clean** at `bdfe784`. **No production source modified.**
- Nothing downloaded or installed.
- No router, Mac executor, or new component created.

---

```text
PHASE 7 ARCHITECTURE RE-EVALUATION COMPLETE / IMPLEMENTATION BLOCKED PENDING REVIEW
```

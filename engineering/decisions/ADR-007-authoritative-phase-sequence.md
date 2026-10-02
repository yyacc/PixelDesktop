# ADR-007: The Master Engineering Prompt Defines the Authoritative Phase Sequence

## Status

Accepted

## Date

2026-10-01

## Context

PixelDesktop's documentation contains **four different documents that each number phases**,
and they disagree. During Phase 2 close-out this produced a real ambiguity: a request to
"proceed to Phase 3" could have meant any of four unrelated bodies of work, depending on
which document the reader treated as authoritative.

The ambiguity was not documented anywhere. A search of the engineering documentation for
any note about phase numbering returned **zero hits**. This ADR resolves it and records
why it arose.

## Problem

Which phase sequence governs the PixelDesktop product, and how should the other numbering
schemes be interpreted?

## Evidence — the four numbering schemes

### Scheme 1 — Master engineering prompt (§16 "PHASE STRUCTURE")

**11 phases, Phase 0–10.** Each phase has a stated objective. This is the document that
commissioned the project and the one that defines what PixelDesktop *is*.

| Phase | Title |
|---|---|
| 0 | Project Definition |
| 1 | Engineering Foundation |
| 2 | Device Discovery and ADB Transport |
| 3 | Android Device Model |
| 4 | Android Application / Process Control |
| 5 | Pixel Compute Worker |
| 6 | Local AI Worker |
| 7 | Resource-Aware Workload Routing † |
| 8 | PixelDesktop UX |
| 9 | Hermes Integration |
| 10 | Production Hardening |

### Scheme 2 — `phase-00-clean-start-audit.md` §9 "MULTICA PHASE STRUCTURE"

**8 phases, Phase 0–8.** Corroborates Scheme 1 at Phases 0–3, then diverges:

| Audit phase | Title | Master prompt equivalent |
|---|---|---|
| 0 | Clean-start audit + project definition | 0 ✅ |
| 1 | Engineering foundation | 1 ✅ |
| 2 | Device discovery + ADB transport | 2 ✅ |
| 3 | Android device model | 3 ✅ |
| 4 | **DTCA-1 worker APK** | **5** (Pixel Compute Worker) |
| 5 | **DTCA-1 verification** | **5** |
| 6 | **PixelDesktop UX** | **8** |
| 7 | **Hermes integration** | **9** |
| 8 | **Production hardening** | **10** |
| — | *missing* | 4 (Android Application / Process Control) |
| — | *missing* | 6 (Local AI Worker) |
| — | *missing* | 7 (Resource-Aware Workload Routing) |

The audit's table omits three master-prompt phases and assigns Phase 4 to work the master
prompt places at Phase 5. **It is stale.** It was written during Phase 0, before the phase
structure was reconciled with the master prompt.

### Scheme 3 — `pixel-compute-node-course-of-action.md` (46 KB, legacy)

**7 phases, Phase 0–6**, tracking **workload maturity**, not product milestones:

| Legacy phase | Title | Master prompt equivalent |
|---|---|---|
| 0 | Requirements and Workload Definition | 0 |
| 1 | Compute Proof | 5 |
| 2 | Minimal Real Worker | 5 |
| 3 | **Communication Boundary** | 4 / 5 |
| 4 | Worker Lifecycle and Verification | 5 + 10 |
| 5 | Resource Awareness | 7 † |
| 6 | Hermes Integration | 9 |

### Scheme 4 — coding-agent documents (legacy)

`coding-agent-candidate-evaluation.md` (Phase 3 = "Multica Integration") and
`local-coding-agent-formulation.md` (Phase 3 = "Install Plan") number a third axis:
**the tooling used to build PixelDesktop**, not PixelDesktop itself.

## Why the numbering diverged

Three unrelated axes were each numbered independently from their own Phase 0, and nothing
reconciled them:

1. **Product axis** — what PixelDesktop is. Master prompt, 11 phases.
2. **Compute-workload axis** — how mature the Pixel compute proof is. Course-of-action,
   7 phases. Its Phase 1 (Compute Proof) is authoritative Phase 5, because it begins at
   workload definition and measures the worker, not the app.
3. **Agent-tooling axis** — how the AI builds the project. Coding-agent docs. Orthogonal
   to the product; its "Phase 3" has no product equivalent at all.

The Phase 0 audit catalogued the legacy documents by *content quality* (§1.2) but never
flagged that they carry incompatible phase numbering. That omission is the root cause of
the ambiguity.

## Decision

1. **The master engineering prompt §16 is the authoritative PixelDesktop product phase
   sequence.** All phase references in current and future work use Schemes 1's numbering.
2. **The Phase 0 audit §9 table is superseded** where it conflicts with the master prompt.
   It is annotated, not rewritten — it is historical Phase 0 evidence.
3. **Legacy documents retain their original numbering.** They are preserved unmodified.
   Their phases must **not** be interpreted as PixelDesktop product phases.
4. **Legacy phase references must be translated** through the mapping tables above before
   being used to plan product work.
5. New engineering documentation references phases by the authoritative number **and**
   title, e.g. "Phase 4 (Android Application / Process Control)", so an ambiguous bare
   number cannot recur.

## Reasoning

The master prompt is authoritative because it is the commissioning document, it is the
only source with complete per-phase objectives, and §17 makes its completion gate binding.
The audit is a Phase 0 artifact whose §9 table was a proposal made before reconciliation;
it is corroborating at Phases 0–3 and wrong thereafter. The legacy documents are
engineering evidence about a *different* problem (the compute workload and the coding
toolchain), so renumbering them would destroy their internal consistency and their value
as historical evidence.

Preserving legacy numbering while translating references is the only option that keeps
both documents truthful.

## Consequences

- "Phase 3" unambiguously means **Android Device Model** in this project.
- The audit's §9 table now carries a supersession banner; readers reaching it directly
  cannot be misled.
- Legacy documents remain internally consistent and unmodified.
- Phase 2's deferred work has an unambiguous destination: `shell()` and lifecycle →
  Phase 4; `push()`/`pull()` → Phase 5. Under the stale audit table these would have
  landed in the wrong phase.
- Documentation must be updated whenever a phase is referenced by bare number.

## Rejected Alternatives

- **Adopt the audit's 8-phase scheme** — omits Phases 6 and 7 entirely and misplaces
  Phase 4. It cannot express the full roadmap.
- **Renumber the legacy documents to match** — destroys their historical accuracy and
  their internal cross-references. The workflow forbids erasing history.
- **Adopt the course-of-action scheme** — it measures workload maturity, not product
  milestones, and has no equivalent for Phases 8 or 10.
- **Leave the ambiguity undocumented** — this is what caused the Phase 2 close-out
  ambiguity. Recorded here so it cannot recur.

## Future Reconsideration Conditions

- Revisit if the master prompt is formally amended. Any amendment must state its
  effective date and supersede this ADR explicitly.
- Revisit if a future phase genuinely requires a sub-phase scheme (e.g. "Phase 5a").
  Prefer explicit sub-phase naming over renumbering.
- Revisit if legacy documents are ever promoted to authoritative status; they would then
  need reconciliation rather than translation.

---

# AMENDMENT 1 — Phase 7 Redefined: Hermes Owns Planning; PixelDesktop Enforces

**Status:** Accepted
**Date:** 2026-10-02
**Effective:** 2026-10-02
**Amends:** Decision item 1 and the Phase 7 row of Scheme 1
**Supersedes:** `ADR-013` (Resource-Aware Workload Routing), withdrawn before implementation at
commit `e339691`
**Authority for this amendment:** this ADR's own *Future Reconsideration Conditions* —
"Revisit if the master prompt is formally amended. **Any amendment must state its effective date
and supersede this ADR explicitly.**"

**Nothing above this line has been rewritten.** The original Phase 7 row is preserved and now
carries a `†` marker pointing here. History is annotated, not erased — the same convention this
ADR applied to the Phase 0 audit §9 table.

---

## A1.1 Why the original Phase 7 concept was withdrawn

Master prompt §16 names Phase 7 "Resource-Aware Workload Routing" and says routing "may eventually"
consider workload type, model requirements, memory, CPU, GPU, latency, thermal state, availability,
energy and task size.

Phase 7 reconnaissance interpreted that as requiring a decision component **inside PixelDesktop**,
and `ADR-013` proposed a `FeasibilityEvaluator` that would decide Mac-vs-Pixel locally.

**That was withdrawn, because it contradicted the master prompt itself.**

Master prompt **§1** states the long-term goal as:

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

Orchestration is placed **above** PixelDesktop, not inside it. §1 also lists "resource-aware
workload routing" among future concerns **without locating it inside PixelDesktop**, and §9 assigns
Hermes the tasks of understanding capabilities, creating workloads, monitoring them and receiving
results.

**A router inside PixelDesktop therefore placed a decision-making component on the wrong side of a
boundary the master prompt had already drawn, and duplicated a decision Hermes already owns.**

Two further pieces of evidence made it unnecessary:

1. **Reconnaissance §B: "there is only one executor."** Phase 6 deliberately ensured the Mac does
   not link llama.cpp (`ADR-012` §P7), so a router could only ever choose the Pixel. A decision
   component with one possible answer is not a decision component.
2. **Reconnaissance §H judged cost-comparison routing "blocked by evidence"** — no Mac executor
   exists to compare against, and Pixel latency varies **2.4×** for identical work.

### Recorded as a process lesson

The reconnaissance surfaced the correct question — §N asked "whether routing is worth it at all"
and suggested the honest frame was a *specialised node*, not load balancing — and a router was
proposed anyway, because the Phase 7 brief's candidate structure listed one.

> **When the evidence says "no component", propose no component.**

Recorded in `engineering/best-practices/techniques.md` as **T-021**, with the decision/enforcement
distinction recorded as **T-022**.

---

## A1.2 The governing architecture boundary

```text
USER
 │
 ▼
HERMES ────────── orchestration, planning, decomposition, placement, synthesis
 │
 │  consumes: the Pixel capability contract
 │  issues:   approved workload requests
 ▼
PIXELDESKTOP ──── the Pixel compute interface
 │
 │  owns: device access, validation, enforcement, execution, evidence, results
 ▼
PIXEL 7a ──────── compute node
```

**Hermes decides. PixelDesktop enforces.**

This is the single sentence the whole amendment exists to establish, and every clause below is a
consequence of it.

---

## A1.3 Hermes as the orchestration and planning authority

Hermes owns:

- workload understanding
- task decomposition
- subtask planning
- understanding Pixel capabilities
- deciding which subtasks should go to Pixel
- coordinating results
- deciding what to do when Pixel cannot handle a subtask

This is consistent with §1 (orchestration and complex reasoning on the Mac), §3 (Hermes is the AI
architect and decision layer), and §9 (Hermes understands capabilities, creates workloads, monitors
them, receives results, and uses the Pixel as a specialised worker).

**No separate traffic controller, scheduler, `FeasibilityEvaluator`, `ExecutionNode` abstraction, or
Mac executor exists inside PixelDesktop for this phase.**

---

## A1.4 PixelDesktop as the authoritative execution and enforcement boundary

PixelDesktop owns:

- exposing Pixel capability information through a **stable contract**
- validating incoming workloads
- **enforcing actual capability limits**
- refusing unsupported or invalid workloads
- executing approved workloads
- returning structured results and errors
- reporting relevant measured runtime and resource information

PixelDesktop does **not** own task decomposition, placement, or planning. It must not become a
second autonomous planner or a general-purpose task router.

---

## A1.5 Why LLM decision-making does not remove the need for PixelDesktop-side validation

Hermes is an LLM. Its reasoning is probabilistic, its context may be stale, and it cannot observe
the device directly.

Three independent reasons PixelDesktop-side validation must remain authoritative:

1. **Hermes cannot observe the device.** It has no ADB access, no `/proc`, and no way to see
   whether the worker is installed, the model present, or memory available. It knows only what it
   was last told.
2. **Capability is not a property of the plan.** A subtask may be well-decomposed and still
   unrunnable — because the model file is missing, the device is disconnected, or memory is
   insufficient at that instant.
3. **`ADR-012` §P7: a snapshot is not a reservation.** `MemAvailable` moved 2.15 → 2.40 GiB during
   reconnaissance as ordinary apps foregrounded. Any belief Hermes holds about available memory is
   stale by the time it acts.

**Therefore Hermes's capability knowledge is an optimisation input, never an execution authority.**

---

## A1.6 Stale or incorrect Hermes knowledge must cost a round trip, never safety

**This is the clause that makes LLM-owned planning safe.**

| If Hermes believes… | …and the truth is | Outcome |
|---|---|---|
| workload supported | not supported | **request refused**, bounded `error_type`, Hermes re-plans |
| model present | model missing | **refused** (`MODEL_MISSING`) |
| memory sufficient | insufficient | **refused** |
| device connected | disconnected | **refused** |
| stale performance figure | different reality | worse plan, **never unsafe execution** |

**A stale or mistaken Hermes belief results only in a rejected request and an extra round trip. It
can never result in unsafe execution**, because PixelDesktop refuses anything it cannot actually
run — regardless of what Hermes asserts.

This preserves the D8 and Phase 6 containment model **completely unchanged**. Containment rests on
fixed paths, approved capabilities, bounded payloads, regular-file validation, and the launcher-UID
check — none of which depend on the caller's intent or knowledge.

**The decision/enforcement split is recorded as technique T-022.**

---

## A1.7 The new purpose of Phase 7

> **Publish Pixel's capabilities and measured execution evidence to Hermes, and establish the
> execution boundary required for Hermes to perform capability-aware workload decomposition.**

Phase 7 is therefore **not** "Resource-Aware Workload Routing" in the sense of a PixelDesktop-internal
router. Routing — in the sense of deciding where work runs — is **owned by Hermes**, which master
prompt §1 mandates.

Phase 7 delivers the **inputs** to that decision and the **boundary** that makes it safe:

| Phase 7 delivers | Why Hermes needs it |
|---|---|
| A stable capability contract | so it can plan without hardcoding |
| Measured execution evidence, with provenance and staleness | so its plans reflect reality, not a constant |
| An enforcement boundary that refuses invalid work | so its beliefs can be wrong safely |

**Note on scope:** reconnaissance established the contract is **~80% already implemented** —
`ModelContract` supplies the model name, SHA-256 and size; `InferenceRuntimeIdentity` supplies
runtime, version and backend; `DeviceCapabilities` supplies supported ABIs; `InferenceResult`
already returns timings and the model hash. **Only context size is genuinely missing** (it exists
solely in `llama_jni.cpp` as `kContextSize`). Phase 7 is largely *publishing existing state*.

---

## A1.8 Components explicitly removed from Phase 7

Each is withdrawn. None is to be implemented.

| Component | Reason for removal |
|---|---|
| `FeasibilityEvaluator` | Wrong layer (§1). Its validation half already exists as `InferenceRequest.validate()` plus worker dispatch |
| `WorkloadDescriptor` | Duplicates the existing job envelope; a parallel type would be a second workload model |
| `Decision { target, reasons[] }` | Target selection is Hermes's. *(The refusal reason is retained — PixelDesktop already returns bounded `error_type` codes)* |
| `ResourceSnapshot` as a routing input | Repurposed: it becomes the dynamic-state section of the capability contract — an observation **for Hermes**, not an input to a local decision |
| `Executors` / `ExecutionNode` abstraction | One executor exists. §5.2 forbids premature multi-device management |
| Mac executor | Out of scope; §1 places complex reasoning on the Mac anyway. **Must not be created** |
| Internal PixelDesktop router or scheduler | The subject of this amendment |
| Retry / backoff / circuit breaker | Deterministic failures cannot be retried into success; each attempt costs 16–26 s of sustained device load |

---

## A1.9 Components and evidence retained

Retained from `ADR-013`. The ADR is **SUPERSEDED but preserved** — its reconnaissance measurements
remain valid and are reused.

**Principles retained:**

| Principle | Why it survives |
|---|---|
| **Approved-capabilities-only** | A routing or planning decision selects among existing validated operations; it never constructs a command, path or shell string. This preserves containment |
| **Support / non-support / unknown** | The honest three-state capability vocabulary. The 3B–4B class stays **UNKNOWN** — falsified as an assumption in Phase 6, never promoted back to a target |
| **Fail and report** | No silent recovery |
| **No automatic retries** | Deterministic failures are not improved by repetition |
| **A snapshot is not a reservation** | §P7, and the basis of A1.5 and A1.6 |

**Measurements retained, with their limitations:**

| Measurement | Value | Limitation |
|---|---|---|
| Decode rate | **~0.97–1.46 tok/s** | single model, single device |
| Prompt eval | 5.25–7.27 s per 27–32 tokens | — |
| **Latency variance** | **2.4×** for identical 8-token work (5,084 ms warm vs 14,793 ms after idle) | **latency cannot be a planning constant** |
| **Model-load variance** | **12×** (393 ms → 4,954 ms) | page-cache dependent, not a constant |
| Peak process memory | 1,279 MB | one model; provisional |
| ADB round-trip | 226 ms | USB |
| Payload size | ~600 bytes | transfer is not a cost |
| Model transfer | 1.04 GiB in 30.79 s | one-time |

**The variance evidence is the most important thing retained.** It is why published performance
figures must carry provenance and a timestamp, and why the future Hermes skill must **read** the
contract rather than hardcode values.

---

## A1.10 Relationship to Phase 9 (Hermes Integration)

**This amendment clarifies the boundary. It does not implement Hermes integration.**

| | Phase 7 (this phase) | Phase 9 |
|---|---|---|
| Question | *What must PixelDesktop expose, and what boundary must exist?* | *How does Hermes actually consume it?* |
| Delivers | capability contract, measured evidence, enforcement boundary | the integration itself |
| Status | not implemented | not started |

Phase 7 must be complete **before** Phase 9 begins: Phase 9 cannot integrate against a contract that
does not exist.

Master prompt §9 requires that Hermes integration "do not compromise the clean architecture" and
that interfaces be explicit. This amendment defines that interface's **shape**; Phase 9 builds the
connection.

---

## A1.11 R4 — the Phase 7 / Phase 9 boundary, documented explicitly

**Risk R4 from the Phase 7 re-evaluation:** redefining Phase 7 brings it adjacent to Phase 9, with a
risk of scope bleed in either direction.

**Resolution — the boundary is the *direction of information*:**

| Phase 7 (publish outward) | Phase 9 (consume inward) |
|---|---|
| PixelDesktop **exposes** capability and evidence | Hermes **reads** it |
| PixelDesktop **enforces** feasibility | Hermes **plans** against it |
| The contract is defined and made stable | The contract is used |
| No Hermes-side code | Hermes skill and integration |

**Concrete non-overlap rules:**
- Phase 7 does **not** write the Hermes skill. (That was Step 4 of the re-evaluation sequence — a
  later step, after the contract exists.)
- Phase 7 does **not** add Hermes-facing tooling, plugins, or MCP surfaces.
- Phase 7 does **not** require Hermes to be running.
- Phase 9 does **not** redefine the contract's contents; if it needs a change, that change is a
  Phase 7 revision.

---

## A1.12 R9 — `shell()` remains inaccessible to Hermes

**Risk R9 from the Phase 7 re-evaluation.**

`ADR-009` established that `shell()` is a general-purpose escape hatch, lives only on
`TransportProtocol`, and that raw `shell()` **must not be exposed to the UI (Phase 8) or Hermes
(Phase 9) without a separate review.**

The architecture overview already states this. This amendment **reaffirms** it:

- **`shell()` is not exposed to Hermes.**
- Exposing it is **not Phase 7 work** and **not Phase 9 work by default** — it requires its own
  separate review and its own decision.
- Hermes uses **named operations only**. The approved-capabilities-only principle (A1.9) is what
  makes this enforceable rather than merely intended.

---

## A1.13 Consequences

- "Phase 7" now unambiguously means **Pixel Capability Contract & Hermes Workload Planning**.
  Bare "Phase 7" must be read with this amendment.
- `ADR-013` remains on disk, marked SUPERSEDED, its measurements intact and cited here.
- The router proposal is preserved as historical reasoning, including *why* it was wrong.
- Phase 8 (UX) and Phase 9 (Hermes Integration) are unchanged.
- Any document describing a PixelDesktop-internal router must be corrected to reference this
  amendment.

## A1.14 Rejected alternatives for this amendment

- **Renumber Phase 7 to something else** — the master prompt's numbering is authoritative and its
  §16 list is not renumberable by this project. Redefining the *purpose* while keeping the *number*
  preserves every existing reference.
- **Delete `ADR-013`** — forbidden. It contains valid measurements and the reasoning that produced
  the correction. Erasing it would make the same mistake possible again.
- **Rewrite the original Phase 7 row in place** — would erase the fact that the definition changed.
  Annotated with `†` and preserved, matching this ADR's own treatment of the Phase 0 audit.
- **Implement the contract in the same change** — out of scope for Step 0, and it would mix an
  architectural decision with an implementation.
- **Leave the router in place as a "small" component** — the size was never the objection. It was
  the wrong layer.

## A1.15 Future reconsideration conditions for this amendment

- **If a Mac executor is ever built** → revisit whether placement needs any PixelDesktop-side
  support. It still would not, under §1, but the assumption should be re-tested rather than assumed.
- **If a second Pixel or another node is added** → revisit whether Hermes can plan across nodes
  using per-node contracts, or whether a minimal node abstraction is justified. §5.2 still applies.
- **If measured performance stabilises** (variance materially reduced) → reconsider whether
  performance figures may be published as tighter bounds rather than as dated observations.
- **If the master prompt is formally amended** → this amendment must be revisited explicitly, per
  the same rule that authorised it.


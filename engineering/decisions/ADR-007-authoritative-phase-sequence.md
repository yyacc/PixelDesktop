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
| 7 | Resource-Aware Workload Routing |
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
| 5 | Resource Awareness | 7 |
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

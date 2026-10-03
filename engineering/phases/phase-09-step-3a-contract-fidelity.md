# Phase 9 Step 3A — Contract Fidelity Reconnaissance, and Phase 7 Amendment 2

**Status:** COMPLETE — defect found, correction implemented, 390 tests green.
**Date:** 2026-10-03
**Discovered by:** Phase 9 Step 3 (execution boundary reconnaissance).
**Corrected as:** **Phase 7 Amendment 2** — because ADR-007 §A1.11 assigns contract changes to
Phase 7, not Phase 9.
**Baseline:** 372 tests, 0 failures, 15 skipped @ `ca766b4`
**Final:** 390 tests, 0 failures, 15 skipped

---

## What was found

While reconnoitring the execution boundary, the contract's published input bound was compared
against the validator of the workload proposed for first execution.

```
contract.limits.maximumPromptCharacters = 4096      ← InferenceRequest (the LLM runtime)
DTCA1Worker.validateInput accepts       = 10000     ← DTCA-1 (phase-05 spec: "max 10,000 characters")
```

`DTCA-1` is the workload the project intends to expose first: it is deterministic, needs no model,
and its result can be independently recomputed on the Mac. **The contract understated its input
capacity by more than half.**

## Why it mattered

Not a safety defect — PixelDesktop validated every request regardless, so a planner acting on the
wrong bound would have been refused nothing and endangered nothing. It was a **planning** defect:
the field exists *"so a planner can respect them rather than discover them by refusal"*, and for
DTCA-1 it did the opposite.

## What the field actually is

Established from three independent sources rather than inferred: its declaration site
(`InferenceRequest` — *"a single bounded generation request"*), the contract's own provenance table
(`phase-07-step-1-capability-contract.md`), and the contract's own doc comment. All three agree:
**it is the LLM runtime's request limit**, never a workload-wide bound.

## The correction (Phase 7 Amendment 2)

Each bound moved to the workload that owns it:

```swift
Workload.maximumInputCharacters: CapabilityValue<Int>?   // NEW
```

| Workload | Bound | Owner |
|---|---|---|
| `DTCA-1` | 10,000 | `DTCA1Worker.maximumInputCharacters` (new named constant) |
| `LOCAL-LLM-1` | 4,096 | `InferenceRequest.maximumPromptCharacters` |

- `RequestLimits.maximumPromptCharacters` **kept its meaning**; its `limitation` now states its scope.
- The DTCA-1 validator's bare `10_000` literal became a named constant, so the published value and
  the enforced value are **the same symbol** — divergence is now a compile error, not a silent drift.
- `contractVersion` **1 → 2**.
- No workload's real behaviour changed. DTCA-1 still accepts 10,000; the LLM still accepts 4,096.

## Options rejected

Redefining `maximumPromptCharacters` (falsifies its documented derivation and an existing test) ·
changing DTCA-1's validator to 4,096 (falsifies the specification to make the contract pass) ·
letting a future execution command accept 10,000 quietly (makes the CLI the authority over the
contract) · hardcoding the bound into the Hermes skill · a general constraint structure (ADR-013
already withdrew `WorkloadDescriptor` with *"do not add a parallel type"*).

## Tests

**390 tests, 0 failures, 15 skipped** (from 372). New: 17 in `Phase7Amendment2Tests.swift`, 3
black-box CLI tests in `Phase9CLITests.swift`.

The derivation tests assert the published value **equals its owner**, so a change to either
validator fails the suite rather than letting the contract drift. One test asserts the boundary
behaviour directly — 10,000 accepted, 10,001 rejected — which is what "derived from the validator"
has to mean in practice, not merely that two constants share a name.

**One pre-existing test required correction, and the evidence was inspected first.**
`testContractIsIndependentOfTheUIAndOfHermes` hardcoded `contractVersion == 1` — a literal
duplicating `currentVersion`, and not a guarantee about the behaviour the test names ("the contract
is independent of the UI and of Hermes"). It now derives from `currentVersion`. The version's
*value* is asserted separately in `testContractCarriesItsVersion`. **No test was weakened, skipped,
or deleted**, and every existing assertion on `limits` still passes unchanged.

## Phase boundary

- **Phase 9 Step 3A** discovered the defect.
- The correction is **Phase 7 Amendment 2**, because ADR-007 explicitly assigns contract changes
  to Phase 7.
- **Phase 9 remains the consumer/integration phase.**
- **This amendment does not authorise execution.** No `run` command was added; Phase 9 Step 4 has
  not started.

## Files changed

**Production:** `PixelDesktop/Inference/PixelCapabilityContract.swift`,
`PixelDesktop/Compute/DTCA1Worker.swift`.
**Tests:** `PixelDesktopTests/Phase7Amendment2Tests.swift` (new),
`PixelDesktopTests/Phase7CapabilityContractTests.swift`, `PixelDesktopTests/Phase9CLITests.swift`.
**Docs:** `engineering/decisions/ADR-007-authoritative-phase-sequence.md` (Amendment 2),
this file, README, journal, created-resources.
**Skill:** `pixel-compute/SKILL.md` + `references/envelope-fields.md`.

```text
PHASE 9 STEP 3A COMPLETE / CONTRACT CORRECTED AS PHASE 7 AMENDMENT 2 / PHASE 9 STEP 4 NOT STARTED
```

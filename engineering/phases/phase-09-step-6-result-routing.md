# Phase 9 Step 6 — Route InferenceResult Through the CLI Boundary

**Status:** COMPLETE

**Date:** 2026-10-03

**Authorization:** User-authorized via explicit message granting Phase 9 Step 6 scope.

---

## Phase objective

Route the already-existing `InferenceResult` type through the CLI boundary so that when the worker emits LOCAL-LLM-1's success token (`"OK"`), the CLI decodes the LOCAL-LLM-1 result shape (text, token_ids, generated_tokens, execution evidence) and publishes it — without executing LOCAL-LLM-1, provisioning a model, or adding a second workload to the `run` command.

## Requirements

When complete:

1. The CLI can decode the LOCAL-LLM-1 `InferenceResult` shape, including `text`, `token_ids`, `generated_tokens`, and existing execution evidence fields.
2. The decoded result is published through `CLIRunResult.inferenceOutput` without losing generation result or execution evidence.
3. DTCA-1 behavior and its existing `WorkerResultEnvelope` path remain unchanged.
4. No LOCAL-LLM-1 execution/provisioning/model transfer is introduced.
5. No raw ADB/shell/transport primitives are exposed to Hermes.

## Starting state

- `InferenceResult` already existed at `InferenceRuntime.swift` with full `CodingKeys` and `isUsableGeneration`.
- The CLI decoded all results as `WorkerResultEnvelope` (DTCA-1-shaped).
- Amendment 3 had made the success token workload-owned — `DTCA1Job.successResultToken = "COMPLETED"`, `InferenceResult.successResultToken = "OK"`.
- `CLIRunResult` had a single `output: DTCA1Result?` field.
- Phase 9 Steps 1–4 and Amendment 3 were complete at 442 tests, 0 failures.

## Investigation

- `InferenceResult` was already designed for LOCAL-LLM-1: it has `.ok` status, `CodingKeys` for all wire fields (`text`, `token_ids`, `generated_tokens`, `prompt_tokens`, timing fields, `model_file`, `model_sha256`, `runtime`, etc.), and `isUsableGeneration`.
- `CLIRunCommand.decodeResult(from:jobId:expectedSuccessToken:)` was the single decode boundary. It decoded as `WorkerResultEnvelope` only.
- `WorkerResultEnvelope` has no LLM fields (text, token_ids, etc.) — so even if it decoded a LOCAL-LLM-1 result, the generation output and evidence would be silently discarded.
- `CLIRunResult` had no field to carry an `InferenceResult`.

## Architecture

The result routing preserves the existing boundary. `decodeResult` now performs an ordered decode:

1. Decode as `WorkerResultEnvelope` (works for both shapes because they share `status` and `job_id` wire keys).
2. If `expectedSuccessToken == InferenceResult.successResultToken` (`"OK"`) **and** the payload decodes as `InferenceResult` with status `.ok`, route to `inferenceOutput`.
3. Otherwise, fall through to the existing `WorkerResultEnvelope` path — `isCompleted(expectedSuccessToken:)` comparison and `asDTCA1Result(expectedSuccessToken:)`.

`CLIRunResult` gained `inferenceOutput: InferenceResult?` alongside the existing `output: DTCA1Result?`. Exactly one is present at a time, selected by the success token.

## Alternatives considered

| Option | Verdict |
|---|---|
| New CLI command for LOCAL-LLM-1 | Rejected — violates "no second workload to `run`" and "no new command" constraints. |
| Separate DTO | Rejected — `InferenceResult` already exists and matches the wire contract. |
| Extend `WorkerResultEnvelope` with LLM fields | Rejected — couples the two result shapes and would require conditional fields on the DTCA-1 type. |
| Token-driven routing (chosen) | Selected — minimal, reuses `InferenceResult`, preserves DTCA-1 path unchanged. |

## Decision

Route `InferenceResult` through the existing `decodeResult` boundary, gated by the workload-owned success token. The `InferenceResult` is decoded only when `expectedSuccessToken == "OK"` and the payload itself has status `.ok`.

## Reason

Amendment 3 made the success token workload-owned, but the CLI only honored the DTCA-1 shape. The result type already exists; the gap is purely the routing decision at the decode boundary.

## Implementation

### `PixelDesktopCLI/CLIRunResult.swift`

- Added `inferenceOutput: InferenceResult?` field.
- Updated `init` to carry `inferenceOutput` through to the published result.
- Updated the doc comment on `output` to clarify it is present only for DTCA-1's `"COMPLETED"` token.

### `PixelDesktopCLI/CLIRunCommand.swift`

- `DecodedResult` struct gained `inferenceOutput: InferenceResult?`.
- `decodeResult` now attempts `InferenceResult` decode when `expectedSuccessToken == InferenceResult.successResultToken`.
- DTCA-1 path (`WorkerResultEnvelope` decode, `isCompleted`, `asDTCA1Result`) is unchanged.
- `run` method passes `decoded.inferenceOutput` to `CLIRunResult.init`.

### `PixelDesktopTests/Phase9Step6Tests.swift` (new)

12 tests covering:

1. Successful `InferenceResult` decoding with all fields.
2. Generation fields preserved (text, token_ids, generated_tokens, prompt_tokens).
3. Execution evidence preserved (timings, runtime, model metadata).
4. Malformed result with empty text — `isUsableGeneration` returns false.
5. Invalid JSON rejected with `verificationFailed`.
6. Foreign job ID rejected with `verificationFailed`.
7. DTCA-1 result still decodes unchanged.
8. DTCA-1 FAILED envelope still produces a refusal.
9. Success-token routing: `"OK"` → `InferenceResult`, `"COMPLETED"` → `DTCA1Result`.
10. `CLIRunResult` publishes `inferenceOutput`.
11. `InferenceResult` Codable round-trip.
12. `InferenceResult` wire keys (snake_case).

## Experiments

No experiments were run against hardware. Step 6 is a decode/routing boundary and requires no device.

## Failures

- Initial attempt to decode `InferenceResult` before `WorkerResultEnvelope` referenced `envelope.refusal` before `envelope` was declared. Fixed by reordering: decode `WorkerResultEnvelope` first, then attempt `InferenceResult` decode.
- `WorkerStreamOutcome.completed` requires labeled parameters `(resultJSON:, resultBytes:)`, not a tuple. Fixed in test fixture.
- `WorkerStreamRunner.Run` field order is `outcome, jobId, workerPidObserved, heartbeatCount, timeToFirstEventSeconds, timeToLaunchAckSeconds, timeToOutcomeSeconds, wallSeconds, stderrLines, unrecognizedLines, streamEndedUnexpectedly`. Fixed in test.
- `XCTAssertThrowsError` requires `try` before the throwing expression.
- PBXBuildFile and PBXFileReference must have distinct 24-hex IDs. Fixed by using `...0002` for the BuildFile.

## Diagnosis

All compilation errors were in the test file and the initial decode ordering. No architectural issues.

## Corrections

- Reordered `decodeResult` so `WorkerResultEnvelope` decode precedes `InferenceResult` decode.
- Fixed test file fixtures and initializer calls to match actual Swift signatures.

## Tests

### Focused (Phase 9 Step 6)

```
Test Suite 'Phase9Step6Tests' passed
    Executed 12 tests, with 0 failures (0 unexpected) in 0.009 seconds
```

All 12 tests pass.

### Full suite

```
Test Suite 'All tests' passed
    Executed 454 tests, with 20 skipped, 0 failures (0 unexpected) in 16.380 seconds
** TEST SUCCEEDED **
```

454 total (442 prior + 12 new), 0 failures.

### git diff --check

Passed — no whitespace or diff errors.

## Regression tests

Full suite rerun: 454 passed, 20 skipped, 0 failures.

## Final architecture

```
CLIRunCommand.decodeResult
    │
    ├── decode as WorkerResultEnvelope (shared keys for both shapes)
    │
    ├── if expectedSuccessToken == "OK":
    │       try decode as InferenceResult with status .ok
    │       → if successful: DecodedResult(inferenceOutput: result)
    │
    └── fall through to WorkerResultEnvelope path (unchanged)
        isCompleted(expectedSuccessToken:) → asDTCA1Result(expectedSuccessToken:)

CLIRunResult
    ├── output: DTCA1Result?           (DTCA-1 payload, "COMPLETED")
    ├── inferenceOutput: InferenceResult?  (LOCAL-LLM-1 payload, "OK")
    └── evidence: CLIRunEvidence        (shared, for both)
```

## Lessons learned

- **Decode order matters when shapes overlap.** `InferenceResult` and `WorkerResultEnvelope` share wire keys (`status`, `job_id`). Decoding the envelope first, then conditionally attempting the specialized type, is cleaner than branching before the common decode.
- **PBXBuildFile IDs must differ from PBXFileReference IDs.** Using the same ID for both causes `xcodebuild` to fail with "Unable to read project". Always increment the last hex digit.
- **Swift labeled parameters are strict.** `WorkerStreamOutcome.completed(resultJSON:resultBytes:)` and `WorkerStreamRunner.Run` field order must match exactly — there is no tolerance for reordering.

## What worked well

- Reusing the existing `InferenceResult` type avoided a new DTO and kept the change to 3 files (2 production, 1 test).
- The Amendment 3 token-driven approach (`expectedSuccessToken`) made the routing decision a one-line comparison.
- Writing all 12 tests upfront caught the fixture/signature mismatches immediately.

## What did not work

- Attempting `InferenceResult` decode before `WorkerResultEnvelope` decode referenced an undeclared `envelope` variable.
- Using identical 24-hex IDs for PBXBuildFile and PBXFileReference.
- Omitting `try` before `CLIRunCommand.decodeResult` in `XCTAssertThrowsError`.

## Best technique discovered

**Decode the shared envelope first, then branch on the workload-owned success token.** This avoids conditional decode paths and keeps the common `status`/`job_id` validation in one place.

## Future recommendations

- When LOCAL-LLM-1 execution is authorized (Phase 9 Step 7+), the `expectedSuccessToken` will come from `Workload.successResultToken` via the contract, not a string literal. The routing logic in `decodeResult` is already token-driven, so no further changes will be needed here.
- Consider a dedicated test fixture builder for `WorkerStreamRunner.Run` to avoid the fragility of its 11-parameter initializer in tests.

## Final status

```
PHASE 9 STEP 6: COMPLETE

Requirements: PASS
Build: PASS
Focused tests: PASS (12/12)
Full test suite: PASS (454 passed, 20 skipped, 0 failures)
Regression: PASS
git diff --check: PASS
Architecture review: PASS
Documentation: UPDATED
DTCA-1 unchanged: CONFIRMED
LOCAL-LLM-1 execution NOT introduced: CONFIRMED
No raw primitives exposed: CONFIRMED
```

## Files changed

### Production

- `PixelDesktopCLI/CLIRunCommand.swift` — `DecodedResult` gained `inferenceOutput`; `decodeResult` routes by success token; `run` passes result through.
- `PixelDesktopCLI/CLIRunResult.swift` — `inferenceOutput: InferenceResult?` field added; `init` updated.

### Test

- `PixelDesktopTests/Phase9Step6Tests.swift` — **new**; 12 tests.

### Project config

- `PixelDesktop.xcodeproj/project.pbxproj` — registered `Phase9Step6Tests.swift` in the test target (PBXBuildFile + PBXFileReference + group + Sources build phase).

### Documentation

- `engineering/phases/phase-09-step-6-result-routing.md` — **this file**.

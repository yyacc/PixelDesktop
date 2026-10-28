# Phase 9 Step 7 — LOCAL-LLM-1 Execution Through the CLI Boundary

## Phase objective

Expose `LOCAL-LLM-1` execution through the existing `pixel-desktop run` CLI command, building the request from the existing `InferenceRequest` type, executing through the existing E1 `WorkerStreamRunner` path, and publishing the decoded `InferenceResult` through `CLIRunResult.inferenceOutput`.

## Requirements

When the phase is complete:
1. `pixel-desktop run --workload LOCAL-LLM-1 --input-file <path> --json` executes a real LLM inference on the Pixel 7a.
2. The result is decoded as `InferenceResult` and published through `CLIRunResult.inferenceOutput`.
3. The `InferenceResult` contains `text`, `token_ids`, `generated_tokens`, and execution/evidence fields.
4. DTCA-1 behavior and its `WorkerResultEnvelope` path remain unchanged.
5. Invalid prompts are rejected locally before any device I/O.

## Starting state

- Phase 9 Steps 1–6 complete (Phase 6: `InferenceResult` type; Amendment 3: workload-owned success tokens).
- `InferenceRequest` exists with full `CodingKeys` and `validate()` (`InferenceRuntime.swift`).
- `decodeResult` routes `InferenceResult` when `expectedSuccessToken == "OK"` (Step 6).
- `CLIRunResult` has `inferenceOutput: InferenceResult?`.
- LOCAL-LLM-1 is implemented on the Android worker (`LlmWorkload.java`) but NOT exposed through the CLI.
- The CLI `run` command accepts only `DTCA-1` (`supportedWorkload`).
- Model `qwen2.5-1.5b-instruct-q4_k_m.gguf` provisioned on device.

## Investigation

Inspected:
- `PixelDesktopCLI/CLIRunCommand.swift` — `run` command boundary, `decodeResult`, `loadInput`.
- `PixelDesktop/Inference/InferenceRuntime.swift` — `InferenceRequest`, `InferenceResult`, `InferenceRuntimeIdentity`.
- `PixelDesktop/Worker/DTCA1Job.swift` — existing job pattern: `workloadName`, `successResultToken`, `encoded()`, `newJobId()`.
- `PixelDesktop/Worker/WorkerStreamRunner.swift` — E1 streaming path.
- `PixelDesktopCLI/CLIRunResult.swift` — result DTO with `inferenceOutput` field.
- `PixelDesktop/Verification/ResultVerifier.swift` — DTCA-1-only verification.
- `DTCA1Worker/app/src/main/java/com/pixeldesktop/worker/LlmWorkload.java` — Android worker's LOCAL-LLM-1 execution.
- `DTCA1Worker/app/src/main/cpp/llama_jni.cpp` — native runtime info format.

## Architecture

Added `LlmJob` (`PixelDesktop/Worker/LlmJob.swift`) following the same envelope pattern as `DTCA1Job`:
- `workloadName = "LOCAL-LLM-1"` — the only workload the worker accepts for this job type.
- `successResultToken = "OK"` — owned by this workload, not assumed by the decode boundary.
- `encoded()` — delegates to `InferenceRequest`'s Codable, then adds the `workload` field the worker uses for routing.
- `newJobId()` — generates a UUID for anti-staleness checking (D9).

Modified `CLIRunCommand.run` to branch on workload:
- `DTCA-1` → `DTCA1Job`, unchanged path.
- `LOCAL-LLM-1` → `LlmJob`, builds `InferenceRequest` with defaults (`max_tokens=32`, `temperature=0.0`, `seed=0`), routes through existing E1 path with `expectedSuccessToken: "OK"`.

Modified `LlmJob.encoded()` to add the `workload` field to the job JSON, which `WorkerActivity.java` requires to route to the correct executor. Without this field, the worker rejects with "unsupported workload: ''".

Modified `InferenceRuntimeIdentity` to accept both the legacy string form (`"llama.cpp a868c3e backend=cpu"`) that the Android worker emits via `nativeRuntimeInfo()`, and the structured object form that `Codable` synthesis would normally expect. This avoids requiring an Android worker change.

## Alternatives considered

1. **Create a separate `LlmJobRequest` type.** Rejected: `InferenceRequest` already owns its `CodingKeys` and `validate()`. Duplicating it would create a second definition that can drift (D8 lesson).
2. **Change the Android worker to emit structured runtime info.** Rejected: the "no Android worker changes" constraint. A Mac-side decoder that accepts both forms is more tolerant of worker versions.
3. **Add `LOCAL-LLM-1` as a second `supportedWorkload`.** Rejected: this would expose the workload before the CLI `run` plumbing was ready. The implementation adds it as `supportedWorkloads` (set) while keeping the same `run` command and `--workload` flag.

## Decision

Chose option 3 — add `LOCAL-LLM-1` to `supportedWorkloads`, create `LlmJob` following the `DTCA1Job` pattern, reuse the existing E1 streaming path, and decode through the Step 6 boundary.

## Reason

The Android worker already executes LOCAL-LLM-1. The only missing piece is the Mac-side CLI boundary. All decode/routing infrastructure was already built in Step 6 (`decodeResult` with `"OK"` token routing, `CLIRunResult.inferenceOutput`). This is the smallest correct change.

## Implementation

### Files changed

1. **`PixelDesktop/Worker/LlmJob.swift`** (new) — Job type for LOCAL-LLM-1, analogous to `DTCA1Job`.
2. **`PixelDesktopCLI/CLIRunCommand.swift`** — Accept `LOCAL-LLM-1` in `supportedWorkloads`; add prompt-file input handling for LOCAL-LLM-1; build `InferenceRequest`; route through E1; pass `expectedSuccessToken: "OK"` to `decodeResult`.
3. **`PixelDesktopCLI/CLIInvocation.swift`** — Updated usage text to reflect `LOCAL-LLM-1` support.
4. **`PixelDesktop/Inference/InferenceRuntime.swift`** — Added custom `init(from:)` and `encode(to:)` to `InferenceRuntimeIdentity` to accept both legacy string form and structured object form.
5. **`PixelDesktopTests/Phase9Step7Tests.swift`** (new) — 12 focused tests.
6. **`PixelDesktopTests/Phase9RunTests.swift`** — Updated workload name in refusal test (LOCAL-LLM-1 is now supported, so "UNSUPPORTED-WORKLOAD" is used instead).
7. **`PixelDesktop.xcodeproj/project.pbxproj`** — Registered `LlmJob.swift` and `Phase9Step7Tests.swift`.

### Approach

The workflow followed the established engineering loop:
- **Observe:** Confirmed Pixel 7a connected, model present, all Step 6 prerequisites complete.
- **Reproduce:** First execution attempt returned "unsupported workload: ''" — the `LlmJob.encoded()` payload lacked the `workload` field.
- **Gather evidence:** Inspected `LlmWorkload.java` — `WorkerActivity` reads `workload` from the job JSON to route to the correct executor.
- **Identify layer:** Mac-side job encoding, not worker or transport.
- **Form hypothesis:** Adding `workload` to the encoded JSON would fix the routing.
- **Test hypothesis:** Verified by executing on real device.
- **Implement fix:** Updated `LlmJob.encoded()` to include `workload` field.
- **Verify:** Second execution returned a valid `InferenceResult` with all expected fields.
- **Regression test:** Full suite passes.
- **Document:** This file.

## Experiments

### Experiment 1: Missing `workload` field in encoded JSON

**Attempt:** Initial `LlmJob.encoded()` encoded `InferenceRequest` directly without adding the `workload` field.

**Observed behavior:** Worker returned `INVALID_INPUT: unsupported workload: ''`.

**Evidence:** `WorkerActivity.java` reads `job.optString("workload", "")` to route to the correct executor. An empty workload string means no executor matches.

**Diagnosis:** The `InferenceRequest` type does not include a `workload` field — it is a job-envelope concern that belongs to `LlmJob`, not the request payload. The `LlmJob.encoded()` method must add it.

**Correction:** Updated `LlmJob.encoded()` to encode the `InferenceRequest`, then add the `workload` field via `JSONSerialization`.

**Result:** Worker accepted and executed the job.

### Experiment 2: `runtime` field decode failure

**Attempt:** First execution after Experiment 1 fix produced error "Worker result is missing required DTCA-1 fields".

**Evidence:** The worker's `LlamaBridge.nativeRuntimeInfo()` returns a plain string `"llama.cpp a868c3e backend=cpu"`, but `InferenceRuntimeIdentity` was `Codable` with no custom `init(from:)`, so it expected a JSON object `{"name":..., "version":..., "backend":...}`. The `InferenceResult` decode failed, causing `decodeResult` to fall through to the `WorkerResultEnvelope` path, which failed on missing DTCA-1 fields.

**Diagnosis:** The `InferenceRuntimeIdentity` type's auto-synthesized `init(from:)` could not decode the worker's string form, making `InferenceResult` decode fail silently (via `try?`).

**Correction:** Added a custom `init(from:)` to `InferenceRuntimeIdentity` that accepts both the legacy string form and the structured object form. No Android worker changes required.

**Result:** Worker result decoded successfully as `InferenceResult` with correctly parsed runtime info.

## Failures

| # | Failure | Root cause | Fix |
|---|---|---|---|
| 1 | "unsupported workload: ''" | `LlmJob.encoded()` omitted the `workload` field the worker uses for routing | Added `workload` to the encoded JSON in `LlmJob.encoded()` |
| 2 | "Worker result is missing required DTCA-1 fields" | `InferenceRuntimeIdentity` auto-synthesized `init(from:)` couldn't decode the worker's string-form runtime info, causing `InferenceResult` decode to fail | Added custom `init(from:)` accepting both string and object forms |

## Diagnosis

Both failures were Mac-side boundary issues, not worker or transport issues. The worker was producing the correct result shape; the Mac-side decode path was too rigid to accept it. This is consistent with the D12 lesson: "the boundary that adapts is on the Mac side — the worker contract is fixed."

## Tests

- **`Phase9Step7Tests.swift`** (12 tests): supported workload check, `InferenceRequest` defaults, encoded wire keys, empty prompt rejection, prompt-too-long rejection, invalid max_tokens rejection, max_tokens-too-large rejection, non-greedy temperature rejection, successful result routing, DTCA-1 regression, refusal handling, `CLIRunResult` publishing.
- **`Phase9RunTests.swift`**: Updated unsupported workload test to use `"UNSUPPORTED-WORKLOAD"` (LOCAL-LLM-1 is now supported).
- **Full suite**: 468 tests, 20 skipped, 0 failures.

## Results

### Focused Step 7 tests
- 12/12 passed.

### Full test suite
- 468 passed, 20 skipped, 0 failures.

### `git diff --check`
- PASS (no whitespace errors).

### Real-device verification

Pixel 7a (serial `DEADBEEF000000`) connected via USB. Model `qwen2.5-1.5b-instruct-q4_k_m.gguf` (1,117,320,736 bytes) present at `/sdcard/Android/data/com.pixeldesktop.worker/files/model/`.

**Execution:**
```
echo "What is the capital of France?" > /tmp/llm_prompt.txt
pixel-desktop run --workload LOCAL-LLM-1 --input-file /tmp/llm_prompt.txt --json
```

**Result:**
```json
{
  "ok": true,
  "result": {
    "workload": "LOCAL-LLM-1",
    "outcome": "completed",
    "jobId": "29D5591A-4D8D-4289-988D-A88E48F0C4F7",
    "inferenceOutput": {
      "status": "OK",
      "text": "The capital of France is Paris.",
      "token_ids": [785, 6722, 315, 9625, 374, 12095, 13],
      "generated_tokens": 7,
      "prompt_tokens": 26,
      "model_load_ms": 427,
      "prompt_eval_ms": 4669,
      "generation_ms": 11582,
      "total_ms": 16686,
      "runtime": {
        "name": "llama.cpp",
        "version": "a868c3e",
        "backend": "cpu"
      },
      "model_file": "qwen2.5-1.5b-instruct-q4_k_m.gguf",
      "model_sha256": "6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e",
      "context_size_tokens": 2048,
      "trained_context_size_tokens": 32768
    },
    "evidence": {
      "workerPidObserved": 22552,
      "heartbeatCount": 42,
      "timeToFirstEventSeconds": 0.064,
      "timeToLaunchAckSeconds": 0.204,
      "timeToOutcomeSeconds": 23.570,
      "wallSeconds": 23.795
    }
  }
}
```

### Acceptance criteria verification

| # | Criterion | Status |
|---|---|---|
| 1 | CLI accepts LOCAL-LLM-1 | PASS — `supportedWorkloads` includes it |
| 2 | Decoded as `InferenceResult` | PASS — verified real device output |
| 3 | `InferenceResult` has generation fields | PASS — `text`, `token_ids`, `generated_tokens`, evidence fields all present |
| 4 | DTCA-1 unchanged | PASS — full suite includes DTCA-1 tests, all pass |
| 5 | Invalid prompts rejected before device I/O | PASS — `InferenceRequest.validate()` rejects empty/too-long prompts |
| 6 | `max_tokens` rejected if <= 0 | PASS — `InferenceRequestError.invalidMaxTokens` |
| 7 | `max_tokens` rejected if > 256 | PASS — `InferenceRequestError.maxTokensTooLarge` |
| 8 | `temperature` rejected if != 0 | PASS — `InferenceRequestError.nonGreedyRequested` |
| 9 | `OK` result becomes `InferenceResult` | PASS — `decodeResult` routes by token |
| 10 | Generated text survives CLI boundary | PASS — `text` field present in output |
| 11 | Execution evidence survives | PASS — all timing/memory fields present |
| 12 | Refusal remains refusal | PASS — `testRefusalRemainsRefusal` |
| 13 | Encoded JSON has `job_id`, `prompt`, `max_tokens`, `temperature`, `seed` | PASS — `testEncodedJobWireKeys` |
| 14 | No model provisioning | PASS — model pre-existing, not provisioned |
| 15 | No ADB/shell primitives exposed | PASS — E1 streaming path only |

## Final architecture

```
User → Hermes → Multica → PixelDesktop CLI (run --workload LOCAL-LLM-1)
                    ↓
              WorkerStreamRunner (E1)
                    ↓
              Pixel 7a worker (LlmWorkload → LlmWorkload.execute)
                    ↓
              Result → decodeResult → InferenceResult
                    ↓
              CLIRunResult.inferenceOutput
```

The CLI boundary gains one workload case while reusing everything else. DTCA-1's path is structurally unchanged.

## Lessons learned

1. **The `workload` field is a job-envelope concern, not a request payload concern.** `InferenceRequest` defines the generation parameters; `LlmJob` adds the envelope (`workload`, `job_id`). This matches `DTCA1Job`'s split. (Technique: keep the job envelope thin and let the payload type own its own fields.)

2. **The Android worker emits runtime info as a string, not a structured object.** `LlamaBridge.nativeRuntimeInfo()` returns `"llama.cpp a868c3e backend=cpu"`, which broke the auto-synthesized `Codable` init. Supporting both string and object forms in the decoder avoids forcing an Android-side change. (Technique: tolerate legacy wire forms on the Mac-side boundary.)

3. **The worker is the source of truth for routing.** `WorkerActivity.java` reads `workload` from the job JSON. Without it, the job is silently routed to no executor. The job encoder must include it. (Technique: verify the complete encoded payload against the worker's parsing before claiming execution works.)

## What worked well

- The Step 6 `decodeResult` routing for `"OK"` token required no changes — it worked immediately once the encoding issue was fixed.
- The `InferenceRequest.validate()` method caught invalid prompts without device I/O, as designed.
- The E1 streaming path (`WorkerStreamRunner`) handled LOCAL-LLM-1 execution identically to DTCA-1, confirming the abstraction.

## What did not work

- Initial `LlmJob.encoded()` omitted the `workload` field. This was a structural oversight in the envelope design, not a fundamental issue.

## Future recommendations

1. **Centralize the job-envelope pattern.** `LlmJob` and `DTCA1Job` now share the same shape (workload name, success token, encoded(), newJobId()). If more workloads are added, extract a common protocol.
2. **Add `--max-tokens` and `--temperature` CLI flags.** Phase 7 defers model provisioning as a separate operation; similarly, prompt overrides should be a separate step. But the infrastructure now supports it trivially.
3. **Verify the `runtime` string parser against future llama.cpp version formats.** The current parser assumes `"name version backend=value"`. If the format changes, the fallback path (everything as name) is safe but lossy.

## Out-of-scope items

- Model provisioning/transfer (Phase 6 prerequisite, not Step 7).
- Android worker changes (no changes to `LlmWorkload.java` or `LlamaBridge`).
- Hermes skill changes (the `pixel-compute` skill already supports this path).
- Multica integration (not required for Step 7).
- No new CLI command (`run` extended, not added).
- No capability contract changes (contract already publishes LOCAL-LLM-1).

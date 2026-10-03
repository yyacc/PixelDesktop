# Phase 9 Step 5 — Reconnaissance: the next capability

**Status:** RECON COMPLETE. **No production code modified.**
**Date:** 2026-10-03
**HEAD at recon:** `ee6269674c2631e4ba12cabc8dacd7447cdb7f26`
**Verdict:** the next useful step is **not** LOCAL-LLM-1 execution. Three prerequisites must be
resolved first, two of which are defects in the current interface.

---

## Executive finding

Extending `run` to `LOCAL-LLM-1` is blocked by **three concrete defects**, none of which is
"the workload is unimplemented". The Android worker already dispatches and executes
`LOCAL-LLM-1`; the Phase 6 proof is on record. What is missing is the *boundary*:

1. **No Swift encoder produces the LOCAL-LLM-1 job wire shape.** `InferenceRequest` has no
   `CodingKeys`, so its synthesized encoding emits `jobId`, `prompt`, `maxTokens`,
   `temperature`, `seed` — but the worker reads `job_id`, `prompt`, `max_tokens`,
   `temperature`, `seed`. **`max_tokens` would be absent**, the worker would silently default to
   32 generated tokens, and the Mac would have no way to know it had not got what it asked for.
2. **The result decoders disagree on the status token.** DTCA-1 emits `"COMPLETED"`; LOCAL-LLM-1
   emits `"OK"`. `WorkerResultEnvelope.isCompleted` requires `"COMPLETED"`, so **a successful
   LLM inference would be reported as a refusal.**
3. **The result payload would be discarded.** `WorkerResultEnvelope` has no `text`, `token_ids`,
   `model_load_ms`, `prompt_eval_ms`, `generation_ms`, `total_ms`, `vm_peak_kb`, or `vm_rss_kb`
   fields. Even decoding successfully, the CLI would publish a result with **no generated text
   and no execution evidence** — the exact opposite of "structured result + evidence".

Defect 2 is the dangerous one: it fails **toward a false refusal**, not a false success. But
defect 3 would make the feature useless, and defect 1 would make it silently wrong.

Additionally, **the Phase 7 evidence types are written but unused**: `PixelExecutionEvidence` and
`PerformanceObservation` are constructed only inside `PixelEvidence.swift` itself and exercised
only by tests. Nothing in the production path calls them. So "improving Hermes' evidence
consumption" is not a matter of exposing something that exists — it is a matter of *wiring
something that does not yet run*.

## What Hermes can currently know

| | |
|---|---|
| Static capability | contract v2 — runtime identity, expected model artifact (name, sha256, byte count), request limits, per-workload input bounds, verifiability |
| Dynamic state | reachability, memory, storage, worker installed/running, model present, thermal (system-wide) |
| Execution | DTCA-1 only: outcome token, decoded payload, stream evidence (pid, heartbeats, timings) |

## What Hermes can currently request

Exactly one workload, one bounded text input, no device/transport/path selection. Everything else
is rejected by name.

## What PixelDesktop can currently execute

Both workloads. `WorkerActivity` dispatches `DTCA-1` → `Dtca1.execute` and `LOCAL-LLM-1` →
`LlmWorkload.execute`. The Android side is **not** the gap.

## Proven on hardware vs architecturally present

| Capability | Status |
|---|---|
| DTCA-1 via CLI `run` | **Proven** (Phase 9 Step 4, 2026-10-03) |
| LOCAL-LLM-1 on the worker | **Proven** (Phase 6), but **not through the CLI** |
| `PixelExecutionEvidence` / `PerformanceObservation` | **Written, never used in production** |
| Model provisioning | **Contract written** (`ModelContract`, `validateLocalArtifact`, `verifyTransfer`) — no caller |
| Model transfer | **No path** — `WorkerTransferContract.maximumPayloadBytes` is 1 MB; the model is 1.04 GiB |

## Candidate next steps

### 1. Extend execution to LOCAL-LLM-1

**For:** the workload exists and is proven; it is the only other published workload; it is what
makes the Pixel useful as an AI worker rather than a word counter.
**Against:** three defects above must be fixed first; it needs a 1.04 GiB provisioning path that
does not exist; and it is **not exactly verifiable** (`exactlyVerifiable: false`), so the Mac
cannot check the answer — only an evidence chain.
**Blocker:** defects 1–3, plus provisioning.

### 2. Add another deterministic workload

**For:** cheap, exactly verifiable, reuses the proven DTCA-1 pattern end to end.
**Against:** **no evidence any second deterministic workload is wanted.** Inventing one to have
something to do is the "propose a component because the brief listed one" failure ADR-013 was
retracted for. There is no user need on record.

### 3. Improve Hermes' capability/evidence consumption

**For:** `PixelExecutionEvidence`/`PerformanceObservation` exist and are unused; the skill could
carry more of the reasoning.
**Against:** **nothing to consume yet.** There is one workload with a small payload. The gap is
not the consumer — it is that the producer never runs.

### 4. Model provisioning as an explicit operation

**For:** it is the genuine prerequisite for anything LLM; the contract is already written
(fixed path, fixed filename, sha256, byte count, 2 GiB ceiling); the local artifact **is present**
at `models/qwen2.5-1.5b-instruct-q4_k_m.gguf` (1,117,320,736 bytes, matching
`ModelContract.expectedByteCount`).
**Against:** it is a large, slow, device-state-changing operation (1.04 GiB), and it is a
prerequisite rather than a capability — provisioning alone produces nothing Hermes can *use*.
**Blocker:** none technical. `WorkerTransferContract.maximumPayloadBytes` (1 MB) governs job
payloads, not model transfer; `ModelContract.maximumModelBytes` (2 GiB) governs the model. The
transfer primitives (`push`) exist and take validated absolute paths.

### 5. Another option supported by evidence

**The three defects.** They are not a "capability" but they are what the evidence actually points
at, and two of them are latent correctness bugs in code that already ships.

## The blocker that matters most

**Defect 2 is a latent bug today, not only an LLM blocker.** `WorkerResultEnvelope.refusal` maps
any non-`COMPLETED` status to a refusal. If any future workload or worker revision emits a
different success token, the Mac reports a refusal for a successful run. The current code is
correct **only because** DTCA-1 happens to emit `"COMPLETED"` and it is the only workload the CLI
accepts. That coupling is undocumented and untested.

## Recommendation

**Recommended next step: Phase 9 Step 5 — close the two interface defects that make the result
boundary workload-specific, and prove it with a second workload shape.**

Rationale, in the project's own terms: the boundary was built for one workload and is
**accidentally** correct. Before adding a second workload — whichever it is — the two places where
it hardcodes DTCA-1's shape must be made explicit. That is smaller than provisioning, it is
exactly verifiable, it requires no hardware beyond a connected Pixel, and it removes a latent bug.

Concretely, the work is:

1. **Make the success token workload-owned**, not a hardcoded `"COMPLETED"` comparison — with the
   vocabulary published in the contract so a consumer can read it. This is the same correction
   Phase 7 Amendment 2 made for input bounds, applied to status.
2. **Add a Swift encoder for `InferenceRequest`** with explicit `CodingKeys` matching the worker's
   wire contract, so a request cannot silently lose `max_tokens`.
3. **Decide the result-shape question before it is needed**: `WorkerResultEnvelope` is
   DTCA-1-shaped. Either extend it with the LLM fields or introduce a workload-keyed result union —
   and record which, because it is an architecture decision, not a detail.

**Then, and only then**, LOCAL-LLM-1 execution becomes a small change: one workload case, one
encoder, one decoder, plus the provisioning path as a **separate explicit operation** (candidate 4)
because a 1.04 GiB device-state change must not be a side effect of `run`.

## Proposed implementation boundary (if approved)

- `WorkerResultEnvelope` / a successor gains a workload-aware success token and optional
  LLM payload fields, sourced from the worker's own emitted keys.
- `InferenceRequest` gains explicit `CodingKeys`; a test asserts the encoded JSON **equals the
  wire contract the worker parses**.
- The contract publishes the success-token vocabulary per workload.
- No new CLI command. No new transport. No provisioning. `run` still accepts one workload.
- Tests: round-trip encoding against the wire contract; a simulated `"OK"` result decoded as
  success; a simulated `"COMPLETED"` result decoded as success; an unknown token refused; every
  existing DTCA-1 assertion unchanged.

## Required tests

Encode/decode round-trips against the worker's actual key names; success-token handling per
workload; unknown-token refusal; `max_tokens` present in the encoded job; existing 421-test
regression unchanged.

## Hardware requirements

**A connected Pixel is not required for the fix** (it is encoding/decoding plus contract text), but
**is required to verify** the round trip against the real worker. The device was attached for
Step 4 and is **currently disconnected** — `adb devices -l` is empty at recon time.

## Contract impact

**Yes — a contract change would be required**, to publish the per-workload success token. That is a
**Phase 7 revision** under ADR-007 §A1.11, exactly as Amendment 2 was, not Phase 9 redefining the
contract. It should be raised as **Amendment 3** and authorised explicitly.

## Out of scope

LOCAL-LLM-1 execution · model provisioning or transfer · any second workload's implementation ·
retries · queues · scheduling · multi-device · HTTP/MCP/sockets/daemon · Android permissions ·
arbitrary shell or ADB · device/path/activity selection by Hermes · `shell()` exposure · any change
to DTCA-1's behaviour · P-Bantad NHS.

## Files and commits inspected

`PixelCapabilityContract.swift` · `InferenceRuntime.swift` · `ModelProvisioning.swift` ·
`WorkerTransferContract.swift` · `WorkerStreamRunner.swift` · `WorkerStreamProtocol.swift` ·
`DTCA1Job.swift` · `CLIRunCommand.swift` · `CLIRunResult.swift` · `WorkerActivity.java` ·
`LlmWorkload.java` · `Dtca1.java` · `PixelEvidence.swift` · Phase 9 Steps 1–4 records ·
ADR-007 (+Amendments 1, 2) · ADR-010 · ADR-012 · `pixel-compute` skill ·
commits `ee62696` `ac73787` `c6d1cd4` `ca766b4`.

## Final authorization status

**NEXT IMPLEMENTATION STEP: AWAITING USER AUTHORIZATION**

No code was modified. No contract change was made. LOCAL-LLM-1 was not implemented, no model was
provisioned or transferred, and no device state was changed.


---

# ADDENDUM — Amendment 3 Scope Correction (read-only inventory)

**Date:** 2026-10-03 · **HEAD:** `ee62696` · **No production code changed.**

This addendum corrects two gaps in the reconnaissance above. It was prompted by the discovery that
`ResultVerifier.swift:17` also hardcodes the success token — a site the original recon missed.

## A. Complete `"COMPLETED"` inventory, classified

| # | Site | Class | Action |
|---|---|---|---|
| 1 | `PixelDesktop/Worker/DTCA1Job.swift:93` `isCompleted { status == "COMPLETED" }` | **1 — generic boundary** | must become workload-owned |
| 2 | `PixelDesktop/Verification/ResultVerifier.swift:17-18` `!= "COMPLETED"` + message | **1 — generic boundary** | must become workload-owned |
| 3 | `PixelDesktop/Worker/DTCA1Job.swift:68` comment | **4 — comment** | update wording |
| 4 | `PixelDesktop/Compute/DTCA1Worker.swift:164` `status: "COMPLETED"` | **2 — legitimate DTCA-1 emission** | unchanged |
| 5 | `DTCA1Worker/.../Dtca1.java:231` `result.put("status","COMPLETED")` | **2 — legitimate DTCA-1 emission** | unchanged |
| 6 | `PixelDesktopCLI/CLIRunResult.swift:48` comment | **4 — comment** | update wording |
| 7 | `PixelDesktopTests/Phase9RunTests.swift:259` fixture `"status":"COMPLETED"` | **3 — fixture** | keep; add an `"OK"` case |
| 8 | `PixelDesktopTests/PixelDesktopTests.swift:102,119,163,190,1933,1941,2238,2308,2310` | **3 — fixtures/assertions** | DTCA-1-specific; keep |
| 9 | `PixelDesktopTests/Phase9HardwareVerificationTests.swift:76,169,170` | **3 — hardware assertions** | DTCA-1-specific; keep |
| 10 | `engineering/**` prose (journal, phase logs) | **4 — documentation** | historical record; do not rewrite |

**Two generic sites, not one.** The recon named only #1.

## B. The E1 stream layer is clean

`WorkerStreamRunner` / `WorkerStreamReducer` / `WorkerStreamScript` do **not** inspect the status
token at all — they operate on stream framing, durability, and ownership. The coupling is confined
to the two decode-boundary sites. **No E1 change is required.**

## C. Second finding — `LOCAL-LLM-1` is not unrepresented

The original recon implied LOCAL-LLM-1 had no Swift result type. **That was wrong.** An
`InferenceResult` **already exists** at `InferenceRuntime.swift:108`, with:

- `enum Status: String { case ok = "OK"; case failed = "FAILED" }`
- a full `CodingKeys` mapping to the worker's exact keys (`text`, `token_ids`, `generated_tokens`,
  `prompt_tokens`, `model_load_ms`, `prompt_eval_ms`, `generation_ms`, `total_ms`, `model_file`,
  `model_sha256`, `context_size_tokens`, `trained_context_size_tokens`)
- `isUsableGeneration { status == .ok && !text.isEmpty }`

So the **result shape for LOCAL-LLM-1 already exists and already encodes the `"OK"` token
correctly**. What is missing is only that nothing *routes* it — the CLI decodes everything as
`WorkerResultEnvelope`.

**Consequence:** the "result-shape problem" is smaller than the recon claimed, and does **not**
require a new DTO.

## D. The wire vocabulary — success is workload-owned, failure is generic

| Token | Owner | Evidence |
|---|---|---|
| `"COMPLETED"` | DTCA-1 | `Dtca1.java:231` |
| `"OK"` | LOCAL-LLM-1 | `LlmWorkload.java:145` |
| `"FAILED"` | **the Activity, for every workload** | `WorkerActivity.java:195` |

Failures are written by `WorkerActivity` for all workloads with `error_type` / `error_message`.
The failure token is therefore **genuinely generic** and must **not** be made workload-owned.
Only the *success* token is workload-owned. The amendment must state this asymmetry.

## E. Reassessment — does Amendment 3 remain minimal?

**Yes, and it is smaller than first proposed.**

- `ResultVerifier` can consume the workload-owned token **without a second source of truth**: its
  `verify` signature gains the expected token as a parameter, supplied by the caller from the
  contract. `ResultVerifier` holds no workload knowledge of its own today and must not gain any.
- The success token **does belong on `Workload`**, exactly as proposed — it is a property of the
  workload's own worker, on the same footing as `maximumInputCharacters` (Amendment 2).
- **No additional contract field is required.**
- **The result-shape work must be split out of Amendment 3.** Amendment 3 covers success semantics
  and the request wire contract. Routing `InferenceResult` through the boundary is separate work —
  and per finding C, it is smaller than assumed. It does **not** need to be "Amendment 4" in the
  sense of a large change; it should be its own authorised step, decided on its own evidence.

## F. Revised scope

**Production (3 files):**
1. `PixelCapabilityContract.swift` — add `Workload.successResultToken: CapabilityValue<String>`,
   derive per workload from its own worker's constant, bump `currentVersion` 2 → 3.
2. `DTCA1Job.swift` — `isCompleted` → workload-aware; remove the hardcoded comparison.
3. `ResultVerifier.swift` — take the expected token as a parameter.

**Tests:** new `Phase7Amendment3Tests.swift` (naming follows `Phase7Amendment2Tests`), plus
`Phase7Amendment2Tests.swift:58` and `Phase9CLITests.swift:363` version assertions updated 2 → 3.
Add an `"OK"` fixture case. Keep every DTCA-1 assertion.

**Explicitly out of scope:** routing `InferenceResult`, model provisioning, `run` accepting a
second workload.

```text
SCOPE CORRECTION: COMPLETE — 2 generic sites (not 1), 0 E1 changes,
InferenceResult already exists, failure token is generic and stays generic.
```

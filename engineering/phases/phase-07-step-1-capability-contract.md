# Phase 7 Step 1 — The Pixel Capability Contract

**Status:** COMPLETE. **Step 2 not started.**
**Date:** 2026-10-02
**Phase:** 7 (Pixel Capability Contract & Hermes Workload Planning) — per **ADR-007 Amendment 1**
**Depends on:** Step 0 (`aeb3404`) — ADR-007 Amendment 1
**Supersedes:** nothing. `ADR-013` remains SUPERSEDED.

---

## What the capability contract is

A small, versioned, machine-readable description of **what the Pixel compute node can actually
support**, published by PixelDesktop so that Hermes can plan against the Pixel without hardcoding
facts about it.

It exists because of the architectural boundary established in **ADR-007 Amendment 1**:

> **Hermes decides. PixelDesktop enforces.**

Hermes owns decomposition and placement. PixelDesktop owns execution and enforcement. For Hermes to
plan, it needs to know what the node can do — and that knowledge must come from an interface, not
from a prompt that says *"the Pixel has X GB"*.

### What it is NOT

| Not | Why |
|---|---|
| A security boundary | It is **informational planning input**. PixelDesktop independently validates every actual request before execution, regardless of what the contract said |
| A router | Routing is Hermes's, per §1 of the master prompt |
| A planner | Decomposition is Hermes's |
| A resource manager | No scheduling, no reservation, no allocation |
| A measurement store | It publishes *what the build supports*, not *how fast it runs* |

**A stale or wrong value in this contract costs a rejected request and an extra round trip — never
unsafe execution.** (ADR-007 Amendment 1 §A1.6.)

---

## What it exposes, and where each field comes from

Every field is **derived from an existing authoritative definition**, never restated. The type is
constructed *from* those sources, so a change to one propagates.

| Field | Source of truth | Provenance |
|---|---|---|
| `device.codename / marketingName / manufacturer / androidVersion / apiLevel / architecture / supportedABIs` | `AndroidDevice` (Phases 2–3) | `.deviceReported` |
| `runtime.name / version / backend` | `InferenceRuntimeIdentity`, `LlamaCppRuntime` | `.declared` |
| `runtime.modelFormat` | `GGUF` — the format the runtime consumes | `.declared` |
| `model.fileName / sha256 / byteCount` | `ModelContract` | `.declared` |
| `model.contextSizeTokens` | **the native runtime** (`kContextSize`, read back via `llama_n_ctx`) | `.runtimeReported` when observed, `.declared` as fallback |
| `model.trainedContextSizeTokens` | the runtime's `n_ctx_train` | `.runtimeReported` |
| `limits.maximumPromptCharacters / maximumTokensCeiling` | `InferenceRequest` | `.declared` |
| `limits.maximumModelBytes` | `ModelContract` | `.declared` |
| `workloads[].name / requiresModel / requiresRuntime` | the worker's dispatch + adapters | `.declared` |
| `workloads[].exactlyVerifiable` | `DTCA-1` deterministic; `LOCAL-LLM-1` not (ADR-012 §P7) | `.declared` |

**No new capability subsystem was created.** The contract reads from what already existed.

---

## Static vs measured

| Kind | In the contract? | Rationale |
|---|---|---|
| **Static capability** | ✅ yes | Changes only on redeploy — worker, runtime, or model. This is what a contract is for |
| **Dynamic state** (device connected, model present, memory free) | ❌ **deliberately not** | Changes per invocation. It belongs in an **observation**, not a contract |
| **Measured performance** (tok/s, load time, latency) | ❌ **deliberately not** | See below |

### Why no performance numbers

Phase 7 reconnaissance measured:

- **2.4× generation-time variance** for identical 8-token work (5,084 ms warm vs 14,793 ms after idle)
- **12× model-load variance** (393 ms → 4,954 ms)
- and, in Step 1, **820 prompt tokens taking 5.1 minutes**

Publishing *"the Pixel does ~1 token/sec"* as a capability would present an **unstable observation as
a constant** — a fabrication of precision. A consumer would plan against a number that is wrong
roughly half the time.

**Performance evidence belongs in a separate, timestamped evidence channel (Step 2) where its
provenance and staleness are explicit.** A unit test asserts the contract contains no performance
field.

---

## Provenance and freshness semantics

Every non-trivial field is a `CapabilityValue<Value>` carrying:

| Component | Meaning |
|---|---|
| `value` | The value itself |
| `source` | `.declared` \| `.deviceReported` \| `.runtimeReported` \| `.unknown` |
| `observedAt` | When observed. **`nil` for `.declared`** — a compile-time constant is not an observation |
| `limitation` | **What this value does NOT establish** |

The ordering matters and is deliberate: `.runtimeReported` is stronger than `.deviceReported`, which
is stronger than `.declared`. The contract must not present them as equivalent.

**The `limitation` field is enforced by test.** A field that does not state what it fails to
establish is an overclaim waiting to happen — the same discipline applied to `InferenceEvidence` in
Phase 6.

### Worked example of why provenance matters

The `model` block carries:

> "Describes the artifact this build expects. It does **NOT** establish that the model is present on
> the device — provisioning is verified separately."

Without that sentence, a consumer could reasonably read `model.sha256` as *"the model is on the
device and correct"*. It means only *"this is what we would provision"*.

---

## What the contract deliberately does NOT claim

1. **That the model is present on the device.** Only that this build expects it.
2. **That anything is currently connected, installed, or running.** Dynamic state is excluded.
3. **How fast anything is.** No performance figures, by design.
4. **That the CPU backend is a hardware limit.** It is a Phase 6 decision (ADR-012 §11); Vulkan
   compute is available on this device and deliberately unused. The contract says so.
5. **That unknown means supported.** Four availability states exist, and a test asserts only
   `.supported` is executable.
6. **That `n_batch` is a caller-facing limit.** It is an implementation detail the worker handles
   internally (see FAIL-005); publishing it would invite callers to plan around a non-limit.
7. **That the contract is authoritative at execution time.** It is not — PixelDesktop re-validates.

---

## The context-size question, resolved

`kContextSize` lived **only** in `llama_jni.cpp`. Three options were considered:

| Option | Verdict |
|---|---|
| Duplicate it as a Swift constant | ❌ **creates a second source of truth** — the two could drift, and the Swift one would be wrong |
| Move it into an existing Swift contract | ❌ same problem inverted: the native layer would then need the Swift value |
| **Report it from the runtime** | ✅ **chosen** |

The native layer now reports **the context size it actually allocated**, read back from the live
context via `llama_n_ctx()` rather than restating the constant. `kContextSize` remains the single
definition; the contract *observes* it.

**Verified on the physical Pixel 7a:**

```
kContextSize in source : 2048
runtime n_ctx_in_use   : 2048    <- reported by the runtime
model's trained max    : 32768   <- a property of the model, not our configuration
```

The trained maximum and the allocated window are **different numbers** and both are published,
because conflating them would misstate what a caller may send.

**Fallback:** when the runtime cannot be asked, the contract falls back to a `.declared` value that
**says it is declared** and is not an observation. A test asserts the fallback carries no timestamp.

---

## Availability model

Four states, not two:

| State | Meaning |
|---|---|
| `supported` | Established as executable; prerequisites present |
| `unsupported` | Established as NOT executable — a fact (e.g. a model class measured to exceed memory) |
| `unavailable` | Supported in principle, but a prerequisite is missing right now — **can become `supported` with no code change** |
| `unknown` | Not established |

`unavailable` is distinct from `unsupported` because collapsing them would either overstate
permanence or understate capability. `unknown` exists so that "we do not know" is a representable
answer rather than an absence — a test asserts **only `supported` is executable**, so an
unestablished value can never default to "fine".

---

## Reuse: what Step 1 did and did not change

| Component | Change |
|---|---|
| `AndroidDevice`, `DeviceCapabilities` | **reuse unchanged** — read by the contract |
| `ModelContract` | **reuse unchanged** — the contract derives from it |
| `InferenceRuntimeIdentity`, `LlamaCppRuntime` | **reuse unchanged** |
| `InferenceRequest` | **reuse unchanged** — limits published, not altered |
| `WorkerInstaller`, `WorkerLifecycle`, `WorkerOperationsProtocol` | **reuse unchanged** |
| `InferenceResult` | **extended** — two optional context fields added |
| `llama_jni.cpp` | **extended** — reports `n_ctx_in_use`; **and one defect fixed** (FAIL-005) |
| `LlmWorkload.java` | **extended** — reports context size in the result envelope |
| `PixelCapabilityContract.swift` | **new** — the contract |
| `Phase7CapabilityContractTests.swift` | **new** — 32 tests |

**No router, scheduler, resource manager, workload planner, Hermes skill, Mac executor,
`ExecutionNode`, new agent, new runtime, or new transport protocol was created.**

---

## The defect found during verification

Real-device verification of the context boundary uncovered **FAIL-005**: a prompt longer than
`n_batch` (256) makes `llama_decode()` call `ggml_abort()` and **SIGABRT the worker** — with no
result file, which the Mac cannot distinguish from a crash-loop or a timeout.

**It compiled cleanly and passed all 224 tests.** It was found only by sending a real oversized
prompt to the real device — the seventh defect of this family in the project.

**Fixed** by decoding in chunks of `kBatchSize` (the documented llama.cpp pattern), and **verified on
the device**: the identical input that previously aborted the process now completes 820 prompt
tokens and returns `status=OK`, with no new abort.

This also **corrected the contract itself**: the context-size limitation originally claimed overflow
is "refused by the runtime", which was wrong — a *different* bound was fatal rather than refused. The
text now states both behaviours accurately.

---

## Tests

| Suite | Count | Result |
|---|---|---|
| Phase 1–6 | 194 | pass |
| **Phase 7 Step 1** | **32** | **pass** |
| **Total** | **226** | **0 failures** (4 skipped: real-device integration, no serial set) |

Step 1 tests prove exactly the six required things:

1. **Correctly populated** — device identity, contract version, both workloads published
2. **Existing values preserved** — model identity asserted *equal to* `ModelContract`; runtime
   asserted *equal to* the adapter; limits asserted *equal to* `InferenceRequest`
3. **Context size correctly represented** — prefers the runtime report; falls back to `.declared`
   and says so; rejects 0 and negative reports; agrees with the native constant; parses the real
   report shape; keeps trained ≠ allocated
4. **Unavailable/unknown honest** — four states; only `.supported` executable; unknown never
   defaults to supported
5. **No invented measurements** — asserts the encoded contract contains no token-rate, load-time,
   or latency field; asserts every field states a limitation
6. **Existing behaviour intact** — contract round-trips; building it does not mutate the device;
   `InferenceRequest` validation unchanged

**What these tests do NOT prove:** anything about the native layer on Android. FAIL-005 was found by
a device, not by a test, and no macOS test could have found it.

---

## Real-device verification performed

| Check | Result |
|---|---|
| Contract context size matches the runtime | ✅ 2048 = 2048 |
| Trained context distinct from allocated | ✅ 32768 vs 2048 |
| `n_ctx_in_use` present in the shipped `.so` | ✅ verified in the built binary |
| APK builds and installs | ✅ 5.9 MB |
| Zero permissions retained | ✅ 0 |
| Phase 6 regression: `LOCAL-LLM-1` | ✅ 3/3 runs, identical token IDs, greedy stable |
| Phase 5 regression: `DTCA-1` | ✅ `COMPLETED`, Mac re-computation matches |
| FAIL-005 fix | ✅ oversized prompt now completes; no new abort |

---

## Unresolved issues

| # | Issue | Impact |
|---|---|---|
| **U1** | **The contract has no retrieval path yet.** The Swift type exists and is tested, but nothing exposes it over a transport, and Hermes cannot read it | **Expected** — Step 1 publishes the contract *shape*. How it is delivered is a later step |
| **U2** | **Dynamic state is not included.** "Is the device connected / model present / memory free" is excluded by design | A consumer cannot learn current availability from the contract alone. This is intentional, but the delivery mechanism must supply it |
| **U3** | **Performance evidence has no channel yet.** Step 2 | Hermes currently has no measured numbers, only the shape for them |
| **U4** | **The `workloads` list is static.** It reflects this build; it is not derived from a runtime query | Acceptable now; would need revisiting if workloads become dynamic |
| **U5** | **`supportedABIs` is read from the device, but the contract cannot confirm the worker's own ABI** | Minor; the APK is arm64-v8a only and the device reports the same |
| **U6** | **Prompt cost is now known to be severe** (820 tokens → 5.1 min) and is **not** published | Deliberately not a contract field. It belongs in Step 2's evidence channel with provenance |
| **U7** | **The pre-existing crash-buffer count was not zero** (1 `SIGABRT` entry, from the pre-fix run) | Cosmetic; the count was unchanged after the fix, which is the meaningful check |

---

## Completion criteria

| Criterion | Status |
|---|---|
| Verified against amended ADR-007 | ✅ Hermes decides / PixelDesktop enforces; publishes only, decides nothing |
| Relevant tests run | ✅ 226, 0 failures |
| Real-device verification | ✅ context size, regressions, FAIL-005 fix |
| Regression suite | ✅ Phase 1–6 intact (DTCA-1 and LOCAL-LLM-1 both verified) |
| Diff inspected | ✅ below |
| No router/scheduler/Mac executor introduced | ✅ confirmed by inspection |
| No unnecessary production change | ✅ extensions only; one defect fixed |

---

## Files changed

**New:**
- `PixelDesktop/Inference/PixelCapabilityContract.swift`
- `PixelDesktopTests/Phase7CapabilityContractTests.swift`
- `engineering/failures/FAIL-005-prompt-exceeding-nbatch-aborts-worker.md`
- `engineering/phases/phase-07-step-1-capability-contract.md` (this file)

**Modified:**
- `DTCA1Worker/app/src/main/cpp/llama_jni.cpp` — chunked decode (FAIL-005 fix); `n_ctx_in_use` reporting; `kBatchSize` constant
- `DTCA1Worker/app/src/main/java/com/pixeldesktop/worker/LlmWorkload.java` — context size in the result envelope
- `PixelDesktop/Inference/InferenceRuntime.swift` — two optional context fields on `InferenceResult`
- `PixelDesktopTests/Phase6InferenceTests.swift` — updated for the new optional fields
- `engineering/` — README, journal, techniques, created-resources

---

```text
PHASE 7 STEP 1 COMPLETE / AWAITING APPROVAL FOR STEP 2
```

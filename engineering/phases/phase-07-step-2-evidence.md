# Phase 7 Step 2 — Measured Evidence with Provenance and Freshness

**Status:** COMPLETE. **Step 3 not started.**
**Date:** 2026-10-02
**Phase:** 7 (Pixel Capability Contract & Hermes Workload Planning) — per **ADR-007 Amendment 1**
**Depends on:** Step 1 (`1c27d8f`) — the capability contract
**Supersedes:** nothing

---

## What Step 2 adds over Step 1

Step 1 published what the Pixel **can** support: static, declared facts that change only on
redeploy. Step 2 publishes what has been **observed**.

The distinction a consumer must be able to draw:

```
"Pixel is capable of doing this"
                    vs.
"Pixel is capable of doing this AND this observed state is current enough to matter"
```

Step 1 answered the first. Step 2 answers the second — without turning either into a rule.

---

## Reuse, not reinvention

**`CapabilityValue` (Step 1) already WAS the observation shape this step requires.** It carries
`value` + `source` + `observedAt` + `limitation`.

There is deliberately **no second observation type**. Creating one would be the "duplicate
information" failure the brief warns against, and would mean two places to keep provenance honest.

Step 2 therefore adds **three new value types and one reader**, and nothing else:

| New | Purpose |
|---|---|
| `PixelStateObservation` | one point-in-time reading of device state |
| `PixelExecutionEvidence` | what a single real execution reported about itself |
| `PerformanceObservation` | a measured sample **with the conditions it was taken under** |
| `PixelEvidenceReader` | reads through the **existing** `TransportProtocol` and worker types |
| `Freshness` | age assessment against a **caller-supplied** window |

**No `ResourceMonitor`, no polling daemon, no cache, no scheduler, no reservation system, no queue,
no refresh loop.** Observations are taken on request and are immutable values. Nothing here holds
state between calls or runs in the background.

---

## Evidence categories

### 1. Declared capability — Step 1, unchanged

Supported ABI · model identity · model hash · model size · runtime/backend · allocated context
size · hard request limits. **These carry no measurement timestamp** because they are not
measurements. Step 1's tests still assert they contain no performance field.

### 2. Device-reported state — new

| Field | Source | Why it is needed |
|---|---|---|
| `availableMemoryBytes` | `/proc/meminfo` `MemAvailable` | **the hard constraint.** A ~1.3 GB model against ~2.3 GiB available is the binding limit on what can run |
| `freeStorageBytes` | `df -k /sdcard` | the model is 1.04 GiB; storage is a real prerequisite |
| `workerInstalled` (+ versionCode) | `WorkerInstaller.installedState` — **reused** | nothing can run without it |
| `workerRunning` | `WorkerLifecycle.state` — **reused** | useful context, with a stated caveat |
| `modelPresent` (+ byte count) | `stat` at the **fixed contract path** | the model is a prerequisite; absence is the most likely cause of refusal |
| `thermalStatus` | `dumpsys thermalservice` | contextual only — **system-wide, not attributable** |
| `deviceReachable` | shell exit code | the most basic prerequisite |

**Deliberately NOT collected**, despite being available: per-core CPU utilisation (not readable for
other processes without root), battery level (no worker attribution), GPU state (no path exists),
and load average (no consumer needs it yet). *The brief's instruction — do not create measurements
merely because they are technically available — was applied literally.*

### 3. Runtime-reported evidence — new

From `InferenceResult`, which the worker **already returned** in Phase 6. Nothing new is measured;
Step 2 publishes what already existed with provenance attached.

Runtime identity · model file + device-computed SHA-256 · allocated context size · timing breakdown
(model load / prompt eval / generation / total) · prompt and generated token counts · status.

### 4. Historical performance evidence — preserved, not converted

| Evidence | Value | Status |
|---|---|---|
| Generation-time variance | **2.4×** for identical 8-token work | preserved |
| Model-load variance | **12×** (393 ms → 4,954 ms) | preserved |
| Prompt processing dominance | 820 tokens → **5.1 minutes** | preserved (Step 1) |
| Measured inference timings | e.g. 7 tokens / 8,130 ms | preserved as a sample |

**None of these is a routing rule, a threshold, or a ranking input.**

---

## Why performance observations are not routing rules

Phase 7 reconnaissance measured a **2.4× generation variance** for identical work under identical
inputs. A single number published as "the Pixel's speed" would be wrong roughly half the time.

Therefore a measurement is represented as a **sample with its conditions attached**
(`PerformanceObservation` + `MeasurementConditions`), never as a capability or a constant. A
consumer that wanted a rule would have to invent the threshold itself — PixelDesktop refuses to.

A unit test asserts the encoded performance observation contains no `threshold`, `minAcceptable`,
`maxLatency`, or `targetTokensPerSecond` field.

---

## Freshness semantics — and why there is no default

`Freshness` has three states, and **no default threshold**:

| State | Meaning |
|---|---|
| `current` | observed within the caller's window |
| `stale` | older than the caller's window — still a real observation, just an old one |
| `unknown` | no timestamp exists, so age **cannot be assessed** |

`unknown` is distinct from `stale` because they are different facts: stale means we know it is old;
unknown means we cannot tell. Collapsing them would let a consumer read "no timestamp" as "old".

**`maxAge` is a required parameter with no default.** PixelDesktop has no defensible basis for
declaring "memory readings older than N seconds are stale" — that depends entirely on what the
consumer intends to do with the number. Baking in a threshold would be inventing policy, and would
risk becoming exactly the kind of hardcoded constant this project forbids. **PixelDesktop does the
arithmetic; the caller supplies the window.**

Two further details, both tested:

- A **future timestamp returns `unknown`, not `current`.** A timestamp ahead of now means the clock
  is wrong, and reporting it as current would hide a real problem.
- The boundary is **inclusive** at exactly `maxAge`.

---

## A snapshot is NOT a reservation

**This is the property Step 2 exists to protect, and it is stated in every relevant place.**

```
availableMemory = X     does NOT guarantee X is available at submission time.
```

The shared constant `PixelEvidenceReader.notAReservation` reads:

> "A SNAPSHOT, NOT A RESERVATION. This value may be different by the time a workload is submitted.
> PixelDesktop re-validates authoritative state immediately before execution, so a stale observation
> causes a refused request, never unsafe execution."

It is **one constant, reused** rather than paraphrased per field — so the warning cannot drift or be
softened in one place. A test asserts its content.

### Demonstrated end-to-end on the real device

The failure chain was exercised for real:

```
1. An observation was taken showing the model present.
2. The model was renamed on the device (removing it).
3. A workload was submitted.
4. PixelDesktop REFUSED: error_type = MODEL_MISSING
5. The model was restored.
```

**A stale observation produced a rejected request — not unsafe execution.** That is the whole
architectural claim of ADR-007 Amendment 1 §A1.6, verified rather than asserted.

---

## What was deliberately not published

| Not published | Why |
|---|---|
| **Page-cache warm/cold state** | The reconnaissance **proved it matters** (393 ms → 4,954 ms model load) but there is **no non-root way to determine it**. Modelled as a field that is always `.unknown`, so the gap is visible rather than silently missing. *Inventing a value would have been worse than omitting it.* |
| **Token rates as capabilities** | They are samples, not capabilities. They live in evidence, never in the contract |
| **Thermal as worker-attributable** | It is system-wide. Every mention says so |
| **Any threshold** | No consumer has a justified basis for one yet |
| **CPU utilisation, GPU state, battery** | Available but no consumer needs them |

---

## The device read is one round trip, not seven

An ADB round trip costs **~226 ms** (measured). Rather than seven separate reads, the reader issues
**one combined shell command** emitting `KEY=value` lines, then parses them.

Two parsing properties matter and are tested:

- **A key absent from the output is `nil`, not `0`.** A failed read must never be readable as a real
  value of zero — that is the most misleading possible substitution.
- **A thermal line that fails to parse returns `nil`, not `0`**, for the same reason.

### An unreachable device yields an observation, not an error

If the device cannot be reached, the reader returns a `PixelStateObservation` whose **every field is
explicitly `.unknown`** with no timestamp, plus `deviceReachable = false`.

This is deliberate: throwing would discard the one fact we do have. A consumer always receives
something it can reason about, and no unreadable field is presented as a zero.

This path was exercised **for real** — the device disconnected mid-verification, and the reader
handled it rather than crashing.

---

## Real-device verification

| Check | Result |
|---|---|
| Reachable | ✅ `true [deviceReported]` |
| Available memory | ✅ **2,451,505,152 bytes (~2.28 GiB)** `[deviceReported]` |
| Storage free | ✅ **58,859,884,544 bytes** `[deviceReported]` |
| Worker installed | ✅ `installed(versionCode: 2)` `[deviceReported]` |
| Worker running | ✅ `true` `[deviceReported]` |
| Model present | ✅ `present(byteCount: 1117320736)` — **matches `ModelContract` exactly** |
| Thermal status | ✅ `0` `[deviceReported]` |
| Freshness (60 s window) | ✅ `current` |
| Freshness (0 s window) | ✅ `stale` — proving freshness is computed, not fixed |
| Execution evidence fields | ✅ **all 12 present** in a real result envelope |
| Derived rates | ✅ generation 0.86 tok/s, prompt 4.11 tok/s (32-token prompt) |
| **Refusal path** | ✅ unsupported workload, non-greedy temperature, max_tokens over ceiling, model absent — all `FAILED` with bounded `error_type` |
| **Stale-observation chain** | ✅ demonstrated end-to-end (above) |

### Phase 1–6 regression

| Check | Result |
|---|---|
| `DTCA-1` (Phase 5) | ✅ `COMPLETED`, Mac re-computation matches |
| `LOCAL-LLM-1` (Phase 6) greedy stability | ✅ **3/3 runs, identical token IDs** |
| Zero permissions | ✅ 0 |

---

## Tests

| Suite | Count | Result |
|---|---|---|
| Phase 1–6 | 194 | pass |
| Phase 7 Step 1 | 32 | pass |
| **Phase 7 Step 2** | **35** | **pass** |
| **Total** | **261** | **0 failures** (4 skipped without a device serial) |

Step 2 tests prove the seven required things: Step 1 static capability intact · dynamic observations
correctly populated · provenance and timestamps correct · stale/unknown semantics as designed ·
measurements not silently promoted to capabilities · **no performance threshold introduced** ·
invalid requests still refused.

Two of my own tests were **wrong and were corrected**, not worked around:
- a `Double?` assertion needed `try XCTUnwrap`
- a rate test zeroed generation but left a 27-token prompt, so the prompt rate was legitimately
  non-nil — the test was wrong, not the code

---

## Unresolved issues and limitations

| # | Issue | Impact |
|---|---|---|
| **U1** | **Still no retrieval path.** The contract and the evidence both exist as Swift types; nothing exposes them over a transport, so Hermes cannot read either yet | **Expected** — publication precedes delivery. A later step |
| **U2** | **Page-cache state is always `.unknown`** | Model-load times are published without their most influential condition. Honest, but incomplete — and unfixable without root |
| **U3** | **No history.** Each observation is a single point in time; there is no trend, min, max, or distribution | Deliberate: no cache, no daemon. A consumer wanting history must collect samples itself |
| **U4** | **The observation reads memory *before* submission, not during** | The value can change between read and execution — which is precisely why it is documented as a snapshot, not a reservation |
| **U5** | **`workerRunning` is of limited value** | A live process does not imply a loaded model. The limitation field says so, but a consumer may still over-read it |
| **U6** | **Thermal remains unusable for decisions** | System-wide; no attribution. Recorded, not worked around |
| **U7** | **The device disconnected once during verification** | Handled correctly (unreachable path), but it is a reminder that connectivity is itself unreliable — and `deviceReachable` is only true *at the instant it was read* |
| **U8** | **`PerformanceObservation` has no accumulator** | Nothing aggregates samples. Building one would be the monitoring subsystem the brief forbids |

---

## Files changed

**New:**
- `PixelDesktop/Inference/PixelEvidence.swift`
- `PixelDesktopTests/Phase7EvidenceTests.swift`
- `PixelDesktopTests/Phase7DeviceEvidenceHarness.swift`
- `engineering/phases/phase-07-step-2-evidence.md` (this file)

**Modified:** `engineering/` — README, journal, techniques, created-resources.

**Production source outside the new file: none.** Step 2 is additive.

---

```text
PHASE 7 STEP 2 COMPLETE / AWAITING APPROVAL FOR STEP 3
```

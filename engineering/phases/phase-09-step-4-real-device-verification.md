
---

# Phase 9 Step 4 — Real-Device Verification (hardware)

**Date:** 2026-10-03
**HEAD at verification:** `ac7378755f45c20cddde28809f26686d621f7bfc`
**Verdict:** **PASS** — including independent Mac-side re-computation.

---

## Device

| | |
|---|---|
| Connected | yes |
| Authorized | yes |
| Serial | `DEADBEEF000000` |
| `adb devices -l` | `device usb:1048576X product:lynx model:Pixel_7a device:lynx transport_id:12` |
| `adb mdns services` | empty |
| **Connection type** | **USB** — determined from the `usb:` token; mdns empty means it is not wireless |

Serial was read from `adb devices -l` and passed through the CLI's own device selection. It was
never hardcoded into the interface.

## Capability (exit 0)

`interface_version: 1` · `contractVersion: 2` · DTCA-1 present with `requiresModel: false`,
`requiresRuntime: false`, `exactlyVerifiable: true`.

**`maximumInputCharacters: 10000`**, `source: declared`, limitation preserved. LOCAL-LLM-1 publishes
`4096`, equal to the global `limits.maximumPromptCharacters`.

**DTCA-1's bound is distinct from the global LLM limit** — Phase 7 Amendment 2 confirmed against a
live contract, not just a unit test.

## Observation (exit 0)

Every field `deviceReported` with a timestamp; every snapshot field carries *"A SNAPSHOT, NOT A
RESERVATION"*:

| Field | Observed |
|---|---|
| availableMemoryBytes | 2,701,570,048 |
| freeStorageBytes | 58,895,212,544 |
| workerInstalled | `installed(versionCode: 2)` |
| workerRunning | false |
| modelPresent | `present(byteCount: 1,117,320,736)` |
| thermalStatus | 0 — flagged SYSTEM-WIDE, not worker-attributable |
| deviceReachable | true |

No field was converted to zero merely because it was unavailable.

## Execution

```
pixel-desktop run --workload DTCA-1 --input-file <input> --json      → exit 0
```

Input: 179 characters, 179 bytes, sha256 `f79d0e3379a3bbf8fe5d21ae7a7e80e26a1e4c471877f5acb316679cedbcb9ce`,
read verbatim. Well within the published 10,000 bound.

Path executed: CLI → `DTCA1Worker.validateInput` → device selection → worker/workspace preflight →
`DTCA1Job` → **`WorkerStreamRunner`** → persistent `adb shell` → Pixel worker → PDE1 stream →
durable `result.json` → `resultBelongsToJob` → `WorkerResultEnvelope` → `DTCA1Result` → CLI envelope.
No polling, no `WorkerComputeProof`, no second execution path.

## Result

| | |
|---|---|
| `ok` | true |
| `outcome` | `completed` |
| job id | `958CDD68-1AED-4102-A16E-9B5F03F56114` |
| status | COMPLETED |
| input_characters | 179 (matches the input exactly) |
| total_words / unique_words | 33 / 23 |
| classification | NATURAL_LANGUAGE |
| top_words | the=6, fox=3, brown=2, dog=2, quick=2 |
| evidence | toOutcome 0.233 s · wall 0.287 s · `streamEndedUnexpectedly: false` · unrecognized 0 · stderr 0 |

An earlier run on the same hardware reported `outcome: completed`, heartbeats 1, wall 0.893 s,
toOutcome 0.827 s — recorded because the timing spread across runs is itself evidence, and the
faster second run is not presented as the typical figure.

## Independent Mac verification — PASS

`ResultVerifier.verify(pixelResult:localResult:originalInput:)` against `DTCA1Worker.execute`:

```
verified   : true
mismatches : []
pixel  total/unique/class : 33/23/NATURAL_LANGUAGE
local  total/unique/class : 33/23/NATURAL_LANGUAGE
pixel top words : ["the=6", "fox=3", "brown=2", "dog=2", "quick=2"]
```

The CLI's `ok` field was **not** taken as truth. The values were also asserted directly, so a
verifier bug could not hide behind its own green light.

## Semantic check — no false success

- a successful execution carried no refusal
- `ok: true` corresponded to an authoritative payload whose own `status` is `COMPLETED`
- ownership: the matching job id was accepted; a foreign id was rejected
- stream-level evidence and the authoritative workload outcome remained distinguishable
- no contradictory `ok` / `outcome`

The Step 4 defect — a worker refusal reported as success — is confirmed fixed on hardware.

## The one failure, and its cause

The **first** hardware run failed. The cause was the **verification procedure, not the
implementation**:

Two suites were run against the **same device concurrently**. The E1 transfer contract uses **fixed
paths** (`job.json` / `result.json`), so the two runs clobbered each other. The other suite's
deliberate session-loss test left its own `result.json` on the device, and `run` found a **foreign**
result — which `resultBelongsToJob` **correctly refused**:

```
Verification failed: Result does not belong to job <id>; refusing a stale or foreign result
```

Re-run serially: **5/5 passed in 3.55 s**, against 140 s of failure while overlapping.

**This is the containment working.** A stale result was rejected rather than reported as this
job's. Recorded as an operational constraint, not an implementation fix:

> **Device-gated suites must run serially.** One device, fixed transfer paths.

## Regression

Serial full suite **with the device attached**: **421 tests, 0 failures**, `EXIT=0`.

The count rose from 406 to 421 because the **15 device-gated tests actually ran** instead of
skipping — including the E1 harness's deliberate worker-kill, session-loss and `am force-stop`
tests. No test was weakened, skipped, deleted, or rewritten.

## Not performed

The optional negative hardware test (§9) was **not** performed. Inducing a deterministic DTCA-1
refusal would require removing the worker or the model, which is a device state change, and the
brief forbids damaging the setup for this verification. The refusal semantics are covered by the
Step 4 scripted tests and by the foreign-result refusal observed above.

`LOCAL-LLM-1` was not executed. No model was provisioned or transferred.

```text
REAL-DEVICE DTCA-1 VERIFICATION — PASS
```

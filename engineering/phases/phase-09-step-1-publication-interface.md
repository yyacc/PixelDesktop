# Phase 9 Step 1 — The Read-Only Publication Interface

**Status:** COMPLETE — `pixel-desktop` CLI implemented, tested, and verified.
**Date:** 2026-10-03
**Phase:** 9 (Hermes Integration) — first bounded step, per **ADR-007 Amendment 1 §A1.10**
**Depends on:** Phase 7 (Steps 1–3) — the contract, the evidence layer, and the refusal path
**Baseline:** 349 tests, 0 failures, 15 skipped @ `32cd021`
**Final:** 372 tests, 0 failures, 15 skipped
**Decision record:** [ADR-014](../decisions/ADR-014-read-only-publication-interface.md)

---

## The gap this step closes

Phase 7 built the capability contract and the evidence layer. It also recorded, in
`phase-07-step-2-evidence.md` §U1, that nothing could read them:

> **U1** | **Still no retrieval path.** The contract and the evidence both exist as Swift types;
> nothing exposes them over a transport, so Hermes cannot read either yet.
> **Expected** — publication precedes delivery. A later step.

This is that step. Without it, the planned `pixel-compute` skill would teach Hermes a procedure it
could not execute — the exact failure the Phase 7 re-evaluation's ordering note warned about.

---

## What was built

A third build target, `pixel-desktop`, and two commands:

```
pixel-desktop capability --json     # static capability; no device, no device I/O
pixel-desktop observe --json        # current device state; read-only reads only
```

### The dependency shape

The requirement was that the CLI must not become a second capability implementation:

```
        Shared PixelDesktop implementation
        (PixelCapabilityContract · PixelEvidenceReader · PixelDesktopError)
                        │
            ┌───────────┴───────────┐
            ▼                       ▼
      App target                CLI target
      execution                 publication
```

This is enforced by the build definition rather than by convention: the CLI target compiles **the
same `PixelDesktop/` sources**, excluding only the SwiftUI entry point (`App/`), the app's
`Info.plist`, and its asset catalog. There is one implementation and two consumers of it.

**No type was duplicated.** `PixelCapabilityContract`, `CapabilityValue`, `PixelStateObservation`,
`PixelExecutionEvidence`, `PerformanceObservation`, `PixelDesktopError`, and the freshness logic are
all the shared originals. No parallel DTO hierarchy was created.

---

## The one design decision worth recording

`PixelCapabilityContract.build(device:contextSize:trainedContextSize:observedAt:)` **requires an
`AndroidDevice`**, and the contract's own `build()` marks `contract.device` as `.deviceReported` — a
device read.

But `capability` promises **no device I/O**. Publishing that field would require either I/O the
command promises not to do, or a fabricated `.declared` provenance on a value that was never
declared.

**Resolution:** `contract.device` is **omitted**, and the omission is stated in the envelope's
`not_read` list with its reason. The remaining device-independent fields (runtime, model, limits,
workloads) are published with provenance restated as `.declared` and `observedAt: nil` — which is
their honest provenance, and exactly what the contract's own doc comment describes: *"Describes what
this build ships, not what is installed on the device."*

`observe` is the command that reads the device. That split is the point of having two commands.

---

## Absent, never zero

`CapabilityValue` carries a non-optional `value`, so an unreadable field encodes as
`value: 0, source: "unknown"`. Semantically correct — the source is the load-bearing marker — but a
consumer reading `value` without reading `source` is told *"zero bytes of memory are available"*,
which is the most damaging possible misreading.

**Presentation rule:** an unknown-source value is published **without its `value` key at all**.
Absent cannot be misread as a measurement.

This is a presentation rule applied uniformly to every `CapabilityValue` in the tree, including
inside arrays and at every nesting depth. It is not a change to the contract or the evidence types,
and it is not a DTO.

---

## The JSON contract

```json
{
  "interface_version": 1,
  "command": "capability" | "observe",
  "ok": true,
  "produced_at": "2026-10-03T01:43:20Z",
  "contract": { ... } | null,
  "observation": { ... } | null,
  "not_read": [ { "field": "...", "reason": "..." } ],
  "error": null | { "type": "...", "message": "...", "is_recoverable": true, "category": null }
}
```

Two properties matter:

- **All eight keys are always present.** `null` (not omission) marks a channel that does not apply,
  so a consumer never has to guess whether a missing key means "not applicable" or "something went
  wrong".
- **`interface_version` is separate from `contractVersion`.** The two can move independently — the
  contract may gain a field without the envelope changing, and vice versa. A consumer must be able
  to detect either.

Keys inside `contract` and `observation` are the shared types' own and are **left alone**. Envelope
keys are snake_case. The CLI is a presentation layer, not a re-modeller.

---

## Error semantics

The existing `PixelDesktopError` vocabulary is preserved and mapped to stable tokens:

| Error case | Token | Recoverable |
|---|---|---|
| `deviceNotFound` | `device_not_found` | yes |
| `deviceUnauthorized` | `device_unauthorized` | yes |
| `deviceOffline` | `device_offline` | yes |
| `adbCommandFailed` | `adb_command_failed` | yes |
| `adbTransportError` | `adb_transport_error` | yes |
| `timeout` | `timeout` | yes |
| `cancelled` | `cancelled` | yes |
| `verificationFailed` | `verification_failed` | no |
| `workerError` | `worker_error` | no |
| `workerRefused` | `worker_refused` | **no** |
| `unknown` | `unknown` | no |

`workerRefused` carries the Android worker's `error_type` **verbatim** in a separate `category`
field. This directly addresses the Phase 7 Step 3 finding: flattening that token into prose made
`MODEL_MISSING` and `INVALID_INPUT` — different causes, different fixes, one retryable and one not —
indistinguishable to any caller not pattern-matching English.

**Exit status:** `0` success · `1` structured failure (JSON still emitted) · `2` usage error.

**A failed observation never yields a partially populated observation.** A failed read is not
evidence of anything, and half a struct invites a consumer to use it.

---

## Tests

**372 tests, 0 failures, 15 skipped** (from 349). The 15 skips are the pre-existing device-gated
harnesses — unchanged.

The Phase 9 suite is split by what each part can actually prove, because the test bundle links the
application target and both compile the same `PixelDesktop/` sources. Importing the tool target
would put two copies of every shared type in one module and make every bare type reference
ambiguous. So:

**1. Pure unit tests (8)** over `CLIJSONPresentation` — deliberately a Foundation-only file, so it
compiles directly into the test bundle. Covers the presentation rules, where a subtle mistake is
silent:

- unknown-source values lose their `value` key; known-source values keep theirs
- the rule reaches every nesting depth and inside arrays
- declared values are not stripped
- ordinary objects without a `source` key are untouched
- unread fields are removed from their parent; a missing parent is harmless

**2. Black-box tests (14)** that run the built binary and assert on stdout, stderr and exit status.
These exercise the **real** serialisation path rather than a reconstruction of it:

- `capability` succeeds with no device; performs no device I/O
- no device identity is published, and the reason is stated
- published static facts **equal** the shared definitions (a change in `ModelContract` or
  `InferenceRequest` fails the suite rather than drifting silently)
- provenance is `.declared` with no timestamp; limitations survive
- no measurement leaks into the capability channel
- `observe` without a device fails structured, non-zero, with no partial observation
- all four usage errors exit `2` with usage text and nothing on stdout
- JSON on stdout, diagnostics on stderr

---

## Real-device verification

**NOT RUN.** No device attached:

```
adb devices -l   ->  "List of devices attached" (empty)
```

`observe --json` was exercised against the real detached state and returned the correct structured
failure (`device_not_found`, exit 1) — that is the real behaviour of the command, not a simulation.
The **populated** observation path was not exercised on hardware.

Two things are therefore unverified on a real device and are carried forward:

1. that `observe` populates real values through the CLI on a connected Pixel (the reader itself was
   verified in Phase 7 Step 2; the CLI is a thin pass-through, but pass-through is not proof)
2. that the absence rule behaves correctly against a live device that is reachable but has an
   unreadable field (the `unknown`-source path is unit-tested, not device-tested)

---

## Files changed

**New:**
- `PixelDesktopCLI/CLIEnvelope.swift` — envelope shape, structured error, error→token mapping
- `PixelDesktopCLI/CLIEnvelopeRenderer.swift` — encode → transform → pretty-print
- `PixelDesktopCLI/CLIJSONPresentation.swift` — the two presentation rules (Foundation-only)
- `PixelDesktopCLI/CLICommands.swift` — the two commands
- `PixelDesktopCLI/CLIDeviceSelection.swift` — device precedence, mirroring `AppState`
- `PixelDesktopCLI/CLIInvocation.swift` — argument parsing
- `PixelDesktopCLI/main.swift` — entry point, exit statuses
- `PixelDesktopTests/Phase9CLITests.swift` — 23 tests
- `engineering/phases/phase-09-step-1-publication-interface.md` (this file)
- `engineering/decisions/ADR-014-read-only-publication-interface.md`

**Modified:**
- `project.yml` — added the `pixel-desktop` tool target and scheme
- `engineering/` — README, journal, created-resources

**Shared implementation: unchanged.** No modification to `PixelCapabilityContract.swift`,
`PixelEvidence.swift`, or any other existing source. The app target is unchanged except that the
project definition now also compiles its sources into a second target.

---

## What this step deliberately did not do

| Not done | Why |
|---|---|
| Execution (`run`, submit a workload) | Not required to unblock the skill; the read path is independently verifiable |
| `shell()` exposure | ADR-007 §A1.12 — requires its own separate review |
| HTTP / MCP / unix socket / daemon | No listener, no port, no service. A process that runs, prints, and exits |
| Queue, scheduler, router, resource manager | No component decides anything |
| Retry loop | `isRecoverable` is published as information for a consumer, not acted on here |
| New Android permission | Zero-permission posture untouched |
| External dependency | Foundation only |
| Changes to contract/evidence contents | A CLI change must never redefine what the contract means |

---

## The lesson

**A promise not to touch the device is only credible if the code cannot touch it.** The
`capability` command takes no `TransportProtocol` at all — it has no device handle to misuse. The
alternative (passing a transport and relying on discipline not to call it) would have looked
identical and been weaker.

The same reasoning produced the `not_read` list: an omission with a stated reason is honest; an
omission with no explanation is indistinguishable from a bug.

---

```text
PHASE 9 STEP 1 COMPLETE / READ-ONLY CLI VERIFIED
```

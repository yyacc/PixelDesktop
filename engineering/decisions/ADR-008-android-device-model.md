# ADR-008: Android Device Representation Model

## Status

Accepted

## Date

2026-10-01

## Context

Master prompt §16 Phase 3 requires "a proper internal representation of an Android device"
exposing device identity, Android version, model, manufacturer, architecture, capabilities,
state, available services and supported operations, with discovery, representation and
operations separated, and "do not combine all device logic into one object".

Phase 2 delivered a partial model: `PixelDevice` with 8 fields, three of which
(`androidVersion`, `apiLevel`, `architecture`) were populated by `DeviceEnricher`.

Two defects were found while preparing Phase 3:

1. **`manufacturer` held the device codename.** `parseDeviceList` populated it from the
   `device:` token of `adb devices -l`. For the Pixel 7a that token is `lynx` — the build
   codename. `ContentView` rendered this as `LabeledContent("Manufacturer", ...)`, so the
   UI displayed a falsehood.
2. **`model` held the codename too.** The `model:` token in `adb devices -l` is `Pixel_7a`,
   which is also a build name, not the marketing name. The real marketing name
   (`Pixel 7a`) was not modelled at all.

## Problem

What should the device representation contain, where should each fact come from, and how
should discovery, representation and operations be separated without inventing
functionality that does not exist?

## Options Considered

### Option A — Extend `PixelDevice` in place

Add fields to the existing struct, leave the name and the two defects.

Rejected. The defects are the reason Phase 3 exists; leaving them would preserve a model
that lies about manufacturer. Master prompt §16 also says "an Android device" while
planning for multiple Android devices, which a vendor-specific type name contradicts.

### Option B — Full device model: RAM, GPU, NPU, thermal, storage, battery

Rejected. None of these has a reliable static `getprop` source. The roadmap assigns
thermal and memory work to Phases 6 and 7 with their own acquisition mechanisms. Modelling
them now is speculative infrastructure (§5.2).

### Option C — Representation types only; no operations protocol

**Chosen.** Grow `DeviceProperties` to the properties that are genuinely stable and
verifiable, rename `PixelDevice` → `AndroidDevice` with corrected identity, add a minimal
`DeviceCapabilities`, model supported operations as an enum listing only what is
implemented, and defer all operations to Phase 4.

## Evidence

Probed on the real Pixel 7a (serial `DEADBEEF000000`) **before** implementing, per §5.1:

| `getprop` key | Raw value returned | Exit |
|---|---|---|
| `ro.product.model` | `Pixel 7a` | 0 |
| `ro.product.manufacturer` | `Google` | 0 |
| `ro.product.cpu.abilist` | `arm64-v8a` | 0 |
| `ro.product.device` | `lynx` | 0 |
| `ro.product.cpu.abi` | `arm64-v8a` | 0 |
| `ro.build.version.release` | `16` | 0 |
| `ro.build.version.sdk` | `36` | 0 |

Findings that shaped the design:

1. **`manufacturer` is genuinely distinct from the codename** — `Google` vs `lynx`.
   Confirms the defect was real and the fix is correct.
2. **`abilist` returns a single entry on this device** (`arm64-v8a`), not a multi-value
   list. The parser must therefore handle the single-entry case as the common case, and
   the model must not assume a list is long.
3. **An unset key still exits 0 with empty output** (re-confirmed), so absence remains
   detectable only from the output.

## Decision

**`DeviceProperties` grows 3 → 6 fields:**

| Field | `getprop` key |
|---|---|
| `androidVersion: String` | `ro.build.version.release` |
| `apiLevel: Int` | `ro.build.version.sdk` |
| `architecture: String` | `ro.product.cpu.abi` |
| `marketingName: String` | `ro.product.model` |
| `manufacturer: String` | `ro.product.manufacturer` |
| `supportedABIs: [String]` | `ro.product.cpu.abilist` |

`DevicePropertyKey` grows to 6 entries plus an `all` list that `DeviceEnricher` iterates,
so keys cannot drift from the model.

**`PixelDevice` → `AndroidDevice`** (`Core/Models/AndroidDevice.swift`), with:

- `deviceCodename` — from the `device:` token of `adb devices -l`
- `marketingName` — from `ro.product.model`
- `manufacturer` — from `ro.product.manufacturer`
- `supportedABIs` — from `ro.product.cpu.abilist`

`displayName` precedence becomes `marketingName` → `deviceCodename` → `serialNumber`.

**`DeviceCapabilities`** — one field, `supportedABIs`, with `supports(abi:)`. No RAM, GPU,
NPU, thermal, storage or battery.

**`DeviceOperation`** — an enum containing only `.discover` and `.readSystemProperties`,
because those are the only implemented operations. **No operations protocol is created.**

**`DeviceService` is deliberately NOT added.** There is no meaningful service abstraction
to model: the legacy course-of-action §9.2 records that no on-device service exists, and
explicitly warns not to resurrect port 18373 merely because it appeared in historical
investigation. A single-case enum modelling "we have ADB" has no value today. Introduce a
service abstraction only when a real device service exists.

**Batched `getprop`** — `TransportProtocol` gains
`getSystemProperties(deviceSerial:timeout:)`, issuing one `adb shell getprop` and parsing
the `[key]: [value]` lines. `DeviceEnricher` uses it instead of six sequential calls.
ADR-005 pre-authorised exactly this once the property count exceeds five.

**Removed:** `Core/Models/PixelDevice.swift` (superseded; recoverable from git history).

## Reasoning

**Why the rename rather than an in-place extension:** the two defects are identity defects.
Fixing them requires distinguishing codename from marketing name from manufacturer, which is
a model-shape change, not a field addition. Master prompt §16 says "an Android device" and
§1 lists multiple Android devices as a future need, so a vendor-specific name is wrong for
the phase whose subject *is* the device model.

**Why capabilities stay minimal:** the master prompt lists "capabilities", so something must
be modelled. `supportedABIs` is the only capability that is both verifiable from a stable
`getprop` and actually needed — Phase 5 must know whether the device can run a given
native binary. Everything else would be invented.

**Why no operations protocol:** Phase 3's deliverable is representation. A protocol with no
implementations is speculative infrastructure. The separation the master prompt demands is
achieved by keeping representation types free of operation logic. RNZM-21 (Phase 4) owns
the operations work and will define the seam when it has a real implementation to put behind
it.

**Why batching:** measured on the real device — 6 single-key reads take 0.354 s (6 `adb`
process spawns) versus 0.095 s batched (1 spawn), a 3.7× speedup. The batched map was
verified to agree with single-key reads for all 6 keys.

## Consequences

- The UI now displays a true manufacturer (`Google`) and a real model name (`Pixel 7a`),
  plus the codename as a separate labelled row.
- Discovery still performs no I/O and claims no properties; enrichment owns them. The
  regression guard `testDiscoveryLeavesPropertiesUnpopulated` still passes.
- Enrichment is 1 process spawn instead of 6.
- `MockTransport` gained `setProperties`/`setProperty`/`setBatchedResult`, and its
  `getprop` now resolves from the same map as the batched read so the two cannot disagree
  in tests.
- 73 tests pass (69 hermetic + 4 opt-in integration tests skipped by design).
- The `AndroidDevice` rename touched 6 files; the compiler caught every site.
- `DeviceOperation` must be extended as Phase 4 implements operations, otherwise the model
  will understate capability. This is intentional: understating is safe, overstating is not.

## Rejected Alternatives

- **Extend `PixelDevice` in place** — preserves the identity defects.
- **Rename `DeviceProperties` → `AndroidSystemProperties`** — defensible name, ~40 test
  references, no correctness gain. Churn not justified.
- **Merge `DeviceProperties` into `AndroidDevice`** — they are a DTO and a domain model at
  different layers; collapsing them puts transport-shaped data in the representation.
- **Add `DeviceService` with `.adb`** — no meaningful abstraction to model yet.
- **Add RAM/GPU/NPU/thermal/storage/battery** — no reliable static source; Phases 6/7 work.
- **Add `InstalledApp`** — applications are Phase 4 (RNZM-21).
- **Add a `Video/`/scrcpy subsystem** — never implemented; conflicts with the master
  prompt's "not a better scrcpy frontend" constraint.
- **Cache enriched properties across reconnects** — Phase 2 deliberately does not cache;
  reconnect semantics belong to RNZM-22 (Phase 4), which must decide and record an ADR.

## Future Reconsideration Conditions

- Revisit `DeviceOperation` in Phase 4 as operations are implemented (RNZM-21, RNZM-22).
- Revisit `DeviceService` when an actual device service exists or a later phase requires one.
- Revisit `DeviceCapabilities` in Phases 6/7, where thermal and memory become real
  requirements with their own acquisition mechanisms.
- Revisit batching if the property count grows substantially; consider reading only the
  needed keys if `getprop` output size becomes a problem (it is currently ~100 KB).
- Revisit caching if RNZM-22 establishes that reconnect must invalidate properties.

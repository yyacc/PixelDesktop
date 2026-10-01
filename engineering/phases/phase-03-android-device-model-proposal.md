# Phase 3 Proposal — Android Device Model

**Status:** PROPOSAL — awaiting review. **No source code has been modified.**
**Phase:** 3 (Android Device Model) — authoritative sequence per [ADR-007](../decisions/ADR-007-authoritative-phase-sequence.md)
**Date:** 2026-10-01
**Depends on:** Phase 2 (Device Discovery and ADB Transport) — COMPLETE

---

## 1. Scope

Master prompt §16 Phase 3 requires:

> Create a proper internal representation of an Android device. The model should expose
> useful **verified** information such as: device identity, Android version, model,
> manufacturer, architecture, capabilities, state, available services, supported
> operations. Separate device discovery from device representation from device operations.
> Do not combine all device logic into one object.

Governing constraints: §5.2 smallest correct architecture · §5.3 existing technology first ·
§22 security · §31 do not rush phases.

**In scope:** device *representation* — the model, its facts, and the boundaries between
discovery, representation, and operations.

**Out of scope:** any device *operation* (launch, stop, query, execute). Those are Phase 4
(RNZM-21, RNZM-22) and Phase 5 (RNZM-23).

---

## 2. Current Model (as-built, Phase 2)

`PixelDevice` — 39 lines, 8 fields:

| Field | Type | Source | Static? |
|---|---|---|---|
| `id` | `String` | `parseDeviceList` (serial) | Static |
| `serialNumber` | `String` | `parseDeviceList` | Static |
| `model` | `String` | `parseDeviceList`, `model:` token → **codename** (`lynx`) | Static |
| `manufacturer` | `String` | `parseDeviceList`, `device:` token → **codename** (`lynx`) | Static |
| `androidVersion` | `String` | `DeviceEnricher` (`getprop`) | Static |
| `apiLevel` | `Int` | `DeviceEnricher` (`getprop`) | Static |
| `architecture` | `String` | `DeviceEnricher` (`getprop`) | Static |
| `state` | `DeviceState` | `parseDeviceList` | **Dynamic** |

`DeviceProperties` — 3 fields, transport-level enrichment payload.
`DeviceEnricher` — reads 3 properties, returns an enriched `PixelDevice`.

### Two defects found in the current model

**Defect 1 — `manufacturer` does not contain a manufacturer.**

`parseDeviceList` populates it from the `device:` token of `adb devices -l`:

```
3C261JEHN25632  device usb:1048576X product:lynx model:Pixel_7a device:lynx
                                                        ^^^^^^^^^^^  ^^^^^^^^^^^
                                                        codename     codename again
```

Both `model:` and `device:` are the device **codename**. `manufacturer` is therefore
`lynx`, which is not a manufacturer. `ContentView:110` renders it as
`LabeledContent("Manufacturer", ...)` — **the UI currently displays a falsehood.**

Verified against the real device before it was disconnected: `model=Pixel_7a device=lynx`.
Note also that even `model:` is not the marketing name — `Pixel_7a` is the *build* name.

**Defect 2 — `model` conflates two distinct concepts.**

`model` holds the codename `lynx`. The master prompt lists "model" as a separate item from
"device identity", and the marketing name (`Pixel 7a`) is a different fact from the codename
(`lynx`). Both are legitimately useful; neither is currently modelled correctly.

---

## 3. Requirement Gap

| Master prompt item | Exists? | Assessment |
|---|---|---|
| device identity | ✅ | serial + codename. Adequate. |
| Android version | ✅ | `androidVersion` from `getprop`. |
| model | ⚠️ | Holds the codename. Marketing name absent. |
| manufacturer | ❌ | Field exists but holds the codename. No real source wired. |
| architecture | ✅ | `architecture` from `getprop`. |
| capabilities | ❌ | Not modelled. |
| state | ✅ | `DeviceState` enum. Adequate. |
| available services | ❌ | Not modelled. |
| supported operations | ❌ | Not modelled. |
| discovery / representation / operations separation | ⚠️ | Discovery and representation exist and are separated. Operations have no home. |

---

## 4. Proposed Changes

### 4.1 `DeviceProperties` — grow 3 → 6 fields

The transport-level enrichment payload. Three additions, all stable AOSP `getprop` values.

| # | Field | Type | Source of truth (`getprop` key) | Static? | Why Phase 3 needs it |
|---|---|---|---|---|---|
| 1 | `androidVersion` | `String` | `ro.build.version.release` | Static | Master prompt item. Existing. |
| 2 | `apiLevel` | `Int` | `ro.build.version.sdk` | Static | Master prompt item. Existing. |
| 3 | `architecture` | `String` | `ro.product.cpu.abi` | Static | Master prompt item. Existing. Primary ABI — what to build for. |
| 4 | `marketingName` | `String` | `ro.product.model` | Static | Fixes Defect 2. The human-facing model name the master prompt asks for. |
| 5 | `manufacturer` | `String` | `ro.product.manufacturer` | Static | Fixes Defect 1. Master prompt item, currently a falsehood. |
| 6 | `supportedABIs` | `[String]` | `ro.product.cpu.abilist` | Static | Backs the minimal `capabilities` model (§4.3). Also the answer to "can this device run our APK". |

`DevicePropertyKey` grows to 6 entries, keeping keys beside the model they populate.

> ⚠️ **Fields 4–6 are UNVERIFIED on real hardware.** The Pixel 7a was physically
> disconnected during this proposal (confirmed: `adb devices` empty, absent from the USB
> bus). These keys are standard AOSP properties, but per §5.1 "do not assume an API works
> because documentation suggests it does", their **actual returned values must be probed
> before implementation.** If a key is unset on the Pixel, the field is dropped and the
> gap recorded — not silently defaulted.

### 4.2 `PixelDevice` → `AndroidDevice`

**Decision point D1.** Rename the representation type and fix the two defects.

| Field | Type | Source | Static? | Why |
|---|---|---|---|---|
| `id` | `String` | serial | Static | `Identifiable`. Unchanged. |
| `serialNumber` | `String` | `parseDeviceList` | Static | Device identity. Unchanged. |
| `deviceCodename` | `String` | `parseDeviceList` `device:` token | Static | **Renamed from `model`.** Was conflating codename with model name. |
| `marketingName` | `String` | `DeviceEnricher` | Static | **New.** The actual model name (`Pixel 7a`). |
| `manufacturer` | `String` | `DeviceEnricher` | Static | **Re-sourced.** Now a real manufacturer, not the codename. |
| `androidVersion` | `String` | `DeviceEnricher` | Static | Unchanged. |
| `apiLevel` | `Int` | `DeviceEnricher` | Static | Unchanged. |
| `architecture` | `String` | `DeviceEnricher` | Static | Unchanged. Primary ABI. |
| `supportedABIs` | `[String]` | `DeviceEnricher` | Static | **New.** Backs `capabilities`. |
| `state` | `DeviceState` | `parseDeviceList` | **Dynamic** | Unchanged. |

`displayName` resolution order becomes: `marketingName` → `deviceCodename` → `serialNumber`.
(The current order is `model` → `serialNumber`.)

**Rename rationale:** master prompt §16 says "an Android device", and §1 lists "multiple
Android devices" as a future need. `PixelDevice` bakes one vendor's product line into a
generic model, and Phase 3 is the phase whose subject *is* the device model. The rename is
mechanical and compiler-verified. **It is reversible and can be dropped** without affecting
any other part of this proposal.

**Blast radius:** 6 files — `PixelDevice.swift` (rename), `DeviceManager.swift`,
`DeviceEnricher.swift`, `ADBTransport.swift`, `ContentView.swift`, and 6 test construction
sites. Compiler catches every one.

### 4.3 Capabilities — `DeviceCapabilities`

**Decision point D2.** Master prompt lists "capabilities", so Phase 3 must model it. It must
not *invent* capabilities, so the model contains only what is verifiable from §4.1 data:

| Field | Type | Derived from | Static? | Why |
|---|---|---|---|---|
| `supportedABIs` | `[String]` | `DeviceProperties.supportedABIs` | Static | The one capability that is genuinely verifiable via `getprop` and genuinely needed: can this device run a given native binary/APK. Phase 5 requires this answer. |

Deliberately **excluded** (no reliable `getprop` source; would be speculative):
RAM, GPU, NPU/TPU, thermal headroom, storage, battery, screen. Master prompt §16 Phase 6/7
lists thermal and memory as *Phase 6/7* concerns with their own acquisition work. Modelling
them now would be speculative infrastructure.

Shape: `DeviceCapabilities` is a separate small value type initialised from an
`AndroidDevice`, so capability logic does not bloat the representation type (master prompt:
"do not combine all device logic into one object").

**Alternative:** omit `DeviceCapabilities` entirely and let Phase 5 read `supportedABIs`
directly. Cleaner by the "smallest viable model" rule, but does not satisfy the master
prompt's explicit Phase 3 requirement to model capabilities.

### 4.4 Available services — `DeviceService`

**Decision point D3.** Master prompt lists "available services".

**Evidence:** the legacy course-of-action §9.2 states that no on-device service exists —
"ADB forward works but no service uses it (the TCP 18373 forward exists but no HTTP server
responds on it)", and explicitly warns: *"Do not resurrect port 18373 merely because it
appeared in historical investigation. The port number is not evidence of a requirement."*

Therefore the honest model has exactly one available service today:

| Case | Meaning | Available? |
|---|---|---|
| `.adb` | ADB command/transport access | **Yes** — the only mechanism actually used |
| *(none)* | No on-device TCP/HTTP service exists | — |

Recommended: model this as an explicit single-case `DeviceService` enum with
`availableServices: Set<DeviceService>` = `[.adb]`, plus documentation that no on-device
service exists. This turns a documented absence into a stated fact, so the 18373 mistake
cannot recur by accident.

**Alternative:** omit it entirely as ceremony. A one-case enum has little value today; its
value is preventing a future phase from assuming a service exists. Offered for your call.

### 4.5 Supported operations — `DeviceOperation`

**Decision point D4.** Master prompt lists "supported operations", and §16 Phase 8 warns
against UI that "imitates functionality that the backend does not actually support". The
same principle applies here: the model must not advertise operations that do not exist.

| Case | Implemented? | Owning phase |
|---|---|---|
| `.discover` | ✅ Phase 2 | 2 |
| `.readSystemProperties` | ✅ Phase 2 | 2 |

Nothing else is listed, because nothing else is implemented. Phase 4 extends the enum as it
implements `shell()` (RNZM-21) and lifecycle (RNZM-22).

`supportedOperations` is computed from what the transport and device state actually permit,
so it cannot drift from reality.

### 4.6 Separation of discovery / representation / operations

The master prompt's central Phase 3 structural requirement. Proposal:

| Concern | Owner | Does not |
|---|---|---|
| **Discovery** | `ADBTransport.parseDeviceList` + `DeviceManager` | Read properties; know operations |
| **Representation** | `AndroidDevice`, `DeviceProperties`, `DeviceCapabilities`, `DeviceService`, `DeviceOperation` | Perform any device action |
| **Operations** | *no home in Phase 3* | — |

**Recommendation: Phase 3 does NOT create an operations protocol.**

Rationale: Phase 3's deliverable is representation. An unused protocol with no
implementations is speculative infrastructure (§5.2). The separation the master prompt
demands is achieved by keeping every representation type free of operation logic, and by
documenting where operations will live. RNZM-21 already owns the Phase 4 operations work.

**Alternative:** define `DeviceOperationsProtocol` now as the seam Phase 4 fills in. This
makes the separation explicit in code immediately, at the cost of an interface with no
implementations.

### 4.7 Enrichment mechanism — batched `getprop`

**Decision point D5.** Enrichment grows from 3 to 6 properties. Each `getprop` spawns an
`adb` process; 6 sequential spawns is meaningfully slower than one.

[ADR-005](../decisions/ADR-005-device-property-enrichment.md) pre-authorised this exact
revisit: *"Revisit if more than ~5 properties are needed: batch them into a single
`getprop` (no argument dumps all properties) and parse the output, rather than N calls."*
Six properties triggers that condition.

Proposal:

- Keep `getprop(deviceSerial:key:timeout:)` — the single-key primitive, already tested.
- Add `getSystemProperties(deviceSerial:timeout:)` — one `adb shell getprop`, parse the
  `[key]: [value]` lines into `[String: String]`, return the map.
- `DeviceEnricher` uses the batch call: **1 process spawn instead of 6.**

**Alternative:** keep 6 sequential `getprop` calls. Simpler, no new transport method, no
parser to test — at ~6× the process-spawn cost. Functionally adequate.

### 4.8 Error model

**No new `PixelDesktopError` cases required.** An unset property continues to map to
`invalidInput` (established in Phase 2 — `getprop` exits 0 for unset keys, so the exit code
cannot detect it). An unknown serial continues to map to `adbCommandFailed`.

For the three new properties, `make(...)` validates them the same way as the existing three:
trim, reject empty. Consistent with Phase 2 and simple to test.

### 4.9 Considered and rejected

| Candidate | Verdict |
|---|---|
| Rename `DeviceProperties` → `AndroidSystemProperties` | **Rejected.** Defensible name, ~40 test references, no correctness gain. Churn not justified. |
| Merge `DeviceProperties` into `AndroidDevice` | **Rejected.** They are a DTO and a domain model at different layers. `DeviceEnricher` maps between them; collapsing them would put transport-shaped data in the representation. |
| Add RAM / GPU / NPU / thermal / storage / battery | **Rejected.** No reliable static `getprop` source. Master prompt assigns thermal and memory to Phases 6/7 with their own acquisition work. |
| Add `InstalledApp` model | **Rejected for Phase 3.** Applications are Phase 4 (RNZM-21). The Phase 0 audit's §6.1 diagram listed `InstalledApp.swift`, but it was never implemented and belongs to Phase 4 if needed. |
| Add a `Video/`/scrcpy subsystem | **Rejected.** Never implemented; conflicts with the master prompt's "not a better scrcpy frontend" constraint. Audit §6.1 annotated accordingly. |
| Cache enriched properties across reconnects | **Deferred.** Phase 2 deliberately does not cache. Reconnect semantics belong to RNZM-22 (Phase 4), which must decide and record an ADR. |

---

## 5. Tests Required

### Hermetic (mock-based, no device) — the regression gate

| Test | Asserts |
|---|---|
| `DeviceProperties.make` — new fields | Trims and validates `marketingName`, `manufacturer`, `supportedABIs` |
| `DeviceProperties.make` — ABI list parsing | `"arm64-v8a,armeabi-v7a,armeabi"` → 3-element array; single-entry; rejects empty |
| `DeviceProperties.make` — rejects empty new fields | Each new field empty → `invalidInput` |
| `DevicePropertyKey` completeness | All 6 keys equal the approved `getprop` names |
| `DeviceCapabilities` | `supportedABIs` derived correctly; empty device → empty capabilities |
| `DeviceOperation` / `DeviceService` | Enum completeness; `availableServices == [.adb]` |
| `AndroidDevice.displayName` | Precedence: marketingName → codename → serial |
| `AndroidDevice` defect regression | `manufacturer` is **not** the codename; codename lives in `deviceCodename` |
| `DeviceEnricher` | Populates all 6 properties; preserves discovery-sourced identity; 3 existing tests updated |
| Batched `getprop` parser (if D5 accepted) | Parses `[key]: [value]` lines; handles missing keys, empty values, values containing `]`, extra whitespace, empty output |
| `testDiscoveryLeavesPropertiesUnpopulated` | **Must still pass** — discovery issues zero property reads |

All 46 existing hermetic tests must continue to pass.

### Real-device (opt-in, requires the Pixel attached)

| Test | Asserts |
|---|---|
| Enrichment on real device | All 6 properties non-empty and well-formed |
| ABI list sanity | `supportedABIs` contains `architecture` |
| Batched vs single read (if D5) | Batched map values equal single-key reads — the parser is not lying |
| Cross-check | Values match raw `adb` invoked outside project code |
| Defect regression on real hardware | `manufacturer` is not the codename; `marketingName` is not the codename |

Assertions check **well-formedness, never a pinned version** (ADR-006).

---

## 6. Real-Device Verification Required

| # | Verification | Status |
|---|---|---|
| 1 | Probe `ro.product.model`, `ro.product.manufacturer`, `ro.product.cpu.abilist` | **BLOCKED — device detached** |
| 2 | Confirm probe values, then implement against them | **BLOCKED** |
| 3 | Enrichment returns all 6 properties correctly | **BLOCKED** |
| 4 | Batched read agrees with single-key reads (if D5) | **BLOCKED** |
| 5 | Independent cross-check vs raw `adb` | **BLOCKED** |

**Blocker:** the Pixel 7a is physically disconnected (verified: `adb devices` empty, device
absent from the USB bus). Real-device verification needs the device reattached — a physical
action only you can perform.

**Consequence:** steps 1–2 gate the *implementation*, not just the verification. Per §5.1,
the three new properties must not be implemented against assumed values. The implementation
can be written against the identified keys, but cannot be declared complete until probed.

---

## 7. Decisions Requiring Your Approval

| # | Decision | Recommendation |
|---|---|---|
| **D1** | Rename `PixelDevice` → `AndroidDevice`, fix the two defects | **Approve.** Phase 3 is the device-model phase; master prompt says "an Android device" and plans for multiple. Reversible. |
| **D2** | Include minimal `DeviceCapabilities` (1 field) | **Approve.** Master prompt lists capabilities; `supportedABIs` is the only verifiable one. |
| **D3** | Include single-case `DeviceService` enum | **Your call.** Low value today; value is preventing a future phase from assuming an on-device service exists. |
| **D4** | `DeviceOperation` with only implemented operations; no operations protocol | **Approve.** Avoids advertising non-existent operations; no speculative interface. |
| **D5** | Batched `getprop` (1 spawn) vs 6 sequential calls | **Approve batched.** ADR-005 pre-authorised this at >5 properties; 6× fewer process spawns. |
| **D6** | Handle the detached-device blocker | **Needs you.** Reattach the Pixel 7a so the three new properties can be probed before implementation. |

---

## 8. Explicitly Not Doing in Phase 3

- No `shell()`, `push()`, `pull()` — Phase 4 (RNZM-21) / Phase 5 (RNZM-23)
- No lifecycle/state-machine work — Phase 4 (RNZM-22)
- No device operations of any kind
- No UI work. `ContentView` currently shows "Unknown" for enrichment fields until it calls
  `enrichDevice`; wiring that is **Phase 8** (master prompt: no UI that imitates unsupported
  backend functionality)
- No RAM/GPU/NPU/thermal/storage/battery fields
- No on-device service, no port forwarding, no HTTP, no networking
- No scrcpy/video subsystem
- No `InstalledApp` model

---

## 9. Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Device stays detached → new property values unverified | High | Medium | Block implementation-complete; do not assume values |
| A `getprop` key unset on the Pixel | Low | Medium | Probe first; drop the field and record the gap rather than defaulting |
| Rename churn introduces regressions | Low | Low | Compiler-verified; full suite rerun; 46-test gate |
| `supportedABIs` parser mishandles output | Low | Medium | Fixture-driven parser tests incl. values containing `]` |
| Capabilities/services/operations grow into speculative modelling | Medium | Medium | Each has a stated justification and an explicit exclusion list |

---

## 10. Phase 3 Completion Gate (planned)

```
Requirements:            master prompt §16 Phase 3 items, each with source + owner
Build:                   xcodebuild Debug
Tests:                   hermetic suite green (46 existing + new); real-device tests pass
Device verification:     6 properties read from the real Pixel 7a, cross-checked vs raw adb
Failure handling:        unset property rejected; unknown serial fails
Regression:              all Phase 2 tests pass, incl. discovery-issues-no-property-reads
Architecture review:     ADR for the model + separation decision
Documentation:           phase log, architecture/overview.md updated
AI development log:      updated
Known limitations:       documented
```

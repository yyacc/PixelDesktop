# Engineering Journal

Chronological record of the PixelDesktop build. Entries are appended, never rewritten.
Failures are recorded alongside successes: see `engineering/failures/`.

---

## 2026-10-01 — Phase 0: Clean-Start Engineering Audit

**Phase:** 0
**Task:** Establish project definition, audit the previous PixelDesktop implementation,
create the documentation structure and Multica phase structure.

**Action:**
Inspected the existing implementation at `~/Documents/PixelDesktop/`. Found all 20 Swift
source files at 0 bytes, a 39 KB binary that turned out to be an Xcode Previews stub
executor rather than a real application, and 9 legacy documentation files totalling
200+ KB. Inspected the working `AndroidMetadataHelper` Java APK. Checked Multica,
OpenCode, OMP and Ollama availability.

**Result:**
No salvageable source code existed. The legacy documentation was the only real asset.

**Decision:**
Treat PixelDesktop as a clean rebuild. Create the clean project at
`~/AICompany/PixelDesktop/` per the `~/AICompany/<project>` convention, leaving the old
project untouched as a source of engineering evidence.

**Reason:**
All implementation files were empty, so there was nothing to continue. The legacy docs
and the Android helper remained valuable and were carried forward as findings.

**Next action:** Phase 1 — create the clean native macOS project.

**Artifacts:** `phases/phase-00-clean-start-audit.md` (495 lines), ADR-001 through
ADR-004, `README.md`, `created-resources.json`, Multica RNZM-18.

---

## 2026-10-01 — Phase 1: Engineering Foundation

**Phase:** 1
**Task:** Create the clean native macOS project with source organisation, tests, build
configuration and documentation structure.

**Action:**
Created 12 Swift source files and a test file (31 tests). First attempted a hand-crafted
`pbxproj`, which failed with exit 74 (duplicate object IDs, missing build phases).
Abandoned it for xcodegen. Build failed with three errors: a `withTaskGroup` throwing
context, and two `@MainActor` isolation issues in default parameter values. Fixed all
three. Two tests then failed against the DTCA-1 specification and were corrected.

**Result:**
BUILD SUCCEEDED. 31/31 tests passing. 3 git commits on `main`.

**Decision:**
Use xcodegen for project generation. Never hand-craft `pbxproj`.

**Reason:**
The hand-crafted project had structural defects that took longer to diagnose than
adopting a generator would have taken. The generator produces a correct project
reproducibly from `project.yml`.

**Next action:** Phase 2 — device discovery and ADB transport.

**Artifacts:** `phases/phase-01-engineering-foundation.md` (308 lines),
`ai-development/ai-development-log.md`, Multica RNZM-19.

---

## 2026-10-01 — Phase 2: Blocker — Transport.swift corruption

**Phase:** 2 (BLOCKED)
**Task:** Add the Phase 2 transport surface to `Transport.swift`.

**Action:**
Attempted to write an expanded `Transport.swift` including a `DeviceProperties` struct.
The written file was 105,413 bytes across 227 lines: `DeviceProperties` opened at line 23
and never closed, with field names growing recursively by appending `PlatformVersion`.
Retried through `execute_code` and a shell heredoc; both reproduced the same defect.

**Result:**
Phase 2 blocked. The file could not have compiled.

**Decision:**
Stop all writes to the file. Preserve the corrupted artifact as evidence. Report the
diagnosis before modifying anything further.

**Reason:**
Three independent write mechanisms reproduced a *semantically* recursive pattern. A
serialization or filesystem fault would produce truncation or encoding damage, not
monotonically growing identifiers. The defect was in the generated content, and no write
mechanism could fix it.

**Next action:** Await user direction on the property model and the write problem.

**Artifacts:** `failures/FAIL-002-transport-swift-runaway-fields.md`.

---

## 2026-10-01 — Phase 2: Property model agreed; blocker resolved

**Phase:** 2
**Task:** Resolve the write problem, then implement device property enrichment.

**Action:**
Established provenance before touching anything: `git show HEAD:<path>` returned
**398 bytes of clean content**, and `git status --porcelain` showed the corruption was
**uncommitted**. Preserved the corrupted file to
`~/.hermes/cache/scratch/pd-evidence/Transport.swift.corrupted` with SHA-256
`3d9b46ee6df02a50689bac77c0e624a5e7bdd83b89407cb8918b4fced5b810a8`. Recovered the clean
file with `git checkout HEAD --`. Probed the real device before designing: `getprop`
returned Android `16`, API `36`, ABI `arm64-v8a`, and an unset key returned exit 0 with
empty output.

**Result:**
Blocker resolved in seconds. The probe invalidated two Phase 1 assumptions (`14`/`34`)
and revealed the exit-0-on-unset behaviour that shaped the validation design.

**Decision:**
Adopt the approved minimal 3-field `DeviceProperties`. Reject the ~50-field design.
Use targeted `patch` for all edits to existing files. Validate emptiness explicitly,
because exit code cannot detect an unset property.

**Reason:**
The oversized design gave the generation defect room to run; a minimal model fails
cheaply. Git recovery was exact and verifiable, so hand-reconstruction was unnecessary.

**Next action:** Implement enrichment.

---

## 2026-10-01 — Phase 2: Implementation and verification

**Phase:** 2
**Task:** Implement `getprop`, `DeviceProperties`, enrichment, tests, and real-device
verification.

**Action:**
Added `getprop` to `TransportProtocol` and implemented it in `ADBTransport` over the
existing `execute()` path. Added `DeviceProperties` (3 fields, throwing `make`) and
`DevicePropertyKey`. Created `DeviceEnricher` depending on `TransportProtocol`.
Widened `DeviceManager` to `TransportProtocol` and added `enrichDevice(serial:)`.
Added 15 mock-based tests and 3 opt-in integration tests with `MockTransport`.

Mid-implementation, `enrichDevice` was first placed on `ADBTransport`; on review it was
removed and moved to `DeviceEnricher`, because it is device modelling rather than
transport, and its presence on the transport would have made it untestable without a
device.

`xcodebuild ... test TEST_RUNNER_PIXELDESKTOP_DEVICE_SERIAL=...` did not forward the
variable, so the integration tests reported "skipped". Rather than claim an unexecuted
real-device pass, compiled the production sources with `swiftc` into a CLI harness and ran
it against the device.

**Result:**
BUILD SUCCEEDED. 49 tests executed, 0 failures (3 integration tests skipped by design).
Real-device verification PASS: Android `16`, API `36`, `arm64-v8a`, with
`CROSS-CHECK MATCH: true` against raw `adb`. Both failure paths confirmed on the real
device: unset property rejected, unknown serial fails.

**Decision:**
Phase 2 COMPLETE. Enrichment is explicit and off the discovery poll. UI wiring of
`enrichDevice` deferred to Phase 8.

**Reason:**
All 8 phase requirements met with evidence. Keeping enrichment off the poll interval
avoids 3 ADB round trips per 5 seconds for values that cannot change while the device is
booted.

**Next action:** Phase 3 — Android Device Model, consuming `DeviceProperties`.

**Artifacts:** `phases/phase-02-device-discovery.md`, ADR-005, ADR-006,
`testing/phase-02-test-report.md`, `best-practices/techniques.md`,
`failures/FAIL-001-non-english-output.md`, `failures/FAIL-002-transport-swift-runaway-fields.md`.

---

## 2026-10-01 — Phase 2 close-out: phase-numbering resolution

**Phase:** 2 (close-out)
**Task:** Resolve the phase-numbering ambiguity discovered when "proceed to Phase 3" proved
to have four possible meanings.

**Action:**
Inspected all four documents that number phases: the master engineering prompt §16, the
Phase 0 audit §9, the legacy compute-node course-of-action, and two legacy coding-agent
documents. Built mapping tables between them. Verified that the Phase 0 audit's §9 table
omits three master-prompt phases and misassigns Phase 4. Confirmed via grep that **no
existing document recorded the mismatch** — the root cause of the ambiguity.

**Result:**
Four incompatible schemes identified on three unrelated axes (product, compute-workload,
agent-tooling). The master prompt §16 is authoritative.

**Decision:**
Record as ADR-007. Annotate the Phase 0 audit §9 as superseded without rewriting its
evidence. Preserve legacy documents' original numbering unmodified; translate references
through the mapping tables. Create `engineering/architecture/` with the architecture
**as delivered**, and annotate the audit's aspirational §6.1 diagram.

**Reason:**
The master prompt is the commissioning document, the only source with complete per-phase
objectives, and its §17 gate is binding. Renumbering legacy documents would destroy their
historical accuracy and internal cross-references.

**Next action:** Phase 3 proposal.

**Artifacts:** `decisions/ADR-007-authoritative-phase-sequence.md`,
`architecture/overview.md`, audit §9 and §6.1 annotations, Multica RNZM-21/22/23.

---

## 2026-10-01 — Deferred Phase 2 work recorded as follow-up issues

**Phase:** 2 (close-out)
**Task:** Record the functionality deferred from Phase 2 as explicit follow-up work, not
silently-dropped scope.

**Action:**
Created three Multica issues against the authoritative phase numbers and linked them from
RNZM-20.

**Result:**
RNZM-21 (`shell()` → Phase 4), RNZM-22 (lifecycle → Phase 4, hardened in 10),
RNZM-23 (`push()`/`pull()` → Phase 5). None marked completed.

**Decision:**
Target phases taken from ADR-007's mapping, not the stale audit table — which would have
placed this work in the wrong phases.

**Next action:** Phase 3 proposal.

---

## 2026-10-01 — Phase 3 proposal produced (no code changed)

**Phase:** 3 (proposal)
**Task:** Produce a Phase 3 implementation proposal for the Android Device Model.

**Action:**
Inspected `PixelDevice`, `DeviceManager`, `DeviceProperties`, `DeviceEnricher`,
`TransportProtocol` and the master prompt's Phase 3 requirements. Attempted to probe three
candidate properties on the real device; **the probe failed because the Pixel 7a is
physically disconnected** (`adb devices` empty, absent from the USB bus). Traced the blast
radius of the two defects found in the current model.

**Result:**
Proposal produced. Two model defects found: `manufacturer` holds the device *codename*
(`lynx`), not a manufacturer — and `ContentView:110` renders it as "Manufacturer", so the
UI currently displays a falsehood; and `model` holds the codename while the marketing name
is absent.

**Decision:**
Propose growing `DeviceProperties` 3 → 6 fields, renaming `PixelDevice` → `AndroidDevice`,
adding minimal `DeviceCapabilities`, and keeping representation free of operations. Six
decision points raised for review. **No source file modified.**

**Reason:**
Master prompt §5.1 forbids implementing against assumed values. Three of the six proposed
properties are unverified on real hardware, so implementation cannot be declared complete
until the device is reattached.

**Next action:** Await review of the proposal and reattachment of the Pixel 7a.

**Artifacts:** `phases/phase-03-android-device-model-proposal.md`.

---

## 2026-10-01 — Phase 3: Android Device Model

**Phase:** 3
**Task:** Build the device representation: correct identity, verified properties, minimal
capabilities, and separate discovery / representation / operations.

**Action:**
Attempted the required real-device probe; the Pixel 7a was **physically disconnected**, so
per D6 implementation was withheld rather than written against assumed values. After
approval and reattachment, probed `ro.product.model` (`Pixel 7a`),
`ro.product.manufacturer` (`Google`), `ro.product.cpu.abilist` (`arm64-v8a`) and
`ro.product.device` (`lynx`), and re-probed the Phase 2 properties as a cross-check.

Implemented: `DeviceProperties` 3 → 6 fields; `PixelDevice` → `AndroidDevice` with
`deviceCodename` / `marketingName` / `manufacturer` / `supportedABIs`; `DeviceCapabilities`
(`supportedABIs` only); `DeviceOperation` (`.discover`, `.readSystemProperties`);
`TransportProtocol.getSystemProperties` batched read plus `parseSystemProperties`. Removed
the superseded `PixelDevice.swift` with `git rm`. `DeviceService` not added (D3 deferred).

The device detached again during the first live verification run. Rather than claim an
unexecuted pass, replayed the device's captured real `getprop` output through the real
pipeline (13/13 checks passed) and retained it as a permanent hermetic test. Re-ran live
verification after reattachment.

**Result:**
BUILD SUCCEEDED. 73 tests executed, 0 failures. Live real-device verification PASS:
`Pixel 7a` / `Google` / `lynx` / Android `16` / API `36` / `arm64-v8a`, all 6 properties
cross-checked against raw `adb`. Batched read measured **3.7× faster** (0.095 s vs 0.354 s)
and agrees with single-key reads 6/6.

**Decision:**
Phase 3 COMPLETE. Two identity defects fixed: `manufacturer` no longer holds the codename,
and the marketing name is now modelled.

**Reason:**
The defects were identity defects — fixing them required distinguishing codename from
marketing name from manufacturer, which is a model-shape change. The rename matches the
master prompt's "an Android device" and its plan for multiple Android devices.

**Next action:** Phase 4 (Android Application / Process Control) — RNZM-21 `shell()`,
RNZM-22 lifecycle. Phase 4 must extend `DeviceOperation` and decide whether reconnect
invalidates cached properties.

**Artifacts:** `phases/phase-03-android-device-model.md`, ADR-008,
`testing/phase-03-test-report.md`, `architecture/overview.md` updated.

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

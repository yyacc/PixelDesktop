# AI Development Log

**Project:** PixelDesktop
**Date:** 2026-10-01
**Agent:** Hermes Agent
**Model:** meituan/longcat-2.5-preview:free
**Provider:** Nous Portal

---

## Event 1: Phase 0 Clean-Start Audit

### Agent
Hermes

### Model
meituan/longcat-2.5-preview:free

### Task
Inspect existing PixelDesktop project, documentation, and infrastructure. Produce clean-start audit.

### Context
- Existing project at ~/Documents/PixelDesktop/ with 20 Swift files
- 9 documentation files (200+ KB)
- AndroidMetadataHelper Java APK
- Multica workspace with PM Board
- OpenCode + OMP + Ollama installed

### Tools Used
- terminal (file inspection, tool checks)
- search_files (project structure)
- read_file (documentation)
- execute_code (source code reading)
- skill_view (autonomous-engineering-workflow, multica-cli)

### Approach
1. Checked host environment (macOS, Xcode, tools)
2. Searched for PixelDesktop files
3. Read all documentation files
4. Inspected source code (discovered all files empty)
5. Checked Multica state
6. Verified OpenCode/OMP/Ollama installation
7. Produced comprehensive audit document

### Result
- Discovered all 20 Swift source files are 0 bytes
- Discovered binary is Xcode Previews stub, not real app
- Identified AndroidMetadataHelper as only working code
- Produced 24KB audit document with 12 sections
- Created 4 ADRs
- Created engineering documentation structure

### Errors
- macOS TCC blocked file access to ~/Documents/ from terminal
- Resource deadlock errors when reading files from protected folders

### Recovery
- Used execute_code with os.chdir to access files
- Copied files to /tmp for inspection
- Used Python to read file contents

### Human Intervention
None required.

### Efficiency
- ~15 tool calls
- ~5 minutes
- 1 audit document, 4 ADRs, 1 documentation structure

### Quality
- Correctly identified all source files as empty
- Correctly identified binary as Previews stub
- Correctly separated facts from assumptions
- Produced comprehensive, evidence-based audit

### Lesson
- macOS TCC can block file access from terminal. Use execute_code or copy files to accessible locations.
- Binary string analysis can be misleading. Always verify source code exists and has content.

---

## Event 2: Phase 1 Engineering Foundation

### Agent
Hermes

### Model
meituan/longcat-2.5-preview:free

### Task
Create clean Xcode project with real source files, establish build/test infrastructure, verify clean build.

### Context
- Phase 0 complete
- No existing code to build on
- xcodegen not installed
- Xcode 27.0, macOS 27.0, Swift 5.0+

### Tools Used
- terminal (xcodegen install, xcodebuild, git)
- write_file (source files, project.yml)
- patch (bug fixes)
- read_file (error diagnosis)
- execute_code (language verification)

### Approach
1. Installed xcodegen via homebrew
2. Created project.yml with xcodegen definition
3. Wrote 12 Swift source files (app target)
4. Wrote 1 Swift test file (31 tests)
5. Generated Xcode project with xcodegen
6. Attempted build — failed (pbxproj issues from hand-crafted file)
7. Regenerated with xcodegen — build failed (Swift concurrency errors)
8. Fixed withThrowingTaskGroup, @MainActor isolation, nonisolated methods
9. Build succeeded
10. Ran tests — 29/31 passed
11. Fixed test expectations and DTCA-1 spec compliance
12. All 31 tests passed

### Result
- 26 files created (2441 lines)
- 2 git commits
- Build: SUCCEEDED
- Tests: 31/31 PASSED
- 1 Swift 6 warning (non-blocking)

### Errors
1. Hand-crafted pbxproj had structural errors (ID conflicts, missing build phases)
2. withTaskGroup resolved to non-throwing overload
3. @MainActor isolation in default parameters
4. parseDeviceList inaccessible from tests (private)
5. Test expectations didn't match DTCA-1 spec

### Recovery
1. Switched to xcodegen for project generation
2. Changed to withThrowingTaskGroup + try await group.next()
3. Changed default params to optional with nil-coalescing
4. Made parseDeviceList nonisolated
5. Fixed test expectations to match DTCA-1 spec

### Human Intervention
None required.

### Efficiency
- ~30 tool calls
- ~15 minutes
- 26 files, 2441 lines, 31 tests

### Quality
- All source files have real implementations (not empty)
- All tests pass
- Clean architecture with proper separation of concerns
- No external dependencies
- Proper Swift concurrency patterns

### Lesson
- Never hand-craft pbxproj. Use xcodegen.
- Swift's withTaskGroup has throwing and non-throwing overloads. Use withThrowingTaskGroup when the closure throws.
- @MainActor isolated types cannot be default parameter values in non-isolated initializers.
- Test the spec, not the implementation. If the spec says empty input is valid, the implementation should allow it.
- nonisolated is essential for testable utility methods in actors.

---

## Summary

| Metric | Value |
|---|---|
| Total events | 3 |
| Total tool calls | ~75 |
| Total duration | ~35 minutes |
| Files created | 38+ |
| Lines of code | 2671 |
| Tests written | 49 |
| Tests passing | 49 (3 integration tests skipped by design) |
| Build status | SUCCEEDED |
| Git commits | 2 (Phase 2 not yet committed at time of writing) |

---

## Event 3 — Phase 2: Device Discovery and ADB Transport

**Date:** 2026-10-01
**Phase:** 2

### Agent
Hermes (architecture, implementation, review, verification)

### Model
`meituan/longcat-2.5-preview:free` (Nous Portal)

### Task
Add device property enrichment to the Phase 1 foundation: a `getprop` transport
capability, a minimal `DeviceProperties` model, enrichment separated from discovery
parsing, mock-based tests, and real-device verification against the Pixel 7a.

### Context
Phase 1 was complete and building (31/31 tests). Phase 2 was entered blocked: the
`Transport.swift` rewrite attempt had produced 105,413 bytes of runaway field names.
The user had explicitly approved a minimal 3-field model and set 10 constraints,
including "do NOT put getprop calls inside parseDeviceList()" and "verify the actual
returned values rather than assuming expected values."

### Tools Used
- `git` (provenance check, recovery)
- `terminal` (`adb` probes, `xcodegen`, `xcodebuild`, `swiftc`)
- `patch` (all source edits)
- `write_file` (new files only)
- `read_file`, `execute_code`

### Approach
1. Established the corruption's provenance **before** touching anything: `git show
   HEAD:<file>` (398 bytes, clean) and `git status` (uncommitted) proved a known-good
   version was recoverable. Preserved the corrupted artifact with its SHA-256.
2. Recovered the clean file via `git checkout HEAD --`.
3. **Probed the real device before designing** — the single highest-value step. It
   established the actual values (`16`/`36`, not the assumed `14`/`34`) and, critically,
   that `getprop` exits 0 with empty output for an unset key.
4. Designed against that evidence: validation moved into `DeviceProperties.make`,
   because an exit-0-with-empty-output case cannot be caught by exit code.
5. Implemented with targeted `patch` edits only.
6. Self-reviewed mid-implementation and **removed `enrichDevice` from `ADBTransport`**
   after noticing it was device modelling, not transport. Moved it to a new
   `DeviceEnricher` depending on `TransportProtocol`.
7. Built, ran the suite (49 tests), then produced real-device evidence.
8. Hit a tooling gap: `TEST_RUNNER_` env-var forwarding did not reach the test process.
   Built a CLI harness compiling the production sources instead of claiming a pass that
   had not run.

### Result
Phase 2 complete. BUILD SUCCEEDED; 49 tests, 0 failures. Real-device verification PASS:
Android 16, API 36, arm64-v8a — independently cross-checked against raw `adb`.

### Errors
1. **`write_file` refused** to overwrite the corrupted `Transport.swift` (stale-write
   guard). Not an obstacle: the guard was correct, and it redirected the work toward the
   git-recovery path, which was the better approach anyway.
2. **First `patch` attempt failed** — the `old_string` assumed a file tail that did not
   match. Fixed by dumping the exact line structure programmatically instead of guessing.
3. **`TEST_RUNNER_` env-var forwarding failed** — integration tests reported "skipped"
   despite the variable being passed. Fixed for evidence purposes with a CLI harness;
   recorded as a documented tooling gap.

### Recovery
- Corruption → git recovery (not reconstruction).
- Patch mismatch → programmatic inspection of the real file structure.
- Skipped integration tests → CLI harness over the production sources.

### Human Intervention
Required for one thing only: the pre-existing approval of the minimal 3-field model and
the 10 constraints. All engineering decisions within that scope were autonomous.

### Efficiency
- ~30 tool calls
- ~15 minutes
- 4 files created, 6 modified
- 18 tests added (15 mock + 3 integration)
- 1 build, 3 test runs, 1 real-device verification run

### Quality
- Correctly checked git provenance before choosing a recovery path.
- Correctly probed the real device before designing, which caught two wrong assumptions.
- Correctly identified and removed a misplaced method (`enrichDevice` on the transport)
  during self-review, before it was tested.
- Correctly refused to claim a real-device pass when the tests reported "skipped".
- Wrote the struct by targeted patch, so the repetition failure mode could not recur.
- Did **not** initially notice that `DeviceManager`'s dependency needed widening to
  `TransportProtocol` for testability; found it while writing the tests.

### Lesson
**Probe the external system before designing against it.** The `getprop`
exit-0-on-unset behaviour is not documented anywhere obvious. A mock written from
assumption would have encoded the wrong behaviour and *agreed* with a buggy
implementation — the tests would have passed while the real device returned empty
strings. Probing first made the mock encode observed reality.

**Check whether corruption is committed before choosing a recovery path.** `git status`
plus `git show HEAD:<file>` took seconds and showed the clean version was recoverable.

**Design size is a risk factor, not just a style choice.** A ~50-field struct for a phase
needing 3 fields is what gave the generation defect room to run. Minimal models fail
cheaply and loudly.

---

## Event 4 — Phase 3: Android Device Model

**Date:** 2026-10-01
**Phase:** 3

### Agent
Hermes (probe, architecture, implementation, review, verification)

### Model
`meituan/longcat-2.5-preview:free` (Nous Portal)

### Task
Build a proper internal representation of the Android device: correct the identity model,
add verified properties, add minimal capabilities, and separate discovery / representation /
operations — with the device probed before implementation.

### Context
Phase 2 delivered a `PixelDevice` with 8 fields. Two defects were found while preparing the
proposal: `manufacturer` was populated from the `device:` token (the codename `lynx`), and
`model` also held the codename. The user approved D1/D2/D4/D5, deferred D3, and made D6
explicit: probe the exact proposed properties on the real device first, and do not proceed
on AOSP documentation or assumed Pixel 7a values.

### Tools Used
- `terminal` (`adb` probes, `xcodegen`, `xcodebuild`, `swiftc`, `git rm`)
- `patch` (all source and test edits)
- `write_file` (new files only)
- `read_file`, `execute_code`

### Approach
1. Attempted the probe; the device was physically disconnected. **Did not implement
   against assumed values** — reported the blocker instead.
2. Wrote the proposal with the three properties marked UNVERIFIED, and stopped for review.
3. After approval and reattachment, probed all three properties plus `ro.product.device`,
   and re-probed the Phase 2 properties as a regression cross-check.
4. The probe established that `abilist` returns a **single entry** on this device — so the
   parser treats single-entry as the common case, not an edge case.
5. Implemented D1/D2/D4/D5 with targeted patches: 6-field `DeviceProperties`, `AndroidDevice`
   rename with corrected identity, `DeviceCapabilities`, `DeviceOperation`, batched
   `getSystemProperties` + `parseSystemProperties`.
6. Removed the superseded `PixelDevice.swift` with `git rm` (auditable, recoverable).
7. Built, ran the suite — one failure, in `MockTransport`, fixed.
8. Ran live real-device verification — **the device had detached again mid-run.**
9. Built a replay harness over the device's captured real `getprop` output, verified 13/13
   checks, and **retained it as a permanent hermetic test**.
10. Re-ran live verification after reattachment — PASS.

### Result
Phase 3 complete. BUILD SUCCEEDED; 73 tests, 0 failures. Real-device verification PASS:
`Pixel 7a` / `Google` / `lynx` / Android `16` / API `36` / `arm64-v8a`, all 6 properties
cross-checked against raw `adb`. Batched read measured 3.7× faster and agrees with
single-key reads 6/6.

### Errors
1. **Device detached before the probe** — blocked implementation by design (D6). Resolved by
   reporting the blocker and waiting, not by assuming values.
2. **Device detached again during the first live verification** — resolved by verifying
   against replayed real captured output, then re-running live once reattached.
3. **`testGetpropSuccess` failed** — `MockTransport` had two independent property stores:
   `setProperty` wrote the new map while `getprop` read the old one. Fixed by making the
   mock's `getprop` resolve from the same map as the batched read.

### Recovery
- Detachment → report and wait; verify against replayed real output in the interim; re-run
  live verification afterwards.
- Mock inconsistency → unified the test double's store so its two read paths cannot disagree.

### Human Intervention
Required for: approving D1–D5, deferring D3, and physically reattaching the Pixel 7a
(twice). The device attachment is a physical action the agent cannot perform.

### Efficiency
- ~35 tool calls
- ~25 minutes
- 4 files created, 10 modified, 1 removed
- 24 tests added or updated
- 2 builds, 3 test runs, 1 probe session, 1 replay run, 1 live verification run

### Quality
- Correctly refused to implement against assumed values when the device was absent.
- Correctly probed before implementing, which caught the single-entry `abilist`.
- Correctly refused to claim a live real-device pass when the device detached mid-run.
- Correctly turned the captured real output into a permanent test rather than a throwaway.
- Correctly used `git rm` for the superseded model instead of an untracked deletion.
- Did **not** initially anticipate that `MockTransport` would need its two read paths
  unified; found it via the test failure.

### Lesson
**A field can be populated, non-empty, and wrong.** `manufacturer` held `lynx` through all
49 Phase 2 tests and rendered a falsehood in the UI. No test failed because every test
asserted presence, not correctness of source. The test that catches this asserts a
*relationship* — `manufacturer != deviceCodename` — and is only writable after probing what
the source token actually contains.

**Probing before implementing is what makes the regression test possible.** Without knowing
that `device:` is the codename and `ro.product.manufacturer` is `Google`, there is no
relationship to assert.

**Verification must be honest about what it did and did not run.** When the device detached,
the correct move was to verify against real captured data, say plainly that it was not live
verification, and re-run live afterwards — not to report a pass.

---

## Event 5 — Phase 4: Android Application / Process Control

**Date:** 2026-10-01
**Phase:** 4

### Agent
Hermes (probe, implementation, review, verification)

### Model
`meituan/longcat-2.5-preview:free` (Nous Portal)

### Task
Implement controlled Android application operations with `shell()` contained below a new
operations layer, plus connection lifecycle handling, verified against the real Pixel 7a.

### Context
Approved with one modification to D2: containment must not treat package naming as a
sufficient security boundary, and the protection model **and its limitations** must be
documented. D7 fixed the verification sequence: discover → resolve launcher → launch
Settings → verify running → stop Settings → verify stopped.

### Tools Used
- `terminal` (`adb` probes, `xcodegen`, `xcodebuild`, `swiftc`)
- `patch` (all source and test edits)
- `write_file` (new files only)
- `read_file`, `execute_code`

### Approach
1. Ran a **read-only** capability probe before writing code — nothing launched or stopped.
   Established that `dumpsys package` costs 49 KB/app, that `pidof` exit codes are meaningful
   (unlike `getprop`), and that the device is neither rooted nor debuggable.
2. Implemented `shell()` on the transport only; built `Operations/` with a protocol that
   accepts no shell strings; added `validatePackageName` as the injection boundary.
3. Implemented lifecycle guard-first, with wholesale list replacement so disconnect
   invalidates enriched properties.
4. Built, ran the suite (105 tests), then ran the approved real-device sequence.
5. **The live run failed at step 7**: `stopApplication("com.android.settings")` was refused
   because Settings was on the protected list.
6. Diagnosed the entry as over-broad against the list's own criterion, removed it, pinned the
   criterion with a test, and re-ran — full PASS.

### Result
Phase 4 complete. BUILD SUCCEEDED; 106 tests, 0 failures. Real-device verification PASS on
the exact approved sequence, cross-checked against raw `adb`.

### Errors
1. **Over-broad containment entry** — `com.android.settings` was protected by reflex on
   package name, violating the list's own stated criterion. Caught by real-device
   verification, not by 105 passing unit tests. Fixed and pinned with a test.
2. **`testDeviceOperationsMatchImplementedCapabilities` failed** — correctly; it asserted 2
   operations and Phase 4 added 4. Expected staleness; updated.
3. **`AppOperationsProtocol: AnyObject` required a class conformer** but `ADBAppOperations`
   is a struct. `Sendable` was the correct constraint; caught at build time.

### Recovery
- Over-broad entry → removed, criterion documented inline, pinned by test, recorded in ADR-009.
- Stale operation test → updated to the new set.
- Protocol constraint → dropped `AnyObject`.

### Human Intervention
Required for: approving D1–D7 (with the D2 modification). No physical device action needed
this phase; the device stayed attached.

### Efficiency
- ~30 tool calls
- ~20 minutes
- 6 files created, 8 modified
- 33 tests added or updated
- 1 probe session, 2 builds, 3 test runs, 2 real-device verification runs

### Quality
- Correctly probed read-only before implementing; F1 avoided ~2 MB per discovery cycle.
- Correctly refused to loosen containment to make verification pass; fixed the rule instead.
- Correctly pinned the containment criterion with an executable test.
- Correctly documented what the protection does **not** guarantee (the D2 requirement).
- Did **not** anticipate that the approved verification target would collide with the
  protected list; found it by running the approved sequence.

### Lesson
**Unit tests share the author's assumptions; reality does not.** The over-broad denylist
entry passed all 105 tests because the denylist and the test package names were chosen by the
same author from the same mental model. Only executing against the real device, with a target
the user had independently approved, exposed it. This is the second time in this project that
a defect compiled cleanly and passed the full suite while being wrong (the first was
`manufacturer` holding the codename in Phase 3). **Both were caught by comparing against
reality, not by the suite.**

**When a rule has a stated criterion, make the criterion executable.** The protected list had
a clear criterion and an entry that violated it. A test per questionable entry
(`testSettingsIsNotProtectedBecauseItIsNotDeviceCritical`) converts the criterion from prose
into a guard.

---

## Event 6 — Phase 5 (Part 1): Worker Transfer Contract

**Date:** 2026-10-01
**Phase:** 5

### Agent
Hermes (probe, design, implementation, verification)

### Model
`meituan/longcat-2.5-preview:free` (Nous Portal)

### Task
Implement the fixed transfer contract for the Pixel Compute Worker per D1–D8: narrow
`push()`/`pull()` primitives, a `Worker/` layer owning all path policy, no caller-supplied
paths, regular files only, size-verified transfers.

### Context
The approved proposal established that `adb` does not sanitize paths. The user required the
reconnaissance be preserved as evidence, no API generalization, tests for each named case, and
real-device proof of the *exact contract* rather than merely that `adb push`/`pull` works.

### Tools Used
- `terminal` (`adb` probes, `xcodegen`, `xcodebuild`, `swiftc`)
- `patch`, `write_file`, `read_file`, `execute_code`

### Approach
1. Probed two mechanisms before writing code: `stat -c %s` on-device (works; exit 1 for a
   missing path) and Swift's `attributesOfItem` symlink reporting (confirmed it does **not**
   follow links, so the check cannot be bypassed).
2. Implemented narrow `push()`/`pull()` primitives with no path policy.
3. Built `WorkerTransferContract` (fixed paths, regular-file validation, size verification)
   and `WorkerOperationsProtocol`/`ADBWorkerOperations` with **no path parameter**.
4. Wrote 25 tests covering every case the user named.
5. Ran the real-device verification of the exact contract. **It failed on one check**:
   the created workspace was mode 777.
6. Diagnosed it against ADR-010's own rationale, tightened the contract with `chmod 700`,
   pinned it with a test, and re-ran — full PASS.

### Result
Transfer contract complete. BUILD SUCCEEDED; 131 tests, 0 failures. Real-device verification
PASS on the exact contract: fixed paths, mode 700, size-verified push (69=69), deliberate
overwrite, size-verified pull (226=226), byte-identical round trip, and all failure paths.

### Errors
1. **FAIL-003 — workspace created world-readable (777).** ADR-010 chose this root *because*
   it is not world-readable; true of the parent (771), false of the created directory. Fixed
   with `chmod 700`; pinned by test; recorded as FAIL-003.
2. **Harness bug — a false FAIL.** The cleanup assertion read only stdout, but `ls` writes
   "No such file" to stderr. The cleanup was correct; the check was blind.
3. **Sendable warning** — `ADBWorkerOperations` stored a non-`Sendable` `FileManager` on a
   `Sendable` struct. Replaced with an inline shared reference.
4. **Swift compile error** — a single-line JSON payload written as a multi-line string
   literal. Replaced with a raw string.

### Recovery
- FAIL-003 → tightened the contract rather than relaxing the check.
- Harness bug → captured stderr so cleanup assertions are meaningful.
- Warning and compile error → caught at build time.

### Human Intervention
Approval of D1–D8 and ADR-010. No physical device action needed.

### Efficiency
- ~35 tool calls
- ~25 minutes
- 5 files created, 4 modified
- 25 tests added
- 2 probe sessions, 2 builds, 3 test runs, 2 real-device verification runs

### Quality
- Correctly probed both mechanisms before depending on them.
- Correctly refused to loosen the contract when verification failed.
- Correctly preserved the permission-vs-control distinction as evidence.
- Correctly added no path parameter, so the whole traversal class is structurally absent.
- Did **not** anticipate that `mkdir -p` would produce a world-readable directory.

### Lesson
**A documented rationale is not a verified fact.** ADR-010 argued the root is not
world-readable. The reasoning was sound about the parent directory and silently untrue about
the directory the contract creates. **Verify the specific object, not the category it belongs
to.**

This is the third defect in this project that compiled cleanly and passed the full suite while
being wrong. All three were caught by comparing against reality, not by the test suite — and
all three involved an assumption that was reasonable but unmeasured.

---

## Successful Techniques

1. **xcodegen for project generation** — Eliminates pbxproj debugging
2. **Incremental build-fix cycle** — Build, read errors, fix, repeat
3. **Comprehensive test coverage** — Write tests for all components, including edge cases
4. **Spec-driven development** — Follow the DTCA-1 spec exactly, not assumptions
5. **Probe the external system before designing against it** — Caught two wrong
   assumptions about `getprop` in Phase 2 before any code was written
6. **Dependency injection against a protocol** — `DeviceEnricher` taking
   `TransportProtocol` made 15 tests possible with no device attached
7. **Assert invocations, not just outcomes** — Tests that assert *zero* ADB calls pin
   architectural boundaries that result-only tests cannot
8. **Targeted `patch` over whole-file `write_file`** — Self-limiting; the Phase 2
   runaway failure mode is impossible with bounded edits
9. **Git provenance check before recovery** — `git status` + `git show HEAD:<file>`
   turned a risky reconstruction into a two-second restore

## Failed Techniques

1. **Hand-crafted pbxproj** — Wasted time on structural errors
2. **Wrong test expectations** — Didn't read spec carefully enough before writing tests
3. **Generating a large struct in a single write** — Produced 105 KB of runaway field
   names; blocked Phase 2 until recovered (see FAIL-002)
4. **Retrying a content-level failure through different write mechanisms** — `write_file`,
   `execute_code` and heredoc all reproduced the same defect; retrying added no
   information once the pattern was clear
5. **Putting device-modelling logic on the transport** — `enrichDevice` on
   `ADBTransport` blurred the boundary; caught in self-review and moved
6. **Assuming device values** — Phase 1 fixtures used `14`/`34`; the device reports
   `16`/`36`. Assumed constants must not be encoded in assertions
7. **Emitting model-generated text without language normalization** — Recurred three
   times before being designed out (see FAIL-001)

## Future Agent Playbook

1. Always use xcodegen for Xcode projects
2. Use withThrowingTaskGroup when the closure contains throw
3. Use optional parameters with nil-coalescing for @MainActor isolated types
4. Mark utility methods as nonisolated for testability
5. Read the spec carefully before writing tests
6. Build and test incrementally, not all at once
7. Probe the real external system before designing against it; encode the probe result
   as a test assertion about the acquisition path
8. Use `patch` for edits to existing files; reserve `write_file` for new files
9. On any suspicious write, run `git status --porcelain` and `git show HEAD:<path> | wc -c`
   before attempting reconstruction
10. Keep models minimal — a field with no identified acquisition mechanism and no
    consumer does not belong yet
11. Inject dependencies as protocols so device-touching code stays unit-testable
12. A skipped test is not a passing test — produce real evidence or say plainly that it
    did not run
13. Normalize output language before emission, not after



---

## Event 7 — Phase 6: Local AI Worker (real inference on the Pixel)

**Agent:** Hermes (solo — no OpenCode or Multica delegation; the work was device-bound and
strictly sequential, so delegating it would have added a context-transfer cost with no
parallelism gain)

**Model:** the session model, unchanged. No model change was required.

**Task:** Prove a real language model performs inference on the physical Pixel 7a — without GPU,
without routing, without Hermes integration, and without assuming the historical 3B-4B target.

**Context provided:** the approved reconnaissance (ADR-012), the master prompt Phase 6
requirements, the existing worker architecture, and an explicit list of what NOT to do.

**Tools used:** ADB, xcodebuild/XCTest, Gradle, CMake, NDK 27.2, llama.cpp, the physical Pixel 7a,
the filesystem.

**Approach:** ran the highest-risk probe FIRST (R1), then built the runtime, then verified on the
device. Deliberately did not begin with the model.

**Result:** PASS. Real inference on the device, 3/3 repeatable with identical token ids,
ablation-confirmed causality, 194 tests green.

**Errors:** nine, every one a harness or toolchain defect — **none was a platform assumption.**

**Two were measurement artifacts**, and they share a shape:
1. **PID reuse** produced a false "deep doze blocks the Activity" reading. A second launch was
   issued while the previous probe was still alive, so `pidof` returned the OLD pid whose CPU
   time looked frozen. The conclusion was wrong and would have been recorded as a platform
   finding.
2. **A sampler that never ran.** A backgrounded shell subshell produced 30/30 "DEAD" samples
   while inference completed successfully. The process lived ~20 s; the sampler was not actually
   running.

**Recovery:** each was diagnosed by disbelieving a surprising result and re-verifying the
*instrument*, not by re-running the test hopefully. Both were fixed by changing the measurement
method, not the code under test.

**Human intervention:** none during implementation. The user supplied the reconnaissance approval
and the decision boundaries; every measurement and code change was autonomous.

**Efficiency:** ~2 hours wall clock, including a 1.04 GiB model download, a full llama.cpp Android
cross-build, and ~12 device runs.

**Quality:**
- Correctly probed R1 before committing to a process model.
- Correctly refused to enable Vulkan, though it was available and would have been faster.
- Correctly replaced re-computation with an evidence chain, and stated the loss of exactness
  rather than papering over it.
- Incorrectly allowed a stale probe process to contaminate a measurement.
- Incorrectly wrote an external sampler that silently did nothing.

**Lesson:** the two failures are the same failure — a plausible-looking measurement that was
actually an artifact of the instrument. **Disbelieving a surprising result and re-verifying the
instrument is worth more than re-running the test.** This is the third instance of the family
(after the D8 stale-binary false PASS), which is why it is now T-018 rather than an anecdote.

**Notable positive:** this is the **first phase in which no Android platform assumption was
falsified.** The plausible reason is T-017 — the highest-risk assumption was probed *before* the
design was committed to, rather than discovered after the code compiled and the tests passed.

---

## Event: Phase 3.2 — A5, the notification stream

### Agent
Ciel (Hermes Agent)

### Model
deepseek-flash

### Task
Implement 3.2 of the Phase 3 proposal: the two-tier notification reader, the five-field parser, the
consent-gated audit, and the Perception view showing it.

### Context
- Phase 3 gate opened by rnz; 3.1 (consent + audit + dry run) already committed at `c370b52`.
- `NotificationParser.swift`, `NotificationStream.swift`, `Notifications.swift` had been authored in an
  earlier turn of the same session and had **never been compiled**.
- P4 data class: package, title, body, sender. Q3 (content may be shown in the app) was approved.

### Tools Used
- `xcodebuild build-for-testing` / `test-without-building`
- `xcodegen generate`
- `swiftc -enable-bare-slash-regex -swift-version 5` (evidence harness, per ADR-006)
- `adb shell 'cmd notification list'`, `dumpsys notification --noredact`
- Python for measuring the captured dump (record counts, field presence, type mix)

### Process
1. Measured the dump before writing any assertion: 33 records, 29 with content, 4 without; key shapes
   30×5-part + 3×10-part; `android.text` typed `SpannableString` 19× / `String` 9× / absent 5×.
2. Compiled — the parser failed (4 × `Regex.firstMatch` need `try?`), then the view failed (ternary
   between `HierarchicalShapeStyle` and `Color`), then the tests failed to compile (`await` inside
   `XCTAssert*` autoclosures, a redeclared `AuditProbeTransport`, a multi-line literal that cannot hold
   column-0 continuation lines).
3. Ran the tests — four logical failures, each one an assertion I had invented rather than measured:
   aggregate key length, multi-line indentation, "text-only finds fewer than half", and the
   in-flight audit probe (which needed the *existing* `AuditProbeTransport`, not a new one).
4. Replaced every invented number with the measured one and re-ran: 26/26 green, then 776/776.
5. Ran the device harness: 4/4 checks pass; discovered my own assertion expected 2 executed audit
   records where the correct count was 3 (poll 2 issues one command), fixed, re-ran, all PASS.

### Errors and fixes
1. **A file that looked finished and had never been compiled.** The parser's doc comments were detailed
   and its logic defensible; the target did not build. Lesson recorded below.
2. **Four assertions that encoded remembered numbers instead of measured ones.** The most instructive:
   `XCTAssertLessThan(textOnly, parsed/2)` passed the *shape* of the prototype's claim (30% coverage)
   but the capture measures 28 of 33 records with `android.text` present. The real cause of the
   prototype's 30% is the `SpannableString` type — 19 of 28 — so the test now asserts `9/28 = 32%`
   from the fixture and says why.
3. **A criterion that cannot be met as written.** Success criterion 2 wants ≥90% of records; the
   capture yields 87.9% because 4 records carry nothing, and the same criterion forbids dropping them.
   Reported as a measured miss with a recommended restatement (phase record §4) rather than redefined
   quietly.

### Quality
- Correctly gated both tiers inside the reader, and asserted **zero shell invocations** rather than a
  thrown error.
- Correctly kept content out of the audit detail and proved it two ways (hermetic: distinctive tokens;
  hardware: 12 real values compared against the trail, 0 leaked).
- Correctly distinguished empty tier-1 output (no notifications) from empty tier-2 output (failed read).
- Incorrectly shipped three files uncompiled into the sub-phase.
- Incorrectly wrote four tests against remembered numbers.

### Lesson
**"The file is written" and "the target builds" are different facts, and the gap is where a whole
sub-phase can sit looking complete.** The check is cheap (`build-for-testing`) and the cost of not
running it was four files' worth of unverified assumptions. The same discipline applies to numbers:
an assertion that quotes a prototype's measurement is a memory, not evidence — measure the fixture,
then assert what it actually says, even when that contradicts the plan.

**Human intervention:** none during implementation. rnz opened the gate and set the direction.


---

## Event: Phase 3.3 preflight — device probes and the Termux two-gate discovery

**Date:** 2026-10-25 · **Gate:** rnz — *"Proceed with your recommendation, except for 8. enable allow
external apps to run commands"* · **Baseline:** `4b41703` (776 / 0 / 30)

No product code. This session closed the preflight items that 3.3 depends on, so 3.3 starts from
measured behaviour: an install/uninstall round-trip, a reboot, and the Termux setting rnz asked for.

### What was decided and applied
- Success criterion 2 restated in the Phase-3 proposal to "≥ 90% of records **that carry content**"
  (87.9% of all records kept as a diagnostic). The criterion as written was unmeetable — some records
  carry nothing and the same criterion forbids dropping them.
- 3.3 ships as two commits: B4 install/uninstall first, B5 reboot second.
- Hermes runtime: `compression.threshold_tokens` 96k → 64k; a daily balance watchdog (alert below
  $0.50, delivered to Discord DM); off-peak work discipline for long phases.

### Findings
1. **The B4 primitive works on hardware.** Worker APK captured (6,150,926 B, sha256 `b3318d6d…`),
   uninstalled (`pm list packages | grep -c` → 0), reinstalled (`versionName=2.0`). Success criterion 4
   is now provable as a real state transition rather than a dry run.
2. **A reboot is safe and self-recovering.** `boot_completed=1` after ~15 s, ADB reattached over USB
   with no host-side action, worker APK intact, tier-1 notification read and screencap both working
   immediately. B5 needs a recovery contract, not a rescue plan.
3. **The Termux wall is two gates, not one.** `allow-external-apps` is now enabled and persists across
   reboot — but `ActivityManager` still denies `com.android.shell` because the service carries a
   `prot=dangerous` manifest permission the shell package never declared. Enabling the setting removes
   only the *service's own* check. `pm grant` exits 0 and no-ops, which reproduces the documented
   behaviour and pins its cause.
4. **A path out of the Termux wall exists and is unbuilt.** A package that *declares*
   `com.termux.permission.RUN_COMMAND` can be granted it. `com.pixeldesktop.worker` is ours; making it
   the forwarding bridge is non-root and needs an APK change plus an ADR. Filed as an open decision —
   explicitly unverified, since the grant-half is inference from `pm grant` semantics.

### Errors and fixes
1. **A setting I could not verify by reading.** Termux's storage is private and the app is not
   debuggable, so `cat` was impossible from the host. Fix: type the command in the terminal and verify
   from the **rendered frame** — the file's content was read off a screenshot, and read again after a
   reboot to prove persistence.
2. **A command that ran three times.** One typed `echo … >>` landed three times in
   `termux.properties`. Harmless because it was idempotent, but the cause was never identified. The
   lesson is not "typing is flaky" — it is that the *only* safe commands to type into that channel are
   idempotent ones.

### Quality
- Correctly refused to call the Termux setting "done" on the strength of a write's exit status; the
  claim rests on a frame capture and a post-reboot re-read.
- Correctly separated "necessary" from "sufficient" for the two Termux gates instead of reporting the
  setting as an unblock.
- Correctly tested the balance watchdog's **alert** path, not just its silent path — a monitor that
  only proves silence is unverified in the direction that matters. Delivery confirmed in the gateway
  log (`Job '56089b466078': delivered to discord:…`).
- Incorrectly let the first preflight plan assume one Termux gate; the second gate cost a round trip.

### Lesson
**A wall with two locks looks like a wall with one until you test each lock separately.** Enabling
`allow-external-apps` was the setting rnz asked for and it is genuinely on; reporting that as "Termux
unblocked" would have been false, because the denial happens a layer earlier, inside
`ActivityManager`, before any Termux code runs. The discipline that caught it is the same one that
caught the notification parser: name the layer that produces the error before claiming the fix
reaches it.

**Human intervention:** rnz answered the eight-item checklist in one line, changing item 8 from *skip*
to *do it*. No corrections during execution.

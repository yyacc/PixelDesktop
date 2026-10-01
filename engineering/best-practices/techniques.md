# Technique Memory

Reusable techniques observed during PixelDesktop development, recorded in the project's
prescribed format. Each entry is a lesson with evidence, not a slogan.

---

## T-001 — Probe the external system before designing against it

**Technique:**
Run the real external system (device, CLI tool, service) manually and record its actual
behaviour before writing any code that integrates with it. Then encode the *observed*
behaviour — including its failure modes — in the mock.

**Worked:**
Yes.

**Evidence:**
Phase 2. Three `getprop` calls were made directly against the Pixel 7a before
`DeviceProperties` was designed. This produced two findings that changed the design:

1. The device reports Android `16` / API `36`, not the `14` / `34` recorded in the
   Phase 1 test fixtures. Assumed values were wrong.
2. `getprop` on an unset key exits **0** with empty output. It does not fail.

Finding 2 is not documented in `adb` help output. Without it, `DeviceProperties` would
have accepted empty strings and populated `androidVersion = ""`, which is
indistinguishable from "not yet enriched". The tests would have passed while the real
device produced empty values.

**Recommended use:**
Any integration with a system whose behaviour is not fully specified by its
documentation — hardware, CLI tools, network services, third-party APIs.

**Avoid when:**
The behaviour is already pinned by an existing passing test. Re-probing then costs time
and adds no information.

---

## T-002 — Check git provenance before choosing a corruption-recovery path

**Technique:**
On discovering a corrupted or unexpected file, run `git status --porcelain` and
`git show HEAD:<path> | wc -c` **before** attempting any reconstruction.

**Worked:**
Yes.

**Evidence:**
Phase 2. `Transport.swift` on disk was 105,413 bytes of runaway field names (FAIL-002).
Two commands established that:

- `git show HEAD:...Transport.swift` → **398 bytes**, clean and complete.
- `git status --porcelain` → `M ...Transport.swift`, i.e. the corruption was
  **uncommitted**.

Recovery was therefore `git checkout HEAD -- <path>` — two seconds, exact, no risk. The
alternative (hand-reconstructing the intended content) would have been slower, riskier,
and unnecessary.

**Recommended use:**
Any corrupted, truncated, or unexpectedly large file in a version-controlled repository.

**Avoid when:**
The file is untracked, or the corruption was committed. Then git holds the corruption
too, and recovery must come from elsewhere (backup, another branch, or reconstruction).

---

## T-003 — Use targeted `patch` for edits, `write_file` only for new files

**Technique:**
Modify existing files with bounded find-and-replace edits. Reserve whole-file writes for
files that do not yet exist.

**Worked:**
Yes.

**Evidence:**
Phase 2. The `Transport.swift` corruption (105 KB of recursively-named fields) occurred
during a whole-file regeneration. After switching to `patch`, all subsequent edits to
`Transport.swift`, `ADBTransport.swift`, `DeviceManager.swift` and the test file
succeeded on the first attempt and each produced a reviewable diff.

The mechanism is structural: a `patch` edit cannot exceed the size of its replacement
text, so a repetition defect can only damage a small, immediately-visible region. A
whole-file write has no such bound.

**Recommended use:**
All edits to existing files.

**Avoid when:**
Creating a new file, or when a file genuinely needs full replacement. Even then, prefer
several bounded patches.

---

## T-004 — Inject dependencies as protocols so device-touching code stays testable

**Technique:**
Have logic depend on a protocol (`TransportProtocol`), not a concrete type
(`ADBTransport`), so tests can substitute a mock.

**Worked:**
Yes.

**Evidence:**
Phase 2. `DeviceEnricher` takes `TransportProtocol`. This made 15 mock-based tests
possible with no device attached, and let them assert *which argv was issued* rather than
only the return value. `DeviceManager` was likewise widened from `ADBTransport` to
`TransportProtocol`; without that change, its enrichment path could not have been tested
at all.

**Recommended use:**
Any component that performs I/O, talks to hardware, or otherwise cannot be exercised
deterministically in a test.

**Avoid when:**
The concrete type has no side effects and no substitution need — introducing a protocol
there is ceremony.

---

## T-005 — Assert invocations, not only outcomes

**Technique:**
Where an architectural boundary matters, write tests that assert a call did **not**
happen, or that calls occurred in a specific form and order.

**Worked:**
Yes.

**Evidence:**
Phase 2. Two tests pin boundaries that outcome-only assertions could not:

- `testDiscoveryLeavesPropertiesUnpopulated` asserts discovery issues **zero** `getprop`
  calls — the regression test for the ADR-005 boundary.
- `testEnrichDeviceRejectsNonConnectedState` asserts an offline device causes **zero** ADB
  calls, proving the guard runs before any I/O.

Both would still pass under a result-only test suite even if the boundary were violated.

**Recommended use:**
Where a design decision is "X must not do Y" — layering, separation of concerns,
short-circuit guards.

**Avoid when:**
The internal call pattern is an implementation detail with no architectural meaning.
Over-asserting on calls makes tests brittle.

---

## T-006 — Test well-formedness, not environment constants

**Technique:**
Assert that a value is present and structurally valid, not that it equals a specific
constant read from the current environment.

**Worked:**
Yes.

**Evidence:**
Phase 2. Phase 1 fixtures encoded `androidVersion: "14"`, `apiLevel: 34`. The real device
reports `16` / `36`. Integration tests therefore assert
`androidVersion` is non-empty and `apiLevel > 0`, deliberately avoiding a pinned version.

A pinned assertion would have failed against the real device on day one while catching
nothing, and would break again on every OS update.

**Recommended use:**
Values owned by an external system: OS versions, device capabilities, service versions,
file paths outside the repo.

**Avoid when:**
The constant is genuinely part of the specification under test (e.g. an approved
`getprop` key name, or a protocol constant). Those *should* be pinned —
`testDevicePropertyKeysMatchApprovedAcquisitionSources` does exactly this.

---

## T-007 — Normalize output language before emission, not after

**Technique:**
When the model's default output language differs from the project's working language,
apply translation as an output-stage step on every emission path — including live
narration.

**Worked:**
Yes, after three failures.

**Evidence:**
FAIL-001. The agent acknowledged the English-only requirement on first correction and
still recurred twice more, because the rule was applied to artifacts (documents) but not
to narration. Narration leaves no artifact, so it is invisible to any post-hoc audit.

**Recommended use:**
Whenever a project has a mandated working language that differs from a model's default.

**Avoid when:**
Never — but do not translate code identifiers, API names, paths, commands, or model
names.

---

## T-011 — Make a rule's stated criterion executable

**Technique:**
When a rule has a written criterion, add a test that checks each questionable entry against
that criterion — not just that the rule's code runs.

**Worked:**
Yes, after failing once.

**Evidence:**
Phase 4. `protectedPackages` had the criterion "stopping this disrupts the device itself",
and `com.android.settings` was on the list anyway — added by reflex on package name. All 105
unit tests passed. The failure surfaced only on the real device, because the approved
verification sequence stops Settings.

`testSettingsIsNotProtectedBecauseItIsNotDeviceCritical` makes the criterion executable, so
the entry cannot silently return.

**Recommended use:**
Denylists, allowlists, classification rules, and any heuristic where entries are added
judgement-by-judgement.

**Avoid when:**
The rule is a genuine constant with no judgement involved (e.g. an approved `getprop` key
name). Asserting a criterion there is ceremony.

---

## T-012 — Specify the verification sequence before designing the constraint

**Technique:**
When a phase both restricts an operation and must demonstrate it working, fix the
verification sequence first. Then check the constraint does not forbid the demonstration.

**Worked:**
Yes.

**Evidence:**
Phase 4. D7 named Settings as the verification target; D2 constrained `stopApplication`. The
constraint as first written forbade the target. Because the sequence was approved up front,
the collision was unambiguous and the fix was obviously "the rule is wrong", not "verification
is too strict".

Had the sequence been invented after implementation, the likely outcome would have been to
weaken verification to make it pass — losing the check rather than fixing the rule.

**Recommended use:**
Any phase that both restricts an operation and must show it working: permissions, rate limits,
allowlists, destructive-operation guards.

**Avoid when:**
Read-only phases, where there is nothing to restrict.

---

## T-009 — Assert field relationships, not just field presence

**Technique:**
Where two fields should differ (or agree), assert the relationship between them rather than
asserting each is non-empty.

**Worked:**
Yes.

**Evidence:**
Phase 3. `manufacturer` was populated from the `device:` token of `adb devices -l`, which is
the device codename (`lynx`). The field was non-empty, compiled cleanly, passed all 49
Phase 2 tests, and rendered as "Manufacturer" in the UI — **displaying a falsehood**.

Every existing test asserted presence. None could catch a field holding the wrong thing.
`XCTAssertNotEqual(device.manufacturer, device.deviceCodename)` catches it in one line.

**Recommended use:**
Fields populated from an ambiguous or reused source: tokens carrying more than one meaning,
enums reused for two purposes, identifiers that alias another field.

**Avoid when:**
The fields are genuinely independent and no relationship should hold. An arbitrary
inequality assertion is noise.

---

## T-010 — Turn real captured system output into a permanent hermetic test

**Technique:**
When you capture real output from an external system, keep it as a test fixture so the
parser and mapping logic stay verified against reality on every future run — without needing
the external system present.

**Worked:**
Yes.

**Evidence:**
Phase 3. The Pixel 7a detached mid-verification. The exact `getprop` output captured from it
was replayed through the real parser, `DeviceProperties.make` and `DeviceEnricher`
(13/13 checks passed), then retained as `testEnrichmentAgainstRealPixel7aOutput`.

That test now runs in the hermetic suite on every change and pins the pipeline to real device
data, including both defect regressions and the unset-key omission.

**Recommended use:**
Parsers, protocol decoders, and any mapping from an external system's output into a model.
Especially valuable for hardware that may not be attached.

**Avoid when:**
The captured output contains secrets or personally identifying data. Also not a substitute
for live verification — it verifies the code, not the integration.

---

## T-008 — Compile production sources into a CLI harness to produce real evidence

**Technique:**
When the test runner cannot reach the real environment, compile the actual production
source files with `swiftc` into a small CLI and run it directly against the real system.

**Worked:**
Yes.

**Evidence:**
Phase 2. `xcodebuild ... test TEST_RUNNER_PIXELDESKTOP_DEVICE_SERIAL=...` did not forward
the variable; the integration tests reported "skipped". Compiling
`Transport.swift` + `ADBTransport.swift` + `DeviceEnricher.swift` + `PixelDevice.swift`
+ `PixelDesktopError.swift` into a harness produced real-device evidence *and* an
independent cross-check against raw `adb` (`CROSS-CHECK MATCH: true`).

**Recommended use:**
Producing verification evidence when the test harness cannot be driven against the real
environment, and as a second, independent path for any claim about real hardware.

**Avoid when:**
The test runner works. A harness duplicates the suite and can drift from it — it is an
evidence tool, not a substitute for tests.

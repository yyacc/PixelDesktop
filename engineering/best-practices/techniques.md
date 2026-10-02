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

## T-015 — A mock asserts what the code sends, not what the platform does

**Technique:**
For any platform behaviour that gates execution, assume the unit tests prove **nothing** about it.
Probe the device, and log the observed value next to the decision that depends on it.

**Worked:**
No — it was violated three times in one phase, and each cost a failed run.

**Evidence:**
Phase 5 D8. Three assumptions, all defensible in review, all wrong, all passing 154 unit tests:

1. `exported="false"` blocks adb from starting the Activity — **false**; adb cannot start a
   non-exported Activity at all (`SecurityException`).
2. `getLaunchedFromUid()` returns `2000` for an adb launch — **false**; it returns `-1`.
3. adb may create a directory the app must write — **false**; the directory is owned by
   `shell:ext_data_rw` and the app cannot write it.

Instance 2 was diagnosed in one line only because the code **logged** `WORKER_LAUNCHER uid=-1`
before acting on it. Had it refused silently, the cause would have been invisible.

**Recommended use:**
Android framework behaviour (exported flags, launcher identity, permissions, storage ownership),
and any external system whose behaviour gates whether code runs at all.

**Avoid when:**
The behaviour is already pinned by a real-device test that runs in CI.

---

## T-016 — Never accept a PASS from a binary you did not intend to run

**Technique:**
After a compile error, delete the output artifact before recompiling. Verify the artifact was
rebuilt before trusting its result.

**Worked:**
Yes — it caught a false PASS.

**Evidence:**
Phase 5 D8. A harness edit left a stale reference, so `swiftc` failed. The **previous** binary was
still on disk and executed successfully, printing a full PASS. The PASS was real for the *old* code
and meaningless for the current source.

Recognised because the compile output and the run output disagreed. Deleted the binary, recompiled
clean, re-ran on a fully clean device (package uninstalled, directory absent).

**Recommended use:**
Any evidence-producing harness compiled outside the normal build system.

**Avoid when:**
The build system already guarantees a fresh artifact.

---

## T-025 — Sample the layers independently, or "disconnected" will mislead you

**Technique:**
When a connection "drops", instrument each layer separately and timestamp them independently.
Never let one layer's view stand in for another's — the phrase "ADB disconnected" collapses at
least three different failures with three different fixes.

**Worked:**
Yes — it turned a vague recurring symptom into a specific kernel-level cause.

**Evidence:**
The reported symptom was "USB/ADB disconnects". Sampling `adb devices` **and**
`ioreg -p IOUSB` **and** `log show` for the USB stack separately showed:
- ADB server uptime was continuous across every disconnect → **ADB was a victim**
- `ioreg` showed the device vanishing from the bus → the failure is at USB level
- `log show` gave the kernel verdict: `AppleUSBHostPort::terminateDevice` with either
  `hardware connection lost` or `hardware port disabled`, after `status 0xe00002ed`

Those two kernel verdicts are *different failures* — one is the link dropping, the other is macOS
disabling the port protectively. A single "disconnected" observation would have hidden both.

**Recommended use:**
Any layered stack — USB/ADB, network/TLS, driver/app. Sample each boundary separately.

**Avoid when:**
Never. It costs one extra command per sample.

---

## T-026 — Separate the trigger from the mechanism before proposing a fix

**Technique:**
A failure usually has a *mechanism* (what actually breaks) and one or more *triggers* (what makes it
happen). Identify both, and do not let a plausible trigger stand in for the mechanism.

**Worked:**
Yes — it prevented a wrong fix.

**Evidence:**
The mechanism was constant: macOS tearing down the USB port after a physical-layer transaction
error. The triggers differed by time of day: **92 system-sleep events explained the morning
teardowns**, but the Mac did not sleep at all after 13:00, so sleep could not explain the afternoon
ones — those correlated with **49 browser exclusive-USB-access events** instead. Two of seven
afternoon teardowns had neither.

Had only one trigger been found, the obvious "fix" would have been to disable sleep — which would
have left the afternoon failures entirely unexplained and the user convinced the problem was solved.

**Recommended use:**
Any intermittent fault. Explicitly check whether the same mechanism has *multiple* triggers, and
look for occurrences none of your triggers explain.

**Avoid when:**
Never — the unexplained residue is the most informative part of the data.

---

## T-024 — Check whether the type you need already exists before designing one

**Technique:**
Before introducing a new abstraction, re-read what the previous step produced and ask whether it
already satisfies the requirement. A new type that duplicates an existing one's shape is a second
place for the same invariant to drift.

**Worked:**
Yes — and it cut the step's surface area substantially.

**Evidence:**
Phase 7 Step 2 required "a simple immutable observation structure: value, source, observedAt,
limitation". Step 1 had already introduced `CapabilityValue` with **exactly those four fields**.
Introducing a parallel `Observation` type would have created two representations of provenance,
two places to keep the limitation text honest, and two serialisation shapes for a consumer to
handle.

Recognising this reduced Step 2 to three value types and one reader — and meant the provenance
guarantees already enforced by Step 1's tests automatically covered the new evidence.

**Recommended use:**
Every step that follows a step which introduced a type. Ask what the previous step built before
designing anything.

**Avoid when:**
Never — though be careful not to force a fit. Here the shapes genuinely matched; a forced reuse
would be worse than a new type.

---

## T-023 — Enumerate a library's limits; guard the FATAL ones first

**Technique:**
When using a library, list every bound it enforces and classify each by what happens when it is
violated: returned error, or process abort. Guard the fatal ones explicitly, and never assume a
guard on one bound covers another.

**Worked:**
No — it was violated, and the violation was invisible to 224 passing tests.

**Evidence:**
Phase 7 Step 1. `llama.cpp` enforces two independent bounds:
- `n_ctx` (2048) — violation returns an error. **Guarded** in Phase 6, tested, documented.
- `n_batch` (256) — violation calls `ggml_abort()` and **SIGABRTs the process**. It was a bare
  literal three lines away in a `cparams` assignment, **unguarded**.

A ~660-token prompt therefore killed the worker with no result file, which the Mac could not
distinguish from a crash-loop or a timeout. Fixed by chunking the decode.

**Why the tests missed it:** every test used a 22–32 token prompt. The failure needs >256. The macOS
suite cannot reach the native layer at all.

**Recommended use:**
Any native or C library with configurable limits — especially where one bound is graceful and
another is fatal. Read the abort paths, not just the return values.

**Avoid when:**
Never. The enumeration costs minutes; the failure cost a phase's verification run.

---

## T-021 — When the evidence says "no component", propose no component

**Technique:**
At the end of a reconnaissance, re-read your own findings and ask whether they argue *against* the
component the brief's candidate structure suggested. A candidate structure is a prompt, not a
requirement.

**Worked:**
No — this was violated, and the reconnaissance had already done the work to prevent it.

**Evidence:**
Phase 7. The reconnaissance itself established that a router was unjustified, in three separate
places: §B "there is only one executor" (the Mac cannot run inference, so a router could only ever
choose the Pixel); §H judged cost-comparison routing "blocked by evidence"; §N asked "whether routing
is worth it at all" and suggested the honest frame was a specialised node, not load balancing.

A `FeasibilityEvaluator` inside PixelDesktop was proposed anyway, because the brief listed a candidate
structure containing a router. Architectural review found it **contradicted the master prompt §1**,
which places orchestration on the Mac *above* PixelDesktop. Withdrawn before implementation.

**Cost:** one wasted document and one review cycle. Cheap here only because it was caught before
code. The same failure after implementation would have been a rewrite.

**Recommended use:**
Every reconnaissance that produces a proposal. Explicitly ask: *"do my own findings support this
component, or merely fail to rule it out?"*

**Avoid when:**
Never. The check costs one paragraph.

---

## T-022 — Distinguish a decision from an enforcement point

**Technique:**
When two layers could both judge whether something is possible, designate one as the **decision**
maker (may be wrong, is optimising) and the other as the **enforcer** (authoritative, refuses). Do
not let both decide, and do not let the decider bypass the enforcer.

**Worked:**
Yes — it is what makes an LLM-driven planner safe here.

**Evidence:**
Phase 7 re-evaluation. Hermes (an LLM) decides where work goes; PixelDesktop (infrastructure) refuses
anything it cannot actually execute. A stale Hermes belief about Pixel capability therefore costs a
**wasted round-trip, never an invalid execution**. This preserved the entire D8/Phase 6 containment
model unchanged while still letting an LLM own planning.

The alternative — both layers deciding — was the withdrawn ADR-013, where PixelDesktop would have
re-judged a placement Hermes had already made.

**Recommended use:**
Any architecture where a non-deterministic or remote component influences what gets executed.

**Avoid when:**
Never — but be explicit about *which* layer is authoritative, or the distinction erodes.

---

## T-017 — Test the highest-risk assumption BEFORE building anything on it

**Technique:**
Identify the assumption that would invalidate the design if false, and falsify it with the
cheapest possible probe before writing production code.

**Worked:**
Yes — and it is the only reason this phase had no falsified platform assumptions.

**Evidence:**
Phase 6. ADR-012 flagged R1 (does a multi-minute Activity survive locked/doze?) as the
highest-risk item, because falsifying it would require a Service — an architecture change, not
an implementation detail. A self-contained probe app (300 s CPU-bound Activity, zero
permissions) answered it in ~15 minutes: PASS unlocked, PASS locked/dozing, PASS forced deep
doze. No Service was needed, and the design proceeded unmodified.

Compare Phase 5/D8, where three platform assumptions were falsified *after* the code was written,
compiled cleanly, and passed 154 tests. Cost of finding out late: a rewrite of the manifest, the
launcher check, and the workspace contract.

**Recommended use:**
Whenever a design decision depends on unverified external-system behaviour that would be
expensive to change later.

**Avoid when:**
The assumption is cheap to change (a config value) or already pinned by an existing device test.

---

## T-018 — A measurement can be an artifact of your own harness

**Technique:**
Before believing a surprising result, check whether the *measurement* could have produced it.
Specifically: reset the subject to a known state between runs, and verify the identity of what
you sampled.

**Worked:**
Yes — it caught a wrong conclusion before it was recorded.

**Evidence:**
Phase 6, R1. A second launch was issued while the previous probe process was still alive. `pidof`
returned the OLD pid, whose CPU time appeared frozen (`utime` stuck at 28751), and the log was
silent. The obvious reading — "deep doze blocks the Activity" — was **wrong**. Adding
`am force-stop` between tests showed deep doze passing cleanly.

Also Phase 6: an external memory sampler running as a backgrounded shell subshell never sampled
anything (30/30 samples "DEAD") while inference completed successfully. The process lived ~20 s
and the sampler was not actually running. Fixed by having the worker read its OWN
`/proc/self/status`, which is both reliable and genuinely worker-attributable.

**Recommended use:**
Any sampling of a short-lived process; any PID- or handle-based measurement; any A/B comparison
where state carries over.

**Avoid when:**
Never avoid it — the failure mode is silent and produces confident wrong answers.

---

## T-019 — Prefer the subject's self-report over an external observer

**Technique:**
For short-lived processes, have the process record its own metrics at the moment of interest
rather than sampling it from outside.

**Worked:**
Yes.

**Evidence:**
Phase 6. The worker lives 12–25 s. External sampling missed it entirely. Reading
`/proc/self/status` (`VmHWM`, `VmRSS`) inside the process captured a 1279 MB peak that no
external sample obtained. It is also more defensible: the value is unambiguously that process's,
not a neighbour's.

**Recommended use:**
Peak memory, timings, and any quantity whose peak is brief.

**Avoid when:**
The metric must be independent of the subject (e.g. proving the subject did not lie). Here the
external CPU-tick reading is the independent one, and it is used for exactly that reason — the
two methods serve different purposes and both are used.

---

## T-020 — A refused request is better than a coerced one

**Technique:**
When the contract permits only one mode, reject other modes explicitly rather than silently
converting them.

**Worked:**
Yes.

**Evidence:**
Phase 6 requires greedy decoding. A non-zero `temperature` is rejected with `INVALID_INPUT`
rather than being clamped to 0. Had it been coerced, a non-greedy run would have been recorded
as a greedy one, and the R4 stability measurement would have been measuring the wrong thing.

**Recommended use:**
Any parameter whose value appears in evidence or affects reproducibility.

**Avoid when:**
The coercion is lossless and unobservable.

---

## T-013 — Separate "the tool refused" from "the OS refused"

**Technique:**
When a security-relevant operation fails and you are about to record the failure as
protection, run the same operation *inside a permitted area* to confirm which layer refused.

**Worked:**
Yes — and it inverted the conclusion.

**Evidence:**
Phase 5. `push … /data/local/tmp/../pd_escape.txt` returned exit 1, as did pushes to
`/data/local`, `/etc` and `/system`. The natural reading was "adb blocks traversal".

Re-running the same traversal inside a writable directory —
`push … /data/local/tmp/pdsub/../pd_trav.txt` — **succeeded** and landed in
`/data/local/tmp/`. The failures were **permission denials by the OS**, not a control.

Without that second test, ADR-010's entire security model would have rested on a false
premise, and would have been wrong in the direction of *understating* risk.

**Recommended use:**
Whenever a security-relevant operation fails and the failure is about to be recorded as
protection. Confirm the refusing layer.

**Avoid when:**
The failure is already unambiguously attributed (e.g. an explicit "permission denied" that
names the mechanism).

---

## T-014 — Verify the specific object, not the category it belongs to

**Technique:**
When a decision rests on a property of the environment, test that property on the **actual
object** the code uses, not on a related one.

**Worked:**
No — it was violated, and cost a real-device failure.

**Evidence:**
Phase 5, FAIL-003. ADR-010 chose `/data/local/tmp` **because it is not world-readable**. The
parent is 771 — correct. But `mkdir -p /data/local/tmp/pixeldesktop` produced mode **777**, so
the directory the contract actually uses was world-readable and the stated rationale was
untrue.

The inference "the parent is restricted, therefore the child is restricted" was never tested
until the real device was asked.

**Recommended use:**
Permissions, ownership, filesystem semantics, defaults inherited from a parent, anything where
a nearby example is used as evidence for the target.

**Avoid when:**
The property is directly observed on the object itself.

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

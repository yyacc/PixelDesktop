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

---

## 2026-10-01 — Phase 4 proposal produced (no code changed)

**Phase:** 4 (proposal)
**Task:** Produce a Phase 4 implementation proposal for Android Application / Process Control.

**Action:**
Ran a read-only capability probe against the Pixel 7a — **no application was launched,
stopped or modified**. Probed `pm list packages`, `pm list packages -3`,
`cmd package query-activities`, `pidof` (running and not-running), `ps -A`,
`dumpsys activity`, `dumpsys package`, `resolve-activity`, `which monkey`, and the
device's privilege posture.

**Result:**
Proposal produced with seven decision points. Five probe findings shaped the design:

1. **`dumpsys package` costs 49,893 bytes per app** — resolving 41 packages that way would
   be ~2 MB. The single `query-activities` call already returns all 58 launchable
   activities, so per-app resolution is unnecessary. Largest efficiency decision in the phase.
2. **`pidof` exit codes are meaningful** (exit 1 for not-running) — unlike `getprop`, which
   exits 0 for an unset key. The two must not share error handling.
3. **`resolve-activity` exits 0 even when it finds nothing** — detection must be
   output-based.
4. **The device is not rooted and not debuggable** (`which su` empty, `ro.debuggable=0`).
   No privilege escalation is available through ADB, which bounds the blast radius of
   `shell()` and is direct evidence for the security review.
5. `--brief` does not shorten `query-activities`, but its output parses cleanly into 58
   package/activity pairs with no duplicates.

**Decision:**
Recommend adding `shell()` as a transport-only primitive contained by an operations layer
that exposes named operations only; adding a new `Operations/` layer
(`AppOperationsProtocol` + `ADBAppOperations`); containing `stopApplication` to explicit
packages with system-package refusal; not caching enriched properties across reconnect; and
deferring `ps -A` parsing since `pidof` covers the actual need. **No source file modified.**

**Reason:**
Phase 4 is the most security-sensitive phase so far — Phases 2 and 3 only read from the
device, while Phase 4 acts on it. `shell()` is a general-purpose escape hatch and
`am force-stop` is destructive-capable, so both need explicit containment and review before
implementation.

**Next action:** Await review of the seven decision points.

**Artifacts:** `phases/phase-04-application-process-control-proposal.md`.

---

## 2026-10-01 — Phase 4: Android Application / Process Control

**Phase:** 4
**Task:** Implement controlled Android application operations with `shell()` contained below a
new operations layer, plus connection lifecycle handling.

**Action:**
Ran a **read-only** capability probe before writing any code — nothing was launched, stopped
or modified. Established: `dumpsys package` costs 49,893 bytes per app (so per-app launch
resolution is unusable); `pidof` exits 1 for a non-running package while `getprop` exits 0 for
an unset key (so they must not share error handling); `resolve-activity` exits 0 even when it
finds nothing; and the device is **not rooted and not debuggable** (`su` absent,
`ro.debuggable=0`).

Implemented `shell()` on `TransportProtocol` only; a new `Operations/` layer
(`AppOperationsProtocol` + `ADBAppOperations`) that accepts no shell strings; an
`InstalledApp` model; four new `DeviceOperation` cases; guard-first lifecycle handling with
wholesale list replacement so disconnect invalidates enriched properties; and
`validatePackageName` as the command-injection boundary.

**Result:**
The first live verification run **FAILED at step 7** — `stopApplication("com.android.settings")`
was refused because Settings had been placed on the protected list. The entry was added by
reflex on package name and violated the list's own stated criterion. All 105 unit tests had
passed; only real-device verification, using the user-approved target, exposed it.

Fixed by removing the entry, documenting the criterion inline, pinning it with
`testSettingsIsNotProtectedBecauseItIsNotDeviceCritical`, and recording the episode in ADR-009.

Final: BUILD SUCCEEDED; 106 tests executed, 0 failures. Real-device verification **PASS** on
the exact approved sequence — discover → resolve launcher → launch Settings → verify running
→ stop Settings → verify stopped — with containment checks and a raw-`adb` cross-check
(third-party count 41 = 41).

**Decision:**
Phase 4 COMPLETE. `shell()` is a transport-only primitive, not exposed upward. The protection
model is documented **with its limitations**: the denylist is defence-in-depth, not a security
boundary; the real boundaries are the device's privilege posture, the absence of upward shell
exposure, and the bounded blast radius.

**Reason:**
D2 was approved with the modification that package naming must not be treated as a sufficient
security boundary. Documenting the limitations is what made the over-broad entry recognisable
as a heuristic error rather than a mystery.

**Next action:** Phase 5 (Pixel Compute Worker) — RNZM-23 `push()`/`pull()`. File transfer
introduces path handling, a new input-validation surface that package-name validation does
not cover; it needs its own review and ADR.

**Artifacts:** `phases/phase-04-application-process-control.md`, ADR-009,
`testing/phase-04-test-report.md`, `architecture/overview.md` updated.

---

## 2026-10-01 — Phase 5 proposal produced (no code changed)

**Phase:** 5 (proposal)
**Task:** Produce the smallest safe transfer contract for the Pixel Compute Worker
(`push()`/`pull()`), reconnaissance and proposal only.

**Action:**
Read the Phase 5 requirements, ADR-003, ADR-004 and the DTCA-1 I/O contract. Inspected
`TransportProtocol`/`ADBTransport` and confirmed **no path abstraction and no `push`/`pull`
exist anywhere**. Then answered every security question **empirically on the real device**
rather than from documentation: traversal, absolute paths, local-destination escape,
symlinks, overwrite, nonexistent paths, directories, spaces, malformed paths, and command
injection through path arguments. All probe files were removed and the remote root verified
clean.

**Result — four findings that determine the design:**

1. **`adb` does NOT sanitize paths.** `../` is resolved by the *filesystem*, not rejected:
   `/data/local/tmp/pdsub/../pd_trav.txt` succeeded and landed in `/data/local/tmp/`. The
   earlier traversal failures were **permission denials** on `/data/local`, `/etc` and
   `/system` — not a security control. This distinction is load-bearing.
2. **Local destinations escape on `pull`.** Pulling to `<staging>/../../file` exited 0 and
   wrote to `/Users/…/.hermes/cache/` — outside the staging directory. Artifact removed.
3. **Symlinks are followed, not rejected.** Pushing a symlink to `/etc/hosts` pushed its
   *content*. A symlink in staging is a full escape from it.
4. **Directories recurse.** `pull` of a directory reported "2 files pulled" — a stray
   directory operand transfers a tree.

Also: overwrite is **silent with exit 0** (no warning, no protection); and path arguments are
**not** a command-injection vector (they are argv elements, no shell involved) — unlike a path
passed to `shell()`, which is a different risk class.

**Decision:**
Propose eliminating path input entirely rather than validating it — two fixed filenames in
two fixed directories, one file each way, no directories, no symlinks, ≤1 MB. Every traversal
case then becomes **unreachable by construction** rather than merely blocked. Remote root
`/data/local/tmp/pixeldesktop/` (writable by `shell`, **not world-readable**, unlike
`/sdcard`). `push`/`pull` as transport primitives with a new `Worker/` layer owning all path
policy — the same split as ADR-009. Overwrite permitted deliberately for the two fixed paths.
Interrupted transfers detected post-hoc by size. Eight decision points raised; **no source
file modified**.

**Reason:**
Phase 4 showed that containment by validation is fragile (the protected-package list was
wrong on the first attempt). Containment by *narrowness* — having no path parameter to attack
— is stronger, and the payload is only ≤10 KB so nothing is lost by it.

**Next action:** Await review of D1–D8 and the ADR-010 recommendation.

**Artifacts:** `phases/phase-05-transfer-contract-proposal.md`.

---

## 2026-10-01 — Phase 5 (Part 1): Worker Transfer Contract

**Phase:** 5 (transfer contract scope; worker APK deferred per D8)
**Task:** Implement the fixed transfer contract for the Pixel Compute Worker per D1–D8.

**Action:**
Probed two mechanisms before depending on them: `stat -c %s` on the device (works; exits 1 for
a missing path) and Swift's `attributesOfItem` symlink reporting (confirmed it reports
`.typeSymbolicLink` **without following**, so the check cannot be bypassed).

Implemented narrow `push()`/`pull()` primitives on `TransportProtocol` with no path policy, and
a `Worker/` layer — `WorkerTransferContract` (fixed paths, regular-file validation, size
verification) plus `WorkerOperationsProtocol`/`ADBWorkerOperations` with **no path parameter
anywhere**. Wrote 25 tests covering each case the user named.

**Result:**
The first real-device run **failed one check**: `mkdir -p` created the workspace with mode
**777**, world-readable. ADR-010 chose `/data/local/tmp` *because* it is not world-readable —
true of the parent (771), false of the directory the contract creates.

Diagnosed as an over-permissive default and fixed by **tightening** the contract
(`mkdir -p … && chmod 700 …`), pinned with `testPrepareRemoteWorkspaceRestrictsPermissions`,
and recorded as FAIL-003. A second, separate harness bug produced a false FAIL (the cleanup
check read only stdout while `ls` writes "No such file" to stderr).

Final: BUILD SUCCEEDED; 131 tests executed, 0 failures. Real-device verification **PASS** on
the exact fixed contract — workspace mode 700, size-verified push (69 = 69), payload
byte-identical on device, deliberate overwrite confirmed, size-verified pull (226 = 226),
local result byte-identical, missing payload → `workerError`, oversized input rejected, unknown
serial fails cleanly, workspace removed, device healthy. Cross-checked against raw `adb`.

**Decision:**
Phase 5 transfer contract COMPLETE. The worker APK, worker lifecycle and compute execution
remain deferred (D8).

**Reason:**
The verification failed because the *contract* did not achieve its own stated property, not
because the check was too strict. Tightening was the correct response; relaxing would have
left a world-readable workspace while claiming otherwise.

**Next action:** The worker APK is its own step (D8) — APK build, installation, compute
execution. `DeviceOperation` was deliberately not extended.

**Artifacts:** `phases/phase-05-transfer-contract.md`, ADR-010,
`testing/phase-05-test-report.md`, `failures/FAIL-003-workspace-world-readable.md`,
`architecture/overview.md` updated.

---

## 2026-10-02 — Phase 5 D8 reconnaissance: minimum compute worker (no code changed)

**Phase:** 5 (D8 proposal)
**Task:** Establish the smallest real, measurable, safe compute boundary between PixelDesktop
and the Pixel. Reconnaissance and proposal only — no APK built or installed, no source
modified.

**Action:**
Read the authoritative Phase 5/6 requirements and §5.2, §5.3, §20, §22. Inspected ADR-003,
ADR-010, the Part 1 implementation (`WorkerTransferContract`, `WorkerOperationsProtocol`,
`ADBWorkerOperations`, `TransportProtocol`, `ADBTransport`) and the **existing Android
project** (`AndroidMetadataHelper`). Then ran 22 read-only probes on the Pixel 7a — **no
install, no uninstall, no launch, no state change**.

**Result — findings that determine the design:**

1. **adb runs as `uid=2000(shell)`** with `sdcard_rw`, **`ext_data_rw`** and **`readproc`**
   in its supplementary groups.
2. **adb can read, write, push and pull inside an app's external files dir** — verified by
   writing a file into an existing app's directory and reading it back. The dir is
   `drwxrws---` (owner + `ext_data_rw` only), so it is **not readable by other apps**, but
   adb is in that group. This is the channel.
3. **`/data/local/tmp` is mode 771 owned by `shell` — an Android app CANNOT write it.** No
   `su` exists. Part 1's remote root is writable only by adb, so it **cannot host worker
   output**. This is a required ADR-010 revision, not a passing note.
4. `/data/data/<pkg>` is **Permission denied** without root; `run-as` is not a production channel.
5. **`com.pixeldesktop.metadata` is already installed** (minSdk 31, targetSdk 36) — the full
   Android chain build→install→run is proven end-to-end on this device.
6. **`/proc/<pid>/stat` IS readable for another UID's process** (via `readproc`) — so CPU-time
   measurement works without root. RSS via `/proc/<pid>/status`; `dumpsys meminfo` for PSS.
7. **Thermal IS observable without root** via `dumpsys thermalservice` (LITTLE 67.0 °C,
   neutral_therm 38.895 °C), even though direct `/sys/class/thermal` is denied. The master
   prompt asks for thermal "if observable" — it is.

**Decision:**
Propose a **one-shot Activity** worker (no service, no daemon, no protocol, no socket, no
HTTP), **file-based exchange over ADB** as the communication boundary, **zero Android
permissions**, a minimal four-state lifecycle, and `install` as a new narrow transport
primitive behind a `WorkerInstaller`. Reuse DTCA-1 (already specified in ADR-003/004 with an
existing local implementation and verifier) as the first workload. Ten decision points raised,
plus **ADR-011** (worker contract) and a **required ADR-010 revision** for the channel root.

**Reason:**
A service would add a lifecycle, a `POST_NOTIFICATIONS` runtime permission (verified
`prot=dangerous` on this device) and background-execution restrictions for no benefit — the
workload is bounded and takes seconds. The file channel needs no permission because adb
already has the group membership to reach the app's own external dir.

**Flagged as the top unknown (R2):** whether `am start` reliably launches the worker while the
device is locked or idle. Per FAIL-003's lesson, this must be **measured, not assumed**, and it
may shape the execution mechanism.

**Next action:** Await review of D-1..D-10 and the ADR recommendations.

**Artifacts:** `phases/phase-05-d8-worker-reconnaissance.md`.

---

## 2026-10-02 — D8 decision review + locked/idle execution experiment

**Phase:** 5 (D8 review)
**Task:** Resolve the locked/idle Activity question with the smallest real-device experiment, and
produce the D-1..D-10 decision table. No implementation.

**Action:**
Checked safety first: `deviceLocked=0`, `strongAuthRequired=0x0`, `lockscreen.password_type=null`
— **no lock credential is set**, so locking could not strand anyone behind a PIN.

Used the **already-installed `com.pixeldesktop.metadata`** app as the experiment subject — built
by this project, single-Activity, and it logs `METADATA_READY` on completion. This required **no
build and no install**. Six conditions were tested, each verified against real device state
(`dumpsys power`, `dumpsys display`, `dumpsys window` `mShowingLockscreen`, `dumpsys deviceidle`).

**Result — the Activity proposal is CONFIRMED, not contradicted:**

| Condition | am start | Process | Work done |
|---|---|---|---|
| unlocked + active | exit 0, 0.27s | 0.25s | yes |
| **locked / screen off** (`mShowingLockscreen=true`) | exit 0, 0.26s | 0.25s | yes |
| already running + duplicate invocation | exit 0 | **same PID**, no duplicate | yes |
| repeated x5 | — | — | **5/5** |
| **deep doze** (`mState=IDLE`) | exit 0 | pid 7411 | yes |
| **adb server killed mid-invocation** | (no adb) | — | **yes — completed with no adb connected** |

The display stayed **OFF** during the locked test: `am start` did not wake the screen or dismiss
the keyguard. And the workload completed with the adb server dead, which is a genuinely useful
property — the worker does not need a live connection to finish, only to receive the job and
return the result.

Also revised **ADR-010** (Revision 1) to record the identity boundary: `/data/local/tmp` is mode
771 owned by `shell`, so adb can write it but an Android worker process **cannot**. The new root
is the worker's own external files dir, reachable by both identities for different reasons. The
containment mechanism is unchanged — still two fixed filenames, no caller paths, regular files
only. The revision adds the principle that **a path's suitability is a property of the pair
(path, identity), not of the path alone.**

Recorded the observable/measurable/**attributable** distinction for resource evidence:
`/proc/<pid>/stat` CPU time is attributable to the worker; `dumpsys thermalservice` temperatures
are **system-wide and NOT attributable** to it. Stated as a limitation rather than smoothed over.

**Incidental:** killing the adb server left the device briefly `unauthorized` on restart —
transient key re-negotiation, not a revocation. It recovered with no user action and
`~/.android/adbkey` was untouched. Recorded so a future agent does not misread it.

**Decision:**
Await approval of the D-1..D-10 table before implementation.

**Reason:**
The experiment was required to be run before the execution mechanism could be treated as proven.
It was run on the real device, with a work-completion signal rather than merely a process check.

**Next action:** On approval, begin the implementation sequence at step 3 (create the Android
project) — step 1 (the execution experiment) is now complete.

**Artifacts:** `phases/phase-05-d8-decision-review.md`, ADR-010 Revision 1.

---

## 2026-10-02 — Phase 5 D8: Pixel Compute Worker implemented and verified on device

**Phase:** 5 (D8 implementation)
**Task:** Build the worker APK, install it, run DTCA-1 on the physical Pixel, verify the result,
and capture evidence distinguishing "the Mac computed the answer" from "the Pixel worker computed
the answer".

**Action:**
Created `DTCA1Worker/` — Gradle 8.13 / AGP 8.13.0 / Java 17 / minSdk 31 / targetSdk 36, mirroring
the proven `AndroidMetadataHelper` template. Two Java files (`WorkerActivity`, `Dtca1`) plus a
manifest with **zero permissions**. `Dtca1.java` is a faithful port of `DTCA1Worker.swift`, with
three divergence traps handled explicitly (tokenizer must split on `isLetterOrDigit`, not `\W`;
Swift's `String.count` counts graphemes, so surrogate pairs are subtracted; the top-word comparator
reproduces count-desc-then-key-asc).

On the Mac side: added `install()` to `TransportProtocol`, and new `WorkerInstaller`,
`WorkerLifecycle`, `DTCA1Job`/`WorkerResultEnvelope`, and `WorkerComputeProof`.

**Result:**
BUILD SUCCESSFUL (APK), BUILD SUCCEEDED (macOS), **154 tests, 0 failures**. Real-device compute
proof **PASS**: DTCA-1 executed on the Pixel, result **VERIFIED** by independent local
re-computation, 3/3 repeated runs verified, ~250–360 ms wall clock, **20 CPU ticks attributable to
the worker's PID**, zero permissions verified on the device, exchange directory mode `2770` owned by
the app's UID.

**Three Android assumptions were falsified by real-device execution** — all three compiled cleanly
and passed all 154 tests:

1. `exported="false"` does **not** let adb start the Activity: `SecurityException: not exported
   from uid 10004`. Export is required; contained by no intent-filter plus a runtime launcher check.
2. `getLaunchedFromUid()` returns **`-1`**, not `2000`, for an adb launch — the launcher check
   refused every legitimate run until corrected.
3. adb **must not** create the exchange directory: an adb-created directory is owned by
   `shell:ext_data_rw`, which the app cannot write. The worker now creates its own directory, and
   `remoteWorkspaceCreateCommand` was removed so adb cannot create it even by accident.

Also: a stale harness binary produced a **false PASS** after a compile error — recognised and
rejected, then re-run on a fully clean device. And `created-resources.json` was found to be
gitignored, contrary to master prompt §28; un-ignored.

**Decision:**
D8 first checkpoint COMPLETE. No approved decision was contradicted — the corrections were to
implementation assumptions about the platform, not to the architecture.

**Reason:**
Three of the six platform assumptions in this project's history were falsified in this phase alone.
The pattern is consistent and now recorded as a technique: a mock asserts what the code *sends*; it
cannot reproduce what the platform *does*.

**Next action:** STOPPED as instructed. Not proceeding to model inference, resource-aware routing,
or Hermes integration.

**Artifacts:** `phases/phase-05-d8-worker-implementation.md`, ADR-011,
`failures/FAIL-004-android-assumptions-falsified.md`, `DTCA1Worker/`.

---

## 2026-10-02 — Phase 6 reconnaissance: Local AI Worker (no code changed)

**Phase:** 6 (reconnaissance + proposal only)
**Task:** Establish the smallest, simplest, experimentally defensible path to real local
language-model inference on the Pixel 7a. **No model downloaded, no runtime installed, no source
modified.**

**Action:**
Read the authoritative Phase 6/7 requirements and the relevant ADRs. Ran read-only measurements on
the Pixel 7a covering SoC, CPU topology, ABI, RAM, swap, storage, GPU, Vulkan/NNAPI/EdgeTPU
availability, SELinux, mount options, exec capability, Java heap caps, ADB throughput, thermal
baseline. Fetched primary documentation for llama.cpp, LiteRT-LM, ExecuTorch, ONNX Runtime and
MediaPipe.

**Result — findings that determine the design:**

1. **NNAPI is NOT available on this device** — `pm list features` has no `neuralnetworks` entry and
   no HAL is present. Measured, not assumed.
2. **EdgeTPU/GXP are present but gated** — the app allowlist (`edgetpu_native.allowlist_app1..12`)
   is entirely empty, so a third-party app cannot use them.
3. **Vulkan compute IS available** (`android.hardware.vulkan.compute`, Mali-G710 ICD).
4. **`/storage/emulated` is mounted `noexec`** — the worker's exchange dir cannot execute anything.
   The model is data, so this does not block it; a runtime binary must ship as an APK native lib.
5. **Only ~2.05 GiB MemAvailable** of 7.27 GiB, with swap 0.6 GB free.
6. **LiteRT-LM's published benchmark** shows a ~2B model needing **1733 MB peak on CPU** — measured
   on a device faster than the Pixel 7a.
7. **ADB throughput is 27.7 MB/s** on incompressible data (an earlier 4030 MB/s reading from a
   sparse file was rejected as not credible).
8. **The Java heap cap (256 MB) does not bound the model** — ggml-style runtimes allocate natively.

**The finding that contradicts a standing assumption:** the historical preference for a 3B–4B model
on the Pixel is **not supportable on this device**. ~2.05 GiB available against ~2.5–3 GB needed for
a 3B Q4 model. Recorded as falsified by measurement rather than quietly adjusted. The first proof
should target ~1B at Q4, with a ~0.5B fallback.

**Decision:**
Propose a one-shot Activity (as D8), file-based exchange over ADB (unchanged), the model in the
worker's own external files dir (app-created, hash-verified), and **llama.cpp with GGUF on CPU** as
the runtime — chosen for its MIT licence, quantization range, single self-describing artifact, and
because CPU-only avoids making the first proof also a GPU backend bring-up. Nine proposed decisions
(P1–P9) and eight unresolved risks (R1–R8).

**The most important honesty point:** D8's independent re-computation verification **does not
transfer** to LLM inference, because the Mac lacks the same model/runtime/backend and generation may
not be bit-reproducible. Proposed replacement is an **evidence chain** whose load-bearing links are
attributable per-process CPU time and an **ablation test** (remove the model → the worker fails),
which establishes causation. It proves inference *occurred on the device*; it does **not** prove the
output is *correct*. Stated plainly rather than glossed.

**The highest-risk assumption (R1):** D8 proved a ~250 ms Activity launches while locked and
dozing. A model load plus generation is two to three orders of magnitude longer, and that is **not**
proven. It must be measured **first**, before any runtime work, because falsifying it changes the
process model — an architecture change, not an implementation detail.

**Next action:** Await review of ADR-012 and the nine proposed decisions. Implementation is BLOCKED.

**Artifacts:** `phases/phase-06-local-ai-reconnaissance.md`, `decisions/ADR-012-local-ai-worker.md`
(PROPOSED, not approved).

---

## 2026-10-02 — Phase 6 IMPLEMENTED: real LLM inference on the physical Pixel 7a

**Phase:** 6 (Local AI Worker)
**Task:** Prove that a real language model, loaded from an artifact physically on the Pixel,
performs inference inside the PixelDesktop worker process.

**Action:**
Ran the R1 experiment FIRST, before any runtime work, using a self-contained probe app. Installed
NDK 27.2 + CMake, cloned and built llama.cpp `a868c3e` for arm64-v8a (CPU only, `GGML_VULKAN=OFF`),
wrote a JNI bridge, added an `Inference/` layer on the Mac, provisioned
Qwen2.5-1.5B-Instruct-Q4_K_M (Apache-2.0), and ran the full real-device sequence.

**Result:**
**Real inference on the Pixel.** `"The capital of France is Paris."` generated by llama.cpp inside
the worker process. Model load 382–437 ms; 3/3 runs with **identical token IDs** (greedy stability
measured, not assumed); **1279 MB native peak**; 4111–4564 CPU ticks attributable to the worker PID;
**ablation PASS** (present→OK, absent→FAILED `MODEL_MISSING`, restored→OK).

**R1 — the highest-risk assumption — is RESOLVED.** A 300 s probe Activity survived unlocked/active,
locked/dozing and forced deep doze with linear CPU accumulation; then real inference completed while
the device was Dozing. **No Service is required.**

**Notable:** **no Android platform assumption was falsified** in this phase. After six phases in
which compiled, test-passing code was wrong on the device, this is plausibly because R1 and the
runtime load were probed *before* the design was committed to.

**Defects found (all harness/toolchain, none platform):** the R1 probe crashed on
`Theme.NoDisplay` (probe's fault); **PID reuse produced a false "deep doze blocks launch" reading**
— corrected by force-stopping between tests; `use_mmap`/`use_mlock` had been replaced upstream by
`load_mode`; system Gradle 9.7.1 vs AGP 8.13; an external memory sampler missed the ~20 s process
entirely, so the worker now self-reports `VmHWM`.

**The honest limit, stated again:** the evidence chain proves inference **occurred on the device**
and that the model is **causally required**. It does **not** prove the output is **correct**.

**Measured performance, and it is slow:** ~0.97–1.46 tokens/s decode and ~4–6 tok/s prefill. A
32-token answer takes ~30 s. This must not be described as interactive performance. ADR-012
deliberately refused to estimate decode rate; it turned out to be the limiting factor.

**Decision:** Phase 6 first inference proof COMPLETE. Stopped as instructed — no GPU, no larger
model, no routing, no Hermes integration, no optimization.

**Artifacts:** `phases/phase-06-local-ai-implementation.md`, ADR-012 (updated to approved and
implemented), `Inference/` (3 Swift files), `DTCA1Worker/` (JNI + native runtime).

---

## 2026-10-02 — Phase 7 reconnaissance: resource-aware routing (no code changed)

**Phase:** 7 (reconnaissance + proposal only)
**Task:** Determine whether PixelDesktop should route workloads between the Mac and the Pixel, and
on what evidence. **No production source modified.**

**Result — the finding that reframes the phase:**

**There is only one executor.** Phase 6 deliberately ensured the Mac does **not** link llama.cpp
(ADR-012 §P7), verified by source inspection. `ollama` happens to be installed on this Mac, but it
is an unrelated user install and nothing in PixelDesktop can call it. **So "Mac or Pixel?" currently
has one real answer for inference workloads, because the Mac option does not exist as an
implementation.** This is the blocking open question.

**Four assumptions a reasonable router would have encoded, all falsified by measurement:**

1. **Pixel latency is predictable — FALSIFIED.** Identical 8-token generation took 5,084 ms warm and
   **14,793 ms** after idle: **2.4× variance**. Model load varied **12×** (393 ms → 4,954 ms).
   Latency cannot be a routing input.
2. **`finish()` destroys the worker process — FALSIFIED.** The process was still alive *minutes*
   later; Android caches it. But the model is **not** resident (freed every run), so **warm process
   ≠ warm model**. True warm execution needs ~1.3 GB resident — an architectural question, not
   implemented.
3. **A Mac executor exists to fall back to — FALSIFIED.** None exists.
4. **Thermal state is comparable across platforms — FALSIFIED.** macOS exposes a 4-level
   `ProcessInfo.thermalState`; Android exposes only a system-wide numeric reading with no worker
   attribution. Incommensurable.

**Cost measurements:** ADB round-trip 226 ms; job+result ~600 bytes (**transfer is not a routing
cost**). Mac 8 tokens with a 4B model in **4.9 s**; Pixel 8 tokens with a 1.5B model in
**16.2–25.8 s** — the Mac ~3–5× faster on a ~2.7× larger model. **Caveat: the Mac figure used
`ollama`, which is not a project component.** It is evidence about the hardware, not about an
executor that exists.

**Decision:** propose three small value types and one **pure function** — descriptor, snapshot,
evaluator, decision — and explicitly **not** a scheduler, queue, `ResourceMonitor`, or fleet
abstraction. Routing inputs limited to four (workload type, model requirement, memory requirement,
availability), each justified by an existing workload. Fail and report; **no retries** — each
attempt costs 16–26 s of sustained device load, and deterministic failures cannot be retried into
success.

**Recommendation:** **resolve the Mac-executor question before implementing anything.** If there is
no Mac executor, the router can only ever choose the Pixel, and a feasibility gate is a
*validation* concern better expressed as an extension of the existing `InferenceRequest.validate()`
than as a new subsystem.

**Artifacts:** `phases/phase-07-routing-reconnaissance.md`, ADR-013 (PROPOSED, not approved).

---

## 2026-10-02 — Phase 7 architecture RE-EVALUATION: the router proposal was withdrawn

**Phase:** 7 (architecture re-evaluation; no code changed)
**Task:** Re-evaluate ADR-013's router against the actual Phase 1–6 implementation and the master
prompt, following a user correction that Hermes should own workload planning.

**Result — the correction was right, and for a stronger reason than given:**

**Master prompt §1 places orchestration on the Mac, ABOVE PixelDesktop:**

```
Mac
 ├── UI
 ├── orchestration        <-- NOT inside PixelDesktop
 ├── complex reasoning
 └── AI coordination
```

ADR-013's `FeasibilityEvaluator` inside PixelDesktop therefore put a decision-making component on
the **wrong side of a boundary the master prompt had already drawn**, and duplicated a decision
Hermes already owns. §9 independently assigns Hermes the capability understanding, workload
creation, monitoring and result receipt.

**How the error happened, recorded honestly:** the reconnaissance *found* the evidence against a
router — §B "there is only one executor"; §H cost-comparison routing "blocked by evidence"; §N
"the honest frame may be that the Mac is the compute node and the Pixel is a specialised node". The
right question was surfaced and then a router was proposed anyway, because the brief's candidate
structure listed one. **Process lesson: when the evidence says "no component", propose no
component.** Added as T-021.

**The corrected architecture:** Hermes owns decomposition, placement and synthesis; PixelDesktop
publishes a **capability contract** and **enforces** feasibility. The critical distinction is
**decision vs enforcement** — Hermes's belief about capability is an optimisation input; PixelDesktop's
validation is the authority. A stale Hermes belief costs a wasted round-trip, never an invalid
execution. **D8/Phase 6 containment is unchanged.**

**Key finding on scope:** the proposed contract is **~80% already implemented** — `ModelContract`
supplies model name/hash/size, `InferenceRuntimeIdentity` supplies runtime+backend,
`DeviceCapabilities` supplies ABIs, `InferenceResult` already returns timings and model hash. **Only
context size is genuinely missing** (it lives only in `llama_jni.cpp` as `kContextSize`). The work is
*publishing existing state*, not building machinery — and the corrected design has **fewer components**
than the router it replaces.

**Withdrawn:** `FeasibilityEvaluator`, `WorkloadDescriptor`, `Decision{target,reasons}`,
`ResourceSnapshot` as a local decision input, `Executors`/`ExecutionNode`, and any Mac executor.
**Retained:** P2 (approved capabilities only), P6 (fail and report; no retries), P7 (a snapshot is
not a reservation), P8 (support / non-support / unknown), and the full §M failure-hypothesis table.
**ADR-013 marked SUPERSEDED, preserved not deleted** — its measurements remain valid.

**Most consequential new risks:** R1 — LLM decomposition is non-deterministic, so routing becomes
irreproducible (mitigation: require an explicit plan before execution); R4 — this redefines Phase 7
into territory adjacent to Phase 9, needing an ADR-007 amendment.

**Next action:** BLOCKED pending review. Recommended first step is an ADR-007 amendment renaming the
phase's purpose, then publishing the contract **before** writing the Hermes skill.

**Artifacts:** `phases/phase-07-architecture-reevaluation.md`; ADR-013 marked SUPERSEDED.

---

## 2026-10-02 — Phase 7 Step 0: ADR-007 Amendment 1 (Phase 7 formally redefined)

**Phase:** 7 (Step 0 — documentation only; no code changed)
**Task:** Amend ADR-007 to formally redefine Phase 7 per the completed re-evaluation.

**Action:**
Appended **Amendment 1** to ADR-007. The original text is untouched — the Phase 7 row of the
master-prompt phase table now carries a `†` marker pointing to the amendment, and the amendment
states its effective date and explicitly supersedes ADR-013, which is exactly what ADR-007's own
*Future Reconsideration Conditions* required before any amendment could be made.

**Content:** 15 clauses (A1.1–A1.15) covering: why the router was withdrawn; the Hermes/PixelDesktop
boundary; Hermes as planning authority; PixelDesktop as enforcement authority; why LLM
decision-making does not remove the need for PixelDesktop-side validation; the
round-trip-not-safety guarantee; the new Phase 7 purpose; the eight removed components; the five
retained principles and eight retained measurements with their limitations; the Phase 9 relationship;
**R4** (the Phase 7/Phase 9 boundary, resolved by direction of information); and **R9** (`shell()`
stays inaccessible to Hermes, not Phase 7 work).

**Why the original text was annotated rather than rewritten:** ADR-007 itself established that
convention when it annotated the Phase 0 audit §9 table instead of rewriting it. The same rule
applies to itself — erasing the fact that Phase 7's definition changed would destroy the reasoning
that produced the correction.

**Consistency corrections made:**
- `phase-07-routing-reconnaissance.md` — added a SUPERSEDED banner naming the current authority and
  separating what remains valid (all §C–§G measurements) from what is withdrawn (§H–§K architecture).
- `architecture/overview.md` — the phase table row for Phase 7 now points at the amendment.
- `engineering/README.md` — Phase 7 line and the ADR-007 index entry updated.

**Preserved:** ADR-013 remains on disk, SUPERSEDED, measurements intact and cited by the amendment.

**Next action:** STOPPED at Step 0 as instructed. Step 1 (publish the capability contract) awaits
explicit approval.

**Artifacts:** `ADR-007-authoritative-phase-sequence.md` (Amendment 1).

---

## 2026-10-02 — Phase 7 Step 1: the Pixel capability contract

**Phase:** 7 (Step 1)
**Task:** Publish the smallest stable contract letting Hermes learn what the Pixel can support,
deriving every field from existing authoritative definitions rather than creating a new subsystem.

**Result:**
`PixelCapabilityContract.swift` — a versioned value type whose every field is DERIVED from an
existing source: `AndroidDevice` (device), `InferenceRuntimeIdentity`/`LlamaCppRuntime` (runtime),
`ModelContract` (model name/hash/size), `InferenceRequest` (limits), the worker dispatch
(workloads). **No new capability subsystem was created.** 226 tests, 0 failures (was 194).

**Context size resolved without a second source of truth.** `kContextSize` lived only in
`llama_jni.cpp`. Rather than duplicate it as a Swift constant (which could drift), the native layer
now reports the context it **actually allocated**, read back via `llama_n_ctx()`. Verified on the
device: source 2048 = runtime 2048, with the model's trained maximum (32768) published separately
because conflating them would misstate what a caller may send.

**Provenance model:** every field carries `source` (.declared / .deviceReported / .runtimeReported),
`observedAt` (nil for declared values — a constant is not an observation), and a `limitation` stating
what the value does NOT establish. A test enforces that no field can omit its limitation, and another
asserts the encoded contract contains **no performance field** — because reconnaissance measured a
2.4× latency variance and a 12× load variance, and publishing a token rate would present an unstable
observation as a constant.

**DEFECT FOUND AND FIXED — FAIL-005.** Real-device verification of the context boundary uncovered
that a prompt longer than `n_batch` (256) makes `llama_decode()` call `ggml_abort()` and **SIGABRT
the worker** — no result file, indistinguishable from a crash-loop. **It compiled cleanly and passed
all 224 tests.** The Phase 6 guard covered `n_ctx` (2048) but `n_batch` is a separate, smaller, and
FATAL bound. Fixed by chunked decode; verified on the device — the identical input that previously
aborted now completes **820 prompt tokens in 5.1 minutes** with `status=OK` and no new abort.

This also **corrected the contract's own text**, which had claimed overflow is "refused by the
runtime". That was wrong for the batch bound, and the limitation now states both behaviours
accurately.

**A planning fact this exposed:** prompt processing is ~2.7 tok/s, so **prompt size dominates the
cost of a Pixel workload** — far more than generation. Recorded as measured evidence; deliberately
NOT turned into a routing threshold.

**Seventh defect of its family** (compiled, passed the suite, wrong on the device). Found only by
sending a real oversized prompt to real hardware. Recorded as T-023.

**Regressions:** `LOCAL-LLM-1` 3/3 runs with identical token IDs (greedy stable); `DTCA-1`
`COMPLETED` with Mac re-computation matching; zero permissions retained.

**Next action:** STOPPED at Step 1. Step 2 (measured performance evidence) awaits approval.

**Artifacts:** `phases/phase-07-step-1-capability-contract.md`,
`failures/FAIL-005-prompt-exceeding-nbatch-aborts-worker.md`.

---

## 2026-10-02 — Phase 7 Step 2: measured evidence with provenance and freshness

**Phase:** 7 (Step 2)
**Task:** Publish measured/dynamic evidence so a consumer can distinguish "the Pixel is capable" from
"the Pixel is capable AND this observation is current enough to matter".

**Key finding on reuse:** **`CapabilityValue` from Step 1 already WAS the observation shape this
step required** — value + source + observedAt + limitation. Creating a second observation type would
have been the "duplicate information" failure the brief warns about. Step 2 therefore adds three
value types and one reader, and nothing else. **No ResourceMonitor, no polling daemon, no cache, no
scheduler, no reservation system, no refresh loop.**

**Deliberately NOT collected** despite being available: per-core CPU utilisation (not readable for
other processes without root), battery level (no worker attribution), GPU state (no path exists),
load average (no consumer yet). The brief's "do not create measurements merely because they are
technically available" was applied literally.

**Freshness has NO default threshold.** PixelDesktop has no defensible basis for declaring "memory
readings older than N seconds are stale" — that depends on what the consumer intends. `maxAge` is a
required parameter; PixelDesktop does the arithmetic and the caller supplies the window. A future
timestamp returns `unknown`, NOT `current`, because that means the clock is wrong and calling it
current would hide a real problem.

**Snapshot ≠ reservation, demonstrated for real.** The failure chain was exercised end-to-end on the
device: an observation showed the model present → the model was renamed → a workload was submitted →
**PixelDesktop REFUSED with `MODEL_MISSING`** → the model was restored. A stale observation produced
a **rejected request, not unsafe execution** — the exact claim of ADR-007 Amendment 1 §A1.6,
verified rather than asserted.

**Page-cache state is always `.unknown`.** The reconnaissance PROVED it matters (393 ms → 4,954 ms
model load) but there is no non-root way to determine it. Modelled as a field that is always unknown
so the gap is visible. Inventing a value would have been worse than omitting it.

**An unreachable device yields an observation, not an error** — every field `.unknown` with no
timestamp. Throwing would discard the one fact available. **This path was exercised for real**: the
device disconnected mid-verification and the reader handled it.

**Real-device results:** reachable, memory 2,451,505,152 bytes, storage 58,859,884,544 bytes, worker
`installed(versionCode: 2)`, model `present(byteCount: 1117320736)` matching `ModelContract`
exactly, thermal 0 — all `[deviceReported]`. Freshness `current` at a 60 s window and `stale` at 0 s,
proving it is computed rather than fixed. All 12 execution-evidence fields present in a real result.

**Refusal path verified:** unsupported workload, non-greedy temperature, max_tokens over ceiling,
and model absent all return bounded `error_type` failures.

**261 tests, 0 failures** (was 226; Step 2 adds 35). Two of my own tests were wrong and were
corrected rather than worked around — one needed `try XCTUnwrap`, the other zeroed generation but
left a 27-token prompt so the prompt rate was legitimately non-nil.

**Regressions:** `DTCA-1` COMPLETED with Mac re-computation matching; `LOCAL-LLM-1` 3/3 runs with
identical token IDs; zero permissions retained.

**Next action:** STOPPED at Step 2. Step 3 awaits approval.

**Artifacts:** `phases/phase-07-step-2-evidence.md`, `PixelDesktop/Inference/PixelEvidence.swift`.

---

## 2026-10-02 — USB disconnection investigation (Phase 7 paused at user request)

**Phase:** none — separate investigation, explicitly outside Phase 7 Step 3
**Task:** Determine why the Mac ↔ Pixel 7a USB connection repeatedly drops on its own.

**Result — root cause identified, PixelDesktop EXCLUDED.**

The teardown is a **macOS kernel USB host-controller event**, strictly below ADB:
`AppleUSBXHCIRequest ... status 0xe00002ed (transaction error)` followed by
`AppleUSBHostPort::terminateDevice ... hardware connection lost` (11×) or `hardware port disabled`
(13×). **24 teardowns today.**

**Layers cleared by evidence:**
- **ADB server** — pid 90509 up continuously 07:24 → present, through every 07:32–14:07 teardown.
  Never restarted; `kill-server` never invoked.
- **Pixel** — USB service up **1 day 13 hours**, `sys.usb.config=adb` stable,
  `VIRTUAL-USB-THROTTLING=0`, usb_pwr_therm ~32 °C. Not disconnecting itself.
- **PixelDesktop** — **not running during any teardown**. `ADBTransport` has no reconnect, retry,
  poll-to-act, or kill-server logic; the sole `Task.sleep` is a command timeout. `DeviceManager`'s
  5 s poll is read-only. **No code change warranted.**
- **Hub** — excluded; the Pixel is attached **directly** to the XHCI controller.

**Two contributing factors, quantified:**
1. **System sleep** — `sleep 1` (one minute!), **92 sleep transitions + 91 DarkWakes today**. Direct
   correlation: 07:07:13 Sleep → 07:07:26 Wake → 07:07:34 enumerate → 07:10:12 connection lost.
2. **Browser USB contention** — Chrome and Brave both take **exclusive** USB access to the Pixel,
   **49 events today**, peaking at 12 in the 13:00 hour. At 13:40:27 a contention event and a
   port-disable occur **within the same second**, three times.

**Honest limits, recorded not smoothed:** the failure **did not recur** during 7 minutes of
continuous monitoring (84 samples, all `adb=1 usb=1`), so the root cause is inferred from the
historical record rather than reproduced. **Two of seven afternoon teardowns (13:32, 14:07) have no
identified trigger at all.** Cable vs port cannot be separated without a physical swap.

**Recommended remedies, in order of evidence:** swap cable and port (the only test that separates
cable from port); `sudo pmset -c sleep 0`; quit both browsers while using the Pixel.

**Explicitly rejected:** an automatic reconnect loop in PixelDesktop. It would mask a
physical-layer fault behind a software workaround — the exact outcome the investigation was asked
to avoid. No reconnect mechanism is justified by this evidence.

**Artifacts:** `failures/FAIL-006-usb-connection-drops.md`. No production code changed.

---

## 2026-10-02 — USB-aware transport design (investigation/design only)

**Phase:** none — transport resilience. Explicitly NOT workload routing or resource management.
**Task:** Determine whether macOS offers an event-driven USB presence mechanism, and design
transport recovery around it. **No production code modified.**

**VERIFIED BY RUNNING CODE — IOKit USB notifications work on macOS 27.0.**
A throwaway Swift probe compiled and ran, then was deleted:
  attach notification registered (result=0)
  PRESENT-AT-START: Pixel 7a  0x18d1/0x4ee2  serial=3C261JEHN25632
  detach notification registered (result=0)
`IOServiceAddMatchingNotification` returned KERN_SUCCESS for BOTH `kIOFirstMatchNotification` and
`kIOTerminatedNotification`, matched `IOUSBHostDevice`, required **no root and no entitlement**, and
— critically — **`kUSBSerialNumberString` returns `3C261JEHN25632`, the SAME serial ADB uses.**
That closes the trust boundary cheaply: a USB attach carries the identity needed to decide "is this
my Pixel?" WITHOUT first trusting ADB.

**THREE FINDINGS THAT SHAPE THE DESIGN**

1. **There is no wireless support at all.** `grep -rniE 'wireless|mdns|bonjour|tcp|:5555|pair'`
   over `PixelDesktop/` returns ZERO functional matches. And wireless ADB is OFF ON THE DEVICE:
   `service.adb.tcp.port` unset, `adb_wifi_enabled=0`. So the proposed flow "wireless active → USB
   appears → switch to wired" has **no wireless leg to start from**. Implementing transport
   switching now would build a state machine with one reachable state.

2. **`TransportProtocol` is already device-targeted, not transport-targeted.** Every method takes
   `deviceSerial:` and `ADBTransport` builds `adb -s <serial>`. **A wireless transport can satisfy
   it unchanged, and no caller needs to know which is active.** The abstraction boundary is already
   correct — no parallel transport architecture is needed, and no `TransportManager` is proposed
   (with one implementation it would manage one thing — the ADR-013 mistake repeating).

3. **`wiredDegraded` is the state the code cannot express, and it is the whole point.** FAIL-006's
   live observation was USB CONNECTED + ADB DISCONNECTED. The current model can only say "not
   connected", which loses the most important fact: the hardware is fine and the problem is above
   it. That distinction decides whether the right response is "check the cable" or "check ADB".

**HONEST LIMITATION OF APPROACH B, stated plainly:** cases 3 and 7 (USB present, ADB broken) are
**event-silent**. The USB device never left, so IOKit fires nothing. **No USB-triggered mechanism can
detect them** — only an attempted operation that fails, or a low-frequency reconciliation check.
This is a genuine gap in the intended direction, not a detail.

**Debounce:** justified by measured evidence (FAIL-006 recorded three teardowns within ~1 second at
13:40:27, and the device repeatedly vanished from `adb devices` while `ioreg` continuously showed it
present). Debounce ATTACH only; DETACH must be immediate. **No duration is proposed** — the flap
distribution is unmeasured, and choosing a constant would repeat the invented-policy mistake that
ADR-013 §P7 and Phase 7 Step 2's `Freshness` both avoided. The window is a parameter with no
default. Better still: **verification subsumes most of the need for a timeout.**

**Verification must be positive, not inferred:** listed by ADB + state `.device` + transport field
begins `usb:` + a round-trip succeeds. Note the `usb:` field is **currently parsed and discarded**,
and the observed value `usb:1048576X` is anomalous — so the design must not validate the full
string.

**RECOMMENDATION — do not implement yet, for a concrete reason:** the wireless leg does not exist,
the physical fault is unresolved (building recovery on it would hide it — the outcome FAIL-006
warned against), and the flap distribution is unmeasured. Order: (1) finish the FAIL-006 physical
isolation test + 1-hour observation; (2) then `USBPresenceMonitor` + `TransportState`, which is
useful even with zero wireless support because it makes `wiredDegraded` visible; (3) wireless
transport as its own decision.

**Phase 7 architectural boundary: UNCHANGED.** This is transport resilience — "is the connection I
have still usable?", not "where should this workload run?". It does reinforce one Phase 7 principle:
`wiredDegraded` is the transport-layer expression of ADR-007 Amendment 1 §A1.6 — know the difference
between "capable" and "currently usable", and never let the first stand in for the second.

**Artifacts:** `design/usb-aware-transport-design.md`. No production code changed.

---

## 2026-10-02 — Wireless ADB persistence design (investigation/design only)

**Phase:** none — transport resilience. Explicitly NOT workload routing or resource management.
**Task:** Determine why a previously-working wireless ADB connection needed manual intervention, and
design persistent wireless fallback. **No production code modified. No device settings changed.**

**THE FINDING THAT RESHAPES THE REQUIREMENT**
`adb` ALREADY does automatic mDNS discovery and reconnection:
    $ADB_MDNS_AUTO_CONNECT   comma-separated list of mdns services to allow auto-connect
                             (default adb-tls-connect)
The default IS adb-tls-connect. So adb already discovers the device and connects to whatever endpoint
is currently advertised — no hardcoded IP, no hardcoded port. **PixelDesktop does not need to
implement mDNS discovery at all.** Verified: `adb mdns check` succeeds. Not verified: the actual
auto-connect, because nothing is advertising.

**THE REAL CAUSE: the toggle, not the connection**
Android automatically DISABLES wireless debugging after inactivity, on Wi-Fi disconnect, and on
reboot. Multiple independent sources; and Google is fixing it in Android 17 + adb 37 by
auto-RE-ENABLING on trusted Wi-Fi — the existence of that fix corroborates the mechanism.
So almost everything that breaks the connection automatically also disables the toggle, and the
toggle is what needs a human.

**THE MANUAL-INTERVENTION BOUNDARY IS NARROWER THAN EXPECTED**
NOT "reconnection". It is: **"re-enabling wireless debugging while no transport is available."**
Reconnection is already automatic (adb mDNS). And with USB present the toggle can plausibly be
re-enabled programmatically: the device shell runs as uid 2000 in group 1011(adb) and HAS
WRITE_SECURE_SETTINGS (verified, 3 grants). That yields a genuine recovery ladder:
    wired healthy  -> can re-enable wireless programmatically -> wireless available as fallback
    wireless only + toggle off -> NO transport exists to re-enable it -> MANUAL (chicken-and-egg)
The write was NOT executed — it is a device state change and must be tested deliberately.

**PREVIOUS FAILURE — investigated, NOT reproduced, and said so plainly**
Evidence a wireless session occurred: ~/.android/adb_known_hosts.pb exists (29 bytes, Sep 17 22:52).
But that is TWO WEEKS ago, not "yesterday", and the file may only be written on first pairing, so it
is weak dating evidence — not presented as proof of when the failure happened. Mac logs for the last
24h returned only WebKit QUIC noise (the string "adb" inside random hex). Pixel logcat had no
wireless history — the buffer had rolled over. **The cause is inferred from documented mechanism,
not reproduced.**

**VERIFIED DEVICE FACTS (Android 16, API 36, BP3A.251005.004.B1)**
wireless debugging OFF (adb_wifi_enabled=0); service.adb.tcp.port and service.adb.tls.port unset;
adb_enabled=1; ro.adb.secure=1; adb_allowed_connection_time=0; Wi-Fi on, SSID "RCB"; Pixel
192.168.1.9 / Mac 192.168.1.10, same subnet; mdnsd not running; /data/misc/adb/adb_keys NOT readable.

**TWO INDEPENDENT STATES, the core distinction**
  STATE A: is wireless debugging ENABLED?  (adb_wifi_enabled) -> VOLATILE, lost on reboot/Wi-Fi/
           inactivity. Controls whether the device advertises at all.
  STATE B: is the Mac PAIRED/AUTHORIZED?   (/data/misc/adb/adb_keys) -> PERSISTENT, a key written
           once. Same file serves USB authorization AND wireless pairing — which is why USB
           debugging is the recovery path.
Conflating A and B is the mistake this design exists to prevent.

**SECURITY:** no key material read, copied, or displayed. Automatic pairing NOT proposed — pairing
requires a code the user reads off the device; automating it would weaken the model. Prefer the
modern TLS mechanism over legacy plaintext tcpip 5555.

**RECOMMENDATION — do not implement yet:** wireless debugging is off so nothing can be verified; the
load-bearing assumption (does `adb -s <serial>` work for a wireless device?) is UNTESTED and decides
whether this is a small change or a structural one; and the FAIL-006 physical fault is unresolved.
Order: (1) enable + pair, then test `-s <serial>` — this single test decides the architecture;
(2) test whether `settings put global adb_wifi_enabled 1` works over USB; (3) then the pure
classification type + TransportState, valuable on its own merits because today the user cannot tell
"cable unplugged" from "wireless debugging silently turned itself off six hours ago".

**Phase 7 architectural boundary: UNCHANGED.** Transport resilience — "which transport can reach
the Pixel?", not "where should a workload run?".

**Artifacts:** `design/wireless-adb-persistence-design.md`. No production code changed.

---

## 2026-10-02 — Wireless serial transport VERIFIED on the physical Pixel 7a

**Phase:** none — verification of the single architectural unknown from `a2c0858`.
**Task:** Does `adb -s <serial>` work when the Pixel is connected through wireless debugging / ADB TLS?
**Result: YES — but the architectural conclusion is NOT "the abstraction works unchanged".**

**THE CRITICAL FINDING — the wireless serial is NOT the USB serial**
    3C261JEHN25632                                      device usb:...    <- USB
    adb-3C261JEHN25632-laKyZz._adb-tls-connect._tcp     device            <- WIRELESS
Two INDEPENDENT device entries with DIFFERENT serials. Confirmed by `adb disconnect`: the wireless
entry vanished while the USB entry survived. Format is
`adb-<hardware-serial>-<random6>._adb-tls-connect._tcp`.

So `-s <serial>` itself works fine with EITHER serial. The real consequence is a DUPLICATION
problem: a discovery pass over `adb devices` sees TWO entries for ONE physical phone, and code
keying on `serialNumber` would treat them as two devices. That is a MODELLING problem, not a
manager problem — no TransportManager is proposed.

**COMMAND PATTERN COMPARISON — byte-identical across both transports**
  getprop ro.product.model        Pixel 7a  ==  Pixel 7a     OK
  getprop ro.build.version.sdk    36        ==  36           OK
  getprop ro.product.manufacturer Google    ==  Google       OK
  shell echo round trip           correct   ==  correct      OK
  shell pidof com.pixeldesktop.worker  4251 ==  4251         OK
  ls model dir                    same      ==  same         OK
Plus a WRITE: `push` of a 24-byte file over wireless succeeded, read back correctly, cleaned up.
No difference was observed in ANY command tested.

**T-029 CONFIRMED ON HARDWARE — adb auto-discovers and auto-reconnects**
Advertisement appeared within ~5 s. adb connected with NO manual `adb connect`. After a forced
`adb disconnect`, the wireless entry reappeared AUTOMATICALLY within <=5 s with the SAME serial.
Only `transport_id` changed (20 -> 40). **No custom mDNS layer is needed.**

**SERIAL STABILITY — stable where it matters, port changes freely**
  initial enable            serial=...laKyZz   port=35987
  after forced disconnect   same serial        port=35987   (auto-recovered)
  after toggle OFF -> ON    SAME suffix        port=33197   (CHANGED)
The port changed and the same serial kept working — that is the payoff of name-based targeting over
endpoint-based. **But one toggle is not proof of general stability**; persistence across a device
restart, Wi-Fi reconnect, or re-pair is UNTESTED and flagged as the most consequential unknown (U1).

**SETUP — no pairing was required.** `settings put global adb_wifi_enabled 1` succeeded (0 -> 1),
confirming the design's section 12 claim that the shell's WRITE_SECURE_SETTINGS grant makes the
toggle programmable when a transport already exists. The Mac's existing ADB key was already
authorized — the same key store serves USB authorization and wireless pairing, as predicted.
No pairing code was used; no key material read, copied, or displayed. TLS throughout
(`ro.adb.secure=1`); no unauthenticated TCP ADB.

**ARCHITECTURE INSPECTION (requirement 1):** `deviceSerial` is passed through as adb's `-s` in 6
places; `parseDeviceList` takes `parts[0]`; a search for usb|wired|cable|physical across
Transport/ and Device/ returned ZERO functional matches. **No USB assumption exists.** The
practical way to tell the transports apart is the `usb:` token — which `parseDeviceList` currently
discards.

**Remaining unknowns (7), U1 most consequential:** suffix stability across restart/re-pair; behaviour
on IP change; Mac sleep/wake; targeting the USB serial when USB is physically absent; wireless
throughput; `.local` name variants; `adb_allowed_connection_time=0` semantics.

**Device state left behind:** wireless debugging left ON (the deliberate setup the task required);
both transports reachable; probe file removed; no production code changed.

**Artifacts:** `testing/wireless-serial-transport-verification.md`.

---

## 2026-10-02 — Communication architecture reconnaissance (comparative design study)

**Phase:** none — architecture reconnaissance. **No production code modified. Nothing implemented.**
**Question:** can a different Mac↔Pixel channel give PixelDesktop materially more capability than ADB?

**EXECUTIVE FINDING: no alternative is justified today.** Three measured findings carry it.

**FINDING A — the overhead is real but small relative to the work.**
Measured fixed orchestration per job: **~1,257 ms** (push 231 + am start 267 + wait 758). Measured
Phase 6 LLM inference: **12-26 s**. So orchestration is **~5-10%** of an LLM job. Eliminating it
entirely would not change what the system can do.

**FINDING B — adb shell ALREADY streams and ALREADY holds a persistent bidirectional session.**
Verified by running both: a long-lived adb shell emitting progress lines delivered each line as
produced; a multi-command adb shell ran as one bidirectional channel. **Our file-exchange-plus-
polling design is a CHOICE, not an ADB limitation.** This removes two of the main claimed reasons to
replace ADB.

**FINDING C — the privilege gap runs the wrong way, and it is decisive.**
ADB runs as uid=2000(shell) with readproc, ext_data_rw and WRITE_SECURE_SETTINGS. Our worker runs as
u0_a45 with ZERO permissions. The privileged operations the system depends on — am start,
am force-stop, pidof, /proc/<pid>/stat of another uid, settings put global — are ONLY available
through ADB. A Service running as the app's own uid has NONE of them.
**So RPC cannot replace ADB; it can only supplement it — which is strictly more system, not less.**

**CANDIDATES REVERSE-ENGINEERED**
- ADB: persistent, bidirectional, streams, host-initiated only. Holds ALL privileges.
- WebSocket/gRPC: genuinely adds device-INITIATED events — the one real gap — at the cost of
  INTERNET + FOREGROUND_SERVICE + POST_NOTIFICATIONS, a mandatory notification, a Mac-side listener,
  a custom protocol, TLS and auth. Gains ZERO privilege.
- gRPC vs WebSocket: identical capability here; gRPC adds protobuf, codegen and APK size for a
  176-byte job envelope with ONE consumer. No capability is reachable via gRPC that a plain socket
  does not provide — the difference is developer ergonomics.
- **adb forward to a local abstract socket: the strongest candidate.** Reaches an APP-OWNED socket
  over the existing authenticated ADB connection. Adds NO permission, NO LAN listener, inherits ADB
  auth and TLS. Still host-initiated. This is the only alternative that adds capability without
  adding a network surface or a permission.
- USB custom protocol: INFEASIBLE for a non-root app — /config/usb_gadget is Permission denied and
  the gadget is owned by init/usbd (11210000.dwc3). Would also contend with ADB for the same
  interface, which FAIL-006 already documented Chrome/Brave fighting over. Adds no capability.
- Bluetooth: present (bluetooth, bluetooth_le) but slower, adds BLUETOOTH_CONNECT, adds no capability.

**THE ONE GENUINE GAP:** device-initiated (unsolicited) events. ADB is host-initiated; the Pixel
cannot speak first. Everything else commonly cited — streaming, sessions, progress — ADB already
does. **And no phase to date has needed device-initiated telemetry.**

**RELIABILITY: in EVERY RPC failure row, ADB is still required for recovery.** The worker app can
only be STARTED by ADB (am start), STOPPED by ADB (force-stop), and its liveness only observed via
ADB (pidof). So the honest architecture is not "ADB or RPC" but "ADB + RPC" — ADB is the mandatory
bootstrap.

**PERFORMANCE: no RPC figure is measured and none is claimed.** For DTCA-1 (~1 ms compute)
orchestration is ~99.9% of wall time, so RPC would help enormously in relative terms. For LLM
(12-26 s) it is ~5-10%. **The LLM workload is the one the project exists for.** DTCA-1 is a proof
workload, not a product feature.

**SECURITY asymmetry:** a network RPC endpoint is a new, discoverable, unauthenticated-by-default
LAN surface — on a subnet FAIL-006 already showed is shared with two browsers. adb forward avoids
this entirely. **An unauthenticated HTTP/WebSocket service is not recommended under any variant.**

**RECOMMENDATION: keep ADB; add no second channel; add no Service.** Instead two zero-permission,
zero-network improvements that capture most of the claimed benefit: (1) use adb shell as a STREAMING
session for long jobs — already available, removes the polling and the 758 ms wait; (2) if an
app-owned channel is ever needed, use adb forward, which adds no permission and no network surface.

**ANSWER TO THE BRIEF'S CLOSING QUESTION: No.** No candidate is both more capable AND simpler. Every
alternative that adds capability adds a Service, permissions and a failure surface — so it is MORE
complex. Every alternative that is simpler adds NO capability. **The correct action is to use ADB
better, not to replace it.**

**REQUIRED EXPERIMENTS (5). E5 is the gate:** identify a concrete workload requiring device-initiated
telemetry. Without one there is no justification for a second channel. **E1 should be done first** —
stream a long job over a single adb shell — cheapest, needs no new architecture, may capture most of
the benefit.

**Phase 7-9 impact: NONE.** The capability contract, evidence layer and transport state are all
transport-agnostic. Keeping ONE channel keeps the Hermes→PixelDesktop→Pixel interface stable.

**Artifacts:** `design/communication-architecture-reconnaissance.md`.

---

## 2026-10-02 — E1: persistent ADB shell as a streaming control channel (experiment)

**Phase:** 7 (experiment). **Disposable. No production code modified. No experimental files left in
the repo or on the device.**

**RESULT: ADB is not limited to one-shot host commands.** A single persistent adb shell drove a
complete long-running worker job - delivering the payload on stdin, launching the worker, streaming
progress, and returning the structured result - in ONE session.

**MEASURED (happy path, 32-token LLM job)**
  time to first output        0.06 s
  time to launch ack          0.17 s
  progress                    26 heartbeats, ~1.00 s apart, across a 27.6 s job
  buffering                   NONE - lines arrived as produced (not batched at the end)
  completion detection        via the stream; NO separate polling loop
  result                      full 176-byte structured JSON, inline
  stdout/stderr separation    preserved (stderr empty)
  -> this removes the 758 ms poll cycle from the critical path.

**FAILURE / EDGE CASES**
  F1 model missing      FAILED MODEL_MISSING in 1.2 s
  F2 malformed job      FAILED INVALID_INPUT in 0.17 s
  F3 cancellation       EXTERNAL only - am force-stop took 69 ms. Streaming adds NO cancellation.
  F4 worker died        heartbeat DETECTED the death (pid -> none at n=7) but the naive loop KEPT
                        GOING. The signal exists; the script must act on it. Most important lesson.
  F5 256-token output   still running past 90 s - a HARNESS cap, not a streaming limit.
                        => a fixed heartbeat cap is wrong; bound the wait by a real timeout.
  F6 locked / Dozing    streamed NORMALLY - 25 lines, result OK in 19.33 s (mWakefulness=Dozing)
  F7 transport died     worker SURVIVED (pid 17751 alive); result.json later written and retrievable
                        (2983 bytes, status=OK, 256 tokens, total_ms=313946)

**THE CENTRAL DESIGN FINDING (F7)**
The streaming session ended at ~8 s. The worker kept running and the result was still written to
disk. **The stream carries PROGRESS; the file carries the RESULT. They are not interchangeable.**
A streaming design that dropped result.json would be LESS robust than what exists today.

**DECISION: A - persistent ADB shell is viable and should replace the POLLING mechanism**, with the
qualification that it is ADDITIVE. It replaces the polling loop (758 ms -> ~0 s) and adds progress
observability; it does NOT replace the durable result file. Not B (benefit is measured and
concrete). Not C (no blocking limitation found - F4 is a scripting mistake with an obvious fix).

**WHAT CAN GO:** the Mac-side polling loop; the separate adb push (payload rides stdin); the
separate adb pull for the result.
**WHAT MUST STAY:** the durable result.json (F7); am force-stop cancellation (F3); pidof liveness
(F4); the one-shot Activity (no Service needed); the fixed-path size-capped contract.

**LIMITATIONS (7), L6 most consequential for future work**
  L1 a session that dies loses the STREAM (progress is not durable)
  L2 cancellation is external to the session
  L3 worker death is invisible to a naive loop
  L4 job duration is unbounded in practice
  L5 one session = one job
  L6 ** progress granularity is what the SCRIPT emits. The worker currently emits NO progress, so
     real progress requires a WORKER-SIDE change - a separate decision, not a transport property. **
  L7 the session is host-initiated; the Pixel still cannot speak first

**This is a change to HOW PixelDesktop uses ADB - not a new channel.** It is the improvement the
communication reconnaissance recommended as improvement #1, now verified on hardware.

**Artifacts:** `phases/phase-07-e1-adb-streaming-experiment.md`.

---

## 2026-10-02 — E1 streaming IMPLEMENTATION (production)

**Phase:** 7. **Implementation, not reconnaissance.** Verified on the physical Pixel 7a.

**WHAT CHANGED:** worker orchestration moved from file exchange + Mac-side polling to a SINGLE
persistent adb shell that streams events, with the durable result file kept as the record of truth.
The OLD path is NOT deleted - it remains for the Phase 5/6 flows and its tests still pass. The
streaming path is ADDITIVE, exactly as E1 required.

**FILES**
  new  Worker/WorkerStreamProtocol.swift   event protocol, parser, stream state, outcome model
  new  Worker/WorkerStreamReducer.swift    the pure state machine (F4 + F7 logic)
  new  Worker/WorkerStreamScript.swift     device-side script builder + job-id containment
  new  Worker/WorkerStreamRunner.swift     session orchestration, durability, recovery
  mod  Transport/Transport.swift           shellStreaming added; StreamReadState added
  mod  Transport/ADBTransport.swift        shellStreaming implemented (incremental, bounded)
  new  PixelDesktopTests/WorkerStreamingTests.swift            41 unit tests
  new  PixelDesktopTests/Phase7StreamingDeviceHarness.swift    6 live-device tests
  mod  PixelDesktopTests/PixelDesktopTests.swift               MockTransport extended
  ** No Android source changed. APK, manifest and worker Java untouched. **

**EVENT PROTOCOL (line-oriented, not an RPC framework)**
  PDE1 START job_id= / JOB_WRITTEN bytes= / LAUNCHED / HEARTBEAT n= pid= / WORKER_EXITED n=
  PDE1 RESULT_BEGIN / <opaque JSON> / RESULT_END bytes= / ERROR code= message=

**THE EVENTS COME FROM THE SCRIPT, NOT THE WORKER.** The Android worker emits NOTHING to stdout - it
logs to logcat only (verified: grep for System.out/System.err across its Java returns no matches),
and it is launched by am start, so its stdout belongs to the app runtime. This is E1's L6 and it
bounds the protocol's claims: **HEARTBEAT is process liveness, NEVER model-generation progress.**
Real progress needs a worker-side change - a separate decision, NOT made here.

**F4 FIXED - worker death is now an explicit transition.** A run of consecutive liveness misses with
no result present moves to .streamAliveWorkerExited and sets a terminal outcome; the script makes the
same determination independently and exits. A single miss is NOT death (the process can be mid-exit
after writing its result); misses before launch and after a result do not count.
  VERIFIED ON HARDWARE: killing the worker gave workerExitedUnexpectedly(sequence: 4) and the run
  TERMINATED IN 3.3 s instead of heartbeating indefinitely.

**F7 FIXED - stream loss is not job failure.** When the session ends with no terminal event the
runner asks the DEVICE: is the worker running (pidof)? does a durable result exist (stat + cat)? If
so it recovers it as .recoveredFromDevice. **The worker is never killed because its session died.**
  VERIFIED ON HARDWARE: with no session watching, the worker ran to completion and wrote a
  2389-byte durable result that was recovered afterwards.

**LONG-RUNNING JOBS: no fixed heartbeat count, no job timeout.** E1 F5 showed a job may exceed 90 s.
The only time bounds are stall detectors, never duration limits: streamStallTimeout 120 s (a live
worker heartbeats every 0.5 s) and a 5 s reap deadline so a stuck adb child cannot block the caller.

**JOB INPUT: adb push REMOVED from the streaming path.** The payload rides stdin via cat > job.json.
The job id is the only value interpolated into a device command and is validated against [A-Za-z0-9-]
with a 64-char cap.

**RESULT: result.json remains the durable source of truth.** Durability is CONFIRMED against the
device, never assumed - .completed requires a positive device-reported size that is at least what
the stream carried; missing/empty/shorter yields .completedButDurabilityUnverified. The brief's rule
("stream completion does not mean result durability") is enforced by the type system.

**CANCELLATION: unchanged - am force-stop, external to the session.** Measured 140-144 ms on
hardware. A unit test asserts the streaming path never issues one.

**TESTS: 310 total, 0 failures.** 41 new unit tests covering the brief's list 1-19, plus 6
live-device tests (skipped unless PIXELDESKTOP_DEVICE_SERIAL is set). Unit and live tests are
deliberately separate so a passing unit suite is never mistaken for device verification.
  LIVE: 6/6 PASS - raw primitive (stdout/stderr/stdin), streamed DTCA-1 job, F4 death detection,
  F7 session loss, cancellation, performance.

**PERFORMANCE (same E1 workload: LOCAL-LLM-1, 32 tokens - DTCA-1 deliberately NOT used)**
  OLD: first output 0.060 s, launch ack 0.170 s, wall 27.600 s, 758 ms poll cycle, 26 heartbeats
  NEW: first output 0.036 s, launch ack 0.196 s, wall 20.985 s, completion via the stream, 37 heartbeats
  ** The 6.6 s wall difference is NOT attributed to the change ** - this workload's variance is large
  (Phase 6 measured a 2.4x spread; worker-reported total_ms varied ~12x). What IS attributable:
  completion detection moved from a 758 ms poll cycle to the stream, and progress is now observable
  at all. ** The win is architectural, not a throughput claim. **

**FOUR DEFECTS FOUND BY LIVE EXECUTION - none by the unit suite**
  1. ** do; SHELL SYNTAX ERROR ** The script was assembled with joined(separator: "; "), emitting
     `while ...; do; i=0`. `do;` is a syntax error, so the ENTIRE script failed to parse and the
     stream produced NO OUTPUT AT ALL. Confirmed on the device: "/system/bin/sh: syntax error:
     unexpected ';'". Fixed; a unit test now asserts the assembled script's structure.
  2. The stall watchdog resumed the continuation only when the child was alive; a child that had
     already exited while the reader was blocked left the continuation NEVER resumed.
  3. process.waitUntilExit() blocked forever - with the transport dead the adb child stayed alive
     and the run sat for 15 minutes. Replaced with a bounded reap.
  4. Unbounded waits in the device harness: each probe cost 30 s on a dead transport, so 240
     iterations became a 2-hour wait. Replaced with wall-clock deadlines.
  ** Defect 1 is the notable one: a pure string-assembly error that only appeared on hardware. **

**ENVIRONMENTAL NOTE:** the USB link dropped THREE times during this work (FAIL-006 recurring), and
the wireless entry once. Verification was completed over both transports. This is a known
environmental fault, not a PixelDesktop defect.

**LIMITATIONS (7), L3 most consequential**
  L1 a session that dies loses the STREAM (progress is not durable; only the file is)
  L2 cancellation remains external
  L3 ** progress is LIVENESS ONLY - real generation progress needs a worker-side change **
  L4 one session = one job
  L5 the session is host-initiated
  L6 the old polling path still exists for Phase 5/6 flows; the two coexist
  L7 the stall detector assumes a 0.5 s heartbeat cadence

**ARCHITECTURAL DISTINCTION RECORDED**
  ADB remains the transport and privileged control boundary.
  Persistent adb shell provides the live execution stream.
  result.json remains the durable job record.
  Worker liveness, connection state, and result state are independent.
And from E1, now implemented: ADB itself was capable of the required streaming behaviour, eliminating
the need for a second communication architecture. No WebSocket, gRPC, Service, custom USB transport,
adb forward RPC, TransportManager, scheduler or custom mDNS was added.

**Artifacts:** `phases/phase-07-e1-streaming-implementation.md`.

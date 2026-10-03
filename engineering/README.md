# PixelDesktop Engineering Documentation

This directory contains all engineering documentation for the PixelDesktop project.

## Structure

- **architecture/** — Architecture documentation and diagrams
- **decisions/** — Architecture Decision Records (ADRs)
- **phases/** — Phase engineering logs
- **logs/** — Engineering journal (chronological)
- **ai-development/** — AI development log and agent performance
- **failures/** — Failure records and diagnoses
- **testing/** — Test documentation and results
- **research/** — Research notes
- **best-practices/** — Engineering playbook
- **created-resources.json** — Machine-readable manifest of agent-created resources

## Project Status

**Phase 0 — Clean-Start Audit:** COMPLETE
**Phase 1 — Engineering Foundation:** COMPLETE
**Phase 2 — Device Discovery and ADB Transport:** COMPLETE
**Phase 3 — Android Device Model:** COMPLETE
**Phase 4 — Android Application / Process Control:** COMPLETE
**Phase 5 — Pixel Compute Worker:** transfer contract COMPLETE; worker APK (D8) IMPLEMENTED and verified on device
**Phase 6 — Local AI Worker:** FIRST INFERENCE PROOF COMPLETE — real LLM inference on the Pixel 7a
**Phase 7 — Pixel Capability Contract & Hermes Workload Planning:** **Steps 1–3 COMPLETE** (capability contract + measured evidence + refusal path). Step 3 resolved S3-1..S3-4: typed worker refusal, typed `.timeout`, `.cancelled` reserved (not faked), `.deviceUnauthorized` surfaced. 349 tests, 0 failures. Real-device verification NOT performed — no device attached (recorded)
**Phase 7 Amendment 2 — Workload-owned input limits:** **IMPLEMENTED** (discovered by Phase 9 Step 3A). Each workload now publishes its own input bound (`Workload.maximumInputCharacters`), derived from the validator that enforces it. `contractVersion` 1 → 2. `RequestLimits.maximumPromptCharacters` unchanged in meaning — it is the LLM's limit, not a workload-wide bound. 390 tests, 0 failures.
**Phase 9 — Hermes Integration:** **Steps 1–4 COMPLETE.** Step 4 adds the first Hermes-callable execution boundary: `pixel-desktop run --workload DTCA-1 --input-file <path>`, a thin layer over the existing E1 streaming path. DTCA-1 only; LOCAL-LLM-1 deferred. 416 tests, 0 failures. Real-device verification NOT RUN — no device attached (recorded) — read-only publication interface. A third target (`pixel-desktop`) publishes the existing capability contract and evidence as JSON. `capability` needs no device and performs no device I/O; `observe` reads device state read-only. No execution, no listener, no daemon. 372 tests, 0 failures. Real-device verification NOT RUN — no device attached (recorded)

> Phase numbering follows the master engineering prompt §16 — see
> [ADR-007](decisions/ADR-007-authoritative-phase-sequence.md) and its **Amendment 1**
> (which redefines Phase 7). Legacy documents use
> three different, incompatible phase numbering schemes; their numbers are **not**
> PixelDesktop product phase numbers.

## Key Documents

### Phase logs
- [Phase 0 Clean-Start Audit](phases/phase-00-clean-start-audit.md) — Audit of the previous implementation
- [Phase 1 Engineering Foundation](phases/phase-01-engineering-foundation.md) — Clean project, build and tests
- [Phase 2 Device Discovery and ADB Transport](phases/phase-02-device-discovery.md) — `getprop` transport, device enrichment, real-device verification
- [Phase 3 Android Device Model](phases/phase-03-android-device-model.md) — corrected identity model, capabilities, batched getprop
- [Phase 3 Proposal (approved)](phases/phase-03-android-device-model-proposal.md) — the approved proposal
- [Phase 3 Test Report](testing/phase-03-test-report.md) — build, test and real-device evidence
- [Phase 4 Android Application / Process Control](phases/phase-04-application-process-control.md) — shell containment, app operations, lifecycle
- [Phase 4 Proposal (approved)](phases/phase-04-application-process-control-proposal.md) — the approved proposal
- [Phase 4 Test Report](testing/phase-04-test-report.md) — build, test and real-device evidence
- [Phase 5 Transfer Contract](phases/phase-05-transfer-contract.md) — fixed-path contract, containment, real-device proof
- [Phase 5 Proposal (approved)](phases/phase-05-transfer-contract-proposal.md) — the approved proposal
- [Phase 5 Test Report](testing/phase-05-test-report.md) — build, test and real-device evidence
- [Phase 5 D8 Reconnaissance — Minimum Compute Worker](phases/phase-05-d8-worker-reconnaissance.md) — reconnaissance and proposal
- [Phase 5 D8 Decision Review — D-1..D-10](phases/phase-05-d8-decision-review.md) — decisions with evidence; locked/idle experiment resolved
- [Phase 5 D8 Implementation — Compute Worker](phases/phase-05-d8-worker-implementation.md) — worker APK, compute proof, real-device evidence
- [Phase 6 Reconnaissance — Local AI Worker](phases/phase-06-local-ai-reconnaissance.md) — reconnaissance + proposal
- [Phase 6 Implementation — Local AI Worker](phases/phase-06-local-ai-implementation.md) — **first inference proof complete**, measured results, evidence chain
- [Phase 7 Reconnaissance — Resource-Aware Routing](phases/phase-07-routing-reconnaissance.md) — reconnaissance; **its router proposal was withdrawn**
- [Phase 7 Architecture Re-Evaluation](phases/phase-07-architecture-reevaluation.md) — Hermes owns planning; PixelDesktop publishes a capability contract
- [Phase 7 Step 1 — The Pixel Capability Contract](phases/phase-07-step-1-capability-contract.md) — **implemented**: contract, provenance model, real-device verification
- [Phase 7 Step 2 — Measured Evidence](phases/phase-07-step-2-evidence.md) — **implemented**: device state, execution evidence, freshness, snapshot-not-reservation
- [Phase 7 Step 3 — The Refusal Path](phases/phase-07-step-3-refusal-path.md) — **implemented**: 8 tests; found 3 unreachable error cases + 1 erased structure; open decisions S3-1..S3-4 resolved
- [Phase 9 Step 4 — The DTCA-1 Execution Boundary](phases/phase-09-step-4-execution-boundary.md) — **implemented**: `run` command, E1 reused unchanged, 26 new tests
- [Phase 9 Step 3A — Contract Fidelity + Phase 7 Amendment 2](phases/phase-09-step-3a-contract-fidelity.md) — **implemented**: per-workload input bounds, contractVersion 2
- [Phase 9 Step 1 — The Read-Only Publication Interface](phases/phase-09-step-1-publication-interface.md) — **implemented**: `pixel-desktop` CLI, two commands, 23 tests, absent-never-zero presentation rule

### Architecture
- [Architecture Overview (as delivered)](architecture/overview.md) — what the code actually implements

### Architecture decisions
- [ADR-001: Project Structure](decisions/ADR-001-project-structure.md)
- [ADR-002: ADB Transport](decisions/ADR-002-adb-transport.md)
- [ADR-003: DTCA-1 Worker APK](decisions/ADR-003-dtca1-worker-apk.md)
- [ADR-004: Verification by Re-computation](decisions/ADR-004-verification.md)
- [ADR-005: Device Property Enrichment Is Separate From Discovery](decisions/ADR-005-device-property-enrichment.md)
- [ADR-006: Test Isolation Strategy for Device-Dependent Code](decisions/ADR-006-test-isolation.md)
- [ADR-007: Authoritative Phase Sequence](decisions/ADR-007-authoritative-phase-sequence.md) — **includes Amendment 1**: Phase 7 redefined (Hermes decides, PixelDesktop enforces)
- [ADR-008: Android Device Representation Model](decisions/ADR-008-android-device-model.md)
- [ADR-009: Application Operations, Shell Containment, and Lifecycle Invalidation](decisions/ADR-009-application-operations-and-shell-containment.md)
- [ADR-010: Worker Transfer Contract and Path Containment](decisions/ADR-010-worker-transfer-contract.md) — **revised 2026-10-02**: transfer root corrected for the identity boundary
- [ADR-011: Pixel Compute Worker Contract](decisions/ADR-011-pixel-compute-worker-contract.md)
- [ADR-012: Local AI Worker (approved and implemented)](decisions/ADR-012-local-ai-worker.md)
- [ADR-013: Resource-Aware Routing (**SUPERSEDED**, not implemented)](decisions/ADR-013-resource-aware-routing.md) — measurements retained, router withdrawn
- [ADR-014: A Read-Only Local CLI as the Publication Interface](decisions/ADR-014-read-only-publication-interface.md) — **implemented**: how Hermes reaches PixelDesktop (six alternatives assessed and rejected)

### Records
- [Engineering Journal](logs/engineering-journal.md) — Chronological build history
- [AI Development Log](ai-development/ai-development-log.md) — How the AI participated in the build
- [Technique Memory](best-practices/techniques.md) — Reusable techniques with evidence
- [Phase 2 Test Report](testing/phase-02-test-report.md) — Build, test and real-device evidence

### Failures
- [FAIL-001: Non-English Output](failures/FAIL-001-non-english-output.md)
- [FAIL-002: Runaway Field Duplication in Transport.swift](failures/FAIL-002-transport-swift-runaway-fields.md)
- [FAIL-003: Worker Workspace Created World-Readable](failures/FAIL-003-workspace-world-readable.md)
- [FAIL-004: Three Android Assumptions Falsified by Real-Device Execution](failures/FAIL-004-android-assumptions-falsified.md)
- [FAIL-005: A Prompt Longer Than n_batch Aborts the Worker](failures/FAIL-005-prompt-exceeding-nbatch-aborts-worker.md)
- [FAIL-006: USB Connection Drops (Mac ↔ Pixel 7a)](failures/FAIL-006-usb-connection-drops.md) — investigation: macOS USB port teardown, not PixelDesktop
- [USB-Aware Transport Design](design/usb-aware-transport-design.md) — **design only**: IOKit presence events, `wiredDegraded` state, not yet implementable
- [Wireless ADB Persistence Design](design/wireless-adb-persistence-design.md) — **design only**: the manual-intervention boundary is *re-enabling wireless debugging*, not reconnecting
- [Wireless Serial Transport Verification](testing/wireless-serial-transport-verification.md) — **verified on device**: `-s` works over TLS, but the wireless serial is NOT the USB serial
- [Communication Architecture Reconnaissance](design/communication-architecture-reconnaissance.md) — **recon only**: no alternative channel is justified; ADB already streams and already holds sessions
- [E1 — Persistent ADB Shell Streaming Experiment](phases/phase-07-e1-adb-streaming-experiment.md) — **verified on device**: one session drives a whole job; streaming is ADDITIVE, not a replacement for the durable result file
- [E1 — Streaming Implementation](phases/phase-07-e1-streaming-implementation.md) — **implemented and verified on device**: persistent `adb shell` execution path with event protocol, F4 death detection, F7 recovery

## Device

**Pixel 7a** — serial `3C261JEHN25632`, codename `lynx`, manufacturer `Google`
Verified: Android `16`, API level `36`, ABI `arm64-v8a`, supported ABIs `["arm64-v8a"]`

## External References

- Legacy documentation: `/Users/rhenzrobertbumanglag/Documents/PixelDesktop/*.md`
- DTCA-1 workload spec: `phase-0-first-workload-specification.md` (legacy)
- Architecture re-evaluation: `architecture-re-evaluation-report.md` (legacy)

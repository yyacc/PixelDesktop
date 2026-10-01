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
**Phase 4 — Android Application / Process Control:** PROPOSAL (awaiting review)

> Phase numbering follows the master engineering prompt §16 — see
> [ADR-007](decisions/ADR-007-authoritative-phase-sequence.md). Legacy documents use
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
- [Phase 4 Proposal — Android Application / Process Control](phases/phase-04-application-process-control-proposal.md) — proposal only, awaiting review

### Architecture
- [Architecture Overview (as delivered)](architecture/overview.md) — what the code actually implements

### Architecture decisions
- [ADR-001: Project Structure](decisions/ADR-001-project-structure.md)
- [ADR-002: ADB Transport](decisions/ADR-002-adb-transport.md)
- [ADR-003: DTCA-1 Worker APK](decisions/ADR-003-dtca1-worker-apk.md)
- [ADR-004: Verification by Re-computation](decisions/ADR-004-verification.md)
- [ADR-005: Device Property Enrichment Is Separate From Discovery](decisions/ADR-005-device-property-enrichment.md)
- [ADR-006: Test Isolation Strategy for Device-Dependent Code](decisions/ADR-006-test-isolation.md)
- [ADR-007: Authoritative Phase Sequence](decisions/ADR-007-authoritative-phase-sequence.md)
- [ADR-008: Android Device Representation Model](decisions/ADR-008-android-device-model.md)

### Records
- [Engineering Journal](logs/engineering-journal.md) — Chronological build history
- [AI Development Log](ai-development/ai-development-log.md) — How the AI participated in the build
- [Technique Memory](best-practices/techniques.md) — Reusable techniques with evidence
- [Phase 2 Test Report](testing/phase-02-test-report.md) — Build, test and real-device evidence

### Failures
- [FAIL-001: Non-English Output](failures/FAIL-001-non-english-output.md)
- [FAIL-002: Runaway Field Duplication in Transport.swift](failures/FAIL-002-transport-swift-runaway-fields.md)

## Device

**Pixel 7a** — serial `3C261JEHN25632`, codename `lynx`, manufacturer `Google`
Verified: Android `16`, API level `36`, ABI `arm64-v8a`, supported ABIs `["arm64-v8a"]`

## External References

- Legacy documentation: `/Users/rhenzrobertbumanglag/Documents/PixelDesktop/*.md`
- DTCA-1 workload spec: `phase-0-first-workload-specification.md` (legacy)
- Architecture re-evaluation: `architecture-re-evaluation-report.md` (legacy)

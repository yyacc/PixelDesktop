# PixelDesktop Repository Assessment & MVP Plan

## Date: 2026-10-09
## Head: 6fb99a9 (Phase 10 Step 6 completion)

---

## 1. Current State

### Git Status
- **Branch:** main
- **HEAD:** 6fb99a9 (docs: engineering journal — Phase 10 Step 6 completion)
- **Working tree:** NOT clean — 2 pre-existing uncommitted changes preserved:
  - M PixelDesktop.xcodeproj/project.pbxproj (+4 lines)
  - M engineering/created-resources.json (+68 lines)
- **Untracked:** engineering/pilot-9sel-evidence/ (from previous pilot)

### Test Baseline
- **506 tests passed, 22 skipped, 0 failures**
- Verified by full suite run on 2026-10-09
- 22 skipped = device-gated tests (require physical Pixel 7a)

### Project Structure
- **PixelDesktop/** — macOS SwiftUI app (device management, inference, worker)
- **PixelDesktopCLI/** — CLI tool (capability, observe, run commands)
- **PixelDesktopTests/** — 16 test files, 506 tests
- **engineering/** — 15 ADRs, 40+ phase docs, architecture, decisions
- **DTCA1Worker/** — Android worker APK (Kotlin)
- **third_party/llama.cpp** — vendored (not committed)

### What Works (verified)
1. Device discovery and enrichment (ADB transport)
2. Application operations (launch, stop, query)
3. Worker transfer contract (fixed paths)
4. DTCA-1 workload (local reference + on-device)
5. LOCAL-LLM-1 workload (real LLM inference on Pixel 7a)
6. Capability contract (v3, published via CLI)
7. Observation interface (read-only, structured)
8. Execution boundary (run command, E1 streaming evidence)
9. Result verification (exact re-computation for DTCA-1, evidence chain for LLM)
10. Production hardening (cancellation, pipe drain, resource exhaustion)

### What's Missing for MVP
1. **No wireless ADB transport** — USB only (design decision, not a gap)
2. **No independent async workload status/polling** — intentional (E1 provides monitoring)
3. **No scheduler/router** — intentional (Hermes owns planning)
4. **No file-access service** — not started
5. **No RAG** — not started
6. **No Zeno client** — not started
7. **No storage analyzer** — not started

### Architecture Preserved
- Transport seam (Protocol-oriented)
- Evidence/provenance model
- Containment boundaries
- CLI boundary (read-only publication + execution)
- Workload-owned success tokens

---

## 2. MVP Definition

The **smallest useful MVP** is already delivered:

**PixelDesktop MVP = Device Management + CLI Boundary + Workload Execution**

A user can:
1. Discover and enrich Android devices via ADB
2. Query capabilities (`pixel-desktop capability --json`)
3. Observe device state (`pixel-desktop observe --json`)
4. Execute workloads (`pixel-desktop run --workload DTCA-1|LOCAL-LLM-1`)
5. Receive structured results with evidence

This is a **functional MVP** — not a production release, but a working system that demonstrates the core value proposition: using a physical Android phone as a compute node.

---

## 3. Prioritized Implementation Plan

### Priority 1: Close Test Coverage Gaps (for Zeno trial)
- **Task:** Add unit tests for CLIEnvelopeRenderer (currently 0 tests)
- **Why:** This is a pure transformation function with no test coverage — ideal for a Zeno trial
- **Scope:** Single file, pure logic, no device I/O

### Priority 2: Zeno Integration
- **Task:** Configure OpenCode with a working model, run a trial task
- **Why:** User explicitly requested Zeno trial before broader delegation
- **Blocker:** OpenCode server model `exo-free` is deprecated

### Priority 3: Production UI
- **Task:** SwiftUI views for device list, capability display, workload submission
- **Why:** Current UI is minimal (device list + identity only)
- **Scope:** New SwiftUI views, no backend changes

### Priority 4: Observability Dashboard
- **Task:** Read-only panel showing agent activity (Zeno + Pixel)
- **Why:** User wants dashboard visibility into all agent activity
- **Scope:** New SwiftUI views + data adapters

---

## 4. Zeno Trial Assignment

### Selected Task: CLIEnvelopeRenderer Unit Tests

**Why this task:**
- Pure transformation function (JSON serialization)
- Zero test coverage currently
- No device I/O required
- Clear acceptance criteria
- Independently verifiable

**Permitted file scope:**
- Create: PixelDesktopTests/Phase9EnvelopeRendererTests.swift
- Read: PixelDesktopCLI/CLIEnvelopeRenderer.swift, PixelDesktopCLI/CLIEnvelope.swift, PixelDesktopCLI/CLIJSONPresentation.swift

**Expected deliverables:**
- One new test file with 5-8 test cases
- Tests must compile and pass
- Tests must cover: successful rendering, error cases, key ordering, date formatting

**Acceptance criteria:**
- All new tests pass
- Full suite still passes (506 + N tests, 0 failures)
- No production code modified
- No files outside permitted scope modified

---

## 5. Zeno Communication Status

### Blocker
- OpenCode server running on 127.0.0.1:49374
- Configured model `exo-free` returns 410 (deprecated)
- No alternative models configured
- OpenCode config is minimal (only $schema line)

### Next Steps
1. Configure OpenCode with a working model (e.g., anthropic/claude-3-haiku or openai/gpt-4o-mini)
2. Verify communication with a simple test message
3. If successful, proceed with Zeno trial
4. If not, report blocker and propose alternatives

---

## 6. Engineering Rules Compliance

- [x] Evidence-first workflow
- [x] Small, reversible changes
- [x] Existing conventions
- [x] No unrelated changes
- [x] No destructive operations
- [x] USB preferred
- [x] No claims without demonstration
- [x] Stop if scope expands
- [x] Preserve evidence
- [x] MVP focus

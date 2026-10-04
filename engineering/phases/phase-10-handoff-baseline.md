# Phase 10 — Production Hardening: Handoff Baseline

## Phase 10 authoritative definition

**Name:** Production Hardening
**Source:** Master engineering prompt §16
**Status:** Not started

### Objective (from master prompt)

Perform a complete engineering review. Test:
- fresh installation
- clean build
- device disconnect
- device reconnect
- failures
- timeouts
- cancellation
- invalid input
- unexpected device state
- worker failure
- application failure
- model failure
- resource exhaustion
- restart behavior
- persistence
- recovery
- regression

Perform:
- code review
- architecture review
- security review
- dependency review
- documentation review
- test coverage review
- performance review
- AI-development review

### Prerequisites

- Phase 9 complete (Hermes Integration)
- All prior phases complete

### Dependencies on Phase 9

Phase 10 depends on Phase 9's CLI boundary (`capability`, `observe`, `run`) and the E1 streaming path. The hardening review will exercise these interfaces under failure conditions.

---

## Repository baseline

- **HEAD commit:** `da720a6aa341884f5e6b11f701f0200be641a0c8`
- **Working tree:** Clean
- **Phase 9 completion commit:** `da720a6` (Step 7 — LOCAL-LLM-1 execution)
- **Test result:** 468 passed, 20 skipped, 0 failures

### Recent commits

```
da720a6 feat: Phase 9 Step 7 — LOCAL-LLM-1 execution through the CLI boundary
3afc441 feat: Phase 9 Step 6 — route InferenceResult through CLI boundary
8272228 feat: Phase 7 Amendment 3 — workload-owned success tokens + Phase 9 CLI/worker boundary
ee62696 Phase 9 Step 4: real-device verification of the DTCA-1 execution boundary
ac73787 Phase 9 Step 4: DTCA-1 execution boundary (pixel-desktop run)
c6d1cd4 Phase 7 Amendment 2: workload-owned input limits
ca766b4 Phase 9 Step 1: read-only publication interface (pixel-desktop CLI)
```

---

## PixelDesktop baseline

### CLI commands

| Command | Description | Device I/O |
|---|---|---|
| `capability --json` | Publish static capability contract | None |
| `observe --json` | Publish point-in-time device observation | Read-only |
| `run --workload <name> --input-file <path> --json` | Execute one bounded workload | Yes |

### Supported workloads

| Workload | Success token | Exactly verifiable | Requires model | Max input |
|---|---|---|---|---|
| `DTCA-1` | `COMPLETED` | Yes | No | 10,000 chars |
| `LOCAL-LLM-1` | `OK` | No | Yes | 4,096 chars |

### Capability contract

- **Version:** 3
- **Runtime:** llama.cpp `a868c3e`, CPU backend
- **Model:** `qwen2.5-1.5b-instruct-q4_k_m.gguf` (1,117,320,736 bytes)
- **Limits:** max prompt 4,096 chars, max tokens 256, max model bytes 2,147,483,648

### Observe contract

Returns: device serial, reachability, available memory, free storage, worker installed/running, model presence, thermal status. All values carry `source`, `observedAt`, and `limitation`.

### Execution boundary

- Input validation before device I/O (per-workload validators)
- Workload-owned success tokens
- E1 streaming path for execution evidence
- Durable result file as source of truth
- Job ID ownership check (anti-staleness)

### Result types

- `DTCA1Result` — published via `CLIRunResult.output`
- `InferenceResult` — published via `CLIRunResult.inferenceOutput`
- `PixelDesktopError` — typed errors with categories

### E1 streaming behavior

- Persistent `adb shell` session
- Heartbeat events (liveness only, no progress)
- Launch acknowledgement
- Terminal outcome events
- F4 death detection, F7 recovery
- Durability confirmation (stream completion ≠ durability)

---

## Pixel worker baseline

### Device

- **Model:** Pixel 7a
- **Serial:** `3C261JEHN25632`
- **Codename:** `lynx`
- **Manufacturer:** Google
- **Android:** 16 (API 36)
- **ABI:** `arm64-v8a`

### Worker

- **Package:** `com.pixeldesktop.worker`
- **Version code:** 2
- **Transfer contract:** Fixed paths, containment, ownership checks

### Installed model

- **File:** `qwen2.5-1.5b-instruct-q4_k_m.gguf`
- **Size:** 1,117,320,736 bytes
- **SHA-256:** `6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e`
- **Location:** `/sdcard/Android/data/com.pixeldesktop.worker/files/model/`

### Inference constraints

- **Runtime:** llama.cpp `a868c3e`, CPU backend
- **Max tokens:** 256
- **Temperature:** 0.0 (greedy only)
- **Context size:** 2,048 tokens allocated, 32,768 trained
- **No network, no conversation, no tools, no RAG**

---

## Hermes baseline

### pixel-compute skill

- **Location:** `~/.hermes/skills/pixel-compute/SKILL.md`
- **Purpose:** Consume PixelDesktop's published capability and evidence at decision time

### What Hermes can do

- Query capabilities (`capability --json`)
- Inspect device state (`observe --json`)
- Submit DTCA-1 workloads (`run --workload DTCA-1`)
- Submit LOCAL-LLM-1 workloads (`run --workload LOCAL-LLM-1`)
- Receive structured results with provenance
- Interpret refusals and plan accordingly

### What Hermes is forbidden from doing

- Bypassing PixelDesktop's enforcement boundary
- Building retry or routing policies into skill usage
- Treating `.declared` values as device facts
- Reading `not_read` fields as gaps to fill
- Retrying deterministic refusals
- Treating a live worker process as a loaded model

### Authority boundary

- **Hermes** owns planning and decision-making
- **PixelDesktop** owns enforcement and execution
- **Pixel 7a** is a constrained worker

---

## Known intentional limitations

These are **not defects**. They are documented design decisions:

1. **No independent async workload status/polling.** `run` is synchronous. Execution-time monitoring is provided through E1 evidence. This is intentional — the `pixel-compute` skill warns against building routing/retry policies.

2. **No scheduler.** No resource-aware workload routing. ADR-013 was superseded by ADR-007 Amendment 1 — routing is owned by Hermes, not PixelDesktop.

3. **No model provisioning in Phase 9.** Model provisioning is a separate explicit operation. The model was provisioned in Phase 6 and is verified present.

4. **LOCAL-LLM-1 is bounded and constrained.** Max 256 tokens, greedy decoding, fixed model file, no network. This is by design (ADR-012).

5. **`exactlyVerifiable` is workload-dependent.** DTCA-1 is exactly verifiable (independent Mac re-computation). LOCAL-LLM-1 is not (generative output). This is recorded in the contract.

6. **No UI for workloads/worker state.** Phase 8 (PixelDesktop UX) is not implemented. The CLI is the interface.

7. **No APK modification or code injection.** The worker is a black-box executor. No third-party APK modification, no security bypasses.

8. **No destructive Android operations.** No `rm -rf`, no `git clean`, no force-stop of unrelated apps.

---

## Phase 10 readiness

**Status: READY WITH DOCUMENTED LIMITATIONS**

### Evidence of readiness

- All phases 0–9 complete
- 468 tests passing, 0 failures
- Real-device verification passed for both workloads
- Clean working tree at a known commit
- Architecture is documented and internally consistent
- Known limitations are documented as intentional design decisions

### What Phase 10 will inherit

- A working CLI boundary with three commands
- Two supported workloads (DTCA-1, LOCAL-LLM-1)
- A proven E1 streaming path with durability guarantees
- A capability contract with provenance and limitation semantics
- A Hermes skill that documents the authority boundary
- A worker APK with fixed-path containment and ownership checks
- A local AI worker with bounded, constrained inference

### What Phase 10 must review

- Fresh installation (clean build from scratch)
- Device disconnect/reconnect handling
- Failure modes (worker failure, model failure, transport loss)
- Timeout and cancellation behavior
- Invalid input handling
- Unexpected device states
- Resource exhaustion
- Restart behavior and persistence
- Security review (shell containment, path containment)
- Dependency review
- Documentation accuracy
- Test coverage gaps
- Performance characteristics
- AI development process review

---

## No Phase 10 task created

This document establishes the baseline only. No Phase 10 task is created or authorized. Phase 10 will begin when an authoritative specification is provided.

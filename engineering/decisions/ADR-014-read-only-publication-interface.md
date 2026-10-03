# ADR-014: A Read-Only Local CLI as the Publication Interface

## Status

Accepted

## Date

2026-10-03

## Context

Phase 7 published a capability contract (`PixelCapabilityContract`), a measured-evidence layer
(`PixelEvidenceReader`, `PixelStateObservation`, `PixelExecutionEvidence`,
`PerformanceObservation`), and a hardened refusal path. All of them are Swift types **inside the
PixelDesktop application target**.

`phase-07-step-2-evidence.md` §U1 recorded the consequence: *"nothing exposes them over a
transport, so Hermes cannot read either yet — Expected — publication precedes delivery. A later
step."*

`engineering/design/communication-architecture-reconnaissance.md` had already settled the adjacent
question — the **Mac→Pixel** channel — and concluded: keep ADB, add no second channel, and noted in
its §15 that *"Hermes consumes the capability contract, not the transport."* That reconnaissance
covers how PixelDesktop reaches the **device**. It does not cover how Hermes reaches
**PixelDesktop**.

This ADR decides that second question.

## Problem

What is the smallest interface by which Hermes can obtain PixelDesktop's authoritative capability
and evidence at decision time, without making Hermes the authority over Pixel capabilities and
without adding infrastructure the project has repeatedly refused?

## Evidence

**[E] The constraint is structural, not a missing file.** `PixelCapabilityContract` and
`PixelEvidence` are compiled into the application target. The project has exactly two targets
(application, test bundle). The only entry point is `@main` SwiftUI
(`PixelDesktop/App/PixelDesktopApp.swift`). No CLI target, no `ArgumentParser`, no MCP server, no
IPC socket, no HTTP server, no file publication.

**[E] `PixelCapabilityContract.build` is a pure static factory.** It reads `AndroidDevice`,
`LlamaCppInferenceRuntime().identity`, `ModelContract`, `InferenceRequest`, and `DTCA1Job`. **No
device I/O.** A capability report is therefore obtainable with no Pixel attached.

**[E] `PixelEvidenceReader` does require a transport.** `observeState` issues one combined read-only
shell round trip (`/proc/meminfo`, `df`, `stat`) plus `dumpsys package`, `pidof`, and
`dumpsys thermalservice`. All read-only; all already authorised.

**[E] The device cannot be the conduit.** The contract describes the **Pixel**, but it is produced
**on the Mac**. Routing Mac→Mac data through the device would add a hop and couple a host-local read
to device availability.

**[E] Prior rejections are on record.** ADR-011: *"No HTTP, no TCP listener, no socket, no RPC, no
port forwarding, no `adb reverse`, no network."* ADR-012 lists *"HTTP / socket / RPC"* as rejected
under master prompt §5.2. The communication reconnaissance refuses an unauthenticated
HTTP/WebSocket service *"under any variant."*

**[E] ADR-007 Amendment 1 §A1.11** — Phase 7 does not add Hermes-facing tooling, plugins, or MCP
surfaces; Phase 9 does not redefine the contract's contents.

## Options considered

| Option | Assessment |
|---|---|
| **A. Narrow local CLI** | **Chosen.** No listener, port, socket, or daemon. Reuses the existing types unchanged. Fails with an exit code. Independently testable. Matches how Hermes already invokes everything. |
| **B. Unix domain socket** | Rejected. No network surface and filesystem-permission trust are attractive, but it needs a listener inside the app and couples the read to the app being resident — a process that need not exist. |
| **C. MCP server** | Rejected for this step. Requires a long-running server process, and §A1.11 names MCP surfaces as out of Phase 7. Plausibly useful later if execution requests are added, since it is the one option that naturally carries both read and execute. |
| **D. Versioned local file publication** | Rejected as the mechanism. Contradicts Step 2's stated design: *"Observations are taken on request and are immutable values. Nothing here holds state between calls or runs in the background."* A written file has unknown age and a writer that must be running. |
| **E. ADB-mediated publication** | Rejected. Backwards — the contract is produced on the Mac. Adds a device round trip to a host-local read. |
| **F. localhost HTTP/API** | Rejected. A listener, a port, an auth story, a lifecycle. Prior ADRs already refuse it; no phase requires it. |

## Decision

**Build a narrow, read-only local CLI — a third target in the PixelDesktop project.**

```
Hermes
  │  terminal("pixel-desktop capability --json")   static; no device
  │  terminal("pixel-desktop observe --json")      dynamic; device reads only
  ▼
pixel-desktop CLI (same shared sources, headless)
  │
  ▼
PixelCapabilityContract.build(...)  /  PixelEvidenceReader(transport:).observeState(...)
```

The CLI target compiles the **same `PixelDesktop/` sources** as the application, excluding only the
SwiftUI entry point, `Info.plist`, and the asset catalog. There is one implementation and two
consumers of it: the app executes, the CLI publishes.

## Reasoning

1. **It adds no infrastructure.** No daemon, listener, port, socket, queue, scheduler, router, or
   retry loop. A process that runs, prints, and exits. This is the only option that adds a delivery
   path while adding no running component — which is what makes it consistent with every prior
   rejection in this repository.
2. **It preserves PixelDesktop as the authority.** The values are produced by PixelDesktop's own
   code. Hermes reads a conclusion; it does not re-derive one. The dependency direction is the one
   §A1.11 draws: publish outward, consume inward.
3. **It cannot become a second capability implementation, structurally.** The shared sources are
   compiled, not copied. A divergence would be a compile error, not a silent drift.
4. **It decouples two lifetimes.** `capability` needs no device; `observe` does. One interface
   serving both would force a device read for a static question.
5. **It is independently testable.** The CLI has no dependency on Hermes, and Hermes has no
   dependency on the CLI being installed. Neither requires the other to be online.
6. **It is verifiable without hardware.** `capability` is fully exercisable with no device, and the
   device-facing path fails in a structured, testable way when no device is present.

## Consequences

**Positive**
- Hermes can obtain capability and evidence at decision time.
- The `pixel-compute` skill's first instruction — *"invoke PixelDesktop's capability query"* —
  becomes executable rather than aspirational.
- The re-evaluation's Step 5 (end-to-end decomposed task) becomes reachable.
- The app target is unchanged; the CLI is additive.

**Negative / accepted costs**
- A second target to keep building. Mitigated by sharing sources rather than duplicating them.
- A second JSON shape to keep honest. Mitigated by serialising the shared Codable types as-is and
  adding no DTO.
- The envelope's interface version is a new compatibility surface that must be maintained.

**Neutral**
- The CLI is a **new** trust boundary only in the sense that a new executable exists. It is read-only,
  runs as the invoking user, and inherits the existing ADB key for the one command that touches a
  device. It opens no port and listens on nothing.

## Rejected alternatives — reasoning recorded

- **A single interface carrying both read and execute.** Deferred, not refused. The read path is
  independently verifiable today and needs no execution coupling; adding execution now would couple
  a working interface to an unproven one.
- **Publishing a merged capability+evidence payload.** Rejected: Phase 7 Steps 1–2 established these
  as separate channels with different lifetimes and different failure modes. Merging them in the
  envelope would undo that distinction at the exact boundary where it matters most.
- **Emitting `value: 0` for unknown fields, with `source: unknown` as the only marker.** Rejected.
  The source is correct but is not load-bearing for a consumer that reads `value` first. An unknown
  value is published without its `value` key at all, so the misreading is impossible rather than
  merely discouraged.
- **Passing a transport to `capability` and relying on discipline not to use it.** Rejected. The
  command takes no transport, so it has no device handle to misuse. A promise not to touch the
  device is only credible if the code cannot.

## Future reconsideration conditions

- **If execution requests are added** → revisit whether a CLI subcommand or an MCP server is the
  right carrier. The CLI remains valid; MCP becomes worth re-examining because it carries both.
- **If Hermes needs to call the interface frequently enough that process spawn cost matters** →
  measure it before changing the mechanism. No measurement currently justifies a resident process.
- **If the envelope's shape must change** → bump `interface_version`; do not silently reshape.
- **If a second consumer appears** → the envelope is the contract; a second consumer is evidence the
  interface is general, not a reason to fork it.

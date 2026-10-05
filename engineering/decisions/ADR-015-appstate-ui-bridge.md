# ADR-015 — AppState as the UI-to-backend bridge

- **Status:** Accepted
- **Date:** 2026-10-04
- **Phase:** 08

## Context

Phases 2–5 built the backend capabilities (device discovery, enrichment, application operations, observation) with full test coverage. Phase 8 needs to wire these to the macOS UI. The question was how views reach backend logic without duplicating it or creating hidden coupling.

## Problem

`ContentView` must call into discovery, enrichment, app listing, and app launching. Two design mistakes were already present in the pre-Phase-8 code and must not be repeated:

1. **Fire-and-forget enrichment** — the "Refresh" path discovered devices via a Combine binding but never awaited `enrichDevice`. Identity fields stayed empty on every launch.
2. **No testable postcondition** — `devices` updated only via Combine dispatch; in tests the dispatch races with the main runloop, producing flaky or impossible-to-assert assertions.

## Options considered

| Option | Trade-off |
|--------|-----------|
| Views call `DeviceManager` directly | Bypasses AppState; views would need to know about transport, enrichment, and error recovery. No guard-first layer. Not testable without a device. |
| Views call `AppState` async methods; `AppState` delegates to `DeviceManager` / `AppOperationsProtocol` / `PixelEvidenceReader` | Single indirection layer; all paths are guard-first and throwing/async is explicit. Mockable. |
| Views reach the transport directly | Security violation (shell containment). Already forbidden by ADR-009. |

## Evidence

The Phase 3 code explicitly documented the omission:

> The UI still does not call `enrichDevice` — `ContentView` will show 'Unknown' for enrichment fields until Phase 8 wires it.

The Phase 2 `refreshDevices` implementation used a detached `Task` and had no completion callback:

```swift
// Phase 2 (removed in Phase 8)
func refreshDevices() {
    Task { await deviceManager.refreshDevices() }
    Task { await enrichConnectedDevice() }
}
```

This made enrichment both uncalled (bug) and unawaitable (no testable boundary).

## Decision

**`AppState` is the bridge.** Views call `async` methods on `AppState`; `AppState` calls `DeviceManager` (discovery + enrichment), `PixelEvidenceReader` (observation), and `AppOperationsProtocol` (app listing + launching). No view reaches the transport or a raw shell.

`refreshDevices()` is `async` with a deterministic postcondition:

```swift
func refreshDevices() async {
    await deviceManager.refreshDevices()
    self.devices = await deviceManager.devices      // read 1: precondition for enrichment
    await enrichConnectedDevice()                    // guard-first on selectedSerial
    self.devices = await deviceManager.devices      // read 2: capture in-place enrichment
}
```

## Reasoning

- **Deterministic postcondition:** After `await refreshDevices()` returns, `devices` is current and enriched — in both the app and tests. No Combine runloop race.
- **Two-read pattern:** `DeviceManager.enrichDevice` mutates `deviceManager.devices[index]` in place but does not touch `AppState.devices`. A single read before enrichment means the enrichment step never sees `selectedSerial`; a single read after means it never runs (because `selectedSerial` is nil). Two explicit reads document the pre- and post-enrichment states.
- **Combine retained for the poll path:** `DeviceManager.startDiscovery` pushes `devices` on its 5 s cadence through the existing binding. Only the explicit `refreshDevices()` path bypasses it. This keeps the background discovery behavior unchanged while making the user-initiated refresh deterministic.
- **Guard-first throughout:** `enrichConnectedDevice`, `observeDevice`, and all app operations check `selectedSerial` / `connectedDeviceSerial()` before issuing any command.

## Consequences

- Views are simplified: they call one method and read one property; no `Task` wrapping, no Combine subscription management.
- Tests are deterministic: `await state.refreshDevices()` then read `state.devices` — no `XCTWaiter`, no runloop pump.
- The Combine binding code remains but is now only used for the discovery poll, not for explicit refresh. This is intentional and documented.
- Any future change to the enrichment mechanism (e.g. caching, multi-device) must update `refreshDevices()` and its tests; views are insulated.

## Rejected alternatives

- **Fire-and-forget `Task`** — re-introduces the bug (enrichment uncalled or unawaitable).
- **Combine-only binding for all updates** — no testable completion boundary; tests require runloop pumps.
- **View-level transport access** — violates shell containment (ADR-009).

## Future reconsideration conditions

Reconsider if:
1. A second device type is added and `selectedSerial` (single-device assumption) must become a `selectedDevice` with a picker.
2. Background enrichment scheduling is needed (currently enrichment runs on connect + explicit refresh only, per ADR-005).
3. The discovery poll interval is reduced below 5 s, at which point the Combine binding load increases and the direct-read optimization may need revisiting.

# Phase 8 — PixelDesktop UX

## Phase objective

Give the native macOS application a working UI surface that reaches existing backend capabilities, rather than re-implementing them in views. This is the wiring phase: all substantive logic (device discovery, enrichment, app operations, observation) was implemented and tested in Phases 2–5. Phase 8 connects that logic to `ContentView` and `AppState`, and keeps the connection tested.

## Requirements

- Device appears in sidebar; selected device serial is derived from connected state.
- Device identity fields (model, manufacturer, Android version, API level, architecture, ABIs) are populated on connect or refresh — not left as "Unknown".
- Live observation fields (memory, storage, worker state) are read.
- Application list is retrievable and launchable.
- Failures are surfaced as typed errors, not silently dropped.

## Starting state

- Phases 0–7 completed and tested.
- `ContentGigView` rendered a static device list with no enrichment.
- `AppState` existed as a minimal class with no enrichment call path.
- `DeviceManager.enrichDevice` existed but was never reachable from the UI layer.
- `AppOperationsProtocol` existed but had no `MockAppOperations` double and no UI caller.

## Investigation

1. `git log --oneline -- PixelDesktop/` — traced the enrichment wiring comment.
2. `DeviceManager.enrichDevice` source — confirmed it mutates `devices[index]` in place and returns the enriched device.
3. `DeviceEnricher.enrich` — reads via `transport.getSystemProperties(deviceSerial:)`.
4. `PixelEvidenceReader.observeState` — exists and returns `PixelStateObservation`.
5. `ContentGigView` — used `@StateObject var state = AppState()` and only bound to `devices` / `isDiscovering`; no calls to `observeDevice` or `loadInstalledApplications`.

## Architecture

**Decision:** `AppState` is the bridge between views and backend. Views call `async` methods on `AppState`; `AppState` calls `DeviceManager` and `AppOperationsProtocol`. No view reaches the transport directly.

**ADR-021** records this boundary decision.

The enrichment wiring lives in `refreshDevices()`:
```
refreshDevices() async
  → deviceManager.refreshDevices()   (updates devices + lastError via Combine)
  → self.devices = ...               (direct copy for deterministic postcondition)
  → enrichConnectedDevice()          (guard-first: only when selectedSerial exists)
  → self.devices = ...               (re-read to capture in-place enrichment)
```

## Alternatives considered

| Option | Rejected | Reason |
|--------|----------|--------|
| Combine-only binding for enrichment | Yes | No testable completion boundary; tests would need `XCTWaiter` + runloop pumps, fragile. One prior test used this and was flaky. |
| Keep fire-and-forget `Task { enrichConnectedDevice() }` | Yes | The whole defect was that nothing awaited it. Re-introducing this recreates the bug. |
| Enrich on the discovery poll | No — not in scope | Properties don't change while booted; poll would add ADB round-trips for no benefit. |

## Decision

Direct assignment + enrichment + re-read, all inside the `async` `refreshDevices()` method.

## Reason

1. `AppState` needs a deterministic postcondition: "after `await refreshDevices()` returns, `devices` is current and enriched." This must hold in tests as well as the running app.
2. `DeviceManager.enrichDevice` mutates `deviceManager.devices[index]` but does not touch `AppState.devices`. A single copy before enrichment is invisible to the enrichment step; a single copy after misses the enrichment result if `selectedSerial` wasn't available before. Two reads are explicit about both preconditions.
3. Combine bindings remain for the discovery poll path (`DeviceManager.startDiscovery` pushes `devices` on its own 5 s cadence); only the explicit `refreshDevices()` path bypasses them.

## Implementation

### `AppState.swift` — `refreshDevices()`

```swift
func refreshDevices() async {
    await deviceManager.refreshDevices()
    self.devices = await deviceManager.devices
    await enrichConnectedDevice()
    self.devices = await deviceManager.devices
}
```

### `AppState.swift` — `enrichConnectedDevice()` (already existed, was a no-op call site)

Unchanged: guard-first on `selectedSerial`, catches errors, records to `lastError`.

### `AppState.swift` — `observeDevice()` (new)

Wraps `PixelEvidenceReader(transport:).observeState(deviceSerial: serial)` — the same reader the CLI publishes from.

### `AppState.swift` — application operations (already existed)

`loadInstalledApplications()`, `launchApplicationReportingFailure(packageName:)` — guard-first via `connectedDeviceSerial()`.

### `ContentView.swift` — wired buttons to state methods

- Refresh → `state.refreshDevices()`
- Observe → `state.observeDevice()`
- List apps → `state.loadInstalledApplications()`
- Launch app → `state.launchApplicationReportingFailure(packageName:)`

### `Phase8UIWiringTests.swift` — new, 11 tests

Covers: selection, enrichment (success + failure + unauthorized), observation, app list (success + failure + guard), app launch (success + failure). Uses `MockTransport` and a new `MockAppOperations` double.

## Experiments

All ran via `xcodebuild test`.

## Failures

| # | Failure | Diagnosis | Correction |
|---|---------|-----------|------------|
| 1 | 10/11 tests failed; `enriched.marketingName` was `""` | Test version read `state.devices` too early; the Combine dispatch had not fired yet. | Switched tests to `await state.refreshDevices()` then read directly — no Combine waiting. |
| 2 | 7/11 tests failed after fix #1 | `refreshDevices()` set `self.devices` *after* `enrichConnectedDevice()`, so `selectedSerial` was nil and enrichment was skipped. | Set `self.devices` before enrichment, re-read after. |
| 3 | `testFailedEnrichmentIsRecordedAndNonFatal` failed | Same root cause as #2 — enrichment was skipped, so `lastError` was nil. | Fixed by #2. |
| 4 | 5/11 tests failed after fix #2 | Tests still used `waitForDevicesToChange` (Combine expectation helper), which raced with the deterministic postcondition. | Removed helper entirely; tests now just `await` and read. |

## Diagnosis of failure #1 (the Combine timing defect)

`AppState.devices` is a `@Published var` assigned from a Combine binding:
```swift
deviceManager.$devices
    .receive(on: DispatchQueue.main)
    .assign(to: &$devices)
```

In the running app this is fine: the rendering loop pumps the runloop, the binding fires, SwiftUI re-renders. In a synchronous test there is no rendering loop. The publisher fires on the main runloop, which only turns over when the test thread blocks — which it does not (it's `async`, not blocked on `DispatchGroup` or `XCTestExpectation.fulfill`).

Switching to direct assignment inside `refreshDevices()` gives the method a deterministic postcondition: after `await`, `self.devices` is current and enriched. No `XCTWaiter`, no runloop pump, no race.

## Diagnosis of failure #2 (the enrichment ordering defect)

The initial fix (after failure #1) was:
```swift
func refreshDevices() async {
    await deviceManager.refreshDevices()
    await enrichConnectedDevice()          // ← reads selectedSerial from self.devices
    self.devices = await deviceManager.devices  // ← set AFTER enrichment
}
```

`enrichConnectedDevice()` reads `selectedSerial`, which reads `self.devices`. But `self.devices` was set *after* the call. So `selectedSerial` was nil, `enrichConnectedDevice` returned early, and no enrichment ran.

Corrected by reordering: set `self.devices` before enrichment, re-read after.

## Tests

- `Phase8UIWiringTests` — 11 tests, all pass.
- Full suite: 506 tests, 0 failures, 22 skipped (device-dependent tests).

## Results

All Phase 8 requirements met. All Phase 8 tests pass. No regressions in existing tests.

## Regression tests

Full suite run after the fix confirmed: `Executed 506 tests, with 0 failures`.

## Final architecture

- `ContentView` → `AppState` (async methods)
- `AppState` → `DeviceManager` (discovery, enrichment)
- `AppState` → `PixelEvidenceReader` (observation)
- `AppState` → `AppOperationsProtocol` (app listing, launching)
- Combine bindings retained for the discovery poll path only.

## Lessons learned

- **Combine bindings have no deterministic completion boundary in tests.** For any `async` method that must have a testable postcondition ("after this returns, the state is X"), read the underlying state directly instead of waiting for a publisher. The binding can still run for the live UI path.
- **Ordering matters when an async method reads from and writes to the same property.** `enrichConnectedDevice()` reads `selectedSerial` (derived from `self.devices`); setting `self.devices` *after* the call means the call sees stale state. Write preconditions before dependent calls.
- **Direct assignment is stronger than publisher observation for test postconditions.** The Combine binding from `DeviceManager.$devices` is fine for the background discovery poll (which updates continuously); but `refreshDevices()` is an explicit, user-initiated action that needs a deterministic result.

## Best technique discovered

**Two-read pattern for async refresh + enrich:**
```swift
await deviceManager.refreshDevices()
self.devices = await deviceManager.devices       // read 1: precondition for enrichment
await enrichConnectedDevice()
self.devices = await deviceManager.devices       // read 2: capture enrichment result
```
Use this whenever a sub-call mutates the source in place but the caller holds a copy. The explicit two reads document the pre- and post-conditions of enrichment.

## Future recommendations

- If a second device is added, `selectedSerial` (single-device assumption) will need a `selectedDevice` state with a picker. Document this as ADR-when-needed.
- The `MockAppOperations` double can be extended to simulate launch failures by package name for future error-UI tests.

## What worked well

- `await state.refreshDevices()` + direct read replaced `XCTWaiter` + runloop pump. Simpler, faster (0.001–0.003 s per test), deterministic.
- Guard-first design (`connectedDeviceSerial()`, `selectedSerial` guard) made the "no device" tests trivial — no mocking needed for the refusal path.

## What did not work

- `waitForDevicesToChange(state:)` using `XCTWaiter().wait(for:timeout:)` inside `withCheckedContinuation` — it worked but was slow (2 s timeout on some tests) and conceptually wrong: it was testing the Combine binding, not the feature. The binding is a transport detail; the feature is "refresh returns enriched devices".
- Single-read pattern (`set devices` after enrichment) — silently skipped enrichment because `selectedSerial` was nil.

# ADR-006: Test Isolation Strategy for Device-Dependent Code

## Status

Accepted

## Date

2026-10-01

## Context

Phase 2 introduces code whose correct behaviour depends on a physically attached
Android device. Two conflicting requirements apply:

- The Phase 2 task explicitly requires mock-based unit tests for `getprop` success,
  `getprop` failure, property parsing, and device enrichment.
- The engineering workflow requires real-device verification against the Pixel 7a
  (serial `DEADBEEF000000`), including verification of the *actual* returned values.

A suite that always requires a device cannot run on a machine without one. A suite
that never touches the device cannot satisfy the verification requirement. A suite
that talks to the device opportunistically will silently pass while testing nothing.

## Problem

Where does the boundary sit between hermetic unit tests and real-device verification,
and how is each made honest?

## Options Considered

### Option A — Real device in the default suite

Rejected. The suite would fail on any machine without the Pixel attached, and CI-style
local verification becomes impossible. It also makes tests non-deterministic: a device
that is offline, unauthorized, or showing a different Android build changes results.

### Option B — Mock everything, no real-device test

Rejected. It would leave the acquisition path unverified. The whole point of Phase 2 is
that ADB actually returns these values from this device. A mock proves the code path,
not the integration.

### Option C — Hermetic default suite plus opt-in integration tests

Default suite is entirely mock-based and always runs. A separate `PixelDeviceIntegrationTests`
class talks to a real device and **skips** unless `PIXELDESKTOP_DEVICE_SERIAL` is set.

**Chosen.**

### Option D — A standalone CLI harness compiling the production sources

Used *in addition* to Option C for the Phase 2 evidence run.

## Evidence

`xcodebuild` in this environment did not forward `TEST_RUNNER_PIXELDESKTOP_DEVICE_SERIAL`
into the test process: the integration tests reported "skipped" even when the variable
was passed on the command line, so no real-device assertion actually executed.

Rather than claim a real-device pass that did not run, the production sources
(`Transport.swift`, `ADBTransport.swift`, `DeviceEnricher.swift`, `PixelDevice.swift`,
`PixelDesktopError.swift`) were compiled directly with `swiftc` into a CLI harness and
executed against the Pixel 7a. That harness printed the real values and independently
cross-checked them against raw `adb` invoked outside all project code.

Observed output:

```
DISCOVERY: 1 device(s)
  serial=DEADBEEF000000 state=device model=Pixel_7a device=lynx
  pre-enrichment -> android='' api=0 abi=''
ENRICHMENT (real values returned by the device):
  androidVersion = 16
  apiLevel       = 36
  architecture   = arm64-v8a
INDEPENDENT CROSS-CHECK (raw adb, no project code):
  androidVersion = 16
  apiLevel       = 36
  architecture   = arm64-v8a
CROSS-CHECK MATCH: true
UNSET PROPERTY: correctly rejected -> Invalid input: Property 'ro.pixeldesktop.not.real' is unset on device DEADBEEF000000
UNKNOWN SERIAL: correctly failed -> ADB command failed: getprop ro.build.version.release (exit code 1): adb: device 'NOSUCHSERIAL0000' not found
RESULT: PASS
```

## Decision

- Default test suite (`PixelDesktopTests`) is hermetic: mock-based, no device required,
  must always pass. It is the regression gate.
- `PixelDeviceIntegrationTests` is opt-in via `PIXELDESKTOP_DEVICE_SERIAL` and uses
  `XCTSkip` when unset, so its absence is visible rather than silently green.
- Integration assertions verify **presence and well-formedness** (`androidVersion` is
  non-empty, `apiLevel > 0`), never a pinned version number. Pinning would turn a device
  OS update into a false test failure.
- The CLI harness is retained as the mechanism for producing real-device evidence when
  the test-runner environment-variable path is unavailable.
- Every real-device claim in the phase log must be backed by printed tool output, not
  by an assertion that merely did not fail.

## Reasoning

The two requirements are genuinely different jobs. Regression safety needs
determinism and zero external dependencies; integration verification needs the real
device. Collapsing them produces a suite that is neither. Making the skip explicit
means a reader can always tell whether the device path ran.

Asserting well-formedness rather than exact values is the direct consequence of a
Phase 2 discovery: the values recorded in Phase 1 fixtures (`14` / `34`) were wrong
for this device (it reports `16` / `36`). Tests that encode a device's current OS
version break on every OS update while catching nothing.

## Consequences

- Local regression runs are fast (0.09 s) and device-independent.
- Real-device verification is a deliberate, separately-invoked step.
- The `TEST_RUNNER_` env-var limitation is a known tooling gap, documented rather than
  worked around with an unverified claim. If it is resolved, the integration tests can
  carry the evidence directly and the harness becomes redundant.
- Three tests are permanently visible as "skipped" in a default run. This is intended:
  it is an honest signal, not noise.

## Rejected Alternatives

- **Real device in the default suite** — non-deterministic, fails without hardware.
- **Mocks only** — leaves the actual ADB acquisition path unverified.
- **Pinning expected Android version/API level** — creates false failures on OS updates.
- **Treating a skipped integration test as a pass** — would let Phase 2 be declared
  complete without ever having touched the device.

## Future Reconsideration Conditions

- Revisit if `TEST_RUNNER_` forwarding works in a future Xcode version: promote the
  integration tests to the primary evidence mechanism.
- Revisit if the project gains CI: integration tests should run there behind a
  self-hosted runner with the device attached, and must never be silently skipped in
  that context.

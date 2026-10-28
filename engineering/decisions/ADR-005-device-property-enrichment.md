# ADR-005: Device Property Enrichment Is Separate From Discovery

## Status

Accepted

## Date

2026-10-01

## Context

Phase 2 needs the Pixel 7a's stable system identity (Android version, API level, CPU
architecture) available to the application. `PixelDevice` has carried `androidVersion`,
`apiLevel` and `architecture` fields since Phase 1, but nothing ever populated them —
`parseDeviceList` hard-codes `""`, `0`, `""`.

Two things needed deciding:

1. How those values are acquired.
2. Where in the architecture that acquisition lives.

## Problem

`adb devices -l` reports serial, connection state, and a coarse `model:`/`device:`
pair. It does **not** report Android version, API level, or ABI. Those come from
`getprop`, which is a separate ADB invocation per property.

That creates a placement question. The obvious-looking move is to call `getprop`
inside `parseDeviceList`, so a device comes out of discovery fully populated.

## Options Considered

### Option A — Enrich inside `parseDeviceList`

One call site, device always complete.

Rejected. `parseDeviceList` is a `nonisolated` pure function over a single
`adb devices -l` string; it performs no I/O. Putting I/O in it would:

- turn a pure parse into an async, device-touching operation;
- make the existing unit tests (`testADBTransportParseDeviceList`,
  `testADBTransportParseEmptyList`) require a mock transport;
- add 3 ADB round trips to **every discovery poll**, for values that cannot change
  while the device stays booted.

### Option B — Enrich in `DeviceManager` using `ADBTransport` directly

Keeps the transport clean, but binds enrichment to the concrete `ADBTransport`
actor. Enrichment logic would then be untestable without a physical device, which
directly conflicts with the Phase 2 requirement for mock-based unit tests.

### Option C — Dedicated `DeviceEnricher` depending on `TransportProtocol`

`ADBTransport` gains only a transport-shaped `getprop()`. A separate `DeviceEnricher`
owns the "what is this device" question and depends on the protocol, not the actor.
`DeviceManager` composes it and depends on `TransportProtocol`.

**Chosen.**

## Evidence

Measured against the real Pixel 7a (`DEADBEEF000000`):

| Property | `getprop` key | Observed value |
|---|---|---|
| Android version | `ro.build.version.release` | `16` |
| API level | `ro.build.version.sdk` | `36` |
| CPU ABI | `ro.product.cpu.abi` | `arm64-v8a` |

Two behaviours were established by direct test rather than assumption:

1. `getprop` on an **unset key exits 0 with empty output**. It does not fail. A
   missing value is therefore only detectable by inspecting the output, so the
   empty check belongs in the transport (and its mock), not in the caller.
2. `getprop` on an **unknown serial exits 1** with
   `adb: device 'NOSUCHSERIAL0000' not found`, which maps to `adbCommandFailed`.

The assumed values recorded in earlier Phase 1 fixtures (`14` / `34`) were **wrong**
for this device. This is why the tests assert well-formedness, not specific values.

## Decision

- `TransportProtocol` gains exactly one new method:
  `getprop(deviceSerial:key:timeout:) async throws -> String`.
- `ADBTransport` implements it via the existing `execute()` path, issuing
  `adb -s <serial> shell getprop <key>`.
- `DeviceProperties` is a 3-field value type with a throwing `make(...)` factory that
  trims whitespace and rejects empty/malformed input.
- `DevicePropertyKey` holds the three `getprop` keys beside the model they populate.
- `DeviceEnricher` (new file, `PixelDesktop/Device/`) depends on `TransportProtocol`
  and returns an enriched copy of a `PixelDevice`.
- `DeviceManager` depends on `TransportProtocol` (was `ADBTransport`) and exposes an
  explicit `enrichDevice(serial:)` that is **not** on the discovery polling path.
- `parseDeviceList` is unchanged and still performs no I/O.

## Reasoning

The deciding constraint was testability under the Phase 2 requirement for mock-based
tests, combined with the fact that these properties are constant for a boot session.
Separating the responsibilities means discovery stays a pure, fast, single-call parse
on a 5-second poll, while the three-round-trip enrichment happens on demand.

`DeviceProperties.make` is where malformed device output is rejected. Because
`getprop` returns exit 0 for unset keys, a naive implementation would populate
`androidVersion = ""` and `apiLevel = 0` — indistinguishable from "not yet enriched".
Failing loudly is the correct behaviour.

## Consequences

- Enrichment is fully unit-testable against `MockTransport` with no device attached.
- `DeviceManager` now takes any `TransportProtocol`, which is a small widening of its
  API but the source of its testability.
- Enrichment is explicit, so callers must decide when to pay for it. Phase 8 UI must
  call `enrichDevice` after discovery to show real values.
- Three sequential round trips per enrichment. Acceptable: it happens on demand, not
  on the poll interval.

## Rejected Alternatives

- **Enrich in `parseDeviceList`** — adds I/O to a pure parse and 3 round trips per poll.
- **Enrich in `DeviceManager` against concrete `ADBTransport`** — not unit-testable.
- **Put `enrichDevice` on `ADBTransport`** — implemented first, then removed. It is
  device-modelling logic, not transport. Leaving it there would have made the transport
  grow a method per consumer concern.
- **Add battery/screen/storage/network fields** — excluded by the approved scope. They
  are dynamic, need different acquisition mechanisms, and are not required yet.

## Future Reconsideration Conditions

- Revisit if enrichment is needed on the discovery path (e.g. UI must show version the
  instant a device appears). Then consider caching properties per serial for the boot
  session rather than calling `getprop` on every poll.
- Revisit if more than ~5 properties are needed: batch them into a single
  `getprop` (no argument dumps all properties) and parse the output, rather than N calls.
- Revisit the `invalidInput` mapping for unset properties if a genuinely optional
  property is added; an optional field would want `String?`, not a throw.

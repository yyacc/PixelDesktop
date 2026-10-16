# Phase 1 (Remote Storage) — Connection Foundation: Transport Priority & Persistence

**Date:** 2026-10-16
**Issue:** RNZM-68 (Multica)
**Proposal:** `docs/PROPOSAL-REMOTE-STORAGE.md` §4 Phase 1, §3.1
**Status:** IMPLEMENTED — 568 tests, 22 skipped, 0 failures (+30 over the Phase 2 baseline)

## Goal

Persistent wireless (WiFi) and wired (USB) connection to the Pixel 7a with automatic
transport selection (USB > WiFi priority), auto-reconnect on connection loss, and
connection-state persistence across app restarts.

## Delivered

| Concern | File |
|---------|------|
| Transport modes, selection priority, endpoint parsing | `PixelDesktop/Device/TransportState.swift` |
| Selection observation, persistence, auto-reconnect | `PixelDesktop/Device/ConnectionManager.swift` |
| Network-change detection seam | `PixelDesktop/Transport/NetworkPathMonitor.swift` |
| `adb connect` primitive + result interpretation | `PixelDesktop/Transport/ADBTransport.swift` |
| Dual-transport integration + published state | `PixelDesktop/Device/DeviceManager.swift` |
| UI-layer MLP binding (status delivery, Phase 3) | `PixelDesktop/App/AppState.swift` |
| 30 unit tests | `PixelDesktopTests/ConnectionFoundationTests.swift` |

## Decisions

1. **Serial classification, not model fields.** `TransportSelector.mode(forSerial:)`
   classifies from the serial: a colon (`host:port`) means wireless; the
   `.adb-tls-connect._tcp` mDNS marker also maps wireless even in the colonless
   mDNS form. USB serials are bare alphanumerics and never match either rule.
   Nothing on `AndroidDevice` changes, so every existing construction site and
   test double stays valid.

2. **Wired priority is a pure function.** `TransportSelector.select(_:)` — first
   connected wired device wins; otherwise the first connected wireless device;
   otherwise `nil` (offline). Unauthorized/offline devices are never selectable.

3. **Persistence records the last known state, never live state.**
   `PersistedConnectionState` (UserDefaults key `PixelDesktop.connectionState.v1`)
   stores the wireless endpoint captured while verifiably connected, plus
   `lastMode`/`lastSerial`/`updatedAt` for information. On startup the endpoint is
   loaded *for reconnection* — a restarted app never reports "connected" without a
   verified device listing.

4. **Reconnect is one single-flight sequence.** Exponential backoff
   (1/2/4/8/16 s, `ReconnectScheduler`, max 5 attempts), then terminal exhaustion.
   A device sighting or a network-up event is "new input" and resets exhaustion;
   repeated offline polls do not stack sequences. An `adb connect` that answers
   but yields no device in the re-listing is not recovery — the sequence continues.

5. **`adb connect` lies about exit codes.** Connecting to a dead endpoint exits 0
   with `cannot connect …` on stdout. `ADBTransport.validateConnectResult` judges
   success by output text (`connected to`/`already connected to` vs. the failure
   phrasings), never by exit status alone.

6. **Network-change detection is a narrow seam.** `NWPathMonitor` is wrapped in
   `NetworkPathMonitor: NetworkPathMonitoring` so connection logic and its
   triggers are unit-testable. A network coming *up* is the only actionable
   direction (down paths cannot be recovered from inside the app).

7. **DeviceManager feeds observations only from successful listings.** A failed
   `adb devices` run is not evidence a device disappeared — it neither tears down
   the current selection nor triggers reconnect.

## Verification

- `xcodegen generate` → `xcodebuild test -scheme PixelDesktop`:
  **Executed 568 tests, with 22 tests skipped and 0 failures.**
- New suite: transport selection (priority, fallback, unusability, classification),
  endpoint parsing (plain/mDNS/USB-serial), scheduler (1-2-4-8-16, clamp,
  exhaustion), persistence (wireless endpoint, wired snapshot, offline retention,
  restart-driven re-dial), reconnect (exhaustion, recovery, silent-failure,
  single-flight, exhaustion reset), network-path triggering, DeviceManager
  dual-transport integration, `adb connect` result interpretation.
- Real-device verification not performed in this run (no device attached); the
  proposal's Phase 5 integration testing covers USB-plug/unplug on hardware.

## Known boundaries

- Endpoint parsing recovers IPv4 endpoints; a serial that is only a mDNS name
  without an embedded IPv4 cannot be remembered for reconnect (visible as `nil`,
  not guessed).
- mDNS *service discovery* of re-published ports (ADR: Bonjour re-discovery in
  the proposal's risk table) is not implemented here; the remembered endpoint is
  the re-dial address until Phase 5 reintroduces discovery if needed.

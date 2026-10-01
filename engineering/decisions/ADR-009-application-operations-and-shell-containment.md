# ADR-009: Application Operations, Shell Containment, and Lifecycle Invalidation

## Status

Accepted

## Date

2026-10-01

## Context

Phase 4 (Android Application / Process Control) is the first phase that **acts on** the
device. Phases 2 and 3 only read from it. Master prompt §16 requires implementing controlled
application operations with discovery, representation and operations separated; §22 forbids
APK modification, code injection, security/anti-cheat bypass, credential extraction and
destructive operations, and requires explicit permissions and documented interfaces.

Three things needed deciding: how the shell primitive is contained, what the stop-operation
protection model actually guarantees, and how connection lifecycle interacts with cached
device state.

## Problem

1. `shell()` is a general-purpose escape hatch — any string handed to it runs on the device.
   How is it contained without removing the capability the phase needs?
2. `am force-stop` terminates a process and discards unsaved state. What protection is
   warranted, and — critically — **what does that protection actually guarantee?**
3. A disconnect invalidates a device's state. Should enriched properties be cached across a
   reconnect?

## Evidence

Probed on the real Pixel 7a (read-only, nothing launched or stopped):

| Probe | Result |
|---|---|
| `which su` | **empty** — no root shell available |
| `getprop ro.debuggable` | **`0`** — device is not debuggable |
| `pm list packages` / `-3` | 364 total, **41 third-party** |
| `cmd package query-activities …` | 58 launchable, one call, parses cleanly, no duplicates |
| `dumpsys package <pkg>` | **49,893 bytes per app** |
| `pidof <running>` / `<not running>` | exit **0** / exit **1** |
| `am force-stop` (no args) | exit **255** + Java exception |

Verified after implementation (live, approved sequence): discover → resolve launcher →
launch Settings → verify running → stop Settings → verify stopped. All passed, and the
third-party count matched raw `adb` (41).

## Decision

### 1. `shell()` is a transport-only primitive

Added to `TransportProtocol` and implemented in `ADBTransport` over the existing
`execute()` path. It is **not** exposed on `AppOperationsProtocol`, not surfaced through
`AppState` as a command-taking method, and must not be exposed to the UI (Phase 8) or Hermes
(Phase 9) without a separate review.

### 2. A new `Operations/` layer owns device actions

`AppOperationsProtocol` + `ADBAppOperations`. Every method takes **explicit typed
arguments**; none accepts a shell string. Commands are assembled from fixed templates plus
one validated argument.

### 3. Stop containment

`stopApplication` requires: an exact package identifier, no wildcards, no arbitrary shell
strings, no command passthrough; and rejects explicitly protected packages, protected
prefixes, and the Phase 5 worker package — all **before any command is issued**.

### 4. No caching across disconnect

`DeviceManager.refreshDevices()` replaces the published device list wholesale. A device that
disappears is dropped; one that reappears returns with properties empty until re-enriched.
Enriched properties are never carried across a disconnect or reconnect.

### 5. Guard-first operations

Operations check device state **before** issuing a command. `requireConnectedDevice(serial:)`
throws `deviceNotFound` / `deviceOffline` up front, so a stale device fails predictably
rather than hanging.

## The Protection Model — and Its Limitations

**This section is the point of the ADR.** The containment is deliberately described by what
it does *not* guarantee.

### What the protection IS

- **Defence-in-depth against accidental misuse.** It stops a caller from stopping SystemUI,
  the launcher, or a system provider by mistake, and stops a caller from passing a wildcard
  or a composed command.
- **An input-shape check.** `validatePackageName` rejects anything that is not a bare
  package identifier, which is what makes command injection through this layer impossible:
  a value containing spaces, `;`, `|`, `&&`, quotes, backticks or redirects cannot pass. This
  is verified by a test that feeds ten hostile strings and asserts each is rejected.
- **A template-constrained command surface.** The only command ever issued by
  `stopApplication` is `am force-stop <validated-package>`. No caller input reaches the shell
  except through that one validated slot.

### What the protection is NOT

- **Not a security boundary.** Package naming is not a security mechanism. The denylist is a
  fixed set of known-critical names; it **cannot be complete**. A vendor system package with
  an unexpected name will not match. An application can legitimately be named `com.android.*`
  and will not be protected. A test pins this explicitly
  (`testContainmentIsDenylistNotBoundary`).
- **Not a sandbox.** `shell()` still exists below this layer and can run anything. Containment
  is achieved by *not exposing it*, not by making it safe.
- **Not a permission system.** ADB access is all-or-nothing: a caller with `TransportProtocol`
  can bypass `AppOperationsProtocol` entirely and call `shell()` directly. The containment
  constrains the *operations layer's* behaviour, not a hostile holder of the transport.

### Why the protection is nevertheless sufficient for this project

The real boundary is **not the denylist**. It is:

1. **No privilege escalation is available.** The device is not rooted and not debuggable
   (`su` absent, `ro.debuggable=0`), so ADB cannot escalate beyond the `shell` user's
   privileges. Anything reachable is already reachable by the user via a terminal.
2. **`shell()` is not reachable from above.** The operations layer never accepts a command
   string, and the UI and Hermes do not receive the transport.
3. **The blast radius is bounded by the device itself.** The worst outcome available through
   this layer is stopping an application; a reboot recovers it. There is no APK modification,
   no injection, and no persistent device change.

Stated plainly: **the denylist prevents mistakes, the architecture prevents misuse, and the
device's own privilege posture prevents escalation.** No single one of those is a boundary.

### On the over-broad protected entry

`com.android.settings` was initially on the protected list, added by reflex on package name.
It fails the list's own stated criterion ("stopping this disrupts the device itself"): it is
an ordinary user-facing app with no system service depending on it. Real-device verification
surfaced the error, because the approved verification sequence stops Settings. It was
removed, and `testSettingsIsNotProtectedBecauseItIsNotDeviceCritical` pins the criterion so
it cannot silently return.

This is recorded because it is the clearest evidence that name-based protection is heuristic:
the rule was applied wrongly on the first attempt, by the author of the rule.

## Reasoning

**Why keep `shell()` at all** rather than one transport method per Android command: Android
application semantics belong in the operations layer, not the transport. ADR-005 and Phase 2
deliberately kept `ADBTransport` free of device meaning. One primitive plus a typed operations
layer preserves that, whereas `listPackages()`/`launch()`/… on the transport would put Android
knowledge in the wrong layer and make the transport grow a method per consumer concern.

**Why `pidof` and not `ps -A`:** `pidof` answers the question any consumer has ("is this app
running") with exit 0/1. `ps -A` is 556 lines of kernel threads and system processes with no
consumer. Approved as D4; `ps -A` is deferred until something needs it.

**Why no caching:** these properties are constant for a boot session but can change across a
reboot or OS update. A reconnect is exactly when that becomes possible, so a cache could
serve stale values precisely when it matters. Not caching makes the bug impossible rather
than unlikely.

**Why guard-first:** Phase 4 assumes a live device. Acting on one that has just disconnected
must fail predictably rather than hang or act on stale state.

## Consequences

- `DeviceOperation` grew from 2 to 6 cases, extended in the same commit as each
  implementation, so the model never advertises a non-existent operation.
- `AppState` gained five operation wrappers, each guard-first, so callers never reach the
  transport or a shell string.
- `MockTransport` gained `shell()` with a per-command response map.
- A refused stop issues **zero** device commands — verified by test.
- `pidof` exit 1 maps to `false`, not an error, and is tested separately from `getprop`'s
  exit-0-for-unset semantics so the two cannot be conflated.
- 106 tests pass (102 hermetic + 4 opt-in integration tests skipped by design).
- Real-device verification launches and stops Settings, leaving the device healthy.

## Rejected Alternatives

- **One transport method per Android command** — puts application semantics in the transport.
- **No containment on `stopApplication`** — a wildcard or a system-package stop could leave
  the device broken mid-verification.
- **Treating the denylist as a security boundary** — it cannot be complete; documented as
  heuristic instead.
- **Caching enriched properties with boot-session invalidation** — adds state and a staleness
  bug for no measured benefit; re-enrichment is one batched call.
- **`ps -A` process inventory** — no consumer; deferred (D4).
- **Exposing `shell()` to the UI for flexibility** — explicitly forbidden by §22 and by the
  Phase 4 approval.

## Future Reconsideration Conditions

- **Revisit before Phase 8/9**: if the UI or Hermes ever needs an operation not yet named,
  add a *named* operation. Do not widen `shell()` exposure.
- **Revisit in Phase 5**: `push()`/`pull()` arrive then (RNZM-23). File transfer introduces
  path handling, which is a new input-validation surface and needs its own review — package
  validation does not cover it.
- **Revisit in Phase 10 (hardening)**: consider whether `shell()` should be removed from
  `TransportProtocol` entirely in favour of a fixed command enum, if no caller needs it
  directly.
- **Revisit the denylist** if a vendor device is added; its system packages will not match
  these prefixes.
- **Revisit caching** if a future phase shows re-enrichment is too slow in practice.

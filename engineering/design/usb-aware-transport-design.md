# USB-Aware Transport Design — Investigation and Design

**Status:** DESIGN COMPLETE. **No production code modified. No implementation performed.**
**Date:** 2026-10-02
**Scope:** transport resilience. **Not** workload routing, resource management, or scheduling.
**Phase 7 architectural boundary: UNCHANGED** — see §18.

---

## 1. Existing transport architecture

### What exists

| Component | Role | Relevant shape |
|---|---|---|
| `TransportProtocol` | the transport abstraction | `AnyObject, Sendable`; every device-facing method takes `deviceSerial:` |
| `ADBTransport` | the **only** implementation | `actor`; shells out to `adb -s <serial> …` |
| `DeviceDiscoveryProtocol` | discovery contract | `startDiscovery()` / `stopDiscovery()` / `refreshDevices()` |
| `DeviceManager` | `@MainActor ObservableObject` | owns a 5-second `while !Task.isCancelled` discovery loop |
| `DeviceState` | existing connection state | `.device` / `.unauthorized` / `.offline` / `.unknown` |
| `AndroidDevice` | device model | `serialNumber` is the ADB identity |

### The structural finding that shapes this design

**`TransportProtocol` is already device-targeted, not transport-targeted.** Every method takes a
`deviceSerial` and `ADBTransport` builds `adb -s <serial>`. Nothing in the protocol knows *how* the
device is attached.

This is important: **the abstraction boundary is already correct for this work.** A wireless
transport and a wired transport can both satisfy `TransportProtocol` with no change to its
signature, and no caller above it needs to know which is active.

**A second parallel transport architecture is therefore not needed.** See §17.

---

## 2. Current wired/wireless behaviour

| Question | Answer | Evidence |
|---|---|---|
| Is there any wireless support? | **No — none at all** | `grep -rniE 'wireless\|mdns\|bonjour\|tcp\|:5555\|pair' PixelDesktop/` returns **zero** functional matches; the only hits are the words "network" in unrelated doc comments |
| Is there mDNS handling? | **No** | no `NetService`, `NWBrowser`, or `Network` framework usage |
| Is there TCP transport handling? | **No** | `ADBTransport` is exclusively `adb` CLI over USB |
| Is there any connection-state model for transports? | **No** | `DeviceState` describes **ADB's view of the device**, not which transport carries it |
| Is there a reconnect/retry mechanism? | **No** | confirmed by source inspection in FAIL-006; the sole `Task.sleep` is a command timeout |
| How is the active transport identified? | **Implicitly, and never parsed** | `adb devices -l` emits `usb:1048576X` for a wired device; `parseDeviceList` ignores that field entirely |

### The wireless premise is currently unmet

**Wireless ADB is not enabled on the device.**

| Check | Result |
|---|---|
| `service.adb.tcp.port` | **unset** |
| `persist.adb.tcp.port` | **unset** |
| `settings get global adb_wifi_enabled` | **`0`** |
| `adb mdns check` | `mdns daemon version [adb discovery 0.0.0]` — the local ADB client supports discovery |

So the proposed flow *"wireless ADB active → USB appears → switch to wired"* has **no wireless leg to
start from**. `adb` on this machine can *do* mDNS discovery, but the **device is not advertising**,
because wireless debugging was never enabled on it.

**This is the single most important finding for the design.** The stated goal assumes a working
wireless fallback that does not exist yet. Implementing transport switching before a wireless
transport exists would mean building a state machine with one reachable state.

---

## 3. macOS USB event mechanisms investigated

### Investigated empirically, not from documentation

A throwaway IOKit probe was **compiled and run** on this machine (macOS **27.0**, Swift **6.4**).
It is **not production code** and has been deleted.

**Result — the mechanism works:**

```
=== IOKit USB NOTIFICATION PROBE ===
watching IOUSBHostDevice  (started 14:42:14.815)
attach notification registered (result=0)
[14:42:14.820] PRESENT-AT-START: Pixel 7a  0x18d1/0x4ee2  serial=3C261JEHN25632
detach notification registered (result=0)
```

| Question | Verified answer |
|---|---|
| Does IOKit deliver USB notifications? | **Yes.** `IOServiceAddMatchingNotification` returned `KERN_SUCCESS` (0) for **both** `kIOFirstMatchNotification` and `kIOTerminatedNotification` |
| Is `IOUSBHostDevice` the right matching class? | **Yes.** It matches the Pixel — confirmed against the live registry |
| Can the **specific device** be identified? | **Yes.** `kUSBSerialNumberString` = **`3C261JEHN25632`** — **the same serial ADB uses** |
| Is `IOUSBHost.framework` present? | **Yes** — `/System/Library/Frameworks/IOUSBHost.framework` |
| Is `IOKit.framework` present? | **Yes** |
| Does it need root or entitlements? | **No.** The probe ran as an ordinary user process |

### Why this matters more than the event itself

**The USB serial and the ADB serial are the same identifier.**

That closes the trust boundary cheaply: a USB attach event carries the identity needed to decide
*"is this the Pixel I expect?"* **without** first trusting ADB. The design can therefore refuse to
attempt a wired switch for an unrelated USB device, using evidence rather than assumption.

### Alternatives considered

| Mechanism | Verdict |
|---|---|
| **IOKit `IOServiceAddMatchingNotification`** | **RECOMMENDED.** Event-driven, no polling, identifies the device by serial, verified working |
| `IOUSBHost` `IOUSBHostDevice` delegate callbacks | Viable and more modern, but oriented toward *claiming and talking to* a device. We do not want to open the device — only observe its presence. Opening it would also collide with the exclusive-access contention already documented in FAIL-006 |
| `DiskArbitration` | Wrong layer — storage volumes, not USB devices |
| `NSWorkspace` USB notifications | Do not exist |
| `system_profiler` parsing | **Already proven unusable** — FAIL-006 recorded that it reports *no USB devices at all* on this machine while `ioreg` sees them correctly |
| Polling `ioreg` | Works, but is polling. Rejected in favour of the event API that is available |

**Important caveat, consistent with FAIL-006:** a USB notification tells us the **kernel** saw a
device appear. It does **not** tell us the device is usable, and it does **not** survive the
kernel's own port teardown. IOKit notifications are generated by the same `IOUSBHostFamily` layer
that issued `hardware port disabled`. **A DETACH event is therefore a strong signal that the
transport is about to break — and it is the event we most need.**

---

## 4. Recommended detection mechanism

**IOKit `IOServiceAddMatchingNotification`, matched on `IOUSBHostDevice`, using
`kIOFirstMatchNotification` (attach) and `kIOTerminatedNotification` (detach).**

Filter to the expected device by `kUSBSerialNumberString`. Deliver events on a dedicated
`DispatchQueue`, never the main thread.

**Verified available and working on macOS 27.0 with no root and no special entitlement.**

---

## 5. Why it is preferable to continuous polling

| Dimension | IOKit notifications | Continuous polling |
|---|---|---|
| Latency | **Immediate** — delivered when the kernel acts | up to one poll interval |
| Cost when idle | **Zero** — no work between events | a subprocess every interval, forever |
| Failure visibility | **Reports detach explicitly** | infers absence from a missing device, indistinguishable from "not yet connected" |
| Interaction with FAIL-006 | **Captures the exact teardown moment** | may miss a 1-second flap entirely between polls |
| Battery/CPU | negligible | continuous |

**The decisive argument is not efficiency — it is fidelity.** FAIL-006 documented a **rapid
attach/detach flap** (13:40:27: three teardowns within ~1 second). A 5-second poll **cannot see**
that event. A kernel notification is delivered for each one.

**However — polling is not eliminated.** See §7: discovery still uses ADB. The change is that
polling becomes *triggered* rather than *continuous*.

---

## 6. How USB presence should trigger wired discovery

**USB presence is a trigger, not proof.** This is the design's central discipline.

```
IOKit ATTACH (serial == expected)
        ↓
mark "USB candidate present"   -- NOT "wired healthy"
        ↓
debounce / stabilization (§11)
        ↓
attempt wired ADB discovery  (adb devices)
        ↓
VERIFY the transport (§7)
        ↓
only now: wired healthy
```

**On failure at any step, nothing changes.** The system remains in whatever state it was, and the
event is recorded. A USB device that appears but never yields a working ADB transport must **not**
be reported as a wired connection.

**Explicitly not done on attach:** no state transition, no transport switch, no assumption.

---

## 7. How wired ADB health should be verified

USB presence and ADB health are independent. Verification must be **positive**, not inferred.

Proposed verification, in order, all of which must pass:

1. **Device is listed by ADB** — `adb devices -l` contains the expected serial.
2. **State is `.device`** — not `.unauthorized`, not `.offline`. `DeviceState` already models this
   distinction and it must be honoured.
3. **The transport is actually wired** — the `usb:` field in `adb devices -l` output. **This field is
   currently parsed and discarded**; it is the only way to tell wired from wireless from ADB's own
   view.
4. **A round-trip succeeds** — one bounded command (e.g. `getprop ro.product.model`) returning the
   expected value. Listing is not the same as working: FAIL-006 showed the device present in
   `ioreg` while ADB listed nothing.

**Only after all four pass may the active transport be considered wired.**

> **Note on step 3:** the `usb:` value observed throughout this project is `usb:1048576X`, which is
> anomalous (the trailing `X`). It is recorded in FAIL-006 as unexplained. **The design must not
> depend on parsing that specific format** — it should treat "the transport field begins with
> `usb:`" as the wired signal and treat anything else as not-wired, rather than validating the
> whole string. This is a real fragility worth flagging.

---

## 8. Wireless fallback behaviour

**Not implementable today.** Wireless ADB is off on the device (§2).

The design should therefore specify the behaviour but **not** be built until a wireless transport
exists:

- If wired ADB is lost and USB is also gone → attempt wireless **only if a wireless transport is
  configured and known-good**.
- If no wireless transport exists → report **"no transport available"** plainly. **Do not** invent
  a fallback.
- Wireless must be verified by the same four-step discipline as wired. Being reachable over TCP is
  not the same as being the expected device.

**The honest current state:** the correct behaviour today is *"wired lost → report unavailable"*,
which is what the code already effectively does. Adding switching logic now would add a state
machine whose fallback branch can never execute.

---

## 9. Wired recovery behaviour

When wireless is active and USB appears:

1. IOKit attach, serial matches → candidate.
2. Debounce (§11).
3. Attempt wired discovery + four-step verification (§7).
4. **On success** → switch active transport to wired.
5. **On failure** → remain wireless, record the attempt, **and do not retry on a loop**.

**Critical anti-flapping rule:** a failed verification must **not** be retried merely because USB is
still physically present. USB presence is a *level*, not an *edge*. Retrying on a level would
hammer ADB continuously — precisely the "do not repeatedly hammer ADB because USB is physically
present" constraint.

**Retry must be edge-triggered:** a *new* attach event, or a *change* in USB presence, not the
continued existence of a device.

---

## 10. Connection-state model

### Reuse, don't reinvent

`DeviceState` already models ADB's view of **one** device: `.device`, `.unauthorized`, `.offline`,
`.unknown`. **That is a different axis** from "which transport is carrying it" and should not be
overloaded.

### Proposed additional axis (not a replacement)

```
TransportState
  .wiredHealthy        wired verified (all four checks)
  .wirelessHealthy     wireless verified
  .wiredDegraded       USB device present, ADB NOT healthy   <-- the FAIL-006 state
  .unavailable         neither transport usable
  .recovering          a switch is in progress and unverified
```

**`wiredDegraded` is the state the existing code cannot express, and it is the one this whole
investigation is about.** FAIL-006's live observation was exactly:

```
macOS USB device: CONNECTED
ADB transport:    DISCONNECTED
```

The current model can only say "not connected", which **loses the most important fact** — that the
hardware is fine and the problem is above it. That distinction determines whether the right response
is "check the cable" or "check ADB".

**Composition, not replacement:** `AndroidDevice.state` (`DeviceState`) stays as-is;
`TransportState` is a separate, orthogonal axis. A device can be `.wiredDegraded` while its
`DeviceState` is `.unknown`, and both are true.

---

## 11. Debounce / stabilization

### Is it justified? Yes — and the evidence is specific

**Evidence for:** FAIL-006 recorded `13:40:27` with **three teardowns within ~1 second**, and
07:10 with two within 200 ms. The kernel itself flaps. An un-debounced handler would attempt a
discovery per event and could produce `wireless → wired → wireless → wired` churn.

**Evidence for the duration being a real problem:** during this investigation the device repeatedly
appeared and disappeared from `adb devices` **while `ioreg` continuously showed it present**, with
**zero** kernel teardowns in the window. So transient ADB absence is a real, observed phenomenon
that is *not* a USB event.

### Proposed mechanism

**Debounce on the ATTACH side only.** Require the device to remain present for a short stabilization
window before attempting discovery.

**Do not debounce DETACH.** Losing a transport should be reported immediately — a fast reaction to
loss is safe, and delaying it only prolongs a broken state.

### On the duration — deliberately not fixed here

**No specific number is proposed, and this is intentional.** The evidence shows flaps at ~200 ms and
~1 s, and transient ADB absence over several seconds. Choosing a constant now would be inventing
policy — the same mistake ADR-013 §P7 and the Phase 7 Step 2 `Freshness` design both avoided.

**What is proposed instead:** the window is a **parameter with no default**, exactly as `Freshness.maxAge`
was made a required parameter in Phase 7 Step 2. The correct value must come from measuring the
actual flap distribution, which requires the 1-hour observation run that was paused.

**A second, stronger stabilizer is available and costs nothing:** require the **verification** (§7)
to pass rather than timing the presence. If verification fails, no switch happens — regardless of
how long USB was present. **Verification subsumes most of the need for a timeout.**

---

## 12. Concurrency and cancellation

| Concern | Design |
|---|---|
| Where do IOKit callbacks run? | A dedicated `DispatchQueue`. **Never** the main thread — `DeviceManager` is `@MainActor` and blocking it would freeze the UI |
| How do callbacks reach the actor world? | Hop explicitly to `@MainActor` / the transport actor. IOKit callbacks are C callbacks and cannot `await` |
| Cancellation | The notification port and run-loop source must be torn down on `stopDiscovery()`, matching the existing `DeviceDiscoveryProtocol` lifecycle. A leaked `IONotificationPortCreate` reference is a real resource leak |
| Re-entrancy | Attach events can arrive faster than verification completes. A switch already in progress must make later events **coalesce**, not queue — otherwise a flap builds a backlog of doomed discovery attempts |
| `ADBTransport` is an `actor` | Verification must go through it, so attempts are already serialized. **This is a benefit of the existing design** and should be relied on rather than duplicated with a new lock |
| Existing cancellation | `DeviceManager` uses `Task.isCancelled` in its loop. The new mechanism must respect the same signal rather than adding a second shutdown path |

---

## 13. Failure cases

| # | Case | Observed event | Expected state | Transport action | Final state |
|---|---|---|---|---|---|
| 1 | Wired healthy | attach + verify passes | `wiredHealthy` | none | `wiredHealthy` |
| 2 | Physically disconnected | IOKit DETACH | `unavailable` | none | `unavailable` |
| 3 | **USB present, ADB down** | **no event** (USB never left) | `wiredDegraded` | **none** | `wiredDegraded` |
| 4 | Wireless active, USB attached | attach, verify passes | `wiredHealthy` | switch to wired | `wiredHealthy` |
| 5 | Wireless active, USB present, wired verify fails | attach, verify fails | `wirelessHealthy` | **remain wireless** | `wirelessHealthy` |
| 6 | Wired active, USB disappears | IOKit DETACH | `unavailable` | wireless if available | `unavailable` or `wirelessHealthy` |
| 7 | Wired fails, USB visible | **no event** | `wiredDegraded` | none | `wiredDegraded` |
| 8 | Both unavailable | detach + no wireless | `unavailable` | none | `unavailable` |
| 9 | Rapid attach/detach | many attach/detach | stays in prior state | debounced, coalesced | unchanged |
| 10 | Wired recovery while wireless active | attach + verify passes | `wiredHealthy` | switch | `wiredHealthy` |

**Case 3 and 7 are the ones this design exists for.** Both are **event-silent**: the USB device
never left, so IOKit fires nothing. **No USB-triggered mechanism can detect them.**

**That is a genuine limitation of approach B, and it must be stated plainly:**
`wiredDegraded` can only be discovered by attempting an operation and failing, **or** by a
low-frequency reconciliation check. It cannot be event-driven, because no event occurs.

---

## 14. Test strategy

### Unit-testable (no device, no macOS integration)

| Test | What it proves |
|---|---|
| Attach event with wrong serial → no discovery attempted | the trust boundary |
| Attach event with expected serial → candidate, **not** healthy | presence ≠ health |
| Verify: listed but `.unauthorized` → not wired healthy | `DeviceState` honoured |
| Verify: listed but transport field not `usb:` → not wired healthy | wireless is not mistaken for wired |
| Verify: listed, correct state, round-trip fails → not healthy | listing ≠ working |
| Verify: all four pass → wired healthy | the positive path |
| Failed verification does **not** trigger a retry loop | anti-hammering |
| Detach is **not** debounced | immediate loss reporting |
| Attach is debounced | anti-flapping |
| Rapid attach/detach leaves state unchanged | case 9 |
| `wiredDegraded` is reachable without any USB event | case 3/7 honesty |
| Concurrent attach events coalesce | re-entrancy |

All of the above should be pure functions over an event stream and a verification result — the same
discipline as `PixelEvidenceReader` in Phase 7 Step 2, which kept device-free logic testable.

### Requires macOS integration

| Test | Method |
|---|---|
| IOKit actually delivers attach/detach | verified once already (§3); repeat as a smoke test |
| Serial is readable from the notification | verified once already |
| Notification port tears down cleanly | instruments/leak check on `stopDiscovery()` |

### Requires a real device

Cases 1–10 above, driven physically. **Case 9 (rapid attach/detach) is the highest-value manual
test** and is the one FAIL-006 proved actually happens.

### Not testable today

Cases involving wireless (4, 5, 6-wireless, 8-wireless, 10) **cannot be tested** because wireless
ADB is not enabled on the device.

---

## 15. Exact production files that would eventually need modification

**None modified now.** For a future approved implementation:

| File | Change | Risk |
|---|---|---|
| `PixelDesktop/Transport/Transport.swift` | add `TransportState`; possibly add a transport-identity accessor to `TransportProtocol` | low — additive |
| `PixelDesktop/Transport/ADBTransport.swift` | parse and expose the `usb:` transport field currently discarded | low |
| **new** `PixelDesktop/Transport/USBPresenceMonitor.swift` | the IOKit notification wrapper | **medium — new subsystem, needs review** |
| `PixelDesktop/Device/DeviceManager.swift` | consume presence events; drive triggered (not continuous) discovery | medium — currently the only discovery owner |
| `PixelDesktop/Core/Models/AndroidDevice.swift` | possibly expose transport in the model | low |
| `PixelDesktopTests/` | the unit tests in §14 | none |

**Not needed:** any change to `WorkerOperationsProtocol`, `WorkerTransferContract`,
`WorkerInstaller`, `WorkerLifecycle`, the inference layer, or the Android worker. This is a
transport-layer concern only.

---

## 16. APIs and platform limitations

| Limitation | Detail |
|---|---|
| **IOKit is deprecated in spirit but not removed** | `IOServiceAddMatchingNotification` works on macOS 27.0 — **verified by running it**. Apple has been steering toward `IOUSBHost`, but the notification API remains functional and is the right fit for *observation* |
| **`IOUSBHost` callbacks are less suitable here** | They are designed for claiming a device. We must not claim it — FAIL-006 recorded Chrome/Brave exclusive-access contention, and opening the device would add a third competitor |
| **`system_profiler` unusable for USB on this machine** | FAIL-006: reports **no USB devices at all** while `ioreg` sees them. Must not be used |
| **The kernel can tear the port down** | FAIL-006's root cause. IOKit will faithfully report the DETACH, but **no user-space API can prevent it** |
| **Event-silent degradation** | Cases 3/7 produce **no event**. No USB mechanism can see them |
| **Wireless is not available** | `service.adb.tcp.port` unset; `adb_wifi_enabled=0`. The wireless half of the design is currently unreachable |
| **`usb:1048576X` is anomalous** | unexplained in FAIL-006. Design must not validate the full string |

---

## 17. New abstraction, or reuse?

**Reuse — with one small, justified addition.**

| Question | Answer |
|---|---|
| Does `TransportProtocol` need restructuring? | **No.** It is already device-targeted; both wired and wireless can satisfy it unchanged |
| Does a parallel transport architecture get created? | **No.** One monitor, one state enum, one verification path |
| Is a new abstraction justified? | **Yes, one: `USBPresenceMonitor`.** It wraps a platform API (IOKit) that must not leak into `DeviceManager`, and it is independently testable |
| Can the state model be reused? | **Partly.** `DeviceState` stays as its own axis; `TransportState` is additive and orthogonal |
| Where does transport selection belong? | **Not in a new layer.** `ADBTransport` is the only implementation, so there is nothing to select between yet. Selection becomes meaningful only when a wireless transport exists |

**Deliberately NOT proposed:** a `TransportManager` type. The brief sketched one, but with exactly
one transport implementation it would be a manager of one thing. **That is the ADR-013 mistake
repeating** — see the design note below.

---

## 18. Does this change any Phase 7 architectural boundary?

**No.**

| Boundary | Effect |
|---|---|
| Hermes decides / PixelDesktop enforces | **unchanged** — nothing here makes a planning decision |
| PixelDesktop publishes capability + evidence | **unchanged** — transport state is not a capability claim |
| No router, scheduler, ResourceMonitor, reservation system | **unchanged** — none is proposed |
| A snapshot is not a reservation | **unchanged** — and directly reinforced: USB presence is explicitly *not* proof of health |
| Containment (fixed paths, approved capabilities) | **unchanged** |

**This is transport resilience.** It answers *"is the connection I already have still usable?"* — not
*"where should this workload run?"* Those are different questions in different layers.

It does touch one Phase 7 principle in a way worth naming: the **`wiredDegraded`** state is the
transport-layer expression of the same discipline as ADR-007 Amendment 1 §A1.6 — *know the
difference between "capable" and "currently usable", and never let the first stand in for the
second.*

---

## 19. Recommendation

**Do not implement yet, and the reason is concrete:**

1. **The wireless leg does not exist.** Wireless ADB is off on the device. A transport-switching
   state machine would have one reachable state.
2. **The physical fault is unresolved.** FAIL-006 identified a macOS USB port teardown as the
   mechanism. **Building recovery on top of an unfixed physical fault would hide it** — the
   outcome FAIL-006 explicitly warned against, and the one this brief also forbids.
3. **The flap distribution is unmeasured.** The debounce window cannot be chosen without it. The
   1-hour observation run was paused before it produced data.

**Recommended order:**

1. **Complete the FAIL-006 physical isolation test** (cable + port swap, `pmset -c sleep 0`,
   browsers closed) and the 1-hour observation. This establishes whether the fault is hardware and
   gives the flap distribution the debounce design needs.
2. **Only then** implement `USBPresenceMonitor` + `TransportState`, which is useful **even with zero
   wireless support** — because it makes `wiredDegraded` visible, and that state is currently
   invisible to the user and to the logs.
3. **Wireless transport** is a separate, larger piece of work and should be its own decision.

**Step 2 is worth doing on its own merits**: distinguishing "the cable is unplugged" from "USB is
fine but ADB is broken" is valuable regardless of whether transport switching is ever built.

---

## Provenance

**Verified by running code:** IOKit `IOServiceAddMatchingNotification` returns `KERN_SUCCESS` for
attach and detach on macOS 27.0; `IOUSBHostDevice` matches the Pixel; `kUSBSerialNumberString`
returns `3C261JEHN25632`; no root or entitlement required. Probe deleted after use.

**Verified by source inspection:** `TransportProtocol` is device-targeted; no wireless/mDNS/TCP
handling exists; `DeviceState` models a different axis; the `usb:` field is parsed and discarded.

**Verified on the device:** `service.adb.tcp.port` unset, `adb_wifi_enabled=0`, `adb mdns check`
functional on the client side.

**Carried from FAIL-006:** the kernel port-teardown mechanism, the 24-teardown baseline, the
Chrome/Brave exclusive-access contention, the `system_profiler` limitation, the `usb:1048576X`
anomaly, and the observation that the device can vanish from `adb devices` with no kernel event.

**Proposed, not verified:** the `TransportState` model; the four-step verification; the
verification-subsumes-debounce argument; the recommended ordering.

**Unresolved:** the debounce duration; the `usb:1048576X` anomaly; whether the physical fault is
cable, port, or neither.

---

## Device and repository state

- Repository **clean** at `08c96cb` — no production source modified.
- Probe artifacts deleted; no monitor running; `pmset` unmodified.
- Device connected and healthy at the time of writing; USB present, ADB present.

---

```text
USB-AWARE TRANSPORT DESIGN COMPLETE / AWAITING REVIEW
```

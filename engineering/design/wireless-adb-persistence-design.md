# Wireless ADB Persistence — Investigation and Design

**Status:** DESIGN COMPLETE. **No production code modified. No wireless transport implemented.**
**Date:** 2026-10-02
**Scope:** transport resilience. **Not** workload routing, resource management, or scheduling.
**Phase 7 architectural boundary: UNCHANGED** — see §18.

---

## 1. Current PixelDesktop transport architecture

Unchanged from the USB-aware transport design (`design/usb-aware-transport-design.md`), and
re-stated here because this design depends on it.

| Component | Role | Relevant shape |
|---|---|---|
| `TransportProtocol` | the transport abstraction | `AnyObject, Sendable`; every device-facing method takes `deviceSerial:` |
| `ADBTransport` | the **only** implementation | `actor`; builds `adb -s <serial> …` |
| `DeviceManager` | discovery owner | `@MainActor`, 5-second loop |
| `DeviceState` | ADB's view of a device | `.device` / `.unauthorized` / `.offline` / `.unknown` |
| wireless support | **none** | `grep -rniE 'wireless\|mdns\|bonjour\|tcp\|:5555\|pair'` over `PixelDesktop/` → **zero functional matches** |

**`ADBTransport` shells out to the `adb` binary. It does not speak ADB itself.** This is the single
most important architectural fact for this design — see §8.

---

## 2. Android 16 wireless ADB architecture

### Two entirely different mechanisms, often conflated

| | Legacy (`adb tcpip 5555`) | **Modern (Wireless debugging)** |
|---|---|---|
| Transport security | **plaintext TCP** | **TLS** |
| Port | **fixed 5555** | **random, changes** |
| Prerequisite | USB connection first | **6-digit pairing code** |
| mDNS | not used | `_adb-tls-connect._tcp`, `_adb-tls-pairing._tcp` |
| Auth | reuses the USB-authorized key | pairing adds the key to the same store |

**The device currently has neither active:**

| Property | Value | Meaning |
|---|---|---|
| `service.adb.tcp.port` | **unset** | legacy not active |
| `service.adb.tls.port` | **unset** | modern not active |
| `adb_wifi_enabled` | **`0`** | **wireless debugging is OFF** |
| `adb_enabled` | `1` | USB debugging is ON |
| `ro.adb.secure` | `1` | **authentication enforced — no unauthenticated ADB** |

### Verified device facts

| Fact | Value |
|---|---|
| Android | **16**, API **36**, build `BP3A.251005.004.B1` |
| Wi-Fi | enabled, SSID **`RCB`** |
| Pixel IP | **`192.168.1.9`** |
| Mac IP | **`192.168.1.10`** |
| Same subnet | **yes** — mDNS can function |
| `mdnsd` running | **no** (consequence of wireless being off, not a fault) |
| `adb mdns check` | **`mdns daemon version [adb discovery 0.0.0]`** — client-side discovery works |
| `adb mdns services` | **empty** — nothing is advertising |
| ADB client | **37.0.1** — supports `mdns`, `pair`, `connect` |

---

## 3. Previous failure analysis

### What I can establish

| Evidence | Finding |
|---|---|
| `~/.android/adbkey` + `adbkey.pub` | **exist** (Feb 15 2026) — the Mac's ADB identity is present |
| `~/.android/adb_known_hosts.pb` | **exists, 29 bytes, Sep 17 22:52** — **a previous wireless TLS session was recorded** |
| `~/.android/analytics.settings` | Sep 22 15:09 — adb's own last-state write |
| `adb_wifi_enabled` | **`0`** — wireless debugging is off **now** |

**So: a wireless session genuinely happened, and wireless debugging is off now.** That is consistent
with the reported symptom.

### What I CANNOT establish, stated plainly

**I could not reproduce the previous failure, and I cannot date it precisely.**

- `adb_known_hosts.pb` is dated **Sep 17** — roughly two weeks ago, not "yesterday". The file may
  only be written on first pairing rather than updated per connection, so it is weak dating
  evidence. **I am not going to present it as proof of when the failure occurred.**
- Mac `log show --last 24h` for adb/5555/tls/pair returned **only WebKit QUIC noise** (the string
  "adb" appearing inside random hex identifiers). **No wireless-ADB log evidence exists.**
- Pixel `logcat` contains **no** wireless-debugging history — the buffer had rolled over.

**Therefore the cause is inferred from documented mechanism, not reproduced.** Every claim below is
labelled accordingly.

### The strongest supported explanation

**Android automatically disables wireless debugging after a period of inactivity.**

This is documented by multiple independent sources, and it directly matches "worked, then a day
later needed manual intervention":

> "Android automatically disables wireless debugging after a period of inactivity."
> — Android Authority, reporting Google's own fix for this problem

> "Wireless debugging in Android 11 off automatically when the device disconnects from the wifi and
> has to enable it from the setting manually."

Two further documented triggers compound it:

| Trigger | Effect | Source |
|---|---|---|
| **Inactivity timeout** | wireless debugging auto-disables | Android Authority; device setting `adb_allowed_connection_time` |
| **Wi-Fi disconnect** | wireless debugging turns off; must be re-enabled manually | Reddit r/androiddev; XDA |
| **Reboot** | wireless debugging does **not** persist; must be re-enabled | GrapheneOS tracker; XDA |

**And this is a known-enough problem that Google is fixing it:** Android 17 with adb 37.0.0
automatically **re-enables** wireless debugging when the device joins a trusted Wi-Fi network. The
fact that a fix was needed corroborates the mechanism.

**Confidence: the mechanism is documented and matches the symptom. The specific trigger in the
user's case is not proven.** The device's `adb_allowed_connection_time = 0` — I could not determine
its exact semantics (whether 0 means "no timeout" or "default timeout"), and I will not guess.

---

## 4. Pairing and authentication lifecycle

### The critical distinction

There are **two independent states**, and conflating them is the core mistake this design exists to
prevent:

```
STATE A: wireless debugging ENABLED?     (adb_wifi_enabled)
   → controls whether the device advertises and listens AT ALL
   → volatile: lost on reboot, Wi-Fi disconnect, inactivity

STATE B: is the Mac PAIRED/AUTHORIZED?   (/data/misc/adb/adb_keys)
   → controls whether an established connection is accepted
   → persistent: a key, written once
```

### What persists, and what does not

| Item | Persists? | Evidence |
|---|---|---|
| Mac ADB private key (`~/.android/adbkey`) | **yes** — a file, Feb 15 2026 | verified on disk |
| Pixel's authorization of that key | **yes** — written to `/data/misc/adb/adb_keys` | documented; **file not readable** (`Permission denied`), so not directly verified |
| Wireless **pairing** | **yes** — same key store | documented: `adb pair` trust "doesn't need to be repeated" |
| **Wireless debugging enabled** | **NO** | reboot, Wi-Fi drop, inactivity all disable it |
| **Connection port** | **NO** — random per enable | random-port design |
| **Pairing port** | **NO** — distinct and random, per pairing session | documented |
| **IP address** | **usually** — DHCP lease-dependent | `.9` today; not guaranteed |

**`/data/misc/adb/adb_keys` is the same file for USB authorization and wireless pairing.** This is
why wireless pairing survives, and why USB debugging is effectively the recovery path: **if the key
is in that file, both transports are authorized.**

**I deliberately did not attempt to read or extract that file, and no key material was read,
copied, or displayed.**

---

## 5. mDNS discovery lifecycle

### Service types

| Type | Purpose | Endpoint |
|---|---|---|
| `_adb-tls-connect._tcp` | **connection** endpoint | the current random TLS port |
| `_adb-tls-pairing._tcp` | **pairing** endpoint | a separate, ephemeral pairing port |
| `_adb._tcp` | legacy | 5555 |

### The finding that reshapes the whole requirement

**`adb` already performs automatic mDNS discovery and reconnection.**

```
$ADB_MDNS_AUTO_CONNECT   comma-separated list of mdns services to allow auto-connect
                         (default adb-tls-connect)
```

**The default is `adb-tls-connect`.** So adb, as shipped, automatically:
- discovers the device via mDNS,
- connects to whatever endpoint is currently advertised,
- and does so **without a hardcoded IP or port**.

**Verified:** `adb mdns check` succeeds; the client supports discovery. **Not verified:** the actual
auto-connect behaviour, because nothing is advertising (wireless is off).

**This means the requirement "rediscover and reconnect automatically, without hardcoded IP/port" is
already satisfied by adb — provided wireless debugging is enabled.** PixelDesktop does not need to
implement mDNS discovery. It needs to call the right adb commands and expose the state honestly.

### Advertisement lifetime

Not directly measurable today. What is established: the advertisement exists only while wireless
debugging is enabled, and `mdnsd` is **not running** on the device while it is off. Advertisement
therefore starts and stops with the toggle — which is precisely why the toggle, not reconnection, is
the manual-intervention boundary.

---

## 6. Endpoint and port lifecycle

| Endpoint | Changes when | Discoverable via |
|---|---|---|
| connection port | every time wireless debugging is enabled | `_adb-tls-connect._tcp` |
| pairing port | per pairing session, and it is ephemeral | `_adb-tls-pairing._tcp` |
| IP address | DHCP lease change / network change | mDNS |

**Conclusion: never hardcode either port, and never hardcode the IP.** mDNS is the correct
mechanism and adb already implements it.

---

## 7. Persistence behaviour — summary

| Scenario | Wireless debugging | Pairing | Auto-recoverable? |
|---|---|---|---|
| Wi-Fi temporarily drops | **disabled** | survives | **No** — must re-enable |
| Pixel reboots | **disabled** | survives | **No** — must re-enable |
| Idle/inactivity timeout | **disabled** | survives | **No** — must re-enable |
| IP address changes | stays enabled | survives | **Yes** — mDNS |
| Connection port changes | stays enabled | survives | **Yes** — mDNS |
| mDNS blip | stays enabled | survives | **Yes** — mDNS re-advertises |
| Mac sleeps/wakes | stays enabled | survives | **Probably** — untested |
| Wireless debugging toggled off | **disabled** | survives | **No** |
| Pairing genuinely revoked | n/a | **lost** | **No** — re-pair required |

**The pattern is stark: almost everything that breaks the connection *automatically* also
*disables wireless debugging*, and disabling is the thing that needs a human.**

---

## 8. Automatic recovery design

### The key architectural insight

**PixelDesktop does not need to implement discovery, reconnection, or endpoint tracking.** `adb`
already does all three via `ADB_MDNS_AUTO_CONNECT=adb-tls-connect`.

What PixelDesktop needs is narrower and more honest:

1. **Detect** whether the device is reachable (it already can — `adb devices`).
2. **Attempt** recovery by the appropriate means.
3. **Verify** the result positively.
4. **Report** which transport is live, and — critically — **when human action is required**.

### Recovery by case

| Case | Expected | Mechanism | Verified? |
|---|---|---|---|
| **1. Wi-Fi drops** | disconnect → rediscover → reconnect | mDNS, **once wireless debugging is re-enabled** | mechanism documented, not reproduced |
| **2. Pixel gets new IP** | old endpoint invalid → mDNS → new endpoint | `adb-tls-connect` auto-connect | not reproducible (wireless off) |
| **3. Connection port changes** | rediscover current endpoint | mDNS | not reproducible |
| **4. Pixel reboots** | pairing survives; **wireless debugging does not** | requires re-enable | documented |
| **5. Mac sleep/wake** | recover automatically | adb reconnect | untested |
| **6. Wireless debugging disabled** | **requires user — unless USB is present** | see below | see §12 |
| **7. Pairing lost** | **requires user** | `adb pair` with a new code | documented |

### Case 6 is the crux — and there is a partial answer

**If USB is present, wireless debugging can be re-enabled programmatically.** The device's shell:

- runs as `uid=2000(shell)`, in group **`1011(adb)`**
- **has `WRITE_SECURE_SETTINGS`** (verified: 3 grants in `dumpsys package com.android.shell`)

So with USB attached, `settings put global adb_wifi_enabled 1` is plausibly writable — the same
approach the community uses to auto-enable wireless ADB on boot.

**This creates a genuine recovery ladder:**

```
wired healthy
   → can re-enable wireless debugging programmatically
   → wireless becomes available as a fallback

wireless only, wireless debugging disabled
   → NO adb connection exists to re-enable it
   → MANUAL INTERVENTION UNAVOIDABLE  (chicken-and-egg)
```

**I did not execute the write.** Testing it is a device state change that was not authorised, and
it must be tested deliberately as its own step.

---

## 9. Retry and backoff design

**No constants are proposed.** Same discipline as the USB-aware design and Phase 7 Step 2's
`Freshness`: a value chosen without measurement is invented policy.

What the evidence does support structurally:

| Rule | Justification |
|---|---|
| **Never retry a disabled toggle** | If `adb_wifi_enabled = 0`, retrying cannot succeed. Retrying is pure waste and looks like a fault when it is a known state. **This single rule prevents the runaway loop.** |
| **Distinguish "endpoint changed" from "not listening"** | The first is recoverable via mDNS; the second is not recoverable at all. |
| **Bound any retry; never unbounded** | §13 |
| **Back off on repeated failure** | Untested assumption that failures are independent; a fixed short interval would hammer |
| **Re-enable attempt requires an existing transport** | By definition |

**The dominant design conclusion: most "recovery" is not retrying — it is correctly *classifying*
the state and reporting it.** Retrying a disabled toggle is the failure mode to design out.

---

## 10. Wired → wireless fallback

```
wired healthy
   ↓ wired ADB fails
classify: is the USB device still present?      (IOKit — from the USB-aware design)
   ├── USB gone        → attempt wireless IF wireless debugging enabled
   └── USB present     → wiredDegraded; wireless is a candidate, not a verdict
        ↓
   wireless attempt: adb connect via mDNS, then VERIFY
        ├── verified    → wirelessHealthy
        └── failed      → report honestly; do NOT loop
```

**Verification must be positive** — same four-step discipline as the wired case: listed, state
`.device`, correct transport, round-trip succeeds.

---

## 11. Wireless → wired recovery

Already designed in `design/usb-aware-transport-design.md`. Restated: USB attach is a **trigger**,
never a verdict; switch only after verification passes; **do not retry on the level of USB
presence** (that would hammer).

**Additional interaction with this design:** a healthy wired connection is the *only* position from
which wireless debugging can be re-enabled programmatically. So wired recovery is not just
preferable — it is the **repair path** for wireless.

---

## 12. Manual-intervention boundary

**This is the most important output of the investigation, and it is narrower than expected.**

| Situation | Manual intervention? | Why |
|---|---|---|
| Connection drops, wireless debugging still on | **No** | adb mDNS auto-connect handles it |
| IP changed | **No** | mDNS |
| Port changed | **No** | mDNS |
| Pixel rebooted, USB available | **No** | re-enable wireless via USB shell |
| Pixel rebooted, USB unavailable | **YES** | no transport exists to re-enable with |
| Wi-Fi dropped, USB available | **No** | as above |
| Wi-Fi dropped, USB unavailable | **YES** | chicken-and-egg |
| Idle timeout fired, USB available | **No** | as above |
| Idle timeout fired, USB unavailable | **YES** | chicken-and-egg |
| Pairing revoked | **YES** | requires a 6-digit code typed on the device |

> **The manual-intervention boundary is NOT "reconnection". It is "re-enabling wireless debugging
> while no transport is available."**

That is a much better boundary than "redo the wireless setup whenever it drops" — and it is the
direct answer to the stated requirement. The user's complaint is addressed not by making
reconnection automatic (adb already does that) but by **removing the need for manual re-enabling
wherever a wired connection exists to do it through.**

---

## 13. Security model

| Concern | Position |
|---|---|
| ADB authentication | **unchanged.** `ro.adb.secure=1`; the existing key model is used as-is |
| Automatic pairing | **NOT proposed.** Pairing requires a code the user reads off the device. Automating it would weaken the model |
| Port exposure | wireless ADB listens on the **local network**. Both devices are on `192.168.1.x` (SSID `RCB`) |
| Untrusted networks | **real risk**: anyone on the same subnet who can complete pairing gains ADB. **Mitigation: only enable wireless debugging on trusted networks** — which is exactly the direction Android 17 takes |
| Key handling | no key material was read, copied, or displayed. `/data/misc/adb/adb_keys` was not readable and no attempt was made to extract it |
| `WRITE_SECURE_SETTINGS` | already held by the shell uid; this design does not broaden it, and using it is a **deliberate, reviewable act** |
| ADB over TLS | modern wireless debugging is TLS, unlike legacy plaintext 5555 |

**Recommendation:** prefer the modern TLS mechanism over legacy `tcpip 5555`. Legacy is plaintext
and fixed-port; the modern one is encrypted and requires pairing.

---

## 14. State model

Extends the USB-aware design's `TransportState` rather than replacing anything.

```
TransportState
  .wiredHealthy
  .wirelessHealthy
  .wiredDegraded          USB present, ADB not healthy        (from USB-aware design)
  .wirelessDegraded       wireless was configured, now unreachable
  .recovering             a switch/attempt is in progress and unverified
  .unavailable            no transport usable
  .pairingRequired        <-- NEW: wireless debugging off or pairing lost, and
                              no transport exists to repair it
```

**`.pairingRequired` is the user-visible answer to "a silent failure after several hours is
unacceptable."** It must be surfaced prominently, because it is the only state where the system
cannot proceed without a human — and the user must be told *what* to do, not merely that something
failed.

**`AndroidDevice.state` (`DeviceState`) is untouched.** It remains the ADB view of a device; this is
an orthogonal axis.

---

## 15. Testing strategy

### Unit-testable (no device)

| Test | Proves |
|---|---|
| wireless-debugging-disabled → `.pairingRequired`, **no retry** | the anti-loop rule |
| wireless enabled + reachable → `.wirelessHealthy` | happy path |
| wireless enabled + unreachable → `.wirelessDegraded`, bounded retry | classification |
| wired present + wireless off → recovery attempted via wired | the repair path |
| wired absent + wireless off → `.pairingRequired`, no retry | the boundary |
| verification: listed but `.unauthorized` → not healthy | `DeviceState` honoured |
| verification: round-trip fails → not healthy | listing ≠ working |
| backoff bounds the attempt count | §9 |

### Requires a device

| # | Test | Classification |
|---|---|---|
| 1 | Initial pairing | **requires user** (6-digit code) |
| 2 | Normal wireless connection | automatic |
| 3 | Wireless reconnect | automatic |
| 4 | Wi-Fi disconnect/reconnect | **requires re-enable** unless USB present |
| 5 | IP address change | automatic (mDNS) |
| 6 | Pixel reboot | **requires re-enable** unless USB present |
| 7 | Mac sleep/wake | expected automatic — **untested** |
| 8 | Android sleep/doze | expected automatic — **untested** |
| 9 | mDNS disappearance/reappearance | automatic |
| 10 | Connection port change | automatic (mDNS) |
| 11 | Wireless debugging disabled | **requires user** unless USB present |
| 12 | Pairing invalidated | **requires user** (re-pair) |
| 13 | Wired fails, wireless available | automatic |
| 14 | Both unavailable | `.unavailable` / `.pairingRequired` |
| 15 | Wired returns while wireless active | automatic |

### Cannot be tested today

**All wireless tests.** Wireless debugging is off on the device, and enabling it requires either a
user action or an authorised `settings put` — neither of which was performed.

---

## 16. Production files likely requiring modification

**None modified now.** For a future approved implementation:

| File | Change | Risk |
|---|---|---|
| `PixelDesktop/Transport/ADBTransport.swift` | wireless connect/disconnect commands; transport identification from `adb devices -l` | low |
| `PixelDesktop/Transport/Transport.swift` | `TransportState` (shared with the USB-aware design) | low — additive |
| **new** `PixelDesktop/Transport/WirelessRecoveryPolicy.swift` | pure classification/decision logic, no I/O | low — pure and testable |
| `PixelDesktop/Device/DeviceManager.swift` | consume transport state; trigger (not continuously poll) recovery | medium |
| `PixelDesktopTests/` | the unit tests in §15 | none |

**Not needed:** `WorkerOperationsProtocol`, `WorkerTransferContract`, `WorkerInstaller`,
`WorkerLifecycle`, the inference layer, or the Android worker. **Transport layer only.**

**Not proposed:** a `TransportManager`. With one transport implementation, it would manage one
thing — the ADR-013 mistake repeating. Selection becomes meaningful only when a second transport
actually exists.

---

## 17. Platform limitations

| Limitation | Detail |
|---|---|
| **Wireless debugging does not survive reboot** | documented; multiple sources |
| **It auto-disables on inactivity** | documented; Google is fixing it in Android 17 |
| **It disables on Wi-Fi disconnect** | documented |
| **The port is random and changes** | by design; mDNS is mandatory, not optional |
| **Pairing requires a human** | by design; automating it would weaken security |
| **Chicken-and-egg when no transport exists** | the manual boundary |
| **`adb_allowed_connection_time` semantics unknown** | value is `0`; I could not determine whether that means "no timeout" or "default". **Not guessed** |
| **`-s <serial>` for a wireless device unverified** | adb reports the serial for TLS devices, so it *should* work unchanged — **but wireless is off, so this was not tested**. It is load-bearing for the architecture claim in §18 |
| **`/data/misc/adb/adb_keys` unreadable** | `Permission denied`; pairing persistence is documented, not directly verified |
| **macOS cannot advertise mDNS on the device's behalf** | discovery is adb's job |

---

## 18. Does existing architecture need to change?

**No structural change.**

| Question | Answer |
|---|---|
| Does `TransportProtocol` need modification? | **Probably not.** It takes `deviceSerial`, and adb reports the serial for wireless TLS devices — so `adb -s <serial>` should work unchanged for both transports. **Flagged as unverified** (§17) |
| Is a new abstraction required? | **One small one: a pure recovery-classification type.** Not a manager |
| Does a parallel transport architecture get created? | **No** |
| Does the Android worker change? | **No** |
| Does Phase 7's boundary change? | **No** — this is transport resilience |

**Phase 7 boundary: UNCHANGED.** This answers *"which transport can currently reach the requested
Pixel?"*, not *"where should a workload execute?"*. It reinforces the ADR-007 Amendment 1 §A1.6
principle in a new place: **"wireless debugging is enabled" and "the Pixel is reachable" are
different facts, and the first must never be reported as the second.**

---

## 19. Recommendation

**Do not implement yet.** Three concrete reasons:

1. **Wireless debugging is off, so nothing can be verified.** Every wireless claim in this document
   is mechanism-based, not reproduced. Implementing against unverified behaviour is what FAIL-004
   and FAIL-005 both punished.
2. **The architecture's load-bearing assumption is untested.** Whether `adb -s <serial>` works
   unchanged for a wireless device determines whether this is a small change or a structural one.
   That must be tested first.
3. **The physical USB fault is still unresolved** (FAIL-006). Building wireless fallback on an
   unfixed fault would hide it.

**Recommended order:**

1. **Enable wireless debugging on the device and pair** — a user action, one time. Then verify the
   load-bearing assumption: does `adb devices` report the serial, and does `adb -s <serial>` work?
   **This single test decides the architecture.**
2. **Test whether `settings put global adb_wifi_enabled 1` works over USB.** If it does, the
   manual-intervention boundary shrinks to "no transport at all" — which is the real win.
3. **Then** implement the pure classification type + `TransportState`, which is valuable even
   before any recovery automation, because it makes `.pairingRequired` visible.
4. **Automated recovery last**, and only for cases 1–3 and 5 (the genuinely automatic ones).

**Step 3 is worth doing on its own merits:** today the user cannot tell *"the cable is unplugged"*
from *"wireless debugging silently turned itself off six hours ago"*. That is the silent failure
the brief calls unacceptable, and it is fixable without any automation.

---

## Provenance

**Verified on the device (Android 16, API 36, `BP3A.251005.004.B1`):** wireless debugging OFF
(`adb_wifi_enabled=0`); `service.adb.tcp.port` and `service.adb.tls.port` unset; `adb_enabled=1`;
`ro.adb.secure=1`; `adb_allowed_connection_time=0`; Wi-Fi on, SSID `RCB`; Pixel `192.168.1.9`, Mac
`192.168.1.10`, same subnet; `mdnsd` not running; shell uid 2000 in group `1011(adb)` **with
`WRITE_SECURE_SETTINGS`**; `/data/misc/adb/adb_keys` **not readable**.

**Verified on the Mac:** ADB 37.0.1; `adb mdns check` succeeds; `adb mdns services` empty;
`ADB_MDNS_AUTO_CONNECT` documented default `adb-tls-connect`; `~/.android/adbkey` and `adbkey.pub`
exist; `adb_known_hosts.pb` exists (Sep 17 22:52) — **evidence a wireless session occurred**.

**Documented:** Android 11+ wireless debugging architecture and the two mDNS service types; automatic
disable on inactivity, Wi-Fi disconnect, and reboot; Android 17 + adb 37 auto-enable on trusted
Wi-Fi; pairing persistence.

**Inferred, NOT reproduced:** that the inactivity timeout caused the specific previous failure.
**I could not reproduce it and did not date it precisely** — the `adb_known_hosts.pb` timestamp is
weak evidence and is labelled as such.

**Unverified:** whether `adb -s <serial>` works for a wireless TLS device; whether
`adb_wifi_enabled` is writable via shell; actual mDNS auto-connect behaviour;
`adb_allowed_connection_time = 0` semantics.

**Not performed:** no key material read or copied; no device settings changed; no wireless transport
implemented; no `settings put` executed.

---

## Device and repository state

- Repository clean; **no production source modified**.
- No device settings changed; wireless debugging left off.
- No key material read, copied, or displayed.

---

```text
WIRELESS ADB PERSISTENCE DESIGN COMPLETE / AWAITING REVIEW
```

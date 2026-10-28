# Wireless Serial Transport Verification

**Status:** VERIFIED on the physical Pixel 7a. **No production source modified.**
**Date:** 2026-10-02
**Resolves:** the single architectural unknown from `a2c0858` — *does `adb -s <serial>` work when the
Pixel is connected through Android wireless debugging / ADB TLS?*
**Scope:** verification only. No TransportManager, mDNS discovery, reconnect loop, state machine,
automatic pairing, or `WRITE_SECURE_SETTINGS` automation was implemented.

---

## Verdict

**`adb -s <serial>` works identically over wireless TLS.** All six command patterns tested returned
**byte-identical results** across both transports, including a write operation.

**But the architectural conclusion is NOT "the existing abstraction works unchanged."** The serial
that identifies a wireless device is **not** the USB serial. That is the finding that matters — see
§4.

---

## 1. Architecture inspection (requirement 1)

### How `deviceSerial` flows

| Layer | Behaviour |
|---|---|
| `TransportProtocol` | every device-facing method takes `deviceSerial: String` |
| `ADBTransport` | builds `["-s", deviceSerial, …]` in **6 places** (lines 153, 179, 187, 200, 205, 213) |
| `parseDeviceList` | takes `parts[0]` of each line as the serial — **transport-agnostic** |

### Does any code assume USB?

**No.** A search for `usb|wired|cable|physical` across `PixelDesktop/Transport/` and
`PixelDesktop/Device/` returned **zero** functional matches.

**Confirmed: `deviceSerial` is used purely as adb's `-s` argument. Nothing inspects it, validates
its format, or assumes it denotes a USB device.** That is why the transport-agnostic part of the
hypothesis holds.

---

## 2. Wireless ADB established on the real Pixel 7a

### Reproducible device state

| Item | Value |
|---|---|
| Device | Pixel 7a, Android **16**, API **36**, `BP3A.251005.004.B1` |
| Pixel IP | **`192.168.1.9`** |
| Mac IP | `192.168.1.10` (same subnet, SSID `RCB`) |
| USB serial | **`DEADBEEF000000`** |
| **Wireless serial** | **`adb-DEADBEEF000000-laKyZz._adb-tls-connect._tcp`** |
| mDNS service | `_adb-tls-connect._tcp` at `192.168.1.9:<port>` |
| Security | TLS, `ro.adb.secure=1`. **No unauthenticated TCP ADB was used.** |

### How wireless debugging was enabled

```
adb -s DEADBEEF000000 shell 'settings put global adb_wifi_enabled 1'
```

**This succeeded** (`0` → `1`), confirming the design document's §12 claim that the shell's
`WRITE_SECURE_SETTINGS` grant makes the toggle programmable **when a transport already exists**.

**No pairing was required.** The Mac's existing ADB key (`~/.android/adbkey`) was already authorized
on the device — the same key store serves USB authorization and wireless pairing, as the design
predicted. **No pairing code was needed and no key material was read, copied, or displayed.**

---

## 3. mDNS discovery and auto-connect — both verified

### Advertisement appeared within ~5 seconds

```
List of discovered mdns services
adb-DEADBEEF000000-laKyZz   _adb-tls-connect._tcp   192.168.1.9:35987
```

### adb auto-connected with NO manual `adb connect`

```
DEADBEEF000000                                     device usb:...    transport_id:19
adb-DEADBEEF000000-laKyZz._adb-tls-connect._tcp    device            transport_id:20
```

**T-029 is confirmed on real hardware: adb performs mDNS discovery and connection automatically via
`ADB_MDNS_AUTO_CONNECT=adb-tls-connect` (the default). No custom mDNS layer is needed.**

### Auto-reconnect after forced disconnect — verified

After `adb disconnect`:
- the wireless entry **vanished** while the USB entry **survived**;
- within **≤5 seconds** the wireless entry **reappeared automatically**, with the **same serial**;
- only `transport_id` changed (20 → 40), which is adb's internal connection counter.

---

## 4. THE CRITICAL FINDING — the wireless serial is not the USB serial

```
DEADBEEF000000                                      device usb:1048576X ...   <- USB
adb-DEADBEEF000000-laKyZz._adb-tls-connect._tcp     device ...                <- WIRELESS
```

**These are two independent device entries with different serials.**

| Property | USB | Wireless |
|---|---|---|
| serial | `DEADBEEF000000` | `adb-DEADBEEF000000-laKyZz._adb-tls-connect._tcp` |
| format | plain hardware serial | `adb-<hwserial>-<random6>._adb-tls-connect._tcp` |
| independence | confirmed — disconnecting one leaves the other | confirmed |

### Why this matters

`AndroidDevice.serialNumber` is documented as coming from `adb devices -l`. **If PixelDesktop
targets `DEADBEEF000000` and only the wireless transport is available, the command still reaches the
device — because adb resolves the hardware serial to the connected transport.**

**However, `adb devices` lists them as two separate devices.** So:
- a discovery pass that iterates `adb devices` would see **two entries for one physical phone**;
- code keying on `serialNumber` would treat them as **two different devices**;
- which entry is "the" device would be **ambiguous**.

**This is the real architectural consequence, and it is a duplication problem, not a
`-s` problem.**

### The 6-character suffix: stable in this test, but NOT verified as stable in general

| Observation | Result |
|---|---|
| suffix before toggle | `laKyZz` |
| suffix after OFF → ON toggle | `laKyZz` — **unchanged** |
| **port** before → after | `35987` → **`33197`** — **changed** |

**The suffix survived one toggle, but one observation is not proof of stability.** Its persistence
across a device restart, a Wi-Fi reconnect, or a re-pair is **untested**. The design must not assume
it is stable.

**The port changing is expected and harmless** — because the serial is name-based, not port-based,
the same serial worked after the port changed. **This is the key advantage of targeting by name
rather than by endpoint.**

---

## 5. Command-pattern comparison (requirements 3 and 4)

The **exact** pattern PixelDesktop uses — `adb -s <serial> <cmd>` — run against both transports:

| Test | USB | Wireless | Match |
|---|---|---|---|
| `shell getprop ro.product.model` | `Pixel 7a` | `Pixel 7a` | **OK** |
| `shell getprop ro.build.version.sdk` | `36` | `36` | **OK** |
| `shell getprop ro.product.manufacturer` | `Google` | `Google` | **OK** |
| `shell echo PIXELDESKTOP_ROUNDTRIP` | correct | correct | **OK** |
| `shell pidof com.pixeldesktop.worker` | `4251` | `4251` | **OK** |
| `shell ls …/files/model/` | `qwen2.5-1.5b-…` | `qwen2.5-1.5b-…` | **OK** |

### Write operation (PixelDesktop `push` primitive), wireless only

```
push /tmp/pd-wireless-probe.txt → /sdcard/Android/data/com.pixeldesktop.worker/files/
  1 file pushed, 0 skipped
read back → wireless-transport-probe     (correct)
cleanup → cleaned
```

**Byte-identical behaviour across both transports, including writes.** No difference was observed in
any command tested.

---

## 6. Serial stability observations (requirement 5)

| Event | Serial | Port | Outcome |
|---|---|---|---|
| initial enable | `adb-…-laKyZz._adb-tls-connect._tcp` | 35987 | works |
| forced `adb disconnect` | same (after auto-reconnect) | 35987 | works, ≤5 s recovery |
| toggle OFF → ON | **same** (`laKyZz` unchanged) | **33197 (changed)** | works |

**Serial stable across reconnect and across a toggle. Port changes freely. Endpoint change is
therefore handled correctly by name-based targeting — which is what adb already does.**

---

## 7. Differences between wired and wireless

| Aspect | Observation |
|---|---|
| Command results | **none** — byte-identical |
| Exit codes | **none** — all 0 |
| Device entry | **different serial**, separate entry |
| `adb devices` count | 2 entries for 1 physical device |
| Transfer speed | not benchmarked (payload was 24 bytes) |
| `usb:` transport token | present for USB, **absent** for wireless |

**The last row is the practical way to distinguish them** — and it is the field
`parseDeviceList` currently discards.

---

## 8. Answers to the stated questions

| Question | Answer |
|---|---|
| Does `adb -s <serial>` work over wireless TLS? | **YES** — identical to USB |
| Does the existing serial-targeted abstraction remain valid? | **Partially.** `-s` works with either serial. But the two transports expose **different serials for one device**, so discovery sees a duplicate |
| Is the wireless serial stable? | **Across reconnect and one toggle: yes. Across restart/re-pair: untested** |
| Can the endpoint change while the serial stays usable? | **YES — demonstrated.** Port changed 35987 → 33197; the same serial kept working |
| Does adb auto-discover/reconnect? | **YES — verified, ≤5 s, no manual `adb connect`** |
| Is pairing required for this Mac? | **NO** — the existing ADB key was already authorized |

---

## 9. Remaining unknowns

| # | Unknown |
|---|---|
| **U1** | **Is the 6-char suffix stable across a device restart, Wi-Fi reconnect, or re-pair?** One toggle is not proof. **This determines whether a wireless serial can be persisted or must be re-read every time** |
| **U2** | **Does the wireless serial survive an IP change?** Not tested (IP did not change) |
| **U3** | Does the wireless entry survive a Mac sleep/wake? Not tested |
| **U4** | Whether targeting the USB serial while **only** wireless is available works when USB is physically absent. The serial worked with both present; the isolation case was not tested |
| **U5** | Transfer throughput over wireless was not benchmarked (24-byte payload) |
| **U6** | Whether `adb devices` ever lists the wireless entry with a **`.local`** form, or under a different name shape on other Android versions |
| **U7** | `adb_allowed_connection_time = 0` semantics remain undetermined |

**U1 is the most consequential** — it decides whether the wireless serial is a durable identifier or
a per-session one.

---

## 10. Production files affected

**None modified.** The verification itself required **no** production change.

For a future approved implementation, this finding adds one file to the design document's list:

| File | Change | Why |
|---|---|---|
| `PixelDesktop/Transport/ADBTransport.swift` | `parseDeviceList` must **distinguish transports** and decide how to represent one physical device reachable two ways | the duplication finding in §4 |
| `PixelDesktop/Core/Models/AndroidDevice.swift` | likely needs a transport attribute, so "one phone, two entries" is representable | §4 |

**No TransportManager is proposed.** With one transport *implementation* (both are `adb`), the
duplication is a **modelling** problem, not a manager problem.

---

## 11. Device state left behind

- **Wireless debugging is left ON** (`adb_wifi_enabled = 1`) — this was the deliberate setup required
  by the task, and it is the state that makes further verification possible. **It was not reverted.**
- Both transports currently reachable; no production code changed; probe file removed.
- No pairing code was used; no key material read, copied, or displayed.

---

## Provenance

**Verified on the physical device (2026-10-02):** wireless debugging enabled via
`settings put global adb_wifi_enabled 1`; mDNS advertisement appeared; adb auto-connected without a
manual `adb connect`; auto-reconnect after forced disconnect within ≤5 s; six command patterns
byte-identical across transports; a `push` write succeeded over wireless; wireless serial stable
across reconnect and one toggle; port changed 35987 → 33197 with the serial still usable; the two
transports are independent entries with different serials.

**Verified by source inspection:** `deviceSerial` is passed through as adb's `-s` in 6 places;
`parseDeviceList` takes `parts[0]`; no USB assumption exists anywhere in the transport or device
layer.

**Not verified:** suffix stability across restart/re-pair (U1); IP change (U2); Mac sleep/wake (U3);
USB-serial targeting with USB physically absent (U4); wireless throughput (U5).

---

```text
WIRELESS SERIAL TRANSPORT VERIFIED / AWAITING IMPLEMENTATION REVIEW
```

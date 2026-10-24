# ADR-017: Wireless Transport Persistence

**Status:** Accepted for Option C (implemented and verified §9). Option B **not adopted** —
its motivating premise is unobserved on this device (§2); the §5 capability probe is superseded
by §5.2.
**Date:** 2026-10-24
**Supersedes:** ADR-002 §Decision ("ADB only for Phase 1") — see §1
**Relates to:** `docs/PROPOSAL-REMOTE-STORAGE.md`, `engineering/design/wireless-adb-persistence-design.md`,
`engineering/design/usb-aware-transport-design.md`, FAIL-006

**Owner decisions recorded 2026-10-24:**
1. Fund Option C — **yes**.
2. Run the §5 go/no-go probe — **yes at the time**, gated on explicit confirmation (§5.1).
   **Superseded 2026-10-24 (§5.2):** the probe's motivating premise is unobserved, so the
   capability question it answers is no longer the gate. Not run; not recommended.
3. Requirement is **both** LAN persistence and internet-wide access, with internet-wide
   preferred. This makes §3 Option B's requirement-mismatch finding load-bearing: internet-wide
   access is a **tunnel** decision, not a bridge decision, and is tracked separately (§9).

---

## 1. Context

ADR-002 chose ADB-only transport and recorded two *Future Reconsideration Conditions*:

> - When wireless operation is required, add wireless ADB fallback
> - When transport switching is needed, add transport abstraction layer

**Both conditions have fired.** Wireless transport now exists in the code:

| Artifact | What it does |
|---|---|
| `PixelDesktop/Device/TransportState.swift` | `TransportMode` (`.wired`/`.wireless`), `TransportSelector` (wired-priority selection), `WirelessEndpoint` (parses a reconnectable `host:port` out of any wireless serial form) |
| `PixelDesktop/Device/ConnectionManager.swift` | `connect(host:port:)`, `runReconnectSequence` (bounded attempts + backoff), `beginReconnectIfNeeded`, endpoint persistence (`persist`/`loadPersistedState`) |
| `PixelDesktop/Transport/ADBTransport.swift` | `connect(host:port:)` over `adb connect`, interpreting its unreliable exit codes |
| `PixelDesktop/Transport/NetworkPathMonitor.swift` | WiFi path changes trigger reconnect |

**Governance gap, recorded as a finding:** this was implemented under
`docs/PROPOSAL-REMOTE-STORAGE.md` (a proposal) with **no ADR**. ADR-002 is still the last
*recorded* transport decision, and it says the opposite of what the code does. Anyone reading
`engineering/decisions/` alone would conclude wireless transport was rejected. This ADR closes
that gap.

### 1.1 Verified live, 2026-10-24 (Android 16, Pixel 7a, `lynx`)

```
$ adb devices -l
3C261JEHN25632                                  device usb:17825792X product:lynx model:Pixel_7a device:lynx transport_id:4
192.168.1.7:5555                                device product:lynx model:Pixel_7a device:lynx transport_id:5
adb-3C261JEHN25632-laKyZz._adb-tls-connect._tcp device product:lynx model:Pixel_7a device:lynx transport_id:3

$ adb -s 192.168.1.7:5555 shell getprop ro.product.model
Pixel 7a
$ adb -s 192.168.1.7:5555 shell getprop ro.product.cpu.abi
arm64-v8a

$ adb -s 3C261JEHN25632 shell getprop service.adb.tcp.port
5555
$ adb -s 3C261JEHN25632 shell settings get global adb_wifi_enabled
1
$ adb -s 3C261JEHN25632 shell settings get global development_settings_enabled
1
```

Three facts this establishes, each of which contradicts a premise in the earlier design docs:

1. **Wireless debugging is ON and reachable.** `wireless-adb-persistence-design.md` §19 reason 1
   ("Wireless debugging is off, so nothing can be verified") is **no longer true**.
2. **The load-bearing assumption is now verified.** That document §18 flagged *"whether
   `adb -s <serial>` works for a wireless TLS device"* as the single test that decides the
   architecture. It works — `adb -s 192.168.1.7:5555` answers normally.
3. **The physical fault is closed.** FAIL-006 is `COMPLETE` (root cause identified). Both design
   docs' shared blocker #3 ("building recovery on an unfixed fault would hide it") is **moot**.

The prior recommendation — *"Do not implement yet"* — was correct when written and is now stale.
It is not evidence against proceeding; it is evidence that the world moved.

**Status update, later on 2026-10-24 — §1.1 is a point-in-time capability recording, not a
standing claim.** Re-verified the same day: `adb_wifi_enabled` now reads **`0`**, and
`192.168.1.7:5555` is **`offline`** — `adb connect` times out. Wireless ADB is presently **off**;
USB is the working transport. This does not invalidate §1.1 (the wireless code path and
`adb -s <wireless>` addressing were proven functional) — it means the *setting* has since been
turned off. **Do not cite §1.1 as evidence that wireless is currently reachable.**

---

## 2. Problem

**The failure mode this ADR was written to solve has not been observed on this device.**

The prior design docs (`wireless-adb-persistence-design.md` §2, §5, §7) assert that Android
disables Wireless Debugging on inactivity timeout, Wi-Fi disconnect, and reboot. That assertion
is the entire justification for Option B. It does not reproduce — measured 2026-10-24 15:34 PST:

| Check | Reading |
|---|---|
| `settings get global adb_wifi_enabled` | `1` |
| `settings get global wifi_sleep_policy` | **`2`** — `WIFI_SLEEP_POLICY_NEVER` |
| `dumpsys battery` | `AC powered: true`, `level: 100` — charging |
| `dumpsys power` | `mWakefulness=Dozing` |
| `adb -s 192.168.1.7:5555 shell 'echo ALIVE'` while dozing | `ALIVE` |
| same, after `input keyevent KEYCODE_SLEEP` | still `ALIVE` |
| `netstat -tlnp` | `[::]:5555 LISTEN` |
| `dumpsys adb` | `connected_to_adb=true`, paired key for this Mac |

Wireless ADB survives a forced sleep. The reason is **configuration, not Android's default
behaviour**: `wifi_sleep_policy=2` keeps the radio up, and the phone is charging. A device on
the default policy and unplugged may behave differently — that configuration was **not** tested
here. And the owner **cannot name an observed instance of the failure** (confirmed 2026-10-24).

**What is actually broken is not the transport — it is the diagnosis.** §1.1 already records
that wireless debugging is on and reachable. The defect that remains real and user-facing is
that the UI collapsed every offline cause into "Offline": the user could not distinguish
"cable unplugged" from "wireless debugging turned itself off". That defect is independent of
*which* cause occurred, and it is what Option C fixes.

**Consequence for Option B:** its motivating premise is unobserved. The §5 probe tests whether a
Termux daemon *can* re-enable wireless debugging (P1–P3). Answering that is no longer the right
gate — the gate is **demonstrating the failure first**. Option B is therefore blocked on an
unobserved problem, not on capability. See §5.2.

> **What restores the connection unattended, after Android has disabled Wireless Debugging?**
>
> Still the right *shape* of question — but its premise must be demonstrated before it is
> funded. Until an instance is captured, it is a hypothetical.

---

## 3. Options Considered

### Option A: Mac-side reconnect only (status quo)

Keep `ConnectionManager.runReconnectSequence` as the recovery mechanism.

**Rejected.** It can only re-dial an endpoint that is *listening*. It cannot re-enable a radio
Android has turned off, so it fails exactly when it is needed — the failure is silent and the
user sees "offline" with no actionable cause. `PROPOSAL-REMOTE-STORAGE.md` line 32 already
records this: *"Wireless transport | ⚠️ Partial | Discovery works, persistent connection does
not."*

### Option B: Phone-side daemon — outbound WebSocket + local bridge

A daemon on the phone (Termux) holds `termux-wake-lock`, connects **outbound** `wss://` to a
Mac-side server on a fixed port, re-enables the adbd TCP port at boot, and reconnects with
exponential backoff. The Mac runs one local TCP bridge per device.

**Not adopted.** Its motivating premise — Android disables Wireless Debugging — does not
reproduce on this device (§2), so the §5 capability probe is no longer the right gate (§5.2).
Recorded here rather than deleted because the mechanism analysis is still correct and would be
the starting point **if** an instance is ever captured.

What it genuinely buys, and what nothing else can:

- **App-controlled heartbeat.** Android's inactivity timeout is a *radio* timeout; a daemon that
  keeps the port alive and re-enables it on boot addresses the cause, not the symptom.
- **Outbound-only from the phone.** No inbound firewall rule on the phone side, which is the
  right posture for a device that moves between networks.
- **Boot re-enable**, the one recovery path that needs an agent on the phone.

What it costs, stated plainly:

- **It is a third-party dependency on the phone.** `Termux` is **not installed** — verified:
  `adb shell pm list packages | grep termux` returns nothing. The Mac side stays dependency-free;
  the phone side does not.
- **A second transport, in parallel with wireless ADB.** Both prior design docs explicitly
  rejected this: *"Does a parallel transport architecture get created? **No**"*
  (`wireless-adb-persistence-design.md` §18, `usb-aware-transport-design.md` §17). This ADR is
  the place to accept or reject that, consciously.
- **The requirement may exceed the mechanism.** `PROPOSAL-REMOTE-STORAGE.md` line 14 states the
  goal as *"access Pixel 7a files from anywhere on the internet"*. A LAN WebSocket bridge does
  **not** provide that; it provides LAN reachability with better persistence. Internet-wide
  access requires a tunnel (Tailscale or similar) — a third-party dependency, and a different
  decision. **These are two different requirements and must not be conflated.**

### Option C: Accept manual recovery; make the failure visible and actionable

Do not build phone-side automation. Instead, surface *why* the connection is down
(`TransportState` already distinguishes `.wired`/`.wireless`; add `.pairingRequired` /
`.wirelessDisabled`), and instruct the user to re-enable Wireless Debugging or plug in USB.

**Accepted as the baseline, independent of B — and now the *only* adopted option.** This is the recommendation
`wireless-adb-persistence-design.md` §19 step 3 made on its own merits: *"today the user cannot
tell 'the cable is unplugged' from 'wireless debugging silently turned itself off six hours
ago'"*. That remains true and remains worth fixing with **zero** phone-side dependency.

---

## 4. Decision

**Proposed:**

1. **Adopt Option C immediately** — no device dependency, no new transport, closes the
   *visible-vs-invisible failure* gap that is the actual user-facing defect.
2. **Do not adopt Option B.** Its motivating premise — Android disables Wireless Debugging — is
   **unobserved** on this device (§2). The §5 capability probe is therefore the wrong gate and is
   superseded by §5.2. B is blocked on an unobserved problem, not on capability.
3. **Record that wireless transport is accepted** and that ADR-002's "ADB only" decision is
   superseded by this ADR — closing the §1 governance gap.

### 4.1 Why `TransportProtocol` needs no change (premise verified)

The proposal states the change *"needs to go through `TransportProtocol` rather than raw sockets,
or the testability seam breaks."* **Verified, and stronger than stated:** the seam already
supports both transports unchanged.

`PixelDesktop/Transport/Transport.swift:3` — `protocol TransportProtocol: AnyObject, Sendable`
— is **device-targeted, not transport-targeted**: every method takes `deviceSerial:`. A wireless
serial (`host:port`, or the mDNS form) is just a string `adb -s` accepts. Both
`usb-aware-transport-design.md` §17 and `wireless-adb-persistence-design.md` §18 reached the
same conclusion independently.

**Consequence:** whichever option is chosen, the seam is untouched. Any new transport must be a
new `TransportProtocol` conformance, never a raw socket in a caller.

---

## 5. Go/No-Go Probe — Phase 0 (**superseded by §5.2 — not the gate**)

Three premises of Option B are unverified. Each has one command that settles it. **Do not
implement against unverified behaviour** — FAIL-004 and FAIL-005 both punished exactly that.

| # | Premise | Probe | Pass criterion |
|---|---|---|---|
| P1 | A Termux app uid can hold `WRITE_SECURE_SETTINGS` | `adb shell pm grant com.termux android.permission.WRITE_SECURE_SETTINGS` then `adb -s <serial> shell run-as`/`am` check | grant succeeds **and** the app uid can read back `settings get global adb_wifi_enabled` |
| P2 | `settings put global adb_wifi_enabled 1` works from a **non-shell** uid | With Termux granted, disable then re-enable from the app uid | setting reads back `1` without a shell uid |
| P3 | A Termux daemon can run at boot on Android 16 | Install Termux, register a `BOOT_COMPLETED` receiver, reboot the device | receiver fires; log line present after boot |

**Decision criterion:** if **P1 or P2 fails**, Option B is **not viable without root** — the
device is `ro.debuggable=0` and unrooted (`Transport.swift:23`), so there is no escalation path.
Fall back to Option C and record B as blocked-on-capability. If **P3 fails**, B is viable only
while the app is in the foreground — record that limit explicitly rather than implying
unattended recovery.

*(The decision criterion below is retained for the record; §5.2 explains why this probe is no
longer the gate.)*

**Also required before B:** resolve the requirement mismatch in §3 Option B. If the goal is
internet-wide access, B is the wrong mechanism and the decision is a tunnel decision, not a
bridge decision.

### 5.1 Probe results so far, and what remains gated *(historical — superseded by §5.2)*

**Settled without touching the device** (from the published manifests, 2026-10-24):

| Premise | Result | Evidence |
|---|---|---|
| P1 — a Termux app uid *can* hold `WRITE_SECURE_SETTINGS` | **plausible** | `termux-app` `app/src/main/AndroidManifest.xml` declares `android.permission.WRITE_SECURE_SETTINGS`, so `pm grant` is possible |
| P3 — a daemon can run at boot | **plausible** | `termux-boot` declares `RECEIVE_BOOT_COMPLETED` with a `BootReceiver` for `android.intent.action.BOOT_COMPLETED` |

**Still gated on explicit confirmation**, because each changes the phone:

- **P1/P2 confirmation** requires installing Termux (not currently installed — verified:
  `adb shell pm list packages` returns no match) and running
  `adb shell pm grant com.termux android.permission.WRITE_SECURE_SETTINGS`.
- **P3 confirmation** requires a device reboot, which interrupts whatever the phone is doing.

Neither has been run. **No device settings were changed and no app was installed** in producing
this ADR or implementing Option C.

### 5.2 Superseded: the probe is the wrong gate (2026-10-24)

§5 framed the probe as the gate for Option B. That framing assumed the motivating premise —
Android disables Wireless Debugging — was true and merely needed a mechanism. §2 shows it is
**unobserved**.

The probe's premises (P1–P3) ask whether a Termux daemon *can* re-enable wireless debugging.
That is a real question, but it is now the **second** question, not the first:

1. **First: demonstrate the failure.** Capture an instance where wireless ADB drops while the
   phone is on the default WiFi sleep policy and not charging. §2's readings show the current
   configuration does not produce it.
2. **Then:** decide whether the §5 mechanism is worth its cost.

Running P1–P3 now would answer a *capability* question while the *need* is undemonstrated, and
would require installing a third-party app plus a device reboot to do it. **Not run. Not
recommended.** Option B is recorded as **blocked-on-unobserved-problem**, not
blocked-on-capability.

---

## 6. Reasoning

- **The seam is not the risk.** `TransportProtocol` is device-targeted and already serves both
  transports (§4.1). The real risk is a second, parallel transport — which is why this needs an
  ADR and not a pull request.
- **The visible defect is not the transport, it is the diagnosis.** The user cannot distinguish
  "cable unplugged" from "wireless silently disabled". That is fixable now, with no device
  dependency, and it is the cheapest real improvement available.
- **Premise drift is the failure mode to avoid.** Two design docs concluded "do not implement"
  on three blockers; all three are now resolved or moot (§1.1). Re-deriving the decision from
  the *current* device state, rather than from those documents, is what makes this ADR worth
  writing.
- **Do not build a bridge to solve a tunnel problem.** LAN persistence and internet-wide access
  are different requirements with different costs (§3 Option B).

---

## 7. Consequences

- ADR-002's *"ADB only for Phase 1"* is superseded; wireless transport is accepted and its
  persistence behaviour is now a recorded decision.
- The governance gap in §1 is closed: the transport decision and the code now agree.
- If Option B is later adopted, it is a **second `TransportProtocol` conformance** and a
  **second recovery path** — both must be covered by the existing test seams
  (`MockTransport`, `SuspendingTransport`, `RunTransport` in `PixelDesktopTests/`), not by new
  ad-hoc harnesses.
- Option C is additive and orthogonal: it changes no transport, so it cannot regress A or B.

---

## 8. Future Reconsideration Conditions

- **If an instance of wireless ADB dropping is captured** (§2, §5.2), re-run the §5 probe — the
  capability question becomes load-bearing only once the need is demonstrated.
- If the device is ever rooted, P1/P2 become unnecessary and Option B's cost drops sharply.
- **If the phone is used on the default WiFi sleep policy, unplugged** — the configuration §2
  identified as untested — measure whether the failure appears. This is the cheapest remaining
  test of the motivating premise and needs no new software.
- If internet-wide access is required, revisit §3 Option B: the decision becomes a tunnel
  decision (Tailscale or similar), which is a third-party dependency and a separate ADR.
- If Android 17+ auto-enable on trusted Wi-Fi ships on this device (documented in
  `wireless-adb-persistence-design.md` §2), the inactivity-timeout problem may shrink on its own
  — re-measure before funding B.

---

## 9. Implementation Record — Option C (2026-10-24)

**Status: implemented and verified.**

| Artifact | Change |
|---|---|
| `PixelDesktop/Device/TransportDiagnosis.swift` | **New.** `TransportCause` (4 causes), `TransportDiagnosis`, `TransportDiagnosisContext`, and the pure `TransportDiagnoser.classify`. No IOKit, no `adb`, no `UserDefaults` — the whole decision table is unit-testable without a device. |
| `PixelDesktop/Device/DeviceManager.swift` | Publishes `diagnosis: TransportDiagnosis?`; `updateDiagnosis(listingError:)` recomputes after **every** listing attempt, successful or not. |
| `PixelDesktop/App/AppState.swift` | Mirrors `diagnosis`; also mirrors `transportState` directly in `refreshDevices()`. |
| `PixelDesktop/StorageUI/StorageBrowserView.swift` | Status bar shows the diagnosed summary plus an actionable next step; renders "Checking…" before the first pass rather than a premature "Offline". |
| `PixelDesktopTests/ConnectionFoundationTests.swift` | 16 new tests pinning the classification order and the integration path. |

**Verification:**

| Check | Result |
|---|---|
| `xcodebuild test -scheme PixelDesktop -destination 'platform=macOS'` | **609 tests, 22 skipped, 0 failures** |
| `-only-testing:PixelDesktopTests/TransportDiagnosisTests` | **16 tests, 0 failures** |
| `xcodebuild build -scheme pixel-desktop` (compiles `Device/`) | **BUILD SUCCEEDED** |
| CLI run: `pixel-desktop capability --json` | contract v3 emitted, with limitation annotations |
| CLI run: `pixel-desktop observe --json` | live observation — `deviceReachable: true`, `deviceSerial: 3C261JEHN25632` |

The CLI target is the one that links `Device/` (46-file sources phase, including
`TransportDiagnosis.swift`), so building and running it proves the new file **links into a
shipping binary and the binary executes** — not merely that it type-checks in isolation.

**Scope limit, corrected.** An earlier version of this section claimed `observe` "confirms the
change did not disturb the transport path it sits beside". That was **overstated**. `observe`
calls `PixelEvidenceReader` over a bare `ADBTransport()` (`PixelDesktopCLI/main.swift:45`) — it
never instantiates `ConnectionManager` or `DeviceManager`. `TransportDiagnoser.classify` has
exactly **three** call sites, all in `DeviceManager.updateDiagnosis`, and `ADBTransport` has
**zero** references to `TransportDiagnosis`. So `observe` exercising `ADBTransport` proves that
transport still works; it does **not** exercise the Option C classification path, which is
covered solely by the 16 `TransportDiagnosisTests`. No device settings changed; no device
dependency added.

### 9.1 Two defects found and fixed while implementing

1. **`MockTransport` cannot express a failed listing.** Its `listDevices` returns the canned array
   and never throws, so the `adbUnavailable` cause was untestable through the shared mock. A
   dedicated `ListingFailureTransport` double was added rather than a flag on the shared mock —
   a failed listing is a genuinely different cause from an empty one, and the shared mock is used
   by many suites.
2. **`AppState` mirrored `transportState` only eventually.** `refreshDevices()` read `devices`
   directly (documented: "the method's postcondition is unconditional") but left `transportState`
   to Combine timing. When no device is connected, `enrichConnectedDevice()` returns without
   awaiting anything, so nothing forces the main runloop to turn over and the mirror is still
   stale on return. `testAppStateMirrorsTransportState` passed only by luck — its connected device
   made enrichment await. Fixed by reading both transport readings directly, which makes the
   postcondition unconditional for every published field. **This was a pre-existing latent bug,
   not introduced by Option C.**

### 9.2 Internet-wide access is a separate decision

The owner confirmed the goal is internet-wide access, preferring it over LAN-only. That is **not**
what Option B's LAN WebSocket bridge provides, and it is not what wireless ADB provides either.

| Mechanism | LAN | Internet-wide | Third-party dependency |
|---|---|---|---|
| Wireless ADB (built) | yes | no | none |
| Option B bridge (LAN) | yes | no | Termux on the phone |
| Mesh VPN (Tailscale-class) | yes | yes | yes — a client on both ends |
| Public relay / reverse tunnel | yes | yes | yes — a relay host |

**Tracked as its own decision**, not folded into this ADR: choosing a tunnel is a third-party
dependency decision with its own threat model (a relay can see traffic; a mesh VPN can see
topology). It must not be smuggled in as "persistence".

---

## Provenance

**Verified by running commands on the device, 2026-10-24** (Android 16, Pixel 7a `lynx`,
`BP3A.251005.004.B1` per `wireless-adb-persistence-design.md`): the three `adb devices -l`
entries; `adb -s 192.168.1.7:5555 shell getprop` returning `Pixel 7a` / `arm64-v8a`;
`service.adb.tcp.port=5555`; `adb_wifi_enabled=1`; `development_settings_enabled=1`; shell uid
`2000(shell)` in group `1011(adb)` with `android.permission.WRITE_SECURE_SETTINGS: granted=true`;
and **Termux absent** (`pm list packages` — no match).

**Verified by source inspection:** `TransportProtocol` is device-targeted
(`PixelDesktop/Transport/Transport.swift:3`); `TransportState`/`TransportSelector`/
`WirelessEndpoint` exist and are wired into `ConnectionManager`/`DeviceManager`; reconnect with
backoff and endpoint persistence is implemented (`ConnectionManager.swift:232-299`);
`ADBTransport.connect(host:port:)` exists.

**Verified by repository record:** ADR-002 is the only ADR mentioning wireless, and it rejects
it; FAIL-006 is `COMPLETE`.

**Not performed:** no device settings changed; no Termux installed; no key material read; no
wireless transport modified; no WebSocket bridge built. **No production source modified by this
ADR.**

**Unverified — the reason this is `Proposed` and not `Accepted`:** P1, P2, P3 in §5.

---

```text
ADR-017 WIRELESS TRANSPORT PERSISTENCE — OPTION C ACCEPTED & IMPLEMENTED
OPTION B BLOCKED PENDING PROBE (§5) · INTERNET-WIDE ACCESS TRACKED SEPARATELY (§9.2)
```

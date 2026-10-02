# Communication Architecture Reconnaissance — Comparative Design Study

**Status:** RECONNAISSANCE COMPLETE. **No production code modified. Nothing implemented.**
**Date:** 2026-10-02
**Scope:** can a different Mac↔Pixel channel give PixelDesktop materially more capability than ADB?
**Constraint honoured:** no WebSocket, gRPC, custom USB protocol, TransportManager, router,
scheduler, custom mDNS, automatic pairing, or autonomous agent was added.

---

## 1. Executive finding

> **No alternative communication architecture is justified today. ADB is not the bottleneck, and
> two of the capabilities usually cited as reasons to replace it — streaming and persistent
> sessions — are already available through ADB and are simply not being used.**

Three findings carry this conclusion, each measured rather than asserted:

**Finding A — the overhead is real but small relative to the work.**
Measured fixed orchestration cost per job: **~1,257 ms** (push 231 ms + `am start` 267 ms + wait
758 ms). Measured Phase 6 LLM inference: **12–26 s**. The orchestration overhead is therefore
**~5–10%** of an LLM job. Eliminating it entirely would not change what the system can do.

**Finding B — `adb shell` already streams and already holds a persistent bidirectional session.**
Verified by running both. A long-lived `adb shell` emitting progress lines delivered each line as
produced, and a 9-second multi-command session ran as one bidirectional channel. **Our current
file-exchange-plus-polling design is a choice, not an ADB limitation.**

**Finding C — the privilege gap runs the wrong way, and it is decisive.**
ADB runs as **`uid=2000(shell)`** with `readproc`, `ext_data_rw`, and `WRITE_SECURE_SETTINGS`. Our
worker runs as **`u0_a45`** with **zero permissions**. The privileged operations the system depends
on — `am start`, `am force-stop`, `pidof`, `/proc/<pid>/stat` of another uid, `settings put global`
— are **only available through ADB**. A Service running as the app's own uid has **none** of them.

**Therefore a persistent RPC channel cannot replace ADB. It can only supplement it, at the cost of
a second channel to secure, a foreground Service, permissions the project has deliberately avoided,
and a new failure surface — in exchange for capability the measurements show is not yet needed.**

---

## 2. Current ADB architecture

| Component | Behaviour |
|---|---|
| `TransportProtocol` | device-targeted; every method takes `deviceSerial:` |
| `ADBTransport` | `actor`; shells to `adb -s <serial> …` |
| Job path | `push job.json` → `am start` → **poll for `result.json`** → `pull` |
| Worker | one-shot `Activity`, `finish()` immediately; **no Service, no daemon** |
| `WorkerTransferContract` | fixed paths, one file each way, 1 MB payload cap |
| Permissions | **ZERO** — verified again in this reconnaissance |
| Worker lifetime | process cached by Android after `finish()`, but **model is not resident** (Phase 7) |

**Privileges ADB provides that the app does not have** — the load-bearing list:

| Operation | Why ADB-only |
|---|---|
| `am start` | launching an exported Activity requires shell |
| `am force-stop` | process control requires shell |
| `pidof` | requires the `readproc` group |
| `/proc/<pid>/stat` for another uid | requires `readproc` |
| `settings put global` | requires `WRITE_SECURE_SETTINGS` |

These are not conveniences. They are **the enforcement and observability layer** the project's
containment model rests on.

---

## 3. Candidate architectures — reverse-engineered

### Option 1 — ADB / ADB TLS (current)

**What it actually creates:** a privileged, host-initiated control channel plus a shell-session
channel, over USB or TLS. `adb` owns discovery (mDNS), reconnection, and device identity.

| Question | Answer |
|---|---|
| Persistent? | **Yes** — a shell session can persist for its duration; the ADB server connection persists |
| Bidirectional? | **Yes** — verified |
| Jobs without a new Activity? | **No, as currently built** — but that is our design, not an ADB limit. A long-lived `adb shell` could host a loop |
| Pixel streams progress? | **Yes** — verified streaming |
| Pixel proactively sends events? | **No** — adb is host-initiated; the device cannot initiate to the Mac |
| Logical session? | **Yes** — for the life of one `adb shell` |
| Wi-Fi change | adb mDNS reconnects (verified in `f3552cf`) |
| Pixel restart | wireless debugging **disabled**; requires re-enable |
| Mac sleep/wake | untested |
| Connection lost | typed error; no reconnect logic exists (FAIL-006) |

**Privilege:** full shell privileges. **This is the only option that has them.**

### Option 2 — Companion app + WebSocket

**What it actually creates:** a foreground Service holding an outbound TCP connection to the Mac,
plus a custom framing protocol. The Mac must run a listener.

| Question | Answer |
|---|---|
| Persistent? | Yes, **if** the Service survives — see the Android constraints below |
| Bidirectional? | **Yes — genuinely.** The device can push unsolicited events. This is the one real advantage over ADB |
| Jobs without new Activity? | Yes, in-process |
| Streaming? | Yes |
| Proactive telemetry? | **Yes** — the differentiator |
| Requires | `INTERNET` (manifest), `FOREGROUND_SERVICE`, `POST_NOTIFICATIONS` (API 33+), a persistent notification, a Mac-side listener, a custom protocol, TLS, authentication |
| Privilege gained | **None.** Cannot `am start`, `force-stop`, `pidof`, read another uid's `/proc`, or write secure settings |

### Option 3 — Companion app + gRPC

Same Android-side cost as Option 2, plus: HTTP/2 framing, protobuf schema, codegen, and a
significantly larger APK. **gRPC's real advantages — schema evolution, multi-language codegen,
streaming semantics, deadlines — are engineering conveniences for a large multi-consumer API.**

PixelDesktop has **one consumer, one producer, two workload types, and a 176-byte job envelope.**
Adopting gRPC would add a protocol stack to serve a contract that currently fits in two fixed
filenames. **No capability in §4 is reachable via gRPC that is not reachable via a plain
length-prefixed TCP stream** — the difference is developer ergonomics, not capability.

### Option 4 — Other persistent RPC

| Mechanism | Verdict |
|---|---|
| Plain TCP + length-prefixed JSON | Functionally equivalent to WebSocket minus HTTP upgrade. Simplest of the RPC family |
| HTTP long-poll | A polling design wearing a persistent-channel costume. Worse than what we have |
| **Android bound Service + `adb forward`** | **The interesting one — see below** |
| MQTT / message broker | Introduces a broker; §5.2 forbids message queues without demonstrated need |

**`adb forward` deserves separate treatment** because it inverts the usual trade-off:

```
adb forward tcp:PORT localabstract:<app-socket>
```

This lets the Mac reach a **socket owned by the app** over the **existing, authenticated ADB
connection**. Consequences:

- **no `INTERNET` permission** — the app opens a local socket, not a network socket;
- **no LAN exposure at all** — nothing listens on the network;
- **ADB's existing authentication and TLS** carry over unchanged;
- **no Mac-side listener** and no new port to secure;
- the app **still cannot initiate** to the Mac (ADB remains host-initiated).

**This is the only alternative that adds capability without adding a network surface or a
permission.** It is the strongest candidate, and it is still not justified today (§10).

### Option 5 — Direct USB (custom protocol)

**Reverse-engineered reality:**

| Requirement | Finding |
|---|---|
| Android app exposes a custom USB protocol | **Not possible for a normal app.** The USB gadget is configured by the system: `/config/usb_gadget` is **`Permission denied`** to shell, and `sys.usb.controller` is `11210000.dwc3` — owned by init/usbd |
| App-visible USB | `android.hardware.usb.accessory` and `usb.host` exist, but those are **host/accessory** roles, not "be a custom device to the Mac" |
| Mac side | Would require claiming the device — **and `IOUSBHost` claiming is exactly what FAIL-006 documented Chrome/Brave fighting over** |
| Compete with ADB? | **Yes** — same USB interface, same exclusive-access contention |
| New capability vs ADB? | **None identified.** ADB already gives a faster, authenticated, multiplexed channel over the same wire |

**Verdict: technically infeasible for a non-root app, and it would add contention without adding
capability.**

### Option 6 — Bluetooth / Nearby Connections

| Requirement | Finding |
|---|---|
| Available | `android.hardware.bluetooth`, `bluetooth_le` present |
| Cost | `BLUETOOTH_CONNECT` runtime permission (API 31+); pairing; a new failure surface |
| Throughput | Materially **worse** than ADB for model transfer (1.04 GiB) |
| Capability added | None. The device still cannot perform privileged operations |
| Latency | Worse than USB/TLS |

**Verdict: adds cost and a permission, adds no capability.**

---

## 4. Capability comparison

"Reachable" = the capability exists. "In use" = our current design uses it.

| Capability | ADB | `adb forward` | WebSocket/gRPC | USB | Bluetooth |
|---|---|---|---|---|---|
| Job submission | ✅ in use | ✅ | ✅ | ❌ | ✅ |
| Job cancellation | ✅ (`force-stop`) | ⚠️ in-app only | ⚠️ in-app only | ❌ | ⚠️ |
| Job status | ✅ (`pidof`) | ✅ | ✅ | ❌ | ✅ |
| **Progress reporting** | ✅ **reachable, not in use** | ✅ | ✅ | ❌ | ✅ |
| **Inference streaming** | ✅ **reachable, not in use** | ✅ | ✅ | ❌ | ⚠️ |
| File transfer | ✅ in use | ✅ | ✅ | ❌ | ⚠️ slow |
| Model deployment | ✅ in use (1.04 GiB) | ✅ | ✅ | ❌ | ⚠️ slow |
| Model verification | ✅ (device-side SHA-256) | ✅ | ✅ | ❌ | ✅ |
| Capability reporting | ✅ | ✅ | ✅ | ❌ | ✅ |
| Memory/resource reporting | ✅ | ✅ | ✅ | ❌ | ✅ |
| Worker health | ✅ | ✅ | ✅ | ❌ | ✅ |
| Logs/diagnostics | ✅ | ✅ | ✅ | ❌ | ✅ |
| Structured errors | ✅ | ✅ | ✅ | ❌ | ✅ |
| Multiple sequential jobs | ✅ | ✅ | ✅ | ❌ | ✅ |
| **Concurrent jobs** | ⚠️ possible | ✅ | ✅ | ❌ | ✅ |
| **Device-initiated events** | ❌ **genuinely impossible** | ❌ | ✅ | ❌ | ✅ |
| **Privileged operations** | ✅ **unique** | ❌ | ❌ | ❌ | ❌ |

### The only two genuine gaps in ADB

1. **Device-initiated (unsolicited) events.** ADB is host-initiated; the Pixel cannot push to the
   Mac. This is the sole capability no ADB variant provides.
2. **Concurrent jobs.** Reachable via multiple `adb shell` sessions, but awkward.

**Everything else commonly cited — streaming, sessions, progress — ADB already does.** That is
measured, not assumed.

**And the gap runs both ways:** no alternative provides the privileged operations ADB provides.

---

## 5. Android permission and security comparison

### The distinction the brief demands

```
communication capability   ≠   Android privilege/control capability
```

A persistent RPC channel gives an app **more ways to talk**. It gives it **no new powers**.
Android grants the app process exactly what its uid and declared permissions allow, and a socket
does not change that.

### Concrete cost per option

| Option | Permissions added | Service | Notification | Screen-locked | Doze | Survives restart |
|---|---|---|---|---|---|---|
| **ADB** | **none** | **no** | **no** | ✅ (measured in Phase 7: Activity survived Dozing) | ✅ | n/a (host-initiated) |
| **`adb forward`** | **none** | yes (bound) | no | ✅ | ⚠️ bound Service is not exempt | ❌ |
| WebSocket | `INTERNET`, `FOREGROUND_SERVICE`, `POST_NOTIFICATIONS` | yes | **yes, mandatory** | ✅ | ⚠️ needs exemption | ❌ |
| gRPC | as WebSocket | yes | yes | ✅ | ⚠️ | ❌ |
| USB | USB accessory + user approval | maybe | — | — | — | ❌ |
| Bluetooth | `BLUETOOTH_CONNECT` | yes | yes | ✅ | ⚠️ | ❌ |

### Measured device facts

| Fact | Value |
|---|---|
| Worker requested permissions | **0** |
| Worker app standby bucket | **10 (ACTIVE)** |
| Battery-optimisation exemptions | **0 entries** |
| Doze state at measurement | `ACTIVE` |
| App uid vs shell uid | **different** — app has none of shell's groups |

**A foreground Service would break the project's zero-permission posture**, which is a stated
design decision (D5) that survived every phase. That is a real architectural cost, and it buys
capability the measurements say is not yet needed.

### Security comparison

| Concern | ADB | `adb forward` | Network RPC |
|---|---|---|---|
| Transport encryption | **TLS** (wireless) / USB | **inherits ADB TLS** | must implement TLS |
| Authentication | **ADB key, already paired** | **inherits ADB auth** | must implement + bootstrap |
| Device identity | **ADB serial** (verified `f3552cf`) | same | must implement |
| LAN exposure | **none** | **none** | **a listening port on the LAN** |
| Replay protection | ADB's | ADB's | must implement |
| Bootstrap/pairing | **already done** | already done | new pairing problem |
| Who else can find it | n/a | n/a | **anything on the subnet** |

**The security asymmetry is stark.** A network RPC endpoint is a new, discoverable, unauthenticated
-by-default surface on a LAN that FAIL-006 already showed is shared with two browsers. `adb forward`
avoids this entirely by riding ADB's existing authenticated channel.

**I explicitly do not recommend an unauthenticated HTTP/WebSocket service**, and there is no version
of this design where one is acceptable.

---

## 6. Reliability / failure matrix

Recovery channel available in each row is the critical column.

| Failure | ADB | `adb forward` | Network RPC |
|---|---|---|---|
| USB disconnect | fails; auto-recovers on replug (FAIL-006 caveat) | same | **survives** (Wi-Fi) |
| Wi-Fi disconnect | fails | fails | fails |
| Wi-Fi IP change | **auto** (mDNS, verified) | n/a | needs rediscovery |
| Android restart | wireless debugging **off** → human | Service gone → **ADB recovers** | Service gone → **ADB recovers** |
| Mac restart | auto (server restarts) | forward lost → **ADB re-establishes** | listener gone → **ADB recovers** |
| Mac sleep/wake | **untested** | untested | untested |
| Pixel Doze | **✅ survived (Phase 7)** | ⚠️ Service may be restricted | ⚠️ Service may be restricted |
| Wireless debugging disabled | **human** unless USB present | n/a | n/a |
| Worker app killed | ADB relaunches | **ADB relaunches** | **ADB relaunches** |
| Worker process killed | ADB detects (`pidof`) | ADB detects | ADB detects |
| RPC connection lost | n/a | app reconnects | app reconnects |
| ADB connection lost | **human if no other channel** | RPC may still work | RPC may still work |
| Malformed request | rejected (`INVALID_INPUT`) | must implement | must implement |
| Stale capability info | ADR-007 A1.6 — refused, not unsafe | same | same |
| Model missing | `MODEL_MISSING` | same | same |
| Insufficient memory | checked before submit | same | same |
| Auth failure | ADB handles | ADB handles | **must implement** |

### The pattern that matters

**In every RPC row, ADB is still required for recovery.** The worker app can only be *started* by
ADB (`am start`); it can only be *stopped* by ADB (`force-stop`); its liveness is only observable
via ADB (`pidof`). **ADB is not replaceable — it is the bootstrap and recovery channel.**

So the honest architecture is not "ADB **or** RPC". It is **ADB + RPC**, where ADB is mandatory and
RPC is additive. That is strictly more system, not less.

---

## 7. Performance considerations

**All figures below are either measured or explicitly marked unverified.**

| Metric | Value | Status |
|---|---|---|
| ADB fixed orchestration per job | **~1,257 ms** | **measured** (this reconnaissance) |
| — push | 231 ms | measured |
| — `am start` | 267 ms | measured |
| — result wait | 758 ms | measured |
| LLM inference per job | **12–26 s** | measured (Phase 6) |
| Orchestration as % of LLM job | **~5–10%** | derived |
| DTCA-1 compute | ~1 ms | measured (D8) |
| Model transfer 1.04 GiB | 30.79 s | measured (Phase 6) |
| ADB round-trip | 226 ms | measured (Phase 7) |
| Streaming via ADB | works | **measured (this reconnaissance)** |
| RPC round-trip latency | **not measured** | **unverified** |
| RPC sustained throughput | **not measured** | **unverified** |
| gRPC vs raw socket overhead | **not measured** | **unverified** |

### The decisive comparison

For a **DTCA-1** job (~1 ms compute), orchestration is **~99.9%** of wall time — RPC would help
enormously in relative terms. For an **LLM** job (12–26 s), it is **~5–10%** — RPC would help
little.

**And the LLM workload is the one the project exists for.** DTCA-1 is a deterministic proof
workload, not a product feature.

**Required experiment to settle it:** measure RPC round-trip and sustained throughput against the
measured 226 ms / 30.79 s ADB baselines. **Until that exists, no performance claim for RPC is
supportable** — and I will not fabricate one.

---

## 8. Complexity comparison

| Dimension | ADB (current) | `adb forward` | WebSocket | gRPC |
|---|---|---|---|---|
| macOS implementation | **exists** | small (forward + client) | listener + protocol + TLS | + protobuf + codegen |
| Android implementation | **exists** | small (local socket) | Service + framing + TLS | + protobuf + codegen |
| Protocol | **none** (files) | small | custom | schema |
| Permissions added | **none** | **none** | 3 | 3 |
| New failure modes | **none** | Service lifecycle | Service, TLS, listener, discovery | + schema drift |
| Security surface | **none new** | **none new** | **new LAN listener** | same |
| Testing | **exists** | + socket tests | + protocol/TLS/reconnect | + codegen tests |
| Maintenance | **none** | low | medium | medium-high |

**gRPC is strictly more complex than WebSocket for identical capability here**, and WebSocket is
strictly more complex than `adb forward` while adding a network surface.

---

## 9. Reuse of existing PixelDesktop architecture

| Component | Reusable if an RPC channel appeared? |
|---|---|
| `TransportProtocol` | **Yes** — device-targeted; a socket transport could satisfy it unchanged |
| `AndroidDevice` / `DeviceState` | **Yes** — identity is transport-independent |
| `WorkerTransferContract` | **Partly** — fixed paths become unnecessary if a channel carries payloads; the *narrowness principle* should survive |
| `WorkerOperationsProtocol` | **Partly** — `submitInput`/`retrieveResult` become channel operations |
| `WorkerInstaller` / `WorkerLifecycle` | **Yes, unchanged — and still required**, since only ADB can install and launch |
| `PixelCapabilityContract` | **Yes, unchanged** — a capability report is transport-agnostic |
| `PixelEvidenceReader` / evidence models | **Yes, unchanged** |
| `InferenceRuntime` / `LlmWorkload` | **Yes, unchanged** |
| Worker Activity | would become a Service — **a real change, and the thing D5 forbade** |

**Most of the system is transport-independent and would survive.** The parts that would not are
exactly the parts the project deliberately chose.

**No parallel abstraction is proposed.**

---

## 10. Recommended architecture

**Recommendation: keep ADB. Do not add a second channel. Do not add a Service.**

The brief asked for the capability that would justify an alternative. **Only one candidate survives
scrutiny, and it is not yet justified:**

| Candidate justification | Verdict |
|---|---|
| "Persistent bidirectional job execution" | **ADB already provides it** (measured) |
| "Streaming inference" | **ADB already provides it** (measured) |
| "Reduced repeated ADB invocation" | ~1.26 s vs 12–26 s — **~5–10%; not material for the LLM workload** |
| "Reliable application-level session state" | ADB sessions persist for their duration; the *file-exchange design* is what lacks session state |
| **"Telemetry the Pixel initiates"** | **The one genuine gap.** Not yet needed by any phase |
| "Long-running workers" | Requires a Service — **forbidden by D5**, and Phase 7 measured the Activity already surviving Dozing |

### What I recommend instead

**Two zero-permission, zero-network improvements that capture most of the claimed benefit:**

1. **Use `adb shell` as a streaming session for long jobs.** It is already available, requires no
   permissions, and would remove the polling and the 758 ms result wait. This is a change to *how
   we use ADB*, not to what we use.
2. **If a real app-owned channel is ever needed, use `adb forward` to a local abstract socket.**
   It adds no permission, no LAN listener, and inherits ADB's authentication — and it keeps ADB as
   the mandatory bootstrap, which the failure matrix shows it must be anyway.

### Answering the brief's closing question directly

> **Is there a communication architecture that gives PixelDesktop materially more useful capability
> than ADB while preserving the Hermes → PixelDesktop → Pixel boundary and keeping the system
> simpler rather than more complex?**

**No.** No candidate is both more capable *and* simpler.

- Every alternative that adds capability adds a Service, permissions, and a failure surface — so it
  is **more complex**, not less.
- Every alternative that is simpler adds **no** capability.
- `adb forward` is the closest to "more capability at no cost" — it adds a device-owned socket with
  no new permission or network surface — **but the capability it adds (device-initiated events) is
  not needed by any phase, and it still requires ADB for bootstrap and recovery.**
- The measured evidence shows ADB is **not** the bottleneck: ~5–10% of an LLM job, and it already
  streams and already holds sessions.

**The correct action is to use ADB better, not to replace it.**

---

## 11. What should NOT be built

| Not built | Why |
|---|---|
| WebSocket / gRPC service | new LAN surface, 3 permissions, a Service, for capability ADB already has |
| Custom USB protocol | infeasible for a non-root app; would contend with ADB (FAIL-006) |
| Bluetooth transport | slower, adds a permission, adds no capability |
| TransportManager / router / scheduler | one transport implementation; the ADR-013 mistake |
| Custom mDNS / pairing / auto-enable | ADB already does discovery; pairing is a security boundary |
| Foreground Service / autonomous agent | forbidden by D5; the worker stays a bounded executor |
| Message broker | §5.2 forbids queues without demonstrated need |

---

## 12. Required experiments before any implementation

**These are prerequisites, not nice-to-haves.**

| # | Experiment | Settles |
|---|---|---|
| **E1** | Measure **streaming a long job over a single `adb shell`** end-to-end, replacing push+poll | whether improvement #1 is worth doing — **cheapest, highest value** |
| **E2** | Measure RPC round-trip and sustained throughput vs the 226 ms / 30.79 s baselines | whether any performance claim for RPC is supportable |
| **E3** | Test **`adb forward` to a local abstract socket** with the current zero-permission app | whether a device-owned channel is reachable without new permissions |
| **E4** | Measure whether a bound Service survives Doze on this device | whether a Service is viable at all |
| **E5** | Identify a **concrete workload requiring device-initiated telemetry** | whether the one genuine gap is real |

**E5 is the gate.** Without a workload that needs the Pixel to speak first, there is no justification
for a second channel — and no phase to date has needed one.

**E1 should be done first**: it is the cheapest, it needs no new architecture, and it may capture
most of the benefit the brief was reaching for.

---

## 13. Proposed implementation boundary

If E1–E5 ever justify a channel:

```
                    Hermes
                      │  orchestration (unchanged)
                      ▼
                 PixelDesktop
                      │
             ┌────────┴────────┐
             │                 │
      ADB control        app-owned socket
      (privileged)       (via adb forward)
             │                 │
             │                 ▼
             │          Worker (bounded)
             └──── bootstrap / recovery / install / launch
```

**ADB remains the privileged bootstrap and recovery channel — the failure matrix shows it must be.**
The socket would be **app-owned and reached through ADB**, not a network listener.

**The worker stays a bounded executor.** No autonomous agent.

---

## 14. Open unknowns

| # | Unknown |
|---|---|
| **U1** | RPC round-trip and throughput — **entirely unmeasured** |
| **U2** | Whether a bound Service survives Doze on this device |
| **U3** | Whether `adb forward` works with the current zero-permission app (expected yes; untested) |
| **U4** | Whether any workload actually needs device-initiated events |
| **U5** | Mac sleep/wake behaviour for any channel (untested for ADB too) |
| **U6** | Whether `adb shell` streaming is robust across a flaky USB link (FAIL-006 context) |
| **U7** | gRPC's value at this scale — plausibly negative, unmeasured |

---

## 15. Architectural impact on Phases 7–9

| Phase | Impact |
|---|---|
| **7** (capability contract & evidence) | **None.** `PixelCapabilityContract` and the evidence layer are transport-agnostic. The transport-state work in `design/usb-aware-transport-design.md` is unaffected |
| **8** (UX) | **None.** Transport state is already modelled; a second channel would add UI, not remove it |
| **9** (Hermes integration) | **None, and this protects it.** Hermes consumes the capability contract, not the transport. Keeping one channel keeps the interface stable |

**The Hermes → PixelDesktop → Pixel boundary is unchanged, and this reconnaissance strengthens it:
one privileged control channel is easier to reason about, secure, and explain than two.**

---

## Provenance

**Measured (this reconnaissance, on the physical Pixel 7a):** ADB orchestration overhead ~1,257 ms
(push 231 + `am start` 267 + wait 758); `adb shell` streams incrementally; a multi-command
`adb shell` holds a persistent bidirectional session; worker permissions 0; app standby bucket 10;
0 battery exemptions; `/config/usb_gadget` permission denied; `sys.usb.controller` = `11210000.dwc3`;
`usb.accessory` and `usb.host` present; Bluetooth and BLE features present; shell uid 2000 vs app
`u0_a45`.

**Measured (prior phases, cited):** LLM inference 12–26 s; model transfer 30.79 s; ADB round-trip
226 ms; Activity survives Dozing; worker process cached after `finish()` but model not resident.

**Verified by source inspection:** the job path is push + `am start` + poll + pull; worker is a
one-shot Activity with no Service; manifest declares zero permissions.

**Documented:** Android foreground-Service and Doze/App-Standby restrictions; USB gadget ownership;
`adb forward` semantics; gRPC/WebSocket characteristics.

**Unverified / not measured:** all RPC performance; Service behaviour under Doze; `adb forward` with
this app; whether any workload needs device-initiated events.

**Not performed:** nothing was implemented; no experimental code was left in the repository; no
Android settings were changed.

---

```text
COMMUNICATION ARCHITECTURE RECON COMPLETE / AWAITING REVIEW
```

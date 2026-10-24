# PixelDesktop as the Phone Interface — Feature Proposal

**Date:** 2026-10-24
**Author:** Ciel
**Status:** **APPROVED** 2026-10-24 (rnz). Revision 2 is the binding plan; §8 is the phasing authority, one gate per phase.
**Revision 2 (2026-10-24):** **A1 (screen mirroring) is dropped as a PixelDesktop subsystem** — rnz chose option (a): scrcpy stays an external tool. See §2.1 and §6.4.
**Supersedes:** nothing. Complements `docs/PROPOSAL-REMOTE-STORAGE.md` (storage/transport).

---

## 1. Vision

The Pixel 7a's screen is broken. That single fact changes what PixelDesktop is for.

It stops being "a tool that happens to talk to a phone" and becomes **the phone's only interface**. Every capability the device has must be reachable from the Mac, and — because the Mac is now also the phone's eyes — every action must be *observable* from the Mac.

### The reframing that drives this proposal

PixelDesktop today is **control-heavy and perception-poor**:

- **Control** — send commands to the phone. Largely built: transport (ADR-002), storage, app operations (ADR-009), worker install/run (ADR-010, ADR-011), local inference (ADR-012).
- **Perception** — see what the phone is doing and what happened. Almost entirely **missing**.

A working screen hides that gap: you tap, you look, you see. With a dead screen the gap becomes a wall. This proposal is mostly about closing it.

### Two rules that follow

1. **No feature may require the phone's screen to be readable or tappable.**
2. **Every command must have an observable result** the Mac can render or log.

Rule 2 is already the project's culture (evidence harness, `ResultVerifier`, capability contract). Rule 1 is new and is the actual design constraint.

---

## 2. Device Facts (verified empirically, 2026-10-24)

Not from documentation — read off the device over ADB. Evidence image: `engineering/evidence/device-probe-lockscreen-20261024.png`.

| Fact | Value | Consequence |
|---|---|---|
| Model | Pixel 7a (`lynx`) | Bootloader unlockable in principle |
| OS | **Android 16**, SDK 36, build `BP3A.251005.004.B1` | Newest Android; affects every tool's flags |
| Security patch | 2025-10-05 | Current |
| CPU / RAM | 8 cores, ~7.6 GB | Adequate for a small GGUF |
| Storage | 110 GB total, **60 GB used / 50 GB free** | Root would destroy 60 GB |
| Bootloader | **locked** (`flash.locked=1`, `verifiedbootstate=green`, `veritymode=enforcing`) | Root requires unlock |
| Build type | `user`, `debuggable=0` | **`adb root` will not work** |
| `ro.oem_unlock_supported` | **unset** | ⚠ Must confirm OEM-unlock toggle exists (§7) |
| Developer options | ON (`development_settings_enabled=1`, `adb_enabled=1`) | Good |
| Wireless debugging | **`adb_wifi_enabled=0`** | ⚠ Contradicts assumption — verify (§7) |
| Root present | No `su` binary | Not rooted, as stated |
| Termux / Shizuku / Magisk / llama | **none installed** | Compute node is unbuilt |
| Screen state | **Unlocked and in use** — scrcpy frame shows TikTok open, no lock screen, clock 4:40, 100% charging | The OLED panel is physically dead (§2.1) but the device is awake and usable |
| Display | 1080×2400, density 420 (override 460) | Coordinate space for input injection |
| **Framebuffer** | ✅ **`screencap` returned a real 1080×2400 PNG (924 KB)** | **Mirroring is viable** |
| **UI hierarchy** | ✅ **`uiautomator dump` returned 18 KB of real XML** | **A4 works today** |
| Battery / thermal | 100% charging; battery 33.6 °C; **LITTLE cluster 67 °C** | ⚠ Thermal headroom is thin |

### What this settles

- **Q1 (screen type) — ANSWERED.** The OLED panel is physically dead, but the framebuffer renders cleanly. `screencap` works and scrcpy mirrors the device over USB (§2.1). **A2 is viable in-app; A3 is a flag on external scrcpy; A1 is dropped (§6.4).** The P0 go/no-go is resolved: **GO**.
- **Q7 (Android version) — ANSWERED.** Android 16, SDK 36.
- **A4 (UI hierarchy) — VERIFIED WORKING**, not merely proposed.
- **A2 (screenshot) — VERIFIED WORKING**, and doubles as evidence.

### 2.1 Verified scrcpy baseline — external tool (2026-10-24)

scrcpy runs against this device over USB and mirrors it. Two runs exited 0.

| Observation | Value |
|---|---|
| Video | `Texture: 1080x2400`, `Renderer: metal` |
| Audio | Forwarding works |
| Frame evidence | `engineering/evidence/scrcpy-frame-20261024.png` |
| Recording | `engineering/evidence/scrcpy-recording-20261024.mkv` (52.3 s, 15.9 MB — `ffprobe`-verified, container valid) |

**The dead OLED is settled — do not re-probe the device to re-derive it.** rnz confirmed it directly ("it doesn't display. the oled is broken"). The framebuffer rendering cleanly is *why* `screencap` and scrcpy both work: both read the framebuffer, not the panel.

**Governance constraint.** Three sources forbid reimplementing scrcpy inside PixelDesktop:

| Source | Says |
|---|---|
| `engineering/architecture/overview.md` §68 | "**No `Video/` subsystem exists, and none is planned.** scrcpy is not a PixelDesktop subsystem." |
| `ADR-008-android-device-model.md` §176 | A `Video/` subsystem "conflicts with the master prompt's *'not a better scrcpy frontend'* constraint" |
| `phase-00-clean-start-audit.md` §279 | "**Do not revive the legacy scrcpy/video architecture**" without an ADR that requires it |

`PixelDesktop/Video/` exists as an **empty directory** — verified 2026-10-24: zero files. The two 0-byte scaffolds recorded in `phase-00-clean-start-audit.md` §35–36 (`ScrcpyProcessService.swift`, `ScrcpyVideoTransport.swift`) no longer exist and were never tracked by git. It is dead scaffold, not a foundation, and Phase 0 removes it (§6.4, §8).

---

## 3. Current State Assessment

Verified against `HEAD` (`87eb2d7`), working tree clean.

| Capability | Status | Where |
|---|---|---|
| Device discovery (USB + wireless) | ✅ Working | `Device/DeviceDiscovery.swift`, `Device/DeviceManager.swift` |
| Transport selection (USB > WiFi) | ✅ Working | `Device/TransportState.swift`, `Device/ConnectionManager.swift` |
| Connection persistence + auto-reconnect | ✅ Working | `PersistedConnectionState` (UserDefaults) |
| File operations (list/push/pull/mkdir/rm/mv) | ✅ Working | `Storage/StorageService.swift` (predates ADR discipline — no ADR) |
| Storage UI | 🚧 WIP | `StorageUI/` (uncommitted) |
| App launch / stop / list | ✅ Working | `Operations/ADBAppOperations.swift` (ADR-009) |
| Worker install / run / stream | ✅ Working | `Worker/` (ADR-010, ADR-011) |
| Local inference runtime + capability contract | ✅ Working | `Inference/` (ADR-012) |
| Evidence / verification harness | ✅ Working | `Verification/ResultVerifier.swift` |
| **Screenshot (A2)** | ✅ **Verified on device** | — |
| **UI hierarchy (A4)** | ✅ **Verified on device** | — |
| **Screen mirroring** | ✅ Working — **external** (`scrcpy`), deliberately not a PixelDesktop subsystem | §2.1, §6.4 |
| **Screen recording (A3)** | ❌ Missing | — |
| **Notification stream (A5)** | ❌ Missing | — |
| **Log stream (A6)** | ❌ Missing | — |
| **Input injection (B1)** | ❌ Missing | — |
| **ADB port forwarding / reverse tunnel (B3)** | ❌ Missing | — |
| **Host service management (B2)** | ❌ Missing | — |
| **App install / uninstall (B4)** | ❌ Missing | `ADBAppOperations` covers launch/stop/list only |
| **Reboot control (B5)** | ❌ Missing | — |

`PixelDesktop/Video/` existing but empty is itself a finding: mirroring was anticipated and never started. It is now **dead scaffold** — decision (a) forbids the subsystem, so Phase 0 deletes the directory rather than filling it.

**Baseline:** **609 tests, 0 failures, 22 skipped** at `87eb2d7` (full suite re-run 2026-10-24). Supersedes the earlier 593 @ `3d703cb` figure, which predated two test commits.

---

## 4. Design Principles (new, because of the broken screen)

**P1 — No local-UI dependency.** Nothing may be *only* doable by looking at or touching the phone. This is an invariant, not a preference — it belongs in the same place as "the backend has no capability, the UI has no control."

**P2 — Headless first.** Prefer `uiautomator`, `dumpsys`, `logcat`, and direct ADB commands over blind taps. Taps are the last resort, not the default.

**P3 — Blind input is gated.** Input injection must support a **dry-run/preview** that shows what *would* be tapped (coordinates, target element from the UI dump) and require explicit confirmation. With no visual feedback, an unconfirmed tap is an unrecoverable mistake.

**P4 — Personal data needs consent + audit.** Notifications, SMS, contacts, clipboard. ADB is a full-trust channel; every read of personal data is logged and gated behind an explicit opt-in per data class. *(rnz approved access — see §6.1.)*

**P5 — Every action has an escape.** Anything destructive must be reversible, or carry a documented recovery (reboot path, safe mode). "You can't see the screen" means a bad action is invisible until it's too late.

**P6 — Prefer the existing seams.** New features go through `TransportProtocol`, not raw `ADBTransport` — this is the established testability pattern (`ADBAppOperations`, `DeviceEnricher`).

---

## 5. Feature List

### Group A — Perception (the missing half)

**A1. Screen mirroring — ❌ DROPPED as a PixelDesktop subsystem (2026-10-24, rnz decision (a))**
scrcpy already provides the eyes and stays an **external tool**. PixelDesktop documents the invocation, owns no `Video/` subsystem, and speaks no part of the scrcpy protocol. Rationale and the ADR conflict: §2.1, §6.4.

```
scrcpy                                # live mirror over USB
scrcpy --no-playback --record=s.mkv   # record only, no window   (= A3)
scrcpy --record=session.mkv           # mirror + record          (= A3)
```

**A2. Screenshot capture** — ✅ **already proven working on device** — *in-app*
`adb exec-out screencap -p`. The one perception primitive PixelDesktop owns outright: a single ADB call returning a PNG on stdout, no protocol and no video pipeline. Doubles as an evidence artifact (fits the existing provenance culture).

**A3. Screen recording — a flag on the chosen dependency, not a subsystem**
`scrcpy --record` for live sessions; `adb shell screenrecord` where scrcpy is unavailable. Both are documented invocations surfaced in the UI as a copyable command plus its output path. **No capture pipeline is built in-app.**

**A4. UI hierarchy dump** — ✅ **already proven working on device**
`adb shell uiautomator dump` → parsed element tree (text, resource-id, bounds, enabled/clickable). This is what makes blind operation *targeted*: you address "the element labelled 'Allow'" instead of "the pixel at (412, 1033)".

**A5. Notification stream** — `dumpsys notification --noredact`. Makes the phone's state legible without seeing it. **P4-gated** (access approved).

**A6. Log stream** — tailed, filtered `logcat`. Essential for debugging the device itself and for observing what the phone's own agents are doing.

**A7. Device telemetry** — battery, temperature, memory pressure, storage, network. `PixelStateObservation` already carries much of this with provenance; needs a real dashboard and **thermal history** — the LITTLE cluster already reads 67 °C while idle-charging.

### Group B — Control (extend what exists)

**B1. Input injection** — tap / swipe / text / keyevent, driven by A4 element coordinates. **P3-gated**: dry-run preview + confirm. See §6.2 for what it is and why it is dangerous.

**B2. Host service management** — start/stop long-running services on the phone (Termux, an HTTP file server, `llama-server`), with status and restart policy. The bridge between "phone as terminal" and "phone as host."

**B3. ADB port forwarding / reverse tunnel** — `adb reverse tcp:X tcp:X` so a Mac process can reach a phone-side service, and `adb forward` for the reverse. **Foundational**: without it, B2 and Group C are unusable from Hermes.

**B4. App install / uninstall** — `adb install -r`, `adb uninstall`. `ADBAppOperations` currently covers discovery/launch/stop only.

**B5. Reboot control** — `adb reboot` / `recovery` / `bootloader`. Last resort, **P5-gated**: requires explicit confirmation and a documented recovery path.

**B6. Clipboard** — read/write. **P4-gated** (personal data). Also the pragmatic answer to "copy a code from the phone to the Mac."

### Group C — The phone as a headless agent host *(rnz: compute node)*

This is the strategic layer, and where the broken screen stops mattering at all.

**C1. On-device model serving** — `llama-server` (or Ollama-in-Termux) running a small GGUF, exposed to the Mac through **B3**. The Pixel becomes a compute node Hermes can route to, not a screen to look at. **No root required** — Termux runs unprivileged.

**C2. Local inference jobs** — extend `Worker/` + `Inference/` so a job can be *scheduled on the phone* and consumed by a Mac-side agent. `LlmJob.swift` already exists; the missing piece is the reverse-tunneled endpoint.

**C3. Remote shell** — a deliberate, audited, streamed `adb shell`. `shell()` is currently contained by design (ADR-009); an interactive shell is a genuine expansion of that boundary and needs its own ADR.

**C4. Scheduled device tasks** — run something on the phone on a schedule (Termux cron), results surfaced in PixelDesktop.

### Group D — Trust & safety

**D1. Consent registry** — per data class (notifications, SMS, contacts, clipboard), persisted, revocable.

**D2. Command audit log** — every command + result + timestamp, retained. The evidence culture already half-exists; this makes it complete for *device* operations.

**D3. Dry-run / preview mode** — universal for anything destructive (B1, B4, B5, storage delete).

**D4. Kill switch / safe mode** — stop all device-side services and disconnect.

---

## 6. Decisions

### 6.1 rnz's calls (2026-10-24)

| # | Question | Answer | Effect |
|---|---|---|---|
| Q1 | Screen broken how? | **Physically broken; framebuffer streams to Mac** | A2 viable in-app; A3 via external scrcpy; A1 reclassified (§6.4) |
| Q2 | Wireless debugging on? | **Yes** — ⚠ but `adb_wifi_enabled=0` on device (re-verified 2026-10-24) | Verify; USB works today (§7 Q2b) |
| Q8 | May PixelDesktop show the phone's screen? | **(a) No — scrcpy stays external** | No `Video/` subsystem; A1 dropped; scaffold deleted (§6.4) |
| Q3 | Personal data access? | **Yes** | A5, B6 unblocked; D1/D2 still required |
| Q4 | Rooted? | **No** — weigh it (§6.3) | Analysis below |
| Q5 | Input injection — what is it? | *explained* | Definition below |
| Q6 | Compute node or terminal? | **Compute node** | **Group C leads.** Group A/B become the control plane. |
| Q7 | Android version? | **Android 16, SDK 36** | Tool flags matter |

**Reprioritisation from Q6.** If the Pixel is a compute node, Group C is the product and Groups A/B are the control plane that makes it operable. Order becomes:

**P0 — Control plane (do first)**
1. **A4 UI hierarchy** ✅ verified working → wire into PixelDesktop
2. **A6 log stream** — debuggability
3. **B3 port forwarding / reverse tunnel** — *the* unlock for Group C
4. **A1 mirroring** — **not built**; scrcpy documented as the external eyes (§6.4)
5. **B1 input injection** — the hands (gated, §6.2)

**P1 — The node**
6. **C1 on-device model serving** (Termux + llama.cpp + reverse tunnel)
7. **B2 host service management** — start/stop/health for C1
8. **C2 phone-side inference jobs**
9. **A7 telemetry dashboard** — thermal history is the constraint, not RAM

**P2 — Durability**
10. **A5 notifications** · **C4 scheduled tasks** · **C3 remote shell** (ADR first) · **B4/B5** · **D1–D4**

### 6.2 Input injection — what it is

**Definition.** Input injection is the ability to send synthetic touch, swipe, and key events to the phone from the Mac, as though a finger were touching the screen. On Android this is one command:

```
adb shell input tap 540 1200            # touch at (x, y)
adb shell input swipe 540 1800 540 600  # swipe up (unlock)
adb shell input text "1234"              # type text
adb shell input keyevent KEYCODE_BACK    # hardware-ish key
```

It works at the framework level (InputManager), **not** through the digitizer — so it functions even when the touchscreen is physically dead. That is exactly why it is the missing piece for a broken-screen phone.

**Why it matters here.** It is the only way to drive any UI that has no headless equivalent: the lock screen, the setup wizard, permission dialogs, the Developer Options toggles, the Magisk/Shizuku installers. Everything else on this list is headless; this is the one thing that lets you *operate the phone's own interface* remotely.

**Why it is dangerous.** A tap has no confirmation loop. With a working screen you see the result immediately and can stop. With a dead screen you are firing blind into a device you cannot observe — and on this device a tap can:
- confirm a factory-reset dialog,
- accept a permission you did not intend,
- unlock the phone, dismiss a lock, or trigger a payment.

**Therefore P3.** Input injection ships only with:
1. **A dry-run mode** — given a target element from the A4 dump, PixelDesktop shows *what will be tapped* (element text, resource-id, bounds) and does nothing until confirmed.
2. **Element-addressed, not coordinate-addressed** — you select "the button labelled *Allow*" from the parsed hierarchy, and the app resolves the bounds. Raw `input tap x y` is not exposed in the UI.
3. **A per-action audit record** (D2) — every injected event is logged with its resolved target.

**Recommendation:** build B1, but keep it behind the dry-run gate and out of the default UI. It is a maintenance tool, not a daily driver — for daily use you want headless (A4 + B3 + B2), and B1 is what you reach for when headless is impossible.

### 6.3 Rooting — advantages, disadvantages, and the Mac-only path

**The honest headline: for a compute node, root buys almost nothing.** The compute workload — `llama.cpp` / `llama-server` in Termux — runs entirely in user space, unprivileged. Root does not make inference faster, and it does not help C1–C4. The only real compute-adjacent benefit is CPU-governor and thermal control, and the phone is already thermally constrained (LITTLE at 67 °C while idle-charging).

**Advantages of rooting**

| Benefit | Real value here |
|---|---|
| Read any app's private `/data` | Marginal — you want the phone's *own* files, not other apps' |
| CPU governor / thermal tuning | Real, but the SoC is thermally limited anyway |
| `iptables`/nftables firewall, VPN control | Marginal for a single-node setup |
| System CA certs (MITM, debugging) | Real if you ever need to inspect TLS |
| Debloat / remove system apps | Cosmetic |
| Full filesystem backup (not just `/sdcard`) | Real, but the wipe is the cost |
| Magisk modules / KernelSU | Interesting, not needed for compute |

**Disadvantages — these are the serious ones**

| Cost | Severity |
|---|---|
| **Bootloader unlock wipes the device completely** | 🔴 **60 GB of data gone.** Everything: photos, messages, app state, the current setup. |
| **Play Integrity fails** → banking apps, Google Wallet/Pay, Netflix/DRM, some apps refuse to run | 🔴 A Pixel with a patched boot image fails hardware-backed attestation. Magisk + Zygisk + Play Integrity Fix spoof *basic* integrity, but Android 16's hardware attestation is much harder. This may be a **permanent regression on a phone rnz still uses daily**. |
| **OTA updates stop** — each update needs a re-patched image or a factory re-flash | 🟠 Ongoing maintenance burden |
| **Bricking risk** | 🟢 Low on Pixel — `fastboot` is robust and a factory image always recovers. But a bad flash with a dead screen is unpleasant. |
| **Root can be re-locked only after re-flashing factory** | 🟢 Reversible in principle |
| Warranty | 🟢 Pixel 7a (2022) is long out of warranty |
| Knox-style permanent fuse | 🟢 Does not exist on Pixel — no irreversible e-fuse |

**The middle path: Shizuku (no root, no wipe).**
Shizuku grants ADB-privilege-level APIs to apps without unlocking the bootloader. It can force-stop apps, manage packages, write some secure settings, and reach hidden APIs. It **cannot** read other apps' private data or change the CPU governor. For a compute node it covers nearly everything root would, with **no data loss and no Play Integrity impact**.

**Recommendation: do not root.** Build the node on Termux + ADB + Shizuku. Revisit root only if a specific capability appears that Shizuku cannot cover (system CA certs, another app's private data, governor control). The wipe and the Play Integrity regression are both costs you cannot undo, and neither buys compute capability.

**Mac-only rooting procedure (for the record, if the decision reverses)**

Everything below is driven from the Mac. The only phone-side actions are **physical button presses**, which work with a broken screen.

1. **Prerequisite — confirm OEM unlock is possible.** `ro.oem_unlock_supported` is **unset** on this build, which is unusual. The Developer Options "OEM unlocking" toggle must be present and ON. This needs one screen interaction, doable via input injection with mirrored feedback.
2. **Back up** — `adb pull /sdcard` plus app-level backups. Accept that the rest is lost.
3. `adb reboot bootloader`
4. `fastboot flashing unlock` → confirm with **Volume Down** (physical button, screen-independent)
5. Device wipes and reboots to the setup wizard. Re-enable Developer Options (tap Build Number ×7 — via input injection + mirroring) and USB debugging.
6. **Download the factory image** for `lynx` from Google's developer site on the Mac.
7. Extract `init_boot.img`. *(Android 13+ moved the ramdisk to `init_boot`; patching `boot` will not root a Pixel 7 series.)*
8. **Patch with `magiskboot` on the Mac** (from the Magisk release) — unpack, inject Magisk, repack. This avoids operating the Magisk app UI on the phone entirely.
9. `fastboot flash init_boot magisk_patched.img`
10. `fastboot reboot`
11. `adb install` the Magisk APK — no UI interaction needed.
12. Root achieved.

### 6.4 A1 / screen mirroring — decision (2026-10-24)

**Question:** Is PixelDesktop allowed to show the phone's screen at all — and if so, how?

**rnz's answer: (a) — drop A1 entirely.**

| Option | Meaning | Verdict |
|---|---|---|
| **(a)** | scrcpy stays an external tool the user runs; PixelDesktop only documents the command. No `Video/` subsystem. | ✅ **CHOSEN 2026-10-24** |
| (b) | ADR exception for a thin scrcpy launcher/lifecycle wrapper (spawn, start/stop, window) — explicitly not a protocol reimplementation | ✗ not chosen |
| (c) | Leave A1 out of Phase 0; "eyes" treated as purely a user-side concern | ✗ not chosen — (a) is stronger, it also forbids the wrapper |

**Why (a).** scrcpy already works (§2.1), so A1 as originally written was a **subtraction, not an addition**: it would have rebuilt a working tool inside an app whose master prompt says it is "not a better scrcpy frontend". Option (a) is the only choice that keeps the ADR set intact without writing a new exception, and it keeps scope honest — **PixelDesktop owns headless perception and control, not video.**

**Consequences (binding):**
1. No `Video/` subsystem. No scrcpy protocol implementation, no video decode, no Metal rendering of the device in-app.
2. `PixelDesktop/Video/` (verified empty — 0 files) is **deleted** in Phase 0.
3. A3 recording is a documented `scrcpy --record` invocation, not an in-app capture pipeline.
4. If a launcher/lifecycle wrapper is ever wanted, it is option (b) and needs **its own ADR** — not an increment on this proposal.

---

**Android 16 caveat:** Android 16 ships strengthened boot-integrity verification that breaks standard Magisk installs. Magisk **v28.0+** is required. KernelSU-Next on a Wild GKI kernel is the alternative (kernel-level root, no boot patching). **Verify current Magisk/KernelSU support for this exact build (`BP3A.251005.004.B1`) before planning a root attempt.**

---

## 7. Open Questions (remaining)

| # | Question | Note |
|---|---|---|
| Q2b | **Is wireless debugging actually on?** | rnz said yes; device reports `adb_wifi_enabled=0` (re-verified 2026-10-24) and is connected over USB. **`ADR-017` §1.1's `adb_wifi_enabled=1` / `192.168.1.7:5555` is a point-in-time reading and is now stale** — that endpoint is `offline` and `adb connect` times out. Confirm before designing the reconnect path. |
| Q4b | **Is OEM unlock available?** | `ro.oem_unlock_supported` unset. Needs the Developer Options screen — requires unlocking the phone first. Only matters if the root decision reverses. |
| ~~Q8~~ | ~~Should the phone be left unlocked?~~ | **Resolved 2026-10-24 — ADR-018.** Phone stays unlocked (`stay_on_while_plugged_in 7`, `lockscreen.disabled 1`, `locksettings set-disabled true`), verified by sleep/wake cycle: zero keyguard nodes in UI dump, `mIsShowing=false`, launcher focused. |
| ~~Q9~~ | ~~Thermal policy for sustained inference?~~ | **Resolved 2026-10-24 — ADR-018.** No context/batch cap; rnz runs an external cooler and accepts throttling. Alert must fire on `Thermal Status >= 4 (CRITICAL)` from `dumpsys thermalservice`; delivery lands in Phase 2/3. |

---

## 8. Proposed Phasing

| Phase | Name | Contents | Gate |
|---|---|---|---|
| 0 | **Control plane** | A4 UI dump wired in · A6 logcat · B3 port forwarding · A2 screenshot-as-evidence · delete dead `Video/` scaffold · document scrcpy invocation (no subsystem) | ✅ **done 2026-10-24** — `engineering/phases/phase-00-control-plane.md` |
| 1 | **The node** | C1 Termux + llama-server · B2 host service management · C2 inference jobs | rnz approval |
| 2 | **Hands** | B1 input injection (dry-run gated) · A7 telemetry + thermal history | rnz approval + ADR |
| 3 | **Durability** | A5 notifications · C4 scheduled tasks · C3 remote shell · B4/B5 · D1–D4 | rnz approval |

---

## 9. Explicitly Out of Scope

- Rebuilding the storage/transport/app-ops/worker/inference layers — they exist and work.
- Cloud relay / remote access over the internet — direct device-to-Mac only (ADR-002, ADR-014).
- Rooting the device (§6.3 — not recommended).
- **Any `Video/` subsystem** — scrcpy protocol, video decode, in-app mirroring, or a scrcpy launcher wrapper (§6.4, decision (a)). scrcpy is an external tool.
- Anything requiring the phone's screen to be usable.

---

## 10. Success Criteria

1. rnz can operate the Pixel 7a headlessly — browse files, run a service, drive an app, read its state — **without touching the phone**. Visual feedback comes from externally-run scrcpy (§6.4); PixelDesktop needs no video path to satisfy this.
2. Every command issued produces a visible, logged result in PixelDesktop.
3. The full test suite passes with no regression (**609 tests / 0 failures / 22 skipped** at `87eb2d7`).
4. No personal data is read without an explicit, persisted, revocable consent.
5. Blind input (B1) cannot execute without a previewed, confirmed target.
6. A model runs on the phone and is reachable from the Mac, with no root.

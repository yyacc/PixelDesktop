# ADR-018: Device Unattended Operation (Q8 Keyguard Policy + Q9 Thermal Policy)

**Status:** Accepted
**Date:** 2026-10-24
**Relates to:** `docs/PROPOSAL-DEVICE-INTERACTION.md` §7 (Q8, Q9 resolved), ADR-006 (serial forwarding),
ADR-017 (transport), `engineering/phases/phase-00-control-plane.md`

**Owner decisions recorded 2026-10-24:**
1. Q8 — leave the phone unlocked. Verbatim: *"Q8 - yes. leave the phone unlocked."*
2. Q9 — no context/batch cap for thermal. rnz runs an external cooler and accepts throttling.
   A notification must fire when the device reaches a dangerous temperature. Verbatim:
   *"Q9 - I have a cooler. a notification can be implemented once it reaches a dangerous temperature"*

---

## 1. Context

Phase 0 established the control plane; Phase 1 will run compute-node services on the device
(Termux + `llama-server`, ADR gates in the proposal §8). Two operational questions blocked that:

- **Q8.** A compute node that dozes and re-locks between host commands degrades service
  behavior (Termux background work, `llama-server` keep-alive) and adds a manual unlock step
  to every interaction. The trade-off is physical security of an unattended device.
- **Q9.** `dumpsys thermalservice` reports LITTLE 67 °C, BIG 74 °C while idle-charging.
  Sustained inference will throttle. The proposal asked whether to cap context/batch or accept
  throttling.

## 2. Decision

**Q8 — the phone stays unlocked and awake while charging.** Device configuration (verified
2026-10-24 on Pixel 7a `lynx`, Android 16 / SDK 36):

| Setting | Value | Effect |
|---|---|---|
| `settings put global stay_on_while_plugged_in 7` | `7` = AC\|USB\|wireless | screen never sleeps while charging |
| `settings put secure lockscreen.disabled 1` | `1` | keyguard suppressed on wake |
| `locksettings set-disabled true` | `true` | no credential prompt |

**Verification evidence (executed, not assumed):** after a full `KEYCODE_SLEEP` → `KEYCODE_WAKEUP`
cycle, `uiautomator dump` contains **zero** `keyguard*` nodes, `dumpsys window policy` reports
`mIsShowing=false`, and the launcher (`com.google.android.apps.nexuslauncher`) renders directly
with no PIN pad or swipe-up. The launcher is the focused window after wake.

**Methodology note (corrects the earlier session's read):** `locksettings set-disabled true`
alone is *insufficient* on Android 16 — after wake the keyguard still appears
(`keyguard_header`, `keyguard_carrier_text` present in the UI dump; `mIsShowing=true`) and only
`wm dismiss-keyguard` clears it. The `secure lockscreen.disabled 1` setting is what actually
suppresses the keyguard. An agent that only checks `locksettings get-disabled` will wrongly
conclude the device is usable.

**Accepted risk:** the device is physically accessible with no lock. This is deliberate —
an unattended compute node cannot require manual unlock per interaction. The screen locks by
proximity to the decision, not by an attacker model; rnz accepts this trade-off.

**Q9 — no thermal cap.** Context/batch sizes are not capped preemptively. rnz runs an external
cooler and accepts platform throttling as the safety mechanism. Throttling is the OS's problem
to manage; the system does not trade inference quality for thermal headroom proactively.

**Thermal alert requirement:** a notification must fire when the device reaches a dangerous
temperature. Trigger source is `dumpsys thermalservice` (no root required), which exposes:

- `Thermal Status` — platform classification: 0 NONE · 1 LIGHT · 2 MODERATE · 3 SEVERE ·
  4 CRITICAL · 5 EMERGENCY · 6 SHUTDOWN
- raw zone readings (LITTLE/MID/BIG/G3D/TPU, battery, skin sensors)

**Recommendation adopted:** trigger on `Thermal Status >= 4 (CRITICAL)` rather than a hardcoded
number — it is the platform's own per-device definition of "dangerous" and avoids the
arbitrariness of picking "75 °C". Raw zone readings are included as the alert payload so the
notification identifies *which* sensor. **Unit caveat:** `dumpsys battery` reports battery temp
in tenths of a degree (287 = 28.7 °C) while `thermalservice` reports °C directly — do not mix
the two sources' units.

## 3. Consequences

- Device-host interaction needs no manual unlock; Termux/`llama-server` reliability improves.
- Physical security risk accepted by rnz; not revisited unless circumstances change.
- Thermal policy does not cap workloads; alerting is the only thermal-facing behavior.
- Alert delivery is **not** implemented here — it lands in Phase 2 (A7 telemetry) / Phase 3
  (A5 notifications) per proposal §8, with this ADR as the written ADR the Phase 2 gate requires.
- If the root decision (Q4b) reverses, the keyguard configuration may need re-verification
  under the rooted environment.

## 4. Provenance

- Device settings verified live 2026-10-24 over USB (`adb shell settings get`, `locksettings get-disabled`,
  sleep/wake cycle with `uiautomator dump` + `dumpsys window policy`).
- Owner decisions rnz, 2026-10-24 (this session).
- Thermal readings from `dumpsys thermalservice` on the same session.

# Handoff: PixelDesktop — Phase 0 (control plane), device interaction

**Written:** 2026-10-24 · **Agent:** Ciel · **Session:** `20261024_183642_8a749c`
**Status:** ⚠️ **DESIGN GATE CLEARED · PHASE 0 IMPLEMENTED · PHASE 1 NOT APPROVED**
Proposal revision 2 was approved by rnz (`proceed`). Phase 0 of its §8 table is built, tested and
device-verified. **Phase 1 (Termux + llama-server, host service management, inference jobs) requires
a new approval** — the §8 gate table is per-phase, and a `proceed` for Phase 0 does not cover it.

---

## Repo state

- `~/AICompany/PixelDesktop`, working tree clean, HEAD is the commit that added this file.
- **650 tests, 0 failures, 26 skipped** (full suite, `xcodebuild test -scheme PixelDesktop`).
  Baseline before this phase was 609 / 0 / 22.
- Device: Pixel 7a (`lynx`), Android 16 / SDK 36, serial `DEADBEEF000000`, **USB only** — wireless
  ADB is `adb_wifi_enabled=0` and `192.168.1.7:5555` is offline (ADR-017 §1.1 carries a dated note).
- **The phone's OLED is dead. It does not display. Do not probe to re-establish this.** The
  framebuffer is alive, which is why `screencap` and `scrcpy` both work.

---

## What Phase 0 delivered

Source: `docs/PROPOSAL-DEVICE-INTERACTION.md` §8, row "0 — Control plane". Log and full evidence:
`engineering/phases/phase-00-control-plane.md`.

| Item | Where | Device-verified |
|---|---|---|
| A4 UI hierarchy dump | `PixelDesktop/Perception/` + **Perception** tab | 67 nodes, 15 tap targets, 2.5 s |
| A2 screenshot as evidence | `ADBDevicePerception.screenshot`, `ScreenshotStore` | 1080×2400 PNG, byte-identical to raw `adb` |
| A6 logcat | `LogcatStream`, `LogcatBuffer` | 500 parsed lines, clean stop |
| B3 port forwarding | `ADBPortForwarding` | create → list → remove, all green |
| Delete dead `Video/` | `rmdir PixelDesktop/Video` | gone (was empty) |
| Document scrcpy | `docs/SCRCPY-EXTERNAL-TOOL.md` + copyable commands in the pane | n/a |

Transport addition: `TransportProtocol.execOut` → `TransportBinaryResult`. **This is load-bearing**:
`execute` decodes stdout as UTF-8 and falls back to `""`, so a PNG would arrive as zero bytes with
exit code 0 — a silent data loss that looks like a blank screen.

**No input injection exists.** No tap, no type, no swipe, not even a disabled button. That is
Phase 2 and must arrive behind a dry-run preview (proposal P3).

---

## Next task

1. **Phase 1 approval** from rnz. Contents: C1 Termux + `llama-server` · B2 host service management ·
   C2 inference jobs. Gate is rnz approval, same table.
2. Four §7 questions are still open and will bite in Phase 1–2: **Q2b** wireless intent (off today),
   **Q4b** OEM unlock, **Q8** leave-unlocked policy, **Q9** thermal cap.
3. If work continues without Phase 1: the Perception pane is the natural place to add small things —
   but anything that acts on the device is Phase 2, not a convenience.

---

## Pitfalls hit this session (do not repeat)

- **`logcat -v threadtime` does not put a space before the tag's colon.** Short tags are padded
  (`chatty  : msg`), long ones are not (`ActivityManager: msg`). Splitting on `" : "` fails on every
  ordinary line. Split on the first `": "` instead. Caught by a real-shaped fixture, not by reasoning.
- **Payload size is not a correctness assertion for a screenshot.** A real 1080×2400 capture of a
  flat screen is 15,580 bytes; a `> 20_000` floor rejected a valid PNG. Use IHDR dimensions.
- **`uiautomator dump` can report failure while exiting 0** (`ERROR: could not get idle state.`).
  Reading the staged file after that describes a screen that no longer exists — check the text.
- **`xcodebuild` still does not forward `PIXELDESKTOP_DEVICE_SERIAL`** (ADR-006, re-confirmed: the 4
  device tests report "skipped" with the var exported). Use the `swiftc` harness path for real-device
  evidence: compile every source except `App/` and `StorageUI/`, plus a `main.swift`.
- **`xcodegen generate` is required after adding files** — sources are globbed from `PixelDesktop/`.
  Adding a file and building without regenerating produces a confusing "cannot find type" error.
- **Don't re-litigate the dead OLED.** It is settled; the user said so twice.

---

## History

The prior session's handoff (proposal drafting, the A1/scrcpy-conflict reasoning trail, and the
three corrections that produced revision 2) is in git history:
`git show 87eb2d7:HANDOFF.md`.

---

## Session metadata

- Date: 2026-10-24
- Agent: Ciel (Hermes)
- Session id: `20261024_183642_8a749c`
- Model: `deepseek/deepseek-v4.1-flash-1017` via openrouter

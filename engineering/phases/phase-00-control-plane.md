# Phase 0 — Control plane (device interaction)

**Date:** 2026-10-24
**Authorization:** rnz approved `docs/PROPOSAL-DEVICE-INTERACTION.md` revision 2 (`proceed`), which
unblocked Phase 0 of its §8 phasing table.
**Scope:** the six items in the proposal's Phase 0 row, and nothing beyond it.

| Item | Delivered | Verified |
|---|---|---|
| A4 UI hierarchy dump, wired in | `Perception/` + **Perception** tab | real device, 3 runs |
| A6 logcat | `LogcatStream` + pane | real device, 500 parsed lines |
| B3 port forwarding | `ADBPortForwarding` + pane | real device, create/list/remove |
| A2 screenshot as evidence | `ADBDevicePerception.screenshot` + pane | real device, 1080×2400 PNG |
| Delete dead `Video/` scaffold | `rmdir PixelDesktop/Video` | directory gone |
| Document scrcpy, no subsystem | `docs/SCRCPY-EXTERNAL-TOOL.md` + copyable commands in the pane | n/a (documentation) |

## What was built

New layer: `PixelDesktop/Perception/` — Foundation-only, so it compiles into both the app and the
CLI target.

| File | Role |
|---|---|
| `UIElement.swift` | `UIElementBounds`, `UIElement`, `UIHierarchy` — the dump as data |
| `UIHierarchyParser.swift` | `XMLParser`-based parser; rejects partial documents |
| `DevicePerceptionProtocol.swift` | `uiHierarchy` / `screenshot` seam, `ScreenshotStore`, `PNGSignature` |
| `ADBDevicePerception.swift` | implementation over `TransportProtocol` |
| `LogcatLine.swift` | threadtime line parser + `LogcatFilter` with tag validation |
| `LogcatStream.swift` | bounded `LogcatBuffer` + live stream over `shellStreaming` |
| `PortForwarding.swift` | `PortForwardingProtocol` + `ADBPortForwarding` |

One transport addition: `TransportProtocol.execOut` / `TransportBinaryResult`.

**Why `execOut` was required, not convenient.** `execute` decodes stdout as UTF-8 and falls back to
`""`. For a PNG that decode fails, so a capture would arrive as **zero bytes with exit code 0** — a
silent data loss that looks like a successful blank screen. The binary-safe sibling is what makes
A2 honest.

UI: a **Perception** tab (proposal §8 "wired in"), containing hierarchy dump + filter, screenshot
with preview, live logcat with priority floor and tag filter, forward management, and the three
scrcpy commands as copyable text. There is deliberately **no tap/type/swipe control**: input
injection is Phase 2 and must arrive behind a dry-run preview (proposal P3).

## Evidence (real device, serial `DEADBEEF000000`)

Harness: production sources compiled with `swiftc` (ADR-006 Option D — `xcodebuild` still does not
forward `PIXELDESKTOP_DEVICE_SERIAL`, re-confirmed this session: 4 device tests reported "skipped").

```
PASS hierarchy non-empty (67 nodes, 15 tap targets, 2.51s)
  package=com.android.systemui rotation=0
PASS labels present (21)
  labels: Wireless debugging | Internet,RCB | Bluetooth. | Auto-rotate screen | Modes.  | Hotspot
  INDEPENDENT focus: mCurrentFocus=Window{73b755 u0 NotificationShade}
PASS screenshot valid PNG (15580 bytes, 1080x2400)
  written: engineering/evidence/device-screenshot-phase0.png
PASS logcat parsed lines (500)
  first: 10-24 18:53:53.137 I/Telephony: TelecomAccountRegistry$AccountEntry: registerPstnPhoneAccount: Registe
PASS logcat stopped
PASS forward created and listed (tcp:18991 -> tcp:5035)
PASS forward removed
RESULT: PASS
```

Independent cross-check: the hierarchy reported `com.android.systemui` while raw
`dumpsys window` (not through project code) reported `mCurrentFocus=Window{… NotificationShade}`.
Those are the same window owner, so the dump describes the screen that actually had focus.

The screenshot was also compared byte-for-byte against raw `adb exec-out screencap -p`:
identical size (15,580 bytes) and identical IEND trailer, and `file` reports
`PNG image data, 1080 x 2400, 8-bit/color RGBA, non-interlaced`.

## Defects found while building (all fixed, all covered by tests)

### 1. The logcat tag/message split assumed a space before the colon

First implementation required `" : "` between tag and message. Real `logcat -v threadtime` output
pads the tag to eight characters and then writes `": "`, so a short tag arrives as
`chatty  : message` and a long one as `ActivityManager: message` — **there is no space before the
colon in the common case**. Every ordinary line failed to parse.

Caught by `testLogcatLineParsesThreadtime` (a real-shaped fixture) and fixed by splitting on the
first `": "` occurrence. A regression test for the padded form
(`testLogcatLineParsesPaddedShortTag`) was added, and the real-device run then parsed 500 lines
including a tag containing colons and `$` (`TelecomAccountRegistry$AccountEntry`).

### 2. A bogus "a screenshot can't be this small" threshold

The device-verification harness asserted `png.count > 20_000`. A real 1080×2400 capture of a
mostly-flat screen is **15,580 bytes**, so a perfectly valid capture failed the check. The file was
byte-identical to raw `adb` output, which is what proved the assertion wrong rather than the capture.

Replaced with a real invariant: `PNGSignature.dimensions` reads width/height from the IHDR chunk and
the test asserts the geometry is `{1080, 2400}`. Payload size is not a property of correctness.

### 3. `uiautomator dump` can report failure with exit code 0

Some builds print `ERROR: could not get idle state.` and still exit 0. Reading the staged file after
that would describe a screen that is no longer there, so `ADBDevicePerception.uiHierarchy` rejects
an error report in the dump output before reading the file. Covered by
`testUIHierarchyRejectsDeviceReportedErrorDespiteExitZero`.

## Test evidence

- New hermetic tests: `PixelDesktopTests/Phase0PerceptionTests.swift` — 35 tests, all passing.
- New device-gated tests: `PixelDesktopTests/Phase0DeviceVerificationTests.swift` — 4 tests,
  skipped without `PIXELDESKTOP_DEVICE_SERIAL` (ADR-006 convention).
- Full suite: **650 tests, 0 failures, 26 skipped** (was 609 / 0 / 22 before this phase).

## Scope boundaries held

- No `Video/` subsystem, no scrcpy protocol, no video decoding (proposal §6.4, ADR-008 §176).
- No input injection — not even a disabled button, because there is no backend for it.
- No new error cases: the existing `PixelDesktopError` vocabulary covered every failure found.
- `PixelDesktop/Video/` was an empty directory, so nothing was lost and nothing needed `git rm`.

## Next

Phase 1 (the node: Termux + `llama-server`, host service management, inference jobs) requires
rnz approval per the proposal's gate table. Four questions from §7 remain open — wireless intent,
OEM unlock, leave-unlocked policy, thermal cap.

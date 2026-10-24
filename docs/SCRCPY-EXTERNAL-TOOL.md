# scrcpy — external tool, not a subsystem

**Status:** binding. Decided 2026-10-24 by rnz (option a, `docs/PROPOSAL-DEVICE-INTERACTION.md` §6.4).

## The rule

PixelDesktop does **not** implement screen mirroring, video decoding, or the scrcpy protocol.
It documents the command and stays out of the way.

Three governing sources already said this, and none of them were written by this decision:

| Source | Says |
|---|---|
| `engineering/architecture/overview.md` §68 | "No `Video/` subsystem exists, and none is planned. scrcpy is not a PixelDesktop subsystem." |
| `engineering/decisions/ADR-008-android-device-model.md` §176 | A `Video/` subsystem "conflicts with the master prompt's *'not a better scrcpy frontend'* constraint" |
| `engineering/phases/phase-00-clean-start-audit.md` §279 | "Do not revive the legacy scrcpy/video architecture" without an ADR that requires it |

## Why, on this device specifically

The Pixel 7a's OLED panel is physically dead — it does not display. The framebuffer renders
perfectly, which is why `screencap` (in-app, A2) and `scrcpy` (external) both work: both read
the framebuffer, not the panel.

That makes mirroring genuinely useful here, and it also makes reimplementing it tempting. The
temptation is the risk: a video pipeline is a large subsystem with a codec, a transport, a
renderer and a lifecycle — and it would exist only to duplicate a tool that already does it
well. The project's value is the *control plane* (perception, operations, evidence), not a
second scrcpy.

## The commands

```bash
# live mirror over USB
scrcpy

# mirror and record to a file
scrcpy --record=session.mkv

# record only, no window (headless capture)
scrcpy --no-playback --record=session.mkv
```

Verified on this device 2026-10-24: `Texture: 1080x2400`, `Renderer: metal`, audio forwarding
working, exit 0. Evidence: `engineering/evidence/scrcpy-frame-20261024.png` and
`engineering/evidence/scrcpy-recording-20261024.mkv` (52.3 s, 15.9 MB).

The same three commands are offered as copyable text in the app's **Perception** pane, so the
user never has to remember them, and PixelDesktop never has to execute them.

## What would have to change for this to be revisited

A future decision to bring mirroring in-process would need a **new ADR** that:

1. states why the external tool is insufficient (not why an in-app version would be nicer);
2. resolves the three constraints above explicitly, rather than treating them as stale;
3. names the subsystem boundary and the codec/renderer choice;
4. accepts the maintenance cost of tracking scrcpy's protocol.

Until then, `PixelDesktop/Video/` does not exist — the empty directory was removed in Phase 0
(it held zero files and the two 0-byte scaffolds recorded in the Phase-0 audit were never
tracked by git).

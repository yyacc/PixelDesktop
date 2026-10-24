# Handoff: PixelDesktop — Device Interaction Proposal (Pixel 7a, dead OLED)

**Written:** 2026-10-24 · **Agent:** Ciel · **Session:** `20261024_131134_982fed`
**Status:** ~~DRAFT~~ → **A1 CONFLICT RESOLVED 2026-10-24 — rnz chose option (a).** Proposal revised to revision 2 and committed. Still design-gated: **await approval of the revised proposal before any implementation.** No code written.

---

## Context

- **Repo:** `~/AICompany/PixelDesktop` (macOS SwiftUI app). HEAD `25d05ce`.
- **Live artifact:** `docs/PROPOSAL-DEVICE-INTERACTION.md` (326 lines, DRAFT) — the deliverable.
- **Complementary:** `docs/PROPOSAL-REMOTE-STORAGE.md` (transport/storage).
- **Device:** Pixel 7a (`lynx`), Android 16 / SDK 36, build `BP3A.251005.004.B1`, serial `3C261JEHN25632`, USB.
- **Project state:** 593 tests, 0 failures, 22 skipped at `3d703cb` (proposal cites this baseline).

---

## The one thing that must not be re-litigated

**The phone's OLED is dead. It does not display anything.** The framebuffer is fully alive.

Confirmed by the user directly, twice, after the agent wasted calls probing `getevent` / `dumpsys input` to re-derive it:

> "why do you need to see which is broken?" → "it doesnt display. the oled is broken"

**Do not probe the device to re-establish this.** It is settled. The framebuffer rendering cleanly is *why* `screencap` and scrcpy both work.

### Verified scrcpy baseline (2026-10-24)

- scrcpy runs and mirrors the phone over USB. Two runs exited 0.
- Video: `Texture: 1080x2400`, `Renderer: metal`. Audio forwarding works.
- Evidence: `engineering/evidence/scrcpy-frame-20261024.png` (TikTok open, status bar 4:40, battery 100% charging) and `scrcpy-recording-20261024.mkv` (52.3 s, 15.9 MB).
- `/tmp/pixel_scrcpy.mp4` — 398 s, 160 MB, **now playable** (exit-0 run finalized the container; an earlier kill mid-write had left it unreadable).

---

## ✅ RESOLVED — the A1 / scrcpy conflict (decision 2026-10-24)

**rnz chose option (a): drop A1 entirely. scrcpy stays an external tool; no `Video/` subsystem.**

Applied to `docs/PROPOSAL-DEVICE-INTERACTION.md` (revision 2):

| Change | Where |
|---|---|
| A1 rewritten as **dropped** — documented `scrcpy` invocation, zero in-app video | §5 A1 |
| Full decision record: 3 options, choice, binding consequences | **§6.4** (new) |
| Verified scrcpy baseline (frame + recording, `Renderer: metal`) | **§2.1** (new) |
| A2 kept in-app (single ADB call); A3 folded into `scrcpy --record`, not a subsystem | §5 A2/A3 |
| §2 screen state corrected: **unlocked and in use**, not lockscreen | §2 |
| ADR-017 §1.1 marked stale (wireless OFF now, `adb_wifi_enabled=0`) | §7 Q2b + ADR-017 §1.1 status note |
| `Video/` (verified **0 files**) registered as `scheduled_for_removal` | `engineering/created-resources.json` |

The history below is kept for the reasoning trail.

---

## 🔴 The (former) blocking conflict — read before touching A1

**scrcpy is architecturally FORBIDDEN as a PixelDesktop subsystem.** Three sources say so:

| Source | Line | Says |
|---|---|---|
| `engineering/architecture/overview.md` | 68 | "**No `Video/` subsystem exists, and none is planned.** scrcpy is not a PixelDesktop subsystem" |
| `engineering/decisions/ADR-008-android-device-model.md` | 176 | adding `Video/` "conflicts with the master prompt's *'not a better scrcpy frontend'* constraint" |
| `engineering/phases/phase-00-clean-start-audit.md` | 279 | "**Do not revive the legacy scrcpy/video architecture** unless a later phase explicitly requires it and records that requirement in an ADR." |

The master engineering prompt constrains the architecture to *not* become "a better scrcpy frontend". `PixelDesktop/Video/` exists as an **empty directory** (`ScrcpyProcessService.swift`, `ScrcpyVideoTransport.swift` — 0 bytes, never implemented).

**The proposal's A1 as written violates this.** It says: *"Stream the framebuffer to the Mac as video (`scrcpy` protocol over the existing ADB transport), rendered in a SwiftUI view"* — i.e. reimplement scrcpy inside PixelDesktop. That is exactly what ADR-008 forbids.

### The unresolved decision for the next session

The user's correction was: *"i can use my phone right now through my mac since i can see its screen"* — scrcpy already solves the "eyes" problem, so A1 is a **subtraction**, not an addition.

But "adopt scrcpy into PixelDesktop" is the one option the ADRs rule out. **These two must be reconciled before A1 is rewritten.** Options, none chosen yet:

- **(a)** Drop A1 from PixelDesktop entirely. scrcpy stays an *external tool* the user runs (it already is). A1 becomes "scrcpy is available; document the command." No Video/ subsystem.
- **(b)** Record an ADR exception permitting a thin scrcpy *launcher/lifecycle* wrapper (spawn the process, show its window, manage start/stop) — explicitly **not** a protocol reimplementation. Still requires the ADR the audit demands.
- **(c)** Leave A1 out of Phase 0 and reclassify the "eyes" as a user-side concern, with PixelDesktop covering only headless perception (A4/A5/A6/A7).

**Do not pick one unilaterally.** This needs rnz's call — it is a constraint-vs-capability conflict, and the user is the final authority on the architecture (ADR-driven).

### ⚑ ANSWERED 2026-10-24 — option (a) (kept for the record)

**Question:** Is PixelDesktop allowed to show the phone's screen at all — and if so, how?

**Answer: (a) — scrcpy stays external, A1 dropped, no `Video/` subsystem.** See §6.4 of the proposal.

The user's stated reality: *"i can use my phone right now through my mac since i can see its screen"* — scrcpy already gives them the eyes, so A1 is a subtraction. But the ADRs forbid a `Video/` subsystem, so "just adopt scrcpy" is not free. **rnz must pick (a), (b), or (c).** Until then the proposal stays DRAFT and no implementation is permitted.

---

## Other corrections the proposal needs — **all three applied in revision 2**

1. **§2 line 52 was factually wrong.** It reads `Screen state | Lock screen, rendering correctly | Needs one-time unlock`. The scrcpy frame shows the phone is **unlocked and in use** (TikTok open, no lockscreen). This claim is stale and should be corrected or removed.
2. **ADR-017 §1.1 is stale.** It claims wireless ADB reachable at `192.168.1.7:5555`. That endpoint is `offline` now and `adb connect` times out. Device reports `adb_wifi_enabled=0`. USB works today. (This is proposal Q2b — already flagged, but the ADR itself still asserts the stale claim.)
3. **A2/A3 collapse into one dependency.** If scrcpy is used at all, `--record` *is* A3 and `screencap` *is* A2. They should not be designed as separate subsystems.

---

## Decisions recorded

- **d1 (prior session):** REVISE DESIGN — Option B not fundable until §5's probe runs; Option C (make offline cause *diagnosable*) unblocked and orthogonal. Implemented as commit `0f2bfe5` (ADR-017 Option C).
- **This session:** no new design decisions. The session produced verification and two corrections (above), plus the ADR conflict discovery.

---

## Done (this session)

- Captured scrcpy evidence → `engineering/evidence/scrcpy-frame-20261024.png`, `scrcpy-recording-20261024.mkv` (**untracked**, not committed).
- Verified both scrcpy runs exited 0; confirmed the older mp4 is now playable.
- Confirmed the ADR conflict (scrcpy forbidden as a subsystem).
- Wrote this handoff.

---

## Next task

1. **rnz approves (or rejects) revision 2** of `docs/PROPOSAL-DEVICE-INTERACTION.md`. That is the remaining gate.
2. On approval, Phase 0 = **A4 UI dump wired in · A6 logcat · B3 port forwarding · A2 screenshot-as-evidence · delete empty `PixelDesktop/Video/` · document the scrcpy invocation**. No video code, ever.
3. Open questions still unanswered: §7 Q2b (wireless is OFF today — confirm intent), Q4b (OEM unlock), Q8 (leave unlocked?), Q9 (thermal policy).
4. **Gate:** design-phase — no implementation until rnz approves the revised proposal.

---

## Pitfalls hit (do not repeat)

- **Do not probe device hardware to re-derive established facts.** The user explicitly pushed back ("why do you need to see which is broken?"). When the user states a premise, take it.
- **Check the ADRs before proposing a subsystem.** The scrcpy prohibition was in three files and the agent nearly proposed the forbidden thing. Read `engineering/architecture/` + `engineering/decisions/` before drafting.
- **`screencapture -R` on a pinned scrcpy window captures whatever is stacked on top.** The Hermes app window occluded it; the frontmost process was `Multica`, and scrcpy could not be raised. The **recording** (`--record`) is the reliable ground truth — it is independent of window stacking. Use that.
- **An ffmpeg failure on an mp4 does not mean the run failed.** A scrcpy killed mid-write leaves an unreadable container. Check the exit code; a clean exit-0 run finalizes it.

---

## Session metadata

- Date: 2026-10-24
- Agent: Ciel (Hermes)
- Session id: `20261024_131134_982fed`
- Model: `meituan/longcat-2.5-preview:free` via nous

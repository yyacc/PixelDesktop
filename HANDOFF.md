# Handoff: PixelDesktop — project context and goals

**Written:** 2026-10-25 · **Agent:** Ciel · **Session:** `20261024_213642_77b4ea` (updated `20261025_1037`)
**Status:** **Phase 3 APPROVED and 3.1 complete.** Trust foundation (D1 consent · D2 generalised audit ·
D3 universal dry run) is implemented, committed, and green at **746 tests / 26 skipped / 0 failures**.
**Next: Phase 3.2 (A5 notification stream).** 3.2–3.5 not started.
**Supersedes:** the Phase 0 handoff, archived to `docs/handoffs/handoff-pixeldesktop-phase0-control-plane.md`.

> This file is the entry point. It carries **the goal of the project** and the minimum context to
> resume. Detail lives in the linked artifacts — do not duplicate it here.

---

## 1. The goal

### 1.1 The north star

**The Pixel 7a's screen is physically dead. PixelDesktop is therefore the phone's only interface.**

That single fact is the whole project. It is not a phone-management tool with a broken screen as
an inconvenience — it is the *only* way to operate the device. Every capability the phone has
must be reachable from the Mac, and — because the Mac is now also the phone's eyes — **every
action must be observable from the Mac**.

### 1.2 The reframing that drives the design

PixelDesktop was **control-heavy and perception-poor**:

- **Control** — send commands to the phone. Largely built: transport (ADR-002), storage, app
  operations (ADR-009), worker install/run (ADR-010/011), local inference (ADR-012).
- **Perception** — see what the phone is doing and what happened. Almost entirely **missing**.

A working screen hides that gap: you tap, you look, you see. With a dead screen the gap becomes a
wall. Closing it is most of the remaining work.

### 1.3 The two rules

1. **No feature may require the phone's screen to be readable or tappable.**
2. **Every command must have an observable result** the Mac can render or log.

Rule 2 is already the project's culture (evidence harness, `ResultVerifier`, capability contract).
Rule 1 is new and is the actual design constraint.

### 1.4 The product — four groups

| Group | What | Leads? |
|---|---|---|
| **A — Perception** | See the phone: UI hierarchy, screenshot, logcat, notifications, telemetry | |
| **B — Control** | Act on the phone: input injection, services, port forwarding, install, reboot | |
| **C — The phone as a headless agent host** | On-device model serving, inference jobs, remote shell, scheduled tasks | **YES — rnz's Q6 call** |
| **D — Trust & safety** | Consent registry, command audit, universal dry-run, kill switch | |

**rnz's Q6 call is the strategic one:** *"Compute node or terminal?" → **compute node**.* Group C is
the product; Groups A and B are the control plane that makes it operable. Root buys almost nothing
for compute (§6.3 of the master proposal) — Termux + ADB is the intended path, no root.

### 1.5 The governance culture (non-negotiable)

- **One ADR per decision.** `engineering/decisions/` currently holds 19.
- **One phase gate at a time.** A `proceed` for Phase 0 does not cover Phase 1.
- **Evidence for every claim.** No "available because the infrastructure exists" — test it.
- **Design before implementation.** Proposals carry a decision gate; the owner decides.
- **The owner is rnz.** Direct, honest, no echo chamber. Final authority is his.

### 1.6 Where PixelDesktop sits in the wider architecture

```
rnz  →  Ciel (orchestrator)  →  Multica  →  PixelDesktop  →  Pixel 7a
```

PixelDesktop is the **Mac-side control plane** for the Pixel 7a, which is the compute node in the
AI-company stack (Ciel = CEO/orchestrator, Qwen = worker, LongCat = escalation/fallback).

---

## 2. Context

**Repo:** `~/AICompany/PixelDesktop` · working tree clean at the Phase 3.1 commit
**Suite:** **746 tests, 26 skipped, 0 failures** (full suite, `xcodebuild test -scheme PixelDesktop`)
**Device:** Pixel 7a (`lynx`), Android 16 / SDK 36, serial `3C261JEHN25632`, **USB only**

**The phone's OLED is dead. It does not display. Do not probe to re-establish this.** The
framebuffer is alive, which is why `screencap` and scrcpy both work. scrcpy is an **external tool**,
deliberately not a PixelDesktop subsystem (ADR-008, ADR-017, §6.4 of the master proposal).

### Device facts that matter right now

| Fact | Value | Consequence |
|---|---|---|
| Termux | **0.118.0 installed** (2026-10-24) | C1 is built; the master proposal §2 said "none installed" — **stale** |
| `/data` storage | **71 GB used / 38 GB free** | §2 said 60/50 — **stale** |
| Model | `gemma-3n-E4B-it-Q4_K_S.gguf`, 4.4 GB, staged `/data/local/tmp/` | C1's model is on device |
| Toolchain | clang 21.1.8, cmake 4.4.4, git 2.56.0, wget, curl | C1/C4 prerequisites present |
| Worker APK | `com.pixeldesktop.worker` **installed** | B4 has a real install/uninstall target |
| `adb root` | **refused** (production build) | no escalation path |
| `com.termux.permission.RUN_COMMAND` | **`prot=dangerous`** — `pm grant` exits 0 and **silently no-ops** | **the Termux wall** |
| `RunCommandService` | **refused** — "Requires permission" | no headless Termux channel |
| `dumpsys notification --noredact` | **works** — 759 KB, 0.11–0.14 s, 23 records | **A5 is viable, and exposes real message bodies** |
| `cmd notification list` | **works** — 1.7 KB, keys only | cheap change-detection tier |
| `cmd jobscheduler run` | exists; needs a `JobService` (worker APK has none) | Android-side scheduling needs an APK change |
| Mac `crontab` / `launchctl` | **available** | **the headless scheduler is already here** |

**rnz indicated (2026-10-25)** that the Termux permission is grantable via
**Settings → Termux → "Allow external apps to run commands"**. As of 2026-10-25 the wall is still
up and `RunCommandService` still refuses — that setting has **not yet been verified end-to-end**.
It is the path that would unblock Termux cron for C4 (proposal §4.1, decision Q3).

---

## 3. Where the work stands

| Phase | Name | Contents | Gate |
|---|---|---|---|
| 0 | **Control plane** | A4 UI dump · A6 logcat · B3 port forwarding · A2 screenshot · scrcpy documented | ✅ done 2026-10-24 |
| 1 | **The node** | C1 Termux + llama-server · B2 host service management · C2 inference jobs | ✅ done |
| 2 | **Hands** | B1 input injection (dry-run gated) · A7 telemetry + thermal history | ✅ done 2026-10-25, ADR-019 |
| 3 | **Durability** | A5 notifications · C4 scheduled tasks · C3 remote shell · B4/B5 · D1–D4 | 🔨 **3.1 done** — 3.2–3.5 open |

**Phase 3 is approved and in progress.** Proposal
`docs/PROPOSAL-PHASE-3-DURABILITY.md` (committed `23f0bb5`); all five §7.2 decisions taken as
recommended (**Q1a–Q5a**) and recorded in `ADR-020`. Any of the five can still be re-opened by rnz
before the sub-phase that depends on it ships — Q1 gates 3.2, Q2 gates 3.5, Q3 gates 3.4, Q5 gates 3.3.

### Phase 3's shape (5 sub-phases, trust layer first)

**3.1** trust foundation (D1 consent · D2 generalized audit · D3 universal dry-run) → **3.2** A5
notification stream → **3.3** B4 install/uninstall + B5 reboot → **3.4** C4 scheduled tasks →
**3.5** D4 kill switch (C3 remote shell deferred per Q2a).

| Sub-phase | Status | What exists |
|---|---|---|
| 3.1 Trust foundation | ✅ done 2026-10-25 | `Trust/ConsentRegistry.swift`, `Trust/DryRun.swift`, `Audit/DeviceAuditLog.swift`, `App/TrustView.swift` (new **Trust** tab), ADR-020, 31 tests |
| 3.2 A5 notifications | ⬜ next | nothing yet — the D1 gate it must use is ready |
| 3.3 B4/B5 | ⬜ | `DestructiveActionPlan` ready; no operation builds one |
| 3.4 C4 Mac scheduler | ⬜ | — |
| 3.5 D4 kill switch | ⬜ | — |

**Why 3.1 first:** A5 reads private messages and B4/B5 destroy state. Neither ships before the
consent gate and dry-run exist.

### Two findings that changed the Phase 3 design

1. **C4 as written (Termux cron) is blocked.** No headless channel reaches a Termux shell. The
   proposal recommends moving the scheduler to the **Mac** (`launchd`/`crontab`) — headless, no
   device change, survives reboots, hermetically testable. Recorded as decision **Q3**.
2. **A5 is not a metadata feed.** `dumpsys notification --noredact` returns message *bodies*. D1
   must be a hard gate that blocks the read, not a warning beside it.

### Execute-validated: the A5 parser

A prototype parser was run against a live dump rather than assumed. It caught a defect:
**a parser reading only `android.text` silently drops 16 of 23 notifications (70%)** — the body
usually lives in `textLines`, `subText` or `tickerText`. Reading all five gives 21/23 (91%).
Also measured: `cmd notification list` is **1.7 KB** vs `dumpsys` at **759 KB** (45×), which is
why the design is two-tier — poll the cheap list for change, fetch the full dump only on change.

---

## 4. Decisions rnz has already made

| # | Question | Answer |
|---|---|---|
| Q1 | Screen broken how? | Physically broken; framebuffer streams to Mac |
| Q2 | Wireless debugging on? | Yes — but `adb_wifi_enabled=0` on device (ADR-017 §1.1 is stale) |
| Q8 | May PixelDesktop show the screen? | **(a) No** — scrcpy stays external; no `Video/` subsystem |
| Q3 | Personal data access? | **Yes** — A5 unblocked, D1/D2 still required |
| Q4 | Rooted? | **No** |
| Q6 | Compute node or terminal? | **Compute node** — Group C leads |
| Q7 | Android version? | Android 16, SDK 36 |

---

## 5. Next task

1. **Build Phase 3.2 — A5 notification stream**, read-only (Q1a), gated by `ConsentGate` on
   `.notifications`. Three pieces, in this order:
   - **the two-tier reader**: poll `cmd notification list` (1,731 B) for the key set; fetch
     `dumpsys notification --noredact` (777,677 B) **only when the key set changed**;
   - **the five-field parser**: `android.title`, `android.text`, `android.textLines` (a *list*),
     `android.subText`, `tickerText` — a text-only parser drops 16 of 23 records (70%). Records with
     no extractable content are surfaced as `contentless`, never dropped;
   - **the view**, plus a `.notificationRead` audit record per read.
   Target: parser extracts content from **≥ 90%** of records on a captured real dump (prototype
   achieved 21/23 = 91%).
2. **Then 3.3 → 3.4 → 3.5** in order. Nothing else in Phase 3 needs a decision from rnz, except:
3. **Two probes still need rnz's authorization** because they mutate the device: an `adb uninstall`
   round-trip of the worker APK (needed by 3.3), and `cmd notification allow_listener` (needs an APK
   with a listener service, which does not exist — only relevant if push is ever wanted over polling).
4. **Verify the Termux setting** — Settings → Termux → "Allow external apps to run commands" — then
   re-test `am startservice … RunCommandService`. It is no longer on the critical path (Q3a moved the
   scheduler to the Mac), so this is now optional reconnaissance.

---

## 6. Pitfalls hit (do not repeat)

- **The Termux wall is real and silent.** `pm grant com.android.shell
  com.termux.permission.RUN_COMMAND` **exits 0 and does nothing**. Do not trust the exit code —
  read the granted list afterwards. `adb root` is refused; `run-as com.termux` says "not
  debuggable".
- **`logcat -v threadtime` does not space the tag's colon.** Short tags are padded
  (`chatty  : msg`), long ones are not (`ActivityManager: msg`). Split on the first `": "`, not
  `" : "`.
- **Payload size is not a correctness assertion for a screenshot.** A real 1080×2400 capture of a
  flat screen is 15,580 bytes; a `> 20_000` floor rejected a valid PNG. Use IHDR dimensions.
- **`uiautomator dump` can report failure while exiting 0.** Check the text, not the exit code.
- **`xcodebuild` does not forward `PIXELDESKTOP_DEVICE_SERIAL`** (ADR-006, re-confirmed). Use the
  `swiftc` harness path for real-device evidence.
- **`xcodegen generate` is required after adding files** — sources are globbed from `PixelDesktop/`.
- **Don't re-litigate the dead OLED.** It is settled; the user said so twice.
- **`execute` decodes stdout as UTF-8 and falls back to `""`** — a PNG would arrive as zero bytes
  with exit code 0. That is why `TransportProtocol.execOut` → `TransportBinaryResult` exists.
- **D2 and D3 are already half-built by Phase 2** (input-only). Generalize them; do not rebuild.
  *(Done in 3.1: `InputAuditLog` is deleted, not extended — input is now a filter over
  `DeviceAuditLog`.)*
- **`Character("\(n)")` traps for a two-digit `n`.** `ContentView` built keyboard shortcuts that
  way; a tenth tab (`trust`) would have crashed the app on first render. Use an explicit mapping
  (⌘1–⌘9, ⌘0).
- **Foundation's `.iso8601` JSON date strategy truncates to whole seconds.** That silently defeats
  any millisecond-ordering requirement. Use a custom strategy with `.withFractionalSeconds`, and
  assert the gap survives a disk round-trip.
- **`MockTransport` cannot prove append-before-execute.** It records invocations but cannot read the
  audit log mid-call, so an append-after-success log passes every assertion. Use a probe transport
  that inspects the log inside `shell(...)`.

---

## 7. Key artifacts

| Artifact | Path |
|---|---|
| **Master proposal (phasing authority)** | `docs/PROPOSAL-DEVICE-INTERACTION.md` |
| **Phase 3 proposal** | `docs/PROPOSAL-PHASE-3-DURABILITY.md` |
| Remote storage proposal | `docs/PROPOSAL-REMOTE-STORAGE.md` |
| scrcpy (external tool) | `docs/SCRCPY-EXTERNAL-TOOL.md` |
| Phase records | `engineering/phases/` (Phase 3.1: `phase-03-1-trust-foundation.md`) |
| ADRs (20) | `engineering/decisions/` (newest: **ADR-020 trust foundation**) |
| Phase 1 handoff | `docs/handoffs/handoff-pixeldesktop-phase1-device-verification.md` |
| Phase 2 handoff | `docs/handoffs/handoff-pixeldesktop-phase2-hands.md` |
| Phase 0 handoff (archived) | `docs/handoffs/handoff-pixeldesktop-phase0-control-plane.md` |

### Suggested skills for the next agent

- `handoff-doc` — keep this file current; update, don't duplicate
- `default-workflow` — Align → Plan → Execute → Verify → Handoff, per memory convention
- `design-authoring-and-review` — for any further proposal
- `architecture-artifact-authoring` — for phase records and ADRs
- `swift-code-review` / `swift-macos-development` — for the implementation work
- `test-driven-development` — the project's tests are the contract

---

## 8. Session metadata

- Date: 2026-10-25
- Agent: Ciel (Hermes)
- Session id: `20261024_213642_77b4ea`
- Model: `meituan/longcat-2.5-preview:free` via nous
- Last commit: `23f0bb5` — Phase 3 proposal, docs only, suite unchanged at 715 / 0 / 26

# Phase 3.3 preflight — device probes and Termux setting

**Date:** 2026-10-25
**Baseline:** `4b41703` — 776 tests, 30 skipped, 0 failures (Phase 3.2 complete)
**Gate:** rnz — *"Proceed with your recommendation, except for 8. enable allow external apps to run
commands"* (2026-10-25). That answers the Phase-3.2 decision checklist as: 1–7 as recommended,
8 changed from *skip* to *do it*.
**Device:** Pixel 7a `lynx`, serial `3C261JEHN25632`, Android 16 / SDK 36, USB.

This record closes the preflight items that 3.3 depends on. It contains **no product code** — it is
evidence, so that 3.3 starts from measured behaviour instead of remembered behaviour.

---

## 1. Decisions applied

| # | Decision | Consequence |
|---|---|---|
| 1 | Restate 3.2 criterion 2 as "≥ 90% of records **that carry content**" | `docs/PROPOSAL-PHASE-3-DURABILITY.md` §9 amended; 87.9% retained as diagnostic |
| 2 | Authorize one `adb uninstall` / reinstall round-trip of the worker APK | Probe A below |
| 3 | Authorize a real reboot test | Probe B below |
| 4 | Ship 3.3 as **two commits** (B4, then B5) | Commit plan for 3.3 |
| 5 | `compression.threshold_tokens` 96000 → **64000** | Hermes config; `protect_last_n` already 10 |
| 6 | Add a spend guardrail (daily balance check, alert < $0.50) | Hermes cron job |
| 7 | Adopt off-peak discipline for long phases | Working convention, no code |
| 8 | Enable Termux **allow external apps to run commands**, and verify it | Probe C below |

Items 5–7 are Hermes-runtime settings, not repo artefacts; they are recorded here for provenance and
verified in §5.

---

## 2. Probe A — B4 install/uninstall round-trip (authorized device mutation)

Success criterion 4 of the Phase-3 proposal ("B4 installs and uninstalls the worker APK on the real
device and leaves it healthy") cannot be demonstrated without mutating the device. This is that
mutation, run once.

| Step | Command | Result |
|---|---|---|
| 1 | `pm path com.pixeldesktop.worker` | `/data/app/~~K3HPz77V6xcKRtci7lHXew==/com.pixeldesktop.worker-pkGog2mh41Hf5anCs7Vv7A==/base.apk` |
| 2 | `adb pull <path>` | 6,150,926 bytes → `engineering/evidence/b4-b5-probes/worker-backup.apk`, sha256 `b3318d6d0729e41497a73e697f23412c5a531ca0cda2825e711bba224f90005f` |
| 3 | `dumpsys package` (before) | `versionCode=2`, `versionName=2.0` |
| 4 | `adb uninstall com.pixeldesktop.worker` | `Success` |
| 5 | `pm list packages \| grep -c pixeldesktop.worker` | **0** — package absent |
| 6 | `adb install worker-backup.apk` | `Success` |
| 7 | `pm list packages` / `dumpsys package` (after) | present; `versionName=2.0`; `firstInstallTime=2026-10-25 11:40:19` |

**Verdict: PASS.** The device was left healthy (probe B ran on it immediately afterwards), and the
captured bytes are pinned by sha256 so the exact binary under test is identifiable.

Note the artefact is **untracked on purpose**: `.gitignore:32` ignores `*.apk` because APKs are build
outputs. `worker-backup.apk` therefore exists on this machine only — regenerate it from the worker
build, and compare against the sha256 above before trusting a future round-trip as identical.

**Why this matters for 3.3:** `adb uninstall` + `adb install` are now known-good primitives on this
device, so B4's acceptance test can assert a real state transition (present → absent → present)
rather than a dry run.

---

## 3. Probe B — reboot (authorized; B5 precedent)

| Step | Result |
|---|---|
| Before | `sys.boot_completed=1`, uptime `4:44` |
| Issued | `adb reboot` at `03:41:09Z` (11:41 local) |
| Recovery | `sys.boot_completed=1` on the 3rd poll (~15 s); uptime `0 min` |
| ADB link | reattached over USB with **no** host-side re-authorization or intervention |
| Worker APK | `com.pixeldesktop.worker` present, `versionName=2.0` |
| A5 tier-1 read | `cmd notification list` returns records immediately post-boot |
| Perception | `screencap` renders (`engineering/evidence/b4-b5-probes/post-reboot-screen.png`, 1.30 MB) |

**Verdict: PASS.** A reboot is a safe, self-recovering action on this device: the link, the installed
packages and the perception tier all come back without a human touching anything. B5 therefore does
not need a "recovery" story beyond re-running `adb wait-for-device` — but it does need one, because
the command that issues the reboot loses its own transport.

---

## 4. Probe C — Termux "allow external apps to run commands"

### 4.1 Baseline: what fails, and at which layer

```
$ adb shell am startservice -n com.termux/.app.RunCommandService -a com.termux.RUN_COMMAND \
      --es com.termux.RUN_COMMAND_PATH /data/data/com.termux/files/usr/bin/true
Error: Requires permission com.termux.permission.RUN_COMMAND

logcat: Permission Denial: Accessing service com.termux/.app.RunCommandService
        from pid=25325, uid=2000 requires com.termux.permission.RUN_COMMAND
```

The denial is raised by `ActivityManager` **before** `RunCommandService` runs a single line, because
the service carries `android:permission` in Termux's manifest. Two facts follow:

- `com.termux.permission.RUN_COMMAND` is declared `prot=dangerous` (`dumpsys package com.termux`).
- `pm grant com.android.shell com.termux.permission.RUN_COMMAND` **exits 0 and changes nothing** —
  `dumpsys package com.android.shell | grep -i termux` is empty afterwards, because `com.android.shell`
  never declares the permission. This reproduces the claim in `HANDOFF.md` §2 and pins the cause: for
  a `dangerous` permission, `pm grant` only works for a package that requests it.

`pm list packages | grep -i termux` → only `com.termux`. No Termux:Tasker, no Termux:Widget.

### 4.2 The setting itself, enabled

ADB shell cannot write Termux's private storage, and Termux is not debuggable (`run-as` unavailable),
so the only channel is the interactive terminal — typed input against `TermuxActivity`, per the
`android-adb-device-management` skill (Rule 4): wake, launch, **3 s settle**, `input text` with
spaces as `%s`, then `KEYCODE_ENTER`.

Executed in Termux:

```sh
mkdir -p /data/data/com.termux/files/home/.termux
echo allow-external-apps=true >> /data/data/com.termux/files/home/.termux/termux.properties
termux-reload-settings
```

Verified from the **rendered frame**, not the write's exit status:

| Check | Evidence |
|---|---|
| Property written | `cat …/termux.properties` shows `allow-external-apps=true` appended to the stock template — `engineering/evidence/termux-external-apps/02-cat-properties.png` |
| Survives reboot | after probe B, `grep -c allow-external …` returns **3** — `…/03-post-reboot-grep.png` |

**Verdict: APPLIED and PERSISTENT.** Setting `allow-external-apps` is required by `RunCommandService`
and is now on, and it survives the reboot that ends the session.

### 4.3 What is still blocked, stated precisely

**Enabling the setting does not open the channel for an ADB-shell caller.** They are two independent
gates and the caller fails the first one:

| Gate | Checked by | State |
|---|---|---|
| Caller holds `com.termux.permission.RUN_COMMAND` | `ActivityManager` (manifest `android:permission`) | **BLOCKED** — `com.android.shell` cannot request or be granted it |
| `allow-external-apps=true` in `termux.properties` | `RunCommandService#onStartCommand` | **PASS** (as of §4.2) |

So `adb shell am startservice` remains refused for the same reason as before this probe. The setting
is necessary, not sufficient — a point the original plan did not distinguish.

### 4.4 Candidate fix (not implemented — needs a decision)

A package that **declares** the permission can be granted it. `com.pixeldesktop.worker` is ours:

```xml
<uses-permission android:name="com.termux.permission.RUN_COMMAND" />
```

then `pm grant com.pixeldesktop.worker com.termux.permission.RUN_COMMAND`, and the worker app forwards
a request to `com.termux/.app.RunCommandService`. Every step is non-root, and it turns the Termux wall
into an app-to-app contract instead of a shell-privilege problem.

It is **unverified**: the grant-half is inference from `pm grant` semantics, not an observation. It
also changes the worker APK's contract and would need its own ADR. Filed as an open decision, not
implemented in this session.

### 4.5 Pitfall worth carrying forward

The property ended up **three** times in the file after being typed once (`02` shows two, `03` shows
three). The duplication is harmless here — identical assignment, last-wins — but the cause was not
identified, and it means **interactive typing may deliver a command more than once**. Type only
idempotent commands through that channel; never `rm`, `mv`, or anything whose repetition changes state.

---

## 5. Runtime settings applied (items 5–7)

| Setting | Before | After | Verified |
|---|---|---|---|
| `compression.threshold_tokens` | 96000 | **64000** | `grep threshold_tokens ~/.hermes/config.yaml` |
| `compression.protect_last_n` | 10 | 10 (unchanged) | guards the smaller ceiling |
| Balance guardrail | none | daily cron `56089b466078` at 09:00, alert below $0.50 | `~/.hermes/scripts/deepseek_balance_watch.sh` — three paths executed: silent at $1.64 balance (default 0.50), one-line alert with forced 5.00, `FAILED` line with the key removed; delivery confirmed to `discord:1556240654655422484` |
| Off-peak convention | — | heavy phases outside 09:00–12:00 / 14:00–18:00 local weekdays | advisory |

DeepSeek balance at time of writing: **$1.64** (`GET /user/balance`).

The first delivered alert (manual run, 11:43:09) quoted a **$5.00** threshold, not $0.50: the run
executed the pre-edit script (file mtime 11:43:32, i.e. 23 s *after* the run). The script now on disk
defaults to 0.50 with no `DEEPSEEK_BALANCE_THRESHOLD` override anywhere in `.env`, the shell profile,
or `config.yaml`, so the 2026-10-26 09:00 run will be silent at the current balance. Delivery was
always the part that mattered and it works; the threshold quoted in that one message was stale.

A $0.50 floor leaves roughly one long phase of headroom, not two. If 3.3's B4/B5 work could cost more
than about $1, raise the floor — `DEEPSEEK_BALANCE_THRESHOLD` in the job environment is enough, the
script needs no edit.

---

## 6. What 3.3 now inherits

- Install/uninstall is a measured primitive (A), so **B4 ships first** and its acceptance test asserts
  a real present→absent→present transition.
- A reboot is safe and self-recovering (B), so **B5 follows** and may assume `adb wait-for-device`
  alone; it must not assume the phone's screen state, and it must re-establish perception itself.
- Termux remains closed to the ADB shell (C). **Nothing in 3.3 or 3.4 may plan on `RunCommandService`**
  until §4.4 is decided and built.
- The criterion-2 restatement is in the proposal, so 3.2 no longer carries a rubric it cannot meet.

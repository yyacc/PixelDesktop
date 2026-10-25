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
| 1 | 3.2 criterion 2 **revised** to "≥ 90% of records **that carry extractable content**" (a change, not a restatement) | `docs/PROPOSAL-PHASE-3-DURABILITY.md` §9 amended; revised result 29/29 = 100%; original criterion + its 29/33 = 87.9% miss retained verbatim |
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

**Decision (rnz, 2026-10-25): the threshold stays at $0.50 and the watchdog is frozen as it is.** Spend
is monitored manually through the DeepSeek provider console, with manual top-ups. The script and the
cron job are not to be refactored, "improved", or debugged further, and no time is to be spent on the
silent-failure question. The version-skew note above is history, not a work item.

---

## 6. What 3.3 now inherits

- Install/uninstall is a measured primitive (A), so **B4 ships first** and its acceptance test asserts
  a real present→absent→present transition.
- A reboot is safe and self-recovering (B), so **B5 follows** and may assume `adb wait-for-device`
  alone; it must not assume the phone's screen state, and it must re-establish perception itself.
- Termux remains closed to the ADB shell (C). **Nothing in 3.3 or 3.4 may plan on `RunCommandService`**
  until §4.4 is decided and built.
- Criterion 2 of 3.2 was **revised** by rnz on 2026-10-25: **≥ 90% of records that carry extractable
  content**, met at **29/29 = 100%**. The original wording and its result are retained verbatim — the
  original criterion was **MISSED at 87.9% (29/33)** and that measurement is unchanged. The revision is
  recorded as a change with its rationale in proposal §9 and in §8 below; nothing in
  `phase-03-2-notification-stream.md` §4 was rewritten. An earlier attempt to present the same
  denominator as a *restatement* was rejected; the rejection was about the framing, and this is not it.

---

## 7. B4 acceptance — executed on the device (approved 2026-10-25)

rnz approved **B4 only**, with seven conditions; **B5 (reboot / power-cycle) remains NOT approved**.
Full command-level record: `engineering/evidence/b4-b5-probes/B4-ACCEPTANCE-REPORT.md`.

Result: **PASS**, present → absent → present on `3C261JEHN25632`.

- Integrity first: backup sha256 `b3318d6d…005f` = build artifact = **the then-installed** `base.apk`.
  All three are the same binary, so the thing removed is the thing restored.
- Package identity unambiguous: `com.pixeldesktop.worker` (v2.0/2), distinct from
  `com.pixeldesktop.metadata` (v1.0) — the latter untouched, install time still 2026-09-22.
- `adb uninstall` → `Success`; absence proven three ways (`pm list` 0 hits, empty `pm path`,
  `am start` "Activity class … does not exist"); app data dir removed by the platform.
- `adb install -r worker-backup.apk` → `Success`; reinstalled APK hashes to the same sha256, fresh
  `firstInstallTime`.
- Function verified twice: identical deterministic result at the contract level, and
  `Phase7StreamingDeviceHarness/testLiveSmokeTest` **passed** (6 events, launch ack 0.161 s, result
  401 B, 0 stderr) through the shipped `WorkerStreamRunner`/`ADBTransport`/`WorkerLifecycle`.
- ADB link never dropped (same `transport_id`), nothing else on the device was modified, no reboot.

### Two findings this run produced

1. **The install path is not an identity.** `apkpath.txt`'s recorded path was already stale (the package
   had relocated); the sha256 was not. Any future restore must key on the hash. Recorded in the report.
2. **The proposal contradicts itself on B4's verification.** §5.5 asks for a real-device test that
   "installs and uninstalls the worker APK", while the same table requires the API to **refuse**
   uninstalling `com.pixeldesktop.worker`. A test through the guarded API can never produce that
   transition. **Resolved by rnz on 2026-10-25:** the B4 Swift acceptance test uses a **disposable
   side-loaded package**; the guarded API's refusal stays intact and unit-tested; the worker's own
   lifecycle keeps the raw-transport evidence recorded above. The three evidence types are kept
   distinct in §8 and are not treated as substitutes for one another.

### Tooling gap confirmed

`xcodebuild test` still does not forward `PIXELDESKTOP_DEVICE_SERIAL` (ADR-006), so live-device tests
cannot run through it. Working invocation — stage `PixelDesktop.debug.dylib` into the test bundle's
`Contents/Frameworks` (build products only; `DYLD_LIBRARY_PATH` is stripped because `xctest` is
SIP-protected), then `xcrun xctest -XCTest <bundle>` with the serial set. Exact commands in the report.

---

## 8. B4 Swift surface + criterion-2 revision (implemented 2026-10-25)

### 8.1 The three evidence types, and what each one establishes

They are separate on purpose. A pass in one is not evidence for another.

| # | Evidence | What it proves | What it cannot prove |
|---|---|---|---|
| 1 | **Transport-level worker lifecycle** — `B4-ACCEPTANCE-REPORT.md` | the worker APK survives present→absent→present byte-identically, with no reboot, and still works | says nothing about the Swift API's gate, audit or rendering |
| 2 | **Guarded-API unit tests** — `Phase3PackageOperationsTests` (19 tests, mock transport) | the gate refuses unconfirmed plans, the worker/protected/system refusals fire before any command, the preview equals the executed command, failures printed on stdout with exit 0 are recorded as failures | establishes nothing about hardware |
| 3 | **Swift acceptance on the device** — `Phase3PackageDeviceHarness` | the real `ADBPackageOperations` installs and uninstalls a real package on the real Pixel 7a and leaves the device as it found it | establishes nothing about the worker's own uninstall, which the API must refuse |

Type 1 does not stand in for 3 (different code path), and 3 does not stand in for 1 (different package).

### 8.2 The disposable package

| Property | Value |
|---|---|
| package id | `com.pixeldesktop.disposable.probe` |
| build | `engineering/evidence/b4-b5-probes/disposable/build-disposable-apk.sh` (aapt2 → zipalign → apksigner) |
| apk size / sha256 | 8,538 B / `e6a3eedac0176d003d22285ee41392f415a84a26562579d4ffe9795596793ec2` |
| permissions | none — the manifest declares no `<uses-permission>` |
| components | none — no activity, service, receiver or provider; `hasCode=false`, no dex |
| effect on device | one package entry + one empty data directory, both removed by the test's own uninstall |
| cleanup | the uninstall step of the acceptance test; if a run aborts, `adb -s <serial> uninstall com.pixeldesktop.disposable.probe` |
| blast radius if misused | cannot run, cannot read, cannot write, cannot receive; it holds no part in the ADB link, so it cannot affect transport |

Preflight refuses to run if the package is already installed (a leftover would make the test unable to
distinguish its own effect), and the test fails if the third-party package set at the end differs from
the baseline.

### 8.3 Criterion 2 — the revision, recorded as a change

- **Original criterion:** "extracts content from ≥ 90% of **records** on a captured real dump".
- **Original result:** **MISSED — 29/33 = 87.9%** (`phase-03-2-notification-stream.md` §4, unchanged).
- **Why unsuitable:** the denominator is every record, so the number moves with the notification mix.
  §3.2's own 91% (21/23) was measured on a dump with 2/23 contentless records; at 4/33 (12.1%) the same
  parser scores 87.9%. A contentless record can never enter the numerator, so the criterion penalises
  the dump, not the parser — and a parser returning nothing would score the same on those records.
- **Revised criterion:** "extracts content from ≥ 90% of **records that carry extractable content**".
- **Revised result:** **MET — 29/29 = 100%**.
- **Retained diagnostic:** 29/33 = 87.9% of all records, with the 4 contentless records identified in
  the 3.2 evidence.
- **Date / authority:** 2026-10-25, rnz. Recorded in proposal §9 with both wordings present.

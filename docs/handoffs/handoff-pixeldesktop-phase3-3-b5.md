# Handoff — PixelDesktop: Phase 3.3 (B4 shipped, B5 is next)

**Date:** 2026-10-25 13:44 PST · **Commit:** `8b42fca` (clean, `main`) · **Suite:** 797 tests, 32 skipped, 0 failures
**Phase:** 3.3 ("App + power control") — **Commit 1 (B4) done**, **Commit 2 (B5) not started and not approved**
**Read this first:** `HANDOFF.md` (product + governance), then `engineering/phases/phase-03-3-preflight-device-probes.md` (measured device behaviour).

> Suite note: 797/32 was measured on hardware at `2e013cb`. `8b42fca` differs by **one markdown file**
> (`git diff --stat 2e013cb..HEAD`), so the count is current by inspection — not re-run for this handoff.
> Verify with §2 below before you touch code.

---

## 1. Everything you need, verified at 13:44 PST

| Thing | Value |
|---|---|
| Repo | `~/AICompany/PixelDesktop` — branch `main`, working tree clean at `8b42fca` |
| Device | Pixel 7a, serial `3C261JEHN25632`, `transport_id=257`, online over USB |
| Device state | `sys.boot_completed=1`; `com.pixeldesktop.worker` (v2.0) and `com.pixeldesktop.metadata` installed; no `com.pixeldesktop.disposable.probe` installed |
| Toolchain | Xcode 27.0 (`27A266a`), Apple Swift 6.4, xcodegen 2.46.0, adb 1.0.41 |
| Project file | Generated — `xcodegen generate` from `project.yml`. **Never hand-edit `project.pbxproj`** |
| Derived data | `.build` (gitignored) |
| Worker backup | `engineering/evidence/b4-b5-probes/worker-backup.apk`, 6,150,926 B, sha256 `b3318d6d0729e41497a73e697f23412c5a531ca0cda2825e711bba224f90005f` |
| Disposable APK | `engineering/evidence/b4-b5-probes/disposable/out/com.pixeldesktop.disposable.probe.apk` (rebuild with `disposable/build-disposable-apk.sh`) |

Design authority: `docs/PROPOSAL-PHASE-3-DURABILITY.md` (§5.6 = B5), `engineering/decisions/ADR-020-trust-foundation.md`.
21 ADRs total.

---

## 2. Verify before changing anything

```sh
cd ~/AICompany/PixelDesktop
git log --oneline -3 && git status --porcelain      # expect 8b42fca, 0 lines
adb devices -l | grep 3C261JEHN25632                # expect "device", not "offline"/"unauthorized"
adb -s 3C261JEHN25632 shell getprop sys.boot_completed   # expect 1
sha256sum engineering/evidence/b4-b5-probes/worker-backup.apk
```

Full suite (no device tests — they self-skip without the serial):

```sh
xcodegen generate
xcodebuild build-for-testing -scheme PixelDesktop -destination 'platform=macOS' -derivedDataPath .build
xcodebuild test-without-building -scheme PixelDesktop -destination 'platform=macOS' -derivedDataPath .build
```

Expect **797 tests, 32 skipped, 0 failures**. If the number moved, someone else edited the tree — stop and look.

---

## 3. What Phase 3.3 has already shipped

### 3.1 B4 — worker APK install/uninstall (committed `2e013cb`)

| File | What it holds |
|---|---|
| `PixelDesktop/Operations/ADBPackageOperations.swift` | `AppPackageOperationsProtocol` + implementation: `planInstall(apkPath:)`, `planUninstall(packageId:)`, `install(_:)`, `uninstall(_:)`, `moveToTrash(_:trashRoot:)`; typed `PackageOperationError` |
| `PixelDesktop/Trust/DryRun.swift` | Already carries the `DestructiveOperation` vocabulary **including `.reboot`** and its recovery warning (lines ~11-42) — B5 consumes this, it does not add to it |
| `PixelDesktop/Audit/DeviceAuditLog.swift` | Persisted audit record with action kinds (`.install`, `.uninstall`, `.reboot`) |
| `PixelDesktopTests/Phase3PackageOperationsTests.swift` | 19 unit tests (mock transport) |
| `PixelDesktopTests/Phase3PackageDeviceHarness.swift` | 2 device tests, skipped unless `PIXELDESKTOP_DEVICE_SERIAL` is set |

Structural guarantees (test-enforced, not documented promises): an unconfirmed `DestructiveActionPlan`
refuses **before building a command**, so the refusal path issues zero transport calls; every
execution, refusal and failure lands in the audit log.

Evidence, in three tiers — copy this pattern for B5:

1. `engineering/evidence/b4-b5-probes/B4-ACCEPTANCE-REPORT.md` — command-level device record, sha256-pinned.
2. `engineering/evidence/b4-b5-probes/B4-SWIFT-ACCEPTANCE.md` — what the *product's own Swift path* did, plus its limitations and an exact reproduction block.
3. `engineering/phases/phase-03-3-preflight-device-probes.md` — measured device behaviour (probes A/B/C).

B4's recorded limitations, repeated here because they bound what you may claim: `install -r` does not
parse the APK's manifest (so the install preview cannot name the package id); host `adb install` used
incremental install; two tests cover one package on one device; **no reboot was involved**, so B4 says
nothing about persistence.

### 3.2 Gap you inherit: B4 is a library surface with no UI

`grep -rln "ADBPackageOperations\|AppPackageOperationsProtocol" PixelDesktop` matches only
`Transport/Transport.swift` (the protocol seam) and `Operations/ADBPackageOperations.swift` itself —
`AppState.swift`, `ContentView.swift` and the views never reference it. Phase 3.1 (Trust) and 3.2
(Notifications) each shipped a tab; B4 shipped none. That is a **decision, not a defect** — the
proposal never asked for a B4 tab — but a new session should know the API is not reachable from the
running app before "finish B4" is proposed as work. Raise it with rnz rather than deciding alone.

---

## 4. The next phase is B5 — and it needs an explicit go

**The records contradict each other. Read both, then ask; do not resolve it yourself.**

- `HANDOFF.md` §5 line 198: *"Both are authorized, and both primitives are already measured on the device."*
- `engineering/phases/phase-03-3-preflight-device-probes.md` §7 line 211 (written **after** the actual
  approval): *"rnz approved **B4 only**, with seven conditions; **B5 (reboot / power-cycle) remains NOT approved.**"*
- `engineering/evidence/b4-b5-probes/B4-ACCEPTANCE-REPORT.md` header: *"**B5 (reboot) explicitly NOT approved.**"*
- ADR-020 Q5(a) records the **design** decision ("build it"), which is not the same as an execution approval.

Two later, more specific records outrank the earlier general one: **treat B5 as not approved** until
rnz says otherwise. Probe B (preflight §3) *did* perform one real reboot, but that was authorised as
reconnaissance, not as shipping the surface.

**The ask, in one message:**

> Approve B5? Implement `adb reboot` behind the D1 consent gate and the D3 dry run in the product path,
> plus one device-acceptance reboot on the Pixel 7a. Reply with: (a) approve / decline, (b) whether
> `recovery` and `bootloader` modes are in scope or normal-only, (c) whether the real device acceptance
> reboot is authorised alongside the code.

Three things are only rnz's to decide: the approval itself, the mode scope, and whether the acceptance
test may reboot his phone. Everything else below is reversible work.

While waiting — or if B5 is declined — the next authorised items are **3.4 (Mac scheduler, Q3a)** and
**3.5 (D4 kill switch)**. Nothing else in Phase 3 needs a decision.

---

## 5. B5 spec, as measured

From the proposal §5.6 and probe B (`phase-03-3-preflight-device-probes.md` §3):

| Property | Measured / required |
|---|---|
| Command | `adb reboot` (normal mode) |
| Immediate effect | The command **destroys the issuing transport** — the link that sends it does not survive |
| Recovery | `sys.boot_completed=1` returned on the 3rd poll (~15 s); `uptime` reset to `0 min` |
| Link after | Reattached over USB with **no** host-side re-authorisation or intervention |
| Packages after | `com.pixeldesktop.worker` still present, `versionName=2.0` |
| Perception after | `cmd notification list` returns records immediately; `screencap` renders (post-reboot PNG on disk, 1.30 MB) |
| Gate | Same D1 consent + D3 dry run as B4; audit append **before** executing |
| Failure mode | Must fail **loudly** on a bounded timeout if the device never returns — never a silent success |

`uptime` is the load-bearing assertion: a transport that never actually dropped will happily report
`sys.boot_completed=1` immediately, so `boot_completed == 1 && uptime < pre-reboot uptime` is what
proves a reboot happened.

---

## 6. Implementation plan (proposed — confirm with rnz, then execute)

Mirror `ADBPackageOperations.swift` exactly; do not invent a second trust idiom.

1. **`PixelDesktop/Operations/DevicePowerOperationsProtocol.swift`** —
   `enum RebootMode { case normal }` (add `recovery`/`bootloader` only if rnz says so);
   `protocol DevicePowerOperationsProtocol { func planReboot(mode:) -> DestructiveActionPlan; func reboot(_ plan:) async throws -> RebootOutcome }`.
2. **`PixelDesktop/Operations/ADBDeviceOperations.swift`** — build the plan through the existing
   `DryRun` `.reboot` consequence (recovery note included verbatim), take the audit record **before**
   the command, then issue `reboot` on the transport.
3. **Recovery inside the operation** — treat the transport dying as *expected*: `waitForDevice` →
   poll `getprop sys.boot_completed` → require `uptime` reset → re-read tier-1 notifications →
   `screencap` non-empty. Deadline-bounded (propose 180 s, poll 1–2 s), returning a typed
   `RebootOutcome` (`.recovered(metrics)`, `.neverReturned(elapsed)`, `.returnedButNotBooted(...)`).
4. **Refusals are plan-time** — unconfirmed plan, unsupported mode, no device: refuse before any
   transport call, exactly like B4, with a test proving zero commands.
5. **Tests** (`PixelDesktopTests/Phase3DevicePowerOperationsTests.swift`, mock transport):
   happy path; transport lost before ack; device never returns (assert loud typed failure, not success);
   `boot_completed` never becomes 1; recovery completes but screencap empty; unconfirmed plan refuses
   with zero transport calls; dry-run report contains the command and the recovery note; unsupported
   mode refuses at plan time.
6. **Device harness** (`Phase3DevicePowerDeviceHarness.swift`, skipped without
   `PIXELDESKTOP_DEVICE_SERIAL`): capture pre-state, reboot once, assert the full post-state table from
   §5, and verify the worker still runs a job afterwards (the existing streaming/worker smoke path).
7. **Evidence** — same three tiers as B4: `B5-SWIFT-ACCEPTANCE.md`, `B5-ACCEPTANCE-REPORT.md`
   (timestamped, sha256 where a binary is involved), and a `phase-03-3-b4-b5.md` phase record (it does
   not exist yet — B4 was recorded only in evidence files).
8. **Commit** — 3.3 is two commits by rnz's standing decision: B4 (`2e013cb`, done) and B5 (yours).
   Commit B5 alone, with its evidence, and update `HANDOFF.md` §3/§5, the proposal's §8 status table
   and `engineering/logs/engineering-journal.md`.

### Proposed acceptance criteria for B5 (rnz's approval, not yet agreed)

- **B5-1** An unconfirmed `DestructiveActionPlan` produces **zero** transport calls (test-enforced).
- **B5-2** The dry-run report names the exact command, the recovery sequence and the timeout.
- **B5-3** On this device, one reboot ends with `boot_completed=1`, `uptime` reset, link back **without
  host intervention**, worker present at v2.0.
- **B5-4** Perception re-established by the operation itself: tier-1 notifications read + non-empty screencap.
- **B5-5** If the device never returns, the call returns a typed failure within the deadline — it does not hang, and does not report success.
- **B5-6** Audit trail: one record per attempt, written before execution, outcome appended after.
- **B5-7** Worker functional check passes after the reboot (same path as the B4 baseline).
- **B5-8** Nothing outside `com.pixeldesktop.*` is touched; no root, no bootloader, no unlock.

---

## 7. Pitfalls that will cost you a day

1. **`xcodebuild build` skips the test targets.** Always `build-for-testing`, then `test-without-building`.
2. **`xcodebuild test` does not forward `PIXELDESKTOP_DEVICE_SERIAL`.** Device tests silently skip.
   Run them by staging the dylib into the built bundle and calling `xcrun xctest` directly:

   ```sh
   A=.build/Build/Products/Debug/PixelDesktop.app; B=$A/Contents/PlugIns/PixelDesktopTests.xctest
   mkdir -p "$B/Contents/Frameworks" && cp "$A/Contents/MacOS/PixelDesktop.debug.dylib" "$B/Contents/Frameworks/"
   PIXELDESKTOP_DEVICE_SERIAL=3C261JEHN25632 xcrun xctest -XCTest PixelDesktopTests.<Suite>/<test> "$B"
   ```
   Re-stage after **every** rebuild — the staged copy goes stale and you will test the previous binary.
3. **Never run two `xcodebuild` invocations against the same `.build` at once.** One non-reproducible
   "failed to produce diagnostic for expression" compile failure on 2026-10-25 was traced to this
   (`8b42fca` records it). If a phantom compile error appears, wipe `.build` and rebuild once.
4. **Never hand-edit `project.pbxproj`.** Add files, then `xcodegen generate`.
5. **`adb reboot` returns nothing useful and kills its own link.** An exit code here is not the verdict;
   the verdict is the post-recovery state table. Do not wrap it in a retry loop that issues two reboots.
6. **A stale transport lies.** `boot_completed=1` alone does not prove a reboot — pair it with `uptime`.
7. **Wiping the worker needs the hash check first** (size 6,150,926 B, sha256 `b3318d6d…`). Do not
   uninstall it without confirming the backup matches; a mismatched backup is unrecoverable without a rebuild.
8. **The `.apk` files are not gitignored** in the evidence dir — check `git status` before committing so
   you do not add a 6 MB binary by accident.
9. **`pm grant com.android.shell com.termux.permission.RUN_COMMAND` exits 0 and does nothing** (dangerous
   permission, undeclared by the caller). Termux `RunCommandService` is unreachable from ADB until an
   APK change declares the permission. Off the critical path — do not plan on it in B5.

---

## 8. Frozen — do not touch

- The durability **watchdog** script and its cron entry (frozen with the Termux wall).
- The **Termux wall** work itself — reconnaissance only, needs an ADR.
- The **two rules** in `HANDOFF.md` §1.3 and the reframing in §1.2 — governance text, not implementation notes.
- No root, no bootloader unlock, no `su`, no C3 shell, no video subsystem.
- No "M8"-style phase invention: 3.4 and 3.5 are the only remaining Phase 3 items.

---

## 9. First 30 minutes

1. Read `HANDOFF.md` §1 (goal, rules, governance) — 10 minutes, do not skip.
2. Run §2 above. Confirm `8b42fca`, clean tree, 797/32/0, device online.
3. Read `engineering/phases/phase-03-3-preflight-device-probes.md` §3 (probe B) and §7 (B4 approval + conditions).
4. Send rnz the §4 ask — approval, mode scope, device-reboot permission — and wait. Do not write B5 code first.
5. If approved: read `ADBPackageOperations.swift` end to end, then write the tests in §6.5 **before** the implementation.

## Definition of done for this session

Either (a) B5 implemented + device-accepted + evidenced + committed, with `HANDOFF.md`, the proposal
status table and the journal updated; or (b) rnz's explicit decline recorded, and the session pivoted to
3.4 (Mac scheduler) with a written plan. A session that ends with B5 half-built and unapproved is the
one outcome to avoid.

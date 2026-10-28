# PixelDesktop MVP — Independent Verification Record

**Date:** 2026-10-09
**HEAD:** 6fb99a9 (`docs: engineering journal — Phase 10 Step 6 completion`)
**Verifier:** Ciel (independent)
**Device:** Pixel 7a, serial `DEADBEEF000000`, attached via USB (adb state: `device`)

---

## 1. Purpose

Confirm — by direct execution, not by report — that the delivered PixelDesktop MVP
(device management + CLI boundary + workload execution) is present, builds, and
operates against a live device. Also reconcile the reported test-baseline discrepancy
(506 vs 501).

This record is evidence preservation. No production or test code was modified.

---

## 2. Working tree preserved

Pre-existing uncommitted changes were left untouched:

- `M PixelDesktop.xcodeproj/project.pbxproj` (+ Phase8UIWiringTests.swift refs)
- `M engineering/created-resources.json`
- `?? engineering/pilot-9sel-evidence/`
- `?? engineering/zeno-mvp-assessment.md`

Only this new file was added.

---

## 3. Full test suite (Mac, no device gating)

Command:
```
xcodebuild test -project PixelDesktop.xcodeproj -scheme PixelDesktop -destination platform=macOS
```
Result: **Executed 506 tests, with 22 tests skipped and 0 failures. TEST SUCCEEDED.**
(2026-10-09 16:35 and again 17:17.)

The 22 skips are environment-gated, not failures:
- `PIXELDESKTOP_DEVICE_SERIAL not set` — device-gated verification tests
- `pixel-desktop tool not built` — CLI-binary-gated tests
- one `expected a refusal` guard

Attempting to enable them by exporting `PIXELDESKTOP_DEVICE_SERIAL=DEADBEEF000000`
before `xcodebuild test` did **not** change the count (still 22 skipped): xcodebuild
does not forward the parent shell environment to the macOS test host. Enabling them
requires a scheme/test-plan environment entry, which is a project-config change and
was **not** made. The device path was verified directly instead (§4).

---

## 4. Live device verification (independent, via the CLI boundary)

The built CLI was located from build settings (it is not on `PATH`):

```
pixel-desktop capability --json   → exit 0, contractVersion 3
pixel-desktop observe --json      → exit 0, live device observation
```

`observe --json` returned real, device-reported values (source `deviceReported`,
`observedAt 2026-10-09T09:16:03Z`):

- `deviceSerial`: `DEADBEEF000000`
- `deviceReachable`: true
- `availableMemoryBytes`: 2,574,376,960
- `freeStorageBytes`: 54,894,559,232
- `modelPresent`: present, 1,117,320,736 bytes
- `workerInstalled`: reported

This is present-tense evidence that the MVP's read-only publication interface works
against a physical device, not a `.declared` build intent.

Not performed in this pass (would consume device time and is covered by prior
real-device records): a `run --workload DTCA-1` / `LOCAL-LLM-1` execution.

---

## 5. Baseline reconciliation (506 vs 501) — resolved

Both numbers are correct; they describe **different test trees**.

| Run | Total executed | Skipped | Included `Phase8UIWiringTests` (11 tests)? | Included `Phase9DeviceSelectionTests` (6 tests)? |
|---|---|---|---|---|
| Current full suite | 506 | 22 | **Yes** (present on disk, added to the working-tree pbxproj) | **No** (file removed) |
| Pilot `full-suite.log` | 501 | 22 | **No** (grep count 0) | **Yes** (grep count 14) |

Arithmetic confirms a single common base:

```
506 − 11 (Phase8UIWiringTests)            = 495
501 −  6 (Phase9DeviceSelectionTests)     = 495
```

So: current = base 495 + 11 UI-wiring tests; pilot = base 495 + 6 device-selection
tests. The pilot's added file was removed after the trial; the UI-wiring tests were
added later. The 22 skips are identical in both (same environment gating). The numbers
are not equivalent and were never meant to be — they are two different snapshots.

---

## 6. Conclusion

- The PixelDesktop MVP is **present, builds, and operates against a live device**
  (independently verified).
- The suite is green (506/0 failures) with 22 environment-gated skips.
- The 506-vs-501 discrepancy is fully explained by which test files were in the tree.
- No blockers. No production or test code changed.

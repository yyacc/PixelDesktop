# B4 acceptance — real worker APK uninstall/reinstall round-trip

**Executed:** 2026-10-25 12:15–12:17 · **Device:** Pixel 7a, serial `3C261JEHN25632`, `transport_id=257`
**Approval:** rnz, 2026-10-25 — *"I approve proceeding with B4, the worker APK uninstall/reinstall
acceptance test on the Pixel 7a"*, with seven conditions. **B5 (reboot) explicitly NOT approved.**
**Outcome:** PASS. Present → absent → present, byte-identical binary, identical functional output
through the product's own Swift path. No other package touched, ADB never dropped, no reboot.

---

## 1. Pre-conditions, checked before anything was mutated

| Check | Expected | Measured | Verdict |
|---|---|---|---|
| Backup `worker-backup.apk` size | 6,150,926 B | 6,150,926 B | PASS |
| Backup sha256 | `b3318d6d0729e41497a73e697f23412c5a531ca0cda2825e711bba224f90005f` | identical | PASS |
| Build artifact `DTCA1Worker/app/build/outputs/apk/debug/app-debug.apk` | (provenance cross-check) | same size, **same sha256** | PASS — backup *is* the build output |
| Installed `base.apk` sha256 (pre-uninstall) | same as backup | identical | PASS — the binary about to be removed is the one backed up |
| Package identity | one exact id, no ambiguity | `com.pixeldesktop.worker` only; the other `pixeldesktop` package is `com.pixeldesktop.metadata` (v1.0, installed 2026-09-22), a different app | PASS |
| Installed version | v2.0 | `versionName=2.0 versionCode=2 minSdk=31 targetSdk=36` | PASS |
| ADB link | one device, no reconnect needed | `3C261JEHN25632 device usb:… transport_id:257` | PASS |

**Note on recorded install path.** `apkpath.txt` records
`/data/app/~~K3HPz77V6xcKRtci7lHXew==/com.pixeldesktop.worker-…/base.apk`, but at run time the package
lived at `…~~h7YCp2ZZYMw-fVF05glQjw==…`. The *path* is unstable (Android relocates on reinstall /
re-optimisation); the *content* was unchanged — verified by hashing the then-installed APK, which
matched the backup. **The sha256 is the stable identifier, not the path.**

## 2. Baseline functional run (before uninstall)

The worker is a single exported Activity with no service, no receiver and no network: it reads
`job.json` from its own app-specific external dir and writes `result.json` (ADR-010 revision 1).

```sh
D=/sdcard/Android/data/com.pixeldesktop.worker/files
adb shell "mkdir -p $D && ls -ld $D"          # drwxrws--- shell ext_data_rw
adb shell "rm -f $D/result.json"
adb push /tmp/b4-job.json $D/job.json         # 123 bytes
adb shell "am start -n com.pixeldesktop.worker/.WorkerActivity"
# poll: adb shell "[ -f $D/result.json ]"
adb pull $D/result.json b4-run/result-before-uninstall.json
```

`am start` output: `Starting: Intent { cmp=com.pixeldesktop.worker/.WorkerActivity }` — result
present after **2 s**, **401 bytes**:

```json
{"status":"COMPLETED","job_id":"5640EF9C-328C-4287-94B8-53C52A867831","input_characters":43,
 "total_words":9,"unique_words":8,"top_words":[{"word":"the","count":2},{"word":"brown","count":1},
 {"word":"dog","count":1},{"word":"fox","count":1},{"word":"jumps","count":1}],
 "classification":"NATURAL_LANGUAGE","confidence":0.3333333333333333,
 "execution_timestamp_ms":1792901752520,"execution_duration_ms":1}
```

The files dir did **not exist** before this run — the app had never been exercised on this install, so
the uninstall below destroyed no pre-existing app data beyond install metadata.

## 3. Uninstall and absence proof

```sh
adb uninstall com.pixeldesktop.worker        # Success   (exit 0)
adb shell 'pm list packages | grep -c "com.pixeldesktop.worker"'   # 0
adb shell "pm path com.pixeldesktop.worker"                        # (empty)
adb shell "am start -n com.pixeldesktop.worker/.WorkerActivity"
adb shell "ls -d $D"                                               # No such file or directory
adb devices -l; adb shell "echo adb-ok; getprop ro.product.model"
```

- `am start` → `Error type 3 · Error: Activity class {com.pixeldesktop.worker/…WorkerActivity} does
  not exist.` — absence is observable from the same surface the product uses to launch it.
- App-specific external dir removed by the platform, as designed.
- **ADB unaffected**: same serial, same `transport_id=257`, `adb-ok`, `Pixel 7a`. The worker app holds
  no role in the ADB link.

## 4. Reinstall from the pinned backup

```sh
adb install -r worker-backup.apk             # Performing Streamed Install · Success
P=$(adb shell "pm path com.pixeldesktop.worker" | sed 's/package://' | tr -d '\r')
adb shell "sha256sum $P"
adb shell 'dumpsys package com.pixeldesktop.worker | grep -E "versionName|versionCode|firstInstallTime"'
```

| Check | Result |
|---|---|
| Installed path | `/data/app/~~ORcxPBEftaBhMwObgvAr0g==/com.pixeldesktop.worker-fWuIzj1j-G2jEe59CXNb3Q==/base.apk` (new path, as expected) |
| Installed sha256 | `b3318d6d0729e41497a73e697f23412c5a531ca0cda2825e711bba224f90005f` — **identical to backup, build artifact and pre-uninstall install** |
| Version | `versionName=2.0 versionCode=2` |
| `firstInstallTime` | `2026-10-25 12:16:03` — genuinely a fresh install, not a no-op |

## 5. Functional verification after reinstall — two levels

**5a. Device level, same contract as the product.** New job id
`FE69E1F7-4D07-4D38-96C2-2C8B608D49E8`, same input. Result in **2 s**, **401 bytes**,
`status=COMPLETED`, `job_id` echoed correctly (anti-staleness contract intact). Comparing every
deterministic field against §2 — `status, input_characters, total_words, unique_words, top_words,
classification, confidence` — **all identical**; only `execution_timestamp_ms` /`execution_duration_ms`
differ, which is their purpose.

**5b. Product path (the real assertion).** `Phase7StreamingDeviceHarness/testLiveSmokeTest` drives the
shipped `WorkerStreamRunner` + `ADBTransport` + `WorkerLifecycle` against the reinstalled app:

```
Test Case '…testLiveSmokeTest' passed (1.124 seconds)
transport             : 3C261JEHN25632
outcome               : completed(resultJSON: {"status":"COMPLETED", …}, resultBytes: 401)
events received       : 6          heartbeats: 1
first event (s)       : 0.031      launch ack (s): 0.161
wall (s)              : 0.891
stderr lines          : 0          unrecognized lines: 0
```

The reinstalled app is indistinguishable from the one removed, through the code path the product
actually uses.

**Tooling gap this exposed (record it, don't rediscover it).** `xcodebuild test` still does not forward
`PIXELDESKTOP_DEVICE_SERIAL` (ADR-006), so live-device tests cannot run through it. They *can* be run
directly, with one staging step the built bundle needs:

```sh
A=.build/Build/Products/Debug/PixelDesktop.app
B=$A/Contents/PlugIns/PixelDesktopTests.xctest
mkdir -p "$B/Contents/Frameworks" && cp "$A/Contents/MacOS/PixelDesktop.debug.dylib" "$B/Contents/Frameworks/"
PIXELDESKTOP_DEVICE_SERIAL=3C261JEHN25632 xcrun xctest \
  -XCTest PixelDesktopTests.Phase7StreamingDeviceHarness/testLiveSmokeTest "$B"
```

Without the dylib copy, the bundle fails to load (`@rpath/PixelDesktop.debug.dylib` not found) and
`DYLD_LIBRARY_PATH` does not help because `xctest` is SIP-protected and strips it. The copy is into
build products only — no repository file is involved.

## 6. Blast radius, stated exactly

- **Destroyed:** `/sdcard/Android/data/com.pixeldesktop.worker/files/{job,result}.json` (both
  regenerable, and the dir was created by this run) plus install metadata.
- **Untouched:** `com.pixeldesktop.metadata` (v1.0, `firstInstallTime` still 2026-09-22 15:14:48),
  every other package, Termux, the "allow external apps to run commands" setting, all job/result files
  outside the worker's own dir, and the ADB link.
- **No reboot:** `/proc/uptime` = 2118 s at 12:17 → last boot ≈ 11:41 (the previous session's
  authorized B5 probe), `ro.boot.bootreason=reboot`. B5 was not exercised.

## 7. Recovery procedure (if this ever goes wrong)

1. **App missing or misbehaving:** `adb install -r engineering/evidence/b4-b5-probes/worker-backup.apk`
   — the pinned binary, byte-identical to the build output. Re-verify with
   `adb shell sha256sum $(adb shell pm path com.pixeldesktop.worker | sed 's/package://')`.
2. **Install refuses (version conflict):** `adb install -r -d worker-backup.apk` (allow downgrade),
   after confirming the installed `versionName` is what you expect — never blanket-force.
3. **ADB link lost:** replug USB, then `adb kill-server && adb start-server && adb wait-for-device`.
   No root, no `run-as`, no developer-options change is needed for any step in this procedure.
4. **Do not** restore the worker by pulling a stale `base.apk` path from `apkpath.txt` — that path has
   already changed twice. Use the sha256-pinned file.
5. **If the pinned APK is ever lost:** it is rebuildable. The worker's sources are tracked in the repo
   (`DTCA1Worker/app/src/main/java/com/pixeldesktop/worker/*.java`, `app/src/main/cpp/llama_jni.cpp`),
   and the APK is gitignored by `.gitignore:32` on purpose, so the binary is not a repo artifact. A
   rebuild must be re-hashed and compared against `b3318d6d…005f` before it is trusted as a substitute;
   if the hash differs, the toolchain changed and that difference must be explained, not papered over.

## 8. Finding for the phase, not a defect in the run

The proposal's §5.5 verification line says *"A real-device test installs and uninstalls the worker
APK"*, while the same table's rule says the API **refuses** to uninstall `com.pixeldesktop.worker`.
Both cannot hold for a test that goes through the API. As measured here, the round-trip is safely
performed at the **device/transport level** (raw `adb uninstall` + `adb install`), which is what the
acceptance test above does. When B4's Swift surface is built, its acceptance test must either drive the
raw transport, or uninstall a **disposable side-loaded package** as its present→absent→present
evidence — it can never prove the transition through the guarded API, because the guard forbids
exactly that package. This needs a one-line clarification in the proposal before B4 code is written.

---

### Artifacts

| File | Content |
|---|---|
| `worker-backup.apk` | pinned APK, sha256 `b3318d6d…005f`, 6,150,926 B |
| `apkpath.txt` | install path at capture time (path is not the identity — see §1) |
| `b4-run/result-before-uninstall.json` | baseline result, 401 B, job `5640EF9C…` |
| `b4-run/job-before-uninstall.json` | baseline job document, 123 B |
| `b4-run/result-after-reinstall.json` | post-reinstall result, 401 B, job `FE69E1F7…` |
| `b4-run/job-after-reinstall.json` | post-reinstall job document, 123 B |
| `B4-ACCEPTANCE-REPORT.md` | this report |

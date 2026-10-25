# B4 — Swift acceptance with a disposable package

Executed **2026-10-25 12:32** on Pixel 7a `3C261JEHN25632`.

Owner ruling (rnz, 2026-10-25): the B4 Swift acceptance test uses a **disposable side-loaded
package**; the guarded API's refusal to uninstall `com.pixeldesktop.worker` stays intact and
unit-tested; the worker's own lifecycle keeps the transport-level evidence already recorded in
`B4-ACCEPTANCE-REPORT.md`. **B5 remains NOT approved** — no reboot or power cycle was performed.

---

## 1. Three evidence types, kept separate

A pass in one is not evidence for another. This file contains type 3 only.

| # | Evidence | Location | Establishes | Does not establish |
|---|---|---|---|---|
| 1 | Transport-level worker lifecycle (raw `adb uninstall` / `adb install`) | `B4-ACCEPTANCE-REPORT.md` | the worker APK goes present→absent→present byte-identically, no reboot, still functional | nothing about the Swift API — no plan, no gate, no audit was involved |
| 2 | Guarded-API unit tests, mock transport | `PixelDesktopTests/Phase3PackageOperationsTests.swift` (19 tests) | the gate refuses unconfirmed plans, worker/protected/system refusals fire before any command, the preview equals the executed command, stdout `Failure` with exit 0 is recorded as a failure | nothing about hardware |
| 3 | Swift acceptance on the device, real package | `PixelDesktopTests/Phase3PackageDeviceHarness.swift` (2 tests) + this file | the real `ADBPackageOperations` installs and uninstalls a real package on the real device, refuses the worker on that device, and leaves the package set identical | nothing about the worker's uninstall, which the API must refuse |

Why the round trip is not performed on the worker here: the API refuses `com.pixeldesktop.worker`
**by design**, so an acceptance test driving the API can never produce the worker's
present→absent→present transition. Evidence 1 was recorded at the device/transport level for exactly
that reason, and this harness gives the same code path a target the API is allowed to act on.

---

## 2. The disposable package — identity, scope, cleanup, effect

| Property | Value |
|---|---|
| package id | `com.pixeldesktop.disposable.probe` |
| versionName / code | `1.0-disposable` / 1 |
| built by | `disposable/build-disposable-apk.sh` — aapt2 link → zipalign → apksigner (debug keystore) |
| size | **8,538 bytes** |
| sha256 | `e6a3eedac0176d003d22285ee41392f415a84a26562579d4ffe9795596793ec2` |
| permissions | **none** — no `<uses-permission>` in the manifest |
| components | **none** — no activity, service, receiver or provider |
| code | `android:hasCode="false"`, no dex |
| minSdk / targetSdk | 31 / 36 |

**Effect on the device:** one package entry under `/data/app` plus one empty private data
directory. Both are removed by the uninstall that ends the test. The package cannot run, cannot be
started, cannot be bound to, cannot receive broadcasts, cannot read or write anything outside its own
empty directory, and holds no part in the ADB link.

**Cleanup:** the test's own uninstall step. If a run aborts after installing, the failure message
prints `adb -s <serial> uninstall com.pixeldesktop.disposable.probe`; the installed state is verified
absent before the test will start at all.

**Stop conditions honoured:** the test refuses to begin if the package is already installed (it could
not then attribute the state to itself), fails if the third-party package set afterwards differs from
the baseline, and never touches another package. Nothing in this run could jeopardise ADB access.

---

## 3. What ran, verbatim

The APK was built once and reused; the path below is a build product, not a repo artifact.

```
$ adb shell 'pm path com.pixeldesktop.disposable.probe; pm list packages -3 | wc -l'
                                      43          <- not installed; 43 third-party packages
$ ... xcrun xctest -XCTest .../testWorkerPackageUninstallIsRefusedOnTheDevice
Test Case ... passed (0.127 seconds)
$ ... xcrun xctest -XCTest .../testDisposablePackageInstallUninstallRoundTrip
Test Case ... passed (1.082 seconds)
```

Harness output:

```
=== B4 SWIFT ACCEPTANCE — disposable package ===
device serial         : 3C261JEHN25632
disposable package    : com.pixeldesktop.disposable.probe
apk                   : …/disposable/out/com.pixeldesktop.disposable.probe.apk
third-party baseline  : 43 packages
worker present        : package:/data/app/~~ORcxPBEftaBhMwObgvAr0g==/com.pixeldesktop.worker-fWuIzj1j-G2jEe59CXNb3Q==/base.apk
install preview       : adb -s 3C261JEHN25632 install -r …/com.pixeldesktop.disposable.probe.apk
preview notes         : 3
install stdout        : Serving...
                        Performing Incremental Install
                        Success
                        Install command complete in 237 ms
installed at          : package:/data/app/~~S0P1bVFu254Y7ZC2_3gW0A==/com.pixeldesktop.disposable.probe-nz8PwHcPrgVnhvujR1hvHA==/base.apk
worker refusal        : Refusing to uninstall 'com.pixeldesktop.worker': it is the PixelDesktop worker package
uninstall preview     : adb -s 3C261JEHN25632 uninstall com.pixeldesktop.disposable.probe
uninstall stdout      : Success
audit records         : ["appInstall/refused", "appInstall/executed", "appUninstall/executed"]
outcome               : PASS (install + uninstall performed by the guarded API)
```

After the run, independently of the test:

```
$ adb shell 'pm path com.pixeldesktop.disposable.probe; pm list packages -3 | wc -l; pm path com.pixeldesktop.worker'
                       (empty)                 <- gone
                       43                      <- baseline restored
package:/data/app/~~ORcxPBEftaBhMwObgvAr0g==/com.pixeldesktop.worker-…/base.apk   <- same path as before
uptime:3065.29                                  <- no reboot (boot ≈ 11:41)
```

---

## 4. What the run actually establishes

1. **The gate holds on hardware, not just in the mock.** The unconfirmed plan was executed first and
   installed nothing; the package was still absent afterwards.
2. **The exact command is the executed command.** The preview string matched the argv the transport
   received; both are printed above.
3. **The worker is refused on the device it matters on.** Refusal happens before any device read or
   command — the worker's `pm path` was identical before and after.
4. **A real install and a real uninstall both succeed through the API**, with `Success` on both.
5. **Blast radius is exactly the disposable package.** Third-party package set: 43 → 44 → 43, with the
   only delta being `com.pixeldesktop.disposable.probe`.
6. **The audit trail is append-before-execute and matches reality**: `refused`, `executed`,
   `executed` — the refused record is the gate, not a silent no-op.

---

## 5. Limitations, stated rather than implied

1. **The install side does not know what it is installing.** `install -r` takes a path; the APK's
   binary manifest is not parsed, so the package id inside is unknown to the API before the command
   runs. Handing it the worker's own APK would replace the worker. Every install preview says so in
   its notes. Closing this needs an APK manifest reader, which is not in scope for B4.
2. **`adb install` used incremental install** (`Performing Incremental Install`) — a modern
   build-tools behaviour, not a property of the API. The package landed correctly and hashed as
   expected, but a different host toolchain may take the non-incremental path.
3. **Two tests cover the surface.** They exercise install/uninstall of one package on one device.
   They do not cover concurrent operations, a device disconnect mid-install, split APKs, or
   `INSTALL_FAILED_*` variants beyond what the unit tests model.
4. **The device is not rebooted or power-cycled**, so nothing here says anything about B4's
   persistence across a reboot. That is B5, which is not approved.
5. **The worker lifecycle evidence (type 1) is unchanged and was not re-run** for this work.

---

## 6. Reproduction

```sh
# 1. build the disposable APK (once)
engineering/evidence/b4-b5-probes/disposable/build-disposable-apk.sh

# 2. build for testing, stage the dylib into the test bundle (build products only)
xcodegen generate
xcodebuild build-for-testing -scheme PixelDesktop -destination 'platform=macOS' -derivedDataPath .build
A=.build/Build/Products/Debug/PixelDesktop.app; B=$A/Contents/PlugIns/PixelDesktopTests.xctest
mkdir -p "$B/Contents/Frameworks" && cp "$A/Contents/MacOS/PixelDesktop.debug.dylib" "$B/Contents/Frameworks/"

# 3. run the acceptance tests (both skipped when the serial is unset)
PIXELDESKTOP_DEVICE_SERIAL=3C261JEHN25632 \
PIXELDESKTOP_DISPOSABLE_APK="$PWD/engineering/evidence/b4-b5-probes/disposable/out/com.pixeldesktop.disposable.probe.apk" \
  xcrun xctest -XCTest PixelDesktopTests.Phase3PackageDeviceHarness/testDisposablePackageInstallUninstallRoundTrip "$B"
```

`xcodebuild test` still cannot run these: it does not forward `PIXELDESKTOP_DEVICE_SERIAL` to the
test host (ADR-006, re-confirmed), and `DYLD_LIBRARY_PATH` is stripped because `xctest` is
SIP-protected — hence the dylib staging above.

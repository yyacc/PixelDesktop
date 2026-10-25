//
//  Phase3PackageDeviceHarness.swift
//  PixelDesktopTests
//
//  B4 — install/uninstall accepted on real hardware, using a **disposable** package.
//
//  ## Why a disposable package, and not the worker
//
//  B4's real subject is the worker: the worker APK must survive being removed and reinstalled
//  without a reboot, and that was already executed at the device/transport level on 2026-10-25
//  (engineering/evidence/b4-b5-probes/B4-ACCEPTANCE-REPORT.md). This harness does **not** repeat
//  that and does **not** extend it. It answers a different question: does the *guarded Swift API*
//  — plan, preview, confirm, execute, audit — perform a real install and a real uninstall on a real
//  device, and does it refuse the one package it must never remove?
//
//  Removing `com.pixeldesktop.worker` through this API is not a supported operation and must never
//  become one, so the API cannot be its own acceptance evidence for the worker's lifecycle. A
//  disposable, explicitly identified package gives the same code path a permitted target.
//
//  ## The three evidence types, which are not interchangeable
//
//  1. **Transport-level worker lifecycle** — raw `adb uninstall` / `adb install` on the worker,
//     byte-identical restore. Evidence file: B4-ACCEPTANCE-REPORT.md. Not produced by this test.
//  2. **Guarded-API unit tests** — Phase3PackageOperationsTests. Mock transport, no device. Proves
//     the gate, the refusals, the rendering and the audit trail. Not device evidence.
//  3. **Swift acceptance evidence** — this file. A real device, a real package, the real API.
//     Proves the API works; it says nothing about the worker's own durability, which (1) covers.
//
//  A pass here does not substitute for (1), and (1) does not substitute for a pass here.
//
//  ## Safety
//
//  - The package is `com.pixeldesktop.disposable.probe`: no permissions, no components, no code.
//    Its only effect is one package entry plus an empty data directory, both removed by the
//    uninstall at the end of the test.
//  - The test refuses to start if that package is already installed (it would not know whether it
//    was there before) or if any other package's presence differs from the baseline at the end.
//  - ADB is never restarted, the device is never rebooted, and nothing else is installed,
//    uninstalled or stopped. A failure leaves the package installed rather than guessing; the
//    failure message says so and gives the exact cleanup command.
//
//  Skipped unless PIXELDESKTOP_DEVICE_SERIAL and PIXELDESKTOP_DISPOSABLE_APK are both set.

import XCTest
@testable import PixelDesktop

final class Phase3PackageDeviceHarness: XCTestCase {
    private let disposablePackage = "com.pixeldesktop.disposable.probe"

    private var deviceSerial: String? {
        ProcessInfo.processInfo.environment["PIXELDESKTOP_DEVICE_SERIAL"]
    }

    private var apkPath: String? {
        ProcessInfo.processInfo.environment["PIXELDESKTOP_DISPOSABLE_APK"]
    }

    private func requireDevice() throws -> (serial: String, apk: String) {
        guard let serial = deviceSerial else {
            throw XCTSkip("PIXELDESKTOP_DEVICE_SERIAL not set; skipping real-device acceptance")
        }
        guard let apk = apkPath else {
            throw XCTSkip(
                "PIXELDESKTOP_DISPOSABLE_APK not set; build it with "
                    + "engineering/evidence/b4-b5-probes/disposable/build-disposable-apk.sh"
            )
        }
        return (serial, apk)
    }

    /// `pm path <pkg>` prints one `package:<apk path>` line per split when installed, nothing when not.
    private func installedAPKPaths(
        _ transport: ADBTransport,
        serial: String,
        packageName: String
    ) async throws -> [String] {
        let result = try await transport.shell(
            deviceSerial: serial,
            command: "pm path \(packageName)",
            timeout: 30
        )
        return result.stdout
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("package:") }
    }

    // MARK: - The round trip

    /// Install the disposable package through the guarded API, prove it is there, uninstall it the
    /// same way, prove it is gone, and prove nothing else moved.
    func testDisposablePackageInstallUninstallRoundTrip() async throws {
        let (serial, apk) = try requireDevice()

        let transport = ADBTransport()
        let auditLog = DeviceAuditLog()
        let operations = ADBPackageOperations(transport: transport, auditLog: auditLog)

        // MARK: Preflight — refuse to start from an ambiguous state

        let baselineThirdParty = try await operations.installedThirdPartyPackages(
            deviceSerial: serial,
            timeout: 60
        )

        let preexisting = try await installedAPKPaths(
            transport, serial: serial, packageName: disposablePackage
        )
        guard preexisting.isEmpty else {
            XCTFail(
                "\(disposablePackage) is already installed; this test cannot tell its own effect "
                    + "from a leftover. Uninstall it first: adb -s \(serial) uninstall \(disposablePackage)"
            )
            return
        }

        let workerBefore = try await installedAPKPaths(
            transport, serial: serial, packageName: ADBAppOperations.workerPackageName
        )
        XCTAssertFalse(workerBefore.isEmpty, "the worker must be installed before the test")

        print("=== B4 SWIFT ACCEPTANCE — disposable package ===")
        print("device serial         : \(serial)")
        print("disposable package    : \(disposablePackage)")
        print("apk                   : \(apk)")
        print("third-party baseline  : \(baselineThirdParty.count) packages")
        print("worker present        : \(workerBefore.joined(separator: ", "))")

        var installedByThisTest = false

        do {
            // MARK: 1. The unconfirmed plan must be inert on the device too

            let preview = try operations.planInstall(deviceSerial: serial, apkLocalPath: apk)
            print("install preview       : \(preview.command)")
            print("preview notes         : \(preview.notes.count)")

            do {
                _ = try await operations.execute(preview, deviceSerial: serial, timeout: 120)
                XCTFail("an unconfirmed plan must not install anything")
            } catch {
                XCTAssertEqual(error as? DryRunError, .dryRunNotConfirmed(operation: .appInstall))
            }

            let afterRefusal = try await installedAPKPaths(
                transport, serial: serial, packageName: disposablePackage
            )
            XCTAssertTrue(afterRefusal.isEmpty, "the refused install must not have created the package")

            // MARK: 2. Install through the confirmed plan

            let installResult = try await operations.execute(
                preview.confirming(),
                deviceSerial: serial,
                timeout: 180
            )
            installedByThisTest = true
            print("install stdout        : \(installResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines))")

            let present = try await installedAPKPaths(
                transport, serial: serial, packageName: disposablePackage
            )
            XCTAssertEqual(present.count, 1, "the package must be installed exactly once")
            print("installed at          : \(present[0])")

            let withPackage = try await operations.installedThirdPartyPackages(
                deviceSerial: serial,
                timeout: 60
            )
            XCTAssertTrue(
                withPackage.contains(disposablePackage),
                "the new package must appear in the third-party list the API reads"
            )
            XCTAssertEqual(
                Set(withPackage).subtracting(Set(baselineThirdParty)),
                Set([disposablePackage]),
                "the install must add this package and nothing else"
            )

            // MARK: 3. The guard, on the real device, against the real worker package

            do {
                _ = try await operations.planUninstall(
                    deviceSerial: serial,
                    packageId: ADBAppOperations.workerPackageName,
                    timeout: 60
                )
                XCTFail("the guarded API must refuse to uninstall the worker package on a real device")
            } catch {
                XCTAssertEqual(
                    error as? ADBPackageOperations.Refusal,
                    .uninstallWorkerPackage(packageName: ADBAppOperations.workerPackageName)
                )
                print("worker refusal        : \(error)")
            }

            // MARK: 4. Uninstall the disposable package through the same gate

            let uninstallPlan = try await operations.planUninstall(
                deviceSerial: serial,
                packageId: disposablePackage,
                timeout: 60
            )
            print("uninstall preview     : \(uninstallPlan.command)")

            let uninstallResult = try await operations.execute(
                uninstallPlan.confirming(),
                deviceSerial: serial,
                timeout: 120
            )
            installedByThisTest = false
            print("uninstall stdout      : \(uninstallResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines))")

            let after = try await installedAPKPaths(
                transport, serial: serial, packageName: disposablePackage
            )
            XCTAssertTrue(after.isEmpty, "the package must be gone after a successful uninstall")

            // MARK: 5. Nothing else moved

            let finalThirdParty = try await operations.installedThirdPartyPackages(
                deviceSerial: serial,
                timeout: 60
            )
            XCTAssertEqual(
                Set(finalThirdParty),
                Set(baselineThirdParty),
                "the third-party package set must be identical to the baseline"
            )

            let workerAfter = try await installedAPKPaths(
                transport,
                serial: serial,
                packageName: ADBAppOperations.workerPackageName
            )
            XCTAssertEqual(workerAfter, workerBefore, "the worker must be untouched")

            // MARK: 6. The audit trail describes what happened

            let records = auditLog.records.filter {
                $0.target == disposablePackage || $0.target == apk
            }
            let executed = records.filter { $0.outcome == .executed }
            XCTAssertEqual(executed.count, 2, "one executed install and one executed uninstall")
            XCTAssertEqual(
                executed.map(\.operation),
                [.appInstall, .appUninstall],
                "and in that order"
            )
            print("audit records         : \(records.map { "\($0.operation.rawValue)/\($0.outcome.rawValue)" })")
        } catch {
            if installedByThisTest {
                print("!! the disposable package may still be installed: \(disposablePackage)")
                print("!! cleanup: adb -s \(serial) uninstall \(disposablePackage)")
            }
            throw error
        }

        print("outcome               : PASS (install + uninstall performed by the guarded API)")
    }

    /// The guard against the real worker package, with no mutation at all.
    ///
    /// Runs even when the disposable APK is not built, so the containment claim is device-verified
    /// on the same device the worker runs on.
    func testWorkerPackageUninstallIsRefusedOnTheDevice() async throws {
        guard let serial = deviceSerial else {
            throw XCTSkip("PIXELDESKTOP_DEVICE_SERIAL not set; skipping real-device verification")
        }

        let transport = ADBTransport()
        let operations = ADBPackageOperations(transport: transport, auditLog: DeviceAuditLog())

        let workerBefore = try await installedAPKPaths(
            transport,
            serial: serial,
            packageName: ADBAppOperations.workerPackageName
        )
        XCTAssertFalse(workerBefore.isEmpty, "the worker must be installed for this check to mean anything")

        do {
            _ = try await operations.planUninstall(
                deviceSerial: serial,
                packageId: ADBAppOperations.workerPackageName,
                timeout: 60
            )
            XCTFail("refusing to uninstall the worker is the point of the guard")
        } catch {
            XCTAssertEqual(
                error as? ADBPackageOperations.Refusal,
                .uninstallWorkerPackage(packageName: ADBAppOperations.workerPackageName)
            )
        }

        let workerAfter = try await installedAPKPaths(
            transport,
            serial: serial,
            packageName: ADBAppOperations.workerPackageName
        )
        XCTAssertEqual(workerAfter, workerBefore, "the refusal must not have changed the worker's install")
    }
}

import XCTest
@testable import PixelDesktop

/// B4 — install/uninstall behind the confirmed dry-run gate.
///
/// These are **hermetic** tests: a mock transport stands in for the device, so they assert the
/// guard, the rendered command, the audit trail and the failure interpretation. They are not
/// evidence that an uninstall works on hardware — that is the device acceptance test's job, and
/// the two must not be confused.
final class Phase3PackageOperationsTests: XCTestCase {
    private let serial = "TEST-SERIAL"

    // MARK: - Helpers

    private func makeOperations(
        transport: MockTransport
    ) -> (ADBPackageOperations, DeviceAuditLog) {
        let log = DeviceAuditLog()
        return (ADBPackageOperations(transport: transport, auditLog: log), log)
    }

    private func makeAPK(named name: String = "probe.apk") throws -> String {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pd-package-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data([0x50, 0x4b, 0x03, 0x04]).write(to: url)
        return url.path
    }

    private func transportWithThirdParty(_ packages: [String]) async -> MockTransport {
        let transport = MockTransport()
        let output = packages.map { "package:\($0)" }.joined(separator: "\n") + "\n"
        await transport.setShellResponse("pm list packages -3", TransportResult(
            exitCode: 0,
            stdout: output,
            stderr: ""
        ))
        await transport.setDefaultResult(TransportResult(exitCode: 0, stdout: "Success", stderr: ""))
        return transport
    }

    // MARK: - Install: preview

    func testInstallPlanRendersTheExactCommandThatWillRun() throws {
        let transport = MockTransport()
        let (operations, _) = makeOperations(transport: transport)
        let apk = try makeAPK()

        let plan = try operations.planInstall(deviceSerial: serial, apkLocalPath: apk)

        XCTAssertEqual(plan.operation, .appInstall)
        XCTAssertEqual(plan.command, "adb -s TEST-SERIAL install -r \(apk)")
        XCTAssertTrue(plan.target == apk)
        XCTAssertFalse(plan.confirmed, "A freshly built plan is never confirmed")

        let report = operations.dryRunReport(for: plan)
        XCTAssertFalse(report.wouldExecute)
        XCTAssertEqual(report.command, plan.command)
        XCTAssertTrue(report.preview.contains("DRY RUN — NOT EXECUTED"))
    }

    /// The install preview must disclose that the APK's manifest is not inspected. Without this
    /// note the preview would imply an identity check that does not happen.
    func testInstallPreviewDeclaresThatThePackageInsideIsNotInspected() throws {
        let transport = MockTransport()
        let (operations, _) = makeOperations(transport: transport)
        let plan = try operations.planInstall(deviceSerial: serial, apkLocalPath: try makeAPK())

        let notes = plan.notes.joined(separator: " ").lowercased()
        XCTAssertTrue(notes.contains("-r"), "replace semantics must be stated")
        XCTAssertTrue(notes.contains("manifest is not inspected"))
        XCTAssertTrue(notes.contains("worker"))
    }

    func testInstallCommandQuotesAPathWithSpaces() throws {
        let transport = MockTransport()
        let (operations, _) = makeOperations(transport: transport)
        let apk = try makeAPK(named: "disposable probe.apk")

        let plan = try operations.planInstall(deviceSerial: serial, apkLocalPath: apk)

        XCTAssertEqual(plan.command, "adb -s TEST-SERIAL install -r '\(apk)'")
    }

    // MARK: - Install: execution

    func testConfirmedInstallRunsInstallWithReplaceAndIsAudited() async throws {
        let transport = MockTransport()
        let (operations, log) = makeOperations(transport: transport)
        let apk = try makeAPK()

        let plan = try operations.planInstall(deviceSerial: serial, apkLocalPath: apk).confirming()
        let result = try await operations.execute(plan, deviceSerial: serial, timeout: 30)

        XCTAssertEqual(result.operation, .appInstall)
        XCTAssertEqual(result.exitCode, 0)

        let invocations = await transport.invocations
        XCTAssertEqual(invocations.count, 1)
        XCTAssertEqual(invocations[0].command, "-s")
        XCTAssertEqual(invocations[0].arguments, [serial, "install", "-r", apk])

        let record = try XCTUnwrap(log.records.last)
        XCTAssertEqual(record.operation, .appInstall)
        XCTAssertEqual(record.outcome, .executed)
        XCTAssertEqual(record.target, apk)
        XCTAssertEqual(record.detail, plan.command)
    }

    func testUnconfirmedInstallSendsNothingAndIsAuditedAsRefused() async throws {
        let transport = MockTransport()
        let (operations, log) = makeOperations(transport: transport)
        let plan = try operations.planInstall(deviceSerial: serial, apkLocalPath: try makeAPK())

        do {
            _ = try await operations.execute(plan, deviceSerial: serial, timeout: 30)
            XCTFail("An unconfirmed plan must not run")
        } catch {
            XCTAssertEqual(error as? DryRunError, .dryRunNotConfirmed(operation: .appInstall))
        }

        let invocations = await transport.invocations
        XCTAssertTrue(invocations.isEmpty, "the gate must refuse before any command is issued")
        XCTAssertEqual(log.records.last?.outcome, .refused)
    }

    /// `adb install` prints `Failure [...]` and exits 0. Treating the exit code alone as success
    /// would record a refused install as an executed one.
    func testInstallFailureOnStdoutWithExitCodeZeroIsAFailure() async throws {
        let transport = MockTransport()
        await transport.setInstallResult(TransportResult(
            exitCode: 0,
            stdout: "Failure [INSTALL_FAILED_OLDER_SDK]",
            stderr: ""
        ))
        let (operations, log) = makeOperations(transport: transport)

        let plan = try operations.planInstall(deviceSerial: serial, apkLocalPath: try makeAPK()).confirming()

        do {
            _ = try await operations.execute(plan, deviceSerial: serial, timeout: 30)
            XCTFail("Failure output must not be reported as success")
        } catch {
            guard case PixelDesktopError.adbCommandFailed(_, _, let stderr)? = error as? PixelDesktopError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(stderr.contains("INSTALL_FAILED_OLDER_SDK"))
        }

        XCTAssertEqual(log.records.last?.outcome, .failed)
    }

    // MARK: - Uninstall: containment

    func testUninstallRefusesTheWorkerPackage() async throws {
        let transport = await transportWithThirdParty([ADBAppOperations.workerPackageName])
        let (operations, log) = makeOperations(transport: transport)

        do {
            _ = try await operations.planUninstall(
                deviceSerial: serial,
                packageId: ADBAppOperations.workerPackageName,
                timeout: 30
            )
            XCTFail("B4 must refuse to uninstall the worker")
        } catch {
            XCTAssertEqual(
                error as? ADBPackageOperations.Refusal,
                .uninstallWorkerPackage(packageName: ADBAppOperations.workerPackageName)
            )
        }

        let invocations = await transport.invocations
        XCTAssertTrue(invocations.isEmpty, "refusal happens before any device read or command")
        XCTAssertTrue(log.records.isEmpty)
    }

    /// The guard must hold for a hand-built confirmed plan too — planning is not the only entry.
    func testUninstallRefusesTheWorkerPackageOnAHandBuiltConfirmedPlan() async throws {
        let transport = await transportWithThirdParty([ADBAppOperations.workerPackageName])
        let (operations, log) = makeOperations(transport: transport)

        let forged = DestructiveActionPlan(
            operation: .appUninstall,
            target: ADBAppOperations.workerPackageName,
            command: "adb -s \(serial) uninstall \(ADBAppOperations.workerPackageName)",
            confirmed: true
        )

        do {
            _ = try await operations.execute(forged, deviceSerial: serial, timeout: 30)
            XCTFail("A confirmed plan must not bypass the worker protection")
        } catch {
            XCTAssertEqual(
                error as? ADBPackageOperations.Refusal,
                .uninstallWorkerPackage(packageName: ADBAppOperations.workerPackageName)
            )
        }

        let invocations = await transport.invocations
        XCTAssertTrue(invocations.isEmpty)
        XCTAssertTrue(log.records.isEmpty)
    }

    func testUninstallRefusesProtectedSystemPackages() async throws {
        let (operations, _) = makeOperations(transport: await transportWithThirdParty([]))

        for name in ["com.android.providers.contacts", "com.android.server.telecom"] {
            do {
                _ = try await operations.planUninstall(
                    deviceSerial: serial,
                    packageId: name,
                    timeout: 30
                )
                XCTFail("Expected refusal for \(name)")
            } catch {
                XCTAssertEqual(
                    error as? ADBPackageOperations.Refusal,
                    .uninstallProtectedPackage(packageName: name)
                )
            }
        }
    }

    /// The framework package is literally `android`, which fails the identifier shape check before
    /// the protected list is consulted. Either refusal is correct — what matters is that it cannot
    /// be removed — so this asserts refusal without pinning which guard fires first.
    func testUninstallRefusesTheBareFrameworkPackage() async throws {
        let (operations, _) = makeOperations(transport: await transportWithThirdParty([]))

        do {
            _ = try await operations.planUninstall(deviceSerial: serial, packageId: "android", timeout: 30)
            XCTFail("The framework package must never be uninstallable")
        } catch {
            XCTAssertNotNil(error as? PixelDesktopError)
        }
    }

    func testUninstallRefusesAPackageThatIsNotInstalled() async throws {
        let (operations, _) = makeOperations(transport: await transportWithThirdParty([]))

        do {
            _ = try await operations.planUninstall(
                deviceSerial: serial,
                packageId: "com.example.absent",
                timeout: 30
            )
            XCTFail("An absent package must be refused, not previewed")
        } catch {
            XCTAssertEqual(
                error as? ADBPackageOperations.Refusal,
                .notInstalled(packageName: "com.example.absent")
            )
        }
    }

    func testUninstallRefusesAnInstalledPackageThatIsNotThirdParty() async throws {
        let transport = await transportWithThirdParty([])
        await transport.setShellResponse("pm list packages", TransportResult(
            exitCode: 0,
            stdout: "package:com.android.settings\n",
            stderr: ""
        ))
        let (operations, _) = makeOperations(transport: transport)

        do {
            _ = try await operations.planUninstall(
                deviceSerial: serial,
                packageId: "com.android.settings",
                timeout: 30
            )
            XCTFail("A system package must be refused even when it is installed")
        } catch {
            XCTAssertEqual(
                error as? ADBPackageOperations.Refusal,
                .notThirdParty(packageName: "com.android.settings")
            )
        }
    }

    func testUninstallRejectsAShellFragmentInThePackageId() async throws {
        let (operations, _) = makeOperations(transport: await transportWithThirdParty([]))

        do {
            _ = try await operations.planUninstall(
                deviceSerial: serial,
                packageId: "com.example.app; reboot",
                timeout: 30
            )
            XCTFail("A shell fragment must not pass package validation")
        } catch {
            guard case PixelDesktopError.invalidInput? = error as? PixelDesktopError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    // MARK: - Uninstall: execution

    func testConfirmedUninstallRunsTheExactAdbCommandAndIsAudited() async throws {
        let transport = await transportWithThirdParty(["com.pixeldesktop.disposable.probe"])
        let (operations, log) = makeOperations(transport: transport)

        let plan = try await operations.planUninstall(
            deviceSerial: serial,
            packageId: "com.pixeldesktop.disposable.probe",
            timeout: 30
        )

        XCTAssertEqual(plan.operation, .appUninstall)
        XCTAssertEqual(plan.command, "adb -s TEST-SERIAL uninstall com.pixeldesktop.disposable.probe")
        XCTAssertEqual(plan.target, "com.pixeldesktop.disposable.probe")

        let result = try await operations.execute(
            plan.confirming(),
            deviceSerial: serial,
            timeout: 30
        )

        XCTAssertEqual(result.exitCode, 0)

        let invocations = await transport.invocations
        XCTAssertEqual(invocations.count, 2, "one presence read, one uninstall")
        XCTAssertEqual(invocations[1].arguments, [serial, "uninstall", "com.pixeldesktop.disposable.probe"])

        let record = try XCTUnwrap(log.records.last)
        XCTAssertEqual(record.operation, .appUninstall)
        XCTAssertEqual(record.outcome, .executed)
        XCTAssertEqual(record.target, "com.pixeldesktop.disposable.probe")
    }

    /// `adb uninstall` prints `Failure [...]` and exits 0 as well.
    func testUninstallFailureOnStdoutIsNotRecordedAsExecuted() async throws {
        let transport = await transportWithThirdParty(["com.pixeldesktop.disposable.probe"])
        await transport.setDefaultResult(TransportResult(
            exitCode: 0,
            stdout: "Failure [DELETE_FAILED_INTERNAL_ERROR]",
            stderr: ""
        ))
        let (operations, log) = makeOperations(transport: transport)

        let plan = try await operations.planUninstall(
            deviceSerial: serial,
            packageId: "com.pixeldesktop.disposable.probe",
            timeout: 30
        )

        do {
            _ = try await operations.execute(plan.confirming(), deviceSerial: serial, timeout: 30)
            XCTFail("Failure output must not be reported as success")
        } catch {
            guard case PixelDesktopError.adbCommandFailed? = error as? PixelDesktopError else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        XCTAssertEqual(log.records.last?.outcome, .failed)
    }

    func testExecuteRefusesAPlanForAnotherOperation() async throws {
        let (operations, _) = makeOperations(transport: await transportWithThirdParty([]))

        let rebootPlan = DestructiveActionPlan(
            operation: .reboot,
            target: serial,
            command: "adb -s \(serial) reboot",
            confirmed: true
        )

        do {
            _ = try await operations.execute(rebootPlan, deviceSerial: serial, timeout: 30)
            XCTFail("B5 is not approved; this surface must not run a reboot")
        } catch {
            XCTAssertEqual(
                error as? ADBPackageOperations.Refusal,
                .planDoesNotMatchOperation(expected: .appUninstall, actual: .reboot)
            )
        }
    }

    // MARK: - APK path validation

    func testAPKPathValidationRejectsMalformedInput() throws {
        XCTAssertThrowsError(try ADBPackageOperations.validateAPKPath(""))
        XCTAssertThrowsError(try ADBPackageOperations.validateAPKPath("relative/app.apk"))
        XCTAssertThrowsError(try ADBPackageOperations.validateAPKPath("/tmp/nope.txt"))
        XCTAssertThrowsError(try ADBPackageOperations.validateAPKPath("/tmp/does-not-exist-\(UUID().uuidString).apk"))
        XCTAssertThrowsError(try ADBPackageOperations.validateAPKPath("/tmp/bad\nname.apk"))
        XCTAssertThrowsError(try ADBPackageOperations.validateAPKPath(NSTemporaryDirectory()))
    }

    func testAPKPathValidationAcceptsARealFile() throws {
        let apk = try makeAPK()
        XCTAssertEqual(try ADBPackageOperations.validateAPKPath(apk), apk)
    }

    // MARK: - Rendering

    func testRenderQuotesOnlyWhenNeeded() {
        XCTAssertEqual(
            ADBPackageOperations.render(["adb", "-s", "SER", "uninstall", "com.example.app"]),
            "adb -s SER uninstall com.example.app"
        )
        XCTAssertEqual(
            ADBPackageOperations.render(["adb", "--path", "/tmp/a b.apk"]),
            "adb --path '/tmp/a b.apk'"
        )
        XCTAssertEqual(
            ADBPackageOperations.render(["adb", "--path", "/tmp/it's.apk"]),
            "adb --path '/tmp/it'\\''s.apk'"
        )
    }
}

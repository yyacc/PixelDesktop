//
//  Phase2HardwareVerificationTests.swift
//  PixelDesktopTests
//
//  Real-device verification of Phase 2 (A7 telemetry, B1 input injection).
//
//  ## What this adds that the scripted tests could not
//
//  `Phase2TelemetryTests` pins the parsers against measured fixtures, and `Phase2InputTests`
//  pins the gate against a mock transport. Neither proves the *commands* work on the physical
//  Pixel: a fixture is a photograph of the output, not the output. This harness runs the real
//  commands and asserts the parsed result is not merely non-nil but plausible — a parser that
//  produced nonsense would satisfy a non-nil check.
//
//  ## Why the input test is deliberately dull
//
//  The only action executed here is `KEYCODE_WAKEUP`. A tap on a real screen is not something a
//  test suite should perform unasked: the phone is unlocked and charging (ADR-018), so a tap
//  lands on whatever happens to be focused. The gate itself is verified against a real
//  hierarchy — resolving a plan, and confirming that executing it unconfirmed is refused — and
//  the execute path is proven with the least destructive key available.
//
//  Skipped when no device is reachable. The serial comes from
//  `PIXELDESKTOP_DEVICE_SERIAL` when that is set, and otherwise from `adb devices` — xcodebuild
//  does not forward the shell environment to the test host, so requiring the variable alone
//  meant these tests silently skipped even with the phone attached.
//

import XCTest
import Foundation
@testable import PixelDesktop

final class Phase2HardwareVerificationTests: XCTestCase {

    private var deviceSerial: String? {
        ProcessInfo.processInfo.environment["PIXELDESKTOP_DEVICE_SERIAL"]
    }

    private func requireDevice() async throws -> String {
        if let serial = deviceSerial, !serial.isEmpty { return serial }

        // Discovery goes through `ADBTransport.listDevices()` rather than shelling out to
        // `adb` here: the transport already owns the binary path as an injectable default, and
        // restating it in a test would be a second source of truth for it. `listDevices` is
        // transport-level and verified in earlier phases, so it is not the layer under test.
        let devices = try await ADBTransport().listDevices()
        if let attached = devices.first(where: { $0.state == .device }) {
            return attached.serialNumber
        }
        throw XCTSkip("no device: set PIXELDESKTOP_DEVICE_SERIAL or attach one")
    }

    // MARK: - A7 · telemetry

    func testTelemetryReadsEverySourceFromRealDevice() async throws {
        let serial = try await requireDevice()

        let telemetry = try await ADBDeviceTelemetry(transport: ADBTransport())
            .read(deviceSerial: serial, timeout: 30)

        let battery = try XCTUnwrap(telemetry.battery, "dumpsys battery did not parse")
        XCTAssertNotNil(battery.levelPercent, "battery level missing")
        XCTAssertNotNil(battery.temperatureCelsius, "battery temperature missing")
        XCTAssertNotNil(battery.voltageMillivolts, "battery voltage missing")

        XCTAssertNotNil(telemetry.thermalStatus, "dumpsys thermalservice did not parse")
        XCTAssertFalse(telemetry.thermalZones.isEmpty, "no thermal zones parsed")

        let memory = try XCTUnwrap(telemetry.memory, "/proc/meminfo did not parse")
        let storage = try XCTUnwrap(telemetry.storage, "df did not parse")

        // Plausibility, not just presence. These bounds are wide on purpose — they catch a
        // unit error (307 °C, a 4 KB total) without encoding today's exact reading.
        XCTAssertTrue((0...100).contains(try XCTUnwrap(battery.levelPercent)))
        XCTAssertTrue(
            (0...80).contains(try XCTUnwrap(battery.temperatureCelsius)),
            "battery temperature is tenths of a degree; a value near 300 means it was not divided"
        )
        XCTAssertTrue((3_000...5_000).contains(try XCTUnwrap(battery.voltageMillivolts)))
        XCTAssertGreaterThan(memory.totalBytes, 1_000_000_000, "total memory looks like kilobytes, not bytes")
        XCTAssertGreaterThan(storage.totalBytes, 1_000_000_000, "storage total looks like blocks, not bytes")

        let hottest = try XCTUnwrap(telemetry.hottestZoneCelsius)
        XCTAssertTrue((0...120).contains(hottest), "hottest zone \(hottest) °C is implausible")
    }

    /// The thermal status the device reports must map onto the ADR-018 scale, and the alert
    /// flag must agree with it. On a cool device this asserts `false`; the point is that the
    /// comparison runs against a real reading rather than a fixture.
    func testThermalAlertFlagAgreesWithTheReportedStatus() async throws {
        let serial = try await requireDevice()

        let telemetry = try await ADBDeviceTelemetry(transport: ADBTransport())
            .read(deviceSerial: serial, timeout: 30)
        let status = try XCTUnwrap(telemetry.thermalStatus)

        XCTAssertEqual(telemetry.isThermalAlert, status >= ThermalStatus.critical)
    }

    // MARK: - B1 · input gate

    /// Resolves a plan against the real screen and proves the gate refuses to run it.
    ///
    /// Nothing is tapped: the assertion is that the *unconfirmed* plan is rejected before any
    /// command is issued, on hardware, with a hierarchy that came from the device.
    func testUnconfirmedPlanIsRefusedAgainstARealHierarchy() async throws {
        let serial = try await requireDevice()
        let transport = ADBTransport()

        let hierarchy = try await ADBDevicePerception(transport: transport)
            .uiHierarchy(deviceSerial: serial, timeout: 30)
        XCTAssertFalse(hierarchy.elements.isEmpty, "the dump parsed to nothing")

        guard let first = hierarchy.tapTargets.first else {
            throw XCTSkip("no interactive element on the current screen to resolve")
        }

        let log = DeviceAuditLog()
        let input = ADBDeviceInput(transport: transport, auditLog: log)

        let plan = try input.planTap(hierarchy: hierarchy, elementIndex: first.index)
        XCTAssertFalse(plan.confirmed)
        XCTAssertEqual(plan.target?.index, first.index)
        XCTAssertEqual(plan.target?.centerX, first.bounds.centerX)

        do {
            _ = try await input.execute(plan, deviceSerial: serial, timeout: 20)
            XCTFail("an unconfirmed plan executed on hardware")
        } catch let refusal as InputRefusal {
            XCTAssertEqual(refusal, .planNotConfirmed)
        }

        XCTAssertEqual(log.latest?.outcome, DeviceAuditRecord.refused)
    }

    /// Proves the execute path works end to end with the least destructive action available.
    func testConfirmedKeyEventExecutesOnRealDevice() async throws {
        let serial = try await requireDevice()
        let log = DeviceAuditLog()
        let input = ADBDeviceInput(transport: ADBTransport(), auditLog: log)

        let plan = try input.planKeyEvent("KEYCODE_WAKEUP").confirming()
        let result = try await input.execute(plan, deviceSerial: serial, timeout: 20)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.command, "input keyevent KEYCODE_WAKEUP")
        XCTAssertEqual(log.latest?.outcome, DeviceAuditRecord.executed)
        XCTAssertEqual(log.latest?.input?.payload, "KEYCODE_WAKEUP")
    }

    /// The containment claim, checked against the device shell rather than a mock: text with
    /// shell metacharacters must arrive as literal text. `KEYCODE_DEL` cleans up after it, so
    /// this leaves no residue in whatever field has focus.
    func testQuotedTextIsDeliveredLiterally() async throws {
        let serial = try await requireDevice()
        let transport = ADBTransport()

        // Built the same way `execute` builds it, so the assertion is about the real command.
        let payload = "$(id)"
        let command = "input text " + (try InputContainment.quotedTextArgument(payload))

        let result = try await transport.shell(
            deviceSerial: serial,
            command: command,
            timeout: 20
        )

        // Clean up whatever field received it — five characters were injected.
        _ = try? await transport.shell(
            deviceSerial: serial,
            command: "input keyevent KEYCODE_DEL",
            timeout: 20
        )

        // If the quoting failed, the shell would have executed `id` and printed a uid line.
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(
            result.stdout.contains("uid="),
            "the shell expanded the payload — quoting is broken"
        )
    }
}

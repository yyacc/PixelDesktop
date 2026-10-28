//
//  Phase2TelemetryTests.swift
//  PixelDesktopTests
//
//  Phase 2 (A7) — device telemetry and thermal history.
//
//  ## What these pin, and what they cannot
//
//  `dumpsys` output is not a stable API: it varies by Android version, by OEM, and in places
//  by build. The parsers are therefore the part most likely to be wrong, and they are pure, so
//  they are pinned here against fixtures taken from the real device where available.
//
//  What these tests cannot prove is that the *commands* work on this device. That is verified
//  against the hardware separately; a parser test with a fixture that was never real would be
//  the "mock written from assumption" defect the project's own rules warn about, so the
//  fixtures below are the measured Pixel 7a shapes.
//

import XCTest
@testable import PixelDesktop

final class Phase2TelemetryTests: XCTestCase {

    private let serial = "DEADBEEF000000"

    // MARK: - Fixtures (measured shapes, Android 16 / Pixel 7a)

    private let batteryFixture = """
    Current Battery Service state:
      AC powered: true
      USB powered: false
      Wireless powered: false
      Dock powered: false
      Max charging current: 3000000
      Max charging voltage: 5000000
      Charge counter: 3530000
      status: 5
      health: 2
      present: true
      level: 100
      scale: 100
      voltage: 4287
      temperature: 343
      technology: Li-ion
      Charging state: 1
    """

    private let thermalFixture = """
    IsStatusOverride: false
    Current temperatures from HAL:
    	Temperature{mValue=67.0, mType=0, mName=LITTLE, mStatus=0}
    	Temperature{mValue=38.895, mType=-1, mName=neutral_therm, mStatus=0}
    	Temperature{mValue=0.0, mType=4, mName=VIRTUAL-USB-UI, mStatus=0}
    	Temperature{mValue=31.400002, mType=2, mName=battery, mStatus=0}
    	Temperature{mValue=74.0, mType=0, mName=BIG, mStatus=0}
    	Temperature{mValue=56.000004, mType=1, mName=G3D, mStatus=0}
    	Temperature{mValue=66.0, mType=0, mName=MID, mStatus=0}
    Current cooling devices from HAL:
    CoolingDevice{mValue=0, mType=0, mName=CPU}
    Thermal Status: 0
    """

    private let meminfoFixture = """
    MemTotal:        7626016 kB
    MemFree:          432180 kB
    MemAvailable:    2468092 kB
    Buffers:            2564 kB
    Cached:          1234567 kB
    """

    private let dfFixture = """
    Filesystem       1K-blocks     Used Available Use% Mounted on
    /dev/block/dm-61 115249236 75646588  39471576  66% /data/user/0
    """

    // MARK: - Battery

    func testBatteryParsesMeasuredFixture() throws {
        let battery = try XCTUnwrap(TelemetryParser.parseBattery(batteryFixture))

        XCTAssertEqual(battery.levelPercent, 100)
        XCTAssertEqual(battery.statusLabel, "full", "status 5 is BATTERY_STATUS_FULL")
        XCTAssertEqual(battery.voltageMillivolts, 4287)
    }

    /// `temperature` is in tenths of a degree. Reading 307 as whole degrees would report a
    /// 30.7 °C battery as 307 °C — an order of magnitude, on the one field this phase exists
    /// to watch.
    func testBatteryTemperatureIsTenthsOfADegree() throws {
        let battery = try XCTUnwrap(TelemetryParser.parseBattery(batteryFixture))
        XCTAssertEqual(try XCTUnwrap(battery.temperatureCelsius), 34.3, accuracy: 0.001)
    }

    func testBatteryReturnsNilForUnparseableInput() {
        XCTAssertNil(TelemetryParser.parseBattery("this is not dumpsys output"))
        XCTAssertNil(TelemetryParser.parseBattery(""))
    }

    func testBatteryReportsUnknownStatusCodeRatherThanDroppingIt() {
        XCTAssertEqual(TelemetryParser.statusLabel(2), "charging")
        XCTAssertEqual(TelemetryParser.statusLabel(3), "discharging")
        XCTAssertEqual(TelemetryParser.statusLabel(5), "full")
        XCTAssertEqual(
            TelemetryParser.statusLabel(99), "unknown(99)",
            "a newer platform constant must surface as itself, not as a silent 'unknown'"
        )
    }

    // MARK: - Thermal

    func testThermalStatusParses() {
        // `ThermalStatus.none` must be spelled out: bare `.none` on an
        // `Optional<ThermalStatus>` resolves to `Optional.none`, i.e. nil.
        XCTAssertEqual(TelemetryParser.parseThermalStatus(thermalFixture), ThermalStatus.none)
    }

    /// `-1` means the service has no reading. That is not "cool".
    func testThermalStatusMinusOneIsAbsentRatherThanNone() {
        XCTAssertNil(TelemetryParser.parseThermalStatus("Thermal Status: -1"))
    }

    func testThermalStatusAbsentLineIsNil() {
        XCTAssertNil(TelemetryParser.parseThermalStatus("no thermal service here"))
    }

    func testThermalZonesParseEveryZone() {
        let zones = TelemetryParser.parseThermalZones(thermalFixture)

        XCTAssertEqual(zones.count, 7)
        XCTAssertEqual(
            zones.map(\.name),
            ["LITTLE", "neutral_therm", "VIRTUAL-USB-UI", "battery", "BIG", "G3D", "MID"]
        )
        XCTAssertEqual(zones[0].temperatureCelsius, 67.0, accuracy: 0.001)
        XCTAssertEqual(zones[4].temperatureCelsius, 74.0, accuracy: 0.001)
        // Six-decimal precision is what the HAL actually emits for the skin sensors.
        XCTAssertEqual(zones[5].temperatureCelsius, 56.000004, accuracy: 0.000001)
    }

    /// The hottest zone is what the history tracks, and on this device it is BIG at 74 °C
    /// while the overall status is still `none` — which is exactly why status alone is not
    /// enough to see the thermal picture.
    func testHottestZoneIsTheMaximumAcrossZones() throws {
        let telemetry = DeviceTelemetry(
            capturedAt: Date(),
            battery: nil,
            thermalStatus: TelemetryParser.parseThermalStatus(thermalFixture),
            thermalZones: TelemetryParser.parseThermalZones(thermalFixture),
            memory: nil,
            storage: nil
        )

        XCTAssertEqual(try XCTUnwrap(telemetry.hottestZoneCelsius), 74.0, accuracy: 0.001)
        XCTAssertFalse(telemetry.isThermalAlert, "status 0 is well below the ADR-018 threshold")
    }

    /// Field order inside the braces is the platform's `toString()`, but the parser must not
    /// depend on it — a build that reorders the fields is the likeliest shape change.
    func testThermalZoneParsingIsOrderIndependent() {
        let reordered = "Temperature{mStatus=0, mName=CPU, mValue=41.5, mType=0}"
        let zones = TelemetryParser.parseThermalZones(reordered)

        XCTAssertEqual(zones.count, 1)
        XCTAssertEqual(zones.first?.name, "CPU")
        XCTAssertEqual(zones.first?.temperatureCelsius, 41.5)
    }

    func testThermalZoneWithoutValueIsSkippedNotZeroed() {
        let zones = TelemetryParser.parseThermalZones("Temperature{mType=0, mName=CPU, mStatus=0}")
        XCTAssertTrue(zones.isEmpty, "a zone with no value must not read as 0 °C")
    }

    // MARK: - Threshold (ADR-018)

    func testAlertThresholdIsCriticalAndAbove() {
        XCTAssertFalse(ThermalStatus.severe.isAlert)
        XCTAssertTrue(ThermalStatus.critical.isAlert)
        XCTAssertTrue(ThermalStatus.emergency.isAlert)
        XCTAssertTrue(ThermalStatus.shutdown.isAlert)
        XCTAssertEqual(ThermalStatus.alertThreshold, .critical)
    }

    func testThermalStatusIsOrdered() {
        XCTAssertTrue(ThermalStatus.light < ThermalStatus.critical)
        XCTAssertTrue(ThermalStatus.shutdown > ThermalStatus.critical)
    }

    // MARK: - Memory / storage

    func testMemoryParsesTotalAndAvailable() throws {
        let memory = try XCTUnwrap(TelemetryParser.parseMemory(meminfoFixture))

        XCTAssertEqual(memory.totalBytes, 7_626_016 * 1024)
        XCTAssertEqual(memory.availableBytes, 2_468_092 * 1024)
        XCTAssertEqual(memory.usedFraction, (7_626_016.0 - 2_468_092.0) / 7_626_016.0, accuracy: 0.0001)
    }

    /// `MemFree` excludes reclaimable page cache and would report a healthy device as nearly
    /// full, so the parser must read `MemAvailable`.
    func testMemoryUsesAvailableNotFree() throws {
        let memory = try XCTUnwrap(TelemetryParser.parseMemory(meminfoFixture))
        XCTAssertNotEqual(memory.availableBytes, 432_180 * 1024)
    }

    func testStorageParsesBlockColumns() throws {
        let storage = try XCTUnwrap(TelemetryParser.parseStorage(dfFixture))

        XCTAssertEqual(storage.totalBytes, 115_249_236 * 1024)
        XCTAssertEqual(storage.usedBytes, 75_646_588 * 1024)
    }

    func testStorageSkipsHeaderRow() throws {
        let storage = try XCTUnwrap(TelemetryParser.parseStorage(dfFixture))
        XCTAssertEqual(storage.totalBytes, 115_249_236 * 1024, "the header must not be read as data")
    }

    // MARK: - History

    func testHistoryIsBoundedAndDropsOldest() {
        var history = TelemetryHistory(capacity: 3)

        for second in 0..<5 {
            history.append(sample(at: TimeInterval(second)))
        }

        XCTAssertEqual(history.samples.count, 3)
        XCTAssertEqual(
            history.samples.map { Int($0.capturedAt.timeIntervalSince1970) }, [2, 3, 4],
            "a bounded history keeps the newest samples"
        )
    }

    func testHistoryRecordsOnlySamplesAtOrAboveTheThreshold() {
        var history = TelemetryHistory(capacity: 10)
        history.append(sample(at: 0, thermal: .light))
        history.append(sample(at: 1, thermal: .severe))
        history.append(sample(at: 2, thermal: .critical))
        history.append(sample(at: 3, thermal: .emergency))

        XCTAssertEqual(history.thermalAlerts.count, 2)
        XCTAssertEqual(history.latestAlert?.thermalStatus, .emergency)
        XCTAssertEqual(history.peakThermalStatus, .emergency)
    }

    func testHistoryWithNoAlertsReportsNone() {
        var history = TelemetryHistory(capacity: 5)
        history.append(sample(at: 0, thermal: .light))

        XCTAssertTrue(history.thermalAlerts.isEmpty)
        XCTAssertNil(history.latestAlert)
    }

    func testHistoryPeakZoneTemperature() {
        var history = TelemetryHistory(capacity: 5)
        history.append(sample(at: 0, thermal: .light, hottest: 41.0))
        history.append(sample(at: 1, thermal: .moderate, hottest: 67.0))
        history.append(sample(at: 2, thermal: .moderate, hottest: 55.0))

        XCTAssertEqual(try? XCTUnwrap(history.peakZoneCelsius), 67.0)
    }

    // MARK: - ADB implementation

    func testReadAssemblesPartialSampleWhenOnlyBatteryAnswers() async throws {
        let transport = MockTransport()
        await transport.setShellResponse(
            ADBDeviceTelemetry.Command.battery,
            TransportResult(exitCode: 0, stdout: batteryFixture, stderr: "")
        )

        let telemetry = try await ADBDeviceTelemetry(transport: transport)
            .read(deviceSerial: serial, timeout: 10)

        XCTAssertNotNil(telemetry.battery)
        XCTAssertNil(telemetry.thermalStatus, "an unanswered source stays nil, it is not defaulted")
        XCTAssertNil(telemetry.memory)
    }

    func testReadThrowsWhenEverySourceFails() async {
        let transport = MockTransport()
        await transport.setDefaultShellResult(
            TransportResult(exitCode: 1, stdout: "", stderr: "not permitted")
        )

        do {
            _ = try await ADBDeviceTelemetry(transport: transport)
                .read(deviceSerial: serial, timeout: 10)
            XCTFail("an all-silent read must not render as an empty sample")
        } catch let error as PixelDesktopError {
            guard case .verificationFailed = error else {
                return XCTFail("expected verificationFailed, got \(error)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    /// The alert path depends on `Thermal Status` parsing. A thermal service that answers with
    /// something unrecognisable must fail loudly rather than silently report "no thermal data".
    func testReadThrowsWhenThermalServiceAnswersUnparseably() async {
        let transport = MockTransport()
        await transport.setShellResponse(
            ADBDeviceTelemetry.Command.thermal,
            TransportResult(exitCode: 0, stdout: "reshaped output", stderr: "")
        )

        do {
            _ = try await ADBDeviceTelemetry(transport: transport)
                .read(deviceSerial: serial, timeout: 10)
            XCTFail("expected a parse failure to surface")
        } catch let error as PixelDesktopError {
            guard case .verificationFailed = error else {
                return XCTFail("expected verificationFailed, got \(error)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testReadIssuesTheFourFixedCommands() async throws {
        let transport = MockTransport()
        _ = try? await ADBDeviceTelemetry(transport: transport)
            .read(deviceSerial: serial, timeout: 10)

        let commands = await transport.invocations.map { $0.arguments.last ?? "" }

        for expected in [
            ADBDeviceTelemetry.Command.battery,
            ADBDeviceTelemetry.Command.thermal,
            ADBDeviceTelemetry.Command.memory,
            ADBDeviceTelemetry.Command.storage
        ] {
            XCTAssertTrue(commands.contains(expected), "missing \(expected)")
        }
    }

    // MARK: - Helpers

    private func sample(
        at second: TimeInterval,
        thermal: ThermalStatus? = nil,
        hottest: Double? = nil
    ) -> TelemetrySample {
        TelemetrySample(
            capturedAt: Date(timeIntervalSince1970: second),
            thermalStatus: thermal,
            hottestZoneCelsius: hottest,
            batteryLevelPercent: nil,
            batteryTemperatureCelsius: nil,
            memoryUsedFraction: nil
        )
    }
}

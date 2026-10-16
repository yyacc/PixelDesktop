//
//  Phase9DeviceSelectionTests.swift
//  PixelDesktopTests
//
//  Phase 9 — CLIDeviceSelection.connectedSerial precedence contract.
//
//  This test file pins the CLI-side device-selection rule:
//
//    device  → return serial
//    unauthorized → throw .deviceUnauthorized
//    offline  → throw .deviceOffline
//    (none)  → throw .deviceNotFound
//
//  The rule is "pinned by a test on both sides" per CLIDeviceSelection.swift:14, but the CLI
//  copy had zero coverage. AppState's private copy is structurally pinned (selectedSerial==nil
//  when unauthorized) but never asserted for its THROW behaviour on each failure state. This
//  file closes that gap for the CLIDeviceSelection copy, which is the one called by the
//  live `run` and `observe` command paths.
//

import XCTest
@testable import PixelDesktop

final class Phase9DeviceSelectionTests: XCTestCase {

    // MARK: - Helpers

    private func device(state: DeviceState, serial: String) -> AndroidDevice {
        AndroidDevice(
            id: serial,
            serialNumber: serial,
            deviceCodename: "test",
            marketingName: "Test Device",
            manufacturer: "Test",
            androidVersion: "14",
            apiLevel: 34,
            architecture: "arm64-v8a",
            supportedABIs: ["arm64-v8a"],
            state: state
        )
    }

    // MARK: - Tests

    /// A single connected device is selected.
    func testConnectedDeviceIsSelected() async {
        let transport = MockTransport()
        await transport.setDeviceList([device(state: .device, serial: "CONNECTED-1")])

        let serial = try? await CLIDeviceSelection.connectedSerial(transport: transport)
        XCTAssertEqual(serial, "CONNECTED-1")
    }

    /// A connected device wins over an unauthorized one present in the same list.
    func testConnectedDeviceWinsOverUnauthorized() async {
        let transport = MockTransport()
        await transport.setDeviceList([
            device(state: .unauthorized, serial: "UNAUTH-1"),
            device(state: .device, serial: "CONNECTED-1"),
        ])

        let serial = try? await CLIDeviceSelection.connectedSerial(transport: transport)
        XCTAssertEqual(serial, "CONNECTED-1")
    }

    /// An unauthorized device throws .deviceUnauthorized — not .deviceNotFound.
    ///
    /// This is the highest-value classification test. An unauthorized device is the one the
    /// user can fix right now (tap "Allow"). Collapsing it into deviceNotFound gives
    /// "No authorized Android device found" for a device that IS connected but awaiting
    /// authorization — the exact confusion the error taxonomy was designed to prevent.
    func testUnauthorizedThrowsDeviceUnauthorized() async {
        let transport = MockTransport()
        await transport.setDeviceList([device(state: .unauthorized, serial: "UNAUTH-1")])

        do {
            _ = try await CLIDeviceSelection.connectedSerial(transport: transport)
            XCTFail("expected .deviceUnauthorized, but no error was thrown")
        } catch let error as PixelDesktopError {
            XCTAssertEqual(error, .deviceUnauthorized)
        } catch {
            XCTFail("expected PixelDesktopError.deviceUnauthorized, got \(type(of: error))")
        }
    }

    /// An offline device throws .deviceOffline.
    func testOfflineThrowsDeviceOffline() async {
        let transport = MockTransport()
        await transport.setDeviceList([device(state: .offline, serial: "OFFLINE-1")])

        do {
            _ = try await CLIDeviceSelection.connectedSerial(transport: transport)
            XCTFail("expected .deviceOffline, but no error was thrown")
        } catch let error as PixelDesktopError {
            XCTAssertEqual(error, .deviceOffline)
        } catch {
            XCTFail("expected PixelDesktopError.deviceOffline, got \(type(of: error))")
        }
    }

    /// When both unauthorized and offline are present, unauthorized wins.
    ///
    /// The ordering rationale (CLIDeviceSelection.swift:10): unauthorized is actionable —
    /// the user can tap "Allow" — while offline means a cable check. A well-meaning
    /// simplification that checks offline first would silently degrade the UX guidance.
    func testUnauthorizedTakesPrecedenceOverOffline() async {
        let transport = MockTransport()
        await transport.setDeviceList([
            device(state: .offline, serial: "OFFLINE-1"),
            device(state: .unauthorized, serial: "UNAUTH-1"),
        ])

        do {
            _ = try await CLIDeviceSelection.connectedSerial(transport: transport)
            XCTFail("expected .deviceUnauthorized, but no error was thrown")
        } catch let error as PixelDesktopError {
            XCTAssertEqual(error, .deviceUnauthorized,
                           "unauthorized must take precedence over offline")
        } catch {
            XCTFail("expected PixelDesktopError.deviceUnauthorized, got \(type(of: error))")
        }
    }

    /// An empty device list throws .deviceNotFound.
    func testEmptyListThrowsDeviceNotFound() async {
        let transport = MockTransport()
        await transport.setDeviceList([])

        do {
            _ = try await CLIDeviceSelection.connectedSerial(transport: transport)
            XCTFail("expected .deviceNotFound, but no error was thrown")
        } catch let error as PixelDesktopError {
            XCTAssertEqual(error, .deviceNotFound)
        } catch {
            XCTFail("expected PixelDesktopError.deviceNotFound, got \(type(of: error))")
        }
    }
}

//
//  Phase0DeviceVerificationTests.swift
//  PixelDesktopTests
//
//  Real-device verification of the Phase 0 control plane
//  (`docs/PROPOSAL-DEVICE-INTERACTION.md` §8).
//
//  ## Why this exists separately from `Phase0PerceptionTests`
//
//  Those tests drive the layer through the `MockTransport` seam and prove the wiring, the
//  parsers and the failure paths. They cannot prove that `uiautomator dump` on this Pixel
//  produces a document this parser understands, that `screencap` returns a complete PNG at
//  1080×2400, or that `logcat -v threadtime` lines split where the parser expects. Those are
//  properties of the device, and the only honest way to establish them is to ask the device.
//
//  Skipped unless `PIXELDESKTOP_DEVICE_SERIAL` is set — the Phase 2–9 convention, so an
//  unattended run does not fail merely because no phone is plugged in.
//
//  ## Evidence
//
//  `testRealScreenshotIsValidPNG` writes the capture into `engineering/evidence/` so the
//  proof is a durable artifact rather than a passing assertion.
//

import XCTest
import Foundation
@testable import PixelDesktop

final class Phase0DeviceVerificationTests: XCTestCase {

    private var deviceSerial: String? {
        ProcessInfo.processInfo.environment["PIXELDESKTOP_DEVICE_SERIAL"]
    }

    private func requireDevice() throws -> String {
        guard let serial = deviceSerial else {
            throw XCTSkip("PIXELDESKTOP_DEVICE_SERIAL not set; skipping real-device verification")
        }
        return serial
    }

    /// The repository root, derived from this file's location. No hardcoded absolute path.
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PixelDesktopTests
            .deletingLastPathComponent()   // repo root
    }

    // MARK: - A4 · UI hierarchy

    func testRealHierarchyDumpsAndParses() async throws {
        let serial = try requireDevice()
        let perception = ADBDevicePerception(transport: ADBTransport())

        let hierarchy = try await perception.uiHierarchy(deviceSerial: serial, timeout: 25)

        XCTAssertFalse(hierarchy.isEmpty, "uiautomator returned no nodes")
        XCTAssertGreaterThan(
            hierarchy.tapTargets.count, 0,
            "no interactive elements: the parser or the dump shape is wrong"
        )

        // A foreground app must be identifiable, otherwise a tap plan could not be scoped.
        let package = try XCTUnwrap(hierarchy.packageName, "no package attribute on any node")
        XCTAssertFalse(package.isEmpty)

        // Labels are what make blind operation targeted; at least one must be readable.
        let labelled = hierarchy.elements.filter {
            $0.text != nil || $0.contentDescription != nil
        }
        XCTAssertGreaterThan(labelled.count, 0, "no node carried text or a content description")

        print("PHASE0 HIERARCHY: package=\(package) nodes=\(hierarchy.elements.count) "
              + "tapTargets=\(hierarchy.tapTargets.count) labelled=\(labelled.count) "
              + "rotation=\(hierarchy.rotation.map(String.init) ?? "unknown")")
        print("PHASE0 LABELS: " + labelled.prefix(8).map(\.label).joined(separator: " | "))

        // Independent cross-check: the package the hierarchy reports should also be the
        // package the device says has the focused window. Asserting the hierarchy against
        // itself would prove nothing.
        let focused = try await ADBTransport().shell(
            deviceSerial: serial,
            command: "dumpsys window | grep -E 'mCurrentFocus|mFocusedApp' | head -2",
            timeout: 15
        ).stdout
        print("PHASE0 FOCUS: \(focused.trimmingCharacters(in: .whitespacesAndNewlines))")
        XCTAssertTrue(
            focused.contains(package),
            "hierarchy reports package '\(package)' but the device's focused window is '\(focused)'"
        )
    }

    // MARK: - A2 · Screenshot as evidence

    func testRealScreenshotIsValidPNG() async throws {
        let serial = try requireDevice()
        let perception = ADBDevicePerception(transport: ADBTransport())

        let png = try await perception.screenshot(deviceSerial: serial, timeout: 30)

        XCTAssertTrue(PNGSignature.isValid(png))

        // Dimensions, not payload size. A real capture of a mostly-flat screen measured 15,580
        // bytes, so a size floor would reject a good image; the IHDR header cannot lie about
        // the framebuffer's geometry.
        let dimensions = try XCTUnwrap(PNGSignature.dimensions(png), "no readable IHDR")
        XCTAssertEqual(Set([dimensions.width, dimensions.height]), [1080, 2400])

        let evidenceDirectory = repositoryRoot.appendingPathComponent("engineering/evidence")
        let store = try ScreenshotStore(directory: evidenceDirectory)
        let written = try store.write(png)

        XCTAssertTrue(FileManager.default.fileExists(atPath: written.path))
        XCTAssertEqual(try Data(contentsOf: written).count, png.count)

        print("PHASE0 SCREENSHOT: \(written.path) (\(png.count) bytes)")
    }

    // MARK: - A6 · Logcat

    func testRealLogcatDeliversParsedLines() async throws {
        let serial = try requireDevice()
        let stream = LogcatStream(transport: ADBTransport(), capacity: 500)

        try stream.start(deviceSerial: serial, filter: LogcatFilter(minimumPriority: .info))
        defer { stream.stop() }

        // The device is idle, so a priority floor still yields a steady trickle within seconds.
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, stream.lines.count < 5 {
            try await Task.sleep(nanoseconds: 250_000_000)
        }

        let lines = stream.lines
        XCTAssertGreaterThanOrEqual(
            lines.count, 5,
            "logcat produced \(lines.count) parsed lines in 15 s; error=\(stream.errorDescription ?? "none")"
        )

        // Parsed, not just received: a raw passthrough would leave these empty.
        XCTAssertFalse(lines[0].tag.isEmpty)
        XCTAssertFalse(lines[0].timestamp.isEmpty)
        XCTAssertTrue(lines.allSatisfy { $0.priority.severity >= LogcatLine.Priority.info.severity })

        print("PHASE0 LOGCAT: \(lines.count) lines, first="
              + "\(lines[0].timestamp) \(lines[0].priority.rawValue)/\(lines[0].tag): \(lines[0].message.prefix(60))")

        stream.stop()
        XCTAssertFalse(stream.isRunning, "stop() left the session running")
    }

    // MARK: - B3 · Port forwarding

    func testRealPortForwardRoundTrip() async throws {
        let serial = try requireDevice()
        let forwarding = ADBPortForwarding(transport: ADBTransport())

        // A high port unlikely to be in use, and away from any service this project runs.
        let localPort = 18_991
        let remotePort = 5_035

        let created = try await forwarding.forward(
            deviceSerial: serial,
            localPort: localPort,
            remotePort: remotePort,
            timeout: 15
        )
        XCTAssertEqual(created.local, "tcp:18991")

        let listed = try await forwarding.forwards(deviceSerial: serial, timeout: 15)
        XCTAssertTrue(
            listed.contains { $0.local == "tcp:\(localPort)" && $0.remote == "tcp:\(remotePort)" },
            "forward was created but not listed: \(listed)"
        )

        _ = try await forwarding.removeForward(deviceSerial: serial, localPort: localPort, timeout: 15)

        let afterRemoval = try await forwarding.forwards(deviceSerial: serial, timeout: 15)
        XCTAssertFalse(
            afterRemoval.contains { $0.local == "tcp:\(localPort)" },
            "forward survived removal: \(afterRemoval)"
        )

        print("PHASE0 FORWARD: created, listed and removed tcp:\(localPort) → tcp:\(remotePort)")
    }
}

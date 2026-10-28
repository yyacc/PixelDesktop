import XCTest
@testable import PixelDesktop

/// Phase 0 — control plane (proposal §8): UI dump, screenshot, logcat, port forwarding.
///
/// These tests cover the parts that are decidable without a device: parsing, validation,
/// bounding and the failure paths. The device-dependent half is verified separately against
/// the Pixel 7a and recorded in `engineering/evidence/`.
final class Phase0PerceptionTests: XCTestCase {

    // MARK: - Bounds

    func testBoundsParseStockForm() {
        let bounds = UIElementBounds.parse("[0,120][1080,2400]")
        XCTAssertEqual(bounds, UIElementBounds(left: 0, top: 120, right: 1080, bottom: 2400))
        XCTAssertEqual(bounds?.width, 1080)
        XCTAssertEqual(bounds?.height, 2280)
        XCTAssertEqual(bounds?.centerX, 540)
    }

    func testBoundsRejectMalformed() {
        XCTAssertNil(UIElementBounds.parse("[0,0]"))
        XCTAssertNil(UIElementBounds.parse("0,0][10,10"))
        XCTAssertNil(UIElementBounds.parse("[a,b][c,d]"))
        XCTAssertNil(UIElementBounds.parse(""))
    }

    /// An inverted rectangle is not silently normalised: it is empty, and emptiness is what
    /// `tapTargets` filters on.
    func testInvertedBoundsAreEmpty() {
        let bounds = UIElementBounds.parse("[100,100][50,50]")
        XCTAssertEqual(bounds?.width, 0)
        XCTAssertEqual(bounds?.isEmpty, true)
    }

    // MARK: - Hierarchy parsing

    private let sampleDump = """
    <?xml version='1.0' encoding='UTF-8' standalone='yes' ?>
    <hierarchy rotation="0">
      <node index="0" text="" resource-id="" class="android.widget.FrameLayout" package="com.zhiliaoapp.musically" content-desc="" clickable="false" enabled="true" bounds="[0,0][1080,2400]">
        <node index="0" text="For You" resource-id="com.zhiliaoapp.musically:id/tab" class="android.widget.TextView" package="com.zhiliaoapp.musically" content-desc="" clickable="true" enabled="true" bounds="[100,2000][540,2100]" />
        <node index="1" text="" resource-id="com.zhiliaoapp.musically:id/profile" class="android.widget.ImageView" package="com.zhiliaoapp.musically" content-desc="Profile" clickable="true" enabled="true" bounds="[900,2000][1080,2100]" />
        <node index="2" text="Café &amp; créme" resource-id="" class="android.widget.TextView" package="com.zhiliaoapp.musically" content-desc="" clickable="false" enabled="false" bounds="[0,0][0,0]" />
        <node index="3" text="" resource-id="" class="android.widget.SeekBar" package="com.zhiliaoapp.musically" content-desc="Video progress" scrollable="true" clickable="false" enabled="true" bounds="[0,2300][1080,2400]" />
      </node>
    </hierarchy>
    """

    func testParserReadsNodesAndMetadata() throws {
        let hierarchy = try UIHierarchyParser.parse(sampleDump)

        XCTAssertEqual(hierarchy.rotation, 0)
        XCTAssertEqual(hierarchy.packageName, "com.zhiliaoapp.musically")
        XCTAssertEqual(hierarchy.elements.count, 5)

        let tab = try XCTUnwrap(hierarchy.elements.first { $0.text == "For You" })
        XCTAssertTrue(tab.isClickable)
        XCTAssertTrue(tab.isEnabled)
        XCTAssertEqual(tab.shortResourceID, "tab")
        XCTAssertEqual(tab.bounds.left, 100)
    }

    /// `XMLParser` decodes entities; a regex-based extractor would leave `&amp;` literal or
    /// corrupt the line. Both are wrong in a way that still looks plausible.
    func testParserDecodesXMLEntities() throws {
        let hierarchy = try UIHierarchyParser.parse(sampleDump)
        XCTAssertTrue(hierarchy.elements.contains { $0.text == "Café & créme" })
    }

    /// Zero-area nodes are kept (they carry structure) but never offered as tap targets.
    func testZeroAreaNodesAreNotTapTargets() throws {
        let hierarchy = try UIHierarchyParser.parse(sampleDump)
        XCTAssertEqual(hierarchy.tapTargets.count, 3)
        XCTAssertFalse(hierarchy.tapTargets.contains { $0.text == "Café & créme" })
    }

    func testScrollableWithoutClickIsInteractive() throws {
        let hierarchy = try UIHierarchyParser.parse(sampleDump)
        XCTAssertTrue(hierarchy.tapTargets.contains { $0.contentDescription == "Video progress" })
    }

    /// The innermost node at a point wins: the container is also clickable? No — here the
    /// container is not clickable, so the point resolves to the child that is.
    func testPointResolvesToInnermostInteractiveElement() throws {
        let hierarchy = try UIHierarchyParser.parse(sampleDump)
        let hit = hierarchy.interactiveElement(atX: 500, y: 2050)
        XCTAssertEqual(hit?.text, "For You")
    }

    /// A point over no interactive node has no target. Returning the root container would
    /// make a later tap land somewhere the caller did not intend.
    func testEmptyPointHasNoTarget() throws {
        let hierarchy = try UIHierarchyParser.parse(sampleDump)
        XCTAssertNil(hierarchy.interactiveElement(atX: 5, y: 5))
    }

    func testParserToleratesLeadingDeviceSentence() throws {
        let raw = "UI hierchary dumped to: /sdcard/window_dump.xml\n" + sampleDump
        let hierarchy = try UIHierarchyParser.parse(raw)
        XCTAssertEqual(hierarchy.elements.count, 5)
    }

    func testParserRejectsNonXML() {
        XCTAssertThrowsError(try UIHierarchyParser.parse("ERROR: could not get idle state.")) { error in
            guard case PixelDesktopError.invalidInput = error else {
                return XCTFail("Expected invalidInput, got \(error)")
            }
        }
    }

    func testParserRejectsTruncatedDocument() {
        let truncated = String(sampleDump.prefix(sampleDump.count / 2))
        XCTAssertThrowsError(try UIHierarchyParser.parse(truncated))
    }

    // MARK: - Perception over the transport seam

    private func makePerception() -> (ADBDevicePerception, MockTransport) {
        let transport = MockTransport()
        return (ADBDevicePerception(transport: transport), transport)
    }

    func testUIHierarchyReadsDumpFileAndParses() async throws {
        let (perception, transport) = makePerception()
        await transport.setShellResponse(
            "uiautomator dump /sdcard/window_dump.xml",
            TransportResult(exitCode: 0, stdout: "UI hierchary dumped to: /sdcard/window_dump.xml", stderr: "")
        )
        await transport.setExecOutResponse(
            for: "cat",
            TransportBinaryResult(exitCode: 0, stdout: Data(sampleDump.utf8), stderr: "")
        )

        let hierarchy = try await perception.uiHierarchy(deviceSerial: "SERIAL", timeout: 10)
        XCTAssertEqual(hierarchy.elements.count, 5)

        let invocations = await transport.invocations
        XCTAssertTrue(
            invocations.contains { $0.arguments == ["SERIAL", "exec-out", "cat", "/sdcard/window_dump.xml"] },
            "expected a binary-safe read of the staged dump, got \(invocations.map(\.arguments))"
        )
    }

    /// `uiautomator dump` reports failure in text while exiting 0 on some builds. Reading the
    /// stale file after that would describe a screen that is no longer there.
    func testUIHierarchyRejectsDeviceReportedErrorDespiteExitZero() async throws {
        let (perception, transport) = makePerception()
        await transport.setShellResponse(
            "uiautomator dump /sdcard/window_dump.xml",
            TransportResult(exitCode: 0, stdout: "ERROR: could not get idle state.", stderr: "")
        )

        do {
            _ = try await perception.uiHierarchy(deviceSerial: "SERIAL", timeout: 10)
            XCTFail("Expected adbCommandFailed")
        } catch let error as PixelDesktopError {
            guard case .adbCommandFailed = error else {
                return XCTFail("Expected adbCommandFailed, got \(error)")
            }
        }
    }

    func testScreenshotReturnsPNGBytes() async throws {
        let (perception, transport) = makePerception()
        let png = TestPNG.valid
        await transport.setExecOutResponse(
            for: "screencap",
            TransportBinaryResult(exitCode: 0, stdout: png, stderr: "")
        )

        let data = try await perception.screenshot(deviceSerial: "SERIAL", timeout: 10)
        XCTAssertEqual(data, png)
    }

    /// `screencap` can exit 0 with an empty or truncated payload. That is a failed capture,
    /// not a blank screen.
    func testScreenshotRejectsEmptyPayload() async throws {
        let (perception, transport) = makePerception()
        await transport.setExecOutResponse(
            for: "screencap",
            TransportBinaryResult(exitCode: 0, stdout: Data(), stderr: "")
        )

        do {
            _ = try await perception.screenshot(deviceSerial: "SERIAL", timeout: 10)
            XCTFail("Expected verificationFailed")
        } catch let error as PixelDesktopError {
            guard case .verificationFailed = error else {
                return XCTFail("Expected verificationFailed, got \(error)")
            }
        }
    }

    func testScreenshotRejectsNonZeroExit() async throws {
        let (perception, transport) = makePerception()
        await transport.setExecOutResponse(
            for: "screencap",
            TransportBinaryResult(exitCode: 1, stdout: Data(), stderr: "error: device offline")
        )

        do {
            _ = try await perception.screenshot(deviceSerial: "SERIAL", timeout: 10)
            XCTFail("Expected adbCommandFailed")
        } catch let error as PixelDesktopError {
            guard case .adbCommandFailed = error else {
                return XCTFail("Expected adbCommandFailed, got \(error)")
            }
        }
    }

    // MARK: - PNG verification

    func testPNGSignatureAcceptsWellFormed() {
        XCTAssertTrue(PNGSignature.isValid(TestPNG.valid))
    }

    func testPNGSignatureRejectsTruncated() {
        let truncated = TestPNG.valid.dropLast(4)
        XCTAssertFalse(PNGSignature.isValid(Data(truncated)))
    }

    func testPNGDimensionsFromIHDR() {
        let dimensions = PNGSignature.dimensions(TestPNG.valid)
        XCTAssertEqual(dimensions?.width, 1080)
        XCTAssertEqual(dimensions?.height, 2400)
    }

    func testPNGDimensionsRejectsHeaderOnly() {
        XCTAssertNil(PNGSignature.dimensions(Data(PNGSignature.magic)))
    }

    func testPNGSignatureRejectsHeaderOnly() {
        XCTAssertFalse(PNGSignature.isValid(Data(PNGSignature.magic)))
    }

    // MARK: - Screenshot store

    func testScreenshotStoreWritesDistinctFilesInSameSecond() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pd-screenshot-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try ScreenshotStore(directory: directory)
        let date = Date(timeIntervalSince1970: 1_760_000_000)

        let first = try store.write(TestPNG.valid, at: date)
        let second = try store.write(TestPNG.valid, at: date)

        XCTAssertNotEqual(first, second)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        XCTAssertEqual(try Data(contentsOf: first), TestPNG.valid)
        XCTAssertTrue(first.lastPathComponent.hasSuffix(".png"))
    }

    // MARK: - Logcat line parsing

    func testLogcatLineParsesThreadtime() throws {
        let line = try XCTUnwrap(
            LogcatLine.parse("06-12 14:03:22.194  1234  5678 I ActivityManager: Start proc 4321:com.example")
        )

        XCTAssertEqual(line.timestamp, "06-12 14:03:22.194")
        XCTAssertEqual(line.pid, 1234)
        XCTAssertEqual(line.tid, 5678)
        XCTAssertEqual(line.priority, .info)
        XCTAssertEqual(line.tag, "ActivityManager")
        XCTAssertEqual(line.message, "Start proc 4321:com.example")
    }

    /// Messages contain colons. The tag/message split must be the first `": "` boundary, not
    /// the first colon anywhere, or every binder and URL line would be mis-tagged.
    func testLogcatLineKeepsColonsInMessage() throws {
        let line = try XCTUnwrap(
            LogcatLine.parse("06-12 14:03:22.194  900  901 D Binder  : Binder:900_2 transaction http://x.y/z")
        )
        XCTAssertEqual(line.tag, "Binder")
        XCTAssertEqual(line.message, "Binder:900_2 transaction http://x.y/z")
    }

    /// The real threadtime shape pads short tags to eight characters, so `chatty` arrives as
    /// `chatty  : msg` — two spaces before the colon and none after the tag. A parser keyed on
    /// `" : "` rejects this line outright, which is what the first version of this test caught.
    func testLogcatLineParsesPaddedShortTag() throws {
        let line = try XCTUnwrap(
            LogcatLine.parse("06-12 14:03:22.194  1234  1234 I chatty  : uid=10123 com.example expire 5 lines")
        )
        XCTAssertEqual(line.tag, "chatty")
        XCTAssertEqual(line.message, "uid=10123 com.example expire 5 lines")
    }

    func testLogcatLineRejectsBufferBanner() {
        XCTAssertNil(LogcatLine.parse("--------- beginning of main"))
        XCTAssertNil(LogcatLine.parse(""))
        XCTAssertNil(LogcatLine.parse("random text that is long enough to pass a naive length check"))
    }

    func testLogcatPrioritySeverityOrdering() {
        XCTAssertLessThan(LogcatLine.Priority.verbose.severity, LogcatLine.Priority.error.severity)
        XCTAssertGreaterThan(LogcatLine.Priority.assert.severity, LogcatLine.Priority.fatal.severity)
    }

    // MARK: - Logcat filter

    func testFilterBuildsTagAndPriorityArguments() throws {
        let filter = LogcatFilter(tag: "PixelWorker", minimumPriority: .warn)
        XCTAssertEqual(
            try filter.arguments(),
            ["logcat", "-v", "threadtime", "-s", "PixelWorker:W"]
        )
    }

    func testFilterWithoutTagUsesWildcardPriority() throws {
        let filter = LogcatFilter(minimumPriority: .error)
        XCTAssertEqual(try filter.arguments(), ["logcat", "-v", "threadtime", "*:E"])
    }

    /// The tag is interpolated into a shell command, so a tag that is not an identifier is
    /// rejected before any session exists — this is the injection boundary for this layer.
    func testFilterRejectsShellMetacharacters() {
        for tag in ["Bad Tag", "tag;reboot", "tag|id", "$(id)", "tag\nreboot"] {
            XCTAssertThrowsError(try LogcatFilter(tag: tag).arguments(), "should reject '\(tag)'")
        }
    }

    func testFilterAcceptsAppliesPriorityFloor() {
        let filter = LogcatFilter(minimumPriority: .warn)
        let verbose = LogcatLine(
            timestamp: "06-12 14:03:22.194", pid: 1, tid: 1, priority: .verbose,
            tag: "T", message: "m", raw: "raw"
        )
        let error = LogcatLine(
            timestamp: "06-12 14:03:22.194", pid: 1, tid: 1, priority: .error,
            tag: "T", message: "m", raw: "raw"
        )
        XCTAssertFalse(filter.accepts(verbose))
        XCTAssertTrue(filter.accepts(error))
    }

    // MARK: - Logcat buffer

    func testBufferIsBoundedAndReportsDrops() {
        let buffer = LogcatBuffer(capacity: 3)
        for index in 0..<5 {
            buffer.append(
                LogcatLine(
                    timestamp: "06-12 14:03:22.194", pid: index, tid: 0, priority: .info,
                    tag: "T", message: "m\(index)", raw: "raw\(index)"
                )
            )
        }

        XCTAssertEqual(buffer.lines.count, 3)
        XCTAssertEqual(buffer.lines.first?.message, "m2", "oldest lines are dropped first")
        XCTAssertEqual(buffer.counts.accepted, 5)
        XCTAssertEqual(buffer.counts.dropped, 2)
    }

    // MARK: - Port forwarding

    func testForwardListParses() {
        let output = """
        DEADBEEF000000 tcp:8080 tcp:8080
        DEADBEEF000000 tcp:9000 localabstract:scrcpy
        garbage line
        """
        let forwards = PortForward.parseList(output)
        XCTAssertEqual(forwards.count, 2)
        XCTAssertEqual(forwards[0].local, "tcp:8080")
        XCTAssertEqual(forwards[1].remote, "localabstract:scrcpy")
    }

    func testForwardValidationRejectsOutOfRangePorts() {
        for port in [0, -1, 65_536, 100_000] {
            XCTAssertThrowsError(try ADBPortForwarding.validatePort(port, label: "local"))
        }
        XCTAssertNoThrow(try ADBPortForwarding.validatePort(8080, label: "local"))
    }

    func testForwardIssuesExpectedCommand() async throws {
        let transport = MockTransport()
        let forwarding = ADBPortForwarding(transport: transport)

        let forward = try await forwarding.forward(
            deviceSerial: "SERIAL", localPort: 8080, remotePort: 8080, timeout: 10
        )

        XCTAssertEqual(forward, PortForward(serial: "SERIAL", local: "tcp:8080", remote: "tcp:8080"))

        let invocations = await transport.invocations
        XCTAssertTrue(
            invocations.contains { $0.command == "-s" && $0.arguments == ["SERIAL", "forward", "tcp:8080", "tcp:8080"] },
            "unexpected invocations: \(invocations.map(\.arguments))"
        )
    }

    func testForwardFailureSurfacesTail() async throws {
        let transport = MockTransport()
        await transport.setDefaultResult(
            TransportResult(exitCode: 1, stdout: "", stderr: "cannot bind listener: Address already in use")
        )
        let forwarding = ADBPortForwarding(transport: transport)

        do {
            _ = try await forwarding.forward(deviceSerial: "SERIAL", localPort: 8080, remotePort: 8080, timeout: 10)
            XCTFail("Expected adbCommandFailed")
        } catch let error as PixelDesktopError {
            guard case .adbCommandFailed(_, let exitCode, let stderr) = error else {
                return XCTFail("Expected adbCommandFailed, got \(error)")
            }
            XCTAssertEqual(exitCode, 1)
            XCTAssertTrue(stderr.contains("Address already in use"))
        }
    }
}

/// A minimal byte string that satisfies `PNGSignature`: magic header plus the IEND trailer.
///
/// Deliberately not a real decodable image — the check under test is the signature and
/// trailer, and a fixture that can only be produced by `screencap` would make the test
/// device-dependent.
enum TestPNG {
    static var valid: Data {
        var data = Data(PNGSignature.magic)
        // IHDR length + type, so the payload is not header-only.
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52])
        data.append(contentsOf: [0x00, 0x00, 0x04, 0x38, 0x00, 0x00, 0x09, 0x60])
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82])
        return data
    }
}

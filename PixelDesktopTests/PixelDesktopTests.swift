import XCTest
@testable import PixelDesktop

@MainActor
final class PixelDesktopTests: XCTestCase {

    // MARK: - DTCA1Worker Tests

    func testDTCA1TokenizeBasic() {
        let text = "Hello world hello"
        let tokens = DTCA1Worker.tokenize(text)
        XCTAssertEqual(tokens, ["hello", "world", "hello"])
    }

    func testDTCA1TokenizeWithPunctuation() {
        let text = "Hello, world! How are you?"
        let tokens = DTCA1Worker.tokenize(text)
        XCTAssertEqual(tokens, ["hello", "world", "how", "are", "you"])
    }

    func testDTCA1TokenizeEmptyString() {
        let tokens = DTCA1Worker.tokenize("")
        XCTAssertTrue(tokens.isEmpty)
    }

    func testDTCA1TokenizeOnlyPunctuation() {
        let tokens = DTCA1Worker.tokenize("!@#$%^&*()")
        XCTAssertTrue(tokens.isEmpty)
    }

    func testDTCA1TokenizeMixedCase() {
        let text = "Hello HELLO hello"
        let tokens = DTCA1Worker.tokenize(text)
        XCTAssertEqual(tokens, ["hello", "hello", "hello"])
    }

    func testDTCA1WordFrequency() {
        let words = ["apple", "banana", "apple", "cherry", "banana", "apple"]
        let freq = DTCA1Worker.computeWordFrequency(words)
        XCTAssertEqual(freq["apple"], 3)
        XCTAssertEqual(freq["banana"], 2)
        XCTAssertEqual(freq["cherry"], 1)
    }

    func testDTCA1ClassifyTechnical() {
        let words = ["api", "code", "function", "class", "data", "server", "client", "http", "adb", "pixel"]
        let (classification, confidence) = DTCA1Worker.classify(words: words)
        XCTAssertEqual(classification, .technical)
        XCTAssertGreaterThan(confidence, 0.1)
    }

    func testDTCA1ClassifyNaturalLanguage() {
        let words = ["the", "a", "is", "are", "was", "were", "be", "have", "has", "had"]
        let (classification, confidence) = DTCA1Worker.classify(words: words)
        XCTAssertEqual(classification, .naturalLanguage)
        XCTAssertGreaterThan(confidence, 0.1)
    }

    func testDTCA1ClassifyMixed() {
        let words = ["the", "api", "is", "code"]
        let (classification, _) = DTCA1Worker.classify(words: words)
        XCTAssertEqual(classification, .mixed)
    }

    func testDTCA1ClassifyEmpty() {
        let (classification, confidence) = DTCA1Worker.classify(words: [])
        XCTAssertEqual(classification, .mixed)
        XCTAssertEqual(confidence, 0.0)
    }

    func testDTCA1ValidateInputEmpty() {
        XCTAssertNoThrow(try DTCA1Worker.validateInput(""))
    }

    func testDTCA1ValidateInputTooLarge() {
        let largeInput = String(repeating: "a", count: 10_001)
        XCTAssertThrowsError(try DTCA1Worker.validateInput(largeInput)) { error in
            guard case PixelDesktopError.invalidInput = error else {
                XCTFail("Expected invalidInput error")
                return
            }
        }
    }

    func testDTCA1ValidateInputNullBytes() {
        XCTAssertThrowsError(try DTCA1Worker.validateInput("hello\0world")) { error in
            guard case PixelDesktopError.invalidInput = error else {
                XCTFail("Expected invalidInput error")
                return
            }
        }
    }

    func testDTCA1ValidateInputValid() {
        XCTAssertNoThrow(try DTCA1Worker.validateInput("Hello, world!"))
    }

    func testDTCA1ExecuteBasic() throws {
        let input = "The quick brown fox jumps over the lazy dog"
        let result = try DTCA1Worker.execute(input)

        XCTAssertEqual(result.status, "COMPLETED")
        XCTAssertEqual(result.inputCharacters, input.count)
        XCTAssertEqual(result.totalWords, 9)
        XCTAssertEqual(result.uniqueWords, 8)
        XCTAssertEqual(result.topWords.count, 5)
        XCTAssertEqual(result.topWords[0].word, "the")
        XCTAssertEqual(result.topWords[0].count, 2)
        XCTAssertEqual(result.classification, "NATURAL_LANGUAGE")
        XCTAssertGreaterThanOrEqual(result.confidence, 0.0)
        XCTAssertLessThanOrEqual(result.confidence, 1.0)
        XCTAssertGreaterThan(result.executionTimestampMs, 0)
        XCTAssertGreaterThanOrEqual(result.executionDurationMs, 0)
    }

    func testDTCA1ExecuteEmpty() throws {
        let result = try DTCA1Worker.execute("")

        XCTAssertEqual(result.status, "COMPLETED")
        XCTAssertEqual(result.totalWords, 0)
        XCTAssertEqual(result.uniqueWords, 0)
        XCTAssertTrue(result.topWords.isEmpty)
        XCTAssertEqual(result.classification, "MIXED")
    }

    func testDTCA1ExecuteDeterministic() throws {
        let input = "The quick brown fox jumps over the lazy dog. The dog barks at the fox."
        let result1 = try DTCA1Worker.execute(input)
        let result2 = try DTCA1Worker.execute(input)

        XCTAssertEqual(result1.status, result2.status)
        XCTAssertEqual(result1.totalWords, result2.totalWords)
        XCTAssertEqual(result1.uniqueWords, result2.uniqueWords)
        XCTAssertEqual(result1.classification, result2.classification)
        XCTAssertEqual(result1.confidence, result2.confidence, accuracy: 0.0001)
        XCTAssertEqual(result1.topWords.count, result2.topWords.count)
    }

    // MARK: - ResultVerifier Tests

    func testVerifierSuccess() throws {
        let input = "Hello world"
        let pixelResult = try DTCA1Worker.execute(input)
        let localResult = try DTCA1Worker.execute(input)

        let verification = ResultVerifier.verify(
            pixelResult: pixelResult,
            localResult: localResult,
            originalInput: input
        )

        XCTAssertTrue(verification.isVerified)
        XCTAssertTrue(verification.mismatches.isEmpty)
    }

    func testVerifierFailureOnWordCount() throws {
        let input = "Hello world"
        var pixelResult = try DTCA1Worker.execute(input)
        let localResult = try DTCA1Worker.execute(input)

        // Tamper with the result
        pixelResult = DTCA1Result(
            status: "COMPLETED",
            inputCharacters: pixelResult.inputCharacters,
            totalWords: pixelResult.totalWords + 1,
            uniqueWords: pixelResult.uniqueWords,
            topWords: pixelResult.topWords,
            classification: pixelResult.classification,
            confidence: pixelResult.confidence,
            executionTimestampMs: pixelResult.executionTimestampMs,
            executionDurationMs: pixelResult.executionDurationMs
        )

        let verification = ResultVerifier.verify(
            pixelResult: pixelResult,
            localResult: localResult,
            originalInput: input
        )

        XCTAssertFalse(verification.isVerified)
        XCTAssertFalse(verification.mismatches.isEmpty)
    }

    func testVerifierFailureOnClassification() throws {
        let input = "Hello world"
        var pixelResult = try DTCA1Worker.execute(input)
        let localResult = try DTCA1Worker.execute(input)

        pixelResult = DTCA1Result(
            status: "COMPLETED",
            inputCharacters: pixelResult.inputCharacters,
            totalWords: pixelResult.totalWords,
            uniqueWords: pixelResult.uniqueWords,
            topWords: pixelResult.topWords,
            classification: "TECHNICAL",
            confidence: pixelResult.confidence,
            executionTimestampMs: pixelResult.executionTimestampMs,
            executionDurationMs: pixelResult.executionDurationMs
        )

        let verification = ResultVerifier.verify(
            pixelResult: pixelResult,
            localResult: localResult,
            originalInput: input
        )

        XCTAssertFalse(verification.isVerified)
    }

    func testVerifierFailureOnStatus() throws {
        let input = "Hello world"
        var pixelResult = try DTCA1Worker.execute(input)
        let localResult = try DTCA1Worker.execute(input)

        pixelResult = DTCA1Result(
            status: "FAILED",
            inputCharacters: pixelResult.inputCharacters,
            totalWords: pixelResult.totalWords,
            uniqueWords: pixelResult.uniqueWords,
            topWords: pixelResult.topWords,
            classification: pixelResult.classification,
            confidence: pixelResult.confidence,
            executionTimestampMs: pixelResult.executionTimestampMs,
            executionDurationMs: pixelResult.executionDurationMs
        )

        let verification = ResultVerifier.verify(
            pixelResult: pixelResult,
            localResult: localResult,
            originalInput: input
        )

        XCTAssertFalse(verification.isVerified)
    }

    // MARK: - PixelDevice Tests

    func testPixelDeviceDisplayName() {
        let device = PixelDevice(
            id: "test123",
            serialNumber: "test123",
            model: "Pixel 7a",
            manufacturer: "Google",
            androidVersion: "14",
            apiLevel: 34,
            architecture: "arm64-v8a",
            state: .device
        )
        XCTAssertEqual(device.displayName, "Pixel 7a")
    }

    func testPixelDeviceDisplayNameFallback() {
        let device = PixelDevice(
            id: "test123",
            serialNumber: "test123",
            model: "",
            manufacturer: "",
            androidVersion: "",
            apiLevel: 0,
            architecture: "",
            state: .device
        )
        XCTAssertEqual(device.displayName, "test123")
    }

    func testDeviceStateIsConnected() {
        XCTAssertTrue(DeviceState.device.isConnected)
        XCTAssertFalse(DeviceState.unauthorized.isConnected)
        XCTAssertFalse(DeviceState.offline.isConnected)
        XCTAssertFalse(DeviceState.unknown.isConnected)
    }

    // MARK: - PixelDesktopError Tests

    func testErrorDescription() {
        let error = PixelDesktopError.deviceNotFound
        XCTAssertEqual(error.description, "No authorized Android device found")
    }

    func testErrorRecoverable() {
        XCTAssertTrue(PixelDesktopError.deviceNotFound.isRecoverable)
        XCTAssertTrue(PixelDesktopError.timeout(operation: "test", duration: 30).isRecoverable)
        XCTAssertFalse(PixelDesktopError.invalidInput("test").isRecoverable)
        XCTAssertFalse(PixelDesktopError.verificationFailed(reason: "test").isRecoverable)
    }

    // MARK: - ADBTransport Tests

    func testADBTransportParseDeviceList() {
        let output = """
        List of devices attached
        ABC123456789    device product:bluefin model:Pixel_7a device:bluefin
        DEF987654321    unauthorized
        """

        let transport = ADBTransport()
        let devices = transport.parseDeviceList(output)

        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(devices[0].serialNumber, "ABC123456789")
        XCTAssertEqual(devices[0].state, DeviceState.device)
        XCTAssertEqual(devices[0].model, "Pixel_7a")
        XCTAssertEqual(devices[1].serialNumber, "DEF987654321")
        XCTAssertEqual(devices[1].state, DeviceState.unauthorized)
    }

    func testADBTransportParseEmptyList() {
        let output = "List of devices attached\n"
        let transport = ADBTransport()
        let devices = transport.parseDeviceList(output)
        XCTAssertTrue(devices.isEmpty)
    }

    // MARK: - AppLogger Tests

    func testAppLoggerAddEntry() {
        let logger = AppLogger()
        logger.info("Test message")
        XCTAssertEqual(logger.entries.count, 1)
        XCTAssertEqual(logger.entries[0].message, "Test message")
        XCTAssertEqual(logger.entries[0].level, .info)
    }

    func testAppLoggerClear() {
        let logger = AppLogger()
        logger.info("Test message 1")
        logger.info("Test message 2")
        XCTAssertEqual(logger.entries.count, 2)
        logger.clear()
        XCTAssertEqual(logger.entries.count, 0)
    }

    func testAppLoggerMaxEntries() {
        let logger = AppLogger()
        for i in 0..<600 {
            logger.info("Message \(i)")
        }
        XCTAssertEqual(logger.entries.count, 500)
    }

    // MARK: - DeviceProperties Tests

    func testDevicePropertiesMakeTrimsWhitespace() throws {
        let properties = try DeviceProperties.make(
            androidVersion: "  16\n",
            apiLevelRaw: " 36 ",
            architecture: "\tarm64-v8a\n"
        )

        XCTAssertEqual(properties.androidVersion, "16")
        XCTAssertEqual(properties.apiLevel, 36)
        XCTAssertEqual(properties.architecture, "arm64-v8a")
    }

    func testDevicePropertiesMakeRejectsEmptyVersion() {
        XCTAssertThrowsError(
            try DeviceProperties.make(androidVersion: "", apiLevelRaw: "36", architecture: "arm64-v8a")
        ) { error in
            guard case PixelDesktopError.invalidInput = error else {
                return XCTFail("Expected invalidInput, got \(error)")
            }
        }
    }

    func testDevicePropertiesMakeRejectsEmptyArchitecture() {
        XCTAssertThrowsError(
            try DeviceProperties.make(androidVersion: "16", apiLevelRaw: "36", architecture: "  ")
        ) { error in
            guard case PixelDesktopError.invalidInput = error else {
                return XCTFail("Expected invalidInput, got \(error)")
            }
        }
    }

    func testDevicePropertiesMakeRejectsNonNumericApiLevel() {
        XCTAssertThrowsError(
            try DeviceProperties.make(androidVersion: "16", apiLevelRaw: "thirty-six", architecture: "arm64-v8a")
        ) { error in
            guard case PixelDesktopError.invalidInput = error else {
                return XCTFail("Expected invalidInput, got \(error)")
            }
        }
    }

    func testDevicePropertiesMakeRejectsZeroApiLevel() {
        XCTAssertThrowsError(
            try DeviceProperties.make(androidVersion: "16", apiLevelRaw: "0", architecture: "arm64-v8a")
        ) { error in
            guard case PixelDesktopError.invalidInput = error else {
                return XCTFail("Expected invalidInput, got \(error)")
            }
        }
    }

    func testDevicePropertyKeysMatchApprovedAcquisitionSources() {
        XCTAssertEqual(DevicePropertyKey.androidVersion, "ro.build.version.release")
        XCTAssertEqual(DevicePropertyKey.apiLevel, "ro.build.version.sdk")
        XCTAssertEqual(DevicePropertyKey.architecture, "ro.product.cpu.abi")
    }

    // MARK: - ADBTransport.getprop Tests

    func testGetpropSuccess() async throws {
        let transport = MockTransport()
        await transport.setResponse(
            forKey: DevicePropertyKey.androidVersion,
            result: TransportResult(exitCode: 0, stdout: "16\n", stderr: "")
        )

        let value = try await transport.getprop(
            deviceSerial: "TEST123",
            key: DevicePropertyKey.androidVersion,
            timeout: 5
        )

        XCTAssertEqual(value, "16")

        let invocations = await transport.invocations
        XCTAssertEqual(invocations.count, 1)
        XCTAssertEqual(invocations[0].command, "-s")
        XCTAssertEqual(invocations[0].arguments, ["TEST123", "shell", "getprop", "ro.build.version.release"])
    }

    func testGetpropFailureSurfacesAdbError() async {
        let transport = MockTransport()
        await transport.setResponse(
            forKey: DevicePropertyKey.apiLevel,
            result: TransportResult(exitCode: 1, stdout: "", stderr: "error: device offline")
        )

        do {
            _ = try await transport.getprop(
                deviceSerial: "TEST123",
                key: DevicePropertyKey.apiLevel,
                timeout: 5
            )
            XCTFail("Expected adbCommandFailed")
        } catch let error as PixelDesktopError {
            guard case .adbCommandFailed(let command, let exitCode, _) = error else {
                return XCTFail("Expected adbCommandFailed, got \(error)")
            }
            XCTAssertEqual(command, "getprop ro.build.version.sdk")
            XCTAssertEqual(exitCode, 1)
        } catch {
            XCTFail("Expected PixelDesktopError, got \(error)")
        }
    }

    func testGetpropUnsetPropertyIsRejected() async {
        let transport = MockTransport()
        await transport.setResponse(
            forKey: "ro.unset.key",
            result: TransportResult(exitCode: 0, stdout: "\n", stderr: "")
        )

        do {
            _ = try await transport.getprop(deviceSerial: "TEST123", key: "ro.unset.key", timeout: 5)
            XCTFail("Expected invalidInput for unset property")
        } catch let error as PixelDesktopError {
            guard case .invalidInput = error else {
                return XCTFail("Expected invalidInput, got \(error)")
            }
        } catch {
            XCTFail("Expected PixelDesktopError, got \(error)")
        }
    }

    // MARK: - DeviceEnricher Tests

    func testEnrichDevicePopulatesProperties() async throws {
        let transport = MockTransport()
        await transport.setDefaultResult(TransportResult(exitCode: 0, stdout: "16\n", stderr: ""))
        await transport.setResponse(
            forKey: DevicePropertyKey.apiLevel,
            result: TransportResult(exitCode: 0, stdout: "36\n", stderr: "")
        )
        await transport.setResponse(
            forKey: DevicePropertyKey.architecture,
            result: TransportResult(exitCode: 0, stdout: "arm64-v8a\n", stderr: "")
        )

        let discovered = PixelDevice(
            id: "3C261JEHN25632",
            serialNumber: "3C261JEHN25632",
            model: "Pixel_7a",
            manufacturer: "lynx",
            androidVersion: "",
            apiLevel: 0,
            architecture: "",
            state: .device
        )

        let enriched = try await DeviceEnricher(transport: transport).enrich(discovered)

        XCTAssertEqual(enriched.androidVersion, "16")
        XCTAssertEqual(enriched.apiLevel, 36)
        XCTAssertEqual(enriched.architecture, "arm64-v8a")
        XCTAssertEqual(enriched.model, "Pixel_7a")
        XCTAssertEqual(enriched.manufacturer, "lynx")
        XCTAssertEqual(enriched.serialNumber, "3C261JEHN25632")

        let invocations = await transport.invocations
        XCTAssertEqual(invocations.count, 3)
        XCTAssertEqual(invocations.map { $0.arguments.last }, [
            DevicePropertyKey.androidVersion,
            DevicePropertyKey.apiLevel,
            DevicePropertyKey.architecture
        ])
    }

    func testEnrichDeviceRejectsNonConnectedState() async {
        let transport = MockTransport()
        let offline = PixelDevice(
            id: "TEST123",
            serialNumber: "TEST123",
            model: "Pixel_7a",
            manufacturer: "lynx",
            androidVersion: "",
            apiLevel: 0,
            architecture: "",
            state: .offline
        )

        do {
            _ = try await DeviceEnricher(transport: transport).enrich(offline)
            XCTFail("Expected deviceOffline")
        } catch let error as PixelDesktopError {
            XCTAssertEqual(error, PixelDesktopError.deviceOffline)
        } catch {
            XCTFail("Expected PixelDesktopError, got \(error)")
        }

        let invocations = await transport.invocations
        XCTAssertTrue(invocations.isEmpty, "Enrichment must not touch the device when it is not connected")
    }

    func testEnrichDevicePropagatesPropertyFailure() async {
        let transport = MockTransport()
        await transport.setDefaultResult(TransportResult(exitCode: 0, stdout: "16\n", stderr: ""))
        await transport.setResponse(
            forKey: DevicePropertyKey.apiLevel,
            result: TransportResult(exitCode: 0, stdout: "", stderr: "")
        )

        let device = PixelDevice(
            id: "TEST123",
            serialNumber: "TEST123",
            model: "Pixel_7a",
            manufacturer: "lynx",
            androidVersion: "",
            apiLevel: 0,
            architecture: "",
            state: .device
        )

        do {
            _ = try await DeviceEnricher(transport: transport).enrich(device)
            XCTFail("Expected failure when a property is unset")
        } catch let error as PixelDesktopError {
            guard case .invalidInput = error else {
                return XCTFail("Expected invalidInput, got \(error)")
            }
        } catch {
            XCTFail("Expected PixelDesktopError, got \(error)")
        }
    }

    // MARK: - DeviceManager Enrichment Tests

    func testDeviceManagerEnrichUpdatesPublishedDevice() async throws {
        let transport = MockTransport()
        await transport.setDefaultResult(TransportResult(exitCode: 0, stdout: "16\n", stderr: ""))
        await transport.setResponse(
            forKey: DevicePropertyKey.apiLevel,
            result: TransportResult(exitCode: 0, stdout: "36\n", stderr: "")
        )
        await transport.setResponse(
            forKey: DevicePropertyKey.architecture,
            result: TransportResult(exitCode: 0, stdout: "arm64-v8a\n", stderr: "")
        )
        await transport.setDeviceList([
            PixelDevice(
                id: "3C261JEHN25632",
                serialNumber: "3C261JEHN25632",
                model: "Pixel_7a",
                manufacturer: "lynx",
                androidVersion: "",
                apiLevel: 0,
                architecture: "",
                state: .device
            )
        ])

        let manager = await DeviceManager(transport: transport)
        await manager.refreshDevices()

        let discovered = await manager.devices
        XCTAssertEqual(discovered.count, 1)
        XCTAssertEqual(discovered[0].androidVersion, "")

        let enriched = try await manager.enrichDevice(serial: "3C261JEHN25632")

        XCTAssertEqual(enriched?.androidVersion, "16")
        XCTAssertEqual(enriched?.apiLevel, 36)

        let published = await manager.devices
        XCTAssertEqual(published[0].androidVersion, "16")
        XCTAssertEqual(published[0].apiLevel, 36)
        XCTAssertEqual(published[0].architecture, "arm64-v8a")
    }

    func testDeviceManagerEnrichUnknownSerialReturnsNil() async throws {
        let transport = MockTransport()
        let manager = await DeviceManager(transport: transport)

        let result = try await manager.enrichDevice(serial: "DOES_NOT_EXIST")

        XCTAssertNil(result)
        let invocations = await transport.invocations
        XCTAssertTrue(invocations.isEmpty)
    }

    func testDiscoveryLeavesPropertiesUnpopulated() async {
        let transport = MockTransport()
        await transport.setDeviceList([
            PixelDevice(
                id: "TEST123",
                serialNumber: "TEST123",
                model: "Pixel_7a",
                manufacturer: "lynx",
                androidVersion: "",
                apiLevel: 0,
                architecture: "",
                state: .device
            )
        ])

        let manager = await DeviceManager(transport: transport)
        await manager.refreshDevices()

        let devices = await manager.devices
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].androidVersion, "")
        XCTAssertEqual(devices[0].apiLevel, 0)
        XCTAssertEqual(devices[0].architecture, "")

        let invocations = await transport.invocations
        XCTAssertTrue(
            invocations.isEmpty,
            "Discovery parsing must not issue getprop calls; enrichment is a separate responsibility"
        )
    }
}

// MARK: - Test Doubles

/// Records invocations and returns canned responses, so enrichment can be tested
/// without a physical device.
actor MockTransport: TransportProtocol {
    struct Invocation: Sendable, Equatable {
        let command: String
        let arguments: [String]
    }

    private(set) var invocations: [Invocation] = []
    private var responses: [String: TransportResult] = [:]
    private var defaultResult = TransportResult(exitCode: 0, stdout: "", stderr: "")
    private var deviceList: [PixelDevice] = []

    func setResponse(forKey key: String, result: TransportResult) {
        responses[key] = result
    }

    func setDefaultResult(_ result: TransportResult) {
        defaultResult = result
    }

    func setDeviceList(_ devices: [PixelDevice]) {
        deviceList = devices
    }

    func execute(command: String, arguments: [String], timeout: TimeInterval) async throws -> TransportResult {
        invocations.append(Invocation(command: command, arguments: arguments))

        if let key = arguments.last, let response = responses[key] {
            return response
        }

        return defaultResult
    }

    func listDevices() async throws -> [PixelDevice] {
        deviceList
    }

    func getprop(deviceSerial: String, key: String, timeout: TimeInterval) async throws -> String {
        let result = try await execute(
            command: "-s",
            arguments: [deviceSerial, "shell", "getprop", key],
            timeout: timeout
        )

        guard result.isSuccess else {
            throw PixelDesktopError.adbCommandFailed(
                command: "getprop \(key)",
                exitCode: Int(result.exitCode),
                stderr: result.stderr
            )
        }

        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !value.isEmpty else {
            throw PixelDesktopError.invalidInput("Property '\(key)' is unset on device \(deviceSerial)")
        }

        return value
    }
}

// MARK: - Real Device Integration Tests

/// Opt-in tests that talk to a physically attached Android device.
///
/// They are skipped unless `PIXELDESKTOP_DEVICE_SERIAL` is set, so the default
/// suite stays hermetic and does not fail on a machine with no device attached.
///
/// Run explicitly:
///
///     xcodebuild -project PixelDesktop.xcodeproj -scheme PixelDesktop \
///       -configuration Debug test \
///       TEST_RUNNER_PIXELDESKTOP_DEVICE_SERIAL=3C261JEHN25632
///
/// Assertions check only that values are present and well-formed. They
/// deliberately do not pin an expected Android version or API level: the point
/// is to verify the acquisition path, not to freeze the device's current build.
final class PixelDeviceIntegrationTests: XCTestCase {
    private var deviceSerial: String? {
        let value = ProcessInfo.processInfo.environment["PIXELDESKTOP_DEVICE_SERIAL"]
        return (value?.isEmpty ?? true) ? nil : value
    }

    func testRealDeviceDiscoveryAndEnrichment() async throws {
        guard let serial = deviceSerial else {
            throw XCTSkip("PIXELDESKTOP_DEVICE_SERIAL not set; skipping real-device verification")
        }

        let transport = ADBTransport()
        let discovered = try await transport.listDevices()

        guard let device = discovered.first(where: { $0.serialNumber == serial }) else {
            XCTFail("Device \(serial) not attached. Attached: \(discovered.map(\.serialNumber))")
            return
        }

        XCTAssertEqual(device.state, .device)

        // Discovery alone must not populate these; enrichment owns them.
        XCTAssertEqual(device.androidVersion, "")
        XCTAssertEqual(device.apiLevel, 0)
        XCTAssertEqual(device.architecture, "")

        let enriched = try await DeviceEnricher(transport: transport).enrich(device)

        print("""
        REAL-DEVICE VERIFICATION
          serial:     \(enriched.serialNumber)
          model:      \(enriched.model)
          android:    \(enriched.androidVersion)
          api level:  \(enriched.apiLevel)
          abi:        \(enriched.architecture)
        """)

        XCTAssertFalse(enriched.androidVersion.isEmpty)
        XCTAssertGreaterThan(enriched.apiLevel, 0)
        XCTAssertFalse(enriched.architecture.isEmpty)

        // Identity from discovery must survive enrichment untouched.
        XCTAssertEqual(enriched.serialNumber, device.serialNumber)
        XCTAssertEqual(enriched.model, device.model)
        XCTAssertEqual(enriched.state, .device)
    }

    func testRealDeviceUnsetPropertyIsRejected() async throws {
        guard let serial = deviceSerial else {
            throw XCTSkip("PIXELDESKTOP_DEVICE_SERIAL not set; skipping real-device verification")
        }

        let transport = ADBTransport()

        do {
            _ = try await transport.getprop(
                deviceSerial: serial,
                key: "ro.pixeldesktop.definitely.not.a.real.key",
                timeout: 10
            )
            XCTFail("Expected an unset property to be rejected")
        } catch let error as PixelDesktopError {
            guard case .invalidInput = error else {
                return XCTFail("Expected invalidInput, got \(error)")
            }
        } catch {
            XCTFail("Expected PixelDesktopError, got \(error)")
        }
    }

    func testRealDeviceUnknownSerialFails() async throws {
        guard deviceSerial != nil else {
            throw XCTSkip("PIXELDESKTOP_DEVICE_SERIAL not set; skipping real-device verification")
        }

        let transport = ADBTransport()

        do {
            _ = try await transport.getprop(
                deviceSerial: "NOSUCHSERIAL0000",
                key: DevicePropertyKey.androidVersion,
                timeout: 10
            )
            XCTFail("Expected a command failure for an unknown serial")
        } catch let error as PixelDesktopError {
            switch error {
            case .adbCommandFailed, .invalidInput:
                break
            default:
                XCTFail("Expected adbCommandFailed or invalidInput, got \(error)")
            }
        } catch {
            XCTFail("Expected PixelDesktopError, got \(error)")
        }
    }
}

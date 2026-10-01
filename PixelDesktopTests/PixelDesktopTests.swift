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
}

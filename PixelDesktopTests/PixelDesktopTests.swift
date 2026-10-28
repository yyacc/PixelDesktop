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
            originalInput: input,
            expectedSuccessToken: DTCA1Job.successResultToken
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
            originalInput: input,
            expectedSuccessToken: DTCA1Job.successResultToken
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
            originalInput: input,
            expectedSuccessToken: DTCA1Job.successResultToken
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
            originalInput: input,
            expectedSuccessToken: DTCA1Job.successResultToken
        )

        XCTAssertFalse(verification.isVerified)
    }

    // MARK: - AndroidDevice Tests

    func testAndroidDeviceDisplayNamePrefersMarketingName() {
        let device = AndroidDevice(
            id: "test123",
            serialNumber: "test123",
            deviceCodename: "lynx",
            marketingName: "Pixel 7a",
            manufacturer: "Google",
            androidVersion: "16",
            apiLevel: 36,
            architecture: "arm64-v8a",
            supportedABIs: ["arm64-v8a"],
            state: .device
        )
        XCTAssertEqual(device.displayName, "Pixel 7a")
    }

    func testAndroidDeviceDisplayNameFallsBackToCodename() {
        let device = AndroidDevice(
            id: "test123",
            serialNumber: "test123",
            deviceCodename: "lynx",
            marketingName: "",
            manufacturer: "",
            androidVersion: "",
            apiLevel: 0,
            architecture: "",
            supportedABIs: [],
            state: .device
        )
        XCTAssertEqual(device.displayName, "lynx")
    }

    func testAndroidDeviceDisplayNameFallsBackToSerial() {
        let device = AndroidDevice(
            id: "test123",
            serialNumber: "test123",
            deviceCodename: "",
            marketingName: "",
            manufacturer: "",
            androidVersion: "",
            apiLevel: 0,
            architecture: "",
            supportedABIs: [],
            state: .device
        )
        XCTAssertEqual(device.displayName, "test123")
    }

    /// Regression for the Phase 3 defect: `manufacturer` must never be the codename.
    func testAndroidDeviceManufacturerIsNotCodename() {
        let device = AndroidDevice(
            id: "test123",
            serialNumber: "test123",
            deviceCodename: "lynx",
            marketingName: "Pixel 7a",
            manufacturer: "Google",
            androidVersion: "16",
            apiLevel: 36,
            architecture: "arm64-v8a",
            supportedABIs: ["arm64-v8a"],
            state: .device
        )
        XCTAssertNotEqual(device.manufacturer, device.deviceCodename)
        XCTAssertNotEqual(device.marketingName, device.deviceCodename)
    }

    func testDeviceStateIsConnected() {
        XCTAssertTrue(DeviceState.device.isConnected)
        XCTAssertFalse(DeviceState.unauthorized.isConnected)
        XCTAssertFalse(DeviceState.offline.isConnected)
        XCTAssertFalse(DeviceState.unknown.isConnected)
    }

    // MARK: - DeviceCapabilities Tests

    func testCapabilitiesDerivedFromDevice() {
        let device = AndroidDevice(
            id: "test123",
            serialNumber: "test123",
            deviceCodename: "lynx",
            marketingName: "Pixel 7a",
            manufacturer: "Google",
            androidVersion: "16",
            apiLevel: 36,
            architecture: "arm64-v8a",
            supportedABIs: ["arm64-v8a"],
            state: .device
        )
        let capabilities = DeviceCapabilities(device: device)

        XCTAssertEqual(capabilities.supportedABIs, ["arm64-v8a"])
        XCTAssertTrue(capabilities.supports(abi: "arm64-v8a"))
        XCTAssertFalse(capabilities.supports(abi: "x86_64"))
    }

    func testCapabilitiesFromDeviceWithNoABIs() {
        let device = AndroidDevice(
            id: "test123",
            serialNumber: "test123",
            deviceCodename: "",
            marketingName: "",
            manufacturer: "",
            androidVersion: "",
            apiLevel: 0,
            architecture: "",
            supportedABIs: [],
            state: .unknown
        )
        let capabilities = DeviceCapabilities(device: device)

        XCTAssertTrue(capabilities.supportedABIs.isEmpty)
        XCTAssertFalse(capabilities.supports(abi: "arm64-v8a"))
    }

    // MARK: - DeviceOperation Tests

    func testDeviceOperationsMatchImplementedCapabilities() {
        // Only operations that actually exist may appear. This list must be extended in the
        // same commit that implements a new operation, never ahead of it.
        // Phase 2: discover, readSystemProperties. Phase 4: the four application operations.
        XCTAssertEqual(Set(DeviceOperation.allCases), [
            .discover,
            .readSystemProperties,
            .listApplications,
            .launchApplication,
            .queryApplicationState,
            .stopApplication
        ])
    }

    func testDeviceOperationDescriptions() {
        XCTAssertEqual(DeviceOperation.discover.description, "Discover attached devices")
        XCTAssertEqual(DeviceOperation.readSystemProperties.description, "Read system properties")
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
        // The `device:` token is the build codename. Discovery must not claim to know
        // the marketing name or manufacturer; those come from getprop during enrichment.
        XCTAssertEqual(devices[0].deviceCodename, "bluefin")
        XCTAssertEqual(devices[0].marketingName, "")
        XCTAssertEqual(devices[0].manufacturer, "")
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
            architecture: "\tarm64-v8a\n",
            marketingName: " Pixel 7a\n",
            manufacturer: " Google ",
            abiListRaw: " arm64-v8a \n"
        )

        XCTAssertEqual(properties.androidVersion, "16")
        XCTAssertEqual(properties.apiLevel, 36)
        XCTAssertEqual(properties.architecture, "arm64-v8a")
        XCTAssertEqual(properties.marketingName, "Pixel 7a")
        XCTAssertEqual(properties.manufacturer, "Google")
        XCTAssertEqual(properties.supportedABIs, ["arm64-v8a"])
    }

    func testDevicePropertiesMakeRejectsEmptyVersion() {
        XCTAssertThrowsError(
            try DeviceProperties.make(androidVersion: "", apiLevelRaw: "36", architecture: "arm64-v8a", marketingName: "Pixel 7a", manufacturer: "Google", abiListRaw: "arm64-v8a")
        ) { error in
            guard case PixelDesktopError.invalidInput = error else {
                return XCTFail("Expected invalidInput, got \(error)")
            }
        }
    }

    func testDevicePropertiesMakeRejectsEmptyArchitecture() {
        XCTAssertThrowsError(
            try DeviceProperties.make(androidVersion: "16", apiLevelRaw: "36", architecture: "  ", marketingName: "Pixel 7a", manufacturer: "Google", abiListRaw: "arm64-v8a")
        ) { error in
            guard case PixelDesktopError.invalidInput = error else {
                return XCTFail("Expected invalidInput, got \(error)")
            }
        }
    }

    func testDevicePropertiesMakeRejectsNonNumericApiLevel() {
        XCTAssertThrowsError(
            try DeviceProperties.make(androidVersion: "16", apiLevelRaw: "thirty-six", architecture: "arm64-v8a", marketingName: "Pixel 7a", manufacturer: "Google", abiListRaw: "arm64-v8a")
        ) { error in
            guard case PixelDesktopError.invalidInput = error else {
                return XCTFail("Expected invalidInput, got \(error)")
            }
        }
    }

    func testDevicePropertiesMakeRejectsZeroApiLevel() {
        XCTAssertThrowsError(
            try DeviceProperties.make(androidVersion: "16", apiLevelRaw: "0", architecture: "arm64-v8a", marketingName: "Pixel 7a", manufacturer: "Google", abiListRaw: "arm64-v8a")
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
        XCTAssertEqual(DevicePropertyKey.marketingName, "ro.product.model")
        XCTAssertEqual(DevicePropertyKey.manufacturer, "ro.product.manufacturer")
        XCTAssertEqual(DevicePropertyKey.supportedABIs, "ro.product.cpu.abilist")
    }

    func testDevicePropertyKeysAllAreCovered() {
        // `all` must stay in sync with the individual keys; DeviceEnricher reads via `all`.
        XCTAssertEqual(DevicePropertyKey.all, [
            DevicePropertyKey.androidVersion,
            DevicePropertyKey.apiLevel,
            DevicePropertyKey.architecture,
            DevicePropertyKey.marketingName,
            DevicePropertyKey.manufacturer,
            DevicePropertyKey.supportedABIs
        ])
        XCTAssertEqual(DevicePropertyKey.all.count, 6)
    }

    func testDevicePropertiesMakeRejectsEmptyMarketingName() {
        XCTAssertThrowsError(
            try DeviceProperties.make(androidVersion: "16", apiLevelRaw: "36", architecture: "arm64-v8a", marketingName: "  ", manufacturer: "Google", abiListRaw: "arm64-v8a")
        ) { error in
            guard case PixelDesktopError.invalidInput = error else {
                return XCTFail("Expected invalidInput, got \(error)")
            }
        }
    }

    func testDevicePropertiesMakeRejectsEmptyManufacturer() {
        XCTAssertThrowsError(
            try DeviceProperties.make(androidVersion: "16", apiLevelRaw: "36", architecture: "arm64-v8a", marketingName: "Pixel 7a", manufacturer: "", abiListRaw: "arm64-v8a")
        ) { error in
            guard case PixelDesktopError.invalidInput = error else {
                return XCTFail("Expected invalidInput, got \(error)")
            }
        }
    }

    func testDevicePropertiesMakeRejectsEmptyABIList() {
        XCTAssertThrowsError(
            try DeviceProperties.make(androidVersion: "16", apiLevelRaw: "36", architecture: "arm64-v8a", marketingName: "Pixel 7a", manufacturer: "Google", abiListRaw: "  ,  , ")
        ) { error in
            guard case PixelDesktopError.invalidInput = error else {
                return XCTFail("Expected invalidInput, got \(error)")
            }
        }
    }

    // MARK: - ABI List Parsing Tests

    func testParseABIListMultiEntry() {
        XCTAssertEqual(
            DeviceProperties.parseABIList("arm64-v8a,armeabi-v7a,armeabi"),
            ["arm64-v8a", "armeabi-v7a", "armeabi"]
        )
    }

    func testParseABIListSingleEntry() {
        // The Pixel 7a reports exactly one ABI. This is the common real-world case.
        XCTAssertEqual(DeviceProperties.parseABIList("arm64-v8a"), ["arm64-v8a"])
    }

    func testParseABIListToleratesWhitespaceAndTrailingComma() {
        XCTAssertEqual(
            DeviceProperties.parseABIList(" arm64-v8a , armeabi-v7a ,"),
            ["arm64-v8a", "armeabi-v7a"]
        )
    }

    func testParseABIListEmptyInput() {
        XCTAssertTrue(DeviceProperties.parseABIList("").isEmpty)
        XCTAssertTrue(DeviceProperties.parseABIList("   ").isEmpty)
        XCTAssertTrue(DeviceProperties.parseABIList(",,").isEmpty)
    }

    // MARK: - Batched getprop Parser Tests

    func testParseSystemPropertiesTypicalOutput() {
        let output = """
        [ro.build.version.release]: [16]
        [ro.build.version.sdk]: [36]
        [ro.product.model]: [Pixel 7a]
        [ro.product.manufacturer]: [Google]
        [ro.product.cpu.abilist]: [arm64-v8a]
        """

        let props = ADBTransport.parseSystemProperties(output)

        XCTAssertEqual(props["ro.build.version.release"], "16")
        XCTAssertEqual(props["ro.product.model"], "Pixel 7a")
        XCTAssertEqual(props["ro.product.manufacturer"], "Google")
        XCTAssertEqual(props["ro.product.cpu.abilist"], "arm64-v8a")
    }

    func testParseSystemPropertiesOmitsUnsetKeys() {
        let output = """
        [ro.set.key]: [value]
        [ro.unset.key]: []
        """

        let props = ADBTransport.parseSystemProperties(output)

        XCTAssertEqual(props["ro.set.key"], "value")
        XCTAssertNil(props["ro.unset.key"], "Unset properties must be absent, not empty")
    }

    func testParseSystemPropertiesHandlesValuesContainingBrackets() {
        // The value is everything after the first "]: [", so brackets inside it survive.
        let output = "[ro.weird]: [value with ] bracket and, comma]"

        let props = ADBTransport.parseSystemProperties(output)

        XCTAssertEqual(props["ro.weird"], "value with ] bracket and, comma")
    }

    func testParseSystemPropertiesHandlesEmptyAndGarbageOutput() {
        XCTAssertTrue(ADBTransport.parseSystemProperties("").isEmpty)
        XCTAssertTrue(ADBTransport.parseSystemProperties("not a property line").isEmpty)
        XCTAssertTrue(ADBTransport.parseSystemProperties("[]: []").isEmpty)
    }

    /// End-to-end enrichment against the exact `getprop` output captured from the
    /// Pixel 7a (serial DEADBEEF000000) while it was attached. This exercises the
    /// parser, DeviceProperties.make and DeviceEnricher on real device data without
    /// needing the device, so it runs in the hermetic suite.
    func testEnrichmentAgainstRealPixel7aOutput() async throws {
        let realOutput = """
        [ro.build.version.release]: [16]
        [ro.build.version.sdk]: [36]
        [ro.product.cpu.abi]: [arm64-v8a]
        [ro.product.model]: [Pixel 7a]
        [ro.product.manufacturer]: [Google]
        [ro.product.cpu.abilist]: [arm64-v8a]
        [ro.product.device]: [lynx]
        [ro.kernel.qemu]: []
        """

        // The real `adb devices -l` line for this device.
        let realDevices = "List of devices attached\nDEADBEEF000000         device usb:1048576X product:lynx model:Pixel_7a device:lynx transport_id:276\n"

        let parsed = ADBTransport().parseDeviceList(realDevices)
        XCTAssertEqual(parsed.count, 1)
        guard let discovered = parsed.first else { return }

        XCTAssertEqual(discovered.serialNumber, "DEADBEEF000000")
        XCTAssertEqual(discovered.deviceCodename, "lynx")
        // Discovery must not claim to know these.
        XCTAssertEqual(discovered.marketingName, "")
        XCTAssertEqual(discovered.manufacturer, "")

        let transport = MockTransport()
        await transport.setProperties(ADBTransport.parseSystemProperties(realOutput))
        await transport.setDeviceList(parsed)

        let enriched = try await DeviceEnricher(transport: transport).enrich(discovered)

        XCTAssertEqual(enriched.marketingName, "Pixel 7a")
        XCTAssertEqual(enriched.manufacturer, "Google")
        XCTAssertEqual(enriched.androidVersion, "16")
        XCTAssertEqual(enriched.apiLevel, 36)
        XCTAssertEqual(enriched.architecture, "arm64-v8a")
        XCTAssertEqual(enriched.supportedABIs, ["arm64-v8a"])
        XCTAssertEqual(enriched.displayName, "Pixel 7a")
        XCTAssertEqual(enriched.deviceCodename, "lynx")

        // The Phase 3 defect, pinned against real data.
        XCTAssertNotEqual(enriched.manufacturer, enriched.deviceCodename)
        XCTAssertNotEqual(enriched.marketingName, enriched.deviceCodename)

        let capabilities = DeviceCapabilities(device: enriched)
        XCTAssertTrue(capabilities.supports(abi: "arm64-v8a"))
        XCTAssertFalse(capabilities.supports(abi: "x86_64"))
    }

    func testParseSystemPropertiesHandlesCRLF() {
        let props = ADBTransport.parseSystemProperties("[ro.a]: [1]\r\n[ro.b]: [2]\r\n")
        XCTAssertEqual(props["ro.a"], "1")
        XCTAssertEqual(props["ro.b"], "2")
    }

    // MARK: - ADBTransport.getprop Tests

    func testGetpropSuccess() async throws {
        let transport = MockTransport()
        await transport.setProperty(DevicePropertyKey.androidVersion, value: "16")

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

    func testGetSystemPropertiesBatchedRead() async throws {
        let transport = MockTransport()
        await transport.setProperties([
            DevicePropertyKey.androidVersion: "16",
            DevicePropertyKey.marketingName: "Pixel 7a"
        ])

        let props = try await transport.getSystemProperties(deviceSerial: "TEST123", timeout: 5)

        XCTAssertEqual(props[DevicePropertyKey.androidVersion], "16")
        XCTAssertEqual(props[DevicePropertyKey.marketingName], "Pixel 7a")

        let invocations = await transport.invocations
        XCTAssertEqual(invocations.count, 1, "A batched read must issue exactly one invocation")
        XCTAssertEqual(invocations[0].command, "-s")
        XCTAssertEqual(invocations[0].arguments, ["TEST123", "shell", "getprop"])
    }

    func testGetSystemPropertiesFailureSurfacesAdbError() async {
        let transport = MockTransport()
        await transport.setBatchedResult(TransportResult(exitCode: 1, stdout: "", stderr: "adb: device offline"))

        do {
            _ = try await transport.getSystemProperties(deviceSerial: "TEST123", timeout: 5)
            XCTFail("Expected adbCommandFailed")
        } catch let error as PixelDesktopError {
            guard case .adbCommandFailed = error else {
                return XCTFail("Expected adbCommandFailed, got \(error)")
            }
        } catch {
            XCTFail("Expected PixelDesktopError, got \(error)")
        }
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
        await transport.setProperties([
            DevicePropertyKey.androidVersion: "16",
            DevicePropertyKey.apiLevel: "36",
            DevicePropertyKey.architecture: "arm64-v8a",
            DevicePropertyKey.marketingName: "Pixel 7a",
            DevicePropertyKey.manufacturer: "Google",
            DevicePropertyKey.supportedABIs: "arm64-v8a"
        ])

        let discovered = AndroidDevice(
            id: "DEADBEEF000000",
            serialNumber: "DEADBEEF000000",
            deviceCodename: "lynx",
            marketingName: "",
            manufacturer: "",
            androidVersion: "",
            apiLevel: 0,
            architecture: "",
            supportedABIs: [],
            state: .device
        )

        let enriched = try await DeviceEnricher(transport: transport).enrich(discovered)

        XCTAssertEqual(enriched.androidVersion, "16")
        XCTAssertEqual(enriched.apiLevel, 36)
        XCTAssertEqual(enriched.architecture, "arm64-v8a")
        XCTAssertEqual(enriched.marketingName, "Pixel 7a")
        XCTAssertEqual(enriched.manufacturer, "Google")
        XCTAssertEqual(enriched.supportedABIs, ["arm64-v8a"])

        // Identity from discovery is preserved untouched.
        XCTAssertEqual(enriched.deviceCodename, "lynx")
        XCTAssertEqual(enriched.serialNumber, "DEADBEEF000000")
        XCTAssertEqual(enriched.state, .device)

        // One batched read, not one process spawn per property.
        let invocations = await transport.invocations
        XCTAssertEqual(invocations.count, 1)
        XCTAssertEqual(invocations[0].arguments, ["DEADBEEF000000", "shell", "getprop"])
    }

    func testEnrichDeviceDoesNotSubstituteCodenameForManufacturer() async throws {
        let transport = MockTransport()
        await transport.setProperties([
            DevicePropertyKey.androidVersion: "16",
            DevicePropertyKey.apiLevel: "36",
            DevicePropertyKey.architecture: "arm64-v8a",
            DevicePropertyKey.marketingName: "Pixel 7a",
            DevicePropertyKey.manufacturer: "Google",
            DevicePropertyKey.supportedABIs: "arm64-v8a"
        ])

        let discovered = AndroidDevice(
            id: "s", serialNumber: "s", deviceCodename: "lynx",
            marketingName: "", manufacturer: "", androidVersion: "",
            apiLevel: 0, architecture: "", supportedABIs: [], state: .device
        )

        let enriched = try await DeviceEnricher(transport: transport).enrich(discovered)

        // Regression for the Phase 3 defect.
        XCTAssertEqual(enriched.manufacturer, "Google")
        XCTAssertNotEqual(enriched.manufacturer, enriched.deviceCodename)
        XCTAssertEqual(enriched.marketingName, "Pixel 7a")
        XCTAssertNotEqual(enriched.marketingName, enriched.deviceCodename)
    }

    func testEnrichDeviceRejectsNonConnectedState() async {
        let transport = MockTransport()
        let offline = AndroidDevice(
            id: "TEST123",
            serialNumber: "TEST123",
            deviceCodename: "lynx",
            marketingName: "",
            manufacturer: "",
            androidVersion: "",
            apiLevel: 0,
            architecture: "",
            supportedABIs: [],
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

    // MARK: - Step 3. Refusal-path decisions (S3-1 .. S3-4)

    /// **S3-4 — implemented.** An `unauthorized` device is now distinguished from an absent one.
    ///
    /// This test previously pinned the defect: the `state == .device` predicate matched nothing
    /// for an unauthorized device, so it surfaced as `.deviceNotFound` even though the device was
    /// attached and the user could fix it by accepting the ADB prompt.
    ///
    /// `AppState.connectedDeviceSerial()` now checks the failure states after the success case.
    /// The pin failed when that landed — which is what it was for.
    func testUnauthorizedDeviceIsDistinguishedFromAnAbsentOne() async {
        let transport = MockTransport()
        await transport.setDeviceList([
            AndroidDevice(
                id: "UNAUTH123",
                serialNumber: "UNAUTH123",
                deviceCodename: "lynx",
                marketingName: "",
                manufacturer: "",
                androidVersion: "",
                apiLevel: 0,
                architecture: "",
                supportedABIs: [],
                state: .unauthorized
            )
        ])

        let devices = try? await transport.listDevices()
        XCTAssertEqual(devices?.first?.state, .unauthorized, "the transport must preserve the state")

        // The connected predicate still rejects it — correctly; it is not usable...
        XCTAssertNil(devices?.first(where: { $0.state == .device }))

        // ...but the failure is now *reported as unauthorized*, not as "not found".
        // Precedence is device -> unauthorized -> offline -> notFound, so a connected device
        // always wins and the actionable failure is preferred over the passive one.
        let unauthorized = devices?.contains(where: { $0.state == .unauthorized }) ?? false
        XCTAssertTrue(unauthorized, "AppState must see the unauthorized device and report it as such")

        // The two errors are distinct and carry different guidance.
        XCTAssertNotEqual(PixelDesktopError.deviceUnauthorized, PixelDesktopError.deviceNotFound)
        XCTAssertTrue(PixelDesktopError.deviceUnauthorized.description.contains("authorization prompt"))
        XCTAssertFalse(PixelDesktopError.deviceNotFound.description.contains("authorization prompt"))
    }

    /// **S3-2 — implemented.** A timeout is now thrown as `.timeout` at the point it is detected,
    /// rather than returned as a `TransportResult` with the `-1` sentinel.
    ///
    /// This test previously pinned the defect: the timeout arrived as `exitCode: -1` and surfaced
    /// as `.adbCommandFailed`, distinguishable from a launch failure only by an English string.
    func testTimeoutIsATypedCaseNotACommandFailure() {
        // The typed case exists, is distinct, and carries the operation and duration.
        let timeout = PixelDesktopError.timeout(operation: "adb devices", duration: 30)
        XCTAssertNotEqual(
            timeout,
            PixelDesktopError.adbCommandFailed(command: "adb devices", exitCode: -1, stderr: "")
        )
        XCTAssertTrue(timeout.description.contains("adb devices"))
        XCTAssertTrue(timeout.description.contains("30.0"))

        // The transport no longer produces the `-1` timeout sentinel: ADBTransport throws
        // PixelDesktopError.timeout from the watchdog task. The remaining `exitCode: -1` site is
        // the launch-failure path, which is genuinely a different condition.

        // Both remain recoverable, so the retry contract is unchanged by the re-typing.
        XCTAssertTrue(timeout.isRecoverable)
        XCTAssertTrue(PixelDesktopError.adbCommandFailed(command: "x", exitCode: -1, stderr: "").isRecoverable)
    }

    /// **S3-3 — reserved, deliberately not implemented.** No case was deleted and no cancellation
    /// was faked.
    ///
    /// Cancellation in this system is `am force-stop`, issued **outside** the streaming session.
    /// `WorkerStreamingTests` §13 asserts the streaming path must never cancel — a worker that
    /// outlives its control channel is recoverable; one that was killed is not. There is therefore
    /// no execution path that produces `.cancelled`, and inventing one to satisfy a completeness
    /// gate would have been the wrong fix.
    ///
    /// The case is preserved as a **reserved contract state**, with the classification that would
    /// apply if a genuine cancellation signal is ever produced.
    func testCancelledIsReservedAndCorrectlyClassified() {
        XCTAssertTrue(PixelDesktopError.cancelled.isRecoverable)
        XCTAssertEqual(PixelDesktopError.cancelled.description, "Operation was cancelled")

        // Reserved, not implemented. The documentation on the case records the evidence:
        //   the cancellation mechanism is external (am force-stop), and the streaming path
        //   is contractually forbidden from issuing it.
    }

    /// Pins the **complete** Swift error vocabulary, so a new case cannot be added without the
    /// Step 3 gate being reconsidered.
    func testSwiftErrorVocabularyIsFullyEnumerated() {
        // All 12 cases, constructed. If one is added, this list must be updated — which is the point.
        let allCases: [PixelDesktopError] = [
            .deviceNotFound,
            .deviceUnauthorized,
            .deviceOffline,
            .adbCommandFailed(command: "x", exitCode: 1, stderr: ""),
            .adbTransportError("x"),
            .invalidInput("x"),
            .timeout(operation: "x", duration: 1),
            .cancelled,
            .verificationFailed(reason: "x"),
            .workerError("x"),
            .workerRefused(category: "INVALID_INPUT", message: "x"),
            .unknown("x"),
        ]
        XCTAssertEqual(allCases.count, 12)
        XCTAssertEqual(Set(allCases.map(\.description)).count, 12, "every case must have a distinct message")

        // The retry contract, complete. Note it is currently read only by tests.
        XCTAssertEqual(allCases.filter(\.isRecoverable).count, 7)
        XCTAssertEqual(allCases.filter { !$0.isRecoverable }.count, 5)
    }

    /// The reachability contract from Step 3: exactly one case is reserved, and it is the one
    /// with no execution path.
    func testOnlyCancelledIsReserved() {
        // Reachable (production code throws each): the rest.
        // Reserved (documented as such, no producer): cancelled.
        let reserved: [PixelDesktopError] = [.cancelled]
        XCTAssertEqual(reserved.count, 1)

        // A `workerRefused` must be distinguishable by category — the S3-1 contract.
        let a = PixelDesktopError.workerRefused(category: "MODEL_MISSING", message: "m")
        let b = PixelDesktopError.workerRefused(category: "INVALID_INPUT", message: "m")
        XCTAssertNotEqual(a, b, "same message, different category, must not compare equal")
        XCTAssertFalse(a.isRecoverable)
        XCTAssertFalse(b.isRecoverable)
    }

    // MARK: - Step 3. S3-4: the unauthorized wire format

    /// The parser must recognise ADB's `unauthorized` state, because S3-4's fix depends on it.
    ///
    /// **Provenance of the input:** this is ADB's documented `adb devices -l` wire format for a
    /// device that has not accepted the host key — the same shape as the real Pixel 7a capture
    /// used by `testEnrichmentAgainstRealPixel7aOutput`, with the state token changed. It is
    /// **not** a live capture from an unauthorized Pixel: inducing that state requires physically
    /// revoking the ADB key on the device, and no device was attached during this closeout
    /// (recorded in `phase-07-step-3-refusal-path.md` §Real-device verification).
    ///
    /// It is still worth pinning: without a correct parse, `DeviceState.unauthorized` is never
    /// populated, and the S3-4 fix would have nothing to report.
    func testParserRecognisesTheUnauthorizedStateFromAdbOutput() {
        let unauthorizedLine =
            "List of devices attached\nDEADBEEF000000         unauthorized usb:1048576X product:lynx model:Pixel_7a device:lynx transport_id:276\n"

        let parsed = ADBTransport().parseDeviceList(unauthorizedLine)

        XCTAssertEqual(parsed.count, 1, "an unauthorized device is still a discovered device")
        guard let device = parsed.first else { return }
        XCTAssertEqual(device.serialNumber, "DEADBEEF000000")
        XCTAssertEqual(device.state, .unauthorized, "the state token must be honoured, not skipped")
        // Discovery must still not claim marketing name or manufacturer — those come from getprop.
        XCTAssertEqual(device.marketingName, "")
        XCTAssertEqual(device.manufacturer, "")
    }

    /// A mixed list — one connected, one unauthorized — must yield both, with correct states.
    ///
    /// This is the realistic shape: the user has an authorized device and a second one awaiting a
    /// prompt. The selection helper must pick the connected one and not be confused by the other.
    func testParserHandlesConnectedAndUnauthorizedTogether() {
        let mixed = "List of devices attached\n"
            + "DEADBEEF000000         device usb:1 product:lynx model:Pixel_7a device:lynx transport_id:1\n"
            + "9ZZ999ZZZZ99         unauthorized usb:2 product:lynx model:Pixel_7a device:lynx transport_id:2\n"

        let parsed = ADBTransport().parseDeviceList(mixed)

        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed.filter { $0.state == .device }.count, 1)
        XCTAssertEqual(parsed.filter { $0.state == .unauthorized }.count, 1)

        // The connected device still wins — S3-4's precedence rule, at the data level.
        let selected = parsed.first(where: { $0.state == .device })
        XCTAssertEqual(selected?.serialNumber, "DEADBEEF000000")
    }

    // MARK: - Step 3 end

    func testEnrichDevicePropagatesPropertyFailure() async {
        let transport = MockTransport()
        // apiLevel present but unset -> absent from the map -> make() rejects it.
        await transport.setProperties([
            DevicePropertyKey.androidVersion: "16",
            DevicePropertyKey.architecture: "arm64-v8a",
            DevicePropertyKey.marketingName: "Pixel 7a",
            DevicePropertyKey.manufacturer: "Google",
            DevicePropertyKey.supportedABIs: "arm64-v8a"
        ])

        let device = AndroidDevice(
            id: "TEST123",
            serialNumber: "TEST123",
            deviceCodename: "lynx",
            marketingName: "",
            manufacturer: "",
            androidVersion: "",
            apiLevel: 0,
            architecture: "",
            supportedABIs: [],
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
        await transport.setProperties([
            DevicePropertyKey.androidVersion: "16",
            DevicePropertyKey.apiLevel: "36",
            DevicePropertyKey.architecture: "arm64-v8a",
            DevicePropertyKey.marketingName: "Pixel 7a",
            DevicePropertyKey.manufacturer: "Google",
            DevicePropertyKey.supportedABIs: "arm64-v8a"
        ])
        await transport.setDeviceList([
            AndroidDevice(
                id: "DEADBEEF000000",
                serialNumber: "DEADBEEF000000",
                deviceCodename: "lynx",
                marketingName: "",
                manufacturer: "",
                androidVersion: "",
                apiLevel: 0,
                architecture: "",
                supportedABIs: [],
                state: .device
            )
        ])

        let manager = await DeviceManager(transport: transport)
        await manager.refreshDevices()

        let discovered = await manager.devices
        XCTAssertEqual(discovered.count, 1)
        XCTAssertEqual(discovered[0].androidVersion, "")

        let enriched = try await manager.enrichDevice(serial: "DEADBEEF000000")

        XCTAssertEqual(enriched?.androidVersion, "16")
        XCTAssertEqual(enriched?.apiLevel, 36)
        XCTAssertEqual(enriched?.marketingName, "Pixel 7a")
        XCTAssertEqual(enriched?.manufacturer, "Google")

        let published = await manager.devices
        XCTAssertEqual(published[0].androidVersion, "16")
        XCTAssertEqual(published[0].apiLevel, 36)
        XCTAssertEqual(published[0].architecture, "arm64-v8a")
        XCTAssertEqual(published[0].supportedABIs, ["arm64-v8a"])
        XCTAssertEqual(published[0].displayName, "Pixel 7a")
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
            AndroidDevice(
                id: "TEST123",
                serialNumber: "TEST123",
                deviceCodename: "lynx",
                marketingName: "",
                manufacturer: "",
                androidVersion: "",
                apiLevel: 0,
                architecture: "",
                supportedABIs: [],
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
        XCTAssertEqual(devices[0].supportedABIs, [])
        XCTAssertEqual(devices[0].marketingName, "")
        XCTAssertEqual(devices[0].manufacturer, "")

        let invocations = await transport.invocations
        XCTAssertTrue(
            invocations.isEmpty,
            "Discovery parsing must not issue getprop calls; enrichment is a separate responsibility"
        )
    }
}

// MARK: - Phase 4: Application Operation Tests

final class AppOperationsTests: XCTestCase {

    // MARK: Package name validation (the injection boundary)

    func testValidatePackageNameAcceptsValidIdentifiers() throws {
        for name in ["com.android.settings", "com.mojang.minecraftpe", "a.b", "com.a_b.c1"] {
            XCTAssertEqual(try ADBAppOperations.validatePackageName(name), name)
        }
    }

    func testValidatePackageNameRejectsEmpty() {
        XCTAssertThrowsError(try ADBAppOperations.validatePackageName("   "))
    }

    /// The mechanism that prevents command injection through the operations layer.
    func testValidatePackageNameRejectsShellMetacharacters() {
        let hostile = [
            "com.example; rm -rf /",
            "com.example && reboot",
            "com.example | sh",
            "com.example`id`",
            "com.example$(whoami)",
            "com.example > /sdcard/x",
            "com.example\nreboot",
            "com.example --user 0",
            "'com.example'",
            "com.example/../other"
        ]
        for name in hostile {
            XCTAssertThrowsError(
                try ADBAppOperations.validatePackageName(name),
                "Expected rejection of '\(name)'"
            ) { error in
                guard case PixelDesktopError.invalidInput = error else {
                    return XCTFail("Expected invalidInput for '\(name)', got \(error)")
                }
            }
        }
    }

    // MARK: Stop containment

    func testStopRejectsProtectedPackages() {
        for name in ["com.android.systemui", "com.google.android.gms", "android", "com.android.phone"] {
            XCTAssertThrowsError(try ADBAppOperations.assertStoppable(name), "Expected refusal for \(name)")
        }
    }

    /// Settings is an ordinary user application, not a device-critical one. It was initially
    /// protected by reflex on package name alone; real-device verification surfaced that the
    /// entry was over-broad, because the approved verification sequence stops Settings.
    /// This test pins the criterion so the entry cannot silently return.
    func testSettingsIsNotProtectedBecauseItIsNotDeviceCritical() throws {
        XCTAssertNoThrow(try ADBAppOperations.assertStoppable("com.android.settings"))
    }

    func testStopRejectsProtectedPrefixes() {
        XCTAssertThrowsError(try ADBAppOperations.assertStoppable("com.android.providers.contacts"))
        XCTAssertThrowsError(try ADBAppOperations.assertStoppable("com.android.server.telecom"))
    }

    func testStopRejectsWorkerPackage() {
        XCTAssertThrowsError(try ADBAppOperations.assertStoppable(ADBAppOperations.workerPackageName))
    }

    func testStopAllowsOrdinaryThirdPartyPackage() throws {
        XCTAssertNoThrow(try ADBAppOperations.assertStoppable("com.mojang.minecraftpe"))
    }

    /// The containment is a denylist, not a boundary. Documented as such in ADR-009.
    func testContainmentIsDenylistNotBoundary() throws {
        // A third-party package can impersonate a system-looking name and is NOT protected.
        XCTAssertNoThrow(try ADBAppOperations.assertStoppable("com.android.impostor"))
    }

    // MARK: Parsers

    func testParsePackageList() {
        let output = """
        package:com.klim.dbdesigner
        package:com.fiio.control
        package:com.smart.consumer.app
        """
        XCTAssertEqual(
            ADBAppOperations.parsePackageList(output),
            ["com.klim.dbdesigner", "com.fiio.control", "com.smart.consumer.app"]
        )
    }

    func testParsePackageListIgnoresMalformedLines() {
        let output = "package:\nnot a package line\npackage:com.valid.app\npackage:   \n"
        XCTAssertEqual(ADBAppOperations.parsePackageList(output), ["com.valid.app"])
    }

    func testParseLaunchableActivitiesFromRealShape() {
        // Shape captured from the real Pixel 7a.
        let output = """
        58 activities found:
          Activity #0:
            priority=0 preferredOrder=0 match=0x108000 specificIndex=-1 isDefault=true
            com.android.chrome/com.google.android.apps.chrome.Main
          Activity #1:
            priority=0 preferredOrder=0 match=0x108000 specificIndex=-1 isDefault=true
            com.android.settings/.Settings
        """
        let parsed = ADBAppOperations.parseLaunchableActivities(output)

        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed["com.android.chrome"], "com.android.chrome/com.google.android.apps.chrome.Main")
        XCTAssertEqual(parsed["com.android.settings"], "com.android.settings/.Settings")
        XCTAssertNil(parsed["58 activities found"])
    }

    func testParseLaunchableActivitiesEmptyOutput() {
        XCTAssertTrue(ADBAppOperations.parseLaunchableActivities("").isEmpty)
        XCTAssertTrue(ADBAppOperations.parseLaunchableActivities("No activities found").isEmpty)
    }

    func testParsePID() {
        XCTAssertEqual(ADBAppOperations.parsePID("2615"), 2615)
        XCTAssertEqual(ADBAppOperations.parsePID("2615 2616"), 2615)
        XCTAssertEqual(ADBAppOperations.parsePID("  42  \n"), 42)
    }

    func testParsePIDReturnsNilWhenNotRunning() {
        // pidof prints nothing and exits 1 when no process matches.
        XCTAssertNil(ADBAppOperations.parsePID(""))
        XCTAssertNil(ADBAppOperations.parsePID("   \n"))
        XCTAssertNil(ADBAppOperations.parsePID("not a pid"))
    }

    func testComponentActivityExtraction() {
        XCTAssertEqual(
            ADBAppOperations.componentActivity(from: "com.android.settings/.Settings", packageName: "com.android.settings"),
            ".Settings"
        )
        XCTAssertEqual(
            ADBAppOperations.componentActivity(from: "com.android.chrome/com.google.android.apps.chrome.Main", packageName: "com.android.chrome"),
            "com.google.android.apps.chrome.Main"
        )
    }

    // MARK: Operations over a mock transport

    func testInstalledApplicationsThirdPartyByDefault() async throws {
        let transport = MockTransport()
        await transport.setShellResponse("pm list packages -3",
            TransportResult(exitCode: 0, stdout: "package:com.a.one\npackage:com.b.two\n", stderr: ""))

        let ops = ADBAppOperations(transport: transport)
        let apps = try await ops.installedApplications(deviceSerial: "S", includeSystem: false, timeout: 5)

        XCTAssertEqual(apps.map(\.packageName), ["com.a.one", "com.b.two"])
        XCTAssertTrue(apps.allSatisfy { !$0.isLaunchable })

        let invocations = await transport.invocations
        XCTAssertEqual(invocations.count, 1)
        XCTAssertEqual(invocations[0].arguments, ["S", "shell", "pm list packages -3"])
    }

    func testInstalledApplicationsIncludeSystemUsesDifferentCommand() async throws {
        let transport = MockTransport()
        await transport.setShellResponse("pm list packages",
            TransportResult(exitCode: 0, stdout: "package:com.a.one\n", stderr: ""))

        let ops = ADBAppOperations(transport: transport)
        _ = try await ops.installedApplications(deviceSerial: "S", includeSystem: true, timeout: 5)

        let invocations = await transport.invocations
        XCTAssertEqual(invocations[0].arguments, ["S", "shell", "pm list packages"])
    }

    func testLaunchableApplicationsResolvedInOneCall() async throws {
        let transport = MockTransport()
        await transport.setDefaultShellResult(TransportResult(exitCode: 0, stdout: """
        2 activities found:
            com.android.settings/.Settings
            com.android.chrome/com.google.android.apps.chrome.Main
        """, stderr: ""))

        let ops = ADBAppOperations(transport: transport)
        let apps = try await ops.launchableApplications(deviceSerial: "S", timeout: 5)

        XCTAssertEqual(apps.count, 2)
        XCTAssertTrue(apps.allSatisfy { $0.isLaunchable })

        // One device call, not one per package.
        let invocations = await transport.invocations
        XCTAssertEqual(invocations.count, 1)
    }

    func testLaunchApplicationBuildsExactCommand() async throws {
        let transport = MockTransport()
        await transport.setDefaultShellResult(TransportResult(exitCode: 0, stdout: """
        1 activities found:
            com.android.settings/.Settings
        """, stderr: ""))

        let ops = ADBAppOperations(transport: transport)
        _ = try await ops.launchApplication(deviceSerial: "S", packageName: "com.android.settings", timeout: 5)

        let invocations = await transport.invocations
        XCTAssertEqual(invocations.last?.arguments, ["S", "shell", "am start -n com.android.settings/.Settings"])
    }

    func testLaunchApplicationRejectsNonLaunchableBeforeCommand() async {
        let transport = MockTransport()
        // Package exists but exposes no launcher activity.
        await transport.setDefaultShellResult(TransportResult(exitCode: 0, stdout: "No activities found", stderr: ""))

        let ops = ADBAppOperations(transport: transport)
        do {
            _ = try await ops.launchApplication(deviceSerial: "S", packageName: "com.library.only", timeout: 5)
            XCTFail("Expected invalidInput")
        } catch let error as PixelDesktopError {
            guard case .invalidInput = error else { return XCTFail("got \(error)") }
        } catch { XCTFail("got \(error)") }

        // No `am start` was issued.
        let invocations = await transport.invocations
        XCTAssertFalse(invocations.contains { $0.arguments.last?.contains("am start") == true })
    }

    func testIsApplicationRunningTrue() async throws {
        let transport = MockTransport()
        await transport.setShellResponse("pidof com.android.settings", TransportResult(exitCode: 0, stdout: "2615\n", stderr: ""))

        let ops = ADBAppOperations(transport: transport)
        let running = try await ops.isApplicationRunning(deviceSerial: "S", packageName: "com.android.settings", timeout: 5)

        XCTAssertTrue(running)
    }

    /// `pidof` exits 1 when not running. That is a valid answer, not an error.
    func testIsApplicationRunningFalseIsNotAnError() async throws {
        let transport = MockTransport()
        await transport.setShellResponse("pidof com.mojang.minecraftpe", TransportResult(exitCode: 1, stdout: "", stderr: ""))

        let ops = ADBAppOperations(transport: transport)
        let running = try await ops.isApplicationRunning(deviceSerial: "S", packageName: "com.mojang.minecraftpe", timeout: 5)

        XCTAssertFalse(running)
    }

    func testStopApplicationBuildsExactCommand() async throws {
        let transport = MockTransport()
        await transport.setDefaultShellResult(TransportResult(exitCode: 0, stdout: "", stderr: ""))

        let ops = ADBAppOperations(transport: transport)
        _ = try await ops.stopApplication(deviceSerial: "S", packageName: "com.mojang.minecraftpe", timeout: 5)

        let invocations = await transport.invocations
        XCTAssertEqual(invocations.last?.arguments, ["S", "shell", "am force-stop com.mojang.minecraftpe"])
    }

    func testStopApplicationRefusesProtectedPackageBeforeCommand() async {
        let transport = MockTransport()
        let ops = ADBAppOperations(transport: transport)

        do {
            _ = try await ops.stopApplication(deviceSerial: "S", packageName: "com.android.systemui", timeout: 5)
            XCTFail("Expected refusal")
        } catch let error as PixelDesktopError {
            guard case .invalidInput = error else { return XCTFail("got \(error)") }
        } catch { XCTFail("got \(error)") }

        let invocations = await transport.invocations
        XCTAssertTrue(invocations.isEmpty, "A refused stop must not touch the device")
    }

    func testShellNonZeroExitSurfacesAdbError() async {
        let transport = MockTransport()
        await transport.setDefaultShellResult(TransportResult(exitCode: 255, stdout: "", stderr: "java.lang.IllegalArgumentException"))

        let ops = ADBAppOperations(transport: transport)
        do {
            _ = try await ops.installedApplications(deviceSerial: "S", includeSystem: false, timeout: 5)
            XCTFail("Expected adbCommandFailed")
        } catch let error as PixelDesktopError {
            guard case .adbCommandFailed(_, let code, _) = error else { return XCTFail("got \(error)") }
            XCTAssertEqual(code, 255)
        } catch { XCTFail("got \(error)") }
    }

    // MARK: InstalledApp model

    func testInstalledAppIsLaunchable() {
        XCTAssertTrue(InstalledApp(packageName: "com.a.b", launchActivity: "com.a.b/.Main").isLaunchable)
        XCTAssertFalse(InstalledApp(packageName: "com.a.b", launchActivity: nil).isLaunchable)
    }

    func testInstalledAppDisplayLabelIsLastSegment() {
        XCTAssertEqual(InstalledApp(packageName: "com.android.settings", launchActivity: nil).displayLabel, "settings")
        XCTAssertEqual(InstalledApp(packageName: "single", launchActivity: nil).displayLabel, "single")
    }

    func testInstalledAppSystemHeuristicIsNotAuthoritative() {
        XCTAssertTrue(InstalledApp(packageName: "com.android.settings", launchActivity: nil).isLikelySystemPackage)
        XCTAssertFalse(InstalledApp(packageName: "com.mojang.minecraftpe", launchActivity: nil).isLikelySystemPackage)
    }
}

// MARK: - Phase 4: Lifecycle Tests

final class DeviceLifecycleTests: XCTestCase {

    func testRequireConnectedDeviceReturnsConnectedDevice() async throws {
        let transport = MockTransport()
        await transport.setDeviceList([
            AndroidDevice(id: "S", serialNumber: "S", deviceCodename: "lynx", marketingName: "",
                          manufacturer: "", androidVersion: "", apiLevel: 0, architecture: "",
                          supportedABIs: [], state: .device)
        ])
        let manager = await DeviceManager(transport: transport)
        await manager.refreshDevices()

        let device = try await manager.requireConnectedDevice(serial: "S")
        XCTAssertEqual(device.serialNumber, "S")
    }

    func testRequireConnectedDeviceThrowsForUnknownSerial() async {
        let transport = MockTransport()
        let manager = await DeviceManager(transport: transport)
        await manager.refreshDevices()

        do {
            _ = try await manager.requireConnectedDevice(serial: "NOPE")
            XCTFail("Expected deviceNotFound")
        } catch let error as PixelDesktopError {
            XCTAssertEqual(error, PixelDesktopError.deviceNotFound)
        } catch { XCTFail("got \(error)") }
    }

    func testRequireConnectedDeviceThrowsForOfflineDevice() async {
        let transport = MockTransport()
        await transport.setDeviceList([
            AndroidDevice(id: "S", serialNumber: "S", deviceCodename: "lynx", marketingName: "",
                          manufacturer: "", androidVersion: "", apiLevel: 0, architecture: "",
                          supportedABIs: [], state: .offline)
        ])
        let manager = await DeviceManager(transport: transport)
        await manager.refreshDevices()

        do {
            _ = try await manager.requireConnectedDevice(serial: "S")
            XCTFail("Expected deviceOffline")
        } catch let error as PixelDesktopError {
            XCTAssertEqual(error, PixelDesktopError.deviceOffline)
        } catch { XCTFail("got \(error)") }
    }

    /// ADR-009: enriched properties must not survive a disconnect/reconnect.
    func testDisconnectInvalidatesEnrichedProperties() async throws {
        let transport = MockTransport()
        await transport.setProperties([
            DevicePropertyKey.androidVersion: "16",
            DevicePropertyKey.apiLevel: "36",
            DevicePropertyKey.architecture: "arm64-v8a",
            DevicePropertyKey.marketingName: "Pixel 7a",
            DevicePropertyKey.manufacturer: "Google",
            DevicePropertyKey.supportedABIs: "arm64-v8a"
        ])
        let device = AndroidDevice(id: "S", serialNumber: "S", deviceCodename: "lynx",
                                   marketingName: "", manufacturer: "", androidVersion: "",
                                   apiLevel: 0, architecture: "", supportedABIs: [], state: .device)
        await transport.setDeviceList([device])

        let manager = await DeviceManager(transport: transport)
        await manager.refreshDevices()
        _ = try await manager.enrichDevice(serial: "S")

        var published = await manager.devices
        XCTAssertEqual(published[0].androidVersion, "16", "precondition: enriched")

        // Device disconnects.
        await transport.setDeviceList([])
        await manager.refreshDevices()
        published = await manager.devices
        XCTAssertTrue(published.isEmpty)

        // Device reconnects: properties must be empty again, not the stale cached values.
        await transport.setDeviceList([device])
        await manager.refreshDevices()
        published = await manager.devices
        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(published[0].androidVersion, "", "reconnect must not resurrect stale properties")
        XCTAssertEqual(published[0].apiLevel, 0)
        XCTAssertEqual(published[0].marketingName, "")
        XCTAssertTrue(published[0].supportedABIs.isEmpty)
    }
}

// MARK: - Phase 5: Worker Transfer Contract Tests

final class WorkerTransferContractTests: XCTestCase {

    // MARK: The contract has no path parameter

    func testContractPathsAreFixedConstants() {
        XCTAssertEqual(WorkerTransferContract.remoteRoot, "/sdcard/Android/data/com.pixeldesktop.worker/files")
        XCTAssertEqual(WorkerTransferContract.remoteInputPath, "/sdcard/Android/data/com.pixeldesktop.worker/files/job.json")
        XCTAssertEqual(WorkerTransferContract.remoteResultPath, "/sdcard/Android/data/com.pixeldesktop.worker/files/result.json")
        // Both payload files live under the single root; neither escapes it.
        XCTAssertTrue(WorkerTransferContract.remoteInputPath.hasPrefix(WorkerTransferContract.remoteRoot + "/"))
        XCTAssertTrue(WorkerTransferContract.remoteResultPath.hasPrefix(WorkerTransferContract.remoteRoot + "/"))
    }

    func testLocalStagingIsInsideTheContainerAndNotUserVisible() {
        let staging = WorkerTransferContract.stagingDirectory
        XCTAssertTrue(staging.path.contains("Application Support"),
                      "staging must live in the container, got \(staging.path)")
        XCTAssertTrue(staging.path.hasSuffix("PixelDesktop/Staging"))
        // Fixed filenames under staging.
        XCTAssertEqual(WorkerTransferContract.localInputPath.lastPathComponent, "job.json")
        XCTAssertEqual(WorkerTransferContract.localResultPath.lastPathComponent, "result.json")
    }

    // MARK: Regular-file requirement (D7)

    func testValidateRegularFileAcceptsRegularFile() throws {
        let url = try makeTempFile(contents: "hello")
        defer { try? FileManager.default.removeItem(at: url) }

        let validated = try WorkerTransferContract.validateRegularFile(at: url)
        XCTAssertEqual(validated.byteCount, 5)
    }

    func testValidateRegularFileRejectsMissingFile() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pd_definitely_missing_\(UUID()).txt")
        XCTAssertThrowsError(try WorkerTransferContract.validateRegularFile(at: url)) { error in
            guard case PixelDesktopError.invalidInput = error else { return XCTFail("got \(error)") }
        }
    }

    /// The escape found in reconnaissance: a symlink in staging pointed outside it, and adb
    /// pushed the *target's* contents.
    func testValidateRegularFileRejectsSymlink() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("target.txt")
        try "secret".write(to: target, atomically: true, encoding: .utf8)
        let link = dir.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(try WorkerTransferContract.validateRegularFile(at: link)) { error in
            guard case PixelDesktopError.invalidInput(let message) = error else {
                return XCTFail("got \(error)")
            }
            XCTAssertTrue(message.contains("symbolic link"), "got: \(message)")
        }
    }

    /// A symlink pointing at a *regular file* must also be refused — the check must not
    /// follow the link and then accept it.
    func testValidateRegularFileRejectsSymlinkToRegularFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("real.txt")
        try "data".write(to: real, atomically: true, encoding: .utf8)
        let link = dir.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        XCTAssertThrowsError(try WorkerTransferContract.validateRegularFile(at: link))
    }

    /// adb recurses on a directory operand, so a directory must never be accepted.
    func testValidateRegularFileRejectsDirectory() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertThrowsError(try WorkerTransferContract.validateRegularFile(at: dir)) { error in
            guard case PixelDesktopError.invalidInput(let message) = error else {
                return XCTFail("got \(error)")
            }
            XCTAssertTrue(message.contains("directory"), "got: \(message)")
        }
    }

    func testValidateRegularFileRejectsOversizedFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let big = dir.appendingPathComponent("big.txt")
        let data = Data(repeating: 0x41, count: WorkerTransferContract.maximumPayloadBytes + 1)
        try data.write(to: big)

        XCTAssertThrowsError(try WorkerTransferContract.validateRegularFile(at: big)) { error in
            guard case PixelDesktopError.invalidInput = error else { return XCTFail("got \(error)") }
        }
    }

    // MARK: Size verification (D3)

    func testVerifySizeMatch() {
        let v = WorkerTransferContract.verifySize(expected: 11, actual: 11)
        XCTAssertTrue(v.isVerified)
        XCTAssertEqual(v, .match(expected: 11, actual: 11))
    }

    func testVerifySizeMismatch() {
        let v = WorkerTransferContract.verifySize(expected: 11, actual: 5)
        XCTAssertFalse(v.isVerified)
        XCTAssertEqual(v, .mismatch(expected: 11, actual: 5))
    }

    func testParseRemoteSize() {
        XCTAssertEqual(WorkerTransferContract.parseRemoteSize("11"), 11)
        XCTAssertEqual(WorkerTransferContract.parseRemoteSize("  11\n"), 11)
        XCTAssertEqual(WorkerTransferContract.parseRemoteSize("0"), 0)
    }

    func testParseRemoteSizeReturnsNilForMissingOrGarbage() {
        XCTAssertNil(WorkerTransferContract.parseRemoteSize(""))
        XCTAssertNil(WorkerTransferContract.parseRemoteSize("   "))
        XCTAssertNil(WorkerTransferContract.parseRemoteSize("stat: No such file or directory"))
    }

    // MARK: Helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pd_test_\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeTempFile(contents: String) throws -> URL {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("payload.txt")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

// MARK: - Phase 5: Worker Operations Tests

final class WorkerOperationsTests: XCTestCase {

    private func stagingCleanup() {
        let dir = WorkerTransferContract.stagingDirectory
        try? FileManager.default.removeItem(at: dir)
    }

    override func tearDown() {
        stagingCleanup()
        super.tearDown()
    }

    // MARK: Workspace

    func testPrepareRemoteWorkspaceChecksExistenceWithoutCreating() async throws {
        let transport = MockTransport()
        await transport.setDefaultShellResult(
            TransportResult(exitCode: 0, stdout: "EXISTS\n", stderr: ""))
        let ops = ADBWorkerOperations(transport: transport)

        try await ops.prepareRemoteWorkspace(deviceSerial: "S", timeout: 5)

        let invocations = await transport.invocations
        XCTAssertEqual(invocations.count, 1)
        XCTAssertEqual(invocations[0].arguments,
                       ["S", "shell", WorkerTransferContract.remoteWorkspaceExistsCommand])

        // adb must NOT create the directory: an adb-created directory is owned by
        // shell:ext_data_rw and the worker cannot write it. Measured on the real device.
        let command = invocations[0].arguments.last ?? ""
        XCTAssertFalse(command.contains("mkdir"),
                       "adb must not create the exchange directory, got: \(command)")
    }

    /// The worker must be the directory's creator. Absence is a reported condition, not a
    /// silent no-op.
    func testPrepareRemoteWorkspaceReportsMissingDirectory() async {
        let transport = MockTransport()
        await transport.setDefaultShellResult(TransportResult(exitCode: 1, stdout: "", stderr: ""))
        let ops = ADBWorkerOperations(transport: transport)

        do {
            try await ops.prepareRemoteWorkspace(deviceSerial: "S", timeout: 5)
            XCTFail("Expected workerError when the exchange directory is absent")
        } catch let error as PixelDesktopError {
            guard case .workerError = error else { return XCTFail("got \(error)") }
        } catch { XCTFail("got \(error)") }
    }

    /// Regression, re-expressed for ADR-010 Revision 1.
    ///
    /// **FAIL-003** was: `mkdir -p` on `/data/local/tmp/pixeldesktop` produced mode **777**
    /// (world-readable), contradicting the stated reason for choosing that root. The fix then
    /// was an explicit `chmod 700`.
    ///
    /// The transfer root has since moved to the worker application's **own external files
    /// directory**, which the platform already creates owner-scoped (`drwxrws---`). The
    /// *property* FAIL-003 demanded — "the exchange directory must not be world-readable" — is
    /// therefore now enforced by the platform rather than by our chmod, and applying `chmod`
    /// here could break the worker's own access to its directory.
    ///
    /// So this test asserts the **property** rather than the mechanism it used to require:
    ///
    /// 1. the root is inside the worker's app-private external directory, where the platform
    ///    enforces owner-scoping; and
    /// 2. no `chmod` is issued that could interfere with the worker's ownership.
    ///
    /// The property itself is verified on the **real device** during the compute proof, where the
    /// actual mode is read back — see the phase log. A unit test cannot observe a mode.
    func testRemoteWorkspaceIsInsideAppPrivateExternalStorage() async throws {
        let transport = MockTransport()
        await transport.setDefaultShellResult(
            TransportResult(exitCode: 0, stdout: "EXISTS\n", stderr: ""))
        let ops = ADBWorkerOperations(transport: transport)

        try await ops.prepareRemoteWorkspace(deviceSerial: "S", timeout: 5)

        // 1. The root must be the app's own external files dir — that is what makes the platform
        //    enforce owner-only access.
        XCTAssertTrue(
            WorkerTransferContract.remoteRoot.hasPrefix(
                "/sdcard/Android/data/\(WorkerTransferContract.workerPackageName)/files"),
            "root must be app-private external storage, got \(WorkerTransferContract.remoteRoot)")

        // 2. Must NOT be /data/local/tmp: an Android app cannot write there (ADR-010 Rev 1).
        XCTAssertFalse(WorkerTransferContract.remoteRoot.hasPrefix("/data/local/tmp"))

        let invocations = await transport.invocations
        let command = invocations.first?.arguments.last ?? ""
        XCTAssertFalse(command.contains("mkdir"), "adb must NOT create the exchange directory - it would own it and break the worker's access")
        XCTAssertFalse(command.contains("chmod"),
                       "chmod must not be applied to the worker's own directory, got: \(command)")
    }

    /// The workspace check must also survive a device-side error without pretending success.
    func testPrepareRemoteWorkspaceSurfacesDeviceError() async {
        let transport = MockTransport()
        await transport.setDefaultShellResult(
            TransportResult(exitCode: 0, stdout: "", stderr: "ls: permission denied"))
        let ops = ADBWorkerOperations(transport: transport)

        do {
            try await ops.prepareRemoteWorkspace(deviceSerial: "S", timeout: 5)
            XCTFail("Expected workerError")
        } catch let error as PixelDesktopError {
            guard case .workerError = error else { return XCTFail("got \(error)") }
        } catch { XCTFail("got \(error)") }
    }

    // MARK: Submit input

    func testSubmitInputPushesToFixedRemotePath() async throws {
        let transport = MockTransport()
        await transport.setDefaultShellResult(TransportResult(exitCode: 0, stdout: "", stderr: ""))
        // stat reports the same size we sent.
        await transport.setShellResponse("stat -c %s \(WorkerTransferContract.remoteInputPath)",
            TransportResult(exitCode: 0, stdout: "5\n", stderr: ""))

        let ops = ADBWorkerOperations(transport: transport)
        let verification = try await ops.submitInput(deviceSerial: "S", text: "hello", timeout: 5)

        XCTAssertTrue(verification.isVerified)

        let invocations = await transport.invocations
        let push = invocations.first { $0.arguments.contains("push") }
        XCTAssertNotNil(push)
        XCTAssertEqual(push?.arguments[0], "S")
        XCTAssertEqual(push?.arguments[1], "push")
        XCTAssertEqual(push?.arguments[2], WorkerTransferContract.localInputPath.path)
        XCTAssertEqual(push?.arguments[3], WorkerTransferContract.remoteInputPath)
    }

    /// The DTCA-1 limits are enforced before anything reaches the device.
    func testSubmitInputRejectsOversizedTextBeforeTouchingDevice() async {
        let transport = MockTransport()
        let ops = ADBWorkerOperations(transport: transport)

        do {
            _ = try await ops.submitInput(deviceSerial: "S", text: String(repeating: "a", count: 10_001), timeout: 5)
            XCTFail("Expected invalidInput")
        } catch let error as PixelDesktopError {
            guard case .invalidInput = error else { return XCTFail("got \(error)") }
        } catch { XCTFail("got \(error)") }

        let invocations = await transport.invocations
        XCTAssertTrue(invocations.isEmpty, "Oversized input must not reach the device")
    }

    func testSubmitInputRejectsNullBytesBeforeTouchingDevice() async {
        let transport = MockTransport()
        let ops = ADBWorkerOperations(transport: transport)

        do {
            _ = try await ops.submitInput(deviceSerial: "S", text: "bad\0input", timeout: 5)
            XCTFail("Expected invalidInput")
        } catch let error as PixelDesktopError {
            guard case .invalidInput = error else { return XCTFail("got \(error)") }
        } catch { XCTFail("got \(error)") }

        let invocations = await transport.invocations
        XCTAssertTrue(invocations.isEmpty)
    }

    func testSubmitInputSurfacesTransportFailure() async {
        let transport = MockTransport()
        await transport.setPushResult(TransportResult(exitCode: 1, stdout: "", stderr: "adb: error: failed to copy"))
        let ops = ADBWorkerOperations(transport: transport)

        do {
            _ = try await ops.submitInput(deviceSerial: "S", text: "hello", timeout: 5)
            XCTFail("Expected adbCommandFailed")
        } catch let error as PixelDesktopError {
            guard case .adbCommandFailed = error else { return XCTFail("got \(error)") }
        } catch { XCTFail("got \(error)") }
    }

    /// D3: a size mismatch means a partial transfer and must be reported as a mismatch.
    func testSubmitInputDetectsSizeMismatch() async throws {
        let transport = MockTransport()
        await transport.setDefaultShellResult(TransportResult(exitCode: 0, stdout: "", stderr: ""))
        // Device reports fewer bytes than we sent.
        await transport.setShellResponse("stat -c %s \(WorkerTransferContract.remoteInputPath)",
            TransportResult(exitCode: 0, stdout: "2\n", stderr: ""))

        let ops = ADBWorkerOperations(transport: transport)
        let verification = try await ops.submitInput(deviceSerial: "S", text: "hello", timeout: 5)

        XCTAssertFalse(verification.isVerified, "a partial transfer must not verify")
        XCTAssertEqual(verification, .mismatch(expected: 5, actual: 2))
    }

    // MARK: Retrieve result

    func testRetrieveResultPullsAndDecodes() async throws {
        let transport = MockTransport()
        let json = #"{"status":"COMPLETED","input_characters":5,"total_words":1,"unique_words":1,"top_words":[{"word":"hello","count":1}],"classification":"NATURAL_LANGUAGE","confidence":0.5,"execution_timestamp_ms":1,"execution_duration_ms":2}"#
        await transport.setShellResponse("stat -c %s \(WorkerTransferContract.remoteResultPath)",
            TransportResult(exitCode: 0, stdout: "\(json.utf8.count)\n", stderr: ""))
        await transport.setPullContent(json)

        let ops = ADBWorkerOperations(transport: transport)
        let retrieved = try await ops.retrieveResult(deviceSerial: "S", timeout: 5)

        XCTAssertEqual(retrieved.result.status, "COMPLETED")
        XCTAssertEqual(retrieved.result.inputCharacters, 5)
        XCTAssertTrue(retrieved.sizeVerification.isVerified)

        let invocations = await transport.invocations
        let pull = invocations.first { $0.arguments.contains("pull") }
        XCTAssertEqual(pull?.arguments[2], WorkerTransferContract.remoteResultPath)
        XCTAssertEqual(pull?.arguments[3], WorkerTransferContract.localResultPath.path)
    }

    /// The worker produced nothing: `adb pull` exits non-zero. That is a worker failure.
    func testRetrieveResultMissingPayloadIsWorkerError() async {
        let transport = MockTransport()
        await transport.setDefaultShellResult(
            TransportResult(exitCode: 1, stdout: "", stderr: "adb: error: failed to stat remote object"))
        let ops = ADBWorkerOperations(transport: transport)

        do {
            _ = try await ops.retrieveResult(deviceSerial: "S", timeout: 5)
            XCTFail("Expected workerError")
        } catch let error as PixelDesktopError {
            guard case .workerError = error else { return XCTFail("got \(error)") }
        } catch { XCTFail("got \(error)") }
    }

    /// A result that cannot be parsed is never trusted (ADR-004).
    func testRetrieveResultMalformedJSONIsVerificationFailure() async {
        let transport = MockTransport()
        let garbage = "not json at all"
        await transport.setShellResponse("stat -c %s \(WorkerTransferContract.remoteResultPath)",
            TransportResult(exitCode: 0, stdout: "\(garbage.utf8.count)\n", stderr: ""))
        await transport.setPullContent(garbage)

        let ops = ADBWorkerOperations(transport: transport)
        do {
            _ = try await ops.retrieveResult(deviceSerial: "S", timeout: 5)
            XCTFail("Expected verificationFailed")
        } catch let error as PixelDesktopError {
            guard case .verificationFailed = error else { return XCTFail("got \(error)") }
        } catch { XCTFail("got \(error)") }
    }

    /// A partial result transfer must fail rather than hand back truncated JSON.
    func testRetrieveResultPartialTransferIsWorkerError() async {
        let transport = MockTransport()
        // Device claims 500 bytes; the pulled file will be much smaller.
        await transport.setShellResponse("stat -c %s \(WorkerTransferContract.remoteResultPath)",
            TransportResult(exitCode: 0, stdout: "500\n", stderr: ""))
        await transport.setPullContent("{}")

        let ops = ADBWorkerOperations(transport: transport)
        do {
            _ = try await ops.retrieveResult(deviceSerial: "S", timeout: 5)
            XCTFail("Expected workerError for partial transfer")
        } catch let error as PixelDesktopError {
            guard case .workerError = error else { return XCTFail("got \(error)") }
        } catch { XCTFail("got \(error)") }
    }

    /// A stale result from a previous run must not be mistaken for a fresh one.
    func testRetrieveResultRemovesStaleLocalResultFirst() async throws {
        try WorkerTransferContract.prepareStagingDirectory()
        try "STALE".write(to: WorkerTransferContract.localResultPath, atomically: true, encoding: .utf8)

        let transport = MockTransport()
        await transport.setDefaultShellResult(TransportResult(exitCode: 1, stdout: "", stderr: "no such file"))
        let ops = ADBWorkerOperations(transport: transport)

        do {
            _ = try await ops.retrieveResult(deviceSerial: "S", timeout: 5)
            XCTFail("Expected workerError")
        } catch { /* expected */ }

        XCTAssertFalse(FileManager.default.fileExists(atPath: WorkerTransferContract.localResultPath.path),
                       "the stale result must have been removed")
    }
}

// MARK: - Phase 5 D8: Worker Installer / Lifecycle / Compute-Proof Tests

final class WorkerInstallerTests: XCTestCase {

    func testParseVersionCode() {
        let output = "    versionCode=1 minSdk=31 targetSdk=36\n    versionName=1.0"
        XCTAssertEqual(WorkerInstaller.parseVersionCode(output), 1)
    }

    func testParseVersionCodeAbsent() {
        XCTAssertNil(WorkerInstaller.parseVersionCode("Unable to find package com.x"))
        XCTAssertNil(WorkerInstaller.parseVersionCode(""))
    }

    func testInstalledStateNotInstalledWhenDumpsysFails() async throws {
        let transport = MockTransport()
        await transport.setDefaultShellResult(TransportResult(exitCode: 1, stdout: "", stderr: "Unable to find package"))
        let installer = WorkerInstaller(transport: transport)

        let state = try await installer.installedState(deviceSerial: "S")
        XCTAssertEqual(state, .notInstalled)
        XCTAssertFalse(state.isInstalled)
    }

    func testInstalledStateReadsVersion() async throws {
        let transport = MockTransport()
        await transport.setShellResponse(
            "dumpsys package \(WorkerTransferContract.workerPackageName)",
            TransportResult(exitCode: 0, stdout: "    versionCode=1 minSdk=31", stderr: ""))
        let installer = WorkerInstaller(transport: transport)

        let state = try await installer.installedState(deviceSerial: "S")
        XCTAssertEqual(state.versionCode, 1)
        XCTAssertTrue(state.isInstalled)
    }

    func testInstallUsesReplaceFlagAndFixedPackage() async throws {
        let transport = MockTransport()
        await transport.setShellResponse(
            "dumpsys package \(WorkerTransferContract.workerPackageName)",
            TransportResult(exitCode: 0, stdout: "    versionCode=1 minSdk=31", stderr: ""))
        let installer = WorkerInstaller(transport: transport)

        let apk = try makeTempFile(contents: "not a real apk")
        defer { try? FileManager.default.removeItem(at: apk) }

        _ = try await installer.installWorker(deviceSerial: "S", apkPath: apk.path)

        let invocations = await transport.invocations
        let install = invocations.first { $0.arguments.contains("install") }
        XCTAssertNotNil(install)
        XCTAssertTrue(install!.arguments.contains("-r"), "install must use -r to replace")
        XCTAssertEqual(install!.arguments.last, apk.path)
    }

    /// Installation is state-changing, so a refused APK must never reach the device.
    func testInstallRefusesSymlinkApkBeforeTouchingDevice() async throws {
        let transport = MockTransport()
        let installer = WorkerInstaller(transport: transport)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pd_inst_\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("real.apk")
        try "x".write(to: real, atomically: true, encoding: .utf8)
        let link = dir.appendingPathComponent("link.apk")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        do {
            _ = try await installer.installWorker(deviceSerial: "S", apkPath: link.path)
            XCTFail("Expected refusal of a symlink APK")
        } catch let error as PixelDesktopError {
            guard case .invalidInput = error else { return XCTFail("got \(error)") }
        } catch { XCTFail("got \(error)") }

        let invocations = await transport.invocations
        XCTAssertTrue(invocations.isEmpty, "a refused APK must not reach the device")
    }

    func testInstallSurfacesFailure() async throws {
        let transport = MockTransport()
        await transport.setInstallResult(TransportResult(exitCode: 1, stdout: "Failure [INSTALL_FAILED_ALREADY_EXISTS]", stderr: ""))
        let installer = WorkerInstaller(transport: transport)
        let apk = try makeTempFile(contents: "x")
        defer { try? FileManager.default.removeItem(at: apk) }

        do {
            _ = try await installer.installWorker(deviceSerial: "S", apkPath: apk.path)
            XCTFail("Expected adbCommandFailed")
        } catch let error as PixelDesktopError {
            guard case .adbCommandFailed = error else { return XCTFail("got \(error)") }
        } catch { XCTFail("got \(error)") }
    }

    /// Idempotence: an already-correct version must not trigger a reinstall.
    func testEnsureInstalledSkipsWhenVersionMatches() async throws {
        let transport = MockTransport()
        await transport.setShellResponse(
            "dumpsys package \(WorkerTransferContract.workerPackageName)",
            TransportResult(exitCode: 0, stdout: "    versionCode=1 minSdk=31", stderr: ""))
        let installer = WorkerInstaller(transport: transport)

        _ = try await installer.ensureInstalled(deviceSerial: "S", apkPath: "/nonexistent.apk", expectedVersionCode: 1)

        let invocations = await transport.invocations
        XCTAssertFalse(invocations.contains { $0.arguments.contains("install") },
                       "no install should occur when the version already matches")
    }

    private func makeTempFile(contents: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pd_apk_\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("worker.apk")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

final class WorkerLifecycleTests: XCTestCase {

    func testStateNotRunningWhenPidofEmpty() async throws {
        let transport = MockTransport()
        await transport.setDefaultShellResult(TransportResult(exitCode: 1, stdout: "", stderr: ""))
        let lifecycle = WorkerLifecycle(transport: transport)

        let state = try await lifecycle.state(deviceSerial: "S")
        XCTAssertEqual(state, .notRunning)
        XCTAssertFalse(state.isRunning)
    }

    func testStateRunningWithPID() async throws {
        let transport = MockTransport()
        await transport.setShellResponse(
            "pidof \(WorkerTransferContract.workerPackageName)",
            TransportResult(exitCode: 0, stdout: "12345\n", stderr: ""))
        let lifecycle = WorkerLifecycle(transport: transport)

        let state = try await lifecycle.state(deviceSerial: "S")
        XCTAssertEqual(state.pid, 12345)
    }

    func testParsePID() {
        XCTAssertEqual(WorkerLifecycle.parsePID("12345"), 12345)
        XCTAssertEqual(WorkerLifecycle.parsePID("12345 67890"), 12345)
        XCTAssertNil(WorkerLifecycle.parsePID(""))
    }

    func testStopIfRunningNoOpWhenNotRunning() async throws {
        let transport = MockTransport()
        await transport.setDefaultShellResult(TransportResult(exitCode: 1, stdout: "", stderr: ""))
        let lifecycle = WorkerLifecycle(transport: transport)

        try await lifecycle.stopIfRunning(deviceSerial: "S")

        let invocations = await transport.invocations
        XCTAssertFalse(invocations.contains { $0.arguments.last?.contains("force-stop") == true },
                       "must not force-stop a process that is not running")
    }

    func testLaunchUsesFixedComponent() async throws {
        let transport = MockTransport()
        let lifecycle = WorkerLifecycle(transport: transport)

        try await lifecycle.launch(deviceSerial: "S")

        let invocations = await transport.invocations
        XCTAssertEqual(invocations.last?.arguments,
                       ["S", "shell", "am start -n \(WorkerTransferContract.workerActivityComponent)"])
    }

    func testLaunchSurfacesFailure() async {
        let transport = MockTransport()
        await transport.setDefaultShellResult(TransportResult(exitCode: 1, stdout: "", stderr: "Error: Activity not found"))
        let lifecycle = WorkerLifecycle(transport: transport)

        do {
            try await lifecycle.launch(deviceSerial: "S")
            XCTFail("Expected workerError")
        } catch let error as PixelDesktopError {
            guard case .workerError = error else { return XCTFail("got \(error)") }
        } catch { XCTFail("got \(error)") }
    }
}

final class WorkerComputeProofParsingTests: XCTestCase {

    /// `/proc/<pid>/stat` parsing must survive a process name containing spaces or parentheses.
    func testParseCPUTicks() {
        // utime=100 (field 14), stime=50 (field 15) -> 150
        let line = "1234 (worker) S 1 1234 0 0 -1 4194624 100 0 0 0 100 50 0 0 20 0 10 0 12345 0 0"
        XCTAssertEqual(WorkerComputeProof.parseCPUTicks(line), 150)
    }

    func testParseCPUTicksWithSpacesInProcessName() {
        // Process name contains a space and parentheses; parsing must split after the LAST ')'.
        let line = "1234 (my worker (v2)) S 1 1234 0 0 -1 4194624 7 0 0 0 300 40 0 0 20 0 10 0 12345 0 0"
        XCTAssertEqual(WorkerComputeProof.parseCPUTicks(line), 340)
    }

    func testParseCPUTicksRejectsMalformed() {
        XCTAssertNil(WorkerComputeProof.parseCPUTicks(""))
        XCTAssertNil(WorkerComputeProof.parseCPUTicks("no parens here"))
        XCTAssertNil(WorkerComputeProof.parseCPUTicks("1234 (w) S 1 2"))
    }

    func testJobEncodesWithExpectedWireFieldNames() throws {
        let job = DTCA1Job(jobId: "abc-123", input: "hello world")
        let encoded = try job.encoded()

        XCTAssertTrue(encoded.contains("\"job_id\":\"abc-123\""), "got: \(encoded)")
        XCTAssertTrue(encoded.contains("\"workload\":\"DTCA-1\""), "got: \(encoded)")
        XCTAssertTrue(encoded.contains("\"input\":\"hello world\""), "got: \(encoded)")
    }

    func testJobIdDiffersBetweenCalls() {
        XCTAssertNotEqual(DTCA1Job.newJobId(), DTCA1Job.newJobId())
    }

    func testResultEnvelopeDecodesCompleted() throws {
        let json = #"{"status":"COMPLETED","job_id":"j1","input_characters":5,"total_words":1,"unique_words":1,"top_words":[{"word":"hello","count":1}],"classification":"NATURAL_LANGUAGE","confidence":0.5,"execution_timestamp_ms":1,"execution_duration_ms":2}"#
        let envelope = try JSONDecoder().decode(WorkerResultEnvelope.self, from: Data(json.utf8))

        XCTAssertTrue(envelope.isCompleted(expectedSuccessToken: DTCA1Job.successResultToken))
        XCTAssertEqual(envelope.jobId, "j1")
        let result = try envelope.asDTCA1Result(expectedSuccessToken: DTCA1Job.successResultToken)
        XCTAssertEqual(result.totalWords, 1)
        XCTAssertEqual(result.classification, "NATURAL_LANGUAGE")
    }

    /// **Updated in Phase 7 Step 3 (S3-1).** This previously asserted `workerError`, which is what
    /// the flattening produced. The worker's structured `error_type` is now preserved as
    /// `workerRefused(category:)`, so the test asserts the category rather than prose.
    func testResultEnvelopeFailedStatusCarriesTheStructuredCategory() throws {
        let json = #"{"status":"FAILED","job_id":"j1","error_type":"INVALID_INPUT","error_message":"unsupported workload"}"#
        let envelope = try JSONDecoder().decode(WorkerResultEnvelope.self, from: Data(json.utf8))

        XCTAssertFalse(envelope.isCompleted(expectedSuccessToken: DTCA1Job.successResultToken))
        XCTAssertThrowsError(try envelope.asDTCA1Result(expectedSuccessToken: DTCA1Job.successResultToken)) { error in
            guard case PixelDesktopError.workerRefused(let category, let message) = error else {
                return XCTFail("got \(error)")
            }
            XCTAssertEqual(category, "INVALID_INPUT")
            XCTAssertEqual(message, "unsupported workload")
        }
    }

    /// A `FAILED` envelope that carries **no** `error_type` falls back to `workerError` — the
    /// category is never invented to fill the field.
    func testResultEnvelopeWithoutCategoryFallsBackToWorkerError() throws {
        let json = #"{"status":"FAILED","job_id":"j1","error_message":"malformed"}"#
        let envelope = try JSONDecoder().decode(WorkerResultEnvelope.self, from: Data(json.utf8))

        XCTAssertThrowsError(try envelope.asDTCA1Result(expectedSuccessToken: DTCA1Job.successResultToken)) { error in
            guard case PixelDesktopError.workerError(let message) = error else {
                return XCTFail("got \(error)")
            }
            XCTAssertTrue(message.contains("malformed"))
        }
    }

    /// Two different worker categories must be **distinguishable** by a caller.
    ///
    /// This is the whole point of S3-1: under the old flattening both were `workerError` and a
    /// caller could only tell them apart by matching English.
    func testDistinctWorkerCategoriesAreProgrammaticallyDistinguishable() throws {
        func refusal(_ errorType: String) throws -> PixelDesktopError {
            let json = #"{"status":"FAILED","job_id":"j1","error_type":"\#(errorType)","error_message":"x"}"#
            let envelope = try JSONDecoder().decode(WorkerResultEnvelope.self, from: Data(json.utf8))
            do {
                _ = try envelope.asDTCA1Result(expectedSuccessToken: DTCA1Job.successResultToken)
                throw XCTSkip("expected a refusal")
            } catch let error as PixelDesktopError {
                return error
            }
        }

        let missingModel = try refusal("MODEL_MISSING")
        let badInput = try refusal("INVALID_INPUT")

        XCTAssertNotEqual(missingModel, badInput, "different causes must not collapse into one case")

        guard case .workerRefused(let a, _) = missingModel,
              case .workerRefused(let b, _) = badInput else {
            return XCTFail("both must be workerRefused")
        }
        XCTAssertEqual(a, "MODEL_MISSING")
        XCTAssertEqual(b, "INVALID_INPUT")
    }

    /// A COMPLETED result missing fields must not be coerced into a plausible one.
    func testResultEnvelopeMissingFieldsIsVerificationFailure() throws {
        let json = #"{"status":"COMPLETED","job_id":"j1","input_characters":5}"#
        let envelope = try JSONDecoder().decode(WorkerResultEnvelope.self, from: Data(json.utf8))

        XCTAssertThrowsError(try envelope.asDTCA1Result(expectedSuccessToken: DTCA1Job.successResultToken)) { error in
            guard case PixelDesktopError.verificationFailed = error else { return XCTFail("got \(error)") }
        }
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
    private var deviceList: [AndroidDevice] = []
    private var properties: [String: String] = [:]
    private var batchedResult: TransportResult?
    private var shellResponses: [String: TransportResult] = [:]
    private var shellResponseSequences: [String: [TransportResult]] = [:]
    private var shellResponseCursor: [String: Int] = [:]
    private var defaultShellResult = TransportResult(exitCode: 0, stdout: "", stderr: "")
    private var pushResult: TransportResult?
    private var pullResult: TransportResult?
    private var pullContent: String?
    private var installResult: TransportResult?

    func setInstallResult(_ result: TransportResult) { installResult = result }

    func setPushResult(_ result: TransportResult) { pushResult = result }
    func setPullResult(_ result: TransportResult) { pullResult = result }
    func setPullContent(_ content: String) { pullContent = content }

    /// Canned response for an exact shell command string.
    func setShellResponse(_ command: String, _ result: TransportResult) {
        shellResponses[command] = result
    }

    /// Canned responses consumed in order for a repeated shell command.
    ///
    /// Needed for commands that are legitimately polled — `WorkerLifecycle.stopIfRunning` reads
    /// `pidof` until the process disappears, so a single canned answer cannot model it.
    func setShellResponses(for command: String, _ results: [TransportResult]) {
        shellResponseSequences[command] = results
        shellResponseCursor[command] = 0
    }

    func setDefaultShellResult(_ result: TransportResult) {
        defaultShellResult = result
    }

    func setResponse(forKey key: String, result: TransportResult) {
        responses[key] = result
    }

    func setDefaultResult(_ result: TransportResult) {
        defaultResult = result
    }

    func setDeviceList(_ devices: [AndroidDevice]) {
        deviceList = devices
    }

    /// Canned values for the batched `getprop` read. Absent keys model unset properties.
    func setProperties(_ values: [String: String]) {
        properties = values
    }

    func setProperty(_ key: String, value: String) {
        properties[key] = value
    }

    func setBatchedResult(_ result: TransportResult) {
        batchedResult = result
    }

    func execute(command: String, arguments: [String], timeout: TimeInterval) async throws -> TransportResult {
        invocations.append(Invocation(command: command, arguments: arguments))

        if let key = arguments.last, let response = responses[key] {
            return response
        }

        return defaultResult
    }

    func listDevices() async throws -> [AndroidDevice] {
        deviceList
    }

    func push(deviceSerial: String, localPath: String, remotePath: String, timeout: TimeInterval) async throws -> TransportResult {
        invocations.append(Invocation(command: "-s", arguments: [deviceSerial, "push", localPath, remotePath]))
        if let result = pushResult { return result }
        return defaultShellResult
    }

    func pull(deviceSerial: String, remotePath: String, localPath: String, timeout: TimeInterval) async throws -> TransportResult {
        invocations.append(Invocation(command: "-s", arguments: [deviceSerial, "pull", remotePath, localPath]))
        if let result = pullResult { return result }
        // Simulate a successful pull by copying canned content into the destination.
        if let content = pullContent {
            try? content.write(toFile: localPath, atomically: true, encoding: .utf8)
        }
        return defaultShellResult
    }

    func install(deviceSerial: String, apkPath: String, replace: Bool, timeout: TimeInterval) async throws -> TransportResult {
        var args = [deviceSerial, "install"]
        if replace { args.append("-r") }
        args.append(apkPath)
        invocations.append(Invocation(command: "-s", arguments: args))
        return installResult ?? TransportResult(exitCode: 0, stdout: "Success", stderr: "")
    }

    func shell(deviceSerial: String, command: String, timeout: TimeInterval) async throws -> TransportResult {
        invocations.append(Invocation(command: "-s", arguments: [deviceSerial, "shell", command]))

        // A sequence takes precedence: it models a command whose answer changes between reads.
        if let sequence = shellResponseSequences[command], !sequence.isEmpty {
            let index = shellResponseCursor[command] ?? 0
            shellResponseCursor[command] = index + 1
            return sequence[min(index, sequence.count - 1)]
        }

        if let result = shellResponses[command] {
            return result
        }
        return defaultShellResult
    }

    // MARK: - Binary-safe reads

    private var execOutResponses: [String: TransportBinaryResult] = [:]
    private var defaultExecOutResult = TransportBinaryResult(exitCode: 1, stdout: Data(), stderr: "execOut not configured")

    /// Canned binary response, keyed by the first exec-out argument (e.g. `screencap`).
    func setExecOutResponse(for key: String, _ result: TransportBinaryResult) {
        execOutResponses[key] = result
    }

    func setDefaultExecOutResult(_ result: TransportBinaryResult) {
        defaultExecOutResult = result
    }

    func execOut(deviceSerial: String, arguments: [String], timeout: TimeInterval) async throws -> TransportBinaryResult {
        invocations.append(Invocation(command: "-s", arguments: [deviceSerial, "exec-out"] + arguments))
        if let key = arguments.first, let response = execOutResponses[key] {
            return response
        }
        return defaultExecOutResult
    }

    // MARK: - Streaming

    private var streamingLines: [String] = []
    private var streamingStderrLines: [String] = []
    private var streamingExitCode: Int32 = 0
    private var streamingError: Error?
    private(set) var streamingInvocations: [String] = []
    private(set) var lastStreamingStdin: String?

    /// Configures the canned stream: lines are delivered in order, then stderr, then the exit code.
    func setStreamingLines(_ lines: [String], stderr: [String] = [], exitCode: Int32 = 0) {
        streamingLines = lines
        streamingStderrLines = stderr
        streamingExitCode = exitCode
    }

    /// Makes the streaming call throw, modelling a transport that never established.
    func setStreamingError(_ error: Error) { streamingError = error }

    func shellStreaming(
        deviceSerial: String,
        command: String,
        stdin: String?,
        onLine: @Sendable @escaping (String) -> Void,
        onStderrLine: @Sendable @escaping (String) -> Void,
        cancellation: CancellationHandle
    ) async throws -> Int32 {
        streamingInvocations.append(command)
        lastStreamingStdin = stdin

        if let streamingError { throw streamingError }

        for line in streamingLines {
            if cancellation.isCancelled || Task.isCancelled { break }
            onLine(line)
        }
        for line in streamingStderrLines { onStderrLine(line) }
        if cancellation.isCancelled || Task.isCancelled {
            throw PixelDesktopError.cancelled
        }
        return streamingExitCode
    }

    func getSystemProperties(deviceSerial: String, timeout: TimeInterval) async throws -> [String: String] {
        invocations.append(Invocation(command: "-s", arguments: [deviceSerial, "shell", "getprop"]))

        if let result = batchedResult, !result.isSuccess {
            throw PixelDesktopError.adbCommandFailed(
                command: "getprop",
                exitCode: Int(result.exitCode),
                stderr: result.stderr
            )
        }

        return properties
    }

    func getprop(deviceSerial: String, key: String, timeout: TimeInterval) async throws -> String {
        invocations.append(Invocation(command: "-s", arguments: [deviceSerial, "shell", "getprop", key]))

        if let result = responses[key], !result.isSuccess {
            throw PixelDesktopError.adbCommandFailed(
                command: "getprop \(key)",
                exitCode: Int(result.exitCode),
                stderr: result.stderr
            )
        }

        // Mirrors the real transport: an unset property is absent from the map, and
        // absence is what makes it invalid rather than empty.
        guard let value = properties[key], !value.isEmpty else {
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
///       TEST_RUNNER_PIXELDESKTOP_DEVICE_SERIAL=DEADBEEF000000
///
/// Assertions check only that values are present and well-formed. They
/// deliberately do not pin an expected Android version or API level: the point
/// is to verify the acquisition path, not to freeze the device's current build.
final class AndroidDeviceIntegrationTests: XCTestCase {
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
        XCTAssertEqual(device.marketingName, "")
        XCTAssertEqual(device.manufacturer, "")
        XCTAssertTrue(device.supportedABIs.isEmpty)

        let enriched = try await DeviceEnricher(transport: transport).enrich(device)

        print("""
        REAL-DEVICE VERIFICATION
          serial:       \(enriched.serialNumber)
          codename:     \(enriched.deviceCodename)
          marketing:    \(enriched.marketingName)
          manufacturer: \(enriched.manufacturer)
          android:      \(enriched.androidVersion)
          api level:    \(enriched.apiLevel)
          abi:          \(enriched.architecture)
          abi list:     \(enriched.supportedABIs.joined(separator: ", "))
        """)

        XCTAssertFalse(enriched.androidVersion.isEmpty)
        XCTAssertGreaterThan(enriched.apiLevel, 0)
        XCTAssertFalse(enriched.architecture.isEmpty)
        XCTAssertFalse(enriched.marketingName.isEmpty)
        XCTAssertFalse(enriched.manufacturer.isEmpty)
        XCTAssertFalse(enriched.supportedABIs.isEmpty)

        // The primary ABI must appear in the supported list.
        XCTAssertTrue(enriched.supportedABIs.contains(enriched.architecture))

        // Regression for the Phase 3 defect: manufacturer must not be the codename.
        XCTAssertNotEqual(enriched.manufacturer, enriched.deviceCodename)
        XCTAssertNotEqual(enriched.marketingName, enriched.deviceCodename)

        // Identity from discovery must survive enrichment untouched.
        XCTAssertEqual(enriched.serialNumber, device.serialNumber)
        XCTAssertEqual(enriched.deviceCodename, device.deviceCodename)
        XCTAssertEqual(enriched.state, .device)
    }

    /// The batched read must agree with single-key reads. If the parser were lying,
    /// enrichment would silently produce wrong values.
    func testRealDeviceBatchedReadAgreesWithSingleKeyReads() async throws {
        guard let serial = deviceSerial else {
            throw XCTSkip("PIXELDESKTOP_DEVICE_SERIAL not set; skipping real-device verification")
        }

        let transport = ADBTransport()
        let batched = try await transport.getSystemProperties(deviceSerial: serial, timeout: 15)

        for key in DevicePropertyKey.all {
            let single = try await transport.getprop(deviceSerial: serial, key: key, timeout: 15)
            XCTAssertEqual(batched[key], single, "Batched value for \(key) disagrees with single-key read")
        }
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

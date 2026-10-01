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
    /// Pixel 7a (serial 3C261JEHN25632) while it was attached. This exercises the
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
        let realDevices = "List of devices attached\n3C261JEHN25632         device usb:1048576X product:lynx model:Pixel_7a device:lynx transport_id:276\n"

        let parsed = ADBTransport().parseDeviceList(realDevices)
        XCTAssertEqual(parsed.count, 1)
        guard let discovered = parsed.first else { return }

        XCTAssertEqual(discovered.serialNumber, "3C261JEHN25632")
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
            id: "3C261JEHN25632",
            serialNumber: "3C261JEHN25632",
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
        XCTAssertEqual(enriched.serialNumber, "3C261JEHN25632")
        XCTAssertEqual(enriched.state, .device)

        // One batched read, not one process spawn per property.
        let invocations = await transport.invocations
        XCTAssertEqual(invocations.count, 1)
        XCTAssertEqual(invocations[0].arguments, ["3C261JEHN25632", "shell", "getprop"])
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
                id: "3C261JEHN25632",
                serialNumber: "3C261JEHN25632",
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

        let enriched = try await manager.enrichDevice(serial: "3C261JEHN25632")

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
    private var defaultShellResult = TransportResult(exitCode: 0, stdout: "", stderr: "")

    /// Canned response for an exact shell command string.
    func setShellResponse(_ command: String, _ result: TransportResult) {
        shellResponses[command] = result
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

    func shell(deviceSerial: String, command: String, timeout: TimeInterval) async throws -> TransportResult {
        invocations.append(Invocation(command: "-s", arguments: [deviceSerial, "shell", command]))

        if let result = shellResponses[command] {
            return result
        }
        return defaultShellResult
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
///       TEST_RUNNER_PIXELDESKTOP_DEVICE_SERIAL=3C261JEHN25632
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

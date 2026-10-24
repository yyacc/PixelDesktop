//
//  Phase1ComputeTests.swift
//  PixelDesktopTests
//
//  Phase 1 (C1 + C2) — the on-device compute node.
//
//  ## Why this file exists
//
//  C1 and C2 were committed at 0f74b40 with a green suite and **zero tests referencing them**.
//  That gap is not hypothetical: the device verification pass of 2026-10-24 found three real
//  defects in this code that no test could have caught, because nothing exercised it —
//
//  1. `LlamaServerService.status` used `pgrep -f llama-server`, which matches the `adb shell`
//     wrapper's own command line and can report the wrapper's PID as the server's.
//  2. `LlamaServerService.start` bound `--host 0.0.0.0`, publishing an unauthenticated
//     inference endpoint on the LAN when `adb forward` only needs loopback.
//  3. `LlamaServerService.swift` and `TermuxNodeInstaller.swift` held each other's
//     implementations.
//
//  These tests pin the *command construction* and the *response parsing* — the parts that are
//  pure and therefore cheap to pin. They cannot prove the channel works: `start`/`stop` are
//  blocked by a Termux 0.118 permission the adb shell cannot hold, which is a property of the
//  device and is recorded in the real-device verification handoff rather than mocked away here.
//

import XCTest
@testable import PixelDesktop

final class Phase1ComputeTests: XCTestCase {

    private let serial = "3C261JEHN25632"

    // MARK: - C1 · status

    /// The regression this file exists for: `-f` matched the wrapper, `-x` cannot.
    func testStatusUsesExactProcessNameMatch() async throws {
        let transport = MockTransport()
        let service = ADBLlamaServerService(transport: transport)
        await transport.setShellResponse("pidof llama-server || echo NONE", TransportResult(
            exitCode: 0, stdout: "8329\n", stderr: ""
        ))

        _ = try await service.status(deviceSerial: serial, port: 8080, timeout: 10)

        let shellCommands = await transport.invocations.map { $0.arguments.last ?? "" }
        XCTAssertTrue(
            shellCommands.contains("pidof llama-server || echo NONE"),
            "status must match the exact process name; -f also matches the adb shell wrapper"
        )
        XCTAssertFalse(
            shellCommands.contains(where: { $0.contains("pgrep") }),
            "pgrep is unusable here: -f self-matches the adb shell wrapper, and -x returns "
            + "nothing on procps-ng 4.0.7 even when the process name matches"
        )
    }

    func testStatusReportsRunningWithParsedPID() async throws {
        let transport = MockTransport()
        let service = ADBLlamaServerService(transport: transport)
        await transport.setShellResponse("pidof llama-server || echo NONE", TransportResult(
            exitCode: 0, stdout: "8329\n", stderr: ""
        ))

        let status = try await service.status(deviceSerial: serial, port: 8080, timeout: 10)

        XCTAssertEqual(status, .running(port: 8080, pid: 8329))
    }

    func testStatusReportsStoppedWhenNoProcess() async throws {
        let transport = MockTransport()
        let service = ADBLlamaServerService(transport: transport)
        await transport.setShellResponse("pidof llama-server || echo NONE", TransportResult(
            exitCode: 0, stdout: "NONE\n", stderr: ""
        ))

        let status = try await service.status(deviceSerial: serial, port: 8080, timeout: 10)

        XCTAssertEqual(status, .stopped)
    }

    /// `pgrep` exits 1 with empty output when nothing matches; the `|| echo NONE` guard means
    /// the empty case is reachable too, and must not be reported as a running server.
    func testStatusReportsStoppedOnEmptyOutput() async throws {
        let transport = MockTransport()
        let service = ADBLlamaServerService(transport: transport)
        await transport.setShellResponse("pidof llama-server || echo NONE", TransportResult(
            exitCode: 1, stdout: "", stderr: ""
        ))

        let status = try await service.status(deviceSerial: serial, port: 8080, timeout: 10)

        XCTAssertEqual(status, .stopped)
    }

    func testStatusReportsRunningWithoutPIDWhenOutputIsNotANumber() async throws {
        let transport = MockTransport()
        let service = ADBLlamaServerService(transport: transport)
        await transport.setShellResponse("pidof llama-server || echo NONE", TransportResult(
            exitCode: 0, stdout: "not-a-pid\n", stderr: ""
        ))

        let status = try await service.status(deviceSerial: serial, port: 8080, timeout: 10)

        XCTAssertEqual(status, .running(port: 8080, pid: nil))
    }

    // MARK: - C1 · start / stop

    /// Loopback, not `0.0.0.0`: `adb forward` reaches the device's loopback, and binding every
    /// interface would expose an unauthenticated inference endpoint on the LAN.
    func testStartBindsLoopbackOnly() async throws {
        let transport = MockTransport()
        let service = ADBLlamaServerService(transport: transport)

        _ = try await service.start(
            deviceSerial: serial, port: 8080,
            modelPath: "/data/data/com.termux/files/home/models/m.gguf",
            timeout: 10
        )

        // Hoisted: an actor-isolated property cannot be referenced from the nonisolated
        // autoclosure that `XCTUnwrap` takes.
        let commands = await transport.invocations.map { $0.arguments.last ?? "" }
        let command = try XCTUnwrap(commands.first(where: { $0.contains("llama-server") }))
        XCTAssertTrue(command.contains("--host 127.0.0.1"), "must not bind 0.0.0.0: \(command)")
        XCTAssertFalse(command.contains("0.0.0.0"))
        XCTAssertTrue(command.contains("--port 8080"))
        XCTAssertTrue(command.contains("models/m.gguf"))
    }

    func testStopIssuesProcessKill() async throws {
        let transport = MockTransport()
        let service = ADBLlamaServerService(transport: transport)

        _ = try await service.stop(deviceSerial: serial, timeout: 10)

        let commands = await transport.invocations.map { $0.arguments.last ?? "" }
        let command = try XCTUnwrap(commands.first(where: { $0.contains("pkill") }))
        XCTAssertTrue(command.contains("llama-server"), "stop must target llama-server: \(command)")
    }

    // MARK: - C1 · installer

    func testInstalledStateParsesVersionCode() async throws {
        let transport = MockTransport()
        let installer = ADBTermuxNodeInstaller(transport: transport)
        await transport.setDefaultShellResult(TransportResult(
            exitCode: 0,
            stdout: "    versionCode=118 minSdk=24 targetSdk=28\n",
            stderr: ""
        ))

        let state = try await installer.installedState(deviceSerial: serial, timeout: 10)

        XCTAssertEqual(state, .installed(versionCode: 118))
    }

    func testInstalledStateReportsNotInstalledWhenVersionAbsent() async throws {
        let transport = MockTransport()
        let installer = ADBTermuxNodeInstaller(transport: transport)
        await transport.setDefaultShellResult(TransportResult(exitCode: 0, stdout: "Packages:\n", stderr: ""))

        let state = try await installer.installedState(deviceSerial: serial, timeout: 10)

        XCTAssertEqual(state, .notInstalled)
    }

    func testInstallTermuxIssuesInstallWithReplace() async throws {
        let transport = MockTransport()
        let installer = ADBTermuxNodeInstaller(transport: transport)
        await transport.setInstallResult(TransportResult(exitCode: 0, stdout: "Success", stderr: ""))

        _ = try await installer.installTermux(
            deviceSerial: serial, apkPath: "/tmp/termux.apk", timeout: 60
        )

        let invocations = await transport.invocations
        let invocation = try XCTUnwrap(invocations.first)
        XCTAssertEqual(invocation.arguments, [serial, "install", "-r", "/tmp/termux.apk"])
    }

    // MARK: - C2 · response parsing

    /// The exact shape returned by the real server on 2026-10-24.
    func testParseCompletionExtractsContentAndTokenCount() throws {
        let body = """
        {"index":0,"content":"PIXEL_OK","tokens_predicted":16,"tokens_evaluated":6,"stop_type":"limit"}
        """.data(using: .utf8)!

        let parsed = try URLSessionOnDeviceInferenceJobRunner.parseCompletionBody(body)

        XCTAssertEqual(parsed.text, "PIXEL_OK")
        XCTAssertEqual(parsed.tokensGenerated, 16)
    }

    /// llama.cpp returns `content`; the `text` fallback exists so an OpenAI-shaped body does
    /// not silently yield an empty result.
    func testParseCompletionFallsBackToTextField() throws {
        let body = #"{"text":"hello","tokens_predicted":3}"#.data(using: .utf8)!

        let parsed = try URLSessionOnDeviceInferenceJobRunner.parseCompletionBody(body)

        XCTAssertEqual(parsed.text, "hello")
        XCTAssertEqual(parsed.tokensGenerated, 3)
    }

    /// An empty completion is a real answer — the model produced nothing within `n_predict` —
    /// so it must not be reported as a failure.
    func testParseCompletionTreatsMissingTextFieldAsEmptyText() throws {
        let body = #"{"tokens_predicted":0,"stop_type":"limit"}"#.data(using: .utf8)!

        let parsed = try URLSessionOnDeviceInferenceJobRunner.parseCompletionBody(body)

        XCTAssertEqual(parsed.text, "")
        XCTAssertEqual(parsed.tokensGenerated, 0)
    }

    func testParseCompletionThrowsOnNonObjectBody() throws {
        let body = #"["not","an","object"]"#.data(using: .utf8)!

        XCTAssertThrowsError(try URLSessionOnDeviceInferenceJobRunner.parseCompletionBody(body))
    }

    func testParseCompletionReportsNilTokensWhenAbsent() throws {
        let body = #"{"content":"ok"}"#.data(using: .utf8)!

        let parsed = try URLSessionOnDeviceInferenceJobRunner.parseCompletionBody(body)

        XCTAssertEqual(parsed.text, "ok")
        XCTAssertNil(parsed.tokensGenerated)
    }
}

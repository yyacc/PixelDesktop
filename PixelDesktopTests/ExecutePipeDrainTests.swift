import XCTest
@testable import PixelDesktop

/// Regression tests for the `execute()` subprocess pipe drain.
///
/// ## The defect these exist for
///
/// `execute()` used to call `process.waitUntilExit()` **before** reading either pipe. That
/// deadlocks whenever the child writes more than the pipe's buffer: the child's `write` blocks
/// once the buffer is full, so the child never exits, so `waitUntilExit()` never returns. The
/// timeout task eventually killed it and the output was truncated to exactly one buffer
/// (65,536 bytes on macOS).
///
/// This was not theoretical. `adb shell getprop` returns 53,721 bytes — 82% of that buffer — and
/// is reached in production through `DeviceEnricher.enrich` → `getSystemProperties` → `execute()`.
///
/// ## Why these use real subprocesses
///
/// The defect lives in the interaction between `Process` and the OS pipe buffer. A mock transport
/// returns a string and cannot reproduce it: the bug *was* that the real objects did not behave as
/// assumed. These tests therefore drive the real `ADBTransport` against a real child, using the
/// same fake-`adb` wrapper shape as `StreamingLifecycleTests`.
///
/// ## Bounded
///
/// Every test runs under a wall-clock bound, so a regression surfaces as a FAILURE rather than as
/// a hung suite.
final class ExecutePipeDrainTests: XCTestCase {

    /// The measured macOS pipe capacity. Output above this is what used to deadlock.
    ///
    /// Recorded as a constant so the test states the boundary it is testing rather than deriving
    /// it from whatever the implementation happens to do.
    private static let pipeBufferBytes = 65_536

    /// Path to a wrapper that emulates `adb`'s argument shape.
    ///
    /// `execute()` invokes `adb <command> <arguments...>`. The wrapper consumes those leading
    /// arguments and runs the final one through `/bin/sh -c`, so a test can supply a shell command
    /// in the position where production supplies `shell <cmd>`.
    private static var fakeADBPath: String = ""

    override class func setUp() {
        super.setUp()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pixeldesktop-exec-fake-adb-\(UUID().uuidString).sh")
        let script = """
        #!/bin/sh
        # Emulates: adb <command> <arguments...>
        # The command is the final argument; everything before it is ignored.
        for last; do :; done
        exec /bin/sh -c "$last"
        """
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path)
        fakeADBPath = url.path
    }

    override class func tearDown() {
        if !fakeADBPath.isEmpty {
            try? FileManager.default.removeItem(atPath: fakeADBPath)
        }
        super.tearDown()
    }

    private func transport(defaultTimeout: TimeInterval = 10.0) -> ADBTransport {
        ADBTransport(adbPath: Self.fakeADBPath, defaultTimeout: defaultTimeout)
    }

    /// Raised when a bounded wait is exceeded, so a hang surfaces as a FAILURE rather than a skip.
    private struct BoundedWaitExceeded: Error, CustomStringConvertible {
        let seconds: TimeInterval
        var description: String { "bounded wait of \(seconds)s exceeded — the operation hung" }
    }

    /// Runs a body with a hard wall-clock bound.
    ///
    /// The failure mode under test is a hang, so a test that could itself hang would be unable to
    /// report it.
    private func withBound<T: Sendable>(
        seconds: TimeInterval,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw BoundedWaitExceeded(seconds: seconds)
            }
            guard let result = try await group.next() else {
                throw BoundedWaitExceeded(seconds: seconds)
            }
            group.cancelAll()
            return result
        }
    }

    // MARK: - 1. The regression

    /// The exact defect: stdout above the pipe buffer must not deadlock.
    ///
    /// Before the fix this returned after the full timeout with exactly `pipeBufferBytes` of
    /// output. After the fix it returns promptly with every byte.
    func testStdoutAbovePipeBufferDoesNotDeadlock() async throws {
        // 3× the buffer, so truncation cannot accidentally look like success.
        let expected = Self.pipeBufferBytes * 3
        let command = "head -c \(expected) /dev/zero | tr '\\0' 'A'"

        let result = try await withBound(seconds: 20) {
            try await self.transport().execute(command: command, arguments: [], timeout: 15)
        }

        XCTAssertEqual(result.exitCode, 0, "the child must exit cleanly, not be killed by the timeout")
        XCTAssertEqual(
            result.stdout.utf8.count, expected,
            "all \(expected) bytes must be drained; truncation at \(Self.pipeBufferBytes) is the old bug"
        )
    }

    /// Large output on **both** streams at once.
    ///
    /// Draining stdout but not stderr still deadlocks when the child fills the stderr buffer, so
    /// this covers the second pipe explicitly.
    ///
    /// The stderr half is wrapped in a subshell — `( … ) >&2` — because redirecting the producer
    /// itself (`yes X >&2 | head`) sends the producer's stdout away from the pipe and leaves
    /// `head` reading forever. That mistake is easy to make here and was made once already; the
    /// subshell form redirects only the pipeline's output.
    func testStdoutAndStderrAbovePipeBufferBothDrain() async throws {
        let each = Self.pipeBufferBytes * 2
        let command = "head -c \(each) /dev/zero | tr '\\0' 'A'; "
            + "(head -c \(each) /dev/zero | tr '\\0' 'B') >&2"

        let result = try await withBound(seconds: 20) {
            try await self.transport().execute(command: command, arguments: [], timeout: 15)
        }

        XCTAssertEqual(result.stdout.utf8.count, each, "stdout must drain fully")
        XCTAssertEqual(result.stderr.utf8.count, each, "stderr must drain fully")
    }

    /// Output of exactly the buffer size, and one byte above it — the boundary itself.
    func testExactlyAtAndAbovePipeBufferBoundary() async throws {
        for size in [Self.pipeBufferBytes, Self.pipeBufferBytes + 1] {
            let result = try await withBound(seconds: 20) {
                try await self.transport()
                    .execute(command: "head -c \(size) /dev/zero | tr '\\0' 'X'", arguments: [], timeout: 15)
            }
            XCTAssertEqual(
                result.stdout.utf8.count, size,
                "boundary size \(size) must drain exactly"
            )
        }
    }

    // MARK: - 2. Behaviour preserved

    /// A normal small-output command is unchanged.
    func testSmallOutputStillReturnedVerbatim() async throws {
        let result = try await self.transport()
            .execute(command: "printf 'hello\\n'", arguments: [], timeout: 5)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "hello\n")
        XCTAssertEqual(result.stderr, "")
    }

    /// A non-zero exit is still reported as a result, not thrown.
    ///
    /// `execute()` deliberately returns failures as `TransportResult`; only a timeout throws.
    /// Changing the drain must not change that.
    func testNonZeroExitIsStillReturnedNotThrown() async throws {
        let result = try await self.transport()
            .execute(command: "echo problem >&2; exit 3", arguments: [], timeout: 5)

        XCTAssertEqual(result.exitCode, 3)
        XCTAssertEqual(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines), "problem")
        XCTAssertFalse(result.isSuccess)
    }

    /// The timeout path still throws the typed case.
    ///
    /// The drain change moved where the pipes are read, not how long the child may run.
    func testTimeoutStillThrowsTypedError() async throws {
        do {
            _ = try await withBound(seconds: 15) {
                try await self.transport(defaultTimeout: 0.5)
                    .execute(command: "sleep 30", arguments: [], timeout: 0.5)
            }
            XCTFail("expected a timeout")
        } catch let error as PixelDesktopError {
            guard case .timeout = error else {
                return XCTFail("expected .timeout, got \(error)")
            }
        }
    }

    /// A large payload that also exits non-zero must still be fully drained.
    ///
    /// This is the realistic shape of a failing `getprop`: useful diagnostics on stderr plus a
    /// non-zero status. The drain must not be conditional on success.
    func testLargeOutputWithNonZeroExitIsFullyDrained() async throws {
        let size = Self.pipeBufferBytes * 2
        let result = try await withBound(seconds: 20) {
            try await self.transport().execute(
                command: "head -c \(size) /dev/zero | tr '\\0' 'E'; exit 1",
                arguments: [],
                timeout: 15
            )
        }

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(result.stdout.utf8.count, size, "a failing child's output must still drain")
    }

    // MARK: - 3. No leaked children

    /// A command killed by the timeout must not leave its child running.
    func testTimedOutChildIsNotLeftRunning() async throws {
        let marker = "pixeldesktop-exec-leak-probe-\(UUID().uuidString.prefix(8))"

        _ = try? await withBound(seconds: 15) {
            try await self.transport(defaultTimeout: 0.5)
                .execute(command: "sleep 300 # \(marker)", arguments: [], timeout: 0.5)
        }

        // Give the transport's terminate a moment to take effect, then look for the marker.
        try await Task.sleep(nanoseconds: 500_000_000)

        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/sh")
        ps.arguments = ["-c", "ps -ax -o command | grep -F '\(marker)' | grep -v grep || true"]
        let out = Pipe()
        ps.standardOutput = out
        try? ps.run()
        ps.waitUntilExit()
        let found = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        XCTAssertTrue(
            found.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "a timed-out child must not survive teardown; found: \(found)"
        )
    }

    // MARK: - 4. Real device

    /// The device-gated case: a real Pixel read whose output exceeds the pipe buffer.
    ///
    /// The scripted tests above prove the drain works against a local child. They cannot prove it
    /// against a real `adb` over USB, where the volume arrives through ADB's own buffering and the
    /// child is `adb` rather than `/bin/sh`. This closes that gap on the **reachable** path
    /// (`shell()`), not the latent `getSystemProperties` one.
    ///
    /// Skipped unless `PIXELDESKTOP_DEVICE_SERIAL` is set, matching the Phase 2–9 convention.
    func testRealDeviceLargeReadExceedsPipeBufferWithoutDeadlock() async throws {
        guard let serial = ProcessInfo.processInfo.environment["PIXELDESKTOP_DEVICE_SERIAL"] else {
            throw XCTSkip("PIXELDESKTOP_DEVICE_SERIAL not set; skipping real-device pipe-boundary test")
        }

        // `getprop` measured 53,721 bytes on the Pixel 7a — under the buffer. Concatenating it
        // three times puts the payload clearly above 65,536 without inventing a device-side
        // generator, so the volume is produced by the device itself.
        let expectedMinimum = Self.pipeBufferBytes * 2

        let start = Date()
        let result = try await withBound(seconds: 60) {
            try await ADBTransport().shell(
                deviceSerial: serial,
                command: "getprop; getprop; getprop",
                timeout: 45
            )
        }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(result.exitCode, 0, "the read must complete cleanly")
        XCTAssertGreaterThan(
            result.stdout.utf8.count, expectedMinimum,
            "the payload must exceed the \(Self.pipeBufferBytes)-byte pipe buffer to be a valid test"
        )
        XCTAssertLessThan(
            elapsed, 40,
            "a stall approaching the timeout means the drain is not keeping up with the device"
        )
    }

    /// A real-device read that is large **and** fails, to confirm the drain is not success-gated.
    func testRealDeviceLargeFailingReadIsStillDrained() async throws {
        guard let serial = ProcessInfo.processInfo.environment["PIXELDESKTOP_DEVICE_SERIAL"] else {
            throw XCTSkip("PIXELDESKTOP_DEVICE_SERIAL not set; skipping real-device failing-read test")
        }

        let result = try await withBound(seconds: 60) {
            try await ADBTransport().shell(
                deviceSerial: serial,
                command: "getprop; getprop; echo deliberate-failure >&2; exit 4",
                timeout: 45
            )
        }

        XCTAssertEqual(result.exitCode, 4, "the non-zero status must be preserved")
        XCTAssertGreaterThan(
            result.stdout.utf8.count, Self.pipeBufferBytes,
            "output above the buffer must drain even when the command fails"
        )
        XCTAssertTrue(
            result.stderr.contains("deliberate-failure"),
            "stderr must survive alongside the large stdout payload"
        )
    }
}

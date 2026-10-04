import XCTest
@testable import PixelDesktop

/// Regression tests for the streaming subprocess / reader / watchdog lifecycle.
///
/// ## The defect these exist for
///
/// The streaming reader hung for ~17 minutes on a real device. The cause was in the Swift
/// subprocess lifecycle, **not** in ADB streaming — standalone `adb shell` stdin delivery and
/// protocol-line return both worked correctly.
///
/// Three distinct defects were found in this path:
///
/// 1. `availableData` blocks forever when the transport dies mid-session.
/// 2. **The watchdog resumed the continuation only when `process.isRunning` was true.** If the child
///    had already exited while the reader thread remained blocked, nothing ever resumed it and the
///    caller waited forever.
/// 3. `waitUntilExit()` blocked even after the read end was closed.
///
/// ## Why these use real subprocesses
///
/// The defect lives in the interaction between `Process`, pipe file handles, a reader thread and a
/// timer. A mock cannot reproduce it — the bug *was* that the real objects did not behave as
/// assumed. These tests therefore spawn real children through the real transport.
///
/// ## Bounded
///
/// Every test has a finite wall-clock bound, and the transport is built with short stall and reap
/// timeouts so the termination paths are observable in bounded time. A test that had to wait the
/// production 120 s to observe the watchdog would never be run.
final class StreamingLifecycleTests: XCTestCase {

    /// Path to a wrapper that emulates `adb`'s argument shape.
    ///
    /// The transport invokes `adb -s <serial> shell <command>`. To exercise the real transport with
    /// a real child, the wrapper consumes those leading arguments and runs the final one through
    /// `/bin/sh -c`, passing stdin straight through.
    private static var fakeADBPath: String = ""

    override class func setUp() {
        super.setUp()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pixeldesktop-fake-adb-\(UUID().uuidString).sh")
        let script = """
        #!/bin/sh
        # Emulates: adb -s <serial> shell <command>
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

    /// A transport whose watchdog fires quickly, so termination paths are testable.
    private func fastTransport(stall: TimeInterval = 1.0, reap: TimeInterval = 1.0) -> ADBTransport {
        ADBTransport(
            adbPath: Self.fakeADBPath,
            defaultTimeout: 5.0,
            streamStallTimeout: stall,
            childReapTimeout: reap
        )
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var out: [String] = []
        private var err: [String] = []
        func addOut(_ s: String) { lock.lock(); out.append(s); lock.unlock() }
        func addErr(_ s: String) { lock.lock(); err.append(s); lock.unlock() }
        var stdout: [String] { lock.lock(); defer { lock.unlock() }; return out }
        var stderr: [String] { lock.lock(); defer { lock.unlock() }; return err }
    }

    /// Raised when a bounded wait is exceeded, so a hang surfaces as a FAILURE rather than a skip.
    private struct BoundedWaitExceeded: Error, CustomStringConvertible {
        let seconds: TimeInterval
        var description: String {
            "bounded wait of \(seconds)s exceeded — the operation hung"
        }
    }

    /// Runs a body with a hard wall-clock bound.
    ///
    /// The failure mode under test is a hang, so a test that could itself hang would be unable to
    /// report it. Every test in this file goes through here.
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

    // MARK: - 1. Child exits while the reader is blocked

    /// The exact defect: the child finishes while the reader is still blocked.
    ///
    /// Before the fix, the watchdog acted only when `process.isRunning` — so once the child had
    /// exited, nothing resumed the continuation and the caller hung forever.
    func testChildExitingWhileReaderBlockedStillResumesTheContinuation() async throws {
        let transport = fastTransport()
        let collector = Collector()

        let elapsed = try await withBound(seconds: 15) {
            let start = Date()
            _ = try await transport.shellStreaming(
                deviceSerial: "serial",
                command: "true",
                stdin: nil,
                onLine: { collector.addOut($0) },
                onStderrLine: { collector.addErr($0) },
                cancellation: CancellationHandle()
            )
            return Date().timeIntervalSince(start)
        }

        // The requirement is simply that it RETURNED. A hang is the defect.
        XCTAssertLessThan(elapsed, 15, "the session must not hang when the child exits early")
    }

    func testChildExitingWithNoOutputResumes() async throws {
        let transport = fastTransport()
        let collector = Collector()

        let elapsed = try await withBound(seconds: 15) {
            let start = Date()
            _ = try await transport.shellStreaming(
                deviceSerial: "serial",
                command: "exit 0",
                stdin: nil,
                onLine: { collector.addOut($0) },
                onStderrLine: { collector.addErr($0) },
                cancellation: CancellationHandle()
            )
            return Date().timeIntervalSince(start)
        }

        XCTAssertLessThan(elapsed, 15)
        XCTAssertTrue(collector.stdout.isEmpty)
    }

    // MARK: - 2. Reader reaches EOF after the child exits

    func testReaderReachesEOFCleanlyAfterChildExit() async throws {
        let transport = fastTransport()
        let collector = Collector()

        _ = try await withBound(seconds: 15) {
            try await transport.shellStreaming(
                deviceSerial: "serial",
                command: "printf 'alpha\\nbeta\\ngamma\\n'",
                stdin: nil,
                onLine: { collector.addOut($0) },
                onStderrLine: { collector.addErr($0) },
                cancellation: CancellationHandle()
            )
        }

        // EOF must deliver every complete line and then finish.
        XCTAssertEqual(collector.stdout, ["alpha", "beta", "gamma"])
    }

    /// A final line with no trailing newline must still be delivered (EOF flush).
    func testFinalLineWithoutNewlineIsDeliveredOnEOF() async throws {
        let transport = fastTransport()
        let collector = Collector()

        _ = try await withBound(seconds: 15) {
            try await transport.shellStreaming(
                deviceSerial: "serial",
                command: "printf 'no-newline-at-end'",
                stdin: nil,
                onLine: { collector.addOut($0) },
                onStderrLine: { collector.addErr($0) },
                cancellation: CancellationHandle()
            )
        }

        XCTAssertEqual(collector.stdout, ["no-newline-at-end"])
    }

    // MARK: - 3. Child remains running but the stream stalls

    /// The watchdog must terminate a child that never exits and never speaks.
    func testWatchdogTerminatesAStalledChild() async throws {
        let transport = fastTransport(stall: 1.0, reap: 1.0)
        let collector = Collector()

        let elapsed = try await withBound(seconds: 25) {
            let start = Date()
            _ = try await transport.shellStreaming(
                deviceSerial: "serial",
                command: "sleep 600",
                stdin: nil,
                onLine: { collector.addOut($0) },
                onStderrLine: { collector.addErr($0) },
                cancellation: CancellationHandle()
            )
            return Date().timeIntervalSince(start)
        }

        // Bounded by watchdog + reap, not by the child's 600 s.
        XCTAssertLessThan(elapsed, 20, "a stalled child must be torn down, not waited on")
        XCTAssertTrue(collector.stdout.isEmpty)
    }

    // MARK: - 4. Child exits normally with a valid completion event

    func testNormalCompletionDeliversTheResultEvent() async throws {
        let transport = fastTransport()
        let collector = Collector()

        let code = try await withBound(seconds: 15) {
            try await transport.shellStreaming(
                deviceSerial: "serial",
                command: "printf 'PDE1 START job_id=j\\nPDE1 LAUNCHED\\nPDE1 RESULT_BEGIN\\n"
                    + "{\"status\":\"OK\"}\\nPDE1 RESULT_END bytes=15\\n'",
                stdin: nil,
                onLine: { collector.addOut($0) },
                onStderrLine: { collector.addErr($0) },
                cancellation: CancellationHandle()
            )
        }

        XCTAssertEqual(code, 0, "a clean exit must report exit code 0")
        XCTAssertEqual(collector.stdout, [
            "PDE1 START job_id=j",
            "PDE1 LAUNCHED",
            "PDE1 RESULT_BEGIN",
            "{\"status\":\"OK\"}",
            "PDE1 RESULT_END bytes=15",
        ])
    }

    // MARK: - 5. Child exits without a completion event

    func testChildExitingWithoutCompletionReportsNonZeroExit() async throws {
        let transport = fastTransport()
        let collector = Collector()

        let code = try await withBound(seconds: 15) {
            try await transport.shellStreaming(
                deviceSerial: "serial",
                command: "printf 'PDE1 START job_id=j\\n'; exit 3",
                stdin: nil,
                onLine: { collector.addOut($0) },
                onStderrLine: { collector.addErr($0) },
                cancellation: CancellationHandle()
            )
        }

        // A non-zero exit is returned, not thrown — the caller decides what it means.
        XCTAssertEqual(code, 3)
        XCTAssertEqual(collector.stdout, ["PDE1 START job_id=j"])
    }

    // MARK: - 6. Cancellation while blocked

    func testTaskCancellationWhileBlockedDoesNotHang() async throws {
        let transport = fastTransport(stall: 1.0, reap: 1.0)
        let collector = Collector()

        let task = Task {
            try await transport.shellStreaming(
                deviceSerial: "serial",
                command: "sleep 600",
                stdin: nil,
                onLine: { collector.addOut($0) },
                onStderrLine: { collector.addErr($0) },
                cancellation: CancellationHandle()
            )
        }

        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()

        let elapsed = try await withBound(seconds: 25) {
            let start = Date()
            _ = try? await task.value
            return Date().timeIntervalSince(start)
        }

        XCTAssertLessThan(elapsed, 20, "cancellation must not leave the read unresolved")
    }

    // MARK: - 7/8. Watchdog timeout — alive, and racing with process exit

    func testWatchdogFiresWhileProcessIsStillAlive() async throws {
        let transport = fastTransport(stall: 1.0, reap: 1.0)
        let collector = Collector()

        let elapsed = try await withBound(seconds: 25) {
            let start = Date()
            _ = try await transport.shellStreaming(
                deviceSerial: "serial",
                command: "sleep 300",
                stdin: nil,
                onLine: { collector.addOut($0) },
                onStderrLine: { collector.addErr($0) },
                cancellation: CancellationHandle()
            )
            return Date().timeIntervalSince(start)
        }

        XCTAssertLessThan(elapsed, 20)
    }

    /// The race the defect was made of: the child exits at almost exactly the moment the watchdog
    /// fires. Whichever path wins, the continuation must be resumed **exactly once**.
    ///
    /// A double resume traps in `CheckedContinuation`; a missed resume hangs. Repeating this many
    /// times is what makes the race observable.
    func testWatchdogRacingWithProcessExitResumesExactlyOnce() async throws {
        for iteration in 0..<40 {
            let transport = fastTransport(stall: 0.05, reap: 0.05)
            let collector = Collector()

            let elapsed = try await withBound(seconds: 10) {
                let start = Date()
                _ = try await transport.shellStreaming(
                    deviceSerial: "serial",
                    command: "printf 'x\\n'",
                    stdin: nil,
                    onLine: { collector.addOut($0) },
                    onStderrLine: { collector.addErr($0) },
                cancellation: CancellationHandle()
                )
                return Date().timeIntervalSince(start)
            }

            XCTAssertLessThan(elapsed, 10, "iteration \(iteration) hung")
        }
    }

    // MARK: - 9. Pipe / transport closure during streaming

    func testPipeClosureDuringStreamingIsBounded() async throws {
        let transport = fastTransport(stall: 1.0, reap: 1.0)
        let collector = Collector()

        let elapsed = try await withBound(seconds: 25) {
            let start = Date()
            // The child writes, then blocks forever — the read end stays open but goes quiet.
            _ = try await transport.shellStreaming(
                deviceSerial: "serial",
                command: "printf 'first\\n'; sleep 300",
                stdin: nil,
                onLine: { collector.addOut($0) },
                onStderrLine: { collector.addErr($0) },
                cancellation: CancellationHandle()
            )
            return Date().timeIntervalSince(start)
        }

        XCTAssertLessThan(elapsed, 20)
        XCTAssertTrue(collector.stdout.contains("first"),
                      "what arrived before the stall must still be delivered")
    }

    // MARK: - stdin delivery

    func testStdinIsDeliveredAndClosed() async throws {
        let transport = fastTransport()
        let collector = Collector()

        _ = try await withBound(seconds: 15) {
            try await transport.shellStreaming(
                deviceSerial: "serial",
                command: "cat; printf 'DONE\\n'",
                // A trailing newline, so `cat` terminates its echo with one and DONE is its own line.
                stdin: "{\"payload\":true}\n",
                onLine: { collector.addOut($0) },
                onStderrLine: { collector.addErr($0) },
                cancellation: CancellationHandle()
            )
        }

        // The payload must arrive, and DONE must follow — which proves stdin was CLOSED. Without the
        // close, `cat` blocks forever and the child would be reaped instead of exiting cleanly.
        XCTAssertTrue(collector.stdout.contains("{\"payload\":true}"),
                      "stdin payload not delivered: \(collector.stdout)")
        XCTAssertTrue(collector.stdout.contains("DONE"),
                      "stdin was not closed, so cat never finished: \(collector.stdout)")
    }

    /// Without a trailing newline the payload and the following output form ONE line.
    ///
    /// Asserted deliberately: the transport is line-oriented and does not invent a boundary that the
    /// child did not emit. The production device script is unaffected because `cat > file` writes to
    /// a file rather than to the stream.
    func testStdinWithoutTrailingNewlineJoinsTheNextOutputOnOneLine() async throws {
        let transport = fastTransport()
        let collector = Collector()

        _ = try await withBound(seconds: 15) {
            try await transport.shellStreaming(
                deviceSerial: "serial",
                command: "cat; printf 'DONE\\n'",
                stdin: "{\"payload\":true}",
                onLine: { collector.addOut($0) },
                onStderrLine: { collector.addErr($0) },
                cancellation: CancellationHandle()
            )
        }

        XCTAssertEqual(collector.stdout, ["{\"payload\":true}DONE"])
    }

    // MARK: - stdout / stderr separation

    func testStdoutAndStderrStaySeparateUnderRealPipes() async throws {
        let transport = fastTransport()
        let collector = Collector()

        _ = try await withBound(seconds: 15) {
            try await transport.shellStreaming(
                deviceSerial: "serial",
                command: "printf 'to-stdout\\n'; printf 'to-stderr\\n' >&2",
                stdin: nil,
                onLine: { collector.addOut($0) },
                onStderrLine: { collector.addErr($0) },
                cancellation: CancellationHandle()
            )
        }

        XCTAssertEqual(collector.stdout, ["to-stdout"])
        XCTAssertEqual(collector.stderr, ["to-stderr"])
    }

    /// Large output must not deadlock: if stderr is not drained concurrently, a child that fills the
    /// stderr buffer blocks and the whole session hangs.
    func testLargeOutputOnBothStreamsDoesNotDeadlock() async throws {
        let transport = fastTransport()
        let collector = Collector()

        let elapsed = try await withBound(seconds: 30) {
            let start = Date()
            _ = try await transport.shellStreaming(
                deviceSerial: "serial",
                command: "i=0; while [ $i -lt 400 ]; do echo \"out-$i\"; echo \"err-$i\" >&2; "
                    + "i=$((i+1)); done",
                stdin: nil,
                onLine: { collector.addOut($0) },
                onStderrLine: { collector.addErr($0) },
                cancellation: CancellationHandle()
            )
            return Date().timeIntervalSince(start)
        }

        XCTAssertLessThan(elapsed, 25, "concurrent draining must prevent a pipe-buffer deadlock")
        XCTAssertEqual(collector.stdout.count, 400)
        XCTAssertEqual(collector.stderr.count, 400)
    }

    // MARK: - Partial / empty / malformed lines

    func testEmptyLinesAreDeliveredAsEmptyStrings() async throws {
        let transport = fastTransport()
        let collector = Collector()

        _ = try await withBound(seconds: 15) {
            try await transport.shellStreaming(
                deviceSerial: "serial",
                command: "printf 'a\\n\\nb\\n'",
                stdin: nil,
                onLine: { collector.addOut($0) },
                onStderrLine: { collector.addErr($0) },
                cancellation: CancellationHandle()
            )
        }

        // The transport reports the empty line; the PROTOCOL layer decides to ignore it. Keeping
        // those responsibilities separate is what makes the empty-line rule testable.
        XCTAssertEqual(collector.stdout, ["a", "", "b"])
    }

    func testCRLFIsNormalisedToALineWithoutCarriageReturn() async throws {
        let transport = fastTransport()
        let collector = Collector()

        _ = try await withBound(seconds: 15) {
            try await transport.shellStreaming(
                deviceSerial: "serial",
                command: "printf 'one\\r\\ntwo\\r\\n'",
                stdin: nil,
                onLine: { collector.addOut($0) },
                onStderrLine: { collector.addErr($0) },
                cancellation: CancellationHandle()
            )
        }

        XCTAssertEqual(collector.stdout, ["one", "two"], "a stray CR must not reach the parser")
    }

    // MARK: - Continuation integrity

    /// Every termination path must resume exactly once.
    ///
    /// `CheckedContinuation` traps on a double resume, so a double resume fails loudly rather than
    /// silently corrupting; a missed resume hangs. Running all four paths repeatedly covers both.
    func testEveryTerminationPathResumesExactlyOnce() async throws {
        let cases: [(String, TimeInterval, TimeInterval)] = [
            ("printf 'ok\\n'", 5.0, 5.0),            // clean exit
            ("exit 7", 5.0, 5.0),                    // early exit
            ("sleep 300", 0.1, 0.1),                 // watchdog
            ("printf 'x\\n'; sleep 300", 0.2, 0.2),  // output then stall
        ]

        for (command, stall, reap) in cases {
            for _ in 0..<8 {
                let transport = fastTransport(stall: stall, reap: reap)
                let collector = Collector()
                let elapsed = try await withBound(seconds: 15) {
                    let start = Date()
                    _ = try? await transport.shellStreaming(
                        deviceSerial: "serial",
                        command: command,
                        stdin: nil,
                        onLine: { collector.addOut($0) },
                        onStderrLine: { collector.addErr($0) },
                cancellation: CancellationHandle()
                    )
                    return Date().timeIntervalSince(start)
                }
                XCTAssertLessThan(elapsed, 15, "path '\(command)' hung")
            }
        }
    }

    // MARK: - No leaked subprocesses

    /// A torn-down session must not leave its child running.
    ///
    /// The marker is placed in a shell comment so it appears in the child's argv (and therefore in
    /// `ps`) while `sleep` still runs normally.
    func testStalledChildIsNotLeftRunningAfterTeardown() async throws {
        let transport = fastTransport(stall: 0.5, reap: 0.5)
        let collector = Collector()
        let marker = "pixeldesktop-leak-probe-\(UUID().uuidString.prefix(8))"

        _ = try await withBound(seconds: 25) {
            try await transport.shellStreaming(
                deviceSerial: "serial",
                command: "sleep 300 # \(marker)",
                stdin: nil,
                onLine: { collector.addOut($0) },
                onStderrLine: { collector.addErr($0) },
                cancellation: CancellationHandle()
            )
        }

        // Give the OS a moment to reap.
        try await Task.sleep(nanoseconds: 800_000_000)

        let survivors = Self.processesMatching(marker)
        XCTAssertTrue(survivors.isEmpty, "leaked subprocess(es): \(survivors)")
    }

    /// Live processes whose command line contains the marker.
    private static func processesMatching(_ marker: String) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-A", "-o", "pid=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let text = String(data: data, encoding: .utf8) ?? ""
        return text.components(separatedBy: .newlines)
            .filter { $0.contains(marker) && !$0.contains("ps -A") }
    }
}

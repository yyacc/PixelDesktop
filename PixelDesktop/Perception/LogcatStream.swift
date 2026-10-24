import Foundation

/// A bounded, thread-safe store of recent log lines.
///
/// Bounded on purpose. A device under a chatty app emits thousands of lines per minute, and
/// an unbounded buffer turns "show me recent logs" into an out-of-memory condition after a
/// few hours. The oldest line is dropped when capacity is reached — the same trade a terminal
/// scrollback makes.
///
/// Thread-safety is by lock rather than by actor because callbacks arrive on the transport's
/// dispatch queues and the UI reads synchronously on the main thread. An actor would force
/// every read into `await`, which for a 2,000-line buffer is the wrong cost.
final class LogcatBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [LogcatLine] = []
    private let capacity: Int

    /// Total lines ever accepted, including ones dropped by the bound. Lets a reader tell
    /// "nothing arrived" from "everything arrived and rolled over".
    private var accepted = 0
    private var dropped = 0

    init(capacity: Int = 2000) {
        self.capacity = max(1, capacity)
    }

    func append(_ line: LogcatLine) {
        lock.lock()
        storage.append(line)
        accepted += 1
        if storage.count > capacity {
            let overflow = storage.count - capacity
            storage.removeFirst(overflow)
            dropped += overflow
        }
        lock.unlock()
    }

    var lines: [LogcatLine] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    var counts: (accepted: Int, dropped: Int) {
        lock.lock(); defer { lock.unlock() }
        return (accepted, dropped)
    }

    func clear() {
        lock.lock(); storage.removeAll(); lock.unlock()
    }
}

/// Runs `logcat` on a device as a live stream and keeps the recent lines.
///
/// ## Why a stream and not a poll
///
/// `logcat -d` (dump) re-reads the whole ring buffer on every call, so polling costs the full
/// buffer each time and still misses lines written between polls. `logcat` without `-d`
/// blocks and emits as the device writes, which is the actual capability. It rides the
/// existing `shellStreaming` primitive, so cancellation, stall detection and process reaping
/// are the ones already exercised by the worker path rather than a second implementation.
///
/// ## Lifecycle
///
/// `start` is idempotent; `stop` cancels the session and is safe to call from any thread.
/// A session that ends by itself (transport gone, device unplugged) leaves `isRunning` false
/// so the UI can show the truth instead of a spinner that never stops.
final class LogcatStream: @unchecked Sendable {
    private let transport: TransportProtocol
    private let buffer: LogcatBuffer

    private let lock = NSLock()
    private var handle: CancellationHandle?
    private var task: Task<Void, Never>?
    private var running = false
    private var lastError: String?

    /// Called after each accepted line, on a background queue. Used to nudge the UI.
    var onUpdate: (@Sendable () -> Void)?

    init(transport: TransportProtocol, capacity: Int = 2000) {
        self.transport = transport
        self.buffer = LogcatBuffer(capacity: capacity)
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    var errorDescription: String? {
        lock.lock(); defer { lock.unlock() }
        return lastError
    }

    var lines: [LogcatLine] { buffer.lines }
    var counts: (accepted: Int, dropped: Int) { buffer.counts }

    /// Starts streaming. Returns immediately; lines arrive through `buffer` and `onUpdate`.
    ///
    /// - Throws: `PixelDesktopError.invalidInput` when the filter is malformed. That is checked
    ///   here, before a session exists, so a bad tag never produces a half-open stream.
    func start(deviceSerial: String, filter: LogcatFilter = LogcatFilter()) throws {
        let arguments = try filter.arguments()
        let command = arguments.joined(separator: " ")

        lock.lock()
        if running {
            lock.unlock()
            return
        }
        let cancellation = CancellationHandle()
        handle = cancellation
        running = true
        lastError = nil
        lock.unlock()

        let buffer = self.buffer
        let onUpdate = self.onUpdate

        let task = Task { [weak self] in
            var exitCode: Int32 = -1
            do {
                exitCode = try await self?.transport.shellStreaming(
                    deviceSerial: deviceSerial,
                    command: command,
                    stdin: nil,
                    onLine: { line in
                        // Lines that do not parse are dropped, not synthesized: the banner and
                        // any adb diagnostic on stdout are not device log entries.
                        if let parsed = LogcatLine.parse(line), filter.accepts(parsed) {
                            buffer.append(parsed)
                            onUpdate?()
                        }
                    },
                    onStderrLine: { _ in
                        // `logcat` stderr is transport noise; it must not become a log line.
                    },
                    cancellation: cancellation
                ) ?? -1
            } catch {
                exitCode = -1
                self?.recordEnd(status: nil, error: error.localizedDescription)
                return
            }

            self?.recordEnd(status: exitCode, error: nil)
        }

        lock.lock(); self.task = task; lock.unlock()
    }

    /// Ends the stream. Safe when not running.
    func stop() {
        lock.lock()
        let cancellation = handle
        let task = self.task
        handle = nil
        self.task = nil
        running = false
        lock.unlock()

        cancellation?.cancel()
        task?.cancel()
    }

    func clear() {
        buffer.clear()
    }

    /// Records how the session ended. A cancelled session is not an error.
    private func recordEnd(status: Int32?, error: String?) {
        lock.lock()
        running = false
        handle = nil
        task = nil
        if let error {
            lastError = error
        } else if let status, status != 0, status != -1 {
            lastError = "logcat exited with status \(status)"
        }
        lock.unlock()

        onUpdate?()
    }
}

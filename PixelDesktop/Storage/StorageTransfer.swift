import Foundation

/// Which way a transfer moves bytes.
enum StorageTransferDirection: String, Equatable, Sendable {
    /// Mac → Pixel (`adb push`).
    case upload
    /// Pixel → Mac (`adb pull`).
    case download
}

/// A point-in-time progress sample for a single transfer.
struct StorageTransferProgress: Equatable, Sendable {
    let direction: StorageTransferDirection

    /// Bytes observed at the *destination* of the transfer so far.
    let transferredBytes: UInt64

    /// The transfer's expected total, in bytes.
    let totalBytes: UInt64

    /// Completion in `0...1`.
    ///
    /// A zero-byte transfer is reported as complete, because there is nothing left to copy —
    /// reporting `0/0` as `NaN` or `0%` would leave the UI stuck on a transfer that already
    /// finished.
    var fractionCompleted: Double {
        guard totalBytes > 0 else { return 1.0 }
        return min(1.0, Double(transferredBytes) / Double(totalBytes))
    }

    /// Whether the destination has reached the expected total.
    var isComplete: Bool {
        totalBytes == 0 || transferredBytes >= totalBytes
    }
}

/// The immutable description of one transfer, and the progress arithmetic over it.
///
/// Keeping the descriptor and the maths together means `StorageService` never computes a
/// fraction by hand and `StorageTransferPoller` never has to know what a transfer *is*.
struct StorageTransfer: Equatable, Sendable {
    let direction: StorageTransferDirection

    /// The local (Mac) operand.
    let localPath: String

    /// The remote (device) operand, already validated and normalised.
    let remotePath: String

    /// Expected total size in bytes. For an upload this is the local file size; for a download
    /// it is the remote file size read before the pull starts.
    let totalBytes: UInt64

    func progress(transferredBytes: UInt64) -> StorageTransferProgress {
        StorageTransferProgress(
            direction: direction,
            transferredBytes: transferredBytes,
            totalBytes: totalBytes
        )
    }
}

/// Receives progress samples. Marked `@Sendable` so it can be invoked from the polling task;
/// a UI caller is expected to hop to `@MainActor` inside the closure.
typealias StorageProgressHandler = @Sendable (StorageTransferProgress) -> Void

/// Polls a transfer's destination size at a fixed interval while the transfer runs.
///
/// ## Why polling
///
/// `adb push` and `adb pull` report only a final summary — there is no native progress channel.
/// The only observable signal is the destination file growing (as reported by `stat -c %s` for
/// an upload, or by the local filesystem for a download), so progress is *inferred* by polling
/// that size. This is the approach recorded in `docs/PROPOSAL-REMOTE-STORAGE.md` §2.
///
/// ## Contract
///
/// - `start()` emits an initial `0` sample, then samples until the probed size reaches the
///   transfer's total or `stop`/`abort` is called.
/// - `stop(transferredBytes:)` cancels polling, **awaits** the poll loop's completion, and emits
///   one final authoritative sample. Awaiting matters: without it a late sample could land after
///   the caller has already torn down its UI state.
/// - `abort()` cancels and awaits without emitting — used when the transfer itself failed, so a
///   final "complete" sample is never shown for a failed transfer.
final class StorageTransferPoller: @unchecked Sendable {
    private let transfer: StorageTransfer
    private let interval: TimeInterval
    private let probe: @Sendable () async -> UInt64
    private let onProgress: StorageProgressHandler

    private let lock = NSLock()
    private var task: Task<Void, Never>?

    /// - Parameters:
    ///   - interval: seconds between samples. Injectable so a test observes the loop in bounded
    ///     time instead of waiting on a production cadence.
    ///   - probe: returns the bytes currently present at the destination. Never throws — an
    ///     unreadable/absent destination is reported as `0`, which is exactly what "not there
    ///     yet" means during a transfer.
    init(
        transfer: StorageTransfer,
        interval: TimeInterval = 0.25,
        probe: @escaping @Sendable () async -> UInt64,
        onProgress: @escaping StorageProgressHandler
    ) {
        self.transfer = transfer
        self.interval = interval
        self.probe = probe
        self.onProgress = onProgress
    }

    /// Begins sampling. A second call while running is a no-op.
    func start() {
        lock.lock()
        guard task == nil else {
            lock.unlock()
            return
        }

        let transfer = self.transfer
        let interval = self.interval
        let probe = self.probe
        let onProgress = self.onProgress

        let task = Task {
            onProgress(transfer.progress(transferredBytes: 0))

            while !Task.isCancelled {
                let transferred = await probe()
                onProgress(transfer.progress(transferredBytes: transferred))

                if transferred >= transfer.totalBytes { break }

                do {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch {
                    break
                }
            }
        }

        self.task = task
        lock.unlock()
    }

    /// Cancels sampling and emits a final, authoritative sample.
    func stop(transferredBytes: UInt64) async {
        await cancelRunningTask()
        onProgress(transfer.progress(transferredBytes: transferredBytes))
    }

    /// Cancels sampling without emitting a final sample.
    func abort() async {
        await cancelRunningTask()
    }

    private func cancelRunningTask() async {
        lock.lock()
        let running = task
        task = nil
        lock.unlock()

        guard let running else { return }
        running.cancel()
        // Await the loop so no sample can arrive after the caller has moved on.
        _ = await running.value
    }
}

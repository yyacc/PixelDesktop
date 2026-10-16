import XCTest
@testable import PixelDesktop

/// Phase 2 — Storage Service Layer.
///
/// Everything here runs against the shared `MockTransport` (defined in `PixelDesktopTests.swift`)
/// with no device attached. The mock records the exact command strings handed to `adb`, so these
/// tests assert both the *parsed result* and the *command that produced it* — the latter is what
/// catches a path being interpolated without quoting.
final class StorageServiceTests: XCTestCase {

    private let serial = "PIXEL7A_TEST"
    private let root = StorageService.storageRoot

    // MARK: - Helpers

    private func makeService(_ transport: MockTransport) -> StorageService {
        // A short poll interval keeps the progress tests bounded; none of them depend on the
        // production cadence.
        StorageService(deviceSerial: serial, transport: transport, progressPollInterval: 0.01)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func writeLocalFile(_ contents: String, in directory: URL, named name: String) throws -> String {
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    private func issued(_ transport: MockTransport, _ expected: [String]) async -> Bool {
        await transport.invocations.contains { $0.arguments == expected }
    }

    /// Runs an async throwing expression and returns the `StorageError` it threw, or fails.
    private func expectStorageError<T>(
        _ expression: () async throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> StorageError? {
        do {
            _ = try await expression()
            XCTFail("expected a StorageError", file: file, line: line)
            return nil
        } catch let error as StorageError {
            return error
        } catch {
            XCTFail("expected a StorageError, got \(error)", file: file, line: line)
            return nil
        }
    }

    // MARK: - Listing parser

    func testParseListingParsesFilesFoldersAndSymlinks() {
        let output = """
        total 8
        drwxrwx--x 2 root sdcard_rw 4096 2026-10-16 10:30 Pictures
        -rw-rw---- 1 root sdcard_rw  123 2026-10-16 10:31 notes.txt
        lrwxrwxrwx 1 root root          8 2026-10-16 10:31 latest -> 2026-10-16
        """

        let items = StorageItem.parseListing(output, parentPath: root)

        XCTAssertEqual(items.map(\.name), ["Pictures", "notes.txt", "latest"])
        XCTAssertEqual(items[0].isDirectory, true)
        XCTAssertEqual(items[0].size, 4096)
        XCTAssertEqual(items[1].isDirectory, false)
        XCTAssertEqual(items[1].size, 123)
        XCTAssertEqual(items[1].path, "\(root)/notes.txt")
        XCTAssertEqual(items[2].isDirectory, false, "a symlink is not a directory")
        XCTAssertEqual(items[2].size, 8)
        XCTAssertNotNil(items[1].modifiedDate)
    }

    func testParseListingFiltersDotEntriesAndHeader() {
        let output = """
        total 4
        drwxrwx--x 3 root sdcard_rw 4096 2026-10-16 10:30 .
        drwxrwx--x 2 root sdcard_rw 4096 2026-10-16 10:29 ..
        -rw-rw---- 1 root sdcard_rw    0 2026-10-16 10:31 empty
        """

        let items = StorageItem.parseListing(output, parentPath: root)
        XCTAssertEqual(items.map(\.name), ["empty"])
    }

    func testParseListingHandlesNamesWithSpacesAndSeconds() {
        let output = "-rw-rw---- 1 root sdcard_rw 42 2026-10-16 10:31:59 my holiday photo.jpg"
        let items = StorageItem.parseListing(output, parentPath: root)
        XCTAssertEqual(items.map(\.name), ["my holiday photo.jpg"])
        XCTAssertNotNil(items[0].modifiedDate)
    }

    func testParseListingIgnoresUnparseableLines() {
        let items = StorageItem.parseListing("garbage line\n\nnot a listing", parentPath: root)
        XCTAssertTrue(items.isEmpty)
    }

    // MARK: - Path validation

    func testNormalizeAcceptsRootAndChildren() throws {
        XCTAssertEqual(try StorageService.normalizeStoragePath(root), root)
        XCTAssertEqual(
            try StorageService.normalizeStoragePath("\(root)/Sub Folder/file.txt"),
            "\(root)/Sub Folder/file.txt"
        )
        XCTAssertEqual(
            try StorageService.normalizeStoragePath("\(root)/./a//b"),
            "\(root)/a/b",
            "redundant separators and '.' are normalised away"
        )
    }

    func testNormalizeRejectsTraversal() {
        XCTAssertThrowsError(try StorageService.normalizeStoragePath("\(root)/../escape")) { error in
            guard case StorageError.invalidPath = error else { return XCTFail("got \(error)") }
        }
    }

    func testNormalizeRejectsRelativeAndOutsideRoot() {
        XCTAssertThrowsError(try StorageService.normalizeStoragePath("PixelDesktop/file")) { error in
            guard case StorageError.invalidPath = error else { return XCTFail("got \(error)") }
        }
        XCTAssertThrowsError(try StorageService.normalizeStoragePath("/sdcard/DCIM/photo.jpg")) { error in
            guard case StorageError.invalidPath = error else { return XCTFail("got \(error)") }
        }
        XCTAssertThrowsError(try StorageService.normalizeStoragePath("/")) { error in
            guard case StorageError.invalidPath = error else { return XCTFail("got \(error)") }
        }
    }

    func testNormalizeRejectsControlCharacters() {
        XCTAssertThrowsError(try StorageService.normalizeStoragePath("\(root)/bad\nname")) { error in
            guard case StorageError.invalidPath = error else { return XCTFail("got \(error)") }
        }
    }

    func testShellQuoteNeutralisesMetacharacters() {
        XCTAssertEqual(StorageService.shellQuote("plain"), "'plain'")
        XCTAssertEqual(StorageService.shellQuote("a'b"), #"'a'\''b'"#)
        // A hostile name stays a single quoted argument; the `;` never reaches the device shell.
        XCTAssertEqual(
            StorageService.shellQuote("\(root)/x; rm -rf /"),
            "'\(root)/x; rm -rf /'"
        )
    }

    // MARK: - list

    func testListIssuesLsAndParsesOutput() async throws {
        let transport = MockTransport()
        await transport.setShellResponse(
            "ls -la '\(root)'",
            TransportResult(exitCode: 0, stdout: "drwxrwx--x 2 root sdcard_rw 4096 2026-10-16 10:30 Docs", stderr: "")
        )

        let items = try await makeService(transport).list(path: root)

        XCTAssertEqual(items.map(\.name), ["Docs"])
        let issuedLs = await issued(transport, [serial, "shell", "ls -la '\(root)'"])
        XCTAssertTrue(issuedLs)
    }

    func testListMapsPermissionDenied() async {
        let transport = MockTransport()
        await transport.setShellResponse(
            "ls -la '\(root)/private'",
            TransportResult(exitCode: 1, stdout: "", stderr: "ls: \(root)/private: Permission denied")
        )

        let error = await expectStorageError { try await makeService(transport).list(path: "\(root)/private") }
        XCTAssertEqual(error, .permissionDenied(path: "\(root)/private"))
    }

    func testListMapsMissingFolder() async {
        let transport = MockTransport()
        await transport.setShellResponse(
            "ls -la '\(root)/gone'",
            TransportResult(exitCode: 2, stdout: "", stderr: "ls: \(root)/gone: No such file or directory")
        )

        let error = await expectStorageError { try await makeService(transport).list(path: "\(root)/gone") }
        XCTAssertEqual(error, .fileNotFound(path: "\(root)/gone"))
    }

    // MARK: - Mutations

    func testDeleteIssuesRecursiveRm() async throws {
        let transport = MockTransport()
        try await makeService(transport).delete(path: "\(root)/old folder")
        let issuedRm = await issued(transport, [serial, "shell", "rm -rf '\(root)/old folder'"])
        XCTAssertTrue(issuedRm)
    }

    func testDeleteRefusesStorageRoot() async {
        let transport = MockTransport()
        let error = await expectStorageError { try await makeService(transport).delete(path: root) }
        guard case .invalidPath = error else { return XCTFail("got \(String(describing: error))") }
        let issuedRootRm = await issued(transport, [serial, "shell", "rm -rf '\(root)'"])
        XCTAssertFalse(issuedRootRm)
    }

    func testMkdirIssuesMkdirP() async throws {
        let transport = MockTransport()
        try await makeService(transport).mkdir(path: "\(root)/New Folder")
        let issuedMkdir = await issued(transport, [serial, "shell", "mkdir -p '\(root)/New Folder'"])
        XCTAssertTrue(issuedMkdir)
    }

    func testRenameIssuesMv() async throws {
        let transport = MockTransport()
        try await makeService(transport).rename(from: "\(root)/a.txt", to: "\(root)/b.txt")
        let issuedMv = await issued(transport, [serial, "shell", "mv '\(root)/a.txt' '\(root)/b.txt'"])
        XCTAssertTrue(issuedMv)
    }

    func testMkdirMapsDiskFull() async {
        let transport = MockTransport()
        await transport.setShellResponse(
            "mkdir -p '\(root)/x'",
            TransportResult(exitCode: 1, stdout: "", stderr: "mkdir: no space left on device")
        )

        let error = await expectStorageError { try await makeService(transport).mkdir(path: "\(root)/x") }
        XCTAssertEqual(error, .diskFull(path: "\(root)/x"))
    }

    // MARK: - upload

    func testUploadPushesFileAndReportsCompletion() async throws {
        let transport = MockTransport()
        let directory = try makeTemporaryDirectory()
        let local = try writeLocalFile("hello", in: directory, named: "hello.txt")
        let remote = "\(root)/hello.txt"
        await transport.setShellResponse(
            "stat -c %s '\(remote)'",
            TransportResult(exitCode: 0, stdout: "5", stderr: "")
        )

        let recorder = ProgressRecorder()
        try await makeService(transport).upload(
            localPath: local,
            remotePath: remote,
            onProgress: { recorder.record($0) }
        )

        let issuedPush = await issued(transport, [serial, "push", local, remote])
        XCTAssertTrue(issuedPush)
        XCTAssertEqual(recorder.last?.direction, .upload)
        XCTAssertEqual(recorder.last?.transferredBytes, 5)
        XCTAssertEqual(recorder.last?.fractionCompleted, 1.0)
    }

    func testUploadRejectsMissingLocalSource() async {
        let transport = MockTransport()
        let error = await expectStorageError {
            try await makeService(transport).upload(
                localPath: "/definitely/not/here.txt",
                remotePath: "\(root)/here.txt"
            )
        }
        XCTAssertEqual(error, .fileNotFound(path: "/definitely/not/here.txt"))
    }

    func testUploadRejectsPathOutsideRoot() async {
        let transport = MockTransport()
        let directory = try? makeTemporaryDirectory()
        let local = (try? writeLocalFile("x", in: directory ?? FileManager.default.temporaryDirectory, named: "x.txt")) ?? "/x"

        let error = await expectStorageError {
            try await makeService(transport).upload(localPath: local, remotePath: "/sdcard/elsewhere.txt")
        }
        guard case .invalidPath = error else { return XCTFail("got \(String(describing: error))") }
    }

    func testUploadReportsSizeMismatch() async throws {
        let transport = MockTransport()
        let directory = try makeTemporaryDirectory()
        let local = try writeLocalFile("hello", in: directory, named: "hello.txt")
        let remote = "\(root)/hello.txt"
        // The device reports a different size than what we pushed — a truncated transfer.
        await transport.setShellResponse(
            "stat -c %s '\(remote)'",
            TransportResult(exitCode: 0, stdout: "3", stderr: "")
        )

        let error = await expectStorageError {
            try await makeService(transport).upload(localPath: local, remotePath: remote)
        }
        guard case .transferFailed = error else { return XCTFail("got \(String(describing: error))") }
    }

    func testUploadMapsPushFailure() async throws {
        let transport = MockTransport()
        let directory = try makeTemporaryDirectory()
        let local = try writeLocalFile("hello", in: directory, named: "hello.txt")
        await transport.setPushResult(TransportResult(exitCode: 1, stdout: "", stderr: "adb: device offline"))

        let error = await expectStorageError {
            try await makeService(transport).upload(localPath: local, remotePath: "\(root)/hello.txt")
        }
        XCTAssertEqual(error, .deviceOffline)
    }

    // MARK: - download

    func testDownloadPullsFileIntoDestination() async throws {
        let transport = MockTransport()
        let directory = try makeTemporaryDirectory()
        let destination = directory.appendingPathComponent("pulled.txt").path
        let remote = "\(root)/pulled.txt"
        await transport.setShellResponse(
            "stat -c %s '\(remote)'",
            TransportResult(exitCode: 0, stdout: "5", stderr: "")
        )
        await transport.setPullContent("hello")

        let recorder = ProgressRecorder()
        try await makeService(transport).download(
            remotePath: remote,
            localPath: destination,
            onProgress: { recorder.record($0) }
        )

        let issuedPull = await issued(transport, [serial, "pull", remote, destination])
        XCTAssertTrue(issuedPull)
        XCTAssertEqual(try String(contentsOfFile: destination, encoding: .utf8), "hello")
        XCTAssertEqual(recorder.last?.direction, .download)
        XCTAssertEqual(recorder.last?.fractionCompleted, 1.0)
    }

    func testDownloadMissingRemoteFileIsNotFound() async throws {
        let transport = MockTransport()
        let directory = try makeTemporaryDirectory()
        let destination = directory.appendingPathComponent("pulled.txt").path

        let error = await expectStorageError {
            try await makeService(transport).download(
                remotePath: "\(root)/missing.txt",
                localPath: destination
            )
        }
        XCTAssertEqual(error, .fileNotFound(path: "\(root)/missing.txt"))
    }

    // MARK: - disk space

    func testDiskSpaceParsesKilobyteOutput() async {
        let transport = MockTransport()
        await transport.setShellResponse(
            "df -k '\(root)'",
            TransportResult(
                exitCode: 0,
                stdout: """
                Filesystem     1K-blocks      Used Available Use% Mounted on
                /dev/block/dm-6 114882560   1153024 113729536   1% /data
                """,
                stderr: ""
            )
        )

        let space = await makeService(transport).diskSpace()
        XCTAssertEqual(space?.total, 114_882_560 * 1024)
        XCTAssertEqual(space?.used, 1_153_024 * 1024)
    }

    func testParseDiskSpaceHandlesHumanOutput() {
        let output = """
        Filesystem      Size  Used Avail Use% Mounted on
        /dev/block/dm-6  110G  1.1G  109G   1% /data
        """
        let space = StorageService.parseDiskSpace(output)
        XCTAssertEqual(space?.total, StorageService.parseHumanBytes("110G"))
        XCTAssertEqual(space?.used, StorageService.parseHumanBytes("1.1G"))
    }

    func testParseDiskSpaceReturnsNilOnGarbage() {
        XCTAssertNil(StorageService.parseDiskSpace("not df output"))
    }

    func testDiskSpaceReturnsNilWhenCommandFails() async {
        let transport = MockTransport()
        await transport.setShellResponse(
            "df -k '\(root)'",
            TransportResult(exitCode: 1, stdout: "", stderr: "df: not found")
        )
        let space = await makeService(transport).diskSpace()
        XCTAssertNil(space)
    }

    // MARK: - error classification

    func testClassifyMapsKnownSignatures() {
        XCTAssertEqual(
            StorageError.classify(command: "rm", exitCode: 1, stderr: "Permission denied", path: "/p"),
            .permissionDenied(path: "/p")
        )
        XCTAssertEqual(
            StorageError.classify(command: "rm", exitCode: 1, stderr: "No space left on device", path: "/p"),
            .diskFull(path: "/p")
        )
        XCTAssertEqual(
            StorageError.classify(command: "ls", exitCode: 2, stderr: "No such file or directory", path: "/p"),
            .fileNotFound(path: "/p")
        )
        XCTAssertEqual(
            StorageError.classify(command: "ls", exitCode: 1, stderr: "error: device offline", path: "/p"),
            .deviceOffline
        )
        guard case .commandFailed = StorageError.classify(
            command: "ls", exitCode: 7, stderr: "something unexpected", path: "/p"
        ) else {
            return XCTFail("unrecognised stderr must fall through to commandFailed")
        }
    }

    // MARK: - progress poller

    func testPollerEmitsSamplesAndFinalValue() async {
        let transfer = StorageTransfer(
            direction: .upload,
            localPath: "/tmp/local",
            remotePath: "\(root)/remote",
            totalBytes: 10
        )
        let probe = ProbeSequence(values: [0, 4, 10])
        let recorder = ProgressRecorder()

        let poller = StorageTransferPoller(
            transfer: transfer,
            interval: 0.01,
            probe: { await probe.next() },
            onProgress: { recorder.record($0) }
        )

        poller.start()
        // Let the loop run at least a couple of intervals.
        try? await Task.sleep(nanoseconds: 80_000_000)
        await poller.stop(transferredBytes: 10)

        XCTAssertGreaterThanOrEqual(recorder.samples.count, 2)
        XCTAssertEqual(recorder.last?.fractionCompleted, 1.0)
        XCTAssertEqual(recorder.last?.isComplete, true)
    }

    func testPollerAbortEmitsNoFinalSample() async {
        let transfer = StorageTransfer(
            direction: .download,
            localPath: "/tmp/local",
            remotePath: "\(root)/remote",
            totalBytes: 100
        )
        let recorder = ProgressRecorder()

        let poller = StorageTransferPoller(
            transfer: transfer,
            interval: 0.01,
            probe: { 0 },
            onProgress: { recorder.record($0) }
        )

        poller.start()
        await poller.abort()

        XCTAssertFalse(recorder.samples.contains { $0.fractionCompleted == 1.0 && $0.totalBytes == 100 && $0.transferredBytes > 0 })
    }

    func testZeroByteTransferIsComplete() {
        let progress = StorageTransferProgress(
            direction: .upload,
            transferredBytes: 0,
            totalBytes: 0
        )
        XCTAssertEqual(progress.fractionCompleted, 1.0)
        XCTAssertTrue(progress.isComplete)
    }
}

// MARK: - Test doubles

/// Thread-safe capture of progress samples emitted from the polling task.
private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [StorageTransferProgress] = []

    func record(_ progress: StorageTransferProgress) {
        lock.lock()
        storage.append(progress)
        lock.unlock()
    }

    var samples: [StorageTransferProgress] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var last: StorageTransferProgress? {
        samples.last
    }
}

/// A deterministic probe that yields a fixed sequence, repeating the last value.
private actor ProbeSequence {
    private let values: [UInt64]
    private var index = 0

    init(values: [UInt64]) {
        self.values = values
    }

    func next() -> UInt64 {
        guard !values.isEmpty else { return 0 }
        let value = values[min(index, values.count - 1)]
        index += 1
        return value
    }
}

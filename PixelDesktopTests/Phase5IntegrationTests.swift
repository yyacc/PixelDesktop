import XCTest
import Foundation
@testable import PixelDesktop

// MARK: - Phase 5: Integration & End-to-End Testing

final class EndToEndFileWorkflowTests: XCTestCase {
    private let serial = "PIXEL7A_TEST"
    private let root = StorageService.storageRoot

    private func makeService(_ transport: MockTransport) -> StorageService {
        StorageService(deviceSerial: serial, transport: transport, progressPollInterval: 0.01)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("E2EWorkflow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testCompleteFileLifecycle() async throws {
        let transport = MockTransport()
        let service = makeService(transport)
        let localDir = try makeTemporaryDirectory()

        try await service.mkdir(path: "\(root)/TestFolder")
        let issuedMkdir = await transport.invocations.contains {
            $0.arguments == [serial, "shell", "mkdir -p '\(root)/TestFolder'"]
        }
        XCTAssertTrue(issuedMkdir)

        let localFile = localDir.appendingPathComponent("test.txt")
        try "Hello, Pixel 7a!".write(to: localFile, atomically: true, encoding: .utf8)
        let remoteFile = "\(root)/TestFolder/test.txt"

        await transport.setShellResponse(
            "stat -c %s '\(remoteFile)'",
            TransportResult(exitCode: 0, stdout: "16", stderr: "")
        )

        try await service.upload(localPath: localFile.path, remotePath: remoteFile)
        let issuedPush = await transport.invocations.contains {
            $0.arguments == [serial, "push", localFile.path, remoteFile]
        }
        XCTAssertTrue(issuedPush)

        await transport.setShellResponse(
            "ls -la '\(root)/TestFolder'",
            TransportResult(
                exitCode: 0,
                stdout: "-rw-rw---- 1 root sdcard_rw 16 2026-10-16 10:31 test.txt",
                stderr: ""
            )
        )
        let items = try await service.list(path: "\(root)/TestFolder")
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].name, "test.txt")
        XCTAssertEqual(items[0].size, 16)

        let downloadDest = localDir.appendingPathComponent("downloaded.txt").path
        await transport.setShellResponse(
            "stat -c %s '\(remoteFile)'",
            TransportResult(exitCode: 0, stdout: "16", stderr: "")
        )
        await transport.setPullContent("Hello, Pixel 7a!")

        try await service.download(remotePath: remoteFile, localPath: downloadDest)
        let downloadedContent = try String(contentsOfFile: downloadDest, encoding: .utf8)
        XCTAssertEqual(downloadedContent, "Hello, Pixel 7a!")

        try await service.rename(from: remoteFile, to: "\(root)/TestFolder/renamed.txt")
        let issuedMv = await transport.invocations.contains {
            $0.arguments == [serial, "shell", "mv '\(root)/TestFolder/test.txt' '\(root)/TestFolder/renamed.txt'"]
        }
        XCTAssertTrue(issuedMv)

        try await service.delete(path: "\(root)/TestFolder/renamed.txt")
        let issuedRm = await transport.invocations.contains {
            $0.arguments == [serial, "shell", "rm -rf '\(root)/TestFolder/renamed.txt'"]
        }
        XCTAssertTrue(issuedRm)
    }
}

@MainActor
final class TransportPriorityIntegrationTests: XCTestCase {
    private let wiredSerial = "3A8C1F5D0B2E4726"
    private let wirelessSerial = "192.168.1.4:37351"

    private func makeDevice(serial: String, state: DeviceState = .device) -> AndroidDevice {
        AndroidDevice(
            id: serial, serialNumber: serial, deviceCodename: "lynx",
            marketingName: "Pixel 7a", manufacturer: "Google",
            androidVersion: "16", apiLevel: 36, architecture: "arm64-v8a",
            supportedABIs: ["arm64-v8a"], state: state
        )
    }

    private func freshDefaults() -> UserDefaults {
        let suite = "TransportPriorityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testUSBPriorityOverWiFi() async {
        let transport = MockTransport()
        await transport.setDeviceList([
            makeDevice(serial: wirelessSerial),
            makeDevice(serial: wiredSerial)
        ])
        let manager = DeviceManager(
            transport: transport,
            pathMonitor: MockNetworkPathMonitor(),
            defaults: freshDefaults(),
            reconnectScheduler: ReconnectScheduler(maxAttempts: 1, baseDelay: 0.01, maxDelay: 0.01)
        )
        await manager.refreshDevices()
        XCTAssertEqual(manager.transportState, TransportState(mode: .wired, deviceSerial: wiredSerial))
    }

    func testFallsBackToWirelessWhenUSBUnplugged() async {
        let transport = MockTransport()
        await transport.setDeviceList([makeDevice(serial: wirelessSerial)])
        let manager = DeviceManager(
            transport: transport,
            pathMonitor: MockNetworkPathMonitor(),
            defaults: freshDefaults(),
            reconnectScheduler: ReconnectScheduler(maxAttempts: 1, baseDelay: 0.01, maxDelay: 0.01)
        )
        await manager.refreshDevices()
        XCTAssertEqual(manager.transportState, TransportState(mode: .wireless, deviceSerial: wirelessSerial))

        await transport.setDeviceList([
            makeDevice(serial: wirelessSerial),
            makeDevice(serial: wiredSerial)
        ])
        await manager.refreshDevices()
        XCTAssertEqual(manager.transportState, TransportState(mode: .wired, deviceSerial: wiredSerial))

        await transport.setDeviceList([makeDevice(serial: wirelessSerial)])
        await manager.refreshDevices()
        XCTAssertEqual(manager.transportState, TransportState(mode: .wireless, deviceSerial: wirelessSerial))
    }
}

@MainActor
final class ConnectionPersistenceIntegrationTests: XCTestCase {
    private let wirelessSerial = "192.168.1.4:37351"
    private let wirelessEndpoint = WirelessEndpoint(host: "192.168.1.4", port: 37351)

    private func makeDevice(serial: String) -> AndroidDevice {
        AndroidDevice(
            id: serial, serialNumber: serial, deviceCodename: "lynx",
            marketingName: "Pixel 7a", manufacturer: "Google",
            androidVersion: "16", apiLevel: 36, architecture: "arm64-v8a",
            supportedABIs: ["arm64-v8a"], state: .device
        )
    }

    private func freshDefaults() -> UserDefaults {
        let suite = "PersistenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testWirelessConnectionPersistsAcrossRestart() async {
        let defaults = freshDefaults()

        let transport1 = MockTransport()
        await transport1.setDeviceList([makeDevice(serial: wirelessSerial)])
        let manager1 = DeviceManager(
            transport: transport1,
            pathMonitor: MockNetworkPathMonitor(),
            defaults: defaults,
            reconnectScheduler: ReconnectScheduler(maxAttempts: 1, baseDelay: 0.01, maxDelay: 0.01)
        )
        await manager1.refreshDevices()
        XCTAssertTrue(manager1.transportState?.mode == .wireless)

        let transport2 = MockTransport()
        await transport2.setDeviceList([])
        let manager2 = DeviceManager(
            transport: transport2,
            pathMonitor: MockNetworkPathMonitor(),
            defaults: defaults,
            reconnectScheduler: ReconnectScheduler(maxAttempts: 1, baseDelay: 0.01, maxDelay: 0.01)
        )

        XCTAssertEqual(manager2.connectionManager.rememberedWirelessEndpoint, wirelessEndpoint)

        await transport2.setDeviceList([makeDevice(serial: wirelessSerial)])
        await manager2.refreshDevices()
        XCTAssertTrue(manager2.transportState?.mode == .wireless)
        XCTAssertTrue(manager2.transportState?.deviceSerial == wirelessSerial)
    }
}

final class StorageEdgeCaseTests: XCTestCase {
    private let serial = "PIXEL7A_TEST"
    private let root = StorageService.storageRoot

    private func makeService(_ transport: MockTransport) -> StorageService {
        StorageService(deviceSerial: serial, transport: transport, progressPollInterval: 0.01)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("EdgeCaseTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testConnectionLossDuringUpload() async {
        let transport = MockTransport()
        let localDir = try! makeTemporaryDirectory()
        let localFile = localDir.appendingPathComponent("test.txt")
        try! "data".write(to: localFile, atomically: true, encoding: .utf8)

        await transport.setPushResult(
            TransportResult(exitCode: 1, stdout: "", stderr: "adb: device offline")
        )

        let error = await expectStorageError {
            try await makeService(transport).upload(
                localPath: localFile.path,
                remotePath: "\(root)/test.txt"
            )
        }
        XCTAssertEqual(error, .deviceOffline)
    }

    func testConnectionLossDuringDownload() async {
        let transport = MockTransport()
        let localDir = try! makeTemporaryDirectory()
        let dest = localDir.appendingPathComponent("downloaded.txt").path

        await transport.setShellResponse(
            "stat -c %s '\(root)/file.txt'",
            TransportResult(exitCode: 0, stdout: "100", stderr: "")
        )
        await transport.setPullResult(
            TransportResult(exitCode: 1, stdout: "", stderr: "adb: device offline")
        )

        let error = await expectStorageError {
            try await makeService(transport).download(
                remotePath: "\(root)/file.txt",
                localPath: dest
            )
        }
        XCTAssertEqual(error, .deviceOffline)
    }

    func testDiskFullOnUpload() async {
        let transport = MockTransport()
        let localDir = try! makeTemporaryDirectory()
        let localFile = localDir.appendingPathComponent("bigfile.bin")
        try! "x".write(to: localFile, atomically: true, encoding: .utf8)

        await transport.setPushResult(
            TransportResult(exitCode: 1, stdout: "", stderr: "adb: no space left on device")
        )

        let error = await expectStorageError {
            try await makeService(transport).upload(
                localPath: localFile.path,
                remotePath: "\(root)/bigfile.bin"
            )
        }
        XCTAssertEqual(error, .diskFull(path: "\(root)/bigfile.bin"))
    }

    func testPermissionDeniedOnDelete() async {
        let transport = MockTransport()
        await transport.setShellResponse(
            "rm -rf '\(root)/protected'",
            TransportResult(exitCode: 1, stdout: "", stderr: "rm: /sdcard/PixelDesktop/protected: Permission denied")
        )

        let error = await expectStorageError {
            try await makeService(transport).delete(path: "\(root)/protected")
        }
        XCTAssertEqual(error, .permissionDenied(path: "\(root)/protected"))
    }

    func testPermissionDeniedOnList() async {
        let transport = MockTransport()
        await transport.setShellResponse(
            "ls -la '\(root)/private'",
            TransportResult(exitCode: 1, stdout: "", stderr: "ls: /sdcard/PixelDesktop/private: Permission denied")
        )

        let error = await expectStorageError {
            try await makeService(transport).list(path: "\(root)/private")
        }
        XCTAssertEqual(error, .permissionDenied(path: "\(root)/private"))
    }

    func testDiskFullOnMkdir() async {
        let transport = MockTransport()
        await transport.setShellResponse(
            "mkdir -p '\(root)/newfolder'",
            TransportResult(exitCode: 1, stdout: "", stderr: "mkdir: no space left on device")
        )

        let error = await expectStorageError {
            try await makeService(transport).mkdir(path: "\(root)/newfolder")
        }
        XCTAssertEqual(error, .diskFull(path: "\(root)/newfolder"))
    }

    func testFileNotFoundOnDownload() async {
        let transport = MockTransport()
        let localDir = try! makeTemporaryDirectory()
        let dest = localDir.appendingPathComponent("downloaded.txt").path

        await transport.setShellResponse(
            "stat -c %s '\(root)/missing.txt'",
            TransportResult(exitCode: 1, stdout: "", stderr: "stat: /sdcard/PixelDesktop/missing.txt: No such file or directory")
        )

        let error = await expectStorageError {
            try await makeService(transport).download(
                remotePath: "\(root)/missing.txt",
                localPath: dest
            )
        }
        XCTAssertEqual(error, .fileNotFound(path: "\(root)/missing.txt"))
    }

    func testFileNotFoundOnUpload() async {
        let transport = MockTransport()

        let error = await expectStorageError {
            try await makeService(transport).upload(
                localPath: "/definitely/not/here.txt",
                remotePath: "\(root)/here.txt"
            )
        }
        XCTAssertEqual(error, .fileNotFound(path: "/definitely/not/here.txt"))
    }

    func testStorageRootCannotBeDeleted() async {
        let transport = MockTransport()

        let error = await expectStorageError {
            try await makeService(transport).delete(path: root)
        }
        guard case .invalidPath = error else { return XCTFail("got \(String(describing: error))") }
    }

    func testStorageRootCannotBeRenamed() async {
        let transport = MockTransport()

        let error = await expectStorageError {
            try await makeService(transport).rename(from: root, to: "\(root)/newroot")
        }
        guard case .invalidPath = error else { return XCTFail("got \(String(describing: error))") }
    }

    func testPathTraversalRejected() async {
        let transport = MockTransport()

        let error = await expectStorageError {
            try await makeService(transport).list(path: "\(root)/../../etc/passwd")
        }
        guard case .invalidPath = error else { return XCTFail("got \(String(describing: error))") }
    }

    func testPathOutsideRootRejected() async {
        let transport = MockTransport()

        let error = await expectStorageError {
            try await makeService(transport).list(path: "/sdcard/DCIM/photo.jpg")
        }
        guard case .invalidPath = error else { return XCTFail("got \(String(describing: error))") }
    }
}

final class LargeFileTransferTests: XCTestCase {
    private let serial = "PIXEL7A_TEST"
    private let root = StorageService.storageRoot

    private func makeService(_ transport: MockTransport) -> StorageService {
        StorageService(deviceSerial: serial, transport: transport, progressPollInterval: 0.01)
    }

    func testLargeFileUploadWithProgress() async throws {
        let transport = MockTransport()
        let localDir = try FileManager.default.temporaryDirectory
            .appendingPathComponent("LargeFileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)

        let localFile = localDir.appendingPathComponent("large.bin")
        let chunk = Data(repeating: 0xAB, count: 1024 * 1024)
        var data = Data()
        for _ in 0..<10 {
            data.append(chunk)
        }
        try data.write(to: localFile)

        let remotePath = "\(root)/large.bin"
        let expectedSize = 10 * 1024 * 1024

        await transport.setShellResponse(
            "stat -c %s '\(remotePath)'",
            TransportResult(exitCode: 0, stdout: "\(expectedSize)", stderr: "")
        )

        let recorder = ProgressRecorder()
        try await makeService(transport).upload(
            localPath: localFile.path,
            remotePath: remotePath,
            onProgress: { recorder.record($0) }
        )

        XCTAssertEqual(recorder.last?.direction, .upload)
        XCTAssertEqual(recorder.last?.transferredBytes, UInt64(expectedSize))
        XCTAssertEqual(recorder.last?.fractionCompleted, 1.0)
        XCTAssertEqual(recorder.last?.isComplete, true)
    }

    func testLargeFileDownloadWithProgress() async throws {
        let transport = MockTransport()
        let localDir = try FileManager.default.temporaryDirectory
            .appendingPathComponent("LargeFileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)

        let remotePath = "\(root)/large.bin"
        let expectedSize = 10 * 1024 * 1024

        await transport.setShellResponse(
            "stat -c %s '\(remotePath)'",
            TransportResult(exitCode: 0, stdout: "\(expectedSize)", stderr: "")
        )

        let dest = localDir.appendingPathComponent("downloaded.bin").path
        let chunk = Data(repeating: 0xCD, count: 1024 * 1024)
        var data = Data()
        for _ in 0..<10 {
            data.append(chunk)
        }
        try data.write(to: URL(fileURLWithPath: dest))

        let recorder = ProgressRecorder()
        try await makeService(transport).download(
            remotePath: remotePath,
            localPath: dest,
            onProgress: { recorder.record($0) }
        )

        XCTAssertEqual(recorder.last?.direction, .download)
        XCTAssertEqual(recorder.last?.fractionCompleted, 1.0)
        XCTAssertEqual(recorder.last?.isComplete, true)
    }
}

@MainActor
final class AppStateStorageIntegrationTests: XCTestCase {
    private let serial = "PIXEL7A_TEST"
    private let root = StorageService.storageRoot

    private func makeDevice(serial: String) -> AndroidDevice {
        AndroidDevice(
            id: serial, serialNumber: serial, deviceCodename: "lynx",
            marketingName: "Pixel 7a", manufacturer: "Google",
            androidVersion: "16", apiLevel: 36, architecture: "arm64-v8a",
            supportedABIs: ["arm64-v8a"], state: .device
        )
    }

    func testAppStateLoadsStorageItems() async throws {
        let transport = MockTransport()
        await transport.setDeviceList([makeDevice(serial: serial)])
        await transport.setShellResponse(
            "ls -la '\(root)'",
            TransportResult(
                exitCode: 0,
                stdout: "-rw-rw---- 1 root sdcard_rw 42 2026-10-16 10:31 readme.txt",
                stderr: ""
            )
        )

        let manager = DeviceManager(
            transport: transport,
            pathMonitor: MockNetworkPathMonitor(),
            defaults: UserDefaults(suiteName: "AppStateStorage-\(UUID().uuidString)")!,
            reconnectScheduler: ReconnectScheduler(maxAttempts: 1, baseDelay: 0.01, maxDelay: 0.01)
        )
        let appState = AppState(deviceManager: manager, transport: transport)
        await appState.refreshDevices()

        try await appState.loadStorageItems(path: root)

        XCTAssertEqual(appState.storageItems.count, 1)
        XCTAssertEqual(appState.storageItems[0].name, "readme.txt")
        XCTAssertEqual(appState.storageItems[0].size, 42)
    }

    func testAppStateUploadFile() async throws {
        let transport = MockTransport()
        await transport.setDeviceList([makeDevice(serial: serial)])

        let localDir = try FileManager.default.temporaryDirectory
            .appendingPathComponent("AppStateUpload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
        let localFile = localDir.appendingPathComponent("upload.txt")
        try "test content".write(to: localFile, atomically: true, encoding: .utf8)

        let remotePath = "\(root)/upload.txt"
        await transport.setShellResponse(
            "stat -c %s '\(remotePath)'",
            TransportResult(exitCode: 0, stdout: "12", stderr: "")
        )

        let manager = DeviceManager(
            transport: transport,
            pathMonitor: MockNetworkPathMonitor(),
            defaults: UserDefaults(suiteName: "AppStateUpload-\(UUID().uuidString)")!,
            reconnectScheduler: ReconnectScheduler(maxAttempts: 1, baseDelay: 0.01, maxDelay: 0.01)
        )
        let appState = AppState(deviceManager: manager, transport: transport)
        await appState.refreshDevices()

        try await appState.uploadFile(localPath: localFile.path, remotePath: remotePath)

        XCTAssertNil(appState.storageError)
    }

    func testAppStateDeleteItem() async {
        let transport = MockTransport()
        await transport.setDeviceList([makeDevice(serial: serial)])
        await transport.setShellResponse(
            "rm -rf '\(root)/old.txt'",
            TransportResult(exitCode: 0, stdout: "", stderr: "")
        )

        let manager = DeviceManager(
            transport: transport,
            pathMonitor: MockNetworkPathMonitor(),
            defaults: UserDefaults(suiteName: "AppStateDelete-\(UUID().uuidString)")!,
            reconnectScheduler: ReconnectScheduler(maxAttempts: 1, baseDelay: 0.01, maxDelay: 0.01)
        )
        let appState = AppState(deviceManager: manager, transport: transport)
        await appState.refreshDevices()

        await appState.deleteStorageItem(path: "\(root)/old.txt")
        XCTAssertNil(appState.storageError)
    }

    func testAppStateCreateFolder() async {
        let transport = MockTransport()
        await transport.setDeviceList([makeDevice(serial: serial)])
        await transport.setShellResponse(
            "mkdir -p '\(root)/NewFolder'",
            TransportResult(exitCode: 0, stdout: "", stderr: "")
        )

        let manager = DeviceManager(
            transport: transport,
            pathMonitor: MockNetworkPathMonitor(),
            defaults: UserDefaults(suiteName: "AppStateMkdir-\(UUID().uuidString)")!,
            reconnectScheduler: ReconnectScheduler(maxAttempts: 1, baseDelay: 0.01, maxDelay: 0.01)
        )
        let appState = AppState(deviceManager: manager, transport: transport)
        await appState.refreshDevices()

        await appState.createStorageFolder(path: "\(root)/NewFolder")
        XCTAssertNil(appState.storageError)
    }

    func testAppStateShowsErrorWhenOffline() async {
        let transport = MockTransport()
        await transport.setDeviceList([])

        let manager = DeviceManager(
            transport: transport,
            pathMonitor: MockNetworkPathMonitor(),
            defaults: UserDefaults(suiteName: "AppStateOffline-\(UUID().uuidString)")!,
            reconnectScheduler: ReconnectScheduler(maxAttempts: 1, baseDelay: 0.01, maxDelay: 0.01)
        )
        let appState = AppState(deviceManager: manager, transport: transport)
        await appState.refreshDevices()

        await appState.loadStorageItems(path: root)
        // When offline, storageService is nil, so items are empty and error is nil
        XCTAssertTrue(appState.storageItems.isEmpty)
        XCTAssertNil(appState.storageError)
    }
}

final class ZenoRemovalVerificationTests: XCTestCase {
    func testNoZenoReferencesInSwiftSources() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let pixelDesktopDir = projectRoot.appendingPathComponent("PixelDesktop/PixelDesktop")
        let enumerator = FileManager.default.enumerator(
            at: pixelDesktopDir,
            includingPropertiesForKeys: [.isDirectoryKey]
        )

        var swiftFiles: [URL] = []
        while let file = enumerator?.nextObject() as? URL {
            if file.pathExtension == "swift" {
                swiftFiles.append(file)
            }
        }

        XCTAssertFalse(swiftFiles.isEmpty, "should find Swift source files")

        for file in swiftFiles {
            let content = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(
                content.contains("Zeno"),
                "Zeno reference found in \(file.lastPathComponent)"
            )
        }
    }

    func testZenoDirectoryRemoved() {
        let zenoDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("PixelDesktop/PixelDesktop/Observability")

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: zenoDir.path),
            "Observability directory should have been removed"
        )
    }
}

// MARK: - Test doubles

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

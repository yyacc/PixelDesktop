//
//  TermuxNodeInstaller.swift
//  PixelDesktop
//
//  Phase 1 (C1) — Termux + llama-server provisioning on the Pixel 7a.
//
//  Scope: package identity for `com.termux`, install from a supplied APK path,
//  bootstrap storage, and install the `llama-cpp` package inside Termux.
//  Deliberately narrow: no arbitrary package management, no data clearing.
//
//  ## Channel status — verified on real hardware 2026-10-24
//
//  `installedState` and `installTermux` work: both are plain `adb` operations.
//
//  `bootstrapStorage` and `installLlamaCpp` are **not reachable**, for the same reason
//  `LlamaServerService.start` is not — see that file's channel table. Termux 0.118 has no
//  `com.termux.execute` extra and its `RunCommandService` needs a permission the adb shell
//  cannot hold. Both are kept as the correct *request* rather than deleted, because the
//  unblock is a user action on the device, not a code change.
//

import Foundation

/// Result of checking whether Termux is installed.
enum TermuxInstallState: Equatable, Sendable {
    case notInstalled
    case installed(versionCode: Int)
}

protocol TermuxNodeInstallerProtocol: Sendable {
    func installedState(deviceSerial: String, timeout: TimeInterval) async throws -> TermuxInstallState
    func installTermux(deviceSerial: String, apkPath: String, timeout: TimeInterval) async throws -> TransportResult
    func bootstrapStorage(deviceSerial: String, timeout: TimeInterval) async throws -> TransportResult
    func installLlamaCpp(deviceSerial: String, timeout: TimeInterval) async throws -> TransportResult
}

struct ADBTermuxNodeInstaller: TermuxNodeInstallerProtocol {
    private let transport: TransportProtocol
    static let termuxPackageName = "com.termux"

    init(transport: TransportProtocol) {
        self.transport = transport
    }

    func installedState(deviceSerial: String, timeout: TimeInterval) async throws -> TermuxInstallState {
        let result = try await transport.shell(
            deviceSerial: deviceSerial,
            command: "dumpsys package \(Self.termuxPackageName)",
            timeout: timeout
        )
        // versionCode parse
        for line in result.stdout.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("versionCode=") {
                let value = trimmed.dropFirst("versionCode=".count)
                if let code = Int(value.split(separator: " ").first ?? "") {
                    return .installed(versionCode: code)
                }
            }
        }
        return .notInstalled
    }

    func installTermux(deviceSerial: String, apkPath: String, timeout: TimeInterval) async throws -> TransportResult {
        try await transport.execute(
            command: "-s",
            arguments: [deviceSerial, "install", "-r", apkPath],
            timeout: timeout
        )
    }

    func bootstrapStorage(deviceSerial: String, timeout: TimeInterval) async throws -> TransportResult {
        // The real action is `termux-setup-storage` *inside* Termux, which raises a system
        // permission dialog the host cannot answer. Bringing the activity forward is all that
        // is reachable; the grant itself is a device-side step.
        try await transport.shell(
            deviceSerial: deviceSerial,
            command: "am start -n com.termux/.app.TermuxActivity && sleep 1 && input keyevent 4",
            timeout: timeout
        )
    }

    func installLlamaCpp(deviceSerial: String, timeout: TimeInterval) async throws -> TransportResult {
        // Blocked channel — see the header. The package itself installs fine once Termux can
        // be commanded (verified: `llama-cpp` 0.7.0, `apt-get install -y llama-cpp`).
        try await transport.shell(
            deviceSerial: deviceSerial,
            command: "am start -n com.termux/.app.TermuxActivity -e com.termux.execute \"pkg install -y llama-cpp\"",
            timeout: timeout
        )
    }
}

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
        // termux-setup-storage grants storage permission; run via am start
        try await transport.shell(
            deviceSerial: deviceSerial,
            command: "am start -n com.termux/.app.TermuxActivity && sleep 1 && input keyevent 4",
            timeout: timeout
        )
    }

    func installLlamaCpp(deviceSerial: String, timeout: TimeInterval) async throws -> TransportResult {
        // Run pkg install inside Termux via run-as / am (best-effort; Termux must be running)
        try await transport.shell(
            deviceSerial: deviceSerial,
            command: "am start -n com.termux/.app.TermuxActivity -e com.termux.execute \"pkg install -y llama-cpp\"",
            timeout: timeout
        )
    }
}

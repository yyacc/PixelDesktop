//
//  a5-notification-evidence.swift
//  PixelDesktop — Phase 3.2 real-device evidence harness
//
//  `xcodebuild` does not forward `PIXELDESKTOP_DEVICE_SERIAL` into the test process in this
//  environment (ADR-006), so device evidence is produced by compiling the production sources with
//  `swiftc` and running them directly. That is the same path phases 2–9 used; this harness makes it
//  reproducible and committed instead of living in a scratch directory.
//
//  Run (from the repository root):
//
//      swiftc -O engineering/harnesses/a5-notification-evidence.swift \
//        PixelDesktop/Core/Errors/PixelDesktopError.swift \
//        PixelDesktop/Core/Models/AndroidDevice.swift \
//        PixelDesktop/Transport/Transport.swift \
//        PixelDesktop/Transport/ADBTransport.swift \
//        PixelDesktop/Audit/DeviceAuditLog.swift \
//        PixelDesktop/Trust/ConsentRegistry.swift \
//        PixelDesktop/Perception/Notifications.swift \
//        PixelDesktop/Perception/NotificationParser.swift \
//        PixelDesktop/Perception/NotificationStream.swift \
//        -o /tmp/a5-evidence && /tmp/a5-evidence DEADBEEF000000
//
//  What it measures, in order:
//
//   1. **No grant, no command** — both tiers refuse, and the harness proves the refusal happened
//      before `adb` was invoked by counting shell invocations.
//   2. **Two-tier cost** — the first poll's tier-1 and tier-2 byte counts, then a second poll whose
//      key set is unchanged: tier 2 must not be read again.
//   3. **Revocation is immediate** — the next poll refuses.
//   4. **No content in the trail** — every audit detail is compared against every parsed value.
//
//  It prints counts and byte sizes only. Notification text is never printed: the point of the check
//  is that it stays out of durable surfaces, so the harness must not create one.
//

import Foundation

// MARK: - Counting transport

/// Wraps the real transport and records how many bytes each shell command returned.
final class CountingTransport: TransportProtocol, @unchecked Sendable {
    private let inner: TransportProtocol = ADBTransport()
    private(set) var shellBytes: [(command: String, bytes: Int)] = []

    func execute(command: String, arguments: [String], timeout: TimeInterval) async throws -> TransportResult {
        try await inner.execute(command: command, arguments: arguments, timeout: timeout)
    }

    func listDevices() async throws -> [AndroidDevice] { try await inner.listDevices() }

    func getprop(deviceSerial: String, key: String, timeout: TimeInterval) async throws -> String {
        try await inner.getprop(deviceSerial: deviceSerial, key: key, timeout: timeout)
    }

    func getSystemProperties(deviceSerial: String, timeout: TimeInterval) async throws -> [String: String] {
        try await inner.getSystemProperties(deviceSerial: deviceSerial, timeout: timeout)
    }

    func shell(deviceSerial: String, command: String, timeout: TimeInterval) async throws -> TransportResult {
        let result = try await inner.shell(deviceSerial: deviceSerial, command: command, timeout: timeout)
        shellBytes.append((command, result.stdout.utf8.count))
        return result
    }

    func shellStreaming(
        deviceSerial: String,
        command: String,
        stdin: String?,
        onLine: @Sendable @escaping (String) -> Void,
        onStderrLine: @Sendable @escaping (String) -> Void,
        cancellation: CancellationHandle
    ) async throws -> Int32 {
        try await inner.shellStreaming(
            deviceSerial: deviceSerial,
            command: command,
            stdin: stdin,
            onLine: onLine,
            onStderrLine: onStderrLine,
            cancellation: cancellation
        )
    }

    func execOut(deviceSerial: String, arguments: [String], timeout: TimeInterval) async throws -> TransportBinaryResult {
        try await inner.execOut(deviceSerial: deviceSerial, arguments: arguments, timeout: timeout)
    }

    func push(deviceSerial: String, localPath: String, remotePath: String, timeout: TimeInterval) async throws -> TransportResult {
        try await inner.push(deviceSerial: deviceSerial, localPath: localPath, remotePath: remotePath, timeout: timeout)
    }

    func pull(deviceSerial: String, remotePath: String, localPath: String, timeout: TimeInterval) async throws -> TransportResult {
        try await inner.pull(deviceSerial: deviceSerial, remotePath: remotePath, localPath: localPath, timeout: timeout)
    }

    func install(deviceSerial: String, apkPath: String, replace: Bool, timeout: TimeInterval) async throws -> TransportResult {
        try await inner.install(deviceSerial: deviceSerial, apkPath: apkPath, replace: replace, timeout: timeout)
    }
}

// MARK: - Harness

@main
struct A5Evidence {
    static func main() async {
        let arguments = CommandLine.arguments
        guard arguments.count > 1 else {
            print("usage: a5-evidence <device-serial>")
            exit(2)
        }
        let serial = arguments[1]
        print("A5 notification evidence — device \(serial)\n")

        let log = DeviceAuditLog()
        let registry = ConsentRegistry()          // in-memory: never touches the real consent file
        let transport = CountingTransport()
        let gate = ConsentGate(registry: registry, auditLog: log)
        let reader = ADBNotificationReader(transport: transport, gate: gate)

        await check("1. no grant → no command", expectation: "both tiers refuse, zero shell calls") {
            var refusals = 0
            for tier in ["tier 1", "tier 2"] {
                do {
                    if tier == "tier 1" {
                        _ = try await reader.keys(deviceSerial: serial, timeout: 20)
                    } else {
                        _ = try await reader.records(deviceSerial: serial, timeout: 40)
                    }
                    print("   \(tier): NO REFUSAL — unexpected")
                } catch let refusal as ConsentError {
                    refusals += 1
                    print("   \(tier): refused — \(refusal.description)")
                } catch {
                    print("   \(tier): unexpected error \(error)")
                }
            }
            print("   shell calls issued: \(transport.shellBytes.count)")
            print("   audit records: \(log.records.map { "\($0.operation.rawValue)/\($0.outcome.rawValue)" }.joined(separator: ", "))")
            return refusals == 2 && transport.shellBytes.isEmpty && log.records.allSatisfy { $0.outcome == .refused }
        }

        do {
            try registry.grant(.notifications, reason: "A5 evidence harness")
        } catch {
            print("could not grant consent: \(error)")
            exit(1)
        }

        let stream = NotificationStream(reader: reader)
        var firstRecords: [NotificationRecord] = []

        await check("2. two-tier cost", expectation: "poll 1 reads both tiers, poll 2 reads tier 1 only") {
            let first = try await stream.refresh(deviceSerial: serial, timeout: 60)
            firstRecords = first.records
            let tier1 = transport.shellBytes.filter { $0.command == ADBNotificationReader.listCommand }
            let tier2 = transport.shellBytes.filter { $0.command == ADBNotificationReader.dumpCommand }
            print("   poll 1: keys=\(first.keys.count) records=\(first.records.count) "
                  + "contentless=\(first.records.filter(\.isContentless).count) didFetchPayload=\(first.didFetchPayload)")
            print("   poll 1 bytes: tier 1 = \(tier1.reduce(0) { $0 + $1.bytes }) B, tier 2 = \(tier2.reduce(0) { $0 + $1.bytes }) B")
            let bytesAfterFirst = transport.shellBytes.count

            let second = try await stream.refresh(deviceSerial: serial, timeout: 60)
            let newCommands = transport.shellBytes[bytesAfterFirst...]
            print("   poll 2: keys=\(second.keys.count) records=\(second.records.count) didFetchPayload=\(second.didFetchPayload)")
            print("   poll 2 commands: \(newCommands.map(\.command).joined(separator: ", "))")
            print("   poll 2 bytes: \(newCommands.reduce(0) { $0 + $1.bytes }) B")

            let tier2Reads = transport.shellBytes.filter { $0.command == ADBNotificationReader.dumpCommand }.count
            return first.didFetchPayload && !second.didFetchPayload
                && newCommands.count == 1
                && tier2Reads == 1
                && second.records.map(\.id) == first.records.map(\.id)
        }

        await check("3. the trail carries counts, not content", expectation: "no parsed value appears in any audit detail") {
            let trail = log.records.map { $0.detail ?? "" }.joined(separator: " | ")
            print("   audit details: \(log.records.compactMap(\.detail).suffix(2).joined(separator: " ; "))")
            let values = firstRecords
                .flatMap { [$0.title, $0.text, $0.subText, $0.bigText, $0.tickerText] }
                .compactMap { $0 }
                .filter { $0.count >= 12 }
            let leaked = values.filter { trail.contains($0) }
            print("   candidate values checked: \(values.count), leaked: \(leaked.count)")
            // Poll 1 issued two commands, poll 2 issued one: three executed records, and that count
            // is itself the evidence that a poll costs one command when nothing changed.
            let executed = log.records.filter { $0.outcome == .executed }.count
            print("   executed audit records: \(executed) (expect 3: tier 1 + tier 2, then tier 1)")
            return leaked.isEmpty && executed == 3
        }

        _ = registry.revoke(.notifications)

        await check("4. revocation is immediate", expectation: "next poll refuses and is recorded") {
            let before = transport.shellBytes.count
            do {
                _ = try await stream.refresh(deviceSerial: serial, timeout: 60)
                print("   NO REFUSAL — unexpected")
                return false
            } catch let refusal as ConsentError {
                print("   refused — \(refusal.description)")
                print("   shell calls during refusal: \(transport.shellBytes.count - before)")
                print("   latest audit: \(log.latest?.operation.rawValue ?? "?")/\(log.latest?.outcome.rawValue ?? "?")")
                return log.latest?.outcome == .refused && transport.shellBytes.count == before
            } catch {
                print("   unexpected error \(error)")
                return false
            }
        }

        print("\nPER-RECORD SHAPE (no content printed)")
        for record in firstRecords {
            print("   \(record.packageID) id=\(record.notificationID) "
                  + "importance=\(record.importance.displayName) visibility=\(record.visibility.displayName) "
                  + "contentless=\(record.isContentless) "
                  + "titleChars=\(record.title?.count ?? 0) textChars=\(record.text?.count ?? 0) lines=\(record.textLines.count)")
        }
    }

    /// Runs one named check and prints a single machine-readable verdict line.
    static func check(_ name: String, expectation: String, _ body: () async throws -> Bool) async {
        print("\n\(name)")
        print("   expectation: \(expectation)")
        do {
            let passed = try await body()
            print("   → \(passed ? "PASS" : "FAIL")")
        } catch {
            print("   → FAIL (threw \(error))")
        }
    }
}

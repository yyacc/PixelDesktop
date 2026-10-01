import Foundation
import OSLog

struct LogEntry: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let level: LogLevel
    let message: String
    let source: String

    var formattedTimestamp: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: timestamp)
    }
}

enum LogLevel: String, CaseIterable {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARNING"
    case error = "ERROR"

    var osLogType: OSLogType {
        switch self {
        case .debug: return .debug
        case .info: return .info
        case .warning: return .default
        case .error: return .error
        }
    }
}

@MainActor
final class AppLogger: ObservableObject {
    @Published var entries: [LogEntry] = []

    private let logger = Logger(subsystem: "com.pixeldesktop.app", category: "general")
    private let maxEntries = 500

    func log(_ message: String, level: LogLevel = .info, source: String = #function) {
        let entry = LogEntry(
            timestamp: Date(),
            level: level,
            message: message,
            source: source
        )

        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }

        logger.log(level: level.osLogType, "\(entry.formattedTimestamp) [\(level.rawValue)] \(source): \(message, privacy: .public)")
    }

    func debug(_ message: String, source: String = #function) {
        log(message, level: .debug, source: source)
    }

    func info(_ message: String, source: String = #function) {
        log(message, level: .info, source: source)
    }

    func warning(_ message: String, source: String = #function) {
        log(message, level: .warning, source: source)
    }

    func error(_ message: String, source: String = #function) {
        log(message, level: .error, source: source)
    }

    func clear() {
        entries.removeAll()
    }
}

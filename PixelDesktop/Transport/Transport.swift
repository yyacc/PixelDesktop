import Foundation

protocol TransportProtocol: AnyObject, Sendable {
    func execute(command: String, arguments: [String], timeout: TimeInterval) async throws -> TransportResult
    func listDevices() async throws -> [PixelDevice]
}

struct TransportResult: Equatable {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var isSuccess: Bool {
        exitCode == 0
    }
}

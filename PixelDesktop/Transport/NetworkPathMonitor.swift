import Foundation
import Network

/// The coarse network availability signal the connection layer acts on.
///
/// Deliberately not a detailed `NWPath` — the connection layer cannot act on
/// interface kind, cost, or DNS capability; it can only use "a network exists",
/// which is what satisfies an `adb connect` attempt.
enum NetworkPathStatus: Equatable {
    case satisfied
    case unsatisfied

    var message: String {
        switch self {
        case .satisfied: return "satisfied"
        case .unsatisfied: return "unsatisfied"
        }
    }
}

/// Seam over `NWPathMonitor` so connection logic is testable without a live network.
///
/// Conformers push every change (and importantly the **initial** observation, which
/// `NWPathMonitor` delivers shortly after `start()`) into `onUpdate`. The test double
/// invokes the same callback manually, so the wiring under test is the real one.
protocol NetworkPathMonitoring: AnyObject {
    var onUpdate: (@Sendable (NetworkPathStatus) -> Void)? { get set }
    func start()
    func cancel()
}

/// Live `NWPathMonitor` implementation.
///
/// Delivers on an arbitrary queue; `ConnectionManager` hops to the main actor, so
/// production code never mutates state off-actor here.
final class NetworkPathMonitor: NetworkPathMonitoring {
    private let monitor = NWPathMonitor()
    private var started = false

    var onUpdate: (@Sendable (NetworkPathStatus) -> Void)?

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            self?.onUpdate?(path.status == .satisfied ? .satisfied : .unsatisfied)
        }
        monitor.start(queue: DispatchQueue(label: "pixeldesktop.networkpath"))
    }

    func cancel() {
        monitor.cancel()
    }
}

import Foundation

/// The transport seam `ConnectionManager` actually needs.
///
/// Deliberately narrow — `listDevices` and `connect` — so `ConnectionManager` stays
/// unit-testable against a mock and never reaches the pushing/pulling/streaming
/// primitives. `ADBTransport` conforms because `adb connect` is just another adb
/// invocation; a type that only satisfies `TransportProtocol` (e.g. a test double)
/// can simply be *not* passed, and `DeviceManager` falls back to a null object.
protocol ConnectionTransporting: Sendable {
    func listDevices() async throws -> [AndroidDevice]
    func connect(host: String, port: Int) async throws
}

/// A no-op connection transport for contexts where reconnecting is impossible.
///
/// `DeviceManager` installs this when the transport it was given is not
/// `ConnectionTransporting`-capable (a test double, or a non-ADB transport).
/// Every connect attempt fails immediately and clearly, so "reconnect is
/// unavailable" is never silently misreported as "connected".
struct NullConnectionTransport: ConnectionTransporting {
    func listDevices() async throws -> [AndroidDevice] { [] }

    func connect(host: String, port: Int) async throws {
        throw PixelDesktopError.adbTransportError(
            "No reconnect-capable transport installed"
        )
    }
}

/// The connection record kept in `UserDefaults` across app restarts.
///
/// Persisted is **what was last known**, never a claim of being connected: the
/// `mode`/`serial` fields describe the last selected transport, `wirelessEndpoint`
/// is what auto-reconnect re-dials, and `updatedAt` marks when that was observed.
/// On startup the endpoint is *loaded for reconnection*, not *restored as state* —
/// the app must still verify the device responds (via discovery) before reporting
/// a connected transport.
struct PersistedConnectionState: Codable, Equatable {
    let lastMode: TransportMode?
    let lastSerial: String?
    let wirelessEndpoint: WirelessEndpoint?
    let updatedAt: Date
}

/// Pure exponential-backoff schedule for reconnect attempts.
///
/// Delay before attempt *n* is `baseDelay * 2^(n-1)`, clamped to `maxDelay`.
/// With the standard 1 s base that yields 1 s, 2 s, 4 s, 8 s, 16 s across five
/// attempts (spec: "exponential backoff, max 5 retries"). Values are injectable
/// so tests run the identical loop in milliseconds.
struct ReconnectScheduler: Equatable, Sendable {
    /// Total reconnect attempts before the sequence is exhausted.
    let maxAttempts: Int

    /// Delay before the first attempt; doubles on each later attempt.
    let baseDelay: TimeInterval

    /// Upper bound on any single wait.
    let maxDelay: TimeInterval

    static let standard = ReconnectScheduler(
        maxAttempts: 5,
        baseDelay: 1.0,
        maxDelay: 30.0
    )

    /// Delay before zero-based attempt `attempt` (0…maxAttempts-1).
    /// Attempt 0 waits `baseDelay`; the math is pure so it is directly testable.
    func delay(beforeAttempt attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return baseDelay }
        return min(baseDelay * pow(2.0, Double(attempt)), maxDelay)
    }

    func isExhausted(afterAttempt attempt: Int) -> Bool {
        attempt >= maxAttempts
    }
}

/// Owns transport selection, connection persistence and auto-reconnect.
///
/// ## Lifecycle
///
/// `DeviceManager` drives it from its discovery poll: every successful device
/// listing is passed to `observe(devices:)`, which (1) selects the transport with
/// USB > WiFi priority, (2) remembers the wireless endpoint while it is connected —
/// that is what gets persisted to `UserDefaults`, and (3) when nothing is connected
/// but a remembered endpoint exists, starts the reconnect sequence.
///
/// A reconnect sequence is a single Task: wait, `adb connect`, re-list devices —
/// re-listing lands back in `observe`, which stops the sequence the moment a device
/// is seen (success) or lets it run to exhaustion (failure). Each reappearance of
/// the poll finding nothing does **not** spawn a second sequence: one is already
/// running, while a completed one has recorded exhaustion and needs no restart.
///
/// ## What persistence is for
///
/// Android Wireless Debugging publishes a new port whenever it is re-enabled, and
/// ADB connections do not survive app restarts. The remembered endpoint is therefore
/// a *last known address*, used to re-dial after a restart or a network change —
/// never proof of a live device, which is why load-on-start does not restore
/// `transportState`.
@MainActor
final class ConnectionManager: ObservableObject {

    /// `UserDefaults` key for the persisted connection state.
    static let persistedStateKey = "PixelDesktop.connectionState.v1"

    private let connectionTransport: ConnectionTransporting
    private let logger: AppLogger
    private let defaults: UserDefaults
    private let scheduler: ReconnectScheduler

    /// Invoked after a `connect` succeeded, so the consumer can re-list devices.
    /// `DeviceManager` supplies `refreshDevices`; absence in tests disables re-listing.
    var refreshHook: (@MainActor () async -> Void)?

    /// The transport currently selected, or `nil` when offline.
    @Published private(set) var transportState: TransportState?

    /// Whether a reconnect sequence is currently running or has stalled exhausted.
    @Published private(set) var isReconnecting = false

    /// Zero-based count of connect attempts in the running sequence (reset on success).
    @Published private(set) var reconnectAttempt = 0

    /// Why the most recent attempt failed, for status UI output.
    @Published private(set) var lastReconnectFailure: String?

    /// The rememberable endpoint (persisted snapshot drives reconnects).
    private var rememberedEndpoint: WirelessEndpoint?

    private var reconnectTask: Task<Void, Never>?
    private var sequenceExhausted = false

    init(
        transport: ConnectionTransporting,
        logger: AppLogger,
        defaults: UserDefaults = .standard,
        scheduler: ReconnectScheduler = .standard,
        pathMonitor: NetworkPathMonitoring? = nil
    ) {
        self.connectionTransport = transport
        self.logger = logger
        self.defaults = defaults
        self.scheduler = scheduler

        loadPersistedState()
        attach(pathMonitor: pathMonitor)
    }

    // MARK: - Selection + observation

    /// Re-selects transport from a fresh device listing and switches reconnect on/off.
    ///
    /// Called **only** on a successful listing (`listDevices` did not throw): a failed
    /// listing is not evidence that the device disappeared, and must not tear down
    /// the currently selected transport.
    func observe(devices: [AndroidDevice]) {
        let state = TransportSelector.select(devices)
        transportState = state

        switch state {
        case .some(let selected):
            sequenceExhausted = false
            lastReconnectFailure = nil

            if selected.isWireless {
                // Remember the endpoint while it is verifiably connected, so the next
                // loss can re-dial it. Recording an endpoint we never saw connected
                // would let auto-reconnect hammer an address that was never valid.
                if let endpoint = WirelessEndpoint.parse(selected.deviceSerial) {
                    rememberedEndpoint = endpoint
                }
            }

            // Persist the full snapshot on any connected state: the endpoint is what
            // reconnect needs, the mode/serial keep the last-known record informative
            // across restarts.
            persist()

            stopReconnect()

        case nil:
            if rememberedEndpoint != nil {
                beginReconnectIfNeeded()
            }
        }
    }

    // MARK: - Network change detection

    private func attach(pathMonitor: NetworkPathMonitoring?) {
        guard let pathMonitor else { return }
        pathMonitor.onUpdate = { [weak self] status in
            Task { @MainActor [weak self] in
                self?.networkPathChanged(status)
            }
        }
        pathMonitor.start()
    }

    /// A network coming *up* is the only actionable direction — a path going down
    /// cannot be recovered from inside the app.
    ///
    /// A `.satisfied` event is new input: it clears ANY prior exhaustion so a fresh
    /// network means a fresh chance at the remembered endpoint (for example the
    /// phone finished re-enabling Wireless Debugging on a new subnet, or the Mac
    /// moved to the network where the phone lives).
    func networkPathChanged(_ status: NetworkPathStatus) {
        logger.info("Network path status: \(status.message)", source: "ConnectionManager.networkPathChanged")

        guard status == .satisfied else { return }
        if sequenceExhausted {
            sequenceExhausted = false
            logger.info("Network change clears reconnect exhaustion", source: "ConnectionManager.networkPathChanged")
        }
        guard transportState == nil else { return }
        guard rememberedEndpoint != nil else { return }

        beginReconnectIfNeeded()
    }

    // MARK: - Reconnect

    /// Starts one reconnect sequence if none is running and attempts remain possible.
    ///
    /// Guarded so that (a) observation leading repeatedly to an offline listing does
    /// not stack sequences, and (b) a single exhausted run is terminal — no retry
    /// happens without new input (a reconnect-network event or a fresh observe that
    /// re-sees a device clears `sequenceExhausted`).
    private func beginReconnectIfNeeded() {
        guard reconnectTask == nil else { return }
        guard !sequenceExhausted else { return }
        guard let endpoint = rememberedEndpoint else { return }

        isReconnecting = true
        reconnectAttempt = 0
        lastReconnectFailure = nil
        logger.warning(
            "Offline — attempting wireless reconnect to \(endpoint.address)",
            source: "ConnectionManager.beginReconnect"
        )

        reconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runReconnectSequence(endpoint: endpoint)
            self.reconnectTask = nil
        }
    }

    private func runReconnectSequence(endpoint: WirelessEndpoint) async {
        for attempt in 0..<scheduler.maxAttempts {
            let delay = scheduler.delay(beforeAttempt: attempt)
            reconnectAttempt = attempt

            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if Task.isCancelled { return }

            do {
                try await connectionTransport.connect(host: endpoint.host, port: endpoint.port)
                logger.info(
                    "Reconnect attempt \(attempt + 1)/\(scheduler.maxAttempts) connected — re-listing devices",
                    source: "ConnectionManager.runReconnectSequence"
                )
                await refreshHook?()

                if transportState != nil {
                    // observe() re-selected a transport and stopped the sequence.
                    return
                }
                lastReconnectFailure = "\(endpoint.address) did not reappear in the listing after a successful connect"
            } catch {
                lastReconnectFailure = (error as? PixelDesktopError)?.description
                    ?? error.localizedDescription
                logger.warning(
                    "Reconnect attempt \(attempt + 1)/\(scheduler.maxAttempts) failed: \(lastReconnectFailure ?? "")",
                    source: "ConnectionManager.runReconnectSequence"
                )
            }
        }

        sequenceExhausted = true
        isReconnecting = false
        reconnectAttempt = scheduler.maxAttempts
        logger.error(
            "Reconnect to \(endpoint.address) exhausted \(scheduler.maxAttempts) attempts",
            source: "ConnectionManager.runReconnectSequence"
        )
    }

    private func stopReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        isReconnecting = false
        reconnectAttempt = 0
    }

    /// Stops the reconnect sequence without clearing remembered state (used on teardown).
    func stop() {
        stopReconnect()
    }

    // MARK: - Persistence

    private func persist() {
        let state = PersistedConnectionState(
            lastMode: transportState?.mode,
            lastSerial: transportState?.deviceSerial,
            wirelessEndpoint: rememberedEndpoint,
            updatedAt: Date()
        )

        do {
            let data = try JSONEncoder().encode(state)
            defaults.set(data, forKey: Self.persistedStateKey)
        } catch {
            // Loss of persistence is degraded operation, never a crash: auto-reconnect
            // simply starts one cycle later, from the next device sighting.
            logger.warning(
                "Failed to persist connection state: \(error.localizedDescription)",
                source: "ConnectionManager.persist"
            )
        }
    }

    private func loadPersistedState() {
        guard let data = defaults.data(forKey: Self.persistedStateKey) else { return }

        do {
            let state = try JSONDecoder().decode(PersistedConnectionState.self, from: data)
            rememberedEndpoint = state.wirelessEndpoint
        } catch {
            // Unreadable state is harmless: discard it and rediscover.
            defaults.removeObject(forKey: Self.persistedStateKey)
            logger.warning(
                "Discarding unreadable persisted connection state: \(error.localizedDescription)",
                source: "ConnectionManager.loadPersistedState"
            )
        }
    }

    /// The endpoint currently remembered (for tests and diagnostics only).
    var rememberedWirelessEndpoint: WirelessEndpoint? {
        rememberedEndpoint
    }
}

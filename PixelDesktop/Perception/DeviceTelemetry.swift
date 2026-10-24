import Foundation

/// Thermal status, on Android's own scale.
///
/// The seven values and their order come from `android.os.Temperature` as reported by
/// `dumpsys thermalservice` (`Thermal Status: N`). The scale is Android's, not ours — a
/// mirrored enum would be a second source of truth for a number the platform owns, so the
/// raw value is preserved and only the *threshold* is ours.
///
/// **ADR-018** fixes the alert threshold at `>= 4 (CRITICAL)`: rnz runs an external cooler and
/// accepts throttling, so anything below CRITICAL is recorded but is not an alert. The
/// threshold is a named constant rather than an inline `>= 4` so the contract and the
/// comparison cannot drift apart.
enum ThermalStatus: Int, CaseIterable, Sendable, Comparable, Codable {
    case none = 0
    case light = 1
    case moderate = 2
    case severe = 3
    case critical = 4
    case emergency = 5
    case shutdown = 6

    /// ADR-018: the only threshold this project alerts on.
    static let alertThreshold: ThermalStatus = .critical

    /// Whether this status warrants an alert. Enforced by `TelemetryHistory`, not merely
    /// declared — see its `thermalAlerts` accessor.
    var isAlert: Bool { self >= Self.alertThreshold }

    var label: String {
        switch self {
        case .none: return "none"
        case .light: return "light"
        case .moderate: return "moderate"
        case .severe: return "severe"
        case .critical: return "critical"
        case .emergency: return "emergency"
        case .shutdown: return "shutdown"
        }
    }

    static func < (lhs: ThermalStatus, rhs: ThermalStatus) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// One thermal zone as the device's HAL reports it.
struct ThermalZone: Equatable, Sendable {
    /// The HAL's own name, e.g. `CPU`, `GPU`, `BATTERY`. Not normalised — the device is the
    /// authority on what zones it has.
    let name: String
    let temperatureCelsius: Double
}

/// Battery state from `dumpsys battery`.
///
/// Every field is optional because each line is independently absent on some builds; a
/// partial read is reported as partial rather than defaulted to a plausible value.
struct BatteryTelemetry: Equatable, Sendable {
    let levelPercent: Int?
    let statusLabel: String?
    let temperatureCelsius: Double?
    let voltageMillivolts: Int?
}

/// Physical memory from `/proc/meminfo`.
struct MemoryTelemetry: Equatable, Sendable {
    let totalBytes: UInt64
    let availableBytes: UInt64

    var usedBytes: UInt64 { totalBytes > availableBytes ? totalBytes - availableBytes : 0 }

    /// Fraction of memory in use, clamped to `0...1`. Zero-total is treated as zero-used
    /// rather than dividing by zero.
    var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(usedBytes) / Double(totalBytes))
    }
}

/// Filesystem usage from `df`.
struct StorageTelemetry: Equatable, Sendable {
    let usedBytes: UInt64
    let totalBytes: UInt64

    var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(usedBytes) / Double(totalBytes))
    }
}

/// One complete telemetry read.
///
/// The sub-reads are independent: a device that answers `dumpsys battery` but refuses
/// `dumpsys thermalservice` yields a sample with `thermalStatus == nil` and a populated
/// battery. That is the honest representation — an absent field means "not read", which is a
/// different claim from "read and zero".
struct DeviceTelemetry: Equatable, Sendable {
    let capturedAt: Date
    let battery: BatteryTelemetry?
    let thermalStatus: ThermalStatus?
    let thermalZones: [ThermalZone]
    let memory: MemoryTelemetry?
    let storage: StorageTelemetry?

    /// The hottest zone the HAL reported, or `nil` when no zone parsed.
    ///
    /// This is the value the thermal history tracks: a single status integer is coarse, and
    /// the handoff recorded the LITTLE cluster at 67 °C while idle-charging — a temperature
    /// that status alone would not have shown.
    var hottestZoneCelsius: Double? {
        thermalZones.map(\.temperatureCelsius).max()
    }

    /// Whether this read crossed the ADR-018 alert threshold.
    var isThermalAlert: Bool {
        thermalStatus?.isAlert ?? false
    }

    /// Reduces the read to the fields worth keeping over time.
    ///
    /// History is a *series*, so it stores scalars rather than whole reads: keeping every
    /// `DeviceTelemetry` would retain zone lists and storage figures that are not part of the
    /// thermal trend and would grow the buffer for no benefit.
    func sample() -> TelemetrySample {
        TelemetrySample(
            capturedAt: capturedAt,
            thermalStatus: thermalStatus,
            hottestZoneCelsius: hottestZoneCelsius,
            batteryLevelPercent: battery?.levelPercent,
            batteryTemperatureCelsius: battery?.temperatureCelsius,
            memoryUsedFraction: memory?.usedFraction
        )
    }
}

/// One point in the telemetry time series.
struct TelemetrySample: Equatable, Sendable, Codable {
    let capturedAt: Date
    let thermalStatus: ThermalStatus?
    let hottestZoneCelsius: Double?
    let batteryLevelPercent: Int?
    let batteryTemperatureCelsius: Double?
    let memoryUsedFraction: Double?
}

/// A bounded, append-only telemetry history.
///
/// **Why a ring buffer.** ADR-018 / proposal Q9 make thermal history the constraint on
/// sustained inference, and a phone that is polled for hours would otherwise grow this
/// without limit. The capacity is explicit and the oldest sample is dropped on overflow.
///
/// **The alert contract is enforced here.** `thermalAlerts` filters samples that crossed the
/// threshold, and `latestAlert` returns the most recent one — both are read by
/// `AppState`/`TelemetryView`, so `ThermalStatus.isAlert` is not a declaration nobody consults.
struct TelemetryHistory: Equatable, Sendable {
    /// How many samples are retained. One sample per poll; at a 10 s cadence this is 100
    /// minutes of history, which is longer than any inference job this project has measured.
    static let defaultCapacity = 600

    let capacity: Int
    private(set) var samples: [TelemetrySample] = []

    init(capacity: Int = TelemetryHistory.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    mutating func append(_ sample: TelemetrySample) {
        samples.append(sample)
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
    }

    mutating func append(_ telemetry: DeviceTelemetry) {
        append(telemetry.sample())
    }

    mutating func removeAll() {
        samples.removeAll()
    }

    /// Samples that crossed the ADR-018 threshold, oldest first.
    var thermalAlerts: [TelemetrySample] {
        samples.filter { $0.thermalStatus?.isAlert == true }
    }

    /// The most recent alert, or `nil` when the device has never crossed the threshold in the
    /// retained window.
    var latestAlert: TelemetrySample? { thermalAlerts.last }

    /// The peak thermal status seen in the retained window.
    var peakThermalStatus: ThermalStatus? {
        samples.compactMap(\.thermalStatus).max()
    }

    /// The peak zone temperature seen in the retained window.
    var peakZoneCelsius: Double? {
        samples.compactMap(\.hottestZoneCelsius).max()
    }

    var isEmpty: Bool { samples.isEmpty }
}

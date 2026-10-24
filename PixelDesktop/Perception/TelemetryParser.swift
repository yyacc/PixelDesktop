import Foundation

/// Pure parsers for the text the device emits for telemetry.
///
/// Separated from `ADBDeviceTelemetry` so every one of them is testable with no device
/// attached and no transport. This matters more than usual here: `dumpsys` output is
/// **not a stable API**. It differs across Android versions, across OEMs, and in places
/// across builds of the same version, so the parsing rules are the part most likely to be
/// wrong and the part cheapest to pin with fixtures.
///
/// Each parser returns `nil` rather than a fabricated default when the input does not match.
/// A battery at "0 %" and a battery whose line was absent are different facts, and a default
/// would erase the difference.
enum TelemetryParser {

    // MARK: - dumpsys battery

    /// Parses the `key: value` lines of `dumpsys battery`.
    ///
    /// Measured on the Pixel 7a (Android 16):
    ///
    ///     Current Battery Service state:
    ///       AC powered: false
    ///       USB powered: true
    ///       status: 2
    ///       health: 2
    ///       present: true
    ///       level: 100
    ///       scale: 100
    ///       voltage: 4400
    ///       temperature: 307
    ///
    /// `temperature` is in **tenths of a degree Celsius** — 307 is 30.7 °C. Treating it as
    /// whole degrees would understate a hot battery by an order of magnitude, which is exactly
    /// the reading this phase exists to catch.
    static func parseBattery(_ raw: String) -> BatteryTelemetry? {
        let fields = keyValueLines(raw)
        guard !fields.isEmpty else { return nil }

        let level = fields["level"].flatMap { Int($0) }
        let voltage = fields["voltage"].flatMap { Int($0) }
        let temperatureTenths = fields["temperature"].flatMap { Int($0) }

        let status = fields["status"].flatMap { Int($0) }.map(statusLabel)

        // Nothing parsed at all is a failure to read, not an empty battery.
        if level == nil, voltage == nil, temperatureTenths == nil, status == nil {
            return nil
        }

        return BatteryTelemetry(
            levelPercent: level,
            statusLabel: status,
            temperatureCelsius: temperatureTenths.map { Double($0) / 10.0 },
            voltageMillivolts: voltage
        )
    }

    /// Maps `BatteryManager` status integers to words.
    ///
    /// The mapping is Android's (`BatteryManager.BATTERY_STATUS_*`). An unrecognised value is
    /// reported as `"unknown(N)"` rather than dropped, so a newer platform constant shows up
    /// as itself instead of silently reading as "unknown".
    static func statusLabel(_ raw: Int) -> String {
        switch raw {
        case 1: return "unknown"
        case 2: return "charging"
        case 3: return "discharging"
        case 4: return "not charging"
        case 5: return "full"
        default: return "unknown(\(raw))"
        }
    }

    // MARK: - dumpsys thermalservice

    /// Parses the overall thermal status.
    ///
    /// The line is `Thermal Status: N`. `-1` means the service has no reading yet and is
    /// treated as absent rather than as `none`, because "no reading" is not "cool".
    static func parseThermalStatus(_ raw: String) -> ThermalStatus? {
        for line in raw.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("thermal status:") else { continue }
            let value = trimmed.split(separator: ":").last
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard let number = Int(value), number >= 0 else { return nil }
            return ThermalStatus(rawValue: number)
        }
        return nil
    }

    /// Parses the `Temperature{...}` lines from the HAL section.
    ///
    /// The HAL prints each zone as:
    ///
    ///     Temperature{mValue=36.5, mType=0, mName=CPU, mStatus=0}
    ///
    /// Field order is the platform's `toString()`, but this parser does not depend on it:
    /// it locates `mValue` and `mName` independently inside each brace group. A zone with no
    /// parsable value is skipped rather than reported as 0 °C.
    static func parseThermalZones(_ raw: String) -> [ThermalZone] {
        var zones: [ThermalZone] = []

        for line in raw.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("Temperature{"), trimmed.hasSuffix("}") else { continue }

            let body = trimmed.dropFirst("Temperature{".count).dropLast()

            guard let valueText = field(in: body, named: "mValue"),
                  let value = Double(valueText) else { continue }
            guard let name = field(in: body, named: "mName"), !name.isEmpty else { continue }

            zones.append(ThermalZone(name: name, temperatureCelsius: value))
        }

        return zones
    }

    /// Extracts one `key=value` field from a comma-separated brace body.
    ///
    /// Matched by prefix so `mName` cannot accidentally match inside another key, and
    /// trailing whitespace is trimmed because the HAL pads some fields.
    private static func field(in body: Substring, named key: String) -> String? {
        let needle = key + "="
        for part in body.split(separator: ",") {
            let candidate = part.trimmingCharacters(in: .whitespaces)
            guard candidate.hasPrefix(needle) else { continue }
            return String(candidate.dropFirst(needle.count))
                .trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    // MARK: - /proc/meminfo

    /// Parses `MemTotal` and `MemAvailable` from `/proc/meminfo`.
    ///
    /// Values are in kB. `MemAvailable` is used rather than `MemFree` because `MemFree`
    /// excludes reclaimable page cache and would report a healthy device as nearly full.
    static func parseMemory(_ raw: String) -> MemoryTelemetry? {
        var total: UInt64?
        var available: UInt64?

        for line in raw.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }

            let key = parts[0].hasSuffix(":") ? String(parts[0].dropLast()) : String(parts[0])
            guard let kilobytes = UInt64(parts[1]) else { continue }

            switch key {
            case "MemTotal": total = kilobytes * 1024
            case "MemAvailable": available = kilobytes * 1024
            default: continue
            }
        }

        guard let total, let available, total > 0 else { return nil }
        return MemoryTelemetry(totalBytes: total, availableBytes: min(available, total))
    }

    // MARK: - df

    /// Parses `df -k <path>`.
    ///
    /// Format on the Pixel 7a:
    ///
    ///     Filesystem       1K-blocks      Used Available Use% Mounted on
    ///     /dev/block/dm-61 115343360  75000000  38000000  66% /data/user/0
    ///
    /// The header row is skipped by requiring the numeric columns to parse. Column 2 is the
    /// block count and column 3 is the used count, both in 1K blocks.
    static func parseStorage(_ raw: String) -> StorageTelemetry? {
        for line in raw.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3,
                  let blocks = UInt64(parts[1]),
                  let used = UInt64(parts[2]) else { continue }
            guard blocks > 0 else { continue }
            return StorageTelemetry(usedBytes: used * 1024, totalBytes: blocks * 1024)
        }
        return nil
    }

    // MARK: - Shared

    /// Collects `key: value` pairs from indented `dumpsys` output.
    ///
    /// Keys are lowercased so a build that prints `Level:` and one that prints `level:` both
    /// resolve. Only the first occurrence of a key is kept — `dumpsys` repeats some fields in
    /// later sections, and the first is the service's current state.
    static func keyValueLines(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in raw.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty else { continue }
            if result[key] == nil { result[key] = value }
        }
        return result
    }
}

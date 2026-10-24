import Foundation

/// Read-only perception of what is on the device screen.
///
/// ## What this is
///
/// Phase 0 of `docs/PROPOSAL-DEVICE-INTERACTION.md`: the control plane's input side. Two
/// primitives, both of which return data the device itself already produced:
///
/// - `uiHierarchy` — the accessibility tree from `uiautomator dump`.
/// - `screenshot` — the framebuffer from `screencap`.
///
/// Nothing here mirrors, decodes, or streams video. The panel is dead but the framebuffer
/// renders, so both reads work; live mirroring is `scrcpy`, an external tool (proposal §6.4).
///
/// ## What this is not
///
/// There is no `tap`, no `type`, no `swipe`. Input injection is Phase 2 and is gated behind a
/// dry-run preview (proposal P3) and its own ADR. A perception layer that could also act
/// would be the wrong seam for that gate to live in.
protocol DevicePerceptionProtocol: Sendable {
    /// Reads the current UI hierarchy.
    ///
    /// - Throws: `PixelDesktopError.adbCommandFailed` when the dump command fails, and
    ///   `PixelDesktopError.invalidInput` when the dump is unparseable.
    func uiHierarchy(deviceSerial: String, timeout: TimeInterval) async throws -> UIHierarchy

    /// Reads one screen capture as PNG bytes.
    ///
    /// - Throws: `PixelDesktopError.adbCommandFailed` on a non-zero exit, and
    ///   `PixelDesktopError.verificationFailed` when the bytes are not a PNG — a truncated or
    ///   empty capture is a `screencap` failure that exits 0, so the payload itself is checked.
    func screenshot(deviceSerial: String, timeout: TimeInterval) async throws -> Data
}

/// Where a device screenshot is written.
///
/// Deliberately a parameter rather than a constant: the app writes into Application Support,
/// tests write into a temporary directory, and neither path is hardcoded at the call site.
struct ScreenshotStore: Sendable {
    let directory: URL

    /// Creates the store, making the directory if needed.
    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    /// The app's default location: `~/Library/Application Support/PixelDesktop/captures`.
    static func applicationDefault() throws -> ScreenshotStore {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return try ScreenshotStore(directory: base.appendingPathComponent("PixelDesktop/captures"))
    }

    /// Writes PNG bytes and returns the file URL.
    ///
    /// The filename carries a UTC timestamp with second resolution so successive captures do
    /// not overwrite each other (proposal P5: every action leaves a recoverable record).
    @discardableResult
    func write(_ data: Data, at date: Date = Date()) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"

        var url = directory.appendingPathComponent("screenshot-\(formatter.string(from: date)).png")

        // Two captures inside the same second must not clobber each other.
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent(
                "screenshot-\(formatter.string(from: date))-\(suffix).png"
            )
            suffix += 1
        }

        try data.write(to: url, options: .atomic)
        return url
    }
}

/// Signature check for a PNG payload.
///
/// `screencap` exits 0 and can still emit zero bytes or a truncated stream when the device
/// is busy. The eight-byte signature is the cheapest assertion that the payload is the thing
/// we asked for; the IEND check catches truncation, which a header check alone misses.
enum PNGSignature {
    static let magic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    static func isValid(_ data: Data) -> Bool {
        guard data.count > magic.count else { return false }
        guard Array(data.prefix(magic.count)) == magic else { return false }
        return endsWithIEND(data)
    }

    /// Reads the pixel dimensions out of the IHDR chunk.
    ///
    /// This is the right invariant for "did I capture the whole screen", and payload *size* is
    /// not: a real 1080×2400 capture of a mostly-flat screen measured 15,580 bytes, so any
    /// "a screenshot can't be this small" threshold rejects a perfectly good image. Dimensions
    /// come from the file's own header — width at offset 16, height at 20 — both big-endian.
    static func dimensions(_ data: Data) -> (width: Int, height: Int)? {
        guard data.count >= 24, isValid(data) else { return nil }

        let bytes = Array(data.prefix(24))
        // `IHDR` must be the first chunk (PNG spec §11.2.2) or this is not a still image.
        guard Array(bytes[12..<16]) == [0x49, 0x48, 0x44, 0x52] else { return nil }

        func bigEndianInt(at offset: Int) -> Int {
            (Int(bytes[offset]) << 24) | (Int(bytes[offset + 1]) << 16)
                | (Int(bytes[offset + 2]) << 8) | Int(bytes[offset + 3])
        }

        let width = bigEndianInt(at: 16)
        let height = bigEndianInt(at: 20)
        guard width > 0, height > 0 else { return nil }
        return (width, height)
    }

    /// Every PNG ends with the 12-byte IEND chunk: length 0, type `IEND`, CRC `AE426082`.
    private static func endsWithIEND(_ data: Data) -> Bool {
        let trailer: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82]
        guard data.count >= trailer.count else { return false }
        return Array(data.suffix(trailer.count)) == trailer
    }
}

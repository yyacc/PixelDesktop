//
//  CLIDeviceSelection.swift
//  PixelDesktopCLI
//
//  Phase 9 Step 1 — which device a command is talking to.
//
//  The precedence here is **the same rule the application already applies** (`AppState
//  .connectedDeviceSerial`): `device` → `unauthorized` → `offline` → not found. Unauthorized is
//  checked before offline because it is the actionable one — an offline device needs a cable
//  check, an unauthorized device needs a tap the user can perform right now.
//
//  It is duplicated in spirit, not in mechanism: the app's version is `private` and reads
//  `@Published` UI state, so it cannot be shared directly. The rule is three lines and is
//  pinned by a test on both sides.
//

import Foundation

// This file is compiled into two different modules: the `pixel-desktop` tool (where the shared
// PixelDesktop sources are in the *same* module, so no import is needed) and the test bundle
// (where they are a separate module). The conditional keeps both compiling from one source file
// rather than forking a test-only copy that could drift.
#if canImport(PixelDesktop) && !PIXELDESKTOP_CLI_TOOL
// `@testable` rather than a plain import: the shared types are `internal`, so a plain import
// would find the module but not the types. In the tool target this branch is not compiled at all
// (the shared sources are in the same module there).
@testable import PixelDesktop
#endif

enum CLIDeviceSelection {

    /// Selects the serial of a connected device, or throws the error that describes why not.
    ///
    /// Performs **no** device I/O of its own — `listDevices()` is a single `adb devices -l`.
    /// Callers that must not touch the device (the `capability` command) do not call this.
    static func connectedSerial(transport: TransportProtocol) async throws -> String {
        let devices: [AndroidDevice]
        do {
            devices = try await transport.listDevices()
        } catch let error as PixelDesktopError {
            throw error
        } catch {
            throw PixelDesktopError.adbTransportError(error.localizedDescription)
        }

        if let serial = devices.first(where: { $0.state == .device })?.serialNumber {
            return serial
        }
        if devices.contains(where: { $0.state == .unauthorized }) {
            throw PixelDesktopError.deviceUnauthorized
        }
        if devices.contains(where: { $0.state == .offline }) {
            throw PixelDesktopError.deviceOffline
        }
        throw PixelDesktopError.deviceNotFound
    }
}

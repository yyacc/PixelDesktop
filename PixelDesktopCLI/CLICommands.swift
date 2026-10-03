//
//  CLICommands.swift
//  PixelDesktopCLI
//
//  Phase 9 Step 1 — the two commands.
//
//  Both are thin: they obtain values from the existing implementation and hand them to the
//  envelope. Neither computes a capability, decides feasibility, retries, or mutates anything.
//

import Foundation

enum CLICommands {

    // MARK: - capability

    /// Publishes the static capability contract.
    ///
    /// **Performs no device I/O.** The contract is built from the project's own definitions —
    /// `LlamaCppInferenceRuntime`, `ModelContract`, `InferenceRequest`, `DTCA1Job` — so it is
    /// fully available with no Pixel attached. That is the property that makes this command
    /// safe for a planner to call before deciding whether to involve the device at all.
    ///
    /// `contract.device` is **not read**, because every device fact is a device read and this
    /// command must not read the device. The contract's own `build()` marks that field
    /// `.deviceReported` (a read); publishing it here would either require I/O this command
    /// promises not to do, or a fabricated `.declared` provenance. Neither is acceptable, so
    /// the field is omitted and the omission is stated in `not_read`.
    ///
    /// The remaining device-independent fields are republished with provenance changed to
    /// `.declared` and the original limitation retained. That is the honest provenance for
    /// "this is what the build supports, not what was observed" — and it is what the contract's
    /// own doc comment describes: *"Describes what this build ships, not what is installed on
    /// the device."*
    static func capability() throws -> CLIEnvelope {
        let built = PixelCapabilityContract.build(
            device: Self.unobservedDevice,
            contextSize: PixelCapabilityContract.contextSize(runtimeReported: nil)
        )

        let contract = PixelCapabilityContract(
            contractVersion: built.contractVersion,
            device: built.device,
            runtime: Self.asDeclared(built.runtime),
            model: Self.asDeclared(built.model),
            limits: Self.asDeclared(built.limits),
            workloads: built.workloads
        )

        return CLIEnvelope(
            command: "capability",
            ok: true,
            contract: contract,
            notRead: [
                CLINotRead(
                    field: "contract.device",
                    reason: "Not read: device identity requires a device read and this command "
                        + "performs no device I/O. Use `observe` for device state."
                )
            ]
        )
    }

    // MARK: - observe

    /// Publishes a point-in-time observation of the device.
    ///
    /// Uses the existing `PixelEvidenceReader` over the existing `TransportProtocol`. Only the
    /// already-authorised read-only observation operations run; no `shell()`, `push`, `pull`,
    /// `install`, launch, or stop is reachable from this command.
    ///
    /// On failure nothing is returned but a structured error — never a partially populated
    /// observation. A failed read is not evidence of anything, and half a struct invites a
    /// consumer to use it.
    static func observe(transport: TransportProtocol) async throws -> CLIEnvelope {
        let serial = try await CLIDeviceSelection.connectedSerial(transport: transport)

        // Errors from the reader propagate unchanged: `PixelEvidenceReader.observeState` returns
        // an all-unknown observation for an unreachable device, and only throws for a genuine
        // failure. Either outcome is published as-is rather than reinterpreted here.
        let observation = try await PixelEvidenceReader(transport: transport)
            .observeState(deviceSerial: serial)

        return CLIEnvelope(
            command: "observe",
            ok: true,
            observation: observation
        )
    }

    // MARK: - Helpers

    /// A placeholder device used only to satisfy `build()`'s signature.
    ///
    /// Every field of `contract.device` is derived from this value and every one of those fields
    /// is omitted from the published output (see `capability()`), so no value here can reach a
    /// consumer. It exists so the device-independent fields can be built through the project's
    /// own factory rather than restated.
    private static let unobservedDevice = AndroidDevice(
        id: "",
        serialNumber: "",
        deviceCodename: "",
        marketingName: "",
        manufacturer: "",
        androidVersion: "",
        apiLevel: 0,
        architecture: "",
        supportedABIs: [],
        state: .unknown
    )

    /// Restates a value's provenance as `.declared`, preserving its limitation.
    ///
    /// Used only for values that are genuinely build constants. It deliberately does **not**
    /// invent a timestamp: `observedAt` becomes `nil`, because a constant was never observed.
    private static func asDeclared<T>(_ value: CapabilityValue<T>) -> CapabilityValue<T> {
        CapabilityValue(value: value.value, source: .declared, observedAt: nil, limitation: value.limitation)
    }
}

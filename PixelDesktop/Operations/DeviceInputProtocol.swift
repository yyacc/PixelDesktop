import Foundation

/// Input injection: the "hands" of Phase 2.
///
/// ## The gate is part of the API, not a convention
///
/// The proposal (§6.2) requires that blind input cannot execute without a previewed,
/// confirmed target. That is expressed structurally here: planning and executing are
/// separate calls, `plan*` returns an **unconfirmed** `InputActionPlan`, and `execute`
/// refuses anything that has not been through `confirming()`. There is no overload that
/// plans and executes in one step, so a caller cannot skip the preview by accident.
///
/// ## No coordinates
///
/// There is no method taking `(x, y)`. Taps are addressed by a query against a
/// `UIHierarchy` dump or by an element index within one. This is the rule that makes a tap
/// reviewable: the preview says *which element*, not *which pixel*, and the audit record
/// keeps the label beside the resolved centre.
///
/// ## Separate from `DevicePerceptionProtocol`
///
/// Perception is read-only and is the seam the gate reads *from*. Putting `tap` on it would
/// mean the type that observes the device could also act on it, which is the wrong place for
/// this boundary to live.
protocol DeviceInputProtocol: Sendable {
    /// Proposes a tap on the single interactive element matching `query`.
    ///
    /// - Throws: `InputRefusal.targetNotFound` when nothing matches,
    ///   `.targetNotInteractive` when matches exist but none can be tapped, and
    ///   `.targetAmbiguous` when more than one interactive element matches — in that case the
    ///   caller disambiguates with `planTap(hierarchy:elementIndex:)`.
    func planTap(hierarchy: UIHierarchy, matching query: String) throws -> InputActionPlan

    /// Proposes a tap on one exact element of a dump.
    ///
    /// The disambiguation path: the UI lists the candidates `planTap(hierarchy:matching:)`
    /// refused as ambiguous and the user picks one.
    ///
    /// - Throws: `InputRefusal.targetNotFound` for an unknown index, `.targetNotInteractive`
    ///   when the node cannot be tapped.
    func planTap(hierarchy: UIHierarchy, elementIndex: Int) throws -> InputActionPlan

    /// Proposes typing `text` into whatever currently has focus.
    ///
    /// - Throws: `InputRefusal.textRejected` for empty text, embedded line breaks, or text
    ///   over the length limit.
    func planText(_ text: String) throws -> InputActionPlan

    /// Proposes a hardware-ish key event.
    ///
    /// - Throws: `InputRefusal.keyRejected` when the name is outside the supported vocabulary.
    func planKeyEvent(_ key: String) throws -> InputActionPlan

    /// Runs a confirmed plan.
    ///
    /// - Throws: `InputRefusal.planNotConfirmed` when the plan was never confirmed;
    ///   `PixelDesktopError.adbCommandFailed` when the device refused the command.
    func execute(
        _ plan: InputActionPlan,
        deviceSerial: String,
        timeout: TimeInterval
    ) async throws -> InputActionResult
}

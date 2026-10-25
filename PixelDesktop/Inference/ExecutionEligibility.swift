//
//  ExecutionEligibility.swift
//  PixelDesktop
//
//  The production side of the routing gate: it gathers the evidence `ExecutionRoutingGate`
//  decides on. Kept separate from the decision itself so the policy stays a pure function that
//  can be tested without a device, and so the *only* thing this file can get wrong is whether it
//  measured honestly.
//

import Foundation

/// What both real execution boundaries depend on instead of a concrete device type.
///
/// Injected, never instantiated inside a command: a boundary that constructs its own policy can
/// silently acquire a different one, and the scheduler and the CLI must not be able to disagree
/// about whether the device is suitable.
protocol ExecutionEligibilityEvaluating: Sendable {
    func decide(
        deviceSerial: String,
        requirement: ExecutionRequirement,
        context: ExecutionContext
    ) async -> RoutingDecision
}

/// The single device-state read `DeviceExecutionEligibility` depends on.
///
/// Narrower than `PixelEvidenceReader` on purpose: the eligibility boundary needs one method, and
/// a test fake must be able to reproduce the real reader's timing without a transport.
protocol PixelStateObserving: Sendable {
    func observeState(
        deviceSerial: String,
        timeout: TimeInterval
    ) async throws -> PixelStateObservation
}

extension PixelStateObserving {
    /// Reads with the concrete reader's default timeout, so the eligibility boundary never has to
    /// invent a timeout of its own.
    func observeState(deviceSerial: String) async throws -> PixelStateObservation {
        try await observeState(
            deviceSerial: deviceSerial,
            timeout: PixelEvidenceReader.defaultObservationTimeout
        )
    }
}

/// Reads the device and decides.
///
/// Fail closed on an unreadable device: an observation that could not be taken is reported as
/// `.unknown` on a hard check, which blocks an unattended run and tells an interactive caller
/// exactly what could not be established.
struct DeviceExecutionEligibility: ExecutionEligibilityEvaluating {

    private let reader: any PixelStateObserving
    private let transport: TransportProtocol
    private let evaluator: ExecutionRoutingEvaluator

    /// The device-local port the inference backend listens on, when it is a network backend.
    ///
    /// `nil` for an in-process backend: there is no endpoint to probe, and inventing a "healthy"
    /// verdict for a probe that never ran would be the one thing this gate must not do. The
    /// absence is published as `notEvaluated`.
    private let backendPort: Int?

    /// Whether the selected backend consults the contract artifact for its model.
    ///
    /// `true` for the in-process backend, whose model *is* the fixed contract artifact on the
    /// device, so model-presence must be checked. `false` for the on-device server backend, which
    /// serves its own model and never reads the contract artifact, so model-presence is skipped
    /// and the skip is recorded rather than silently passed.
    private let contractModelRequired: Bool

    /// How long the liveness probe may take before it counts as a failure.
    private let probeTimeout: TimeInterval

    init(
        transport: TransportProtocol,
        thresholds: RoutingThresholds = .default,
        backendPort: Int? = nil,
        contractModelRequired: Bool,
        probeTimeout: TimeInterval = 5,
        reader: (any PixelStateObserving)? = nil
    ) {
        self.transport = transport
        self.reader = reader ?? PixelEvidenceReader(transport: transport)
        self.evaluator = ExecutionRoutingEvaluator(thresholds: thresholds)
        self.backendPort = backendPort
        self.contractModelRequired = contractModelRequired
        self.probeTimeout = probeTimeout
    }

    func decide(
        deviceSerial: String,
        requirement: ExecutionRequirement,
        context: ExecutionContext
    ) async -> RoutingDecision {
        let observation: PixelStateObservation
        do {
            observation = try await reader.observeState(deviceSerial: deviceSerial)
        } catch {
            return ExecutionRoutingEvaluator.unobservable(
                reason: (error as? PixelDesktopError)?.description ?? String(describing: error),
                requirement: requirement,
                context: context,
                deviceSerial: deviceSerial,
                at: Date()
            )
        }

        // Sample the decision clock only after the read completes. `PixelEvidenceReader` stamps
        // `observedAt` at the *start* of a read that can take one to two seconds, so a clock
        // sampled before the read would make the observation look timestamped in the future and
        // report its freshness as unknown on every real device. Sampling after makes the age the
        // real elapsed read time.
        let now = Date()

        // Only an inference run over a network backend has an endpoint to ask.
        var backendHealth: Bool?
        if requirement == .inference, let port = backendPort {
            backendHealth = await Self.probeBackend(
                deviceSerial: deviceSerial,
                port: port,
                transport: transport,
                timeout: probeTimeout
            )
        }

        return evaluator.evaluate(
            observation: observation,
            // No throughput evidence is threaded in yet: no store of past measurements is reachable
            // from either boundary. The gate reports that as `notEvaluated` rather than assuming a
            // rate, so the check becomes live the moment a caller can supply one.
            performance: nil,
            backendHealth: backendHealth,
            contractModelRequired: contractModelRequired,
            requirement: requirement,
            context: context,
            now: now
        )
    }

    /// Asks the backend, from the device, whether it is answering.
    ///
    /// `curl` and `wget` are both absent on the target build; `nc` is present. A bare HTTP/1.0
    /// request is enough to separate "listening and answering" from "connection refused", which
    /// is exactly the distinction the gate needs. Probed from the device rather than through a
    /// host forward so the check exercises the path the worker itself will use, and so it fails
    /// in the states where the run would fail.
    static func probeBackend(
        deviceSerial: String,
        port: Int,
        transport: TransportProtocol,
        timeout: TimeInterval = 5
    ) async -> Bool {
        let command =
            "printf 'GET /health HTTP/1.0\\r\\nHost: 127.0.0.1\\r\\n\\r\\n' | nc -w 3 127.0.0.1 \(port) | head -1"
        do {
            let result = try await transport.shell(
                deviceSerial: deviceSerial,
                command: command,
                timeout: timeout
            )
            // llama.cpp answers `HTTP/1.1 200 OK`. Anything else — refused, empty, or a different
            // status — is not evidence of a healthy backend.
            return result.stdout.contains(" 200 ")
        } catch {
            return false
        }
    }
}

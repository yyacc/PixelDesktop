//
//  InferenceEvidence.swift
//  PixelDesktop
//
//  Phase 6 — the evidence chain.
//
//  D8's verification was independent re-computation: DTCA-1 is deterministic, so the Mac could
//  recompute the answer and compare it exactly.
//
//  THAT METHOD DOES NOT TRANSFER TO LLM INFERENCE. The Mac has no model and no runtime, and
//  generation may not be bit-reproducible even on identical hardware. ADR-012 §P7 replaces it
//  with an evidence chain whose load-bearing links are:
//
//    1. CPU time attributable to the worker's PID  (per-process, cannot be attributed elsewhere)
//    2. an ABLATION test: remove the model -> the worker must FAIL
//
//  Ablation is the LLM-era substitute for re-computation. It is the only link that establishes
//  CAUSATION: if the model artifact is required for the output to exist, the output came from
//  the model.
//
//  What this chain proves: inference OCCURRED ON THE DEVICE.
//  What it does NOT prove: that the output is CORRECT. That is a different claim, and Phase 6
//  does not make it.
//

import Foundation

/// One link in the chain. Each is recorded with its raw observed value, not a pass/fail only,
/// so a later reader can re-judge the evidence rather than trusting this code's verdict.
struct EvidenceLink: Equatable, Sendable {
    let name: String
    let observed: String
    let satisfied: Bool
    /// What this link does NOT establish. Every link has one; recording it is what keeps the
    /// chain honest.
    let limitation: String
}

/// The full evidence chain for one inference run.
struct InferenceEvidence: Equatable, Sendable {
    var links: [EvidenceLink] = []

    var allSatisfied: Bool { links.allSatisfy(\.satisfied) }

    /// Links that are load-bearing. If these fail, the proof fails regardless of the rest.
    static let loadBearingLinks: Set<String> = ["cpu_time_attributable", "ablation"]

    var loadBearingSatisfied: Bool {
        links.filter { Self.loadBearingLinks.contains($0.name) }.allSatisfy(\.satisfied)
    }

    var failedLinks: [EvidenceLink] { links.filter { !$0.satisfied } }

    mutating func add(_ name: String, observed: String, satisfied: Bool, limitation: String) {
        links.append(EvidenceLink(
            name: name, observed: observed, satisfied: satisfied, limitation: limitation))
    }

    func link(named name: String) -> EvidenceLink? {
        links.first { $0.name == name }
    }
}

/// Builds the chain from observed device facts.
///
/// Deliberately pure: it takes facts and produces links. Nothing here contacts a device, so the
/// logic that decides whether the proof holds is testable without one.
enum InferenceEvidenceBuilder {

    /// The expected model hash. A result whose device-computed hash differs from this is not a
    /// result for the model we provisioned.
    static let expectedModelSha256 = ModelContract.expectedSha256

    struct RunFacts: Equatable, Sendable {
        // Model
        let modelPresentOnDevice: Bool
        let modelBytesOnDevice: Int?
        let modelSha256OnDevice: String?
        // Process
        let workerPackage: String
        let workerPid: Int?
        let processCmdline: String?
        let processAliveAfterLaunch: Bool
        // Execution
        let cpuTicksBefore: Int?
        let cpuTicksAfter: Int?
        let resultJobId: String?
        let requestedJobId: String
        let generatedTokens: Int?
        let modelLoadMs: Int?
        let generationMs: Int?
        // Causality
        let ablationPerformed: Bool
        let ablationFailedAsExpected: Bool
        // Freshness
        let resultExistedBeforeRun: Bool
    }

    static func build(facts: RunFacts, expectedPackage: String = WorkerTransferContract.workerPackageName)
        -> InferenceEvidence {
        var e = InferenceEvidence()

        // ---- model evidence ----
        e.add("model_present_on_device",
              observed: facts.modelPresentOnDevice
                  ? "present, \(facts.modelBytesOnDevice ?? -1) bytes"
                  : "absent",
              satisfied: facts.modelPresentOnDevice,
              limitation: "proves the artifact is on the device, not that it was used")

        let hashMatches = facts.modelSha256OnDevice?.lowercased() == expectedModelSha256.lowercased()
        e.add("model_hash_matches",
              observed: facts.modelSha256OnDevice.map { String($0.prefix(16)) + "..." } ?? "unreadable",
              satisfied: hashMatches,
              limitation: "proves the bytes match what we provisioned, not that they were read")

        // ---- process evidence ----
        e.add("worker_package_identity",
              observed: facts.workerPackage,
              satisfied: facts.workerPackage == expectedPackage,
              limitation: "proves our worker is installed, not that it ran")

        e.add("worker_pid_observed",
              observed: facts.workerPid.map(String.init) ?? "none",
              satisfied: facts.workerPid != nil && facts.processAliveAfterLaunch,
              limitation: "proves a process existed, not that it computed")

        let cmdlineMatches = facts.processCmdline?.contains(expectedPackage) ?? false
        e.add("process_cmdline_matches_package",
              observed: facts.processCmdline ?? "unreadable",
              satisfied: cmdlineMatches,
              limitation: "proves the PID belongs to our package, not what it did")

        // ---- LOAD-BEARING: attributable CPU time ----
        // Per-process CPU consumed by the worker's own PID. This cannot be attributed to any
        // other process on the device.
        let cpuDelta: Int? = {
            guard let before = facts.cpuTicksBefore, let after = facts.cpuTicksAfter else { return nil }
            return after - before
        }()
        e.add("cpu_time_attributable",
              observed: cpuDelta.map { "\($0) ticks consumed by the worker PID" } ?? "unavailable",
              satisfied: (cpuDelta ?? 0) > 0,
              limitation: "proves that PID did real CPU work, not that the work was inference")

        // ---- execution evidence ----
        let freshResult = !facts.resultExistedBeforeRun
        e.add("result_was_fresh",
              observed: facts.resultExistedBeforeRun ? "a result file already existed" : "no prior result",
              satisfied: freshResult,
              limitation: "proves the result appeared during this run, not what produced it")

        let jobIdMatches = facts.resultJobId == facts.requestedJobId
        e.add("job_id_echoed",
              observed: facts.resultJobId ?? "none",
              satisfied: jobIdMatches,
              limitation: "proves the result corresponds to this job, not how it was computed")

        e.add("tokens_generated",
              observed: facts.generatedTokens.map(String.init) ?? "none",
              satisfied: (facts.generatedTokens ?? 0) > 0,
              limitation: "proves tokens were produced, not that a model produced them")

        // A constant lookup would show no model-load cost. This is weak on its own and is
        // recorded as such rather than overclaimed.
        e.add("model_load_cost_observed",
              observed: facts.modelLoadMs.map { "\($0) ms" } ?? "none",
              satisfied: (facts.modelLoadMs ?? 0) > 0,
              limitation: "a large load time is consistent with a model but does not prove one")

        // ---- LOAD-BEARING: ablation ----
        e.add("ablation",
              observed: facts.ablationPerformed
                  ? (facts.ablationFailedAsExpected
                      ? "model absent -> worker failed as expected"
                      : "model absent -> worker SUCCEEDED, which falsifies model causality")
                  : "not performed",
              satisfied: facts.ablationPerformed && facts.ablationFailedAsExpected,
              limitation: "proves the model artifact is causally required; "
                  + "does not prove the output is correct")

        return e
    }
}

/// Compares two runs for greedy stability.
///
/// ADR-012 R4 requires this to be MEASURED, not assumed. Greedy decoding is often but not always
/// reproducible across backends and builds, so a mismatch is a finding to report, not a failure
/// to hide.
enum GreedyStability {
    enum Outcome: Equatable, Sendable {
        case stable(runCount: Int)
        case unstable(differingRunIndex: Int, expected: [Int], actual: [Int])
        case insufficientRuns(Int)

        var description: String {
            switch self {
            case .stable(let n):
                return "greedy output reproduced across \(n) runs (token-for-token)"
            case .unstable(let i, let expected, let actual):
                return "greedy output DIFFERED at run \(i + 1): "
                    + "\(expected.prefix(8))... vs \(actual.prefix(8))..."
            case .insufficientRuns(let n):
                return "only \(n) run(s); stability not established"
            }
        }
    }

    /// Compares by TOKEN IDS, not text. Two different token sequences can decode to the same
    /// string, and comparing strings would report false stability.
    static func evaluate(runs: [[Int]], minimumRuns: Int = 3) -> Outcome {
        guard runs.count >= minimumRuns else { return .insufficientRuns(runs.count) }
        guard let first = runs.first else { return .insufficientRuns(0) }
        for (index, run) in runs.enumerated().dropFirst() {
            if run != first {
                return .unstable(differingRunIndex: index, expected: first, actual: run)
            }
        }
        return .stable(runCount: runs.count)
    }
}

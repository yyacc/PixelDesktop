//
//  Phase2InputTests.swift
//  PixelDesktopTests
//
//  Phase 2 (B1) — input injection, and the gate that makes it safe.
//
//  ## The property under test
//
//  The proposal (§6.2) says input injection ships only with a dry-run preview, element
//  addressing, and an audit record. Those are three claims, and each is pinned here:
//
//  - **dry run** — an unconfirmed plan cannot execute, and no command reaches the device;
//  - **element addressing** — a tap's coordinates come from a `UIHierarchy` element, never
//    from the caller;
//  - **audit** — every execution and every refusal leaves a record.
//
//  The tests also pin the containment on the one place caller text reaches the device shell.
//  That is the part a unit test can genuinely prove, unlike "the tap landed where I meant".
//

import XCTest
@testable import PixelDesktop

final class Phase2InputTests: XCTestCase {

    private let serial = "3C261JEHN25632"

    // MARK: - The gate

    /// The core requirement: a plan that was never previewed cannot run, and nothing is sent.
    func testUnconfirmedPlanIsRefusedAndNothingReachesTheDevice() async throws {
        let transport = MockTransport()
        let log = InputAuditLog()
        let input = ADBDeviceInput(transport: transport, auditLog: log)

        let plan = try input.planTap(hierarchy: hierarchy([allowButton()]), matching: "allow")
        XCTAssertFalse(plan.confirmed)

        do {
            _ = try await input.execute(plan, deviceSerial: serial, timeout: 10)
            XCTFail("an unconfirmed plan must not execute")
        } catch let refusal as InputRefusal {
            XCTAssertEqual(refusal, .planNotConfirmed)
        }

        let invocations = await transport.invocations
        XCTAssertTrue(invocations.isEmpty, "a refused plan must issue no device command")
        XCTAssertEqual(log.latest?.outcome, InputAuditRecord.refused)
    }

    func testConfirmingProducesALivePlanAndTheOriginalStaysDead() async throws {
        let transport = MockTransport()
        let input = ADBDeviceInput(transport: transport, auditLog: InputAuditLog())

        let proposed = try input.planTap(hierarchy: hierarchy([allowButton()]), matching: "allow")
        let approved = proposed.confirming()

        XCTAssertTrue(approved.confirmed)
        XCTAssertFalse(proposed.confirmed, "approval is a transition, not a mutation")

        _ = try await input.execute(approved, deviceSerial: serial, timeout: 10)

        let commands = await transport.invocations.map { $0.arguments.last ?? "" }
        XCTAssertEqual(commands, ["input tap 200 230"])
    }

    // MARK: - Element addressing

    func testTapResolvesTheElementCentre() throws {
        let input = ADBDeviceInput(transport: MockTransport(), auditLog: InputAuditLog())
        let button = allowButton()

        let plan = try input.planTap(hierarchy: hierarchy([button]), matching: "allow")

        let target = try XCTUnwrap(plan.target)
        XCTAssertEqual(target.centerX, button.bounds.centerX)
        XCTAssertEqual(target.centerY, button.bounds.centerY)
        XCTAssertEqual(target.label, "Allow")
        XCTAssertEqual(target.resourceID, "com.android.settings:id/allow_button")
    }

    func testAmbiguousQueryIsRefusedWithCandidates() throws {
        let input = ADBDeviceInput(transport: MockTransport(), auditLog: InputAuditLog())
        let first = allowButton(index: 1, top: 100)
        let second = allowButton(index: 2, top: 400)

        do {
            _ = try input.planTap(hierarchy: hierarchy([first, second]), matching: "allow")
            XCTFail("two interactive matches cannot produce a determinate preview")
        } catch let refusal as InputRefusal {
            guard case .targetAmbiguous(let candidates) = refusal else {
                return XCTFail("expected targetAmbiguous, got \(refusal)")
            }
            XCTAssertEqual(candidates.count, 2)
        }
    }

    func testDisambiguationByElementIndex() throws {
        let input = ADBDeviceInput(transport: MockTransport(), auditLog: InputAuditLog())
        let first = allowButton(index: 1, top: 100)
        let second = allowButton(index: 2, top: 400)

        let plan = try input.planTap(hierarchy: hierarchy([first, second]), elementIndex: 2)

        XCTAssertEqual(plan.target?.index, 2)
        XCTAssertEqual(plan.target?.centerY, 430)
    }

    func testUnknownQueryIsRefused() throws {
        let input = ADBDeviceInput(transport: MockTransport(), auditLog: InputAuditLog())

        do {
            _ = try input.planTap(hierarchy: hierarchy([allowButton()]), matching: "deny")
            XCTFail("expected a refusal")
        } catch let refusal as InputRefusal {
            guard case .targetNotFound = refusal else {
                return XCTFail("expected targetNotFound, got \(refusal)")
            }
        }
    }

    /// A match that exists but cannot be tapped is a different mistake from a wrong query, and
    /// the refusal says so.
    func testNonInteractiveMatchIsRefusedAsUntappable() throws {
        let input = ADBDeviceInput(transport: MockTransport(), auditLog: InputAuditLog())
        let label = element(index: 3, text: "Allow", clickable: false)

        do {
            _ = try input.planTap(hierarchy: hierarchy([label]), matching: "allow")
            XCTFail("expected a refusal")
        } catch let refusal as InputRefusal {
            guard case .targetNotInteractive = refusal else {
                return XCTFail("expected targetNotInteractive, got \(refusal)")
            }
        }
    }

    func testOffScreenElementIsNotOfferedAsATarget() throws {
        let input = ADBDeviceInput(transport: MockTransport(), auditLog: InputAuditLog())
        let zeroArea = element(
            index: 4,
            text: "Allow",
            bounds: UIElementBounds(left: 0, top: 0, right: 0, bottom: 0)
        )

        do {
            _ = try input.planTap(hierarchy: hierarchy([zeroArea]), matching: "allow")
            XCTFail("a zero-area node has no centre to tap")
        } catch let refusal as InputRefusal {
            guard case .targetNotInteractive = refusal else {
                return XCTFail("expected targetNotInteractive, got \(refusal)")
            }
        }
    }

    // MARK: - Text containment

    func testTextRejectsEmpty() {
        let input = ADBDeviceInput(transport: MockTransport(), auditLog: InputAuditLog())
        XCTAssertThrowsError(try input.planText("")) { error in
            XCTAssertEqual(error as? InputRefusal, .textRejected(reason: "text is empty"))
        }
    }

    func testTextRejectsLineBreaks() {
        let input = ADBDeviceInput(transport: MockTransport(), auditLog: InputAuditLog())
        XCTAssertThrowsError(try input.planText("first\nsecond"))
    }

    func testTextRejectsOverlongPayloads() {
        let input = ADBDeviceInput(transport: MockTransport(), auditLog: InputAuditLog())
        XCTAssertThrowsError(try input.planText(String(repeating: "a", count: 513)))
    }

    /// The reason for quoting rather than an allowlist: a password containing `$` must be
    /// deliverable, and the shell must not expand it.
    func testTextIsSingleQuotedSoTheShellCannotExpandIt() throws {
        let input = ADBDeviceInput(transport: MockTransport(), auditLog: InputAuditLog())
        let plan = try input.planText("$(whoami) `id` ; reboot").confirming()

        let command = try input.buildCommand(for: plan)

        XCTAssertEqual(command, "input text '$(whoami)%s`id`%s;%sreboot'")
        XCTAssertTrue(command.contains("'"), "the payload must be quoted")
    }

    func testSpacesBecomePercentS() throws {
        XCTAssertEqual(try InputContainment.quotedTextArgument("hello world"), "'hello%sworld'")
    }

    func testEmbeddedSingleQuoteIsClosedAndReopened() {
        XCTAssertEqual(
            InputContainment.shellSingleQuote("it's"),
            "'it'\\''s'",
            "the only correct way to embed a quote in a single-quoted shell string"
        )
    }

    // MARK: - Keys

    func testKeyAllowlistAcceptsKnownNames() throws {
        let input = ADBDeviceInput(transport: MockTransport(), auditLog: InputAuditLog())
        let plan = try input.planKeyEvent("keycode_back")
        XCTAssertEqual(plan.payload, "KEYCODE_BACK", "input is normalised to upper case")
    }

    func testKeyAllowlistRejectsAnythingElse() {
        let input = ADBDeviceInput(transport: MockTransport(), auditLog: InputAuditLog())
        XCTAssertThrowsError(try input.planKeyEvent("KEYCODE_BACK; reboot")) { error in
            guard case .keyRejected = (error as? InputRefusal) else {
                return XCTFail("expected keyRejected, got \(error)")
            }
        }
    }

    // MARK: - Audit

    func testExecutionIsAuditedWithResolvedTarget() async throws {
        let transport = MockTransport()
        let log = InputAuditLog()
        let input = ADBDeviceInput(transport: transport, auditLog: log)

        let plan = try input.planTap(hierarchy: hierarchy([allowButton()]), matching: "allow")
        _ = try await input.execute(plan.confirming(), deviceSerial: serial, timeout: 10)

        let record = try XCTUnwrap(log.latest)
        XCTAssertEqual(record.outcome, InputAuditRecord.executed)
        XCTAssertEqual(record.targetLabel, "Allow")
        XCTAssertEqual(record.targetResourceID, "com.android.settings:id/allow_button")
        XCTAssertEqual(record.centerX, 200)
        XCTAssertEqual(record.centerY, 230)
        XCTAssertEqual(record.detail, "input tap 200 230")
    }

    func testAuditLogIsBounded() {
        let log = InputAuditLog(capacity: 2)
        let plan = InputActionPlan(kind: .keyEvent, payload: "KEYCODE_BACK", confirmed: true)

        for index in 0..<5 {
            log.append(
                InputAuditRecord(plan: plan, outcome: InputAuditRecord.executed, detail: "\(index)")
            )
        }

        XCTAssertEqual(log.records.count, 2)
        XCTAssertEqual(log.records.map(\.detail), ["3", "4"])
    }

    func testAuditLogPersistsAndReloads() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pd-audit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("audit.json")

        let plan = InputActionPlan(kind: .keyEvent, payload: "KEYCODE_HOME", confirmed: true)
        let log = InputAuditLog(capacity: 10, fileURL: url)
        log.append(InputAuditRecord(plan: plan, outcome: InputAuditRecord.executed, detail: "x"))

        let reloaded = InputAuditLog(capacity: 10, fileURL: url)
        XCTAssertEqual(reloaded.records.count, 1)
        XCTAssertEqual(reloaded.latest?.payload, "KEYCODE_HOME")
    }

    func testFailedCommandIsAuditedAsFailed() async throws {
        let transport = MockTransport()
        await transport.setDefaultShellResult(
            TransportResult(exitCode: 1, stdout: "", stderr: "INJECT_EVENTS denied")
        )
        let log = InputAuditLog()
        let input = ADBDeviceInput(transport: transport, auditLog: log)

        let plan = try input.planTap(hierarchy: hierarchy([allowButton()]), matching: "allow")

        do {
            _ = try await input.execute(plan.confirming(), deviceSerial: serial, timeout: 10)
            XCTFail("expected the device refusal to surface")
        } catch let error as PixelDesktopError {
            guard case .adbCommandFailed = error else {
                return XCTFail("expected adbCommandFailed, got \(error)")
            }
        }

        XCTAssertEqual(log.latest?.outcome, InputAuditRecord.failed)
    }

    // MARK: - Fixtures

    private func allowButton(index: Int = 1, top: Int = 200) -> UIElement {
        element(
            index: index,
            text: "Allow",
            resourceID: "com.android.settings:id/allow_button",
            bounds: UIElementBounds(left: 100, top: top, right: 300, bottom: top + 60)
        )
    }

    private func element(
        index: Int,
        text: String? = nil,
        contentDescription: String? = nil,
        resourceID: String? = nil,
        bounds: UIElementBounds = UIElementBounds(left: 0, top: 0, right: 1080, bottom: 2400),
        clickable: Bool = true,
        className: String = "android.widget.Button"
    ) -> UIElement {
        UIElement(
            index: index,
            className: className,
            resourceID: resourceID,
            text: text,
            contentDescription: contentDescription,
            bounds: bounds,
            packageName: "com.android.settings",
            isEnabled: true,
            isClickable: clickable,
            isScrollable: false,
            isFocused: false,
            isChecked: false,
            isSelected: false,
            isPassword: false
        )
    }

    private func hierarchy(_ elements: [UIElement]) -> UIHierarchy {
        UIHierarchy(elements: elements, rotation: 0, packageName: "com.android.settings")
    }
}

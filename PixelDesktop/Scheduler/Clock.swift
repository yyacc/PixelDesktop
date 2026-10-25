//
//  Clock.swift
//  PixelDesktop
//
//  Phase 3.4 (C4) — the clock seam.
//
//  WHAT IT IS
//  The only place the scheduler asks what time it is, or waits. Everything with a cadence,
//  a deadline or a catch-up rule is written against this protocol, so the whole scheduler suite
//  runs without wall-clock waits (`TestClock` in the tests).
//
//  WHAT IT IS NOT
//  Not a timer, not a run loop, not a scheduler. The scheduler's clock is launchd; this type
//  exists so the *logic around* that tick can be tested hermetically.
//

import Foundation

protocol Clock: Sendable {
    func now() -> Date

    /// Suspends until `date`. Returns immediately when `date` is already past, so a caller
    /// cannot accidentally wait a negative interval.
    func sleep(until date: Date) async throws
}

struct SystemClock: Clock {
    func now() -> Date { Date() }

    func sleep(until date: Date) async throws {
        let interval = date.timeIntervalSinceNow
        guard interval > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
    }
}

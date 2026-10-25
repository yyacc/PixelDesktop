//
//  CadenceResolver.swift
//  PixelDesktop
//
//  Phase 3.4 (C4) — cadence arithmetic, pure.
//
//  WHAT IT IS
//  Three questions, all answered without touching a clock, a file or a device:
//  when does this job run next, how many ticks were missed while the Mac slept, and was this
//  tick due at all.
//
//  WHAT IT IS NOT
//  Not the tick itself. launchd fires; this type only says what the store should record.
//

import Foundation

enum CadenceResolver {
    /// The next firing strictly after `date`.
    static func nextRun(
        after date: Date,
        cadence: ScheduledCadence,
        calendar: Calendar = .current
    ) -> Date {
        switch cadence {
        case .interval(let seconds):
            return date.addingTimeInterval(TimeInterval(seconds))

        case .daily(let hour, let minute):
            var components = DateComponents()
            components.hour = hour
            components.minute = minute
            return calendar.nextDate(
                after: date,
                matching: components,
                matchingPolicy: .nextTime
            ) ?? date.addingTimeInterval(24 * 3600)
        }
    }

    /// How many scheduled ticks were missed between `lastRun` and `now`.
    ///
    /// A Mac that slept through four intervals owes **one** run, not four: the return value is
    /// what the run records as `skipped`, so an operator can see the sleep in the history.
    static func missedTicks(
        lastRun: Date?,
        now: Date,
        cadence: ScheduledCadence,
        calendar: Calendar = .current
    ) -> Int {
        guard let lastRun else { return 0 }
        let elapsed = now.timeIntervalSince(lastRun)
        guard elapsed > 0 else { return 0 }

        switch cadence {
        case .interval(let seconds):
            guard seconds > 0 else { return 0 }
            // One elapsed interval is the run that is happening now; the rest were missed.
            return max(0, Int(elapsed / TimeInterval(seconds)) - 1)

        case .daily:
            var missed = 0
            var cursor = nextRun(after: lastRun, cadence: cadence, calendar: calendar)
            // Bounded: a year of daily misses is enough to report, and an unbounded loop on a
            // corrupted date is not worth the risk.
            while cursor <= now && missed < 400 {
                missed += 1
                cursor = nextRun(after: cursor, cadence: cadence, calendar: calendar)
            }
            return max(0, missed - 1)
        }
    }

    /// Whether a tick at `now` should execute, given the last recorded run.
    ///
    /// launchd may deliver a tick early (clock skew, manual `kickstart`) and a `RunAtLoad` tick can
    /// arrive seconds after the previous one. A job that already ran inside its own interval is not
    /// run twice.
    static func isDue(
        lastRun: Date?,
        now: Date,
        cadence: ScheduledCadence,
        calendar: Calendar = .current
    ) -> Bool {
        guard let lastRun else { return true }
        return now >= nextRun(after: lastRun, cadence: cadence, calendar: calendar)
    }
}

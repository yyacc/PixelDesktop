# Phase 13 — Zeno Event Timeline

**Date:** 2026-10-10
**Status:** COMPLETE
**Tests:** 607 executed, 26 skipped, 0 failures (baseline was 585/26; +22 tests)

---

## Objective

Add a read-only event timeline to the Zeno Observability dashboard that displays real-time
Zeno activity — session creation, message updates, text streaming, step starts/finishes,
model/agent switches — read directly from Zeno's own SQLite `event` table.

---

## What was implemented

### Data layer (Foundation-only, under `PixelDesktop/Observability/`)

| File | Purpose |
|---|---|
| `ZenoEventModels.swift` | `ZenoEvent`, `ZenoEventType`, `ZenoEventInfo`, `ZenoEventPart` — typed models for the event table |
| `ZenoEventStoreAdapter.swift` | `readEvents(afterSeq:limit:)`, `lastSeq()` — read-only bridge with incremental polling |
| `ZenoSessionStoreAdapter.swift` (modified) | Added `readRows(from:where:orderBy:limit:)` to the `ZenoSQLiteReading` protocol for efficient SQL filtering |
| `SQLiteDatabaseReader.swift` (modified) | Added `readRaw(sql:map:)` for arbitrary read-only SQL queries |

### App layer (SwiftUI, under `PixelDesktop/App/Observability/`)

| File | Purpose |
|---|---|
| `ZenoEventTimelineView.swift` | `ZenoEventTimelinePanel`, `ZenoEventRow` — timeline view with per-event type badges |
| `ZenoObservabilityStore.swift` (modified) | Added `zenoEvents`, `zenoEventTimelineStatus`, `lastSeenEventSeq`, `readZenoEvents()` |
| `ZenoDashboardView.swift` (modified) | Added `ZenoEventTimelinePanel` between session panel and detail view |

### Tests (under `PixelDesktopTests/`)

| File | Tests |
|---|---|
| `ZenoEventStoreAdapterTests.swift` | 22 tests covering all event types, incremental polling, limits, ordering, malformed data, read-only behavior |

---

## Design decisions

### Incremental polling via `seq` cursor

The `event` table has a contiguous `seq` per session (verified: 0..N with no gaps). The
adapter's `readEvents(afterSeq:)` method reads only `WHERE seq > afterSeq`, so each poll
gets only new events. The `lastSeq()` method returns `MAX(seq)` for the cursor.

This is efficient: the event table has 3,240 events, but each poll only reads the new
ones. The first poll reads all events (up to a limit of 200), and subsequent polls read
only the delta.

### Malformed events are skipped, not fatal

A malformed JSON event in the `data` column is skipped (returns `nil` from `mapEvent`),
not a fatal error. This is the correct behavior: one bad event should not crash the
timeline or prevent other events from being shown.

### Unknown event types are preserved

An unrecognised event type is preserved as `.unknown(rawType)` with its raw string, so
a future Zeno version adding a new event type does not crash the dashboard. The timeline
renders it with a generic icon and the raw type string as the summary.

### Read-only by construction

The database is opened with `SQLITE_OPEN_READONLY`. There is no method that issues a
write statement. The `readRaw(sql:map:)` method is the efficient path for queries that
need a WHERE clause or aggregate function, but it is still read-only — the database
handle cannot execute writes.

### Source isolation

The `ZenoEvent` type is produced only by `ZenoEventStoreAdapter`, which reads only from
Zeno's data directory. Nothing in the Homebrew OpenCode path can create one, so a Zeno
event can never appear under a Homebrew heading.

---

## Event types

| Type | Count (live DB) | Icon | Color | Summary |
|---|---|---|---|---|
| `session.created.1` | 8 | plus.circle | green | Session created |
| `session.updated.1` | 241 | pencil.circle | blue | Session updated |
| `message.updated.1` | 680 | bubble.left | purple | Message {role} received |
| `message.part.updated.1` | 2,296 | text.bubble | orange | Text: {truncated} / Step started / Step finished / Tool: {name} |
| `session.next.model.switched.1` | 8 | arrow.triangle.2.circlepath | cyan | Model switched |
| `session.next.agent.switched.1` | 6 | person.crop.circle | mint | Agent switched |
| `message.removed.1` | 1 | trash | red | Message removed |

---

## Test coverage

22 tests, all passing:

- `testSessionCreatedEvent` — valid session.created.1 decoding
- `testSessionUpdatedEvent` — valid session.updated.1 with all fields
- `testMessageUpdatedEvent` — valid message.updated.1 with role
- `testMessagePartTextEvent` — text part with content
- `testMessagePartStepStartEvent` — step-start part
- `testMessagePartStepFinishEvent` — step-finish with tokens
- `testModelSwitchedEvent` — model switch event
- `testAgentSwitchedEvent` — agent switch event
- `testMessageRemovedEvent` — message removal event
- `testUnknownEventType` — unrecognised type preserved as .unknown
- `testReadEventsAfterSeq` — incremental polling (after seq 2, after seq 4, after seq -1)
- `testReadEventsWithLimit` — limit parameter
- `testLastSeq` — MAX(seq) query
- `testLastSeqEmptyTable` — empty table returns nil
- `testMultipleSessions` — events from multiple sessions
- `testMalformedJSONIsSkipped` — malformed JSON skipped, valid event still read
- `testMissingDatabaseThrows` — missing file throws .cannotOpen
- `testMissingEventTableThrows` — missing table throws
- `testReadOnlyDoesNotModifyDatabase` — file size unchanged after read
- `testEventsOrderedBySeqAscending` — events ordered by seq even if inserted out of order
- `testTimestampParsing` — integer, double, info-level, and missing timestamps
- `testEmptyDatabaseReturnsEmptyArray` — empty table returns empty array

---

## Build and test results

**Build:** `** BUILD SUCCEEDED **` (exit 0)

**Tests:** `** TEST SUCCEEDED **` (exit 0)
- Executed 607 tests, with 26 tests skipped and 0 failures (21.18 s)
- `ZenoEventStoreAdapterTests` — 22/22 passed
- `ZenoSessionStoreAdapterTests` — 11/11 passed (unchanged)
- All other suites unchanged and green

**Test count arithmetic:** Phase 12 baseline 585 + Phase 13's 22 new event tests = 607.

---

## Integration

The timeline is integrated into the dashboard between the session panel and the session
detail view. The store's `refresh()` method calls `readZenoEvents()` concurrently with
the other service reads. The timeline polls incrementally: the first refresh reads all
events (up to 200), and subsequent refreshes read only `seq > lastSeenEventSeq`.

The timeline panel follows the same four-state pattern as every other panel:
- **Unknown** — no read has run yet
- **Connected** — shows the event list or an explicit empty state
- **Authentication Required** — not applicable (file read, not HTTP)
- **Unavailable** — database could not be read, with the reason shown

---

## Limitations

1. **Polling interval** — the timeline polls every 10 seconds (the same interval as the
   rest of the dashboard). There is no push notification from Zeno's database, so the
   timeline is not truly real-time. A future phase could reduce the interval for the
   event table specifically, or use FSEvents to detect file changes.

2. **Event limit** — the timeline keeps at most 200 events in memory. Older events are
   dropped as new ones arrive. The full event history is still in the database and can
   be read by lowering the `afterSeq` parameter.

3. **No event filtering** — the timeline shows all events, with no filter by session
   or event type. A future phase could add a filter picker.

4. **No event detail** — tapping an event row does nothing. A future phase could show
   the full JSON payload in a detail view.

---

## Files modified

- `PixelDesktop/Observability/ZenoSessionStoreAdapter.swift` — added `readRows(from:where:orderBy:limit:)` to `ZenoSQLiteReading` protocol with default implementation
- `PixelDesktop/Observability/SQLiteDatabaseReader.swift` — added `readRaw(sql:map:)` for efficient SQL queries
- `PixelDesktop/App/Observability/ZenoObservabilityStore.swift` — added event timeline state and `readZenoEvents()` method
- `PixelDesktop/App/Observability/ZenoDashboardView.swift` — added `ZenoEventTimelinePanel`
- `PixelDesktop.xcodeproj/project.pbxproj` — regenerated via `xcodegen generate`

# Phase 13 — Independent Post-Implementation Audit

**Date:** 2026-10-10
**Scope:** Independent audit of the Phase 13 "Zeno Event Timeline" implementation
**Auditor:** Hermes (independent of the Phase 13 implementation report)
**Verdict:** The Phase 13 report's central claim — "incremental polling via `seq` cursor… safe" — was **wrong**. Four defects were found, three of them real correctness defects. All four are fixed, with regression tests, and verified against Zeno's live database. Full suite: **614 tests, 26 skipped, 0 failures**; build succeeds.

---

## 0. Method

Ground truth came from three independent sources, not from the report:

1. **The live schema and data** — `sqlite3 -readonly` against Zeno's real
   `~/Library/Application Support/ai.zeno.desktop/data/opencode/opencode.db`.
2. **The production sources** — read directly (`ZenoEventStoreAdapter.swift`,
   `ZenoObservabilityStore.swift`, `SQLiteDatabaseReader.swift`, `ZenoSessionStoreAdapter.swift`).
3. **Standalone probes** — small Swift executables compiled against the *real* production
   source files and run against the *real* database (read-only), separate from the test suite.

The report's own numbers (607 tests, "seq contiguous per session") were treated as claims to
re-check, not as evidence.

---

## 1. Findings summary

| # | Finding | Severity | Status |
|---|---|---|---|
| **C1** | Per-session `seq` used as a **global** cursor and sort key → events from newly created sessions are **permanently skipped** | **HIGH** | Fixed |
| **C2** | `readRaw`/`exec` ignore `sqlite3_step`'s return code → a **runtime SQL error is silently returned as an empty result** | **MEDIUM** | Fixed |
| **C3** | Lazy reader **caches the first open failure forever** → a transiently absent database never recovers | **MEDIUM** | Fixed |
| **C4** | Cold start shows the **oldest** 200 events, not the newest, contradicting the code's stated intent | **LOW–MED** | Fixed |
| **C5** | `MAX(rowid)` costs ~8 ms per call on the live DB; `lastPosition()` is currently unused by production polling | **LOW (advisory)** | Recorded |

---

## 2. C1 — The `seq` cursor is not a global key (HIGH, fixed)

### Evidence

The `event` table's unique index is **per-aggregate**, and every session restarts `seq` at 0:

```
$ sqlite3 -readonly opencode.db ".schema event"
CREATE TABLE `event` (
  `id` text PRIMARY KEY,
  `aggregate_id` text NOT NULL,      -- = sessionID
  `seq` integer NOT NULL,            -- monotonic WITHIN a session
  ...
);
CREATE UNIQUE INDEX `event_aggregate_seq_idx` ON `event` (`aggregate_id`,`seq`);
```

```
$ sqlite3 -readonly opencode.db \
  "SELECT COUNT(*) AS total, COUNT(DISTINCT seq) AS distinct_seqs, MAX(seq) AS max_seq FROM event;"
3240|963|962
```

3,240 events but only **963 distinct `seq` values** — i.e. `seq` is reused across sessions. Every
session's first event has `seq = 0`:

```
ses_ee69136f0f|963|0|962
ses_ee8ce34dff|701|0|700
ses_ee4c5a93ef|652|0|651
...   (all 8 sessions start at MIN(seq)=0)
```

The implementation ordered by `seq` and kept a single **global** cursor:

```swift
// ZenoEventStoreAdapter.readEvents (before fix)
where: afterSeq.map { "seq > \($0)" }, orderBy: "seq ASC", limit: limit
// ZenoObservabilityStore.readZenoEvents (before fix)
if let maxSeq = newEvents.map(\.seq).max() { lastSeenEventSeq = maxSeq }
```

**Consequence.** The cursor only ever increases (to the max `seq` seen across *all* sessions).
A session created *after* the cursor has advanced emits events starting at `seq = 0, 1, 2, …`,
all **below** the cursor — so `WHERE seq > cursor` never returns them. They are skipped
**permanently**, not merely delayed. This is the exact failure the report asserted could not
happen ("The `seq` is contiguous per session… so this is safe" — true per session, false globally).

### Reproduction

Probe compiled against the real sources, on a temp DB shaped like the live one
(session A `seq` 0–4, then a **new** session B `seq` 0–1):

```
First poll (limit 5):        ["a0","a1","a2","a3","a4"] nextPosition=5
Second poll (rowid cursor):  ["b0","b1"]   <- new session B visible: true
OLD seq-cursor behavior (seq > 4): 0 events  <- defect: new session B INVISIBLE: true
```

Automated regression (fixture, `ZenoEventStoreAdapterTests`):

- `testSeqCursorWouldSkipNewSessionEvents` — asserts the old `seq > cursor` predicate returns **0**
  of the new session's events while `rowid > cursor` returns **2**.
- `testPollingNeverSkipsANewSession` — end-to-end: poll 1 yields the cursor, poll 2 must return
  the new session's events (it does).

### Fix

Order and paginate by SQLite's implicit **`rowid`** (global insertion order), not `seq`:

- `ZenoEvent.position` (`Int`) added to the model; `ZenoEvent.seq` retained as per-session data,
  documented as **not** a global key.
- `SQLiteDatabaseReader.readRowsByRowID(from:afterPosition:limit:)` issues
  `SELECT *, rowid AS rowid FROM event [WHERE rowid > ?] ORDER BY rowid ASC [LIMIT ?]`.
- The `ZenoSQLiteReading` protocol's string-WHERE method was **replaced** by this typed rowid
  method (the string form could not see `rowid`).
- The store's cursor is renamed `lastSeenEventPosition` and advanced from `rowid`.

### Verification against the live database

Full paged walk of the real table, 200 rows at a time:

```
Full walk: 18 pages, 3240 decoded events, 3240 distinct positions
Order/duplicate violations: 0        (0 == strictly increasing, no dupes)
Raw table rows: 3240  |  decoded: 3240  |  match: true
```

Every row is visited exactly once, in strictly increasing `rowid` order — the property a `seq`
cursor cannot provide.

---

## 3. C2 — Runtime SQL errors were swallowed (MEDIUM, fixed)

### Evidence

`SQLiteDatabaseReader.readRaw` and its private `exec` looped on `sqlite3_step(...) == SQLITE_ROW`
and **ignored every other return code**:

```swift
while sqlite3_step(statement) == SQLITE_ROW { try map(...) }   // SQLITE_ERROR == loop exit, silently
```

A statement that *prepares* but fails at *step* time (a missing column/table, a constraint, a
write on a read-only handle) therefore returned an **empty result with no error** — directly
contradicting the adapter's own documented contract: *"A failed read never appears as a successful
empty result."*

This surfaced during the read-only probe: an `INSERT` attempt was reported as "succeeded" because
`sqlite3_step` returned `SQLITE_READONLY` (8) and the loop exited as if done.

### Reproduction

```
prepare INSERT rc=0 (OK)
step INSERT rc=8  (SQLITE_READONLY)   msg: attempt to write a readonly database
rows with id='__probe__' after the attempt: 0   (write did NOT land)
reader.readRaw(INSERT) returned WITHOUT throwing          <- defect
```

Automated regressions (`ZenoEventStoreAdapterTests`):

- `testStepErrorIsThrownNotSwallowed` — `SELECT abs(-9223372036854775808)` (prepares, fails at
  step with `SQLITE_ERROR`) must throw `.stepFailed`.
- `testWriteAttemptFailsAndDoesNotLand` — an `INSERT` must throw `.stepFailed` with
  `SQLITE_READONLY`, and the row must not exist afterwards.

### Fix

`readRaw` and `exec` now distinguish `SQLITE_ROW` / `SQLITE_DONE` / anything-else, and throw a new
`ZenoSQLiteError.stepFailed(sql:code:message:)` for the last case.

---

## 4. C3 — A transient open failure was permanent (MEDIUM, fixed)

### Evidence

Both lazy readers cached the first open error and re-threw it on every subsequent call:

```swift
private var openError: Error?
...
if let openError { throw openError }        // returned forever, even after the DB appears
```

Zeno's database is legitimately absent until Zeno is launched. If the dashboard starts first, the
first read fails and — because the error is cached — **every** later read (including the 10-second
polling loop) keeps failing. The dashboard stays "Unavailable" until the whole app is restarted.

### Reproduction

```
1. read with no DB:        threw as expected -> Cannot open database at .../opencode.db
3. read after DB appeared: STILL THROWING -> Cannot open database at .../opencode.db
                           <- RECOVERY DEFECT: transient failure is permanent
```

Automated regression: `testRecoversAfterTransientAbsence` — a first read with no file throws; after
the schema is created, the *same adapter instance* must succeed.

### Fix

Removed the cached `openError`; `ensureOpen()` retries the open on each call. The failure is still
thrown while the DB is absent (never a silent empty result) — it just recovers once the DB appears.

```
1. read with no DB:        threw as expected -> Cannot open database at .../opencode.db
3. read after DB appeared: SUCCEEDED, 1 event(s)   <- RECOVERY WORKS
```

---

## 5. C4 — Cold start showed the oldest events, not the newest (LOW–MED, fixed)

### Evidence

`maxTimelineEvents = 200` is documented as *"the timeline shows the most recent events"*, but the
first read was `WHERE rowid > nil ORDER BY rowid ASC LIMIT 200` — i.e. the **oldest** 200. On the
live DB (3,240 events) the newest event is 17 polls (~170 s) away:

```
Oldest rowid in first poll (limit 200): 1
Newest rowid in first poll:            200
Actual newest rowid in table:         3240
```

### Fix

Cold start (`lastSeenEventPosition == nil`) now uses `readRecentEvents(limit:)`
(`… ORDER BY rowid DESC LIMIT 200` wrapped to return oldest-first), so the newest 200 load
immediately and the cursor starts at the head.

Automated regression: `testColdStartReturnsNewestEvents`. Live verification:

```
Cold start: 200 events, positions 3041..3240
  newest event in table: 3240  |  cold start reaches it: true
  next poll after cold start: 0 events
  cold-start cursor == MAX(rowid): true
```

---

## 6. C5 — Polling performance (advisory)

Measured on the live 26 MB DB:

```
cold start (newest 200)            17.13 ms
incremental poll (0 new events)     0.07 ms
incremental poll (0 new) x100       1.72 ms
lastPosition() x100               767.35 ms   (~7.7 ms per MAX(rowid) scan)
```

Production polling is fast (`readEventBatch` with a cursor near the head touches almost nothing).
`lastPosition()` is **not** called in the production poll path (verified by grep); it is a
test/probe accessor. Recorded as advisory: if a future change calls `lastPosition()` every poll,
expect ~8 ms per call on a DB of this size.

---

## 7. Scope items verified with no defect

- **Read-only guarantee holds.** The live-DB write attempt failed with `SQLITE_READONLY` and
  **0 rows landed**; the live table remained `3240|0` (total | probe rows) afterwards. Only one
  `sqlite3_open*` call exists, using `SQLITE_OPEN_READONLY`. No write verb (`INSERT`/`UPDATE`/
  `DELETE`/`DROP`/`CREATE`) exists anywhere in the Observability layer's production code.
- **Source isolation holds.** `ZenoEvent` is constructed in exactly one place
  (`ZenoEventStoreAdapter.swift:173`); nothing in the Homebrew OpenCode path can produce one.
  The event/session adapters reference no credential file, no `service.json`, and no runtime port
  (only in "does not" documentation comments).
- **Malformed rows / unknown types / schema change.** Malformed JSON is skipped, not fatal
  (`testMalformedJSONIsSkipped`); unknown event types are preserved (`testUnknownEventType`);
  a missing table throws (`testMissingEventTableThrows`). New: a malformed row no longer stalls
  the cursor — `ZenoEventBatch.nextPosition` advances past skipped rows
  (`testCursorAdvancesPastMalformedRows`).
- **Bounded memory.** The store trims to `maxTimelineEvents` (200) after every append.
- **Unrelated systems untouched.** `git status` shows only the pre-existing Phase 11–13 working
  set plus this audit's changes. No LeadFlow or other project files were modified. Zeno's database,
  configuration, and runtime were read-only throughout.

---

## 8. Files changed by this audit

| File | Change |
|---|---|
| `Observability/SQLiteDatabaseReader.swift` | Added `readRowsByRowID`, `readRecentRowsByRowID`; `readRaw`/`exec` now throw `.stepFailed` on step errors; added `.stepFailed` error case |
| `Observability/ZenoSessionStoreAdapter.swift` | Replaced the string-WHERE protocol method with typed `readRowsByRowID`/`readRecentRowsByRowID`; removed the inert Swift WHERE evaluator and `ZenoSQLiteReadingLimitReached`; lazy reader no longer caches open failure |
| `Observability/ZenoEventStoreAdapter.swift` | `readEvents(afterPosition:)`, `readEventBatch` (cursor = highest `rowid` scanned), `readRecentEvents`, `lastPosition()`; maps `rowid` → `ZenoEvent.position`; lazy reader no longer caches open failure |
| `Observability/ZenoEventModels.swift` | Added `ZenoEvent.position`; added `ZenoEventBatch`; corrected `seq` documentation |
| `App/Observability/ZenoObservabilityStore.swift` | Cursor renamed `lastSeenEventPosition`; cold start reads newest; advances from batch cursor |
| `App/Observability/ZenoEventTimelineView.swift` | Row now shows `seq N · #position` |
| `PixelDesktopTests/ZenoEventStoreAdapterTests.swift` | 7 new tests + 5 corrected tests (22 → 29) |

---

## 9. Final build / test results

```
Build:  ** BUILD SUCCEEDED **
Tests:  Executed 614 tests, with 26 tests skipped and 0 failures
```

- `ZenoEventStoreAdapterTests`: **29/29** (was 22; +7).
- The 26 skips are all pre-existing device/live gates (`PIXELDESKTOP_DEVICE_SERIAL` /
  `PIXELDESKTOP_LIVE_OBSERVABILITY` unset) — none in the event path, each reason read and confirmed
  unrelated.

**One pre-existing test was corrected, not just added:** `testEventsOrderedBySeqAscending` encoded
the *old, wrong* contract (output sorted by `seq`). It was renamed to
`testEventsOrderedByGlobalAppendPosition` and now asserts the correct contract (insertion order),
so it fails against the buggy code and passes against the fix.

> **Superseded by §12.** The store-level integration follow-up was subsequently authorized and
> completed; the final suite is **620 tests, 26 skipped, 0 failures**. See §12.

---

## 10. Remaining limitations / next recommended action

1. **Not GUI-tested.** All verification is at the adapter, store, and live-database level. The
   SwiftUI panel's rendering of the corrected order was not exercised (per audit constraints).
2. ~~**Live acceptance of the *store* is not covered.**~~ **Closed by §12.** A store-level
   integration test now drives `ZenoObservabilityStore.refresh()` against a temporary
   `opencode.db` end-to-end (cold start, incremental poll, new-session pickup, duplicate
   suppression, memory bound, recovery).
3. **`lastPosition()` is currently unused in production.** Kept as a documented adapter accessor
   (used by tests/probes). If it stays unused, consider removing it to shrink the surface.
4. **Advisory (C5):** any future per-poll `MAX(rowid)` call costs ~8 ms on a 26 MB DB.

**Next recommended action:** do **not** begin Phase 14. The bounded store-level follow-up
(§12) is now complete; the wiring this audit fixed is pinned at the layer the UI actually calls.
The remaining work, if any, is the GUI rendering check — deliberately out of scope here.

---

## 11. Corrections to the Phase 13 report

- The claim *"The `seq` is contiguous per session… so this is safe"* conflated per-session
  contiguity with global ordering. It is true per session and **false** as a global cursor — the
  basis of finding C1.
- The claim *"A failed read never appears as a successful empty result"* was **not** true for
  runtime step errors — the basis of finding C2.
- The claim *"subsequent refreshes read only `seq > lastSeenEventSeq`"* described a mechanism that
  silently dropped new-session events.

---

## 12. Follow-up: store-level integration test (authorized 2026-10-10)

This section closes limitation #2 above. It was authorized as a bounded follow-up, not a feature
phase. No Phase 14 work was started.

### 12.1 What was missing

`ZenoObservabilityStoreTests` drives the store with HTTP mocks and **never injects a
`zenoDatabasePath`**. The store therefore reads Zeno's *live* data directory — absent in CI (the
read fails) or the developer's real data (a read that must not be depended on). The
cold-start-vs-poll branch in `readZenoEvents()` and the `lastSeenEventPosition` wiring in
`refresh()` were proven only at the **adapter** level, never at the layer the UI calls.

### 12.2 The test

New file: `PixelDesktopTests/ZenoEventStoreIntegrationTests.swift` (6 tests). Each test:

1. builds a temporary `opencode.db` in a private temp directory using Zeno's real schema
   (`event` with the `event_sequence` foreign key, plus `session` and `todo` so the store's
   session read succeeds);
2. wires a `ZenoObservabilityStore` to it via `zenoDatabasePath: dbPath`;
3. drives the **real** `store.refresh()` (the SQLite path is not mocked — only the HTTP sources
   are, with valid empty payloads).

Isolation: the store can reach Zeno's live database only through `defaultZenoDatabasePath()`,
which the injected `zenoDatabasePath` overrides. The test therefore cannot read or write live
data; the live DB is never touched. (This is the same reason the audit's §7 "unrelated systems
untouched" holds.)

### 12.3 Requirements → evidence

| Requirement | Test | Result |
|---|---|---|
| Cold start shows the **newest** 200 in correct order | `testColdStartShowsNewestEventsInOrderWithCursorAtHead` | Pass |
| Initial cursor = correct global insertion position | same | Pass (`lastSeenEventPosition == 250 == MAX(rowid)`) |
| Refreshes include new events from **existing + new** sessions | `testRefreshPicksUpNewEventsFromExistingAndNewSessions` | Pass |
| Overlapping per-session `seq` do **not** skip events | same | Pass (fixture: a `seq>9` cursor sees 2 of 4 new events; the store sees all 4) |
| Repeated refreshes introduce **no duplicates** | `testRepeatedRefreshesDoNotDuplicate` | Pass |
| Database-unavailable **recovery** after it appears | `testRecoversWhenDatabaseAppearsAndNeverReportsAFailedReadAsEmptyConnected` | Pass |
| A failed read is **not** reported as a successful empty result | same | Pass (`.unavailable`, not `.connected`-empty) |
| **Memory bounded** | `testTimelineMemoryStaysBounded` | Pass (≤200 across 3 polls appending 300 events) |
| Malformed rows do not stall the store cursor | `testMalformedRowDoesNotStallTheStoreCursor` | Pass |

The overlap fixtures are deliberately adversarial: multiple sessions each restarting `seq` at 0
and interleaved in insertion order — the exact shape that breaks a `seq`-based cursor.

### 12.4 Negative control (the test is not vacuous)

To prove the integration test actually discriminates, the store's cold-start branch was
**temporarily** reverted to the old forward-read (`readEventBatch(limit:)` instead of
`readRecentEvents(limit:)`) and the suite re-run:

```
XCTAssertEqual failed: (Optional(1)) is not equal to (Optional(51)) - the cold start must show the NEWEST events, not the oldest
XCTAssertEqual failed: (Optional(200)) is not equal to (Optional(250))
XCTAssertEqual failed: (Optional(200)) is not equal to (Optional(250)) - the initial cursor must be the global insertion head
Executed 6 tests, with 3 failures
```

The correct behavior was then restored (`readRecentEvents`) and the file re-verified by grep. The
test fails against the bug and passes against the fix — it is a real check, not a tautology.

### 12.5 Results

```
Targeted:  Executed 6 tests, with 0 failures
Full:      Executed 620 tests, with 26 tests skipped and 0 failures
Build:     ** TEST SUCCEEDED **  (builds cleanly; the 26 skips are the same pre-existing gates)
```

Changed files for this follow-up:

- **Added** `PixelDesktopTests/ZenoEventStoreIntegrationTests.swift`
- **Regenerated** `PixelDesktop.xcodeproj/project.pbxproj` (via `xcodegen generate`; the new file
  is source-controlled through `project.yml`, not hand-edited)
- **Updated** this document (§9 note, §10 limitation #2, and §12)

`PixelDesktop/App/Observability/ZenoObservabilityStore.swift` was **not** changed: the
negative-control edit was reverted before the final run (verified: line 291 is
`readRecentEvents(limit: Self.maxTimelineEvents)`).

### 12.6 Remaining limitations after §12

1. **GUI rendering still not exercised** (unchanged; out of scope).
2. **`lastPosition()` still unused in production** (unchanged; see §10.3).
3. The integration tests cover the store's event path; the store's *HTTP* paths remain covered by
   the existing mock-based tests, and the two suites do not overlap.

# Phase 12 — Actual Zeno Activity Observability (Reconnaissance & Plan)

**Author:** Ciel
**Date:** 2026-10-10
**Status:** RECONNAISSANCE COMPLETE — plan proposed, awaiting rnz authorization before any code.
**Scope:** Read-only investigation. No Zeno runtime modified, no authentication bypassed, no secret extracted.

---

## 1. What was investigated

Read-only inspection of: Zeno's live processes and listening ports, Zeno's application-support
directory, Zeno's OpenCode data directory, Zeno's structured log, Homebrew OpenCode's SQLite
database, and the existing PixelDesktop observability layer.

## 2. What data Zeno exposes today (VERIFIED)

### 2.1 A full OpenCode data directory, on disk, readable

Zeno runs an OpenCode-family runtime and persists its state to:

```
~/Library/Application Support/ai.zeno.desktop/data/opencode/
├── opencode.db          (26 MB SQLite; -wal 4 MB, live)
├── opencode.db-wal
├── storage/session_diff/
├── tool-output/         (9 large tool-result blobs, up to 5 MB each)
└── log/opencode.log     (370 KB structured log, live)
```

This is **not** a symlink to Homebrew OpenCode and is **not** the same database — it is Zeno's
own store, written by Zeno's own runtime (the `data/opencode` path is Electron's per-app
`userData` root, i.e. `ai.zeno.desktop`).

### 2.2 The database schema (VERIFIED)

Relevant tables and live row counts:

| Table | Rows | What it holds |
|---|---|---|
| `session` | 8 | One row per Zeno task, with title, directory, tokens, cost, timestamps |
| `message` | 202 | One row per message; `data` is JSON (role: user/assistant) |
| `part` | 774 | One row per message part; `data` is JSON |
| `todo` | 7 | Task plan items with content, status, priority |
| `event` | 3240 | Append-only event log (see §2.4) |
| `project` | 1 | Project metadata |
| `credential` | 0 | Empty — Zeno persists no credential here |

`part.data` types observed: `tool` (247), `text` (228), `step-start` (153), `step-finish` (140),
`patch` (5), `compaction` (1).

### 2.3 The sessions are real Zeno engineering work (VERIFIED)

The 8 sessions are genuine Zeno activity, e.g.:

- `LeadFlow — Logo Design and Brand` — 16,910 in / 23,208 out tokens
- `Inspect Zeno app architecture (@…)` — 67,998 in / 6,501 out
- `Trace references code path (@exp…)` — 69,915 in / 37,081 out
- `How well can you run on a macboo…` — 75,474 in / 4,880 out

The `todo` table for the LeadFlow session shows a real plan: *Review product description and
audience (completed)*, *Develop 3 distinct logo concepts (completed)*, *Export final assets
(pending)*, etc.

### 2.4 The event stream is structured and typed (VERIFIED)

`event.type` distribution across 3,240 rows:

| Type | Count |
|---|---|
| `message.part.updated.1` | 2296 |
| `message.updated.1` | 680 |
| `session.updated.1` | 241 |
| `session.next.model.switched.1` | 8 |
| `session.created.1` | 8 |
| `session.next.agent.switched.1` | 6 |
| `message.removed.1` | 1 |

Each row carries `aggregate_id`, a monotonic `seq`, and a JSON `data` payload. Sample
`session.created.1` payload includes the full session info (slug, projectID, directory, tokens,
cost). This is exactly the "structured event" shape the proposed architecture needs.

### 2.5 Tool and command execution is captured (VERIFIED)

`part.data` with `type == "tool"` carries the tool name, its input, and its result state:

```json
{"type":"tool","tool":"webfetch","callID":"call_…",
 "state":{"status":"completed","input":{"url":"…"},"output":"…"}}
```

Tool usage: `bash` (156), `write` (52), `read` (18), `glob` (9), `webfetch` (4), `todowrite` (2),
`task` (2), `skill` (2), `render_pptx_custom` (2). Status: `completed` 190, `error` **57**.

This is the source for "tool and command execution" and, via `status`, for "errors".

### 2.6 File changes are captured (VERIFIED, partial)

`part.data` with `type == "patch"` lists changed files and a git-style hash:

```json
{"type":"patch","hash":"012e21a6…","files":["…/ZENO.md","…/Zeno Dashboard/ZENO.md"]}
```

Only 5 patch parts exist, so this is a thinner signal than the others. A richer file-change
signal exists in the log (`message=tracking hash=… cwd=…`).

### 2.7 The structured log is live and parseable (VERIFIED)

`log/opencode.log` is line-oriented `key=value` with a level and a run id:

```
timestamp=2026-10-10T04:22:14.284Z level=INFO run=708b12de message=stream providerID=local …
timestamp=2026-10-10T04:22:49.066Z level=WARN run=708b12de message="failed to add snapshot files" …
```

Observed `message=` values include `loop session`, `process session`, `stream provider`,
`tracking hash`, `evaluated permission`, `cancel session`, `pruning`. This is a supplementary
signal (build/test/error events) but its vocabulary is internal and undocumented.

### 2.8 Liveness and readability (VERIFIED)

- The DB is readable **read-only while Zeno holds it open**: `sqlite3 -readonly` queries succeed
  with no lock error, and the `-wal` file is present (WAL mode).
- The DB, WAL, and log all carry timestamps from minutes ago — Zeno is actively writing.
- There is currently **no live session** (latest event is `message.updated.1`, no running loop),
  so a poll now returns a quiescent state; the mechanism is what is being verified, not activity.

## 3. Which sources are verified and accessible

| Source | Path / address | Access | Verified |
|---|---|---|---|
| Zeno sessions | `…/data/opencode/opencode.db` → `session` | read-only SQLite | ✅ 8 rows |
| Zeno messages/parts | same → `message`, `part` | read-only SQLite | ✅ 202 / 774 |
| Zeno todos (task plan) | same → `todo` | read-only SQLite | ✅ 7 |
| Zeno structured events | same → `event` | read-only SQLite | ✅ 3240 |
| Zeno tool/command exec | `part.data.type == tool` | read-only SQLite | ✅ 247 |
| Zeno file changes | `part.data.type == patch` | read-only SQLite | ✅ 5 |
| Zeno build/test/error log | `…/log/opencode.log` | read-only file tail | ✅ live |
| Zeno HTTP runtime API | `127.0.0.1:55811` | **401 — blocked** | ❌ by design |
| Homebrew OpenCode API | `127.0.0.1:49374` | 401 unauthenticated (credentialed in app) | ✅ app path |
| Zeno model server | `127.0.0.1:55823` | open | ✅ |

## 4. What is missing

1. **No push mechanism.** Zeno exposes no WebSocket and no documented read-only event endpoint;
   the DB and log are poll targets, not subscriptions.
2. **No Zeno runtime HTTP access.** The `55811` API stays 401. Filesystem reading is the
   workaround; it is not a sanctioned API and its schema may change with a Zeno update.
3. **No first-class "build/test result" field.** Build and test outcomes appear only indirectly —
   as `bash` tool calls with exit statuses inside `part.data`, or as log lines. There is no
   `build_result` record.
4. **No stable event vocabulary.** `event.type` values carry a `.1` suffix (a versioning hint)
   and are undocumented for this fork.
5. **No filesystem-route latency guarantee.** Polling a WAL-mode DB is safe but not push-live; the
   dashboard will show activity with the poll interval's lag.
6. **Path coupling.** The data directory is derived from the app's `userData` root; a Zeno
   reinstall or bundle-id change moves it.

## 5. The proposed architecture, and why

The requested shape was:

```
Zeno → Structured Events → Dashboard API → WebSocket → PixelDesktop UI
```

**Recommendation: adopt the shape, but replace the two middle boxes for the MVP.**

```
Zeno runtime
  └─ writes ─▶ …/data/opencode/opencode.db  (event, session, part, todo)
  └─ writes ─▶ …/log/opencode.log
                    │
                    ▼  (read-only, polled)
        ZenoSessionStoreAdapter   ← a new adapter in PixelDesktop/Observability/
                    │  emits the SAME OpenCodeSession/Message/Event shapes
                    ▼
        ZenoObservabilityStore    ← existing store, unchanged contract
                    │  @Published
                    ▼
        existing SwiftUI views    ← unchanged (already source-isolated)
```

**Why this and not a Dashboard API + WebSocket:**

- **No component to build that does not exist.** A "Dashboard API" would be a new service that
  Zeno does not provide and that we would have to write and run; a WebSocket server would be a
  second new process. Both add operational surface for a read-only panel. The store already
  isolates sources, so a third adapter slots in with **zero view changes** — the architecture doc
  reached the same conclusion (§11, route 2).
- **It is honest.** The adapter reports "read from Zeno's own data store" and the panel keeps the
  **Zeno OpenCode** label. No data is relabelled.
- **It reuses the transport seam correctly.** The existing seam is a transport *protocol*
  (`ObservabilityHTTPTransport`). A filesystem/SQLite adapter is a sibling implementation of the
  same seam, so the decoding/classification/presentation above it is untouched and stays
  deterministically testable offline.

**A WebSocket is still the right long-term answer** — but it requires Zeno to expose one, which is
a change to Zeno (out of scope, needs authorization). The filesystem adapter is the honest MVP
that delivers real Zeno activity now, and it is replaceable later without touching the views.

## 6. The smallest useful MVP

**MVP-12: a read-only "Zeno Activity" source, sourced from Zeno's own SQLite store.**

1. A new `ZenoSessionStoreAdapter` (Foundation-only, read-only) that:
   - locates the DB via an overridable env var, default derived from the home dir
     (`PIXELDESKTOP_ZENO_DATA_DIR`, default `~/Library/Application Support/ai.zeno.desktop/data/opencode`);
   - opens `opencode.db` **read-only** (`?mode=ro` / `SQLITE_OPEN_READONLY`);
   - reads `session`, `todo`, and `part`-type counts; maps `session` rows into the existing
     `OpenCodeSession` shape.
2. A `zenoActivityStatus` + `zenoSessions` + `zenoTodos` published surface on the store (or a
   parallel small store) — **additive only**, existing fields untouched.
3. A **Zeno Activity** panel that reuses `SessionRow` / `OutcomeBadge` / `PanelHeader`, labelled
   **Zeno OpenCode**, with the same empty/unknown/error states.
4. Tests: a `MockSQLiteSource` fixture with captured rows → deterministic decoding tests; the
   store's existing honesty rules (absence ≠ success) applied to the new fields.
5. Explicitly **out of MVP**: writes of any kind, a Dashboard API service, a WebSocket, log
   parsing, build/test classification, and any HTTP call to `55811`.

**Deliberately excluded from the MVP, and why:** `event`-table streaming (3240 rows, high churn)
and log parsing (undocumented vocabulary) are deferred until the session/todo read is proven —
they add cost without adding the core signal.

## 7. Required changes

| Change | Files | Risk |
|---|---|---|
| New read-only SQLite adapter | `PixelDesktop/Observability/ZenoSessionStoreAdapter.swift` | low — additive |
| Read-only SQLite seam (protocol) | `PixelDesktop/Observability/SQLiteSource.swift` | low — mirrors transport seam |
| Additive store surface | `ZenoObservabilityStore.swift` (additive only) | **medium** — touches a frozen contract; must be additive, reviewed |
| New panel + wiring | `App/Observability/…`, `RootView.swift` | low |
| Tests + fixtures | `PixelDesktopTests/…` | low |

**Do not** modify Zeno's runtime, read `service.json`, call `55811`, or write to any Zeno file.

## 8. Risks

1. **Schema drift** — a Zeno update may change `opencode.db`. Mitigation: read only stable columns;
   fail soft to a "cannot read Zeno store" state, never fabricate.
2. **Frozen-contract breach** — adding fields to `ZenoObservabilityStore` risks the existing 574
   tests. Mitigation: additive-only, full suite must still report 574/26/0.
3. **Path coupling** — the data dir is Electron-derived. Mitigation: env override + graceful
   absence.
4. **Reading a live DB** — WAL mode makes read-only opens safe, but a long read could see a
   mid-transaction snapshot. Mitigation: short reads, tolerate inconsistency, never write.
5. **False "Zeno is idle"** — a quiescent DB is not proof Zeno is stopped. Mitigation: label the
   panel's freshness; never render absence as "no activity".

## 9. Acceptance criteria (for the eventual implementation)

- [ ] `xcodebuild test` still reports **574 tests, 26 skipped, 0 failures** (additive change only).
- [ ] The new panel renders real Zeno sessions with the **Zeno OpenCode** label.
- [ ] `grep -r "service.json" PixelDesktop/` returns nothing; no secret in any file/log.
- [ ] The adapter opens the DB **read-only** — a write attempt must be impossible by construction.
- [ ] Zeno's runtime is unmodified and `55811` is never called by the adapter.
- [ ] Absence (no Zeno store, empty DB) renders as an explicit state, never as "no activity".
- [ ] Offline decoding tests exist for the adapter using captured rows.

## 10. Implementation (MVP-12)

**Status:** Implemented (2026-10-10).

### Files added

| File | Purpose |
|---|---|
| `PixelDesktop/Observability/ZenoSQLiteModels.swift` | `ZenoSession`, `ZenoSessionTodo` models |
| `PixelDesktop/Observability/SQLiteDatabaseReader.swift` | Read-only SQLite3 C API wrapper |
| `PixelDesktop/Observability/ZenoSessionStoreAdapter.swift` | Maps SQLite rows to models |
| `PixelDesktop/App/Observability/ZenoSQLiteSessionViews.swift` | Zeno session list + detail views |
| `PixelDesktopTests/ZenoSQLiteAdapterTests.swift` | 11 adapter tests with real SQLite |

### Files modified

| File | Change |
|---|---|
| `PixelDesktop/App/Observability/ZenoObservabilityStore.swift` | Added `zenoSQLiteStatus`, `zenoSessions`, `selectedZenoSessionID`, `isLoadingZenoSessions`, `readZenoSessions()`, `selectZenoSession()`, `clearZenoSelection()`, `defaultZenoDatabasePath()` |
| `PixelDesktop/App/Observability/ZenoDashboardView.swift` | Wired `ZenoSQLiteSessionPanel` into the dashboard |

### Key decisions

1. **`ZenoSession` is a separate type from `OpenCodeSession`.** The SQLite `session` table has columns the HTTP API does not expose (`title`, `agent`, `model`). Rather than widen `OpenCodeSession` (which would change its Homebrew decoding contract), a dedicated type carries the full SQLite shape. A `bridge()` method maps the shared subset onto `OpenCodeSession` so `SessionRow` can be reused.

2. **`SQLiteRow` is a `class`, not a `struct`.** Column-index resolution caches on the row instance. A `struct` would copy the cache on every accessor call, defeating it.

3. **The adapter reads a real SQLite database, not a mock.** The test suite creates actual SQLite databases in a temp directory and exercises the full C interop → adapter → model path. This is the same pattern as `Captured` in `ObservabilityTests`.

4. **The `model` column is parsed defensively.** It stores a JSON object like `{"id":"...","providerID":"...","variant":"..."}`. Malformed JSON yields `nil`, not a crash.

5. **Environment override.** The database path is `PIXELDESKTOP_ZENO_DATA_DIR`, defaulting to `~/Library/Application Support/ai.zeno.desktop/data/opencode/opencode.db`.

6. **No global error banner.** A failed SQLite read is shown on the Zeno OpenCode Sessions panel only, never as a global banner: it is an alternate source for a panel that already has its own unavailable state.

### Test results

- Adapter tests: 11 tests, all passing (real SQLite databases, not mocks)
- Full suite: 585 tests (574 baseline + 11 new), 26 skipped, 0 failures
- Live observability tests: 4 tests, unchanged

### What was deliberately not implemented

- Event-table streaming (3240 rows, high churn)
- Log parsing (undocumented vocabulary)
- Build/test classification
- WebSocket or any push mechanism
- Any write to Zeno's database
- Any HTTP call to port 55811

## 11. Recommendation

**MVP-12 is complete.** The dashboard now shows real Zeno OpenCode sessions read from Zeno's own SQLite database. The next highest-value step is event-table streaming (to show live activity), but that requires a separate design phase due to the high churn and undocumented vocabulary.

**Phase 12 MVP-12 is done.**

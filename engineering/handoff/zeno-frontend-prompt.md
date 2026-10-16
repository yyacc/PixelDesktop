# Zeno Frontend Task — Self-Contained Prompt

**Paste this entire document into Zeno.**

---

## Context

You are improving the presentation layer of a read-only observability dashboard in a native macOS
SwiftUI application called PixelDesktop. The backend (API clients, data models, store, tests) is
already implemented and tested. Your job is exclusively the SwiftUI views: layout, information
hierarchy, empty/loading/error affordances, and readability.

The dashboard monitors three separate local services:
1. **Homebrew OpenCode** at `127.0.0.1:49374` — provides sessions, messages, agents, config, events
2. **Zeno Flashmoe** at `127.0.0.1:55823` — provides model information only
3. **Zeno OpenCode API** at `127.0.0.1:55811` — currently returns HTTP 401 (authentication required)

The critical architectural rule: **Homebrew OpenCode and Zeno are completely separate services.**
Never label Homebrew OpenCode data as Zeno data. Never merge their data. Never imply unavailable
Zeno session data is available.

## Repository

- **Path:** `~/AICompany/PixelDesktop/`
- **Build:** `xcodebuild build -project PixelDesktop.xcodeproj -scheme PixelDesktop -destination 'platform=macOS' -derivedDataPath ./build`
- **Test:** `xcodebuild test -project PixelDesktop.xcodeproj -scheme PixelDesktop -destination 'platform=macOS' -derivedDataPath ./build`
- **Project generation:** `xcodegen generate` (new files under existing source directories are picked up automatically)

## Files You May Change (presentation only)

- `PixelDesktop/App/Observability/ZenoDashboardView.swift`
- `PixelDesktop/App/Observability/ZenoSessionViews.swift`
- `PixelDesktop/App/Observability/ZenoSourcePanelsView.swift`
- `PixelDesktop/App/Observability/ZenoSQLiteSessionViews.swift`
- `PixelDesktop/App/Observability/ObservabilityFormat.swift`
- `PixelDesktop/App/RootView.swift` (layout of the workspace switcher only)

## Files You Must NOT Change

- Everything under `PixelDesktop/Observability/` (clients, models, parser, transport, credentials)
- `PixelDesktop/App/Observability/ZenoObservabilityStore.swift` (the store's published surface is
  the contract; new *read-only* computed helpers may be requested but not added unilaterally)
- Any existing test, and `ContentView` / the device workspace
- `project.yml` targets, other than adding files that already fall under existing directory sources

## The Store Contract

The store (`ZenoObservabilityStore`) publishes exactly this surface (all `@Published private(set)`,
all read-only unless noted):

```swift
// Homebrew OpenCode
var openCodeStatus: ServiceStatus
var sessions: [OpenCodeSession]
var agents: [OpenCodeAgent]
var configEntries: [OpenCodeConfigEntry]
var isLoadingSessions: Bool
var selectedSessionID: String?          // settable via selectSession(_:)
var messages: [OpenCodeMessage]
var isLoadingMessages: Bool
var messageError: ObservabilityError?

// Zeno model server
var modelServerStatus: ServiceStatus
var models: [ModelInfo]

// Zeno runtime
var zenoOpenCodeStatus: ServiceStatus

// Zeno SQLite sessions (read-only, from Zeno's own database)
var zenoSQLiteStatus: ServiceStatus
var zenoSessions: [ZenoSession]
var selectedZenoSessionID: String?          // settable via selectZenoSession(_:)
var isLoadingZenoSessions: Bool

// Live events
var isStreamingEvents: Bool
var recentEvents: [SSEEvent]
var eventStreamError: ObservabilityError?

// Refresh bookkeeping
var lastRefreshed: Date?
var isRefreshing: Bool
var lastError: ObservabilityError?
let config: ObservabilityConfig
```

Callable methods: `refresh()`, `selectSession(_:)`, `clearSelection()`, `startEventStream()`,
`stopEventStream()`, `startPolling()`, `stopPolling()`, `selectZenoSession(_:)`.

## The Five Rules (acceptance criteria, not suggestions)

1. **Every panel names its source.** A panel rendering `sessions` must say "Homebrew OpenCode".
   A panel rendering `models` must say "Zeno Flashmoe". Never imply Homebrew OpenCode's sessions
   are Zeno's.
2. **Absence renders as absence.** A `nil` outcome/timestamp/token count renders as "—", never
   as a plausible default and never as success. `OutcomeStyle.colorName(for: nil)` is grey.
3. **Four service states are visually distinct:** `.unknown` ("Not checked"), `.connected`,
   `.authenticationRequired` ("Unavailable — Authentication Required"), `.unavailable`.
   `.authenticationRequired` must not be drawn the same as `.unavailable`.
4. **An empty list is not an error.** `.connected` + empty renders as an empty state.
5. **No credentials anywhere.** Do not read, log, display or embed anything from
   `~/.config/opencode/service.json`.

## Read-Only Constraint

The MVP is read-only. Do not implement remote command execution, agent control, file modification
through an agent API, or automatic configuration changes.

## Deliverables

1. A polished dashboard that satisfies the acceptance criteria above.
2. Loading, empty, disconnected, authentication-error and general-error states for each panel.
3. A last-refreshed indicator that shows "never" when `lastRefreshed == nil`.
4. Manual Refresh, and Start/Stop for the live event stream.
5. Screenshots (light and dark appearance) at `engineering/design/screenshots/`.
6. A short notes file `engineering/design/zeno-frontend-notes.md` describing what changed and any
   place where the contract was insufficient.

## Acceptance Criteria (self-check before handing back)

- [ ] `xcodebuild build` succeeds with no new warnings.
- [ ] `xcodebuild test` still reports **585 tests, 26 skipped, 0 failures** — no test deleted,
      weakened, or newly skipped.
- [ ] The dashboard is reachable from the workspace switcher and renders with a device attached
      **and** with none attached.
- [ ] All five rules in "The five rules" are visibly satisfied.
- [ ] `grep -r "service.json" PixelDesktop/App/` returns nothing.
- [ ] No secret appears in any file, log, or screenshot.

## What to Report Back

When done, report:
1. Every changed file with a summary of what changed and why.
2. Every design decision you made and the reasoning behind it.
3. Build and test output (paste the actual output).
4. Known limitations or places where the store contract was insufficient.
5. Any unresolved issues.
6. The screenshots you captured.

# Handoff: Frontend task for Zeno — Zeno Observability dashboard

**Prepared by:** Ciel
**Date:** 2026-10-09
**Status:** READY — awaiting rnz to hand this to Zeno.
**Context:** The read-only backend, data layer, store and a first-pass SwiftUI dashboard are
implemented and tested (585 tests, 0 failures). Zeno's contribution is the **presentation layer**:
making the dashboard genuinely usable and reviewing the existing views against the stated
acceptance criteria.

> **Do not paste anything below into Zeno until rnz says so.** Ciel and Zeno do not communicate
> directly; rnz is the intermediary.

---

## What Zeno is being asked to do

Improve and complete the SwiftUI presentation layer of the Zeno Observability dashboard. The
backend, models, store and tests are done and must not be changed in ways that break them. The
work is UI/UX: layout, information hierarchy, empty/loading/error affordances, and readability of
the session/message views.

---

## Repository and scope

- **Repo:** `~/AICompany/PixelDesktop/`
- **Build:** `xcodebuild build -project PixelDesktop.xcodeproj -scheme PixelDesktop -destination 'platform=macOS' -derivedDataPath ./build`
- **Test:** `xcodebuild test -project PixelDesktop.xcodeproj -scheme PixelDesktop -destination 'platform=macOS' -derivedDataPath ./build`
- **Project generation:** `xcodegen generate` (sources are directory-based, so new files under
  `PixelDesktop/App/Observability/` are picked up automatically; run it after adding files).

### Files Zeno may change (presentation only)

- `PixelDesktop/App/Observability/ZenoDashboardView.swift`
- `PixelDesktop/App/Observability/ZenoSessionViews.swift`
- `PixelDesktop/App/Observability/ZenoSourcePanelsView.swift`
- `PixelDesktop/App/Observability/ObservabilityFormat.swift`
- `PixelDesktop/App/RootView.swift` (layout of the workspace switcher only)

### Files Zeno must NOT change

- Everything under `PixelDesktop/Observability/` (clients, models, parser, transport, credentials)
- `PixelDesktop/App/Observability/ZenoObservabilityStore.swift` (the store's published surface is
  the contract; new *read-only* computed helpers may be requested but not added unilaterally)
- Any existing test, and `ContentView` / the device workspace
- `project.yml` targets, other than adding files that already fall under existing directory sources

---

## The contract Zeno must render against

The store publishes exactly this surface (all `@Published private(set)`, all read-only):

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
`stopEventStream()`, `startPolling()`, `stopPolling()`.

### The rules the UI must preserve (these are acceptance criteria, not suggestions)

1. **Every panel names its source.** A panel rendering `sessions` must say "Homebrew OpenCode". A
   panel rendering `models` must say "Zeno Flashmoe". Never imply Homebrew OpenCode's sessions are
   Zeno's.
2. **Absence renders as absence.** A `nil` outcome/timestamp/token count renders as "—", never as a
   plausible default and never as success. `OutcomeStyle.colorName(for: nil)` is grey.
3. **Four service states are visually distinct:** `.unknown` ("Not checked"), `.connected`,
   `.authenticationRequired` ("Unavailable — Authentication Required"), `.unavailable`.
   `.authenticationRequired` must not be drawn the same as `.unavailable`.
4. **An empty list is not an error.** `.connected` + empty renders as an empty state.
5. **No credentials anywhere.** Do not read, log, display or embed anything from
   `~/.config/opencode/service.json`.
6. **Read-only.** No control that starts, stops, submits to, or configures a service.

---

## Deliverables

1. A polished dashboard that satisfies the acceptance criteria above.
2. Loading, empty, disconnected, authentication-error and general-error states for each panel.
3. A last-refreshed indicator that shows "never" when `lastRefreshed == nil`.
4. Manual Refresh, and Start/Stop for the live event stream.
5. Screenshots (light and dark appearance) at `engineering/design/screenshots/`.
6. A short notes file `engineering/design/zeno-frontend-notes.md` describing what changed and any
   place where the contract was insufficient.

## Acceptance criteria (Zeno self-checks before handing back)

- [ ] `xcodebuild build` succeeds with no new warnings.
- [ ] `xcodebuild test` still reports **585 tests, 26 skipped, 0 failures** — no test deleted,
      weakened, or newly skipped.
- [ ] The dashboard is reachable from the workspace switcher and renders with a device attached
      **and** with none attached.
- [ ] All five rules in "The rules the UI must preserve" are visibly satisfied.
- [ ] `grep -r "service.json" PixelDesktop/App/` returns nothing.
- [ ] No secret appears in any file, log, or screenshot.

## Handing back

Return: the list of changed files, the build/test output, the screenshots, and the notes file.
Ciel will review the diff against the criteria above before it is accepted.

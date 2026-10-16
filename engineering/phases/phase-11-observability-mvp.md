# Phase 11 — Zeno Observability MVP

**Date:** 2026-10-09
**Status:** COMPLETE (MVP)
**Tests:** 574 executed, 26 skipped, 0 failures (baseline was 506/22; +68 tests)

---

## Objective

Build a read-only dashboard inside the PixelDesktop macOS app that displays verified data from the
local coding-agent services, as the first step toward the shared Ciel–Zeno workspace.

---

## What was recovered

The existing project was inspected before anything was changed, and **nothing pre-existing was
discarded**:

- The two uncommitted changes (`project.pbxproj`, `created-resources.json`) were preserved.
- The untracked engineering assessments and `pilot-9sel-evidence/` were preserved.
- `ContentView` and the entire device workspace were left untouched — the dashboard is a sibling
  under a new `RootView`, not a modification of the device UI.
- The existing 506-test suite was left intact; no test was deleted or weakened.

---

## Environment audit (verified, not assumed)

| Fact | Evidence |
|---|---|
| Homebrew OpenCode running | `opencode serve --service` on `127.0.0.1:49374`, 44 sessions readable |
| Zeno model server running | `flashmoe` on `127.0.0.1:55823`, `/v1/models` returns one model |
| Zeno runtime unreachable | `127.0.0.1:55811` answers **401** |
| Zeno's runtime credential is not obtainable | Password is `randomUUID()` at launch, passed over Electron IPC, never written to disk (confirmed by reading the app's `sidecar.js`) |
| Pixel 7a attached and authorized | `3C261JEHN25632`, Android 16 / SDK 36 / arm64-v8a |

The historical ports quoted in the mission brief (`57946`, `57961`) were **stale** — the live
runtime is on `55811`/`55823`. The audit is what caught that.

---

## Decision

Implemented as **Situation C + a partial B** from the brief:

- **Homebrew OpenCode** — full read: sessions, messages, agents, configuration, live events.
- **Zeno model server** — model information only.
- **Zeno OpenCode runtime** — reported "Unavailable — Authentication Required", not bypassed.

Recorded in [ADR-016](../decisions/ADR-016-zeno-observability-dashboard.md) and
[the architecture doc](../design/zeno-observability-architecture.md).

---

## Deliverables

**Core (Foundation-only, compiles into both the app and CLI targets)**

- `PixelDesktop/Observability/ObservabilityConfig.swift` — configurable addresses, no hardcoded ports in views
- `PixelDesktop/Observability/ObservabilityError.swift` — typed errors; credential-free by construction
- `PixelDesktop/Observability/ServiceStatus.swift` — connected / authenticationRequired / unavailable / unknown
- `PixelDesktop/Observability/OpenCodeModels.swift` — session, message, agent, config, model types
- `PixelDesktop/Observability/SSEParser.swift` — byte-level event-stream parser
- `PixelDesktop/Observability/ObservabilityHTTP.swift` — the transport seam + `URLSession` implementation
- `PixelDesktop/Observability/CredentialProvider.swift` — reads `service.json` on demand, never caches
- `PixelDesktop/Observability/OpenCodeClient.swift` — read-only OpenCode client (GET only)
- `PixelDesktop/Observability/ModelServerClient.swift` — read-only model-server client

**App (SwiftUI)**

- `PixelDesktop/App/Observability/ZenoObservabilityStore.swift` — observable state
- `PixelDesktop/App/Observability/ZenoDashboardView.swift` — dashboard shell + source cards
- `PixelDesktop/App/Observability/ZenoSessionViews.swift` — session list, detail, messages
- `PixelDesktop/App/Observability/ZenoSourcePanelsView.swift` — models, agents, config, events
- `PixelDesktop/App/Observability/ObservabilityFormat.swift` — absence-renders-as-absence rules
- `PixelDesktop/App/RootView.swift` — workspace switcher (new sibling; `ContentView` untouched)

**Tests**

- `PixelDesktopTests/ObservabilityTests.swift` — 45 tests: decoding against captured payloads, error
  classification, credential containment, SSE parsing, configuration
- `PixelDesktopTests/ZenoObservabilityStoreTests.swift` — 19 tests: state transitions, source
  isolation, empty vs. unavailable
- `PixelDesktopTests/ObservabilityLiveTests.swift` — 4 opt-in tests against the running services

---

## Defects found and fixed during the phase

1. **A mock routed by path only.** `MockHTTPTransport` handed Homebrew's session payload to Zeno's
   runtime client because both answer `/api/session`. Three store tests failed. The fix (route by
   port) is the correct one, and the failure is itself evidence that the source distinction is real.
2. **`SSEParser` mis-parsed CRLF — a genuine product bug.** Swift treats `"\r\n"` as a *single*
   grapheme cluster, so a `Character`-based scanner never matches the line break in a CRLF stream.
   The parser was rewritten to scan UTF-8 bytes. Caught by `testSSEHandlesCRLFLineEndings`, which
   then crashed the test process on `events[0]` — the assertion was hardened to `first` so a
   regression fails instead of crashing.

---

## Verification

```
xcodebuild build  →  ** BUILD SUCCEEDED **
xcodebuild test   →  Executed 574 tests, with 26 skipped and 0 failures  ** TEST SUCCEEDED **
TEST_RUNNER_PIXELDESKTOP_LIVE_OBSERVABILITY=1 … -only-testing:ObservabilityLiveTests
                  →  Executed 4 tests, with 0 failures  ** TEST SUCCEEDED **
```

Live tests confirmed against the running services: Homebrew OpenCode readable with sessions and
agents, model server readable with one model, Zeno runtime never `connected`, live event stream
opening and yielding `server.connected`.

The app was launched (`open -g`, no focus steal), ran for 6 s without crashing, and was terminated
cleanly.

---

## Known limitations

1. **No Zeno session data** — blocked on the unreachable runtime credential.
2. **No view-layer tests** — SwiftUI views are not unit-tested; the store and client surface is.
3. **Event payloads shown raw** — not interpreted.
4. **Fixed 10 s poll** while visible; not user-configurable.

---

## Next step

Observe Zeno's sessions **from the filesystem** rather than its HTTP API. OpenCode-family runtimes
persist session state under their data directory; a filesystem adapter producing the same
`OpenCodeSession` shape would slot into the store's existing per-source isolation with no change to
the views. This is the only route to genuine Zeno session observability that does not require
Zeno's cooperation or any bypass.

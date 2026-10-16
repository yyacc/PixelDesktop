# Zeno Observability — Architecture and Data Flow

**Status:** Implemented (MVP + Phase 12 SQLite adapter)
**Date:** 2026-10-10
**Scope:** Read-only dashboard inside the PixelDesktop macOS app.

---

## 1. What this is

A read-only panel that shows what the local coding-agent services on this machine are doing. It
is the first step toward the shared Ciel–Zeno workspace: the point of this MVP is to establish
that **verified, honestly-labelled** data can be read from those services and rendered, before
any of the harder questions (agent-to-agent messaging, task submission) are approached.

It reads. It does not write, submit, start, stop, or configure anything.

---

## 2. The three services, and why they are kept separate

Three local HTTP services are relevant. They are **not** interchangeable, and the dashboard never
merges them.

| Service | Address | Auth | What it provides | Label in UI |
|---|---|---|---|---|
| Homebrew OpenCode | `127.0.0.1:49374` | Basic (`opencode:<password>`) | Sessions, messages, agents, configuration, event stream | **Homebrew OpenCode** |
| Zeno model server ("flashmoe") | `127.0.0.1:55823` | none | Model listing (`/v1/models`) | **Zeno Flashmoe** |
| Zeno OpenCode runtime | `127.0.0.1:55811` | Basic, **credential unreachable** | — (401) | **Zeno OpenCode** |

### Why Zeno's runtime cannot be read

Zeno's runtime password is generated at launch with `randomUUID()`, handed to its sidecar over
Electron IPC, and used only in memory:

```
const password = randomUUID();
// → parentPort.postMessage({ type: "start", password, ... })
// → sidecar: process.env.OPENCODE_SERVER_PASSWORD = password
```

It is never written to disk, so it cannot be read from outside the app. The dashboard therefore
reports that service as **"Unavailable — Authentication Required"** and does not attempt to
recover the credential. This is a deliberate boundary, not an unfinished feature.

### Why the labels matter more than they look

Homebrew OpenCode and Zeno's runtime speak the same wire protocol. A session decoded from one is
byte-for-byte identical in shape to a session decoded from the other. If the dashboard ever lost
track of which service a row came from, it would silently misattribute activity — presenting
Homebrew OpenCode's 44 failed sessions as Zeno's work. The `ObservabilitySourceLabel` is carried
alongside the data and rendered on every panel specifically so that cannot happen by accident.

---

## 3. Data flow

```
┌─────────────────────────────────────────────────────────────────────┐
│ ZenoDashboardView / ZenoSessionViews / ZenoSourcePanelsView         │
│   render only; compute nothing                                      │
└───────────────────────────────┬─────────────────────────────────────┘
                                │ @EnvironmentObject
┌───────────────────────────────▼─────────────────────────────────────┐
│ ZenoObservabilityStore  (@MainActor, ObservableObject)              │
│   · refresh()  — reads all three services concurrently              │
│   · selectSession(_:)                                               │
│   · startEventStream() / stopEventStream()                          │
│   · startPolling() / stopPolling()   (10 s, while the view is up)   │
└───────────────────────────────┬─────────────────────────────────────┘
                                │
        ┌───────────────────────┼────────────────────────┐
        ▼                       ▼                        ▼
┌────────────────┐   ┌──────────────────┐   ┌──────────────────────┐
│ OpenCodeClient │   │ ModelServerClient│   │ OpenCodeClient        │
│ (Homebrew,     │   │ (flashmoe)       │   │ (Zeno runtime,        │
│  credentialed) │   │                  │   │  no credential)       │
└───────┬────────┘   └────────┬─────────┘   └──────────┬───────────┘
        │                     │                        │
        └──────────┬──────────┴────────────────────────┘
                   ▼
        ┌──────────────────────────────────────────┐
        │ ObservabilityJSONGetter                  │
        │   status → 2xx decode | 401/403 → auth    │
        │           | other → httpStatus            │
        │           | decode failure → decoding     │
        └──────────────────┬───────────────────────┘
                           ▼
        ┌──────────────────────────────────────────┐
        │ ObservabilityHTTPTransport (protocol)    │
        │   production: URLSessionHTTPTransport    │
        │   tests:      MockHTTPTransport          │
        └──────────────────────────────────────────┘
```

The transport protocol is the **only** seam. Everything above it — decoding, error
classification, status mapping, sorting, presentation — is deterministic and is exercised offline
against captured payloads.

---

## 4. Where every dashboard field comes from

No field is computed or inferred. Each maps to a verified endpoint.

### Sessions panel — source: Homebrew OpenCode

| UI field | Source |
|---|---|
| Session ID | `GET /api/session` → `data[].id` |
| Outcome badge | `data[].outcome` (absent → rendered "—") |
| Directory | `data[].location.directory` |
| Created / Updated / Idle | `data[].time.created` / `.updated` / `.idle` (ms since epoch) |
| Token count | `data[].tokens.{input,output,reasoning}` |

### Session detail — source: Homebrew OpenCode

| UI field | Source |
|---|---|
| Project ID | `data[].projectID` |
| Cost | `data[].cost` |
| Messages | `GET /api/session/{id}/message` → `data[]` |
| Message type | `data[].type` |
| Message text | `data[].text` |
| Message outcome | `data[].outcome` |

### Models panel — source: Zeno Flashmoe

| UI field | Source |
|---|---|
| Model ID | `GET /v1/models` → `data[].id` |
| Owner | `data[].owned_by` |
| Advertised at | `data[].created` |

### Agents panel — source: Homebrew OpenCode

| UI field | Source |
|---|---|
| Name / ID | `GET /api/agent` → `data[].name` / `.id` |
| Description | `data[].description` |
| Mode | `data[].mode` |
| Hidden | `data[].hidden` |
| Permission count | `data[].permissions.count` |

### Configuration panel — source: Homebrew OpenCode

| UI field | Source |
|---|---|
| Document path | `GET /api/config` → `[].path` where `type == "document"` |
| Model | `[].info.model.model` |
| Provider | `[].info.model.providerID` |

### Live events panel — source: Homebrew OpenCode

| UI field | Source |
|---|---|
| Event type | `GET /api/event` (SSE) → `event:` field |
| Event payload | SSE `data:` field |

---

## 5. Verified endpoints and their limits

Verified live on 2026-10-09 against the running services.

| Endpoint | Service | Verified behaviour |
|---|---|---|
| `GET /api/session` | Homebrew OpenCode | 200, `{"data":[...]}`. 44 sessions, all `outcome:"failed"`. |
| `GET /api/session/{id}/message` | Homebrew OpenCode | 200, `{"data":[...],"cursor":{...}}`. |
| `GET /api/agent` | Homebrew OpenCode | 200, `{"data":[...]}`. 7 agents. |
| `GET /api/config` | Homebrew OpenCode | 200, bare array of documents and directories. |
| `GET /api/event` | Homebrew OpenCode | 200 `text/event-stream`; opens with `server.connected`, then `: heartbeat` comments. |
| `GET /v1/models` | Zeno Flashmoe | 200, OpenAI-compatible model list. One model: `mlx-community/Qwen3.6-35B-A3B-4bit`. |
| `GET /api/session` | Zeno runtime | **401** — credential unreachable by design. |

### Limits

- **No Zeno session data.** Zeno's runtime is unreadable; only its model server is. The dashboard
  says so plainly rather than substituting Homebrew OpenCode's data.
- **No write path.** No session creation, message submission, agent control, or config change.
- **Event payloads are shown raw.** The SSE `data:` field is rendered as text; this dashboard does
  not interpret event semantics, because the event vocabulary is the server's to define and it is
  not documented for this fork.

---

## 6. Credential handling

- The password is read from `~/.config/opencode/service.json` **on each request**, never cached.
- It lives only in `BasicAuth`, which is deliberately not `CustomStringConvertible`; the only code
  that reads it is `URLSessionHTTPTransport.basicHeader`.
- It is sent only to the configured Homebrew OpenCode origin, never to the model server or Zeno's
  runtime (both are constructed without a credential provider).
- It never enters a log, an error description, the UI, a test fixture, or the repository. Two
  tests assert this directly: one that a decoding error's description does not echo the body, one
  that no `ObservabilityError` description can contain the password.
- The credential file path is overridable via `PIXELDESKTOP_OPENCODE_CREDENTIAL_FILE`; the default
  is derived from the home directory, so no absolute path is hardcoded in source.

---

## 7. Honesty rules (the properties the tests enforce)

1. **Absence renders as absence.** A missing outcome, timestamp, or token count is "—", never a
   plausible default. `OutcomeStyle.colorName(for: nil)` is grey, never green.
2. **A 401 is not "down".** `ServiceStatus.authenticationRequired` is distinct from `.unavailable`,
   and `isReachable` is true for both — the service is up, it just refused us.
3. **An empty list is not an error.** Connected-and-empty renders as an empty state, not a failure.
4. **Services are isolated.** A failure on one never clears another's data.
5. **Zeno's expected 401 never raises a global error banner.** It is rendered on its own card.
6. **A failed read is not a refresh.** `lastRefreshed` only advances on a successful read.

---

## 8. Configuration

Every address is configurable; no port is hardcoded in a view.

| Environment variable | Default |
|---|---|
| `PIXELDESKTOP_OPENCODE_URL` | `http://127.0.0.1:49374` |
| `PIXELDESKTOP_MODEL_SERVER_URL` | `http://127.0.0.1:55823` |
| `PIXELDESKTOP_ZENO_OPENCODE_URL` | `http://127.0.0.1:55811` |
| `PIXELDESKTOP_OPENCODE_CREDENTIAL_FILE` | `~/.config/opencode/service.json` |
| `PIXELDESKTOP_OBSERVABILITY_TIMEOUT` | `6` (seconds) |

A malformed override falls back to its default rather than trapping, and a non-`http(s)` scheme is
rejected.

---

## 9. Running and testing

```bash
# Build
xcodebuild build -project PixelDesktop.xcodeproj -scheme PixelDesktop \
  -destination 'platform=macOS' -derivedDataPath ./build

# Full test suite (deterministic, offline; live tests skipped)
xcodebuild test -project PixelDesktop.xcodeproj -scheme PixelDesktop \
  -destination 'platform=macOS' -derivedDataPath ./build

# Live integration tests against the running services (opt-in)
TEST_RUNNER_PIXELDESKTOP_LIVE_OBSERVABILITY=1 xcodebuild test \
  -project PixelDesktop.xcodeproj -scheme PixelDesktop \
  -destination 'platform=macOS' -derivedDataPath ./build \
  -only-testing:PixelDesktopTests/ObservabilityLiveTests
```

To open the dashboard: launch the app and select **Zeno Observability** in the top segmented
control. The Device workspace is unchanged and remains the default.

---

## 10. Known limitations

1. **Zeno session observability is not implemented** — blocked on the runtime credential, which is
   unreachable by design. This is the single most valuable next step; see §11.
2. **The dashboard has no snapshot/UI tests.** The view layer is not unit-tested (SwiftUI views
   are not meaningfully testable without a snapshot harness this project does not have). What *is*
   tested is the store and client surface the views call.
3. **Event payloads are unparsed.** Shown as text.
4. **Polling is fixed at 10 s** while the view is visible; not user-configurable in the MVP.
5. **No persistence.** Nothing is stored between launches.

---

## 11. Next step toward genuine Zeno session observability

The blocker is one credential. Three honest routes exist, in order of preference:

1. **Ask Zeno to expose a read-only local endpoint** (or to write its runtime password to a
   file with owner-only permissions) as a supported feature. This is the clean path and requires
   no reverse engineering.
2. **Observe Zeno's sessions from the filesystem.** OpenCode-family runtimes persist session
   state under their data directory. Reading that is a different adapter (not HTTP) but produces
   the same `OpenCodeSession` shape, and the store already isolates sources — a third adapter
   would slot in without touching the views.
3. **Screen-level observation.** Rejected for this MVP: it requires simulating input against an
   active application, which is explicitly out of scope.

Route 2 is the best next step that can be done without Zeno's cooperation, and it reuses the
entire presentation layer unchanged.

# ADR-016: Read-Only Zeno Observability Dashboard

**Status:** Accepted
**Date:** 2026-10-09
**Context:** Phase 11 (observability MVP)

---

## Context

The PixelDesktop app manages an Android device. The project's larger goal is a shared workspace in
which Ciel can observe Zeno's coding activity. The first step is a read-only dashboard that
displays verified data from the local agent services.

Three services exist on this machine:

- Homebrew OpenCode (`127.0.0.1:49374`) — an OpenCode server with a readable credential file.
- Zeno's embedded model server (`127.0.0.1:55823`) — unauthenticated, model listing only.
- Zeno's own OpenCode runtime (`127.0.0.1:55811`) — Basic auth with a launch-time random password
  that is never persisted.

The naive approach — point the dashboard at Zeno's runtime — does not work, because its credential
cannot be obtained. The risk is that a dashboard built around this would either fake Zeno data or
present a different service's data as Zeno's.

## Decision

1. **Build the dashboard against the services that can actually be read, and label every panel
   with its source.** Homebrew OpenCode for sessions/messages/agents/config/events; Zeno's model
   server for models; Zeno's runtime reported as "Unavailable — Authentication Required".

2. **Never merge sources.** A source label travels with the data; the store has no code path that
   copies one source's data into another's fields.

3. **One client type, two instances.** `OpenCodeClient` is instantiated twice — once with a
   credential provider (Homebrew), once without (Zeno's runtime). The wire protocol is identical;
   only the credential differs.

4. **Read-only by construction.** The client exposes only `GET` operations. There is no write
   capability to disable, because none is implemented.

5. **The transport is the only seam.** `ObservabilityHTTPTransport` is a protocol; the production
   implementation wraps `URLSession`, and tests inject a mock. Everything above it is deterministic
   and tested offline against captured payloads.

6. **Absence renders as absence.** Optional API fields stay optional through the model layer and
   render as "—". No default is invented.

7. **Integrate as a sibling, not a child.** `RootView` switches between the existing `ContentView`
   (device workspace) and the new dashboard. The dashboard has no device dependency, so nesting it
   inside `ContentView`'s device-gated detail pane would have made it unreachable exactly when it
   is most useful — with no phone attached. `ContentView` is untouched.

## Consequences

**Positive**

- The dashboard is honest: every value is traceable to a verified endpoint, and every panel names
  its source.
- The credential never leaves the request header; the containment is asserted by tests.
- Adding a third data source (for example a filesystem adapter for Zeno's sessions) requires no
  change to the views or the store's isolation model.

**Negative / accepted**

- **Zeno session data is not shown.** The headline capability is blocked on one credential. This is
  recorded as the top known limitation and the next milestone.
- The dashboard has no view-layer tests; only the store and client surface is tested.
- A fixed 10 s poll while visible is a deliberate bound; it is not yet configurable.

## Alternatives considered

- **Reverse-engineer the runtime credential from Electron IPC.** Rejected: explicitly out of
  scope, and fragile across Zeno updates.
- **Simulate input against Zeno's window.** Rejected: requires manipulating an active application,
  which is outside the safety boundary.
- **Show Homebrew OpenCode sessions under a "Zeno" heading.** Rejected: misattribution. This is the
  failure mode the source labels exist to prevent.
- **Mock live data so the dashboard "works".** Rejected: the MVP's core requirement is that it not
  fabricate activity.

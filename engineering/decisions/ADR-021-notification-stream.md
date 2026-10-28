# ADR-021: The Notification Stream (Phase 3.2) — Two Tiers, a Gated Reader, a Content-Free Trail

**Status:** Accepted
**Date:** 2026-10-25
**Supersedes:** —
**Related:** ADR-006 (test isolation), ADR-019 (input injection + telemetry), ADR-020 (trust foundation)

---

## 1. Context

A5 is the first capability in PixelDesktop that reads a **P4** data class: notification package,
title, body, sender. It arrives immediately after 3.1 built the consent registry (D1) and the
generalised audit trail (D2) specifically so it could arrive. Three questions had to be settled before
any code:

1. **How does the read stay affordable?** `dumpsys notification --noredact` on the Pixel 7a returns
   **627,757 B** for six notifications. Polling that every 30 seconds is 1.8 GB/hour of USB traffic and
   a plausible battery cost.
2. **Where does the gate live?** A gate that callers must remember to use is a gate that will be
   forgotten exactly once, at the call site that matters.
3. **What may be written down?** The audit trail outlives the session and is rendered in the UI. It is
   therefore a copy of whatever it contains.

---

## 2. Decision — two tiers, gated inside the reader, and a trail that carries counts

### 2.1 Two tiers, compared by key set

Tier 1 is `cmd notification list`: one line per notification, the notification key, **539 B** live.
Tier 2 is `dumpsys notification --noredact`: the full records, **627,757 B** live.

`NotificationStream` polls tier 1 and reads tier 2 **only when the set of keys changed**. Measured in
one poll pair on hardware: poll 1 = 539 B + 627,757 B; poll 2 = **539 B and one command**. That is a
99.91% reduction per unchanged poll, and it makes a 30-second cadence cheap.

A dismissal removes a key, so it is detected as a change; an edit to an existing notification's body
is **not** detected until something else changes the key set or the user forces a full read. The view
therefore has an explicit **Force full read**, and the readout says which kind of poll just happened
(`last poll: key list only` / `full dump fetched`) — an operator who cannot see that cannot tell
polling from polling.

### 2.2 The gate is inside the reader

`ADBNotificationReader` is constructed with a `ConsentGate` and wraps **both** tiers in
`gate.performing(.notifications, …)`. `AppState.notificationReader` is the only accessor the UI has,
and it returns the gated reader. There is no seam where a caller can hold an ungated transport and a
notification command at the same time.

The test that matters asserts **zero shell invocations** with no grant, not merely that an error was
thrown: a gate that throws after issuing the command has already read the phone.

### 2.3 The audit trail carries counts and byte sizes; content never

Per command, one `DeviceAuditRecord`:

- `begin(operation: .notificationRead, detail: "tier 2 (dump): dumpsys notification --noredact")` before
  the command, so a crash mid-read leaves a `pending` record;
- `resolve(…, outcome: .executed, detail: "tier 2: 6 records (2 contentless), 627757 B")` after.

The detail is counts and sizes. It never contains a title, a body, a package name, or stderr, and this
is asserted rather than intended: every parsed value of ≥12 characters is compared against the whole
trail, in tests **and** in the device harness (live: 12 values checked, 0 leaked).

Package names are excluded on the same logic that excludes bodies. A package name is a fact about the
user's life (a dating app, a clinic, a bank) and the P4 grant covers the read, not the permanent
record of it.

### 2.4 The view lives in Perception, and grants nothing

`NotificationsSection` is mounted inside Perception (Group A of the capability table). Reasons:

- The tab bar is already at ten tabs with ⌘1–⌘9/⌘0 mapped by index; an eleventh needs a second
  shortcut scheme for no navigational gain.
- The question it answers — "what is the phone showing right now" — is the question Perception exists
  to answer.

It shows the consent state, the refusal text, the payload/tier readout, and every record including the
contentless ones, badged. It deliberately has **no consent button**: consent needs a written reason and
lives in Trust, and a one-click grant next to the messages it unlocks turns a decision into a reflex.

### 2.5 Empty output is asymmetric

- Tier 1 empty ⇒ **no notifications** (valid; a clear shade prints nothing).
- Tier 2 empty ⇒ **the read did not happen** (the device always prints section headers) ⇒ throws and is
  audited as `failed`.

Conflating these would turn a broken read into "your phone has no notifications", which is a silent
false negative in the one place a user would not question it.

---

## 3. Consequences

**Good**

- Polling costs 539 B, so a 30-second cadence is defensible on USB and on battery.
- The gate cannot be bypassed by a future caller that forgets: it is not a parameter.
- The trail is safe to render, copy into a report, and keep after the session — which is what makes it
  useful for reviewing what an agent did.
- 26 hermetic tests + 4 device-gated tests pin the behaviour against a **captured** dump rather than an
  invented one.

**Costs and limits**

- A body edit without a key change is invisible until the next key change or a forced read. Accepted:
  the alternative is reading 613 KB every 30 seconds.
- The key set is compared as a set of raw strings, so a notification that keeps its key and changes
  everything else is the blind spot. It is documented in the view, not hidden.
- Contentless records are 4 of 33 on this phone; a naive "coverage" metric will read as a parser
  regression when it is a property of the notification mix (see phase record §4).

---

## 4. Alternatives considered

| Alternative | Why not |
|---|---|
| Tier 2 only | 627,757 B per poll; ~1.8 GB/hour at 30 s. |
| `logcat` event stream instead of polling | Rejected for 3.2, not forever: it needs a second transport path (streaming, reconnect, dedupe) to prove a design the two tiers already make cheap. It is the natural 3.4+ optimisation. |
| Gate at the call site (a `requireConsent()` the caller must invoke) | Fails the first time a new caller forgets, and the failure is invisible in review because the code compiles. |
| Audit with the notification key | The key contains the package name and tag; the trail is durable. Counts and sizes are enough to reconstruct *that* a read happened and how big it was. |
| An eleventh tab | Second shortcut scheme; splits one question across two surfaces. |
| A "grant" button in the panel | Turns a deliberate act into a reflex, and moves the reason — the only part that makes a grant reviewable — out of the flow. |

---

## 5. Verification

- **Suite:** 776 tests, 30 skipped, 0 failures (baseline 746/26/0). 26 hermetic A5 tests + 4
  device-gated.
- **Hardware** (`DEADBEEF000000`, Android 16): 4 harness checks pass — refusal with 0 commands, the
  539 B / 627,757 B / 539 B poll sequence, 0 of 12 content values in the trail, immediate refusal after
  revocation.
- **Evidence:** `engineering/harnesses/a5-notification-evidence.swift` (committed, reproducible per
  ADR-006), transcripts in `engineering/phases/phase-03-2-notification-stream.md` §5.

---

## 6. Not in this decision

Push-based notification events; notification actions (reply/dismiss) and their consent class; per-record
history or dedupe across polls; filtering rules (the view shows the shade as the device reports it).

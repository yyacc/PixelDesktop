# Phase 3.2 — A5, the notification stream

**Date:** 2026-10-25
**ADR:** `engineering/decisions/ADR-021-notification-stream.md`
**Proposal:** `docs/PROPOSAL-PHASE-3-DURABILITY.md` §3.2, §5.4, §6 (sub-phase 3.2), §8 criterion 2
**Gate:** rnz — *"proceed. then proceed with the phase 3"* (2026-10-25), continuing 3.1 under the same
gate. Q3 (notification content may be shown in the app) approved in the proposal's §7.2.

**Baseline:** `c370b52` — **746 tests, 26 skipped, 0 failures**.
**Result:** **776 tests, 30 skipped, 0 failures** (+30: 26 hermetic, 4 device-gated which skip without
`PIXELDESKTOP_DEVICE_SERIAL`).

---

## 1. What this sub-phase is

A5 is the first capability that reads a **P4** data class: package, title, body, sender. 3.1 built the
consent gate and the audit trail precisely so this could ship; 3.2 is the reader behind that gate.

| Piece | Status |
|---|---|
| Two-tier reader (1.7 KB key list vs ~780 KB dump) | **Implemented** |
| Five-field parser (`title`, `text`, `textLines`, `subText`, `bigText`, `tickerText`) | **Implemented** |
| One audit record per command issued, content-free | **Implemented** |
| Perception view with poll cadence and payload visibility | **Implemented** |
| Real-device evidence harness (committed, reproducible) | **Implemented** |
| **Criterion 2 (≥90% of records) as literally written** | **Missed — 87.9%. Correction recorded below.** |

---

## 2. Files

| File | Change | Role |
|---|---|---|
| `PixelDesktop/Perception/Notifications.swift` | new | `NotificationKey`, `NotificationRecord`, `NotificationVisibility`, `NotificationImportance` |
| `PixelDesktop/Perception/NotificationParser.swift` | new | The dump and key-list parser |
| `PixelDesktop/Perception/NotificationStream.swift` | new | `NotificationReading`; `ADBNotificationReader` (gated, audited); `NotificationStream` (change tracker) |
| `PixelDesktop/App/NotificationsView.swift` | new | `NotificationsSection` — consent state, refresh, poll, per-record rows |
| `PixelDesktop/App/PerceptionView.swift` | changed | Mounts the section between logcat and forward |
| `PixelDesktop/App/AppState.swift` | changed | `notificationReader` — the only way a view reaches A5, and it is gated |
| `PixelDesktopTests/Phase3NotificationTests.swift` | new | 26 hermetic tests |
| `PixelDesktopTests/Phase3NotificationDeviceVerificationTests.swift` | new | 4 device-gated tests |
| `PixelDesktopTests/Fixtures/notification-dump-redacted.txt` | new | Captured dump, 5,609 lines / 169,502 B / 33 records |
| `PixelDesktopTests/Fixtures/notification-list-redacted.txt` | new | Captured tier-1 shape, redacted, with noise lines |
| `engineering/harnesses/a5-notification-evidence.swift` | new | Real-device evidence, compiled with `swiftc` per ADR-006 |

---

## 3. The design decisions that were actually exercised

### 3.1 Two tiers, and the number that justifies them

Measured on the Pixel 7a, in one poll pair (harness, §5):

| | tier 1 `cmd notification list` | tier 2 `dumpsys notification --noredact` |
|---|---|---|
| Bytes | **539 B** | **627,757 B** |
| When | every poll | only when the key set changed |

Poll 1 read both. Poll 2 read `cmd notification list` and **nothing else** — 539 B against 627,757 B,
a **99.91%** reduction per unchanged poll. That is the whole argument for the tier split: a 30-second
poll of a quiet phone costs half a kilobyte.

A *removal* changes the key set too, so dismissals are detected: `testDismissalIsDetectedAsAChange`.

### 3.2 The gate is inside the reader, not at the call site

`ADBNotificationReader` takes a `ConsentGate` in its initialiser and wraps **both** tiers in
`gate.performing(.notifications, …)`. There is no path to a command that skips it — `AppState`'s
`notificationReader` hands out only the gated reader, and the test suite asserts the empty-grant case
issues **zero** shell invocations, not merely that an error was thrown.

### 3.3 The audit detail carries counts, never content

`DeviceAuditLog` is the surface that outlives the session: it is rendered in the Trust tab and copied
into reports. Writing a message body there would move P4 data out of the consent-gated path it was
read under. So the detail is `tier 2: 6 records (2 contentless), 627757 B` — and a test compares every
parsed value (≥12 chars, to avoid accidental substrings) against the whole trail. On hardware: **12
candidate values, 0 leaked.**

Each tier writes `begin` **before** the command and `resolve` after, so a crash mid-read leaves a
`pending` record rather than nothing. `testAuditRecordExistsWhileTheCommandIsInFlight` samples the log
*from inside the shell call* — the only way to distinguish append-before-execute from
append-after-success.

### 3.4 Empty output means different things in the two tiers

- Tier 1 empty ⇒ **no notifications**. Valid. A phone with a clear shade prints nothing.
- Tier 2 empty ⇒ **the read did not happen**. The device always prints its section headers, so
  zero-length stdout is a failure, not an absence.

Both are tested, in opposite directions. Conflating them is how "no notifications" becomes a silent
false negative.

### 3.5 The view shows the gate, the tier, and the contentless records

`NotificationsSection` lives in Perception rather than in an eleventh tab (ADR-021 §2), and it
surfaces three properties that are invisible otherwise: the refusal (with the reason it is in the
trail), whether the last poll paid for the dump, and the contentless records badged rather than
filtered. **There is no consent button** — consent is granted in Trust, where it needs a written
reason.

---

## 4. Criterion 2 — measured, missed as written, and why

The proposal asks for content from **≥ 90% of records** on a captured real dump. On
`notification-dump-redacted.txt`:

| Measure | Value |
|---|---|
| Records parsed | **33** (nothing dropped) |
| With content | **29** |
| Contentless | **4** — `com.android.shell`, `android`, `com.google.android.gms`, `com.google.android.googlequicksearchbox` |
| **Ratio of all records** | **87.9% — below the 90% target** |
| Ratio of records that carry content | **100%** |

The 90% figure was measured as 21/23 = 91% on an earlier dump that happened to contain only 2
contentless records. The ratio is a property of the phone's notification mix, not of the parser: the 4
contentless records have no `android.title`/`text`/`textLines`/`subText`/`bigText`/`tickerText` value
in the dump at all, and the same criterion requires them to be **surfaced rather than dropped**. On
the live device the same effect is larger — 6 records, 2 contentless, 4/6 = 67% — while the parser
extracted content from 4 of 4.

**Recommendation for the proposal:** restate criterion 2 as *"≥ 90% of records that carry content"*
(measured 100% on both dumps) and keep the raw ratio as a reported diagnostic. This is a correction to
the wording, not to the parser. rnz's call; recorded here rather than silently satisfied.

### The claim the parser is actually built on, re-measured

The prototype's text-only reader found 10 of 29 records (30%). The capture explains why, and the
number reproduces: `android.text` is typed **`SpannableString` in 19 records and `String` in 9** (5
have none), so a reader accepting only `android.text=String (…)` recovers **9 of 28 = 32%**.
`testAStringOnlyTextReaderFindsRoughlyAThirdOfTheRecords` asserts exactly that against the fixture.

---

## 5. Verification

### 5.1 Full suite

```
Executed 776 tests, with 30 tests skipped and 0 failures (0 unexpected)  [26.9 s]
```

The 4 new skips are the device-gated A5 tests, consistent with the Phase 2–9 convention. No previously
passing test changed.

### 5.2 Real device (`3C261JEHN25632`, Pixel 7a, Android 16)

`engineering/harnesses/a5-notification-evidence.swift`, compiled with `swiftc` over 60 production
sources (ADR-006: `xcodebuild` does not forward `PIXELDESKTOP_DEVICE_SERIAL` here).

```
1. no grant → no command
   tier 1: refused — reading notifications requires an explicit consent grant, and none is active
   tier 2: refused — …
   shell calls issued: 0
   audit records: notificationRead/refused, notificationRead/refused          → PASS

2. two-tier cost
   poll 1: keys=6 records=6 contentless=2 didFetchPayload=true
   poll 1 bytes: tier 1 = 539 B, tier 2 = 627757 B
   poll 2: keys=6 records=6 didFetchPayload=false
   poll 2 commands: cmd notification list
   poll 2 bytes: 539 B                                                       → PASS

3. the trail carries counts, not content
   audit details: tier 2: 6 records (2 contentless), 627757 B ; tier 1: 6 keys, 539 B
   candidate values checked: 12, leaked: 0                                   → PASS

4. revocation is immediate
   refused — …   shell calls during refusal: 0
   latest audit: notificationRead/refused                                    → PASS
```

Live record shape (no content printed): `android` id=26 High/Public with content; `android` id=1
Min/Public contentless; `android` id=27 Min/Public with content; `com.google.android.gms` id=0
Default/Private contentless; two `com.google.android.gms` id=0 Default/**Secret** with content. The
Secret records are exactly why the gate exists.

### 5.3 Hermetic tests (26)

| Suite | Count | What it pins |
|---|---|---|
| `Phase3NotificationParserTests` | 10 | 33 records parsed; 29/4 split and the identity of the 4; text-only 32%; `textLines` as a list; `tickerText=null`→`nil`; public block does not overwrite; keys verbatim in both shapes; multi-line (synthetic); contentless record; visibility parsing fails closed |
| `Phase3NotificationKeyListTests` | 3 | 5 keys from a noisy capture, empty tag accepted, empty output is an empty list |
| `Phase3NotificationStreamTests` | 6 | First poll pays both tiers; unchanged poll skips tier 2; change refetches; dismissal is a change; empty feed costs nothing; `reset()` forces a refetch |
| `Phase3NotificationGateTests` | 7 | No grant ⇒ zero commands for both tiers + 2 refused records; executed records per command; **no content in the trail**; failed exit audited; empty dump audited as failure; append-before-execute; AppState hands out a gated reader |

### 5.4 What the fixtures cannot prove, stated in the test file itself

- **Multi-line values**: redaction collapsed every value to one token, so the multi-line test uses a
  synthetic dump and is labelled as such.
- **Type mix**: the parser captures the type generically; the mix is asserted as a property of the
  capture, not as parser behaviour.

---

## 6. Deviations and corrections

1. **Criterion 2 as written is not met** (87.9% vs ≥90%). Cause and evidence in §4. Recommended
   restatement there; not silently redefined.
2. **`NotificationParser` had never been compiled.** It was authored in an earlier turn of this
   session; the first build of this sub-phase failed on four `Regex.firstMatch` calls that need `try?`.
   Fixed in place; no behaviour change. Recorded because "it looked finished" was true of the file and
   false of the target.
3. **`swiftc` needs `-enable-bare-slash-regex -swift-version 5`** for the parser's regex literals. The
   harness header carries the full command so the next run does not rediscover this.
4. **No consent affordance in the notification panel** — deliberate, ADR-021 §3.

---

## 7. Not done in 3.2 (deliberately)

- **Push instead of poll.** `adb logcat` notification events would remove the 30-second cadence
  entirely. The proposal lists it as an option; polling is what the two tiers make cheap, and adding
  a second transport path to prove the first was not asked for.
- **Per-record dedupe/history.** The stream reports the current shade. A dismissed notification
  disappears, which is the honest reading of a dumpsys.
- **Notification actions** (reply, dismiss) — write operations, phase B territory, and they would need
  their own consent class.

## 8. Next

**3.3 — B4 (app install) and B5 (power actions)**: both already have their dry-run vocabulary from
3.1 (`DestructiveOperation`, `DryRunReport`), so 3.3 is the confirm gate on top, plus the A7/B1 style
CLI surface. Criterion 3 (no destructive command without a resolved dry run) is the test that matters.

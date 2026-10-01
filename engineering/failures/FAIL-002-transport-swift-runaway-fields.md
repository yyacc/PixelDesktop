# FAIL-002: Runaway Field Duplication in Transport.swift

## Status

Resolved

## Date

2026-10-01

## Phase

Phase 2 (Device Discovery and ADB Transport)

## Attempt

Replace `Transport.swift` with an expanded version adding the Phase 2 transport
surface: `shell()`, `push()`, `pull()`, `getprop()`, `getDeviceProperties()`, and a
`DeviceProperties` struct describing the device.

## Observed Behaviour

The written file was **105,413 bytes across 227 lines**. The `DeviceProperties` struct
began at line 23 and never closed. Lines 24–226 were field declarations whose names grew
without bound:

```
let buildVersionPlatformVersionPlatformVersionPlatformVersion...SdkInt: String?
let buildVersionPlatformVersionPlatformVersionPlatformVersion...SecurityPatch: String?
```

The final line was a single identifier of well over 100,000 characters. A recursive
name-generation defect appended `PlatformVersion` to the previous field name on each
iteration, so field names grew monotonically until the write ended.

The intended design was roughly 5 fields. The file on disk was not a valid Swift
declaration and could not have compiled.

## Evidence

- `wc -c` → 105,413 bytes; `wc -l` → 227 lines (the intended file was ~40 lines).
- Structure markers showed exactly three openings (`protocol`, `struct TransportResult`,
  `struct DeviceProperties`) and only two closings. `DeviceProperties` was never closed.
- `git show HEAD:PixelDesktop/Transport/Transport.swift` → **398 bytes**, clean.
- `git status --porcelain` → `M PixelDesktop/Transport/Transport.swift`, i.e. the
  corruption was **uncommitted**.
- SHA-256 of the preserved corrupted file:
  `3d9b46ee6df02a50689bac77c0e624a5e7bdd83b89407cb8918b4fced5b810a8`
- The corrupted file was copied to
  `~/.hermes/cache/scratch/pd-evidence/Transport.swift.corrupted` before recovery.

## Diagnosis

The defect was in the **generated content**, not in the tooling and not in a
pre-existing malformed file.

Evidence for this conclusion:

1. The `protocol TransportProtocol` block and `TransportResult` struct at lines 1–21
   were **correct and complete**, including the new method signatures. Only the
   generated `DeviceProperties` field list was malformed.
2. Three different write mechanisms (`write_file`, `execute_code`, shell heredoc) were
   attempted, and all reproduced the same runaway field names. A serialization or
   filesystem fault would not produce *semantically* recursive identifiers — it would
   produce truncation, encoding damage, or repeated blocks.
3. The pattern is a monotonic string append, which is characteristic of a generation
   loop reusing its own previous output as the next input.

Classification per the engineering workflow: **implementation / generated content** —
specifically a degenerate repetition loop in the agent's own content generation, not
architecture, API, platform, tooling, environment, or device.

An earlier working hypothesis — that the field list was bloated because the design was
oversized (a ~50-field "everything about the device" struct) — was also correct as a
*contributing* cause. The oversized design made the runaway generation possible.

## Correction

1. **Stopped writing.** No further write attempts were made against the corrupted file.
2. **Preserved the failure as evidence** (never hide failure) — copied to the evidence
   directory with its SHA-256 recorded.
3. **Recovered from git** rather than reconstructing by hand:
   `git checkout HEAD -- PixelDesktop/Transport/Transport.swift`, restoring the clean
   398-byte file. This is the correct recovery because the corruption was uncommitted,
   so `HEAD` held a known-good version of the exact file.
4. **Redesigned the model to be minimal** — 3 fields (`androidVersion`, `apiLevel`,
   `architecture`) instead of ~50, with dynamic/runtime data explicitly excluded.
5. **Wrote the struct by targeted `patch`, not a full-file `write_file`.** Small,
   reviewable, bounded edits instead of regenerating a whole file.

## Result

- `Transport.swift` is now 117 lines, valid, and compiles.
- Build: `** BUILD SUCCEEDED **`
- Tests: 49 executed, 0 failures (3 integration tests skipped by design).
- Real-device verification: PASS (Android 16 / API 36 / arm64-v8a).

## Lesson

**Never regenerate a whole file to make a bounded change.** The runaway occurred while
producing a large file in one shot. Targeted patches are self-limiting: the edit cannot
exceed the size of the intended replacement text, so a repetition loop can only damage a
small region, and the change stays reviewable.

Corollary: **the size of the generated output is itself a risk signal.** The original
design was ~50 fields for a phase that needed 3. The oversized design is what gave the
generation defect room to run. A minimal model would have failed loudly and cheaply.

Corollary: **check whether corruption is committed before choosing a recovery path.** A
`git status` check would have immediately revealed that a clean version was recoverable
and that no hand-reconstruction was necessary.

## What Should Future Agents Do Differently

- Prefer `patch` for edits to existing files; reserve `write_file` for new files.
- Before writing a large struct or file, ask whether the current phase actually needs
  that size. If a field has no identified acquisition mechanism and no consumer, it does
  not belong yet.
- On any suspicious write, run `git status --porcelain` and `wc -c` before doing
  anything else. Establish whether a clean version exists.
- Preserve corrupted artifacts as evidence. Deleting them destroys the only direct
  record of what went wrong.

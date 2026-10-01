# ADR-003: DTCA-1 Worker APK

**Status:** Accepted
**Date:** 2026-10-01

## Context

The DTCA-1 workload requires computation on the Pixel 7a's own CPU/RAM. The Pixel 7a is a standard Android device with no guaranteed script interpreter. The Android build chain is proven (AndroidMetadataHelper builds successfully).

## Problem

How should the DTCA-1 computation execute on the Pixel?

## Options Considered

### Option A: ADB shell with pre-installed script

**Rejected.** No script interpreter (Python, Lua, etc.) is guaranteed on a standard Pixel 7a. This option requires investigation and may not be viable.

### Option B: Minimal worker APK

**Accepted.** Build a small Android APK that:
1. Receives input via ADB push (file on device)
2. Performs DTCA-1 computation (word tokenization, counting, classification)
3. Writes result JSON to known file location
4. PixelDesktop retrieves result via ADB pull

### Option C: Pure shell commands

**Rejected.** Android's built-in shell (Toybox) has limited text processing capabilities. Word tokenization, frequency counting, and JSON generation are too complex for pure shell.

## Decision

Option B — minimal worker APK.

## Reasoning

- Android build chain is proven (AndroidMetadataHelper)
- APK gives full control over computation
- Uses existing ADB push/shell/pull for I/O
- No new infrastructure required
- Can be debuggable for development

## Consequences

- A new Android project must be created
- The APK must be built and installed on the Pixel
- The APK uses Java/Kotlin (same as AndroidMetadataHelper)

## Future Reconsideration Conditions

- When a script interpreter is confirmed on the device, Option A may be simpler
- When multiple workloads exist, the worker APK may need a task dispatch mechanism

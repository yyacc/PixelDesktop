# ADR-001: Project Structure

**Status:** Accepted
**Date:** 2026-10-01

## Context

The existing PixelDesktop project at `~/Documents/PixelDesktop/` has 20 empty Swift source files and a 39KB Xcode Previews stub binary. No working code exists. The project needs a clean rebuild.

## Problem

What project structure should the clean rebuild use?

## Options Considered

### Option A: Keep existing structure, fill in files

**Rejected.** The existing structure includes components not justified by the DTCA-1 workload:
- `AndroidVirtualDisplayService.swift` — not needed for DTCA-1
- `AndroidApppSessionManager.swift` — not needed for DTCA-1
- `AndroidAppSession.swift` — not needed for DTCA-1
- `Video/` directory — scrcpy is not part of DTCA-1

### Option B: Minimal structure with only what DTCA-1 needs

**Accepted.** Structure:
```
PixelDesktop/
├── App/           # App entry point, state
├── Core/          # Errors, logging, models
├── Device/        # Device discovery, management
├── Transport/     # ADB transport
├── Compute/       # DTCA-1 worker
└── Verification/  # Result verification
```

### Option C: Full structure with all planned components

**Rejected.** Premature. Components should be added when needed, not before.

## Decision

Option B — minimal structure.

## Reasoning

The DTCA-1 workload requires:
1. ADB communication (Transport)
2. Device management (Device)
3. Computation (Compute)
4. Verification (Verification)
5. App entry point and state (App)
6. Core types and errors (Core)

It does not require video, app session management, or virtual display services.

## Consequences

- Video and app session components can be added later when needed
- The structure is minimal and focused
- No dead code or placeholder files

## Future Reconsideration Conditions

- When scrcpy integration is needed, add Video/ directory
- When app session management is needed, add AppSession/ directory
- When multi-device support is needed, extend Device/ directory

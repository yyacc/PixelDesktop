# ADR-002: ADB Transport

**Status:** Accepted
**Date:** 2026-10-01

## Context

The DTCA-1 workload requires communication with the physical Pixel 7a. ADB is available via homebrew at `/opt/homebrew/bin/adb`. The Pixel 7a is expected to be USB-connected.

## Problem

What transport mechanism should Phase 1 use for device communication?

## Options Considered

### Option A: ADB only

**Accepted.** Use ADB for all device communication:
- `adb devices` — device discovery
- `adb shell` — command execution
- `adb push` — file transfer to device
- `adb pull` — file transfer from device

### Option B: ADB + wireless fallback

**Rejected.** Wireless ADB fallback is not needed for Phase 1. The DTCA-1 workload operates over USB. Wireless fallback is a future requirement.

### Option C: Custom RPC/HTTP layer

**Rejected.** Premature. No compute workload justifies a custom RPC layer. ADB push/shell/pull is sufficient for DTCA-1.

## Decision

ADB only for Phase 1.

## Reasoning

- ADB is proven and available
- ADB supports all required operations: discovery, shell, push, pull
- No networking complexity needed
- USB-first operation is the expected mode

## Consequences

- Phase 1 is USB-only
- Wireless fallback must be added as a future phase
- No networking code in Phase 1

## Future Reconsideration Conditions

- When wireless operation is required, add wireless ADB fallback
- When transport switching is needed, add transport abstraction layer

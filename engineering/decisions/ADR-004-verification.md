# ADR-004: Verification by Re-computation

**Status:** Accepted
**Date:** 2026-10-01

## Context

The DTCA-1 workload is deterministic: same input + same algorithm = same output. PixelDesktop must verify results without trusting the worker's self-report.

## Problem

How should PixelDesktop verify DTCA-1 results?

## Options Considered

### Option A: Local re-computation and comparison

**Accepted.** PixelDesktop:
1. Re-runs the same deterministic algorithm locally on the Mac
2. Compares its local result against the Pixel's result
3. Match criteria: input_characters, total_words, unique_words, top_words, classification, confidence (±0.01)

### Option B: Trust worker self-report

**Rejected.** This is not verification. The worker could report success without actually computing.

### Option C: Checksum comparison

**Rejected.** A checksum only verifies data integrity, not computational correctness.

## Decision

Option A — local re-computation and comparison.

## Reasoning

- DTCA-1 is deterministic by design
- Same input + same algorithm = same output
- PixelDesktop can independently prove the result is correct
- No trust in worker self-report needed

## Consequences

- PixelDesktop must implement the DTCA-1 algorithm locally
- Verification is independent of the worker
- Mismatches indicate either worker bugs or verification bugs

## Future Reconsideration Conditions

- When non-deterministic workloads are introduced, a different verification method is needed
- When model inference is added, verification becomes probabilistic

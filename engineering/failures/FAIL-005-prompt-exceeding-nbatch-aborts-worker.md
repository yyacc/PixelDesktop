# FAIL-005 — A prompt longer than `n_batch` aborts the worker process

**Discovered:** 2026-10-02, during Phase 7 Step 1 real-device verification
**Phase:** 7 (Step 1)
**Class:** **implementation defect** — a missing bound in our own JNI code, not a platform defect
**Severity:** high — the worker dies with no result file and no error
**Status:** FIXED and verified on the physical Pixel 7a

---

## Summary

`llama_decode()` **aborts the process** when handed more tokens than `n_batch`. It does not return
an error. The Phase 6 native layer decoded the entire prompt in a single batch, so any prompt
longer than 256 tokens killed the worker via `SIGABRT`, producing **no result file** — which the Mac
cannot distinguish from a crash-loop, a timeout, or a missing worker.

The defect survived Phase 6 implementation, 154 tests, 194 tests, and 224 tests in Phase 7 Step 1.
It was found only by exercising the real device with an oversized input.

---

## Observed behaviour

Phase 7 Step 1 attempted a context-boundary probe: a ~660-token prompt with `max_tokens = 200`,
intended to confirm the documented context guard refuses an overflow.

| Expected | Actual |
|---|---|
| A bounded `FAILED` result with a context-overflow error | **No result file at all** |
| Worker exits normally | Worker **killed** |
| A log line explaining the refusal | Log stops after `model loaded in 404 ms` |

The worker was launched, loaded the model successfully, then vanished with nothing written.

---

## Evidence

### Native crash trace (`logcat -b crash`)

```
F libc    : Fatal signal 6 (SIGABRT), code -1 (SI_QUEUE) in tid 30668 (ldesktop.worker)
#00 pc .../libc.so (abort+156)
#01 pc .../base.apk!libpdllama.so (ggml_abort+228)
#02 pc .../base.apk!libpdllama.so (llama_context::decode(llama_batch_ext const&)+4708)
#03 pc .../base.apk!libpdllama.so (llama_decode+60)
#04 pc .../base.apk!libpdllama.so (Java_com_pixeldesktop_worker_LlamaBridge_nativeGenerate+864)
#05 pc .../libart.so (art_quick_generic_jni_trampoline+144)
```

The trace is unambiguous: `nativeGenerate` → `llama_decode` → `llama_context::decode` →
`ggml_abort` → `abort`. The abort originates **inside llama.cpp**, reached from our JNI function.

### Why the existing guard did not catch it

The Phase 6 code guarded the **context** bound:

```cpp
if (n_prompt + max_tokens > kContextSize) { ...refuse... }   // kContextSize = 2048
```

The prompt was ~660 tokens. **660 + 200 = 860, well under 2048.** The guard correctly passed.

`n_batch` is a **separate and much smaller bound** — 256 — and violating it is fatal rather than
reportable. The two bounds were conflated: the code assumed a single "context" limit governed
everything.

---

## Root cause

Two independent llama.cpp bounds, only one of which is graceful:

| Bound | Value | Violation behaviour |
|---|---|---|
| `n_ctx` (context window) | 2048 | returns an error — handled by the existing guard |
| **`n_batch` (per-decode-call)** | **256** | **`ggml_abort()` → SIGABRT — not reportable** |

The Phase 6 implementation passed the entire prompt to a single `llama_decode()` call. That is
correct only while the prompt is under 256 tokens — which every Phase 6 test was, because Phase 6
used 22–32 token prompts.

---

## Why the tests did not catch it

**Every test used a short prompt.** The largest prompt in Phase 5/6 verification was ~32 tokens;
this failure needs >256. The unit tests are macOS-side and cannot reach the native layer at all —
`ADR-012` is explicit that a macOS test establishes nothing about Android correctness.

This is the **seventh** defect in this project that compiled cleanly and passed the full test suite
while being wrong on the device. It is the same family as FAIL-004.

---

## Fix

Decode the prompt in chunks of at most `n_batch`, which is the documented llama.cpp pattern:

```cpp
constexpr int kBatchSize = 256;   // MUST stay in step with cparams.n_batch

for (int i = 0; i < n_prompt; i += kBatchSize) {
    const int n_chunk = std::min(kBatchSize, n_prompt - i);
    llama_batch chunk = llama_batch_get_one(tokens.data() + i, n_chunk);
    if (llama_decode(e->ctx, chunk) != 0) {
        return env->NewStringUTF("{\"error\":\"llama_decode failed on prompt\"}");
    }
}
```

`kBatchSize` is a named constant and `cparams.n_batch` now references it, so the two cannot drift
apart.

---

## Verification on the physical Pixel 7a

**The identical input that previously aborted the process:**

| Check | Result |
|---|---|
| Worker survives | ✅ **yes** |
| Result produced | ✅ `status=OK` |
| New `SIGABRT` | ✅ **none** (crash-buffer count unchanged) |
| Prompt tokens processed | **820** |
| Prompt eval time | **308,655 ms (5.1 minutes)** |
| Tokens generated | 39 in 44,750 ms |

The worker now completes where it previously died.

### A planning fact this exposed

**An 820-token prompt takes 5.1 minutes of prefill on the Pixel.** That is roughly **2.7 tokens/sec**
of prompt processing — consistent with Phase 6's measured 4–6 tok/s prefill on shorter prompts, and
much worse in absolute terms because the cost scales with prompt length.

This matters for Phase 7: **prompt size is the dominant cost of a Pixel workload**, far more than
generation. A caller planning many subtasks must keep prompts small, and the capability contract
should let it reason about that. Recorded here as measured evidence; **not** turned into a routing
threshold.

---

## Consequence for the capability contract

The contract's context-size field originally claimed:

> "Exceeding it is refused by the runtime, not silently truncated."

**That was wrong in an important way** — a *different* bound (the batch bound) was fatal rather than
refused. The limitation text now states both behaviours accurately, and notes that the worker chunks
internally to respect the batch bound, which is why the batch bound is deliberately **not**
published: it is an implementation detail the worker handles, whereas `n_ctx` is a real limit a
caller must plan around.

---

## Lesson

**A guard on one bound is not a guard on all bounds.** `kContextSize` was guarded, tested, and
documented; `n_batch` was a bare literal in a `cparams` assignment, three lines away, with a
different and fatal failure mode.

Recorded as **T-023**: *when a library exposes multiple limits, enumerate them and check which
violations are reportable and which are fatal. Guard the fatal ones first.*

The broader lesson already on record (T-015) applies again: **a mock asserts what the code sends; it
cannot reproduce what the platform does.** The only way to find this was to send a real oversized
prompt to a real device.

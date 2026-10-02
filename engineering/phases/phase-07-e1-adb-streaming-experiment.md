# E1 — Persistent ADB Shell as a Streaming Control Channel

**Status:** EXPERIMENT COMPLETE. **Disposable. No production code modified. No experimental files
left in the repository or on the device.**
**Date:** 2026-10-02
**Question:** can ONE persistent `adb shell` drive a long-running worker job with streamed progress,
instead of push + `am start` + Mac-side polling + pull?

---

## 1. Executive finding

> **ADB is not limited to one-shot host commands. A single persistent `adb shell` can drive a
> complete long-running worker job — delivering the job payload, launching the worker, streaming
> progress incrementally, and returning the structured result — all in one session.**
>
> **But streaming is ADDITIVE, not a replacement. Two pieces of the current architecture must stay,
> and one of them is load-bearing: the durable result file.**

The decisive measurements:

| Measurement | Result |
|---|---|
| Time to first output | **0.06 s** |
| Time to launch acknowledgement | **0.17 s** |
| Progress delivery | **incremental — 26 heartbeats over a 27.6 s job** |
| Buffering | **none observed** — lines arrived as produced |
| Completion detection | **via the stream, no separate polling loop** |
| Result collected in-session | **yes** — full 176-byte structured result inline |
| stdout/stderr separation | **preserved** (`stderr` empty throughout; stream carried stdout only) |
| Worker survives session death | **YES — pid 17751 still alive after the session was killed** |
| Result survives session death | **YES — `result.json`, 2983 bytes, `status=OK`, 256 tokens** |

**Verdict: Option A, with a qualification** — persistent ADB shell is a viable improvement and should
replace *the polling loop*, but must **not** replace the durable result file.

---

## 2. Current sequence (documented before any experiment)

```
ADBWorkerOperations.submitInput(job)
  ├── push job.json  →  <ext>/files/job.json          [1 MB cap, fixed path]
  ├── am start -n com.pixeldesktop.worker/.WorkerActivity
  └── (WorkerLifecycle.stopIfRunning before each job)

WorkerActivity (one-shot)
  ├── reads job.json, dispatches to DTCA1Worker or LlmWorkload
  ├── writes result.json
  └── finish()          ← no Service, no daemon, process then cached by Android

ADBWorkerOperations.retrieveResult()
  └── poll for result.json existence, then pull
```

Measured fixed orchestration cost of that sequence: **~1,257 ms** (push 231 + `am start` 267 +
result wait 758).

**What the experiment asked:** can one session do all of it?

**Answer: yes — including the payload.** `adb shell` can write a file from stdin
(`cat > job.json` verified), so the separate `adb push` is **not required**.

---

## 3. Method

A single device-side shell script, run as **one** `adb shell`:

1. `cat > job.json` — receives the job payload on **stdin** (replaces `adb push`)
2. `am start -n …/.WorkerActivity` — launches the worker
3. a 1-second heartbeat loop emitting `pidof` for attributability, while waiting for `result.json`
4. `cat result.json` **inline** into the stream
5. a terminal `E1 DONE` / `E1 FAILED` line

The Mac read the stream line-by-line and **timestamped every arrival**, so incremental delivery was
measured rather than assumed.

The harness lived in `/tmp` and was deleted afterwards. **No repository file was created or
modified.**

---

## 4. Results — the happy path (long-running LLM job)

Job: `LOCAL-LLM-1`, "What is the capital of France?", 32 tokens.

```
t+  0.06s  E1 START
t+  0.10s  E1 JOB_WRITTEN bytes=176
t+  0.17s  E1 LAUNCHED
t+  1.20s  E1 HEARTBEAT n=1 pid=14415
t+  2.20s  E1 HEARTBEAT n=2 pid=14415
   …  26 heartbeats, each arriving 1 s apart   …
t+ 27.56s  E1 RESULT_BEGIN
t+ 27.59s  {"status":"OK", … ,"text":"The capital of France is Paris.", …}
t+ 27.59s  E1 DONE
```

| Measurement | Value |
|---|---|
| Session startup → first output | **0.06 s** |
| → launch acknowledged | **0.17 s** |
| Progress lines | **26** |
| Inter-line spacing | **~1.00 s** (as emitted — not batched) |
| Completion detection latency | **0 s** — the stream carried the terminal line |
| Total wall time | **27.6 s** |
| stderr | **empty** (stdout/stderr separation preserved) |
| Result | **complete structured JSON, collected without a second round trip** |

**Incremental delivery confirmed:** 26 heartbeats arrived ~1 s apart across a 27.6 s job. Had
output been buffered, they would have arrived in one block at the end. **They did not.**

---

## 5. Results — failure and edge cases

| # | Case | Result | Detection latency |
|---|---|---|---|
| **F1** | Model missing | `status=FAILED`, `error_type=MODEL_MISSING` | **1.2 s** |
| **F2** | Malformed job (`workload=NOT-A-WORKLOAD`) | `status=FAILED`, `error_type=INVALID_INPUT` | **0.17 s** |
| **F3** | Cancellation | **external only** — `am force-stop` took **69 ms**, pid gone | n/a |
| **F4** | Worker killed mid-run | heartbeat **detected death** (`pid` → `none` at n=7) | **~7 s** |
| **F5** | Large output (256 tokens) | still running past 90 s — **harness cap, not a streaming limit** | n/a |
| **F6** | Screen locked, `mWakefulness=Dozing` | **streamed normally** — 25 lines, result OK in 19.33 s | n/a |
| **F7** | Transport killed mid-run | worker **survived**; result **written and retrievable** | n/a |

### F3 — cancellation is NOT a streaming capability

`am force-stop` is **external to the session**. The stream cannot cancel anything. Cancellation
remains exactly what it is today: a privileged ADB command. **Streaming adds no cancellation.**

### F4 — the death signal exists, but a naive script ignores it

```
E1 HEARTBEAT n=6 pid=17560
E1 HEARTBEAT n=7 pid=none      ← death detected here
E1 HEARTBEAT n=8 pid=none
   … heartbeats continued to n=18 …
```

The heartbeat loop **saw** the death and **kept going**. **The signal is available; the script must
act on it.** A real implementation must treat `pid=none` before `result.json` as a failure and
terminate. **This is the single most important implementation lesson from E1.**

### F5 — a harness limit, honestly labelled

The 256-token job exceeded the harness's 90-heartbeat cap. It was **not** a streaming failure: the
job simply takes minutes on this device. **Implication: a fixed heartbeat cap is wrong; the wait
must be bounded by a real timeout, not by a line count.**

### F6 — Dozing did not break streaming

With `mWakefulness=Dozing`, the session streamed normally and the job completed in 19.33 s. This
matches the Phase 7 R1 result (the Activity survives Dozing) and extends it: **the streaming channel
survives too.**

### F7 — the central design finding

The session was **killed at ~8 s**. Afterwards:

- the **worker was still running** (pid 17751, CPU ticks 105764, still climbing);
- the **result was later written to disk**: `result.json`, 2983 bytes, `status=OK`,
  `generated_tokens=256`, `total_ms=313946`, `text_len=1235`.

**The job did not depend on the session.** `am start` is fire-and-forget, so the worker is
**decoupled** from the shell that launched it — and the result is **durable on the device**, not
confined to the stream.

> **The stream carries progress. The file carries the result. They are not interchangeable.**

**This is the finding that decides the architecture.**

---

## 6. Architecture comparison

| Stage | Current | One persistent session | Disappears? |
|---|---|---|---|
| push job.json | `adb push` (231 ms) | **`cat >` on stdin** | **yes — replaced, not removed** |
| launch worker | `am start` | `am start` (inside session) | no — same command |
| progress | **none** | **streamed, 1 s granularity** | **new capability** |
| completion detection | Mac-side poll loop | **terminal line in the stream** | **yes — the polling loop goes** |
| result retrieval | `adb pull` | `cat` inline **and** file remains | **partially** — see below |
| cleanup | `force-stop` | `force-stop` (external) | no |
| cancellation | `force-stop` | `force-stop` (external) | no |

### What can go

- **The Mac-side polling loop** — completion arrives as a stream line. **This is the real win.**
- **The separate `adb push`** — the payload rides the session's stdin.
- **The separate `adb pull` for the result** — though the file should still be written.

### What must stay

| Piece | Why it must stay |
|---|---|
| **The durable `result.json`** | **F7 proved a killed session loses the stream but not the file.** Streaming must be *added to* file exchange, not substituted for it |
| **`am force-stop` cancellation** | F3 — cancellation is external to the session |
| **`pidof`-based liveness** | F4 — the only way to distinguish "slow" from "dead" |
| **The one-shot Activity** | No Service was needed; Phase 7 already proved it survives Dozing |
| **The fixed-path, size-capped contract** | The narrowness principle is orthogonal to the transport and still applies |

---

## 7. Architectural decision

> ### **A — Persistent ADB shell is a viable improvement and should replace the polling mechanism.**
>
> **With the qualification that it is ADDITIVE:** it replaces the *polling loop*, not the *durable
> result file*. A streaming implementation that dropped `result.json` would be **less** robust than
> what exists today — F7 is the evidence.

**It is not B**, because the benefit is measured and concrete: completion detection goes from a
**758 ms poll cycle** to **~0 s**, and progress becomes observable for the first time. It is not C,
because no limitation was found that blocks it — the one hazard found (F4) is a scripting mistake
with an obvious fix, not a transport limit.

**Proposed shape, if ever adopted:**

```
single persistent adb shell
  ├── job payload on stdin          → job.json        (replaces adb push)
  ├── am start                                       (unchanged)
  ├── heartbeat loop with pidof
  │     └── pid=none and no result → FAIL FAST       (F4 lesson)
  ├── stream progress lines          → UI / caller
  └── terminal line when result.json appears
        └── result.json STILL written to disk        (F7 — must not be dropped)
```

**This is a change to how PixelDesktop uses ADB — not a new channel.**

---

## 8. Limitations discovered

| # | Limitation |
|---|---|
| **L1** | **A killed session loses the stream.** Progress is not durable; only the file is (F7) |
| **L2** | **Cancellation is external.** Streaming provides no cancellation (F3) |
| **L3** | **Worker death is invisible to a naive loop.** `pidof` must be acted upon (F4) |
| **L4** | **Job duration is unbounded in practice.** A fixed heartbeat cap is wrong (F5) |
| **L5** | **One session = one job.** Concurrency still requires multiple sessions |
| **L6** | **Progress granularity is what the script emits.** ADB does not invent progress; the worker must emit it. **The worker currently emits none — progress would require worker-side changes** |
| **L7** | **The session is host-initiated.** The Pixel still cannot speak first — unchanged from the reconnaissance |

**L6 is the most consequential for any future work:** streaming a heartbeat is not the same as
streaming *useful* progress. Real progress (tokens generated, phase) requires the worker to write
it, which is a worker change — and therefore a separate decision.

---

## 9. What was NOT done

No WebSocket, gRPC, Service, custom USB, Bluetooth, `adb forward` RPC, TransportManager, scheduler,
or new communication architecture was implemented. No production source was modified. No experimental
file was left in the repository or on the device. The worker remains a bounded executor.

**Experimental artifacts removed:** three `/tmp` harnesses; the probe file on the device; the
job/result files. The device's `files/` directory contains only `model/`.

---

## 10. Recorded distinction

> **ADB is not limited to one-shot host commands. PixelDesktop can use a persistent `adb shell`
> session as a streaming control channel — verified on the physical Pixel 7a — and this replaces
> the Mac-side polling loop. It does not replace the durable result file, which is what makes
> recovery possible when the session dies.**

---

## Provenance

**Measured on the physical Pixel 7a (this experiment):** 0.06 s to first output; 0.17 s to launch
ack; 26 heartbeats at ~1.00 s spacing across 27.6 s; result inline; stderr empty; F1 1.2 s;
F2 0.17 s; F3 `force-stop` 69 ms; F4 death seen at n=7; F5 still running past 90 s; F6 streamed
normally under `mWakefulness=Dozing` (19.33 s); F7 worker pid 17751 alive after session kill, result
2983 bytes `status=OK` 256 tokens `total_ms=313946`.

**Measured in prior phases (cited):** ADB orchestration ~1,257 ms (push 231 / `am start` 267 / wait
758); LLM inference 12–26 s.

**Verified by source inspection:** the current sequence in §2.

**Unverified:** progress quality (the worker emits none — L6); concurrency (L5); behaviour across a
real USB drop (FAIL-006 context) as opposed to a client kill.

---

```text
E1 ADB STREAMING EXPERIMENT COMPLETE / AWAITING REVIEW
```

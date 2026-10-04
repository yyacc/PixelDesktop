# Phase 10 Step 2 — Mid-Execution USB Disconnect Experiment

- **Date:** 2026-10-04
- **Job ID:** `E8CB0C91-88CD-4EDF-9059-1AF7766A0C15`
- **Workload:** LOCAL-LLM-1
- **Mode:** Evidence-gathering only. No production code, tests, architecture, CLI, contracts, timeouts, cancellation, worker code, or skills modified. No commits.

---

## Experiment

| Attribute | Value |
|---|---|
| Job ID | `E8CB0C91-88CD-4EDF-9059-1AF7766A0C15` |
| Workload | LOCAL-LLM-1 |
| Baseline transport_id | 106 |
| Worker PID | 22552 |
| Disconnect timing | ~23 s after job start |
| Reconnect | ~2 minutes after disconnect |
| Post-reconnect transport_id | 629 |

## Disconnect Timing

| Time | Event | Observation |
|---|---|---|
| t=0 | Job started | CLI running in background |
| t=2 s | Worker execution confirmed | PID 22552, state R, memory 1.30 GB |
| t=2 s | User disconnected USB | — |
| t=23.47 s | CLI returned | `stream_lost_worker_gone`, exit code 1 |
| t=23.47 s | Device checked | USB gone, wireless ADB entry present |
| t=23.47 s | Processes checked | No pixel-desktop leak, no adb leak |
| t=reconnect | User reconnected USB | — |
| t=reconnect | Device rediscovered | transport_id 629, state `device` |

## Mac-Side Behavior

| Observation | Value | Classification |
|---|---|---|
| CLI exit code | 1 (failure) | EXPECTED |
| Error type | `worker_error` | EXPECTED |
| Error message | "Transport lost, the worker is gone, and no result was found" | EXPECTED |
| Result | `stream_lost_worker_gone` | EXPECTED |
| Total duration | 23.47 s | EXPECTED |
| Heartbeat count | 42 | EXPECTED |
| Stream ended unexpectedly | true | EXPECTED |
| CLI hung | No | EXPECTED |
| CLI crashed | No | EXPECTED |
| pixel-desktop process leak | None | EXPECTED |
| adb process leak | None | EXPECTED |

## Pixel-Side Behavior

| Observation | Value | Classification |
|---|---|---|
| Worker survived disconnect | Yes (PID 22552) | EXPECTED |
| Worker survived reconnect | Yes (PID 22552, state S) | EXPECTED |
| Worker continued executing | Yes (result written) | EXPECTED |
| Model file | Present, correct size | EXPECTED |
| Model SHA256 | `6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e` | EXPECTED |

## Durable Result

| Observation | Value | Classification |
|---|---|---|
| Result exists | Yes | **KEY FINDING** |
| Result job ID | `E8CB0C91-88CD-4EDF-9059-1AF7766A0C15` | **Matches original job** |
| Result status | `OK` | EXPECTED |
| Generated tokens | 32 | EXPECTED |
| Total duration | 77.82 s | EXPECTED (worker completed during disconnect) |
| Prompt tokens | 182 | EXPECTED |
| Model file | `qwen2.5-1.5b-instruct-q4_k_m.gguf` | EXPECTED |
| Model SHA256 | `6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e` | EXPECTED |
| Result integrity | Complete (830 bytes) | EXPECTED |
| Result ownership | Belongs to original job | EXPECTED |

**Key finding:** The worker continued executing during the USB disconnect, completed the job, and wrote a durable result. The result belongs to the original job ID, has status `OK`, and is intact.

## F7 Recovery

| Observation | Value | Classification |
|---|---|---|
| F7 recovery executed | No | EXPECTED |
| Reason | Worker invisible to CLI when checked (USB disconnected) | EXPECTED |
| Result recovered | No (CLI had already given up) | EXPECTED |
| Result exists | Yes (written by worker) | **KEY FINDING** |
| Result belongs to original job | Yes | EXPECTED |

**Note:** The F7 recovery path did not execute because the worker was invisible to the CLI at check time (USB disconnected). This is expected behavior — F7 recovery is designed for the case where the stream is lost but the worker remains visible. In this experiment the worker was invisible, so the CLI correctly reported `stream_lost_worker_gone`.

## Post-Reconnect Execution

| Observation | Value | Classification |
|---|---|---|
| New job ID | `EEA8052D-D409-4539-BEE6-930A360A7296` | EXPECTED |
| Result | `ok: true`, `outcome: "completed"` | EXPECTED |
| Status | `OK` | EXPECTED |
| Text | "The capital of France is Paris." | EXPECTED |

## Defects Found

**None.** All observed behavior matched expectations.

## What This Proves

1. **Worker continues executing during USB disconnect** — yes, the worker completed the job and wrote a result.
2. **Worker writes a durable result** — yes, `result.json` exists and belongs to the original job.
3. **Result belongs to the correct job ID** — yes, `E8CB0C91-88CD-4EDF-9059-1AF7766A0C15`.
4. **Result is complete and valid** — yes, status `OK`, content intact.
5. **CLI correctly reports failure** — yes, structured error, no hang.
6. **No process leaks** — yes, no pixel-desktop or adb leak.
7. **Post-reconnect execution works** — yes, new job completed successfully.
8. **Worker survives independently** — yes, PID 22552 survived both the disconnect and the reconnect.

## What Remains Unverified

1. **F7 recovery path** — not exercised, because the worker was invisible to the CLI at check time.
2. **Result recovery through F7** — not verified, because the CLI did not attempt recovery.
3. **Long disconnects** — only ~2 minutes tested.
4. **Multiple disconnect/reconnect cycles** — only one cycle tested.

## Production Change Justified?

**No.** The experiment proves PixelDesktop behaves correctly under USB disconnect:
- Worker survives independently and completes the job.
- Durable result is written correctly.
- CLI returns a structured error.
- No process leaks.
- Post-reconnect execution works.

## Next Phase 10 Target

**F7 Recovery Path Verification** — highest-value remaining target.

### Reason

1. **High production impact** — F7 recovery is the critical path for stream-loss scenarios.
2. **Large evidence gap** — this experiment did not exercise F7 recovery (worker invisible).
3. **Objectively verifiable** — the F7 path can be verified with mock tests.
4. **Direct mapping to the master prompt** — the master prompt explicitly requires testing "recovery".

### Verification plan

1. Use MockTransport to simulate stream loss with the worker alive.
2. Verify the F7 recovery path executes correctly.
3. Verify result-ownership checking.
4. Verify the recovered result is returned correctly.

---

**Experiment complete. No files modified.**

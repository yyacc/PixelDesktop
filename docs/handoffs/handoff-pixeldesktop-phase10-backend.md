# Handoff — Phase 10: worker backend selection (LOCAL-LLM-1)

Status: **milestone complete and verified end to end on the device; committed locally (`3ed9420` worker, `26360bd` Swift/CLI/tests), not pushed.**

## What this phase added

A per-job `backend` field on `LOCAL-LLM-1` so one workload can be computed by either runtime:

| id | runtime | weights | where |
|---|---|---|---|
| `llama-jni` (default, absent on the wire) | worker's own JNI llama.cpp | `qwen2.5-1.5b-instruct-q4_k_m.gguf` | `getExternalFilesDir(null)/model/` |
| `llama-server-http` | on-device `llama-server` (Termux) | `gemma-3n-E4B-it-Q4_K_S.gguf` | Termux private dir, server-resident |

Absence means in-process, on both sides of the wire, so every job document written before this
phase still decodes and still runs the same path. Verified on the device: a run with no
`--backend` pushed `job.json` with **no `backend` key at all** — byte-identical to the old form.

## Two failures that only a real device could have produced

Both were found by running the thing, not by reading it. Recorded because each one is invisible
in code review and would have shipped as "works on my machine".

1. **Cleartext HTTP to loopback is blocked.** First end-to-end attempt:
   `WORKER_FAILED type=BACKEND_ERROR Cleartext HTTP traffic to 127.0.0.1 not permitted`.
   Since targetSdk 28 the platform blocks cleartext by default and does **not** exempt loopback,
   so `INTERNET` is necessary but not sufficient — the permission grants the socket, the policy
   decides whether the request can be written. Fixed with `res/xml/network_security_config.xml`:
   `base-config` denies cleartext everywhere, only `127.0.0.1` and `localhost` are exempted.
   Deliberately **not** `android:usesCleartextTraffic="true"`, which would have permitted every
   host and quietly widened the containment that justifies holding `INTERNET` at all.
   (Build lesson: XML comments cannot contain a double hyphen; the first version quoted the flag
   name inside the comment and `mergeDebugResources` rejected it.)

2. **`NetworkOnMainThreadException`, message `null`.** With cleartext allowed, the run failed as
   `type=BACKEND_ERROR null` — a message-only error report loses the type, and this exception has
   no message, so the whole diagnosis was the string "null". `WorkerActivity` executes the job in
   `onCreate` (main thread) and StrictMode blocks Java sockets there; the in-process backend was
   never exposed because it works in native code. Fixed by running the blocking request on a
   plain thread and joining it, with the join ceiling (3 s + 180 s + 5 s) deliberately longer than
   the socket timeouts so those keep reporting their own honest categories. Error reporting now
   logs the full trace and includes `getClass().getName()`.

## Verified, with numbers

- **End to end, final tree.** `run --workload LOCAL-LLM-1 --backend llama-server-http` →
  `ok = true`, `outcome = completed`, text `"The capital of France is Paris. \n"`,
  `model_file = gemma-3n-E4B-it-Q4_K_S.gguf`, `runtime.name = llama.cpp-server`,
  `model_load_ms = 0` (server-resident, no load), `prompt_tokens 26`, `generated_tokens 10`,
  `total_ms 124629`, launch ack 0.18 s, 236 heartbeats, 0 stderr lines, 0 unrecognised lines.
- **Swift suite.** `xcodebuild test -scheme PixelDesktop` → **867 executed, 32 skipped,
  0 failures**. Baseline before this phase was 849; the 18 new cases are
  `Phase10BackendSelectionTests`. Note: the count only moved after `xcodegen generate` — a new
  test file is not picked up until the project is regenerated, and `xcodebuild build` does not
  compile the test bundle at all.
- **Test-bundle compile rule.** Any CLI file that names an application type needs the
  `#if canImport(PixelDesktop) @testable import PixelDesktop #endif` block. `CLIInvocation.swift`
  did not have one, so adding `InferenceRequest.InferenceBackend` broke the whole CLI suite at
  compile time while both app schemes still built cleanly.
- **Build warning fixed, not tolerated.** The build reported `'pixel-desktop' is missing a dependency
  on 'PixelDesktop' because dependency scan of Swift module 'pixel_desktop' discovered a dependency
  on 'PixelDesktop'`. Cause: the `canImport(PixelDesktop)` guard was written for the test bundle, but
  in the tool target that module is *also* importable (same scheme), so the tool acquired a hidden
  dependency on the app it does not need — it compiles the shared sources itself. Fixed by giving
  the tool an explicit `SWIFT_ACTIVE_COMPILATION_CONDITIONS: PIXELDESKTOP_CLI_TOOL` and guarding
  with `#if canImport(PixelDesktop) && !PIXELDESKTOP_CLI_TOOL`. The tool then builds with no
  warning, which proves the import was genuinely redundant there.
- **APK.** `assembleDebug` → BUILD SUCCESSFUL, 6,157,747 bytes, contains
  `res/xml/network_security_config.xml` and `HttpInferenceBackend`; installed with `adb install -r`.

## Gaps — stated, not papered over

- **The in-process path could not be executed.** `model/` on the device is empty (`total 0`), so
  `run` with no `--backend` correctly reports `MODEL_MISSING` for
  `qwen2.5-1.5b-instruct-q4_k_m.gguf`. The Qwen artifact was never present in this workspace.
  The wire form is proven unchanged; the code path is not exercised.
- **`model_sha256` is empty, and cannot be filled over this path.** The worker cannot read
  Termux's private directory, so the provenance link that exists for the Qwen artifact **does not
  exist for Gemma**. The result says `""` rather than lying.
- **The result does not echo the backend id.** `HttpInferenceBackend` puts `backend` in its
  envelope, but the Mac-side `inferenceOutput` projection (a fixed key set) drops it. Which
  backend ran is inferable only from `model_file` + `runtime.name` + `model_load_ms = 0`. Cosmetic,
  but it is not what the phase title implies.
- **Throughput collapsed on the second run** (10 tokens in 99 s vs 4.5 tok/s in the standalone
  probe) at battery 33.2 °C — so not thermal. Device load average was **7.33** with **297 MB**
  of swap free. This is a direct correction to the checkpoint-4 headroom rule proposed earlier:
  a memory-only gate (`MemAvailable − coldStart ≥ 512 MB`) passes here (2.93 GB available) while
  latency degrades ~40×. **The gate must include load average, not just memory.**
- **The `llama-server` I started is still running** (pid 24576). `adb shell kill` returns
  `Operation not permitted` — it runs under Termux's uid, and `run-as com.termux` is unavailable
  for a non-debuggable app. Stop it in Termux (`pkill llama-server`) or authorise
  `adb shell am force-stop com.termux`, which also kills any other Termux session. It is worth
  noting that `MemAvailable` stays at ~3.1 GB because the weights are file-backed and reclaimable
  (`RssAnon` 118 MB against `RssFile` 2.57 GB), so the resident server costs less than its VmRSS
  suggests.

## Files

Modified: `DTCA1Worker/app/src/main/AndroidManifest.xml`, `DTCA1Worker/app/src/main/java/
com/pixeldesktop/worker/LlmWorkload.java`, `PixelDesktopCLI/{CLIInvocation,CLIRunCommand,
CLIEnvelope,CLIDeviceSelection,CLIRunResult,CLIScheduleCommand,CLIScheduledRunReport,main}.swift`, `PixelDesktop/Inference/InferenceRuntime.swift`,
`PixelDesktop.xcodeproj/project.pbxproj` (regenerated from `project.yml`), `project.yml`.

New: `DTCA1Worker/app/src/main/java/com/pixeldesktop/worker/HttpInferenceBackend.java`,
`DTCA1Worker/app/src/main/res/xml/network_security_config.xml`,
`PixelDesktopTests/Phase10BackendSelectionTests.swift`.

Nothing committed.

# Handoff — PixelDesktop Phase 1 (C1+C2) device verification

**Date:** 2026-10-24 · **Device:** Pixel 7a, serial `3C261JEHN25632`, Android 16, aarch64 · **Termux:** 0.118
**Model:** `gemma-3n-E4B-it-Q4_K_S.gguf`, 4,404,697,216 bytes, 6.87 B params, 6.87 B, ftype `Q4_K - Small`

---

## State

- **C1** (`TermuxNodeInstaller` + `LlamaServerService`) and **C2** (`OnDeviceInferenceJob`) were
  committed at `0f74b40` with a green suite and **zero tests referencing them**.
- This pass read the code against the real device. It found **three real defects** in that code
  and closed the coverage gap.
- **C2 is verified end to end.** **C1's `status`/`health` work; `start`/`stop` are blocked by a
  device-side Termux setting, not by the code.**
- The "screen broken" constraint in the previous revision of this file is **stale** — screenshots
  are readable and were used throughout.

---

## 1. The channel — what can and cannot reach Termux

This governs everything else, so it comes first.

| Attempt | Result |
|---|---|
| `am start … -e com.termux.execute "<cmd>"` | **Not executed.** Termux 0.118 dropped the extra. Intent delivered; no command ran, no side effect. |
| `am startservice … RunCommandService` | `Requires permission com.termux.permission.RUN_COMMAND` |
| `pm grant com.android.shell com.termux.permission.RUN_COMMAND` | exits 0 and **silently does nothing** — not in the shell's manifest |
| `adb shell pkill -f llama-server` | `Operation not permitted` — shell cannot signal a Termux-UID process |
| `su -c …` | `su: inaccessible or not found` |
| `adb root` | `adbd cannot run as root in production builds` |
| `run-as com.termux` | `run-as: package not debuggable: com.termux` |

**The only channel that reaches a Termux shell is the interactive terminal UI** —
`adb shell input text` / `input keyevent` against the focused `TermuxActivity`. There is no
headless path on this device.

### 1.1 That channel drops leading characters

`input text` issued before the IME is ready loses the first keystrokes:

```
typed:    bash /data/local/tmp/pd_chan.sh
arrived:  ash  /data/local/tmp/pd_chan.ashsh
```

A dropped leading character does not fail loudly — it turns a command into a *different* one,
which is worse. Fix: focus the terminal, then **wait 3 s** before typing. Re-measured with the
settle: `PROBE12345` arrived intact.

---

## 2. C1 defects found and fixed

### 2.1 `status()` matched its own invocation — and the obvious fix is also broken

`status` used `pgrep -f llama-server`. `-f` matches the **full command line**, and the `adb shell`
wrapper's command line contains the string `llama-server` — so `pgrep` reported the wrapper's PID
alongside the server's, and `status` took the *first* line, which is not guaranteed to be the
server.

Measured:

```
$ adb shell pgrep -f llama-server
8329        ← the server
8540        ← the adb shell wrapper
```

A later run returned the wrapper's PID first.

The obvious fix is `pgrep -x`, and **it does not work on this device**. procps-ng 4.0.7 returns
nothing for an exact-name match even when the name is right:

```
cat /proc/8329/comm          → llama-server
pgrep -x llama-server        → (nothing)
pgrep -a -x llama-server     → (nothing)
pgrep llama-server           → 8329
pidof llama-server           → 8329
```

**Fixed** to `pidof llama-server || echo NONE`. `pidof` matches the exact process name, cannot
match a shell, and works on this build. Verified: `pidof llama-server` → `8329` while running,
`pidof nosuchproc` → nothing, and `pidof llama-server` → nothing after `kill 8329`.

### 2.2 `start()` bound every interface

`start` issued `--host 0.0.0.0`. `adb forward` reaches the device's **loopback**, so binding all
interfaces buys nothing and publishes an unauthenticated inference endpoint on the LAN.
**Fixed** to `--host 127.0.0.1`.

### 2.3 The two Compute files held each other's implementations

```
Compute/LlamaServerService.swift   → contained ADBTermuxNodeInstaller
Compute/TermuxNodeInstaller.swift  → contained ADBLlamaServerService
```

Both types existed and compiled, so nothing failed — but each file's header comment described the
other's type. **Fixed:** each implementation now lives in its own file.

### 2.4 `start`/`stop` are unreachable — and are kept as the correct request

Per §1 there is no headless channel, so `start`/`stop` cannot complete. They are **not deleted**:
the unblock is a user action on the device, not a code change, and deleting them would discard the
correct request. Both files carry the channel table above so the next reader does not rediscover it.

**Unblock:** Settings → Termux → "Allow external apps to run commands", or root.

---

## 3. C2 — verified end to end

The inference path **works**. Exercised against a real `llama-server` on the device, serving
**gemma-3n-E4B-it-Q4_K_S** (6.87 B params, `Q4_K - Small`, ctx 2048, 8 threads, CPU-only):

```
POST /completion
{"prompt":"…","n_predict":24,"temperature":0.1,"stream":false}
→ 200, `content` + `tokens_predicted` present
```

| Run | Prompt | Generation | Result |
|---|---|---|---|
| 1 | 6 tok in 993 ms (6.04 tok/s) | 20 tok in 5.55 s (3.42 tok/s) | `" Paris.\n\nThis is a statement of fact…"` |
| 2 | 12 tok in 1520 ms (7.89 tok/s) | 4 tok in 2136 ms (1.40 tok/s) | `" 4\n"` — correct |

Both stopped on `stop_type: "eos"`. The request shape and the two fields read back are exactly
what `run` sends and parses.

**Refactor:** response parsing extracted to `parseCompletionBody(_:)` so it is testable without a
live server. The fields read back (`content`, `tokens_predicted`) are the server's own names; a
rename on either side is the kind of defect a unit test catches cheaply.

---

## 4. Device-side state

### Toolchain — installed and verified

```
clang    21.1.8   (aarch64-unknown-linux-android24)
cmake    4.4.4
git      2.56.0
wget     1.25.0
curl     8.23.0
```

Recovered from an interrupted `dpkg` state. The recovery needed the non-interactive guards
(`DEBIAN_FRONTEND=noninteractive` + `force-confold`); the first attempt **hung on a conffile
prompt** for `sources.list` — a real trap for any unattended bootstrap.

### Model

`gemma-3n-E4B-it-Q4_K_S.gguf` (4,404,697,216 bytes, sha256 `2b24f937…c4be49`) downloaded from
Hugging Face, pushed to `/data/local/tmp/`, and copied into Termux home as
`~/models/gemma-3n-E4B-it-Q4_K_S.gguf`.

The server came up clean:

```
load_model: loading model '…/gemma-3n-E4B-it-Q4_K_S.gguf'
init: llama threadpool init, n_threads = 8
load_model: initializing, n_slots = 4, n_ctx_slot = 2048, kv_unified = 'true'
llama_server: model loaded
llama_server: listening on http://127.0.0.1:8080
```

**One trap worth recording:** a previous `llama-server` (the Qwen model) was still running and
held port 8080, so the new server failed with `couldn't bind HTTP server socket` while
`curl /health` still returned `200` — the probe was answering for the *old* server. A health
check that succeeds does not mean *your* server is up. `pgrep`/`ss` could not see the process
(`/proc/net/tcp` is permission-denied for the Termux shell); `pgrep -a -f llama` and
`pidof llama-server` could.

---

## 5. What changed in the code

| File | Change |
|---|---|
| `Compute/LlamaServerService.swift` | `pidof` (was `pgrep -f`); `--host 127.0.0.1`; correct file contents; channel table documented |
| `Compute/TermuxNodeInstaller.swift` | Correct file contents; blocked methods documented rather than deleted |
| `Compute/OnDeviceInferenceJob.swift` | Extracted `parseCompletionBody`; verified request shape documented |
| `App/AppState.swift` | C1/C2 surfaced: status, health, start/stop, inference job |
| `App/InferenceView.swift` | **New** tab; renders published state, computes nothing |
| `App/ContentView.swift` | `Inference` tab wired |
| `Tests/Phase1ComputeTests.swift` | **New**: 15 tests pinning command construction and response parsing |

**Suite:** 665 tests, 26 skipped, **0 failures**. The 15 new tests were verified individually
with `-only-testing:PixelDesktopTests/Phase1ComputeTests`.

---

## 6. What remains

1. **`start`/`stop` stay blocked** until the device-side Termux setting is changed. Not a code task.
2. **The interactive channel is the only one.** Any future headless path needs the Termux setting
   or root; neither is available to this host.
3. **`input text` remains timing-sensitive.** The 3 s settle is a workaround, not a fix — a dropped
   leading character still turns a command into a different one rather than failing loudly.
4. **C1/C2 have no live-device test.** The unit tests pin construction and parsing; the end-to-end
   path is verified by this document, not by an automated test.
5. **A health check is not a readiness check.** `curl /health` returning 200 only means *something*
   is on the port. Confirming the right server is up needs the process identity, which on this
   device means `pidof`/`pgrep -a -f` — `ss` and `/proc/net/tcp` are permission-denied.

---

## 7. Current device state

- `llama-server` running on the device, serving `gemma-3n-E4B-it-Q4_K_S` on `127.0.0.1:8080`.
- `adb forward tcp:8080 tcp:8080` is set, so the Mac reaches it at `http://127.0.0.1:8080`.
- Toolchain present: clang 21.1.8, cmake 4.4.4, git 2.56.0, wget 1.25.0, curl 8.23.0.
- Model staged at `~/models/gemma-3n-E4B-it-Q4_K_S.gguf` inside Termux.
- `~/models/` holds both `gemma-3n-E4B-it-Q4_K_S.gguf` (4.40 GB, in use) and the superseded
  `Qwen3.5-4B-Q4_K_S.gguf` (2.65 GB, still present). Remove the Qwen copy to reclaim the space.

---

## Files

- `PixelDesktop/Compute/TermuxNodeInstaller.swift`
- `PixelDesktop/Compute/LlamaServerService.swift`
- `PixelDesktop/Compute/OnDeviceInferenceJob.swift`
- `PixelDesktop/App/AppState.swift`
- `PixelDesktop/App/InferenceView.swift`
- `PixelDesktop/App/ContentView.swift`
- `PixelDesktopTests/Phase1ComputeTests.swift`

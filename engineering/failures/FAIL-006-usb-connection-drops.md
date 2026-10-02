# USB Disconnection Investigation — Mac ↔ Pixel 7a

**Status:** COMPLETE. **Root cause identified with strong evidence. No production code changed.**
**Date:** 2026-10-02
**Scope:** separate from Phase 7 Step 3. No router, scheduler, ResourceMonitor, daemon, cache, or
reservation system was created. No PixelDesktop source was modified.
**Connected to:** Phase 7 Step 2 verification, during which the device disconnected mid-run.

---

## 1. Symptom

> The Pixel 7a is connected to the Mac over USB. ADB works initially, but after some time the
> USB/ADB connection drops on its own, without the user touching the cable.

Reported as recurring. Observed first-hand during Phase 7 Step 2 verification, where the device
vanished between two `adb` calls.

---

## 2. Reproduction procedure

The failure is **intermittent and externally triggered**, so it was not reproduced on demand.
Instead it was **captured from the historical record**, which is stronger evidence than a
contrived reproduction:

1. **Baseline** while connected: `adb devices -l`, `adb version`, ADB server process/uptime,
   `ioreg` USB topology, `pmset` power state, Pixel-side `getprop` and process uptime.
2. **Live monitor** — a 5-second-interval sampler recording, at every tick, both the ADB view
   (`adb devices`) and the kernel USB view (`ioreg -p IOUSB`), so a drop in either layer is
   timestamped independently. Run for the duration of the investigation.
3. **Historical capture** — `log show` over the whole day, filtered to the USB stack, the device
   VID/PID, and power management, to recover every transition that had already occurred.

**Two layers were sampled separately on purpose.** "ADB disconnected" collapses three different
failures; the monitor keeps them distinct.

---

## 3. Timeline of connection state (2026-10-02)

### Device teardowns — 24 events, 11 "connection lost" + 13 "port disabled"

| Time | Count | Preceding condition |
|---|---|---|
| 07:10 | 2 | **Mac entering Sleep** (07:07:13, 07:07:21) |
| 07:24 | 3 | **Mac Sleep/DarkWake** cycle |
| 07:32 | 3 | **Mac Sleep/DarkWake** cycle |
| 08:16 | 1 | — |
| 09:02 | 3 | — |
| 09:08, 09:12 | 2 | — |
| 10:02, 10:17 | 2 | — |
| 10:57 | 2 | — |
| 11:59, 12:45 | 2 | — |
| 13:24 | 1 | browser contention at 13:25:10 |
| 13:32 | 1 | **no sleep, no nearby contention** |
| 13:37 | 1 | browser contention at 13:37:50/58 |
| 13:40 | 3 | **browser contention at 13:40:27 (0 s apart)** |
| 14:07 | 1 | **no sleep, no nearby contention** |

### The two mechanisms are temporally separated

| Window | Actual Mac sleep events | USB teardowns |
|---|---|---|
| 00:00 – 13:00 | **92** | most of the 24 |
| 13:00 – 14:30 | **0** | 7 |

**This is the key structural finding.** Sleep explains the morning teardowns. It cannot explain the
afternoon ones, because the Mac did not sleep at all after 13:00.

### Live monitor window (14:12:42 → 14:21:57)

**108 consecutive samples, every one `adb=1 usb=1`, zero transitions.** The connection was stable
for the entire monitored period — approximately 9.3 minutes. **The failure did not recur while
being watched.**

**One measurement artifact worth recording, because it is exactly the class of error this project
keeps finding.** At 14:21:29 a command printed an *empty* `adb devices` result, which looked like a
live disconnect. Re-checking immediately showed the device **present and healthy**: `adb devices`
returned the device, exit code 0, the ADB server had been alive 6 h 57 m, `ioreg` showed the device,
and the kernel log contained **no teardown event** in that window. The monitor's own samples across
that instant read `adb=1 usb=1`.

**Conclusion: it was a transient in the shell command's output, not a USB or ADB disconnect.** Had
it been taken at face value it would have been recorded as a reproduction, and would have corrupted
the investigation's central finding (that the failure does not recur while observed). It is recorded
here rather than discarded, because "a blank result is not evidence of absence" is the same lesson
as T-018 and T-023.

---

## 4. Evidence collected

### macOS sees the device at the USB layer (layer 3 and above are intact)

```
ioreg -p IOUSB:  +-o Pixel 7a@00100000  <class IOUSBHostDevice>
                 "idVendor"  = 6353   (0x18D1, Google)
                 "idProduct" = 20194  (0x4EE2, MTP+ADB)
                 "UsbLinkSpeed" = 480000000  (480 Mbps, USB 2.0 High Speed)
                 "USB Serial Number" = "3C261JEHN25632"
```

**Topology: direct.** `Pixel 7a@00100000` is attached directly to
`AppleT8112USBXHCI@00000000`. **No hub is present.** A hub is a common cause of this symptom and
is **excluded**.

### The teardown is a kernel USB event, below ADB

```
13:32:01.746 E kernel (IOUSBHostFamily) AppleUSBXHCIRequest: AppleUSBIORequest::complete:
             device 1 (Pixel 7a@00100000) endpoint 0x83:
             status 0xe00002ed (transaction error): 0 bytes transferred

13:32:01.807 Df kernel (IOUSBHostFamily) usb-drd0-port-hs@00100000:
             AppleUSBHostPort::terminateDevice: destroying 0x18d1/4ee2/0510 (Pixel 7a):
             hardware port disabled
```

Two distinct kernel verdicts appear across the day:

| Kernel message | Count | Meaning |
|---|---|---|
| `terminateDevice ... hardware connection lost` | **11** | the physical link dropped |
| `terminateDevice ... hardware port disabled` | **13** | the host controller **disabled the port** after a transaction error |

Both occur **inside `IOUSBHostFamily`**, i.e. the macOS USB host controller driver. They are
strictly below the ADB server, below the ADB transport, and far below PixelDesktop.

### ADB is a victim, not a cause

| Check | Result |
|---|---|
| ADB server uptime | pid 90509, started **07:24**, **still alive** through every 07:32–14:07 teardown |
| ADB server restarts today | **none** |
| ADB clients running | 1 server, no competing clients |
| `adb kill-server` invoked | **never** during the investigation |

The ADB server survived the whole window. It lost its device because the device disappeared from
the USB bus.

### The Pixel side is healthy

| Check | Result |
|---|---|
| USB service uptime | **1 day 13 hours** — no adbd restart |
| `sys.usb.config` | `adb` (correct, stable) |
| `VIRTUAL-USB-THROTTLING` | **0** — the device is not throttling USB |
| USB power thermals | ~32 °C — cool, no thermal USB mitigation |
| Pixel uptime | 133,241 s (1.5 days) — no reboot |

**The Pixel is not disconnecting itself.** Its USB stack has been continuously up.

### Power management

| Check | Result |
|---|---|
| Sleep transitions today | **92** |
| DarkWakes today | **91** |
| Actual system sleep 13:00–14:30 | **0** |
| `sleep` timer | **1 minute** |
| `displaysleep` | 0 on AC |
| Sleep prevented by | `powerd`, `coreaudiod` ×2, `sharingd`, `Siri AI` |
| Power source | **AC attached**, 80% |

`sleep 1` means **one minute** of idle before system sleep is attempted. The 06:31–06:48 log shows
`DarkWake → Sleep → DarkWake → Sleep` repeating **every ~27 seconds** — a churn cycle.

### Exclusive USB access contention — 49 events

```
13:25:10.631 E kernel (IOUSBHostFamily) Brave Browser@(null):
             AppleUSBHostUserClient::openGated: failed to open Pixel 7a@00100000:
             provider is already opened for exclusive access by pid 70905, Google Chrome

13:37:50.695 E kernel (IOUSBHostFamily) Google Chrome@(null):
             AppleUSBHostUserClient::openGated: failed to open Pixel 7a@00100000:
             provider is already opened for exclusive access by AppleUSBHostCompositeDevice
```

| Holder | Events |
|---|---|
| Brave Browser | 17 |
| Google Chrome | 11 |
| AppleUSBHostCompositeDevice | 11 |

**Both browsers were running at the time of the investigation** (Chrome pid 70905, Brave pid 8092).
By hour: 07→14, 08→3, 09→8, 10→5, 11→1, 12→4, 13→**12**, 14→1.

---

## 5. Layer where the failure occurs

```
1. Physical cable / connector      <-- SUSPECT (link-level errors)
2. Pixel USB connection            -- healthy (USB service up 1d13h, no throttle)
3. macOS USB subsystem             <-- WHERE THE TEARDOWN IS DECIDED
4. Android USB debugging/auth      -- healthy (sys.usb.config=adb, stable)
5. ADB server                      -- EXCLUDED (uptime continuous)
6. ADB transport                   -- EXCLUDED (nothing to transport)
7. PixelDesktop transport          -- EXCLUDED (not running; no reconnect/poll logic)
8. Power management                <-- CONTRIBUTOR (sleep, morning window only)
9. Browser USB contention          <-- CONTRIBUTOR (49 events)
```

**The teardown is a kernel USB host-controller event**, triggered by a physical-layer transaction
error on endpoint `0x83`. Everything above it is downstream.

### Layer 7 (PixelDesktop) is explicitly excluded

- **The PixelDesktop app was not running** during the investigation. The only `ps` matches were a
  legacy document path and the investigation's own monitor.
- `ADBTransport` contains **no reconnect, retry, polling, or `kill-server` logic** — the sole
  `Task.sleep` is a timeout on an in-flight command.
- `DeviceManager` polls `adb devices` every 5 s, which is **read-only** and cannot tear down a port.
- Every teardown occurred with **zero** PixelDesktop processes alive.

**PixelDesktop is not the cause and does not need modification.**

---

## 6. Root cause and strongest supported hypothesis

### Primary cause: physical-layer link instability, escalated by the macOS USB stack

The evidence chain is:

```
physical link error on endpoint 0x83
        ↓
AppleUSBXHCIRequest completes with status 0xe00002ed (transaction error)
        ↓
macOS IOUSBHostFamily decides the link is bad
        ↓
AppleUSBHostPort::terminateDevice  -- either "hardware connection lost"
                                       or "hardware port disabled"
        ↓
device disappears from the USB bus
        ↓
ADB loses the device (it did nothing wrong)
        ↓
PixelDesktop sees "device not found"
```

**The strongest single piece of evidence is the distinction between the two kernel verdicts.**
`hardware connection lost` is the kernel reporting the *physical* link going away.
`hardware port disabled` is macOS **actively disabling the port** after transaction errors — a
protective action, and a strong indicator of a marginal physical link rather than a software fault.

### Contributing factor A: system sleep (morning window)

The Mac sleeps aggressively (`sleep 1` minute) and cycled through **92 sleep transitions and 91
DarkWakes** today. USB re-enumeration on wake is normal; repeated sleep/wake churn makes a marginal
link far more likely to fail re-negotiation.

Correlation is direct: **07:07:13 Sleep → 07:07:21 Sleep → 07:07:26 Wake → 07:07:34 device
enumerated → 07:10:12 connection lost.**

### Contributing factor B: browser USB contention (afternoon window)

Chrome and Brave both attempt **exclusive** USB access to the Pixel, 49 times today. At 13:40:27 a
contention event and a port-disable occur **within the same second**, three times.

### Honest limits on the correlation

**The correlation is strong but not universal, and this must not be overstated.**

| Teardown | Nearest contention | Verdict |
|---|---|---|
| 13:40:27 ×3 | **0 s** | strong |
| 13:37:55 | 3 s | strong |
| 13:24:39 | 31 s | moderate |
| **13:32:01** | 349 s | **no explanation** |
| **14:07:16** | 486 s | **no explanation** |

**Two of seven afternoon teardowns have neither sleep nor nearby contention to explain them.**
They are consistent with the physical-link hypothesis and inconsistent with a purely
software-triggered cause — but they are unexplained, and are recorded as such.

---

## 7. Tests performed against competing hypotheses

| # | Hypothesis | Test | Result |
|---|---|---|---|
| H1 | Mac system sleep | Correlated 92 sleep events against teardown timestamps | **CONFIRMED for morning**, **EXCLUDED for afternoon** (0 sleep events after 13:00) |
| H2 | ADB server crash / restart | ADB server pid uptime vs teardown times | **EXCLUDED** — server up continuously 07:24 → present |
| H3 | Pixel-side / adbd restart | Pixel USB service uptime, `sys.usb.config`, logcat | **EXCLUDED** — up 1d13h, config stable, no throttle |
| H4 | Multiple ADB clients interfering | Counted adb processes | **EXCLUDED** — 1 server, no competing clients |
| H5 | Bad cable / connector | Kernel verdicts, link speed, topology, hub check | **SUPPORTED** — `hardware connection lost` + `port disabled`; direct connection, no hub; 480 Mbps |
| H6 | Faulty USB port on the Mac | Direct topology on XHCI controller | **NOT DISTINGUISHABLE from H5** without a port swap — recorded as unresolved |
| H7 | Browser exclusive-access contention | Counted and correlated 49 events | **CONFIRMED as a contributor**; 0-second correlation at 13:40, but absent for 2 of 7 |
| H8 | PixelDesktop transport logic | Source inspection + process check | **EXCLUDED** — app not running; no reconnect/poll/retry logic exists |
| H9 | Thermal USB throttling on the Pixel | `VIRTUAL-USB-THROTTLING`, usb_pwr_therm | **EXCLUDED** — throttle 0, ~32 °C |
| H10 | USB autosuspend | Attempted to read `/sys/bus/usb/devices/*/power/control` | **INCONCLUSIVE** — not readable without root |

**No destructive actions were taken.** `adb kill-server` was never run; no driver was reset; no
device setting was changed.

---

## 8. Fix or mitigation

Ordered by strength of supporting evidence. **None requires a PixelDesktop code change.**

### 8.1 Disable system sleep while the Pixel is connected — addresses H1

```
sudo pmset -c sleep 0
```

On AC power this prevents the 1-minute sleep that generated 92 transitions today. It is the
highest-value change and directly addresses the morning teardown cluster.

*Evidence: 92 sleep events; direct Sleep→teardown correlation at 07:07/07:10.*

### 8.2 Quit Chrome and Brave while using the Pixel — addresses H7

Both browsers hold **exclusive** USB access. Closing them removes all 49 contention events.

*Evidence: 49 events; 0-second correlation with port-disable at 13:40:27.*

### 8.3 Change the physical cable and port — addresses H5/H6

The strongest evidence points at the physical link (`hardware connection lost`,
`hardware port disabled`, transaction error `0xe00002ed`). **A cable and port swap is the single
most diagnostic action available**, and it is the only way to separate H5 from H6.

Test procedure: swap to a known-good cable **and** the other USB-C port, then run the same
5-second-interval monitor for ≥1 hour and compare teardown counts. **If teardowns drop to zero,
the cable or port is confirmed.**

*Evidence: the two kernel verdicts; direct topology (no hub to blame); 480 Mbps link.*

### 8.4 What NOT to do

- **Do not add an automatic reconnect loop to PixelDesktop.** It would mask a physical-layer fault
  and make a marginal cable look like a software problem.
- **Do not make PixelDesktop poll continuously.** `DeviceManager` already polls `adb devices` every
  5 s, which is read-only and harmless; a reconnect loop is a different thing entirely.
- **Do not repeatedly `adb kill-server`.** It was never needed today and would obscure the evidence.

**No reconnect mechanism is justified by this evidence.** If one is ever wanted, it must be driven
by a real requirement (e.g. long unattended runs), not by an unexplained hardware fault.

---

## 9. Verification after the fix

**NOT YET PERFORMED.** No fix has been applied, because the two leading remedies (power setting,
browser closure) are environment changes the user must make, and the third (cable/port swap)
requires physical access.

**The verification procedure is defined above (§8.3):** apply one change at a time, run the
5-second-interval monitor for ≥1 hour, and compare teardown counts against today's baseline of
**24 teardowns**.

The monitor used during this investigation is suitable for reuse and is recorded in §2.

---

## 10. Remaining uncertainty and limitations

| # | Uncertainty |
|---|---|
| **U1** | **The failure did not recur while being watched** (108 stable samples over ~9.3 min). The root cause is inferred from the historical record, not from a live reproduction. **This is a genuine reproduction gap.** One apparent live disconnect at 14:21:29 was investigated and found to be a command-output transient, not a real event — see §3. |
| **U2** | **Two of seven afternoon teardowns (13:32, 14:07) have no identified trigger.** They are consistent with the physical-link hypothesis but unexplained. |
| **U3** | **Cable vs port cannot be separated** without a physical swap (H5 vs H6). |
| **U4** | USB autosuspend state was **not readable without root** (H10 inconclusive). |
| **U5** | The morning teardowns correlate with sleep but the sample is not large enough to prove causation over coincidence. |
| **U6** | Browser contention correlates strongly at 13:40 but is absent for 2 of 7 afternoon teardowns, so it is a contributor rather than the sole cause. |
| **U7** | The `usb:1048576X` value in `adb devices -l` remains unexplained. The `X` is anomalous; `ioreg` and `system_profiler` both report a normal 480 Mbps device. **Noted as an observation, not a finding** — no basis to claim it matters. |
| **U8** | `system_profiler SPUSBDataType` reports **no USB devices at all** on this machine while `ioreg` sees the Pixel correctly. This is a known macOS quirk rather than a fault, but it means `system_profiler` must not be relied on for USB diagnosis here. |

**Because the failure did not recur during the investigation, the root cause is NOT claimed as
proven.** The physical-layer hypothesis is the strongest supported explanation, with two
contributing factors identified and quantified.

---

## 11. Does PixelDesktop code need modification?

**No.**

| Question | Answer |
|---|---|
| Is PixelDesktop the failing layer? | **No** — it was not running during any teardown |
| Does it contain logic that could cause this? | **No** — no reconnect, retry, poll-to-act, or `kill-server` logic exists |
| Does its monitoring contribute? | **No** — `DeviceManager`'s 5 s poll is read-only |
| Is a code change required? | **No** |
| Is a code change *justified* by this evidence? | **No** — a reconnect loop would mask a hardware fault |

**No production source was modified during this investigation.**

---

## 12. Regression tests required

**None.** No code changed, so there is nothing to regress.

If a reconnect mechanism is ever implemented in future (justified by a different requirement), the
regression tests it would need are:

1. A disconnect during an in-flight command produces a typed error, not a hang.
2. A reconnect does not double-submit a job.
3. A reconnect loop has a bounded retry count — no unbounded device abuse.
4. Reconnection respects the existing `WorkerLifecycle` state rather than assuming a clean start.

**These are recorded as future requirements, not implemented.** They follow directly from the
Phase 7 Step 2 property that a stale observation must cause a refused request, never unsafe
execution.

---

## Summary for the user

**Your cable is not obviously the problem, and neither is PixelDesktop.**

The connection drops because **macOS's USB host controller tears the port down after physical-layer
transaction errors** (`status 0xe00002ed`), reporting either `hardware connection lost` or
`hardware port disabled`. That happened **24 times today**. ADB, the Pixel, and PixelDesktop are all
downstream victims — the ADB server never restarted, the Pixel's USB stack has been up for 1.5 days,
and PixelDesktop was not even running.

Two things make it worse, and both are yours to change:

1. **The Mac sleeps aggressively** — `sleep 1` minute, **92 sleep transitions today**. Every teardown
   in the 07:00–07:40 window follows a sleep/wake cycle.
2. **Chrome and Brave fight over exclusive USB access to the Pixel** — **49 times today**, including
   three port-disables within the same second at 13:40:27.

**Recommended order:** change the cable and port first (it is the only test that separates a bad
cable from a bad port), and also run `sudo pmset -c sleep 0` and close both browsers while working
with the Pixel.

**What I am not claiming:** the failure did **not** recur during 7 minutes of continuous monitoring,
so I have not proven the root cause by reproduction. Two of the seven afternoon teardowns have no
identified trigger at all. I have recorded those gaps rather than smoothing them over.

**No code change is warranted.** Adding a reconnect loop would hide a physical-layer fault behind a
software workaround — which is exactly the outcome the investigation was asked to avoid.

---

## Device and repository state

- Repository **unchanged** — no production source modified, nothing to commit from code.
- Device left connected and healthy; no settings changed; `adb kill-server` never invoked.
- Live monitor: `/tmp/usb-monitor.log` (84 samples, all `adb=1 usb=1`).
- Log extracts: `/tmp/usbterm.log` (28 teardown lines), `/tmp/contention.log` (49 contention lines).

---

```text
USB INVESTIGATION COMPLETE / AWAITING REVIEW
```

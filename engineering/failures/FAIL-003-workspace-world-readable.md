# FAIL-003: Worker Workspace Created World-Readable

## Status

Resolved

## Date

2026-10-01

## Phase

Phase 5 (Pixel Compute Worker — transfer contract)

## Attempt

Create the device-side workspace at `/data/local/tmp/pixeldesktop` so worker payloads have a
fixed home.

## Observed Behaviour

The first real-device verification run reported:

```
[FAIL] remote root is not world-readable — mode=777
```

`stat -c %a` on the created directory returned **777**. The parent `/data/local/tmp` is 771.

## Evidence

```
$ adb -s 3C261JEHN25632 shell 'mkdir -p /data/local/tmp/pixeldesktop && ls -ld /data/local/tmp/pixeldesktop'
drwxrwxrwx 2 shell shell 3452 2026-10-01 23:15 /data/local/tmp/pixeldesktop

$ adb -s 3C261JEHN25632 shell stat -c %a /data/local/tmp/pixeldesktop
777

$ adb -s 3C261JEHN25632 shell ls -ld /data/local/tmp
drwxrwx--x 2 shell shell 3452 ... /data/local/tmp
```

## Diagnosis

Classified as **implementation / over-permissive default**, surfaced by real-device
verification.

ADR-010 chose `/data/local/tmp` over `/sdcard` **specifically because it is not
world-readable** — the parent is 771, whereas `/sdcard` is FUSE-mounted and readable by any
installed application. That reasoning is correct about the parent but was never true of the
directory the contract actually creates: `mkdir -p` produced 777.

The rationale was correct about the *neighbourhood* and wrong about the *thing*.

**Why unit tests could not catch it:** the test asserted that `mkdir -p` was *invoked*. The
resulting permission bits require a real filesystem to observe.

## Correction

`prepareRemoteWorkspace` now issues:

```
mkdir -p /data/local/tmp/pixeldesktop && chmod 700 /data/local/tmp/pixeldesktop
```

`testPrepareRemoteWorkspaceRestrictsPermissions` pins the requirement so the `chmod` cannot be
dropped silently.

This **tightened** the contract. It did not broaden or weaken anything — the approved design
(D1) already required a non-world-readable root; the implementation simply did not achieve it.

## Result

Re-run: `drwx------`, mode **700**, all checks PASS.

## Lesson

**A documented rationale is not a verified fact.** ADR-010's proposal argued this root is not
world-readable. The argument was sound about the parent directory and silently untrue about
the directory the contract uses.

**Verify the specific object, not the category it belongs to.** "`/data/local/tmp` is not
world-readable" does not imply "`/data/local/tmp/pixeldesktop` is not world-readable", and the
inference was never tested until the real device was asked.

**This is the third defect in this project that compiled cleanly and passed the full suite
while being wrong** (the others: `manufacturer` holding the codename in Phase 3; the
over-broad protected-package entry in Phase 4). All three were caught by comparing against
reality rather than by the test suite.

## What Should Future Agents Do Differently

- When a design decision rests on a property of the environment, **test that property on the
  actual object**, not on a related one.
- Do not assume a created resource inherits the restrictive permissions of its parent.
- When a verification step fails, first ask whether the *contract* is wrong before asking
  whether the *check* is too strict.

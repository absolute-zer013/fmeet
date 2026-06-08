# PixyControl — Development Log & Reverse-Engineering Notes

A single reference for *why* this project exists, *how* the EMEET PIXY protocol
was captured and decoded, every problem hit along the way and how it was solved,
and the trade-offs behind each decision.

---

## 1. Why this project exists

The **EMEET PIXY** is an AI PTZ (pan/tilt/zoom) USB webcam (USB ID `328f:00c0`).
Its full feature set — PTZ, presets, tracking, gesture control, audio modes,
image/exposure/focus controls, privacy, capture resolution — is only exposed
through **EMEET Studio**, which ships for **Windows and macOS only**.

On Linux there is no first-party control software. The camera works as a plain
UVC webcam (you get video), but everything that makes it a *PTZ AI* camera is
locked behind a proprietary USB protocol with no public documentation.

**Goal:** a native Linux desktop app that talks the camera's protocol directly,
so the PIXY is fully usable on Linux without a Windows VM.

**Stack:** Flutter (Linux desktop, 3.35.0 via FVM), Dart FFI to `hidapi` for the
HID control channel, `v4l2-ctl` for UVC image controls, and `mpv`/`ffmpeg`
subprocesses for the video stream.

### This project did NOT start from scratch

The protocol work builds on **PixyBar** by **RoseWaveStudio** (MIT-licensed) —
<https://github.com/RoseWaveStudio/PixyBar> — which did the initial
reverse-engineering of the PIXY HID command set. This
project took that as a starting point and **extended and verified it on Linux**:
re-captured the traffic with a fresh labelled session (`assets/log`), confirmed
and corrected framings against real hardware, decoded additional commands
(resolution/fps, exposure menu values, the tracking-is-a-mode behaviour, gesture
status/channel details), and built the full Flutter control application,
in-app MJPEG preview, and FFI transport around it. `assets/PROTOCOL.md` carries
the same attribution inline. Credit for the original protocol groundwork goes to
PixyBar; the bugs, fixes, and the Linux app are this project's.

---

## 2. How the protocol was captured (step by step)

The camera exposes a **vendor HID interface** (interface 4 of the USB device) for
control, plus the standard **UVC** interface for video and image controls. The
control protocol is undocumented, so it had to be reverse-engineered by watching
EMEET Studio talk to the camera.

### 2.1 Tooling
- **`assets/pixysniff.py`** — a USB sniffer that decodes the traffic into
  human-readable lines (HID frames on the vendor interface and `UVC SET_CUR`
  control transfers on the UVC interface).
- EMEET Studio runs in a **Windows environment with USB passthrough** (a Windows
  VM / Winboat) so the real app drives the real camera while the sniffer
  watches on the host.

### 2.2 Method — one action at a time
The key discipline: **isolate a single action per capture**. For each feature:

1. Start the sniffer.
2. In EMEET Studio, perform exactly **one** operation (e.g. only toggle gesture,
   or only change resolution to 1080p).
3. Stop, and look at the handful of frames that appeared.
4. Repeat for the on/off (or min/max) variants so the changing byte is obvious.

The result of this process is **`assets/log`** — a labelled capture covering
resolution/fps, audio modes, camera modes, zoom, flip, anti-flicker, all image
sliders, focus, privacy timer, gesture, and auto-rotate.

### 2.3 Decoding the frames
**HID control frames are 32 bytes.** Decoding the device's HID *report
descriptor* (`/sys/class/hidraw/hidrawN/device/report_descriptor`) showed:

```
Report ID 0x09 + 31 data bytes  →  32-byte reports
```

So the leading `0x09` that every frame starts with **is the HID Report ID**, not
a magic constant. Frame layout used throughout the app (`assets/PROTOCOL.md`):

```
byte 0      0x09         report id
byte 1      group        response echoes group OR'd with 0x60
byte 2      channel      0x00 system, 0x01 gimbal, 0x02 AI/async
byte 3      sub          sub-command
byte 4      0x00
bytes 5-6   length        payload length, little-endian u16
byte 7      chunk         payload bytes in this report
bytes 8+    payload        (status 0x20 = OK / 0x40 = reject; floats LE f32, degrees)
```

Examples pulled straight from the capture:
- **Gesture on/off:** `09 04 02 00` + payload `02 01` / `02 00`; the OK status
  `0x20` lands in the *second* payload byte (`02 20`).
- **Camera mode:** `09 01 01 00` + payload `00` standard / `01` tracking /
  `02` privacy.
- **Privacy timer:** `09 02 01 00` + u32 LE seconds.
- **Flip / auto-rotate:** `09 04 00 08` + `<id> <0/1>`.

Image/exposure/focus/WB/zoom are **UVC `SET_CUR`** transfers (not HID), which map
to standard `v4l2-ctl` controls on Linux — e.g. fps appears in the UVC
`dwFrameInterval` (100 ns units: 30 fps = `0x051615`, 60 fps = `0x028b0a`).

### 2.4 Verifying on real hardware
Decoded guesses were confirmed with throwaway Dart probes
(`tool/live_probe.dart`, `tool/ptz_gesture_probe.dart`) that open the real HID
device and exercise one command while watching the read-back. This is how, for
example, gesture was *proven* to toggle (`set(true)→get=true`,
`set(false)→get=false`) and how the motor primitives were ranked by what
actually moved the gimbal.

> Lesson learned the hard way: **don't guess framings blind.** Several motor
> framings were tried without a capture and none moved the gimbal — time that a
> single isolated PTZ capture would have saved.

---

## 3. Issues encountered and how they were fixed

### Build / toolchain
| Issue | Cause | Fix |
|---|---|---|
| `ffigen` dependency conflict | analyzer/macros version clash in the toolchain | Dropped ffigen; **hand-wrote** the small `hidapi` FFI binding surface |
| CMake "could not find Ninja" | `ninja` was a shell alias, no real binary | Installed system `ninja` |

### Connection / permissions
| Issue | Cause | Fix |
|---|---|---|
| Permanent "Needs permission" even with correct udev ACL | Dart `FileStat.stat` reports a **character device** (e.g. `/dev/hidraw4`) as `type == notFound`, and the permission probe rejected `notFound` | `canAccess` now only rejects real files/dirs and otherwise tries a non-destructive append-open |
| Device gets a different `/dev/hidrawN` each replug | USB re-enumeration | Discovery matches the camera by **sysfs `HID_ID`**, not a fixed path |

### Live preview
| Issue | Cause | Fix |
|---|---|---|
| App crashed (SIGSEGV) when loading the preview | `media_kit`'s in-Flutter video texture couldn't get a hardware GL context on this box (AMD radeonsi + Wayland) and fell back to **software (llvmpipe) GL**, which JIT-segfaults | Removed `media_kit`; held the stream with an `mpv --vo=null` keepalive and showed video in a separate **mpv window** |
| (later) wanted preview **inside** the app | — | The PIXY streams **MJPG natively**, so `ffmpeg … -c:v copy -f mjpeg pipe:1` copies its JPEG frames out; Dart splits them on the JPEG `FFD8…FFD9` markers and paints each with `Image.memory` — pure Flutter, **no GL, no media_kit, no external window** |

### The field crash (spontaneous + on arrow press)
- **Symptom:** SIGSEGV a few seconds after launch with no interaction, and on
  arrow press. Confirmed in **both** debug (JIT) and release (AOT) cores, on the
  Dart UI isolate executing our own app code.
- **Ruled out:** FFI buffer overflow (the report descriptor proves 32-byte
  reports fit the buffers exactly); software-GL fallback (the GPU's hardware GL
  libraries were loaded, not llvmpipe).
- **Root cause:** every UI panel did `context.watch<DeviceController>()`, so
  **any** `notifyListeners()` rebuilt the whole widget tree. The async-push
  handler fired a notify on **every** camera push with no change-guard or
  throttle → a rebuild storm that destabilised the GTK/GL engine.
- **Fix:** `_notify()` now **coalesces to one rebuild per frame**; the push
  handler **change-guards** (only notifies on a real change) and **debounces**
  its follow-up reads; the HID read pump was slowed 8 ms → 25 ms.
- **Diagnostics:** because it couldn't be reproduced in development, a breadcrumb
  logger (`lib/core/diag/crash_log.dart`, writes `$XDG_RUNTIME_DIR/pixyctl.log`)
  plus `FlutterError`/`PlatformDispatcher`/isolate error handlers were added so
  the *next* crash's last line names the failing operation. `tool/run-release.sh`
  also offers a `GDK_BACKEND=x11` toggle to test the XWayland path.

### Motor / PTZ
| Issue | Finding | Resolution |
|---|---|---|
| Relative move commands (`09 03 01 19`, `09 63 01 19`) never moved the gimbal | Hardware probes: no motion | Abandoned |
| Absolute (`09 03 01 18`) accepted but unreliable for non-zero targets | "Recenter" (to 0,0) moved, arbitrary targets didn't | Not used for arrows |
| `getPosition` (`09 03 01 14`) returns a **frozen** value | Read-back is stale | Don't poll it; the readout tracks the commanded target instead |
| Velocity (`09 63 01 20`, the knob) is the **only** primitive that reliably moves | Confirmed every session | **Arrows are a velocity pulse**: drive at 18°/s in the step direction for `step°/18` seconds, then stop — a "move right 10°"-style nudge |
| Arrow press ran the gimbal to the mechanical limit | The crash killed the app mid-pulse before the stop fired → runaway | Fixing the crash removed the runaway; the pulse is also capped and the `mpv` keepalive's `pdeathsig` closes the stream (ungates/stops the motor) if the app dies |

### AI features
| Issue | Cause | Fix |
|---|---|---|
| **Subject tracking** toggle did nothing | There is **no standalone tracking command** — "tracking" is a **camera mode** (`09 01 01 00` payload `01`). The old `09 04 01 00` framing was bogus | Toggle now drives `setMode(tracking/standard)` |
| **Gesture** toggle "did nothing" | Two real bugs: the OK status was read from the wrong payload byte, and the response matcher collided with the tracking GET (they differ only in the **channel** byte) | Read status from payload[1]; matchers now check the channel. **Verified on hardware that the flag toggles** |
| Gesture still "not detected" | The camera only **detects** gestures while it is actively framing — i.e. **Tracking mode on**. Detection is firmware-side; the app only sets the enable flag | UI now says so |
| Live tracking state didn't reflect a hand-gesture toggle | The UI only knew about commands it sent | A 1.5 s **mode poll** (`09 01 01 01`, which returns live values) mirrors mode→UI. **Crucially, the gesture channel is *not* polled** — polling `09 04 02 01` in the background **broke the camera's gesture detection** |

### Image controls
| Issue | Cause | Fix |
|---|---|---|
| **Auto-Exposure** button + slider not working | Code set `auto_exposure` to `8` and tested `value == 8`, but on this device it's a **menu 0–3** (auto = 3 Aperture-Priority, manual = 1). The set was silently clamped to 3, so the switch never matched its own read-back and looked dead; the slider gate was also wrong and the control's `inactive` flag wasn't refreshed | Use the real menu values (auto = default, manual = 1), gate on `value`, and re-enumerate after the toggle |

### Features added
- **Picture quality** selector — 4K / 2K / 1080p / 720p with a **30/60 fps**
  toggle (60 fps only at 1080p/720p), driving the `mpv`/`ffmpeg` stream format;
  digital zoom is gated to non-4K per the camera's spec.
- **In-app live preview** (see above).
- **Live mode/tracking** reflection via the mode poll.
- Removed the redundant "Go to position" section.

### Not supported / not tested

Deliberately out of scope or unverified:

- **Whiteboard mode** — not supported.
- **Desktop mode** — not supported.
- **Screen capture** — not supported. In the capture, EMEET Studio's screen-
  capture action produced **no protocol response**, so there is nothing to drive.
- **Screen recording** — not supported (same: no response observed).
- **Microphone** — the camera's audio *modes* (Live / Original / Noise-Cancel)
  are implemented and switch fine, but the **microphone capture path itself was
  not tested** (no recording/mixing validation). Audio-mixing in EMEET Studio
  also returned no response in the capture.
- **Firmware update** — not supported. There is no firmware-update feature; this
  app only controls the camera, it does not flash or update its firmware (see the
  firmware trade-off below for why that's intentionally out of scope).

These are documented here so the gap is explicit rather than assumed-working.

---

## 4. Trade-offs

- **Hand-written FFI vs `ffigen`** — hand-written bindings dodge a toolchain
  dependency conflict; the cost is maintaining ~10 function signatures by hand
  (the surface is tiny and stable, so this is cheap).
- **`ffmpeg` MJPEG pipe + `Image.memory` vs `media_kit`** — the in-app preview
  decodes JPEG on the **CPU** and paints with Flutter's normal image path. The
  win: it sidesteps the GTK GL-texture crash entirely and needs no native plugin.
  The cost: more CPU than a hardware-GL video texture (light at 720p/1080p,
  heavier at 4K) and a dependency on the `ffmpeg` binary.
- **Velocity-pulse arrows vs absolute** — velocity is the *only* primitive that
  moves this gimbal, so arrows use it. Open-loop (no position feedback, since the
  read-back is frozen) means the step distance is approximate, and a held
  velocity carries a theoretical runaway risk — mitigated by the crash fix, a
  capped pulse, and the stream-gate (`pdeathsig`) backstop.
- **Mode polling vs push** — the camera does push some events, but not a clean
  tracking-mode change, so a 1.5 s poll of `getMode` is used. The cost is a small
  steady HID read; the benefit is the UI reflecting gesture-driven tracking. The
  gesture channel is deliberately left unpolled because polling it breaks
  detection.
- **Host-side custom gestures — considered and rejected.** We already have the
  video frames, so a host-side hand model (MediaPipe/ONNX) could add arbitrary
  gestures mapped to any command, with no firmware risk. Rejected by the project
  owner as not worth the extra CPU and dependencies. (Note: that load would fall
  on the PC, not the camera.)
- **Firmware gesture injection — not feasible.** Gesture recognition runs on the
  camera's own SoC/NPU; the host only flips an enable flag. Adding a gesture
  there would require the (closed, almost certainly signed) firmware image, the
  model format, and a flashing tool — with a real bricking risk and no SDK. Dead
  end.
- **Public repository** — the project owner chose to publish, which makes the
  reverse-engineered protocol (`assets/PROTOCOL.md`) and the capture (`assets/log`)
  publicly visible. Intentional, to document the protocol for others.

---

## 5. Contributors & credits

- **PixyBar** by **RoseWaveStudio** (MIT) —
  <https://github.com/RoseWaveStudio/PixyBar> — the original PIXY HID protocol
  reverse-engineering this project is built on. The base command set came from
  PixyBar; this project extended, corrected, and verified it on Linux.
- **mfahmitj** (GitHub [@absolute-zer013](https://github.com/absolute-zer013)) —
  project owner and direction; hardware (the EMEET PIXY, AMD/Wayland/Linux test
  rig); all USB packet captures against EMEET Studio; every round of on-device
  testing and verification; product decisions and trade-off calls.
- **Claude (Opus 4.8)** — implementation, protocol decoding from the captures,
  FFI/transport layer, crash diagnosis, and this document. Co-authored the
  commits.

---

## 6. Key references in this repo

- `assets/PROTOCOL.md` — the decoded command reference.
- `assets/log` — the labelled pixysniff capture (ground truth).
- `assets/pixysniff.py` — the USB sniffer.
- `lib/core/protocol/` — frame encode/decode + typed command builders (unit-tested
  in `test/protocol_test.dart`).
- `lib/core/transport/` — hidapi FFI + the HID read/write transport.
- `lib/core/stream/preview_controller.dart` — mpv keepalive + ffmpeg MJPEG preview.
- `lib/state/device_controller.dart` — device state, intent methods, polling.
- `tool/` — throwaway hardware probes; `run-release.sh` launcher.

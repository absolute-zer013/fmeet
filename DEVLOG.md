# PixyControl: Development Log & Reverse-Engineering Notes

A single reference for why this project exists, how the EMEET PIXY protocol was
captured and decoded, every problem hit along the way and how it was solved, and
the trade-offs behind each decision.

**Status: complete and working.** PTZ, presets, camera modes, subject tracking,
gesture control, the full image/exposure/focus/zoom set, audio modes, the privacy
timer, picture-quality selection, and the in-app live preview all run on Linux
against real hardware. The startup crash, the gesture-reflect latency, the
software-GL flicker, and the accessibility console noise are all resolved, and the
app installs into the desktop menu. Remaining gaps are the deliberately
out-of-scope features listed in section 3 (whiteboard/desktop/capture/record,
firmware update) and the untested microphone capture path.

---

## 1. Why this project exists

The EMEET PIXY is an AI PTZ (pan/tilt/zoom) USB webcam (USB ID `328f:00c0`). Its
full feature set, covering PTZ, presets, tracking, gesture control, audio modes,
image/exposure/focus controls, privacy, and capture resolution, is only exposed
through EMEET Studio, which ships for Windows and macOS only.

On Linux there's no first-party control software. The camera works as a plain UVC
webcam, so you do get video, but everything that makes it a PTZ AI camera is
locked behind a proprietary USB protocol with no public documentation.

The goal here is a native Linux desktop app that talks the camera's protocol
directly, so the PIXY is fully usable on Linux without a Windows VM.

The stack is Flutter (Linux desktop, 3.35.0 via FVM), Dart FFI to `hidapi` for
the HID control channel, `v4l2-ctl` for UVC image controls, and `mpv`/`ffmpeg`
subprocesses for the video stream.

### This project did NOT start from scratch

The protocol work builds on **PixyBar** by RoseWaveStudio (MIT-licensed) at
<https://github.com/RoseWaveStudio/PixyBar>, which did the initial
reverse-engineering of the PIXY HID command set. This project took that as a
starting point and extended and verified it on Linux: it re-captured the traffic
with a fresh labelled session (`assets/log`), confirmed and corrected framings
against real hardware, decoded additional commands (resolution and fps, the
exposure menu values, the tracking-is-a-mode behaviour, the gesture
status/channel details), and built the full Flutter control application, the
in-app MJPEG preview, and the FFI transport around it. `assets/PROTOCOL.md`
carries the same attribution inline. Credit for the original protocol groundwork
goes to PixyBar; the bugs, the fixes, and the Linux app are this project's.

---

## 2. How the protocol was captured (step by step)

The camera exposes a vendor HID interface (interface 4 of the USB device) for
control, plus the standard UVC interface for video and image controls. The
control protocol is undocumented, so it had to be reverse-engineered by watching
EMEET Studio talk to the camera.

### 2.1 Tooling
- `assets/pixysniff.py` is a USB sniffer that decodes the traffic into
  human-readable lines, covering both HID frames on the vendor interface and
  `UVC SET_CUR` control transfers on the UVC interface.
- EMEET Studio runs in a Windows environment with USB passthrough (a Windows VM
  or Winboat), so the real app drives the real camera while the sniffer watches
  on the host.

### 2.2 Method: one action at a time
The key discipline is to isolate a single action per capture. For each feature:

1. Start the sniffer.
2. In EMEET Studio, perform exactly one operation (only toggle gesture, say, or
   only change resolution to 1080p).
3. Stop, and look at the handful of frames that appeared.
4. Repeat for the on/off (or min/max) variants so the changing byte is obvious.

The result is `assets/log`, a labelled capture covering resolution and fps, audio
modes, camera modes, zoom, flip, anti-flicker, all the image sliders, focus, the
privacy timer, gesture, and auto-rotate.

### 2.3 Decoding the frames
The HID control frames are 32 bytes. Decoding the device's HID report descriptor
(`/sys/class/hidraw/hidrawN/device/report_descriptor`) showed:

```
Report ID 0x09 + 31 data bytes  →  32-byte reports
```

So the leading `0x09` that every frame starts with is the HID Report ID, not a
magic constant. Here's the frame layout used throughout the app
(`assets/PROTOCOL.md`):

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

Some examples pulled straight from the capture:
- **Gesture on/off:** `09 04 02 00` with payload `02 01` or `02 00`. The OK status
  `0x20` lands in the second payload byte (`02 20`).
- **Camera mode:** `09 01 01 00` with payload `00` standard, `01` tracking, or
  `02` privacy.
- **Privacy timer:** `09 02 01 00` with u32 LE seconds.
- **Flip and auto-rotate:** `09 04 00 08` with `<id> <0/1>`.

Image, exposure, focus, white balance, and zoom are UVC `SET_CUR` transfers
rather than HID, and they map to standard `v4l2-ctl` controls on Linux. For
instance, fps shows up in the UVC `dwFrameInterval` (in 100 ns units, so 30 fps
is `0x051615` and 60 fps is `0x028b0a`).

### 2.4 Verifying on real hardware
Decoded guesses were confirmed with throwaway Dart probes (`tool/live_probe.dart`,
`tool/ptz_gesture_probe.dart`) that open the real HID device and exercise one
command while watching the read-back. That's how gesture was proven to toggle
(`set(true)→get=true`, `set(false)→get=false`), and how the motor primitives were
ranked by what actually moved the gimbal.

> A lesson learned the hard way: don't guess framings blind. Several motor
> framings were tried without a capture and none of them moved the gimbal, which
> is time a single isolated PTZ capture would have saved.

---

## 3. Issues encountered and how they were fixed

### Build / toolchain
| Issue | Cause | Fix |
|---|---|---|
| `ffigen` dependency conflict | analyzer/macros version clash in the toolchain | Dropped ffigen and hand-wrote the small `hidapi` FFI binding surface |
| CMake "could not find Ninja" | `ninja` was a shell alias with no real binary | Installed the system `ninja` |

### Connection / permissions
| Issue | Cause | Fix |
|---|---|---|
| Permanent "Needs permission" even with the correct udev ACL | Dart `FileStat.stat` reports a character device (e.g. `/dev/hidraw4`) as `type == notFound`, and the permission probe rejected `notFound` | `canAccess` now only rejects real files and dirs, and otherwise tries a non-destructive append-open |
| Device gets a different `/dev/hidrawN` each replug | USB re-enumeration | Discovery matches the camera by its sysfs `HID_ID`, not a fixed path |

### Live preview
| Issue | Cause | Fix |
|---|---|---|
| App crashed (SIGSEGV) when loading the preview | `media_kit`'s in-Flutter video texture tripped the same radeonsi GL-texture-upload bug later confirmed by the core (see "The field crash") | Removed `media_kit`; held the stream with an `mpv --vo=null` keepalive and showed video in a separate mpv window (later replaced by the in-app MJPEG painter plus software GL) |
| Wanted the preview inside the app, not a separate window | follow-up request | The PIXY streams MJPG natively, so `ffmpeg … -c:v copy -f mjpeg pipe:1` copies its JPEG frames out; Dart splits them on the JPEG `FFD8…FFD9` markers and paints each one with `Image.memory`. Pure Flutter, with no GL, no media_kit, and no external window |

### The field crash (SIGSEGV during preview)
The symptom was a SIGSEGV a few seconds into a session with no interaction needed.
It was intermittent: an idle launch could run fine, and it only fired once the
live preview started pushing frames.

A saved core (`coredumpctl debug … -ex 'thread apply all bt'`) put the crashing
thread squarely in the GPU driver rather than in our Dart code:

```
SkImages::CrossContextTextureFromPixmap   ← Flutter uploads a decoded image to a GL texture
GrGLGpu::uploadTexData → glTexSubImage
→ libgallium-26.1.2 (radeonsi)            ← SIGSEGV
```

The root cause is that Flutter's Linux/GTK backend uploads decoded raster images
to GL textures on a cross-context IO thread, and on this box's radeonsi/Mesa 26.1
stack (an AMD RX 6700 XT, navi22) that upload path segfaults inside `libgallium`.
Every MJPEG preview frame is an `Image.memory`, which means a texture upload,
which means another roll of the dice on the broken driver path. It's the same
GL-texture fragility that sank `media_kit` earlier, so it was the hardware driver
all along rather than a software fallback.

The first fix was to force the llvmpipe software rasterizer. The runner
(`linux/runner/main.cc`) can call `setenv("LIBGL_ALWAYS_SOFTWARE","1")` before any
GL init, so even the bare binary is safe. It's proven on this box: `glxinfo` flips
from radeonsi to llvmpipe under the flag, and the app then runs the preview
without crashing.

That introduced a second problem, though: llvmpipe under native Wayland flickers,
because partial-damage repaints redraw stale buffer content on mouse-move and even
at idle. The same software GL presents cleanly through XWayland, so software mode
also defaulted to `GDK_BACKEND=x11`.

In the end the owner's machine ran hardware GL on native Wayland with no flicker
at all, so that became the shipping default and the software path became an opt-in
fallback. The runner now ships hardware GL plus native Wayland by default, and
`PIXY_SOFTWARE=1` (or `tool/run-release.sh software`) switches to the crash-safe
llvmpipe plus XWayland combination for any radeonsi stack where the preview
crashes. The trade-off is explicit: hardware GL is smoother but carries the
preview-crash risk on some drivers, while the software fallback trades a little
sharpness and CPU for guaranteed stability.

One cosmetic loose end: the runner also clears `NO_AT_BRIDGE` and sets
`GTK_A11Y=none`, because setting `NO_AT_BRIDGE=1` actually triggers the harmless
`atk_socket_embed: assertion 'plug_id != NULL'` console line (GTK asks the absent
AT-SPI bridge for a plug id and gets NULL). A separate `Gdk-Message: Unable to
load  from the cursor theme` line is a harmless Flutter/GDK-on-Wayland
empty-cursor-name quirk that prints once at startup and isn't worth chasing.

A few things were hardened along the way as well. These were good hygiene rather
than the segv cause: every UI panel used to `context.watch<DeviceController>()`,
so any `notifyListeners()` rebuilt the whole tree. Now `_notify()` coalesces to
one rebuild per frame, the push handler change-guards and debounces, the hot
widgets use `context.select`, and the HID pump was slowed from 8 ms to 25 ms.

For diagnostics, a breadcrumb logger (`lib/core/diag/crash_log.dart`, writing to
`$XDG_RUNTIME_DIR/pixyctl.log`) plus `FlutterError`, `PlatformDispatcher`, and
isolate error handlers name the failing operation if anything else ever crashes.
`tool/run-release.sh` offers `gpu` (hardware GL) and `x11` (XWayland) toggles.

### Motor / PTZ
| Issue | Finding | Resolution |
|---|---|---|
| Relative move commands (`09 03 01 19`, `09 63 01 19`) never moved the gimbal | Hardware probes showed no motion | Abandoned |
| Absolute (`09 03 01 18`) was accepted but unreliable for non-zero targets | "Recenter" (to 0,0) moved, but arbitrary targets didn't | Not used for arrows |
| `getPosition` (`09 03 01 14`) returns a frozen value | The read-back is stale | Don't poll it; the readout tracks the commanded target instead |
| Velocity (`09 63 01 20`, the knob) is the only primitive that reliably moves | Confirmed every session | Arrows became a velocity pulse: drive at 18°/s in the step direction for `step°/18` seconds, then stop, giving a "move right 10°"-style nudge |
| An arrow press ran the gimbal to the mechanical limit | The crash killed the app mid-pulse before the stop fired, so the gimbal ran away | Fixing the crash removed the runaway; on top of that the pulse is capped, and the `mpv` keepalive's `pdeathsig` closes the stream (which ungates and stops the motor) if the app dies |

### AI features
| Issue | Cause | Fix |
|---|---|---|
| The **Subject tracking** toggle did nothing | There's no standalone tracking command. "Tracking" is a camera mode (`09 01 01 00` payload `01`), and the old `09 04 01 00` framing was bogus | The toggle now drives `setMode(tracking/standard)` |
| The **Gesture** toggle "did nothing" | Two real bugs: the OK status was read from the wrong payload byte, and the response matcher collided with the tracking GET, which differs only in the channel byte | Read the status from payload[1], and have the matchers check the channel. Verified on hardware that the flag toggles |
| Gesture was still "not detected" | The camera only detects gestures while it's actively framing, i.e. with Tracking mode on. Detection is firmware-side; the app only sets the enable flag | The UI now says so |
| Live tracking state didn't reflect a hand-gesture toggle | The UI only knew about the commands it sent | A 400 ms mode poll (`09 01 01 01`, which returns live values) mirrors mode back to the UI, so a gesture-driven toggle shows up in about 0.2 s. Crucially the gesture channel is not polled, because polling `09 04 02 01` in the background broke the camera's gesture detection |

### Image controls
| Issue | Cause | Fix |
|---|---|---|
| The **Auto-Exposure** button and slider didn't work | The code set `auto_exposure` to `8` and tested `value == 8`, but on this device it's a menu of 0 to 3 (auto is 3, Aperture-Priority; manual is 1). The set was silently clamped to 3, so the switch never matched its own read-back and looked dead, the slider gate was also wrong, and the control's `inactive` flag wasn't refreshed | Use the real menu values (auto is the default, manual is 1), gate on `value`, and re-enumerate after the toggle |

### Features added
- A **Picture quality** selector for 4K, 2K, 1080p, and 720p with a 30/60 fps
  toggle (60 fps only at 1080p and 720p), driving the `mpv`/`ffmpeg` stream
  format. Digital zoom is gated to non-4K per the camera's spec.
- The in-app live preview (covered above).
- Live mode/tracking reflection via the mode poll.
- Removed the redundant "Go to position" section.
- A per-user app-menu shortcut installer (`packaging/install-desktop.sh`) so the
  app launches from the desktop menu instead of a terminal. It points at the
  release bundle by absolute path, generates a branded icon, and refreshes the
  desktop/icon caches.

### Not supported / not tested

Some things are deliberately out of scope or simply unverified:

- **Whiteboard mode** isn't supported.
- **Desktop mode** isn't supported.
- **Screen capture** isn't supported. In the capture, EMEET Studio's
  screen-capture action produced no protocol response, so there's nothing to
  drive.
- **Screen recording** isn't supported either, for the same reason: no response
  was observed.
- **Microphone:** the camera's audio modes (Live, Original, Noise-Cancel) are
  implemented and switch fine, but the microphone capture path itself wasn't
  tested, so there's been no recording or mixing validation. Audio mixing in
  EMEET Studio also returned no response in the capture.
- **Firmware update** isn't supported. There's no firmware-update feature; this
  app only controls the camera, it doesn't flash or update its firmware. See the
  firmware trade-off below for why that's intentionally out of scope.

These are documented here so the gap is explicit rather than assumed-working.

---

## 4. Trade-offs

- **Hand-written FFI vs `ffigen`.** Hand-written bindings dodge a toolchain
  dependency conflict. The cost is maintaining about ten function signatures by
  hand, but the surface is tiny and stable, so that's cheap.
- **`ffmpeg` MJPEG pipe plus `Image.memory` vs `media_kit`.** The in-app preview
  decodes JPEG on the CPU and paints with Flutter's normal image path, which needs
  no native plugin and keeps the preview a plain widget. The cost is more CPU than
  a hardware-GL video texture (light at 720p and 1080p, heavier at 4K) and a
  dependency on the `ffmpeg` binary. It doesn't dodge the radeonsi GL-texture crash
  on its own, since the painted frames still become GL textures under hardware GL;
  that's what the software-GL fallback (`PIXY_SOFTWARE=1`) is for.
- **Velocity-pulse arrows vs absolute.** Velocity is the only primitive that moves
  this gimbal, so the arrows use it. Being open-loop (there's no position
  feedback, since the read-back is frozen) means the step distance is approximate,
  and a held velocity carries a theoretical runaway risk. That's mitigated by the
  crash fix, a capped pulse, and the stream-gate (`pdeathsig`) backstop.
- **Mode polling vs push.** The camera does push some events, but not a clean
  tracking-mode change, so a 400 ms poll of `getMode` is used instead. The cost is
  a small steady HID read; the benefit is that the UI reflects gesture-driven
  tracking in about 0.2 s. The gesture channel is deliberately left unpolled,
  because polling it breaks detection.
- **Rendering backend: hardware GL vs the software fallback.** Hardware GL on
  native Wayland is the default because it's smooth and flicker-free, but on the
  radeonsi stack it can crash during the live preview's texture upload. The
  software fallback (`PIXY_SOFTWARE=1`) is rock-solid but pairs llvmpipe with
  XWayland to avoid the Wayland software-GL flicker, at some cost in CPU and
  sharpness. Rather than pick one for everyone, the default is the smooth path and
  the stable path is one environment variable away.
- **Host-side custom gestures, considered and rejected.** We already have the
  video frames, so a host-side hand model (MediaPipe or ONNX) could add arbitrary
  gestures mapped to any command, with no firmware risk. The project owner
  rejected it as not worth the extra CPU and dependencies. (That load would fall
  on the PC, not the camera.)
- **Firmware gesture injection, not feasible.** Gesture recognition runs on the
  camera's own SoC/NPU, and the host only flips an enable flag. Adding a gesture
  there would need the (closed, almost certainly signed) firmware image, the model
  format, and a flashing tool, with a real bricking risk and no SDK. A dead end.
- **Public repository.** The project owner chose to publish, which makes the
  reverse-engineered protocol (`assets/PROTOCOL.md`) and the capture (`assets/log`)
  publicly visible. That's intentional, to document the protocol for others.

---

## 5. Contributors & credits

- **PixyBar** by RoseWaveStudio (MIT),
  <https://github.com/RoseWaveStudio/PixyBar>, did the original PIXY HID protocol
  reverse-engineering this project is built on. The base command set came from
  PixyBar; this project extended, corrected, and verified it on Linux.
- **mfahmitj** (GitHub [@absolute-zer013](https://github.com/absolute-zer013))
  owns the project and its direction, provided the hardware (the EMEET PIXY and an
  AMD/Wayland/Linux test rig), ran all the USB packet captures against EMEET
  Studio, did every round of on-device testing and verification, and made the
  product decisions and trade-off calls.
- **Claude (Opus 4.8)** handled the implementation, the protocol decoding from the
  captures, the FFI/transport layer, the crash diagnosis, and this document, and
  co-authored the commits.

---

## 6. Key references in this repo

- `assets/PROTOCOL.md`, the decoded command reference.
- `assets/log`, the labelled pixysniff capture (the ground truth).
- `assets/pixysniff.py`, the USB sniffer.
- `lib/core/protocol/`, frame encode/decode plus typed command builders (unit-tested
  in `test/protocol_test.dart`).
- `lib/core/transport/`, hidapi FFI plus the HID read/write transport.
- `lib/core/stream/preview_controller.dart`, the mpv keepalive plus ffmpeg MJPEG
  preview.
- `lib/state/device_controller.dart`, device state, intent methods, and polling.
- `tool/`, throwaway hardware probes, plus the `run-release.sh` launcher.

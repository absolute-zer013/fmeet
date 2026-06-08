# PixyControl

Native **Linux** control app for the **EMEET PIXY** AI PTZ webcam (`328f:00c0`),
replacing the Windows/macOS-only *EMEET Studio*. Built with Flutter (Linux
desktop), driving the camera through its reverse-engineered HID protocol plus
standard V4L2/UVC controls — with the **live preview rendered inside the app**.

> Built on the protocol groundwork of **PixyBar** (RoseWaveStudio, MIT) —
> <https://github.com/RoseWaveStudio/PixyBar> — extended and verified on Linux.
> For the full story (how the protocol was captured, every issue and fix, and the
> trade-offs), see **[DEVLOG.md](DEVLOG.md)**.

## Features

- **PTZ** — velocity joystick (knob), arrow-key nudges (configurable step),
  recenter, and presets.
- **Camera modes** — Standard / Tracking / Privacy, with **live UI sync** (the
  UI reflects mode/tracking changes the camera makes on its own, e.g. via a hand
  gesture).
- **Subject tracking** and **gesture control** toggles.
- **Image controls** (V4L2/UVC) — brightness, contrast, saturation, tone,
  sharpness, ISO/gain, anti-flicker, white balance, exposure (auto/manual),
  focus (auto/lock), and digital zoom.
- **Picture quality** — 4K / 2K / 1080p / 720p with a **30/60 fps** toggle
  (60 fps at 1080p/720p).
- **Flip / auto-rotate**, **audio modes** (Live / Original / Noise-Cancel),
  **privacy auto-timer**.
- **In-app live preview** — the camera's native MJPG frames are piped in via
  `ffmpeg` and painted by Flutter (no external window, no GL).

## Requirements

- Flutter (stable). This repo pins **3.35.0** via [FVM](https://fvm.app/)
  (`.fvmrc`); plain `flutter` works too.
- System packages (Arch / CachyOS):
  ```bash
  sudo pacman -S hidapi mpv ffmpeg v4l-utils
  ```
  - `hidapi` → HID control transport (FFI to `libhidapi-hidraw.so`)
  - `mpv` → holds the V4L2 stream open in the background (ungates control)
  - `ffmpeg` → pipes the camera's MJPG frames for the in-app live preview
  - `v4l-utils` → `v4l2-ctl` for image/exposure/focus/zoom controls

## Build & run

```bash
# with FVM (pinned 3.35.0)
fvm flutter pub get
fvm flutter build linux --release

# run it
./build/linux/x64/release/bundle/fmeet
# or the helper:
tool/run-release.sh           # software GL (default, crash-safe)
tool/run-release.sh gpu       # opt into hardware GL (PIXY_GPU=1)
tool/run-release.sh x11       # force XWayland
```

> The app forces the **llvmpipe software rasterizer** by default. Flutter's
> hardware-GL texture upload SIGSEGVs inside the radeonsi/Mesa driver on some AMD
> stacks (see DEVLOG). If your GPU/driver is stable, set `PIXY_GPU=1` (or
> `tool/run-release.sh gpu`) for hardware GL.

For development: `fvm flutter run -d linux`. Plain `flutter` works in place of
`fvm flutter`.

> Use the **release** build for daily use — the debug (JIT) build is less stable
> on some GTK/GL stacks.

## Permissions (udev) — required

HID writes need access to the PIXY's `hidraw` node. Easiest: open the app's
**System** panel and click the one-click installer (`pkexec`). Or install the
shipped rule manually:

```bash
sudo cp packaging/70-emeet-pixy.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=hidraw
# then UNPLUG and REPLUG the camera
```

> The **`70-` prefix matters**: `uaccess` is applied by `73-seat-late.rules`, so
> the rule must sort *before* 73.

## How to use

1. **Plug in the PIXY** and launch the app. It auto-discovers the camera by its
   USB id (handles the `/dev/hidrawN` number changing between replugs).
2. **Wait for the badge to say _Connected_ / _Controls ready_.** The camera
   **ignores motor and mode commands unless a video stream is open**, so on
   connect the app starts a hidden stream holder to ungate control. If the badge
   shows *needs permission*, install the udev rule (above) and reconnect.
3. **Move the camera** — drag the joystick knob (continuous), or tap the arrows
   (each press jogs by the configured step; change it with the Step selector).
   Recenter returns to home.
4. **Live preview** — click **Show preview** in the right pane to render live
   video inside the app; **Hide** stops it. If another app (Zoom/OBS) is already
   using the camera, controls still work but the in-app preview is unavailable
   (single UVC stream).
5. **Picture quality** — pick 4K/2K/1080p/720p and 30/60 fps in the Image panel;
   the stream relaunches at that format. Digital zoom only works at
   2K/1080p/720p (not 4K).
6. **Tracking & gesture** — turn **Tracking** on to let the camera auto-frame.
   **Gesture detection only works while Tracking is on** (the camera only acts on
   gestures while it is actively framing); the toggle just enables the feature.
   When the camera changes tracking on its own (e.g. you gesture), the UI updates
   within ~1.5 s.
7. **Image / exposure / focus** — Image panel. For manual exposure, switch
   **Auto exposure** off, then the exposure-time slider becomes adjustable.

## Not supported / not tested

- **Whiteboard mode**, **desktop mode**, **screen capture**, **screen
  recording** — not supported (EMEET Studio returned no protocol response for
  capture/record).
- **Firmware update** — not supported; this is a control app, it does not flash
  firmware.
- **Microphone** — audio *modes* switch fine, but the mic capture path itself was
  not tested.

## Packaging (AppImage)

```bash
packaging/build-appimage.sh
```
Builds a release bundle, assembles an `AppDir` (bundling `libhidapi` only), and
runs `appimagetool` if present. `mpv`, `ffmpeg`, and `v4l2-ctl` are **runtime
dependencies** (not bundled) and must be installed on the target. The udev rule
also has to be installed once on the target machine.

## Architecture

Layered, with a pure-Dart, hardware-free protocol core that is unit-tested:

```
lib/core/protocol/   frames.dart · commands.dart · enums.dart   (pure Dart, tested)
lib/core/transport/  hidapi FFI bindings + HID transport (open/write/read loop)
lib/core/v4l2/       v4l2-ctl wrapper (enumerate/get/set image controls)
lib/core/stream/     mpv keepalive + ffmpeg MJPEG in-app preview + stream gating
lib/core/diag/       crash breadcrumb logger
lib/services/        device discovery · PixyDevice high-level API
lib/state/           DeviceController + SettingsController (Provider)
lib/ui/              home shell · panels · widgets
packaging/           udev rule · .desktop · build-appimage.sh
tool/                hardware probes · run-release.sh
```

See `assets/PROTOCOL.md` for the reverse-engineered command reference and
**[DEVLOG.md](DEVLOG.md)** for the development/RE write-up.

## Tests

The protocol layer is covered by unit tests asserting exact wire bytes:

```bash
fvm flutter test
```

## Credits

- **PixyBar** (RoseWaveStudio, MIT) — <https://github.com/RoseWaveStudio/PixyBar>
  — original PIXY HID protocol reverse-engineering this builds on.
- Extended, corrected, and verified on Linux by
  [@absolute-zer013](https://github.com/absolute-zer013). MIT licensed.

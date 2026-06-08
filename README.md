# PixyControl

A native **Linux** control app for the **EMEET PIXY** AI PTZ webcam (`328f:00c0`),
filling in for *EMEET Studio*, which only ships on Windows and macOS. It's built
with Flutter (Linux desktop) and drives the camera through its reverse-engineered
HID protocol alongside the standard V4L2/UVC controls, with the **live preview
rendered right inside the app**.

> The protocol groundwork comes from **PixyBar** (RoseWaveStudio, MIT) at
> <https://github.com/RoseWaveStudio/PixyBar>, extended and verified here on Linux.
> If you want the full story (how the protocol was captured, every issue and fix,
> and the trade-offs behind each decision), read **[DEVLOG.md](DEVLOG.md)**.

## Features

- **PTZ:** a velocity joystick (the knob), arrow-key nudges with a configurable
  step, recenter, and presets.
- **Camera modes:** Standard, Tracking, and Privacy. The UI stays in sync, so
  when the camera changes mode on its own (say you trigger it with a hand
  gesture), the app reflects it.
- **Subject tracking** and **gesture control** toggles.
- **Image controls** over V4L2/UVC: brightness, contrast, saturation, tone,
  sharpness, ISO/gain, anti-flicker, white balance, exposure (auto or manual),
  focus (auto or lock), and digital zoom.
- **Picture quality:** 4K, 2K, 1080p, or 720p, with a 30/60 fps toggle (60 fps is
  available at 1080p and 720p).
- **Flip and auto-rotate**, **audio modes** (Live, Original, Noise-Cancel), and a
  **privacy auto-timer**.
- **In-app live preview:** the camera's native MJPG frames are piped in through
  `ffmpeg` and painted by Flutter, with no external window and no GL.

## Requirements

- Flutter (stable). This repo pins **3.35.0** via [FVM](https://fvm.app/)
  (`.fvmrc`), but plain `flutter` works too.
- System packages (Arch / CachyOS):
  ```bash
  sudo pacman -S hidapi mpv ffmpeg v4l-utils
  ```
  - `hidapi` is the HID control transport (FFI to `libhidapi-hidraw.so`).
  - `mpv` holds the V4L2 stream open in the background so control ungates.
  - `ffmpeg` pipes the camera's MJPG frames for the in-app live preview.
  - `v4l-utils` provides `v4l2-ctl` for the image, exposure, focus, and zoom
    controls.

## Build & run

```bash
# with FVM (pinned 3.35.0)
fvm flutter pub get
fvm flutter build linux --release

# run it
./build/linux/x64/release/bundle/fmeet
# or the helper:
tool/run-release.sh            # hardware GL, native Wayland (default)
tool/run-release.sh software   # software GL + XWayland (PIXY_SOFTWARE=1), crash-safe
```

> The app runs on **hardware GL / native Wayland** by default (smooth, no
> flicker). On some radeonsi/Mesa stacks Flutter's GL texture upload SIGSEGVs
> during the live preview (the DEVLOG has the details). If that happens, set
> `PIXY_SOFTWARE=1` (or run `tool/run-release.sh software`) to fall back to the
> llvmpipe software rasterizer plus XWayland, which is crash-safe.

To launch it from the desktop app menu instead of a terminal, install a per-user
shortcut (it points at the release bundle in this checkout and ships a generated
icon):

```bash
packaging/install-desktop.sh              # install / refresh
packaging/install-desktop.sh --uninstall  # remove
```

Then search for *PixyControl* in your app menu. Re-run it if you move the project.

For development, use `fvm flutter run -d linux`. Plain `flutter` works in place of
`fvm flutter`.

> Use the **release** build day to day. The debug (JIT) build is less stable on
> some GTK/GL stacks.

## Permissions (udev), required

HID writes need access to the PIXY's `hidraw` node. The easy path is to open the
app's **System** panel and click the one-click installer (it uses `pkexec`).
Otherwise, install the shipped rule by hand:

```bash
sudo cp packaging/70-emeet-pixy.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=hidraw
# then UNPLUG and REPLUG the camera
```

> The `70-` prefix matters. `uaccess` is applied by `73-seat-late.rules`, so this
> rule has to sort before 73.

## How to use

1. **Plug in the PIXY** and launch the app. It auto-discovers the camera by its
   USB id and handles the `/dev/hidrawN` number changing between replugs.
2. **Wait for the badge to read _Connected_ or _Controls ready_.** The camera
   ignores motor and mode commands unless a video stream is open, so on connect
   the app quietly starts a stream holder to ungate control. If the badge says
   *needs permission*, install the udev rule above and reconnect.
3. **Move the camera.** Drag the joystick knob for continuous motion, or tap the
   arrows to jog by the configured step (change it with the Step selector).
   Recenter returns to home.
4. **Live preview.** Click **Show preview** in the right pane to render live video
   inside the app, and **Hide** to stop it. If another app such as Zoom or OBS is
   already using the camera, the controls still work but the in-app preview isn't
   available, since the camera only exposes a single UVC stream.
5. **Picture quality.** Pick 4K, 2K, 1080p, or 720p and 30 or 60 fps in the Image
   panel, and the stream relaunches at that format. Digital zoom works at 2K,
   1080p, and 720p, but not at 4K.
6. **Tracking and gesture.** Turn **Tracking** on to let the camera auto-frame.
   Gesture detection only works while Tracking is on, because the camera only acts
   on gestures while it's actively framing; the toggle just enables the feature.
   When the camera changes tracking on its own (for example after a gesture), the
   UI catches up in about a fifth of a second.
7. **Image, exposure, and focus** live in the Image panel. For manual exposure,
   switch **Auto exposure** off and the exposure-time slider becomes adjustable.

## Not supported / not tested

- **Whiteboard mode**, **desktop mode**, **screen capture**, and **screen
  recording** aren't supported. EMEET Studio returned no protocol response for the
  capture and record actions, so there's nothing to drive.
- **Firmware update** isn't supported. This is a control app; it doesn't flash
  firmware.
- **Microphone:** the audio *modes* switch fine, but the mic capture path itself
  wasn't tested.

## Packaging (AppImage)

```bash
packaging/build-appimage.sh
```

This builds a release bundle, assembles an `AppDir` (bundling `libhidapi` only),
and runs `appimagetool` if it's present. `mpv`, `ffmpeg`, and `v4l2-ctl` are
runtime dependencies rather than bundled, so they need to be installed on the
target, and the udev rule has to be installed once there as well.

## Architecture

The app is layered, with a pure-Dart, hardware-free protocol core that's
unit-tested:

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
**[DEVLOG.md](DEVLOG.md)** for the development and RE write-up.

## Tests

The protocol layer is covered by unit tests that assert the exact wire bytes:

```bash
fvm flutter test
```

## Credits

- **PixyBar** by RoseWaveStudio (MIT),
  <https://github.com/RoseWaveStudio/PixyBar>, did the original PIXY HID protocol
  reverse-engineering this builds on.
- Extended, corrected, and verified on Linux by
  [@absolute-zer013](https://github.com/absolute-zer013). MIT licensed.

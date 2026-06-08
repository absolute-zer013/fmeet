# PixyControl

Native **Linux** control app for the **EMEET PIXY** AI PTZ webcam (`328f:00c0`),
replacing the Windows/macOS-only *EMEET Studio*. Built with Flutter (Linux
desktop), driving the camera through its reverse-engineered HID protocol plus
standard V4L2/UVC controls.

Full control: PTZ (joystick / arrows / go-to / presets), camera modes, subject
tracking, gesture control, focus-metering, flip / auto-rotate, audio modes,
privacy auto-timer, and all image controls (brightness, contrast, saturation,
tone, sharpness, ISO, anti-flicker, white balance, exposure, focus, zoom) — with
a live preview pane.

## Requirements

- Flutter (stable). This repo pins **3.35.0** via [FVM](https://fvm.app/)
  (`.fvmrc`); plain `flutter` works too.
- System packages (Arch / CachyOS):
  ```bash
  sudo pacman -S hidapi mpv v4l-utils
  ```
  - `hidapi` → HID control transport (FFI to `libhidapi-hidraw.so`)
  - `mpv` → the `mpv` binary is run as a subprocess to hold the V4L2 stream
    open (ungates control) and to show the live preview window
  - `v4l-utils` → `v4l2-ctl` for image/zoom/focus controls

## Build & run

```bash
# with FVM
fvm flutter pub get
fvm flutter run -d linux

# or plain flutter
flutter pub get
flutter run -d linux
```

Release build:
```bash
flutter build linux --release
# bundle at build/linux/x64/release/bundle/
```

## Permissions (udev) — required

HID writes need access to the PIXY's `hidraw` node. Install the shipped rule:

```bash
sudo cp packaging/70-emeet-pixy.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=hidraw
# then UNPLUG and REPLUG the camera
```

> The **`70-` prefix matters**: `uaccess` is applied by `73-seat-late.rules`, so
> the file must sort *before* 73. The app's **System** panel has a one-click
> installer (uses `pkexec`) and a "Copy rule" button.

## Stream gating (important behavior)

The camera **ignores motor and mode commands unless a video stream is open.**
On connect, PixyControl starts a hidden `mpv --vo=null` subprocess that holds the
V4L2 stream open (no rendering) — this ungates control. Live video is shown on
demand in a **separate hardware-accelerated `mpv` window** via the *Show preview*
button (the embedded-in-Flutter video path is unstable on some GL stacks, so it
was intentionally dropped in favour of a subprocess). Cases the app handles:

- **Streaming** → keepalive holds the stream, controls enabled; *Show preview*
  opens the live window.
- **Camera already in use** (OBS/Zoom/etc.) → badge shows *“Controls ready”*;
  **controls stay enabled** because the other app's stream already ungated the
  device.
- **Device absent / no permission** → controls disabled; badge explains why.

So if PTZ seems dead, make sure the keepalive (or another app's stream) is
running — i.e. the badge is Connected / Controls ready.

## Packaging (AppImage)

```bash
packaging/build-appimage.sh
```
Builds a release bundle, assembles an `AppDir` (bundling `libhidapi` + `libmpv`),
and runs `appimagetool` if present. The udev rule still has to be installed once
on the target machine (see above).

## Architecture

Layered, with a pure-Dart, hardware-free protocol core that is unit-tested:

```
lib/core/protocol/   frames.dart · commands.dart · enums.dart   (pure Dart, tested)
lib/core/transport/  hidapi FFI bindings + HID transport (open/write/read loop)
lib/core/v4l2/       v4l2-ctl wrapper (enumerate/get/set image controls)
lib/core/stream/     media_kit preview + EBUSY/stream-gating detection
lib/services/        device discovery · PixyDevice high-level API
lib/state/           DeviceController + SettingsController (Provider)
lib/ui/              home shell · panels · widgets
packaging/           udev rule · .desktop · build-appimage.sh
```

See `assets/PROTOCOL.md` for the full reverse-engineered command reference and
`assets/PixyControl_Flutter_Spec.md` for the build spec.

## Tests

The protocol layer is covered by unit tests asserting exact wire bytes against
`PROTOCOL.md`:

```bash
flutter test test/protocol_test.dart
```

## Credits

Protocol built on **PixyBar** (RoseWaveStudio, MIT) and extended through USB
reverse engineering. MIT licensed.

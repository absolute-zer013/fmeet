# PixyControl — Flutter Linux App Build Specification

> A native Linux control application for the **EMEET PIXY** AI PTZ webcam, replacing
> the Windows/macOS-only "EMEET Studio". Spec-first document intended to be handed
> to Claude Code for implementation. Pair this with `PROTOCOL.md` (the full
> reverse-engineered command reference) and `pixyctl.py` (working reference port).

---

## 1. Overview & goals

EMEET ships no Linux software for the PIXY. Through USB reverse engineering the
full control protocol is now known (see `PROTOCOL.md`). This app exposes it as a
clean desktop GUI on Linux.

**Goals**
- Full device control on Linux: PTZ, presets, modes, tracking, gesture, audio
  modes, image quality, focus, zoom, privacy timer.
- Live video preview (which also satisfies the camera's "stream must be open"
  requirement for control to work — see §4).
- Reliable connect / disconnect / reconnect handling.
- Clean, dark-first Material 3 UI. Functional, not flashy.

**Non-goals (deliberately out of scope)**
- Recording, screen capture, filters, whiteboard/desktop mode, audio mixing, AI
  scriptwriting — these are Studio *software* features that send **no device
  traffic** and are not camera capabilities. Do not implement.
- Firmware update (never reverse-engineered; risk of bricking).
- Multi-camera orchestration (single PIXY first; architecture should not *prevent*
  multi-device later, but don't build it now).
- Windows/macOS builds.

---

## 2. Tech stack

| Concern | Choice | Notes |
|---|---|---|
| Framework | Flutter (stable), **Linux desktop target** | |
| State management | **Provider** (`ChangeNotifier`) | matches existing skillset |
| HID transport | **Dart FFI → hidapi** (`libhidapi-hidraw.so`) | bindings via `ffigen`; Arch pkg `hidapi` |
| Image/zoom/focus controls | **v4l2** via `v4l2-ctl` subprocess wrapper (MVP) | libv4l FFI is a later optimization |
| Preview + stream keepalive | **media_kit** (`media_kit`, `media_kit_video`) | libmpv-based; opens `/dev/videoN`, renders to a Flutter texture, holds the stream open |
| Persistence | `shared_preferences` (Linux-supported) | preset labels, settings, last device |
| Packaging | AppImage (primary) + AUR `PKGBUILD` (stretch) | ship udev rule + `.desktop` |
| Tests | `flutter_test` for the pure-Dart protocol layer | |

**Key dependency rationale:** `media_kit` solves two problems with one component —
it provides the preview pane *and*, by holding the V4L2 stream open, ungates the
HID control channel (the camera ignores motor/mode commands unless a stream is
active; see §4.1). No separate keepalive hack needed in the normal case.

---

## 3. Architecture

Layered, with a pure-Dart protocol core that is unit-testable without hardware.

```
lib/
  main.dart                       app entry, Provider wiring
  app.dart                        MaterialApp, theme, routing/shell

  core/
    protocol/
      frames.dart                 build/parse 32-byte HID frames
      commands.dart               typed command builders (one per PROTOCOL.md entry)
      enums.dart                  CameraMode, TrackingMode, AudioMode, FocusMetering, etc.
    transport/
      hidapi_bindings.dart        ffigen-generated hidapi FFI bindings
      hid_transport.dart          open/close/write/read, async read loop -> event stream
    v4l2/
      v4l2_controls.dart          wrapper over `v4l2-ctl`: list, get, set, ranges
    stream/
      preview_controller.dart     media_kit player lifecycle; EBUSY detection (§4.2)

  services/
    device_discovery.dart         find PIXY hidraw node + matching /dev/videoN
    pixy_device.dart              HIGH-LEVEL API: setMode(), drive(), gotoPreset(),
                                  savePreset(), setAudioMode(), setGesture(),
                                  setFocusMetering(), setFlip(), setPrivacyTimer(),
                                  positionStream(), image controls (delegates to v4l2)

  state/
    device_controller.dart        ChangeNotifier: connection state + live device state
    settings_controller.dart      ChangeNotifier: persisted prefs

  ui/
    home_shell.dart               nav rail / tabs + preview pane + connection badge
    panels/
      control_panel.dart          PTZ joystick, arrows, recenter, go-to, presets, zoom, mode
      image_panel.dart            brightness/contrast/saturation/tone/sharpness/ISO/
                                  anti-flicker/WB/exposure/focus
      ai_panel.dart               tracking on/off + mode, gesture, focus-metering, flip, auto-rotate
      audio_panel.dart            audio mode selector
      system_panel.dart           privacy timer, serial, firmware/build, about, udev helper
      debug_panel.dart            live raw-frame log (reuse sniffer decode) + raw send box
    widgets/
      ptz_joystick.dart           draggable knob -> velocity stream (§5.1)
      preset_bar.dart             Initial / No.1-3 buttons + save + local label edit
      labeled_slider.dart         slider with min/max/value, debounced apply
      connection_badge.dart       connected / disconnected / claimed-by-other / no-perms
      preview_view.dart           media_kit video widget + overlay states

  theme/
    app_theme.dart                dark-first Material 3 tokens

linux/                            CMake; link/bundle libhidapi
native/ffigen.yaml                ffigen config for hidapi.h
packaging/
  70-emeet-pixy.rules             udev rule (NOTE: 70- prefix, see §4.3)
  pixy-control.desktop
  build-appimage.sh
test/
  protocol_test.dart              frame encode/decode + command builder tests
pubspec.yaml
README.md
```

**Data flow:** UI → `DeviceController` (Provider) → `PixyDevice` (high-level) →
`HidTransport` (FFI) and/or `V4l2Controls` (subprocess). Async device pushes and
polled position flow back up via streams the controller exposes.

---

## 4. Critical behaviors (hard-won; implement carefully)

### 4.1 Stream gating
The camera **ignores motor and mode commands unless a video stream is open.**
With no stream, `GET mode` returns `startup` (3); once a stream is active it flips
to `normal` (0) and PTZ works. Therefore:
- On connect, `PreviewController` opens the V4L2 device (preview) immediately.
- Control actions should be enabled only once a stream is confirmed active; if
  not, surface a clear hint ("Start preview to enable PTZ control").

### 4.2 Shared-stream awareness (important real-world case)
A UVC camera typically allows only one streamer. If the PIXY is already in use by
OBS/Zoom/etc., opening it for preview will fail with EBUSY — **but control still
works**, because that other app's stream already ungates the device. So:
- Try to open preview. On success → show video + control enabled.
- On EBUSY → show "Preview unavailable (camera in use by another app). Controls
  available." and **keep controls enabled** (do not block PTZ).
- Only if the device is truly absent → disable controls.

### 4.3 Permissions / udev
HID writes need access to the PIXY's `hidraw` node. Ship `70-emeet-pixy.rules`:
```
KERNEL=="hidraw*", ATTRS{idVendor}=="328f", ATTRS{idProduct}=="00c0", MODE="0660", TAG+="uaccess"
```
**The `70-` prefix matters:** `uaccess` is processed by `73-seat-late.rules`, so
the file must sort *before* 73. First-run check: if the hidraw node lacks an ACL
for the current user, the System panel shows a one-click helper that copies the
rule to `/etc/udev/rules.d/`, reloads udev, and prompts a replug.

### 4.4 Range clamping & wedge recovery
Absolute targets beyond mechanical limits return status `0x40` and can leave the
motor controller unresponsive until USB power-cycle. Therefore:
- Clamp pan/tilt in the high-level API to safe limits (start conservative,
  e.g. pan ±150°, tilt ±30°; expose as constants and refine after measuring).
- If a command returns `0x40`, surface a non-blocking warning; if subsequent
  motor commands keep failing, show a "camera may need to be unplugged/replugged"
  recovery notice.

### 4.5 Async pushes
The camera emits unsolicited frames: `09 02 00 02` (privacy state change) and
`09 63 02 01` (auto-rotate event). The read loop must distinguish solicited
responses from async pushes and route pushes to the controller so UI reflects
external state changes (e.g. user covers the lens / flips the camera).

### 4.6 Zoom resolution dependency
Digital zoom (`0x0b` CT, 100–150) only takes effect at 2K/1080p/720p @30fps.
If preview is at a lower mode, disable/grey the zoom slider with a tooltip.

---

## 5. Protocol integration (see PROTOCOL.md for full detail)

All HID frames are 32 bytes: `09 | group | channel | sub | 00 | len_lo len_hi |
chunk | payload…`. Status `0x20` OK / `0x40` reject. Floats LE f32 in degrees.

`commands.dart` should expose typed builders. Minimum set:

**Motor / PTZ (group 0x03, channel 0x01)**
- `motorRelative(axis, deltaDeg)` → `09 03 01 19`, payload `u8 axis + f32` (axis 1 pan, 2 tilt)
- `motorAbsolute(axis, deg)` → `09 03 01 18`, payload `u8 axis + f32`
- `driveVelocity(panVel, tiltVel)` → header `09 63 01 20`, payload `f32 pan + f32 tilt + 0×4` (send `0x63` verbatim; this is the knob channel; zero vector = stop)
- `getPosition()` → `09 03 01 14` → resp `u8 + f32 pan + f32 tilt`
- `presetRead(slot)` / `presetWrite(slot, pan, tilt)` → `09 03 01 16` (confirm save-vs-recall framing — see §9)
- `recenter()` → absolute pan 0 then tilt 0 (20 ms apart), as pixyctl does

**Mode (group 0x01)**
- `setMode(mode)` → `09 01 01 00`, u8 (0 standard, 1 tracking, 2 privacy)
- `getMode()` → `09 01 01 01`
- `getSerial()` → `09 01 00 03` (ASCII)

**Tracking + AI (group 0x04)**
- `setFocusMetering(mode)` → send `09 04 00 01` and `09 04 00 03` both `u8 mode + f32(0)` (0 central, 1 face, 2 selected-area). **Only valid when focus is in Lock (AF off)** — gate in UI.
- `getFocusMetering()` → `09 04 00 02`
- `setGesture(on)` → `09 04 02 00`, payload `02 + u8`
- `getGesture()` → `09 04 02 01`, payload `02`
- `setTracking(mode)` → `09 04 01 00`, `u8 + 5×f32` (use 0.5,0.5,1.0,0,0 default)
- `getTracking()` → `09 04 01 01`

**Feature toggles (group 0x04, channel 0x00, sub 0x07 get / 0x08 set)**
- `setFeature(id, on)` → `09 04 00 08`, `u8 id + u8 on`
- `getFeature(id)` → `09 04 00 07`, `u8 id`
- IDs: `0x01` flip-vertical, `0x02` flip-horizontal, `0x04` auto-rotate-upside-down

**Audio mode (group 0x05, channel 0x00)**
- `setAudioMode(m)` → `09 05 00 03`, u8 (1 Live, 2 Noise-Canceling, 3 Original)
- `getAudioMode()` → `09 05 00 04`

**Privacy auto-timer (group 0x02, channel 0x01)**
- `setPrivacyTimeout(sec)` → `09 02 01 00`, u32 (10 / 60 / 900 / 0=Never)
- `getPrivacyTimeout()` → `09 02 01 01`

**Image / exposure / focus / WB / zoom — via v4l2, NOT HID.** `V4l2Controls`
wraps `v4l2-ctl -d <node>`:
- enumerate with `--list-ctrls-menus` → parse name, min, max, default, current
- set with `--set-ctrl=<name>=<value>`
- Map UI sliders to standard control names (brightness, contrast, saturation,
  sharpness, gain, hue, white_balance_temperature, white_balance_automatic,
  power_line_frequency, auto_exposure, exposure_time_absolute, focus_absolute,
  focus_automatic_continuous, zoom_absolute). Confirm exact names at runtime from
  the enumeration (don't hard-code; PROTOCOL.md gives selector↔meaning).

---

## 6. UI specification

Dark-first Material 3. Left nav rail (or top tabs) selects a panel; a persistent
right-side **preview pane** with a connection badge sits across all panels.

**Home shell**
- Connection badge states: Connected · Disconnected · Camera in use (preview off,
  controls on) · Needs permission (udev helper).
- Preview pane: live video, or overlay text for the non-streaming states.

**Control panel**
- `PtzJoystick`: circular drag knob → continuous `driveVelocity`; release → stop.
  Magnitude of drag maps to velocity (cap ~±30°/s).
- Arrow buttons (↑↓←→): single `motorRelative` step; step size from settings
  (default 5°, options 1/3/5/10).
- Recenter button.
- Go-to: numeric pan/tilt fields → `motorAbsolute` pair (clamped).
- Live position readout (poll `getPosition` ~5 Hz while panel visible).
- `PresetBar`: Initial / No.1 / No.2 / No.3 recall; "Save current to slot"; local
  editable labels (persisted).
- Zoom slider (100–150), gated by resolution (§4.6).
- Camera mode segmented control: Standard / Tracking / Privacy.

**Image panel** (all v4l2)
- Sliders (debounced): Brightness, Contrast, Saturation, Tone, Sharpness, ISO/Gain.
- Anti-flicker: 50 Hz / 60 Hz toggle.
- White balance: AWB lock toggle + temperature slider (enabled when AWB off).
- Exposure: Auto/Manual toggle + EV/exposure-time slider (manual only).
- Focus: AF / Lock toggle + focus slider (Lock only).
- "Restore defaults" per section (use v4l2 control defaults).

**AI panel**
- Tracking: on/off + mode (face / half-body / full-body); optional live subject-
  position indicator (small dot from `getTracking` floats).
- Gesture control toggle.
- Focus-metering: Central / Face / Selected-area (disabled unless focus = Lock;
  show why when disabled).
- Flip vertical / horizontal toggles.
- Auto-rotate when upside down toggle.

**Audio panel**
- Audio mode: Live / Noise-Canceling / Original (segmented).

**System panel**
- Auto-privacy timer: 10s / 1min / 15min / Never.
- Device info: serial (`getSerial`), firmware/build (group 0x02 value — label as
  "build" until confirmed), model.
- Permissions helper (udev installer, §4.3).
- About / credits (link PixyBar + this project; MIT).

**Debug panel** (developer aid, on-brand)
- Live decoded frame log (reuse the `pixysniff` decode tables).
- Raw send box: hex header + payload → `HidTransport.write`, show response.

---

## 7. State models (sketch)

```dart
enum CameraMode { standard, tracking, privacy, startup }
enum TrackingMode { off, face, halfBody, fullBody }
enum AudioMode { live, noiseCanceling, original }
enum FocusMetering { central, face, selectedArea }
enum ConnectionState { disconnected, connected, cameraInUse, needsPermission }

class DeviceState {
  ConnectionState connection;
  CameraMode mode;
  TrackingMode tracking;
  bool gesture, flipV, flipH, autoRotate;
  FocusMetering focusMetering;
  AudioMode audioMode;
  int privacyTimeoutSec;       // 0 = never
  double pan, tilt;            // live, from getPosition
  String? serial, build;
  Map<int,String> presetLabels; // slot -> label (persisted)
  // v4l2 image controls cached as name -> (min,max,value) map
}
```

`DeviceController extends ChangeNotifier` owns a `DeviceState`, a `PixyDevice`,
and the `PreviewController`; exposes intent methods that call the device and then
`notifyListeners()`. Position polling and async pushes update state and notify.

---

## 8. Build phases (implementation order for Claude Code)

Each phase should compile, run, and be independently verifiable.

**Phase 0 — Skeleton**
- Flutter Linux project, Provider wiring, dark M3 theme, empty panels behind a nav
  shell, connection badge stub. Acceptance: app launches on CachyOS.

**Phase 1 — Protocol core (pure Dart, TDD)**
- `frames.dart`, `commands.dart`, `enums.dart` + `protocol_test.dart`.
- Acceptance: unit tests cover frame encode/decode and every command builder
  against the byte sequences in PROTOCOL.md (e.g. `motorRelative(1,10)` ==
  `09 03 01 19 00 05 00 05 01 00 00 20 41 …`).

**Phase 2 — HID transport (FFI)**
- ffigen bindings for hidapi; open by VID/PID (fallback: open by hidraw path from
  discovery); write; non-blocking read loop in an isolate → event stream.
- Acceptance: `getMode()`/`getSerial()` return correct values from a real PIXY;
  `motorRelative` moves the gimbal (with a stream open).

**Phase 3 — Preview + keepalive**
- `media_kit` preview of `/dev/videoN`; EBUSY handling (§4.2); discovery ties
  hidraw node to the right video node.
- Acceptance: preview renders; PTZ works while preview is up; covering the case
  where OBS holds the stream keeps controls enabled.

**Phase 4 — Control panel**
- Joystick (velocity), arrows (relative), recenter, go-to, live position, presets,
  zoom (gated), mode. Acceptance: full PTZ + presets usable by mouse.

**Phase 5 — v4l2 image controls**
- `v4l2_controls.dart` wrapper + Image panel sliders/toggles with debounce and
  enable/disable logic (AWB, AE, AF gating). Acceptance: sliders change the live
  preview.

**Phase 6 — AI / Audio / System panels**
- Tracking, gesture, focus-metering (AF-lock gated), flip, auto-rotate; audio
  mode; privacy timer; device info; udev permissions helper.
- Acceptance: each toggle reflects on the device and survives reconnection.

**Phase 7 — Persistence, polish, debug panel**
- `shared_preferences` for preset labels / step size / last device / theme;
  debug frame log + raw send. Reconnect/hotplug handling. Acceptance: settings
  persist; unplug/replug recovers cleanly.

**Phase 8 — Packaging**
- AppImage build script, `.desktop`, bundle/declare libhidapi + mpv runtime deps,
  install udev rule. Stretch: AUR `PKGBUILD`. Acceptance: AppImage runs on a clean
  CachyOS install after the udev rule + replug.

---

## 9. Open items to resolve during build (cheap captures)
- **Preset save vs recall** exact framing on `09 03 01 16`: do one isolated save
  and one recall in Studio under `pixysniff`, diff. Until confirmed, implement
  read (zero-length) and write (with record) per the working hypothesis and verify
  on hardware.
- **`09 03 01 00`** semantics (axis-limit vs alternate absolute).
- **Pan/tilt mechanical limits**: binary-search with 1° steps near edges; bake the
  measured values into the clamp constants (§4.4).
- **Firmware/build field** (group 0x02 value `900`): confirm meaning for the
  System panel label.

---

## 10. Acceptance (definition of done)
- Connect to a PIXY on CachyOS, see preview, drive PTZ (joystick + arrows +
  presets), switch modes, toggle tracking/gesture/flip/focus-metering, set audio
  mode and privacy timer, adjust all image controls — all reflected on the device.
- Graceful handling of: no device, device-in-use, missing permissions, out-of-
  range motor, hotplug.
- AppImage that a fresh Linux user can run after installing the udev rule.
- Pure-Dart protocol layer covered by unit tests.
- README documents build, run, the udev rule, and the stream-gating requirement.

import 'dart:async';
import 'dart:typed_data';

import '../core/protocol/commands.dart';
import '../core/protocol/enums.dart';
import '../core/protocol/frames.dart';
import '../core/transport/hid_transport.dart';
import '../core/v4l2/v4l2_controls.dart';

/// Result of a motor command — lets the UI react to range rejects (§4.4).
class MotorResult {
  const MotorResult({required this.accepted, this.rejected = false});
  final bool accepted;

  /// True when the device returned status 0x40 (out of range / wedge risk).
  final bool rejected;

  static const ok = MotorResult(accepted: true);
  static const reject = MotorResult(accepted: false, rejected: true);
}

/// Live position sample from `getPosition`.
class Position {
  const Position(this.pan, this.tilt);
  final double pan;
  final double tilt;
}

/// High-level device API. Wraps [HidTransport] (FFI) and [V4l2Controls]
/// (subprocess) behind intent methods. Owns range clamping (§4.4) and frame
/// decoding so controllers stay thin.
class PixyDevice {
  PixyDevice({required this.transport, this.v4l2});

  final HidTransport transport;
  V4l2Controls? v4l2;

  // Conservative mechanical clamps (§4.4) — refine after measuring on hardware.
  static const double panLimit = 150.0;
  static const double tiltLimit = 30.0;

  // Velocity cap for the knob/joystick (~±30 °/s, §5.1).
  static const double velocityCap = 30.0;

  /// Async pushes (privacy state, auto-rotate) the camera emits unsolicited.
  Stream<PixyFrame> get pushes => transport.frames.where(_isAsyncPush);

  bool _isAsyncPush(PixyFrame f) {
    // 09 02 00 02 privacy state, 09 63 02 01 auto-rotate (channel 0x02 async).
    return f.channel == 0x02 &&
        ((f.group == 0x02 && f.sub == 0x02) ||
            (f.group == 0x03 && f.sub == 0x01));
  }

  double _clamp(double v, double limit) => v < -limit ? -limit : (v > limit ? limit : v);

  // ---- Motor / PTZ -----------------------------------------------------------

  /// Absolute target on one axis, clamped to mechanical limits. This is the only
  /// motion command used for arrows/go-to/recenter — the relative command
  /// `09 03 01 19` never moved the gimbal in testing and the arrow press
  /// correlated with a crash, so arrows are driven as absolute moves with a
  /// software-tracked target (see `DeviceController`). Returns the clamped
  /// target actually sent so the caller can keep its tracked position honest.
  Future<({MotorResult result, double target})> moveAbsolute(
      MotorAxis axis, double deg) async {
    final limit = axis == MotorAxis.pan ? panLimit : tiltLimit;
    final target = _clamp(deg, limit);
    final result = await _motor(Commands.motorAbsolute(axis, target));
    return (result: result, target: target);
  }

  /// Go-to a pan+tilt pair (clamped). Sends pan then tilt 20 ms apart.
  Future<void> goTo(double pan, double tilt) async {
    await moveAbsolute(MotorAxis.pan, pan);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await moveAbsolute(MotorAxis.tilt, tilt);
  }

  /// Recenter — absolute pan 0 then tilt 0, 20 ms apart (as pixyctl does).
  Future<void> recenter() => goTo(0, 0);

  /// Continuous velocity from the joystick knob. Zero vector stops.
  void drive(double panVel, double tiltVel) {
    final p = _clamp(panVel, velocityCap);
    final t = _clamp(tiltVel, velocityCap);
    transport.writeRaw(Commands.driveVelocity(p, t));
  }

  void stopDrive() => transport.writeRaw(Commands.driveVelocity(0, 0));

  Future<MotorResult> _motor(Uint8List frame) async {
    final resp = await transport.request(
      frame,
      // Motor status echoes on the same group/sub (or 09 03 01 17). The status
      // byte is the FIRST payload byte (0x20 OK / 0x40 reject) — scanning the
      // whole frame for 0x40 would false-positive on any position/payload byte
      // that happens to equal 0x40.
      timeout: const Duration(milliseconds: 300),
    );
    if (resp == null) return MotorResult.ok; // fire-and-forget; no error seen
    final rejected =
        resp.payload.isNotEmpty && resp.payload[0] == kStatusRejected;
    return rejected ? MotorResult.reject : MotorResult.ok;
  }

  /// Poll live position. Returns null if no response (e.g. stream not open).
  Future<Position?> getPosition() async {
    final resp = await transport.request(Commands.getPosition(),
        matcher: (f) => f.group == 0x03 && f.sub == 0x14);
    if (resp == null || resp.payload.length < 9) return null;
    return Position(resp.f32At(1), resp.f32At(5));
  }

  // ---- Presets ---------------------------------------------------------------

  Future<void> gotoPreset(int slot) async {
    transport.writeRaw(Commands.presetRead(slot));
  }

  Future<void> savePreset(int slot, double pan, double tilt) async {
    transport.writeRaw(Commands.presetWrite(slot, pan, tilt));
  }

  // ---- Mode ------------------------------------------------------------------

  Future<void> setMode(CameraMode mode) async =>
      transport.writeRaw(Commands.setMode(mode));

  Future<CameraMode?> getMode() async {
    final resp = await transport.request(Commands.getMode(),
        matcher: (f) => f.group == 0x01 && f.sub == 0x01);
    if (resp == null || resp.payload.isEmpty) return null;
    return CameraMode.fromWire(resp.u8At(0));
  }

  Future<String?> getSerial() async {
    final resp = await transport.request(Commands.getSerial(),
        matcher: (f) => f.group == 0x01 && f.sub == 0x03);
    if (resp == null) return null;
    final bytes = resp.payload.takeWhile((b) => b != 0).toList();
    final s = String.fromCharCodes(bytes).trim();
    return s.isEmpty ? null : s;
  }

  // ---- Tracking / AI ---------------------------------------------------------

  Future<void> setTracking(bool on) async =>
      transport.writeRaw(Commands.setTracking(on));

  /// Set gesture control. Sent as a *request* (not fire-and-forget) so a 0x40
  /// reject is visible — gesture framing (`09 04 02 00`) is from PROTOCOL.md and
  /// not yet hardware-verified, so we surface whether the device accepts it.
  /// Returns true if not explicitly rejected.
  Future<bool> setGesture(bool on) async {
    final resp = await transport.request(
      Commands.setGesture(on),
      // channel 0x02 distinguishes gesture (09 04 02 00) from the feature/flip
      // echo (09 04 00 08) which shares group 0x04.
      matcher: (f) => f.group == 0x04 && f.channel == 0x02 && f.sub == 0x00,
      timeout: const Duration(milliseconds: 250),
    );
    if (resp == null) return true; // no echo seen; treat as sent
    // Echo is `02 <status>` — status (0x20 OK / 0x40 reject) is the SECOND byte,
    // payload[0] is the feature selector (0x02). (Capture: `09 04 02 00 02 20`.)
    return !(resp.payload.length >= 2 && resp.payload[1] == kStatusRejected);
  }

  /// Read gesture-control state (`09 04 02 01` → resp payload `02, value`).
  Future<bool?> getGesture() async {
    final resp = await transport.request(Commands.getGesture(),
        // channel 0x02 — avoids matching the tracking GET (09 04 00 01).
        matcher: (f) => f.group == 0x04 && f.channel == 0x02 && f.sub == 0x01);
    if (resp == null || resp.payload.length < 2) return null;
    return resp.payload[1] != 0;
  }

  /// Focus-metering sends the 01 + 03 pair. Only valid in focus Lock (gate UI).
  Future<void> setFocusMetering(FocusMetering mode) async {
    for (final frame in Commands.setFocusMetering(mode)) {
      transport.writeRaw(frame);
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<void> setFlip({bool? vertical, bool? horizontal}) async {
    if (vertical != null) {
      transport.writeRaw(Commands.setFeature(FeatureId.flipVertical, vertical));
    }
    if (horizontal != null) {
      transport
          .writeRaw(Commands.setFeature(FeatureId.flipHorizontal, horizontal));
    }
  }

  Future<void> setAutoRotate(bool on) async => transport
      .writeRaw(Commands.setFeature(FeatureId.autoRotateUpsideDown, on));

  Future<bool?> getFeature(int id) async {
    final resp = await transport.request(Commands.getFeature(id),
        matcher: (f) => f.group == 0x04 && f.sub == 0x07);
    if (resp == null || resp.payload.length < 2) return null;
    return resp.payload[1] != 0;
  }

  // ---- Audio -----------------------------------------------------------------

  Future<void> setAudioMode(AudioMode mode) async =>
      transport.writeRaw(Commands.setAudioMode(mode));

  Future<AudioMode?> getAudioMode() async {
    final resp = await transport.request(Commands.getAudioMode(),
        matcher: (f) => f.group == 0x05 && f.sub == 0x04);
    if (resp == null || resp.payload.isEmpty) return null;
    return AudioMode.fromWire(resp.u8At(0));
  }

  // ---- Privacy timer ---------------------------------------------------------

  Future<void> setPrivacyTimer(int seconds) async =>
      transport.writeRaw(Commands.setPrivacyTimeout(seconds));

  Future<int?> getPrivacyTimer() async {
    final resp = await transport.request(Commands.getPrivacyTimeout(),
        matcher: (f) => f.group == 0x02 && f.sub == 0x01);
    if (resp == null || resp.payload.length < 4) return null;
    return resp.u32At(0);
  }

  // ---- Image controls (delegate to v4l2) -------------------------------------

  Future<void> refreshImageControls() async => v4l2?.refresh();

  /// Set a logical image control (resolves the concrete name at runtime).
  Future<bool> setImageControl(String logical, int value) async {
    final dev = v4l2;
    if (dev == null) return false;
    final candidates = V4l2Controls.logical[logical] ?? [logical];
    final name = dev.resolve(candidates);
    if (name == null) return false;
    return dev.set(name, value);
  }

  V4l2Control? imageControl(String logical) {
    final dev = v4l2;
    if (dev == null) return null;
    final candidates = V4l2Controls.logical[logical] ?? [logical];
    final name = dev.resolve(candidates);
    return name == null ? null : dev[name];
  }
}

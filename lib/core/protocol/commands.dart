import 'dart:typed_data';

import 'enums.dart';
import 'frames.dart';

/// Typed command builders — one entry per PROTOCOL.md command.
///
/// Every method returns a ready-to-write 32-byte frame (or a small ordered list
/// of frames where the protocol requires a pair). Range clamping is NOT done
/// here — that belongs to the high-level `PixyDevice` (§4.4). These builders are
/// the single source of truth for on-the-wire bytes and are unit-tested against
/// PROTOCOL.md.
class Commands {
  const Commands._();

  // ---------------------------------------------------------------------------
  // Motor / PTZ — group 0x03, channel 0x01
  // ---------------------------------------------------------------------------

  /// `09 03 01 18` — absolute motor target. Payload `u8 axis + f32`.
  static Uint8List motorAbsolute(MotorAxis axis, double deg) => buildFrame(
        [0x09, 0x03, 0x01, 0x18],
        payload: payloadOf([axis.wire, f32le(deg)]),
      );

  /// `09 63 01 20` — velocity stream (on-screen knob / joystick). Payload
  /// `f32 pan_vel + f32 tilt_vel + 4 zero bytes`. Zero vector = stop.
  /// Group byte carries the 0x60 knob bit verbatim (`0x63`).
  static Uint8List driveVelocity(double panVel, double tiltVel) => buildFrame(
        [0x09, 0x63, 0x01, 0x20],
        payload: payloadOf([f32le(panVel), f32le(tiltVel), 0, 0, 0, 0]),
      );

  /// `09 03 01 14` — get live position. Response `u8 + f32 pan + f32 tilt`.
  static Uint8List getPosition() => buildFrame([0x09, 0x03, 0x01, 0x14]);

  /// `09 03 01 16` — preset recall (read slot). Payload `u8 slot`.
  /// Working hypothesis until save-vs-recall framing is confirmed (§9).
  static Uint8List presetRead(int slot) => buildFrame(
        [0x09, 0x03, 0x01, 0x16],
        payload: payloadOf([slot]),
      );

  /// `09 03 01 16` — preset save (write slot). Payload `u8 slot + f32 pan + f32 tilt`.
  static Uint8List presetWrite(int slot, double pan, double tilt) => buildFrame(
        [0x09, 0x03, 0x01, 0x16],
        payload: payloadOf([slot, f32le(pan), f32le(tilt)]),
      );

  // ---------------------------------------------------------------------------
  // Mode — group 0x01
  // ---------------------------------------------------------------------------

  /// `09 01 01 00` — set camera mode. Payload `u8` (0 standard, 1 tracking, 2 privacy).
  static Uint8List setMode(CameraMode mode) => buildFrame(
        [0x09, 0x01, 0x01, 0x00],
        payload: payloadOf([mode.wire]),
      );

  /// `09 01 01 01` — get mode. Response byte 8 = mode.
  static Uint8List getMode() => buildFrame([0x09, 0x01, 0x01, 0x01]);

  /// `09 01 00 03` — get serial (ASCII).
  static Uint8List getSerial() => buildFrame([0x09, 0x01, 0x00, 0x03]);

  // ---------------------------------------------------------------------------
  // Tracking + AI — group 0x04
  // ---------------------------------------------------------------------------

  /// Focus-metering set: the protocol sends `09 04 00 01` and `09 04 00 03`
  /// with the *same* value (`u8 mode + f32(0)`). Returns both frames in order.
  /// Only valid while focus is locked (AF off) — gate in UI.
  static List<Uint8List> setFocusMetering(FocusMetering mode) => [
        buildFrame([0x09, 0x04, 0x00, 0x01],
            payload: payloadOf([mode.wire, f32le(0)])),
        buildFrame([0x09, 0x04, 0x00, 0x03],
            payload: payloadOf([mode.wire, f32le(0)])),
      ];

  /// `09 04 00 02` — get focus-metering. Response `u8 + f32`.
  static Uint8List getFocusMetering() => buildFrame([0x09, 0x04, 0x00, 0x02]);

  /// `09 04 02 00` — set gesture control on/off. Payload `02 + u8`.
  static Uint8List setGesture(bool on) => buildFrame(
        [0x09, 0x04, 0x02, 0x00],
        payload: payloadOf([0x02, on ? 1 : 0]),
      );

  /// `09 04 02 01` — get gesture control. Payload `02`.
  static Uint8List getGesture() => buildFrame(
        [0x09, 0x04, 0x02, 0x01],
        payload: payloadOf([0x02]),
      );

  /// `09 04 01 00` — set tracking target. Payload `u8 track + 5x f32`.
  /// [trackOn] toggles tracking; the 5 floats default to the centred frame.
  static Uint8List setTracking(
    bool trackOn, {
    double cx = 0.5,
    double cy = 0.5,
    double scale = 1.0,
    double a = 0.0,
    double b = 0.0,
  }) =>
      buildFrame(
        [0x09, 0x04, 0x01, 0x00],
        payload: payloadOf([
          trackOn ? 1 : 0,
          f32le(cx),
          f32le(cy),
          f32le(scale),
          f32le(a),
          f32le(b),
        ]),
      );

  /// `09 04 01 01` — get tracking. Response `u8 + 5x f32` (live subject coords).
  static Uint8List getTracking() => buildFrame([0x09, 0x04, 0x01, 0x01]);

  /// `09 04 00 08` — set feature toggle. Payload `u8 id + u8 on`.
  /// IDs: 0x01 flip-V, 0x02 flip-H, 0x04 auto-rotate-upside-down.
  static Uint8List setFeature(int id, bool on) => buildFrame(
        [0x09, 0x04, 0x00, 0x08],
        payload: payloadOf([id, on ? 1 : 0]),
      );

  /// `09 04 00 07` — get feature toggle. Payload `u8 id`. Response `id, value`.
  static Uint8List getFeature(int id) => buildFrame(
        [0x09, 0x04, 0x00, 0x07],
        payload: payloadOf([id]),
      );

  // ---------------------------------------------------------------------------
  // Audio mode — group 0x05, channel 0x00
  // ---------------------------------------------------------------------------

  /// `09 05 00 03` — set audio mode. Payload `u8` (1 Live, 2 Noise-Cancel, 3 Original).
  static Uint8List setAudioMode(AudioMode mode) => buildFrame(
        [0x09, 0x05, 0x00, 0x03],
        payload: payloadOf([mode.wire]),
      );

  /// `09 05 00 04` — get audio mode. Response `u8`.
  static Uint8List getAudioMode() => buildFrame([0x09, 0x05, 0x00, 0x04]);

  // ---------------------------------------------------------------------------
  // Privacy auto-timer — group 0x02, channel 0x01
  // ---------------------------------------------------------------------------

  /// `09 02 01 00` — set auto-privacy timeout. Payload `u32` seconds (0 = Never).
  static Uint8List setPrivacyTimeout(int seconds) => buildFrame(
        [0x09, 0x02, 0x01, 0x00],
        payload: payloadOf([u32le(seconds)]),
      );

  /// `09 02 01 01` — get auto-privacy timeout. Response `u32`.
  static Uint8List getPrivacyTimeout() => buildFrame([0x09, 0x02, 0x01, 0x01]);
}

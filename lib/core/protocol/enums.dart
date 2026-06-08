/// Typed enums for the PIXY control protocol.
///
/// Wire values are taken from PROTOCOL.md and must not be changed without a
/// matching capture — they are the bytes the camera actually expects.
library;

/// Camera operating mode — group 0x01, `09 01 01 00`.
enum CameraMode {
  standard(0),
  tracking(1),
  privacy(2),

  /// Reported by the camera before any stream is open (stream gating, §4.1).
  startup(3);

  const CameraMode(this.wire);
  final int wire;

  static CameraMode fromWire(int v) =>
      CameraMode.values.firstWhere((m) => m.wire == v, orElse: () => CameraMode.startup);
}

/// Tracking subject mode. `off` is represented by tracking feature disabled;
/// the on-states map to the camera's tracking-target framing.
enum TrackingMode {
  off,
  face,
  halfBody,
  fullBody,
}

/// Audio mode — group 0x05, `09 05 00 03`.
enum AudioMode {
  live(1),
  noiseCanceling(2),
  original(3);

  const AudioMode(this.wire);
  final int wire;

  static AudioMode fromWire(int v) =>
      AudioMode.values.firstWhere((m) => m.wire == v, orElse: () => AudioMode.live);
}

/// Focus-metering mode — group 0x04, `09 04 00 01`/`03`.
/// Only valid while focus is locked (AF off) — gate in UI (§5, AI panel).
enum FocusMetering {
  central(0),
  face(1),
  selectedArea(2);

  const FocusMetering(this.wire);
  final int wire;

  static FocusMetering fromWire(int v) => FocusMetering.values
      .firstWhere((m) => m.wire == v, orElse: () => FocusMetering.central);
}

/// Connection / availability state surfaced by the controller.
enum PixyConnectionState {
  disconnected,

  /// Discovery / open in progress (drives the searching spinner).
  connecting,

  connected,
  cameraInUse,
  needsPermission,

  /// Discovery completed but no PIXY was found (distinct from idle disconnected).
  notFound,
}

/// Motor axis selector — payload byte for motor commands (group 0x03).
enum MotorAxis {
  pan(1),
  tilt(2);

  const MotorAxis(this.wire);
  final int wire;
}

/// Feature-toggle IDs — group 0x04, channel 0x00, sub 0x07 get / 0x08 set.
class FeatureId {
  static const int flipVertical = 0x01;
  static const int flipHorizontal = 0x02;
  static const int autoRotateUpsideDown = 0x04;
}

/// Privacy auto-timer presets in seconds — group 0x02, `09 02 01 00`.
/// 0 = Never.
class PrivacyTimeout {
  static const List<int> presets = [10, 60, 900, 0];
  static const int never = 0;
}

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/diag/crash_log.dart';
import '../core/protocol/enums.dart';
import '../core/protocol/frames.dart';
import '../core/stream/capture_resolution.dart';
import '../core/stream/preview_controller.dart';
import '../core/transport/hid_transport.dart';
import '../core/v4l2/v4l2_controls.dart';
import '../services/device_discovery.dart';
import '../services/pixy_device.dart';
import 'settings_controller.dart';

/// Live device state mirrored from the camera (spec §7).
class DeviceState {
  PixyConnectionState connection = PixyConnectionState.disconnected;
  CameraMode mode = CameraMode.startup;
  bool tracking = false;
  TrackingMode trackingMode = TrackingMode.face;
  bool gesture = false;
  bool flipV = false;
  bool flipH = false;
  bool autoRotate = false;
  FocusMetering focusMetering = FocusMetering.central;
  AudioMode audioMode = AudioMode.live;
  int privacyTimeoutSec = 0; // 0 = never
  double pan = 0;
  double tilt = 0;
  String? serial;
  String? hidrawPath;
  String? videoNode;

  /// True once a stream (ours or another app's) has ungated control (§4.1/§4.2).
  bool controlUngated = false;

  /// Last motor reject (§4.4) — surfaced as a non-blocking warning.
  bool motorWedgeWarning = false;
}

/// Owns connection + live device state, the [PixyDevice], and the
/// [PreviewController]; exposes intent methods that drive the device and then
/// `notifyListeners()`.
class DeviceController extends ChangeNotifier {
  DeviceController({required this.settings, DeviceDiscovery? discovery})
      : _discovery = discovery ?? const DeviceDiscovery();

  final SettingsController settings;
  final DeviceDiscovery _discovery;

  final DeviceState state = DeviceState();
  final PreviewController preview = PreviewController();

  HidTransport? _transport;
  PixyDevice? _device;
  PixyDevice? get device => _device;

  StreamSubscription<PixyFrame>? _pushSub;
  StreamSubscription<PreviewState>? _previewSub;

  bool _disposed = false;
  bool _connecting = false;

  /// The most recent decoded async frames, newest first (debug panel).
  final List<String> debugLog = [];
  static const int _maxLog = 200;

  PixyConnectionState get connection => state.connection;
  bool get isConnected => _transport?.isOpen ?? false;
  bool get controlsEnabled => isConnected && state.controlUngated;

  V4l2Controls? get v4l2 => _device?.v4l2;

  /// All incoming HID frames (debug panel live log). Null when disconnected.
  Stream<PixyFrame>? get frameStream => _transport?.frames;

  /// Whether digital zoom is currently usable. Zoom only takes effect at
  /// 2K/1080p/720p @30fps (§4.6) — NOT at 4K — and needs the control present.
  bool get zoomAvailable {
    final c = _device?.imageControl('zoomAbsolute');
    return c != null && !c.isInactive && settings.captureResolution.zoomCapable;
  }

  /// Change PixyControl's capture resolution (persists + relaunches the stream).
  Future<void> setCaptureResolution(CaptureResolution r) async {
    await settings.setCaptureResolution(r);
    await preview.setFormat(r, settings.captureFps);
    _notify();
  }

  /// Change capture fps (30/60 — 60 only honoured at 1080p/720p).
  Future<void> setCaptureFps(int fps) async {
    await settings.setCaptureFps(fps);
    await preview.setFormat(settings.captureResolution, settings.captureFps);
    _notify();
  }

  bool _notifyScheduled = false;

  /// Coalesce listener notifications to ONE rebuild per frame. Every panel does
  /// `context.watch<DeviceController>()`, so a burst of state changes (e.g. the
  /// 8 sequential reads in `_readInitialState`, or rapid camera pushes) would
  /// otherwise rebuild the whole widget tree N times in a row — a rebuild storm
  /// that destabilised the GTK/GL engine and crashed the app. Scheduling a
  /// single microtask collapses the burst into one rebuild. Guards `_disposed`
  /// (async continuations may resolve after dispose; notifyListeners() throws).
  void _notify() {
    if (_disposed || _notifyScheduled) return;
    _notifyScheduled = true;
    scheduleMicrotask(() {
      _notifyScheduled = false;
      if (!_disposed) notifyListeners();
    });
  }

  void _setConnection(PixyConnectionState s) {
    state.connection = s;
    _notify();
  }

  // ---- connection lifecycle --------------------------------------------------

  Future<void> connect() async {
    // Reentrancy guard: auto-connect on launch + a user tap could race and
    // leak transports/subscriptions.
    if (_connecting || _disposed) return;
    _connecting = true;
    try {
      await _connectImpl();
    } finally {
      _connecting = false;
    }
  }

  Future<void> _connectImpl() async {
    await disconnect();
    if (_disposed) return;
    _setConnection(PixyConnectionState.connecting);

    PixyDiscovery disco;
    try {
      disco = await _discovery.discover();
    } catch (e) {
      _logLine('discovery failed: $e');
      _setConnection(PixyConnectionState.notFound);
      return;
    }
    if (_disposed) return;
    state.hidrawPath = disco.hidrawPath;
    state.videoNode = disco.videoNode;

    // No control node and no video node → nothing found.
    if (!disco.hasControl && !disco.hasVideo) {
      _setConnection(PixyConnectionState.notFound);
      return;
    }

    // Permission pre-check on the hidraw node.
    if (disco.hidrawPath != null &&
        !await _discovery.canAccess(disco.hidrawPath!)) {
      _setConnection(PixyConnectionState.needsPermission);
      // Still try to bring up preview so the user sees video.
      await _startPreview(disco.videoNode);
      return;
    }

    // Open HID transport.
    try {
      final t = HidTransport();
      t.open(path: disco.hidrawPath);
      _transport = t;
    } on HidTransportException catch (e) {
      _logLine('hid open failed: ${e.message}');
      _setConnection(e.isPermission
          ? PixyConnectionState.needsPermission
          : PixyConnectionState.notFound);
      await _startPreview(disco.videoNode);
      return;
    } catch (e) {
      _logLine('hid open error: $e');
      _setConnection(PixyConnectionState.notFound);
      return;
    }

    final v4l2 = disco.videoNode == null ? null : V4l2Controls(disco.videoNode!);
    _device = PixyDevice(transport: _transport!, v4l2: v4l2);

    _pushSub = _device!.pushes.listen(_onPush);
    _previewSub = preview.stateStream.listen(_onPreviewState);

    await settings.rememberDevice(
        videoNode: disco.videoNode, hidrawPath: disco.hidrawPath);

    _setConnection(PixyConnectionState.connected);
    await _startPreview(disco.videoNode);
    await _device!.refreshImageControls();

    // Initial state read happens once control is ungated (preview live/busy).
    if (state.controlUngated) await _readInitialState();
  }

  Future<void> _startPreview(String? videoNode) async {
    // Apply the saved capture format before the first spawn (only stores while
    // videoNode is still null).
    await preview.setFormat(settings.captureResolution, settings.captureFps);
    await preview.open(videoNode);
  }

  /// Show / hide the in-app live preview.
  Future<void> setPreview(bool on) async {
    await preview.setPreview(on);
    _notify();
  }

  bool get previewOn => preview.previewOn;

  Future<void> disconnect() async {
    _statePoll?.cancel();
    _statePoll = null;
    _pulseTimer?.cancel();
    _pulseTimer = null;
    await _pushSub?.cancel();
    _pushSub = null;
    await _previewSub?.cancel();
    _previewSub = null;
    await preview.stop();
    final t = _transport;
    _transport = null;
    _device = null;
    if (t != null) await t.dispose();
    state.controlUngated = false;
    _initialStateRead = false;
    _setConnection(PixyConnectionState.disconnected);
  }

  void _onPreviewState(PreviewState s) {
    if (_disposed) return;
    final wasUngated = state.controlUngated;
    state.controlUngated = preview.controlUngated;
    // Reflect "camera in use" in the connection badge when HID is up but our
    // preview is busy (§4.2).
    if (isConnected) {
      if (s == PreviewState.busy) {
        _setConnection(PixyConnectionState.cameraInUse);
      } else if (state.connection == PixyConnectionState.cameraInUse &&
          s == PreviewState.streaming) {
        _setConnection(PixyConnectionState.connected);
      }
    }
    if (wasUngated && !state.controlUngated) {
      // Control was lost (e.g. another app grabbed the single stream). Re-arm the
      // one-shot initial read + stop the mode poll so they re-run on the next
      // ungate against the real, possibly-changed device state.
      _initialStateRead = false;
      _statePoll?.cancel();
      _statePoll = null;
    }
    if (!wasUngated && state.controlUngated && isConnected) {
      // Control just became available — read the device's real state.
      _readInitialState();
    }
    _notify();
  }

  bool _initialStateRead = false;

  Future<void> _readInitialState() async {
    if (_initialStateRead) return; // guard against double-read on connect
    final dev = _device;
    if (dev == null) return;
    _initialStateRead = true;
    CrashLog.write('readInitialState: begin');
    state.mode = await dev.getMode() ?? state.mode;
    state.serial = await dev.getSerial() ?? state.serial;
    state.audioMode = await dev.getAudioMode() ?? state.audioMode;
    state.privacyTimeoutSec = await dev.getPrivacyTimer() ?? state.privacyTimeoutSec;
    state.flipV = await dev.getFeature(FeatureId.flipVertical) ?? state.flipV;
    state.flipH = await dev.getFeature(FeatureId.flipHorizontal) ?? state.flipH;
    state.autoRotate =
        await dev.getFeature(FeatureId.autoRotateUpsideDown) ?? state.autoRotate;
    state.gesture = await dev.getGesture() ?? state.gesture;
    state.tracking = state.mode == CameraMode.tracking;
    CrashLog.write('readInitialState: done mode=${state.mode} gesture=${state.gesture}');
    _startStatePoll();
    // Seed the tracked command target from a one-shot read (best-effort; the
    // readback is otherwise unreliable so we don't keep polling it).
    final pos = await dev.getPosition();
    if (pos != null) {
      _cmdPan = pos.pan;
      _cmdTilt = pos.tilt;
      state.pan = pos.pan;
      state.tilt = pos.tilt;
    }
    _notify();
  }

  bool _autoRotateReadInFlight = false;

  // Live MODE poll — the camera's mode (and thus tracking) can change WITHOUT a
  // command from us (e.g. a hand gesture starts/stops tracking). getMode
  // (09 01 01 01, group 0x01) returns the live value, unlike the frozen position
  // readback. Only mode is polled: gesture is a flag the USER sets (it never
  // self-changes), and polling its channel (09 04 02 01) was disrupting the
  // camera's gesture DETECTION — so we never touch group 0x04 in the background.
  //
  // The camera emits NO async push for a mode change (the capture shows even
  // EMEET Studio polls 09 01 01 01 continuously), so this poll is the ONLY way a
  // gesture-driven tracking toggle reaches the UI. Cadence = how fast that toggle
  // shows up: 400 ms gives ~0.2 s average reflect latency. group 0x01 is safe to
  // poll at this rate (it's what the official app does); 0x04 is the one to avoid.
  static const _statePollInterval = Duration(milliseconds: 400);
  Timer? _statePoll;
  bool _statePollBusy = false;

  void _startStatePoll() {
    _statePoll?.cancel();
    _statePoll = Timer.periodic(_statePollInterval, (_) => _pollState());
  }

  Future<void> _pollState() async {
    if (_statePollBusy || _disposed) return;
    final dev = _device;
    if (dev == null || !state.controlUngated) return;
    _statePollBusy = true;
    try {
      final m = await dev.getMode();
      if (m != null && m != CameraMode.startup && m != state.mode) {
        state.mode = m;
        state.tracking = m == CameraMode.tracking;
        _notify();
      }
    } finally {
      _statePollBusy = false;
    }
  }

  void _onPush(PixyFrame f) {
    if (_disposed) return;
    _logLine('push $f');
    // Privacy state change: 09 02 00 02 -> u8 (3 active / 0 off). Only notify on
    // an actual change — the camera can repeat this push, and an unconditional
    // _notify() per push rebuilds every watching panel and fed the crash.
    if (f.group == 0x02 && f.sub == 0x02 && f.payload.isNotEmpty) {
      final active = f.payload[0] == 3;
      final mode = active ? CameraMode.privacy : CameraMode.standard;
      if (state.mode != mode) {
        state.mode = mode;
        _notify();
      }
    }
    // Auto-rotate event: 09 63 02 01 — re-read the feature flag. Debounce: skip
    // if a read is already in flight so a burst of pushes can't flood the HID
    // channel with overlapping requests.
    final dev = _device;
    if (f.group == 0x03 && f.sub == 0x01 && dev != null &&
        !_autoRotateReadInFlight) {
      _autoRotateReadInFlight = true;
      dev.getFeature(FeatureId.autoRotateUpsideDown).then((v) {
        _autoRotateReadInFlight = false;
        if (v != null && !_disposed && state.autoRotate != v) {
          state.autoRotate = v;
          _notify();
        }
      });
    }
  }

  // ---- intent methods --------------------------------------------------------

  Future<void> setMode(CameraMode mode) async {
    await _device?.setMode(mode);
    state.mode = mode;
    state.tracking = mode == CameraMode.tracking;
    _notify();
  }

  // Software-tracked commanded target. The camera's live-position readback
  // (09 03 01 14) is frozen/stale, so we accumulate arrow steps against this
  // instead of re-reading. Seeded from getPosition() once on connect.
  double _cmdPan = 0;
  double _cmdTilt = 0;

  // Arrow steps = a VELOCITY PULSE on the knob channel (09 63 01 20). This is the
  // ONLY motion primitive that actually moves the gimbal on this hardware —
  // the relative commands (09 03 01 19 / 09 63 01 19) never moved it and absolute
  // (09 03 01 18) is unreliable for non-zero targets. So an arrow press drives at
  // a fixed speed in the step's direction for `|delta| / speed` seconds, then
  // stops — an open-loop "move right 10°"-style nudge. Safety: the rebuild-storm
  // crash that previously killed the stop mid-pulse (→ runaway) is fixed, the
  // pulse is short/capped, and if the app dies the mpv keepalive's pdeathsig
  // closes the stream which ungates (stops) the motor.
  static const double _pulseSpeed = 18.0; // deg/s (< velocityCap 30)
  Timer? _pulseTimer;

  void step(MotorAxis axis, double delta) {
    final dev = _device;
    if (dev == null || delta == 0) return;
    _pulseTimer?.cancel(); // supersede any in-flight pulse
    final speed = delta < 0 ? -_pulseSpeed : _pulseSpeed;
    final durMs = (delta.abs() / _pulseSpeed * 1000).round().clamp(80, 2500);
    if (axis == MotorAxis.pan) {
      dev.drive(speed, 0);
      _cmdPan += delta;
      state.pan = _cmdPan;
    } else {
      dev.drive(0, speed);
      _cmdTilt += delta;
      state.tilt = _cmdTilt;
    }
    // Commit the commanded target at issue time (not in the timer): rapid
    // presses each cancel the prior timer, so a deferred commit would be lost
    // and the readout would drift. The timer only stops the motor.
    _notify();
    _pulseTimer = Timer(Duration(milliseconds: durMs), dev.stopDrive);
  }

  Future<void> moveAbsolute(MotorAxis axis, double deg) => _absolute(axis, deg);

  /// Drive one axis to an absolute target and update the tracked command.
  Future<void> _absolute(MotorAxis axis, double deg) async {
    final dev = _device;
    if (dev == null) return;
    final r = await dev.moveAbsolute(axis, deg);
    if (axis == MotorAxis.pan) {
      _cmdPan = r.target;
      state.pan = r.target;
    } else {
      _cmdTilt = r.target;
      state.tilt = r.target;
    }
    _handleMotor(r.result);
    _notify();
  }

  Future<void> goTo(double pan, double tilt) async {
    await _absolute(MotorAxis.pan, pan);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await _absolute(MotorAxis.tilt, tilt);
  }

  Future<void> recenter() => goTo(0, 0);

  void drive(double panVel, double tiltVel) {
    _pulseTimer?.cancel(); // knob takes over; cancel pending pulse-stop
    _device?.drive(panVel, tiltVel);
  }

  void stopDrive() {
    _pulseTimer?.cancel();
    _device?.stopDrive();
  }

  Future<void> gotoPreset(int slot) async => _device?.gotoPreset(slot);
  Future<void> savePreset(int slot) async =>
      _device?.savePreset(slot, state.pan, state.tilt);

  Future<void> setTracking(bool on) async {
    await _device?.setTracking(on);
    state.tracking = on;
    _notify();
  }

  Future<void> setGesture(bool on) async {
    final dev = _device;
    if (dev == null) return;
    final accepted = await dev.setGesture(on);
    _logLine('setGesture($on) -> ${accepted ? "accepted" : "REJECTED (0x40)"}');
    state.gesture = on;
    _notify();
  }

  Future<void> setFocusMetering(FocusMetering mode) async {
    await _device?.setFocusMetering(mode);
    state.focusMetering = mode;
    _notify();
  }

  Future<void> setFlipVertical(bool on) async {
    await _device?.setFlip(vertical: on);
    state.flipV = on;
    _notify();
  }

  Future<void> setFlipHorizontal(bool on) async {
    await _device?.setFlip(horizontal: on);
    state.flipH = on;
    _notify();
  }

  Future<void> setAutoRotate(bool on) async {
    await _device?.setAutoRotate(on);
    state.autoRotate = on;
    _notify();
  }

  Future<void> setAudioMode(AudioMode mode) async {
    await _device?.setAudioMode(mode);
    state.audioMode = mode;
    _notify();
  }

  Future<void> setPrivacyTimer(int seconds) async {
    await _device?.setPrivacyTimer(seconds);
    state.privacyTimeoutSec = seconds;
    _notify();
  }

  Future<bool> setImageControl(String logical, int value) async =>
      await _device?.setImageControl(logical, value) ?? false;

  void _handleMotor(MotorResult? r) {
    if (r != null && r.rejected) {
      state.motorWedgeWarning = true;
      _logLine('motor rejected (0x40) — possible range/wedge');
      _notify();
    }
  }

  void clearMotorWarning() {
    state.motorWedgeWarning = false;
    _notify();
  }

  // The Pan/Tilt readout tracks the software-commanded target (_cmdPan/_cmdTilt,
  // mirrored into state.pan/state.tilt) — the camera's live-position readback
  // (09 03 01 14) is frozen/stale, so it is never polled.

  // ---- raw send (debug panel) ------------------------------------------------

  void sendRaw(List<int> header, List<int> payload) {
    final frame = buildFrame(header, payload: payload);
    _transport?.writeRaw(frame);
    _logLine('raw-> $frame');
  }

  void _logLine(String s) {
    debugLog.insert(0, s);
    if (debugLog.length > _maxLog) debugLog.removeLast();
    CrashLog.write(s); // mirror to the on-disk breadcrumb trail
  }

  @override
  void dispose() {
    // Mark disposed first so any in-flight async continuation that resolves
    // during teardown no-ops instead of calling notifyListeners() (which throws
    // after dispose). ChangeNotifier.dispose is sync, so the native/stream
    // teardown is fire-and-forget by necessity; nulling the fields prevents
    // further use.
    _disposed = true;
    _statePoll?.cancel();
    _statePoll = null;
    _pulseTimer?.cancel();
    _pulseTimer = null;
    _pushSub?.cancel();
    _pushSub = null;
    _previewSub?.cancel();
    _previewSub = null;
    final t = _transport;
    _transport = null;
    _device = null;
    t?.dispose();
    preview.dispose();
    super.dispose();
  }
}

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/stream/capture_resolution.dart';

/// Persisted user preferences (preset labels, PTZ step size, theme, last device).
class SettingsController extends ChangeNotifier {
  SettingsController(this._prefs) {
    _load();
  }

  final SharedPreferences _prefs;

  static const _kStep = 'ptz.step';
  static const _kThemeDark = 'theme.dark';
  static const _kLastVideo = 'device.lastVideo';
  static const _kLastHidraw = 'device.lastHidraw';
  static const _kPresetPrefix = 'preset.label.';
  static const _kResolution = 'capture.resolution';
  static const _kFps = 'capture.fps';

  // PTZ arrow step size (degrees). Options 1/3/5/10 (§6 control panel).
  double _stepDeg = 5.0;
  double get stepDeg => _stepDeg;
  static const List<double> stepOptions = [1, 3, 5, 10];

  bool _darkMode = true; // dark-first (spec §2/§6)
  bool get darkMode => _darkMode;

  // PixyControl's preferred capture resolution (4K/2K/1080p/720p) + fps.
  CaptureResolution _resolution = CaptureResolution.defaultValue;
  CaptureResolution get captureResolution => _resolution;

  int _fps = 30; // 30 or 60 (60 only valid at 1080p/720p)
  int get captureFps => _resolution.supports60 ? _fps : 30;

  String? get lastVideoNode => _prefs.getString(_kLastVideo);
  String? get lastHidrawPath => _prefs.getString(_kLastHidraw);

  final Map<int, String> _presetLabels = {};
  Map<int, String> get presetLabels => Map.unmodifiable(_presetLabels);

  /// Default labels for slots 0..3 (0 = Initial, 1..3 = No.1..No.3).
  static const Map<int, String> defaultPresetLabels = {
    0: 'Initial',
    1: 'No.1',
    2: 'No.2',
    3: 'No.3',
  };

  String presetLabel(int slot) =>
      _presetLabels[slot] ?? defaultPresetLabels[slot] ?? 'Slot $slot';

  void _load() {
    _stepDeg = _prefs.getDouble(_kStep) ?? 5.0;
    _darkMode = _prefs.getBool(_kThemeDark) ?? true;
    _resolution = CaptureResolution.fromKey(_prefs.getString(_kResolution));
    _fps = _prefs.getInt(_kFps) ?? 30;
    for (final slot in defaultPresetLabels.keys) {
      final v = _prefs.getString('$_kPresetPrefix$slot');
      if (v != null) _presetLabels[slot] = v;
    }
  }

  Future<void> setCaptureResolution(CaptureResolution r) async {
    _resolution = r;
    await _prefs.setString(_kResolution, r.key);
    notifyListeners();
  }

  Future<void> setCaptureFps(int fps) async {
    _fps = fps == 60 ? 60 : 30;
    await _prefs.setInt(_kFps, _fps);
    notifyListeners();
  }

  Future<void> setStep(double deg) async {
    _stepDeg = deg;
    await _prefs.setDouble(_kStep, deg);
    notifyListeners();
  }

  Future<void> setDarkMode(bool dark) async {
    _darkMode = dark;
    await _prefs.setBool(_kThemeDark, dark);
    notifyListeners();
  }

  Future<void> setPresetLabel(int slot, String label) async {
    final trimmed = label.trim();
    if (trimmed.isEmpty) {
      _presetLabels.remove(slot);
      await _prefs.remove('$_kPresetPrefix$slot');
    } else {
      _presetLabels[slot] = trimmed;
      await _prefs.setString('$_kPresetPrefix$slot', trimmed);
    }
    notifyListeners();
  }

  Future<void> rememberDevice({String? videoNode, String? hidrawPath}) async {
    if (videoNode != null) await _prefs.setString(_kLastVideo, videoNode);
    if (hidrawPath != null) await _prefs.setString(_kLastHidraw, hidrawPath);
  }
}

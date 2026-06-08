import 'dart:io';

/// A single V4L2 control as reported by `v4l2-ctl --list-ctrls-menus`.
class V4l2Control {
  V4l2Control({
    required this.name,
    required this.type,
    this.min,
    this.max,
    this.step,
    this.defaultValue,
    required this.value,
    this.flags = const [],
    Map<int, String>? menu,
  }) : menu = menu ?? {};

  final String name; // e.g. brightness, white_balance_temperature
  final String type; // int, bool, menu
  final int? min;
  final int? max;
  final int? step;
  final int? defaultValue;
  int value;
  final List<String> flags; // e.g. inactive, read-only
  final Map<int, String> menu; // menu index -> label

  bool get isBool => type == 'bool';
  bool get isMenu => type == 'menu';
  bool get isInactive => flags.contains('inactive');
  bool get isReadOnly => flags.contains('read-only');

  @override
  String toString() =>
      '$name=$value ($type, min=$min max=$max def=$defaultValue ${flags.join(",")})';
}

/// Wrapper over the `v4l2-ctl` CLI for image / exposure / focus / WB / zoom
/// controls (these are UVC, not HID — PROTOCOL.md §UVC).
///
/// Control names are discovered at runtime from the enumeration rather than
/// hard-coded (spec §5): the same logical control can have slightly different
/// names across kernels.
class V4l2Controls {
  V4l2Controls(this.device);

  /// Absolute path to the tool — avoids a `$PATH` hijack of `v4l2-ctl`.
  static const String v4l2ctl = '/usr/bin/v4l2-ctl';

  /// Control names must be a single identifier token. Rejecting anything else
  /// blocks comma/equals injection into `--set-ctrl=NAME=VALUE` (a crafted name
  /// like `x=0,focus_absolute` would set unintended controls).
  static final RegExp _validName = RegExp(r'^\w+$');

  /// V4L2 node, e.g. `/dev/video0`.
  final String device;

  final Map<String, V4l2Control> _controls = {};

  Map<String, V4l2Control> get controls => Map.unmodifiable(_controls);

  V4l2Control? operator [](String name) => _controls[name];

  /// Resolve a logical control to whichever concrete name exists on this device.
  /// Returns the first candidate that is present.
  String? resolve(List<String> candidates) {
    for (final c in candidates) {
      if (_controls.containsKey(c)) return c;
    }
    return null;
  }

  // Logical control name → ordered candidate concrete names.
  static const Map<String, List<String>> logical = {
    'brightness': ['brightness'],
    'contrast': ['contrast'],
    'saturation': ['saturation'],
    'tone': ['hue'],
    'sharpness': ['sharpness'],
    'gain': ['gain', 'iso_sensitivity'],
    'powerLineFrequency': ['power_line_frequency'],
    'whiteBalanceAuto': [
      'white_balance_automatic',
      'white_balance_temperature_auto',
    ],
    'whiteBalanceTemp': ['white_balance_temperature'],
    'autoExposure': ['auto_exposure', 'exposure_auto'],
    'exposureTime': ['exposure_time_absolute', 'exposure_absolute'],
    'focusAuto': ['focus_automatic_continuous', 'focus_auto'],
    'focusAbsolute': ['focus_absolute'],
    'zoomAbsolute': ['zoom_absolute'],
  };

  /// Enumerate all controls from the device. Populates [controls].
  Future<void> refresh() async {
    final res = await _run(['--list-ctrls-menus']);
    if (res == null) return;
    _controls
      ..clear()
      ..addAll(_parse(res));
  }

  /// Get the current value of a concrete control (reads live from the device).
  Future<int?> get(String name) async {
    if (!_validName.hasMatch(name)) return null;
    final out = await _run(['--get-ctrl=$name']);
    if (out == null) return null;
    // Output: "brightness: 128" — anchor on the control name to avoid
    // mis-parsing multi-field or digit-bearing output.
    final m = RegExp('${RegExp.escape(name)}:\\s*(-?\\d+)').firstMatch(out) ??
        RegExp(r':\s*(-?\d+)').firstMatch(out);
    final v = m == null ? null : int.tryParse(m.group(1)!);
    if (v != null && _controls.containsKey(name)) _controls[name]!.value = v;
    return v;
  }

  /// Set a concrete control to [value]. Updates the cached value on success.
  /// Rejects invalid names and clamps to the enumerated min/max when known.
  Future<bool> set(String name, int value) async {
    if (!_validName.hasMatch(name)) return false;
    final ctrl = _controls[name];
    var v = value;
    if (ctrl != null) {
      if (ctrl.min != null && v < ctrl.min!) v = ctrl.min!;
      if (ctrl.max != null && v > ctrl.max!) v = ctrl.max!;
    }
    final out = await _run(['--set-ctrl=$name=$v']);
    final ok = out != null;
    if (ok && ctrl != null) ctrl.value = v;
    return ok;
  }

  /// Restore a control to its enumerated default.
  Future<bool> restoreDefault(String name) async {
    final ctrl = _controls[name];
    if (ctrl?.defaultValue == null) return false;
    return set(name, ctrl!.defaultValue!);
  }

  Future<String?> _run(List<String> args) async {
    try {
      final res = await Process.run(v4l2ctl, ['-d', device, ...args]);
      if (res.exitCode != 0) return null;
      return res.stdout as String;
    } catch (_) {
      return null;
    }
  }

  /// Parse `--list-ctrls-menus` output. Lines look like:
  /// ```
  ///   brightness 0x00980900 (int)    : min=0 max=255 step=1 default=128 value=128
  ///   power_line_frequency 0x00980918 (menu)   : min=0 max=2 default=1 value=1
  ///                0: Disabled
  ///                1: 50 Hz
  ///   white_balance_automatic 0x0098090c (bool)   : default=1 value=1
  /// ```
  static Map<String, V4l2Control> _parse(String text) {
    final out = <String, V4l2Control>{};
    final ctrlLine = RegExp(
        r'^\s*(\w+)\s+0x[0-9a-fA-F]+\s+\((int|bool|menu|intmenu|int64|button|string)\)\s*:\s*(.*)$');
    final menuItem = RegExp(r'^\s+(\d+):\s*(.+)$');
    V4l2Control? current;

    for (final line in text.split('\n')) {
      final cm = ctrlLine.firstMatch(line);
      if (cm != null) {
        final name = cm.group(1)!;
        final type = cm.group(2)!;
        final rest = cm.group(3)!;
        int? field(String key) {
          final m = RegExp('$key=(-?\\d+)').firstMatch(rest);
          return m == null ? null : int.tryParse(m.group(1)!);
        }

        final flags = <String>[];
        final flagsM = RegExp(r'flags=([\w,]+)').firstMatch(rest);
        if (flagsM != null) flags.addAll(flagsM.group(1)!.split(','));

        current = V4l2Control(
          name: name,
          type: type == 'intmenu' ? 'menu' : type,
          min: field('min'),
          max: field('max'),
          step: field('step'),
          defaultValue: field('default'),
          value: field('value') ?? 0,
          flags: flags,
        );
        out[name] = current;
        continue;
      }
      final mi = menuItem.firstMatch(line);
      if (mi != null && current != null && current.isMenu) {
        current.menu[int.parse(mi.group(1)!)] = mi.group(2)!.trim();
      }
    }
    return out;
  }
}

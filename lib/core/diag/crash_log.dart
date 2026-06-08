import 'dart:io';

/// Append-only breadcrumb log. The app crashes with a native SIGSEGV on some
/// systems (no Dart stack survives), and it can't be reproduced in development,
/// so we leave a trail: the LAST line written before the process dies points at
/// the operation that was running. Cheap, synchronous, flushed on every write so
/// nothing is lost in the OS buffer when the process is killed.
class CrashLog {
  CrashLog._();

  static IOSink? _sink;
  static bool _init = false;

  static String? _cachedPath;

  /// Log file path (resolved once). Prefer `$XDG_RUNTIME_DIR` (per-user 0700
  /// tmpfs). On the world-writable temp fallback, use a freshly `createTempSync`
  /// dir (0700, unpredictable name) so another local user can't pre-create or
  /// symlink a fixed name we'd then truncate.
  static String get path {
    final cached = _cachedPath;
    if (cached != null) return cached;
    final runtime = Platform.environment['XDG_RUNTIME_DIR'];
    String resolved;
    if (runtime != null && runtime.isNotEmpty) {
      resolved = '$runtime/pixyctl.log';
    } else {
      try {
        resolved = '${Directory.systemTemp.createTempSync('pixyctl-').path}/pixyctl.log';
      } catch (_) {
        resolved = '${Directory.systemTemp.path}/pixyctl.log';
      }
    }
    return _cachedPath = resolved;
  }

  /// Open the log (truncates a prior run's file). Safe to call once at startup.
  static void init() {
    if (_init) return;
    _init = true;
    try {
      final f = File(path);
      _sink = f.openWrite(mode: FileMode.write);
      write('=== PixyControl started — log at $path ===');
    } catch (_) {
      _sink = null; // logging must never take down the app
    }
  }

  /// Write a timestamped breadcrumb and flush immediately.
  static void write(String msg) {
    final sink = _sink;
    if (sink == null) return;
    try {
      sink.writeln('${DateTime.now().toIso8601String()}  $msg');
      // ignore: discarded_futures
      sink.flush();
    } catch (_) {}
  }
}

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'capture_resolution.dart';

/// Preview lifecycle states (drives the badge + overlay, §4.1/§4.2).
enum PreviewState {
  idle,

  /// Starting the stream holder.
  opening,

  /// A subprocess holds the V4L2 stream open — this ungates HID control (§4.1).
  streaming,

  /// Device is busy (already streamed by another app, e.g. OBS/Zoom). Controls
  /// stay enabled because that app's stream already ungated the device (§4.2).
  busy,

  /// Device node not present.
  noDevice,

  /// Some other failure starting the subprocess.
  error,
}

/// Holds the PIXY's V4L2 stream open via a subprocess so the HID control channel
/// is ungated (§4.1), and renders the live preview **inside the app**.
///
/// Two modes, one subprocess at a time:
///  - **Keepalive** (preview off): `mpv --vo=null` holds the stream with no
///    rendering — cheap, no GL.
///  - **In-app preview** (preview on): `ffmpeg` copies the camera's *native*
///    MJPG straight to a pipe; we split the concatenated JPEG frames and publish
///    the latest one on [frame], which a Flutter `Image.memory` paints. No GL /
///    media_kit / external window — Flutter's normal image path decodes the JPEG
///    (the box's GTK GL texture path crashed, hence the frame-pipe approach).
class PreviewController {
  PreviewController();

  static const String _mpv = '/usr/bin/mpv';
  static const String _ffmpeg = '/usr/bin/ffmpeg';
  static const String _setpriv = '/usr/bin/setpriv';

  /// Unique marker on our mpv keepalive so we can reap our own orphans (e.g.
  /// from a hard crash) without touching the user's other mpv instances.
  static const String _marker = 'PixyControlKeepalive';

  Process? _proc;
  StreamSubscription<List<int>>? _stdoutSub;
  bool _sweptOrphans = false;
  String? _videoNode;
  String? get videoNode => _videoNode;
  String? lastError;

  bool _inApp = false;

  /// Whether the in-app live preview is currently active.
  bool get previewOn => _inApp;

  /// Latest decoded JPEG frame for the in-app preview (null when not previewing).
  final ValueNotifier<Uint8List?> frame = ValueNotifier<Uint8List?>(null);

  /// Requested capture format (4K/2K/1080p/720p @ 30/60).
  CaptureResolution _resolution = CaptureResolution.defaultValue;
  int _fps = 30;
  CaptureResolution get resolution => _resolution;

  /// Set the capture format. Relaunches the running subprocess at the new size.
  Future<void> setFormat(CaptureResolution r, int fps) async {
    if (_resolution == r && _fps == fps) return;
    _resolution = r;
    _fps = fps;
    if (_videoNode != null) await _spawn();
  }

  PreviewState _state = PreviewState.idle;
  PreviewState get state => _state;

  /// True when control commands should be enabled — our subprocess holds the
  /// stream, OR another app already holds it (busy).
  bool get controlUngated =>
      _state == PreviewState.streaming || _state == PreviewState.busy;

  final _stateController = StreamController<PreviewState>.broadcast();
  Stream<PreviewState> get stateStream => _stateController.stream;

  void _setState(PreviewState s) {
    if (_state == s) return;
    _state = s;
    if (!_stateController.isClosed) _stateController.add(s);
  }

  /// Open [videoNode] and hold its stream (ungate control). Starts in keepalive
  /// (no preview) mode. If the node is absent → [PreviewState.noDevice].
  Future<void> open(String? videoNode) async {
    _videoNode = videoNode;
    lastError = null;
    if (videoNode == null) {
      _setState(PreviewState.noDevice);
      return;
    }
    await _sweepOrphans();
    await _spawn();
  }

  Future<void> _sweepOrphans() async {
    if (_sweptOrphans) return;
    _sweptOrphans = true;
    try {
      await Process.run('pkill', ['-f', _marker]);
    } catch (_) {}
  }

  /// Toggle the in-app live preview. Swaps the single subprocess between the
  /// mpv keepalive and the ffmpeg frame pipe (both hold the stream open).
  Future<void> setPreview(bool on) async {
    if (_inApp == on) return;
    _inApp = on;
    if (!on) frame.value = null;
    if (_videoNode != null) await _spawn();
  }

  /// (Re)launch the subprocess for the current mode.
  Future<void> _spawn() async {
    final node = _videoNode;
    if (node == null) return;
    await _killProc();
    _setState(PreviewState.opening);
    if (_inApp) {
      await _spawnFfmpeg(node);
    } else {
      await _spawnMpv(node);
    }
  }

  /// mpv keepalive: holds the stream open, no rendering (preview off).
  Future<void> _spawnMpv(String node) async {
    if (!await File(_mpv).exists()) {
      lastError = 'mpv not found at $_mpv (install the `mpv` package).';
      _setState(PreviewState.error);
      return;
    }
    final r = _resolution;
    final args = <String>[
      '--no-config',
      '--ao=null',
      '--really-quiet',
      '--force-media-title=$_marker',
      '--demuxer-lavf-o=video_size=${r.width}x${r.height},'
          'framerate=$_fps,input_format=mjpeg',
      '--vo=null',
      '--untimed',
      'av://v4l2:$node',
    ];
    await _launch(_mpv, args, node);
  }

  /// ffmpeg frame pipe: copies the camera's native MJPG to stdout; we split the
  /// JPEG frames and publish the latest on [frame] (preview on).
  Future<void> _spawnFfmpeg(String node) async {
    if (!await File(_ffmpeg).exists()) {
      lastError = 'ffmpeg not found at $_ffmpeg (install the `ffmpeg` package).';
      _setState(PreviewState.error);
      return;
    }
    final r = _resolution;
    final args = <String>[
      '-hide_banner', '-loglevel', 'error',
      '-f', 'v4l2',
      '-input_format', 'mjpeg',
      '-video_size', '${r.width}x${r.height}',
      '-framerate', '$_fps',
      '-i', node,
      '-c:v', 'copy', // pass the JPEGs through untouched — minimal CPU
      '-f', 'mjpeg',
      'pipe:1',
    ];
    final proc = await _launch(_ffmpeg, args, node, wantStdout: true);
    if (proc != null) _readJpegFrames(proc);
  }

  /// Start [exe] with [args], wrapped in setpriv pdeathsig so the kernel reaps
  /// it if the app dies. Wires early-exit → busy/noDevice. Returns the process.
  Future<Process?> _launch(String exe, List<String> args, String node,
      {bool wantStdout = false}) async {
    final useSetpriv = File(_setpriv).existsSync();
    final realExe = useSetpriv ? _setpriv : exe;
    final realArgs =
        useSetpriv ? ['--pdeathsig', 'TERM', exe, ...args] : args;

    Process proc;
    try {
      proc = await Process.start(realExe, realArgs);
    } catch (e) {
      lastError = e.toString();
      _setState(PreviewState.error);
      return null;
    }
    _proc = proc;
    proc.stderr.drain<void>().catchError((_) {});

    final pid = proc.pid;
    var exitedEarly = false;
    proc.exitCode.then((code) {
      if (_proc?.pid != pid) return; // superseded by a newer spawn
      exitedEarly = true;
      _proc = null;
      // Node still present → another app holds the single UVC stream (busy);
      // keep controls enabled and don't respawn.
      _setState(File(node).existsSync()
          ? PreviewState.busy
          : PreviewState.noDevice);
    });

    await Future<void>.delayed(const Duration(milliseconds: 700));
    if (!exitedEarly && _proc?.pid == pid) {
      _setState(PreviewState.streaming);
    }
    return exitedEarly ? null : proc;
  }

  // ---- MJPEG frame splitting -------------------------------------------------

  static const int _soi0 = 0xFF, _soi1 = 0xD8; // JPEG start-of-image
  static const int _eoi1 = 0xD9; //                JPEG end-of-image
  static const int _maxBuf = 8 * 1024 * 1024; // guard against runaway growth
  final BytesBuilder _acc = BytesBuilder(copy: false);

  void _readJpegFrames(Process proc) {
    final pid = proc.pid;
    _acc.clear();
    _stdoutSub = proc.stdout.listen((chunk) {
      if (_proc?.pid != pid) return; // superseded
      _acc.add(chunk);
      if (_acc.length > _maxBuf) _acc.clear();
      _extractFrames();
    }, onError: (_) {}, cancelOnError: false);
  }

  /// Pull every complete SOI..EOI JPEG out of the buffer; publish the latest and
  /// keep the trailing partial frame for the next chunk.
  void _extractFrames() {
    var bytes = _acc.takeBytes(); // empties the builder
    Uint8List? latest;
    var search = 0;
    var keepFrom = 0;
    while (true) {
      final soi = _indexOf2(bytes, _soi0, _soi1, search);
      if (soi < 0) break;
      final eoi = _indexOf2(bytes, _soi0, _eoi1, soi + 2);
      if (eoi < 0) {
        keepFrom = soi; // incomplete frame — keep from its start
        break;
      }
      latest = Uint8List.sublistView(bytes, soi, eoi + 2);
      search = eoi + 2;
      keepFrom = eoi + 2;
    }
    // Preserve any trailing partial frame for the next chunk.
    if (keepFrom < bytes.length) {
      _acc.add(Uint8List.sublistView(bytes, keepFrom));
    }
    if (latest != null) frame.value = Uint8List.fromList(latest);
  }

  static int _indexOf2(Uint8List b, int a0, int a1, int from) {
    for (var i = from; i + 1 < b.length; i++) {
      if (b[i] == a0 && b[i + 1] == a1) return i;
    }
    return -1;
  }

  // ---------------------------------------------------------------------------

  Future<void> _killProc() async {
    await _stdoutSub?.cancel();
    _stdoutSub = null;
    final p = _proc;
    _proc = null;
    if (p != null) {
      p.kill();
      try {
        await p.exitCode.timeout(const Duration(seconds: 1));
      } catch (_) {}
    }
  }

  Future<void> stop() async {
    await _killProc();
    _inApp = false;
    frame.value = null;
    _setState(PreviewState.idle);
  }

  Future<void> dispose() async {
    await _killProc();
    frame.dispose();
    await _stateController.close();
  }
}

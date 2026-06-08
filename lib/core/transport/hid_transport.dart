import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../protocol/frames.dart';
import 'hidapi_bindings.dart';

/// EMEET PIXY USB identifiers.
const int kPixyVendorId = 0x328f;
const int kPixyProductId = 0x00c0;

/// Thrown when a transport operation fails (open / permission / write).
class HidTransportException implements Exception {
  HidTransportException(this.message, {this.isPermission = false});
  final String message;

  /// True when the failure looks like a udev/permission issue (open returned
  /// null while the node exists) — lets the UI route to the permissions helper.
  final bool isPermission;

  @override
  String toString() => 'HidTransportException: $message';
}

/// Low-level HID channel to the PIXY: open / close / write / async read loop.
///
/// All incoming reports (solicited responses *and* async pushes) are parsed and
/// pushed onto [frames]. [request] writes a command and resolves with the first
/// matching response, while pushes continue to flow to listeners.
class HidTransport {
  HidTransport({HidApi? api}) : _api = api ?? HidApi.open() {
    _api.hidInit();
  }

  final HidApi _api;

  Pointer<HidDevice> _handle = nullptr;
  Pointer<Uint8>? _readBuf;
  Pointer<Uint8>? _writeBuf;
  Timer? _pump;

  final StreamController<PixyFrame> _frames =
      StreamController<PixyFrame>.broadcast();

  /// All parsed incoming frames (responses + async pushes).
  Stream<PixyFrame> get frames => _frames.stream;

  bool get isOpen => _handle != nullptr;

  /// hidraw path this transport opened, if discovered by path.
  String? openedPath;

  /// Open the PIXY. Tries [path] first if given, else VID/PID, else enumerates
  /// for a matching hidraw node and opens its path (covers the case where
  /// `hid_open(vid,pid)` grabs the wrong interface).
  void open({String? path}) {
    if (isOpen) return;

    if (path != null) {
      _handle = _openPath(path);
      if (isOpen) openedPath = path;
    }

    if (!isOpen) {
      _handle = _api.hidOpen(kPixyVendorId, kPixyProductId, nullptr);
    }

    if (!isOpen) {
      final p = _firstMatchingPath();
      if (p != null) {
        _handle = _openPath(p);
        if (isOpen) openedPath = p;
      }
    }

    if (!isOpen) {
      throw HidTransportException(
        'Could not open PIXY HID device. It may be unplugged or you may lack '
        'permission on its hidraw node (see the System panel).',
        isPermission: true,
      );
    }

    _readBuf = calloc<Uint8>(kFrameLength);
    _writeBuf = calloc<Uint8>(kFrameLength + 1); // +1 report-id byte
    _startPump();
  }

  Pointer<HidDevice> _openPath(String path) {
    final c = path.toNativeUtf8();
    try {
      return _api.hidOpenPath(c);
    } finally {
      calloc.free(c);
    }
  }

  /// Enumerate hidapi for the PIXY and return the first node's path.
  String? _firstMatchingPath() {
    final head = _api.hidEnumerate(kPixyVendorId, kPixyProductId);
    if (head == nullptr) return null;
    try {
      var cur = head;
      String? best;
      while (cur != nullptr) {
        final info = cur.ref;
        final p = info.path == nullptr ? '' : info.path.toDartString();
        if (p.isNotEmpty) {
          // Prefer interface 4 (the proprietary control interface) when known.
          if (info.interfaceNumber == 4) return p;
          best ??= p;
        }
        cur = info.next;
      }
      return best;
    } finally {
      _api.hidFreeEnumeration(head);
    }
  }

  /// Write a raw 32-byte frame. Prepends the unnumbered-report id byte (0x00).
  void writeRaw(Uint8List frame) {
    if (!isOpen) throw HidTransportException('Transport not open');
    final buf = _writeBuf!;
    buf[0] = 0x00; // report id for unnumbered reports
    for (var i = 0; i < kFrameLength; i++) {
      buf[1 + i] = i < frame.length ? frame[i] : 0;
    }
    final n = _api.hidWrite(_handle, buf, kFrameLength + 1);
    // A short write (0 <= n < full report) silently corrupts the frame on the
    // wire, so treat anything but the full 33-byte report as a failure.
    if (n != kFrameLength + 1) {
      throw HidTransportException('hid_write failed (wrote $n): ${_lastError()}');
    }
  }

  // Serializes [request] calls. Responses are matched only by group/sub on a
  // shared broadcast stream, so two concurrent requests with the same group/sub
  // could complete each other's completer (wrong payload to wrong caller).
  // Running requests one-at-a-time removes that race; writes stay cheap.
  Future<void> _requestChain = Future<void>.value();

  /// Write [frame] and await the first response matching [matcher] (or, by
  /// default, the same group+sub with the response bit set). Serialized against
  /// other requests. Async pushes keep flowing to [frames] regardless.
  Future<PixyFrame?> request(
    Uint8List frame, {
    bool Function(PixyFrame)? matcher,
    Duration timeout = const Duration(milliseconds: 400),
  }) {
    final result = _requestChain
        .then((_) => _runRequest(frame, matcher: matcher, timeout: timeout));
    // Keep the chain alive regardless of this request's success/failure.
    _requestChain = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<PixyFrame?> _runRequest(
    Uint8List frame, {
    bool Function(PixyFrame)? matcher,
    Duration timeout = const Duration(milliseconds: 400),
  }) async {
    if (!isOpen) throw HidTransportException('Transport not open');
    final reqGroup = frame[1] & 0x1f;
    final reqSub = frame[3];
    final match = matcher ??
        (PixyFrame f) => f.isResponse && f.group == reqGroup && f.sub == reqSub;

    final completer = Completer<PixyFrame?>();
    final sub = frames.listen((f) {
      if (!completer.isCompleted && match(f)) completer.complete(f);
    });
    try {
      writeRaw(frame);
      return await completer.future.timeout(timeout, onTimeout: () => null);
    } finally {
      await sub.cancel();
    }
  }

  // ---- read pump -------------------------------------------------------------

  void _startPump() {
    // Non-blocking drain on a timer keeps the UI isolate responsive while still
    // surfacing async pushes promptly. hid_read_timeout(.., 0) returns
    // immediately with 0 when nothing is pending. 25 ms (~40 Hz) is ample for
    // responses + pushes and reduces stream/FFI churn vs the old 8 ms.
    _pump = Timer.periodic(const Duration(milliseconds: 25), (_) => _drain());
  }

  void _drain() {
    final buf = _readBuf;
    if (buf == null || !isOpen) return;
    for (var guard = 0; guard < 32; guard++) {
      final n = _api.hidReadTimeout(_handle, buf, kFrameLength, 0);
      if (n <= 0) break; // 0 = nothing pending, <0 = error
      final bytes = Uint8List(n);
      for (var i = 0; i < n; i++) {
        bytes[i] = buf[i];
      }
      final frame = PixyFrame.parse(bytes);
      if (frame != null && !_frames.isClosed) _frames.add(frame);
    }
  }

  String _lastError() {
    if (!isOpen) return 'device closed';
    return HidApi.wcharToString(_api.hidError(_handle));
  }

  /// Close the device and release native buffers. Safe to call repeatedly.
  Future<void> close() async {
    _pump?.cancel();
    _pump = null;
    if (isOpen) {
      _api.hidClose(_handle);
      _handle = nullptr;
    }
    openedPath = null;
    final rb = _readBuf;
    if (rb != null) {
      calloc.free(rb);
      _readBuf = null;
    }
    final wb = _writeBuf;
    if (wb != null) {
      calloc.free(wb);
      _writeBuf = null;
    }
  }

  /// Permanently dispose (closes the device and the frame stream).
  Future<void> dispose() async {
    await close();
    await _frames.close();
  }
}

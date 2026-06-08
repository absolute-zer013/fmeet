import 'dart:io';

import '../core/transport/hid_transport.dart';
import '../core/v4l2/v4l2_controls.dart';

/// A discovered PIXY: its hidraw control node and the matching V4L2 video node.
class PixyDiscovery {
  const PixyDiscovery({this.hidrawPath, this.videoNode});

  /// e.g. `/dev/hidraw3` (may be null if found only via hidapi VID/PID open).
  final String? hidrawPath;

  /// e.g. `/dev/video0` for preview (null if the camera node wasn't found).
  final String? videoNode;

  bool get hasControl => hidrawPath != null;
  bool get hasVideo => videoNode != null;

  @override
  String toString() =>
      'PixyDiscovery(hidraw: $hidrawPath, video: $videoNode)';
}

/// Locates the PIXY's hidraw node and its V4L2 capture node on Linux.
///
/// hidraw: scans `/sys/class/hidraw/*/device/uevent` for the PIXY HID_ID.
/// video: parses `v4l2-ctl --list-devices`, picking the EMEET/PIXY block's
/// first capture node.
class DeviceDiscovery {
  const DeviceDiscovery();

  // HID_ID in a hidraw uevent looks like `HID_ID=0003:0000328F:000000C0`.
  static final RegExp _hidId = RegExp(
    'HID_ID=[0-9A-Fa-f]+:0*${kPixyVendorId.toRadixString(16)}:'
    '0*${kPixyProductId.toRadixString(16)}',
    caseSensitive: false,
  );

  Future<PixyDiscovery> discover() async {
    final hidraw = await _findHidraw();
    final video = await _findVideoNode();
    return PixyDiscovery(hidrawPath: hidraw, videoNode: video);
  }

  /// Whether the current user can read+write [path] (permission check).
  ///
  /// Non-destructive: a plain `FileMode.write` opens with O_TRUNC and would
  /// zero a regular file. The hidraw node is a character device, so we (a)
  /// refuse to probe anything that stats as a regular file/dir, and (b) open
  /// with `writeOnlyAppend` (O_WRONLY|O_APPEND, no O_TRUNC) to test the uaccess
  /// ACL without side effects.
  Future<bool> canAccess(String path) async {
    try {
      // Only refuse a *regular file* (the case where O_TRUNC-style opens would
      // be destructive). Dart's FileStat reports character devices — like the
      // hidraw node — as `notFound`/unclassified, NOT as a device type, so we
      // must not reject on `notFound` here: that path falls through to the
      // open, which fails harmlessly if the node is genuinely absent.
      final stat = await FileStat.stat(path);
      if (stat.type == FileSystemEntityType.file ||
          stat.type == FileSystemEntityType.directory) {
        return false;
      }
      // writeOnlyAppend = O_WRONLY|O_APPEND (no O_TRUNC) — non-destructive ACL
      // probe. Throws if the node is missing or not writable.
      final raf = await File(path).open(mode: FileMode.writeOnlyAppend);
      await raf.close();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<String?> _findHidraw() async {
    final dir = Directory('/sys/class/hidraw');
    if (!await dir.exists()) return null;
    await for (final entry in dir.list()) {
      final name = entry.path.split('/').last; // hidrawN
      final uevent = File('/sys/class/hidraw/$name/device/uevent');
      if (!await uevent.exists()) continue;
      try {
        final text = await uevent.readAsString();
        if (_hidId.hasMatch(text)) {
          return '/dev/$name';
        }
      } catch (_) {
        // unreadable; skip
      }
    }
    return null;
  }

  Future<String?> _findVideoNode() async {
    // Try v4l2-ctl --list-devices first (groups nodes by device).
    final byList = await _videoFromListDevices();
    if (byList != null) return byList;
    // Fallback: scan sysfs names.
    return _videoFromSysfs();
  }

  Future<String?> _videoFromListDevices() async {
    ProcessResult res;
    try {
      res = await Process.run(V4l2Controls.v4l2ctl, ['--list-devices']);
    } catch (_) {
      return null;
    }
    if (res.exitCode != 0) return null;
    final lines = (res.stdout as String).split('\n');
    var inPixyBlock = false;
    final candidates = <String>[];
    for (final raw in lines) {
      if (raw.trim().isEmpty) {
        continue;
      }
      final isHeader = !raw.startsWith('\t') && !raw.startsWith(' ');
      if (isHeader) {
        final lower = raw.toLowerCase();
        inPixyBlock = lower.contains('pixy') || lower.contains('emeet');
      } else if (inPixyBlock) {
        final node = raw.trim();
        if (node.startsWith('/dev/video')) candidates.add(node);
      }
    }
    // Prefer the first node that actually supports video capture. If none do,
    // return null so the sysfs fallback can try (avoid handing back a
    // metadata/non-capture node that will fail to open).
    for (final node in candidates) {
      if (await _supportsCapture(node)) return node;
    }
    return null;
  }

  Future<bool> _supportsCapture(String node) async {
    try {
      final res = await Process.run(V4l2Controls.v4l2ctl, ['-d', node, '--all']);
      final out = '${res.stdout}';
      return out.contains('Video Capture');
    } catch (_) {
      return false;
    }
  }

  Future<String?> _videoFromSysfs() async {
    final dir = Directory('/sys/class/video4linux');
    if (!await dir.exists()) return null;
    await for (final entry in dir.list()) {
      final name = entry.path.split('/').last; // videoN
      final nameFile = File('/sys/class/video4linux/$name/name');
      if (!await nameFile.exists()) continue;
      try {
        final n = (await nameFile.readAsString()).toLowerCase();
        if (n.contains('pixy') || n.contains('emeet')) {
          final dev = '/dev/$name';
          if (await _supportsCapture(dev)) return dev;
        }
      } catch (_) {}
    }
    return null;
  }
}

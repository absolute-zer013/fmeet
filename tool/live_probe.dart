// Throwaway hardware probe — exercises the real transport against a connected
// PIXY. Run with a V4L2 stream already open (stream gating, §4.1):
//   v4l2-ctl -d /dev/video0 --stream-mmap --stream-count=400 &
//   dart run tool/live_probe.dart /dev/hidraw11
import 'dart:io';

import 'package:fmeet/core/protocol/enums.dart';
import 'package:fmeet/core/transport/hid_transport.dart';
import 'package:fmeet/services/pixy_device.dart';

Future<void> main(List<String> args) async {
  final path = args.isNotEmpty ? args.first : null;
  final t = HidTransport();
  t.open(path: path);
  stdout.writeln('opened: ${t.openedPath ?? "by VID/PID"}');
  final dev = PixyDevice(transport: t);

  final serial = await dev.getSerial();
  stdout.writeln('serial:   $serial');

  final mode = await dev.getMode();
  stdout.writeln('mode:     $mode  (expect standard once a stream is open)');

  final audio = await dev.getAudioMode();
  stdout.writeln('audio:    $audio');

  final privacy = await dev.getPrivacyTimer();
  stdout.writeln('privacy:  ${privacy}s');

  final flipV = await dev.getFeature(FeatureId.flipVertical);
  final flipH = await dev.getFeature(FeatureId.flipHorizontal);
  stdout.writeln('flipV/H:  $flipV / $flipH');

  final p0 = await dev.getPosition();
  stdout.writeln('pos:      pan=${p0?.pan} tilt=${p0?.tilt}');

  final base = p0?.pan ?? 0;
  stdout.writeln('--- absolute move pan ${base + 5} then back ---');
  final r1 = await dev.moveAbsolute(MotorAxis.pan, base + 5);
  await Future<void>.delayed(const Duration(milliseconds: 600));
  final p1 = await dev.getPosition();
  stdout.writeln('after +5: pan=${p1?.pan} tilt=${p1?.tilt}  rejected=${r1.result.rejected}');

  final r2 = await dev.moveAbsolute(MotorAxis.pan, base);
  await Future<void>.delayed(const Duration(milliseconds: 600));
  final p2 = await dev.getPosition();
  stdout.writeln('after back: pan=${p2?.pan} tilt=${p2?.tilt}  rejected=${r2.result.rejected}');

  await t.dispose();
  stdout.writeln('done.');
  exit(0);
}

// Hardware probe: settle (1) whether gesture set/get works at the protocol
// level, and (2) which motor primitive actually MOVES the gimbal.
//
//   mpv --no-config --ao=null --vo=null --really-quiet av://v4l2:/dev/video0 &
//   dart run tool/ptz_gesture_probe.dart /dev/hidraw11
import 'dart:io';

import 'package:fmeet/core/protocol/enums.dart';
import 'package:fmeet/core/transport/hid_transport.dart';
import 'package:fmeet/services/pixy_device.dart';

Future<void> main(List<String> args) async {
  final path = args.isNotEmpty ? args.first : '/dev/hidraw11';
  final t = HidTransport()..open(path: path);
  final dev = PixyDevice(transport: t);
  stdout.writeln('opened ${t.openedPath}');

  // ---- gesture ----
  stdout.writeln('\n== GESTURE ==');
  stdout.writeln('get before: ${await dev.getGesture()}');
  final onAcc = await dev.setGesture(true);
  await Future<void>.delayed(const Duration(milliseconds: 200));
  stdout.writeln('set(true) accepted=$onAcc  get=${await dev.getGesture()}');
  final offAcc = await dev.setGesture(false);
  await Future<void>.delayed(const Duration(milliseconds: 200));
  stdout.writeln('set(false) accepted=$offAcc get=${await dev.getGesture()}');

  // ---- motor: velocity vs absolute ----
  stdout.writeln('\n== VELOCITY pulse (watch gimbal: should pan ~right) ==');
  dev.drive(18, 0);
  await Future<void>.delayed(const Duration(milliseconds: 700));
  dev.stopDrive();
  stdout.writeln('drove +18 deg/s for 700ms then stop');

  await Future<void>.delayed(const Duration(milliseconds: 800));
  stdout.writeln('\n== VELOCITY pulse back (should pan ~left) ==');
  dev.drive(-18, 0);
  await Future<void>.delayed(const Duration(milliseconds: 700));
  dev.stopDrive();
  stdout.writeln('drove -18 deg/s for 700ms then stop');

  await Future<void>.delayed(const Duration(milliseconds: 800));
  final p = await dev.getPosition();
  stdout.writeln('\n== ABSOLUTE (watch gimbal) pos=${p?.pan},${p?.tilt} ==');
  final r = await dev.moveAbsolute(MotorAxis.pan, (p?.pan ?? 0) + 15);
  stdout.writeln('moveAbsolute pan ${(p?.pan ?? 0) + 15} rejected=${r.result.rejected}');

  await t.dispose();
  exit(0);
}

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fmeet/core/protocol/commands.dart';
import 'package:fmeet/core/protocol/enums.dart';
import 'package:fmeet/core/protocol/frames.dart';

/// Parse a "09 03 01 19 ..." hex string into bytes, padded to 32.
Uint8List hex(String s, {int pad = kFrameLength}) {
  final parts = s
      .trim()
      .split(RegExp(r'\s+'))
      .where((p) => p.isNotEmpty)
      .map((p) => int.parse(p, radix: 16))
      .toList();
  final out = Uint8List(pad);
  for (var i = 0; i < parts.length; i++) {
    out[i] = parts[i];
  }
  return out;
}

void main() {
  group('frames', () {
    test('buildFrame lays out header, length, chunk, payload, zero-pad', () {
      final f = buildFrame([0x09, 0x03, 0x01, 0x19],
          payload: payloadOf([0x01, f32le(10.0)]));
      expect(f.length, kFrameLength);
      // 09 03 01 19 00 | len=05 00 | chunk=05 | 01 | f32(10)=00 00 20 41
      expect(f.sublist(0, 13),
          hex('09 03 01 19 00 05 00 05 01 00 00 20 41', pad: 13));
      // tail zero-padded
      expect(f.sublist(13).every((b) => b == 0), isTrue);
    });

    test('f32le encodes 10.0 little-endian', () {
      expect(f32le(10.0), Uint8List.fromList([0x00, 0x00, 0x20, 0x41]));
    });

    test('u32le encodes 900 little-endian', () {
      expect(u32le(900), Uint8List.fromList([0x84, 0x03, 0x00, 0x00]));
    });

    test('parse strips 0x60 response bit from group', () {
      // response to getMode: 09 61 01 01 ... payload [00] (standard)
      final raw = hex('09 61 01 01 00 01 00 01 00');
      final frame = PixyFrame.parse(raw)!;
      expect(frame.group, 0x01);
      expect(frame.sub, 0x01);
      expect(frame.isResponse, isTrue);
      expect(frame.u8At(0), 0x00);
    });

    test('parse decodes position floats', () {
      // 09 63 01 14 resp: u8 + f32 pan(10) + f32 tilt(-45)
      // payload: 00 | 00 00 20 41 | 00 00 34 c2
      final raw = hex('09 63 01 14 00 09 00 09 00 00 00 20 41 00 00 34 c2');
      final frame = PixyFrame.parse(raw)!;
      expect(frame.f32At(1), 10.0);
      expect(frame.f32At(5), -45.0);
    });

    test('parse rejects non-PIXY frames', () {
      expect(PixyFrame.parse(hex('00 01 02 03')), isNull);
    });
  });

  group('commands — exact wire bytes (PROTOCOL.md)', () {
    test('motorAbsolute(tilt, -45)', () {
      // 09 03 01 18 | len5 | axis2 | f32(-45)=00 00 34 c2
      expect(Commands.motorAbsolute(MotorAxis.tilt, -45.0),
          hex('09 03 01 18 00 05 00 05 02 00 00 34 c2'));
    });

    test('driveVelocity(0,0) is a stop vector (knob channel 0x63)', () {
      // 09 63 01 20 | len=12 | chunk=12 | 4 bytes pan + 4 tilt + 4 zero
      expect(Commands.driveVelocity(0, 0),
          hex('09 63 01 20 00 0c 00 0c 00 00 00 00 00 00 00 00 00 00 00 00'));
    });

    test('driveVelocity carries pan/tilt floats', () {
      final f = Commands.driveVelocity(30.0, -15.0);
      final frame = PixyFrame.parse(f)!;
      expect(frame.f32At(0), 30.0);
      expect(frame.f32At(4), -15.0);
      // trailing 4 zero bytes
      expect(frame.payload.sublist(8, 12), Uint8List.fromList([0, 0, 0, 0]));
    });

    test('getPosition() == 09 03 01 14 (no payload)', () {
      expect(Commands.getPosition(), hex('09 03 01 14 00 00 00 00'));
    });

    test('presetRead/presetWrite framing', () {
      expect(Commands.presetRead(1), hex('09 03 01 16 00 01 00 01 01'));
      // write slot 2 -> pan 12, tilt -8
      final w = PixyFrame.parse(Commands.presetWrite(2, 12.0, -8.0))!;
      expect(w.u8At(0), 2);
      expect(w.f32At(1), 12.0);
      expect(w.f32At(5), -8.0);
    });

    test('setMode / getMode / getSerial', () {
      expect(Commands.setMode(CameraMode.tracking),
          hex('09 01 01 00 00 01 00 01 01'));
      expect(Commands.getMode(), hex('09 01 01 01 00 00 00 00'));
      expect(Commands.getSerial(), hex('09 01 00 03 00 00 00 00'));
    });

    test('setFocusMetering sends 01 then 03 with same value', () {
      final frames = Commands.setFocusMetering(FocusMetering.face);
      expect(frames, hasLength(2));
      expect(frames[0], hex('09 04 00 01 00 05 00 05 01 00 00 00 00'));
      expect(frames[1], hex('09 04 00 03 00 05 00 05 01 00 00 00 00'));
    });

    test('setGesture(true) == 09 04 02 00 .. 02 01', () {
      expect(Commands.setGesture(true),
          hex('09 04 02 00 00 02 00 02 02 01'));
      expect(Commands.setGesture(false),
          hex('09 04 02 00 00 02 00 02 02 00'));
    });

    test('getGesture carries the 0x02 channel byte', () {
      expect(Commands.getGesture(), hex('09 04 02 01 00 01 00 01 02'));
    });

    test('setTracking default frame: u8 + 5 floats (0.5,0.5,1,0,0)', () {
      final frame = PixyFrame.parse(Commands.setTracking(true))!;
      expect(frame.u8At(0), 1);
      expect(frame.f32At(1), 0.5);
      expect(frame.f32At(5), 0.5);
      expect(frame.f32At(9), 1.0);
      expect(frame.f32At(13), 0.0);
      expect(frame.f32At(17), 0.0);
      expect(frame.length, 21);
    });

    test('setFeature flip-vertical on / off', () {
      expect(Commands.setFeature(FeatureId.flipVertical, true),
          hex('09 04 00 08 00 02 00 02 01 01'));
      expect(Commands.setFeature(FeatureId.flipHorizontal, false),
          hex('09 04 00 08 00 02 00 02 02 00'));
      expect(Commands.getFeature(FeatureId.autoRotateUpsideDown),
          hex('09 04 00 07 00 01 00 01 04'));
    });

    test('setAudioMode / getAudioMode', () {
      expect(Commands.setAudioMode(AudioMode.noiseCanceling),
          hex('09 05 00 03 00 01 00 01 02'));
      expect(Commands.getAudioMode(), hex('09 05 00 04 00 00 00 00'));
    });

    test('setPrivacyTimeout(900) u32 LE; Never == 0', () {
      expect(Commands.setPrivacyTimeout(900),
          hex('09 02 01 00 00 04 00 04 84 03 00 00'));
      expect(Commands.setPrivacyTimeout(PrivacyTimeout.never),
          hex('09 02 01 00 00 04 00 04 00 00 00 00'));
      expect(Commands.getPrivacyTimeout(), hex('09 02 01 01 00 00 00 00'));
    });
  });

  group('enum wire mapping', () {
    test('CameraMode round-trips', () {
      expect(CameraMode.fromWire(0), CameraMode.standard);
      expect(CameraMode.fromWire(3), CameraMode.startup);
      expect(CameraMode.fromWire(99), CameraMode.startup);
    });

    test('AudioMode / FocusMetering fromWire', () {
      expect(AudioMode.fromWire(3), AudioMode.original);
      expect(FocusMetering.fromWire(2), FocusMetering.selectedArea);
    });
  });
}

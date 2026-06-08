import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fmeet/core/protocol/enums.dart';
import 'package:fmeet/core/protocol/frames.dart';
import 'package:fmeet/core/stream/capture_resolution.dart';
import 'package:fmeet/core/v4l2/v4l2_controls.dart';

void main() {
  group('CaptureResolution', () {
    test('fromKey resolves + round-trips, falls back to 1080p', () {
      expect(CaptureResolution.fromKey('2560x1440'), CaptureResolution.qhd2k);
      expect(CaptureResolution.fromKey(null), CaptureResolution.fhd1080);
      expect(CaptureResolution.fromKey('garbage'), CaptureResolution.fhd1080);
      for (final r in CaptureResolution.values) {
        expect(CaptureResolution.fromKey(r.key), r);
      }
    });

    test('zoom gated to non-4K; 60fps only at 1080p/720p', () {
      expect(CaptureResolution.uhd4k.zoomCapable, isFalse);
      expect(CaptureResolution.qhd2k.zoomCapable, isTrue);
      expect(CaptureResolution.fhd1080.zoomCapable, isTrue);
      expect(CaptureResolution.uhd4k.supports60, isFalse);
      expect(CaptureResolution.qhd2k.supports60, isFalse);
      expect(CaptureResolution.fhd1080.supports60, isTrue);
      expect(CaptureResolution.hd720.supports60, isTrue);
    });
  });

  group('buildFrame guards', () {
    test('rejects non-4-byte header', () {
      expect(() => buildFrame([0x09]), throwsArgumentError);
      expect(() => buildFrame([0x09, 0x03, 0x01, 0x18, 0x00]), throwsArgumentError);
    });

    test('rejects oversized payload', () {
      final tooLong = List.filled(kMaxPayload + 1, 0);
      expect(() => buildFrame([0x09, 0x03, 0x01, 0x18], payload: tooLong),
          throwsArgumentError);
    });

    test('payloadOf rejects non int/List parts', () {
      expect(() => payloadOf(['nope']), throwsArgumentError);
    });
  });

  group('enum fromWire fallbacks', () {
    test('unknown values fall back', () {
      expect(CameraMode.fromWire(99), CameraMode.startup);
      expect(AudioMode.fromWire(99), AudioMode.live);
      expect(FocusMetering.fromWire(99), FocusMetering.central);
    });
  });

  group('PixyFrame.parse bounds', () {
    PixyFrame? p(List<int> b) => PixyFrame.parse(Uint8List.fromList(b));

    test('rejects short / non-PIXY frames', () {
      expect(p([0x09, 0, 0, 0]), isNull); // < 8 bytes
      expect(p([0x00, 0, 0, 0, 0, 0, 0, 0]), isNull); // wrong report id
    });

    test('declared length larger than available is truncated, not thrown', () {
      // length = 0xFF (255) but only 2 payload bytes available.
      final f = p([0x09, 0x03, 0x01, 0x14, 0x00, 0xFF, 0x00, 0x00, 0xAB, 0xCD]);
      expect(f, isNotNull);
      expect(f!.length, 0xFF);
      expect(f.payload.length, 2); // clamped to available
    });

    test('zero-length payload', () {
      final f = p([0x09, 0x03, 0x01, 0x14, 0x00, 0x00, 0x00, 0x00]);
      expect(f!.payload, isEmpty);
    });

    test('out-of-range accessors return 0 instead of throwing', () {
      final f = p([0x09, 0x03, 0x01, 0x14, 0x00, 0x00, 0x00, 0x00])!;
      expect(f.f32At(99), 0.0);
      expect(f.u32At(99), 0);
      expect(f.u8At(99), 0);
    });
  });

  group('V4l2Controls.set/get guards', () {
    final v = V4l2Controls('/dev/null'); // no controls enumerated

    test('rejects names failing the identifier regex (no process spawn)', () async {
      expect(await v.set('focus_absolute,brightness', 1), isFalse);
      expect(await v.set('x=0,focus', 1), isFalse);
      expect(await v.set('', 1), isFalse);
      expect(await v.get('bad name'), isNull);
    });

    test('rejects valid-syntax but never-enumerated control', () async {
      expect(await v.set('brightness', 128), isFalse); // not in empty _controls
    });
  });
}

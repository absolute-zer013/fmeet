import 'dart:typed_data';

/// 32-byte HID frame encode/decode for the PIXY protocol.
///
/// Layout (PROTOCOL.md §"Frame format"):
/// ```
/// byte 0      0x09        constant
/// byte 1      group       response echoes group OR'd with 0x60
/// byte 2      channel     0x00 system, 0x01 main/gimbal, 0x02 AI-cam/async
/// byte 3      sub         sub-command
/// byte 4      0x00
/// bytes 5-6   length      total payload length, little-endian u16
/// byte 7      chunk       payload bytes in this report
/// bytes 8+    payload
/// ```
/// Status `0x20` = OK, `0x40` = rejected. Floats are LE f32 in degrees.

/// Total length of a single HID report for the PIXY (interface 4).
const int kFrameLength = 32;

/// Response group bit — the camera echoes the request group OR'd with this.
const int kResponseGroupBit = 0x60;

/// Status bytes seen in responses.
const int kStatusOk = 0x20;
const int kStatusRejected = 0x40;

/// Build a raw 32-byte frame from its fields. Payload is copied verbatim and
/// the report is zero-padded to [kFrameLength].
///
/// [header] is the literal first four bytes `[0x09, group, channel, sub]`. Some
/// commands send the group with the 0x60 bit already set (e.g. the velocity
/// knob channel `09 63 01 20`), so callers pass the exact header they want on
/// the wire rather than having it derived.
/// Max single-report payload bytes (32 - 8-byte header region).
const int kMaxPayload = kFrameLength - 8;

Uint8List buildFrame(List<int> header, {List<int> payload = const []}) {
  // Hard runtime checks (not asserts): asserts are stripped in release builds,
  // and payload can originate from user input (debug raw-send box).
  if (header.length != 4) {
    throw ArgumentError.value(
        header, 'header', 'must be exactly [0x09, group, channel, sub]');
  }
  if (payload.length > kMaxPayload) {
    throw ArgumentError.value(payload.length, 'payload.length',
        'too long for one report (max $kMaxPayload bytes)');
  }

  final frame = Uint8List(kFrameLength);
  frame[0] = header[0];
  frame[1] = header[1];
  frame[2] = header[2];
  frame[3] = header[3];
  frame[4] = 0x00;

  final len = payload.length;
  frame[5] = len & 0xff;
  frame[6] = (len >> 8) & 0xff;
  frame[7] = len & 0xff; // single-report: chunk == length

  for (var i = 0; i < payload.length; i++) {
    frame[8 + i] = payload[i] & 0xff;
  }
  return frame;
}

/// Encode an LE f32 to 4 bytes.
Uint8List f32le(double value) {
  final b = ByteData(4)..setFloat32(0, value, Endian.little);
  return b.buffer.asUint8List();
}

/// Encode an LE u32 to 4 bytes.
Uint8List u32le(int value) {
  final b = ByteData(4)..setUint32(0, value, Endian.little);
  return b.buffer.asUint8List();
}

/// Convenience: assemble a payload from a mix of ints (single bytes) and
/// pre-encoded byte lists, in order.
List<int> payloadOf(List<Object> parts) {
  final out = <int>[];
  for (final p in parts) {
    if (p is int) {
      out.add(p & 0xff);
    } else if (p is List<int>) {
      out.addAll(p);
    } else {
      throw ArgumentError('payload part must be int or List<int>, got $p');
    }
  }
  return out;
}

/// A parsed HID frame coming back from the device (or an async push).
class PixyFrame {
  PixyFrame({
    required this.raw,
    required this.group,
    required this.channel,
    required this.sub,
    required this.length,
    required this.payload,
  });

  /// The full raw report as received.
  final Uint8List raw;

  /// Group with the 0x60 response bit stripped (matches request group).
  final int group;
  final int channel;
  final int sub;
  final int length;
  final Uint8List payload;

  /// True if byte 1 had the 0x60 response bit set (solicited response or push).
  bool get isResponse => (raw.length > 1) && (raw[1] & kResponseGroupBit) != 0;

  /// Status byte (first payload byte is not the status; status lives at byte 8
  /// only for some commands). Many frames carry the value directly. Callers
  /// that care about OK/reject inspect [payload] per the command contract.

  /// Parse a received report. Returns null if it is not a PIXY frame.
  static PixyFrame? parse(Uint8List raw) {
    if (raw.length < 8 || raw[0] != 0x09) return null;
    final group = raw[1] & 0x1f; // strip response/knob high bits
    final channel = raw[2];
    final sub = raw[3];
    final length = raw[5] | (raw[6] << 8);
    final avail = raw.length - 8;
    final take = length < avail ? length : avail;
    final payload = Uint8List.sublistView(raw, 8, 8 + (take < 0 ? 0 : take));
    return PixyFrame(
      raw: raw,
      group: group,
      channel: channel,
      sub: sub,
      length: length,
      payload: payload,
    );
  }

  /// Decode an LE f32 from the payload at [offset].
  double f32At(int offset) =>
      ByteData.sublistView(payload).getFloat32(offset, Endian.little);

  /// Decode an LE u32 from the payload at [offset].
  int u32At(int offset) =>
      ByteData.sublistView(payload).getUint32(offset, Endian.little);

  int u8At(int offset) => payload[offset];

  @override
  String toString() {
    final hdr = raw
        .take(4)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join(' ');
    final pl = payload
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join(' ');
    return 'PixyFrame($hdr len=$length payload=[${pl.isEmpty ? '-' : pl}])';
  }
}

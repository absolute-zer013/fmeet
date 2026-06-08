import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// Minimal hand-written FFI bindings for `libhidapi-hidraw.so` (hidapi).
///
/// Only the handful of entry points PixyControl needs are bound. Hand-written
/// rather than ffigen-generated to avoid the analyzer/macros dependency clash
/// in the current Flutter toolchain; the surface is tiny and stable.
///
/// Arch package: `hidapi` → `/usr/lib/libhidapi-hidraw.so`.

/// Opaque hidapi device handle.
final class HidDevice extends Opaque {}

/// `struct hid_device_info` — enough fields to discover the PIXY's hidraw path.
///
/// Layout must match hidapi's header exactly. Fields we don't use are still
/// declared so member offsets line up.
final class HidDeviceInfo extends Struct {
  external Pointer<Utf8> path; // char*
  @Uint16()
  external int vendorId;
  @Uint16()
  external int productId;
  external Pointer<Uint16> serialNumber; // wchar_t*
  @Uint16()
  external int releaseNumber;
  external Pointer<Uint16> manufacturerString;
  external Pointer<Uint16> productString;
  @Uint16()
  external int usagePage;
  @Uint16()
  external int usage;
  @Int32()
  external int interfaceNumber;
  external Pointer<HidDeviceInfo> next;
}

// ---- native + dart signatures -------------------------------------------------

typedef HidInitNative = Int32 Function();
typedef HidInitDart = int Function();

typedef HidExitNative = Int32 Function();
typedef HidExitDart = int Function();

typedef HidOpenNative = Pointer<HidDevice> Function(
    Uint16 vendorId, Uint16 productId, Pointer<Uint16> serial);
typedef HidOpenDart = Pointer<HidDevice> Function(
    int vendorId, int productId, Pointer<Uint16> serial);

typedef HidOpenPathNative = Pointer<HidDevice> Function(Pointer<Utf8> path);
typedef HidOpenPathDart = Pointer<HidDevice> Function(Pointer<Utf8> path);

typedef HidWriteNative = IntPtr Function(
    Pointer<HidDevice> dev, Pointer<Uint8> data, IntPtr length);
typedef HidWriteDart = int Function(
    Pointer<HidDevice> dev, Pointer<Uint8> data, int length);

typedef HidReadTimeoutNative = IntPtr Function(
    Pointer<HidDevice> dev, Pointer<Uint8> data, IntPtr length, Int32 ms);
typedef HidReadTimeoutDart = int Function(
    Pointer<HidDevice> dev, Pointer<Uint8> data, int length, int ms);

typedef HidCloseNative = Void Function(Pointer<HidDevice> dev);
typedef HidCloseDart = void Function(Pointer<HidDevice> dev);

typedef HidErrorNative = Pointer<Uint16> Function(Pointer<HidDevice> dev);
typedef HidErrorDart = Pointer<Uint16> Function(Pointer<HidDevice> dev);

typedef HidEnumerateNative = Pointer<HidDeviceInfo> Function(
    Uint16 vendorId, Uint16 productId);
typedef HidEnumerateDart = Pointer<HidDeviceInfo> Function(
    int vendorId, int productId);

typedef HidFreeEnumerationNative = Void Function(Pointer<HidDeviceInfo> devs);
typedef HidFreeEnumerationDart = void Function(Pointer<HidDeviceInfo> devs);

/// Thin resolved-symbol wrapper over the hidapi shared library.
class HidApi {
  HidApi._({
    required this.hidInit,
    required this.hidExit,
    required this.hidOpen,
    required this.hidOpenPath,
    required this.hidWrite,
    required this.hidReadTimeout,
    required this.hidClose,
    required this.hidError,
    required this.hidEnumerate,
    required this.hidFreeEnumeration,
  });

  final HidInitDart hidInit;
  final HidExitDart hidExit;
  final HidOpenDart hidOpen;
  final HidOpenPathDart hidOpenPath;
  final HidWriteDart hidWrite;
  final HidReadTimeoutDart hidReadTimeout;
  final HidCloseDart hidClose;
  final HidErrorDart hidError;
  final HidEnumerateDart hidEnumerate;
  final HidFreeEnumerationDart hidFreeEnumeration;

  /// Candidate sonames in preference order (hidraw backend first).
  static const List<String> _candidates = [
    'libhidapi-hidraw.so',
    'libhidapi-hidraw.so.0',
    'libhidapi.so',
    'libhidapi-libusb.so',
    'libhidapi-libusb.so.0',
  ];

  /// Open the hidapi shared library, trying known sonames.
  factory HidApi.open() {
    Object? lastError;
    for (final name in _candidates) {
      try {
        final lib = DynamicLibrary.open(name);
        return HidApi._(
          hidInit: lib.lookupFunction<HidInitNative, HidInitDart>('hid_init'),
          hidExit: lib.lookupFunction<HidExitNative, HidExitDart>('hid_exit'),
          hidOpen: lib.lookupFunction<HidOpenNative, HidOpenDart>('hid_open'),
          hidOpenPath: lib
              .lookupFunction<HidOpenPathNative, HidOpenPathDart>('hid_open_path'),
          hidWrite:
              lib.lookupFunction<HidWriteNative, HidWriteDart>('hid_write'),
          hidReadTimeout: lib
              .lookupFunction<HidReadTimeoutNative, HidReadTimeoutDart>(
                  'hid_read_timeout'),
          hidClose:
              lib.lookupFunction<HidCloseNative, HidCloseDart>('hid_close'),
          hidError:
              lib.lookupFunction<HidErrorNative, HidErrorDart>('hid_error'),
          hidEnumerate: lib
              .lookupFunction<HidEnumerateNative, HidEnumerateDart>(
                  'hid_enumerate'),
          hidFreeEnumeration: lib.lookupFunction<HidFreeEnumerationNative,
              HidFreeEnumerationDart>('hid_free_enumeration'),
        );
      } catch (e) {
        lastError = e;
      }
    }
    throw StateError(
        'Could not load hidapi (tried $_candidates). Install the `hidapi` '
        'package. Last error: $lastError');
  }

  /// Decode a hidapi wchar_t* (UTF-32 on Linux) into a Dart string.
  static String wcharToString(Pointer<Uint16> ptr) {
    if (ptr == nullptr) return '';
    final units = <int>[];
    var i = 0;
    while (true) {
      final c = (ptr + i).value;
      if (c == 0) break;
      units.add(c);
      i++;
      if (i > 1024) break; // safety bound
    }
    return String.fromCharCodes(units);
  }
}

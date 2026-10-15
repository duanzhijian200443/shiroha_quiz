import 'dart:ffi';
import 'dart:typed_data';

import 'external_native_bindings.dart';
import 'windows_external_native.dart';

/// Caller-owned copies. Native storage is wiped; dispose of Dart private bytes
/// after bounded use. No guarantee is made about additional GC copies.
final class ExternalP256KeyPair {
  ExternalP256KeyPair(this.pkcs8Der, this.publicPoint);
  final Uint8List pkcs8Der, publicPoint;
  void clearPrivateKey() => pkcs8Der.fillRange(0, pkcs8Der.length, 0);
  @override
  String toString() => 'ExternalP256KeyPair(REDACTED)';
}

/// Explicit, inactive infrastructure primitive. No store or runtime wiring.
/// Real operations need a separate G0-L1 grant; tests inject fake calls only.
final class WindowsExternalCrypto {
  WindowsExternalCrypto._(this._memory, this._crypto);
  factory WindowsExternalCrypto.fromCalls(ExternalNativeCalls calls) {
    if (calls is! ExternalNativeCryptoCalls) {
      _fail(ExternalNativeFailure.libraryUnavailable);
    }
    return WindowsExternalCrypto._(calls, calls as ExternalNativeCryptoCalls);
  }
  final ExternalNativeCalls _memory;
  final ExternalNativeCryptoCalls _crypto;

  ExternalP256KeyPair generateKey() => _buffers([256, 65, 16], (b) {
        final keyCount = b[2].cast<Uint64>();
        final pointCount = (b[2] + 8).cast<Uint64>();
        _status(
            _crypto.generateKey(3, b[0], 256, keyCount, b[1], 65, pointCount));
        if (keyCount.value < 1 ||
            keyCount.value > 256 ||
            pointCount.value != 65 ||
            b[1].value != 4) {
          _fail(ExternalNativeFailure.invalidNativeResult);
        }
        return ExternalP256KeyPair(
            Uint8List.fromList(b[0].asTypedList(keyCount.value)),
            Uint8List.fromList(b[1].asTypedList(65)));
      });

  Uint8List signDigest(
      {required Uint8List pkcs8Der,
      required Uint8List publicPoint,
      required Uint8List digest}) {
    _point(publicPoint);
    if (pkcs8Der.isEmpty || pkcs8Der.length > 256 || digest.length != 32) {
      _fail(ExternalNativeFailure.invalidInput);
    }
    return _buffers([pkcs8Der.length, 65, 32, 64, 8], (b) {
      b[0].asTypedList(pkcs8Der.length).setAll(0, pkcs8Der);
      b[1].asTypedList(65).setAll(0, publicPoint);
      b[2].asTypedList(32).setAll(0, digest);
      final count = b[4].cast<Uint64>();
      _status(_crypto.signDigest(
          3, b[0], pkcs8Der.length, b[1], 65, b[2], 32, b[3], 64, count));
      if (count.value != 64) _fail(ExternalNativeFailure.invalidNativeResult);
      return Uint8List.fromList(b[3].asTypedList(64));
    });
  }

  /// Explicit signature mismatch throws verificationRejected; malformed/native
  /// failures remain distinct. Success supplies no Principal or trust evidence.
  void verifyDigest(
      {required Uint8List publicPoint,
      required Uint8List digest,
      required Uint8List rawSignature}) {
    _point(publicPoint);
    if (digest.length != 32 || rawSignature.length != 64) {
      _fail(ExternalNativeFailure.invalidInput);
    }
    _buffers<void>([65, 32, 64], (b) {
      b[0].asTypedList(65).setAll(0, publicPoint);
      b[1].asTypedList(32).setAll(0, digest);
      b[2].asTypedList(64).setAll(0, rawSignature);
      _status(_crypto.verifyDigest(3, b[0], 65, b[1], 32, b[2], 64));
    });
  }

  T _buffers<T>(List<int> lengths, T Function(List<Pointer<Uint8>>) invoke) {
    final buffers = <Pointer<Uint8>>[];
    try {
      if (_memory.abiVersion() != 3) _fail(ExternalNativeFailure.abiMismatch);
      for (final length in lengths) {
        final buffer = _memory.allocate(length);
        if (buffer == nullptr) _fail(ExternalNativeFailure.resourceLimit);
        // Caller records every allocation before the first subsequent operation.
        buffers.add(buffer);
        buffer.asTypedList(length).fillRange(0, length, 0);
      }
      return invoke(buffers);
    } on ExternalNativeException {
      rethrow;
    } on ArgumentError {
      // A missing optional native symbol is an older helper, never fallback.
      _fail(ExternalNativeFailure.libraryUnavailable);
    } catch (_) {
      _fail(ExternalNativeFailure.temporarilyUnavailable);
    } finally {
      var failed = false;
      for (var i = buffers.length - 1; i >= 0; i--) {
        try {
          buffers[i].asTypedList(lengths[i]).fillRange(0, lengths[i], 0);
          _memory.free(buffers[i]);
        } catch (_) {
          failed = true;
        }
      }
      if (failed) _fail(ExternalNativeFailure.temporarilyUnavailable);
    }
  }

  static void _point(Uint8List bytes) {
    if (bytes.length != 65 || bytes[0] != 4) {
      _fail(ExternalNativeFailure.invalidInput);
    }
  }

  static void _status(int status) {
    if (status == 0) return;
    _fail(switch (status) {
      1 => ExternalNativeFailure.invalidInput,
      2 => ExternalNativeFailure.abiMismatch,
      3 => ExternalNativeFailure.resourceLimit,
      4 => ExternalNativeFailure.temporarilyUnavailable,
      5 => ExternalNativeFailure.dataCorrupt,
      8 => ExternalNativeFailure.verificationRejected,
      _ => ExternalNativeFailure.invalidNativeResult,
    });
  }

  static Never _fail(ExternalNativeFailure failure) =>
      throw ExternalNativeException(failure);
}

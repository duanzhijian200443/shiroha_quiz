import 'dart:ffi';
import 'dart:typed_data';

import 'external_native_bindings.dart';
import 'windows_external_native.dart';

enum TlsPeerRole { server, client }

/// Explicit crypt32 policy operation. No helper is loaded by construction.
/// L0 uses injected calls; real execution requires its separate L1/L2 grant.
final class WindowsPeerCertificatePolicy {
  WindowsPeerCertificatePolicy(this._calls);
  final ExternalNativeCalls _calls;

  void check(Uint8List der, TlsPeerRole role) {
    if (der.isEmpty || der.length > 16384) {
      throw const ExternalNativeException(ExternalNativeFailure.invalidInput);
    }
    Pointer<Uint8> buffer = nullptr;
    try {
      if (_calls.abiVersion() != 3) {
        throw const ExternalNativeException(ExternalNativeFailure.abiMismatch);
      }
      if (_calls is! ExternalNativePeerPolicyCalls) {
        throw const ExternalNativeException(
            ExternalNativeFailure.libraryUnavailable);
      }
      buffer = _calls.allocate(der.length);
      if (buffer == nullptr) {
        throw const ExternalNativeException(
            ExternalNativeFailure.resourceLimit);
      }
      buffer.asTypedList(der.length).setAll(0, der);
      final status = (_calls as ExternalNativePeerPolicyCalls)
          .peerCertificatePolicy(3, buffer, der.length, role.index + 1);
      if (status != 0) {
        throw ExternalNativeException(switch (status) {
          1 => ExternalNativeFailure.invalidInput,
          2 => ExternalNativeFailure.abiMismatch,
          3 => ExternalNativeFailure.resourceLimit,
          4 => ExternalNativeFailure.temporarilyUnavailable,
          8 => ExternalNativeFailure.verificationRejected,
          _ => ExternalNativeFailure.invalidNativeResult,
        });
      }
    } on ExternalNativeException {
      rethrow;
    } on ArgumentError {
      throw const ExternalNativeException(
          ExternalNativeFailure.libraryUnavailable);
    } catch (_) {
      throw const ExternalNativeException(
          ExternalNativeFailure.temporarilyUnavailable);
    } finally {
      if (buffer != nullptr) {
        try {
          buffer.asTypedList(der.length).fillRange(0, der.length, 0);
          _calls.free(buffer);
        } catch (_) {
          throw const ExternalNativeException(
              ExternalNativeFailure.temporarilyUnavailable);
        }
      }
    }
  }
}

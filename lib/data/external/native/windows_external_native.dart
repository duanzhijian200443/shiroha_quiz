import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import 'external_native_bindings.dart';

enum ExternalNativeFailure {
  unsupportedPlatform,
  libraryUnavailable,
  abiMismatch,
  invalidInput,
  resourceLimit,
  temporarilyUnavailable,
  dataCorrupt,
  invalidNativeResult,
}

/// Local infrastructure failures only; never expose loader/OS exception text.
final class ExternalNativeException implements Exception {
  const ExternalNativeException(this.failure);
  final ExternalNativeFailure failure;
  @override
  String toString() => 'ExternalNativeException(${failure.name})';
}

/// OS-resolved path only. No owner, DACL, volume or reparse validation is implied.
final class ExternalLocalAppDataPath {
  const ExternalLocalAppDataPath._(this.value);
  final String value;
  @override
  String toString() => 'ExternalLocalAppDataPath(REDACTED)';
}

/// Explicitly opened primitive adapter, shared by future App and AOT composition.
/// It performs no persistence, trust recovery, session creation or Host wiring.
final class WindowsExternalNative {
  WindowsExternalNative._(this._calls);
  static const abiVersion = 1;
  static const maxBytes = 65536;
  static const libraryName = 'shiroha_external_native.dll';
  final ExternalNativeCalls _calls;

  static WindowsExternalNative open() => _open(
        windows: Platform.isWindows,
        executable: Platform.resolvedExecutable,
        exists: (path) => File(path).existsSync(),
        load: (path) => FfiExternalNativeCalls(DynamicLibrary.open(path)),
      );

  @visibleForTesting
  static WindowsExternalNative openForTesting({
    required bool windows,
    required String executable,
    required bool Function(String) exists,
    required ExternalNativeCalls Function(String) load,
  }) =>
      _open(
          windows: windows, executable: executable, exists: exists, load: load);

  static WindowsExternalNative _open({
    required bool windows,
    required String executable,
    required bool Function(String) exists,
    required ExternalNativeCalls Function(String) load,
  }) {
    if (!windows) _fail(ExternalNativeFailure.unsupportedPlatform);
    final context = p.Context(style: p.Style.windows);
    // The only production source is resolvedExecutable. No PATH, environment,
    // working directory, caller-selected root or alternate location is searched.
    if (!context.isAbsolute(executable)) {
      _fail(ExternalNativeFailure.libraryUnavailable);
    }
    final path = context.join(context.dirname(executable), libraryName);
    try {
      if (!exists(path)) _fail(ExternalNativeFailure.libraryUnavailable);
      final adapter = WindowsExternalNative._(load(path));
      adapter._checkAbi();
      return adapter;
    } on ExternalNativeException {
      rethrow;
    } catch (_) {
      _fail(ExternalNativeFailure.libraryUnavailable);
    }
  }

  void _checkAbi() {
    if (_calls.abiVersion() != abiVersion) {
      _fail(ExternalNativeFailure.abiMismatch);
    }
  }

  /// Caller owns the returned Dart copy; native storage is wiped and freed.
  /// The caller must dispose of sensitive Dart bytes after its bounded use.
  Uint8List protect(Uint8List plaintext) => _transform(plaintext, false);
  Uint8List unprotect(Uint8List blob) => _transform(blob, true);

  Uint8List _transform(Uint8List input, bool decrypt) {
    if (input.isEmpty || input.length > maxBytes) {
      _fail(ExternalNativeFailure.invalidInput);
    }
    return _invoke(
        input,
        (source, output, written) => decrypt
            ? _calls.unprotect(
                abiVersion, source, input.length, output, maxBytes, written)
            : _calls.protect(
                abiVersion, source, input.length, output, maxBytes, written));
  }

  ExternalLocalAppDataPath resolveLocalAppData() {
    final bytes = _invoke(
        null,
        (source, output, written) =>
            _calls.localAppData(abiVersion, output, maxBytes, written));
    if (bytes.length.isOdd) _fail(ExternalNativeFailure.invalidNativeResult);
    final units = <int>[];
    final data = ByteData.sublistView(bytes);
    for (var i = 0; i < bytes.length; i += 2) {
      final unit = data.getUint16(i, Endian.little);
      if (unit == 0) _fail(ExternalNativeFailure.invalidNativeResult);
      units.add(unit);
    }
    for (var i = 0; i < units.length; i++) {
      final unit = units[i];
      if (unit >= 0xd800 && unit <= 0xdbff) {
        if (++i >= units.length || units[i] < 0xdc00 || units[i] > 0xdfff) {
          _fail(ExternalNativeFailure.invalidNativeResult);
        }
      } else if (unit >= 0xdc00 && unit <= 0xdfff) {
        _fail(ExternalNativeFailure.invalidNativeResult);
      }
    }
    final value = String.fromCharCodes(units);
    if (!p.Context(style: p.Style.windows).isAbsolute(value)) {
      _fail(ExternalNativeFailure.invalidNativeResult);
    }
    return ExternalLocalAppDataPath._(value);
  }

  Uint8List _invoke(Uint8List? input,
      int Function(Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint64>) operation) {
    Pointer<Uint8> source = nullptr, output = nullptr, count = nullptr;
    _checkAbi(); // Every operation checks before even allocating native storage.
    try {
      if (input != null) {
        source = _allocate(input.length);
        source.asTypedList(input.length).setAll(0, input);
      }
      output = _allocate(maxBytes);
      count = _allocate(sizeOf<Uint64>());
      final written = count.cast<Uint64>();
      written.value = 0;
      final status = operation(source, output, written);
      _checkStatus(status);
      final length = written.value;
      if (length <= 0 || length > maxBytes) {
        _fail(ExternalNativeFailure.invalidNativeResult);
      }
      return Uint8List.fromList(output.asTypedList(length));
    } on ExternalNativeException {
      rethrow;
    } catch (_) {
      _fail(ExternalNativeFailure.temporarilyUnavailable);
    } finally {
      // Helper owns the allocator, allocation sizes and SecureZeroMemory/free.
      // Nested finally keeps all releases reachable if a test seam throws.
      try {
        if (count != nullptr) _calls.free(count);
      } finally {
        try {
          if (output != nullptr) _calls.free(output);
        } finally {
          if (source != nullptr) _calls.free(source);
        }
      }
    }
  }

  Pointer<Uint8> _allocate(int capacity) {
    final result = _calls.allocate(capacity);
    if (result == nullptr) _fail(ExternalNativeFailure.resourceLimit);
    return result;
  }

  static void _checkStatus(int status) {
    switch (status) {
      case 0:
        return;
      case 1:
        _fail(ExternalNativeFailure.invalidInput);
      case 2:
        _fail(ExternalNativeFailure.abiMismatch);
      case 3:
        _fail(ExternalNativeFailure.resourceLimit);
      case 4:
        _fail(ExternalNativeFailure.temporarilyUnavailable);
      case 5:
        _fail(ExternalNativeFailure.dataCorrupt);
      default:
        _fail(ExternalNativeFailure.invalidNativeResult);
    }
  }

  static Never _fail(ExternalNativeFailure failure) =>
      throw ExternalNativeException(failure);
}

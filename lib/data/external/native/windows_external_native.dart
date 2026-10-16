import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import 'external_native_bindings.dart';
import 'windows_external_crypto.dart';

enum ExternalNativeFailure {
  unsupportedPlatform,
  libraryUnavailable,
  abiMismatch,
  invalidInput,
  resourceLimit,
  temporarilyUnavailable,
  dataCorrupt,
  invalidNativeResult,
  commitUnknown,
  verificationRejected,
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
  static const abiVersion = 3;
  static const maxBytes = 65536;
  static const libraryName = 'shiroha_external_native.dll';
  final ExternalNativeCalls _calls;

  WindowsExternalCrypto get crypto => WindowsExternalCrypto.fromCalls(_calls);

  /// Explicit acquisition only. The returned owner retains the real OS lock
  /// across asynchronous work until its caller explicitly closes it.
  ExternalProtectedObjects acquireAppObjects() => _acquireOwner(1);
  ExternalProtectedObjects acquireBridgeObjects() => _acquireOwner(2);

  ExternalProtectedObjects _acquireOwner(int role) {
    _checkAbi();
    Pointer<Uint8> output = nullptr;
    var token = 0;
    try {
      output = _allocate(sizeOf<Uint64>());
      final result = output.cast<Uint64>();
      result.value = 0;
      final status = _calls.acquireOwner(abiVersion, role, result);
      token = result.value;
      _checkStatus(status);
      if (token <= 0) _fail(ExternalNativeFailure.invalidNativeResult);
      // Free before ownership transfer. An allocation-release exception cannot
      // strand an OS owner behind an unsuccessful Dart return.
      final released = output;
      output = nullptr;
      _calls.free(released);
      final owner = ExternalProtectedObjects._(this, token, role);
      token = 0;
      return owner;
    } on ExternalNativeException {
      rethrow;
    } catch (_) {
      _fail(ExternalNativeFailure.temporarilyUnavailable);
    } finally {
      var cleanupFailed = false;
      try {
        // A throwing fake/native boundary may have populated the result first.
        if (output != nullptr && token == 0) {
          token = output.cast<Uint64>().value;
        }
        if (token > 0 && _calls.closeOwner(abiVersion, token) != 0) {
          cleanupFailed = true;
        }
      } catch (_) {
        cleanupFailed = true;
      } finally {
        try {
          if (output != nullptr) _calls.free(output);
        } catch (_) {
          cleanupFailed = true;
        }
      }
      if (cleanupFailed) _fail(ExternalNativeFailure.temporarilyUnavailable);
    }
  }

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

/// Infrastructure ownership only. No paths, native handles or token constructor
/// escape this adapter. Close after the owning caller has drained all work;
/// completing a Future never releases the lock automatically.
final class ExternalProtectedObjects {
  ExternalProtectedObjects._(this._adapter, this._token, this._role);
  final WindowsExternalNative _adapter;
  final int _token;
  final int _role;
  bool _closed = false, _denied = false;
  bool _runtimeClaimed = false;
  int _associationEpoch = 0;
  final Map<String, int> _associationRevisions = {};
  bool get isClosed => _closed;
  int get associationEpoch => _associationEpoch;
  bool get isUsable => !_closed && !_denied;

  /// One Host may claim this already-held App lock. Sharing one Dart Owner
  /// between two candidate Hosts must not bypass OS acquisition exclusion.
  /// This creates no lock or authorization and can never be reset/reused.
  void claimRuntime() {
    ensureOpen();
    if (_role != 1 || _runtimeClaimed) {
      WindowsExternalNative._fail(ExternalNativeFailure.temporarilyUnavailable);
    }
    _runtimeClaimed = true;
  }

  void invalidateAssociationSnapshots() {
    _associationEpoch++;
  }

  /// Rejection-only high-water marks shared across stores on this OS owner.
  /// They never provide file bytes or a record snapshot.
  void observeAssociationRevisions(Map<String, int> revisions) {
    if (revisions.length > 64 ||
        revisions.values.any((r) => r < 1 || r > 2147483647)) {
      _associationEpoch++;
      WindowsExternalNative._fail(ExternalNativeFailure.dataCorrupt);
    }
    for (final old in _associationRevisions.entries) {
      if ((revisions[old.key] ?? 0) < old.value) {
        _associationEpoch++;
        WindowsExternalNative._fail(ExternalNativeFailure.dataCorrupt);
      }
    }
    _associationRevisions.addAll(revisions);
  }

  Uint8List protectAssociation(Uint8List bytes) {
    ensureOpen();
    return _adapter.protect(bytes);
  }

  Uint8List unprotectAssociation(Uint8List bytes) {
    ensureOpen();
    return _adapter.unprotect(bytes);
  }

  /// Explicit App transaction only; no caller path, handle or native token.
  ExternalAssociationTransaction beginAssociation() {
    Pointer<Uint8> output = nullptr, counts = nullptr;
    var ticket = 0;
    try {
      ensureOpen();
      if (_role != 1) {
        WindowsExternalNative._fail(ExternalNativeFailure.invalidInput);
      }
      output = _adapter._allocate(WindowsExternalNative.maxBytes);
      counts = _adapter._allocate(16);
      final written = counts.cast<Uint64>(),
          token = (counts + 8).cast<Uint64>();
      written.value = 0;
      token.value = 0;
      final status = _adapter._calls.associationBegin(
          WindowsExternalNative.abiVersion,
          _token,
          output,
          WindowsExternalNative.maxBytes,
          written,
          token);
      ticket = token.value;
      if (status != 6) WindowsExternalNative._checkStatus(status);
      final length = written.value;
      if (ticket <= 0 ||
          length < 0 ||
          length > WindowsExternalNative.maxBytes ||
          (status == 6 ? length != 0 : length == 0)) {
        WindowsExternalNative._fail(ExternalNativeFailure.invalidNativeResult);
      }
      final bytes =
          status == 6 ? null : Uint8List.fromList(output.asTypedList(length));
      final releasedOutput = output, releasedCounts = counts;
      output = nullptr;
      counts = nullptr;
      try {
        _adapter._calls.free(releasedOutput);
      } finally {
        _adapter._calls.free(releasedCounts);
      }
      final result = ExternalAssociationTransaction._(this, ticket, bytes);
      ticket = 0;
      return result;
    } on ExternalNativeException {
      _associationEpoch++;
      rethrow;
    } catch (_) {
      _associationEpoch++;
      WindowsExternalNative._fail(ExternalNativeFailure.temporarilyUnavailable);
    } finally {
      // Capture a ticket even if the native seam threw after acquiring it.
      if (ticket == 0 && counts != nullptr) {
        ticket = (counts + 8).cast<Uint64>().value;
      }
      var cleanupFailed = false;
      try {
        if (ticket > 0) {
          WindowsExternalNative._checkStatus(_adapter._calls.associationAbort(
              WindowsExternalNative.abiVersion, _token, ticket));
        }
      } catch (_) {
        cleanupFailed = true;
      } finally {
        try {
          if (output != nullptr) _adapter._calls.free(output);
        } catch (_) {
          cleanupFailed = true;
        } finally {
          try {
            if (counts != nullptr) _adapter._calls.free(counts);
          } catch (_) {
            cleanupFailed = true;
          }
        }
      }
      if (cleanupFailed) {
        _associationEpoch++;
        WindowsExternalNative._fail(
            ExternalNativeFailure.temporarilyUnavailable);
      }
    }
  }

  ExternalNativeCredentialCalls get _credentialCalls {
    final calls = _adapter._calls;
    if (calls is! ExternalNativeCredentialCalls) {
      WindowsExternalNative._fail(ExternalNativeFailure.temporarilyUnavailable);
    }
    return calls as ExternalNativeCredentialCalls;
  }

  ExternalNativeExchangeCalls get _exchangeCalls {
    final calls = _adapter._calls;
    if (calls is! ExternalNativeExchangeCalls) {
      WindowsExternalNative._fail(ExternalNativeFailure.temporarilyUnavailable);
    }
    return calls as ExternalNativeExchangeCalls;
  }

  static int _discoveryCap(int kind) => switch (kind) {
        1 => 185,
        2 => 1024,
        3 => 36,
        _ => WindowsExternalNative._fail(ExternalNativeFailure.invalidInput),
      };

  ExternalNativeDiscoveryCalls get _discoveryCalls {
    final calls = _adapter._calls;
    if (calls is! ExternalNativeDiscoveryCalls) {
      WindowsExternalNative._fail(ExternalNativeFailure.temporarilyUnavailable);
    }
    return calls as ExternalNativeDiscoveryCalls;
  }

  /// Fixed public objects only; no arbitrary paths, cleanup or trust authority.
  void publishDiscovery(int kind, Uint8List bytes) {
    final cap = _discoveryCap(kind);
    if (_role != 1 ||
        bytes.isEmpty ||
        bytes.length > cap ||
        (kind != 2 && bytes.length != cap)) {
      WindowsExternalNative._fail(ExternalNativeFailure.invalidInput);
    }
    Pointer<Uint8> input = nullptr;
    var entered = false;
    var uncertain = false;
    var returned = false;
    try {
      ensureOpen();
      final calls = _discoveryCalls;
      input = _adapter._allocate(bytes.length);
      input.asTypedList(bytes.length).setAll(0, bytes);
      entered = true;
      final status =
          calls.discoveryPublish(3, _token, kind, input, bytes.length);
      returned = true;
      if (![0, 1, 2, 3, 4, 5].contains(status)) {
        _denied = true;
        WindowsExternalNative._fail(ExternalNativeFailure.commitUnknown);
      }
      WindowsExternalNative._checkStatus(status);
    } on ExternalNativeException catch (e) {
      uncertain = (entered && !returned) ||
          e.failure == ExternalNativeFailure.commitUnknown;
      if (uncertain) {
        _denied = true;
        WindowsExternalNative._fail(ExternalNativeFailure.commitUnknown);
      }
      rethrow;
    } catch (_) {
      uncertain = entered;
      if (uncertain) _denied = true;
      WindowsExternalNative._fail(entered
          ? ExternalNativeFailure.commitUnknown
          : ExternalNativeFailure.temporarilyUnavailable);
    } finally {
      try {
        _exchangeFree([input]);
      } catch (_) {
        if (uncertain || entered) _denied = true;
        WindowsExternalNative._fail(uncertain || entered
            ? ExternalNativeFailure.commitUnknown
            : ExternalNativeFailure.temporarilyUnavailable);
      }
    }
  }

  Uint8List? readDiscovery(int kind) {
    final cap = _discoveryCap(kind);
    Pointer<Uint8> output = nullptr, count = nullptr;
    try {
      ensureOpen();
      output = _adapter._allocate(cap);
      count = _adapter._allocate(8);
      count.cast<Uint64>().value = 0;
      final status = _discoveryCalls.discoveryRead(
          3, _token, kind, output, cap, count.cast<Uint64>());
      if (status != 6) WindowsExternalNative._checkStatus(status);
      final length = count.cast<Uint64>().value;
      if (status == 6 && length == 0) return null;
      if (status == 6 || length <= 0 || length > cap) {
        WindowsExternalNative._fail(ExternalNativeFailure.invalidNativeResult);
      }
      return Uint8List.fromList(output.asTypedList(length));
    } on ExternalNativeException {
      rethrow;
    } catch (_) {
      WindowsExternalNative._fail(ExternalNativeFailure.temporarilyUnavailable);
    } finally {
      _exchangeFree([output, count]);
    }
  }

  static int _exchangeCap(int kind) => switch (kind) {
        1 => 1024,
        2 => 4096,
        3 => 256,
        _ => WindowsExternalNative._fail(ExternalNativeFailure.invalidInput),
      };

  /// Raw bounded I/O only. The Data adapter must apply P22 before creation and
  /// after reading. A receipt confers creator cleanup only, never Pairing trust.
  ExternalExchangeReceipt createExchange(
      int kind, Uint8List id, Uint8List bytes) {
    final cap = _exchangeCap(kind);
    if (id.length != 16 ||
        bytes.isEmpty ||
        bytes.length > cap ||
        _role != (kind == 2 ? 1 : 2)) {
      WindowsExternalNative._fail(ExternalNativeFailure.invalidInput);
    }
    Pointer<Uint8> nativeId = nullptr, input = nullptr, count = nullptr;
    try {
      ensureOpen();
      nativeId = _adapter._allocate(16);
      nativeId.asTypedList(16).setAll(0, id);
      input = _adapter._allocate(bytes.length);
      input.asTypedList(bytes.length).setAll(0, bytes);
      count = _adapter._allocate(8);
      count.cast<Uint64>().value = 0;
      WindowsExternalNative._checkStatus(_exchangeCalls.exchangeCreate(3,
          _token, kind, nativeId, input, bytes.length, count.cast<Uint64>()));
      final receipt = count.cast<Uint64>().value;
      if (receipt <= 0) {
        WindowsExternalNative._fail(ExternalNativeFailure.invalidNativeResult);
      }
      return ExternalExchangeReceipt._(this, receipt);
    } on ExternalNativeException {
      rethrow;
    } catch (_) {
      WindowsExternalNative._fail(ExternalNativeFailure.temporarilyUnavailable);
    } finally {
      // On any boundary failure, an unpublished creator pin stays bounded in
      // this owner until close. Failure NEVER initiates file deletion.
      _exchangeFree([nativeId, input, count]);
    }
  }

  /// Null is Missing; full P22 decoding still belongs to the Data adapter.
  Uint8List? readExchange(int kind, Uint8List id) {
    final cap = _exchangeCap(kind);
    if (id.length != 16 || _role == (kind == 2 ? 1 : 2)) {
      WindowsExternalNative._fail(ExternalNativeFailure.invalidInput);
    }
    Pointer<Uint8> nativeId = nullptr, output = nullptr, count = nullptr;
    try {
      ensureOpen();
      nativeId = _adapter._allocate(16);
      nativeId.asTypedList(16).setAll(0, id);
      output = _adapter._allocate(cap);
      count = _adapter._allocate(8);
      count.cast<Uint64>().value = 0;
      final status = _exchangeCalls.exchangeRead(
          3, _token, kind, nativeId, output, cap, count.cast<Uint64>());
      if (status != 6) WindowsExternalNative._checkStatus(status);
      final length = count.cast<Uint64>().value;
      if (status == 6 && length == 0) return null;
      if (status == 6 || length <= 0 || length > cap) {
        WindowsExternalNative._fail(ExternalNativeFailure.invalidNativeResult);
      }
      return Uint8List.fromList(output.asTypedList(length));
    } on ExternalNativeException {
      rethrow;
    } catch (_) {
      WindowsExternalNative._fail(ExternalNativeFailure.temporarilyUnavailable);
    } finally {
      _exchangeFree([nativeId, output, count]);
    }
  }

  void _exchangeFree(List<Pointer<Uint8>> buffers) {
    var failed = false;
    for (final buffer in buffers) {
      try {
        if (buffer != nullptr) _adapter._calls.free(buffer);
      } catch (_) {
        failed = true;
      }
    }
    if (failed) {
      WindowsExternalNative._fail(ExternalNativeFailure.temporarilyUnavailable);
    }
  }

  ExternalNativeExchangeConsumptionCalls get _consumptionCalls {
    final calls = _adapter._calls;
    if (calls is! ExternalNativeExchangeConsumptionCalls ||
        !(calls as ExternalNativeExchangeConsumptionCalls)
            .exchangeConsumptionAvailable) {
      WindowsExternalNative._fail(ExternalNativeFailure.temporarilyUnavailable);
    }
    return calls as ExternalNativeExchangeConsumptionCalls;
  }

  /// Retains a bounded native identity/content pin. P22 validation is mandatory
  /// before the Data adapter releases this result to its trusted caller.
  ExternalExchangeRead? beginExchangeRead(int kind, Uint8List id) {
    final cap = _exchangeCap(kind);
    if (id.length != 16 || _role == (kind == 2 ? 1 : 2)) {
      WindowsExternalNative._fail(ExternalNativeFailure.invalidInput);
    }
    Pointer<Uint8> nativeId = nullptr,
        output = nullptr,
        count = nullptr,
        ticket = nullptr;
    ExternalExchangeRead? result;
    var delivered = false;
    var entered = false;
    var returned = false;
    var failed = false;
    try {
      ensureOpen();
      final calls = _consumptionCalls;
      nativeId = _adapter._allocate(16);
      nativeId.asTypedList(16).setAll(0, id);
      output = _adapter._allocate(cap);
      count = _adapter._allocate(8);
      ticket = _adapter._allocate(24);
      count.cast<Uint64>().value = 0;
      ticket.asTypedList(24).fillRange(0, 24, 0);
      entered = true;
      final status = calls.exchangeReadBegin(
          3, _token, kind, nativeId, output, cap, count.cast<Uint64>(), ticket);
      returned = true;
      final length = count.cast<Uint64>().value;
      final token = Uint8List.fromList(ticket.asTypedList(24));
      final hasTicket = token.any((v) => v != 0);
      if (hasTicket) result = ExternalExchangeRead._(this, token);
      if (status == 6 && length == 0 && !hasTicket) {
        delivered = true;
        return null;
      }
      WindowsExternalNative._checkStatus(status);
      if (length <= 0 ||
          length > cap ||
          !hasTicket ||
          ticket.cast<Uint64>().value <= 0) {
        if (!hasTicket) _denied = true;
        WindowsExternalNative._fail(ExternalNativeFailure.invalidNativeResult);
      }
      result!._bytes = Uint8List.fromList(output.asTypedList(length));
      // Free borrowed buffers before publishing the ticket-bearing result.
      delivered = true;
      return result;
    } on ExternalNativeException {
      rethrow;
    } catch (_) {
      WindowsExternalNative._fail(ExternalNativeFailure.temporarilyUnavailable);
    } finally {
      if (entered && !returned) {
        _denied = true; // Unknown acquisition: OwnerClose only.
      }
      try {
        _exchangeFree([nativeId, output, count, ticket]);
      } catch (_) {
        failed = true;
        delivered = false;
      }
      if (!delivered && result != null) {
        try {
          result.release();
        } catch (_) {
          failed = true;
          _denied = true;
        }
      }
      if (failed) {
        _denied = true;
        WindowsExternalNative._fail(
            ExternalNativeFailure.temporarilyUnavailable);
      }
    }
  }

  void _settleExchangeRead(Uint8List token, bool consume) {
    Pointer<Uint8> ticket = nullptr;
    var entered = false;
    var returned = false;
    var unknown = false;
    try {
      ensureOpen();
      final calls = _consumptionCalls;
      ticket = _adapter._allocate(24);
      ticket.asTypedList(24).setAll(0, token);
      entered = true;
      final status = consume
          ? calls.exchangeConsume(3, _token, ticket)
          : calls.exchangeRelease(3, _token, ticket);
      returned = true;
      unknown =
          consume && (status == 7 || ![0, 1, 2, 3, 4, 5, 6].contains(status));
      if (unknown) {
        _denied = true;
        WindowsExternalNative._fail(ExternalNativeFailure.commitUnknown);
      }
      WindowsExternalNative._checkStatus(status);
    } on ExternalNativeException {
      if (!consume || !entered) _denied = true;
      rethrow;
    } catch (_) {
      unknown = consume && entered;
      _denied = true;
      WindowsExternalNative._fail(unknown
          ? ExternalNativeFailure.commitUnknown
          : ExternalNativeFailure.temporarilyUnavailable);
    } finally {
      token.fillRange(0, token.length, 0);
      if (entered && !returned) _denied = true;
      try {
        _exchangeFree([ticket]);
      } catch (_) {
        _denied = true;
        WindowsExternalNative._fail(consume && entered
            ? ExternalNativeFailure.commitUnknown
            : ExternalNativeFailure.temporarilyUnavailable);
      }
    }
  }

  Uint8List protectCredential(Uint8List bytes) {
    ensureOpen();
    return _adapter.protect(bytes);
  }

  Uint8List unprotectCredential(Uint8List bytes) {
    ensureOpen();
    return _adapter.unprotect(bytes);
  }

  /// Fixed credential transaction only; no caller path, handle or native token.
  ExternalCredentialTransaction beginCredential(int kind) {
    Pointer<Uint8> output = nullptr, counts = nullptr;
    var ticket = 0;
    try {
      ensureOpen();
      if (![1, 2, 4].contains(kind) || _role != (kind == 4 ? 2 : 1)) {
        WindowsExternalNative._fail(ExternalNativeFailure.invalidInput);
      }
      output = _adapter._allocate(WindowsExternalNative.maxBytes);
      counts = _adapter._allocate(16);
      final written = counts.cast<Uint64>(),
          token = (counts + 8).cast<Uint64>();
      written.value = 0;
      token.value = 0;
      final status = _credentialCalls.credentialBegin(
          WindowsExternalNative.abiVersion,
          _token,
          kind,
          output,
          WindowsExternalNative.maxBytes,
          written,
          token);
      ticket = token.value;
      if (status != 6) WindowsExternalNative._checkStatus(status);
      final length = written.value;
      if (ticket <= 0 ||
          length < 0 ||
          length > WindowsExternalNative.maxBytes ||
          (status == 6 ? length != 0 : length == 0)) {
        WindowsExternalNative._fail(ExternalNativeFailure.invalidNativeResult);
      }
      final bytes =
          status == 6 ? null : Uint8List.fromList(output.asTypedList(length));
      final releasedOutput = output, releasedCounts = counts;
      output = nullptr;
      counts = nullptr;
      try {
        _adapter._calls.free(releasedOutput);
      } finally {
        _adapter._calls.free(releasedCounts);
      }
      final result = ExternalCredentialTransaction._(this, ticket, bytes);
      ticket = 0;
      return result;
    } on ExternalNativeException {
      _associationEpoch++;
      rethrow;
    } catch (_) {
      _associationEpoch++;
      WindowsExternalNative._fail(ExternalNativeFailure.temporarilyUnavailable);
    } finally {
      // Capture a ticket even if the native seam threw after acquiring it.
      if (ticket == 0 && counts != nullptr) {
        ticket = (counts + 8).cast<Uint64>().value;
      }
      var cleanupFailed = false;
      try {
        if (ticket > 0) {
          WindowsExternalNative._checkStatus(_credentialCalls.credentialAbort(
              WindowsExternalNative.abiVersion, _token, ticket));
        }
      } catch (_) {
        cleanupFailed = true;
      } finally {
        try {
          if (output != nullptr) _adapter._calls.free(output);
        } catch (_) {
          cleanupFailed = true;
        } finally {
          try {
            if (counts != nullptr) _adapter._calls.free(counts);
          } catch (_) {
            cleanupFailed = true;
          }
        }
      }
      if (cleanupFailed) {
        _associationEpoch++;
        WindowsExternalNative._fail(
            ExternalNativeFailure.temporarilyUnavailable);
      }
    }
  }

  /// Rechecks the held handles and captured identities without reopening paths.
  /// Denial is permanent for this owner; only close remains permitted.
  void ensureOpen() {
    if (_closed || _denied) {
      WindowsExternalNative._fail(ExternalNativeFailure.invalidInput);
    }
    try {
      _adapter._checkAbi();
      WindowsExternalNative._checkStatus(_adapter._calls
          .validateOwner(WindowsExternalNative.abiVersion, _token));
    } on ExternalNativeException {
      _denied = true;
      _associationEpoch++;
      rethrow;
    } catch (_) {
      _denied = true;
      _associationEpoch++;
      WindowsExternalNative._fail(ExternalNativeFailure.temporarilyUnavailable);
    }
  }

  /// Idempotent Dart close; native stale tokens never regain ownership. A failed
  /// close denies further use and reports failure, with native quarantine.
  void close() {
    if (_closed) return;
    _closed = true;
    _associationEpoch++;
    try {
      // Closing the acquired version is still required if a later ABI check
      // fails. No allocation, Future completion or finalizer owns this release.
      WindowsExternalNative._checkStatus(
          _adapter._calls.closeOwner(WindowsExternalNative.abiVersion, _token));
    } on ExternalNativeException {
      rethrow;
    } catch (_) {
      WindowsExternalNative._fail(ExternalNativeFailure.temporarilyUnavailable);
    }
  }

  @override
  String toString() => 'ExternalProtectedObjects(REDACTED)';
}

/// One creator-owned cleanup attempt, independent of any business consumption.
/// It cannot be constructed from an ID, path or decoded Exchange DTO.
final class ExternalExchangeReceipt {
  ExternalExchangeReceipt._(this._owner, this._receipt);
  final ExternalProtectedObjects _owner;
  final int _receipt;
  bool _settled = false;

  void cleanup() {
    if (_settled) {
      WindowsExternalNative._fail(ExternalNativeFailure.invalidInput);
    }
    _settled = true;
    try {
      _owner.ensureOpen();
      WindowsExternalNative._checkStatus(
          _owner._exchangeCalls.exchangeCleanup(3, _owner._token, _receipt));
    } on ExternalNativeException {
      rethrow;
    } catch (_) {
      WindowsExternalNative._fail(ExternalNativeFailure.temporarilyUnavailable);
    }
  }

  @override
  String toString() => 'ExternalExchangeReceipt(REDACTED)';
}

/// Opaque owner-bound one-use native read. Bytes are defensive copies; changing
/// a caller's copy cannot change the native snapshot or deletion target.
final class ExternalExchangeRead {
  ExternalExchangeRead._(this._owner, this._ticket);
  final ExternalProtectedObjects _owner;
  final Uint8List _ticket;
  Uint8List _bytes = Uint8List(0);
  bool _settled = false;
  Uint8List get bytes => Uint8List.fromList(_bytes);
  void consume() => _settle(true);
  void release() => _settle(false);
  void _settle(bool consume) {
    if (_settled) {
      WindowsExternalNative._fail(ExternalNativeFailure.invalidInput);
    }
    _settled = true;
    _owner._settleExchangeRead(_ticket, consume);
  }

  @override
  String toString() => 'ExternalExchangeRead(REDACTED)';
}

/// One-use native transaction; caller must commit or abort after actual work.
final class ExternalAssociationTransaction {
  ExternalAssociationTransaction._(this._owner, this._ticket, this.encrypted);
  final ExternalProtectedObjects _owner;
  final int _ticket;
  final Uint8List? encrypted;
  bool _settled = false, _uncertain = false;

  void commit(Uint8List ciphertext) {
    if (_settled ||
        ciphertext.isEmpty ||
        ciphertext.length > WindowsExternalNative.maxBytes) {
      WindowsExternalNative._fail(ExternalNativeFailure.invalidInput);
    }
    Pointer<Uint8> input = nullptr;
    var entered = false;
    try {
      _owner.ensureOpen();
      input = _owner._adapter._allocate(ciphertext.length);
      input.asTypedList(ciphertext.length).setAll(0, ciphertext);
      entered = true;
      final status = _owner._adapter._calls.associationCommit(
          WindowsExternalNative.abiVersion,
          _owner._token,
          _ticket,
          input,
          ciphertext.length);
      _settled =
          true; // Native consumes a well-formed commit, including denial.
      if (![0, 1, 2, 3, 4, 5].contains(status)) {
        WindowsExternalNative._fail(ExternalNativeFailure.commitUnknown);
      }
      WindowsExternalNative._checkStatus(status);
    } on ExternalNativeException {
      rethrow;
    } catch (_) {
      _uncertain = entered;
      WindowsExternalNative._fail(entered
          ? ExternalNativeFailure.commitUnknown
          : ExternalNativeFailure.temporarilyUnavailable);
    } finally {
      _owner._associationEpoch++;
      try {
        if (input != nullptr) _owner._adapter._calls.free(input);
      } catch (_) {
        WindowsExternalNative._fail(entered
            ? ExternalNativeFailure.commitUnknown
            : ExternalNativeFailure.temporarilyUnavailable);
      } finally {
        encrypted?.fillRange(0, encrypted!.length, 0);
      }
    }
  }

  void abort() {
    if (_settled) return;
    _settled = true;
    encrypted?.fillRange(0, encrypted!.length, 0);
    // Closing the owner already releases a retained transaction.
    if (_owner.isClosed) return;
    try {
      final status = _owner._adapter._calls.associationAbort(
          WindowsExternalNative.abiVersion, _owner._token, _ticket);
      // A throwing commit seam may already have consumed the ticket. Exactly
      // one abort attempt settles a still-live ticket without retrying commit.
      if (!_uncertain || status != 1) {
        WindowsExternalNative._checkStatus(status);
      }
    } catch (_) {
      _owner._associationEpoch++;
      WindowsExternalNative._fail(_uncertain
          ? ExternalNativeFailure.commitUnknown
          : ExternalNativeFailure.temporarilyUnavailable);
    }
  }

  @override
  String toString() => 'ExternalAssociationTransaction(REDACTED)';
}

/// One-use native transaction; caller must commit or abort after actual work.
final class ExternalCredentialTransaction {
  ExternalCredentialTransaction._(this._owner, this._ticket, this.encrypted);
  final ExternalProtectedObjects _owner;
  final int _ticket;
  final Uint8List? encrypted;
  bool _settled = false, _uncertain = false;

  void commit(Uint8List ciphertext) {
    if (_settled ||
        _uncertain ||
        ciphertext.isEmpty ||
        ciphertext.length > WindowsExternalNative.maxBytes) {
      WindowsExternalNative._fail(ExternalNativeFailure.invalidInput);
    }
    Pointer<Uint8> input = nullptr;
    var entered = false;
    try {
      _owner.ensureOpen();
      input = _owner._adapter._allocate(ciphertext.length);
      input.asTypedList(ciphertext.length).setAll(0, ciphertext);
      entered = true;
      final status = _owner._credentialCalls.credentialCommit(
          WindowsExternalNative.abiVersion,
          _owner._token,
          _ticket,
          input,
          ciphertext.length);
      _settled =
          true; // Native consumes a well-formed commit, including denial.
      if (![0, 1, 2, 3, 4, 5].contains(status)) {
        WindowsExternalNative._fail(ExternalNativeFailure.commitUnknown);
      }
      WindowsExternalNative._checkStatus(status);
    } on ExternalNativeException {
      rethrow;
    } catch (_) {
      _uncertain = entered;
      WindowsExternalNative._fail(entered
          ? ExternalNativeFailure.commitUnknown
          : ExternalNativeFailure.temporarilyUnavailable);
    } finally {
      _owner._associationEpoch++;
      try {
        if (input != nullptr) _owner._adapter._calls.free(input);
      } catch (_) {
        WindowsExternalNative._fail(entered
            ? ExternalNativeFailure.commitUnknown
            : ExternalNativeFailure.temporarilyUnavailable);
      } finally {
        encrypted?.fillRange(0, encrypted!.length, 0);
      }
    }
  }

  void abort() {
    if (_settled) return;
    _settled = true;
    encrypted?.fillRange(0, encrypted!.length, 0);
    // Closing the owner already releases a retained transaction.
    if (_owner.isClosed) return;
    try {
      final status = _owner._credentialCalls.credentialAbort(
          WindowsExternalNative.abiVersion, _owner._token, _ticket);
      // A throwing commit seam may already have consumed the ticket. Exactly
      // one abort attempt settles a still-live ticket without retrying commit.
      if (!_uncertain || status != 1) {
        WindowsExternalNative._checkStatus(status);
      }
    } catch (_) {
      _owner._associationEpoch++;
      WindowsExternalNative._fail(_uncertain
          ? ExternalNativeFailure.commitUnknown
          : ExternalNativeFailure.temporarilyUnavailable);
    }
  }

  @override
  String toString() => 'ExternalCredentialTransaction(REDACTED)';
}

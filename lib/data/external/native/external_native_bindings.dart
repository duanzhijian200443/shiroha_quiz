import 'dart:ffi';

/// Infrastructure call seam only; it supplies no credential/authentication port.
abstract interface class ExternalNativeCalls {
  int abiVersion();
  Pointer<Uint8> allocate(int capacity);
  void free(Pointer<Uint8> buffer);
  int localAppData(int version, Pointer<Uint8> output, int capacity,
      Pointer<Uint64> written);
  int protect(int version, Pointer<Uint8> input, int length,
      Pointer<Uint8> output, int capacity, Pointer<Uint64> written);
  int unprotect(int version, Pointer<Uint8> input, int length,
      Pointer<Uint8> output, int capacity, Pointer<Uint64> written);
  int acquireOwner(int version, int role, Pointer<Uint64> token);
  int validateOwner(int version, int token);
  int closeOwner(int version, int token);
  int associationBegin(int version, int owner, Pointer<Uint8> output,
      int capacity, Pointer<Uint64> written, Pointer<Uint64> ticket);
  int associationCommit(
      int version, int owner, int ticket, Pointer<Uint8> input, int length);
  int associationAbort(int version, int owner, int ticket);
}

/// Optional ABI-3 fixed credential transactions. Missing symbols fail closed.
abstract interface class ExternalNativeCredentialCalls {
  int credentialBegin(int version, int owner, int kind, Pointer<Uint8> output,
      int capacity, Pointer<Uint64> written, Pointer<Uint64> ticket);
  int credentialCommit(
      int version, int owner, int ticket, Pointer<Uint8> input, int length);
  int credentialAbort(int version, int owner, int ticket);
}

typedef _CredentialBeginNative = Int32 Function(Uint32, Uint64, Uint32,
    Pointer<Uint8>, Uint64, Pointer<Uint64>, Pointer<Uint64>);

abstract interface class ExternalNativeDiscoveryCalls {
  int discoveryPublish(
      int version, int owner, int kind, Pointer<Uint8> input, int length);
  int discoveryRead(int version, int owner, int kind, Pointer<Uint8> output,
      int capacity, Pointer<Uint64> written);
}

typedef _DiscoveryPublishNative = Int32 Function(
    Uint32, Uint64, Uint32, Pointer<Uint8>, Uint64);
typedef _DiscoveryReadNative = Int32 Function(
    Uint32, Uint64, Uint32, Pointer<Uint8>, Uint64, Pointer<Uint64>);

/// Optional ABI-3 Exchange capability. No caller paths or raw OS handles.
abstract interface class ExternalNativeExchangeCalls {
  int exchangeCreate(int version, int owner, int kind, Pointer<Uint8> id,
      Pointer<Uint8> input, int length, Pointer<Uint64> receipt);
  int exchangeRead(int version, int owner, int kind, Pointer<Uint8> id,
      Pointer<Uint8> output, int capacity, Pointer<Uint64> written);
  int exchangeCleanup(int version, int owner, int receipt);
}

/// Optional E0 capability; all three symbols must exist before acquiring a pin.
abstract interface class ExternalNativeExchangeConsumptionCalls {
  bool get exchangeConsumptionAvailable;
  int exchangeReadBegin(
      int version,
      int owner,
      int kind,
      Pointer<Uint8> id,
      Pointer<Uint8> output,
      int capacity,
      Pointer<Uint64> written,
      Pointer<Uint8> ticket);
  int exchangeConsume(int version, int owner, Pointer<Uint8> ticket);
  int exchangeRelease(int version, int owner, Pointer<Uint8> ticket);
}

typedef _ExchangeReadBeginNative = Int32 Function(Uint32, Uint64, Uint32,
    Pointer<Uint8>, Pointer<Uint8>, Uint64, Pointer<Uint64>, Pointer<Uint8>);
typedef _ExchangeSettleNative = Int32 Function(Uint32, Uint64, Pointer<Uint8>);

typedef _ExchangeNative = Int32 Function(Uint32, Uint64, Uint32, Pointer<Uint8>,
    Pointer<Uint8>, Uint64, Pointer<Uint64>);

/// Optional ABI-3 additive capability; older ABI-3 helpers retain memory/store calls.
abstract interface class ExternalNativeCryptoCalls {
  int generateKey(
      int version,
      Pointer<Uint8> key,
      int keyCapacity,
      Pointer<Uint64> keyWritten,
      Pointer<Uint8> point,
      int pointCapacity,
      Pointer<Uint64> pointWritten);
  int signDigest(
      int version,
      Pointer<Uint8> key,
      int keyLength,
      Pointer<Uint8> point,
      int pointLength,
      Pointer<Uint8> digest,
      int digestLength,
      Pointer<Uint8> signature,
      int capacity,
      Pointer<Uint64> written);
  int verifyDigest(
      int version,
      Pointer<Uint8> point,
      int pointLength,
      Pointer<Uint8> digest,
      int digestLength,
      Pointer<Uint8> signature,
      int length);
}

typedef _GenerateNative = Int32 Function(Uint32, Pointer<Uint8>, Uint64,
    Pointer<Uint64>, Pointer<Uint8>, Uint64, Pointer<Uint64>);
typedef _SignNative = Int32 Function(
    Uint32,
    Pointer<Uint8>,
    Uint64,
    Pointer<Uint8>,
    Uint64,
    Pointer<Uint8>,
    Uint64,
    Pointer<Uint8>,
    Uint64,
    Pointer<Uint64>);
typedef _VerifyNative = Int32 Function(Uint32, Pointer<Uint8>, Uint64,
    Pointer<Uint8>, Uint64, Pointer<Uint8>, Uint64);

typedef _VersionNative = Uint32 Function();
typedef _AllocateNative = Pointer<Uint8> Function(Uint64);
typedef _FreeNative = Void Function(Pointer<Uint8>);
typedef _FolderNative = Int32 Function(
    Uint32, Pointer<Uint8>, Uint64, Pointer<Uint64>);
typedef _TransformNative = Int32 Function(
    Uint32, Pointer<Uint8>, Uint64, Pointer<Uint8>, Uint64, Pointer<Uint64>);
typedef _AcquireNative = Int32 Function(Uint32, Uint32, Pointer<Uint64>);
typedef _OwnerNative = Int32 Function(Uint32, Uint64);
typedef _BeginNative = Int32 Function(
    Uint32, Uint64, Pointer<Uint8>, Uint64, Pointer<Uint64>, Pointer<Uint64>);
typedef _CommitNative = Int32 Function(
    Uint32, Uint64, Uint64, Pointer<Uint8>, Uint64);
typedef _AbortNative = Int32 Function(Uint32, Uint64, Uint64);

/// Lookup is passive; only an explicit adapter operation invokes the helper.
final class FfiExternalNativeCalls
    implements
        ExternalNativeCalls,
        ExternalNativeCryptoCalls,
        ExternalNativeCredentialCalls,
        ExternalNativeExchangeCalls,
        ExternalNativeExchangeConsumptionCalls,
        ExternalNativeDiscoveryCalls {
  FfiExternalNativeCalls(DynamicLibrary library)
      : _library = library,
        _version = library.lookupFunction<_VersionNative, int Function()>(
            'shiroha_native_abi_version'),
        _allocate = library.lookupFunction<_AllocateNative,
            Pointer<Uint8> Function(int)>('shiroha_native_buffer_alloc'),
        _free =
            library.lookupFunction<_FreeNative, void Function(Pointer<Uint8>)>(
                'shiroha_native_buffer_free'),
        _folder = library.lookupFunction<_FolderNative,
            int Function(int, Pointer<Uint8>, int, Pointer<Uint64>)>(
          'shiroha_native_local_app_data',
        ),
        _protect = library.lookupFunction<
            _TransformNative,
            int Function(int, Pointer<Uint8>, int, Pointer<Uint8>, int,
                Pointer<Uint64>)>('shiroha_native_dpapi_protect'),
        _unprotect = library.lookupFunction<
            _TransformNative,
            int Function(int, Pointer<Uint8>, int, Pointer<Uint8>, int,
                Pointer<Uint64>)>('shiroha_native_dpapi_unprotect'),
        _acquire = library.lookupFunction<
            _AcquireNative,
            int Function(
                int, int, Pointer<Uint64>)>('shiroha_native_owner_acquire'),
        _validate =
            library.lookupFunction<_OwnerNative, int Function(int, int)>(
                'shiroha_native_owner_validate'),
        _close = library.lookupFunction<_OwnerNative, int Function(int, int)>(
            'shiroha_native_owner_close'),
        _begin = library.lookupFunction<
            _BeginNative,
            int Function(int, int, Pointer<Uint8>, int, Pointer<Uint64>,
                Pointer<Uint64>)>('shiroha_native_association_begin'),
        _commit = library.lookupFunction<
            _CommitNative,
            int Function(int, int, int, Pointer<Uint8>,
                int)>('shiroha_native_association_commit'),
        _abort =
            library.lookupFunction<_AbortNative, int Function(int, int, int)>(
                'shiroha_native_association_abort');

  late final _credentialBegin = _library.lookupFunction<
      _CredentialBeginNative,
      int Function(int, int, int, Pointer<Uint8>, int, Pointer<Uint64>,
          Pointer<Uint64>)>('shiroha_native_credential_begin');
  late final _credentialCommit = _library.lookupFunction<
      _CommitNative,
      int Function(int, int, int, Pointer<Uint8>,
          int)>('shiroha_native_credential_commit');
  late final _credentialAbort =
      _library.lookupFunction<_AbortNative, int Function(int, int, int)>(
          'shiroha_native_credential_abort');
  @override
  int credentialBegin(int version, int owner, int kind, Pointer<Uint8> output,
          int capacity, Pointer<Uint64> written, Pointer<Uint64> ticket) =>
      _credentialBegin(version, owner, kind, output, capacity, written, ticket);
  @override
  int credentialCommit(int version, int owner, int ticket, Pointer<Uint8> input,
          int length) =>
      _credentialCommit(version, owner, ticket, input, length);
  @override
  int credentialAbort(int version, int owner, int ticket) =>
      _credentialAbort(version, owner, ticket);

  final DynamicLibrary _library;
  late final _exchangeReadBegin = _library.lookupFunction<
      _ExchangeReadBeginNative,
      int Function(
          int,
          int,
          int,
          Pointer<Uint8>,
          Pointer<Uint8>,
          int,
          Pointer<Uint64>,
          Pointer<Uint8>)>('shiroha_native_exchange_read_begin');
  late final _exchangeConsume = _library.lookupFunction<
      _ExchangeSettleNative,
      int Function(
          int, int, Pointer<Uint8>)>('shiroha_native_exchange_consume');
  late final _exchangeRelease = _library.lookupFunction<
      _ExchangeSettleNative,
      int Function(
          int, int, Pointer<Uint8>)>('shiroha_native_exchange_release');
  @override
  bool get exchangeConsumptionAvailable {
    try {
      // Resolve the complete lifecycle before any operation can retain a pin.
      return [_exchangeReadBegin, _exchangeConsume, _exchangeRelease].length ==
          3;
    } catch (_) {
      return false;
    }
  }

  @override
  int exchangeReadBegin(
          int version,
          int owner,
          int kind,
          Pointer<Uint8> id,
          Pointer<Uint8> output,
          int capacity,
          Pointer<Uint64> written,
          Pointer<Uint8> ticket) =>
      _exchangeReadBegin(
          version, owner, kind, id, output, capacity, written, ticket);
  @override
  int exchangeConsume(int version, int owner, Pointer<Uint8> ticket) =>
      _exchangeConsume(version, owner, ticket);
  @override
  int exchangeRelease(int version, int owner, Pointer<Uint8> ticket) =>
      _exchangeRelease(version, owner, ticket);
  late final _discoveryPublish = _library.lookupFunction<
      _DiscoveryPublishNative,
      int Function(int, int, int, Pointer<Uint8>,
          int)>('shiroha_native_discovery_publish');
  late final _discoveryRead = _library.lookupFunction<
      _DiscoveryReadNative,
      int Function(int, int, int, Pointer<Uint8>, int,
          Pointer<Uint64>)>('shiroha_native_discovery_read');
  @override
  int discoveryPublish(
          int version, int owner, int kind, Pointer<Uint8> input, int length) =>
      _discoveryPublish(version, owner, kind, input, length);
  @override
  int discoveryRead(int version, int owner, int kind, Pointer<Uint8> output,
          int capacity, Pointer<Uint64> written) =>
      _discoveryRead(version, owner, kind, output, capacity, written);
  late final _exchangeCreate = _library.lookupFunction<
      _ExchangeNative,
      int Function(int, int, int, Pointer<Uint8>, Pointer<Uint8>, int,
          Pointer<Uint64>)>('shiroha_native_exchange_create');
  late final _exchangeRead = _library.lookupFunction<
      _ExchangeNative,
      int Function(int, int, int, Pointer<Uint8>, Pointer<Uint8>, int,
          Pointer<Uint64>)>('shiroha_native_exchange_read');
  late final _exchangeCleanup =
      _library.lookupFunction<_AbortNative, int Function(int, int, int)>(
          'shiroha_native_exchange_cleanup');
  @override
  int exchangeCreate(int version, int owner, int kind, Pointer<Uint8> id,
          Pointer<Uint8> input, int length, Pointer<Uint64> receipt) =>
      _exchangeCreate(version, owner, kind, id, input, length, receipt);
  @override
  int exchangeRead(int version, int owner, int kind, Pointer<Uint8> id,
          Pointer<Uint8> output, int capacity, Pointer<Uint64> written) =>
      _exchangeRead(version, owner, kind, id, output, capacity, written);
  @override
  int exchangeCleanup(int version, int owner, int receipt) =>
      _exchangeCleanup(version, owner, receipt);
  // Lazy lookups preserve compatibility with pre-P21 ABI-3 helper symbols.
  late final _generate = _library.lookupFunction<
      _GenerateNative,
      int Function(int, Pointer<Uint8>, int, Pointer<Uint64>, Pointer<Uint8>,
          int, Pointer<Uint64>)>('shiroha_native_ecdsa_generate_key');
  late final _sign = _library.lookupFunction<
      _SignNative,
      int Function(
          int,
          Pointer<Uint8>,
          int,
          Pointer<Uint8>,
          int,
          Pointer<Uint8>,
          int,
          Pointer<Uint8>,
          int,
          Pointer<Uint64>)>('shiroha_native_ecdsa_sign_digest');
  late final _verify = _library.lookupFunction<
      _VerifyNative,
      int Function(int, Pointer<Uint8>, int, Pointer<Uint8>, int,
          Pointer<Uint8>, int)>('shiroha_native_ecdsa_verify_digest');
  @override
  int generateKey(
          int version,
          Pointer<Uint8> key,
          int capacity,
          Pointer<Uint64> written,
          Pointer<Uint8> point,
          int pointCapacity,
          Pointer<Uint64> pointWritten) =>
      _generate(
          version, key, capacity, written, point, pointCapacity, pointWritten);
  @override
  int signDigest(
          int version,
          Pointer<Uint8> key,
          int keyLength,
          Pointer<Uint8> point,
          int pointLength,
          Pointer<Uint8> digest,
          int digestLength,
          Pointer<Uint8> signature,
          int capacity,
          Pointer<Uint64> written) =>
      _sign(version, key, keyLength, point, pointLength, digest, digestLength,
          signature, capacity, written);
  @override
  int verifyDigest(
          int version,
          Pointer<Uint8> point,
          int pointLength,
          Pointer<Uint8> digest,
          int digestLength,
          Pointer<Uint8> signature,
          int length) =>
      _verify(
          version, point, pointLength, digest, digestLength, signature, length);

  final int Function() _version;
  final Pointer<Uint8> Function(int) _allocate;
  final void Function(Pointer<Uint8>) _free;
  final int Function(int, Pointer<Uint8>, int, Pointer<Uint64>) _folder;
  final int Function(
          int, Pointer<Uint8>, int, Pointer<Uint8>, int, Pointer<Uint64>)
      _protect, _unprotect;
  final int Function(int, int, Pointer<Uint64>) _acquire;
  final int Function(int, int) _validate, _close;
  final int Function(
      int, int, Pointer<Uint8>, int, Pointer<Uint64>, Pointer<Uint64>) _begin;
  final int Function(int, int, int, Pointer<Uint8>, int) _commit;
  final int Function(int, int, int) _abort;

  @override
  int associationBegin(int version, int owner, Pointer<Uint8> output,
          int capacity, Pointer<Uint64> written, Pointer<Uint64> ticket) =>
      _begin(version, owner, output, capacity, written, ticket);
  @override
  int associationCommit(int version, int owner, int ticket,
          Pointer<Uint8> input, int length) =>
      _commit(version, owner, ticket, input, length);
  @override
  int associationAbort(int version, int owner, int ticket) =>
      _abort(version, owner, ticket);

  @override
  int acquireOwner(int version, int role, Pointer<Uint64> token) =>
      _acquire(version, role, token);
  @override
  int validateOwner(int version, int token) => _validate(version, token);
  @override
  int closeOwner(int version, int token) => _close(version, token);

  @override
  int abiVersion() => _version();
  @override
  Pointer<Uint8> allocate(int capacity) => _allocate(capacity);
  @override
  void free(Pointer<Uint8> buffer) => _free(buffer);
  @override
  int localAppData(int version, Pointer<Uint8> output, int capacity,
          Pointer<Uint64> written) =>
      _folder(version, output, capacity, written);
  @override
  int protect(int version, Pointer<Uint8> input, int length,
          Pointer<Uint8> output, int capacity, Pointer<Uint64> written) =>
      _protect(version, input, length, output, capacity, written);
  @override
  int unprotect(int version, Pointer<Uint8> input, int length,
          Pointer<Uint8> output, int capacity, Pointer<Uint64> written) =>
      _unprotect(version, input, length, output, capacity, written);
}

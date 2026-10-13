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
}

typedef _VersionNative = Uint32 Function();
typedef _AllocateNative = Pointer<Uint8> Function(Uint64);
typedef _FreeNative = Void Function(Pointer<Uint8>);
typedef _FolderNative = Int32 Function(
    Uint32, Pointer<Uint8>, Uint64, Pointer<Uint64>);
typedef _TransformNative = Int32 Function(
    Uint32, Pointer<Uint8>, Uint64, Pointer<Uint8>, Uint64, Pointer<Uint64>);
typedef _AcquireNative = Int32 Function(Uint32, Uint32, Pointer<Uint64>);
typedef _OwnerNative = Int32 Function(Uint32, Uint64);

/// Lookup is passive; only an explicit adapter operation invokes the helper.
final class FfiExternalNativeCalls implements ExternalNativeCalls {
  FfiExternalNativeCalls(DynamicLibrary library)
      : _version = library.lookupFunction<_VersionNative, int Function()>(
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
            'shiroha_native_owner_close');

  final int Function() _version;
  final Pointer<Uint8> Function(int) _allocate;
  final void Function(Pointer<Uint8>) _free;
  final int Function(int, Pointer<Uint8>, int, Pointer<Uint64>) _folder;
  final int Function(
          int, Pointer<Uint8>, int, Pointer<Uint8>, int, Pointer<Uint64>)
      _protect, _unprotect;
  final int Function(int, int, Pointer<Uint64>) _acquire;
  final int Function(int, int) _validate, _close;

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

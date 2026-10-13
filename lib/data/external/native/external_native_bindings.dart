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
}

typedef _VersionNative = Uint32 Function();
typedef _AllocateNative = Pointer<Uint8> Function(Uint64);
typedef _FreeNative = Void Function(Pointer<Uint8>);
typedef _FolderNative = Int32 Function(
    Uint32, Pointer<Uint8>, Uint64, Pointer<Uint64>);
typedef _TransformNative = Int32 Function(
    Uint32, Pointer<Uint8>, Uint64, Pointer<Uint8>, Uint64, Pointer<Uint64>);

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
                Pointer<Uint64>)>('shiroha_native_dpapi_unprotect');

  final int Function() _version;
  final Pointer<Uint8> Function(int) _allocate;
  final void Function(Pointer<Uint8>) _free;
  final int Function(int, Pointer<Uint8>, int, Pointer<Uint64>) _folder;
  final int Function(
          int, Pointer<Uint8>, int, Pointer<Uint8>, int, Pointer<Uint64>)
      _protect, _unprotect;

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

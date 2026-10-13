import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:shiroha_quiz/data/external/native/external_native_bindings.dart';

/// Test-only allocator + fake calls. Never opens the production helper, calls
/// DPAPI, reads credentials or implements an Application authentication backend.
final class FakeExternalNativeCalls implements ExternalNativeCalls {
  FakeExternalNativeCalls() {
    final library = Platform.isWindows
        ? DynamicLibrary.open('msvcrt.dll')
        : DynamicLibrary.process();
    _calloc = library.lookupFunction<Pointer<Void> Function(UintPtr, UintPtr),
        Pointer<Void> Function(int, int)>('calloc');
    _free = library.lookupFunction<Void Function(Pointer<Void>),
        void Function(Pointer<Void>)>('free');
  }

  late final Pointer<Void> Function(int, int) _calloc;
  late final void Function(Pointer<Void>) _free;
  final allocations = <int, int>{};
  final freed = <int>[];
  final events = <String>[];
  Uint8List result = Uint8List.fromList([9, 8, 7]);
  int version = 1, status = 0, allocationCount = 0, operationCount = 0;
  int? failAllocation, outputLength;
  bool throwOperation = false;
  Uint8List? capturedInput;

  @override
  int abiVersion() {
    events.add('version');
    return version;
  }

  @override
  Pointer<Uint8> allocate(int capacity) {
    events.add('allocate');
    if (++allocationCount == failAllocation) return nullptr;
    final pointer = _calloc(1, capacity).cast<Uint8>();
    if (pointer != nullptr) allocations[pointer.address] = capacity;
    return pointer;
  }

  @override
  void free(Pointer<Uint8> buffer) {
    final capacity = allocations.remove(buffer.address)!;
    buffer.asTypedList(capacity).fillRange(0, capacity, 0);
    freed.add(buffer.address);
    _free(buffer.cast<Void>());
  }

  int _result(Pointer<Uint8> output, Pointer<Uint64> written) {
    operationCount++;
    output.asTypedList(result.length).setAll(0, result);
    written.value = outputLength ?? result.length;
    if (throwOperation) throw StateError('synthetic private OS detail');
    return status;
  }

  @override
  int localAppData(int version, Pointer<Uint8> output, int capacity,
          Pointer<Uint64> written) =>
      _result(output, written);

  @override
  int protect(int version, Pointer<Uint8> input, int length,
      Pointer<Uint8> output, int capacity, Pointer<Uint64> written) {
    capturedInput = Uint8List.fromList(input.asTypedList(length));
    return _result(output, written);
  }

  @override
  int unprotect(int version, Pointer<Uint8> input, int length,
          Pointer<Uint8> output, int capacity, Pointer<Uint64> written) =>
      protect(version, input, length, output, capacity, written);
}

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
  int version = 2, status = 0, allocationCount = 0, operationCount = 0;
  int? failAllocation, outputLength;
  bool throwOperation = false;
  Uint8List? capturedInput;
  final owners = <int, int>{};
  int nextToken = 1, ownerStatus = 0, closeStatus = 0;
  bool invalidOwnerResult = false,
      throwValidate = false,
      throwFree = false,
      throwClose = false;

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
    if (throwFree) throw StateError('synthetic private release detail');
  }

  @override
  int acquireOwner(int version, int role, Pointer<Uint64> token) {
    events.add('acquire:$role');
    token.value = 0;
    if (owners.containsValue(role)) return 4;
    if (ownerStatus != 0) return ownerStatus;
    if (invalidOwnerResult) return 0;
    token.value = nextToken++;
    owners[token.value] = role;
    if (throwOperation) throw StateError('synthetic private native detail');
    return 0;
  }

  @override
  int validateOwner(int version, int token) {
    events.add('validate');
    if (throwValidate) throw StateError('synthetic private handle detail');
    return owners.containsKey(token) ? ownerStatus : 1;
  }

  @override
  int closeOwner(int version, int token) {
    events.add('close');
    if (!owners.containsKey(token)) return 1;
    owners.remove(token);
    if (throwClose) throw StateError('synthetic private close detail');
    return closeStatus;
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

import 'dart:ffi';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/data/external/native/external_native_bindings.dart';
import 'package:shiroha_quiz/data/external/native/windows_external_native.dart';
import 'package:shiroha_quiz/data/external/native/windows_external_crypto.dart';
import 'external_native_test_support.dart';

final class _Fake implements ExternalNativeCalls, ExternalNativeCryptoCalls {
  final memory = FakeExternalNativeCalls();
  int status = 0,
      operations = 0,
      keyLength = 67,
      pointLength = 65,
      signatureLength = 64;
  bool throws = false, missing = false;
  @override
  int abiVersion() => memory.version;
  @override
  Pointer<Uint8> allocate(int length) => memory.allocate(length);
  @override
  void free(Pointer<Uint8> buffer) {
    expect(buffer.asTypedList(memory.allocations[buffer.address]!),
        everyElement(0));
    memory.free(buffer);
  }

  int _operation() {
    operations++;
    if (missing) throw ArgumentError('synthetic missing symbol');
    if (throws) throw StateError('synthetic unsafe message');
    return status;
  }

  @override
  int generateKey(
      int version,
      Pointer<Uint8> key,
      int capacity,
      Pointer<Uint64> written,
      Pointer<Uint8> point,
      int pointCapacity,
      Pointer<Uint64> pointWritten) {
    expect(version, 3);
    expect(capacity, 256);
    expect(pointCapacity, 65);
    key.asTypedList(67).fillRange(0, 67, 0x22);
    point.asTypedList(65).fillRange(0, 65, 0x33);
    point.value = 4;
    written.value = keyLength;
    pointWritten.value = pointLength;
    return _operation();
  }

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
      Pointer<Uint64> written) {
    expect(version, 3);
    expect(keyLength, 67);
    expect(pointLength, 65);
    expect(digestLength, 32);
    expect(key.asTypedList(67), everyElement(0x22));
    expect(point.value, 4);
    expect(digest.asTypedList(32), everyElement(0x44));
    expect(capacity, 64);
    signature.asTypedList(64).fillRange(0, 64, 0x55);
    written.value = signatureLength;
    return _operation();
  }

  @override
  int verifyDigest(
      int version,
      Pointer<Uint8> point,
      int pointLength,
      Pointer<Uint8> digest,
      int digestLength,
      Pointer<Uint8> signature,
      int length) {
    expect(version, 3);
    expect(pointLength, 65);
    expect(digestLength, 32);
    expect(length, 64);
    expect(signature.asTypedList(64), everyElement(0x55));
    return _operation();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unapproved memory/store call');
}

Matcher _failure(ExternalNativeFailure failure) =>
    throwsA(isA<ExternalNativeException>()
        .having((e) => e.failure, 'category', failure));
void main() {
  late _Fake calls;
  late WindowsExternalCrypto crypto;
  final key = Uint8List(67)..fillRange(0, 67, 0x22);
  final point = Uint8List(65)
    ..fillRange(0, 65, 0x33)
    ..[0] = 4;
  final digest = Uint8List(32)..fillRange(0, 32, 0x44);
  final signature = Uint8List(64)..fillRange(0, 64, 0x55);
  setUp(() {
    calls = _Fake();
    crypto = WindowsExternalCrypto.fromCalls(calls);
  });
  tearDown(() {
    expect(calls.memory.allocations, isEmpty);
  });
  Uint8List sign() =>
      crypto.signDigest(pkcs8Der: key, publicPoint: point, digest: digest);
  void verify() => crypto.verifyDigest(
      publicPoint: point, digest: digest, rawSignature: signature);
  test(
      'explicit generation/sign/verify copy results and wipe every native allocation',
      () {
    final pair = crypto.generateKey();
    expect(pair.pkcs8Der, key);
    expect(pair.publicPoint, point);
    expect(pair.toString(), 'ExternalP256KeyPair(REDACTED)');
    expect(sign(), signature);
    verify();
    pair.clearPrivateKey();
    expect(pair.pkcs8Der, everyElement(0));
    expect(key, everyElement(0x22));
    expect(calls.operations, 3);
  });
  test('ABI mismatch and older call seam reject before allocation/operations',
      () {
    calls.memory.version = 2;
    expect(sign, _failure(ExternalNativeFailure.abiMismatch));
    expect(calls.operations, 0);
    expect(calls.memory.allocationCount, 0);
    expect(() => WindowsExternalCrypto.fromCalls(calls.memory),
        _failure(ExternalNativeFailure.libraryUnavailable));
  });
  test('all partial allocations release on failure', () {
    for (var allocation = 1; allocation <= 5; allocation++) {
      calls.memory.allocationCount = 0;
      calls.memory.failAllocation = allocation;
      expect(sign, _failure(ExternalNativeFailure.resourceLimit));
      expect(calls.memory.allocations, isEmpty);
    }
    expect(calls.operations, 0);
  });
  test('native categories remain exact and unknown statuses reject', () {
    final mapping = {
      1: ExternalNativeFailure.invalidInput,
      2: ExternalNativeFailure.abiMismatch,
      3: ExternalNativeFailure.resourceLimit,
      4: ExternalNativeFailure.temporarilyUnavailable,
      5: ExternalNativeFailure.dataCorrupt,
      8: ExternalNativeFailure.verificationRejected,
      99: ExternalNativeFailure.invalidNativeResult
    };
    for (final entry in mapping.entries) {
      calls.status = entry.key;
      expect(verify, _failure(entry.value));
    }
  });
  test('invalid successful key/count/signature results never escape', () {
    for (final n in [0, 257]) {
      calls.keyLength = n;
      expect(crypto.generateKey,
          _failure(ExternalNativeFailure.invalidNativeResult));
    }
    calls.keyLength = 67;
    calls.pointLength = 64;
    expect(crypto.generateKey,
        _failure(ExternalNativeFailure.invalidNativeResult));
    calls.signatureLength = 63;
    expect(sign, _failure(ExternalNativeFailure.invalidNativeResult));
  });
  test('malformed lengths reject before allocation or native call', () {
    for (final length in [0, 66]) {
      expect(
          () => crypto.signDigest(
              pkcs8Der: key, publicPoint: Uint8List(length), digest: digest),
          _failure(ExternalNativeFailure.invalidInput));
    }
    expect(
        () => crypto.signDigest(
            pkcs8Der: Uint8List(257), publicPoint: point, digest: digest),
        _failure(ExternalNativeFailure.invalidInput));
    expect(
        () => crypto.verifyDigest(
            publicPoint: point, digest: Uint8List(31), rawSignature: signature),
        _failure(ExternalNativeFailure.invalidInput));
    expect(calls.operations, 0);
    expect(calls.memory.allocationCount, 0);
  });
  test('exceptions/missing symbols release memory and redact unsafe details',
      () {
    calls.throws = true;
    expect(sign, _failure(ExternalNativeFailure.temporarilyUnavailable));
    calls.throws = false;
    calls.missing = true;
    expect(sign, _failure(ExternalNativeFailure.libraryUnavailable));
  });
  test('throwing free attempts every remaining release once', () {
    calls.memory.throwFree = true;
    expect(sign, _failure(ExternalNativeFailure.temporarilyUnavailable));
    expect(calls.memory.freed.length, 5);
  });
}

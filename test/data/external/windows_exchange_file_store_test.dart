import 'dart:ffi';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/data/external/exchange_message_codec.dart';
import 'package:shiroha_quiz/data/external/native/external_native_bindings.dart';
import 'package:shiroha_quiz/data/external/native/windows_external_native.dart';
import 'package:shiroha_quiz/data/external/windows_exchange_file_store.dart';

import 'bootstrap_test_support.dart';
import 'external_native_test_support.dart';

final class LegacyCalls implements ExternalNativeCalls {
  LegacyCalls(this.base);
  final FakeExternalNativeCalls base;
  @override
  int abiVersion() => 3;
  @override
  Pointer<Uint8> allocate(int capacity) => base.allocate(capacity);
  @override
  void free(Pointer<Uint8> buffer) => base.free(buffer);
  @override
  int acquireOwner(int version, int role, Pointer<Uint64> token) =>
      base.acquireOwner(version, role, token);
  @override
  int validateOwner(int version, int token) =>
      base.validateOwner(version, token);
  @override
  int closeOwner(int version, int token) => base.closeOwner(version, token);
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unused legacy seam');
}

WindowsExternalNative adapter(ExternalNativeCalls calls) =>
    WindowsExternalNative.openForTesting(
        windows: true,
        executable: r'C:\offline\app.exe',
        exists: (_) => true,
        load: (_) => calls);

void main() {
  late FakeExternalNativeCalls calls;
  late ExternalProtectedObjects app, bridge;
  late WindowsExchangeFileStore appStore, bridgeStore;
  final messages = <ExchangeMessage>[
    EnrollmentSubmission(
        submissionId: vectorBytes('submissionId'),
        publicPoint: vectorBytes('point'),
        displayLabel: '',
        clientBuild: ''),
    PairingChallengeMessage(
        submissionId: vectorBytes('submissionId'),
        transcript: transcript(),
        publicationEpoch: vectorInt('publicationEpoch'),
        clientLeafDer: vectorBytes('clientDer')),
    PossessionProofMessage(
        submissionId: vectorBytes('submissionId'),
        requestId: vectorBytes('requestId'),
        rawSignature: vectorBytes('transcriptSignature')),
  ];
  final exchangeFailure = isA<ExternalExchangeException>();
  setUp(() {
    calls = FakeExternalNativeCalls();
    final native = adapter(calls);
    app = native.acquireAppObjects();
    bridge = native.acquireBridgeObjects();
    appStore = WindowsExchangeFileStore(app);
    bridgeStore = WindowsExchangeFileStore(bridge);
  });
  tearDown(() {
    app.close();
    bridge.close();
    expect(calls.allocations, isEmpty);
    expect(calls.exchangeReceipts, isEmpty);
  });

  for (var i = 0; i < messages.length; i++) {
    final message = messages[i];
    test(
        'kind ${i + 1}: fixed creator/counterpart, exact P22 bytes, explicit cleanup',
        () {
      final writer = i == 1 ? appStore : bridgeStore;
      final reader = i == 1 ? bridgeStore : appStore;
      final receipt = writer.create(message);
      final id = message.submissionId;
      final actual = switch (i) {
        0 => reader.readSubmission(id),
        1 => reader.readChallenge(id),
        _ => reader.readProof(id)
      };
      final name = ExchangeMessageCodec.fileName(message);
      expect(ExchangeMessageCodec.encode(name, actual!),
          ExchangeMessageCodec.encode(name, message));
      expect(calls.exchangeDeletes, 0);
      expect(() => writer.create(message), throwsA(exchangeFailure));
      expect(() => reader.create(message), throwsA(exchangeFailure));
      expect(
          () => switch (i) {
                0 => writer.readSubmission(id),
                1 => writer.readChallenge(id),
                _ => writer.readProof(id)
              },
          throwsA(exchangeFailure));
      receipt.cleanup();
      expect(calls.exchangeDeletes, 1);
      expect(() => receipt.cleanup(), throwsA(isA<ExternalNativeException>()));
      expect(calls.exchangeFiles, isEmpty);
    });
  }
  test(
      'missing is null; malformed/truncated/oversize/internal ID mismatch hard deny',
      () {
    final id = vectorBytes('submissionId');
    expect(appStore.readSubmission(id), isNull);
    bridgeStore.create(messages.first);
    final key = calls.exchangeFiles.keys.single;
    final bytes = calls.exchangeFiles[key]!;
    for (final bad in [
      Uint8List(1025),
      Uint8List(0),
      bytes.sublist(0, 20),
      changed(bytes, 0),
      changed(bytes, 9),
      Uint8List.fromList([...bytes, 0])
    ]) {
      calls.exchangeFiles[key] = bad;
      expect(() => appStore.readSubmission(id), throwsA(exchangeFailure));
    }
    expect(calls.exchangeDeletes, 0);
  });
  test('P22 rejects malformed writes before any native file operation', () {
    final bad = EnrollmentSubmission(
        submissionId: Uint8List(15),
        publicPoint: vectorBytes('point'),
        displayLabel: '',
        clientBuild: '');
    expect(() => bridgeStore.create(bad), throwsA(exchangeFailure));
    expect(calls.exchangeFiles, isEmpty);
    expect(
        () => appStore.readSubmission(Uint8List(17)), throwsA(exchangeFailure));
    expect(
        () =>
            bridge.createExchange(4, vectorBytes('submissionId'), Uint8List(1)),
        throwsA(isA<ExternalNativeException>()));
    expect(calls.credentialFiles, isEmpty);
  });
  test('unknown entries occupy quota; at 32 reads work, above 32 fail closed',
      () {
    calls.unknownExchangeEntries = 31;
    bridgeStore.create(messages.first);
    expect(appStore.readSubmission(messages.first.submissionId), isNotNull);
    expect(() => appStore.create(messages[1]), throwsA(exchangeFailure));
    calls.unknownExchangeEntries = 32;
    expect(() => appStore.readSubmission(messages.first.submissionId),
        throwsA(exchangeFailure));
    expect(calls.exchangeDeletes, 0);
    expect(calls.unknownExchangeEntries, 32);
  });
  test('replacement cannot be cleaned; failed attempt never retries', () {
    final receipt = bridgeStore.create(messages.first);
    final key = calls.exchangeFiles.keys.single;
    calls.exchangeIdentities[key] = 1000;
    expect(() => receipt.cleanup(), throwsA(isA<ExternalNativeException>()));
    expect(() => receipt.cleanup(), throwsA(isA<ExternalNativeException>()));
    expect(calls.exchangeDeletes, 0);
    expect(calls.exchangeFiles.length, 1);
  });
  test('closed or invalidated owners cannot create/read/clean up', () {
    final receipt = bridgeStore.create(messages.first);
    bridge.close();
    expect(() => bridgeStore.create(messages.first), throwsA(exchangeFailure));
    expect(() => receipt.cleanup(), throwsA(isA<ExternalNativeException>()));
    calls.ownerStatus = 4;
    expect(() => appStore.readSubmission(messages.first.submissionId),
        throwsA(exchangeFailure));
    calls.ownerStatus = 0;
    expect(() => appStore.readSubmission(messages.first.submissionId),
        throwsA(exchangeFailure));
    expect(calls.exchangeDeletes, 0);
  });
  test(
      'every allocation failure and throwing boundary frees memory; files remain inert',
      () {
    for (var offset = 1; offset <= 3; offset++) {
      calls.failAllocation = calls.allocationCount + offset;
      expect(
          () => bridgeStore.create(messages.first), throwsA(exchangeFailure));
      expect(calls.allocations, isEmpty);
    }
    calls.failAllocation = null;
    calls.throwExchange = true;
    expect(() => bridgeStore.create(messages.first), throwsA(exchangeFailure));
    expect(calls.allocations, isEmpty);
    expect(calls.exchangeFiles.length, 1);
    expect(() => appStore.readSubmission(messages.first.submissionId),
        throwsA(exchangeFailure));
    expect(calls.allocations, isEmpty);
    expect(calls.exchangeDeletes, 0);
    calls.throwExchange = false;
  });
  test('malicious native count and release exceptions never return success',
      () {
    bridgeStore.create(messages.first);
    calls.outputLength = 1025;
    expect(() => appStore.readSubmission(messages.first.submissionId),
        throwsA(exchangeFailure));
    calls.outputLength = null;
    calls.throwFree = true;
    expect(() => appStore.readSubmission(messages.first.submissionId),
        throwsA(exchangeFailure));
    expect(calls.allocations, isEmpty);
    calls.throwFree = false;
  });
  test('older ABI3 owner remains usable while optional Exchange fails closed',
      () {
    app.close();
    final legacy = adapter(LegacyCalls(calls)).acquireAppObjects();
    try {
      expect(
          () => WindowsExchangeFileStore(legacy)
              .readSubmission(messages.first.submissionId),
          throwsA(exchangeFailure));
      legacy.ensureOpen();
      expect(calls.allocations, isEmpty);
    } finally {
      legacy.close();
    }
  });
}

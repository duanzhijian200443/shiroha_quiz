import 'dart:ffi';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/data/external/exchange_message_codec.dart';
import 'package:shiroha_quiz/data/external/native/external_native_bindings.dart';
import 'package:shiroha_quiz/data/external/native/windows_external_native.dart';
import 'package:shiroha_quiz/data/external/windows_exchange_file_store.dart';

import 'bootstrap_test_support.dart';
import 'external_native_test_support.dart';
import 'windows_exchange_file_store_test.dart' show adapter;

/// An older ABI-3 helper has P24, but none of the E0 symbols.
final class P24OnlyCalls
    implements ExternalNativeCalls, ExternalNativeExchangeCalls {
  P24OnlyCalls(this.base);
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
  int exchangeCreate(int version, int owner, int kind, Pointer<Uint8> id,
          Pointer<Uint8> input, int length, Pointer<Uint64> receipt) =>
      base.exchangeCreate(version, owner, kind, id, input, length, receipt);
  @override
  int exchangeRead(int version, int owner, int kind, Pointer<Uint8> id,
          Pointer<Uint8> output, int capacity, Pointer<Uint64> written) =>
      base.exchangeRead(version, owner, kind, id, output, capacity, written);
  @override
  int exchangeCleanup(int version, int owner, int receipt) =>
      base.exchangeCleanup(version, owner, receipt);
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unused legacy seam');
}

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
  Matcher failure(ExternalExchangeFailure value) =>
      isA<ExternalExchangeException>()
          .having((e) => e.failure, 'failure', value);
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
    expect(calls.exchangeReadTickets, isEmpty);
    expect(calls.tickets, isEmpty); // E0 never borrows credential transactions.
  });
  ExchangeFileRead<ExchangeMessage>? read(int kind) => switch (kind) {
        1 => appStore.readSubmissionForConsumption(messages[0].submissionId),
        2 => bridgeStore.readChallengeForConsumption(messages[1].submissionId),
        _ => appStore.readProofForConsumption(messages[2].submissionId),
      };

  for (var kind = 1; kind <= 3; kind++) {
    for (final consume in [false, true]) {
      test(
          'kind $kind strict exact bytes then ${consume ? 'consume' : 'release'} once',
          () {
        final message = messages[kind - 1];
        final writer = kind == 2 ? appStore : bridgeStore;
        final receipt = writer.create(message);
        final result = read(kind)!;
        final original = ExchangeMessageCodec.encode(
            ExchangeMessageCodec.fileName(message), message);
        expect(result.bytes, original);
        expect(
            ExchangeMessageCodec.encode(
                ExchangeMessageCodec.fileName(message), result.message),
            original);
        final copy = result.bytes;
        copy.fillRange(0, copy.length, 0);
        expect(result.bytes, original);
        expect(calls.exchangeDeletes, 0);
        if (consume) {
          result.consume();
        } else {
          result.release();
        }
        expect(calls.exchangeDeletes, consume ? 1 : 0);
        expect(calls.exchangeReadTickets, isEmpty);
        expect(result.consume,
            throwsA(failure(ExternalExchangeFailure.invalidInput)));
        expect(result.release,
            throwsA(failure(ExternalExchangeFailure.invalidInput)));
        if (!consume) {
          receipt.cleanup();
          expect(calls.exchangeDeletes, 1);
        }
      });
    }
  }
  test('missing and invalid arguments never acquire a ticket', () {
    expect(read(1), isNull);
    expect(() => appStore.readSubmissionForConsumption(Uint8List(15)),
        throwsA(failure(ExternalExchangeFailure.invalidInput)));
    expect(
        () =>
            bridgeStore.readSubmissionForConsumption(messages[0].submissionId),
        throwsA(failure(ExternalExchangeFailure.invalidInput)));
    expect(calls.exchangeReadTickets, isEmpty);
  });
  test(
      'P22 rejection releases exact native read without deleting or authorizing',
      () {
    bridgeStore.create(messages[0]);
    final key = calls.exchangeFiles.keys.single,
        original = calls.exchangeFiles.values.single;
    for (final bad in [
      original.sublist(0, 20),
      changed(original, 0),
      changed(original, 9),
      Uint8List.fromList([...original, 0])
    ]) {
      calls.exchangeFiles[key] = bad;
      expect(
          () => read(1), throwsA(failure(ExternalExchangeFailure.dataCorrupt)));
      expect(calls.exchangeReadTickets, isEmpty);
    }
    expect(calls.exchangeReleases, 4);
    expect(calls.exchangeDeletes, 0);
    expect(calls.exchangeConsumes, 0);
  });
  test('decode rejection plus release failure denies owner permanently', () {
    bridgeStore.create(messages[0]);
    final key = calls.exchangeFiles.keys.single;
    calls.exchangeFiles[key] =
        Uint8List.fromList([...calls.exchangeFiles[key]!, 0]);
    calls.releaseStatus = 4;
    expect(() => read(1),
        throwsA(failure(ExternalExchangeFailure.temporarilyUnavailable)));
    calls.releaseStatus = 0;
    expect(app.ensureOpen, throwsA(isA<ExternalNativeException>()));
    expect(calls.exchangeDeletes, 0);
  });
  for (final identityChange in [false, true]) {
    test(
        'same name ${identityChange ? 'replacement' : 'same-ID content change'} never deletes',
        () {
      bridgeStore.create(messages[0]);
      final result = read(1)!;
      final key = calls.exchangeFiles.keys.single;
      if (identityChange) {
        calls.exchangeIdentities[key] = 999;
      } else {
        calls.exchangeFiles[key]![30] ^= 1;
      }
      expect(result.consume, throwsA(isA<ExternalExchangeException>()));
      expect(result.consume,
          throwsA(failure(ExternalExchangeFailure.invalidInput)));
      expect(calls.exchangeDeletes, 0);
      expect(calls.exchangeReadTickets, isEmpty);
    });
  }
  test('two pending reads yield at most one successful consumer', () {
    bridgeStore.create(messages[0]);
    final a = read(1)!, b = read(1)!;
    a.consume();
    expect(b.consume, throwsA(isA<ExternalExchangeException>()));
    expect(calls.exchangeDeletes, 1);
    expect(calls.exchangeReadTickets, isEmpty);
  });
  test('P24 creator cleanup remains usable while reader pin is outstanding',
      () {
    final receipt = bridgeStore.create(messages[0]);
    final result = read(1)!;
    receipt.cleanup();
    expect(result.consume, throwsA(isA<ExternalExchangeException>()));
    expect(calls.exchangeDeletes, 1);
  });
  test('owner close releases all unconsumed tickets without deletion', () {
    bridgeStore.create(messages[0]);
    final result = read(1)!;
    app.close();
    app.close();
    expect(result.consume, throwsA(isA<ExternalExchangeException>()));
    expect(calls.exchangeReadTickets, isEmpty);
    expect(calls.exchangeDeletes, 0);
  });
  test(
      '32 pending reads bound repeated reads of one object; release frees a slot',
      () {
    bridgeStore.create(messages[0]);
    final reads = List.generate(32, (_) => read(1)!);
    expect(() => read(1), throwsA(isA<ExternalExchangeException>()));
    reads.first.release();
    read(1)!.release();
    for (final result in reads.skip(1)) {
      result.release();
    }
    expect(calls.exchangeReadTickets, isEmpty);
    expect(calls.exchangeDeletes, 0);
  });
  test('at 32 directory objects consume works; above 32 fails without cleanup',
      () {
    calls.unknownExchangeEntries = 31;
    bridgeStore.create(messages[0]);
    final result = read(1)!;
    calls.unknownExchangeEntries = 32;
    expect(result.consume, throwsA(isA<ExternalExchangeException>()));
    calls.unknownExchangeEntries = 31;
    read(1)!.consume();
    expect(calls.unknownExchangeEntries, 31);
    expect(calls.exchangeDeletes, 1);
  });
  test('all four read allocations fail safely; no leaked memory or deletion',
      () {
    bridgeStore.create(messages[0]);
    for (var offset = 1; offset <= 4; offset++) {
      calls.failAllocation = calls.allocationCount + offset;
      expect(() => read(1), throwsA(isA<ExternalExchangeException>()));
      expect(calls.allocations, isEmpty);
      expect(calls.exchangeReadTickets, isEmpty);
    }
    calls.failAllocation = null;
    expect(calls.exchangeDeletes, 0);
  });
  test('invalid native lengths release tickets before returning failure', () {
    bridgeStore.create(messages[0]);
    for (final size in [0, 1025]) {
      calls.outputLength = size;
      expect(() => read(1), throwsA(isA<ExternalExchangeException>()));
      expect(calls.exchangeReadTickets, isEmpty);
    }
    calls.outputLength = null;
    expect(calls.exchangeReleases, 2);
  });
  test('read buffer-free failure releases pin and denies owner', () {
    bridgeStore.create(messages[0]);
    calls.throwFree = true;
    expect(() => read(1), throwsA(isA<ExternalExchangeException>()));
    calls.throwFree = false;
    expect(calls.exchangeReadTickets, isEmpty);
    expect(calls.exchangeDeletes, 0);
    expect(app.ensureOpen, throwsA(isA<ExternalNativeException>()));
  });
  for (final acquire in [false, true]) {
    test(
        '${acquire ? 'throwing acquire' : 'malformed ticket'} stays owner-bounded until close',
        () {
      bridgeStore.create(messages[0]);
      calls.throwReadBegin = acquire;
      calls.invalidReadTicket = !acquire;
      expect(() => read(1), throwsA(isA<ExternalExchangeException>()));
      expect(app.ensureOpen, throwsA(isA<ExternalNativeException>()));
      expect(calls.exchangeDeletes, 0);
      app.close();
      expect(calls.exchangeReadTickets, isEmpty);
    });
  }
  for (final status in [4, 7, 99]) {
    test(
        'consume status $status spends ticket; unknown cannot report success or retry',
        () {
      bridgeStore.create(messages[0]);
      final result = read(1)!;
      calls.consumptionStatus = status;
      expect(
          result.consume,
          throwsA(failure(status == 4
              ? ExternalExchangeFailure.temporarilyUnavailable
              : ExternalExchangeFailure.commitUnknown)));
      calls.consumptionStatus = 0;
      expect(result.consume,
          throwsA(failure(ExternalExchangeFailure.invalidInput)));
      expect(calls.exchangeConsumes, 1);
      expect(calls.exchangeDeletes, 0);
      if (status != 4) {
        expect(app.ensureOpen, throwsA(isA<ExternalNativeException>()));
      }
    });
  }
  for (final consume in [false, true]) {
    test(
        'throwing ${consume ? 'consume' : 'release'} is terminal and denies owner',
        () {
      bridgeStore.create(messages[0]);
      final result = read(1)!;
      calls.throwConsume = consume;
      calls.throwRelease = !consume;
      expect(
          consume ? result.consume : result.release,
          throwsA(failure(consume
              ? ExternalExchangeFailure.commitUnknown
              : ExternalExchangeFailure.temporarilyUnavailable)));
      expect(app.ensureOpen, throwsA(isA<ExternalNativeException>()));
      expect(result.consume,
          throwsA(failure(ExternalExchangeFailure.invalidInput)));
      expect(calls.exchangeDeletes, 0);
    });
    test(
        'buffer release failure after ${consume ? 'consume' : 'release'} never reports success',
        () {
      bridgeStore.create(messages[0]);
      final result = read(1)!;
      calls.throwFree = true;
      expect(
          consume ? result.consume : result.release,
          throwsA(failure(consume
              ? ExternalExchangeFailure.commitUnknown
              : ExternalExchangeFailure.temporarilyUnavailable)));
      calls.throwFree = false;
      expect(calls.allocations, isEmpty);
      expect(calls.exchangeReadTickets, isEmpty);
      expect(calls.exchangeDeletes, consume ? 1 : 0);
      expect(result.consume,
          throwsA(failure(ExternalExchangeFailure.invalidInput)));
      expect(app.ensureOpen, throwsA(isA<ExternalNativeException>()));
    });
  }
  test(
      'consume allocation failure invalidates local ticket and owner, close reclaims pin',
      () {
    bridgeStore.create(messages[0]);
    final result = read(1)!;
    calls.failAllocation = calls.allocationCount + 1;
    expect(result.consume, throwsA(isA<ExternalExchangeException>()));
    expect(app.ensureOpen, throwsA(isA<ExternalNativeException>()));
    expect(calls.exchangeDeletes, 0);
    app.close();
    expect(calls.exchangeReadTickets, isEmpty);
  });
  test('older P24 DLL keeps plain read working while E0 fails closed', () {
    bridgeStore.create(messages[0]);
    app.close();
    final older = adapter(P24OnlyCalls(calls)).acquireAppObjects();
    try {
      final store = WindowsExchangeFileStore(older);
      expect(store.readSubmission(messages[0].submissionId), isNotNull);
      expect(() => store.readSubmissionForConsumption(messages[0].submissionId),
          throwsA(failure(ExternalExchangeFailure.temporarilyUnavailable)));
      older.ensureOpen();
      expect(calls.exchangeReadTickets, isEmpty);
    } finally {
      older.close();
    }
  });
  test('incomplete optional lifecycle cannot acquire a native pin', () {
    bridgeStore.create(messages[0]);
    calls.exchangeConsumptionAvailable = false;
    expect(() => read(1),
        throwsA(failure(ExternalExchangeFailure.temporarilyUnavailable)));
    expect(calls.exchangeReadTickets, isEmpty);
    app.ensureOpen();
  });
}

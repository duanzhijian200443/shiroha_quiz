import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/external/external_device_connection.dart';
import 'package:shiroha_quiz/data/repositories/external_device_selection_store.dart';
import '../generated_question/generated_test_support.dart';

final class _Store implements ExternalDeviceSelectionStore {
  ExternalDeviceSelection? value;
  bool fail = false;
  @override
  Future<ExternalDeviceSelection?> readDeviceSelection() async => value;
  @override
  Future<void> saveDeviceSelection(ExternalDeviceSelection next) async {
    if (fail) throw StateError('synthetic save failure');
    value = next;
  }

  @override
  Future<void> acknowledgeDeviceCleanup(
      ExternalDeviceSelection expected, ExternalDeviceSelection next) async {
    if (fail ||
        value?.target != expected.target ||
        value?.generation != expected.generation ||
        value?.needsCleanup != expected.needsCleanup) {
      throw const ExternalDeviceException(ExternalDeviceFailure.needsAttention);
    }
    value = next;
  }
}

Matcher failure(ExternalDeviceFailure value) => throwsA(
    isA<ExternalDeviceException>().having((e) => e.failure, 'failure', value));

void main() {
  initializeGeneratedTests();
  const local = ExternalDeviceTarget.windows();
  final phone = ExternalDeviceTarget.android('paired-android');
  late _Store store;
  late ExternalDeviceConnection connection;
  Future<void> Function()? close;
  setUp(() async {
    close = null;
    store = _Store();
    connection = ExternalDeviceConnection(
        store: store,
        availableTargets: () async => [local, phone],
        endConnection: () async => await close?.call());
    await connection.load();
  });

  test('default never selects or connects to a target', () async {
    expect(connection.selection.target.kind, ExternalDeviceKind.unselected);
    await expectLater(
        connection.begin(), failure(ExternalDeviceFailure.targetNotSelected));
    expect(store.value, isNull);
  });
  test('SQLite selection roundtrips and malformed state is preserved',
      () async {
    final h = GeneratedHarness();
    await h.open();
    try {
      final persisted =
          SqliteExternalDeviceSelectionStore(databaseHelper: h.helper);
      expect(await persisted.readDeviceSelection(), isNull);
      await persisted.saveDeviceSelection(ExternalDeviceSelection(
          target: phone, generation: 7, needsCleanup: true));
      final loaded = (await persisted.readDeviceSelection())!;
      expect(loaded.target, phone);
      expect(loaded.generation, 7);
      expect(loaded.needsCleanup, true);
      await h.helper.saveSetting(
          SqliteExternalDeviceSelectionStore.settingKey, '{"version":99}');
      await expectLater(persisted.readDeviceSelection(),
          failure(ExternalDeviceFailure.needsAttention));
      expect(
          await h.helper
              .getSetting(SqliteExternalDeviceSelectionStore.settingKey),
          '{"version":99}');
    } finally {
      await h.close();
    }
  });
  test('dirty record precedes the lease and original settlement clears it',
      () async {
    await connection.select(local);
    final lease = await connection.begin();
    expect(store.value!.needsCleanup, true);
    await expectLater(connection.begin(), failure(ExternalDeviceFailure.busy));
    connection.connected(lease);
    expect(connection.phase, ExternalDevicePhase.connected);
    await connection.settled(lease, clean: true);
    expect(store.value!.needsCleanup, false);
    expect(connection.phase, ExternalDevicePhase.disconnected);
  });
  test('switch waits for old work, then saves target and increments generation',
      () async {
    await connection.select(local);
    final lease = await connection.begin();
    final entered = Completer<void>(), released = Completer<void>();
    close = () async {
      entered.complete();
      await released.future;
      await connection.settled(lease, clean: true);
    };
    final switching = connection.select(phone);
    await entered.future;
    expect(connection.phase, ExternalDevicePhase.ending);
    expect(store.value!.target, local);
    await expectLater(connection.begin(), failure(ExternalDeviceFailure.busy));
    released.complete();
    await switching;
    expect(store.value!.target, phone);
    expect(store.value!.generation, 2);
    expect(store.value!.needsCleanup, false);
  });
  test('failed original cleanup prevents switching and all further admission',
      () async {
    await connection.select(local);
    final lease = await connection.begin();
    close = () => connection.settled(lease, clean: false);
    await expectLater(connection.select(phone),
        failure(ExternalDeviceFailure.needsAttention));
    expect(store.value!.target, local);
    expect(store.value!.needsCleanup, true);
    await expectLater(
        connection.begin(), failure(ExternalDeviceFailure.needsAttention));
    await expectLater(
        connection.select(const ExternalDeviceTarget.unselected()),
        failure(ExternalDeviceFailure.needsAttention));
  });
  test('App restart preserves an unresolved dirty marker', () async {
    await connection.select(phone);
    await connection.begin();
    final restarted = ExternalDeviceConnection(
        store: store,
        availableTargets: () async => [local, phone],
        endConnection: () async {});
    await restarted.load();
    expect(restarted.phase, ExternalDevicePhase.needsAttention);
    await expectLater(
        restarted.begin(), failure(ExternalDeviceFailure.needsAttention));
    expect(store.value!.needsCleanup, true);
    await restarted.close();
  });
  test('unavailable target does not replace the current selection', () async {
    await connection.select(local);
    await expectLater(connection.select(ExternalDeviceTarget.android('absent')),
        failure(ExternalDeviceFailure.targetUnavailable));
    expect(store.value!.target, local);
  });
  test('unknown save outcome fails closed without starting a lease', () async {
    await connection.select(local);
    store.fail = true;
    await expectLater(connection.begin(), throwsStateError);
    expect(connection.phase, ExternalDevicePhase.needsAttention);
    await expectLater(
        connection.begin(), failure(ExternalDeviceFailure.needsAttention));
  });

  Future<ExternalDeviceConnection> interrupted(
      Future<void> Function(ExternalDeviceTarget) proof) async {
    store.value = ExternalDeviceSelection(
        target: phone, generation: 11, needsCleanup: true);
    final restored = ExternalDeviceConnection(
        store: store,
        availableTargets: () async => [local, phone],
        endConnection: () async {},
        verifyRecovery: proof);
    await restored.load();
    return restored;
  }

  test('manual recovery waits for original proof and increments generation',
      () async {
    final entered = Completer<void>(), settled = Completer<void>();
    final restored = await interrupted((target) async {
      expect(target, phone);
      entered.complete();
      await settled.future;
    });
    expect(restored.canRecover, true);
    final work = restored.recover(11, isCurrent: () => true);
    await entered.future;
    expect(store.value!.needsCleanup, true);
    await expectLater(
        restored.begin(), failure(ExternalDeviceFailure.needsAttention));
    settled.complete();
    await work;
    expect(store.value!.needsCleanup, false);
    expect(store.value!.generation, 12);
    expect(store.value!.target, phone);
    final lease = await restored.begin();
    await restored.settled(lease, clean: true);
    await restored.close();
  });

  test('failed recovery proof preserves original marker and target', () async {
    final restored =
        await interrupted((_) async => throw StateError('proof failed'));
    await expectLater(
        restored.recover(11, isCurrent: () => true), throwsStateError);
    expect(store.value!.needsCleanup, true);
    expect(store.value!.generation, 11);
    expect(restored.phase, ExternalDevicePhase.needsAttention);
    await restored.close();
  });

  test('recovery cannot overwrite a changed persisted selection', () async {
    final restored = await interrupted((_) async {
      store.value = ExternalDeviceSelection(
          target: local, generation: 12, needsCleanup: true);
    });
    await expectLater(restored.recover(11, isCurrent: () => true),
        failure(ExternalDeviceFailure.needsAttention));
    expect(store.value!.target, local);
    expect(store.value!.needsCleanup, true);
    await restored.close();
  });

  test('leaving the view or closing the App prevents late recovery publication',
      () async {
    for (final appClose in [false, true]) {
      var current = true;
      final entered = Completer<void>(), settled = Completer<void>();
      final restored = await interrupted((_) async {
        entered.complete();
        await settled.future;
      });
      final work = restored.recover(11, isCurrent: () => current);
      await entered.future;
      if (appClose) {
        restored.withdraw();
      } else {
        current = false;
      }
      settled.complete();
      await expectLater(work, failure(ExternalDeviceFailure.needsAttention));
      expect(store.value!.needsCleanup, true);
      await restored.close();
    }
  });

  test(
      'SQLite cleanup acknowledgment is conditional and preserves corrupt records',
      () async {
    final h = GeneratedHarness();
    await h.open();
    try {
      final persisted =
          SqliteExternalDeviceSelectionStore(databaseHelper: h.helper);
      final before = ExternalDeviceSelection(
          target: phone, generation: 11, needsCleanup: true);
      final after = ExternalDeviceSelection(target: phone, generation: 12);
      await persisted.saveDeviceSelection(before);
      await persisted.acknowledgeDeviceCleanup(before, after);
      expect((await persisted.readDeviceSelection())!.needsCleanup, false);
      await expectLater(persisted.acknowledgeDeviceCleanup(before, after),
          failure(ExternalDeviceFailure.needsAttention));
      await h.helper.saveSetting(
          SqliteExternalDeviceSelectionStore.settingKey, '{"version":99}');
      await expectLater(persisted.acknowledgeDeviceCleanup(before, after),
          failure(ExternalDeviceFailure.needsAttention));
      expect(
          await h.helper
              .getSetting(SqliteExternalDeviceSelectionStore.settingKey),
          '{"version":99}');
    } finally {
      await h.close();
    }
  });
}

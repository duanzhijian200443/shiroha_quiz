import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/backup/backup_restore_gate.dart';
import 'package:shiroha_quiz/application/external/external_device_connection.dart';
import 'package:shiroha_quiz/data/repositories/external_device_selection_store.dart';
import 'package:shiroha_quiz/domain/backup/backup_failure.dart';
import 'package:shiroha_quiz/domain/backup/backup_manifest.dart';
import '../generated_question/generated_test_support.dart';

final class _Store implements ExternalDeviceSelectionStore {
  ExternalDeviceSelection? value;
  bool fail = false;
  Future<void> Function()? beforeSave;
  @override
  Future<ExternalDeviceSelection?> readDeviceSelection() async => value;
  @override
  Future<void> saveDeviceSelection(ExternalDeviceSelection next) async {
    await beforeSave?.call();
    if (fail) throw StateError('synthetic save failure');
    value = next;
  }

  @override
  Future<void> settleDeviceLease(ExternalDeviceLease lease) async {
    lease.requireSettlement(this);
    await saveDeviceSelection(ExternalDeviceSelection(
        target: lease.target, generation: lease.generation));
  }

  @override
  Future<void> acknowledgeDeviceCleanup(
      ExternalDeviceSelection expected, ExternalDeviceSelection next,
      {required bool Function() isCurrent}) async {
    if (!isCurrent() ||
        fail ||
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
  Future<List<ExternalDeviceTarget>> Function()? available;
  setUp(() async {
    close = null;
    available = null;
    store = _Store();
    connection = ExternalDeviceConnection(
        store: store,
        availableTargets: () async => await available?.call() ?? [local, phone],
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

  test('App close joins selection drain and prevents the late target write',
      () async {
    await connection.select(local);
    final lease = await connection.begin();
    final entered = Completer<void>(), release = Completer<void>();
    close = () async {
      entered.complete();
      await release.future;
      await connection.settled(lease, clean: true);
    };
    final switching = connection
        .select(phone)
        .then((_) => true, onError: (Object _) => false);
    await entered.future;
    var ended = false;
    final closing = connection
        .close()
        .then((_) => ended = true, onError: (Object _) => ended = true);
    await Future<void>.delayed(Duration.zero);
    final endedBeforeDrain = ended;
    release.complete();
    final selected = await switching;
    await closing;
    expect(endedBeforeDrain, false);
    expect(selected, false);
    expect(store.value!.target, local);
    expect(store.value!.generation, lease.generation);
    expect(store.value!.needsCleanup, false);
  });

  for (final saveFails in [false, true]) {
    test('App close joins dirty-marker persistence: saveFails=$saveFails',
        () async {
      await connection.select(local);
      final entered = Completer<void>(), release = Completer<void>();
      store.beforeSave = () async {
        entered.complete();
        await release.future;
      };
      store.fail = saveFails;
      final acquiring = connection.begin().then<ExternalDeviceLease?>(
          (lease) => lease,
          onError: (Object _) => null);
      await entered.future;
      var ended = false;
      final closing = connection.close().then((_) {
        ended = true;
        return true;
      }, onError: (Object _) {
        ended = true;
        return false;
      });
      await Future<void>.delayed(Duration.zero);
      final endedBeforeSave = ended;
      release.complete();
      final lease = await acquiring;
      final clean = await closing;
      store.beforeSave = null;
      expect(endedBeforeSave, false);
      if (saveFails) {
        expect(lease, isNull);
        expect(connection.phase, ExternalDevicePhase.needsAttention);
      } else {
        expect(clean, false);
        expect(lease, isNotNull);
        expect(store.value!.needsCleanup, true);
        // Only the original borrower can finish this late lease. Until then
        // App close must fail, so B0 cannot close/swap the database.
        await connection.settled(lease!, clean: true);
        expect(store.value!.needsCleanup, false);
      }
    });
  }

  for (final selecting in [false, true]) {
    test(
        'App close joins availability before new persistence: select=$selecting',
        () async {
      await connection.select(local);
      final entered = Completer<void>(), release = Completer<void>();
      available = () async {
        entered.complete();
        await release.future;
        return [local, phone];
      };
      final operation =
          (selecting ? connection.select(phone) : connection.begin())
              .then((_) => true, onError: (Object _) => false);
      await entered.future;
      var ended = false;
      final closing = connection.close().then((_) => ended = true);
      await Future<void>.delayed(Duration.zero);
      final endedBeforeAvailability = ended;
      release.complete();
      final admitted = await operation;
      await closing;
      expect(endedBeforeAvailability, false);
      expect(admitted, false);
      expect(store.value!.target, local);
      expect(store.value!.needsCleanup, false);
      await expectLater(
          connection.begin(), failure(ExternalDeviceFailure.needsAttention));
    });
  }
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

  test('only current original clean settlement can consume a live lease',
      () async {
    await connection.select(local);
    final first = await connection.begin();
    await expectLater(store.settleDeviceLease(first),
        failure(ExternalDeviceFailure.needsAttention));
    await connection.settled(first, clean: true);
    final next = await connection.begin();
    await expectLater(connection.settled(first, clean: true),
        failure(ExternalDeviceFailure.needsAttention));
    await expectLater(store.settleDeviceLease(first),
        failure(ExternalDeviceFailure.needsAttention));
    expect(store.value!.needsCleanup, true);
    await expectLater(connection.settled(next, clean: false),
        failure(ExternalDeviceFailure.needsAttention));
    await expectLater(connection.settled(next, clean: true),
        failure(ExternalDeviceFailure.needsAttention));
    expect(store.value!.needsCleanup, true);
  });

  test(
      'SQLite original cleanup during maintenance retains all other write gates',
      () async {
    final h = GeneratedHarness();
    await h.open();
    final persisted =
        SqliteExternalDeviceSelectionStore(databaseHelper: h.helper);
    final owner = ExternalDeviceConnection(
        store: persisted,
        availableTargets: () async => [local],
        endConnection: () async {});
    try {
      await owner.load();
      await owner.select(local);
      final lease = await owner.begin();
      await BackupRestoreMutationGate.instance.enterQuiescence();
      final blocked = throwsA(isA<BackupException>()
          .having((e) => e.failure, 'failure', BackupFailure.restoreBlocked));
      await expectLater(
          persisted.saveDeviceSelection(ExternalDeviceSelection(target: phone)),
          blocked);
      await expectLater(
          persisted.acknowledgeDeviceCleanup(
              ExternalDeviceSelection(
                  target: phone, generation: 11, needsCleanup: true),
              ExternalDeviceSelection(target: phone, generation: 12),
              isCurrent: () => true),
          blocked);
      owner.withdraw();
      await owner.settled(lease, clean: true);
      final saved = (await persisted.readDeviceSelection())!;
      expect(saved.needsCleanup, false);
      expect(saved.target, local);
      expect(saved.generation, lease.generation);
      await expectLater(persisted.settleDeviceLease(lease),
          failure(ExternalDeviceFailure.needsAttention));
      await owner.close();
    } finally {
      BackupRestoreMutationGate.instance.exitQuiescence();
      await h.close();
    }
  });

  test('SQLite live cleanup cannot overwrite a changed dirty generation',
      () async {
    final h = GeneratedHarness();
    await h.open();
    final persisted =
        SqliteExternalDeviceSelectionStore(databaseHelper: h.helper);
    final owner = ExternalDeviceConnection(
        store: persisted,
        availableTargets: () async => [local],
        endConnection: () async {});
    try {
      await owner.load();
      await owner.select(local);
      final lease = await owner.begin();
      await persisted.saveDeviceSelection(ExternalDeviceSelection(
          target: phone, generation: lease.generation + 1, needsCleanup: true));
      await expectLater(owner.settled(lease, clean: true),
          failure(ExternalDeviceFailure.needsAttention));
      final saved = (await persisted.readDeviceSelection())!;
      expect(saved.needsCleanup, true);
      expect(saved.target, phone);
      expect(saved.generation, lease.generation + 1);
      expect(owner.phase, ExternalDevicePhase.needsAttention);
    } finally {
      await h.close();
    }
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

  for (final appClose in [false, true]) {
    test(
        'SQLite-wait recovery withdrawal retains dirty state: appClose=$appClose',
        () async {
      final h = GeneratedHarness();
      await h.open();
      final persisted =
          SqliteExternalDeviceSelectionStore(databaseHelper: h.helper);
      final blocked = Completer<void>(), release = Completer<void>();
      var current = true;
      final restored = ExternalDeviceConnection(
          store: persisted,
          availableTargets: () async => [phone],
          endConnection: () async {},
          verifyRecovery: (_) async {});
      Future<void>? holdingDatabase;
      try {
        await persisted.saveDeviceSelection(ExternalDeviceSelection(
            target: phone, generation: 11, needsCleanup: true));
        await restored.load();
        holdingDatabase = h.db.transaction<void>((txn) async {
          blocked.complete();
          await release.future;
        });
        await blocked.future;
        final recovery = restored.recover(11, isCurrent: () => current);
        final refused = expectLater(
            recovery, failure(ExternalDeviceFailure.needsAttention));
        await Future<void>.delayed(Duration.zero);
        expect(BackupRestoreMutationGate.instance.activeMutationCount, 1,
            reason:
                'Recovery reached its mutation lease and is queued behind SQLite.');
        if (appClose) {
          restored.withdraw();
        } else {
          current = false;
        }
        release.complete();
        await holdingDatabase;
        await refused;
        final saved = (await persisted.readDeviceSelection())!;
        expect(saved.needsCleanup, true);
        expect(saved.generation, 11);
        expect(saved.target, phone);
        expect(restored.phase, ExternalDevicePhase.needsAttention);
      } finally {
        if (!release.isCompleted) release.complete();
        await holdingDatabase;
        await restored.close();
        await h.close();
      }
    });
  }

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
      await persisted.acknowledgeDeviceCleanup(before, after,
          isCurrent: () => true);
      expect((await persisted.readDeviceSelection())!.needsCleanup, false);
      await expectLater(
          persisted.acknowledgeDeviceCleanup(before, after,
              isCurrent: () => true),
          failure(ExternalDeviceFailure.needsAttention));
      await h.helper.saveSetting(
          SqliteExternalDeviceSelectionStore.settingKey, '{"version":99}');
      await expectLater(
          persisted.acknowledgeDeviceCleanup(before, after,
              isCurrent: () => true),
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

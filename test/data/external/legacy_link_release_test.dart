import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/external/link/host_handoff.dart';
import 'package:shiroha_quiz/data/external/link/link_values.dart';
import 'package:shiroha_quiz/data/repositories/legacy_link_handoff_repository.dart';

final class AppDatabase implements DatabaseHelper {
  AppDatabase(this.value);
  final Database value;
  @override
  Future<Database> get database async => value;
  @override
  Future<String?> getSetting(String key) async {
    final rows =
        await value.query('app_settings', where: 'key=?', whereArgs: [key]);
    return rows.isEmpty ? null : rows.single['value'] as String;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  sqfliteFfiInit();
  late Database db;
  late Directory slot;
  late LegacyLinkHandoffRepository old;
  late String raw;
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await db.execute(
        'CREATE TABLE app_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
    raw = jsonEncode({
      'version': 1,
      'kind': 'android',
      'reference': 'phone',
      'generation': 7,
      'needsCleanup': false
    });
    await db.insert('app_settings',
        {'key': LegacyLinkHandoffRepository.selectionKey, 'value': raw});
    await db.insert('app_settings',
        {'key': 'generated_proposal_local_owner', 'value': 'original-app'});
    slot = await Directory.systemTemp.createTemp('link-release-');
    old = LegacyLinkHandoffRepository(
        database: AppDatabase(db),
        slotRef: 'phone',
        closeOriginalOwners: () async {},
        readOriginalBinding: () async =>
            LinkVerifiedTarget('a' * 64, 'installation', 'profile'));
  });
  tearDown(() async {
    await db.close();
    await slot.delete(recursive: true);
  });
  test(
      'old App transaction binds exact clean row and durable owner before RELEASED',
      () async {
    final store = HostHandoffStore(slot);
    final released = await store.release(old, 'new-owner');
    expect(released.phase, HostHandoffPhase.released);
    final rows = await db.query('app_settings',
        where: 'key=?', whereArgs: [LegacyLinkHandoffRepository.selectionKey]);
    expect(jsonDecode(rows.single['value'] as String), {
      'version': 2,
      'state': 'released',
      'handoffId': released.handoffId,
      'releaseRecordRef': released.releaseRecordRef
    });
    expect((await store.release(old, 'new-owner')).digest, released.digest);
  });
  test(
      'SQLite fault rolls back release and tombstone together; PREPARED survives',
      () async {
    await db.execute(
        "CREATE TRIGGER fail_release BEFORE UPDATE ON app_settings BEGIN SELECT RAISE(ABORT, 'synthetic'); END");
    final store = HostHandoffStore(slot);
    await expectLater(store.release(old, 'new-owner'), throwsA(anything));
    expect((await store.read())!.phase, HostHandoffPhase.prepared);
    expect(
        await AppDatabase(db)
            .getSetting(LegacyLinkHandoffRepository.selectionKey),
        raw);
    expect(
        await AppDatabase(db)
            .getSetting(LegacyLinkHandoffRepository.releaseKey),
        isNull);
    await db.execute('DROP TRIGGER fail_release');
    expect((await store.release(old, 'new-owner')).phase,
        HostHandoffPhase.released);
  });
  test('dirty or absent legacy state never becomes a fresh transferable slot',
      () async {
    await db.update(
        'app_settings', {'value': raw.replaceFirst('false', 'true')},
        where: 'key=?', whereArgs: [LegacyLinkHandoffRepository.selectionKey]);
    final store = HostHandoffStore(slot);
    await expectLater(
        store.release(old, 'new-owner'), throwsA(isA<LinkException>()));
    expect(await store.read(), isNull);
    await db.delete('app_settings',
        where: 'key=?', whereArgs: [LegacyLinkHandoffRepository.selectionKey]);
    await expectLater(
        store.release(old, 'new-owner'), throwsA(isA<LinkException>()));
    expect(await store.read(), isNull);
  });
}

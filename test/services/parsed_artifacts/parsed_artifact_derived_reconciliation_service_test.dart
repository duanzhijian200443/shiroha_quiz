import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/application/backup/backup_restore_gate.dart';
import 'package:shiroha_quiz/application/parsed_artifacts/parsed_artifact_lifecycle.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/repositories/parsed_artifact_derived_maintenance_repository.dart';
import 'package:shiroha_quiz/services/file_library/managed_artifact_storage_adapter.dart';
import 'package:shiroha_quiz/services/parsed_artifacts/parsed_artifact_derived_reconciliation_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final class _UnavailableCurrentArtifacts
    implements ParsedArtifactLifecyclePort {
  @override
  Future<ParsedArtifactSnapshot> getCurrentArtifact(String fileId) async =>
      throw StateError('current artifact cannot be verified');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory temp;
  late Directory managed;
  late DatabaseHelper helper;
  late ManagedArtifactStorageAdapter storage;
  late ParsedArtifactDerivedReconciliationService reconciliation;

  setUp(() async {
    BackupRestoreMutationGate.resetForTesting();
    temp = await Directory.systemTemp.createTemp('derived_reconciliation_');
    managed = Directory(p.join(temp.path, 'managed'))..createSync();
    final dbDir = Directory(p.join(temp.path, 'db'))..createSync();
    await databaseFactory.setDatabasesPath(dbDir.path);
    DatabaseHelper.configureRuntimeProfile(DatabaseRuntimeProfile.explicitFile,
        databasePath: dbDir.path);
    helper = DatabaseHelper.instance;
    storage = ManagedArtifactStorageAdapter(managedRoot: managed);
    reconciliation = ParsedArtifactDerivedReconciliationService(
      derivedRows: SqliteParsedArtifactDerivedMaintenanceRepository(
          databaseHelper: helper),
      managedRoot: managed,
      storage: storage,
      artifacts: _UnavailableCurrentArtifacts(),
    );
  });

  tearDown(() async {
    await helper.close();
    await DatabaseHelper.resetRuntimeProfileForTesting();
    BackupRestoreMutationGate.resetForTesting();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('crash residue and stale retrieval build reconcile idempotently',
      () async {
    final key = storage.allocateArtifactStorageKey('orphan-1');
    await storage.writeArtifact(storageKey: key, bytes: <int>[1, 2, 3]);
    final temporary =
        File(p.join(managed.path, 'artifacts', 'orphan-2.json.tmp.123.1'));
    await temporary.writeAsBytes(<int>[4, 5, 6]);
    final db = await helper.database;
    await db.insert('library_files', <String, Object?>{
      'file_id': 'file-1',
      'display_name': 'Synthetic file',
      'mime_type': 'text/plain',
      'size_bytes': 1,
      'sha256': 'a' * 64,
      'storage_key': 'library/file-1',
      'created_at': 10,
    });
    await db.insert('retrieval_index_builds', <String, Object?>{
      'build_id': 'b' * 64,
      'file_id': 'file-1',
      'artifact_id': 'orphan-1',
      'revision': 1,
      'payload_digest': 'c' * 64,
      'chunker_version': '1',
      'lexical_projection_version': '1',
      'chunk_count': 0,
      'chunk_digest': 'd' * 64,
    });

    final first = await reconciliation.reconcile();
    expect(first.outcome, ParsedArtifactDerivedReconciliationOutcome.complete);
    expect(first.staleSidecars, 2);
    expect(first.deletedSidecars, 2);
    expect(first.staleRetrievalBuilds, 1);
    expect(await File(p.join(managed.path, key)).exists(), isFalse);
    expect(await temporary.exists(), isFalse);
    expect(await db.query('retrieval_index_builds'), isEmpty);

    final second = await reconciliation.reconcile();
    expect(second.outcome, ParsedArtifactDerivedReconciliationOutcome.complete);
    expect(second.staleSidecars, 0);
    expect(second.staleRetrievalBuilds, 0);
  });

  test('unknown physical entry retains every sidecar', () async {
    final key = storage.allocateArtifactStorageKey('orphan-1');
    await storage.writeArtifact(storageKey: key, bytes: <int>[1]);
    await Directory(p.join(managed.path, 'artifacts', 'unexpected')).create();
    final result = await reconciliation.reconcile();
    expect(
        result.outcome, ParsedArtifactDerivedReconciliationOutcome.incomplete);
    expect(result.deletedSidecars, 0);
    expect(await File(p.join(managed.path, key)).exists(), isTrue);
  });

  test('unverified current artifact retains stale sidecars', () async {
    final key = storage.allocateArtifactStorageKey('orphan-1');
    await storage.writeArtifact(storageKey: key, bytes: <int>[1]);
    final db = await helper.database;
    await db.insert('library_files', <String, Object?>{
      'file_id': 'file-1',
      'display_name': 'Synthetic file',
      'mime_type': 'text/plain',
      'size_bytes': 1,
      'sha256': 'a' * 64,
      'storage_key': 'library/file-1',
      'created_at': 10,
    });
    await db.insert('parsed_artifact_heads', <String, Object?>{
      'file_id': 'file-1',
      'last_revision': 1,
    });
    await db.insert('parsed_artifacts', <String, Object?>{
      'file_id': 'file-1',
      'artifact_id': 'current-1',
      'revision': 1,
      'source_sha256': 'a' * 64,
      'cache_key_version': 1,
      'cache_fingerprint': 'fingerprint',
      'parser_route': 'synthetic',
      'parser_version': '1',
      'options_schema_version': 1,
      'payload_schema_version': 1,
      'storage_key': 'artifacts/current-1.json',
      'payload_sha256': 'b' * 64,
      'size_bytes': 1,
      'published_at': 1,
    });
    final result = await reconciliation.reconcile();
    expect(
        result.outcome, ParsedArtifactDerivedReconciliationOutcome.incomplete);
    expect(result.deletedSidecars, 0);
    expect(await File(p.join(managed.path, key)).exists(), isTrue);
  });
}

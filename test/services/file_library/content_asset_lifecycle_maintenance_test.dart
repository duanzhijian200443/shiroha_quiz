import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/application/backup/backup_restore_gate.dart';
import 'package:shiroha_quiz/application/content/content_asset_maintenance.dart';
import 'package:shiroha_quiz/application/import_review/typed_review_snapshot.dart';
import 'package:shiroha_quiz/application/parsed_artifacts/parsed_artifact_lifecycle.dart';
import 'package:shiroha_quiz/core/database/content_asset_reclamation_v27_schema.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/persistence/question_v2_persistence_mapper.dart';
import 'package:shiroha_quiz/data/repositories/content_asset_reclamation_observation_repository.dart';
import 'package:shiroha_quiz/data/repositories/content_asset_root_page_repository.dart';
import 'package:shiroha_quiz/data/repositories/library_file_repository.dart';
import 'package:shiroha_quiz/data/repositories/question_repository.dart';
import 'package:shiroha_quiz/domain/assets/asset_ref.dart';
import 'package:shiroha_quiz/domain/assets/library_file.dart';
import 'package:shiroha_quiz/domain/assets/parsed_artifact.dart';
import 'package:shiroha_quiz/domain/assets/sourced_asset_ref.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/domain/source/source_document.dart';
import 'package:shiroha_quiz/domain/source/source_part.dart';
import 'package:shiroha_quiz/services/file_library/content_asset_lifecycle_maintenance_service.dart';
import 'package:shiroha_quiz/services/file_library/library_file_deletion_service.dart';
import 'package:shiroha_quiz/services/file_library/managed_artifact_storage_adapter.dart';
import 'package:shiroha_quiz/services/file_library/managed_content_asset_store.dart';
import 'package:shiroha_quiz/services/file_library/managed_file_storage_adapter.dart';
import 'package:shiroha_quiz/services/file_library/windows_reparse_point_probe.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final class _NoCurrentArtifact implements ParsedArtifactLifecyclePort {
  ParsedArtifactSnapshot? current;

  @override
  Future<ParsedArtifactSnapshot> getCurrentArtifact(String fileId) async =>
      current ?? (throw StateError('unexpected current artifact'));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Serves an empty root set for the first scans, then reports [owningDraft]
/// as a live root so a sweep sees ownership return after ledger admission.
final class _DriftRootPages implements ContentAssetRootPagePort {
  _DriftRootPages({
    required this.owningDraft,
    required this.draftFromScan,
    this.onRootScan,
  });

  final QuestionDraftV2 owningDraft;
  final int draftFromScan;
  final void Function(int rootScan)? onRootScan;
  int _questionScans = 0;

  @override
  Future<List<QuestionDraftV2?>> questionPage({
    required int offset,
    required int limit,
  }) async {
    if (offset > 0) return const <QuestionDraftV2?>[];
    _questionScans++;
    onRootScan?.call(_questionScans);
    if (_questionScans < draftFromScan) return const <QuestionDraftV2?>[];
    return <QuestionDraftV2?>[owningDraft];
  }

  @override
  Future<List<String>> currentArtifactFileIdsPage({
    required int offset,
    required int limit,
  }) async =>
      const <String>[];

  @override
  Future<List<ContentAssetTaskRootRow>> importTaskPage({
    required int offset,
    required int limit,
  }) async =>
      const <ContentAssetTaskRootRow>[];
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
  late ManagedContentAssetStore store;
  late ContentAssetReclamationObservationRepository observations;
  late ContentAssetLifecycleMaintenanceService maintenance;
  late _NoCurrentArtifact artifacts;
  late int now;

  setUp(() async {
    BackupRestoreMutationGate.resetForTesting();
    temp = await Directory.systemTemp.createTemp('content_lifecycle_');
    managed = Directory(p.join(temp.path, 'managed'))..createSync();
    final dbDir = Directory(p.join(temp.path, 'db'))..createSync();
    await databaseFactory.setDatabasesPath(dbDir.path);
    DatabaseHelper.configureRuntimeProfile(
      DatabaseRuntimeProfile.explicitFile,
      databasePath: dbDir.path,
    );
    helper = DatabaseHelper.instance;
    store = ManagedContentAssetStore(managedRoot: managed);
    observations = ContentAssetReclamationObservationRepository(
      databaseHelper: helper,
    );
    now = 1000000;
    artifacts = _NoCurrentArtifact();
    maintenance = ContentAssetLifecycleMaintenanceService(
      rootPages: SqliteContentAssetRootPageRepository(databaseHelper: helper),
      contentAssets: store,
      parsedArtifacts: artifacts,
      observations: observations,
      nowUtcSeconds: () => now,
    );
    store.storeBytesSync(
      sourceId: 'source-1',
      localAssetId: 'asset-1',
      bytes: base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
        '+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      ),
      mimeType: 'image/png',
    );
  });

  tearDown(() async {
    await helper.close();
    await DatabaseHelper.resetRuntimeProfileForTesting();
    BackupRestoreMutationGate.resetForTesting();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Future<List<Map<String, Object?>>> rows() async =>
      (await helper.database).query(contentAssetReclamationTable);

  QuestionDraftV2 imageDraft(String questionId) => QuestionDraftV2(
        questionId: questionId,
        kind: QuestionKind.shortAnswer,
        stem: RichContent(nodes: <ContentNode>[
          ImageNode(sourceId: 'source-1', localAssetId: 'asset-1'),
        ]),
        sourceRefs: <SourceRef>[SourceRef.document(sourceId: 'source-1')],
        assetRefs: <SourcedAssetRef>[
          SourcedAssetRef(
            sourceId: 'source-1',
            asset: AssetRef(assetId: 'asset-1', kind: AssetKind.image),
          ),
        ],
      );

  test('G1-G3 first scan, pending scan, and 72h complete scan', () async {
    final first = await maintenance.reportOnly();
    expect(first.outcome, ContentAssetMaintenanceOutcome.complete);
    expect(first.unobservedCount, 1);
    expect(first.deletedCount, 0);
    expect((await rows()).single['first_unreachable_at'], now);

    now += ContentAssetLifecycleMaintenanceService.graceSeconds - 1;
    final pending = await maintenance.sweepEligible();
    expect(pending.gracePendingCount, 1);
    expect(pending.deletedCount, 0);

    now++;
    final eligible = await maintenance.sweepEligible();
    expect(eligible.outcome, ContentAssetMaintenanceOutcome.complete);
    expect(eligible.graceEligibleCount, 1);
    expect(eligible.deletedCount, 1);
    expect(
        await store.assetExists(sourceId: 'source-1', localAssetId: 'asset-1'),
        isFalse);
  });

  test('I3 deletes no more than 32 after complete proof', () async {
    final bytes = await File(
            p.join(managed.path, 'content_assets', 'source-1', 'asset-1'))
        .readAsBytes();
    for (var index = 2; index <= 33; index++) {
      store.storeBytesSync(
        sourceId: 'source-1',
        localAssetId: 'asset-$index',
        bytes: bytes,
        mimeType: 'image/png',
      );
    }
    expect((await maintenance.reportOnly()).unobservedCount, 33);
    now += ContentAssetLifecycleMaintenanceService.graceSeconds;
    final first = await maintenance.sweepEligible();
    expect(first.outcome, ContentAssetMaintenanceOutcome.complete);
    expect(first.graceEligibleCount, 33);
    expect(first.deletedCount, 32);
    final second = await maintenance.sweepEligible();
    expect(second.outcome, ContentAssetMaintenanceOutcome.complete);
    expect(second.deletedCount, 1);
  });

  test('physical delete failure retains bytes and durable grace evidence',
      () async {
    expect((await maintenance.reportOnly()).unobservedCount, 1);
    now += ContentAssetLifecycleMaintenanceService.graceSeconds;
    final path = p.join(managed.path, 'content_assets', 'source-1', 'asset-1');
    final protected = await Process.run('attrib', <String>['+R', path]);
    expect(protected.exitCode, 0);
    try {
      final result = await maintenance.sweepEligible();
      expect(result.outcome, ContentAssetMaintenanceOutcome.deleteFailed);
      expect(result.deletedCount, 0);
      expect(await File(path).exists(), isTrue);
      expect(await rows(), hasLength(1));
    } finally {
      final unprotected = await Process.run('attrib', <String>['-R', path]);
      expect(unprotected.exitCode, 0);
    }
  },
      skip: !Platform.isWindows
          ? 'Windows-only filesystem semantics: read-only attribute blocks unlink'
          : null);

  test('target mutation in the delete window blocks the exact delete',
      () async {
    final path = p.join(managed.path, 'content_assets', 'source-1', 'asset-1');
    final original = await File(path).readAsBytes();
    final armed = ContentAssetLifecycleMaintenanceService(
      rootPages: SqliteContentAssetRootPageRepository(databaseHelper: helper),
      contentAssets: store,
      parsedArtifacts: artifacts,
      observations: observations,
      nowUtcSeconds: () => now,
      beforeExactDeleteForTesting: () =>
          File(path).writeAsBytes(<int>[...original, 0x00]),
    );

    expect((await armed.reportOnly()).unobservedCount, 1);
    now += ContentAssetLifecycleMaintenanceService.graceSeconds;

    final result = await armed.sweepEligible();
    expect(result.outcome, ContentAssetMaintenanceOutcome.deleteFailed);
    expect(result.deletedCount, 0);
    expect(await File(path).exists(), isTrue);
    expect(await File(path).readAsBytes(), isNot(original));
    expect(await rows(), hasLength(1));
  });

  test('root reacquisition after ledger admission aborts before deletion',
      () async {
    final withDrift = ContentAssetLifecycleMaintenanceService(
      rootPages: _DriftRootPages(
        owningDraft: imageDraft('q-1'),
        draftFromScan: 3,
      ),
      contentAssets: store,
      parsedArtifacts: artifacts,
      observations: observations,
      nowUtcSeconds: () => now,
    );

    expect((await withDrift.reportOnly()).unobservedCount, 1);
    now += ContentAssetLifecycleMaintenanceService.graceSeconds;

    final result = await withDrift.sweepEligible();
    expect(result.graceEligibleCount, 1);
    expect(result.outcome, ContentAssetMaintenanceOutcome.revalidationFailed);
    expect(result.deletedCount, 0);
    expect(
        await store.assetExists(sourceId: 'source-1', localAssetId: 'asset-1'),
        isTrue);
    expect(await rows(), hasLength(1));
  });

  test('Windows junction replacement fails fresh path proof', () async {
    expect((await maintenance.reportOnly()).unobservedCount, 1);
    now += ContentAssetLifecycleMaintenanceService.graceSeconds;
    final content = Directory(p.join(managed.path, 'content_assets'));
    final source = Directory(p.join(content.path, 'source-1'));
    final moved = Directory(p.join(temp.path, 'moved_source'));
    await source.rename(moved.path);
    final external = Directory(p.join(temp.path, 'external'))..createSync();
    final externalAsset = File(p.join(external.path, 'asset-1'));
    await externalAsset.writeAsBytes(
      await File(p.join(moved.path, 'asset-1')).readAsBytes(),
    );
    final created = await Process.run('powershell', <String>[
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      r'New-Item -ItemType Junction -Path $env:DM_LINK_PATH '
          r'-Target $env:DM_TARGET_PATH | Out-Null',
    ], environment: <String, String>{
      'DM_LINK_PATH': source.path,
      'DM_TARGET_PATH': external.path,
    });
    expect(created.exitCode, 0);
    expect(WindowsReparsePointProbe.isReparsePoint(source.path), isTrue);
    final result = await maintenance.sweepEligible();
    expect(result.deletedCount, 0);
    expect(result.outcome, ContentAssetMaintenanceOutcome.incompleteInventory);
    expect(await externalAsset.exists(), isTrue);
    await Link(source.path).delete();
  },
      skip: !Platform.isWindows
          ? 'Windows-only filesystem semantics: junction replacement'
          : null);

  test('G4-G5 Question acquisition resets timer; release waits for next scan',
      () async {
    await maintenance.reportOnly();
    now += ContentAssetLifecycleMaintenanceService.graceSeconds - 3600;
    final questions = QuestionRepository(
      databaseHelper: helper,
      mapper: QuestionV2PersistenceMapper(contentAssetAuthority: store),
    );
    await questions.saveQuestionDraftsV2ToBank(
      bankName: 'synthetic',
      folderName: null,
      questions: <QuestionDraftV2>[imageDraft('draft-1')],
    );
    expect(await rows(), isEmpty);
    final live = await maintenance.reportOnly();
    expect(live.liveCount, 1);
    expect(live.deletedCount, 0);

    final db = await helper.database;
    await db.delete('questions');
    expect(await rows(), isEmpty);
    now += 3600;
    final released = await maintenance.sweepEligible();
    expect(released.unobservedCount, 1);
    expect(released.deletedCount, 0);
    expect((await rows()).single['first_unreachable_at'], now);
  });

  test('two Question roots retain one shared asset until both release',
      () async {
    final questions = QuestionRepository(
      databaseHelper: helper,
      mapper: QuestionV2PersistenceMapper(contentAssetAuthority: store),
    );
    await questions.saveQuestionDraftsV2ToBank(
      bankName: 'synthetic',
      folderName: null,
      questions: <QuestionDraftV2>[
        imageDraft('draft-1'),
        imageDraft('draft-2'),
      ],
    );
    final db = await helper.database;
    expect((await maintenance.reportOnly()).liveCount, 1);
    final saved = await db.query('questions', columns: <String>['id']);
    expect(saved, hasLength(2));
    await db.delete('questions',
        where: 'id = ?', whereArgs: <Object?>[saved.first['id']]);
    now += ContentAssetLifecycleMaintenanceService.graceSeconds;
    final shared = await maintenance.sweepEligible();
    expect(shared.liveCount, 1);
    expect(shared.deletedCount, 0);
    expect(await rows(), isEmpty);
    await db.delete('questions',
        where: 'id = ?', whereArgs: <Object?>[saved.last['id']]);
    final released = await maintenance.sweepEligible();
    expect(released.unobservedCount, 1);
    expect(released.deletedCount, 0);
  });

  test('LibraryFile removal keeps an independently rooted Question asset',
      () async {
    final original = File(p.join(temp.path, 'source.txt'));
    await original.writeAsString('synthetic');
    final fileStorage = ManagedFileStorageAdapter(managedRoot: managed);
    final storageKey = fileStorage.allocateStorageKey('file-1');
    final copy = await fileStorage.copyIntoManagedStorage(
      externalPath: original.path,
      storageKey: storageKey,
    );
    final library = LibraryFileRepository(databaseHelper: helper);
    await library.save(LibraryFile(
      fileId: 'file-1',
      displayName: 'source.txt',
      mimeType: 'text/plain',
      sizeBytes: copy.sizeBytes,
      sha256: copy.sha256,
      storageKey: storageKey,
      createdAt: DateTime.utc(2026, 1, 1),
    ));
    final questions = QuestionRepository(
      databaseHelper: helper,
      mapper: QuestionV2PersistenceMapper(contentAssetAuthority: store),
    );
    await questions.saveQuestionDraftsV2ToBank(
      bankName: 'synthetic',
      folderName: null,
      questions: <QuestionDraftV2>[imageDraft('draft-1')],
    );
    final deletion = LibraryFileDeletionService(
      metadataRepository: library,
      deletionRepository: library,
      managedFileStorage: fileStorage,
      managedArtifactStorage: ManagedArtifactStorageAdapter(
        managedRoot: managed,
      ),
    );
    await deletion.deleteLibraryFile('file-1');
    expect(await library.findById('file-1'), isNull);
    expect(await fileStorage.managedFileExists(storageKey), isFalse);
    now += ContentAssetLifecycleMaintenanceService.graceSeconds;
    final retained = await maintenance.sweepEligible();
    expect(retained.liveCount, 1);
    expect(retained.deletedCount, 0);
    expect(await rows(), isEmpty);
    expect(
      await store.assetExists(sourceId: 'source-1', localAssetId: 'asset-1'),
      isTrue,
    );
  });

  test('G7 durable pendingReview candidate resets grace evidence', () async {
    await maintenance.reportOnly();
    now += ContentAssetLifecycleMaintenanceService.graceSeconds - 3600;
    await helper.saveImportTask(<String, dynamic>{
      'id': 'task-1',
      'title': 'synthetic',
      'status': 1,
      'progress_text': 'review',
      'percent': 1.0,
      'created_at': now,
      'parsed_data': '[]',
      'diagnostics': jsonEncode(<String, Object?>{
        '_candidate_asset_source_id': 'source-1',
        '_candidate_asset_local_ids': <String>['asset-1'],
      }),
    });
    expect(await rows(), isEmpty);
    final live = await maintenance.reportOnly();
    expect(live.liveCount, 1);
    expect(live.deletedCount, 0);
    await helper.close();
    final afterRestart = ContentAssetLifecycleMaintenanceService(
      rootPages: SqliteContentAssetRootPageRepository(databaseHelper: helper),
      contentAssets: ManagedContentAssetStore(managedRoot: managed),
      parsedArtifacts: _NoCurrentArtifact(),
      observations:
          ContentAssetReclamationObservationRepository(databaseHelper: helper),
      nowUtcSeconds: () => now,
    );
    final restarted = await afterRestart.sweepEligible();
    expect(restarted.outcome, ContentAssetMaintenanceOutcome.complete);
    expect(restarted.liveCount, 1);
    expect(restarted.deletedCount, 0);
  });

  test('typed pendingReview ImageNode resets and retains its identity',
      () async {
    await maintenance.reportOnly();
    now += ContentAssetLifecycleMaintenanceService.graceSeconds - 3600;
    final draft = QuestionDraftV2(
      questionId: '11111111-1111-4111-8111-111111111111',
      kind: QuestionKind.shortAnswer,
      stem: RichContent(nodes: <ContentNode>[
        ImageNode(sourceId: 'source-1', localAssetId: 'asset-1'),
      ]),
      sourceRefs: <SourceRef>[SourceRef.document(sourceId: 'source-1')],
      assetRefs: <SourcedAssetRef>[
        SourcedAssetRef(
          sourceId: 'source-1',
          asset: AssetRef(assetId: 'asset-1', kind: AssetKind.image),
        ),
      ],
    );
    final envelope = const TypedReviewSnapshotCodec().encode(
      TypedReviewSnapshot(
        reviewItemId: '22222222-2222-4222-8222-222222222222',
        questionId: draft.questionId,
        draft: draft,
        baselineLegacy: LegacyReviewBaseline(
          type: 3,
          questionNumber: null,
          content: '[图片]',
          options: const <String>[],
          standardAnswer: '',
          explanation: '',
        ),
      ),
    );
    await helper.saveImportTask(<String, dynamic>{
      'id': 'task-1',
      'title': 'synthetic',
      'status': 1,
      'progress_text': 'review',
      'percent': 1.0,
      'created_at': now,
      'parsed_data': jsonEncode(<Object?>[
        <String, Object?>{TypedReviewSnapshotCodec.mapKey: envelope},
      ]),
      'diagnostics': jsonEncode(<String, Object?>{
        '_importStorageRoute': 'typedV2',
      }),
    });
    expect(await rows(), isEmpty);
    final live = await maintenance.sweepEligible();
    expect(live.outcome, ContentAssetMaintenanceOutcome.complete);
    expect(live.liveCount, 1);
    expect(live.deletedCount, 0);
  });

  test('G6 current ParsedArtifact acquisition resets timer and remains live',
      () async {
    await maintenance.reportOnly();
    now += ContentAssetLifecycleMaintenanceService.graceSeconds - 3600;
    await observations.resetBeforeOwnership(
      sourceId: 'source-1',
      localAssetIds: <String>['asset-1'],
    );
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
      'artifact_id': 'source-1',
      'revision': 1,
      'source_sha256': 'a' * 64,
      'cache_key_version': 1,
      'cache_fingerprint': 'fingerprint',
      'parser_route': 'synthetic',
      'parser_version': '1',
      'options_schema_version': 1,
      'payload_schema_version': 1,
      'storage_key': 'artifacts/source-1.json',
      'payload_sha256': 'b' * 64,
      'size_bytes': 1,
      'published_at': 10,
    });
    artifacts.current = ParsedArtifactSnapshot(
      artifact: ParsedArtifact(
        fileId: 'file-1',
        artifactId: 'source-1',
        revision: 1,
        payloadSchemaVersion: 1,
      ),
      sourceDocument: SourceDocument(
        sourceId: 'source-1',
        parts: <SourcePart>[
          SourceAssetPart(
            sourceRef: SourceRef.document(sourceId: 'source-1'),
            asset: AssetRef(assetId: 'asset-1', kind: AssetKind.image),
          ),
        ],
      ),
    );
    expect(await rows(), isEmpty);
    final live = await maintenance.sweepEligible();
    expect(live.liveCount, 1);
    expect(live.deletedCount, 0);

    // A crash-era stale observation alongside a now-live current payload is
    // reset by the complete startup-style scan, never used as orphan proof.
    await db.insert(contentAssetReclamationTable, <String, Object?>{
      'source_id': 'source-1',
      'local_asset_id': 'asset-1',
      'first_unreachable_at': 1,
      'last_verified_unreachable_at': 2,
    });
    final reconciled = await maintenance.reportOnly();
    expect(reconciled.liveCount, 1);
    expect(await rows(), isEmpty);

    final questions = QuestionRepository(
      databaseHelper: helper,
      mapper: QuestionV2PersistenceMapper(contentAssetAuthority: store),
    );
    await questions.saveQuestionDraftsV2ToBank(
      bankName: 'synthetic',
      folderName: null,
      questions: <QuestionDraftV2>[imageDraft('draft-1')],
    );
    await db.delete('parsed_artifacts');
    now += ContentAssetLifecycleMaintenanceService.graceSeconds;
    final questionRetained = await maintenance.sweepEligible();
    expect(questionRetained.liveCount, 1);
    expect(questionRetained.deletedCount, 0);
    expect(await rows(), isEmpty);
  });

  test('head-only Artifact history is not a ContentAsset root', () async {
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
    expect((await maintenance.reportOnly()).unobservedCount, 1);
    now += ContentAssetLifecycleMaintenanceService.graceSeconds;
    final result = await maintenance.sweepEligible();
    expect(result.deletedCount, 1);
  });

  test('malformed pending-review owner blocks deletion', () async {
    await maintenance.reportOnly();
    now += ContentAssetLifecycleMaintenanceService.graceSeconds;
    final db = await helper.database;
    await db.insert('import_tasks', <String, Object?>{
      'id': 'task-1',
      'title': 'synthetic',
      'status': 1,
      'progress_text': 'review',
      'percent': 1.0,
      'created_at': now,
      'parsed_data': '[]',
      'diagnostics': jsonEncode(<String, Object?>{
        '_candidate_asset_source_id': 'source-1',
        '_candidate_asset_local_ids': 'malformed',
      }),
    });
    final result = await maintenance.sweepEligible();
    expect(result.outcome, ContentAssetMaintenanceOutcome.incompleteRoots);
    expect(result.deletedCount, 0);
    expect(
        await store.assetExists(sourceId: 'source-1', localAssetId: 'asset-1'),
        isTrue);
  });

  test('active writer excludes maintenance and reset restarts grace', () async {
    await maintenance.reportOnly();
    now += ContentAssetLifecycleMaintenanceService.graceSeconds;
    final lease = BackupRestoreMutationGate.instance.acquireMutationLease();
    try {
      final busy = await maintenance.sweepEligible();
      expect(busy.outcome, ContentAssetMaintenanceOutcome.busy);
      expect(busy.deletedCount, 0);
      await observations.resetBeforeOwnership(
        sourceId: 'source-1',
        localAssetIds: <String>['asset-1'],
      );
    } finally {
      lease.release();
    }
    final restarted = await maintenance.sweepEligible();
    expect(restarted.unobservedCount, 1);
    expect(restarted.deletedCount, 0);
  });

  test('G9 backward clock restarts grace and deletes nothing', () async {
    await maintenance.reportOnly();
    now--;
    final result = await maintenance.sweepEligible();
    expect(result.unobservedCount, 1);
    expect(result.deletedCount, 0);
    expect((await rows()).single['first_unreachable_at'], now);
  });

  test('G10 unavailable ledger gives zero destructive deletes', () async {
    await maintenance.reportOnly();
    now += ContentAssetLifecycleMaintenanceService.graceSeconds;
    await (await helper.database).execute(
      'DROP TABLE $contentAssetReclamationTable',
    );
    final result = await maintenance.sweepEligible();
    expect(result.outcome, ContentAssetMaintenanceOutcome.ledgerUnavailable);
    expect(result.deletedCount, 0);
    expect(
        await store.assetExists(sourceId: 'source-1', localAssetId: 'asset-1'),
        isTrue);
  });

  test('incomplete physical inventory never advances grace or deletes',
      () async {
    await maintenance.reportOnly();
    final before = (await rows()).single['last_verified_unreachable_at'];
    now += ContentAssetLifecycleMaintenanceService.graceSeconds;
    final invalid = File(
      p.join(managed.path, 'content_assets', 'source-1', 'empty-asset'),
    );
    await invalid.writeAsBytes(const <int>[], flush: true);
    final result = await maintenance.sweepEligible();
    expect(result.outcome, ContentAssetMaintenanceOutcome.incompleteInventory);
    expect(result.unknownCount, 1);
    expect(result.deletedCount, 0);
    expect((await rows()).single['last_verified_unreachable_at'], before);
    expect(
        await store.assetExists(sourceId: 'source-1', localAssetId: 'asset-1'),
        isTrue);
  });

  test('physical inventory classifies every encountered entity', () async {
    final source =
        Directory(p.join(managed.path, 'content_assets', 'source-1'));
    await File(p.join(source.path, 'empty-asset')).writeAsBytes(const []);
    await File(p.join(source.path, '.tmp_write')).writeAsBytes(const [1]);
    await File(p.join(source.path, 'unknown-asset'))
        .writeAsBytes(const [1, 2, 3]);
    final valid = await File(p.join(source.path, 'asset-1')).readAsBytes();
    await File(p.join(source.path, 'corrupt-asset')).writeAsBytes(
        <int>[...valid.take(33), ...valid.skip(valid.length - 12)]);
    await Directory(p.join(source.path, 'unexpected')).create();
    final inventory = await store.classifyPhysicalInventory();
    expect(inventory.entries.length, 7);
    expect(inventory.records.length, 1);
    expect(inventory.unknownCount, 5);
    expect(
      inventory.entries.map((entry) => entry.classification).toSet(),
      containsAll(<ContentAssetPhysicalClass>{
        ContentAssetPhysicalClass.canonicalSourceDirectory,
        ContentAssetPhysicalClass.canonicalValidAsset,
        ContentAssetPhysicalClass.canonicalEmptyAsset,
        ContentAssetPhysicalClass.temporaryWrite,
        ContentAssetPhysicalClass.unknownMimeAsset,
        ContentAssetPhysicalClass.canonicalCorruptAsset,
        ContentAssetPhysicalClass.unexpectedDirectory,
      }),
    );
    final result = await maintenance.sweepEligible();
    expect(result.outcome, ContentAssetMaintenanceOutcome.incompleteInventory);
    expect(result.unknownCount, 5);
    expect(result.deletedCount, 0);
  });

  test('physical inventory entry bound is incomplete', () async {
    await expectLater(
      store.inspectCompleteInventory(maxEntries: 1),
      throwsA(isA<ContentAssetPhysicalInventoryException>()
          .having((error) => error.boundHit, 'boundHit', true)),
    );
  });

  test('v0 complete-proof ceiling stays the declared entry and time bound', () {
    expect(ManagedContentAssetStore.completeInventoryEntryCeiling, 5000);
    expect(
      ManagedContentAssetStore.completeInventoryTimeBudget,
      const Duration(seconds: 2),
    );
  });

  test('question mark ceiling prevents any destructive delete', () async {
    await maintenance.reportOnly();
    now += ContentAssetLifecycleMaintenanceService.graceSeconds;
    final db = await helper.database;
    await db.execute('''
      WITH RECURSIVE n(x) AS (
        SELECT 1 UNION ALL SELECT x + 1 FROM n WHERE x < 10001
      )
      INSERT INTO questions (
        id, type, content, options, standard_answer,
        explanation, created_at, bank_name
      )
      SELECT 'synthetic-' || x, 0, 'synthetic', '["A","B"]', 'A',
        'synthetic', 1, 'synthetic'
      FROM n
    ''');
    final result = await maintenance.sweepEligible();
    expect(result.outcome, ContentAssetMaintenanceOutcome.incompleteRoots);
    expect(result.boundHit, isTrue);
    expect(result.deletedCount, 0);
    expect(
        await store.assetExists(sourceId: 'source-1', localAssetId: 'asset-1'),
        isTrue);
  });

  test('corrupt current Artifact blocks the complete root scan', () async {
    await maintenance.reportOnly();
    now += ContentAssetLifecycleMaintenanceService.graceSeconds;
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
      'artifact_id': 'source-1',
      'revision': 1,
      'source_sha256': 'a' * 64,
      'cache_key_version': 1,
      'cache_fingerprint': 'fingerprint',
      'parser_route': 'synthetic',
      'parser_version': '1',
      'options_schema_version': 1,
      'payload_schema_version': 1,
      'storage_key': 'artifacts/source-1.json',
      'payload_sha256': 'b' * 64,
      'size_bytes': 1,
      'published_at': 10,
    });
    final result = await maintenance.sweepEligible();
    expect(result.outcome, ContentAssetMaintenanceOutcome.incompleteRoots);
    expect(result.deletedCount, 0);
    expect(
        await store.assetExists(sourceId: 'source-1', localAssetId: 'asset-1'),
        isTrue);
  });

  test('a selected target that changed entity kind is never unlinked',
      () async {
    final assetPath =
        p.join(managed.path, 'content_assets', 'source-1', 'asset-1');
    final externalPath = p.join(temp.path, 'outside.png');
    final original = await File(assetPath).readAsBytes();
    await File(externalPath).writeAsBytes(original);
    final armed = ContentAssetLifecycleMaintenanceService(
      rootPages: SqliteContentAssetRootPageRepository(databaseHelper: helper),
      contentAssets: store,
      parsedArtifacts: artifacts,
      observations: observations,
      nowUtcSeconds: () => now,
      beforeExactDeleteForTesting: () async {
        File(assetPath).deleteSync();
        if (Platform.isWindows) {
          Directory(assetPath).createSync();
        } else {
          await Link(assetPath).create(externalPath);
        }
      },
    );

    expect((await armed.reportOnly()).unobservedCount, 1);
    now += ContentAssetLifecycleMaintenanceService.graceSeconds;

    final result = await armed.sweepEligible();
    expect(result.outcome, ContentAssetMaintenanceOutcome.deleteFailed);
    expect(result.deletedCount, 0);
    expect(
      await FileSystemEntity.type(assetPath, followLinks: false),
      isNot(FileSystemEntityType.file),
    );
    expect(await File(externalPath).readAsBytes(), original);
  });

  test('a physical entry appearing during ledger admission aborts deletion',
      () async {
    final withDrift = ContentAssetLifecycleMaintenanceService(
      rootPages: _DriftRootPages(
        owningDraft: imageDraft('q-1'),
        draftFromScan: 99,
        onRootScan: (rootScan) {
          if (rootScan != 3) return;
          store.storeBytesSync(
            sourceId: 'source-1',
            localAssetId: 'asset-2',
            bytes: base64Decode(
              'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
              '+A8AAQUBAScY42YAAAAASUVORK5CYII=',
            ),
            mimeType: 'image/png',
          );
        },
      ),
      contentAssets: store,
      parsedArtifacts: artifacts,
      observations: observations,
      nowUtcSeconds: () => now,
    );

    expect((await withDrift.reportOnly()).unobservedCount, 1);
    now += ContentAssetLifecycleMaintenanceService.graceSeconds;

    final result = await withDrift.sweepEligible();
    expect(result.outcome, ContentAssetMaintenanceOutcome.revalidationFailed);
    expect(result.deletedCount, 0);
    expect(
        await store.assetExists(sourceId: 'source-1', localAssetId: 'asset-1'),
        isTrue);
  });

  test('the delete window admits no new content writer', () async {
    var writerAdmitted = false;
    final armed = ContentAssetLifecycleMaintenanceService(
      rootPages: SqliteContentAssetRootPageRepository(databaseHelper: helper),
      contentAssets: store,
      parsedArtifacts: artifacts,
      observations: observations,
      nowUtcSeconds: () => now,
      beforeExactDeleteForTesting: () async {
        try {
          BackupRestoreMutationGate.instance.acquireMutationLease().release();
          writerAdmitted = true;
        } catch (_) {
          writerAdmitted = false;
        }
      },
    );

    expect((await armed.reportOnly()).unobservedCount, 1);
    now += ContentAssetLifecycleMaintenanceService.graceSeconds;
    final result = await armed.sweepEligible();

    expect(writerAdmitted, isFalse);
    expect(result.deletedCount, 1);
  });

  test('retryable cleanup residue stays a ContentAsset root', () async {
    final db = await helper.database;
    await db.insert('import_tasks', <String, Object?>{
      'id': 'task-cleanup',
      'title': 'synthetic',
      'status': 0,
      'progress_text': 'cleanup pending',
      'percent': 1.0,
      'created_at': 10,
      'diagnostics': jsonEncode(<String, Object?>{
        '_candidate_asset_cleanup_source_id': 'source-1',
        '_candidate_asset_cleanup_local_ids': <String>['asset-1'],
      }),
    });

    final live = await maintenance.reportOnly();
    expect(live.liveCount, 1);
    now += ContentAssetLifecycleMaintenanceService.graceSeconds;
    final swept = await maintenance.sweepEligible();

    expect(swept.deletedCount, 0);
    expect(
        await store.assetExists(sourceId: 'source-1', localAssetId: 'asset-1'),
        isTrue);
  });

  test('malformed cleanup residue aborts the complete root scan', () async {
    final db = await helper.database;
    await db.insert('import_tasks', <String, Object?>{
      'id': 'task-cleanup',
      'title': 'synthetic',
      'status': 0,
      'progress_text': 'cleanup pending',
      'percent': 1.0,
      'created_at': 10,
      'diagnostics': jsonEncode(<String, Object?>{
        '_candidate_asset_cleanup_source_id': 'source-1',
        '_candidate_asset_cleanup_local_ids': 'malformed',
      }),
    });

    final result = await maintenance.sweepEligible();
    expect(result.outcome, ContentAssetMaintenanceOutcome.incompleteRoots);
    expect(result.deletedCount, 0);
    expect(
        await store.assetExists(sourceId: 'source-1', localAssetId: 'asset-1'),
        isTrue);
  });

  test('grace elapsed before a restart completes against the persisted timer',
      () async {
    expect((await maintenance.reportOnly()).unobservedCount, 1);
    expect((await rows()).single['first_unreachable_at'], now);

    await helper.close();
    final afterRestart = ContentAssetLifecycleMaintenanceService(
      rootPages: SqliteContentAssetRootPageRepository(databaseHelper: helper),
      contentAssets: ManagedContentAssetStore(managedRoot: managed),
      parsedArtifacts: _NoCurrentArtifact(),
      observations:
          ContentAssetReclamationObservationRepository(databaseHelper: helper),
      nowUtcSeconds: () => now,
    );
    now += ContentAssetLifecycleMaintenanceService.graceSeconds;

    final result = await afterRestart.sweepEligible();
    expect(result.outcome, ContentAssetMaintenanceOutcome.complete);
    expect(result.deletedCount, 1);
    expect(await rows(), isEmpty);
  });

  test('a released Question root reaches a real orphan deletion', () async {
    final questions = QuestionRepository(
      databaseHelper: helper,
      mapper: QuestionV2PersistenceMapper(contentAssetAuthority: store),
    );
    await questions.saveQuestionDraftsV2ToBank(
      bankName: 'synthetic',
      folderName: null,
      questions: <QuestionDraftV2>[imageDraft('draft-1')],
    );
    final live = await maintenance.reportOnly();
    expect(live.liveCount, 1);
    expect(live.deletedCount, 0);

    final db = await helper.database;
    final questionId =
        (await db.query('questions', columns: <String>['id'], limit: 1))
            .single['id']! as String;
    await questions.deleteQuestion(questionId);

    final released = await maintenance.reportOnly();
    expect(released.unobservedCount, 1);
    expect(released.deletedCount, 0);
    expect((await rows()).single['first_unreachable_at'], now);

    now += ContentAssetLifecycleMaintenanceService.graceSeconds - 1;
    final pending = await maintenance.sweepEligible();
    expect(pending.deletedCount, 0);

    now++;
    final eligible = await maintenance.sweepEligible();
    expect(eligible.outcome, ContentAssetMaintenanceOutcome.complete);
    expect(eligible.deletedCount, 1);
    expect(
        await store.assetExists(sourceId: 'source-1', localAssetId: 'asset-1'),
        isFalse);
  });

  test('unknown physical entities block the whole destructive pass', () async {
    expect((await maintenance.reportOnly()).unobservedCount, 1);
    now += ContentAssetLifecycleMaintenanceService.graceSeconds;

    final contentRoot = Directory(p.join(managed.path, 'content_assets'));
    final stray = File(p.join(contentRoot.path, 'stray-file'));
    final invalidSource = Directory(p.join(contentRoot.path, 'bad source!'));
    final invalidAsset =
        File(p.join(contentRoot.path, 'source-1', 'bad name.png'));
    await stray.writeAsBytes(const <int>[1]);
    await invalidSource.create();
    await invalidAsset.writeAsBytes(const <int>[1]);

    final inventory = await store.classifyPhysicalInventory();
    expect(
      inventory.entries.map((entry) => entry.classification).toSet(),
      containsAll(<ContentAssetPhysicalClass>{
        ContentAssetPhysicalClass.unexpectedFile,
        ContentAssetPhysicalClass.invalidSourceIdentity,
        ContentAssetPhysicalClass.invalidLocalAssetIdentity,
      }),
    );

    final blocked = await maintenance.sweepEligible();
    expect(blocked.outcome, ContentAssetMaintenanceOutcome.incompleteInventory);
    expect(blocked.deletedCount, 0);
    expect(
        await store.assetExists(sourceId: 'source-1', localAssetId: 'asset-1'),
        isTrue);

    await stray.delete();
    await invalidSource.delete();
    await invalidAsset.delete();

    final unblocked = await maintenance.sweepEligible();
    expect(unblocked.outcome, ContentAssetMaintenanceOutcome.complete);
    expect(unblocked.deletedCount, 1);
  });

  test('a healthy listing is not a destructive inventory', () async {
    final source =
        Directory(p.join(managed.path, 'content_assets', 'source-1'));
    await File(p.join(source.path, 'empty-asset')).writeAsBytes(const <int>[]);
    await File(p.join(source.path, 'unknown-asset'))
        .writeAsBytes(const <int>[1, 2, 3]);
    final valid = await File(p.join(source.path, 'asset-1')).readAsBytes();
    await File(p.join(source.path, 'corrupt-asset')).writeAsBytes(
        <int>[...valid.take(33), ...valid.skip(valid.length - 12)]);
    final oversized = File(p.join(source.path, 'oversized-asset'));
    final handle = await oversized.open(mode: FileMode.write);
    try {
      await handle.truncate(ManagedContentAssetStore.maxImageBytes + 1);
    } finally {
      await handle.close();
    }

    final healthy = await store.listAssets();
    final healthyIds = healthy.map((asset) => asset.localAssetId).toSet();
    expect(healthyIds, <String>{'asset-1', 'corrupt-asset'});
    expect(healthyIds, isNot(contains('empty-asset')));
    expect(healthyIds, isNot(contains('oversized-asset')));
    expect(healthyIds, isNot(contains('unknown-asset')));

    final inventory = await store.classifyPhysicalInventory();
    expect(
      inventory.entries.map((entry) => entry.classification).toSet(),
      containsAll(<ContentAssetPhysicalClass>{
        ContentAssetPhysicalClass.canonicalValidAsset,
        ContentAssetPhysicalClass.canonicalEmptyAsset,
        ContentAssetPhysicalClass.canonicalOversizedAsset,
        ContentAssetPhysicalClass.canonicalCorruptAsset,
        ContentAssetPhysicalClass.unknownMimeAsset,
      }),
    );

    final blocked = await maintenance.sweepEligible();
    expect(blocked.outcome, ContentAssetMaintenanceOutcome.incompleteInventory);
    expect(blocked.deletedCount, 0);
    expect(
        await store.assetExists(sourceId: 'source-1', localAssetId: 'asset-1'),
        isTrue);
  });

  test('an invalid durable clock deletes nothing and advances no grace',
      () async {
    final db = await helper.database;
    await db.insert(contentAssetReclamationTable, <String, Object?>{
      'source_id': 'source-1',
      'local_asset_id': 'asset-1',
      'first_unreachable_at': 1,
      'last_verified_unreachable_at': 1,
    });
    final invalidClock = ContentAssetLifecycleMaintenanceService(
      rootPages: SqliteContentAssetRootPageRepository(databaseHelper: helper),
      contentAssets: store,
      parsedArtifacts: artifacts,
      observations: observations,
      nowUtcSeconds: () => -1,
    );

    final result = await invalidClock.sweepEligible();
    expect(result.outcome, ContentAssetMaintenanceOutcome.ledgerUnavailable);
    expect(result.deletedCount, 0);
    final row = (await rows()).single;
    expect(row['first_unreachable_at'], 1);
    expect(row['last_verified_unreachable_at'], 1);
    expect(
        await store.assetExists(sourceId: 'source-1', localAssetId: 'asset-1'),
        isTrue);
  });
}

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/core/database/content_asset_reclamation_v27_schema.dart';
import 'package:shiroha_quiz/application/backup/backup_restore_gate.dart';
import 'package:shiroha_quiz/application/content/content_asset_maintenance.dart';
import 'package:shiroha_quiz/application/parsed_artifacts/parsed_artifact_lifecycle.dart';
import 'package:shiroha_quiz/data/persistence/question_v2_persistence_mapper.dart';
import 'package:shiroha_quiz/data/repositories/backup_database_authority.dart';
import 'package:shiroha_quiz/data/repositories/backup_snapshot_repository.dart';
import 'package:shiroha_quiz/data/repositories/content_asset_reclamation_observation_repository.dart';
import 'package:shiroha_quiz/data/repositories/content_asset_root_page_repository.dart';
import 'package:shiroha_quiz/domain/backup/backup_failure.dart';
import 'package:shiroha_quiz/domain/backup/backup_manifest.dart';
import 'package:shiroha_quiz/domain/assets/asset_ref.dart';
import 'package:shiroha_quiz/domain/assets/parsed_artifact.dart';
import 'package:shiroha_quiz/domain/assets/sourced_asset_ref.dart';
import 'package:shiroha_quiz/domain/backup/backup_values.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2_codec.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/domain/source/source_document.dart';
import 'package:shiroha_quiz/domain/source/source_part.dart';
import 'package:shiroha_quiz/services/backup/backup_disk_space.dart';
import 'package:shiroha_quiz/services/backup/backup_archive_io.dart';
import 'package:shiroha_quiz/services/backup/backup_restore_runtime.dart';
import 'package:shiroha_quiz/services/backup/sha256.dart';
import 'package:shiroha_quiz/services/file_library/managed_content_asset_store.dart';
import 'package:shiroha_quiz/services/file_library/content_asset_lifecycle_maintenance_service.dart';
import 'package:shiroha_quiz/services/file_library/managed_artifact_storage_adapter.dart';
import 'package:shiroha_quiz/services/file_library/managed_file_storage_adapter.dart';

final class _InfiniteDisk implements BackupDiskSpaceProbe {
  const _InfiniteDisk();

  @override
  Future<int?> availableBytes(String path) async => 1 << 40;
}

const _tinyPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
    '+A8AAQUBAScY42YAAAAASUVORK5CYII=';

List<int> _tinyPngBytes() => base64Decode(_tinyPngBase64);

final class _ArtifactOnlyRoot implements ParsedArtifactLifecyclePort {
  _ArtifactOnlyRoot(this.snapshot);

  final ParsedArtifactSnapshot snapshot;

  @override
  Future<ParsedArtifactSnapshot> getCurrentArtifact(String fileId) async =>
      snapshot;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory temp;
  late Directory dbDir;
  late Directory managedRoot;
  late Directory restoreRoot;
  late DatabaseHelper helper;
  late BackupSnapshotRepository snapshots;
  late ManagedFileStorageAdapter fileStorage;
  late ManagedContentAssetStore contentStore;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('b0_content_asset_');
    dbDir = Directory(p.join(temp.path, 'db'))..createSync(recursive: true);
    managedRoot = Directory(p.join(temp.path, 'managed'))
      ..createSync(recursive: true);
    restoreRoot = Directory(p.join(temp.path, 'restore'))
      ..createSync(recursive: true);
    await databaseFactory.setDatabasesPath(dbDir.path);
    DatabaseHelper.configureRuntimeProfile(
      DatabaseRuntimeProfile.explicitFile,
      databasePath: dbDir.path,
    );
    helper = DatabaseHelper.instance;
    snapshots = BackupSnapshotRepository(databaseHelper: helper);
    fileStorage = ManagedFileStorageAdapter(managedRoot: managedRoot);
    contentStore = ManagedContentAssetStore(managedRoot: managedRoot);

    contentStore.storeBytesSync(
      sourceId: 'source_001',
      localAssetId: 'asset_000001',
      bytes: _tinyPngBytes(),
      mimeType: 'image/png',
    );
    final draft = _imageDraft();
    final frozen = QuestionV2PersistenceMapper(
      contentAssetAuthority: contentStore,
    ).freezeForWrite(
      storageId: 'a3f9c2e4-5b6d-4e7f-8a9b-0c1d2e3f4a5b',
      bankName: 'synthetic_bank',
      createdAt: 1,
      draft: draft,
    );
    final db = await helper.database;
    await db.insert('questions', frozen.questionRow);
    await db.insert('question_v2_payloads', frozen.payloadRow);
  });

  tearDown(() async {
    await helper.close();
    await DatabaseHelper.resetRuntimeProfileForTesting();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  BackupRestoreRuntime buildRuntime() {
    return BackupRestoreRuntime(
      databaseAuthority: SqliteBackupDatabaseAuthority(
        databaseHelper: helper,
        snapshotRepository: snapshots,
      ),
      snapshotRepository: snapshots,
      managedFileStorage: fileStorage,
      contentAssetStore: contentStore,
      restoreRoot: restoreRoot,
      managedFilesRoot: managedRoot,
      diskSpaceProbe: const _InfiniteDisk(),
    );
  }

  test('B0 package preserves referenced content bytes and typed payload',
      () async {
    final runtime = buildRuntime();
    final packagePath = p.join(temp.path, 'export', 'content.shiroha');
    final summary = await runtime.exportTo(packagePath);
    expect(summary.managedBytes, greaterThan(0));

    final manifest = await BackupArchiveIo.readManifestOnly(packagePath);
    expect(manifest.packageVersion, BackupValues.currentPackageVersion);
    expect(manifest.contentAssets, hasLength(1));
    expect(
      manifest.contentAssets.single.archivePath,
      'files/content_assets/source_001/asset_000001',
    );

    final asset = File(
      p.join(
        managedRoot.path,
        'content_assets',
        'source_001',
        'asset_000001',
      ),
    );
    await asset.delete();
    expect(asset.existsSync(), isFalse);

    await runtime.prepareRestore(packagePath);
    final result = await runtime.commitPreparedRestore();
    expect(result.fileCount, 0);
    expect(
      contentStore.readAssetBytes(
        sourceId: 'source_001',
        localAssetId: 'asset_000001',
      ),
      _tinyPngBytes(),
    );

    final db = await helper.database;
    final row = (await db.query('question_v2_payloads')).single;
    final decoded = const QuestionDraftV2Codec().decode(
      jsonDecode(row['payload_json']! as String),
    );
    expect(decoded.assetRefs.single.sourceId, 'source_001');
    expect(decoded.assetRefs.single.localAssetId, 'asset_000001');
    expect(reachableImageNodes(decoded.stem), hasLength(1));
    await _expectDecodableImage(
      contentStore.readAssetBytes(
        sourceId: 'source_001',
        localAssetId: 'asset_000001',
      )!,
    );
  });

  test('B0 export scrubs v27 grace evidence and restore starts empty',
      () async {
    final db = await helper.database;
    await db.insert(contentAssetReclamationTable, <String, Object?>{
      'source_id': 'orphan-source',
      'local_asset_id': 'orphan-asset',
      'first_unreachable_at': 10,
      'last_verified_unreachable_at': 20,
    });
    final packagePath = p.join(temp.path, 'export', 'grace.shiroha');
    final runtime = buildRuntime();
    await runtime.exportTo(packagePath);
    final manifest = await BackupArchiveIo.readManifestOnly(packagePath);
    expect(manifest.schemaVersion, 27);
    expect(manifest.contentAssets, hasLength(1));

    final extracted = await BackupArchiveIo.extractAndValidate(
      packagePath: packagePath,
      stagingRoot: p.join(temp.path, 'extracted'),
    );
    final exported = await databaseFactory.openDatabase(extracted.databasePath);
    try {
      expect(await exported.query(contentAssetReclamationTable), isEmpty);
    } finally {
      await exported.close();
    }
    expect(await db.query(contentAssetReclamationTable), hasLength(1));
    await runtime.prepareRestore(packagePath);
    await runtime.commitPreparedRestore();
    expect(
      await (await helper.database).query(contentAssetReclamationTable),
      isEmpty,
    );
  });

  test('supported v26 package migrates to v27 with an empty ledger', () async {
    final runtime = buildRuntime();
    final sourcePackage = p.join(temp.path, 'export', 'source.shiroha');
    await runtime.exportTo(sourcePackage);
    final extracted = await BackupArchiveIo.extractAndValidate(
      packagePath: sourcePackage,
      stagingRoot: p.join(temp.path, 'old-package-staging'),
    );
    final oldDb = await databaseFactory.openDatabase(extracted.databasePath);
    try {
      await oldDb.execute('DROP TABLE $contentAssetReclamationTable');
      await oldDb.execute('PRAGMA user_version = 26');
    } finally {
      await oldDb.close();
    }
    final dbFile = File(extracted.databasePath);
    final oldManifest = BackupManifest(
      packageVersion: extracted.manifest.packageVersion,
      schemaVersion: 26,
      createdAtUtc: extracted.manifest.createdAtUtc,
      database: BackupDatabaseEntry(
        archivePath: BackupValues.databaseArchivePath,
        sizeBytes: await dbFile.length(),
        sha256: sha256Hex(await dbFile.readAsBytes()),
      ),
      managedFiles: extracted.manifest.managedFiles,
      contentAssets: extracted.manifest.contentAssets,
    );
    final manifestPath = p.join(temp.path, 'old-manifest.json');
    await File(manifestPath).writeAsString(oldManifest.encode(), flush: true);
    final oldPackage = p.join(temp.path, 'old-v26.shiroha');
    await BackupArchiveIo.writeStoredPackage(
      packagePath: oldPackage,
      manifestPath: manifestPath,
      databasePath: extracted.databasePath,
      files: <ArchiveSourceFile>[
        for (final asset in oldManifest.contentAssets)
          ArchiveSourceFile(
            fileId: asset.localAssetId,
            path: p.join(temp.path, 'old-package-staging', asset.archivePath),
            archivePath: asset.archivePath,
          ),
      ],
    );

    await runtime.prepareRestore(oldPackage);
    await runtime.commitPreparedRestore();
    final restored = await helper.database;
    expect(await restored.getVersion(), 27);
    expect(await restored.query(contentAssetReclamationTable), isEmpty);
    expect(await restored.query('question_v2_payloads'), hasLength(1));
    expect(
      contentStore.readAssetBytes(
        sourceId: 'source_001',
        localAssetId: 'asset_000001',
      ),
      _tinyPngBytes(),
    );
  });

  test('typed ImageNode and managed bytes survive database close and reopen',
      () async {
    await helper.close();
    final reopened = await helper.database;
    final row = (await reopened.query('question_v2_payloads')).single;
    final decoded = const QuestionDraftV2Codec().decode(
      jsonDecode(row['payload_json']! as String),
    );

    expect(reachableImageNodes(decoded.stem), hasLength(1));
    expect(
      contentStore.readAssetBytes(
        sourceId: 'source_001',
        localAssetId: 'asset_000001',
      ),
      _tinyPngBytes(),
    );
    expect(
      await contentStore.resolveAssetBytesAsync(
        sourceId: 'source_001',
        localAssetId: 'asset_000001',
      ),
      _tinyPngBytes(),
    );
    await _expectDecodableImage(
      (await contentStore.resolveAssetBytesAsync(
        sourceId: 'source_001',
        localAssetId: 'asset_000001',
      ))!,
    );
  });

  test('merged TableNode survives typed reopen and B0 backup restore',
      () async {
    final db = await helper.database;
    await _replacePayload(db, _mergedTableDraft());

    await helper.close();
    var reopened = await helper.database;
    var row = (await reopened.query('question_v2_payloads')).single;
    var decoded = const QuestionDraftV2Codec().decode(
      jsonDecode(row['payload_json']! as String),
    );
    _expectMergedTable(decoded);

    final packagePath = p.join(temp.path, 'export', 'merged-table.shiroha');
    final runtime = buildRuntime();
    await runtime.exportTo(packagePath);
    await runtime.prepareRestore(packagePath);
    await runtime.commitPreparedRestore();

    await helper.close();
    reopened = await helper.database;
    row = (await reopened.query('question_v2_payloads')).single;
    decoded = const QuestionDraftV2Codec().decode(
      jsonDecode(row['payload_json']! as String),
    );
    _expectMergedTable(decoded);
  });

  test('B0 ignores valid but unreferenced inventory members', () async {
    final db = await helper.database;
    await _replacePayload(db, _imageDraftWithExtraInventory());

    final packagePath = p.join(temp.path, 'export', 'extra-inventory.shiroha');
    final summary = await buildRuntime().exportTo(packagePath);
    expect(summary.managedBytes, greaterThan(0));
    final manifest = await BackupArchiveIo.readManifestOnly(packagePath);

    expect(
      manifest.contentAssets.map(
        (asset) => '${asset.sourceId}/${asset.localAssetId}',
      ),
      <String>['source_001/asset_000001'],
    );
  });

  test('Artifact-only asset stays live for maintenance but leaves B0 manifest',
      () async {
    const sourceId = 'source_002';
    const localAssetId = 'asset_artifact';
    contentStore.storeBytesSync(
      sourceId: sourceId,
      localAssetId: localAssetId,
      bytes: _tinyPngBytes(),
      mimeType: 'image/png',
    );
    final source = File(p.join(temp.path, 'artifact-source.txt'));
    await source.writeAsString('synthetic');
    final fileKey = fileStorage.allocateStorageKey('file-1');
    final copied = await fileStorage.copyIntoManagedStorage(
      externalPath: source.path,
      storageKey: fileKey,
    );
    final artifactStorage = ManagedArtifactStorageAdapter(
      managedRoot: managedRoot,
    );
    final artifactKey =
        artifactStorage.allocateArtifactStorageKey('artifact-1');
    final written = await artifactStorage.writeArtifact(
      storageKey: artifactKey,
      bytes: utf8.encode('synthetic'),
    );
    final db = await helper.database;
    await db.insert('library_files', <String, Object?>{
      'file_id': 'file-1',
      'display_name': 'artifact-source.txt',
      'mime_type': 'text/plain',
      'size_bytes': copied.sizeBytes,
      'sha256': copied.sha256,
      'storage_key': fileKey,
      'created_at': 10,
    });
    await db.insert('parsed_artifact_heads', <String, Object?>{
      'file_id': 'file-1',
      'last_revision': 1,
    });
    await db.insert('parsed_artifacts', <String, Object?>{
      'file_id': 'file-1',
      'artifact_id': 'artifact-1',
      'revision': 1,
      'source_sha256': copied.sha256,
      'cache_key_version': 1,
      'cache_fingerprint': 'fingerprint',
      'parser_route': 'synthetic',
      'parser_version': '1',
      'options_schema_version': 1,
      'payload_schema_version': 1,
      'storage_key': written.storageKey,
      'payload_sha256': written.sha256,
      'size_bytes': written.sizeBytes,
      'published_at': 10,
    });
    final artifact = _ArtifactOnlyRoot(ParsedArtifactSnapshot(
      artifact: ParsedArtifact(
        fileId: 'file-1',
        artifactId: 'artifact-1',
        revision: 1,
        payloadSchemaVersion: 1,
      ),
      sourceDocument: SourceDocument(
        sourceId: sourceId,
        parts: <SourcePart>[
          SourceAssetPart(
            sourceRef: SourceRef.document(sourceId: sourceId),
            asset: AssetRef(assetId: localAssetId, kind: AssetKind.image),
          ),
        ],
      ),
    ));
    final maintenance = ContentAssetLifecycleMaintenanceService(
      rootPages: SqliteContentAssetRootPageRepository(databaseHelper: helper),
      contentAssets: contentStore,
      parsedArtifacts: artifact,
      observations: ContentAssetReclamationObservationRepository(
        databaseHelper: helper,
      ),
    );
    final live = await maintenance.reportOnly();
    expect(live.outcome, ContentAssetMaintenanceOutcome.complete);
    expect(live.liveCount, 2);
    expect(live.unobservedCount, 0);

    final gate = BackupRestoreMutationGate.instance;
    gate.acquireExclusive();
    try {
      final busy = await maintenance.sweepEligible();
      expect(busy.outcome, ContentAssetMaintenanceOutcome.busy);
      expect(busy.physicalCount, 0);
      expect(busy.deletedCount, 0);
    } finally {
      gate.releaseExclusive();
    }

    final packagePath = p.join(temp.path, 'export', 'artifact-only.shiroha');
    await buildRuntime().exportTo(packagePath);
    final manifest = await BackupArchiveIo.readManifestOnly(packagePath);
    expect(
      manifest.contentAssets.map(
        (asset) => '${asset.sourceId}/${asset.localAssetId}',
      ),
      <String>['source_001/asset_000001'],
    );
    expect((await maintenance.reportOnly()).liveCount, 2);
  });

  test('B0 blocks a missing reachable image asset', () async {
    final asset = File(
      p.join(
        managedRoot.path,
        'content_assets',
        'source_001',
        'asset_000001',
      ),
    );
    await asset.delete();

    await expectLater(
      buildRuntime().exportTo(p.join(temp.path, 'export', 'missing.shiroha')),
      throwsA(
        isA<BackupException>().having(
          (error) => error.failure,
          'failure',
          BackupFailure.integrityMismatch,
        ),
      ),
    );
  });

  test('B0 includes table-cell, answer, and explanation image closure',
      () async {
    final bytes = _tinyPngBytes();
    for (final localAssetId in <String>[
      'asset_table',
      'asset_answer',
      'asset_explanation',
    ]) {
      contentStore.storeBytesSync(
        sourceId: 'source_001',
        localAssetId: localAssetId,
        bytes: bytes,
        mimeType: 'image/png',
      );
    }
    final db = await helper.database;
    await _replacePayload(db, _imageDraftWithNestedClosure());

    final packagePath = p.join(temp.path, 'export', 'nested-closure.shiroha');
    final summary = await buildRuntime().exportTo(packagePath);
    expect(summary.managedBytes, greaterThan(0));
    final manifest = await BackupArchiveIo.readManifestOnly(packagePath);
    expect(
      manifest.contentAssets
          .map((asset) => asset.localAssetId)
          .toList(growable: false),
      <String>['asset_answer', 'asset_explanation', 'asset_table'],
    );
  });

  for (final invalidPayload in <String, Object?>{
    'unsupported schema': 999,
    'corrupt JSON': '{',
  }.entries) {
    test('B0 blocks ${invalidPayload.key} before package publication',
        () async {
      final db = await helper.database;
      await db.update(
        'question_v2_payloads',
        invalidPayload.key == 'unsupported schema'
            ? <String, Object?>{
                'payload_schema_version': invalidPayload.value,
              }
            : <String, Object?>{'payload_json': invalidPayload.value},
      );
      final packagePath = p.join(temp.path, 'export', 'invalid.shiroha');

      await expectLater(
        buildRuntime().exportTo(packagePath),
        throwsA(isA<BackupException>().having(
          (error) => error.failure,
          'failure',
          BackupFailure.databaseInvalid,
        )),
      );
      expect(File(packagePath).existsSync(), isFalse);
    });
  }
}

Future<void> _replacePayload(Database db, QuestionDraftV2 draft) async {
  await db.update(
    'question_v2_payloads',
    <String, Object?>{
      'payload_json': jsonEncode(const QuestionDraftV2Codec().encode(draft)),
    },
    where: 'question_id = ?',
    whereArgs: const <Object?>['a3f9c2e4-5b6d-4e7f-8a9b-0c1d2e3f4a5b'],
  );
}

Future<void> _expectDecodableImage(List<int> bytes) async {
  final codec = await ui.instantiateImageCodec(Uint8List.fromList(bytes));
  try {
    final frame = await codec.getNextFrame();
    expect(frame.image.width, 1);
    expect(frame.image.height, 1);
    frame.image.dispose();
  } finally {
    codec.dispose();
  }
}

QuestionDraftV2 _imageDraft() {
  return QuestionDraftV2(
    questionId: 'question_001',
    kind: QuestionKind.shortAnswer,
    stem: RichContent(nodes: <ContentNode>[
      ImageNode(sourceId: 'source_001', localAssetId: 'asset_000001'),
    ]),
    sourceRefs: <SourceRef>[SourceRef.document(sourceId: 'source_001')],
    assetRefs: <SourcedAssetRef>[
      SourcedAssetRef(
        sourceId: 'source_001',
        asset: AssetRef(assetId: 'asset_000001', kind: AssetKind.image),
      ),
    ],
  );
}

QuestionDraftV2 _imageDraftWithExtraInventory() {
  return QuestionDraftV2(
    questionId: 'question_001',
    kind: QuestionKind.shortAnswer,
    stem: RichContent(nodes: <ContentNode>[
      ImageNode(sourceId: 'source_001', localAssetId: 'asset_000001'),
    ]),
    sourceRefs: <SourceRef>[SourceRef.document(sourceId: 'source_001')],
    assetRefs: <SourcedAssetRef>[
      SourcedAssetRef(
        sourceId: 'source_001',
        asset: AssetRef(assetId: 'asset_000001', kind: AssetKind.image),
      ),
      SourcedAssetRef(
        sourceId: 'source_001',
        asset: AssetRef(assetId: 'asset_000002', kind: AssetKind.image),
      ),
    ],
  );
}

QuestionDraftV2 _imageDraftWithNestedClosure() {
  ImageNode image(String localAssetId) {
    return ImageNode(sourceId: 'source_001', localAssetId: localAssetId);
  }

  final table = TableNode(
    structure: TableStructure(
      rows: <TableRow>[
        TableRow(
          cells: <TableCell>[
            TableCell(
              content: RichContent(nodes: <ContentNode>[image('asset_table')]),
            ),
          ],
        ),
      ],
    ),
  );
  return QuestionDraftV2(
    questionId: 'question_001',
    kind: QuestionKind.shortAnswer,
    stem: RichContent(nodes: <ContentNode>[table]),
    answer: ContentAnswer(
      content: RichContent(nodes: <ContentNode>[image('asset_answer')]),
    ),
    explanation: RichContent(
      nodes: <ContentNode>[image('asset_explanation')],
    ),
    sourceRefs: <SourceRef>[SourceRef.document(sourceId: 'source_001')],
    assetRefs: <SourcedAssetRef>[
      for (final localAssetId in <String>[
        'asset_000001',
        'asset_table',
        'asset_answer',
        'asset_explanation',
      ])
        SourcedAssetRef(
          sourceId: 'source_001',
          asset: AssetRef(assetId: localAssetId, kind: AssetKind.image),
        ),
    ],
  );
}

QuestionDraftV2 _mergedTableDraft() {
  return QuestionDraftV2(
    questionId: 'question_001',
    kind: QuestionKind.shortAnswer,
    stem: RichContent(
      nodes: <ContentNode>[
        TableNode(
          structure: TableStructure(
            rows: <TableRow>[
              TableRow(
                cells: <TableCell>[
                  TableCell(
                    content: RichContent(
                      nodes: const <ContentNode>[TextNode('A')],
                    ),
                    rowSpan: 2,
                    columnSpan: 2,
                  ),
                  TableCell(
                    content: RichContent(
                      nodes: const <ContentNode>[TextNode('B')],
                    ),
                  ),
                ],
              ),
              TableRow(
                cells: <TableCell>[
                  TableCell(
                    content: RichContent(
                      nodes: const <ContentNode>[TextNode('C')],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    ),
    sourceRefs: <SourceRef>[SourceRef.document(sourceId: 'source_001')],
  );
}

void _expectMergedTable(QuestionDraftV2 draft) {
  final table = draft.stem.nodes.single as TableNode;
  final cell = table.structure.rows.first.cells.first;
  expect(cell.rowSpan, 2);
  expect(cell.columnSpan, 2);
  expect(cell.content.nodes.single, const TextNode('A'));
}

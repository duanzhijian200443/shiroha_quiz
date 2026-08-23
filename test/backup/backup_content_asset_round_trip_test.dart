import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/persistence/question_v2_persistence_mapper.dart';
import 'package:shiroha_quiz/data/repositories/backup_database_authority.dart';
import 'package:shiroha_quiz/data/repositories/backup_snapshot_repository.dart';
import 'package:shiroha_quiz/domain/backup/backup_failure.dart';
import 'package:shiroha_quiz/domain/backup/backup_manifest.dart';
import 'package:shiroha_quiz/domain/assets/asset_ref.dart';
import 'package:shiroha_quiz/domain/assets/sourced_asset_ref.dart';
import 'package:shiroha_quiz/domain/backup/backup_values.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2_codec.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/services/backup/backup_disk_space.dart';
import 'package:shiroha_quiz/services/backup/backup_archive_io.dart';
import 'package:shiroha_quiz/services/backup/backup_restore_runtime.dart';
import 'package:shiroha_quiz/services/file_library/managed_content_asset_store.dart';
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

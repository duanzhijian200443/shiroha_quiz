import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/repositories/backup_database_authority.dart';
import 'package:shiroha_quiz/data/repositories/backup_snapshot_repository.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/content/rich_content_codec.dart';
import 'package:shiroha_quiz/services/backup/backup_restore_runtime.dart';
import 'package:shiroha_quiz/services/file_library/managed_content_asset_store.dart';
import 'package:shiroha_quiz/services/file_library/managed_file_storage_adapter.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;
  late Directory dbDir;
  late Directory managedRoot;
  late ManagedContentAssetStore assetStore;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('backup_asset_test_');
    dbDir = Directory(p.join(tempDir.path, 'db'))..createSync(recursive: true);
    managedRoot = Directory(p.join(tempDir.path, 'managed'))
      ..createSync(recursive: true);
    await databaseFactory.setDatabasesPath(dbDir.path);
    assetStore = ManagedContentAssetStore(managedRoot: managedRoot);
    DefaultContentAssetResolver.instance.setStore(assetStore);
  });

  tearDown(() async {
    DefaultContentAssetResolver.instance.setStore(null);
    await DatabaseHelper.instance.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('Backup snapshot with Content Assets', () {
    test(
        'discovers and snapshots content assets referenced in question_v2_payloads',
        () async {
      final db = await DatabaseHelper.instance.database;

      // 1. Store an image asset
      final imageBytes = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
      final storageKey = await assetStore.storeBytes(
        bytes: imageBytes,
        mimeType: 'image/png',
      );

      // 2. Insert a QuestionV2 payload referencing this asset
      const codec = RichContentCodec();
      final stem = RichContent(nodes: <ContentNode>[
        const TextNode('题干文字'),
        ImageNode(assetRef: storageKey, altText: '示例图片'),
      ]);

      final encoded = codec.encode(stem);
      final jsonPayload = jsonEncode(encoded);

      await db.insert('questions', <String, Object?>{
        'id': 'q_image_1',
        'type': 3,
        'content': '题干文字',
        'options': '[]',
        'standard_answer': '标准答案',
        'explanation': '解析',
        'created_at': 1000,
        'bank_name': '默认题库',
      });

      await db.insert('question_v2_payloads', <String, Object?>{
        'question_id': 'q_image_1',
        'payload_schema_version': 1,
        'payload_json': jsonPayload,
      });

      // 3. Snapshot via BackupSnapshotRepository
      final repo = BackupSnapshotRepository(
        databaseHelper: DatabaseHelper.instance,
      );

      final snapshotPath = p.join(tempDir.path, 'snapshot', 'shiroha.db');
      final snapshot = await repo.createSanitizedSnapshot(snapshotPath);

      expect(snapshot.files.any((f) => f.storageKey == storageKey), isTrue);
      final entry =
          snapshot.files.firstWhere((f) => f.storageKey == storageKey);
      expect(entry.storageKey, storageKey);
      expect(entry.sizeBytes, imageBytes.length);
      expect(entry.sha256, isNotEmpty);
    });

    test('exports and restores content assets through BackupRestoreRuntime',
        () async {
      final db = await DatabaseHelper.instance.database;

      // 1. Store an image asset in managed root
      final imageBytes = Uint8List.fromList([10, 20, 30, 40, 50]);
      final storageKey = await assetStore.storeBytes(
        bytes: imageBytes,
        mimeType: 'image/png',
      );

      // 2. Insert question and question_v2_payload
      const codec = RichContentCodec();
      final stem = RichContent(nodes: <ContentNode>[
        const TextNode('题目'),
        ImageNode(assetRef: storageKey),
      ]);
      final jsonPayload = jsonEncode(codec.encode(stem));

      await db.insert('questions', <String, Object?>{
        'id': 'q_image_restore',
        'type': 3,
        'content': '题目',
        'options': '[]',
        'standard_answer': 'A',
        'explanation': 'E',
        'created_at': 2000,
        'bank_name': '默认题库',
      });
      await db.insert('question_v2_payloads', <String, Object?>{
        'question_id': 'q_image_restore',
        'payload_schema_version': 1,
        'payload_json': jsonPayload,
      });

      // 3. Export package
      final storage = ManagedFileStorageAdapter(managedRoot: managedRoot);
      final helper = DatabaseHelper.instance;
      final snapshots = BackupSnapshotRepository(
        databaseHelper: helper,
        managedFileStorage: storage,
      );
      final restoreRoot = Directory(p.join(tempDir.path, 'restore'))
        ..createSync(recursive: true);

      final runtime = BackupRestoreRuntime(
        databaseAuthority: SqliteBackupDatabaseAuthority(
          databaseHelper: helper,
          snapshotRepository: snapshots,
        ),
        snapshotRepository: snapshots,
        managedFileStorage: storage,
        restoreRoot: restoreRoot,
        managedFilesRoot: managedRoot,
      );

      final packagePath =
          p.join(tempDir.path, 'out', 'backup_with_images.shiroha');
      final exportSummary = await runtime.exportTo(packagePath);

      expect(exportSummary.fileCount, 1);

      // 4. Delete the live content asset file to simulate clean slate
      final liveAssetFile = assetStore.resolveAsset(storageKey);
      expect(liveAssetFile, isNotNull);
      if (liveAssetFile!.existsSync()) {
        liveAssetFile.deleteSync();
      }
      expect(assetStore.resolveAsset(storageKey), isNull);

      // 5. Restore package
      final preview = await runtime.prepareRestore(packagePath);
      expect(preview.fileCount, 1);
      final commitResult = await runtime.commitPreparedRestore();
      expect(commitResult.fileCount, 1);

      // 6. Verify restored image file exists and contains exact bytes
      final restoredFile = assetStore.resolveAsset(storageKey);
      expect(restoredFile, isNotNull);
      expect(restoredFile!.existsSync(), isTrue);
      expect(restoredFile.readAsBytesSync(), equals(imageBytes));
    });
  });
}

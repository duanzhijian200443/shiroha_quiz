import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/content/content_asset_authority.dart';
import 'package:shiroha_quiz/services/import_pipeline/candidate_asset_cleanup.dart';
import 'package:shiroha_quiz/services/import_pipeline/candidate_asset_lease.dart';
import 'package:shiroha_quiz/services/task_manager.dart';

final class _ScriptedAssetStore implements ContentAssetStore {
  _ScriptedAssetStore(this.outcomes);

  final List<ContentAssetRollbackResult> outcomes;
  var calls = 0;

  @override
  String storageKey({required String sourceId, required String localAssetId}) =>
      '$sourceId/$localAssetId';

  @override
  Future<ContentAssetWriteResult> storeBytes({
    required String sourceId,
    required String localAssetId,
    required List<int> bytes,
    required String mimeType,
  }) async {
    return storeBytesSync(
      sourceId: sourceId,
      localAssetId: localAssetId,
      bytes: bytes,
      mimeType: mimeType,
    );
  }

  @override
  ContentAssetWriteResult storeBytesSync({
    required String sourceId,
    required String localAssetId,
    required List<int> bytes,
    required String mimeType,
  }) {
    return ContentAssetWriteResult(
      storageKey: storageKey(sourceId: sourceId, localAssetId: localAssetId),
      sha256: 'fixture',
      sizeBytes: bytes.length,
      mimeType: mimeType,
      created: true,
    );
  }

  @override
  Future<ContentAssetRollbackResult> deleteCandidateAssets(
    ContentAssetCandidateLease lease,
  ) async {
    final index = calls++;
    return index < outcomes.length
        ? outcomes[index]
        : const ContentAssetRollbackResult(failedCount: 1);
  }

  @override
  List<int>? readAssetBytes({
    required String sourceId,
    required String localAssetId,
  }) =>
      null;

  @override
  Future<bool> assetExists({
    required String sourceId,
    required String localAssetId,
  }) async =>
      false;

  @override
  Future<List<ContentAssetRecord>> listAssets() async => const [];
}

const _cleanupSourceId = '15151515-1515-4151-8151-151515151515';

void main() {
  test('candidate cleanup retries one whole lease without unbounded looping',
      () async {
    final store = _ScriptedAssetStore(<ContentAssetRollbackResult>[
      const ContentAssetRollbackResult(failedCount: 1),
      const ContentAssetRollbackResult(deletedCount: 1),
    ]);
    final outcome = await deleteCandidateAssetsWithRetry(
      store: store,
      lease: ContentAssetCandidateLease(
        sourceId: _cleanupSourceId,
        localAssetIds: <String>['img_001'],
      ),
    );

    expect(outcome.isComplete, isTrue);
    expect(store.calls, 2);
  });

  test('persistent cleanup failure stores only a privacy-safe owner marker',
      () async {
    Map<String, dynamic>? savedTask;
    final manager = TaskManager.forTesting(
      saveTask: (taskMap) async {
        savedTask = taskMap;
      },
    );
    manager.tasks.add(
      ImportTask(
        id: 'cleanup-owner-task',
        title: 'Synthetic cleanup owner',
        status: TaskStatus.processing,
        diagnostics: const <String, dynamic>{
          TaskManager.keyAttemptState: 'running',
        },
      ),
    );

    final status = await manager.persistCandidateAssetCleanupPending(
      taskId: 'cleanup-owner-task',
      lease: ContentAssetCandidateLease(
        sourceId: _cleanupSourceId,
        localAssetIds: <String>['img_001', 'img_002'],
      ),
    );

    expect(status, ImportAttemptWriteStatus.applied);
    expect(savedTask, isNotNull);
    final diagnostics =
        jsonDecode(savedTask!['diagnostics'] as String) as Map<String, dynamic>;
    expect(diagnostics[candidateAssetCleanupPendingKey], isTrue);
    expect(
      diagnostics[candidateAssetCleanupSourceIdKey],
      _cleanupSourceId,
    );
    expect(
      diagnostics[candidateAssetCleanupLocalIdsKey],
      <dynamic>['img_001', 'img_002'],
    );
    final serialized = jsonEncode(diagnostics);
    expect(serialized, isNot(contains('https://')));
    expect(serialized, isNot(contains('C:\\')));
    expect(serialized, isNot(contains('raw provider')));
  });
}

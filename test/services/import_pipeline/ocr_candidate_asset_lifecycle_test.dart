import 'dart:async';
import 'dart:io';

import 'package:shiroha_quiz/application/backup/backup_restore_gate.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/content/content_asset_authority.dart';
import 'package:shiroha_quiz/services/file_library/managed_content_asset_store.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_parse_request.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_parse_result.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_pipeline_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_attempt_context.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_task_coordinator.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_question_assembler.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_question_regionizer.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_typed_candidate.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_import_service.dart';
import 'package:shiroha_quiz/services/task_manager.dart';

const _sourceId = '11111111-1111-4111-8111-111111111111';
const _questionId = '22222222-2222-4222-8222-222222222222';
const _reviewId = '33333333-3333-4333-8333-333333333333';
const _pngDataUrl = 'data:image/png;base64,'
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
    '+A8AAQUBAScY42YAAAAASUVORK5CYII=';

void main() {
  late Directory temp;

  setUp(() {
    BackupRestoreMutationGate.resetForTesting();
  });

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('ocr_asset_lifecycle_');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
    BackupRestoreMutationGate.resetForTesting();
  });

  test('pipeline fallback rolls back newly acquired candidate assets',
      () async {
    final store = ManagedContentAssetStore(managedRoot: temp);
    final fixture = _fixture();
    final region = const OcrQuestionRegionizer().regionize(fixture).regions;
    final legacyQuestion =
        const OcrQuestionAssembler().assemble(region.single).question;
    final batch = buildOcrTypedCandidateBatch(
      document: fixture,
      regions: region,
      legacyQuestions: <Map<String, dynamic>>[legacyQuestion],
      uuidV4Factory: _uuidSequence(),
      assetStore: store,
    );
    final lease = batch.candidateAssetLease;
    expect(lease, isNotNull);
    expect(lease!.localAssetIds, <String>['img_001']);
    expect(
      store.readAssetBytes(sourceId: _sourceId, localAssetId: 'img_001'),
      isNotNull,
    );

    final finalQuestion = Map<String, dynamic>.from(legacyQuestion)
      ..['explanation'] = 'different final explanation';
    final pipeline = ImportPipelineService.forTesting(
      taskManager: TaskManager.forTesting(),
      contentAssetStore: store,
      textParser: (_, {required taskId, required isMarkdown}) async => const [],
      visionParser: (_) async => const [],
      ocrParser: ({
        required filePath,
        required sourceName,
        required format,
        required explanationRetentionMode,
      }) async {
        return OcrImportResult(
          usedOcr: true,
          questions: <Map<String, dynamic>>[finalQuestion],
          warnings: const <String>[],
          diagnostics: const <String, dynamic>{},
          typedCandidateBatch: batch,
        );
      },
    );

    final result = await pipeline.parseFiles(
      const ImportParseRequest(
        filePaths: <String>['fixture.png'],
        fileNames: <String>['fixture.png'],
        mode: ImportParseMode.ocr,
        maxConcurrency: 1,
        taskId: 'lifecycle-fallback',
      ),
    );

    expect(result.storageRoute.name, 'legacyV1');
    expect(result.storageReason, 'typed_candidate_raw_explanation_diverged');
    expect(
      store.readAssetBytes(sourceId: _sourceId, localAssetId: 'img_001'),
      isNull,
    );
  });

  test(
      'candidate lease excludes pre-existing identity and rollback is idempotent',
      () async {
    final store = ManagedContentAssetStore(managedRoot: temp);
    final bytes = OcrImagePayload.fromDataUrl(_pngDataUrl)!.bytes;
    store.storeBytesSync(
      sourceId: _sourceId,
      localAssetId: 'img_001',
      bytes: bytes,
      mimeType: 'image/png',
    );
    final fixture = _fixture();
    final region = const OcrQuestionRegionizer().regionize(fixture).regions;
    final legacyQuestion =
        const OcrQuestionAssembler().assemble(region.single).question;
    final batch = buildOcrTypedCandidateBatch(
      document: fixture,
      regions: region,
      legacyQuestions: <Map<String, dynamic>>[legacyQuestion],
      uuidV4Factory: _uuidSequence(),
      assetStore: store,
    );

    expect(batch.candidateAssetLease, isNotNull);
    expect(batch.candidateAssetLease!.localAssetIds, isEmpty);
    await store.deleteCandidateAssets(batch.candidateAssetLease!);
    await store.deleteCandidateAssets(batch.candidateAssetLease!);
    expect(
      store.readAssetBytes(sourceId: _sourceId, localAssetId: 'img_001'),
      bytes,
    );
  });

  test('cancellation rolls back a lease returned after the cancel boundary',
      () async {
    final store = ManagedContentAssetStore(managedRoot: temp);
    final bytes = OcrImagePayload.fromDataUrl(_pngDataUrl)!.bytes;
    store.storeBytesSync(
      sourceId: _sourceId,
      localAssetId: 'img_001',
      bytes: bytes,
      mimeType: 'image/png',
    );
    final lease = ContentAssetCandidateLease(
      sourceId: _sourceId,
      localAssetIds: const <String>['img_001'],
    );
    final release = Completer<void>();
    var started = false;
    final manager = TaskManager.forTesting();
    final coordinator = ImportTaskCoordinator(
      taskManager: manager,
      readiness: manager.ready,
      contentAssetStore: store,
      taskIdFactory: () => 'cancel-lifecycle-task',
      traceIdFactory: () => 'cancel-lifecycle-trace',
    );

    final handle = await coordinator.dispatch(
      sourceDescription: 'fixture.pdf',
      mode: ImportParseMode.ocr,
      parse: (_) async {
        started = true;
        await release.future;
        return ImportParseResult(
          questions: const <Map<String, dynamic>>[
            <String, dynamic>{
              'q_num': '1',
              'type': 0,
              'content': 'Synthetic cancellation question',
              'options': <String>[],
              'standard_answer': '',
              'explanation': '',
            },
          ],
          candidateAssetLease: lease,
        );
      },
    );
    while (!started) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(
      await coordinator.cancelOcrTask(handle.taskId),
      ImportAttemptWriteStatus.applied,
    );
    release.complete();
    await _waitForTask(
      manager,
      handle.taskId,
      (task) => task.attemptState == ImportAttemptState.cancelled,
    );
    await _waitForAsset(
      store,
      exists: false,
    );
    expect(
      store.readAssetBytes(sourceId: _sourceId, localAssetId: 'img_001'),
      isNull,
    );
  });

  test('retry rolls back the previous attempt namespace before restart',
      () async {
    final store = ManagedContentAssetStore(managedRoot: temp);
    final bytes = OcrImagePayload.fromDataUrl(_pngDataUrl)!.bytes;
    store.storeBytesSync(
      sourceId: _sourceId,
      localAssetId: 'img_001',
      bytes: bytes,
      mimeType: 'image/png',
    );
    final lease = ContentAssetCandidateLease(
      sourceId: _sourceId,
      localAssetIds: const <String>['img_001'],
    );
    final manager = TaskManager.forTesting();
    final coordinator = ImportTaskCoordinator(
      taskManager: manager,
      readiness: manager.ready,
      contentAssetStore: store,
      taskIdFactory: () => 'retry-lifecycle-task',
      traceIdFactory: () => 'retry-lifecycle-trace',
      attemptTokenFactory: () => 'retry-lifecycle-token',
    );

    final first = await coordinator.dispatch(
      sourceDescription: 'fixture.pdf',
      mode: ImportParseMode.ocr,
      parse: (_) async => ImportParseResult(
        questions: const <Map<String, dynamic>>[
          <String, dynamic>{
            'q_num': '1',
            'type': 0,
            'content': 'Synthetic first attempt',
            'options': <String>[],
            'standard_answer': '',
            'explanation': '',
          },
        ],
        candidateAssetLease: lease,
      ),
    );
    await _waitForTask(
      manager,
      first.taskId,
      (task) => task.status == TaskStatus.pendingReview,
    );
    expect(
      store.readAssetBytes(sourceId: _sourceId, localAssetId: 'img_001'),
      isNotNull,
    );
    final failedTask = manager.tasks.single;
    failedTask.status = TaskStatus.error;
    failedTask.errorMsg = 'synthetic failure';
    failedTask.diagnostics = <String, dynamic>{
      ...?failedTask.diagnostics,
      TaskManager.keyAttemptState: ImportAttemptState.failed.name,
    };

    await coordinator.retryOcrTask(
      taskId: first.taskId,
      sourceDescription: 'fixture.pdf',
      parse: (_) async => const ImportParseResult(
        questions: <Map<String, dynamic>>[
          <String, dynamic>{
            'q_num': '2',
            'type': 0,
            'content': 'Synthetic retry attempt',
            'options': <String>[],
            'standard_answer': '',
            'explanation': '',
          },
        ],
      ),
    );
    await _waitForTask(
      manager,
      first.taskId,
      (task) =>
          task.status == TaskStatus.pendingReview && task.attemptNumber == 2,
    );
    expect(
      store.readAssetBytes(sourceId: _sourceId, localAssetId: 'img_001'),
      isNull,
    );
  });
}

Future<ImportTask> _waitForTask(
  TaskManager manager,
  String taskId,
  bool Function(ImportTask task) predicate,
) async {
  for (var index = 0; index < 100; index++) {
    final matches = manager.tasks.where((task) => task.id == taskId);
    if (matches.isNotEmpty && predicate(matches.single)) return matches.single;
    await Future<void>.delayed(Duration.zero);
  }
  throw StateError('Synthetic import task did not reach the expected state.');
}

Future<void> _waitForAsset(
  ManagedContentAssetStore store, {
  required bool exists,
}) async {
  for (var index = 0; index < 100; index++) {
    final present = store.readAssetBytes(
          sourceId: _sourceId,
          localAssetId: 'img_001',
        ) !=
        null;
    if (present == exists) return;
    await Future<void>.delayed(Duration.zero);
  }
  throw StateError(
      'Synthetic candidate asset did not reach the expected state.');
}

OcrDocument _fixture() {
  return OcrDocument(
    sourceName: 'synthetic.pdf',
    pages: <OcrPage>[
      OcrPage(
        pageIndex: 1,
        blocks: <OcrBlock>[
          _block('section', 'text', '三、解答题', 0),
          _block('q_1', 'text', '1. Prompt before image', 1),
          _block('img_001', 'image', _pngDataUrl, 2),
          _block('answer_1', 'text', '答案：synthetic-result-1', 3),
          _block('explanation_1', 'text', '解析：Synthetic explanation 1', 4),
        ],
      ),
    ],
    markdown: '',
    rawResponses: const <Map<String, dynamic>>[],
    usage: const <String, dynamic>{},
  );
}

OcrBlock _block(String id, String type, String text, int order) {
  return OcrBlock(
    blockId: id,
    pageIndex: 1,
    type: type,
    text: text,
    bbox: const <double>[],
    readingOrder: order,
  );
}

String Function() _uuidSequence() {
  final values = <String>[_sourceId, _questionId, _reviewId];
  var index = 0;
  return () => values[index++];
}

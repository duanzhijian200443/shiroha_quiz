import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shiroha_quiz/application/content/content_asset_authority.dart';
import 'package:shiroha_quiz/data/models/ai_engine_profile.dart';
import 'package:shiroha_quiz/services/import_pipeline/candidate_asset_lease.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_attempt_context.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_field_policy.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_task_coordinator.dart';
import 'package:shiroha_quiz/services/llm_providers/zhipu_ocr_client.dart';
import 'package:shiroha_quiz/services/task_manager.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

final class _ChunkedResponseClient extends http.BaseClient {
  _ChunkedResponseClient(this.chunks);

  final List<List<int>> chunks;
  var sendCalls = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sendCalls++;
    return http.StreamedResponse(
      Stream<List<int>>.fromIterable(chunks),
      200,
      headers: const <String, String>{'content-type': 'application/json'},
    );
  }
}

final class _FailingCandidateAssetStore implements ContentAssetStore {
  var deleteCalls = 0;

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
    deleteCalls++;
    return ContentAssetRollbackResult(failedCount: lease.localAssetIds.length);
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

const _profile = AiEngineProfile(
  id: 'test-ocr',
  engineType: AiEngineType.ocr,
  name: 'Test OCR',
  apiKey: 'fixture-api-key',
  baseUrl: 'https://example.test/api/paas',
  modelName: ZhipuOcrClient.model,
  temperature: 0,
  reasoningEffort: '',
  isActive: true,
);

File _syntheticPdfFile(int pageCount) {
  final document = PdfDocument();
  for (var index = 0; index < pageCount; index++) {
    document.pages.add();
  }
  final bytes = document.saveSync();
  document.dispose();
  return File(
    '${Directory.systemTemp.path}${Platform.pathSeparator}'
    'pr137-layout-budget-${DateTime.now().microsecondsSinceEpoch}.pdf',
  )..writeAsBytesSync(bytes);
}

void main() {
  test('layout response cap rejects before JSON admission', () async {
    final file = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'pr137-layout-bound-${DateTime.now().microsecondsSinceEpoch}.png',
    )..writeAsBytesSync(const <int>[1]);
    addTearDown(() {
      if (file.existsSync()) file.deleteSync();
    });

    final body = utf8.encode(jsonEncode(<String, Object?>{
      'md_results': List<String>.filled(64, 'x').join(),
      'layout_details': const <Object?>[],
      'data_info': const <String, Object?>{
        'num_pages': 1,
        'pages': <Object?>[
          <String, Object?>{'width': 1, 'height': 1},
        ],
      },
    }));
    final split = body.length ~/ 2;
    final client = ZhipuOcrClient(
      httpClient: _ChunkedResponseClient(<List<int>>[
        body.sublist(0, split),
        body.sublist(split),
      ]),
      layoutResponseBytesLimit: 32,
    );

    await expectLater(
      client.parseFile(
        profile: _profile,
        filePath: file.path,
        sourceName: 'fixture.png',
      ),
      throwsA(isA<ZhipuOcrResponseFormatException>()),
    );
  });

  test('layout response budget is shared across PDF chunks', () async {
    final file = _syntheticPdfFile(2);
    addTearDown(() {
      if (file.existsSync()) file.deleteSync();
    });

    final body = utf8.encode(jsonEncode(<String, Object?>{
      'md_results': 'Page Content',
      'layout_details': const <Object?>[
        <Object?>[
          <String, Object?>{
            'index': 1,
            'label': 'text',
            'content': 'hello',
          },
        ],
      ],
      'data_info': const <String, Object?>{
        'num_pages': 1,
        'pages': <Object?>[
          <String, Object?>{'width': 600, 'height': 800},
        ],
      },
    }));
    final split = body.length ~/ 2;
    final transport = _ChunkedResponseClient(<List<int>>[
      body.sublist(0, split),
      body.sublist(split),
    ]);
    final client = ZhipuOcrClient(
      pdfPageChunkSize: 1,
      httpClient: transport,
      layoutResponseBytesLimit: body.length + split - 1,
    );

    await expectLater(
      client.parseFile(
        profile: _profile,
        filePath: file.path,
        sourceName: 'fixture.pdf',
      ),
      throwsA(isA<ZhipuOcrResponseFormatException>()),
    );
    expect(transport.sendCalls, 2);
  });

  test('retry keeps cleanup owner when deletion still fails', () async {
    final saved = <Map<String, dynamic>>[];
    final manager = TaskManager.forTesting(
      saveTask: (taskMap) async {
        saved.add(Map<String, dynamic>.from(taskMap));
      },
    );
    await manager.ready;
    final cleanupLease = ContentAssetCandidateLease(
      sourceId: '15151515-1515-4151-8151-151515151515',
      localAssetIds: const <String>['img_001'],
    );
    manager.tasks.add(
      ImportTask(
        id: 'retry-cleanup-owner',
        title: 'Synthetic OCR retry',
        status: TaskStatus.error,
        diagnostics: <String, dynamic>{
          TaskManager.keyTraceId: 'trace-1',
          TaskManager.keyParseMode: 'ocr',
          TaskManager.keyAttemptNumber: 1,
          TaskManager.keyAttemptToken: 'attempt-1',
          TaskManager.keyAttemptState: ImportAttemptState.failed.name,
          TaskManager.keyExplanationRetentionMode:
              ExplanationRetentionMode.subjectiveOnly.name,
          ...candidateAssetCleanupPendingDiagnostics(cleanupLease),
        },
      ),
    );
    final store = _FailingCandidateAssetStore();
    final coordinator = ImportTaskCoordinator(
      taskManager: manager,
      readiness: Future<void>.value(),
      contentAssetStore: store,
      traceIdFactory: () => 'trace-2',
      attemptTokenFactory: () => 'attempt-2',
    );

    await expectLater(
      coordinator.retryOcrTask(
        taskId: 'retry-cleanup-owner',
        sourceDescription: 'fixture.pdf',
        parse: (_) async => throw StateError('retry parser must not run'),
      ),
      throwsA(isA<ImportTaskRetryRejectedException>()),
    );

    expect(store.deleteCalls, 2);
    expect(manager.tasks.single.attemptNumber, 1);
    expect(
      manager.tasks.single.diagnostics?[candidateAssetCleanupPendingKey],
      isTrue,
    );
    expect(
      manager.tasks.single.diagnostics?[candidateAssetCleanupLocalIdsKey],
      <String>['img_001'],
    );
    expect(saved, isEmpty);
  });
}

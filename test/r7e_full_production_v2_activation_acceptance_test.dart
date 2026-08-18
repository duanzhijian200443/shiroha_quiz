// R7E permanent acceptance: full production V2 activation.
//
// Evidence class: synthetic fixtures only. E1 drives one vertical scenario
// end to end: synthetic single-file OCR -> the real production parse chain
// (OcrImportService / ImportPipelineService / ImportTaskCoordinator /
// TaskManager pendingReview with route typedV2 + typed_candidate_ready)
// -> real TaskManager persistence on a real v15 file database -> simulated
// restart reload -> ImportStagingScreen with the real commit service ->
// one user-visible typed review mutation -> final review flush ->
// ImportCommitService.commitTyped -> QuestionRepository atomic transaction
// -> close/reopen -> QuestionListScreen production read -> typed
// RichContent rendering. E2 proves the sidecar is authoritative when the
// V1 compatibility row drifts, and E3 proves a partial sidecar on a real
// committed typed row fails the whole bank load with the fixed safe UI
// error and no legacy fallback.
//
// Every database is opened through the frozen
// DatabaseHelper.openPathForTesting seam; the fake OCR client is the only
// provider boundary and is never invoked by E2/E3, so Provider calls are 0
// by construction.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/application/import_review/typed_review_snapshot.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/models/ai_engine_profile.dart';
import 'package:shiroha_quiz/data/models/persisted_question.dart';
import 'package:shiroha_quiz/data/models/question_draft.dart';
import 'package:shiroha_quiz/data/models/typed_import_commit_guard.dart';
import 'package:shiroha_quiz/data/persistence/question_v2_persistence_mapper.dart';
import 'package:shiroha_quiz/data/repositories/ai_engine_repository.dart';
import 'package:shiroha_quiz/data/repositories/import_task_repository.dart';
import 'package:shiroha_quiz/data/repositories/question_repository.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_parse_request.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_pipeline_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_field_policy.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_task_coordinator.dart';
import 'package:shiroha_quiz/services/import_pipeline/local_question_assembler.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document_client.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_import_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_typed_candidate.dart';
import 'package:shiroha_quiz/services/import_pipeline/single_question_repair_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/subjective_answer_distillation_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/text_question_region.dart';
import 'package:shiroha_quiz/services/import_review/import_commit_service.dart';
import 'package:shiroha_quiz/services/import_review/typed_review_result_builder.dart';
import 'package:shiroha_quiz/services/task_manager.dart';
import 'package:shiroha_quiz/ui/pages/import_staging_screen.dart';
import 'package:shiroha_quiz/ui/pages/question_list_screen.dart';
import 'package:shiroha_quiz/ui/widgets/persisted_question_card.dart';
import 'package:shiroha_quiz/ui/widgets/structured_content_renderer.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/memory_content_asset_store.dart';
import 'support/unsupported_ai_engine_store.dart';

const _sourceName = 'r7e_acceptance_single.pdf';
const _bankName = 'r7e_synthetic_bank';

class _FakeAiEngineRepository extends AiEngineRepository {
  _FakeAiEngineRepository(this.profile)
      : super(
          store: const UnsupportedAiEngineStore(),
          credentialStore: const UnsupportedEngineCredentialStore(),
        );

  final AiEngineProfile profile;

  @override
  Future<AiEngineProfile?> getActiveOcrEngine() async => profile;
}

class _FakeOcrDocumentClient implements OcrDocumentClient {
  _FakeOcrDocumentClient(this.document);

  final OcrDocument document;
  int callCount = 0;

  @override
  String get modelId => 'fake-ocr-model';

  @override
  Future<OcrDocument> parseFile({
    required AiEngineProfile profile,
    required String filePath,
    required String sourceName,
    Duration timeout = const Duration(minutes: 8),
  }) async {
    callCount++;
    return document;
  }
}

class _FakeRepairService extends SingleQuestionRepairService {
  const _FakeRepairService();

  @override
  Future<LocalAssemblyResult> repair({
    required TextQuestionRegion region,
    required LocalAssemblyResult localResult,
    required bool requireAnswer,
    required ExplanationRetentionMode explanationRetentionMode,
  }) async {
    return localResult;
  }
}

/// Synthetic provider-boundary distiller: returns a fixed answer with no
/// AI/network call, mirroring the frozen R7C.1 vertical distillation seam.
class _FixedDistiller implements SubjectiveAnswerDistiller {
  const _FixedDistiller(this.answer);

  final String answer;

  @override
  Future<SubjectiveAnswerDistillationResult> distill({
    required int questionNumber,
    required QuestionDraft question,
    required bool isStemOnly,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    return SubjectiveAnswerDistillationResult.applied(answer);
  }
}

AiEngineProfile _ocrProfile() {
  return const AiEngineProfile(
    id: 'r7e-ocr',
    engineType: AiEngineType.ocr,
    name: 'zhipu-ocr',
    apiKey: 'test-key',
    baseUrl: 'https://open.bigmodel.cn/api/paas',
    modelName: 'glm-ocr',
    temperature: 0.1,
    reasoningEffort: '',
    isActive: true,
  );
}

/// Deterministic canonical UUIDv4 factory so every identity is reproducible.
String Function() _uuidFactory() {
  var index = 0;
  return () {
    index++;
    return '0d8b7a3e-7f1c-4b2a-9d3e-${index.toRadixString(16).padLeft(12, '0')}';
  };
}

OcrBlock _block(
  String blockId,
  int pageIndex,
  int readingOrder,
  String text, {
  String type = 'text',
}) {
  return OcrBlock(
    blockId: blockId,
    pageIndex: pageIndex,
    type: type,
    text: text,
    bbox: const <double>[],
    readingOrder: readingOrder,
  );
}

OcrDocument _document(String sourceName, List<OcrPage> pages) {
  return OcrDocument(
    sourceName: sourceName,
    pages: pages,
    markdown: '',
    rawResponses: const <Map<String, dynamic>>[],
    usage: const <String, dynamic>{},
  );
}

/// One answer-bearing question and one stem-only question in document
/// order: the batch stays typed-eligible while question 2 remains a
/// distillation candidate for the user-visible typed review mutation.
OcrDocument _e1Document() {
  return _document(
    _sourceName,
    <OcrPage>[
      OcrPage(
        pageIndex: 1,
        blocks: <OcrBlock>[
          _block('section', 1, 0, '三、解答题'),
          _block('q_1', 1, 1, '1. Synthetic prompt marker 1.'),
          _block('answer_1', 1, 2, '答案：synthetic-result-1'),
          _block('e_1', 1, 3, '解析：Synthetic explanation 1'),
          _block('q_2', 1, 4, '2. Synthetic prompt marker 2.'),
          _block('e_2', 1, 5, '解析：Synthetic explanation 2'),
        ],
      ),
    ],
  );
}

/// File-backed DatabaseHelper seam: repository APIs run against a real
/// database opened through the frozen openPathForTesting seam. Only the
/// members used by the exercised repository paths are reachable.
class _FileDatabaseHelper extends Fake implements DatabaseHelper {
  _FileDatabaseHelper(this.path);

  final String path;
  Database? _database;

  @override
  Future<Database> get database async =>
      _database ??= await DatabaseHelper.instance.openPathForTesting(path);

  @override
  Future<void> saveImportTask(Map<String, dynamic> taskData) async {
    final db = await database;
    await db.insert(
      'import_tasks',
      taskData,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<List<Map<String, dynamic>>> getAllImportTasks() async {
    final db = await database;
    return db.query('import_tasks', orderBy: 'created_at DESC');
  }

  @override
  Future<Map<String, List<Map<String, dynamic>>>> getSubjectTree() async =>
      const <String, List<Map<String, dynamic>>>{};

  @override
  Future<void> close() async {
    final db = _database;
    _database = null;
    if (db != null) await db.close();
  }
}

/// Real repository implementation with call counters proving the screen
/// only uses the V2-first union read and the atomic typed writer.
class _CountingRepository extends QuestionRepository {
  _CountingRepository({super.databaseHelper});

  int atomicCalls = 0;
  int legacyCalls = 0;
  int persistedReadCalls = 0;

  @override
  Future<TypedImportCommitPersistenceResult> commitQuestionDraftsV2ForImport({
    required String bankName,
    String? folderName,
    required List<QuestionDraftV2> questions,
    required TypedImportCommitGuard guard,
    required String completionText,
  }) async {
    atomicCalls++;
    return super.commitQuestionDraftsV2ForImport(
      bankName: bankName,
      folderName: folderName,
      questions: questions,
      guard: guard,
      completionText: completionText,
    );
  }

  @override
  Future<void> saveQuestionDraftsToBank({
    required String bankName,
    required String? folderName,
    required List<QuestionDraft> questions,
  }) async {
    legacyCalls++;
    await super.saveQuestionDraftsToBank(
      bankName: bankName,
      folderName: folderName,
      questions: questions,
    );
  }

  @override
  Future<List<PersistedQuestion>> getPersistedQuestionsByBank(
    String bankName,
  ) async {
    persistedReadCalls++;
    return super.getPersistedQuestionsByBank(bankName);
  }
}

RichContent _text(String text) {
  return RichContent(nodes: <ContentNode>[TextNode(text)]);
}

Future<void> _insertReviewState(Database db, String questionId) async {
  await db.insert('review_states', <String, Object?>{
    'question_id': questionId,
    'state': 0,
    'next_review_time': 0,
    'lapses': 0,
    'difficulty': 5.0,
    'stability': 0.0,
    'reps': 0,
    'last_lapse_time': 0,
    'last_review_time': 0,
  });
}

Future<void> _insertLegacy(
  Database db, {
  required String id,
  String content = 'Legacy stem text.',
  String answer = 'L|||Legacy explanation.',
}) async {
  await db.insert('questions', <String, Object?>{
    'id': id,
    'type': 0,
    'content': content,
    'options': '["A. legacy one","B. legacy two"]',
    'standard_answer': answer,
    'explanation': 'Legacy explanation.',
    'raw_explanation': 'Legacy raw explanation.',
    'created_at': 1700000001,
    'bank_name': _bankName,
  });
  await _insertReviewState(db, id);
}

/// Runs the synthetic OCR parse through the real coordinator into a real
/// TaskManager persisted on the caller's database helper.
Future<
    ({
      _FakeOcrDocumentClient client,
      ImportTaskHandle handle,
    })> _dispatchTypedOcrTask(
  TaskManager manager, {
  required String taskId,
  required OcrDocument document,
}) async {
  final client = _FakeOcrDocumentClient(document);
  final ocrService = OcrImportService(
    engineRepository: _FakeAiEngineRepository(_ocrProfile()),
    ocrClient: client,
    assetStore: MemoryContentAssetStore(),
    repairService: const _FakeRepairService(),
    uuidV4Factory: _uuidFactory(),
  );
  final pipeline = ImportPipelineService.forTesting(
    textParser: (rawText, {required taskId, required isMarkdown}) async =>
        fail('text parser must not run'),
    visionParser: (imagePaths) async => fail('vision parser must not run'),
    ocrParser: ocrService.tryParse,
  );
  final coordinator = ImportTaskCoordinator(
    taskManager: manager,
    readiness: manager.ready,
    parser: pipeline.parseFiles,
    taskIdFactory: () => taskId,
    traceIdFactory: () => '$taskId-trace',
  );
  final handle = await coordinator.dispatchRequest(
    sourceDescription: _sourceName,
    filePaths: const <String>['single.pdf'],
    fileNames: const <String>[_sourceName],
    mode: ImportParseMode.ocr,
    maxConcurrency: 1,
  );
  await _waitForImportTask(
    manager,
    handle.taskId,
    (task) => task.status == TaskStatus.pendingReview,
  );
  return (client: client, handle: handle);
}

/// Mirrors the staging screen marker recovery: the persisted `_reviewItemId`
/// marker wins, otherwise the canonical id inside the envelope is used.
String _reviewItemIdFor(Map<String, dynamic> question) {
  final stored = question[TaskManager.keyReviewItemId]?.toString();
  if (stored != null && stored.isNotEmpty) return stored;
  final envelope = question[TypedReviewSnapshotCodec.mapKey];
  return (envelope as Map)['reviewItemId'] as String;
}

/// Runs one real-async database chunk: the FakeAsync widget-test zone cannot
/// drive file I/O, so every database touch must run inside the real zone.
Future<void> _dbChunk(WidgetTester tester, Future<void> Function() action) {
  return tester.runAsync(action);
}

/// Spins real event-loop time while pumping fake frames so pending real
/// database reads/writes and their continuation microtasks can flush.
Future<void> _spinForDatabase(WidgetTester tester, {int iterations = 120}) {
  return tester.runAsync(() async {
    for (var i = 0; i < iterations; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      await tester.pump();
    }
  });
}

/// Enlarges the test viewport so a lazy ListView builds every card.
void _setTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 2800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> _pumpListScreen(
  WidgetTester tester,
  QuestionRepository repository, {
  ValueChanged<int?>? onLoadFinished,
}) async {
  await tester.runAsync(() async {
    await tester.pumpWidget(
      MaterialApp(
        home: QuestionListScreen(
          bankName: _bankName,
          questionRepository: repository,
          onLoadFinished: onLoadFinished,
        ),
      ),
    );
  });
  await _spinForDatabase(tester);
  await tester.pumpAndSettle();
}

/// Opens the staging save dialog and confirms the typed commit. Real
/// database I/O is driven by the caller through [_spinForDatabase].
Future<void> _commitThroughDialog(WidgetTester tester) async {
  await tester.tap(
    find.ancestor(
      of: find.textContaining('收入题库'),
      matching: find.byType(ElevatedButton),
    ),
  );
  await tester.pumpAndSettle();
  if (find.text('仍然继续').evaluate().isNotEmpty) {
    await tester.tap(find.text('仍然继续'));
    await tester.pumpAndSettle();
  }
  if (find.text('继续').evaluate().isNotEmpty) {
    await tester.tap(find.text('继续'));
    await tester.pumpAndSettle();
  }
  await tester.enterText(
    find.widgetWithText(TextField, '目标题库名称'),
    _bankName,
  );
  await tester.enterText(
    find.widgetWithText(TextField, '所属学科分类 (选填)'),
    'Math',
  );
  await tester.tap(find.text('确定入库'));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('r7e_acceptance_');
  });

  tearDown(() async {
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
        break;
      } on PathAccessException {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  });

  testWidgets(
      'E1: synthetic OCR -> real typed chain -> staging mutation -> '
      'atomic commit -> close/reopen -> V2-first QuestionList', (tester) async {
    _setTallViewport(tester);
    final path = p.join(tempDir.path, 'r7e_e1_full_chain.db');
    late _FileDatabaseHelper helper;
    late _FakeOcrDocumentClient client;

    // Synthetic single-file OCR through the real production parse chain and
    // coordinator into a real TaskManager persisted on a real v15 file DB.
    await tester.runAsync(() async {
      helper = _FileDatabaseHelper(path);
      final taskRepo = ImportTaskRepository(databaseHelper: helper);
      final parseManager = TaskManager.forTesting(
        saveTask: (map) => taskRepo.saveImportTask(map),
        loadTasks: () => taskRepo.getAllImportTasks(),
      );
      await parseManager.ready;
      final dispatched = await _dispatchTypedOcrTask(
        parseManager,
        taskId: 'r7e-e1-task',
        document: _e1Document(),
      );
      client = dispatched.client;
      expect(client.callCount, 1,
          reason: 'one synthetic boundary invocation; Provider calls are 0 '
              'by construction');
      final task = parseManager.tasks.single;
      expect(task.status, TaskStatus.pendingReview);
      expect(task.diagnostics?[TaskManager.keyImportStorageRoute], 'typedV2');
      expect(
        task.diagnostics?[TaskManager.keyImportStorageReason],
        'typed_candidate_ready',
      );
      expect(task.parsedData, hasLength(2));
    });

    // Simulated restart: a fresh TaskManager reloads the same file DB and
    // must keep the typed route (never silently downgraded to legacy).
    late TaskManager stagingManager;
    late _CountingRepository repository;
    late ImportCommitService service;
    await tester.runAsync(() async {
      final taskRepo = ImportTaskRepository(databaseHelper: helper);
      stagingManager = TaskManager.forTesting(
        saveTask: (map) => taskRepo.saveImportTask(map),
        loadTasks: () => taskRepo.getAllImportTasks(),
      );
      await stagingManager.ready;
      repository = _CountingRepository(databaseHelper: helper);
      service = ImportCommitService(
        questionRepository: repository,
        taskManager: stagingManager,
      );
    });

    final task = stagingManager.tasks.single;
    expect(task.status, TaskStatus.pendingReview);
    expect(task.diagnostics?[TaskManager.keyImportStorageRoute], 'typedV2');
    expect(
      task.diagnostics?[TaskManager.keyImportStorageReason],
      'typed_candidate_ready',
    );
    expect(task.attemptToken, isNotNull);
    expect(task.attemptNumber, 1);
    final codec = const TypedReviewSnapshotCodec();
    for (final question in task.parsedData!) {
      final envelope = question[TypedReviewSnapshotCodec.mapKey];
      expect(envelope, isA<Map<String, Object?>>());
      final decoded = codec.decodeRequired(envelope);
      expect(isCanonicalUuidV4(decoded.reviewItemId), isTrue);
      expect(isCanonicalUuidV4(decoded.questionId), isTrue);
      expect(decoded.questionId, decoded.draft.questionId);
      expect(decoded.baselineLegacy.content, question['content']);
    }

    // Pump a launcher and push the staging screen as a real route so the
    // success dialog can pop cleanly after the typed commit.
    await tester.runAsync(() async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: Text('launcher'))),
        ),
      );
    });
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    await tester.runAsync(() async {
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            body: ImportStagingScreen(
              parsedQuestions: task.parsedData!,
              taskId: task.id,
              diagnostics: task.diagnostics,
              questionRepository: repository,
              taskManager: stagingManager,
              commitService: service,
              answerDistiller: const _FixedDistiller('E1 distilled conclusion'),
            ),
          ),
        ),
      );
    });
    await tester.pumpAndSettle();
    await _spinForDatabase(tester);
    await tester.pumpAndSettle();

    // One user-visible typed review mutation: distill the missing answer of
    // question 2 through the real merge -> review-draft save path.
    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('answer-distillation-single-1')),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('answer-distillation-single-1')),
    );
    await _spinForDatabase(tester);
    await tester.pumpAndSettle();
    expect(find.text('标准答案已生成'), findsOneWidget);
    expect(find.text('E1 distilled conclusion'), findsOneWidget,
        reason: 'the user-visible edit must land in the staged card');
    // Let the outcome snackbar expire so it cannot cover the confirm button.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    // Final review flush + typed commit through the real production chain.
    await _commitThroughDialog(tester);
    await _spinForDatabase(tester);
    await tester.pumpAndSettle();

    expect(find.text('本次导入报告'), findsOneWidget);
    expect(stagingManager.tasks.single.status, TaskStatus.completed);
    expect(stagingManager.tasks.single.parsedData, isNull,
        reason: 'parsed_data clears after the durable completion');
    expect(repository.atomicCalls, 1);
    expect(repository.legacyCalls, 0,
        reason: 'the typed route must never touch the legacy writer');
    expect(client.callCount, 1,
        reason: 'no second OCR invocation; Provider calls are 0 by '
            'construction');

    // Dismiss the success report dialog cleanly, then close and reopen the
    // real database before the V2-first read.
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await helper.close();
    });

    // V2-first QuestionList production read after close/reopen.
    int? lastCount = -1;
    final readHelper = _FileDatabaseHelper(path);
    final readRepository = _CountingRepository(databaseHelper: readHelper);
    await _pumpListScreen(
      tester,
      readRepository,
      onLoadFinished: (count) => lastCount = count,
    );

    expect(lastCount, 2);
    expect(readRepository.persistedReadCalls, 1);
    expect(find.byType(PersistedQuestionCard), findsNWidgets(2));
    expect(find.text('Synthetic prompt marker 1.'), findsOneWidget);
    expect(find.text('synthetic-result-1'), findsOneWidget,
        reason: 'the OCR answer must survive into the typed row');
    expect(find.text('Synthetic prompt marker 2.'), findsOneWidget);
    expect(find.text('E1 distilled conclusion'), findsOneWidget,
        reason: 'the staged user edit must survive the atomic commit');
    expect(find.text('结构化'), findsNWidgets(2));
    expect(find.byType(RichContentRenderer), findsWidgets,
        reason: 'typed rows render through the RichContent path');
    expect(tester.takeException(), isNull);

    await tester.runAsync(() async {
      final db = await readHelper.database;
      final version = await db.rawQuery('PRAGMA user_version');
      expect(version.single['user_version'], DatabaseHelper.databaseVersion);
      expect(await db.query('questions'), hasLength(2));
      final payloads = await db.query('question_v2_payloads');
      expect(payloads, hasLength(2), reason: 'one sidecar per typed row');
      for (final row in payloads) {
        expect(row['payload_schema_version'], 2);
      }
      expect(await db.query('review_states'), hasLength(2));
      final ids = await db.query('questions', columns: <String>['id']);
      expect(ids.map((row) => row['id']).toSet(), hasLength(2),
          reason: 'exactly one batch, no duplicate storage ids');
      final taskRows = await db.query('import_tasks');
      expect(taskRows, hasLength(1));
      final completed = taskRows.single;
      expect(completed['status'], 2, reason: 'task completed');
      expect(completed['parsed_data'], isNull,
          reason: 'parsed_data must be cleared after completion');
      expect(completed['completed_at'], isNotNull);
      final diagnostics = jsonDecode(completed['diagnostics'] as String)
          as Map<String, Object?>;
      expect(diagnostics[TaskManager.keyImportStorageRoute], 'typedV2');
      expect(
        diagnostics[TaskManager.keyImportStorageReason],
        'typed_candidate_ready',
      );
      expect(diagnostics[TaskManager.keyReviewDraftRevision] as int,
          greaterThan(0),
          reason: 'the commit must bind a positive final review revision');
      expect((await db.query('bank_folders')).single['folder_name'], 'Math');
      await readHelper.close();
    });
  });

  testWidgets(
      'E2: sidecar stays authoritative when the V1 compatibility row drifts '
      'in a mixed bank', (tester) async {
    _setTallViewport(tester);
    final path = p.join(tempDir.path, 'r7e_e2_mixed_bank.db');
    const typedStorageId = '11111111-2222-4333-8444-555555555555';
    const legacyStorageId = '22222222-3333-4444-8555-666666666666';

    await _dbChunk(tester, () async {
      final first = _FileDatabaseHelper(path);
      final db = await first.database;
      final frozen = const QuestionV2PersistenceMapper().freezeForWrite(
        storageId: typedStorageId,
        bankName: _bankName,
        createdAt: 1700000002,
        draft: QuestionDraftV2(
          questionId: 'r7e-typed-001',
          kind: QuestionKind.singleChoice,
          stem: _text('typed-visible'),
          options: <QuestionOption>[
            QuestionOption(
              optionId: 'opt_a',
              label: 'A',
              content: _text('typed option one'),
            ),
          ],
          answer: ChoiceAnswer(optionIds: <String>['opt_a']),
          // Explicit typed empty explanation: never the legacy placeholder
          // and never the drifted compatibility text.
          explanation: RichContent(nodes: const <ContentNode>[]),
        ),
      );
      await db.insert('questions', frozen.questionRow);
      await db.insert('question_v2_payloads', frozen.payloadRow);
      await _insertReviewState(db, typedStorageId);
      // Drift every visible V1 compatibility field away from the sidecar.
      await db.update(
        'questions',
        <String, Object?>{
          'content': 'compatibility-decoy',
          'explanation': 'decoy-explanation',
          'standard_answer': 'decoy-answer|||decoy-explanation',
        },
        where: 'id = ?',
        whereArgs: <Object?>[typedStorageId],
      );
      await _insertLegacy(db, id: legacyStorageId, content: 'legacy-visible');
      await first.close();
    });

    int? lastCount = -1;
    final helper = _FileDatabaseHelper(path);
    final repository = _CountingRepository(databaseHelper: helper);
    await _pumpListScreen(
      tester,
      repository,
      onLoadFinished: (count) => lastCount = count,
    );

    expect(lastCount, 2);
    expect(repository.persistedReadCalls, 1);
    expect(find.byType(PersistedQuestionCard), findsNWidgets(2));
    expect(find.text('typed-visible'), findsOneWidget,
        reason: 'the sidecar stem is the display authority');
    expect(find.text('compatibility-decoy'), findsNothing,
        reason: 'the drifted V1 compatibility row must never render');
    expect(find.text('decoy-answer'), findsNothing);
    expect(find.text('decoy-explanation'), findsNothing);
    expect(find.text('legacy-visible'), findsOneWidget,
        reason: 'the historical legacy row still renders through the legacy '
            'projection');
    expect(find.text('Legacy explanation.'), findsOneWidget);
    expect(find.text('A'), findsOneWidget,
        reason: 'the typed choice answer comes from the sidecar');
    expect(find.text('无解析'), findsNothing,
        reason: 'an explicit typed empty explanation is not the legacy '
            'placeholder and never falls back to the compat row');
    expect(find.byType(RichContentRenderer), findsWidgets,
        reason: 'typed content renders through the RichContent path');
    expect(find.byType(StructuredContentRenderer), findsWidgets,
        reason: 'legacy content keeps the StructuredContent path');
    expect(tester.takeException(), isNull);
    await _dbChunk(tester, helper.close);
  });

  testWidgets(
      'E3: a partial sidecar on a real committed typed row fails the whole '
      'bank load with the fixed safe UI error', (tester) async {
    _setTallViewport(tester);
    final path = p.join(tempDir.path, 'r7e_e3_corrupt.db');
    late _FakeOcrDocumentClient client;

    // Commit a genuine typed batch through the production chain: parse ->
    // coordinator -> real TaskManager -> flush -> atomic commitTyped.
    await tester.runAsync(() async {
      final helper = _FileDatabaseHelper(path);
      final taskRepo = ImportTaskRepository(databaseHelper: helper);
      final manager = TaskManager.forTesting(
        saveTask: (map) => taskRepo.saveImportTask(map),
        loadTasks: () => taskRepo.getAllImportTasks(),
      );
      await manager.ready;
      final dispatched = await _dispatchTypedOcrTask(
        manager,
        taskId: 'r7e-e3-task',
        document: _e1Document(),
      );
      client = dispatched.client;
      final task = manager.tasks.single;
      expect(task.status, TaskStatus.pendingReview);
      final inputs = <TypedReviewCommitInput>[
        for (final question in task.parsedData!)
          TypedReviewCommitInput(
            reviewItemId: _reviewItemIdFor(question),
            envelope: question[TypedReviewSnapshotCodec.mapKey],
            currentDraft: QuestionDraft.fromMap(question),
          ),
      ];
      final flush = await manager.saveReviewDraft(
        task.id,
        questions: task.parsedData!,
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      );
      expect(flush.saved, isTrue);
      expect(flush.revision, greaterThan(0));
      final repository = _CountingRepository(databaseHelper: helper);
      final service = ImportCommitService(
        questionRepository: repository,
        taskManager: manager,
      );
      final result = await service.commitTyped(
        bankName: _bankName,
        folderName: 'Math',
        items: inputs,
        taskId: task.id,
        attemptToken: task.attemptToken!,
        attemptNumber: task.attemptNumber,
        expectedReviewDraftRevision: flush.revision,
        storageRoute: ImportStorageRoute.typedV2,
        storageReason: ocrTypedCandidateReadyReason,
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      );
      expect(result.questionCount, 2);
      expect(repository.legacyCalls, 0);
      expect(manager.tasks.single.status, TaskStatus.completed);
      await helper.close();
    });

    // Corrupt one sidecar with a structurally partial payload (valid JSON,
    // incomplete draft) and add a historical legacy row to the same bank.
    await _dbChunk(tester, () async {
      final helper = _FileDatabaseHelper(path);
      final db = await helper.database;
      await _insertLegacy(
        db,
        id: '22222222-3333-4444-8555-666666666666',
        content: 'legacy-decoy',
      );
      final payloads = await db.query('question_v2_payloads');
      expect(payloads, hasLength(2));
      await db.update(
        'question_v2_payloads',
        <String, Object?>{
          'payload_json': jsonEncode(<String, Object?>{
            'schemaVersion': 2,
          }),
        },
        where: 'question_id = ?',
        whereArgs: <Object?>[payloads.first['question_id']],
      );
      await helper.close();
    });

    int? lastCount = -1;
    final helper = _FileDatabaseHelper(path);
    final repository = _CountingRepository(databaseHelper: helper);
    await _pumpListScreen(
      tester,
      repository,
      onLoadFinished: (count) => lastCount = count,
    );

    expect(lastCount, isNull);
    expect(find.text('题库中存在无法安全读取的题目，请重试或修复数据'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.byType(PersistedQuestionCard), findsNothing);
    expect(find.text('legacy-decoy'), findsNothing,
        reason: 'no legacy fallback or decoy render after a typed failure');
    expect(find.textContaining('Synthetic'), findsNothing);
    expect(find.textContaining('Exception'), findsNothing);
    expect(repository.persistedReadCalls, 1);
    expect(client.callCount, 1,
        reason: 'one synthetic boundary invocation; Provider calls are 0 '
            'by construction');
    expect(tester.takeException(), isNull);
    await _dbChunk(tester, helper.close);
  });
}

Future<ImportTask> _waitForImportTask(
  TaskManager manager,
  String taskId,
  bool Function(ImportTask task) predicate,
) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    final matches = manager.tasks.where((task) => task.id == taskId);
    if (matches.isNotEmpty && predicate(matches.first)) return matches.first;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw StateError('Task did not reach the expected state.');
}

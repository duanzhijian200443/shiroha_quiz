// R7C permanent acceptance: production typed writer activation.
//
// Evidence class: synthetic fixtures only. The vertical chain runs in
// memory plus real file-backed databases opened only through the frozen
// DatabaseHelper.openPathForTesting seam:
//   synthetic OcrDocument -> R7B candidate -> typedV2 + typed_candidate_ready
//   -> real TaskManager persistence/reload -> staging QuestionDraft
//   -> TypedReviewResultBuilder -> ReviewSession -> ReviewResult
//   -> ImportCommitService.commitTyped -> QuestionRepository
//   -> saveQuestionDraftsV2ToBank -> close/reopen
//   -> getPersistedQuestionsByBank -> TypedPersistedQuestion.
//
// There is no Provider, Replay, network, real application database, private
// PDF, filesystem (outside the frozen seam) or application call site;
// Provider calls are 0 by construction.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/application/import_review/typed_review_snapshot.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/models/ai_engine_profile.dart';
import 'package:shiroha_quiz/data/models/persisted_question.dart';
import 'package:shiroha_quiz/data/models/question_draft.dart';
import 'package:shiroha_quiz/data/repositories/ai_engine_repository.dart';
import 'package:shiroha_quiz/data/repositories/question_repository.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_parse_request.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_parse_result.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_pipeline_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_field_policy.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_task_coordinator.dart';
import 'package:shiroha_quiz/services/import_pipeline/local_question_assembler.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document_client.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_import_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_typed_candidate.dart';
import 'package:shiroha_quiz/services/import_pipeline/single_question_repair_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/text_question_region.dart';
import 'package:shiroha_quiz/services/import_review/import_commit_service.dart';
import 'package:shiroha_quiz/services/import_review/typed_review_result_builder.dart';
import 'package:shiroha_quiz/services/task_manager.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/unsupported_ai_engine_store.dart';

const _sourceName = 'r7c_acceptance_single.pdf';
const _bankName = 'r7c_synthetic_bank';

class _FakeAiEngineRepository extends AiEngineRepository {
  _FakeAiEngineRepository(this.profile)
      : super(store: const UnsupportedAiEngineStore());

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

/// Real repository implementation with call counters. The database handle
/// is owned by the injected helper; every write goes through the production
/// mapper and the frozen v15 schema.
class _CountingRepository extends QuestionRepository {
  _CountingRepository({super.databaseHelper});

  int v2Calls = 0;
  int legacyCalls = 0;

  @override
  Future<void> saveQuestionDraftsV2ToBank({
    required String bankName,
    required String? folderName,
    required List<QuestionDraftV2> questions,
  }) async {
    v2Calls++;
    await super.saveQuestionDraftsV2ToBank(
      bankName: bankName,
      folderName: folderName,
      questions: questions,
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
}

/// File-backed DatabaseHelper seam: the repository APIs run against a real
/// database opened through the frozen openPathForTesting seam. Only the
/// members used by the exercised repository paths are reachable; all other
/// members fail loudly if a test accidentally touches them.
class _FileDatabaseHelper extends Fake implements DatabaseHelper {
  _FileDatabaseHelper(this.path);

  final String path;
  Database? _database;

  @override
  Future<Database> get database async =>
      _database ??= await DatabaseHelper.instance.openPathForTesting(path);

  @override
  Future<void> updateBankFolder(String bankName, String folderName) async {
    final db = await database;
    await db.insert(
      'bank_folders',
      <String, Object?>{
        'bank_name': bankName,
        'folder_name': folderName,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<void> close() async {
    final db = _database;
    _database = null;
    if (db != null) await db.close();
  }
}

AiEngineProfile _ocrProfile() {
  return const AiEngineProfile(
    id: 'r7c-ocr',
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

OcrDocument _inlineAnswerDocument() {
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
          _block('answer_2', 1, 5, '答案：synthetic-result-2'),
          _block('e_2', 1, 6, '解析：Synthetic explanation 2'),
        ],
      ),
    ],
  );
}

/// Runs the synthetic OCR parse and returns the typed task result through
/// the real coordinator and a real TaskManager persistence/reload cycle.
Future<
    ({
      ImportParseResult parseResult,
      ImportTask reloadedTask,
      TaskManager reloadedManager,
    })> _parseAndReloadTask() async {
  final client = _FakeOcrDocumentClient(_inlineAnswerDocument());
  final ocrService = OcrImportService(
    engineRepository: _FakeAiEngineRepository(_ocrProfile()),
    ocrClient: client,
    repairService: const _FakeRepairService(),
    uuidV4Factory: _uuidFactory(),
  );
  final pipeline = ImportPipelineService.forTesting(
    textParser: (rawText, {required taskId, required isMarkdown}) async =>
        fail('text parser must not run'),
    visionParser: (imagePaths) async => fail('vision parser must not run'),
    ocrParser: ocrService.tryParse,
  );
  final parseResult = await pipeline.parseFiles(
    ImportParseRequest(
      filePaths: const <String>['single.pdf'],
      fileNames: const <String>[_sourceName],
      mode: ImportParseMode.ocr,
      maxConcurrency: 1,
      taskId: 'r7c-acceptance-parse',
    ),
  );

  final savedMaps = <Map<String, dynamic>>[];
  final manager = TaskManager.forTesting(
    saveTask: (taskMap) async {
      savedMaps.add(Map<String, dynamic>.from(taskMap));
    },
  );
  final coordinator = ImportTaskCoordinator(
    taskManager: manager,
    readiness: Future<void>.value(),
    parser: pipeline.parseFiles,
    taskIdFactory: () => 'r7c-acceptance-task',
    traceIdFactory: () => 'r7c-acceptance-trace',
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

  final lastSaved = ImportTask.fromMap(savedMaps.last);
  final reloadedManager = TaskManager.forTesting(
    loadTasks: () async => <Map<String, dynamic>>[lastSaved.toMap()],
  );
  await reloadedManager.ready;
  return (
    parseResult: parseResult,
    reloadedTask: reloadedManager.tasks.single,
    reloadedManager: reloadedManager,
  );
}

/// Mirrors the staging screen marker recovery: the persisted `_reviewItemId`
/// marker wins, otherwise the canonical id inside the envelope is used.
String _reviewItemIdFor(Map<String, dynamic> question) {
  final stored = question[TaskManager.keyReviewItemId]?.toString();
  if (stored != null && stored.isNotEmpty) return stored;
  final envelope = question[TypedReviewSnapshotCodec.mapKey];
  return (envelope as Map)['reviewItemId'] as String;
}

List<TypedReviewCommitInput> _stagingTypedInputs(
  List<Map<String, dynamic>> parsedData,
) {
  return <TypedReviewCommitInput>[
    for (final question in parsedData)
      TypedReviewCommitInput(
        reviewItemId: _reviewItemIdFor(question),
        envelope: question[TypedReviewSnapshotCodec.mapKey],
        currentDraft: QuestionDraft.fromMap(question),
      ),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('r7c_acceptance_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test(
      'eligible new OCR activates typedV2 and persists through a real '
      'close/reopen database round trip', () async {
    final parsed = await _parseAndReloadTask();

    expect(parsed.parseResult.storageRoute, ImportStorageRoute.typedV2);
    expect(
      parsed.parseResult.storageReason,
      ocrTypedCandidateReadyReason,
    );
    expect(parsed.parseResult.questions, hasLength(2));
    for (final question in parsed.parseResult.questions) {
      expect(
        question.containsKey(TypedReviewSnapshotCodec.mapKey),
        isTrue,
      );
    }
    expect(
      parsed.reloadedTask.diagnostics?[TaskManager.keyImportStorageRoute],
      'typedV2',
    );
    expect(
      parsed.reloadedTask.diagnostics?[TaskManager.keyImportStorageReason],
      'typed_candidate_ready',
    );
    expect(parsed.reloadedTask.parsedData, hasLength(2));
    for (final question in parsed.reloadedTask.parsedData!) {
      expect(
        question.containsKey(TypedReviewSnapshotCodec.mapKey),
        isTrue,
      );
    }

    final inputs = _stagingTypedInputs(parsed.reloadedTask.parsedData!);
    final taskId = parsed.reloadedTask.id;
    final attemptToken = parsed.reloadedTask.attemptToken!;
    final attemptNumber = parsed.reloadedTask.attemptNumber;

    // Capture the exact ReviewResult final drafts the builder produces.
    final built = TypedReviewResultBuilder().build(
      inputs: inputs,
      taskId: taskId,
      attemptToken: attemptToken,
      attemptNumber: attemptNumber,
    );
    expect(built.acceptedDrafts, hasLength(2));

    final path = p.join(tempDir.path, 'r7c_full_chain.db');
    final firstHelper = _FileDatabaseHelper(path);
    final firstRepo = _CountingRepository(databaseHelper: firstHelper);
    final service = ImportCommitService(
      questionRepository: firstRepo,
      taskManager: parsed.reloadedManager,
    );

    final result = await service.commitTyped(
      bankName: _bankName,
      folderName: 'Math',
      items: inputs,
      taskId: taskId,
      attemptToken: attemptToken,
      attemptNumber: attemptNumber,
      storageRoute: ImportStorageRoute.typedV2,
      storageReason: ocrTypedCandidateReadyReason,
      explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
    );

    expect(result.questionCount, 2);
    expect(firstRepo.v2Calls, 1);
    expect(firstRepo.legacyCalls, 0,
        reason: 'the typed route must never touch the legacy writer');
    expect(
      parsed.reloadedManager.tasks.single.status,
      TaskStatus.completed,
      reason: 'the task completes only after the V2 transaction succeeds',
    );
    await firstHelper.close();

    final secondHelper = _FileDatabaseHelper(path);
    final secondRepo = _CountingRepository(databaseHelper: secondHelper);
    final decoded = await secondRepo.getPersistedQuestionsByBank(_bankName);
    expect(decoded, hasLength(2));
    for (var index = 0; index < decoded.length; index++) {
      expect(decoded[index], isA<TypedPersistedQuestion>());
      final typed = decoded[index] as TypedPersistedQuestion;
      expect(typed.bankName, _bankName);
      expect(typed.draft, built.acceptedDrafts[index],
          reason: 'the persisted V2 draft must equal the ReviewResult '
              'final draft');
    }

    final reopenedDb = await secondHelper.database;
    expect(await reopenedDb.query('questions'), hasLength(2));
    expect(await reopenedDb.query('question_v2_payloads'), hasLength(2));
    expect(await reopenedDb.query('review_states'), hasLength(2));
    final folders = await reopenedDb.query('bank_folders');
    expect(folders.single['folder_name'], 'Math');
    final payloads = await reopenedDb.query('question_v2_payloads');
    for (final row in payloads) {
      expect(row['payload_schema_version'], 2);
    }
    await secondHelper.close();
  });

  test(
      'repository transaction failure leaves zero rows and the task '
      'pendingReview without any legacy fallback', () async {
    final parsed = await _parseAndReloadTask();
    final inputs = _stagingTypedInputs(parsed.reloadedTask.parsedData!);
    final taskId = parsed.reloadedTask.id;
    final attemptToken = parsed.reloadedTask.attemptToken!;
    final attemptNumber = parsed.reloadedTask.attemptNumber;

    final path = p.join(tempDir.path, 'r7c_transaction_failure.db');
    final helper = _FileDatabaseHelper(path);
    final db = await helper.database;
    await db.execute('''
      CREATE TRIGGER r7c_block_second_payload
      BEFORE INSERT ON question_v2_payloads
      WHEN (SELECT COUNT(*) FROM question_v2_payloads) >= 1
      BEGIN SELECT RAISE(ABORT, 'r7c_synthetic_second_payload_failure'); END;
    ''');
    final repo = _CountingRepository(databaseHelper: helper);
    final service = ImportCommitService(
      questionRepository: repo,
      taskManager: parsed.reloadedManager,
    );

    await expectLater(
      service.commitTyped(
        bankName: _bankName,
        folderName: 'Math',
        items: inputs,
        taskId: taskId,
        attemptToken: attemptToken,
        attemptNumber: attemptNumber,
        storageRoute: ImportStorageRoute.typedV2,
        storageReason: ocrTypedCandidateReadyReason,
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      ),
      throwsA(
        isA<TypedReviewCommitException>().having(
          (error) => error.failure,
          'failure',
          TypedReviewCommitFailure.persistenceFailed,
        ),
      ),
    );

    expect(repo.v2Calls, 1);
    expect(repo.legacyCalls, 0,
        reason: 'a failed typed transaction must never fall back to legacy');
    expect(
      parsed.reloadedManager.tasks.single.status,
      TaskStatus.pendingReview,
    );
    await helper.close();

    final reopened = _FileDatabaseHelper(path);
    final reopenedDb = await reopened.database;
    expect(await reopenedDb.query('questions'), isEmpty,
        reason: 'the transaction must roll back every parent row');
    expect(await reopenedDb.query('question_v2_payloads'), isEmpty);
    expect(await reopenedDb.query('review_states'), isEmpty);
    await reopened.close();
  });

  test(
      'typed route with a corrupt envelope blocks before the repository '
      'with a safe fixed error', () async {
    final envelope = <String, Object?>{
      'schemaVersion': 1,
      'route': 'typedV2',
      'reviewItemId': '0d8b7a3e-7f1c-4b2a-9d3e-000000000009',
      'questionId': '0d8b7a3e-7f1c-4b2a-9d3e-000000000010',
      'draft': <String, Object?>{'broken': true},
      'baselineLegacy': <String, Object?>{'broken': true},
      'unexpected': 'extra',
    };
    final question = <String, dynamic>{
      'q_num': '1',
      'question_number': 1,
      'type': 3,
      'content': 'Synthetic stem',
      'options': <String>[],
      'standard_answer': 'Conclusion',
      'explanation': 'Explanation',
      TypedReviewSnapshotCodec.mapKey: envelope,
    };
    final manager = TaskManager.forTesting();
    manager.tasks.add(ImportTask(
      id: 'r7c-corrupt-task',
      title: 'Corrupt synthetic typed task',
      status: TaskStatus.pendingReview,
      parsedData: <Map<String, dynamic>>[question],
      diagnostics: const <String, dynamic>{
        TaskManager.keyImportStorageRoute: 'typedV2',
        TaskManager.keyImportStorageReason: 'typed_candidate_ready',
        TaskManager.keyAttemptToken: 'r7c-corrupt-attempt',
        TaskManager.keyAttemptNumber: 1,
      },
    ));
    final path = p.join(tempDir.path, 'r7c_corrupt_envelope.db');
    final helper = _FileDatabaseHelper(path);
    final repo = _CountingRepository(databaseHelper: helper);
    final service = ImportCommitService(
      questionRepository: repo,
      taskManager: manager,
    );

    await expectLater(
      service.commitTyped(
        bankName: _bankName,
        folderName: 'Math',
        items: _stagingTypedInputs(<Map<String, dynamic>>[question]),
        taskId: 'r7c-corrupt-task',
        attemptToken: 'r7c-corrupt-attempt',
        attemptNumber: 1,
        storageRoute: ImportStorageRoute.typedV2,
        storageReason: ocrTypedCandidateReadyReason,
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      ),
      throwsA(
        isA<TypedReviewCommitException>().having(
          (error) => error.failure,
          'failure',
          TypedReviewCommitFailure.corruptSnapshot,
        ),
      ),
    );

    expect(repo.v2Calls, 0,
        reason: 'corrupt envelopes block before any repository call');
    expect(repo.legacyCalls, 0);
    expect(manager.tasks.single.status, TaskStatus.pendingReview);
    await helper.close();

    final reopened = _FileDatabaseHelper(path);
    final reopenedDb = await reopened.database;
    expect(await reopenedDb.query('questions'), isEmpty);
    expect(await reopenedDb.query('question_v2_payloads'), isEmpty);
    await reopened.close();
  });

  test(
      'historical legacyV1 + shadow_ready keeps the legacy writer and '
      'writes no V2 sidecar', () async {
    final question = <String, dynamic>{
      'q_num': '1',
      'question_number': 1,
      'type': 3,
      'content': 'Historical synthetic stem',
      'options': <String>[],
      'standard_answer': 'Conclusion',
      'explanation': 'Explanation',
    };
    final manager = TaskManager.forTesting();
    manager.tasks.add(ImportTask(
      id: 'r7c-shadow-task',
      title: 'Historical shadow task',
      status: TaskStatus.pendingReview,
      parsedData: <Map<String, dynamic>>[question],
      diagnostics: const <String, dynamic>{
        TaskManager.keyImportStorageRoute: 'legacyV1',
        TaskManager.keyImportStorageReason: 'typed_candidate_shadow_ready',
        TaskManager.keyAttemptToken: 'r7c-shadow-attempt',
        TaskManager.keyAttemptNumber: 1,
      },
    ));
    final path = p.join(tempDir.path, 'r7c_historical_legacy.db');
    final helper = _FileDatabaseHelper(path);
    final repo = _CountingRepository(databaseHelper: helper);
    final service = ImportCommitService(
      questionRepository: repo,
      taskManager: manager,
    );

    final result = await service.commitLegacy(
      bankName: _bankName,
      folderName: 'Math',
      questions: QuestionDraft.listFromMaps(<Map<String, dynamic>>[question]),
      taskId: 'r7c-shadow-task',
      diagnostics: const <String, dynamic>{},
    );

    expect(result.questionCount, 1);
    expect(repo.legacyCalls, 1);
    expect(repo.v2Calls, 0,
        reason: 'historical shadow tasks must never be auto-upgraded');
    expect(manager.tasks.single.status, TaskStatus.completed);
    await helper.close();

    final reopened = _FileDatabaseHelper(path);
    final reopenedDb = await reopened.database;
    expect(await reopenedDb.query('questions'), hasLength(1));
    expect(await reopenedDb.query('question_v2_payloads'), isEmpty);
    expect(await reopenedDb.query('review_states'), hasLength(1));
    await reopened.close();
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

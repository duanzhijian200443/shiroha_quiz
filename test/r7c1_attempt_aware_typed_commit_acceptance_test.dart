// R7C.1 permanent acceptance: attempt-aware typed commit finalization.
//
// Evidence class: synthetic fixtures only. Every database is a real v15 file
// database opened through the frozen DatabaseHelper.openPathForTesting seam;
// TaskManager persistence/reload and ImportCommitService run against the same
// file so the persisted import_tasks gate is authoritative. No Provider,
// Replay, network, real application database, private PDF or application call
// site is touched; Provider calls are 0 by construction.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/application/import_review/typed_review_snapshot.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/models/question_draft.dart';
import 'package:shiroha_quiz/data/models/persisted_question.dart';
import 'package:shiroha_quiz/data/models/typed_import_commit_guard.dart';
import 'package:shiroha_quiz/data/repositories/import_task_repository.dart';
import 'package:shiroha_quiz/data/repositories/question_repository.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_field_policy.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_typed_candidate.dart';
import 'package:shiroha_quiz/services/import_review/import_commit_service.dart';
import 'package:shiroha_quiz/services/import_review/typed_review_result_builder.dart';
import 'package:shiroha_quiz/services/task_manager.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _bankName = 'r7c1_synthetic_bank';
const _taskId = 'r7c1-typed-task';
const _attemptTokenA = 'attempt-A';
const _attemptTokenB = 'attempt-B';

const _reviewItemIdA = '44444444-4444-4444-8444-000000000001';
const _questionIdA = '22222222-2222-4222-8222-000000000001';
const _sourceIdA = '11111111-1111-4111-8111-000000000001';
const _reviewItemIdB = '44444444-4444-4444-8444-000000000002';
const _questionIdB = '22222222-2222-4222-8222-000000000002';
const _sourceIdB = '11111111-1111-4111-8111-000000000002';

Map<String, Object?> _envelope(int number) {
  final isA = number == 1;
  final draft = QuestionDraftV2(
    questionId: isA ? _questionIdA : _questionIdB,
    kind: QuestionKind.shortAnswer,
    questionNumber: number,
    stem: RichContent(
      nodes: <ContentNode>[TextNode('Synthetic stem $number')],
    ),
    answer: ContentAnswer(
      content: RichContent(
        nodes: <ContentNode>[TextNode('Conclusion $number')],
      ),
    ),
    explanation: RichContent(
      nodes: <ContentNode>[TextNode('Synthetic explanation $number')],
    ),
    sourceRefs: <SourceRef>[
      SourceRef.document(
        sourceId: isA ? _sourceIdA : _sourceIdB,
        displayLabel: null,
      ),
    ],
  );
  return const TypedReviewSnapshotCodec().encode(
    TypedReviewSnapshot(
      reviewItemId: isA ? _reviewItemIdA : _reviewItemIdB,
      questionId: isA ? _questionIdA : _questionIdB,
      draft: draft,
      baselineLegacy: LegacyReviewBaseline(
        type: 3,
        questionNumber: number,
        content: 'Synthetic stem $number',
        options: const <String>[],
        standardAnswer: 'Conclusion $number',
        explanation: 'Synthetic explanation $number',
      ),
    ),
  );
}

Map<String, dynamic> _typedQuestion(int number) {
  return <String, dynamic>{
    'q_num': '$number',
    'question_number': number,
    'source_page_indices': <int>[number - 1],
    'source_block_ids': <String>['synthetic-block-$number'],
    'type': 3,
    'content': 'Synthetic stem $number',
    'options': <String>[],
    'standard_answer': 'Conclusion $number',
    'explanation': 'Synthetic explanation $number',
    TaskManager.keyReviewItemId: number == 1 ? _reviewItemIdA : _reviewItemIdB,
    TypedReviewSnapshotCodec.mapKey: _envelope(number),
  };
}

Map<String, dynamic> _typedDiagnostics({
  String token = _attemptTokenA,
  int number = 1,
  int revision = 0,
}) {
  return <String, dynamic>{
    TaskManager.keyAttemptToken: token,
    TaskManager.keyAttemptNumber: number,
    TaskManager.keyAttemptState: 'readyForReview',
    TaskManager.keyImportStorageRoute: 'typedV2',
    TaskManager.keyImportStorageReason: 'typed_candidate_ready',
    if (revision > 0) TaskManager.keyReviewDraftRevision: revision,
  };
}

ImportTask _typedTask({
  String token = _attemptTokenA,
  int number = 1,
  int revision = 0,
  int questionCount = 1,
}) {
  return ImportTask(
    id: _taskId,
    title: 'Synthetic typed import',
    status: TaskStatus.pendingReview,
    parsedData: <Map<String, dynamic>>[
      for (var index = 0; index < questionCount; index++)
        _typedQuestion(index + 1),
    ],
    bankName: _bankName,
    folderName: 'Math',
    diagnostics:
        _typedDiagnostics(token: token, number: number, revision: revision),
  );
}

List<TypedReviewCommitInput> _inputs(ImportTask task) {
  return <TypedReviewCommitInput>[
    for (final question in task.parsedData!)
      TypedReviewCommitInput(
        reviewItemId: question[TaskManager.keyReviewItemId]!.toString(),
        envelope: question[TypedReviewSnapshotCodec.mapKey],
        currentDraft: QuestionDraft.fromMap(question),
      ),
  ];
}

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
  Future<void> close() async {
    final db = _database;
    _database = null;
    if (db != null) await db.close();
  }
}

class _CountingRepository extends QuestionRepository {
  _CountingRepository({super.databaseHelper});

  int atomicCalls = 0;
  int legacyCalls = 0;

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
    String? folderName,
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

class _Harness {
  _Harness({
    required this.path,
    Future<void> Function(Map<String, dynamic> taskMap)? saveTask,
  }) : _saveTask = saveTask {
    helper = _FileDatabaseHelper(path);
    taskRepo = ImportTaskRepository(databaseHelper: helper);
    manager = TaskManager.forTesting(
      saveTask: _saveTask ?? (taskMap) => taskRepo.saveImportTask(taskMap),
      loadTasks: () => taskRepo.getAllImportTasks(),
    );
    repository = _CountingRepository(databaseHelper: helper);
    service = ImportCommitService(
      questionRepository: repository,
      taskManager: manager,
    );
  }

  final String path;
  final Future<void> Function(Map<String, dynamic> taskMap)? _saveTask;
  late final _FileDatabaseHelper helper;
  late final ImportTaskRepository taskRepo;
  late final TaskManager manager;
  late final _CountingRepository repository;
  late final ImportCommitService service;

  Future<void> seed(ImportTask task) async {
    await manager.ready;
    final db = await helper.database;
    await db.insert(
      'import_tasks',
      task.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    manager.tasks.add(ImportTask.fromMap(task.toMap()));
  }

  Future<int> flush(ImportTask task) async {
    final result = await manager.saveReviewDraft(
      task.id,
      questions: task.parsedData!,
      explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
    );
    expect(result.saved, isTrue);
    expect(result.revision, greaterThan(0));
    return result.revision;
  }

  Future<TaskManager> reloadedManager() async {
    final reloaded = TaskManager.forTesting(
      saveTask: (taskMap) => taskRepo.saveImportTask(taskMap),
      loadTasks: () => taskRepo.getAllImportTasks(),
    );
    await reloaded.ready;
    return reloaded;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('r7c1_acceptance_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('34.1 success path commits one atomic batch and survives close/reopen',
      () async {
    final harness = _Harness(path: p.join(tempDir.path, 'success.db'));
    final task = _typedTask();
    await harness.seed(task);
    final revision = await harness.flush(task);

    final result = await harness.service.commitTyped(
      bankName: _bankName,
      folderName: 'Math',
      items: _inputs(task),
      taskId: _taskId,
      attemptToken: _attemptTokenA,
      attemptNumber: 1,
      expectedReviewDraftRevision: revision,
      storageRoute: ImportStorageRoute.typedV2,
      storageReason: ocrTypedCandidateReadyReason,
      explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
    );

    expect(result.questionCount, 1);
    expect(harness.repository.atomicCalls, 1);
    expect(harness.repository.legacyCalls, 0);
    expect(harness.manager.tasks.single.status, TaskStatus.completed);
    await harness.helper.close();

    final reopened = _FileDatabaseHelper(
      p.join(tempDir.path, 'success.db'),
    );
    final db = await reopened.database;
    expect(await db.query('questions'), hasLength(1));
    expect(await db.query('question_v2_payloads'), hasLength(1));
    expect(await db.query('review_states'), hasLength(1));
    expect((await db.query('bank_folders')).single['folder_name'], 'Math');
    final taskRow = (await db.query('import_tasks')).single;
    expect(taskRow['status'], 2);
    expect(taskRow['parsed_data'], isNull);
    expect(taskRow['completed_at'], isNotNull);
    expect(taskRow['progress_text'], '已成功导入题库: $_bankName');
    final diagnostics = (taskRow['diagnostics'] as String).letSafeDecode();
    expect(diagnostics[TaskManager.keyAttemptToken], _attemptTokenA);
    expect(diagnostics[TaskManager.keyAttemptNumber], 1);
    expect(diagnostics[TaskManager.keyImportStorageRoute], 'typedV2');
    expect(
      diagnostics[TaskManager.keyImportStorageReason],
      'typed_candidate_ready',
    );
    expect(
      diagnostics[TaskManager.keyReviewDraftRevision],
      revision,
      reason: 'review draft revision must be preserved in diagnostics',
    );
    final decoded = await _CountingRepository(databaseHelper: reopened)
        .getPersistedQuestionsByBank(_bankName);
    expect(decoded, hasLength(1));
    expect(decoded.single, isA<TypedPersistedQuestion>());

    final taskRepo = ImportTaskRepository(databaseHelper: reopened);
    final reloaded = TaskManager.forTesting(
      saveTask: (map) => taskRepo.saveImportTask(map),
      loadTasks: () => taskRepo.getAllImportTasks(),
    );
    await reloaded.ready;
    expect(reloaded.tasks.single.status, TaskStatus.completed);
    expect(reloaded.tasks.single.parsedData, isNull);
    await reopened.close();
  });

  test(
      '34.2 task completion update failure rolls back every question row '
      'and keeps the task pendingReview', () async {
    final harness = _Harness(path: p.join(tempDir.path, 'completion_fail.db'));
    final task = _typedTask();
    await harness.seed(task);
    final revision = await harness.flush(task);
    final db = await harness.helper.database;
    await db.execute('''
      CREATE TRIGGER r7c1_block_completion
      BEFORE UPDATE ON import_tasks
      WHEN NEW.status = 2
      BEGIN SELECT RAISE(ABORT, 'r7c1_synthetic_completion_failure'); END;
    ''');

    await expectLater(
      harness.service.commitTyped(
        bankName: _bankName,
        folderName: 'Math',
        items: _inputs(task),
        taskId: _taskId,
        attemptToken: _attemptTokenA,
        attemptNumber: 1,
        expectedReviewDraftRevision: revision,
        storageRoute: ImportStorageRoute.typedV2,
        storageReason: ocrTypedCandidateReadyReason,
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      ),
      throwsA(
        isA<TypedReviewCommitAttemptException>().having(
          (error) => error.failure,
          'failure',
          TypedReviewCommitAttemptFailure.persistenceFailed,
        ),
      ),
    );

    expect(await db.query('questions'), isEmpty);
    expect(await db.query('question_v2_payloads'), isEmpty);
    expect(await db.query('review_states'), isEmpty);
    final taskRow = (await db.query('import_tasks')).single;
    expect(taskRow['status'], 1);
    expect(taskRow['parsed_data'], isNotNull);
    expect(harness.repository.legacyCalls, 0);
    expect(harness.manager.tasks.single.status, TaskStatus.pendingReview);

    final reloaded = await harness.reloadedManager();
    expect(reloaded.tasks.single.status, TaskStatus.pendingReview);
    await harness.helper.close();
  });

  test(
      '34.3 question transaction failure rolls back and a retry succeeds '
      'after the blocker is removed', () async {
    final harness = _Harness(path: p.join(tempDir.path, 'retry.db'));
    final task = _typedTask(questionCount: 2);
    await harness.seed(task);
    final revision = await harness.flush(task);
    final db = await harness.helper.database;
    await db.execute('''
      CREATE TRIGGER r7c1_block_second_payload
      BEFORE INSERT ON question_v2_payloads
      WHEN (SELECT COUNT(*) FROM question_v2_payloads) >= 1
      BEGIN SELECT RAISE(ABORT, 'r7c1_synthetic_second_payload_failure'); END;
    ''');

    await expectLater(
      harness.service.commitTyped(
        bankName: _bankName,
        folderName: 'Math',
        items: _inputs(task),
        taskId: _taskId,
        attemptToken: _attemptTokenA,
        attemptNumber: 1,
        expectedReviewDraftRevision: revision,
        storageRoute: ImportStorageRoute.typedV2,
        storageReason: ocrTypedCandidateReadyReason,
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      ),
      throwsA(isA<TypedReviewCommitAttemptException>()),
    );
    expect(await db.query('questions'), isEmpty);
    expect((await db.query('import_tasks')).single['status'], 1);

    await db.execute('DROP TRIGGER r7c1_block_second_payload');
    final retry = await harness.service.commitTyped(
      bankName: _bankName,
      folderName: 'Math',
      items: _inputs(task),
      taskId: _taskId,
      attemptToken: _attemptTokenA,
      attemptNumber: 1,
      expectedReviewDraftRevision: revision,
      storageRoute: ImportStorageRoute.typedV2,
      storageReason: ocrTypedCandidateReadyReason,
      explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
    );

    expect(retry.questionCount, 2);
    expect(await db.query('questions'), hasLength(2));
    expect((await db.query('import_tasks')).single['status'], 2);
    await harness.helper.close();
  });

  test('34.4 stale attempt writes zero rows with no legacy fallback', () async {
    final harness = _Harness(path: p.join(tempDir.path, 'stale_attempt.db'));
    final task = _typedTask(token: _attemptTokenB);
    await harness.seed(task);
    final revision = await harness.flush(task);

    await expectLater(
      harness.service.commitTyped(
        bankName: _bankName,
        folderName: 'Math',
        items: _inputs(task),
        taskId: _taskId,
        attemptToken: _attemptTokenA,
        attemptNumber: 1,
        expectedReviewDraftRevision: revision,
        storageRoute: ImportStorageRoute.typedV2,
        storageReason: ocrTypedCandidateReadyReason,
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      ),
      throwsA(
        isA<TypedReviewCommitAttemptException>().having(
          (error) => error.failure,
          'failure',
          TypedReviewCommitAttemptFailure.staleAttempt,
        ),
      ),
    );
    final db = await harness.helper.database;
    expect(await db.query('questions'), isEmpty);
    expect(await db.query('question_v2_payloads'), isEmpty);
    expect(await db.query('review_states'), isEmpty);
    expect(harness.repository.atomicCalls, 0);
    expect(harness.repository.legacyCalls, 0);
    await harness.helper.close();

    // Same coverage for a stale attempt number on a fresh database.
    final numberHarness = _Harness(
      path: p.join(tempDir.path, 'stale_number.db'),
    );
    final numberTask = _typedTask(number: 2);
    await numberHarness.seed(numberTask);
    final numberRevision = await numberHarness.flush(numberTask);
    await expectLater(
      numberHarness.service.commitTyped(
        bankName: _bankName,
        folderName: 'Math',
        items: _inputs(numberTask),
        taskId: _taskId,
        attemptToken: _attemptTokenA,
        attemptNumber: 1,
        expectedReviewDraftRevision: numberRevision,
        storageRoute: ImportStorageRoute.typedV2,
        storageReason: ocrTypedCandidateReadyReason,
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      ),
      throwsA(
        isA<TypedReviewCommitAttemptException>().having(
          (error) => error.failure,
          'failure',
          TypedReviewCommitAttemptFailure.staleAttempt,
        ),
      ),
    );
    expect(
        await numberHarness.helper.database.then((db) => db.query('questions')),
        isEmpty);
    await numberHarness.helper.close();
  });

  test('34.5 stale review revision writes zero rows and preserves the draft',
      () async {
    final harness = _Harness(path: p.join(tempDir.path, 'stale_revision.db'));
    final task = _typedTask(revision: 2);
    await harness.seed(task);
    final db = await harness.helper.database;

    await expectLater(
      harness.service.commitTyped(
        bankName: _bankName,
        folderName: 'Math',
        items: _inputs(task),
        taskId: _taskId,
        attemptToken: _attemptTokenA,
        attemptNumber: 1,
        expectedReviewDraftRevision: 1,
        storageRoute: ImportStorageRoute.typedV2,
        storageReason: ocrTypedCandidateReadyReason,
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      ),
      throwsA(
        isA<TypedReviewCommitAttemptException>().having(
          (error) => error.failure,
          'failure',
          TypedReviewCommitAttemptFailure.staleReviewDraft,
        ),
      ),
    );

    expect(await db.query('questions'), isEmpty);
    expect(await db.query('question_v2_payloads'), isEmpty);
    expect(await db.query('review_states'), isEmpty);
    final taskRow = (await db.query('import_tasks')).single;
    expect(taskRow['status'], 1);
    expect(taskRow['parsed_data'], isNotNull,
        reason: 'the updated review draft must not be overwritten');
    final diagnostics = (taskRow['diagnostics'] as String).letSafeDecode();
    expect(diagnostics[TaskManager.keyReviewDraftRevision], 2);
    expect(harness.repository.legacyCalls, 0);
    await harness.helper.close();
  });

  test('34.6 duplicate concurrent commits write exactly one batch', () async {
    final harness = _Harness(path: p.join(tempDir.path, 'duplicate.db'));
    final task = _typedTask(questionCount: 2);
    await harness.seed(task);
    final revision = await harness.flush(task);

    Future<ImportCommitResult> commit() {
      return harness.service.commitTyped(
        bankName: _bankName,
        folderName: 'Math',
        items: _inputs(task),
        taskId: _taskId,
        attemptToken: _attemptTokenA,
        attemptNumber: 1,
        expectedReviewDraftRevision: revision,
        storageRoute: ImportStorageRoute.typedV2,
        storageReason: ocrTypedCandidateReadyReason,
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      );
    }

    final firstFuture = commit();
    final secondFuture = commit();
    final secondExpectation = expectLater(
      secondFuture,
      throwsA(
        isA<TypedReviewCommitAttemptException>().having(
          (error) => error.failure,
          'failure',
          TypedReviewCommitAttemptFailure.commitInProgress,
        ),
      ),
    );
    final first = await firstFuture;
    expect(first.questionCount, 2);
    await secondExpectation;

    final db = await harness.helper.database;
    expect(await db.query('questions'), hasLength(2),
        reason: 'exactly one batch of questions must be written');
    expect(await db.query('question_v2_payloads'), hasLength(2));
    expect(await db.query('review_states'), hasLength(2));
    final ids = await db.query('questions', columns: <String>['id']);
    expect(ids.map((row) => row['id']).toSet(), hasLength(2),
        reason: 'no duplicate storage ids');
    expect((await db.query('import_tasks')).single['status'], 2);
    await harness.helper.close();
  });

  test(
      '34.7 a delayed review draft save is awaited and cannot resurrect '
      'the completed task', () async {
    final path = p.join(tempDir.path, 'race.db');
    final gate = Completer<void>();
    var gateArmed = false;
    final helper = _FileDatabaseHelper(path);
    final taskRepo = ImportTaskRepository(databaseHelper: helper);
    final manager = TaskManager.forTesting(
      saveTask: (taskMap) async {
        if (gateArmed) await gate.future;
        await taskRepo.saveImportTask(taskMap);
      },
      loadTasks: () => taskRepo.getAllImportTasks(),
    );
    await manager.ready;
    final repository = _CountingRepository(databaseHelper: helper);
    final service = ImportCommitService(
      questionRepository: repository,
      taskManager: manager,
    );
    final task = _typedTask();
    final db = await helper.database;
    await db.insert(
      'import_tasks',
      task.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    manager.tasks.add(ImportTask.fromMap(task.toMap()));

    // The final review draft save is in flight when the typed commit is
    // requested; the commit must wait for it and use the latest revision.
    gateArmed = true;
    final saveFuture = manager.saveReviewDraft(
      _taskId,
      questions: task.parsedData!,
      explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
    );
    final commitFuture = service.commitTyped(
      bankName: _bankName,
      folderName: 'Math',
      items: _inputs(task),
      taskId: _taskId,
      attemptToken: _attemptTokenA,
      attemptNumber: 1,
      expectedReviewDraftRevision: 1,
      storageRoute: ImportStorageRoute.typedV2,
      storageReason: ocrTypedCandidateReadyReason,
      explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
    );

    await Future<void>.delayed(const Duration(milliseconds: 100));
    gate.complete();
    final saveResult = await saveFuture;
    expect(saveResult.status, ReviewDraftSaveStatus.saved);
    expect(saveResult.revision, 1);
    final commitResult = await commitFuture;
    expect(commitResult.questionCount, 1,
        reason: 'the commit must succeed only after the queued save drained');
    expect(manager.tasks.single.status, TaskStatus.completed);
    await helper.close();

    final reopened = _FileDatabaseHelper(path);
    final reopenedRepo = ImportTaskRepository(databaseHelper: reopened);
    final reloaded = TaskManager.forTesting(
      saveTask: (map) => reopenedRepo.saveImportTask(map),
      loadTasks: () => reopenedRepo.getAllImportTasks(),
    );
    await reloaded.ready;
    expect(reloaded.tasks.single.status, TaskStatus.completed);
    expect(reloaded.tasks.single.parsedData, isNull,
        reason: 'the old snapshot must never resurrect the completed task');
    await reopened.close();
  });
}

extension on String {
  Map<String, dynamic> letSafeDecode() {
    final decoded = const JsonDecoder().convert(this);
    return Map<String, dynamic>.from(decoded as Map);
  }
}

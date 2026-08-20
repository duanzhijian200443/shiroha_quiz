import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/import_review/typed_review_snapshot.dart';
import 'package:shiroha_quiz/data/models/question_draft.dart';
import 'package:shiroha_quiz/data/models/typed_import_commit_guard.dart';
import 'package:shiroha_quiz/data/repositories/question_repository.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_field_policy.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_typed_candidate.dart';
import 'package:shiroha_quiz/services/import_review/typed_review_result_builder.dart';
import 'package:shiroha_quiz/services/import_review/import_commit_service.dart';
import 'package:shiroha_quiz/services/task_manager.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _CommitRepository extends Fake implements QuestionRepository {
  var saveCalls = 0;
  var v2SaveCalls = 0;
  Object? failure;
  List<QuestionDraft>? savedQuestions;
  List<QuestionDraftV2>? savedV2Questions;

  @override
  Future<void> saveQuestionDraftsToBank({
    required String bankName,
    String? folderName,
    required List<QuestionDraft> questions,
  }) async {
    saveCalls++;
    savedQuestions = List<QuestionDraft>.unmodifiable(questions);
    if (failure != null) throw failure!;
  }

  @override
  Future<void> saveQuestionDraftsV2ToBank({
    required String bankName,
    String? folderName,
    required List<QuestionDraftV2> questions,
  }) async {
    v2SaveCalls++;
    savedV2Questions = List<QuestionDraftV2>.unmodifiable(questions);
    if (failure != null) throw failure!;
  }

  @override
  Future<TypedImportCommitPersistenceResult> commitQuestionDraftsV2ForImport({
    required String bankName,
    String? folderName,
    required List<QuestionDraftV2> questions,
    required TypedImportCommitGuard guard,
    required String completionText,
  }) async {
    v2SaveCalls++;
    savedV2Questions = List<QuestionDraftV2>.unmodifiable(questions);
    if (failure != null) throw failure!;
    return TypedImportCommitPersistenceResult(
      questionCount: questions.length,
      completedAt: 1700000000,
    );
  }

  @override
  Future<LegacyImportCommitPersistenceResult>
      commitQuestionDraftsLegacyForImport({
    required String bankName,
    String? folderName,
    required List<QuestionDraft> questions,
    required LegacyImportCommitGuard guard,
    required String completionText,
  }) async {
    saveCalls++;
    savedQuestions = List<QuestionDraft>.unmodifiable(questions);
    if (failure != null) throw failure!;
    return LegacyImportCommitPersistenceResult(
      questionCount: questions.length,
      completedAt: 1700000000,
    );
  }
}

const _typedQuestionId = '66666666-6666-4666-8666-666666666666';
const _typedReviewItemId = '77777777-7777-4777-8777-777777777777';
const _typedSourceId = '88888888-8888-4888-8888-888888888888';
const _typedTaskId = 'typed-commit-task';
const _typedAttemptToken = 'typed-commit-attempt';
const _typedQuestionIdB = '99999999-9999-4999-8999-999999999999';
const _typedReviewItemIdB = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _typedSourceIdB = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

QuestionDraftV2 _typedDraft() {
  return QuestionDraftV2(
    questionId: _typedQuestionId,
    kind: QuestionKind.shortAnswer,
    questionNumber: 1,
    stem: RichContent(nodes: <ContentNode>[TextNode('Synthetic stem')]),
    answer: ContentAnswer(
      content: RichContent(nodes: <ContentNode>[TextNode('Conclusion')]),
    ),
    explanation: RichContent(
      nodes: <ContentNode>[TextNode('Subjective explanation')],
    ),
    sourceRefs: <SourceRef>[
      SourceRef.document(sourceId: _typedSourceId, displayLabel: null),
    ],
  );
}

Map<String, Object?> _typedEnvelope() {
  return const TypedReviewSnapshotCodec().encode(
    TypedReviewSnapshot(
      reviewItemId: _typedReviewItemId,
      questionId: _typedQuestionId,
      draft: _typedDraft(),
      baselineLegacy: LegacyReviewBaseline(
        type: 3,
        questionNumber: 1,
        content: 'Synthetic stem',
        options: const <String>[],
        standardAnswer: 'Conclusion',
        explanation: 'Subjective explanation',
      ),
    ),
  );
}

TypedReviewCommitInput _typedInput() {
  return TypedReviewCommitInput(
    reviewItemId: _typedReviewItemId,
    envelope: _typedEnvelope(),
    currentDraft: const QuestionDraft(
      type: QuestionType.shortAnswer,
      content: 'Synthetic stem',
      options: <String>[],
      standardAnswer: 'Conclusion',
      explanation: 'Subjective explanation',
    ),
  );
}

TypedReviewCommitInput _typedInputB() {
  final draft = QuestionDraftV2(
    questionId: _typedQuestionIdB,
    kind: QuestionKind.shortAnswer,
    questionNumber: 2,
    stem: RichContent(nodes: <ContentNode>[TextNode('Synthetic stem B')]),
    answer: ContentAnswer(
      content: RichContent(nodes: <ContentNode>[TextNode('Conclusion B')]),
    ),
    explanation: RichContent(
      nodes: <ContentNode>[TextNode('Subjective explanation B')],
    ),
    sourceRefs: <SourceRef>[
      SourceRef.document(sourceId: _typedSourceIdB, displayLabel: null),
    ],
  );
  return TypedReviewCommitInput(
    reviewItemId: _typedReviewItemIdB,
    envelope: const TypedReviewSnapshotCodec().encode(
      TypedReviewSnapshot(
        reviewItemId: _typedReviewItemIdB,
        questionId: _typedQuestionIdB,
        draft: draft,
        baselineLegacy: LegacyReviewBaseline(
          type: 3,
          questionNumber: 2,
          content: 'Synthetic stem B',
          options: const <String>[],
          standardAnswer: 'Conclusion B',
          explanation: 'Subjective explanation B',
        ),
      ),
    ),
    currentDraft: const QuestionDraft(
      type: QuestionType.shortAnswer,
      content: 'Synthetic stem B',
      options: <String>[],
      standardAnswer: 'Conclusion B',
      explanation: 'Subjective explanation B',
    ),
  );
}

const _draft = QuestionDraft(
  type: QuestionType.singleChoice,
  content: 'Synthetic question',
  options: ['A', 'B'],
  standardAnswer: 'A',
  explanation: '',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final manager = TaskManager.forTesting();

  setUp(() async {
    await manager.ready;
    manager.tasks.clear();
  });

  tearDown(() {
    manager.tasks.clear();
  });

  test('historical blocked gate does not override legal current questions',
      () async {
    final repository = _CommitRepository();
    final service = ImportCommitService(
      questionRepository: repository,
      taskManager: manager,
    );

    final result = await service.commit(
      bankName: 'Smoke Bank',
      folderName: 'Smoke',
      questions: const [_draft],
      diagnostics: const {
        'qualityGate': {'blocked': true, 'reason': 'synthetic gate'},
      },
    );

    expect(result.questionCount, 1);
    expect(repository.saveCalls, 1);
  });

  test('historical blocked gate still blocks illegal current questions',
      () async {
    final repository = _CommitRepository();
    final service = ImportCommitService(
      questionRepository: repository,
      taskManager: manager,
    );

    await expectLater(
      service.commit(
        bankName: 'Smoke Bank',
        folderName: 'Smoke',
        questions: const [
          QuestionDraft(
            type: QuestionType.singleChoice,
            content: 'Broken choice question',
            options: [],
            standardAnswer: '',
            explanation: '',
          ),
        ],
        diagnostics: const {
          'qualityGate': {'blocked': true, 'reason': 'synthetic gate'},
        },
      ),
      throwsA(isA<ImportCommitBlockedException>()),
    );

    expect(repository.saveCalls, 0);
  });

  test('historical clear gate cannot allow illegal current questions',
      () async {
    final repository = _CommitRepository();
    final service = ImportCommitService(
      questionRepository: repository,
      taskManager: manager,
    );

    await expectLater(
      service.commit(
        bankName: 'Smoke Bank',
        folderName: 'Smoke',
        questions: const [
          QuestionDraft(
            type: QuestionType.singleChoice,
            content: 'Broken choice question',
            options: ['', '   '],
            standardAnswer: 'A',
            explanation: '',
          ),
        ],
        diagnostics: const {
          'qualityGate': {'blocked': false},
        },
      ),
      throwsA(isA<ImportCommitBlockedException>()),
    );

    expect(repository.saveCalls, 0);
  });

  test('all current hard structural errors remain blocked', () async {
    for (final draft in const [
      QuestionDraft(
        type: QuestionType.shortAnswer,
        content: '',
        options: [],
        standardAnswer: 'Answer',
        explanation: '',
      ),
      QuestionDraft(
        type: QuestionType.singleChoice,
        content: 'Choice answer outside options',
        options: ['A', 'B'],
        standardAnswer: 'C',
        explanation: '',
      ),
      QuestionDraft(
        type: QuestionType.shortAnswer,
        content: 'Subjective question with choice options',
        options: ['A', 'B'],
        standardAnswer: 'Answer',
        explanation: '',
      ),
    ]) {
      final repository = _CommitRepository();
      final service = ImportCommitService(
        questionRepository: repository,
        taskManager: manager,
      );

      await expectLater(
        service.commit(
          bankName: 'Smoke Bank',
          folderName: 'Smoke',
          questions: [draft],
          diagnostics: const {},
        ),
        throwsA(isA<ImportCommitBlockedException>()),
      );
      expect(repository.saveCalls, 0);
    }
  });

  test('unparseable meaningful answer remains reviewable and committable',
      () async {
    final repository = _CommitRepository();
    final service = ImportCommitService(
      questionRepository: repository,
      taskManager: manager,
    );

    await service.commit(
      bankName: 'Smoke Bank',
      folderName: 'Smoke',
      questions: const [
        QuestionDraft(
          type: QuestionType.singleChoice,
          content: 'Choice question',
          options: ['A', 'B', 'C', 'D'],
          standardAnswer: 'The answer is described in the source',
          explanation: '',
        ),
      ],
      diagnostics: const {},
    );

    expect(repository.saveCalls, 1);
  });

  test('missing answer alone remains reviewable and committable', () async {
    final repository = _CommitRepository();
    final service = ImportCommitService(
      questionRepository: repository,
      taskManager: manager,
    );

    await service.commit(
      bankName: 'Smoke Bank',
      folderName: 'Smoke',
      questions: const [
        QuestionDraft(
          type: QuestionType.shortAnswer,
          content: 'Question without supplied answer',
          options: [],
          standardAnswer: '',
          explanation: '',
        ),
      ],
      diagnostics: const {},
    );

    expect(repository.saveCalls, 1);
  });

  test('commit applies default policy and strips raw provenance before save',
      () async {
    final repository = _CommitRepository();
    final service = ImportCommitService(
      questionRepository: repository,
      taskManager: manager,
    );

    await service.commit(
      bankName: 'Smoke Bank',
      folderName: 'Smoke',
      questions: const [
        QuestionDraft(
          type: QuestionType.singleChoice,
          content: 'Choice question',
          options: ['A', 'B'],
          standardAnswer: 'A',
          explanation: 'Choice explanation must not be persisted',
          rawExplanation: 'Raw choice explanation',
        ),
        QuestionDraft(
          type: QuestionType.fillBlank,
          content: 'Fill question',
          options: [],
          standardAnswer: '42',
          explanation: 'Fill explanation must not be persisted',
          rawExplanation: 'Raw fill explanation',
        ),
        QuestionDraft(
          type: QuestionType.shortAnswer,
          content: 'Subjective question',
          options: [],
          standardAnswer: 'Conclusion',
          explanation: 'Subjective explanation is persisted',
          rawExplanation: 'Raw subjective explanation',
        ),
      ],
      diagnostics: const {},
    );

    final saved = repository.savedQuestions!;
    expect(saved, hasLength(3));
    expect(saved[0].explanation, isEmpty);
    expect(saved[0].rawExplanation, isNull);
    expect(saved[1].explanation, isEmpty);
    expect(saved[1].rawExplanation, isNull);
    expect(saved[2].explanation, 'Subjective explanation is persisted');
    expect(saved[2].rawExplanation, isNull);
  });

  test('commit honors document mode and per-question override', () async {
    final repository = _CommitRepository();
    final service = ImportCommitService(
      questionRepository: repository,
      taskManager: manager,
    );

    await service.commit(
      bankName: 'Smoke Bank',
      folderName: 'Smoke',
      questions: const [
        QuestionDraft(
          type: QuestionType.singleChoice,
          content: 'Choice question',
          options: ['A', 'B'],
          standardAnswer: 'A',
          explanation: '',
          rawExplanation: 'Keep by document mode',
        ),
        QuestionDraft(
          type: QuestionType.fillBlank,
          content: 'Fill question',
          options: [],
          standardAnswer: '42',
          explanation: 'Existing final explanation',
          rawExplanation: 'Discard by override',
        ),
      ],
      diagnostics: const {},
      explanationRetentionMode: ExplanationRetentionMode.allQuestionTypes,
      explanationOverrides: const [
        QuestionExplanationOverride.inherit,
        QuestionExplanationOverride.discard,
      ],
    );

    final saved = repository.savedQuestions!;
    expect(saved[0].explanation, 'Keep by document mode');
    expect(saved[0].rawExplanation, isNull);
    expect(saved[1].explanation, isEmpty);
    expect(saved[1].rawExplanation, isNull);
  });

  test('commit saves the latest answer restored from review snapshot',
      () async {
    manager.addTask(
      ImportTask(
        id: 'snapshot-commit',
        title: 'Synthetic snapshot commit',
        status: TaskStatus.pendingReview,
        parsedData: const [
          {
            'type': 3,
            'content': 'Subjective question',
            'options': <String>[],
            'standard_answer': '',
            'explanation': 'Existing explanation',
          },
        ],
      ),
    );
    await manager.saveReviewDraft(
      'snapshot-commit',
      questions: const [
        {
          'type': 3,
          'content': 'Subjective question',
          'options': <String>[],
          'standard_answer': 'Restored answer',
          'explanation': 'Existing explanation',
        },
      ],
      explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
    );
    final repository = _CommitRepository();
    final service = ImportCommitService(
      questionRepository: repository,
      taskManager: manager,
    );

    await service.commit(
      bankName: 'Smoke Bank',
      folderName: 'Smoke',
      questions: QuestionDraft.listFromMaps(
        manager.tasks.single.parsedData!,
      ),
      taskId: 'snapshot-commit',
      diagnostics: const {},
    );

    expect(repository.savedQuestions!.single.standardAnswer, 'Restored answer');
  });

  test('commit finalizes retained raw explanation before repository write',
      () async {
    final repository = _CommitRepository();
    final service = ImportCommitService(
      questionRepository: repository,
      taskManager: manager,
    );

    await service.commit(
      bankName: 'Smoke Bank',
      folderName: 'Smoke',
      questions: const [
        QuestionDraft(
          type: QuestionType.singleChoice,
          content: 'Choice question',
          options: ['A', 'B'],
          standardAnswer: 'A',
          explanation: '',
          rawExplanation:
              r'<div>Broken \(x + 1</div><script>privateBody</script>',
        ),
      ],
      diagnostics: const {},
      explanationRetentionMode: ExplanationRetentionMode.allQuestionTypes,
    );

    final saved = repository.savedQuestions!.single;
    expect(saved.explanation, r'Broken \(x + 1\)');
    expect(saved.explanation, isNot(contains('<div>')));
    expect(saved.explanation, isNot(contains('privateBody')));
    expect(saved.rawExplanation, isNull);
  });

  test('successful commit saves through repository and completes task',
      () async {
    final repository = _CommitRepository();
    manager.addTask(ImportTask(
      id: 'task-commit',
      title: 'Synthetic import',
      status: TaskStatus.pendingReview,
      parsedData: <Map<String, dynamic>>[_draft.toMap()],
      diagnostics: const {TaskManager.keyTraceId: 'trace-commit'},
    ));
    final service = ImportCommitService(
      questionRepository: repository,
      taskManager: manager,
    );

    final result = await service.commit(
      bankName: 'Smoke Bank',
      folderName: 'Smoke',
      questions: const [_draft],
      taskId: 'task-commit',
      diagnostics: const {},
    );

    expect(result.questionCount, 1);
    expect(repository.saveCalls, 1);
    expect(manager.tasks.single.status, TaskStatus.completed);
    expect(manager.tasks.single.traceId, 'trace-commit');
  });

  test('repository failure does not mark task completed', () async {
    final repository = _CommitRepository()..failure = StateError('synthetic');
    manager.addTask(ImportTask(
      id: 'task-failed-commit',
      title: 'Synthetic import',
      status: TaskStatus.pendingReview,
      parsedData: <Map<String, dynamic>>[_draft.toMap()],
    ));
    final service = ImportCommitService(
      questionRepository: repository,
      taskManager: manager,
    );

    await expectLater(
      service.commit(
        bankName: 'Smoke Bank',
        folderName: 'Smoke',
        questions: const [_draft],
        taskId: 'task-failed-commit',
        diagnostics: const {},
      ),
      throwsA(
        isA<LegacyReviewCommitAttemptException>().having(
          (error) => error.failure,
          'failure',
          LegacyReviewCommitAttemptFailure.persistenceFailed,
        ),
      ),
    );

    expect(manager.tasks.single.status, TaskStatus.pendingReview);
  });

  group('typed commit', () {
    ImportCommitService typedService(
      _CommitRepository repository, {
      bool withTask = true,
    }) {
      if (withTask) {
        manager.addTask(ImportTask(
          id: _typedTaskId,
          title: 'Synthetic typed import',
          status: TaskStatus.pendingReview,
          parsedData: <Map<String, dynamic>>[
            <String, dynamic>{
              'q_num': 1,
              'type': 3,
              'content': 'Synthetic stem',
              'standard_answer': 'Conclusion',
            },
          ],
          diagnostics: const <String, dynamic>{
            TaskManager.keyAttemptToken: _typedAttemptToken,
            TaskManager.keyAttemptNumber: 1,
            TaskManager.keyAttemptState: 'readyForReview',
            TaskManager.keyImportStorageRoute: 'typedV2',
            TaskManager.keyImportStorageReason: 'typed_candidate_ready',
            TaskManager.keyReviewDraftRevision: 1,
          },
        ));
      }
      return ImportCommitService(
        questionRepository: repository,
        taskManager: manager,
      );
    }

    test('commitLegacy keeps the legacy writer behavior unchanged', () async {
      final repository = _CommitRepository();
      final service = ImportCommitService(
        questionRepository: repository,
        taskManager: manager,
      );

      final result = await service.commitLegacy(
        bankName: 'Smoke Bank',
        folderName: 'Smoke',
        questions: const [_draft],
        taskId: null,
        diagnostics: const {},
      );

      expect(result.questionCount, 1);
      expect(repository.saveCalls, 1);
      expect(repository.v2SaveCalls, 0);
    });

    test('compatibility commit() still routes to the legacy writer', () async {
      final repository = _CommitRepository();
      final service = ImportCommitService(
        questionRepository: repository,
        taskManager: manager,
      );

      final result = await service.commit(
        bankName: 'Smoke Bank',
        folderName: 'Smoke',
        questions: const [_draft],
        diagnostics: const {},
      );

      expect(result.questionCount, 1);
      expect(repository.saveCalls, 1);
      expect(repository.v2SaveCalls, 0);
    });

    test('typed commit calls only the V2 writer', () async {
      final repository = _CommitRepository();
      final service = typedService(repository);

      final result = await service.commitTyped(
        bankName: 'Typed Bank',
        folderName: 'Math',
        items: <TypedReviewCommitInput>[_typedInput()],
        taskId: _typedTaskId,
        attemptToken: _typedAttemptToken,
        attemptNumber: 1,
        expectedReviewDraftRevision: 1,
        storageRoute: ImportStorageRoute.typedV2,
        storageReason: ocrTypedCandidateReadyReason,
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      );

      expect(result.questionCount, 1);
      expect(repository.v2SaveCalls, 1);
      expect(repository.saveCalls, 0,
          reason: 'a typed task must never touch the legacy writer');
      expect(repository.savedV2Questions!.single, _typedDraft());
    });

    test('typed success question count equals accepted drafts', () async {
      final repository = _CommitRepository();
      final service = typedService(repository);

      final result = await service.commitTyped(
        bankName: 'Typed Bank',
        folderName: 'Math',
        items: <TypedReviewCommitInput>[_typedInput(), _typedInputB()],
        taskId: _typedTaskId,
        attemptToken: _typedAttemptToken,
        attemptNumber: 1,
        expectedReviewDraftRevision: 1,
        storageRoute: ImportStorageRoute.typedV2,
        storageReason: ocrTypedCandidateReadyReason,
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      );

      expect(result.questionCount, 2);
      expect(repository.savedV2Questions, hasLength(2));
      expect(manager.tasks.single.status, TaskStatus.completed);
    });

    test('V2 writer success completes the task', () async {
      final repository = _CommitRepository();
      final service = typedService(repository);

      await service.commitTyped(
        bankName: 'Typed Bank',
        folderName: 'Math',
        items: <TypedReviewCommitInput>[_typedInput()],
        taskId: _typedTaskId,
        attemptToken: _typedAttemptToken,
        attemptNumber: 1,
        expectedReviewDraftRevision: 1,
        storageRoute: ImportStorageRoute.typedV2,
        storageReason: ocrTypedCandidateReadyReason,
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      );

      expect(manager.tasks.single.status, TaskStatus.completed);
    });

    test('V2 writer failure keeps the task pending and never falls back',
        () async {
      final repository = _CommitRepository()
        ..failure = StateError('synthetic-db-error');
      final service = typedService(repository);

      await expectLater(
        service.commitTyped(
          bankName: 'Typed Bank',
          folderName: 'Math',
          items: <TypedReviewCommitInput>[_typedInput()],
          taskId: _typedTaskId,
          attemptToken: _typedAttemptToken,
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
            TypedReviewCommitAttemptFailure.persistenceFailed,
          ),
        ),
      );

      expect(manager.tasks.single.status, TaskStatus.pendingReview);
      expect(repository.saveCalls, 0,
          reason: 'repository failure must never trigger the legacy writer');
    });

    test('repository errors map to the fixed safe exception', () async {
      final repository = _CommitRepository()
        ..failure = StateError('synthetic-db-error');
      final service = typedService(repository);

      try {
        await service.commitTyped(
          bankName: 'Typed Bank',
          folderName: 'Math',
          items: <TypedReviewCommitInput>[_typedInput()],
          taskId: _typedTaskId,
          attemptToken: _typedAttemptToken,
          attemptNumber: 1,
          expectedReviewDraftRevision: 1,
          storageRoute: ImportStorageRoute.typedV2,
          storageReason: ocrTypedCandidateReadyReason,
          explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
        );
        fail('expected a persistence failure');
      } on TypedReviewCommitAttemptException catch (error) {
        expect(
          error.failure,
          TypedReviewCommitAttemptFailure.persistenceFailed,
        );
        expect(error.toString(), isNot(contains('synthetic-db-error')));
        expect(error.toString(), isNot(contains('StateError')));
      }
    });

    test('quality blocked typed commit never calls the repository', () async {
      final repository = _CommitRepository();
      final service = typedService(repository);

      await expectLater(
        service.commitTyped(
          bankName: 'Typed Bank',
          folderName: 'Math',
          items: <TypedReviewCommitInput>[
            TypedReviewCommitInput(
              reviewItemId: _typedReviewItemId,
              envelope: _typedEnvelope(),
              currentDraft: const QuestionDraft(
                type: QuestionType.singleChoice,
                content: 'Broken choice question',
                options: <String>[],
                standardAnswer: '',
                explanation: '',
              ),
            ),
          ],
          taskId: _typedTaskId,
          attemptToken: _typedAttemptToken,
          attemptNumber: 1,
          expectedReviewDraftRevision: 1,
          storageRoute: ImportStorageRoute.typedV2,
          storageReason: ocrTypedCandidateReadyReason,
          explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
        ),
        throwsA(
          isA<TypedReviewCommitException>().having(
            (error) => error.failure,
            'failure',
            TypedReviewCommitFailure.qualityBlocked,
          ),
        ),
      );

      expect(repository.v2SaveCalls, 0);
      expect(repository.saveCalls, 0);
      expect(manager.tasks.single.status, TaskStatus.pendingReview);
    });

    test('empty typed commit blocks without repository writes', () async {
      final repository = _CommitRepository();
      final service = typedService(repository);

      await expectLater(
        service.commitTyped(
          bankName: 'Typed Bank',
          folderName: 'Math',
          items: <TypedReviewCommitInput>[],
          taskId: _typedTaskId,
          attemptToken: _typedAttemptToken,
          attemptNumber: 1,
          expectedReviewDraftRevision: 1,
          storageRoute: ImportStorageRoute.typedV2,
          storageReason: ocrTypedCandidateReadyReason,
          explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
        ),
        throwsA(
          isA<TypedReviewCommitException>().having(
            (error) => error.failure,
            'failure',
            TypedReviewCommitFailure.emptyCommit,
          ),
        ),
      );

      expect(repository.v2SaveCalls, 0);
      expect(repository.saveCalls, 0);
      expect(manager.tasks.single.status, TaskStatus.pendingReview);
    });

    test('invalid route blocks typed commit', () async {
      final repository = _CommitRepository();
      final service = typedService(repository);

      for (final metadata in <(ImportStorageRoute, String?)>[
        (ImportStorageRoute.typedV2, ocrTypedCandidateShadowReadyReason),
        (ImportStorageRoute.typedV2, null),
        (ImportStorageRoute.legacyV1, ocrTypedCandidateReadyReason),
      ]) {
        await expectLater(
          service.commitTyped(
            bankName: 'Typed Bank',
            folderName: 'Math',
            items: <TypedReviewCommitInput>[_typedInput()],
            taskId: _typedTaskId,
            attemptToken: _typedAttemptToken,
            attemptNumber: 1,
            expectedReviewDraftRevision: 1,
            storageRoute: metadata.$1,
            storageReason: metadata.$2 ?? '',
            explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
          ),
          throwsA(
            isA<TypedReviewCommitException>().having(
              (error) => error.failure,
              'failure',
              TypedReviewCommitFailure.invalidRoute,
            ),
          ),
          reason: '${metadata.$1.name} + ${metadata.$2}',
        );
      }
      expect(repository.v2SaveCalls, 0);
      expect(repository.saveCalls, 0);
    });

    test('historical shadow route can never enter the typed writer', () async {
      final repository = _CommitRepository();
      final service = typedService(repository);

      await expectLater(
        service.commitTyped(
          bankName: 'Typed Bank',
          folderName: 'Math',
          items: <TypedReviewCommitInput>[_typedInput()],
          taskId: _typedTaskId,
          attemptToken: _typedAttemptToken,
          attemptNumber: 1,
          expectedReviewDraftRevision: 1,
          storageRoute: ImportStorageRoute.typedV2,
          storageReason: ocrTypedCandidateShadowReadyReason,
          explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
        ),
        throwsA(
          isA<TypedReviewCommitException>().having(
            (error) => error.failure,
            'failure',
            TypedReviewCommitFailure.invalidRoute,
          ),
        ),
      );
      expect(repository.v2SaveCalls, 0);
    });

    test('corrupt envelope blocks before any repository call', () async {
      final repository = _CommitRepository();
      final service = typedService(repository);

      await expectLater(
        service.commitTyped(
          bankName: 'Typed Bank',
          folderName: 'Math',
          items: <TypedReviewCommitInput>[
            TypedReviewCommitInput(
              reviewItemId: _typedReviewItemId,
              envelope: <String, Object?>{
                'schemaVersion': 1,
                'route': 'typedV2',
                'reviewItemId': _typedReviewItemId,
                'questionId': _typedQuestionId,
                'draft': <String, Object?>{'broken': true},
                'baselineLegacy': <String, Object?>{'broken': true},
                'unexpected': 'extra',
              },
              currentDraft: const QuestionDraft(
                type: QuestionType.shortAnswer,
                content: 'Synthetic stem',
                options: <String>[],
                standardAnswer: 'Conclusion',
                explanation: 'Subjective explanation',
              ),
            ),
          ],
          taskId: _typedTaskId,
          attemptToken: _typedAttemptToken,
          attemptNumber: 1,
          expectedReviewDraftRevision: 1,
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
      expect(repository.v2SaveCalls, 0);
      expect(repository.saveCalls, 0);
      expect(manager.tasks.single.status, TaskStatus.pendingReview);
    });

    test('commitTyped requires a positive review draft revision', () async {
      final repository = _CommitRepository();
      final service = typedService(repository);

      await expectLater(
        service.commitTyped(
          bankName: 'Typed Bank',
          folderName: 'Math',
          items: <TypedReviewCommitInput>[_typedInput()],
          taskId: _typedTaskId,
          attemptToken: _typedAttemptToken,
          attemptNumber: 1,
          expectedReviewDraftRevision: 0,
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
      expect(repository.v2SaveCalls, 0);
      expect(repository.saveCalls, 0);
    });

    test('missing task blocks before any repository call', () async {
      final repository = _CommitRepository();
      final service = typedService(repository, withTask: false);

      await expectLater(
        service.commitTyped(
          bankName: 'Typed Bank',
          folderName: 'Math',
          items: <TypedReviewCommitInput>[_typedInput()],
          taskId: _typedTaskId,
          attemptToken: _typedAttemptToken,
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
            TypedReviewCommitAttemptFailure.taskMissing,
          ),
        ),
      );
      expect(repository.v2SaveCalls, 0);
      expect(repository.saveCalls, 0);
    });

    test('stale attempt blocks before any repository call', () async {
      final repository = _CommitRepository();
      final service = typedService(repository);

      await expectLater(
        service.commitTyped(
          bankName: 'Typed Bank',
          folderName: 'Math',
          items: <TypedReviewCommitInput>[_typedInput()],
          taskId: _typedTaskId,
          attemptToken: 'stale-attempt-token',
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
            TypedReviewCommitAttemptFailure.staleAttempt,
          ),
        ),
      );
      expect(repository.v2SaveCalls, 0);
      expect(repository.saveCalls, 0);
    });

    test('a second concurrent typed commit is rejected with commitInProgress',
        () async {
      final repository = _CommitRepository();
      final service = typedService(repository);

      Future<ImportCommitResult> commit() {
        return service.commitTyped(
          bankName: 'Typed Bank',
          folderName: 'Math',
          items: <TypedReviewCommitInput>[_typedInput()],
          taskId: _typedTaskId,
          attemptToken: _typedAttemptToken,
          attemptNumber: 1,
          expectedReviewDraftRevision: 1,
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
      expect(first.questionCount, 1);
      await secondExpectation;
    });

    test('typed success never persists the task a second time', () async {
      var saveCalls = 0;
      final repository = _CommitRepository();
      final countingManager = TaskManager.forTesting(
        saveTask: (taskMap) async {
          saveCalls++;
        },
      );
      countingManager.tasks.add(ImportTask(
        id: _typedTaskId,
        title: 'Synthetic typed import',
        status: TaskStatus.pendingReview,
        parsedData: <Map<String, dynamic>>[
          <String, dynamic>{
            'q_num': 1,
            'type': 3,
            'content': 'Synthetic stem',
            'standard_answer': 'Conclusion',
          },
        ],
        diagnostics: const <String, dynamic>{
          TaskManager.keyAttemptToken: _typedAttemptToken,
          TaskManager.keyAttemptNumber: 1,
          TaskManager.keyAttemptState: 'readyForReview',
          TaskManager.keyImportStorageRoute: 'typedV2',
          TaskManager.keyImportStorageReason: 'typed_candidate_ready',
          TaskManager.keyReviewDraftRevision: 1,
        },
      ));
      final service = ImportCommitService(
        questionRepository: repository,
        taskManager: countingManager,
      );

      await service.commitTyped(
        bankName: 'Typed Bank',
        folderName: 'Math',
        items: <TypedReviewCommitInput>[_typedInput()],
        taskId: _typedTaskId,
        attemptToken: _typedAttemptToken,
        attemptNumber: 1,
        expectedReviewDraftRevision: 1,
        storageRoute: ImportStorageRoute.typedV2,
        storageReason: ocrTypedCandidateReadyReason,
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      );

      expect(saveCalls, 0,
          reason: 'the typed path must never call saveTask again');
      expect(countingManager.tasks.single.status, TaskStatus.completed);
    });

    test('a failed typed commit releases the lease and allows retry', () async {
      final repository = _CommitRepository()..failure = StateError('synthetic');
      final service = typedService(repository);

      await expectLater(
        service.commitTyped(
          bankName: 'Typed Bank',
          folderName: 'Math',
          items: <TypedReviewCommitInput>[_typedInput()],
          taskId: _typedTaskId,
          attemptToken: _typedAttemptToken,
          attemptNumber: 1,
          expectedReviewDraftRevision: 1,
          storageRoute: ImportStorageRoute.typedV2,
          storageReason: ocrTypedCandidateReadyReason,
          explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
        ),
        throwsA(isA<TypedReviewCommitAttemptException>()),
      );

      repository.failure = null;
      final retry = await service.commitTyped(
        bankName: 'Typed Bank',
        folderName: 'Math',
        items: <TypedReviewCommitInput>[_typedInput()],
        taskId: _typedTaskId,
        attemptToken: _typedAttemptToken,
        attemptNumber: 1,
        expectedReviewDraftRevision: 1,
        storageRoute: ImportStorageRoute.typedV2,
        storageReason: ocrTypedCandidateReadyReason,
        explanationRetentionMode: ExplanationRetentionMode.subjectiveOnly,
      );

      expect(retry.questionCount, 1);
      expect(manager.tasks.single.status, TaskStatus.completed);
    });
  });
}

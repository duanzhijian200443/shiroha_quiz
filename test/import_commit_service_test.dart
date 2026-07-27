import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/data/models/question_draft.dart';
import 'package:shiroha_quiz/data/repositories/question_repository.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_field_policy.dart';
import 'package:shiroha_quiz/services/import_review/import_commit_service.dart';
import 'package:shiroha_quiz/services/task_manager.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _CommitRepository extends Fake implements QuestionRepository {
  var saveCalls = 0;
  Object? failure;
  List<QuestionDraft>? savedQuestions;

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

  test('hard quality gate blocks repository writes', () async {
    final repository = _CommitRepository();
    final service = ImportCommitService(
      questionRepository: repository,
      taskManager: manager,
    );

    await expectLater(
      service.commit(
        bankName: 'Smoke Bank',
        folderName: 'Smoke',
        questions: const [_draft],
        diagnostics: const {
          'qualityGate': {'blocked': true, 'reason': 'synthetic gate'},
        },
      ),
      throwsA(isA<ImportCommitBlockedException>()),
    );

    expect(repository.saveCalls, 0);
  });

  test('hard structural review issues block repository writes', () async {
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
        diagnostics: const {},
      ),
      throwsA(isA<ImportCommitBlockedException>()),
    );

    expect(repository.saveCalls, 0);
  });

  test('blank choice options are blocked before repository writes', () async {
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
        diagnostics: const {},
      ),
      throwsA(isA<ImportCommitBlockedException>()),
    );

    expect(repository.saveCalls, 0);
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
      throwsStateError,
    );

    expect(manager.tasks.single.status, TaskStatus.pendingReview);
  });
}

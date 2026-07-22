import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/data/models/question_draft.dart';
import 'package:shiroha_quiz/data/repositories/question_repository.dart';
import 'package:shiroha_quiz/services/import_review/import_commit_service.dart';
import 'package:shiroha_quiz/services/task_manager.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _CommitRepository extends Fake implements QuestionRepository {
  var saveCalls = 0;
  Object? failure;

  @override
  Future<void> saveQuestionDraftsToBank({
    required String bankName,
    String? folderName,
    required List<QuestionDraft> questions,
  }) async {
    saveCalls++;
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

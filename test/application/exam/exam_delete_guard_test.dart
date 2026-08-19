import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/backup/backup_restore_gate.dart';
import 'package:shiroha_quiz/application/exam/exam_mutation_command.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/repositories/exam_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _paperId = 'exam-delete-active-grading';
const _questionId = 'exam-delete-active-question';

Future<Database> _database() => DatabaseHelper.instance.database;

Future<void> _seedActiveGradingPaper(Database db) async {
  await ExamRepository().getAllExamPapers();
  await db.insert('exam_papers', <String, Object?>{
    'id': _paperId,
    'title': 'Active grading paper',
    'source_type': 0,
    'status': 1,
    'score': 0.0,
    'total_score': 1.0,
    'created_at': 1,
  });
  await db.insert('paper_questions', <String, Object?>{
    'paper_id': _paperId,
    'question_id': _questionId,
    'user_answer': '',
    'is_correct': 0,
    'order_index': 0,
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    BackupRestoreMutationGate.resetForTesting();
    await DatabaseHelper.resetRuntimeProfileForTesting();
  });

  tearDown(() async {
    BackupRestoreMutationGate.resetForTesting();
    await DatabaseHelper.resetRuntimeProfileForTesting();
  });

  test('active grading blocks delete and preserves paper relations', () async {
    final db = await _database();
    await _seedActiveGradingPaper(db);

    await expectLater(
      ExamMutationCommand(ExamRepository()).deleteExamPaper(_paperId),
      throwsA(
        isA<ExamDeleteException>().having(
          (error) => error.failure,
          'failure',
          ExamDeleteFailure.activeGrading,
        ),
      ),
    );

    expect(await db.query('exam_papers'), hasLength(1));
    expect(await db.query('paper_questions'), hasLength(1));
  });
}

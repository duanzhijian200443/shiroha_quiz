import '../../core/database/database_helper.dart';
import '../models/import_task_cleanup.dart';
import '../models/review_draft_cas.dart';

class ImportTaskRepository {
  ImportTaskRepository({DatabaseHelper? databaseHelper})
      : _databaseHelper = databaseHelper ?? DatabaseHelper.instance;

  static final ImportTaskRepository instance = ImportTaskRepository();

  final DatabaseHelper _databaseHelper;

  Future<List<String>> deleteOldImportTasks(int olderThanUnix) async {
    return _databaseHelper.deleteOldImportTasks(olderThanUnix);
  }

  Future<List<Map<String, dynamic>>> getAllImportTasks() async {
    return _databaseHelper.getAllImportTasks();
  }

  Future<void> saveImportTask(Map<String, dynamic> taskMap) async {
    return _databaseHelper.saveImportTask(taskMap);
  }

  Future<ReviewDraftCasResult> saveReviewDraftCas({
    required String taskId,
    required ReviewDraftAttemptIdentity expectedAttempt,
    required int expectedRevision,
    required List<Map<String, dynamic>> questions,
    required String explanationRetentionMode,
  }) {
    return _databaseHelper.saveReviewDraftCas(
      taskId: taskId,
      expectedAttempt: expectedAttempt,
      expectedRevision: expectedRevision,
      questions: questions,
      explanationRetentionMode: explanationRetentionMode,
    );
  }

  Future<ImportTaskDeletePersistenceStatus> deleteImportTask(
    String id,
  ) async {
    return _databaseHelper.deleteImportTask(id);
  }

  Future<List<String>> clearCompletedImportTasks({
    Set<String> excludedIds = const <String>{},
    Set<String> candidateIds = const <String>{},
  }) async {
    return _databaseHelper.clearCompletedImportTasks(
      excludedIds: excludedIds,
      candidateIds: candidateIds,
    );
  }
}

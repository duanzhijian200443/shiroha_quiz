import '../../core/database/database_helper.dart';
import '../models/import_task_cleanup.dart';

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

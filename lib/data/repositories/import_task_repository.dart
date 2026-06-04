import '../../core/database/database_helper.dart';

class ImportTaskRepository {
  ImportTaskRepository({DatabaseHelper? databaseHelper})
      : _databaseHelper = databaseHelper ?? DatabaseHelper.instance;

  static final ImportTaskRepository instance = ImportTaskRepository();

  final DatabaseHelper _databaseHelper;

  Future<void> deleteOldImportTasks(int olderThanUnix) async {
    return _databaseHelper.deleteOldImportTasks(olderThanUnix);
  }

  Future<List<Map<String, dynamic>>> getAllImportTasks() async {
    return _databaseHelper.getAllImportTasks();
  }

  Future<void> saveImportTask(Map<String, dynamic> taskMap) async {
    return _databaseHelper.saveImportTask(taskMap);
  }

  Future<void> deleteImportTask(String id) async {
    return _databaseHelper.deleteImportTask(id);
  }

  Future<void> clearCompletedImportTasks() async {
    return _databaseHelper.clearCompletedImportTasks();
  }
}

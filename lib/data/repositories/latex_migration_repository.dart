import 'package:sqflite/sqflite.dart';
import '../../core/database/database_helper.dart';

class LatexMigrationRepository {
  LatexMigrationRepository({DatabaseHelper? databaseHelper})
      : _databaseHelper = databaseHelper ?? DatabaseHelper.instance;

  static final LatexMigrationRepository instance = LatexMigrationRepository();

  final DatabaseHelper _databaseHelper;

  Future<Database> get _db async => await _databaseHelper.database;

  Future<List<Map<String, dynamic>>> getAllQuestions() async {
    final db = await _db;
    return await db.query('questions');
  }

  Future<void> updateQuestionFields(
      String id, Map<String, dynamic> fields) async {
    final db = await _db;
    await db.update(
      'questions',
      fields,
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}

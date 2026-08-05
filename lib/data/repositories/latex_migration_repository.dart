import 'package:sqflite/sqflite.dart';
import '../../core/database/database_helper.dart';

class LatexMigrationRepository {
  LatexMigrationRepository({DatabaseHelper? databaseHelper})
      : _databaseHelper = databaseHelper ?? DatabaseHelper.instance;

  static final LatexMigrationRepository instance = LatexMigrationRepository();

  static final RegExp _columnNamePattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

  final DatabaseHelper _databaseHelper;

  Future<Database> get _db async => await _databaseHelper.database;

  Future<List<Map<String, dynamic>>> getAllQuestions() async {
    final db = await _db;
    return await db.rawQuery('''
      SELECT q.* FROM questions q
      WHERE NOT EXISTS (
        SELECT 1 FROM question_v2_payloads p WHERE p.question_id = q.id
      )
    ''');
  }

  Future<void> updateQuestionFields(
      String id, Map<String, dynamic> fields) async {
    // sqflite binds values but only quotes keyword identifiers; reject any
    // key that is not a plain SQLite identifier so caller-controlled names
    // can never splice SQL into the SET clause.
    for (final key in fields.keys) {
      if (!_columnNamePattern.hasMatch(key)) {
        throw ArgumentError('Invalid update field name');
      }
    }
    final db = await _db;
    await db.update(
      'questions',
      fields,
      where: 'id = ? AND NOT EXISTS ('
          'SELECT 1 FROM question_v2_payloads p '
          'WHERE p.question_id = questions.id'
          ')',
      whereArgs: [id],
    );
  }
}

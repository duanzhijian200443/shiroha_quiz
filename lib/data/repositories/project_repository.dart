import 'package:sqflite/sqflite.dart';

import '../../application/projects/project_repository.dart';
import '../../core/database/database_helper.dart';
import '../../domain/projects/project.dart';

/// SQLite implementation of the J0 [ProjectRepository] port.
///
/// Writes are strictly scoped to the J0 tables:
///
/// - `projects` metadata;
/// - `project_files` / `project_banks` many-to-many relation rows.
///
/// No method here reads, writes, or deletes `library_files` (beyond foreign
/// key existence checks), banks, questions, sidecars, or review state.
/// Project deletion removes metadata and relation rows only.
class SqliteProjectRepository implements ProjectRepository {
  SqliteProjectRepository({DatabaseHelper? databaseHelper})
      : _databaseHelper = databaseHelper ?? DatabaseHelper.instance;

  final DatabaseHelper _databaseHelper;

  static const String _projectsTable = 'projects';
  static const String _projectFilesTable = 'project_files';
  static const String _projectBanksTable = 'project_banks';
  static const String _libraryFilesTable = 'library_files';

  @override
  Future<void> createProject(Project project) async {
    final db = await _databaseHelper.database;
    await db.transaction((txn) async {
      final existing = await txn.query(
        _projectsTable,
        columns: const <String>['project_id'],
        where: 'project_id = ?',
        whereArgs: <Object?>[project.projectId],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        throw const ProjectRepositoryException(
          ProjectRepositoryFailure.projectAlreadyExists,
        );
      }
      await txn.insert(_projectsTable, _toRow(project));
    });
  }

  @override
  Future<List<Project>> listProjects() async {
    final db = await _databaseHelper.database;
    final rows = await db.query(
      _projectsTable,
      orderBy: 'created_at ASC, project_id ASC',
    );
    return rows.map(_fromRow).toList(growable: false);
  }

  @override
  Future<Project?> getProject(String projectId) async {
    final db = await _databaseHelper.database;
    final rows = await db.query(
      _projectsTable,
      where: 'project_id = ?',
      whereArgs: <Object?>[projectId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.single);
  }

  @override
  Future<Project> renameProject({
    required String projectId,
    required String displayName,
  }) async {
    final db = await _databaseHelper.database;
    return db.transaction((txn) async {
      final rows = await txn.query(
        _projectsTable,
        where: 'project_id = ?',
        whereArgs: <Object?>[projectId],
        limit: 1,
      );
      if (rows.isEmpty) {
        throw const ProjectRepositoryException(
          ProjectRepositoryFailure.projectNotFound,
        );
      }
      final updated = Project(
        projectId: projectId,
        displayName: displayName,
        createdAt: _createdAtFromRow(rows.single),
      );
      await txn.update(
        _projectsTable,
        <String, Object?>{'display_name': updated.displayName},
        where: 'project_id = ?',
        whereArgs: <Object?>[projectId],
      );
      return updated;
    });
  }

  @override
  Future<void> deleteProject(String projectId) async {
    final db = await _databaseHelper.database;
    await db.transaction((txn) async {
      final existing = await txn.query(
        _projectsTable,
        columns: const <String>['project_id'],
        where: 'project_id = ?',
        whereArgs: <Object?>[projectId],
        limit: 1,
      );
      if (existing.isEmpty) {
        throw const ProjectRepositoryException(
          ProjectRepositoryFailure.projectNotFound,
        );
      }
      await txn.delete(
        _projectFilesTable,
        where: 'project_id = ?',
        whereArgs: <Object?>[projectId],
      );
      await txn.delete(
        _projectBanksTable,
        where: 'project_id = ?',
        whereArgs: <Object?>[projectId],
      );
      await txn.delete(
        _projectsTable,
        where: 'project_id = ?',
        whereArgs: <Object?>[projectId],
      );
    });
  }

  @override
  Future<void> attachFile({
    required String projectId,
    required String fileId,
  }) async {
    final db = await _databaseHelper.database;
    await db.transaction((txn) async {
      await _expectProject(txn, projectId);
      final file = await txn.query(
        _libraryFilesTable,
        columns: const <String>['file_id'],
        where: 'file_id = ?',
        whereArgs: <Object?>[fileId],
        limit: 1,
      );
      if (file.isEmpty) {
        throw const ProjectRepositoryException(
          ProjectRepositoryFailure.fileNotFound,
        );
      }
      await txn.insert(
          _projectFilesTable,
          <String, Object?>{
            'project_id': projectId,
            'file_id': fileId,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore);
    });
  }

  @override
  Future<void> detachFile({
    required String projectId,
    required String fileId,
  }) async {
    final db = await _databaseHelper.database;
    await db.transaction((txn) async {
      await _expectProject(txn, projectId);
      await txn.delete(
        _projectFilesTable,
        where: 'project_id = ? AND file_id = ?',
        whereArgs: <Object?>[projectId, fileId],
      );
    });
  }

  @override
  Future<void> attachBank({
    required String projectId,
    required String bankName,
  }) async {
    final db = await _databaseHelper.database;
    await db.transaction((txn) async {
      await _expectProject(txn, projectId);
      await txn.insert(
          _projectBanksTable,
          <String, Object?>{
            'project_id': projectId,
            'bank_name': bankName,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore);
    });
  }

  @override
  Future<void> detachBank({
    required String projectId,
    required String bankName,
  }) async {
    final db = await _databaseHelper.database;
    await db.transaction((txn) async {
      await _expectProject(txn, projectId);
      await txn.delete(
        _projectBanksTable,
        where: 'project_id = ? AND bank_name = ?',
        whereArgs: <Object?>[projectId, bankName],
      );
    });
  }

  @override
  Future<List<String>> listProjectFileIds(String projectId) async {
    final db = await _databaseHelper.database;
    final rows = await db.query(
      _projectFilesTable,
      columns: const <String>['file_id'],
      where: 'project_id = ?',
      whereArgs: <Object?>[projectId],
      orderBy: 'file_id ASC',
    );
    return rows.map((row) => row['file_id']! as String).toList(growable: false);
  }

  @override
  Future<List<String>> listProjectBankNames(String projectId) async {
    final db = await _databaseHelper.database;
    final rows = await db.query(
      _projectBanksTable,
      columns: const <String>['bank_name'],
      where: 'project_id = ?',
      whereArgs: <Object?>[projectId],
      orderBy: 'bank_name ASC',
    );
    return rows
        .map((row) => row['bank_name']! as String)
        .toList(growable: false);
  }

  @override
  Future<List<String>> listProjectIdsForFile(String fileId) async {
    final db = await _databaseHelper.database;
    final rows = await db.query(
      _projectFilesTable,
      columns: const <String>['project_id'],
      where: 'file_id = ?',
      whereArgs: <Object?>[fileId],
      orderBy: 'project_id ASC',
    );
    return rows
        .map((row) => row['project_id']! as String)
        .toList(growable: false);
  }

  @override
  Future<List<String>> listProjectIdsForBank(String bankName) async {
    final db = await _databaseHelper.database;
    final rows = await db.query(
      _projectBanksTable,
      columns: const <String>['project_id'],
      where: 'bank_name = ?',
      whereArgs: <Object?>[bankName],
      orderBy: 'project_id ASC',
    );
    return rows
        .map((row) => row['project_id']! as String)
        .toList(growable: false);
  }

  Future<void> _expectProject(DatabaseExecutor txn, String projectId) async {
    final rows = await txn.query(
      _projectsTable,
      columns: const <String>['project_id'],
      where: 'project_id = ?',
      whereArgs: <Object?>[projectId],
      limit: 1,
    );
    if (rows.isEmpty) {
      throw const ProjectRepositoryException(
        ProjectRepositoryFailure.projectNotFound,
      );
    }
  }

  Map<String, Object?> _toRow(Project project) {
    return <String, Object?>{
      'project_id': project.projectId,
      'display_name': project.displayName,
      'created_at': project.createdAt.millisecondsSinceEpoch,
    };
  }

  Project _fromRow(Map<String, Object?> row) {
    return Project(
      projectId: row['project_id']! as String,
      displayName: row['display_name']! as String,
      createdAt: _createdAtFromRow(row),
    );
  }

  DateTime _createdAtFromRow(Map<String, Object?> row) {
    return DateTime.fromMillisecondsSinceEpoch(
      row['created_at']! as int,
      isUtc: true,
    );
  }
}

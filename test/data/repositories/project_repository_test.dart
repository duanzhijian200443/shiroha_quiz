// J0 SqliteProjectRepository contract on a real SQLite database: CRUD
// durability, many-to-many file/bank relations, detach/delete safety for
// underlying assets, unassigned assets, close/reopen durability, and the
// Decision A bank relation semantics (no bank rename, exact-name keys).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/application/projects/project_repository.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/repositories/library_file_repository.dart';
import 'package:shiroha_quiz/data/repositories/project_repository.dart';
import 'package:shiroha_quiz/domain/assets/library_file.dart';
import 'package:shiroha_quiz/domain/projects/project.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const String _sha256 =
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';

LibraryFile file({
  String fileId = 'file-j0-0001',
  String storageKey = 'library/file-j0-0001',
}) {
  return LibraryFile(
    fileId: fileId,
    displayName: 'report.pdf',
    mimeType: 'application/pdf',
    sizeBytes: 3,
    sha256: _sha256,
    storageKey: storageKey,
    createdAt: DateTime.utc(2026, 8, 8, 12),
  );
}

Project project({
  String projectId = 'project-j0-0001',
  String displayName = '数学复习',
}) {
  return Project(
    projectId: projectId,
    displayName: displayName,
    createdAt: DateTime.utc(2026, 8, 8, 12),
  );
}

/// File-backed DatabaseHelper seam: repository APIs run against a real
/// database opened only through the frozen openPathForTesting seam.
class _FileDatabaseHelper extends Fake implements DatabaseHelper {
  _FileDatabaseHelper(this.path);

  final String path;
  Database? _database;

  @override
  Future<Database> get database async =>
      _database ??= await DatabaseHelper.instance.openPathForTesting(path);

  @override
  Future<void> close() async {
    final db = _database;
    _database = null;
    if (db != null) await db.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    tempDir = await Directory.systemTemp.createTemp('j0_project_repo_');
  });

  tearDown(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<void> seedBank(
    Database db,
    String bankName, {
    String? questionId,
  }) async {
    await db.insert('questions', <String, Object?>{
      'id': questionId ?? 'q_${bankName.replaceAll(RegExp(r'\W'), '_')}',
      'type': 0,
      'content': 'seed question for $bankName',
      'options': jsonEncode(<String>['A', 'B']),
      'standard_answer': 'A',
      'explanation': 'seed',
      'raw_explanation': 'seed raw',
      'created_at': 1700000001,
      'bank_name': bankName,
    });
  }

  Future<void> seedTypedQuestionWithReview(Database db) async {
    await db.insert('questions', <String, Object?>{
      'id': 'q_typed_j0',
      'type': 0,
      'content': 'typed stem',
      'options': jsonEncode(<String>['A', 'B']),
      'standard_answer': 'A',
      'explanation': 'typed explanation',
      'raw_explanation': 'typed raw',
      'created_at': 1700000002,
      'bank_name': 'typed_bank',
    });
    await db.insert('question_v2_payloads', <String, Object?>{
      'question_id': 'q_typed_j0',
      'payload_schema_version': 2,
      'payload_json': '{"schemaVersion":2,"j0":true,"preserve":"exact"}',
    });
    await db.insert('review_states', <String, Object?>{
      'question_id': 'q_typed_j0',
      'state': 3,
      'next_review_time': 1700002000,
      'lapses': 4,
      'difficulty': 2.5,
      'stability': 9.5,
      'reps': 7,
      'last_lapse_time': 1700000500,
      'last_review_time': 1700001000,
    });
  }

  test('create, list, and get round-trip project metadata', () async {
    final repository = SqliteProjectRepository();
    final expected = project();
    await repository.createProject(expected);

    expect(await repository.getProject(expected.projectId), expected);
    expect(await repository.listProjects(), <Project>[expected]);
    expect(await repository.getProject('project-missing'), isNull);
  });

  test('list orders projects by creation time then id', () async {
    final repository = SqliteProjectRepository();
    await repository.createProject(
      project(projectId: 'project-b', displayName: 'B'),
    );
    await repository.createProject(
      project(projectId: 'project-a', displayName: 'A'),
    );

    final all = await repository.listProjects();
    expect(all.map((p) => p.projectId).toList(), <String>[
      'project-a',
      'project-b',
    ]);
  });

  test(
    'rename persists the new label and keeps id and creation time',
    () async {
      final repository = SqliteProjectRepository();
      final expected = project();
      await repository.createProject(expected);

      final renamed = await repository.renameProject(
        projectId: expected.projectId,
        displayName: '新名称',
      );
      expect(renamed.projectId, expected.projectId);
      expect(renamed.createdAt, expected.createdAt);
      expect(renamed.displayName, '新名称');
      expect(await repository.getProject(expected.projectId), renamed);
    },
  );

  test('rename of an unknown project fails with projectNotFound', () async {
    final repository = SqliteProjectRepository();
    await expectLater(
      repository.renameProject(
        projectId: 'project-missing',
        displayName: 'new',
      ),
      throwsA(
        isA<ProjectRepositoryException>().having(
          (error) => error.failure,
          'failure',
          ProjectRepositoryFailure.projectNotFound,
        ),
      ),
    );
  });

  test('duplicate create fails with projectAlreadyExists', () async {
    final repository = SqliteProjectRepository();
    await repository.createProject(project());
    await expectLater(
      repository.createProject(project()),
      throwsA(
        isA<ProjectRepositoryException>().having(
          (error) => error.failure,
          'failure',
          ProjectRepositoryFailure.projectAlreadyExists,
        ),
      ),
    );
  });

  test('one file belongs to multiple projects without duplication', () async {
    final repository = SqliteProjectRepository();
    await LibraryFileRepository().save(file());
    final first = project(projectId: 'project-p1', displayName: 'P1');
    final second = project(projectId: 'project-p2', displayName: 'P2');
    await repository.createProject(first);
    await repository.createProject(second);

    await repository.attachFile(
      projectId: first.projectId,
      fileId: 'file-j0-0001',
    );
    await repository.attachFile(
      projectId: second.projectId,
      fileId: 'file-j0-0001',
    );

    expect(await repository.listProjectIdsForFile('file-j0-0001'), <String>[
      first.projectId,
      second.projectId,
    ]);
    expect(await repository.listProjectFileIds(first.projectId), <String>[
      'file-j0-0001',
    ]);
    expect(await repository.listProjectFileIds(second.projectId), <String>[
      'file-j0-0001',
    ]);
    final fileRows = await (await openDatabase()).query('library_files');
    expect(fileRows, hasLength(1));
  });

  test('one bank belongs to multiple projects (Decision A name key)', () async {
    final repository = SqliteProjectRepository();
    final db = await openDatabase();
    await seedBank(db, '高中数学');

    final first = project(projectId: 'project-p1', displayName: 'P1');
    final second = project(projectId: 'project-p2', displayName: 'P2');
    await repository.createProject(first);
    await repository.createProject(second);

    await repository.attachBank(projectId: first.projectId, bankName: '高中数学');
    await repository.attachBank(projectId: second.projectId, bankName: '高中数学');

    expect(await repository.listProjectIdsForBank('高中数学'), <String>[
      first.projectId,
      second.projectId,
    ]);
    expect(await repository.listProjectBankNames(first.projectId), <String>[
      '高中数学',
    ]);
    expect(await repository.listProjectBankNames(second.projectId), <String>[
      '高中数学',
    ]);
  });

  test(
    'attach is idempotent; detach never deletes the underlying asset',
    () async {
      final repository = SqliteProjectRepository();
      await LibraryFileRepository().save(file());
      final db = await openDatabase();
      await seedBank(db, 'bank_detach');

      final expected = project();
      await repository.createProject(expected);
      await repository.attachFile(
        projectId: expected.projectId,
        fileId: 'file-j0-0001',
      );
      await repository.attachFile(
        projectId: expected.projectId,
        fileId: 'file-j0-0001',
      );
      await repository.attachBank(
        projectId: expected.projectId,
        bankName: 'bank_detach',
      );
      await repository.attachBank(
        projectId: expected.projectId,
        bankName: 'bank_detach',
      );

      await repository.detachFile(
        projectId: expected.projectId,
        fileId: 'file-j0-0001',
      );
      await repository.detachBank(
        projectId: expected.projectId,
        bankName: 'bank_detach',
      );
      // Detaching an absent relation is a no-op.
      await repository.detachFile(
        projectId: expected.projectId,
        fileId: 'file-j0-0001',
      );

      expect(await repository.listProjectFileIds(expected.projectId), isEmpty);
      expect(
        await repository.listProjectBankNames(expected.projectId),
        isEmpty,
      );
      // The library file row and the bank question row are untouched.
      expect(await LibraryFileRepository().findById('file-j0-0001'), file());
      final questionRows = await db.query(
        'questions',
        where: 'bank_name = ?',
        whereArgs: <Object?>['bank_detach'],
      );
      expect(questionRows, hasLength(1));
    },
  );

  test('delete removes metadata and relations only (E)', () async {
    final repository = SqliteProjectRepository();
    final db = await openDatabase();
    await LibraryFileRepository().save(file());
    await seedTypedQuestionWithReview(db);
    await seedBank(db, 'bank_delete', questionId: 'q_legacy_j0');

    final expected = project();
    await repository.createProject(expected);
    await repository.attachFile(
      projectId: expected.projectId,
      fileId: 'file-j0-0001',
    );
    await repository.attachBank(
      projectId: expected.projectId,
      bankName: 'bank_delete',
    );
    await repository.attachBank(
      projectId: expected.projectId,
      bankName: 'typed_bank',
    );

    await repository.deleteProject(expected.projectId);

    expect(await repository.getProject(expected.projectId), isNull);
    expect(await repository.listProjects(), isEmpty);
    expect(await repository.listProjectFileIds(expected.projectId), isEmpty);
    expect(await repository.listProjectBankNames(expected.projectId), isEmpty);
    expect(await repository.listProjectIdsForFile('file-j0-0001'), isEmpty);
    expect(await repository.listProjectIdsForBank('bank_delete'), isEmpty);

    // Underlying assets survive: file, legacy question, typed sidecar,
    // and review state.
    expect(await LibraryFileRepository().findById('file-j0-0001'), file());
    expect(
      (await db.query(
        'questions',
        where: 'id = ?',
        whereArgs: <Object?>['q_typed_j0'],
      ))
          .single['content'],
      'typed stem',
    );
    expect(
      (await db.query(
        'question_v2_payloads',
        where: 'question_id = ?',
        whereArgs: <Object?>['q_typed_j0'],
      ))
          .single['payload_json'],
      '{"schemaVersion":2,"j0":true,"preserve":"exact"}',
    );
    expect(
      (await db.query(
        'review_states',
        where: 'question_id = ?',
        whereArgs: <Object?>['q_typed_j0'],
      ))
          .single['lapses'],
      4,
    );
    expect(
      (await db.query(
        'questions',
        where: 'id = ?',
        whereArgs: <Object?>['q_legacy_j0'],
      ))
          .single['bank_name'],
      'bank_delete',
    );
    expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
  });

  test('unassigned files and banks remain valid (F)', () async {
    final repository = SqliteProjectRepository();
    await LibraryFileRepository().save(file());
    final db = await openDatabase();
    await seedBank(db, 'unassigned_bank');

    expect(await LibraryFileRepository().findById('file-j0-0001'), file());
    expect(await repository.listProjectIdsForFile('file-j0-0001'), isEmpty);
    expect(await repository.listProjectIdsForBank('unassigned_bank'), isEmpty);

    final questionRows = await db.query(
      'questions',
      where: 'bank_name = ?',
      whereArgs: <Object?>['unassigned_bank'],
    );
    expect(questionRows, hasLength(1));
  });

  test('projects and relations survive close and reopen (G)', () async {
    final path = p.join(tempDir.path, 'project_repo.db');
    final firstHelper = _FileDatabaseHelper(path);
    final first = SqliteProjectRepository(databaseHelper: firstHelper);
    await LibraryFileRepository(databaseHelper: firstHelper).save(file());
    final expected = project();
    await first.createProject(expected);
    await first.attachFile(
      projectId: expected.projectId,
      fileId: 'file-j0-0001',
    );
    await first.attachBank(
      projectId: expected.projectId,
      bankName: 'bank_reopen',
    );
    await firstHelper.close();

    final secondHelper = _FileDatabaseHelper(path);
    final reopened = SqliteProjectRepository(databaseHelper: secondHelper);
    expect(await reopened.getProject(expected.projectId), expected);
    expect(await reopened.listProjectFileIds(expected.projectId), <String>[
      'file-j0-0001',
    ]);
    expect(await reopened.listProjectBankNames(expected.projectId), <String>[
      'bank_reopen',
    ]);
    final version = await (await secondHelper.database).rawQuery(
      'PRAGMA user_version',
    );
    expect(version.single['user_version'], 17);
    await secondHelper.close();
  });

  test(
    'attach/detach against missing references fail deterministically',
    () async {
      final repository = SqliteProjectRepository();
      await LibraryFileRepository().save(file());
      final expected = project();
      await repository.createProject(expected);

      await expectLater(
        repository.attachFile(
          projectId: expected.projectId,
          fileId: 'file-missing',
        ),
        throwsA(
          isA<ProjectRepositoryException>().having(
            (error) => error.failure,
            'failure',
            ProjectRepositoryFailure.fileNotFound,
          ),
        ),
      );
      await expectLater(
        repository.attachFile(
          projectId: 'project-missing',
          fileId: 'file-j0-0001',
        ),
        throwsA(
          isA<ProjectRepositoryException>().having(
            (error) => error.failure,
            'failure',
            ProjectRepositoryFailure.projectNotFound,
          ),
        ),
      );
      await expectLater(
        repository.attachBank(
          projectId: 'project-missing',
          bankName: 'any_bank',
        ),
        throwsA(
          isA<ProjectRepositoryException>().having(
            (error) => error.failure,
            'failure',
            ProjectRepositoryFailure.projectNotFound,
          ),
        ),
      );
      await expectLater(
        repository.deleteProject('project-missing'),
        throwsA(
          isA<ProjectRepositoryException>().having(
            (error) => error.failure,
            'failure',
            ProjectRepositoryFailure.projectNotFound,
          ),
        ),
      );
    },
  );

  test(
    'Project rename never touches bank relations (Decision A semantics)',
    () async {
      final repository = SqliteProjectRepository();
      final db = await openDatabase();
      await seedBank(db, 'bank_rename_probe');
      final expected = project();
      await repository.createProject(expected);
      await repository.attachBank(
        projectId: expected.projectId,
        bankName: 'bank_rename_probe',
      );

      final renamed = await repository.renameProject(
        projectId: expected.projectId,
        displayName: 'renamed project',
      );

      expect(renamed.displayName, 'renamed project');
      expect(
        await repository.listProjectBankNames(expected.projectId),
        <String>['bank_rename_probe'],
      );
      // J0 exposes no bank rename capability; the bank row itself is
      // untouched by project metadata changes.
      expect(
        (await db.query(
          'questions',
          where: 'bank_name = ?',
          whereArgs: <Object?>['bank_rename_probe'],
        ))
            .single['bank_name'],
        'bank_rename_probe',
      );
    },
  );
}

/// Opens the shared singleton-backed database for direct fixture seeding and
/// row assertions.
Future<Database> openDatabase() => DatabaseHelper.instance.database;

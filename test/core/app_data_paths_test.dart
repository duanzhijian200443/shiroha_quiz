import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/core/app_data_paths.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/repositories/backup_database_authority.dart';

void main() {
  late Directory supportDirectory;

  setUp(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    supportDirectory = await Directory.systemTemp.createTemp('app_data_paths_');
  });

  tearDown(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    if (supportDirectory.existsSync()) {
      await supportDirectory.delete(recursive: true);
    }
  });

  test('development paths are independent of the worktree name', () {
    final paths = AppDataPaths.fromApplicationSupportDirectory(
      supportDirectory,
      environment: AppDataEnvironment.development,
    );

    expect(paths.rootPath, contains(p.join('Shiroha', 'development')));
    expect(paths.databasePath, isNot(contains('shiroha_quiz')));
    expect(paths.databasePath, isNot(contains('shiroha_product_fix')));
    expect(paths.databasePath, isNot(contains('dart_tool')));
    expect(paths.contentAssetsRoot,
        p.join(paths.managedFilesRoot, 'content_assets'));
  });

  test('production and development use isolated canonical roots', () {
    final development = AppDataPaths.fromApplicationSupportDirectory(
      supportDirectory,
      environment: AppDataEnvironment.development,
    );
    final production = AppDataPaths.fromApplicationSupportDirectory(
      supportDirectory,
      environment: AppDataEnvironment.production,
    );

    expect(development.databasePath, isNot(production.databasePath));
    expect(development.managedFilesRoot, isNot(production.managedFilesRoot));
    expect(development.restoreRoot, isNot(production.restoreRoot));
  });

  test('DatabaseHelper and B0 share the configured canonical database path',
      () async {
    final paths = AppDataPaths.fromApplicationSupportDirectory(
      supportDirectory,
      environment: AppDataEnvironment.development,
    );
    DatabaseHelper.configureAppDataPaths(paths);

    expect(
      await DatabaseHelper.instance.getProductionDatabasePath(),
      paths.databasePath,
    );
    final authority = SqliteBackupDatabaseAuthority(
      databaseHelper: DatabaseHelper.instance,
    );
    expect(await authority.productionDatabasePath(), paths.databasePath);
  });

  test('application-support path must be absolute', () {
    expect(
      () => AppDataPaths.fromApplicationSupportDirectory(
        Directory('relative-support'),
        environment: AppDataEnvironment.development,
      ),
      throwsArgumentError,
    );
  });
}

import 'dart:io';

import 'package:path/path.dart' as p;

/// Selects the durable user-data namespace for a running application.
enum AppDataEnvironment {
  development('development'),
  production('production');

  const AppDataEnvironment(this.directoryName);

  final String directoryName;
}

/// Computes the canonical durable paths owned by the application.
///
/// The application-support directory is supplied by the composition root so
/// this value object never consults [Directory.current], a repository root, or
/// a Git worktree. Test callers can provide an absolute temporary directory.
final class AppDataPaths {
  AppDataPaths._({
    required this.applicationSupportRoot,
    required this.environment,
  }) : rootPath = p.normalize(
          p.join(
            applicationSupportRoot,
            'Shiroha',
            environment.directoryName,
          ),
        );

  factory AppDataPaths.fromApplicationSupportDirectory(
    Directory applicationSupportDirectory, {
    required AppDataEnvironment environment,
  }) {
    final path = p.normalize(applicationSupportDirectory.path);
    if (!p.isAbsolute(path)) {
      throw ArgumentError.value(
        applicationSupportDirectory.path,
        'applicationSupportDirectory',
        'The application-support path must be absolute.',
      );
    }
    return AppDataPaths._(
      applicationSupportRoot: path,
      environment: environment,
    );
  }

  static const String databaseFileName = 'shiroha_core_v1.db';

  final String applicationSupportRoot;
  final AppDataEnvironment environment;
  final String rootPath;

  String get databaseRoot => p.join(rootPath, 'database');

  String get databasePath => p.join(databaseRoot, databaseFileName);

  /// Root for the existing managed-file storage-key namespace.
  ///
  /// Content assets currently use the `content_assets/...` storage-key
  /// namespace below this same root, so [contentAssetsRoot] is its child and
  /// does not change the existing storage-key layout.
  String get managedFilesRoot => p.join(rootPath, 'library');

  String get contentAssetsRoot => p.join(managedFilesRoot, 'content_assets');

  String get runtimeRoot => p.join(rootPath, 'runtime');

  String get restoreRoot => p.join(runtimeRoot, 'restore');
}

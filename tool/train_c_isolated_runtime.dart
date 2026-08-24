// ignore_for_file: invalid_use_of_visible_for_testing_member

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/core/database/sqflite_runtime.dart';
import 'package:shiroha_quiz/services/file_library/managed_content_asset_store.dart';

import 'train_c_b0_runtime.dart';
import 'train_c_file_storage.dart';

const _markerName = '.train_c_isolated_v1';
const _markerContents = 'train-c-isolated-v1\n';

final class TrainCIsolationException implements Exception {
  const TrainCIsolationException();

  static const String code = 'TRAIN_C_ISOLATION_FAILURE';

  @override
  String toString() => code;
}

final class TrainCBlankStoreProof {
  const TrainCBlankStoreProof({
    required this.questionRows,
    required this.v2Sidecars,
    required this.libraryFiles,
    required this.importTasks,
    required this.contentAssets,
  });

  final int questionRows;
  final int v2Sidecars;
  final int libraryFiles;
  final int importTasks;
  final int contentAssets;

  bool get passed =>
      questionRows == 0 &&
      v2Sidecars == 0 &&
      libraryFiles == 0 &&
      importTasks == 0 &&
      contentAssets == 0;
}

/// Tool-only composition for a newly-created, user-data-free TRAIN C store.
///
/// The runtime owns its root and never accepts a caller-selected directory.
/// All database, managed-file, restore, and export paths are derived from the
/// self-created root and checked for lexical and resolved containment.
final class TrainCIsolatedRuntime {
  TrainCIsolatedRuntime._({required this.root})
      : dbDirectory = Directory(p.join(root.path, 'db')),
        managedDirectory = Directory(p.join(root.path, 'managed')),
        restoreDirectory = Directory(p.join(root.path, 'restore')),
        exportDirectory = Directory(p.join(root.path, 'export')),
        _contentAssetStore = ManagedContentAssetStore(
          managedRoot: Directory(p.join(root.path, 'managed')),
        ),
        _fileStorage = createTrainCManagedFileStorage(
          managedRoot: Directory(p.join(root.path, 'managed')),
        );

  final Directory root;
  final Directory dbDirectory;
  final Directory managedDirectory;
  final Directory restoreDirectory;
  final Directory exportDirectory;
  final ManagedContentAssetStore _contentAssetStore;
  final Object _fileStorage;

  bool _opened = false;
  bool _disposed = false;

  static Future<TrainCIsolatedRuntime> create() async {
    try {
      final root = await Directory.systemTemp.createTemp('shiroha_train_c_');
      final runtime = TrainCIsolatedRuntime._(root: root);
      await runtime._initializeDirectories();
      return runtime;
    } catch (_) {
      throw const TrainCIsolationException();
    }
  }

  /// Closes the current database handle and creates a fresh tool composition
  /// over the same self-owned durable root. The explicit-file profile is kept
  /// intact; no production runtime profile or database is consulted.
  Future<TrainCIsolatedRuntime> reopenFresh() async {
    _ensureUsable();
    final ownedRoot = root;
    await closeForRestart();
    final fresh = await _reopenFromOwnedRoot(ownedRoot);
    _disposed = true;
    return fresh;
  }

  ManagedContentAssetStore get contentAssetStore => _contentAssetStore;

  Object get fileStorage => _fileStorage;

  Future<Database> get database async {
    _ensureUsable();
    if (!_opened) {
      throw const TrainCIsolationException();
    }
    return DatabaseHelper.instance.database;
  }

  Future<void> open() async {
    _ensureUsable();
    if (_opened) return;
    try {
      final dbPath = _containedPath(
        root,
        p.join(dbDirectory.path, DatabaseHelper.databaseFileName),
      );
      if (File(dbPath).existsSync()) {
        throw const TrainCIsolationException();
      }

      // Plain Dart uses the repository's standalone FFI composition. Flutter
      // tests install the same FFI factory in their setUpAll hook.
      if (!Platform.environment.containsKey('FLUTTER_TEST')) {
        initializeStandaloneDatabaseRuntime();
      }
      await databaseFactory.setDatabasesPath(dbDirectory.path);
      DatabaseHelper.configureRuntimeProfile(
        DatabaseRuntimeProfile.explicitFile,
        databasePath: dbDirectory.path,
      );
      await DatabaseHelper.instance.database;

      final openedPath =
          await DatabaseHelper.instance.getProductionDatabasePath();
      if (!_isContained(root, p.normalize(p.absolute(openedPath)))) {
        throw const TrainCIsolationException();
      }
      _opened = true;
    } on TrainCIsolationException {
      rethrow;
    } catch (_) {
      throw const TrainCIsolationException();
    }
  }

  Future<void> reopen() async {
    _ensureUsable();
    if (!_opened) {
      throw const TrainCIsolationException();
    }
    try {
      await DatabaseHelper.instance.database;
      final openedPath =
          await DatabaseHelper.instance.getProductionDatabasePath();
      if (!_isContained(root, p.normalize(p.absolute(openedPath)))) {
        throw const TrainCIsolationException();
      }
    } on TrainCIsolationException {
      rethrow;
    } catch (_) {
      throw const TrainCIsolationException();
    }
  }

  Future<void> closeForRestart() async {
    _ensureUsable();
    if (_opened) {
      await DatabaseHelper.instance.close();
      _opened = false;
    }
  }

  Future<TrainCBlankStoreProof> verifyBlankStore() async {
    _ensureUsable();
    if (!_opened) {
      throw const TrainCIsolationException();
    }
    try {
      final db = await DatabaseHelper.instance.database;
      final proof = TrainCBlankStoreProof(
        questionRows: await _count(db, 'questions'),
        v2Sidecars: await _count(db, 'question_v2_payloads'),
        libraryFiles: await _count(db, 'library_files'),
        importTasks: await _count(db, 'import_tasks'),
        contentAssets: (await _contentAssetStore.listAssets()).length,
      );
      if (!proof.passed) {
        throw const TrainCIsolationException();
      }
      return proof;
    } on TrainCIsolationException {
      rethrow;
    } catch (_) {
      throw const TrainCIsolationException();
    }
  }

  TrainCBackupRuntimePort buildBackupRuntime() {
    _ensureUsable();
    if (!_opened) {
      throw const TrainCIsolationException();
    }
    return createTrainCBackupRuntime(
      databaseHelper: DatabaseHelper.instance,
      managedFileStorage: _fileStorage,
      contentAssetStore: _contentAssetStore,
      restoreRoot: restoreDirectory,
      managedFilesRoot: managedDirectory,
    );
  }

  /// Public only for focused tool tests; no caller may use it to escape the
  /// runtime root.
  String containedPath(String candidate) => _containedPath(root, candidate);

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await DatabaseHelper.resetRuntimeProfileForTesting();
    } finally {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    }
  }

  Future<void> _initializeDirectories() async {
    try {
      if (!await root.exists()) {
        throw const TrainCIsolationException();
      }
      for (final directory in <Directory>[
        dbDirectory,
        managedDirectory,
        restoreDirectory,
        exportDirectory,
      ]) {
        final path = _containedPath(root, directory.path);
        if (await directory.exists()) {
          throw const TrainCIsolationException();
        }
        await Directory(path).create(recursive: true);
      }
      final marker = File(_containedPath(root, p.join(root.path, _markerName)));
      if (await marker.exists()) {
        throw const TrainCIsolationException();
      }
      await marker.writeAsString(_markerContents, flush: true);
    } on TrainCIsolationException {
      rethrow;
    } catch (_) {
      throw const TrainCIsolationException();
    }
  }

  static Future<TrainCIsolatedRuntime> _reopenFromOwnedRoot(
    Directory root,
  ) async {
    try {
      final runtime = TrainCIsolatedRuntime._(root: root);
      await runtime._validateOwnedRoot();
      await runtime._openExistingDatabase();
      return runtime;
    } on TrainCIsolationException {
      rethrow;
    } catch (_) {
      throw const TrainCIsolationException();
    }
  }

  Future<void> _validateOwnedRoot() async {
    if (!await root.exists()) throw const TrainCIsolationException();
    final marker = File(_containedPath(root, p.join(root.path, _markerName)));
    if (!await marker.exists() ||
        await marker.readAsString() != _markerContents) {
      throw const TrainCIsolationException();
    }
    for (final directory in <Directory>[
      dbDirectory,
      managedDirectory,
      restoreDirectory,
      exportDirectory,
    ]) {
      _containedPath(root, directory.path);
      if (!await directory.exists()) {
        throw const TrainCIsolationException();
      }
    }
    final dbPath = _containedPath(
      root,
      p.join(dbDirectory.path, DatabaseHelper.databaseFileName),
    );
    if (!File(dbPath).existsSync()) {
      throw const TrainCIsolationException();
    }
  }

  Future<void> _openExistingDatabase() async {
    if (DatabaseHelper.runtimeProfile != DatabaseRuntimeProfile.explicitFile) {
      throw const TrainCIsolationException();
    }
    if (!Platform.environment.containsKey('FLUTTER_TEST')) {
      initializeStandaloneDatabaseRuntime();
    }
    await databaseFactory.setDatabasesPath(dbDirectory.path);
    await DatabaseHelper.instance.database;
    final openedPath =
        await DatabaseHelper.instance.getProductionDatabasePath();
    final expectedPath = _containedPath(
      root,
      p.join(dbDirectory.path, DatabaseHelper.databaseFileName),
    );
    if (p.normalize(p.absolute(openedPath)) !=
        p.normalize(p.absolute(expectedPath))) {
      throw const TrainCIsolationException();
    }
    _opened = true;
  }

  Future<int> _count(Database db, String table) async {
    final rows = await db.rawQuery('SELECT COUNT(*) AS count FROM $table');
    final value = rows.single['count'];
    if (value is! int) throw const TrainCIsolationException();
    return value;
  }

  void _ensureUsable() {
    if (_disposed) throw const TrainCIsolationException();
  }

  static String _containedPath(Directory root, String candidate) {
    try {
      final candidatePath = p.normalize(p.absolute(candidate));
      if (!_isContained(root, candidatePath)) {
        throw const TrainCIsolationException();
      }

      final canonicalRoot = root.resolveSymbolicLinksSync();
      final existing = _nearestExisting(candidatePath);
      final canonicalExisting = existing.resolveSymbolicLinksSync();
      final suffix = p.relative(candidatePath, from: existing.path);
      final canonicalCandidate = p.normalize(
        p.join(canonicalExisting, suffix),
      );
      if (canonicalCandidate != canonicalRoot &&
          !p.isWithin(canonicalRoot, canonicalCandidate)) {
        throw const TrainCIsolationException();
      }
      return candidatePath;
    } on TrainCIsolationException {
      rethrow;
    } catch (_) {
      throw const TrainCIsolationException();
    }
  }

  static bool _isContained(Directory root, String candidate) {
    final rootPath = p.normalize(p.absolute(root.path));
    final candidatePath = p.normalize(p.absolute(candidate));
    return candidatePath == rootPath || p.isWithin(rootPath, candidatePath);
  }

  static Directory _nearestExisting(String path) {
    var current = Directory(path);
    while (!current.existsSync()) {
      final parent = current.parent;
      if (parent.path == current.path) {
        throw const TrainCIsolationException();
      }
      current = parent;
    }
    return current;
  }
}

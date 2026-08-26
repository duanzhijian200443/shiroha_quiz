// ignore_for_file: invalid_use_of_visible_for_testing_member

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/services/file_library/managed_content_asset_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'train_c_b0_runtime.dart';
import 'train_c_file_storage.dart';
import 'train_c_restart_proof.dart';

const _markerName = '.train_c_isolated_v1';
const _markerContents = 'train-c-isolated-v1\n';
const _reattachCapabilityName = '.train_c_reattach_v1';
const _reattachEnvironmentKey = 'TRAIN_C_REATTACH_CAPABILITY';
const _restartTimeout = Duration(seconds: 30);

void _initializeTrainCDatabaseRuntime() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
}

Map<String, String> buildTrainCRestartChildEnvironment(
  String capability, {
  Map<String, String> parentEnvironment = const <String, String>{},
}) {
  final environment = <String, String>{
    _reattachEnvironmentKey: capability,
  };
  final safeBootstrapKeys = Platform.isWindows
      ? const <String>['SystemRoot', 'WINDIR', 'TEMP', 'TMP']
      : const <String>['TMPDIR', 'LANG', 'LC_ALL'];
  for (final key in safeBootstrapKeys) {
    final value = parentEnvironment[key];
    if (value != null && value.isNotEmpty) {
      environment[key] = value;
    }
  }
  return environment;
}

final class TrainCIsolationException implements Exception {
  const TrainCIsolationException([this.safeDetail]);

  static const String code = 'TRAIN_C_ISOLATION_FAILURE';
  final String? safeDetail;

  @override
  String toString() => safeDetail == null ? code : '$code:$safeDetail';
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
  TrainCIsolatedRuntime._({required this.root, bool deleteRootOnDispose = true})
      : _deleteRootOnDispose = deleteRootOnDispose,
        dbDirectory = Directory(p.join(root.path, 'db')),
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
  final bool _deleteRootOnDispose;

  bool _opened = false;
  bool _disposed = false;
  TrainCOsProcessRestartProof? _osProcessRestartProof;

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

  /// Reattaches to an existing isolated runtime using an opaque capability.
  ///
  /// The capability is issued only by the owning runtime, transported through
  /// the child process environment, and validated against a nonce stored under
  /// the already-owned root. No caller-selected raw path is accepted here.
  static Future<TrainCIsolatedRuntime> reattachFromCapability(
    String capability, {
    bool deleteRootOnDispose = false,
  }) async {
    try {
      late final (String, String) decoded;
      try {
        decoded = _decodeCapability(capability);
      } catch (_) {
        throw const TrainCIsolationException(
          'TRAIN_C_REATTACH_CAPABILITY_INVALID',
        );
      }
      final rootPath = decoded.$1;
      final nonce = decoded.$2;
      if (!p.isAbsolute(rootPath) || nonce.isEmpty) {
        throw const TrainCIsolationException();
      }
      final runtime = TrainCIsolatedRuntime._(
        root: Directory(rootPath),
        deleteRootOnDispose: deleteRootOnDispose,
      );
      try {
        await runtime._validateOwnedRoot();
      } catch (_) {
        throw const TrainCIsolationException(
          'TRAIN_C_REATTACH_ROOT_INVALID',
        );
      }
      final capabilityFile = File(
        _containedPath(
          runtime.root,
          p.join(runtime.root.path, _reattachCapabilityName),
        ),
      );
      if (!await capabilityFile.exists() ||
          await capabilityFile.readAsString() != '$nonce\n') {
        throw const TrainCIsolationException(
          'TRAIN_C_REATTACH_NONCE_INVALID',
        );
      }
      try {
        await runtime._openExistingDatabase(configureRuntimeProfile: true);
      } on TrainCIsolationException {
        rethrow;
      } catch (_) {
        throw const TrainCIsolationException(
          'TRAIN_C_REATTACH_DATABASE_FAILURE',
        );
      }
      return runtime;
    } on TrainCIsolationException {
      rethrow;
    } catch (_) {
      throw const TrainCIsolationException();
    }
  }

  /// Closes the parent runtime, proves that a new OS process can reattach to
  /// the same durable root, then returns a fresh parent-side composition.
  ///
  /// The child process emits only counts plus a digest and performs zero
  /// provider dispatches. Final acceptance can therefore reject any runtime
  /// that was reopened only inside the original Dart process.
  Future<TrainCIsolatedRuntime> reopenFresh() async {
    _ensureUsable();
    final capability = await _issueReattachCapability();
    final preCloseCheckpoint = await captureTrainCDurableRestartCheckpoint(
      database: await database,
      managedDirectory: managedDirectory,
    );
    await closeForRestart();
    final processProof = await _runProcessRestartProbe(
      capability,
      preCloseCheckpoint,
    );
    final fresh = await _reattachInOriginalProcess(capability);
    final parentCheckpoint = await captureTrainCDurableRestartCheckpoint(
      database: await fresh.database,
      managedDirectory: fresh.managedDirectory,
    );
    if (!preCloseCheckpoint.equivalentTo(parentCheckpoint) ||
        !processProof.matches(parentCheckpoint)) {
      throw const TrainCRestartException(trainCRestartStateMismatch);
    }
    await fresh._consumeReattachCapability();
    fresh._osProcessRestartProof = processProof;
    _disposed = true;
    return fresh;
  }

  ManagedContentAssetStore get contentAssetStore => _contentAssetStore;

  Object get fileStorage => _fileStorage;

  TrainCOsProcessRestartProof? get osProcessRestartProof =>
      _osProcessRestartProof;

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

      _initializeTrainCDatabaseRuntime();
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

  /// Issues a durable reattach capability for the TRAIN C phase controller.
  ///
  /// Unlike [reopenFresh], this capability remains present across the
  /// pending-review/commit/B0 process boundaries. The caller must keep the
  /// returned opaque token inside the repo-external TRAIN-C control artifact;
  /// it must not be logged or included in evidence.
  Future<String> issuePersistentReattachCapability() async {
    _ensureUsable();
    return _issueReattachCapability();
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
      if (_deleteRootOnDispose && await root.exists()) {
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

  Future<String> _issueReattachCapability() async {
    final nonce = _secureNonce();
    final capabilityFile = File(
      _containedPath(root, p.join(root.path, _reattachCapabilityName)),
    );
    if (await capabilityFile.exists()) {
      throw const TrainCIsolationException();
    }
    await capabilityFile.writeAsString('$nonce\n', flush: true);
    return base64UrlEncode(
      utf8.encode(
        jsonEncode(<String, String>{
          'root': p.normalize(p.absolute(root.path)),
          'nonce': nonce,
        }),
      ),
    );
  }

  Future<TrainCOsProcessRestartProof> _runProcessRestartProbe(
    String capability,
    TrainCDurableRestartCheckpoint expectedCheckpoint,
  ) async {
    final bootstrap = await _resolveRestartBootstrap();
    return runTrainCRestartProcess(
      timeout: _restartTimeout,
      parentPid: pid,
      expectedCheckpoint: expectedCheckpoint,
      start: () async {
        final process = await Process.start(
          bootstrap.dartExecutable,
          <String>[
            '--packages=${bootstrap.packageConfigPath}',
            'run',
            '--verbosity=error',
            bootstrap.scriptPath,
            '--child',
          ],
          workingDirectory: bootstrap.packageRoot,
          environment: buildTrainCRestartChildEnvironment(
            capability,
            parentEnvironment: Platform.environment,
          ),
          includeParentEnvironment: false,
          runInShell: false,
        );
        return (
          stdout: process.stdout,
          stderr: process.stderr,
          exitCode: process.exitCode,
          kill: process.kill,
        );
      },
    );
  }

  static Future<TrainCIsolatedRuntime> _reattachInOriginalProcess(
    String capability,
  ) async {
    try {
      final decoded = _decodeCapability(capability);
      final runtime = TrainCIsolatedRuntime._(
        root: Directory(decoded.$1),
        deleteRootOnDispose: true,
      );
      await runtime._validateOwnedRoot();
      final capabilityFile = File(
        _containedPath(
          runtime.root,
          p.join(runtime.root.path, _reattachCapabilityName),
        ),
      );
      if (!await capabilityFile.exists() ||
          await capabilityFile.readAsString() != '${decoded.$2}\n') {
        throw const TrainCIsolationException();
      }
      await runtime._openExistingDatabase(configureRuntimeProfile: false);
      return runtime;
    } on TrainCIsolationException {
      rethrow;
    } catch (_) {
      throw const TrainCIsolationException();
    }
  }

  Future<void> _consumeReattachCapability() async {
    final capabilityFile = File(
      _containedPath(root, p.join(root.path, _reattachCapabilityName)),
    );
    if (!await capabilityFile.exists()) {
      throw const TrainCIsolationException();
    }
    await capabilityFile.delete();
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

  Future<void> _openExistingDatabase({
    required bool configureRuntimeProfile,
  }) async {
    if (configureRuntimeProfile) {
      try {
        _initializeTrainCDatabaseRuntime();
      } catch (_) {
        throw const TrainCIsolationException(
          'TRAIN_C_REATTACH_DATABASE_INIT_FAILURE',
        );
      }
      try {
        await databaseFactory.setDatabasesPath(dbDirectory.path);
      } catch (_) {
        throw const TrainCIsolationException(
          'TRAIN_C_REATTACH_DATABASE_PATH_FAILURE',
        );
      }
      try {
        DatabaseHelper.configureRuntimeProfile(
          DatabaseRuntimeProfile.explicitFile,
          databasePath: dbDirectory.path,
        );
      } catch (_) {
        throw const TrainCIsolationException(
          'TRAIN_C_REATTACH_DATABASE_PROFILE_FAILURE',
        );
      }
    }
    try {
      await DatabaseHelper.instance.database;
    } catch (_) {
      throw const TrainCIsolationException(
        'TRAIN_C_REATTACH_DATABASE_OPEN_FAILURE',
      );
    }
    final openedPath =
        await DatabaseHelper.instance.getProductionDatabasePath();
    final expectedPath = _containedPath(
      root,
      p.join(dbDirectory.path, DatabaseHelper.databaseFileName),
    );
    if (p.normalize(p.absolute(openedPath)) !=
        p.normalize(p.absolute(expectedPath))) {
      throw const TrainCIsolationException(
        'TRAIN_C_REATTACH_DATABASE_IDENTITY_FAILURE',
      );
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

  static (String, String) _decodeCapability(String capability) {
    try {
      final decoded = jsonDecode(utf8.decode(base64Url.decode(capability)));
      if (decoded is! Map) throw const TrainCIsolationException();
      final root = decoded['root'];
      final nonce = decoded['nonce'];
      if (root is! String || nonce is! String) {
        throw const TrainCIsolationException();
      }
      return (root, nonce);
    } on TrainCIsolationException {
      rethrow;
    } catch (_) {
      throw const TrainCIsolationException();
    }
  }

  static String _secureNonce() {
    final random = Random.secure();
    final buffer = StringBuffer();
    for (var index = 0; index < 32; index++) {
      buffer.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  static Future<_TrainCRestartBootstrap> _resolveRestartBootstrap() async {
    try {
      String? packageArgument;
      for (final argument in Platform.executableArguments) {
        if (argument.startsWith('--packages=')) {
          packageArgument = argument.substring('--packages='.length);
          break;
        }
      }
      if (packageArgument == null || packageArgument.isEmpty) {
        throw const TrainCRestartException(trainCRestartProcessStartFailure);
      }
      final parsedArgument = Uri.tryParse(packageArgument);
      final packageConfigUri = parsedArgument?.scheme == 'file'
          ? parsedArgument!
          : p.isAbsolute(packageArgument)
              ? Uri.file(packageArgument)
              : null;
      if (packageConfigUri == null) {
        throw const TrainCRestartException(trainCRestartProcessStartFailure);
      }
      final packageConfigFile = File(packageConfigUri.toFilePath());
      if (!packageConfigFile.existsSync()) {
        throw const TrainCRestartException(trainCRestartProcessStartFailure);
      }
      final decoded = jsonDecode(packageConfigFile.readAsStringSync());
      if (decoded is! Map || decoded['packages'] is! List) {
        throw const TrainCRestartException(trainCRestartProcessStartFailure);
      }
      final packages = decoded['packages'] as List;
      final packageRoot = _packageDirectory(
        packages,
        packageConfigUri,
        'shiroha_quiz',
      );
      final flutterPackageDirectory = _packageDirectory(
        packages,
        packageConfigUri,
        'flutter',
      );
      final script = File(
        p.join(packageRoot.path, 'tool', 'train_c_restart_probe.dart'),
      );
      final pubspec = File(p.join(packageRoot.path, 'pubspec.yaml'));
      final childPackageConfig = File(
        p.join(packageRoot.path, '.dart_tool', 'package_config.json'),
      );
      if (!script.existsSync() ||
          !pubspec.existsSync() ||
          !childPackageConfig.existsSync()) {
        throw const TrainCRestartException(trainCRestartProcessStartFailure);
      }
      final dartExecutable = _dartExecutableFromPackageConfig(
        flutterPackageDirectory,
      );
      return _TrainCRestartBootstrap(
        dartExecutable: dartExecutable,
        packageConfigPath: childPackageConfig.path,
        packageRoot: packageRoot.path,
        scriptPath: script.path,
      );
    } on TrainCRestartException {
      rethrow;
    } catch (_) {
      throw const TrainCRestartException(trainCRestartProcessStartFailure);
    }
  }

  static String _dartExecutableFromPackageConfig(
    Directory flutterPackageDirectory,
  ) {
    final resolved = Platform.resolvedExecutable;
    final name = p.basenameWithoutExtension(resolved).toLowerCase();
    if (name == 'dart' && File(resolved).existsSync()) return resolved;

    final flutterSdkRoot = flutterPackageDirectory.parent.parent;
    final executable = p.join(
      flutterSdkRoot.path,
      'bin',
      'cache',
      'dart-sdk',
      'bin',
      Platform.isWindows ? 'dart.exe' : 'dart',
    );
    if (!File(executable).existsSync()) {
      throw const TrainCRestartException(trainCRestartProcessStartFailure);
    }
    return executable;
  }

  static Directory _packageDirectory(
    List<dynamic> packages,
    Uri packageConfigUri,
    String packageName,
  ) {
    for (final entry in packages) {
      if (entry is Map && entry['name'] == packageName) {
        final rootUri = entry['rootUri'];
        if (rootUri is String) {
          final resolved = packageConfigUri.resolve(rootUri);
          if (resolved.scheme == 'file') {
            return Directory(resolved.toFilePath());
          }
        }
        break;
      }
    }
    throw const TrainCRestartException(trainCRestartProcessStartFailure);
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
      final canonicalCandidate = p.normalize(p.join(canonicalExisting, suffix));
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

final class _TrainCRestartBootstrap {
  const _TrainCRestartBootstrap({
    required this.dartExecutable,
    required this.packageConfigPath,
    required this.packageRoot,
    required this.scriptPath,
  });

  final String dartExecutable;
  final String packageConfigPath;
  final String packageRoot;
  final String scriptPath;
}

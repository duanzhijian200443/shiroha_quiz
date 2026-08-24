import 'dart:convert';

import 'archive_path_policy.dart';
import 'backup_failure.dart';
import 'backup_values.dart';

final class BackupDatabaseEntry {
  const BackupDatabaseEntry({
    required this.archivePath,
    required this.sizeBytes,
    required this.sha256,
  });

  factory BackupDatabaseEntry.fromJson(Map<String, Object?> json) {
    final archivePath = _requiredString(json, 'archivePath');
    final sizeBytes = _requiredInt(json, 'sizeBytes');
    final sha256 = _requiredString(json, 'sha256');
    if (archivePath != BackupValues.databaseArchivePath ||
        sizeBytes < 0 ||
        sizeBytes > BackupValues.databaseMaxDeclaredSizeBytes ||
        !_isSha256(sha256)) {
      throw const BackupException(BackupFailure.manifestInvalid);
    }
    return BackupDatabaseEntry(
      archivePath: archivePath,
      sizeBytes: sizeBytes,
      sha256: sha256,
    );
  }

  final String archivePath;
  final int sizeBytes;
  final String sha256;

  Map<String, Object?> toJson() => <String, Object?>{
        'archivePath': archivePath,
        'sizeBytes': sizeBytes,
        'sha256': sha256,
      };
}

final class BackupManagedFileEntry {
  const BackupManagedFileEntry({
    required this.fileId,
    required this.storageKey,
    required this.archivePath,
    required this.sizeBytes,
    required this.sha256,
  });

  factory BackupManagedFileEntry.fromJson(Map<String, Object?> json) {
    final fileId = _requiredString(json, 'fileId');
    final storageKey = _requiredString(json, 'storageKey');
    final archivePath = _requiredString(json, 'archivePath');
    final sizeBytes = _requiredInt(json, 'sizeBytes');
    final sha256 = _requiredString(json, 'sha256');
    if (!_isSafeFileId(fileId) ||
        !ArchivePathPolicy.isSafeManagedStorageKey(storageKey) ||
        archivePath != BackupValues.managedArchivePath(fileId) ||
        sizeBytes < 0 ||
        sizeBytes > BackupValues.singleManagedFileMaxDeclaredSizeBytes ||
        !_isSha256(sha256)) {
      throw const BackupException(BackupFailure.manifestInvalid);
    }
    return BackupManagedFileEntry(
      fileId: fileId,
      storageKey: storageKey,
      archivePath: archivePath,
      sizeBytes: sizeBytes,
      sha256: sha256,
    );
  }

  final String fileId;
  final String storageKey;
  final String archivePath;
  final int sizeBytes;
  final String sha256;

  Map<String, Object?> toJson() => <String, Object?>{
        'fileId': fileId,
        'storageKey': storageKey,
        'archivePath': archivePath,
        'sizeBytes': sizeBytes,
        'sha256': sha256,
      };
}

final class BackupContentAssetEntry {
  const BackupContentAssetEntry({
    required this.sourceId,
    required this.localAssetId,
    required this.storageKey,
    required this.archivePath,
    required this.sizeBytes,
    required this.sha256,
  });

  factory BackupContentAssetEntry.fromJson(Map<String, Object?> json) {
    final sourceId = _requiredString(json, 'sourceId');
    final localAssetId = _requiredString(json, 'localAssetId');
    final storageKey = _requiredString(json, 'storageKey');
    final archivePath = _requiredString(json, 'archivePath');
    final sizeBytes = _requiredInt(json, 'sizeBytes');
    final sha256 = _requiredString(json, 'sha256');
    if (!_isSafeFileId(sourceId) ||
        !_isSafeFileId(localAssetId) ||
        storageKey != 'content_assets/$sourceId/$localAssetId' ||
        !ArchivePathPolicy.isSafeManagedStorageKey(storageKey) ||
        archivePath !=
            BackupValues.contentAssetArchivePath(
              sourceId: sourceId,
              localAssetId: localAssetId,
            ) ||
        sizeBytes < 1 ||
        sizeBytes > BackupValues.singleManagedFileMaxDeclaredSizeBytes ||
        !_isSha256(sha256)) {
      throw const BackupException(BackupFailure.manifestInvalid);
    }
    return BackupContentAssetEntry(
      sourceId: sourceId,
      localAssetId: localAssetId,
      storageKey: storageKey,
      archivePath: archivePath,
      sizeBytes: sizeBytes,
      sha256: sha256,
    );
  }

  final String sourceId;
  final String localAssetId;
  final String storageKey;
  final String archivePath;
  final int sizeBytes;
  final String sha256;

  Map<String, Object?> toJson() => <String, Object?>{
        'sourceId': sourceId,
        'localAssetId': localAssetId,
        'storageKey': storageKey,
        'archivePath': archivePath,
        'sizeBytes': sizeBytes,
        'sha256': sha256,
      };
}

final class BackupManifest {
  const BackupManifest({
    required this.schemaVersion,
    required this.createdAtUtc,
    required this.database,
    required this.managedFiles,
    this.packageVersion = BackupValues.packageVersion,
    this.contentAssets = const <BackupContentAssetEntry>[],
  });

  factory BackupManifest.fromJsonString(String source) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      throw const BackupException(BackupFailure.manifestInvalid);
    }
    if (decoded is! Map<String, Object?>) {
      throw const BackupException(BackupFailure.manifestInvalid);
    }
    return BackupManifest.fromJson(decoded);
  }

  factory BackupManifest.fromJson(Map<String, Object?> json) {
    final keys = json.keys.toSet();
    const requiredKeys = <String>{
      'format',
      'packageVersion',
      'schemaVersion',
      'createdAtUtc',
      'database',
      'managedFiles',
    };
    const optionalKeys = <String>{'contentAssets'};
    if (!keys.containsAll(requiredKeys) ||
        keys.difference(requiredKeys).difference(optionalKeys).isNotEmpty) {
      throw const BackupException(BackupFailure.manifestInvalid);
    }
    if (json['format'] != BackupValues.format) {
      throw const BackupException(BackupFailure.invalidPackage);
    }
    final packageVersion = _requiredInt(json, 'packageVersion');
    if (packageVersion != BackupValues.packageVersion &&
        packageVersion != BackupValues.currentPackageVersion) {
      throw const BackupException(BackupFailure.unsupportedPackageVersion);
    }
    final schemaVersion = _requiredInt(json, 'schemaVersion');
    if (schemaVersion < 1) {
      throw const BackupException(BackupFailure.manifestInvalid);
    }
    final createdAtUtc = _requiredString(json, 'createdAtUtc');
    final created = DateTime.tryParse(createdAtUtc);
    if (created == null || !created.isUtc) {
      throw const BackupException(BackupFailure.manifestInvalid);
    }
    final databaseJson = json['database'];
    final filesJson = json['managedFiles'];
    final assetsJson = json['contentAssets'];
    if (packageVersion < BackupValues.contentAssetPackageVersion &&
        assetsJson != null) {
      throw const BackupException(BackupFailure.unsupportedPackageVersion);
    }
    if (databaseJson is! Map<String, Object?> ||
        filesJson is! List<Object?> ||
        (assetsJson != null && assetsJson is! List<Object?>)) {
      throw const BackupException(BackupFailure.manifestInvalid);
    }
    final assetItems =
        assetsJson is List<Object?> ? assetsJson : const <Object?>[];

    final database = BackupDatabaseEntry.fromJson(databaseJson);
    final files = <BackupManagedFileEntry>[];
    final fileIds = <String>{};
    final storageKeys = <String>{};
    final archivePaths = <String>{};
    final assetIdentities = <String>{};
    var totalSize = database.sizeBytes;
    for (final item in filesJson) {
      if (item is! Map<String, Object?>) {
        throw const BackupException(BackupFailure.manifestInvalid);
      }
      final file = BackupManagedFileEntry.fromJson(item);
      if (!fileIds.add(file.fileId) ||
          !storageKeys.add(file.storageKey) ||
          !archivePaths.add(file.archivePath)) {
        throw const BackupException(BackupFailure.duplicateArchiveEntry);
      }
      totalSize += file.sizeBytes;
      if (files.length >= BackupValues.maxArchiveEntries) {
        throw const BackupException(BackupFailure.resourceLimitExceeded);
      }
      files.add(file);
    }
    final contentAssets = <BackupContentAssetEntry>[];
    for (final item in assetItems) {
      if (item is! Map<String, Object?>) {
        throw const BackupException(BackupFailure.manifestInvalid);
      }
      final asset = BackupContentAssetEntry.fromJson(item);
      final identity = '${asset.sourceId}\u0000${asset.localAssetId}';
      if (!assetIdentities.add(identity) ||
          !storageKeys.add(asset.storageKey) ||
          !archivePaths.add(asset.archivePath)) {
        throw const BackupException(BackupFailure.duplicateArchiveEntry);
      }
      totalSize += asset.sizeBytes;
      if (files.length + contentAssets.length >=
          BackupValues.maxArchiveEntries) {
        throw const BackupException(BackupFailure.resourceLimitExceeded);
      }
      contentAssets.add(asset);
    }
    if (totalSize > BackupValues.packageMaxDeclaredUncompressedBytes) {
      throw const BackupException(BackupFailure.resourceLimitExceeded);
    }
    if (files.length + contentAssets.length + 2 >
        BackupValues.maxArchiveEntries) {
      throw const BackupException(BackupFailure.resourceLimitExceeded);
    }
    return BackupManifest(
      packageVersion: packageVersion,
      schemaVersion: schemaVersion,
      createdAtUtc: created.toUtc(),
      database: database,
      managedFiles: List<BackupManagedFileEntry>.unmodifiable(files),
      contentAssets: List<BackupContentAssetEntry>.unmodifiable(contentAssets),
    );
  }

  final int schemaVersion;
  final int packageVersion;
  final DateTime createdAtUtc;
  final BackupDatabaseEntry database;
  final List<BackupManagedFileEntry> managedFiles;
  final List<BackupContentAssetEntry> contentAssets;

  int get managedFileCount => managedFiles.length;
  int get contentAssetCount => contentAssets.length;
  int get totalEntryCount => managedFiles.length + contentAssets.length;
  int get totalDeclaredBytes =>
      database.sizeBytes +
      managedFiles.fold<int>(0, (sum, file) => sum + file.sizeBytes) +
      contentAssets.fold<int>(0, (sum, asset) => sum + asset.sizeBytes);

  Map<String, Object?> toJson() {
    final result = <String, Object?>{
      'format': BackupValues.format,
      'packageVersion': packageVersion,
      'schemaVersion': schemaVersion,
      'createdAtUtc': createdAtUtc.toUtc().toIso8601String(),
      'database': database.toJson(),
      'managedFiles':
          managedFiles.map((file) => file.toJson()).toList(growable: false),
    };
    if (contentAssets.isNotEmpty &&
        packageVersion < BackupValues.contentAssetPackageVersion) {
      throw const BackupException(BackupFailure.unsupportedPackageVersion);
    }
    if (contentAssets.isNotEmpty) {
      result['contentAssets'] =
          contentAssets.map((asset) => asset.toJson()).toList(growable: false);
    }
    return result;
  }

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());
}

final class BackupException implements Exception {
  const BackupException(this.failure, [this.diagnosticId]);

  final BackupFailure failure;
  final String? diagnosticId;

  @override
  String toString() => 'BackupException(${failure.name})';
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String) {
    throw const BackupException(BackupFailure.manifestInvalid);
  }
  return value;
}

int _requiredInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! int) throw const BackupException(BackupFailure.manifestInvalid);
  return value;
}

bool _isSha256(String value) => RegExp(r'^[0-9a-f]{64}$').hasMatch(value);
bool _isSafeFileId(String value) =>
    RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(value);

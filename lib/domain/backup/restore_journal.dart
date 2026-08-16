import 'dart:convert';

import 'archive_path_policy.dart';
import 'backup_failure.dart';
import 'backup_manifest.dart';
import 'backup_values.dart';

enum RestoreJournalState {
  prepared('PREPARED'),
  swapping('SWAPPING'),
  committed('COMMITTED'),
  rollingBack('ROLLING_BACK'),
  rolledBack('ROLLED_BACK'),
  rollbackFailed('ROLLBACK_FAILED');

  const RestoreJournalState(this.wireName);
  final String wireName;

  static RestoreJournalState parse(Object? value) {
    return RestoreJournalState.values.firstWhere(
      (state) => state.wireName == value,
      orElse: () => throw const BackupException(BackupFailure.journalInvalid),
    );
  }
}

final class RestoreJournal {
  const RestoreJournal({
    required this.version,
    required this.operationId,
    required this.format,
    required this.packageVersion,
    required this.schemaVersion,
    required this.packageDigest,
    required this.state,
    required this.updatedAtUtc,
    required this.stagingKey,
    required this.rollbackDbKey,
    required this.rollbackFilesKey,
    this.fileCount,
    this.databaseSizeBytes,
    this.managedBytes,
  });

  factory RestoreJournal.fromJsonString(String source) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      throw const BackupException(BackupFailure.journalInvalid);
    }
    if (decoded is! Map<String, Object?>) {
      throw const BackupException(BackupFailure.journalInvalid);
    }
    return RestoreJournal.fromJson(decoded);
  }

  factory RestoreJournal.fromJson(Map<String, Object?> json) {
    final keys = json.keys.toSet();
    const requiredKeys = <String>{
      'version',
      'operationId',
      'format',
      'packageVersion',
      'schemaVersion',
      'packageDigest',
      'state',
      'updatedAtUtc',
      'stagingKey',
      'rollbackDbKey',
      'rollbackFilesKey',
    };
    if (!keys.containsAll(requiredKeys) || keys.length != requiredKeys.length) {
      throw const BackupException(BackupFailure.journalInvalid);
    }
    final version = json['version'];
    if (version != 1) {
      throw const BackupException(BackupFailure.journalInvalid);
    }
    final operationId = json['operationId'];
    final format = json['format'];
    final packageVersion = json['packageVersion'];
    final schemaVersion = json['schemaVersion'];
    final packageDigest = json['packageDigest'];
    final updatedAtUtc = json['updatedAtUtc'];
    final stagingKey = json['stagingKey'];
    final rollbackDbKey = json['rollbackDbKey'];
    final rollbackFilesKey = json['rollbackFilesKey'];
    if (operationId is! String ||
        !_isSafeToken(operationId) ||
        format != BackupValues.format ||
        packageVersion is! int ||
        schemaVersion is! int ||
        packageDigest is! String ||
        !_isSha256(packageDigest) ||
        updatedAtUtc is! String ||
        DateTime.tryParse(updatedAtUtc) == null ||
        stagingKey is! String ||
        !ArchivePathPolicy.isSafeArchivePath(stagingKey) ||
        rollbackDbKey is! String ||
        !ArchivePathPolicy.isSafeArchivePath(rollbackDbKey) ||
        rollbackFilesKey is! String ||
        !ArchivePathPolicy.isSafeArchivePath(rollbackFilesKey)) {
      throw const BackupException(BackupFailure.journalInvalid);
    }
    final state = RestoreJournalState.parse(json['state']);
    final fileCount = json['fileCount'];
    final databaseSizeBytes = json['databaseSizeBytes'];
    final managedBytes = json['managedBytes'];
    if ((fileCount != null && fileCount is! int) ||
        (databaseSizeBytes != null && databaseSizeBytes is! int) ||
        (managedBytes != null && managedBytes is! int)) {
      throw const BackupException(BackupFailure.journalInvalid);
    }
    return RestoreJournal(
      version: version as int,
      operationId: operationId,
      format: format as String,
      packageVersion: packageVersion,
      schemaVersion: schemaVersion,
      packageDigest: packageDigest,
      state: state,
      updatedAtUtc: DateTime.parse(updatedAtUtc),
      stagingKey: stagingKey,
      rollbackDbKey: rollbackDbKey,
      rollbackFilesKey: rollbackFilesKey,
      fileCount: fileCount as int?,
      databaseSizeBytes: databaseSizeBytes as int?,
      managedBytes: managedBytes as int?,
    );
  }

  final int version;
  final String operationId;
  final String format;
  final int packageVersion;
  final int schemaVersion;
  final String packageDigest;
  final RestoreJournalState state;
  final DateTime updatedAtUtc;
  final String stagingKey;
  final String rollbackDbKey;
  final String rollbackFilesKey;
  final int? fileCount;
  final int? databaseSizeBytes;
  final int? managedBytes;

  RestoreJournal copyWithState(
    RestoreJournalState state, {
    DateTime? updatedAtUtc,
  }) {
    return RestoreJournal(
      version: version,
      operationId: operationId,
      format: format,
      packageVersion: packageVersion,
      schemaVersion: schemaVersion,
      packageDigest: packageDigest,
      state: state,
      updatedAtUtc: updatedAtUtc ?? DateTime.now().toUtc(),
      stagingKey: stagingKey,
      rollbackDbKey: rollbackDbKey,
      rollbackFilesKey: rollbackFilesKey,
      fileCount: fileCount,
      databaseSizeBytes: databaseSizeBytes,
      managedBytes: managedBytes,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'version': version,
        'operationId': operationId,
        'format': format,
        'packageVersion': packageVersion,
        'schemaVersion': schemaVersion,
        'packageDigest': packageDigest,
        'state': state.wireName,
        'updatedAtUtc': updatedAtUtc.toUtc().toIso8601String(),
        'stagingKey': stagingKey,
        'rollbackDbKey': rollbackDbKey,
        'rollbackFilesKey': rollbackFilesKey,
        'fileCount': fileCount,
        'databaseSizeBytes': databaseSizeBytes,
        'managedBytes': managedBytes,
      };

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());
}

bool _isSafeToken(String value) =>
    value.length <= 128 &&
    RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$').hasMatch(value);
bool _isSha256(String value) => RegExp(r'^[0-9a-f]{64}$').hasMatch(value);

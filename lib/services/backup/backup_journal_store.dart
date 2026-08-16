import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../domain/backup/backup_failure.dart';
import '../../domain/backup/backup_manifest.dart';
import '../../domain/backup/restore_journal.dart';
import 'backup_filesystem.dart';

final class BackupJournalStore {
  /// [keyRoot] owns the safe relative keys stored in the journal; the JSON
  /// file itself lives under [keyRoot]/journal/journal.json so it is outside
  /// every swapped root but keys resolve against the same root that runtime
  /// paths are created under.
  BackupJournalStore({required Directory keyRoot})
      : _keyRoot = keyRoot,
        _journalPath = p.join(keyRoot.path, 'journal', 'journal.json');

  final Directory _keyRoot;
  final String _journalPath;
  String get _tombstonePath => '$_journalPath.tombstone';

  String get journalPath => _journalPath;

  Future<RestoreJournal?> read() async {
    final tombstone = File(_tombstonePath);
    if (await tombstone.exists()) {
      await _consumeClearMarker(tombstone);
    }
    return _readJournal();
  }

  Future<RestoreJournal?> _readJournal() async {
    final file = File(_journalPath);
    final backup = File('$_journalPath.bak');
    final sourceFile = await file.exists()
        ? file
        : await backup.exists()
            ? backup
            : null;
    if (sourceFile == null) return null;
    final source = await sourceFile.readAsString();
    return RestoreJournal.fromJsonString(source);
  }

  Future<void> write(RestoreJournal journal) {
    return BackupFilesystem.atomicWriteString(
      _journalPath,
      journal.encode(),
    );
  }

  Future<void> clear() async {
    // Crash-safe clear order: publish a durable, generation-bound marker
    // before deleting either journal generation. A later journal write is
    // therefore preserved when startup consumes an old marker.
    final marker = _ClearMarker(
      journalSha256: _digestIfPresent(_journalPath),
      backupSha256: _digestIfPresent('$_journalPath.bak'),
    );
    await BackupFilesystem.atomicWriteString(
      _tombstonePath,
      marker.encode(),
    );
    await _deleteIfMatches(_journalPath, marker.journalSha256);
    await _deleteIfMatches('$_journalPath.bak', marker.backupSha256);
    await _removeClearMarker();
  }

  Future<void> _consumeClearMarker(File tombstone) async {
    final source = await tombstone.readAsString();
    final marker = _ClearMarker.tryParse(source);
    if (marker == null) {
      // Compatibility with the literal marker emitted by the first B0
      // implementation. It has no generation identity, so fail closed by
      // removing both stale journal generations exactly once.
      if (source != 'tombstone') {
        throw const BackupException(BackupFailure.journalInvalid);
      }
      await _deleteIfPresent(_journalPath);
      await _deleteIfPresent('$_journalPath.bak');
    } else {
      await _deleteIfMatches(_journalPath, marker.journalSha256);
      await _deleteIfMatches('$_journalPath.bak', marker.backupSha256);
    }
    await _removeClearMarker();
  }

  String? _digestIfPresent(String path) {
    final file = File(path);
    return file.existsSync() ? BackupFilesystem.sha256File(path) : null;
  }

  Future<void> _deleteIfMatches(String path, String? expectedSha256) async {
    if (expectedSha256 == null) return;
    final file = File(path);
    if (!await file.exists()) return;
    if (_digestIfPresent(path) != expectedSha256) return;
    await file.delete();
  }

  Future<void> _deleteIfPresent(String path) async {
    final file = File(path);
    if (await file.exists()) await file.delete();
  }

  Future<void> _removeClearMarker() async {
    await _deleteIfPresent(_tombstonePath);
    await _deleteIfPresent('$_tombstonePath.bak');
  }

  String resolveKey(String key) {
    final root = p.normalize(p.absolute(_keyRoot.path));
    final resolved = p.normalize(p.absolute(p.join(root, key)));
    if (!p.isWithin(root, resolved) && resolved != root) {
      throw const BackupException(BackupFailure.unsafeArchivePath);
    }
    return resolved;
  }

  /// Strict local DTO boundaries are enforced by [RestoreJournal.fromJson].
  /// This helper exists only to keep the runtime free of raw json maps.
  static Map<String, Object?> jsonFromJournal(RestoreJournal journal) {
    return journal.toJson();
  }

  static String decodeString(Map<String, Object?> json, String key) {
    final value = json[key];
    if (value is! String) {
      throw const BackupException(BackupFailure.journalInvalid);
    }
    return value;
  }
}

final class _ClearMarker {
  const _ClearMarker({
    required this.journalSha256,
    required this.backupSha256,
  });

  final String? journalSha256;
  final String? backupSha256;

  static _ClearMarker? tryParse(String source) {
    if (source == 'tombstone') return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      throw const BackupException(BackupFailure.journalInvalid);
    }
    const requiredKeys = <String>{
      'version',
      'journalSha256',
      'backupSha256',
    };
    if (decoded is! Map<String, Object?> ||
        decoded.length != requiredKeys.length ||
        !decoded.keys.toSet().containsAll(requiredKeys) ||
        decoded['version'] != 1) {
      throw const BackupException(BackupFailure.journalInvalid);
    }
    final journalSha256 = decoded['journalSha256'];
    final backupSha256 = decoded['backupSha256'];
    if (!_validDigestOrNull(journalSha256) ||
        !_validDigestOrNull(backupSha256)) {
      throw const BackupException(BackupFailure.journalInvalid);
    }
    return _ClearMarker(
      journalSha256: journalSha256 as String?,
      backupSha256: backupSha256 as String?,
    );
  }

  String encode() => jsonEncode(<String, Object?>{
        'version': 1,
        'journalSha256': journalSha256,
        'backupSha256': backupSha256,
      });

  static bool _validDigestOrNull(Object? value) {
    return value == null ||
        (value is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(value));
  }
}

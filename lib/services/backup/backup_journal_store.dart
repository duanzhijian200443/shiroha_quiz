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

  String get journalPath => _journalPath;

  Future<RestoreJournal?> read() async {
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
    for (final path in <String>[_journalPath, '$_journalPath.bak']) {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    }
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

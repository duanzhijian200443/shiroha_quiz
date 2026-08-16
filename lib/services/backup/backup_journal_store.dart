import 'dart:io';

import 'package:path/path.dart' as p;

import '../../domain/backup/backup_failure.dart';
import '../../domain/backup/backup_manifest.dart';
import '../../domain/backup/restore_journal.dart';
import 'backup_filesystem.dart';

final class BackupJournalStore {
  BackupJournalStore({required Directory journalRoot})
      : _journalPath = p.join(journalRoot.path, 'journal.json'),
        _root = journalRoot;

  final String _journalPath;
  final Directory _root;

  String get journalPath => _journalPath;

  Future<RestoreJournal?> read() async {
    final file = File(_journalPath);
    if (!await file.exists()) return null;
    final source = await file.readAsString();
    return RestoreJournal.fromJsonString(source);
  }

  Future<void> write(RestoreJournal journal) {
    return BackupFilesystem.atomicWriteString(
      _journalPath,
      journal.encode(),
    );
  }

  Future<void> clear() async {
    final file = File(_journalPath);
    if (await file.exists()) {
      await file.delete();
    }
  }

  String resolveKey(String key) {
    final root = p.normalize(p.absolute(_root.path));
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

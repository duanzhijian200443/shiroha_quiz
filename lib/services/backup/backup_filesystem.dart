import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../domain/backup/backup_failure.dart';
import '../../domain/backup/backup_manifest.dart';
import 'sha256.dart';

abstract final class BackupFilesystem {
  static const int chunkSize = 1024 * 1024;

  static String sha256File(String path) {
    final file = File(path).openSync();
    try {
      final hasher = StreamingSha256();
      final chunk = Uint8List(chunkSize);
      while (true) {
        final read = file.readIntoSync(chunk);
        if (read <= 0) break;
        hasher.update(chunk, 0, read);
      }
      return hasher.digestHex();
    } finally {
      file.closeSync();
    }
  }

  static Future<({int sizeBytes, String sha256})> copyAndMeasure({
    required String sourcePath,
    required String targetPath,
  }) async {
    await File(targetPath).parent.create(recursive: true);
    final source = File(sourcePath);
    final target = await File(targetPath).open(mode: FileMode.write);
    final hasher = StreamingSha256();
    var sizeBytes = 0;
    try {
      final input = await source.open(mode: FileMode.read);
      try {
        final chunk = Uint8List(chunkSize);
        while (true) {
          final read = await input.readInto(chunk);
          if (read <= 0) break;
          target.writeFromSync(chunk, 0, read);
          hasher.update(chunk, 0, read);
          sizeBytes += read;
        }
      } finally {
        await input.close();
      }
      await target.flush();
    } finally {
      await target.close();
    }
    return (sizeBytes: sizeBytes, sha256: hasher.digestHex());
  }

  /// Durable-enough journal replace with a backup generation.
  ///
  /// Never leaves a crash window where the previous journal is already
  /// deleted and the new one is not yet visible: the previous file is first
  /// renamed to `.bak`, then the fsynced temp file replaces it. If the
  /// process dies between those two renames, [BackupJournalStore.read]
  /// falls back to `.bak`.
  static Future<void> atomicWriteString(String path, String content) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    final backup = File('${file.path}.bak');
    final raf = await temp.open(mode: FileMode.write);
    try {
      raf.writeStringSync(content);
      await raf.flush();
    } finally {
      await raf.close();
    }

    if (await backup.exists()) {
      await backup.delete();
    }
    final hadPrevious = await file.exists();
    if (hadPrevious) {
      await file.rename(backup.path);
    }
    try {
      await temp.rename(file.path);
    } catch (_) {
      if (hadPrevious && !await file.exists() && await backup.exists()) {
        await backup.rename(file.path);
      }
      rethrow;
    }
    if (await backup.exists()) {
      await backup.delete();
    }
  }

  static Future<void> atomicWriteJson(
    String path,
    Map<String, Object?> json,
  ) {
    return atomicWriteString(
        path, const JsonEncoder.withIndent('  ').convert(json));
  }

  static Future<void> deleteDirectoryContents(Directory root) async {
    if (!await root.exists()) return;
    await for (final entity in root.list(recursive: false)) {
      await entity.delete(recursive: true);
    }
  }

  static Future<void> copyDirectoryContents({
    required Directory source,
    required Directory target,
  }) async {
    if (!await source.exists()) return;
    await target.create(recursive: true);
    await for (final entity in source.list(recursive: true)) {
      final relative = p.relative(entity.path, from: source.path);
      final destinationPath = p.join(target.path, relative);
      if (entity is Directory) {
        await Directory(destinationPath).create(recursive: true);
      } else if (entity is File) {
        await copyAndMeasure(
          sourcePath: entity.path,
          targetPath: destinationPath,
        );
      } else if (entity is Link) {
        throw const BackupException(BackupFailure.unsafeArchivePath);
      }
    }
  }

  static Future<void> ensureWithin(String root, String path) async {
    final normalizedRoot = p.normalize(p.absolute(root));
    final normalized = p.normalize(p.absolute(path));
    if (!p.isWithin(normalizedRoot, normalized) &&
        normalizedRoot != normalized) {
      throw const BackupException(BackupFailure.unsafeArchivePath);
    }
  }
}

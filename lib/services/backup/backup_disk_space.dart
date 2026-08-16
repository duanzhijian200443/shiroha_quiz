import 'dart:io';

import 'package:path/path.dart' as p;

import '../../domain/backup/backup_failure.dart';
import '../../domain/backup/backup_manifest.dart';
import '../../domain/backup/backup_values.dart';

abstract interface class BackupDiskSpaceProbe {
  Future<int?> availableBytes(String path);
}

/// Production free-space probe.
///
/// Linux/Android use `statvfs`-equivalent userland `df`; Windows uses
/// PowerShell `Get-PSDrive`; unsupported platforms return null and the
/// runtime fails closed as `resourceLimitExceeded` before extracting large
/// data because a contract preflight cannot be proven.
final class PlatformDiskSpaceProbe implements BackupDiskSpaceProbe {
  const PlatformDiskSpaceProbe();

  @override
  Future<int?> availableBytes(String path) async {
    final directory = Directory(p.absolute(path));
    final probePath = directory.existsSync()
        ? directory.path
        : Directory(p.dirname(p.absolute(path))).path;
    if (Platform.isWindows) {
      final result = await Process.run(
          'powershell',
          <String>[
            '-NoProfile',
            '-Command',
            r"(Get-PSDrive -Name (Get-Location).Drive.Name).Free",
          ],
          workingDirectory: probePath);
      if (result.exitCode != 0) return null;
      return int.tryParse((result.stdout as String).trim());
    }
    if (Platform.isLinux || Platform.isMacOS || Platform.isAndroid) {
      final result = await Process.run('df', <String>['-Pk', probePath]);
      if (result.exitCode != 0) return null;
      final lines = (result.stdout as String).split('\n');
      if (lines.length < 2) return null;
      final parts = lines[1].trim().split(RegExp(r'\s+'));
      if (parts.length < 4) return null;
      final availableKb = int.tryParse(parts[3]);
      if (availableKb == null) return null;
      return availableKb * 1024;
    }
    return null;
  }
}

abstract final class BackupFreeSpacePolicy {
  static int workingReserve(int durableBytes) {
    final tenPercent = (durableBytes / 10).ceil();
    const floor = BackupValues.freeSpaceWorkingReserveBytes;
    return tenPercent > floor ? tenPercent : floor;
  }

  static Future<void> ensureAvailable({
    required BackupDiskSpaceProbe probe,
    required String path,
    required int durableBytes,
  }) async {
    final required = durableBytes + workingReserve(durableBytes);
    final available = await probe.availableBytes(path);
    if (available == null || available < required) {
      throw const BackupException(BackupFailure.resourceLimitExceeded);
    }
  }
}

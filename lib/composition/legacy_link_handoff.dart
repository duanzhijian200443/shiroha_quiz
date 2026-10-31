import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import '../application/external/local_link_handoff.dart';
import '../core/database/database_helper.dart';
import '../data/external/bounded_json_object.dart';
import '../data/external/link/host_handoff.dart';
import '../data/external/link/link_installation.dart';
import '../data/external/link/link_values.dart';
import '../data/repositories/legacy_link_handoff_repository.dart';

/// The already-running Windows App is the only owner of the old database.
final class WindowsAppLinkHandoff implements LocalLinkHandoff {
  WindowsAppLinkHandoff(
      {required this.database, required this.closeOriginalOwners});
  final DatabaseHelper database;
  final Future<void> Function() closeOriginalOwners;
  Future<void>? _running;
  @override
  Future<void> run() => _running ??= _run().whenComplete(() => _running = null);
  Future<void> _run() async {
    if (!Platform.isWindows) linkFail('unavailable');
    final config = await LinkInstallation.load();
    final authority = LegacyLinkHandoffRepository(
        database: database,
        slotRef: config.slotRef,
        closeOriginalOwners: closeOriginalOwners,
        readOriginalBinding: () => _binding(config));
    await HostHandoffStore(Directory(config.slotDirectory))
        .release(authority, config.connectorInstanceId);
  }

  Future<LinkVerifiedTarget> _binding(LinkInstallation config) async {
    final child = await Process.start(
        config.adapterExecutable, ['--handoff-binding'],
        runInShell: false);
    final bytes = BytesBuilder(copy: false);
    var failed = false, errorBytes = 0;
    final output = child.stdout.forEach((chunk) {
      if (bytes.length + chunk.length > 4096) {
        failed = true;
      } else {
        bytes.add(chunk);
      }
    });
    final errors = child.stderr.forEach((chunk) {
      errorBytes += chunk.length;
      if (errorBytes > 4096) failed = true;
    });
    final code = await child.exitCode;
    await Future.wait([output, errors]);
    await child.stdin.close();
    if (code != 0 || failed) linkFail('old_owner_unresolved');
    return LinkVerifiedTarget.fromJson(
        boundedJsonObject(bytes.takeBytes(), maxBytes: 4096));
  }
}

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/core/app_data_paths.dart';
import 'package:shiroha_quiz/data/persistence/engine_credential_store.dart';
import 'package:shiroha_quiz/main.dart' as app;

const smokeRootDefine = 'SHIROHA_MCP_APP_SMOKE_ROOT';
const smokeOwner = 'MCP-VNEXT-WINDOWS-APP-FUNCTIONAL-SMOKE';
const smokePrefix = 'shiroha_mcp_app_smoke_';

/// Accepts only an explicitly prepared, task-owned immediate temporary child.
///
/// There is no fallback to an OS application-support or personal data root.
AppDataPaths smokeDataPaths(String root) {
  if (!p.isAbsolute(root) ||
      FileSystemEntity.typeSync(root, followLinks: false) !=
          FileSystemEntityType.directory) {
    throw StateError('Smoke isolation unavailable');
  }
  final canonical = Directory(root).resolveSymbolicLinksSync();
  final temp = Directory.systemTemp.resolveSymbolicLinksSync();
  if (!p.equals(p.dirname(canonical), temp) ||
      !p.basename(canonical).startsWith(smokePrefix)) {
    throw StateError('Smoke isolation unavailable');
  }
  final marker = p.join(canonical, '.smoke-owner');
  if (FileSystemEntity.typeSync(marker, followLinks: false) !=
          FileSystemEntityType.file ||
      File(marker).readAsStringSync() != smokeOwner) {
    throw StateError('Smoke isolation unavailable');
  }
  return AppDataPaths.fromApplicationSupportDirectory(
    Directory(canonical),
    environment: AppDataEnvironment.development,
  );
}

/// No native secure storage or credential material exists in this entrypoint.
final class SmokeCredentialStore implements EngineCredentialStore {
  Never _deny() => throw const EngineCredentialException(
      EngineCredentialFailure.temporarilyUnavailable);
  @override
  Future<String?> readCredential(String engineId) async => _deny();
  @override
  Future<void> writeCredential(String engineId, String secret) async => _deny();
  @override
  Future<void> deleteCredential(String engineId) async => _deny();
}

/// Even accidental Provider use cannot create an HTTP connection.
final class SmokeHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.findProxy = (_) => 'DIRECT';
    client.connectionFactory =
        (_, __, ___) => throw StateError('Network unavailable in App smoke');
    return client;
  }
}

void main() {
  final paths = smokeDataPaths(const String.fromEnvironment(smokeRootDefine));
  HttpOverrides.global = SmokeHttpOverrides();
  app.runShirohaQuiz(
      dataPaths: paths, createCredentialStore: SmokeCredentialStore.new);
}

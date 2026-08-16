import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/agent/agent_config.dart';
import 'package:shiroha_quiz/application/agent/agent_config_service.dart';
import 'package:shiroha_quiz/application/backup/backup_restore_gate.dart';
import 'package:shiroha_quiz/domain/backup/backup_failure.dart';
import 'package:shiroha_quiz/domain/backup/backup_manifest.dart';

Matcher _restoreBlocked() => throwsA(
      isA<BackupException>().having(
        (error) => error.failure,
        'failure',
        BackupFailure.restoreBlocked,
      ),
    );

final class _ConfigStore implements AgentConfigStorePort {
  Completer<void>? writeRelease;
  int writeCalls = 0;

  @override
  Future<String?> readAgentConfig() async => null;

  @override
  Future<void> writeAgentConfig(String encodedConfig) async {
    writeCalls++;
    await writeRelease?.future;
  }
}

final class _ProfileCatalog implements AgentProfileCatalogPort {
  @override
  Future<List<AgentProfileSummary>> listMainProfiles() async =>
      <AgentProfileSummary>[
        AgentProfileSummary(
          profileId: 'profile-main',
          displayName: 'Main',
          modelName: 'fixture-model',
        ),
      ];
}

AgentSettingsService _service(_ConfigStore store) {
  return AgentSettingsService(
    configStore: store,
    profileCatalog: _ProfileCatalog(),
  );
}

AgentConfig _config() => AgentConfig(
      providerKind: AgentProviderKind.deepSeekResponses,
      mainProfileId: 'profile-main',
    );

void main() {
  setUp(BackupRestoreMutationGate.resetForTesting);
  tearDown(BackupRestoreMutationGate.resetForTesting);

  test('AgentSettings save holds lease through the config store write',
      () async {
    final store = _ConfigStore()..writeRelease = Completer<void>();
    final pending = _service(store).save(_config());

    await Future<void>.delayed(Duration.zero);
    expect(store.writeCalls, 1);
    expect(BackupRestoreMutationGate.instance.activeMutationCount, 1);

    final drained = BackupRestoreMutationGate.instance.enterQuiescence();
    var drainCompleted = false;
    unawaited(drained.then((_) => drainCompleted = true));
    await Future<void>.delayed(Duration.zero);
    expect(drainCompleted, isFalse);

    store.writeRelease!.complete();
    await pending;
    await drained;
    expect(BackupRestoreMutationGate.instance.activeMutationCount, 0);
    BackupRestoreMutationGate.instance.exitQuiescence();
  });

  test('AgentSettings save is blocked before the config store write', () async {
    final store = _ConfigStore();
    await BackupRestoreMutationGate.instance.enterQuiescence();

    await expectLater(_service(store).save(_config()), _restoreBlocked());
    expect(store.writeCalls, 0);
    BackupRestoreMutationGate.instance.exitQuiescence();
  });
}

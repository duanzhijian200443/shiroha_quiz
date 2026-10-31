import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/backup/backup_restore_gate.dart';
import 'package:shiroha_quiz/application/capabilities/capability.dart';
import 'package:shiroha_quiz/application/external/local_host_dispatch.dart';
import 'external_question_read_test_support.dart';

/// Synthetic startup driver around the real fixture database/B0 gate. No Host
/// listener or production credential storage is used by these tests.
final class OfflineReadiness implements LocalHostReadinessPort {
  OfflineReadiness(this.database);
  final Future<void> Function() database;
  final events = <String>[];
  Future<void> Function()? recovery, modules;
  bool current = true;
  @override
  bool get isCurrent => current;
  @override
  Future<void> ensureDatabaseReady() async {
    events.add('database');
    await database();
  }

  @override
  Future<void> ensureRecoveryComplete() async {
    events.add('recovery');
    await recovery?.call();
    BackupRestoreMutationGate.instance.ensureMutationAllowed();
  }

  @override
  Future<void> ensureModulesAndRoutesReady() async {
    events.add('modules');
    await modules?.call();
  }
}

final class OfflineHostHarness {
  final h = QuestionReadHarness();
  late ExternalCapabilityGateway gateway;
  late LocalHostDispatchCore host;
  late OfflineReadiness readiness;
  late LocalHostSessionEntry entry;
  Future<void> open({bool start = true}) async {
    await h.open();
    await h.typed();
    await h.legacy('out-of-scope',
        bank: 'private-bank', stem: 'private needle');
    compose();
    if (start) await startHost();
  }

  void compose() {
    gateway = ExternalCapabilityGateway(stages: h.s.service, reads: h.read);
    readiness = OfflineReadiness(() async {
      final row = await h.s.h.db.rawQuery('PRAGMA user_version');
      expect(row.single.values.single, 36);
    });
    host = LocalHostDispatchCore(gateway: gateway, readiness: readiness);
  }

  Future<void> startHost() async {
    await host.startOffline();
    entry = await host.bindSession(h.s.session);
  }

  Future<ExternalExecutionContext> readContext() async {
    final discovery = await host.openRead(entry);
    final targets = await host.dispatch(
        ExternalCapabilities.listTargets, const ExternalTargetQuery(),
        entry: entry, context: discovery);
    expect(targets.output!.items.map((item) => item.bankName), ['bank']);
    final created = await host.dispatch(ExternalCapabilities.createReadContext,
        ExternalTargetSelection(targets.output!.items.single.targetRef),
        entry: entry, context: discovery);
    return host.openRead(entry, context: created.output!);
  }

  Future<ExternalExecutionContext> stageContext() async =>
      host.openStage(entry, await h.s.context());
  Future<void> close() async {
    await host.shutdown();
    await h.close();
  }
}

Matcher hostFailure(CapabilityFailure failure) =>
    throwsA(isA<LocalHostAdmissionException>()
        .having((e) => e.failure, 'failure', failure));

void expectNotStarted(CapabilityResult result) {
  expect(result.output, isNull);
  expect(result.receipt.status, CapabilityExecutionStatus.notStarted);
  expect(result.receipt.knownEffect, CapabilityEffect.none);
}

Future<void> flushHostMicrotasks() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.value();
  }
}

import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/backup/backup_restore_gate.dart';
import 'package:shiroha_quiz/application/capabilities/capability.dart';
import 'package:shiroha_quiz/application/external/external_authorization.dart';
import 'package:shiroha_quiz/application/external/external_generated_stage.dart';
import 'package:shiroha_quiz/application/external/external_invocation_core.dart';
import 'package:shiroha_quiz/application/external/external_trust_core.dart';
import 'package:shiroha_quiz/application/external/local_host_dispatch.dart';
import 'package:shiroha_quiz/data/repositories/generated_proposal_repository.dart';
import 'external_file_read_test_support.dart' show FileReadHarness;
import 'external_question_read_test_support.dart';
import 'local_host_test_support.dart';

void main() {
  initializeGeneratedTests();
  group('P8 offline startup and trusted entry', () {
    late OfflineHostHarness f;
    setUp(() async {
      f = OfflineHostHarness();
      await f.open(start: false);
    });
    tearDown(() => f.close());

    test('default disabled and recovery-in-progress refuse all Host admission',
        () async {
      final context = await f.gateway.openRead(session: f.h.s.session);
      expect(f.host.state, LocalHostState.disabled);
      expect(() => f.host.bindSession(f.h.s.session),
          hostFailure(CapabilityFailure.temporarilyUnavailable));
      expectNotStarted(await f.host.dispatch(
          ExternalCapabilities.listTargets, const ExternalTargetQuery(),
          entry: null, context: context));
      final reached = Completer<void>(), resume = Completer<void>();
      f.readiness.recovery = () async {
        reached.complete();
        await resume.future;
      };
      final starting = f.host.startOffline();
      await reached.future;
      expect(f.host.state, LocalHostState.starting);
      expect(f.readiness.events, ['database', 'recovery']);
      expect(() => f.host.bindSession(f.h.s.session),
          hostFailure(CapabilityFailure.temporarilyUnavailable));
      resume.complete();
      await starting;
      expect(f.readiness.events, ['database', 'recovery', 'modules']);
      expect(f.host.state, LocalHostState.ready);
      expect(f.h.read.activeHandleCount, 0);
    });

    test('ready never authenticates, enables or accepts claimed Profile fields',
        () async {
      f.h.s.trust.disable(f.h.s.principal);
      await f.host.startOffline();
      await expectLater(f.host.bindSession(f.h.s.session),
          hostFailure(CapabilityFailure.accessDenied));
      expect(
          () => f.h.s.trust.authenticate(
              {'profileId': f.h.s.profile.profileId, 'authenticated': true}),
          throwsA(isA<ExternalCoreException>()));
      f.h.s.trust.enable(f.h.s.principal, const Duration(minutes: 30));
      await expectLater(f.host.bindSession(f.h.s.session),
          hostFailure(CapabilityFailure.accessDenied));
      final fresh = f.h.s.trust.openSession(
          f.h.s.trust.authenticate(f.h.s.credentials.authentication));
      final entry = await f.host.bindSession(fresh);
      expect(await f.host.openRead(entry), isA<ExternalExecutionContext>());
    });

    for (final failedGate in ['database', 'recovery', 'modules', 'current']) {
      test('$failedGate failure is closed and never exposes the exception',
          () async {
        Future<void> fail() async =>
            throw StateError('secret-token/local-path');
        if (failedGate == 'database') {
          f.readiness = OfflineReadiness(fail);
          f.host =
              LocalHostDispatchCore(gateway: f.gateway, readiness: f.readiness);
        } else if (failedGate == 'recovery') {
          f.readiness.recovery = fail;
        } else if (failedGate == 'modules') {
          f.readiness.modules = fail;
        } else {
          f.readiness.current = false;
        }
        Object? error;
        try {
          await f.host.startOffline();
        } catch (e) {
          error = e;
        }
        expect(error, isA<LocalHostAdmissionException>());
        expect(error.toString(), isNot(contains('secret-token')));
        expect(f.host.state, LocalHostState.stopped);
        expect(() => f.host.startOffline(),
            hostFailure(CapabilityFailure.temporarilyUnavailable));
        expect(f.h.contentReads, 0);
      });
    }

    test('B0 maintenance admission cannot reach ready', () async {
      BackupRestoreMutationGate.instance.tryEnterQuiescence();
      try {
        await expectLater(f.host.startOffline(),
            hostFailure(CapabilityFailure.temporarilyUnavailable));
        expect(f.host.state, LocalHostState.stopped);
      } finally {
        BackupRestoreMutationGate.instance.exitQuiescence();
      }
    });

    test('shutdown drains startup and prevents late ready publication',
        () async {
      final reached = Completer<void>(), resume = Completer<void>();
      f.readiness.modules = () async {
        reached.complete();
        await resume.future;
      };
      final starting = f.host.startOffline();
      final refused = expectLater(
          starting, hostFailure(CapabilityFailure.temporarilyUnavailable));
      await reached.future;
      var stopped = false;
      final shutdown = f.host.shutdown().then((_) => stopped = true);
      await flushHostMicrotasks();
      expect(stopped, isFalse);
      expect(f.host.state, LocalHostState.stopping);
      resume.complete();
      await refused;
      await shutdown;
      expect(f.host.state, LocalHostState.stopped);
      expect(f.host.pendingCount, 0);
    });
  });

  group('P8 P7 delegation and authority', () {
    late OfflineHostHarness f;
    setUp(() async {
      f = OfflineHostHarness();
      await f.open();
    });
    tearDown(() => f.close());

    test(
        'scoped Target/Context/search/detail use real typed authority and Receipt',
        () async {
      final context = await f.readContext();
      final search = await f.host.dispatch(ExternalCapabilities.searchQuestions,
          const ExternalQuestionQuery('needle'),
          entry: f.entry, context: context);
      expect(search.output!.items, hasLength(1));
      final detail = await f.host.dispatch(
          ExternalCapabilities.getQuestionDetail,
          ExternalQuestionSelection(search.output!.items.single.questionRef),
          entry: f.entry,
          context: context);
      expect(detail.receipt.status, CapabilityExecutionStatus.completed);
      expect(detail.receipt.knownEffect, CapabilityEffect.none);
      expect(detail.receipt.authorization.external!.recipient,
          f.h.s.profile.profileId);
      expect(
          detail.receipt.authorization.external!
              .belongsToSession(f.h.s.session),
          isTrue);
      expect(detail.output!.toJson().toString(), contains('Synthetic needle'));
      expect(detail.output!.toJson().toString(),
          isNot(contains('private needle')));
    });

    test(
        'unknown/mismatched/Built-in/COMMIT/DESTRUCTIVE cannot enter a handler',
        () async {
      final context = await f.host.openRead(f.entry);
      for (final name in [
        'secret-token/local-path',
        'commit',
        'destructive',
        'search_questions',
        'external_list_targets'
      ]) {
        final result = await f.host.dispatch(CapabilityId<int, int>(name), 1,
            entry: f.entry, context: context);
        expectNotStarted(result);
        expect(
            result.failure,
            name == 'external_list_targets'
                ? CapabilityFailure.invalidRequest
                : CapabilityFailure.unknownCapability);
        expect(result.receipt.authorization.external, isNull);
        expect(result.receipt.capabilityId.value, 'local_host_rejected');
      }
      expect(f.h.contentReads, 0);
      expect(await f.h.s.h.count('generated_question_proposals'), 0);
      expect(await f.h.s.h.count('questions'), 2);
      expectNotStarted(await f.host.dispatch(
          ExternalCapabilities.listTargets, const ExternalTargetQuery(),
          entry: null, context: context));
    });

    test('foreign Principal and foreign Host entry cannot reuse Contexts',
        () async {
      final context = await f.readContext();
      final other = OfflineHostHarness();
      await other.open();
      try {
        await expectLater(f.host.bindSession(other.h.s.session),
            hostFailure(CapabilityFailure.accessDenied));
        final result = await f.host.dispatch(
            ExternalCapabilities.searchQuestions,
            const ExternalQuestionQuery('needle'),
            entry: other.entry,
            context: context);
        expectNotStarted(result);
        expect(f.h.contentReads, 0);
      } finally {
        await other.close();
      }
    });

    test('same Principal cannot copy a P7 Context or a precise STAGE Context',
        () async {
      final context = await f.readContext();
      final session = f.h.s.trust.openSession(
          f.h.s.trust.authenticate(f.h.s.credentials.authentication));
      final second = await f.host.bindSession(session);
      final denied = await f.host.dispatch(ExternalCapabilities.searchQuestions,
          const ExternalQuestionQuery('needle'),
          entry: second, context: context);
      expectNotStarted(denied);
      expect(f.h.contentReads, 0);
      await expectLater(f.host.openStage(second, await f.h.s.context()),
          hostFailure(CapabilityFailure.accessDenied));
      final fresh = await f.host
          .openRead(second, context: context.authorization.contextReference);
      final success = await f.host.dispatch(
          ExternalCapabilities.searchQuestions,
          const ExternalQuestionQuery('needle'),
          entry: second,
          context: fresh);
      expect(success.output!.items, hasLength(1));
    });

    for (final mutation in [
      'disable',
      'expire',
      'revoke',
      'regrant',
      'restart',
      'restore',
      'readiness'
    ]) {
      test('$mutation invalidates old entry/Context before content admission',
          () async {
        final context = await f.readContext();
        switch (mutation) {
          case 'disable':
            f.h.s.trust.disable(f.h.s.principal);
          case 'expire':
            f.h.s.clock.current =
                f.h.s.clock.current.add(const Duration(minutes: 31));
          case 'revoke':
            await f.h.s.management.revokeGrant(f.h.s.profile, 2);
          case 'regrant':
            await f.h.s.management.replaceGrant(
                f.h.s.profile,
                2,
                f.h.s.policy(permissions: [
                  CapabilityPermission.read,
                  CapabilityPermission.stage
                ]));
          case 'restart':
            f.h.s.trust.restart();
          case 'restore':
            f.h.s.trust.restore();
          case 'readiness':
            f.readiness.current = false;
        }
        final denied = await f.host.dispatch(
            ExternalCapabilities.searchQuestions,
            const ExternalQuestionQuery('needle'),
            entry: f.entry,
            context: context);
        expectNotStarted(denied);
        await expectLater(f.host.openRead(f.entry),
            hostFailure(CapabilityFailure.accessDenied));
        expect(f.h.contentReads, 0);
        if (mutation == 'regrant') {
          final newEntry = await f.host.bindSession(f.h.s.session);
          final fresh = await f.host.openRead(newEntry);
          final allowed = await f.host.dispatch(
              ExternalCapabilities.listTargets, const ExternalTargetQuery(),
              entry: newEntry, context: fresh);
          expect(allowed.output!.items, hasLength(1));
        }
      });
    }

    for (final mutation in ['revoke', 'egress', 'scope', 'readiness']) {
      test('$mutation after real scoped content read suppresses final release',
          () async {
        final context = await f.readContext();
        f.h.barrier.afterSearch = () async {
          switch (mutation) {
            case 'revoke':
              await f.h.s.management.revokeGrant(f.h.s.profile, 2);
            case 'egress':
              await f.h.s.management.replaceGrant(
                  f.h.s.profile,
                  2,
                  f.h.s.policy(
                      permissions: [CapabilityPermission.read],
                      categories: [ExternalContentCategory.proposalMetadata]));
            case 'scope':
              await f.h.s.management.replaceGrant(
                  f.h.s.profile,
                  2,
                  f.h.s.policy(
                      permissions: [CapabilityPermission.read], scopes: []));
            case 'readiness':
              f.readiness.current = false;
          }
        };
        final result = await f.host.dispatch(
            ExternalCapabilities.searchQuestions,
            const ExternalQuestionQuery('needle'),
            entry: f.entry,
            context: context);
        expect(f.h.contentReads, greaterThan(0));
        expect(result.output, isNull);
        expect(result.receipt.knownEffect, CapabilityEffect.none);
        expect(
            result.receipt.status, isNot(CapabilityExecutionStatus.notStarted));
      });
    }

    for (final deadline in [false, true]) {
      test(
          'READ ${deadline ? "deadline" : "cancel"} holds owning work through shutdown',
          () async {
        final context = await f.readContext();
        final reached = Completer<void>(), resume = Completer<void>();
        f.h.barrier.beforeSearch = () async {
          reached.complete();
          await resume.future;
        };
        final control = ExternalCallControl(
            clock: f.h.s.clock,
            deadline: deadline
                ? f.h.s.clock.now().add(const Duration(seconds: 1))
                : null);
        final pending = f.host.dispatch(ExternalCapabilities.searchQuestions,
            const ExternalQuestionQuery('needle'),
            entry: f.entry, context: context, control: control);
        await reached.future;
        if (deadline) {
          f.h.s.clock.current =
              f.h.s.clock.current.add(const Duration(seconds: 2));
          control.checkDeadline();
        } else {
          control.cancel();
        }
        final result = await pending;
        expect(result.output, isNull);
        expect(
            result.failure,
            deadline
                ? CapabilityFailure.deadlineExceeded
                : CapabilityFailure.cancelled);
        expect(result.receipt.status, CapabilityExecutionStatus.outcomeUnknown);
        expect(result.receipt.knownEffect, CapabilityEffect.none);
        expect(f.h.read.pendingCount, 1);
        expect(f.gateway.pendingCount, 1);
        var stopped = false;
        final shutdown = f.host.shutdown().then((_) => stopped = true);
        await flushHostMicrotasks();
        expect(stopped, isFalse);
        resume.complete();
        await shutdown;
        expect(f.h.read.pendingCount, 0);
        expect(f.gateway.pendingCount, 0);
        expect(f.h.contentReads, 0);
      });
    }

    test('shutdown during an uninterrupted READ suppresses output and waits',
        () async {
      final context = await f.readContext();
      final reached = Completer<void>(), resume = Completer<void>();
      f.h.barrier.afterSearch = () async {
        reached.complete();
        await resume.future;
      };
      final pending = f.host.dispatch(ExternalCapabilities.searchQuestions,
          const ExternalQuestionQuery('needle'),
          entry: f.entry, context: context);
      await reached.future;
      expect(f.h.contentReads, greaterThan(0));
      var stopped = false;
      final shutdown = f.host.shutdown().then((_) => stopped = true);
      expect(identical(f.host.shutdown(), f.host.shutdown()), isTrue);
      await flushHostMicrotasks();
      expect(stopped, isFalse);
      expectNotStarted(await f.host.dispatch(
          ExternalCapabilities.searchQuestions,
          const ExternalQuestionQuery('needle'),
          entry: f.entry,
          context: context));
      resume.complete();
      final result = await pending;
      expect(result.output, isNull);
      expect(result.receipt.knownEffect, CapabilityEffect.none);
      await shutdown;
      expect(f.h.read.activeHandleCount, 0);
    });

    test('shutdown drains a real SQLite-blocked Context opening', () async {
      final reached = Completer<void>(), resume = Completer<void>();
      final transaction = f.h.s.h.db.transaction((txn) async {
        await txn.rawQuery('SELECT count(*) FROM external_grants');
        reached.complete();
        await resume.future;
      });
      await reached.future;
      final opening = f.host.openRead(f.entry);
      final refusal =
          expectLater(opening, hostFailure(CapabilityFailure.accessDenied));
      var stopped = false;
      final shutdown = f.host.shutdown().then((_) => stopped = true);
      await flushHostMicrotasks();
      expect(f.host.pendingCount, 1);
      expect(stopped, isFalse);
      resume.complete();
      await transaction;
      await refusal;
      await shutdown;
      expect(f.host.pendingCount, 0);
      expect(f.host.state, LocalHostState.stopped);
    });
  });

  group('P8 STAGE effects, competition and drain', () {
    late OfflineHostHarness f;
    setUp(() async {
      f = OfflineHostHarness();
      await f.open();
    });
    tearDown(() => f.close());
    Future<CapabilityResult<ExternalStageSummary>> stage(
            ExternalExecutionContext context,
            {ExternalCallControl? control,
            bool Function()? available}) =>
        f.host.dispatch(ExternalCapabilities.stage,
            ExternalStageSubmission(submission(key: 'host-key')),
            entry: f.entry,
            context: context,
            control: control,
            responseAvailable: available);

    for (final winner in ['revoke', 'revision', 'publication']) {
      test('$winner wins the original SQLite STAGE publication authority',
          () async {
        final context = await f.stageContext();
        Future<void>? revoking;
        f.h.s.checkpoint = (point) async {
          if (point == ExternalStageCheckpoint.beforeTransaction &&
              winner != 'publication') {
            if (winner == 'revoke') {
              await f.h.s.management.revokeGrant(f.h.s.profile, 2);
            } else {
              await f.h.s.management.replaceGrant(f.h.s.profile, 2,
                  f.h.s.policy(permissions: [CapabilityPermission.stage]));
            }
          }
          if (point == ExternalStageCheckpoint.authorized &&
              winner == 'publication') {
            revoking = f.h.s.management.revokeGrant(f.h.s.profile, 2);
          }
        };
        final result = await stage(context);
        await revoking;
        expect(result.output, isNull);
        expect(
            result.receipt.knownEffect,
            winner == 'publication'
                ? CapabilityEffect.proposalStaged
                : CapabilityEffect.none);
        expect(
            result.receipt.status,
            winner == 'publication'
                ? CapabilityExecutionStatus.outcomeUnknown
                : CapabilityExecutionStatus.failedWithoutEffect);
        expect(await f.h.s.h.count('generated_question_proposals'),
            winner == 'publication' ? 1 : 0);
        expect(await f.h.s.h.count('generated_question_commit_receipts'), 0);
        expect(await f.h.s.h.count('questions'), 2);
      });
    }

    test(
        'revoke at final Kernel STAGE release withholds output and preserves completed effect',
        () async {
      final context = await f.stageContext();
      var releases = 0;
      f.h.s.checkpoint = (point) async {
        if (point == ExternalStageCheckpoint.beforeRelease && ++releases == 2) {
          await f.h.s.management.revokeGrant(f.h.s.profile, 2);
        }
      };
      final result = await stage(context);
      expect(releases, 2);
      expect(result.output, isNull);
      expect(result.receipt.status, CapabilityExecutionStatus.completed);
      expect(result.receipt.knownEffect, CapabilityEffect.proposalStaged);
      expect(result.receipt.durableReconciliation!.submissionKey, 'host-key');
      expect(await f.h.s.h.count('generated_question_proposals'), 1);
    });

    test(
        'lost successful STAGE retains effect and reconciles original key without retry',
        () async {
      final result =
          await stage(await f.stageContext(), available: () => false);
      expect(result.output, isNull);
      expect(result.failure, CapabilityFailure.externalResponseLost);
      expect(result.receipt.knownEffect, CapabilityEffect.proposalStaged);
      expect(result.receipt.durableReconciliation!.submissionKey, 'host-key');
      final reconciliation =
          await f.host.openReconciliation(f.entry, 'host-key');
      final found = await f.host.dispatch(
          ExternalCapabilities.reconcile, const ExternalNoInput(),
          entry: f.entry, context: reconciliation);
      expect(found.output!.submissionKey, 'host-key');
      expect(await f.h.s.h.count('generated_question_proposals'), 1);
      final absent = await f.host.dispatch(
          ExternalCapabilities.reconcile, const ExternalNoInput(),
          entry: f.entry,
          context: await f.host.openReconciliation(f.entry, 'absent-key'));
      expect(absent.output, isNull);
      expect(absent.receipt.status, CapabilityExecutionStatus.outcomeUnknown);
      expect(absent.receipt.knownEffect, isNull);
      expect(await f.h.s.h.count('generated_question_proposals'), 1);
    });

    for (final deadline in [false, true]) {
      for (final committed in [false, true]) {
        test(
            '${deadline ? "deadline" : "cancel"} ${committed ? "after commit" : "before commit"} never substitutes for settlement',
            () async {
          final context = await f.stageContext();
          final reached = Completer<void>(), resume = Completer<void>();
          final control = ExternalCallControl(
              clock: f.h.s.clock,
              deadline: deadline
                  ? f.h.s.clock.now().add(const Duration(seconds: 1))
                  : null);
          f.h.s.checkpoint = (point) async {
            if (point ==
                (committed
                    ? ExternalStageCheckpoint.afterCommit
                    : ExternalStageCheckpoint.authorized)) {
              reached.complete();
              await resume.future;
            }
          };
          final pending = stage(context, control: control);
          await reached.future;
          if (deadline) {
            f.h.s.clock.current =
                f.h.s.clock.current.add(const Duration(seconds: 2));
            control.checkDeadline();
          } else {
            control.cancel();
          }
          final result = await pending;
          expect(result.output, isNull);
          expect(
              result.receipt.status, CapabilityExecutionStatus.outcomeUnknown);
          expect(result.receipt.knownEffect,
              committed ? CapabilityEffect.proposalStaged : null);
          expect(
              result.failure,
              deadline
                  ? CapabilityFailure.deadlineExceeded
                  : CapabilityFailure.cancelled);
          expect(f.h.s.service.pendingCount, 1);
          expect(f.gateway.pendingCount, 1);
          var replaced = false;
          final shutdown = f.host.shutdown().then((_) => replaced = true);
          await flushHostMicrotasks();
          expect(replaced, isFalse);
          expect(f.h.read.activeHandleCount, 0);
          expectNotStarted(await stage(context));
          resume.complete();
          await shutdown;
          expect(f.gateway.pendingCount, 0);
          expect(f.h.s.service.pendingCount, 0);
          expect(await f.h.s.h.count('generated_question_proposals'),
              committed ? 1 : 0);
          expect(await f.h.s.h.count('generated_question_commit_receipts'), 0);
          expect(f.host.state, LocalHostState.stopped);
        });
      }
    }
  });

  test(
      'P8 explicit File choices/Context/retrieval/passage retain real F1/FTS evidence',
      () async {
    final h = FileReadHarness();
    await h.open();
    final gateway =
        ExternalCapabilityGateway(stages: h.s.service, reads: h.read);
    final readiness = OfflineReadiness(() async {
      expect(
          (await h.s.h.db.rawQuery('PRAGMA user_version')).single.values.single,
          34);
    });
    final host = LocalHostDispatchCore(gateway: gateway, readiness: readiness);
    try {
      await host.startOffline();
      final entry = await host.bindSession(h.s.session);
      final discovery = await host.openRead(entry);
      final targets = await host.dispatch(
          ExternalCapabilities.listTargets, const ExternalTargetQuery(),
          entry: entry, context: discovery);
      final created = await host.dispatch(
          ExternalCapabilities.createReadContext,
          ExternalTargetSelection(targets.output!.items.single.targetRef),
          entry: entry,
          context: discovery);
      final parent = await host.openRead(entry, context: created.output!);
      final bodies = h.observed.reads;
      final choices = await host.dispatch(
          ExternalCapabilities.listFileSelections, const ExternalNoInput(),
          entry: entry, context: parent);
      expect(h.observed.reads, bodies);
      final files = await host.dispatch(
          ExternalCapabilities.createFileContext,
          ExternalFileSelections(
              [choices.output!.items.first['fileRef']! as String]),
          entry: entry,
          context: parent);
      final approved = await host.openRead(entry, context: files.output!);
      final search = await host.dispatch(
          ExternalCapabilities.retrieveFileContent,
          const ExternalFileQuery('needle'),
          entry: entry,
          context: approved);
      expect(search.receipt.knownEffect, CapabilityEffect.derivedCache);
      expect(h.index.searched, hasLength(1));
      final passage = await host.dispatch(
          ExternalCapabilities.getFilePassage,
          ExternalPassageSelection(
              search.output!.items.first['passageRef']! as String),
          entry: entry,
          context: approved);
      expect(passage.output!.items, isNotEmpty);
      expect(passage.receipt.knownEffect, CapabilityEffect.none);
      expect(passage.output!.toJson().toString(),
          isNot(contains('never-release-raw')));
      expect(await h.s.h.count('generated_question_proposals'), 0);
    } finally {
      await host.shutdown();
      await h.close();
    }
  });

  test('P8 has no transport/data dependency or default application activation',
      () {
    final source = File('lib/application/external/local_host_dispatch.dart')
        .readAsStringSync();
    final imports = RegExp(r'''import\s+['"]([^'"]+)['"]''')
        .allMatches(source)
        .map((m) => m.group(1)!);
    for (final forbidden in [
      'dart:io',
      '/data/',
      '/services/',
      'flutter',
      'mcp_dart',
      'provider'
    ]) {
      expect(imports.any((value) => value.contains(forbidden)), isFalse,
          reason: forbidden);
    }
    for (final forbidden in [
      'ServerSocket',
      'HttpServer',
      'Socket.connect',
      'NamedPipe',
      'jsonDecode',
      'fromJson'
    ]) {
      expect(source, isNot(contains(forbidden)), reason: forbidden);
    }
    final consumers = <String>[];
    for (final file in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) =>
            file.path.endsWith('.dart') &&
            !file.path.endsWith('local_host_dispatch.dart'))) {
      if (file.readAsStringSync().contains('LocalHostDispatchCore')) {
        consumers.add(file.path.replaceAll('\\', '/'));
      }
    }
    // P10 receives an existing offline core; it cannot start a production Host.
    expect(consumers, ['lib/data/external/ipc_command_projection.dart']);
    final adapter = File(consumers.single).readAsStringSync();
    expect(adapter.contains('LocalHostDispatchCore('), isFalse);
    expect(adapter.contains('.startOffline('), isFalse);
  });
}

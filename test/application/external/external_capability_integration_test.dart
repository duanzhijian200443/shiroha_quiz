import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/application/capabilities/capability.dart';
import 'package:shiroha_quiz/application/external/external_authorization.dart';
import 'package:shiroha_quiz/application/external/external_generated_stage.dart';
import 'package:shiroha_quiz/application/external/external_invocation_core.dart';
import 'package:shiroha_quiz/application/external/external_read_context.dart';
import 'package:shiroha_quiz/application/external/external_trust_core.dart';
import 'package:shiroha_quiz/data/repositories/generated_proposal_repository.dart';
import 'package:shiroha_quiz/domain/conversations/conversation.dart';
import 'package:shiroha_quiz/domain/generated_question/generated_question_contract.dart';
import 'external_question_read_test_support.dart';
import 'external_file_read_test_support.dart' show FileReadHarness;

void main() {
  initializeGeneratedTests();
  group('P7 trusted admission and Question READ', () {
    late QuestionReadHarness h;
    late ExternalCapabilityGateway gateway;
    setUp(() async {
      h = QuestionReadHarness();
      await h.open();
      gateway = ExternalCapabilityGateway(stages: h.s.service, reads: h.read);
      await h.typed();
      await h.legacy('private-question',
          bank: 'private-bank', stem: 'Private needle');
    });
    tearDown(() async {
      gateway.close();
      await h.close();
    });

    test('public constructor cannot claim an external Principal', () {
      expect(
          () => CapabilityContext(
              principal: CapabilityPrincipal.external,
              capabilities: [ExternalCapabilities.listTargets],
              permissions: [CapabilityPermission.read],
              scope: ConversationScope.global(),
              authorizedScope: ConversationScope.global(),
              authorizationCurrent: () async => true),
          throwsArgumentError);
    });

    test('explicit typed allowlist excludes Built-in and formal mutations',
        () async {
      final definitions = gateway.executor.registry.definitions;
      expect(definitions, hasLength(10));
      expect(
          definitions.every((d) => d.id.value.startsWith('external_')), isTrue);
      expect(
          definitions.every((d) => {
                CapabilityPermission.read,
                CapabilityPermission.stage
              }.contains(d.permission)),
          isTrue);
      final forged = CapabilityContext(
          principal: CapabilityPrincipal.builtInAgent,
          capabilities: [ExternalCapabilities.listTargets],
          permissions: [CapabilityPermission.read],
          scope: ConversationScope.global(),
          authorizedScope: ConversationScope.global(),
          authorizationCurrent: () async => true);
      final result = await gateway.executor.execute(
          ExternalCapabilities.listTargets,
          const ExternalTargetQuery(),
          forged);
      expect(result.receipt.status, CapabilityExecutionStatus.notStarted);
      expect(result.failure, CapabilityFailure.accessDenied);
    });

    test(
        'Target READ and Context creation use Kernel receipts and existing Registry',
        () async {
      final context = await gateway.openRead(session: h.s.session);
      final page = await gateway.execute(
          ExternalCapabilities.listTargets, const ExternalTargetQuery(),
          session: h.s.session, context: context);
      expect(page.output!.items.map((e) => e.bankName), ['bank']);
      expect(page.receipt.principal, CapabilityPrincipal.external);
      expect(page.receipt.knownEffect, CapabilityEffect.none);
      expect(page.receipt.authorization.external!.recipient,
          h.s.profile.profileId);
      final selected = await gateway.execute(
          ExternalCapabilities.createReadContext,
          ExternalTargetSelection(page.output!.items.single.targetRef),
          session: h.s.session,
          context: context);
      expect(
          await h.read
              .contextStatus(session: h.s.session, context: selected.output!),
          ExternalReadValidity.authorized);
    });

    test(
        'P7 exact Session rejection preserves same-Principal READ reference reuse',
        () async {
      final token = await h.context();
      final first = h.s.session;
      final original = await gateway.openRead(session: first, context: token);
      final second = h.s.trust
          .openSession(h.s.trust.authenticate(h.s.credentials.authentication));
      final denied = await gateway.execute(ExternalCapabilities.searchQuestions,
          const ExternalQuestionQuery('needle'),
          session: second, context: original);
      expect(denied.receipt.status, CapabilityExecutionStatus.notStarted);
      expect(denied.failure, CapabilityFailure.accessDenied);
      expect(h.contentReads, 0);
      final fresh = await gateway.openRead(session: second, context: token);
      final search = await gateway.execute(ExternalCapabilities.searchQuestions,
          const ExternalQuestionQuery('needle'),
          session: second, context: fresh);
      expect(search.output!.items, hasLength(1));
      final ref = search.output!.items.single.questionRef;
      final oldSessionDetail = await h.read
          .getQuestionDetail(session: first, context: token, questionRef: ref);
      expect(oldSessionDetail.toJson().toString(), isNot(contains('Private')));
      final detail = await gateway.execute(
          ExternalCapabilities.getQuestionDetail,
          ExternalQuestionSelection(ref),
          session: second,
          context: fresh);
      expect(detail.receipt.status, CapabilityExecutionStatus.completed);
      expect(detail.receipt.knownEffect, CapabilityEffect.none);
      expect(detail.output!.toJson(), oldSessionDetail.toJson());
      expect(detail.receipt.authorization.external!.belongsToSession(second),
          isTrue);
      expect(
          detail.receipt.authorization.external!.scopes.map((s) => s.targetId),
          ['bank']);
    });

    test(
        'another TrustCore with identical Profile display id cannot mint P7 context',
        () async {
      final trust = ExternalTrustCore(
          credentials: h.s.credentials,
          clock: h.s.clock,
          mintProfileId: () => h.s.profile.profileId);
      final principal = trust.createProfile();
      trust.requestPairing(principal,
          requestId: 'synthetic-pairing',
          credentialIdentity: 'synthetic-credential');
      trust.approvePairing(principal);
      trust.completePairing(principal, h.s.credentials.proof);
      trust.enable(principal, const Duration(minutes: 30));
      final foreign =
          trust.openSession(trust.authenticate(h.s.credentials.authentication));
      await expectLater(gateway.openRead(session: foreign),
          throwsA(isA<ExternalAuthException>()));
    });

    test('unpaired or disabled Principal cannot create an execution context',
        () async {
      expect(
          () => h.s.trust.authenticate(
              {'profileId': h.s.profile.profileId, 'trusted': true}),
          throwsA(isA<ExternalCoreException>()));
      h.s.trust.disable(h.s.principal);
      await expectLater(gateway.openRead(session: h.s.session),
          throwsA(isA<ExternalAuthException>()));
    });

    for (final mutation in [
      'revoke',
      'revision',
      'scope',
      'restart',
      'expiry',
      'close'
    ]) {
      test('$mutation invalidates old P7 context before handler entry',
          () async {
        final token = await h.context();
        final context =
            await gateway.openRead(session: h.s.session, context: token);
        switch (mutation) {
          case 'revoke':
            await h.s.management.revokeGrant(h.s.profile, 2);
          case 'revision':
            await h.s.management.replaceGrant(
                h.s.profile,
                2,
                h.s.policy(permissions: [
                  CapabilityPermission.read,
                  CapabilityPermission.stage
                ]));
          case 'scope':
            await h.s.management.replaceGrant(
                h.s.profile,
                2,
                h.s.policy(
                    permissions: [CapabilityPermission.read], scopes: []));
          case 'restart':
            h.s.trust.restart();
          case 'expiry':
            h.s.clock.current =
                h.s.clock.current.add(const Duration(minutes: 16));
          case 'close':
            gateway.close();
        }
        final result = await gateway.execute(
            ExternalCapabilities.searchQuestions,
            const ExternalQuestionQuery('needle'),
            session: h.s.session,
            context: context);
        expect(result.output, isNull);
        expect(result.receipt.status, CapabilityExecutionStatus.notStarted);
        expect(result.receipt.knownEffect, CapabilityEffect.none);
        expect(h.contentReads, 0);
      });
    }

    test('revoke after scoped content read releases no content', () async {
      final context = await gateway.openRead(
          session: h.s.session, context: await h.context());
      h.barrier.afterSearch = () => h.s.management.revokeGrant(h.s.profile, 2);
      final result = await gateway.execute(ExternalCapabilities.searchQuestions,
          const ExternalQuestionQuery('needle'),
          session: h.s.session, context: context);
      expect(result.output, isNull);
      expect(result.failure, CapabilityFailure.externalReadDenied);
      expect(
          result.receipt.status, CapabilityExecutionStatus.failedWithoutEffect);
      expect(result.receipt.knownEffect, CapabilityEffect.none);
      expect(await h.s.h.count('questions'), 2);
    });

    test('unknown QuestionRef and another Context never query unscoped content',
        () async {
      final first = await h.context();
      final search = await h.read.searchQuestions(
          session: h.s.session, context: first, query: 'needle');
      final other = await gateway.openRead(
          session: h.s.session, context: await h.context());
      for (final ref in ['missing', search.items.single.questionRef]) {
        final before = h.contentReads;
        final result = await gateway.execute(
            ExternalCapabilities.getQuestionDetail,
            ExternalQuestionSelection(ref),
            session: h.s.session,
            context: other);
        expect(result.output, isNull);
        expect(result.failure, CapabilityFailure.externalReadDenied);
        expect(h.contentReads, before);
      }
    });

    test(
        'cancel before Kernel handler is notStarted and READ result loss retains completion',
        () async {
      final context = await gateway.openRead(session: h.s.session);
      final cancelled = h.s.control()..cancel();
      final rejected = await gateway.execute(
          ExternalCapabilities.listTargets, const ExternalTargetQuery(),
          session: h.s.session, context: context, control: cancelled);
      expect(rejected.receipt.status, CapabilityExecutionStatus.notStarted);
      expect(rejected.failure, CapabilityFailure.cancelled);
      final handles = h.read.activeHandleCount;
      final lost = await gateway.execute(
          ExternalCapabilities.listTargets, const ExternalTargetQuery(),
          session: h.s.session,
          context: context,
          responseAvailable: () => false);
      expect(lost.output, isNull);
      expect(lost.failure, CapabilityFailure.externalResponseLost);
      expect(lost.receipt.status, CapabilityExecutionStatus.completed);
      expect(lost.receipt.knownEffect, CapabilityEffect.none);
      expect(h.read.activeHandleCount, handles);
    });
  });

  group('P7 durable STAGE and reconciliation', () {
    late QuestionReadHarness h;
    late ExternalCapabilityGateway gateway;
    setUp(() async {
      h = QuestionReadHarness();
      await h.open();
      gateway = ExternalCapabilityGateway(stages: h.s.service, reads: h.read);
    });
    tearDown(() async {
      gateway.close();
      await h.close();
    });
    Future<ExternalExecutionContext> stageContext() async =>
        gateway.openStage(session: h.s.session, context: await h.s.context());
    Future<CapabilityResult<ExternalStageSummary>> stage(
            ExternalExecutionContext context,
            {ExternalCallControl? control,
            String key = 'external-key',
            bool Function()? responseAvailable}) =>
        gateway.execute(ExternalCapabilities.stage,
            ExternalStageSubmission(submission(key: key)),
            session: h.s.session,
            context: context,
            control: control,
            responseAvailable: responseAvailable);
    Future<CapabilityResult<ExternalStageSummary>> reconcile(
            String key) async =>
        gateway.execute(ExternalCapabilities.reconcile, const ExternalNoInput(),
            session: h.s.session,
            context: await gateway.openReconciliation(
                session: h.s.session, submissionKey: key));

    test(
        'durable receipt references owning Proposal/key and never formal COMMIT',
        () async {
      final result = await stage(await stageContext());
      expect(result.receipt.status, CapabilityExecutionStatus.completed);
      expect(result.receipt.knownEffect, CapabilityEffect.proposalStaged);
      expect(result.receipt.reconciliation, isNull);
      expect(
          result.receipt.durableReconciliation!.submissionKey, 'external-key');
      expect(result.receipt.durableReconciliation!.profileId,
          h.s.profile.profileId);
      expect(
          gateway.executor.registry
              .definition(ExternalCapabilities.stage)!
              .semantics,
          CapabilityExecutionSemantics.durableStage);
      final found = await reconcile('external-key');
      expect(found.output!.proposalId, result.output!.proposalId);
      expect(await h.s.h.count('generated_question_proposals'), 1);
      expect(await h.s.h.count('generated_question_commit_receipts'), 0);
      expect(await h.s.h.count('questions'), 0);
    });

    test(
        'same-key conflict remains distinct from invalid submission after Kernel entry',
        () async {
      final context = await stageContext();
      await stage(context);
      final conflict = await gateway.execute(
          ExternalCapabilities.stage,
          ExternalStageSubmission(submission(
              key: 'external-key', items: [candidate(stem: 'Changed stem')])),
          session: h.s.session,
          context: context);
      expect(conflict.failure, CapabilityFailure.generatedIdempotencyConflict);
      expect(conflict.receipt.status,
          CapabilityExecutionStatus.failedWithoutEffect);
      final invalid = await gateway.execute(
          ExternalCapabilities.stage, const ExternalStageSubmission('{}'),
          session: h.s.session, context: context);
      expect(invalid.failure, CapabilityFailure.generatedInvalidSubmission);
      expect(invalid.receipt.status,
          CapabilityExecutionStatus.failedWithoutEffect);
      expect(await h.s.h.count('generated_question_proposals'), 1);
    });

    test(
        'P3 precise Session boundary stays mandatory even when P7 Context is fresh',
        () async {
      final approved = await h.s.context();
      final second = h.s.trust
          .openSession(h.s.trust.authenticate(h.s.credentials.authentication));
      await expectLater(gateway.openStage(session: second, context: approved),
          failure(GeneratedFailure.unauthorized));
    });

    test('revoke wins publication transaction: owning zero effect is preserved',
        () async {
      final context = await stageContext();
      h.s.checkpoint = (point) async {
        if (point == ExternalStageCheckpoint.beforeTransaction) {
          await h.s.management.revokeGrant(h.s.profile, 2);
        }
      };
      final result = await stage(context);
      expect(result.output, isNull);
      expect(
          result.receipt.status, CapabilityExecutionStatus.failedWithoutEffect);
      expect(result.receipt.knownEffect, CapabilityEffect.none);
      expect(await h.s.h.count('generated_question_proposals'), 0);
    });

    test(
        'publication wins queued revoke: immutable history and effect survive denied output',
        () async {
      final context = await stageContext();
      final entered = Completer<void>(), proceed = Completer<void>();
      h.s.checkpoint = (point) async {
        if (point == ExternalStageCheckpoint.authorized) {
          entered.complete();
          await proceed.future;
        }
      };
      final pending = stage(context);
      await entered.future;
      final revoking = h.s.management.revokeGrant(h.s.profile, 2);
      proceed.complete();
      final result = await pending;
      await revoking;
      expect(result.output, isNull);
      expect(result.receipt.knownEffect, CapabilityEffect.proposalStaged);
      expect(result.receipt.status, CapabilityExecutionStatus.outcomeUnknown);
      expect(await h.s.h.count('generated_question_proposals'), 1);
      expect(await h.s.h.count('generated_question_proposal_items'), 1);
    });

    test('final Kernel egress revoke retains completed publication evidence',
        () async {
      var releases = 0;
      final context = await stageContext();
      h.s.checkpoint = (point) async {
        if (point == ExternalStageCheckpoint.beforeRelease && ++releases == 2) {
          await h.s.management.revokeGrant(h.s.profile, 2);
        }
      };
      final result = await stage(context);
      expect(result.output, isNull);
      expect(result.receipt.status, CapabilityExecutionStatus.completed);
      expect(result.receipt.knownEffect, CapabilityEffect.proposalStaged);
      expect(
          result.receipt.durableReconciliation!.submissionKey, 'external-key');
      expect(await h.s.h.count('generated_question_proposals'), 1);
    });

    for (final deadline in [false, true]) {
      test(
          'STAGE ${deadline ? "deadline" : "cancel"} after entry is unknown and keeps pending slot',
          () async {
        final context = await stageContext();
        final entered = Completer<void>(), proceed = Completer<void>();
        final control = ExternalCallControl(
            clock: h.s.clock,
            deadline: deadline
                ? h.s.clock.now().add(const Duration(seconds: 1))
                : null);
        h.s.checkpoint = (point) async {
          if (point == ExternalStageCheckpoint.authorized) {
            entered.complete();
            await proceed.future;
          }
        };
        final pending = stage(context, control: control);
        await entered.future;
        if (deadline) {
          h.s.clock.current = h.s.clock.current.add(const Duration(seconds: 2));
          control.checkDeadline();
        } else {
          control.cancel();
        }
        final result = await pending;
        expect(result.output, isNull);
        expect(result.receipt.status, CapabilityExecutionStatus.outcomeUnknown);
        expect(result.receipt.knownEffect, isNull);
        expect(
            result.failure,
            deadline
                ? CapabilityFailure.deadlineExceeded
                : CapabilityFailure.cancelled);
        expect(h.s.service.pendingCount, 1);
        proceed.complete();
        await h.s.service.whenIdle;
        h.s.checkpoint = null;
        expect((await reconcile('external-key')).output, isNotNull);
        expect(await h.s.h.count('generated_question_proposals'), 1);
      });
    }

    test(
        'commit then result loss reconciles after real SQLite reopen with no repeat',
        () async {
      final context = await stageContext();
      h.s.checkpoint = (point) async {
        if (point == ExternalStageCheckpoint.afterCommit) {
          throw StateError('synthetic response loss');
        }
      };
      final result = await stage(context);
      expect(result.receipt.status, CapabilityExecutionStatus.outcomeUnknown);
      expect(result.receipt.knownEffect, CapabilityEffect.proposalStaged);
      expect(
          result.receipt.durableReconciliation!.submissionKey, 'external-key');
      gateway.close();
      h.read.close();
      await h.read.whenIdle;
      await h.s.reopen();
      h.compose();
      gateway = ExternalCapabilityGateway(stages: h.s.service, reads: h.read);
      final found = await reconcile('external-key');
      expect(found.output, isNotNull);
      expect(await h.s.h.count('generated_question_proposals'), 1);
      final absent = await reconcile('missing-key');
      expect(absent.output, isNull);
      expect(absent.receipt.status, CapabilityExecutionStatus.outcomeUnknown);
      expect(absent.receipt.knownEffect, isNull);
    });

    test('STAGE-only reconciliation does not require READ or current Context',
        () async {
      await stage(await stageContext());
      await h.s.management.replaceGrant(h.s.profile, 2,
          h.s.policy(categories: [ExternalContentCategory.proposalMetadata]));
      final result = await reconcile('external-key');
      expect(result.output, isNotNull);
      await expectLater(gateway.openRead(session: h.s.session),
          throwsA(isA<ExternalAuthException>()));
    });

    test(
        'P7 fifth call stays denied while interrupted owning work and queued admission remain pending',
        () async {
      final context = await stageContext();
      final entered = Completer<void>(), proceed = Completer<void>();
      h.s.checkpoint = (point) async {
        if (point == ExternalStageCheckpoint.authorized) {
          if (!entered.isCompleted) entered.complete();
          await proceed.future;
        }
      };
      final controls = List.generate(4, (_) => h.s.control());
      final operations = [
        for (final control in controls) stage(context, control: control)
      ];
      await entered.future;
      for (final control in controls) {
        control.cancel();
      }
      await Future.wait(operations);
      expect(gateway.pendingCount, 4);
      final fifth = await stage(context);
      expect(fifth.receipt.status, CapabilityExecutionStatus.notStarted);
      expect(fifth.failure, CapabilityFailure.budgetDenied);
      proceed.complete();
      await gateway.whenIdle;
      expect(gateway.pendingCount, 0);
      expect(await h.s.h.count('generated_question_proposals'), 1);
    });
  });

  group('P7 File READ cache effects and reference compatibility', () {
    late FileReadHarness h;
    late ExternalCapabilityGateway gateway;
    setUp(() async {
      h = FileReadHarness();
      await h.open();
      gateway = ExternalCapabilityGateway(stages: h.s.service, reads: h.read);
    });
    tearDown(() async {
      gateway.close();
      await h.close();
    });

    test('file choice and creation preserve separate bounded Context snapshots',
        () async {
      final parent = await h.context();
      final context =
          await gateway.openRead(session: h.s.session, context: parent);
      final choices = await gateway.execute(
          ExternalCapabilities.listFileSelections, const ExternalNoInput(),
          session: h.s.session, context: context);
      final file = await gateway.execute(
          ExternalCapabilities.createFileContext,
          ExternalFileSelections(
              [choices.output!.items.first['fileRef']! as String]),
          session: h.s.session,
          context: context);
      expect(file.output, isNotNull);
      final approved =
          await gateway.openRead(session: h.s.session, context: file.output);
      expect(approved.authorization.scopes.map((s) => s.targetId),
          ['bank', 'file-a']);
      final choicesAgain = await gateway.execute(
          ExternalCapabilities.listFileSelections, const ExternalNoInput(),
          session: h.s.session, context: approved);
      final reselected = await gateway.execute(
          ExternalCapabilities.createFileContext,
          ExternalFileSelections(
              [choicesAgain.output!.items.first['fileRef']! as String]),
          session: h.s.session,
          context: approved);
      expect(reselected.output, isNotNull);
      final old = await gateway.execute(
          ExternalCapabilities.retrieveFileContent,
          const ExternalFileQuery('needle'),
          session: h.s.session,
          context: context);
      expect(old.output, isNull);
      expect(old.receipt.knownEffect, CapabilityEffect.none);
    });

    test(
        'Question/File refs remain same-Principal reusable by another valid Session',
        () async {
      final first = h.s.session;
      final parent = await h.context();
      final choices =
          await h.read.listFileSelections(session: first, context: parent);
      final second = h.s.trust
          .openSession(h.s.trust.authenticate(h.s.credentials.authentication));
      final fileContext = await h.read.createFileContext(
          session: second,
          context: parent,
          fileRefs: [choices.items.first['fileRef']! as String]);
      final execution =
          await gateway.openRead(session: first, context: fileContext);
      final page = await gateway.execute(
          ExternalCapabilities.retrieveFileContent,
          const ExternalFileQuery('needle'),
          session: first,
          context: execution);
      expect(page.receipt.status, CapabilityExecutionStatus.completed);
      expect(page.receipt.knownEffect, CapabilityEffect.derivedCache);
      final anchor = page.output!.items.single['passageRef']! as String;
      final passage = await h.read.getFilePassage(
          session: second, context: fileContext, passageRef: anchor);
      expect(passage.items, isNotEmpty);
      expect(passage.nextCursor, isNotNull);
      final continued = await h.read.getFilePassage(
          session: first,
          context: fileContext,
          passageRef: anchor,
          cursor: passage.nextCursor);
      expect(continued.items, isNotEmpty);
      final secondExecution =
          await gateway.openRead(session: second, context: fileContext);
      final result = await gateway.execute(
          ExternalCapabilities.getFilePassage, ExternalPassageSelection(anchor),
          session: second, context: secondExecution);
      expect(result.receipt.knownEffect, CapabilityEffect.none);
      expect(result.output!.toJson().keys.toSet(), {
        'items',
        'nextCursor',
        'hasMore',
        'unsupportedExcluded',
        'startsAtDocumentBeginning'
      });
    });

    test('confirmed cache effect survives result loss; warm READ is unchanged',
        () async {
      final context = await gateway.openRead(
          session: h.s.session, context: await h.approved());
      final lost = await gateway.execute(
          ExternalCapabilities.retrieveFileContent,
          const ExternalFileQuery('needle'),
          session: h.s.session,
          context: context,
          responseAvailable: () => false);
      expect(lost.output, isNull);
      expect(lost.failure, CapabilityFailure.externalResponseLost);
      expect(lost.receipt.status, CapabilityExecutionStatus.completed);
      expect(lost.receipt.knownEffect, CapabilityEffect.derivedCache);
      final warm = await gateway.execute(
          ExternalCapabilities.retrieveFileContent,
          const ExternalFileQuery('needle'),
          session: h.s.session,
          context: context);
      expect(warm.output!.items, isNotEmpty);
      expect(warm.receipt.knownEffect, CapabilityEffect.none);
    });

    test(
        'derived cache commit followed by revoke releases no data and preserves effect',
        () async {
      final context = await gateway.openRead(
          session: h.s.session, context: await h.approved());
      h.index.afterSearch =
          () => h.s.management.revokeGrant(h.s.profile, h.revision);
      final result = await gateway.execute(
          ExternalCapabilities.retrieveFileContent,
          const ExternalFileQuery('needle'),
          session: h.s.session,
          context: context);
      expect(result.output, isNull);
      expect(result.receipt.status, CapabilityExecutionStatus.outcomeUnknown);
      expect(result.receipt.knownEffect, CapabilityEffect.derivedCache);
    });

    for (final deadline in [false, true]) {
      test(
          'File READ ${deadline ? "timeout" : "cancel"} keeps unknown cache outcome and underlying slot',
          () async {
        final context = await gateway.openRead(
            session: h.s.session, context: await h.approved());
        final entered = Completer<void>(), resume = Completer<void>();
        h.index.beforeBuild = () async {
          entered.complete();
          await resume.future;
        };
        final control = h.s.control();
        final pending = gateway.execute(
            ExternalCapabilities.retrieveFileContent,
            const ExternalFileQuery('needle'),
            session: h.s.session,
            context: context,
            control: control);
        await entered.future;
        if (deadline) {
          h.s.clock.current = h.s.clock.current.add(const Duration(seconds: 3));
          // Existing READ service uses its own bounded cooperative deadline.
        } else {
          control.cancel();
        }
        final result = await pending;
        expect(result.output, isNull);
        expect(result.receipt.status, CapabilityExecutionStatus.outcomeUnknown);
        expect(result.receipt.knownEffect, isNull);
        expect(h.read.pendingCount, 1);
        resume.complete();
        await h.read.whenIdle;
        expect(h.read.pendingCount, 0);
      });
    }

    test(
        'metadata selections tolerate a damaged payload without loading bodies',
        () async {
      final artifact = (await h.metadata.findCurrentByFileId('file-b'))!;
      await File(p.join(h.managed.path, artifact.storageKey))
          .writeAsString('corrupt');
      final parent = await h.context();
      final owningReads = h.observed.reads;
      final direct = await h.read
          .listFileSelections(session: h.s.session, context: parent);
      expect(direct.items, hasLength(2));
      expect(h.observed.reads, owningReads);
      final context =
          await gateway.openRead(session: h.s.session, context: parent);
      final kernelReads = h.observed.reads;
      final choices = await gateway.execute(
          ExternalCapabilities.listFileSelections, const ExternalNoInput(),
          session: h.s.session, context: context);
      expect(choices.failure, isNull);
      expect(choices.receipt.status, CapabilityExecutionStatus.completed);
      expect(choices.receipt.knownEffect, CapabilityEffect.none);
      expect(choices.output!.items, hasLength(2));
      expect(h.observed.reads, kernelReads,
          reason: 'metadata selection must not reload F1 document bodies');
    });

    test('P7 creation fails closed for the damaged file choice', () async {
      final artifact = (await h.metadata.findCurrentByFileId('file-b'))!;
      await File(p.join(h.managed.path, artifact.storageKey))
          .writeAsString('corrupt');
      final parent = await h.context();
      final context =
          await gateway.openRead(session: h.s.session, context: parent);
      final choices = await gateway.execute(
          ExternalCapabilities.listFileSelections, const ExternalNoInput(),
          session: h.s.session, context: context);
      expect(choices.output, isNotNull);
      var created = 0;
      var corrupt = 0;
      for (final item in choices.output!.items) {
        final outcome = await gateway.execute(
            ExternalCapabilities.createFileContext,
            ExternalFileSelections([item['fileRef']! as String]),
            session: h.s.session,
            context: context);
        if (outcome.output != null) {
          created++;
        } else if (outcome.failure ==
            CapabilityFailure.externalReadDataCorrupt) {
          corrupt++;
        }
      }
      expect(created, 1);
      expect(corrupt, 1);
    });

    test('P7 content release still verifies the damaged F1 payload', () async {
      final fileContext = await h.approved();
      final artifact = (await h.metadata.findCurrentByFileId('file-a'))!;
      await File(p.join(h.managed.path, artifact.storageKey))
          .writeAsString('corrupt');
      final execution =
          await gateway.openRead(session: h.s.session, context: fileContext);
      final result = await gateway.execute(
          ExternalCapabilities.retrieveFileContent,
          const ExternalFileQuery('needle'),
          session: h.s.session,
          context: execution);
      expect(result.output, isNull);
      expect(result.failure, CapabilityFailure.externalReadDataCorrupt);
    });
  });

  test(
      'P7 stays protocol-neutral with private identity construction and no Host',
      () {
    final source =
        File('lib/application/capabilities/external_capabilities.dart')
            .readAsStringSync();
    for (final token in [
      'dart:io',
      'package:mcp_dart',
      'package:flutter/',
      'DatabaseHelper',
      'Socket(',
      'ServerSocket',
      'jsonDecode',
      'fromJson'
    ]) {
      expect(source, isNot(contains(token)), reason: token);
    }
    expect(source, contains('ExternalExecutionContext._('));
  });
}

import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/capabilities/capability.dart';
import 'package:shiroha_quiz/application/external/external_authorization.dart';
import 'package:shiroha_quiz/application/external/external_generated_stage.dart';
import 'package:shiroha_quiz/data/repositories/generated_proposal_reader.dart';
import 'package:shiroha_quiz/data/repositories/generated_proposal_repository.dart';
import 'package:shiroha_quiz/domain/generated_question/generated_question_contract.dart';
import 'durable_stage_test_support.dart';

void main() {
  initializeGeneratedTests();
  late DurableStageHarness s;
  setUp(() async {
    s = DurableStageHarness();
    await s.open();
  });
  tearDown(() async => s.close());
  Future<void> mode(ExternalGenerationMode value) async {
    final revision = (await s.management.read(s.profile)).profile.grantRevision;
    await s.management.replaceGrant(
        s.profile,
        revision,
        ExternalGrantPolicy(
            permissions: [
              CapabilityPermission.read,
              CapabilityPermission.stage
            ],
            scopes: [],
            categories: ExternalContentCategory.values,
            allContent: true,
            generationMode: value));
  }

  Future<void> counts(int proposals, int questions, int receipts) async {
    expect(await s.h.count('generated_question_proposals'), proposals);
    expect(await s.h.count('questions'), questions);
    expect(await s.h.count('generated_question_commit_receipts'), receipts);
  }

  void completed(ExternalStageResult r, CapabilityEffect effect) {
    expect(r.status, CapabilityExecutionStatus.completed,
        reason: '${r.failure}');
    expect(r.effect, effect);
    expect(r.output, isNotNull);
  }

  test('review policy produces only a pending draft', () async {
    await mode(ExternalGenerationMode.review);
    final r = await s.stage();
    completed(r, CapabilityEffect.proposalStaged);
    final p = await readGeneratedProposal(s.h.db, r.output!.proposalId);
    expect(p.lifecycleStatus, GeneratedStatus.pendingReview);
    await counts(1, 0, 0);
  });
  test(
      'direct policy atomically writes typed questions and receipt; replay and reopen are idempotent',
      () async {
    await mode(ExternalGenerationMode.direct);
    final r = await s.stage(items: [
      candidate(),
      candidate(key: 'second', stem: 'Second unique stem')
    ]);
    completed(r, CapabilityEffect.formalMutation);
    final p = await readGeneratedProposal(s.h.db, r.output!.proposalId);
    expect(p.lifecycleStatus, GeneratedStatus.committed);
    expect(p.reviewRevision, 1);
    await counts(1, 2, 1);
    await s.reopen();
    final recovered = await s.reconcile('external-key');
    completed(recovered, CapabilityEffect.formalMutation);
    expect(recovered.output!.proposalId, r.output!.proposalId);
    completed(
        await s.stage(items: [
          candidate(),
          candidate(key: 'second', stem: 'Second unique stem')
        ]),
        CapabilityEffect.formalMutation);
    await counts(1, 2, 1);
  });
  test('turning direct on never commits a previously staged key', () async {
    await mode(ExternalGenerationMode.review);
    final old = await s.stage();
    await mode(ExternalGenerationMode.direct);
    completed(await s.stage(), CapabilityEffect.proposalStaged);
    expect(
        (await readGeneratedProposal(s.h.db, old.output!.proposalId))
            .lifecycleStatus,
        GeneratedStatus.pendingReview);
    completed(await s.stage(key: 'new', items: [candidate(stem: 'New batch')]),
        CapabilityEffect.formalMutation);
    await counts(2, 1, 1);
  });
  test('concurrent same-key submissions create exactly one receipt', () async {
    await mode(ExternalGenerationMode.direct);
    final both = await Future.wait([s.stage(), s.stage()]);
    for (final r in both) {
      completed(r, CapabilityEffect.formalMutation);
    }
    expect(both.first.output!.proposalId, both.last.output!.proposalId);
    await counts(1, 1, 1);
  });
  test('duplicate admission rolls back the entire direct batch', () async {
    await mode(ExternalGenerationMode.direct);
    completed(await s.stage(), CapabilityEffect.formalMutation);
    final duplicate = await s.stage(key: 'duplicate');
    expect(duplicate.output, isNull);
    expect(duplicate.effect, CapabilityEffect.none);
    await counts(1, 1, 1);
  });
  test(
      'response loss preserves committed effect and original-key reconciliation',
      () async {
    await mode(ExternalGenerationMode.direct);
    final lost = await s.stage(responseAvailable: () => false);
    expect(lost.status, CapabilityExecutionStatus.outcomeUnknown);
    expect(lost.effect, CapabilityEffect.formalMutation);
    completed(
        await s.reconcile('external-key'), CapabilityEffect.formalMutation);
    await counts(1, 1, 1);
  });
  test('policy revision change refuses an old approved context', () async {
    await mode(ExternalGenerationMode.direct);
    final approved = await s.context();
    await mode(ExternalGenerationMode.review);
    final r = await s.stage(approved: approved);
    expect(r.output, isNull);
    await counts(0, 0, 0);
    completed(await s.stage(), CapabilityEffect.proposalStaged);
    await counts(1, 0, 0);
  });
  test('cancel at final commit boundary rolls back proposal and questions',
      () async {
    await mode(ExternalGenerationMode.direct);
    final entered = Completer<void>(), release = Completer<void>();
    s.checkpoint = (point) async {
      if (point == ExternalStageCheckpoint.beforeCommit) {
        entered.complete();
        await release.future;
      }
    };
    final control = s.control();
    final work = s.stage(call: control);
    await entered.future;
    control.cancel();
    release.complete();
    await work;
    await s.service.whenIdle;
    await counts(0, 0, 0);
  });
}

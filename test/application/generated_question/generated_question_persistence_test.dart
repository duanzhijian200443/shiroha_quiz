import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/generated_question/generated_question_service.dart';
import 'package:shiroha_quiz/domain/generated_question/generated_question_contract.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2_codec.dart';
import 'package:shiroha_quiz/data/repositories/question_repository.dart';
import 'package:shiroha_quiz/data/models/persisted_question.dart';
import 'generated_test_support.dart';

void main() {
  initializeGeneratedTests();
  late GeneratedHarness h;
  setUp(() async {
    h = GeneratedHarness();
    await h.open();
  });
  tearDown(() async => h.close());
  test('whole-batch rejection stages zero rows', () async {
    final bad = candidate(key: 'bad');
    bad['storageId'] = 'injected';
    await expectLater(
        () =>
            h.service.stage(submission(items: [candidate(), bad]), h.origin()),
        throwsA(isA<GeneratedQuestionException>()));
    expect(await h.count('generated_question_proposals'), 0);
    expect(await h.count('questions'), 0);
  });
  test('durable same-key response-loss reconciliation and content conflict',
      () async {
    final a = await h.stage();
    await h.reopen();
    final b = await h.stage();
    expect(b.proposalId, a.proposalId);
    expect(await h.count('generated_question_proposals'), 1);
    await expectLater(h.stage(items: [candidate(stem: 'Different')]),
        failure(GeneratedFailure.idempotencyConflict));
    expect(await h.count('generated_question_proposals'), 1);
  });
  test('concurrent same-key submissions have one persisted winner', () async {
    final results = await Future.wait([h.stage(), h.stage()]);
    expect(results[0].proposalId, results[1].proposalId);
    expect(await h.count('generated_question_proposals'), 1);
  });
  test('count mismatch and uncited state are durable', () async {
    final p =
        (await h.service.stage(submission(requested: 3), h.origin())).proposal;
    expect(p.actualCount, 1);
    expect(p.requestedCount, 3);
    expect(p.countMismatchWarning, isTrue);
    expect(p.items.single.evidence, isEmpty);
    await h.reopen();
    expect(
        (await h.repository.read(p.proposalId, h.local)).countMismatchWarning,
        isTrue);
  });
  test(
      'typed working edits, original immutability, flush revision and CAS survive reopen',
      () async {
    final p = await h.stage();
    final original =
        const QuestionDraftV2Codec().encode(p.items.single.original);
    final next = await h.flush(p, [
      {
        'type': 'edit',
        'edit': {
          'itemId': p.items.single.itemId,
          'field': 'stem',
          'value': [
            {'type': 'text', 'text': 'Changed '},
            {'type': 'inline_math', 'latex': 'x+1'}
          ]
        }
      },
      {
        'type': 'decide',
        'itemId': p.items.single.itemId,
        'decision': 'accepted'
      }
    ]);
    expect(next.reviewRevision, 1);
    expect(next.items.single.decision, GeneratedDecision.accepted);
    await expectLater(h.decide(p), failure(GeneratedFailure.staleRevision));
    await h.reopen();
    final restored = await h.repository.read(p.proposalId, h.local);
    expect(const QuestionDraftV2Codec().encode(restored.items.single.original),
        original);
    expect(restored.items.single.working, next.items.single.working);
    final receipt = await h.service.approve(h.approval(restored), h.local);
    expect(receipt.reviewRevision, 1);
    await expectLater(
        h.decide(restored), failure(GeneratedFailure.terminalConflict));
  });
  test(
      'single terminal commit, partial selection, independent typed Questions and durable receipt',
      () async {
    final p = await h.stage(
        items: [candidate(key: 'a'), candidate(key: 'b', stem: 'Second stem')]);
    final reviewed = await h.flush(p, [
      {'type': 'decide', 'itemId': p.items[0].itemId, 'decision': 'accepted'},
      {'type': 'decide', 'itemId': p.items[1].itemId, 'decision': 'rejected'}
    ]);
    final receipt = await h.service.approve(h.approval(reviewed), h.local);
    expect(await h.count('questions'), 1);
    expect(await h.count('question_v2_payloads'), 1);
    expect(await h.count('review_states'), 1);
    expect(await h.count('generated_question_commit_items'), 1);
    expect(await h.count('import_tasks'), 0);
    final questions = await QuestionRepository(databaseHelper: h.helper)
        .getPersistedQuestionsByBank('bank');
    expect(questions.single, isA<TypedPersistedQuestion>());
    await h.reopen();
    final retry = await h.service.approve(h.approval(reviewed), h.local);
    expect(retry.toJson(), receipt.toJson());
    expect(await h.count('questions'), 1);
    await expectLater(
        h.service
            .approve(h.approval(reviewed, ids: [p.items[1].itemId]), h.local),
        failure(GeneratedFailure.terminalConflict));
    await expectLater(
        h.service.approve(h.approval(reviewed, revision: 0), h.local),
        failure(GeneratedFailure.terminalConflict));
    // Formal content reads independently; historical proposal tables aren't joined.
    final payload = await h.db.query('question_v2_payloads');
    expect(jsonDecode(payload.single['payload_json'] as String)['questionId'],
        reviewed.items[0].working.questionId);
  });
  for (final decision in ['unreviewed', 'deferred']) {
    test('$decision blocks approval with zero writes', () async {
      var p = await h.stage();
      if (decision != 'unreviewed') {
        p = await h.flush(p, [
          {
            'type': 'decide',
            'itemId': p.items.single.itemId,
            'decision': decision
          }
        ]);
      }
      await expectLater(
          h.service
              .approve(h.approval(p, ids: [p.items.single.itemId]), h.local),
          failure(GeneratedFailure.reviewIncomplete));
      expect(await h.count('questions'), 0);
    });
  }
  test('all-rejected uses explicit rejection, never zero-question commit',
      () async {
    final p = await h.decide(await h.stage(), accepted: false);
    final command = RejectGeneratedProposalCommand.fromJson({
      'proposalId': p.proposalId,
      'expectedReviewRevision': p.reviewRevision
    });
    final result = await h.service.reject(command, h.local);
    expect(result.lifecycleStatus, GeneratedStatus.rejected);
    expect((await h.service.reject(command, h.local)).proposalId, p.proposalId);
    expect(await h.count('questions'), 0);
    expect(await h.count('generated_question_commit_receipts'), 0);
  });
  test('local authorization remains required for read, write and receipt retry',
      () async {
    final p = await h.decide(await h.stage());
    await h.service.approve(h.approval(p), h.local);
    h.authorized = false;
    expect(() => h.repository.read(p.proposalId, h.local),
        failure(GeneratedFailure.unauthorized));
    expect(() => h.service.approve(h.approval(p), h.local),
        failure(GeneratedFailure.unauthorized));
  });
  test(
      'foreign and absent proposal IDs are indistinguishable for read, flush, approve and reject',
      () async {
    final p = await h.decide(await h.stage());
    const absent = '99999999-9999-4999-8999-999999999999';
    final foreign = GeneratedLocalContext(
        localOwner: 'other', confirmedTarget: h.target, isCurrent: () => true);
    GeneratedReviewFlush flushOf(String id) => GeneratedReviewFlush.fromJson({
          'proposalId': id,
          'expectedReviewRevision': p.reviewRevision,
          'operations': [
            {
              'type': 'decide',
              'itemId': p.items.single.itemId,
              'decision': 'accepted'
            }
          ]
        });
    Future<GeneratedReceipt> approveOf(String id) => h.service.approve(
        ApproveGeneratedProposalCommand.fromJson({
          'proposalId': id,
          'expectedReviewRevision': p.reviewRevision,
          'approvedItemIds': [p.items.single.itemId]
        }),
        foreign);
    Future<GeneratedQuestionProposal> rejectOf(String id) => h.service.reject(
        RejectGeneratedProposalCommand.fromJson(
            {'proposalId': id, 'expectedReviewRevision': p.reviewRevision}),
        foreign);
    for (final id in [p.proposalId, absent]) {
      await expectLater(h.repository.read(id, foreign),
          failure(GeneratedFailure.proposalUnavailable));
      await expectLater(
          h.repository.evidenceState(id, p.items.single.itemId, foreign),
          failure(GeneratedFailure.proposalUnavailable));
      await expectLater(h.service.flush(flushOf(id), foreign),
          failure(GeneratedFailure.proposalUnavailable));
      await expectLater(
          approveOf(id), failure(GeneratedFailure.proposalUnavailable));
      await expectLater(
          rejectOf(id), failure(GeneratedFailure.proposalUnavailable));
    }
    expect((await h.repository.read(p.proposalId, h.local)).lifecycleStatus,
        GeneratedStatus.pendingReview);
    expect(await h.count('questions'), 0);
  });
  test('within-batch and different-key pending duplicates block commits',
      () async {
    final a = await h.stage();
    final b = await h.service.stage(submission(key: 'other'), h.origin());
    expect(b.duplicateItemIds, isNotEmpty);
    final reviewed = await h.decide(a);
    await expectLater(h.service.approve(h.approval(reviewed), h.local),
        failure(GeneratedFailure.duplicateContent));
    final rejected = await h.decide(b.proposal, accepted: false);
    await h.service.reject(
        RejectGeneratedProposalCommand.fromJson({
          'proposalId': rejected.proposalId,
          'expectedReviewRevision': rejected.reviewRevision
        }),
        h.local);
    await h.service.approve(h.approval(reviewed), h.local);
    final third = await h.decide(await h.stage(key: 'third'));
    await expectLater(h.service.approve(h.approval(third), h.local),
        failure(GeneratedFailure.duplicateContent));
    expect(await h.count('questions'), 1);
    final batch = await h.decide(await h.stage(key: 'batch', items: [
      candidate(key: 'x', stem: 'Equal'),
      candidate(key: 'y', stem: 'Equal')
    ]));
    await expectLater(h.service.approve(h.approval(batch), h.local),
        failure(GeneratedFailure.duplicateContent));
  });
  test('current target drift blocks until explicit rebind and fresh review',
      () async {
    final p = await h.decide(await h.stage());
    await h.db.update('bank_folders', {'folder_name': 'moved'},
        where: 'bank_name=?', whereArgs: ['bank']);
    await expectLater(h.service.approve(h.approval(p), h.local),
        failure(GeneratedFailure.targetChanged));
    h.target = GeneratedTarget(
        bankName: 'bank',
        folderName: 'moved',
        projectId: null,
        projectBankNames: []);
    final rebound = await h.flush(p, [
      {'type': 'rebind', 'target': h.target.toJson()}
    ]);
    expect(rebound.items.single.decision, GeneratedDecision.unreviewed);
    expect(rebound.originalTarget.folderName, 'folder');
    final reviewed = await h.decide(rebound);
    await h.service.approve(h.approval(reviewed), h.local);
    expect(await h.count('questions'), 1);
  });
  test('concurrent identical approvals return one receipt', () async {
    final p = await h.decide(await h.stage());
    final receipts = await Future.wait([
      h.service.approve(h.approval(p), h.local),
      h.service.approve(h.approval(p), h.local)
    ]);
    expect(receipts[0].toJson(), receipts[1].toJson());
    expect(await h.count('questions'), 1);
  });
  test('approve/reject race has exactly one terminal outcome', () async {
    final p = await h.decide(await h.stage());
    final rejection = RejectGeneratedProposalCommand.fromJson({
      'proposalId': p.proposalId,
      'expectedReviewRevision': p.reviewRevision
    });
    final outcomes = await Future.wait<Object>([
      h.service
          .approve(h.approval(p), h.local)
          .then<Object>((v) => v)
          .catchError((Object e) => e),
      h.service
          .reject(rejection, h.local)
          .then<Object>((v) => v)
          .catchError((Object e) => e)
    ]);
    expect(outcomes.whereType<GeneratedReceipt>(), hasLength(1));
    expect((await h.repository.read(p.proposalId, h.local)).lifecycleStatus,
        GeneratedStatus.committed);
    expect(await h.count('questions'), 1);
  });
  for (final entry in {
    'questions': 'INSERT',
    'question_v2_payloads': 'INSERT',
    'review_states': 'INSERT',
    'bank_folders': 'INSERT',
    'generated_question_commit_items': 'INSERT',
    'generated_question_commit_receipts': 'INSERT',
    'generated_question_proposals': 'UPDATE'
  }.entries) {
    test(
        'real transaction failure ${entry.key} rolls back every write and retry succeeds',
        () async {
      final p = await h.decide(await h.stage());
      await h.db.execute(
          "CREATE TEMP TRIGGER r5a_injected BEFORE ${entry.value} ON ${entry.key} BEGIN SELECT RAISE(ABORT,'synthetic_failure'); END;");
      await expectLater(h.service.approve(h.approval(p), h.local),
          failure(GeneratedFailure.persistenceFailed));
      for (final table in [
        'questions',
        'question_v2_payloads',
        'review_states',
        'generated_question_commit_items',
        'generated_question_commit_receipts'
      ]) {
        expect(await h.count(table), 0, reason: table);
      }
      expect((await h.repository.read(p.proposalId, h.local)).lifecycleStatus,
          GeneratedStatus.pendingReview);
      expect(
          (await h.db.query('bank_folders')).single['folder_name'], 'folder');
      await h.db.execute('DROP TRIGGER r5a_injected');
      await h.service.approve(h.approval(p), h.local);
      expect(await h.count('questions'), 1);
    });
  }
  test('CAS zero affected rows rolls back pre-CAS inserts and can retry',
      () async {
    final p = await h.decide(await h.stage());
    await h.db.execute(
        "CREATE TEMP TRIGGER r5a_ignore BEFORE UPDATE ON generated_question_proposals WHEN NEW.lifecycle_status='committed' BEGIN SELECT RAISE(IGNORE); END;");
    await expectLater(h.service.approve(h.approval(p), h.local),
        failure(GeneratedFailure.staleRevision));
    expect(await h.count('questions'), 0);
    expect(await h.count('generated_question_commit_receipts'), 0);
    await h.db.execute('DROP TRIGGER r5a_ignore');
    await h.service.approve(h.approval(p), h.local);
  });

  for (final table in ['questions', 'question_v2_payloads', 'review_states']) {
    test('ignored $table insert cannot produce a false committed receipt',
        () async {
      final p = await h.decide(await h.stage());
      await h.db.execute(
          "CREATE TEMP TRIGGER r5a_ignore BEFORE INSERT ON $table BEGIN SELECT RAISE(IGNORE); END;");
      await expectLater(h.service.approve(h.approval(p), h.local),
          failure(GeneratedFailure.persistenceFailed));
      for (final owned in [
        'questions',
        'question_v2_payloads',
        'review_states',
        'generated_question_commit_items',
        'generated_question_commit_receipts'
      ]) {
        expect(await h.count(owned), 0);
      }
      expect((await h.repository.read(p.proposalId, h.local)).lifecycleStatus,
          GeneratedStatus.pendingReview);
      await h.db.execute('DROP TRIGGER r5a_ignore');
      await h.service.approve(h.approval(p), h.local);
      expect(await h.count('questions'), 1);
    });
  }
  test(
      'ignored working-copy update does not advance the successful flush revision',
      () async {
    final p = await h.stage();
    await h.db.execute(
        "CREATE TEMP TRIGGER r5a_ignore BEFORE UPDATE ON generated_question_review_state BEGIN SELECT RAISE(IGNORE); END;");
    await expectLater(h.decide(p), failure(GeneratedFailure.persistenceFailed));
    final restored = await h.repository.read(p.proposalId, h.local);
    expect(restored.reviewRevision, p.reviewRevision);
    expect(restored.items.single.decision, GeneratedDecision.unreviewed);
    await h.db.execute('DROP TRIGGER r5a_ignore');
    expect((await h.decide(p)).reviewRevision, 1);
  });
  for (final rejectFirst in [false, true]) {
    test(
        'review flush versus approve/reject races yield one terminal winner (reject first $rejectFirst)',
        () async {
      final p = await h.decide(await h.stage());
      Future<Object> approve() => h.service
          .approve(h.approval(p), h.local)
          .then<Object>((v) => v)
          .catchError((Object e) => e);
      Future<Object> reject() async {
        try {
          final rejected = await h.decide(p, accepted: false);
          return await h.service.reject(
              RejectGeneratedProposalCommand.fromJson({
                'proposalId': p.proposalId,
                'expectedReviewRevision': rejected.reviewRevision
              }),
              h.local);
        } on GeneratedQuestionException catch (e) {
          return e;
        }
      }

      final results = await Future.wait(
          rejectFirst ? [reject(), approve()] : [approve(), reject()]);
      expect(
          results.where(
              (v) => v is GeneratedReceipt || v is GeneratedQuestionProposal),
          hasLength(1));
      expect((await h.repository.read(p.proposalId, h.local)).lifecycleStatus,
          rejectFirst ? GeneratedStatus.rejected : GeneratedStatus.committed);
      expect(await h.count('questions'), rejectFirst ? 0 : 1);
    });
  }
  test(
      'kind changes and structural option edits are rejected before review writes',
      () async {
    final p = await h.stage(items: [candidate(kind: 'singleChoice')]);
    for (final field in ['kind', 'options']) {
      await expectLater(
          () => h.flush(p, [
                {
                  'type': 'edit',
                  'edit': {
                    'field': field,
                    'itemId': p.items.single.itemId,
                    'value': []
                  }
                }
              ]),
          failure(GeneratedFailure.invalidEdit));
    }
    final option = p.items.single.working.options.first;
    final edited = await h.flush(p, [
      {
        'type': 'edit',
        'edit': {
          'field': 'optionContent',
          'itemId': p.items.single.itemId,
          'optionId': option.optionId,
          'value': [
            {'type': 'inline_math', 'latex': 'x=1'}
          ]
        }
      }
    ]);
    expect(edited.items.single.working.options.last,
        p.items.single.working.options.last);
    expect(edited.items.single.working.options.first.optionId, option.optionId);
    expect(edited.items.single.original, p.items.single.original);
  });
}

// SPL-1-D0 draft service tests: normalized staging, fingerprint replay
// dedup, one-active-per-source-turn, the atomic transient lifecycle gate,
// intent-ordered staging, replay-without-re-admission, and bounded failure
// mapping. All lifecycle assertions are eligibility/state only: D0 performs
// zero durable writes.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/study_plan/study_plan_draft_service.dart';
import 'package:shiroha_quiz/application/study_plan/study_plan_ports.dart';
import 'package:shiroha_quiz/domain/conversations/conversation.dart';
import 'package:shiroha_quiz/domain/study_plan/study_plan_draft.dart';
import 'package:shiroha_quiz/domain/study_plan/study_plan_values.dart';

const String _conversationId = 'conv_a_001';
const String _messageId = 'msg_a_user_001';

final DateTime _now = DateTime.fromMillisecondsSinceEpoch(2000, isUtc: true);

StudyPlanPlanningContext _context({int questionCount = 100}) {
  return StudyPlanPlanningContext(
    bankName: 'Math',
    questionCount: questionCount,
    masteredCount: 20,
    dueCount: 30,
    weakCount: 5,
    newCount: 40,
  );
}

class _FakePlanningPort implements StudyPlanPlanningPort {
  _FakePlanningPort(this.result);

  StudyPlanPlanningAdmission result;

  /// When set, the next read throws this bounded failure.
  StudyPlanReadException? error;
  int calls = 0;

  @override
  Future<StudyPlanPlanningAdmission> loadPlanningContext({
    required ConversationScope sourceScope,
    required String bankName,
    required DateTime now,
  }) async {
    calls++;
    final error = this.error;
    if (error != null) throw error;
    return result;
  }
}

class _ThrowingPlanningPort implements StudyPlanPlanningPort {
  @override
  Future<StudyPlanPlanningAdmission> loadPlanningContext({
    required ConversationScope sourceScope,
    required String bankName,
    required DateTime now,
  }) async {
    throw const StudyPlanReadException(StudyPlanReadFailure.unavailable);
  }
}

/// Deterministic delayed planning port driven by explicit Completers.
///
/// Reads are handed out in invocation order; the test completes them in the
/// exact order it chooses. No sleeps, no timing assumptions.
class _DelayedPlanningPort implements StudyPlanPlanningPort {
  final List<Completer<StudyPlanPlanningAdmission>> _pending = [];

  @override
  Future<StudyPlanPlanningAdmission> loadPlanningContext({
    required ConversationScope sourceScope,
    required String bankName,
    required DateTime now,
  }) {
    final completer = Completer<StudyPlanPlanningAdmission>();
    _pending.add(completer);
    return completer.future;
  }

  int get pendingCount => _pending.length;

  void complete(int index, StudyPlanPlanningAdmission admission) {
    _pending[index].complete(admission);
  }
}

class _Harness {
  _Harness({StudyPlanPlanningAdmission? admission})
      : port = _FakePlanningPort(
          admission ?? StudyPlanPlanningAdmitted(_context()),
        ) {
    service = StudyPlanDraftService(
      planningPort: port,
      draftIdFactory: () => 'draft_${_nextId++}',
      clock: () => _now,
    );
  }

  final _FakePlanningPort port;
  late final StudyPlanDraftService service;
  int _nextId = 0;

  Future<StudyPlanStageResult> stage({
    String conversationId = _conversationId,
    String messageId = _messageId,
    ConversationScope? scope,
    String bankName = 'Math',
    String? goal,
    int? dailyTarget,
    StudyPlanPriority? priority,
    int? horizonDays,
  }) {
    return service.stage(
      sourceConversationId: conversationId,
      sourceMessageId: messageId,
      sourceScope: scope ?? ConversationScope.global(),
      bankName: bankName,
      goal: goal,
      dailyTarget: dailyTarget,
      priority: priority,
      horizonDays: horizonDays,
    );
  }
}

void main() {
  test('1. first valid stage creates a pending draft with normalized fields',
      () async {
    final harness = _Harness();
    final result = await harness.stage(goal: '  Master  math  ');
    expect(result, isA<StudyPlanStageResultStaged>());
    final draft = (result as StudyPlanStageResultStaged).draft;
    expect(draft.outcome, StudyPlanDraftOutcome.pending);
    expect(draft.bankName, 'Math');
    expect(draft.goal, 'Master math');
    expect(draft.dailyTarget, 40);
    expect(draft.priority, StudyPlanPriority.balanced);
    expect(draft.sourceConversationId, _conversationId);
    expect(draft.sourceMessageId, _messageId);
    expect(draft.sourceScope, ConversationScope.global());
    expect(draft.preview.questionCount, 100);
    expect(draft.preview.estimatedDays, 2); // ceil(80 / 40)
  });

  test('2. same fingerprint replay reuses the same draft id', () async {
    final harness = _Harness();
    final first = (await harness.stage()) as StudyPlanStageResultStaged;
    final second = (await harness.stage()) as StudyPlanStageResultStaged;
    expect(second.draft.draftId, first.draft.draftId);
    expect(second.draft.outcome, StudyPlanDraftOutcome.pending);
  });

  test('3. omitted defaults and explicit defaults replay identically',
      () async {
    final harness = _Harness();
    final omitted = (await harness.stage()) as StudyPlanStageResultStaged;
    final explicit = (await harness.stage(
      dailyTarget: 40,
      priority: StudyPlanPriority.balanced,
    )) as StudyPlanStageResultStaged;
    expect(explicit.draft.draftId, omitted.draft.draftId);
  });

  test(
      '4. different payload on the same turn supersedes pending and stages '
      'a new pending draft', () async {
    final harness = _Harness();
    final first =
        (await harness.stage(dailyTarget: 30)) as StudyPlanStageResultStaged;
    final second =
        (await harness.stage(dailyTarget: 50)) as StudyPlanStageResultStaged;
    expect(harness.service.draftById(first.draft.draftId).outcome,
        StudyPlanDraftOutcome.superseded);
    expect(second.draft.draftId, isNot(first.draft.draftId));
    expect(second.draft.outcome, StudyPlanDraftOutcome.pending);
    expect(second.draft.dailyTarget, 50);
  });

  test('5. explicit reject transitions pending -> rejected', () async {
    final harness = _Harness();
    final staged = (await harness.stage()) as StudyPlanStageResultStaged;
    final rejected = harness.service.rejectDraft(staged.draft.draftId);
    expect(rejected.outcome, StudyPlanDraftOutcome.rejected);
  });

  test(
      '6. rejected replay never reactivates; a different payload starts a '
      'new pending draft', () async {
    final harness = _Harness();
    final staged = (await harness.stage()) as StudyPlanStageResultStaged;
    harness.service.rejectDraft(staged.draft.draftId);

    final replay = (await harness.stage()) as StudyPlanStageResultStaged;
    expect(replay.draft.draftId, staged.draft.draftId);
    expect(replay.draft.outcome, StudyPlanDraftOutcome.rejected);

    final revised =
        (await harness.stage(dailyTarget: 60)) as StudyPlanStageResultStaged;
    expect(revised.draft.draftId, isNot(staged.draft.draftId));
    expect(revised.draft.outcome, StudyPlanDraftOutcome.pending);
  });

  test('7. beginCommit transitions pending -> committing atomically', () async {
    final harness = _Harness();
    final staged = (await harness.stage()) as StudyPlanStageResultStaged;
    final committing = harness.service.beginCommit(staged.draft.draftId);
    expect(committing.outcome, StudyPlanDraftOutcome.committing);
  });

  test('8. reject after committing cannot change the committing state',
      () async {
    final harness = _Harness();
    final staged = (await harness.stage()) as StudyPlanStageResultStaged;
    harness.service.beginCommit(staged.draft.draftId);
    final afterReject = harness.service.rejectDraft(staged.draft.draftId);
    expect(afterReject.outcome, StudyPlanDraftOutcome.committing);
    expect(afterReject.draftId, staged.draft.draftId);
  });

  test(
      '9. revised proposal while committing is a bounded busy result: no '
      'supersede, no second pending draft', () async {
    final harness = _Harness();
    final staged = (await harness.stage()) as StudyPlanStageResultStaged;
    harness.service.beginCommit(staged.draft.draftId);

    final busy1 = await harness.stage(dailyTarget: 70);
    expect(busy1, isA<StudyPlanStageResultBusy>());
    final busy2 = await harness.stage(dailyTarget: 80);
    expect(busy2, isA<StudyPlanStageResultBusy>());

    expect(harness.service.draftById(staged.draft.draftId).outcome,
        StudyPlanDraftOutcome.committing);
    // The committing draft stays the only draft for the turn.
    final replay = (await harness.stage()) as StudyPlanStageResultStaged;
    expect(replay.draft.draftId, staged.draft.draftId);
    expect(replay.draft.outcome, StudyPlanDraftOutcome.committing);
  });

  test('10. a superseded draft cannot beginCommit', () async {
    final harness = _Harness();
    final first =
        (await harness.stage(dailyTarget: 30)) as StudyPlanStageResultStaged;
    await harness.stage(dailyTarget: 50);
    final gate = harness.service.beginCommit(first.draft.draftId);
    expect(gate.outcome, StudyPlanDraftOutcome.superseded);
  });

  test('11. a rejected draft cannot beginCommit', () async {
    final harness = _Harness();
    final staged = (await harness.stage()) as StudyPlanStageResultStaged;
    harness.service.rejectDraft(staged.draft.draftId);
    final gate = harness.service.beginCommit(staged.draft.draftId);
    expect(gate.outcome, StudyPlanDraftOutcome.rejected);
  });

  test('12. committed drafts replay as committed and never reactivate',
      () async {
    final harness = _Harness();
    final staged = (await harness.stage()) as StudyPlanStageResultStaged;
    harness.service.beginCommit(staged.draft.draftId);
    harness.service.markCommitted(staged.draft.draftId);
    expect(harness.service.draftById(staged.draft.draftId).outcome,
        StudyPlanDraftOutcome.committed);

    final replay = (await harness.stage()) as StudyPlanStageResultStaged;
    expect(replay.draft.draftId, staged.draft.draftId);
    expect(replay.draft.outcome, StudyPlanDraftOutcome.committed);

    final gate = harness.service.beginCommit(staged.draft.draftId);
    expect(gate.outcome, StudyPlanDraftOutcome.committed);
  });

  test('13. markCommitted only accepts a committing draft', () async {
    final harness = _Harness();
    final staged = (await harness.stage()) as StudyPlanStageResultStaged;
    final noOp = harness.service.markCommitted(staged.draft.draftId);
    expect(noOp.outcome, StudyPlanDraftOutcome.pending);
  });

  test('14. sourceScope participates in the fingerprint', () async {
    final harness = _Harness();
    final global = (await harness.stage()) as StudyPlanStageResultStaged;
    final learningSpace = (await harness.stage(
      scope: ConversationScope.learningSpace('project_1'),
    )) as StudyPlanStageResultStaged;
    expect(learningSpace.draft.draftId, isNot(global.draft.draftId));
    expect(harness.service.draftById(global.draft.draftId).outcome,
        StudyPlanDraftOutcome.superseded);
    expect(learningSpace.draft.outcome, StudyPlanDraftOutcome.pending);
  });

  test(
      '15. concurrent staging of different payloads stays deterministic: '
      'only the latest proposal intent activates; older in-flight calls are '
      'stale with zero mutation', () async {
    final harness = _Harness();
    final results = await Future.wait(<Future<StudyPlanStageResult>>[
      harness.stage(dailyTarget: 30),
      harness.stage(dailyTarget: 50),
      harness.stage(dailyTarget: 70),
    ]);
    // With three different concurrent intents, only the newest reserved
    // intent (dailyTarget 70) may activate; the two older in-flight calls
    // become stale and must not create or supersede anything.
    final staged = <StudyPlanDraft>[
      for (final result in results)
        if (result is StudyPlanStageResultStaged) result.draft,
    ];
    final stale = results.whereType<StudyPlanStageResultStale>();
    expect(staged, hasLength(1));
    expect(stale, hasLength(2));
    expect(staged.single.outcome, StudyPlanDraftOutcome.pending);
    expect(staged.single.dailyTarget, 70);
    // Service state: exactly one pending draft exists (the deterministic id
    // sequence proves only one draft id was ever issued), zero superseded.
    expect(staged.single.draftId, 'draft_0');
    final pending = harness.service.draftById(staged.single.draftId);
    expect(pending.outcome, StudyPlanDraftOutcome.pending);
    expect(() => harness.service.draftById('draft_1'), throwsArgumentError,
        reason: 'no second draft id may ever be issued');
  });

  test(
      '16. invalid plan fields and unbounded source ids are bounded '
      'invalid results with zero state change', () async {
    final harness = _Harness();
    expect(await harness.stage(bankName: '   '),
        isA<StudyPlanStageResultInvalid>());
    expect(await harness.stage(goal: 'g' * 121),
        isA<StudyPlanStageResultInvalid>());
    expect(await harness.stage(conversationId: ''),
        isA<StudyPlanStageResultInvalid>());
    expect(await harness.stage(messageId: 'bad\u0000id'),
        isA<StudyPlanStageResultInvalid>());
    expect(harness.port.calls, 0);
  });

  test('17. planning denial maps to the shared unavailable result', () async {
    final harness = _Harness(
      admission: const StudyPlanPlanningUnavailable(),
    );
    expect(await harness.stage(), isA<StudyPlanStageResultUnavailable>());
  });

  test(
      '18. infrastructure read failure maps to a bounded '
      'temporarilyUnavailable exception', () async {
    final service = StudyPlanDraftService(
      planningPort: _ThrowingPlanningPort(),
      draftIdFactory: () => 'draft_x',
      clock: () => _now,
    );
    await expectLater(
      service.stage(
        sourceConversationId: _conversationId,
        sourceMessageId: _messageId,
        sourceScope: ConversationScope.global(),
        bankName: 'Math',
      ),
      throwsA(isA<StudyPlanException>().having(
        (e) => e.failure,
        'failure',
        StudyPlanFailure.temporarilyUnavailable,
      )),
    );
  });

  test('19. unknown draft ids throw ArgumentError without side effects',
      () async {
    final harness = _Harness();
    expect(() => harness.service.draftById('missing'), throwsArgumentError);
    expect(() => harness.service.beginCommit('missing'), throwsArgumentError);
    expect(() => harness.service.rejectDraft('missing'), throwsArgumentError);
  });

  test(
      '20. preview aggregates flow from the admitted context and '
      'estimatedDays is deterministic advisory math', () async {
    final harness = _Harness(
      admission: StudyPlanPlanningAdmitted(
        const StudyPlanPlanningContext(
          bankName: 'Math',
          questionCount: 101,
          masteredCount: 20,
          dueCount: 30,
          weakCount: 5,
          newCount: 40,
        ),
      ),
    );
    final staged =
        (await harness.stage(dailyTarget: 40)) as StudyPlanStageResultStaged;
    final preview = staged.draft.preview;
    expect(preview.questionCount, 101);
    expect(preview.masteredCount, 20);
    expect(preview.dueCount, 30);
    expect(preview.weakCount, 5);
    expect(preview.newCount, 40);
    expect(preview.estimatedDays, 3); // ceil(81 / 40)
  });

  group('P2-A proposal intent ordering', () {
    test(
        'older slow invocation never supersedes a newer proposal: B '
        'completed first stays the sole pending draft and stale A performs '
        'zero lifecycle mutation', () async {
      final port = _DelayedPlanningPort();
      var nextId = 0;
      final service = StudyPlanDraftService(
        planningPort: port,
        draftIdFactory: () => 'draft_${nextId++}',
        clock: () => _now,
      );

      // A invoked first, B invoked second; both planning reads pending.
      final futureA = service.stage(
        sourceConversationId: _conversationId,
        sourceMessageId: _messageId,
        sourceScope: ConversationScope.global(),
        bankName: 'Math',
        dailyTarget: 30,
      );
      final futureB = service.stage(
        sourceConversationId: _conversationId,
        sourceMessageId: _messageId,
        sourceScope: ConversationScope.global(),
        bankName: 'Math',
        dailyTarget: 50,
      );
      expect(port.pendingCount, 2);

      // Complete B first: B activates as pending.
      port.complete(1, StudyPlanPlanningAdmitted(_context()));
      final resultB = await futureB;
      expect(resultB, isA<StudyPlanStageResultStaged>());
      final draftB = (resultB as StudyPlanStageResultStaged).draft;
      expect(draftB.outcome, StudyPlanDraftOutcome.pending);
      expect(draftB.dailyTarget, 50);

      // Then complete A: its read finished later, so it must not supersede
      // B and must not create or mutate anything.
      port.complete(0, StudyPlanPlanningAdmitted(_context()));
      final resultA = await futureA;
      expect(resultA, isA<StudyPlanStageResultStale>());

      // B remains the sole current pending draft; no second draft exists.
      final current = service.draftById(draftB.draftId);
      expect(current.outcome, StudyPlanDraftOutcome.pending);
      expect(current.draftId, draftB.draftId);
      expect(() => service.draftById('draft_1'), throwsArgumentError,
          reason: 'stale A must never create a second draft');
      // A's fingerprint never entered the service, so replaying the A
      // payload later is a NEW proposal intent (not a semantic replay) and
      // legitimately supersedes B like any revised proposal.
      final replayFuture = service.stage(
        sourceConversationId: _conversationId,
        sourceMessageId: _messageId,
        sourceScope: ConversationScope.global(),
        bankName: 'Math',
        dailyTarget: 30,
      );
      expect(port.pendingCount, 3);
      port.complete(2, StudyPlanPlanningAdmitted(_context()));
      final replayA = await replayFuture;
      expect(replayA, isA<StudyPlanStageResultStaged>());
      final draftA = (replayA as StudyPlanStageResultStaged).draft;
      expect(draftA.draftId, isNot(draftB.draftId));
      expect(draftA.outcome, StudyPlanDraftOutcome.pending);
      expect(service.draftById(draftB.draftId).outcome,
          StudyPlanDraftOutcome.superseded);
    });

    test(
        'concurrent same fingerprint converges to one draft identity in '
        'either completion order', () async {
      Future<(StudyPlanStageResult, StudyPlanStageResult)> run(
        List<int> completionOrder,
      ) async {
        final port = _DelayedPlanningPort();
        var nextId = 0;
        final service = StudyPlanDraftService(
          planningPort: port,
          draftIdFactory: () => 'draft_${nextId++}',
          clock: () => _now,
        );
        final futureA = service.stage(
          sourceConversationId: _conversationId,
          sourceMessageId: _messageId,
          sourceScope: ConversationScope.global(),
          bankName: 'Math',
        );
        final futureB = service.stage(
          sourceConversationId: _conversationId,
          sourceMessageId: _messageId,
          sourceScope: ConversationScope.global(),
          bankName: 'Math',
        );
        expect(port.pendingCount, 2);
        for (final index in completionOrder) {
          port.complete(index, StudyPlanPlanningAdmitted(_context()));
        }
        return (await futureA, await futureB);
      }

      for (final order in <List<int>>[
        <int>[0, 1],
        <int>[1, 0],
      ]) {
        final (resultA, resultB) = await run(order);
        final draftA = (resultA as StudyPlanStageResultStaged).draft;
        final draftB = (resultB as StudyPlanStageResultStaged).draft;
        expect(draftA.draftId, draftB.draftId,
            reason: 'same-fingerprint intents must share one draft '
                '(completion order $order)');
        expect(draftA.outcome, StudyPlanDraftOutcome.pending);
      }
    });
  });

  group('P2-C replay must not re-admit', () {
    test(
        'A. replay after the planning port turns unavailable returns the '
        'same draft without a fresh planning read', () async {
      final harness = _Harness();
      final staged = (await harness.stage()) as StudyPlanStageResultStaged;
      expect(harness.port.calls, 1);

      harness.port.result = const StudyPlanPlanningUnavailable();
      final replay = (await harness.stage()) as StudyPlanStageResultStaged;
      expect(replay.draft.draftId, staged.draft.draftId);
      expect(replay.draft.outcome, StudyPlanDraftOutcome.pending);
      expect(harness.port.calls, 1, reason: 'replay must not re-read');
    });

    test(
        'B. replay after reject with a throwing port returns the rejected '
        'draft without exception or planning read', () async {
      final harness = _Harness();
      final staged = (await harness.stage()) as StudyPlanStageResultStaged;
      harness.service.rejectDraft(staged.draft.draftId);

      // A fresh planning read would now throw; replay must never reach it.
      harness.port.error =
          const StudyPlanReadException(StudyPlanReadFailure.unavailable);
      final replay = (await harness.stage()) as StudyPlanStageResultStaged;
      expect(replay.draft.draftId, staged.draft.draftId);
      expect(replay.draft.outcome, StudyPlanDraftOutcome.rejected);
      expect(harness.port.calls, 1,
          reason: 'replay must not re-read even when the next read would '
              'throw');
    });

    test(
        'C. replay of a superseded draft returns the same superseded draft; '
        'the newer draft stays current; zero planning reads', () async {
      final harness = _Harness();
      final first =
          (await harness.stage(dailyTarget: 30)) as StudyPlanStageResultStaged;
      final second =
          (await harness.stage(dailyTarget: 50)) as StudyPlanStageResultStaged;
      final callsAfterSequencing = harness.port.calls;
      expect(harness.service.draftById(first.draft.draftId).outcome,
          StudyPlanDraftOutcome.superseded);

      final replay =
          (await harness.stage(dailyTarget: 30)) as StudyPlanStageResultStaged;
      expect(replay.draft.draftId, first.draft.draftId);
      expect(replay.draft.outcome, StudyPlanDraftOutcome.superseded);
      expect(harness.port.calls, callsAfterSequencing,
          reason: 'replay must not re-read');
      // The newer draft remains current.
      expect(harness.service.draftById(second.draft.draftId).outcome,
          StudyPlanDraftOutcome.pending);
    });

    test('D. committed replay stays committed without a new planning read',
        () async {
      final harness = _Harness();
      final staged = (await harness.stage()) as StudyPlanStageResultStaged;
      harness.service.beginCommit(staged.draft.draftId);
      harness.service.markCommitted(staged.draft.draftId);
      expect(harness.port.calls, 1);

      final replay = (await harness.stage()) as StudyPlanStageResultStaged;
      expect(replay.draft.draftId, staged.draft.draftId);
      expect(replay.draft.outcome, StudyPlanDraftOutcome.committed);
      expect(harness.port.calls, 1, reason: 'replay must not re-read');
    });
  });
}

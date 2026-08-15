// SPL-1-D0 draft service tests: normalized staging, fingerprint replay
// dedup, one-active-per-source-turn, the atomic transient lifecycle gate,
// and bounded failure mapping. All lifecycle assertions are
// eligibility/state only: D0 performs zero durable writes.
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
  int calls = 0;

  @override
  Future<StudyPlanPlanningAdmission> loadPlanningContext({
    required ConversationScope sourceScope,
    required String bankName,
    required DateTime now,
  }) async {
    calls++;
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
      'exactly one pending draft and no lost transitions', () async {
    final harness = _Harness();
    final results = await Future.wait(<Future<StudyPlanStageResult>>[
      harness.stage(dailyTarget: 30),
      harness.stage(dailyTarget: 50),
      harness.stage(dailyTarget: 70),
    ]);
    final resultDrafts = <StudyPlanDraft>[
      for (final result in results)
        if (result is StudyPlanStageResultStaged) result.draft,
    ];
    expect(resultDrafts, hasLength(3));
    // Result drafts are immutable activation snapshots; current lifecycle
    // state lives in the service map, so read it back per draft id.
    final current = <StudyPlanDraft>[
      for (final draft in resultDrafts)
        harness.service.draftById(draft.draftId),
    ];
    final pending =
        current.where((d) => d.outcome == StudyPlanDraftOutcome.pending);
    final superseded =
        current.where((d) => d.outcome == StudyPlanDraftOutcome.superseded);
    expect(pending, hasLength(1));
    expect(superseded, hasLength(2));
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
}

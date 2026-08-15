// SPL-1-D0 domain tests: canonical values, normalization bounds and
// defaults, fingerprint normalization, scope participation, and the
// ActiveStudyPlan immutable value type.
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/domain/conversations/conversation.dart';
import 'package:shiroha_quiz/domain/study_plan/active_study_plan.dart';
import 'package:shiroha_quiz/domain/study_plan/study_plan_draft.dart';
import 'package:shiroha_quiz/domain/study_plan/study_plan_values.dart';

void main() {
  group('StudyPlanPriority codec', () {
    test('canonical codes round-trip for all four priorities', () {
      const pairs = <(StudyPlanPriority, String)>[
        (StudyPlanPriority.balanced, 'balanced'),
        (StudyPlanPriority.dueFirst, 'due_first'),
        (StudyPlanPriority.weakFirst, 'weak_first'),
        (StudyPlanPriority.newFirst, 'new_first'),
      ];
      for (final (priority, code) in pairs) {
        expect(priority.canonicalCode, code);
        expect(StudyPlanPriority.fromCanonicalCode(code), priority);
      }
    });

    test('unknown codes are rejected', () {
      expect(() => StudyPlanPriority.fromCanonicalCode('priority'),
          throwsFormatException);
      expect(
          () => StudyPlanPriority.fromCanonicalCode(''), throwsFormatException);
    });
  });

  group('StudyPlanInput normalization', () {
    test('defaults: omitted dailyTarget = 40, omitted priority = balanced', () {
      final omitted = StudyPlanInput.normalize(bankName: ' Math ');
      expect(omitted.bankName, 'Math');
      expect(omitted.goal, isNull);
      expect(omitted.dailyTarget, 40);
      expect(omitted.priority, StudyPlanPriority.balanced);
      expect(omitted.horizonDays, isNull);
    });

    test('omitted defaults equal explicit defaults canonically', () {
      final omitted = StudyPlanInput.normalize(
        bankName: 'Math',
        goal: '  Master  calculus  ',
      );
      final explicit = StudyPlanInput.normalize(
        bankName: 'Math',
        goal: 'Master calculus',
        dailyTarget: 40,
        priority: StudyPlanPriority.balanced,
      );
      expect(omitted, explicit);
      expect(omitted.hashCode, explicit.hashCode);
    });

    test('bankName is trimmed and bounded 1..200', () {
      expect(StudyPlanInput.normalize(bankName: '  Math  ').bankName, 'Math');
      expect(
        () => StudyPlanInput.normalize(bankName: '   '),
        throwsA(isA<StudyPlanValidationException>().having(
          (e) => e.failure,
          'failure',
          StudyPlanValidationFailure.emptyBankName,
        )),
      );
      final twoHundred = 'x' * 200;
      expect(
          StudyPlanInput.normalize(bankName: twoHundred).bankName, twoHundred);
      expect(
        () => StudyPlanInput.normalize(bankName: 'x' * 201),
        throwsA(isA<StudyPlanValidationException>().having(
          (e) => e.failure,
          'failure',
          StudyPlanValidationFailure.bankNameTooLong,
        )),
      );
    });

    test('goal is optional, collapsed, bounded 120, control-free', () {
      expect(StudyPlanInput.normalize(bankName: 'M').goal, isNull);
      final collapsed =
          StudyPlanInput.normalize(bankName: 'M', goal: '  a\n  b  ');
      expect(collapsed.goal, 'a b');
      expect(
        () => StudyPlanInput.normalize(bankName: 'M', goal: '   '),
        throwsA(isA<StudyPlanValidationException>().having(
          (e) => e.failure,
          'failure',
          StudyPlanValidationFailure.emptyGoal,
        )),
      );
      expect(
        () => StudyPlanInput.normalize(bankName: 'M', goal: 'y' * 121),
        throwsA(isA<StudyPlanValidationException>().having(
          (e) => e.failure,
          'failure',
          StudyPlanValidationFailure.goalTooLong,
        )),
      );
      expect(
        () => StudyPlanInput.normalize(bankName: 'M', goal: 'ok\u0000bad'),
        throwsA(isA<StudyPlanValidationException>().having(
          (e) => e.failure,
          'failure',
          StudyPlanValidationFailure.goalControlCharacters,
        )),
      );
      expect(
        () => StudyPlanInput.normalize(bankName: 'M', goal: 'ok\u007fbad'),
        throwsA(isA<StudyPlanValidationException>().having(
          (e) => e.failure,
          'failure',
          StudyPlanValidationFailure.goalControlCharacters,
        )),
      );
      // 120 runes is accepted (multi-byte runes count by code point).
      expect(
        StudyPlanInput.normalize(bankName: 'M', goal: '目' * 120).goal,
        '目' * 120,
      );
    });

    test('dailyTarget bounds 1..200 with default 40', () {
      expect(
          StudyPlanInput.normalize(bankName: 'M', dailyTarget: 1).dailyTarget,
          1);
      expect(
          StudyPlanInput.normalize(bankName: 'M', dailyTarget: 200).dailyTarget,
          200);
      for (final bad in <int>[0, -1, 201, 1000]) {
        expect(
          () => StudyPlanInput.normalize(bankName: 'M', dailyTarget: bad),
          throwsA(isA<StudyPlanValidationException>().having(
            (e) => e.failure,
            'failure',
            StudyPlanValidationFailure.invalidDailyTarget,
          )),
        );
      }
    });

    test('priority accepts exactly the four enum values', () {
      for (final priority in StudyPlanPriority.values) {
        expect(
          StudyPlanInput.normalize(bankName: 'M', priority: priority).priority,
          priority,
        );
      }
    });

    test('horizonDays is optional and bounded 1..90', () {
      expect(StudyPlanInput.normalize(bankName: 'M').horizonDays, isNull);
      expect(
          StudyPlanInput.normalize(bankName: 'M', horizonDays: 1).horizonDays,
          1);
      expect(
          StudyPlanInput.normalize(bankName: 'M', horizonDays: 90).horizonDays,
          90);
      for (final bad in <int>[0, -1, 91]) {
        expect(
          () => StudyPlanInput.normalize(bankName: 'M', horizonDays: bad),
          throwsA(isA<StudyPlanValidationException>().having(
            (e) => e.failure,
            'failure',
            StudyPlanValidationFailure.invalidHorizonDays,
          )),
        );
      }
    });
  });

  group('StudyPlanDraftFingerprint', () {
    const conversationId = 'conv_1';
    const messageId = 'msg_1';
    final global = ConversationScope.global();
    final learningSpace = ConversationScope.learningSpace('project_1');

    test('omitted defaults and explicit defaults fingerprint identically', () {
      final a = StudyPlanDraftFingerprint(
        sourceConversationId: conversationId,
        sourceMessageId: messageId,
        sourceScope: global,
        operationKind: StudyPlanOperationKind.proposeStudyPlan,
        plan: StudyPlanInput.normalize(bankName: 'Math'),
      );
      final b = StudyPlanDraftFingerprint(
        sourceConversationId: conversationId,
        sourceMessageId: messageId,
        sourceScope: global,
        operationKind: StudyPlanOperationKind.proposeStudyPlan,
        plan: StudyPlanInput.normalize(
          bankName: 'Math',
          dailyTarget: 40,
          priority: StudyPlanPriority.balanced,
        ),
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('plan field differences change the fingerprint', () {
      StudyPlanDraftFingerprint fingerprint(StudyPlanInput plan) =>
          StudyPlanDraftFingerprint(
            sourceConversationId: conversationId,
            sourceMessageId: messageId,
            sourceScope: global,
            operationKind: StudyPlanOperationKind.proposeStudyPlan,
            plan: plan,
          );
      final base = fingerprint(StudyPlanInput.normalize(bankName: 'Math'));
      expect(
        fingerprint(StudyPlanInput.normalize(bankName: 'Physics')),
        isNot(base),
      );
      expect(
        fingerprint(StudyPlanInput.normalize(bankName: 'Math', goal: 'g')),
        isNot(base),
      );
      expect(
        fingerprint(
          StudyPlanInput.normalize(bankName: 'Math', dailyTarget: 50),
        ),
        isNot(base),
      );
      expect(
        fingerprint(
          StudyPlanInput.normalize(
            bankName: 'Math',
            priority: StudyPlanPriority.dueFirst,
          ),
        ),
        isNot(base),
      );
      expect(
        fingerprint(
          StudyPlanInput.normalize(bankName: 'Math', horizonDays: 30),
        ),
        isNot(base),
      );
    });

    test('source scope participates in the fingerprint', () {
      StudyPlanDraftFingerprint fingerprint(ConversationScope scope) =>
          StudyPlanDraftFingerprint(
            sourceConversationId: conversationId,
            sourceMessageId: messageId,
            sourceScope: scope,
            operationKind: StudyPlanOperationKind.proposeStudyPlan,
            plan: StudyPlanInput.normalize(bankName: 'Math'),
          );
      expect(fingerprint(global), isNot(fingerprint(learningSpace)));
      expect(
        fingerprint(learningSpace),
        isNot(
          fingerprint(ConversationScope.learningSpace('project_2')),
        ),
      );
    });

    test('source conversation/message and operation participate', () {
      StudyPlanDraftFingerprint fingerprint({
        String conv = conversationId,
        String msg = messageId,
      }) =>
          StudyPlanDraftFingerprint(
            sourceConversationId: conv,
            sourceMessageId: msg,
            sourceScope: global,
            operationKind: StudyPlanOperationKind.proposeStudyPlan,
            plan: StudyPlanInput.normalize(bankName: 'Math'),
          );
      expect(fingerprint(conv: 'conv_2'), isNot(fingerprint()));
      expect(fingerprint(msg: 'msg_2'), isNot(fingerprint()));
    });
  });

  group('StudyPlanDraft value', () {
    test('withOutcome copies every field and changes only the outcome', () {
      final draft = StudyPlanDraft(
        draftId: 'draft_1',
        fingerprint: StudyPlanDraftFingerprint(
          sourceConversationId: 'conv_1',
          sourceMessageId: 'msg_1',
          sourceScope: ConversationScope.global(),
          operationKind: StudyPlanOperationKind.proposeStudyPlan,
          plan: StudyPlanInput.normalize(bankName: 'Math'),
        ),
        sourceConversationId: 'conv_1',
        sourceMessageId: 'msg_1',
        sourceScope: ConversationScope.global(),
        bankName: 'Math',
        goal: null,
        dailyTarget: 40,
        priority: StudyPlanPriority.balanced,
        horizonDays: null,
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true),
        outcome: StudyPlanDraftOutcome.pending,
        preview: const StudyPlanPreview(
          bankName: 'Math',
          goal: null,
          dailyTarget: 40,
          priority: StudyPlanPriority.balanced,
          horizonDays: null,
          questionCount: 10,
          masteredCount: 2,
          dueCount: 3,
          weakCount: 1,
          newCount: 4,
          estimatedDays: 1,
        ),
      );
      final updated = draft.withOutcome(StudyPlanDraftOutcome.rejected);
      expect(updated.draftId, draft.draftId);
      expect(updated.outcome, StudyPlanDraftOutcome.rejected);
      expect(updated.fingerprint, draft.fingerprint);
      expect(updated.bankName, draft.bankName);
      expect(updated.preview, draft.preview);
      expect(draft.outcome, StudyPlanDraftOutcome.pending);
    });
  });

  group('StudyPlanCandidate / StudyPlanPlanningContext values', () {
    test('candidate carries only bounded selection fields', () {
      const candidate = StudyPlanCandidate(
        storageId: 'id_1',
        bankName: 'Math',
        due: true,
        nextReviewAt: 100,
        lapses: 2,
        difficulty: 6.5,
        classification: StudyPlanQuestionClassification.review,
      );
      expect(candidate.storageId, 'id_1');
      expect(candidate.due, isTrue);
      expect(candidate.nextReviewAt, 100);
      expect(candidate.lapses, 2);
      expect(candidate.difficulty, 6.5);
      expect(candidate.classification, StudyPlanQuestionClassification.review);
    });

    test('context aggregates are plain descriptive counts', () {
      const context = StudyPlanPlanningContext(
        bankName: 'Math',
        questionCount: 10,
        masteredCount: 2,
        dueCount: 3,
        weakCount: 4,
        newCount: 5,
      );
      expect(context.questionCount, 10);
      expect(context.masteredCount, 2);
      expect(context.dueCount, 3);
      expect(context.weakCount, 4);
      expect(context.newCount, 5);
    });
  });

  group('ActiveStudyPlan immutable value', () {
    test('normalizes plan fields and keeps provenance record-only', () {
      final plan = ActiveStudyPlan(
        planId: 'plan_1',
        bankName: ' Math ',
        goal: '  Master  it  ',
        dailyTarget: 30,
        priority: StudyPlanPriority.dueFirst,
        horizonDays: 14,
        sourceConversationId: 'conv_1',
        sourceUserMessageId: 'msg_1',
        adoptedAt: DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true),
      );
      expect(plan.planId, 'plan_1');
      expect(plan.bankName, 'Math');
      expect(plan.goal, 'Master it');
      expect(plan.dailyTarget, 30);
      expect(plan.priority, StudyPlanPriority.dueFirst);
      expect(plan.horizonDays, 14);
      expect(plan.sourceConversationId, 'conv_1');
      expect(plan.sourceUserMessageId, 'msg_1');
      expect(plan.adoptedAt,
          DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true));
    });

    test('rejects unbounded ids and timestamps', () {
      final adoptedAt = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
      expect(
        () => ActiveStudyPlan(
          planId: '',
          bankName: 'Math',
          adoptedAt: adoptedAt,
        ),
        throwsFormatException,
      );
      expect(
        () => ActiveStudyPlan(
          planId: 'p',
          bankName: 'Math',
          sourceConversationId: 'bad\u0000id',
          adoptedAt: adoptedAt,
        ),
        throwsFormatException,
      );
      expect(
        () => ActiveStudyPlan(
          planId: 'p',
          bankName: 'Math',
          adoptedAt: DateTime.fromMillisecondsSinceEpoch(-1, isUtc: true),
        ),
        throwsFormatException,
      );
    });

    test('equality is structural', () {
      ActiveStudyPlan plan({String? goal}) => ActiveStudyPlan(
            planId: 'plan_1',
            bankName: 'Math',
            goal: goal,
            adoptedAt: DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true),
          );
      expect(plan(), plan());
      expect(plan(goal: 'g'), isNot(plan()));
      expect(plan().hashCode, plan().hashCode);
    });
  });
}

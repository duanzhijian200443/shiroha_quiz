import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/supplemental_answers/supplemental_answer_target_port.dart';
import 'package:shiroha_quiz/application/supplemental_answers/target_question_snapshot_service.dart';
import 'package:shiroha_quiz/data/models/question.dart';
import 'package:shiroha_quiz/data/models/persisted_question.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/supplemental_answers/supplemental_answer_scope.dart';

void main() {
  final draftA = _draft('question_a');
  final draftB = _draft('question_b');

  group('TargetQuestionSnapshotService', () {
    test('bank scope keeps only typed targets and reports legacy ineligible',
        () async {
      final service = TargetQuestionSnapshotService(
        port: _FakePort(questionsByBank: {
          'bank_math': [
            TypedPersistedQuestion(
              storageId: 'q_a',
              bankName: 'bank_math',
              createdAt: 1,
              draft: draftA,
            ),
            _legacy('legacy_1', 'bank_math'),
          ],
        }),
      );

      final snapshot = await service.resolve(
        const QuestionBankScope(bankName: 'bank_math'),
      );

      expect(snapshot.targets, hasLength(1));
      expect(snapshot.targets.single.storageId, 'q_a');
      expect(snapshot.targets.single.bankName, 'bank_math');
      expect(snapshot.targets.single.draft, draftA);
      expect(snapshot.reports, hasLength(1));
      expect(snapshot.reports.single.code, TargetScopeReportCode.legacyIneligible);
      expect(snapshot.reports.single.storageId, 'legacy_1');
    });

    test('project scope resolves through project bank relations in order',
        () async {
      final service = TargetQuestionSnapshotService(
        port: _FakePort(
          projectBanks: {
            'project_1': ['bank_a', 'bank_b'],
          },
          questionsByBank: {
            'bank_a': [
              TypedPersistedQuestion(
                storageId: 'q_a',
                bankName: 'bank_a',
                createdAt: 1,
                draft: draftA,
              ),
            ],
            'bank_b': [
              TypedPersistedQuestion(
                storageId: 'q_b',
                bankName: 'bank_b',
                createdAt: 2,
                draft: draftB,
              ),
            ],
          },
        ),
      );

      final snapshot = await service.resolve(
        const ProjectScope(projectId: 'project_1'),
      );

      expect(
        snapshot.targets.map((target) => target.storageId),
        ['q_a', 'q_b'],
      );
      expect(
        snapshot.targets.map((target) => target.bankName),
        ['bank_a', 'bank_b'],
      );
    });

    test('explicit subset preserves caller order and reports missing and '
        'duplicate ids', () async {
      final service = TargetQuestionSnapshotService(
        port: _FakePort(questionsByIds: {
          'q_a': TypedPersistedQuestion(
            storageId: 'q_a',
            bankName: 'bank_math',
            createdAt: 1,
            draft: draftA,
          ),
          'q_b': TypedPersistedQuestion(
            storageId: 'q_b',
            bankName: 'bank_math',
            createdAt: 2,
            draft: draftB,
          ),
        }),
      );

      final snapshot = await service.resolve(
        ExplicitQuestionScope(
          storageIds: ['q_b', 'missing', 'q_a', 'q_b'],
        ),
      );

      expect(
        snapshot.targets.map((target) => target.storageId),
        ['q_b', 'q_a'],
      );
      expect(
        snapshot.reports.map((report) => report.code),
        [
          TargetScopeReportCode.missingTarget,
          TargetScopeReportCode.duplicateTarget,
        ],
      );
      expect(snapshot.reports[0].storageId, 'missing');
      expect(snapshot.reports[1].storageId, 'q_b');
    });

    test('empty eligible target set yields an empty snapshot', () async {
      final service = TargetQuestionSnapshotService(
        port: _FakePort(questionsByBank: {
          'bank_empty': <PersistedQuestion>[],
        }),
      );

      final snapshot = await service.resolve(
        const QuestionBankScope(bankName: 'bank_empty'),
      );

      expect(snapshot.isEmpty, isTrue);
      expect(snapshot.reports, isEmpty);
    });
  });
}

class _FakePort implements SupplementalAnswerTargetPort {
  _FakePort({
    this.questionsByBank = const {},
    this.questionsByIds = const {},
    this.projectBanks = const {},
  });

  final Map<String, List<PersistedQuestion>> questionsByBank;
  final Map<String, PersistedQuestion> questionsByIds;
  final Map<String, List<String>> projectBanks;

  @override
  Future<List<String>> listProjectBankNames(String projectId) async {
    return projectBanks[projectId] ?? const <String>[];
  }

  @override
  Future<List<PersistedQuestion>> listTypedQuestionsByBank(
    String bankName,
  ) async {
    return questionsByBank[bankName] ?? const <PersistedQuestion>[];
  }

  @override
  Future<List<PersistedQuestion>> listTypedQuestionsByIds(
    Iterable<String> storageIds,
  ) async {
    return storageIds
        .map((id) => questionsByIds[id])
        .whereType<PersistedQuestion>()
        .toList(growable: false);
  }
}

LegacyPersistedQuestion _legacy(String id, String bankName) {
  return LegacyPersistedQuestion(
    question: Question(
      id: id,
      type: 3,
      content: 'legacy stem',
      createdAt: 1,
      bankName: bankName,
      answer: 'legacy answer',
    ),
  );
}

QuestionDraftV2 _draft(String questionId) {
  return QuestionDraftV2(
    questionId: questionId,
    kind: QuestionKind.shortAnswer,
    stem: RichContent(nodes: [TextNode('stem')]),
  );
}

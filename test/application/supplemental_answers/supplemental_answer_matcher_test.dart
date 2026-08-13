import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/supplemental_answers/supplemental_answer_matcher.dart';
import 'package:shiroha_quiz/application/supplemental_answers/target_question_snapshot_service.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/domain/supplemental_answers/answer_candidate.dart';
import 'package:shiroha_quiz/domain/supplemental_answers/answer_match_record.dart';
import 'package:shiroha_quiz/domain/supplemental_answers/supplemental_answer_fragment.dart';
import 'package:shiroha_quiz/domain/supplemental_answers/target_coverage.dart';

const _artifact = SupplementalArtifactContext(
  supplementalFileId: 'file_001',
  artifactId: 'artifact_001',
  artifactRevision: 1,
);

void main() {
  const matcher = SupplementalAnswerMatcher();

  group('primary identity proof', () {
    test('scope-unique normalized main number matches deterministically',
        () {
      final snapshot = TargetQuestionSnapshot(
        targets: [
          _target('q_1', number: 1, kind: QuestionKind.shortAnswer),
          _target('q_2', number: 2, kind: QuestionKind.shortAnswer),
        ],
        reports: const [],
      );

      final result = matcher.match(
        fragments: [_fragment('frag_1', main: '1', answer: 'x = 1')],
        snapshot: snapshot,
        artifact: _artifact,
      );

      expect(result.records.single.disposition, AnswerMatchDisposition.matched);
      expect(result.records.single.certainty, MatchCertainty.deterministic);
      expect(result.records.single.candidate!.targetStorageId, 'q_1');
      expect(result.records.single.candidate!.writeIntent, CandidateWriteIntent.fill);
      expect(
        result.records.single.evidence,
        contains(MatchEvidenceCode.uniqueMainNumber),
      );
      expect(
        result.coverage.singleWhere((c) => c.storageId == 'q_1').status,
        TargetCoverageStatus.covered,
      );
    });

    test('duplicate numbers without unique proof are ambiguous', () {
      final snapshot = TargetQuestionSnapshot(
        targets: [
          _target('q_1', number: 1, kind: QuestionKind.shortAnswer),
          _target('q_2', number: 1, kind: QuestionKind.shortAnswer),
        ],
        reports: const [],
      );

      final result = matcher.match(
        fragments: [_fragment('frag_1', main: '1', answer: 'x = 1')],
        snapshot: snapshot,
        artifact: _artifact,
      );

      expect(result.records.single.disposition, AnswerMatchDisposition.ambiguous);
      expect(result.records.single.candidate, isNull);
      expect(result.records.single.alternatives, hasLength(2));
    });

    test('subquestion proof disambiguates duplicate main numbers', () {
      final snapshot = TargetQuestionSnapshot(
        targets: [
          _target('q_1', number: 1, kind: QuestionKind.shortAnswer, stem: '（1）'),
          _target('q_2', number: 1, kind: QuestionKind.shortAnswer, stem: '（2）'),
        ],
        reports: const [],
      );

      final result = matcher.match(
        fragments: [
          _fragment('frag_1', main: '1', sub: '1', answer: 'first'),
        ],
        snapshot: snapshot,
        artifact: _artifact,
      );

      expect(result.records.single.disposition, AnswerMatchDisposition.matched);
      expect(result.records.single.candidate!.targetStorageId, 'q_1');
      expect(
        result.records.single.evidence,
        containsAll(<MatchEvidenceCode>[
          MatchEvidenceCode.uniqueMainNumber,
          MatchEvidenceCode.mainNumberAndSubquestion,
        ]),
      );
    });
  });

  group('answer conversion and existing-answer contract', () {
    test('singleChoice label maps uniquely to a current option id', () {
      final snapshot = TargetQuestionSnapshot(
        targets: [
          _choiceTarget('q_choice', number: 1),
        ],
        reports: const [],
      );

      final result = matcher.match(
        fragments: [_fragment('frag_1', main: '1', answer: 'A')],
        snapshot: snapshot,
        artifact: _artifact,
      );

      final candidate = result.records.single.candidate!;
      expect(candidate.answer, ChoiceAnswer(optionIds: ['opt_a']));
      expect(candidate.writeIntent, CandidateWriteIntent.fill);
    });

    test('unmappable choice label is invalid and never committable', () {
      final snapshot = TargetQuestionSnapshot(
        targets: [_choiceTarget('q_choice', number: 1)],
        reports: const [],
      );

      final result = matcher.match(
        fragments: [_fragment('frag_1', main: '1', answer: 'Z')],
        snapshot: snapshot,
        artifact: _artifact,
      );

      expect(result.records.single.disposition, AnswerMatchDisposition.invalid);
      expect(result.records.single.candidate, isNull);
      expect(
        result.records.single.evidence,
        contains(MatchEvidenceCode.ambiguousChoiceLabel),
      );
    });

    test('equivalent existing answer is noOp with zero transaction', () {
      final snapshot = TargetQuestionSnapshot(
        targets: [
          _target(
            'q_filled',
            number: 1,
            kind: QuestionKind.shortAnswer,
            answer: ContentAnswer(content: _text('x = 1')),
          ),
        ],
        reports: const [],
      );

      final result = matcher.match(
        fragments: [_fragment('frag_1', main: '1', answer: 'x = 1')],
        snapshot: snapshot,
        artifact: _artifact,
      );

      expect(result.records.single.disposition, AnswerMatchDisposition.matched);
      expect(
        result.records.single.candidate!.writeIntent,
        CandidateWriteIntent.noOp,
      );
    });

    test('different existing answer is conflict with replace intent', () {
      final snapshot = TargetQuestionSnapshot(
        targets: [
          _target(
            'q_filled',
            number: 1,
            kind: QuestionKind.shortAnswer,
            answer: ContentAnswer(content: _text('x = 2')),
          ),
        ],
        reports: const [],
      );

      final result = matcher.match(
        fragments: [_fragment('frag_1', main: '1', answer: 'x = 1')],
        snapshot: snapshot,
        artifact: _artifact,
      );

      expect(result.records.single.disposition, AnswerMatchDisposition.conflict);
      expect(
        result.records.single.candidate!.writeIntent,
        CandidateWriteIntent.replace,
      );
    });
  });

  group('multi-fragment semantics', () {
    test('identical duplicate fragments merge provenance into one candidate',
        () {
      final snapshot = TargetQuestionSnapshot(
        targets: [
          _target('q_1', number: 1, kind: QuestionKind.shortAnswer),
        ],
        reports: const [],
      );

      final result = matcher.match(
        fragments: [
          _fragment('frag_a', main: '1', answer: 'x = 1'),
          _fragment('frag_b', main: '1', answer: 'x = 1'),
        ],
        snapshot: snapshot,
        artifact: _artifact,
      );

      expect(result.records, hasLength(1));
      expect(result.records.single.candidate!.supplementalSourceRefs,
          hasLength(2));
    });

    test('conflicting duplicate fragments are invalid sourceConflict', () {
      final snapshot = TargetQuestionSnapshot(
        targets: [
          _target('q_1', number: 1, kind: QuestionKind.shortAnswer),
        ],
        reports: const [],
      );

      final result = matcher.match(
        fragments: [
          _fragment('frag_a', main: '1', answer: 'x = 1'),
          _fragment('frag_b', main: '1', answer: 'x = 9'),
        ],
        snapshot: snapshot,
        artifact: _artifact,
      );

      expect(result.records.single.disposition, AnswerMatchDisposition.invalid);
      expect(
        result.records.single.evidence,
        contains(MatchEvidenceCode.sourceConflict),
      );
    });

    test('complete subquestion set composes one ContentAnswer in sub-order',
        () {
      final snapshot = TargetQuestionSnapshot(
        targets: [
          _target(
            'q_parent',
            number: 1,
            kind: QuestionKind.shortAnswer,
            stem: '（1） and （2）',
          ),
        ],
        reports: const [],
      );

      final result = matcher.match(
        fragments: [
          _fragment('frag_sub1', main: '1', sub: '2', answer: 'second'),
          _fragment('frag_sub2', main: '1', sub: '1', answer: 'first'),
        ],
        snapshot: snapshot,
        artifact: _artifact,
      );

      expect(result.records, hasLength(1));
      expect(result.records.single.disposition, AnswerMatchDisposition.matched);
      final answer = result.records.single.candidate!.answer as ContentAnswer;
      expect(
        answer.content.nodes.map((node) => (node as TextNode).text),
        ['first', 'second'],
      );
    });

    test('incomplete subquestion set stays ambiguous', () {
      final snapshot = TargetQuestionSnapshot(
        targets: [
          _target(
            'q_parent',
            number: 1,
            kind: QuestionKind.shortAnswer,
            stem: '（1） and （2）',
          ),
        ],
        reports: const [],
      );

      final result = matcher.match(
        fragments: [
          _fragment('frag_sub1', main: '1', sub: '1', answer: 'first'),
        ],
        snapshot: snapshot,
        artifact: _artifact,
      );

      expect(result.records.single.disposition, AnswerMatchDisposition.ambiguous);
      expect(result.records.single.candidate, isNull);
    });

    test('complete subquestion set with a different existing answer is '
        'conflict and requires replace reconfirmation', () {
      final snapshot = TargetQuestionSnapshot(
        targets: [
          _target(
            'q_parent',
            number: 1,
            kind: QuestionKind.shortAnswer,
            stem: '（1） and （2）',
            answer: ContentAnswer(content: _text('old answer')),
          ),
        ],
        reports: const [],
      );

      final result = matcher.match(
        fragments: [
          _fragment('frag_sub1', main: '1', sub: '2', answer: 'second'),
          _fragment('frag_sub2', main: '1', sub: '1', answer: 'first'),
        ],
        snapshot: snapshot,
        artifact: _artifact,
      );

      expect(result.records, hasLength(1));
      expect(
        result.records.single.disposition,
        AnswerMatchDisposition.conflict,
      );
      expect(
        result.records.single.candidate!.writeIntent,
        CandidateWriteIntent.replace,
      );
    });

    test('complete subquestion set equal to the existing answer is noOp',
        () {
      final composed = RichContent(
        nodes: [TextNode('first'), TextNode('second')],
      );
      final snapshot = TargetQuestionSnapshot(
        targets: [
          _target(
            'q_parent',
            number: 1,
            kind: QuestionKind.shortAnswer,
            stem: '（1） and （2）',
            answer: ContentAnswer(content: composed),
          ),
        ],
        reports: const [],
      );

      final result = matcher.match(
        fragments: [
          _fragment('frag_sub1', main: '1', sub: '2', answer: 'second'),
          _fragment('frag_sub2', main: '1', sub: '1', answer: 'first'),
        ],
        snapshot: snapshot,
        artifact: _artifact,
      );

      expect(result.records, hasLength(1));
      expect(
        result.records.single.candidate!.writeIntent,
        CandidateWriteIntent.noOp,
      );
    });
  });

  group('numberless fragments', () {
    test('unique exact stem fingerprint matches deterministically', () {
      final snapshot = TargetQuestionSnapshot(
        targets: [
          _target(
            'q_stem',
            number: null,
            kind: QuestionKind.shortAnswer,
            stem: 'solve for x',
          ),
        ],
        reports: const [],
      );

      final result = matcher.match(
        fragments: [
          _fragment(
            'frag_stem',
            main: null,
            answer: 'x = 1',
            stemContext: 'solve for x',
          ),
        ],
        snapshot: snapshot,
        artifact: _artifact,
      );

      expect(result.records.single.disposition, AnswerMatchDisposition.matched);
      expect(result.records.single.candidate!.targetStorageId, 'q_stem');
    });

    test('missing locator and stem context is unmatched and never writes',
        () {
      final snapshot = TargetQuestionSnapshot(
        targets: [
          _target('q_1', number: 1, kind: QuestionKind.shortAnswer),
        ],
        reports: const [],
      );

      final result = matcher.match(
        fragments: [
          _fragment('frag_none', main: null, answer: 'x = 1'),
        ],
        snapshot: snapshot,
        artifact: _artifact,
      );

      expect(result.records.single.disposition, AnswerMatchDisposition.unmatched);
      expect(result.records.single.candidate, isNull);
    });
  });
}

AnswerTargetReference _target(
  String storageId, {
  required int? number,
  required QuestionKind kind,
  String stem = 'synthetic stem',
  QuestionAnswer? answer,
}) {
  return AnswerTargetReference(
    storageId: storageId,
    bankName: 'bank_math',
    draft: QuestionDraftV2(
      questionId: storageId,
      kind: kind,
      questionNumber: number,
      stem: _text(stem),
      options: kind == QuestionKind.singleChoice
          ? [
              QuestionOption(
                optionId: 'opt_a',
                label: 'A',
                content: _text('A option'),
              ),
              QuestionOption(
                optionId: 'opt_b',
                label: 'B',
                content: _text('B option'),
              ),
            ]
          : <QuestionOption>[],
      answer: answer,
    ),
  );
}

AnswerTargetReference _choiceTarget(String storageId, {required int number}) {
  return _target(storageId, number: number, kind: QuestionKind.singleChoice);
}

SupplementalAnswerFragment _fragment(
  String fragmentId, {
  required String? main,
  String? sub,
  required String answer,
  String? stemContext,
}) {
  return SupplementalAnswerFragment(
    fragmentId: fragmentId,
    normalizedMainNumber: main,
    normalizedSubquestion: sub,
    answerContent: _text(answer),
    sourceRefs: [
      SourceRef.document(sourceId: 'artifact_001'),
    ],
    sequencePosition: const SupplementalSequencePosition(
      partIndex: 0,
      continuationOrdinal: 0,
    ),
    stemContext: stemContext == null ? null : _text(stemContext),
  );
}

RichContent _text(String text) {
  return RichContent(nodes: [TextNode(text)]);
}

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
    test('scope-unique normalized main number matches deterministically', () {
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
      expect(result.records.single.candidate!.writeIntent,
          CandidateWriteIntent.fill);
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

      expect(
          result.records.single.disposition, AnswerMatchDisposition.ambiguous);
      expect(result.records.single.candidate, isNull);
      expect(result.records.single.alternatives, hasLength(2));
    });

    test('subquestion proof disambiguates duplicate main numbers', () {
      final snapshot = TargetQuestionSnapshot(
        targets: [
          _target('q_1',
              number: 1, kind: QuestionKind.shortAnswer, stem: '（1）'),
          _target('q_2',
              number: 1, kind: QuestionKind.shortAnswer, stem: '（2）'),
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

      expect(
          result.records.single.disposition, AnswerMatchDisposition.conflict);
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
      final candidate = result.records.single.candidate!;
      expect(candidate.origin, isA<SupplementalAnswerOrigin>());
      final origin = switch (candidate.origin) {
        SupplementalAnswerOrigin origin => origin,
        AiAnswerOrigin() => fail('matcher must produce a supplemental origin'),
      };
      expect(origin.supplementalSourceRefs, hasLength(2));
      expect(
        origin.supplementalSourceRefs.map((ref) => ref.sourceId).toSet(),
        {'artifact_001'},
      );
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

    test(
        'a duplicate locator mixing candidate and non-candidate siblings '
        'keeps both outcomes', () {
      final snapshot = TargetQuestionSnapshot(
        targets: [_abcdTarget('q_choice', number: 1)],
        reports: const [],
      );

      final result = matcher.match(
        fragments: [
          _fragment('frag_writable', main: '1', answer: 'A'),
          _fragment('frag_unmappable', main: '1', answer: 'Z'),
        ],
        snapshot: snapshot,
        artifact: _artifact,
      );

      expect(result.records, hasLength(2));
      final writable = result.records.firstWhere(
        (record) => record.fragmentId == 'frag_writable',
      );
      final unmappable = result.records.firstWhere(
        (record) => record.fragmentId == 'frag_unmappable',
      );
      expect(writable.disposition, AnswerMatchDisposition.matched);
      expect(
        (writable.candidate!.answer as ChoiceAnswer).optionIds,
        <String>['opt_a'],
      );
      expect(writable.candidate!.writeIntent, CandidateWriteIntent.fill);
      expect(unmappable.disposition, AnswerMatchDisposition.invalid);
      expect(unmappable.candidate, isNull);
      expect(
        unmappable.evidence,
        contains(MatchEvidenceCode.ambiguousChoiceLabel),
      );
    });

    test(
        'a conflicting duplicate locator still reports sourceConflict beside '
        'its non-candidate sibling', () {
      final snapshot = TargetQuestionSnapshot(
        targets: [_abcdTarget('q_choice', number: 1)],
        reports: const [],
      );

      final result = matcher.match(
        fragments: [
          _fragment('frag_a', main: '1', answer: 'A'),
          _fragment('frag_b', main: '1', answer: 'B'),
          _fragment('frag_unmappable', main: '1', answer: 'Z'),
        ],
        snapshot: snapshot,
        artifact: _artifact,
      );

      expect(result.records, hasLength(2));
      final conflicted = result.records.firstWhere(
        (record) => record.evidence.contains(MatchEvidenceCode.sourceConflict),
      );
      final unmappable = result.records.firstWhere(
        (record) => record.fragmentId == 'frag_unmappable',
      );
      expect(conflicted.disposition, AnswerMatchDisposition.invalid);
      expect(conflicted.candidate, isNull);
      expect(unmappable.disposition, AnswerMatchDisposition.invalid);
      expect(
        unmappable.evidence,
        contains(MatchEvidenceCode.ambiguousChoiceLabel),
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

      expect(
          result.records.single.disposition, AnswerMatchDisposition.ambiguous);
      expect(result.records.single.candidate, isNull);
    });

    test(
        'complete subquestion set with a different existing answer is '
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

    test('complete subquestion set equal to the existing answer is noOp', () {
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

    test('missing locator and stem context is unmatched and never writes', () {
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

      expect(
          result.records.single.disposition, AnswerMatchDisposition.unmatched);
      expect(result.records.single.candidate, isNull);
    });
  });

  group('transient answer source gate', () {
    TargetQuestionSnapshot oneTarget(QuestionKind kind) {
      return TargetQuestionSnapshot(
        targets: [_target('q_one', number: 3, kind: kind)],
        reports: const [],
      );
    }

    test('shortAnswer accepts a derived solution block as a candidate', () {
      final result = matcher.match(
        fragments: [
          _fragment(
            'frag_sol',
            main: '3',
            answer: 'proof body',
            source: SupplementalAnswerSource.solutionBlock,
          ),
        ],
        snapshot: oneTarget(QuestionKind.shortAnswer),
        artifact: _artifact,
      );

      expect(result.records.single.disposition, AnswerMatchDisposition.matched);
      expect(result.records.single.candidate, isNotNull);
      expect(
        (result.records.single.candidate!.answer as ContentAnswer)
            .content
            .nodes,
        hasLength(1),
      );
    });

    test('fillBlank rejects a derived solution block as typeIncompatible', () {
      final result = matcher.match(
        fragments: [
          _fragment(
            'frag_sol',
            main: '3',
            answer: 'x = 1',
            source: SupplementalAnswerSource.solutionBlock,
          ),
        ],
        snapshot: oneTarget(QuestionKind.fillBlank),
        artifact: _artifact,
      );

      expect(result.records.single.disposition, AnswerMatchDisposition.invalid);
      expect(result.records.single.candidate, isNull);
      expect(
        result.records.single.evidence,
        contains(MatchEvidenceCode.typeIncompatible),
      );
    });

    test('singleChoice rejects a derived solution block despite a valid label',
        () {
      final result = matcher.match(
        fragments: [
          _fragment(
            'frag_sol',
            main: '3',
            answer: 'A',
            source: SupplementalAnswerSource.solutionBlock,
          ),
        ],
        snapshot: oneTarget(QuestionKind.singleChoice),
        artifact: _artifact,
      );

      expect(result.records.single.disposition, AnswerMatchDisposition.invalid);
      expect(result.records.single.candidate, isNull);
      expect(
        result.records.single.evidence,
        contains(MatchEvidenceCode.typeIncompatible),
      );
    });

    test('explicit answers keep every target type available', () {
      final fillBlank = matcher.match(
        fragments: [_fragment('frag_fill', main: '3', answer: 'x = 1')],
        snapshot: oneTarget(QuestionKind.fillBlank),
        artifact: _artifact,
      );
      expect(
        fillBlank.records.single.disposition,
        AnswerMatchDisposition.matched,
      );

      final singleChoice = matcher.match(
        fragments: [_fragment('frag_choice', main: '3', answer: 'A')],
        snapshot: oneTarget(QuestionKind.singleChoice),
        artifact: _artifact,
      );
      expect(
        singleChoice.records.single.disposition,
        AnswerMatchDisposition.matched,
      );
      expect(
        (singleChoice.records.single.candidate!.answer as ChoiceAnswer)
            .optionIds,
        <String>['opt_a'],
      );
    });

    test('over-limit composition fails closed instead of throwing', () {
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
          _fragment('frag_sub1', main: '1', sub: '1', answer: 'z' * 4097),
          _fragment('frag_sub2', main: '1', sub: '2', answer: 'second'),
        ],
        snapshot: snapshot,
        artifact: _artifact,
      );

      expect(result.records, hasLength(2));
      for (final record in result.records) {
        expect(record.disposition, AnswerMatchDisposition.invalid);
        expect(record.candidate, isNull);
        expect(
          record.evidence,
          contains(MatchEvidenceCode.unsupportedContent),
        );
      }
    });
  });

  group('single-choice label normalization', () {
    AnswerMatchRecord matchOne(String answer) {
      return matcher
          .match(
            fragments: [_fragment('frag_1', main: '1', answer: answer)],
            snapshot: TargetQuestionSnapshot(
              targets: [_abcdTarget('q_choice', number: 1)],
              reports: const [],
            ),
            artifact: _artifact,
          )
          .records
          .single;
    }

    test('one strict label maps to its option as a fill candidate', () {
      const expected = <String, String>{
        '(C).': 'opt_c',
        '（Ｂ）。': 'opt_b',
        'c': 'opt_c',
        'C': 'opt_c',
        'Ｃ': 'opt_c',
        '(D)': 'opt_d',
        'A．': 'opt_a',
        ' (B) ': 'opt_b',
      };
      for (final entry in expected.entries) {
        final record = matchOne(entry.key);
        expect(
          record.disposition,
          AnswerMatchDisposition.matched,
          reason: '${entry.key} must normalize to a writable label',
        );
        expect(
          (record.candidate!.answer as ChoiceAnswer).optionIds,
          <String>[entry.value],
          reason: entry.key,
        );
        expect(record.candidate!.writeIntent, CandidateWriteIntent.fill);
      }
    });

    test('anything beyond one strict label stays invalid', () {
      const rejected = <String>[
        '(C) explanation',
        'A/B',
        'AB',
        'Z',
        '(Z)',
        'option C',
        '答案 C because',
        '(C',
        'C)',
        'C D',
      ];
      for (final answer in rejected) {
        final record = matchOne(answer);
        expect(
          record.disposition,
          AnswerMatchDisposition.invalid,
          reason: answer,
        );
        expect(record.candidate, isNull, reason: answer);
        expect(
          record.evidence,
          contains(MatchEvidenceCode.ambiguousChoiceLabel),
          reason: answer,
        );
      }
    });

    test('normalization never rewrites a non-choice target answer', () {
      final result = matcher.match(
        fragments: [_fragment('frag_fill', main: '1', answer: '(C).')],
        snapshot: TargetQuestionSnapshot(
          targets: [
            _target('q_fill', number: 1, kind: QuestionKind.fillBlank),
          ],
          reports: const [],
        ),
        artifact: _artifact,
      );

      final record = result.records.single;
      expect(record.disposition, AnswerMatchDisposition.matched);
      expect(
        (record.candidate!.answer as ContentAnswer)
            .content
            .nodes
            .map((node) => (node as TextNode).text),
        ['(C).'],
      );
    });
  });
}

AnswerTargetReference _abcdTarget(String storageId, {required int number}) {
  return AnswerTargetReference(
    storageId: storageId,
    bankName: 'bank_math',
    draft: QuestionDraftV2(
      questionId: storageId,
      kind: QuestionKind.singleChoice,
      questionNumber: number,
      stem: _text('synthetic stem'),
      options: [
        for (final label in const <String>['A', 'B', 'C', 'D'])
          QuestionOption(
            optionId: 'opt_${label.toLowerCase()}',
            label: label,
            content: _text('$label option'),
          ),
      ],
    ),
  );
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
  SupplementalAnswerSource source = SupplementalAnswerSource.explicitAnswer,
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
    source: source,
  );
}

RichContent _text(String text) {
  return RichContent(nodes: [TextNode(text)]);
}

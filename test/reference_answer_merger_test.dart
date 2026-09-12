import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_question_regionizer.dart';
import 'package:shiroha_quiz/services/import_pipeline/reference_answer_entry.dart';
import 'package:shiroha_quiz/services/import_pipeline/reference_answer_merger.dart';
import 'package:shiroha_quiz/services/import_pipeline/text_question_region.dart';

void main() {
  const merger = ReferenceAnswerMerger();

  test('attaches a meaningful reference answer to an empty region', () {
    final merged = merger.merge(
      [
        _region(answerParts: const [], diagnostics: const ['missing_answer'])
      ],
      _index(answer: 'Final answer'),
    ).single;

    expect(merged.answerText, 'Final answer');
    expect(merged.diagnostics, contains('reference_answer_attached'));
    expect(
      merged.diagnostics,
      contains('reference_answer_pattern:explicit_numbered'),
    );
    expect(merged.diagnostics, isNot(contains('missing_answer')));
    expect(merged.sourcePageIndices, [1, 3]);
    expect(merged.sourceBlockIds, ['question_block', 'reference_block']);
  });

  test('does not overwrite an existing meaningful answer', () {
    final merged = merger.merge(
      [
        _region(answerParts: const ['Local answer'])
      ],
      _index(answer: 'Different answer'),
    ).single;

    expect(merged.answerText, 'Local answer');
    expect(merged.diagnostics, contains('reference_answer_conflict'));
    expect(
      merged.evidenceOnlySourceBlockIds,
      const <String>['reference_block'],
    );
    expect(merged.diagnostics, isNot(contains('reference_answer_attached')));
  });

  test('conflicting reference evidence does not own local answer content', () {
    final localAnswerOwner = const OcrQuestionRegionSource(
      blockId: 'local_answer',
      field: OcrRegionField.answer,
      text: 'Local answer',
    );
    final merged = merger.merge(
      [
        _region(
          answerParts: const ['Local answer'],
          sourceBlockIds: const ['question_block', 'local_answer'],
          ownedSources: <OcrQuestionRegionSource>[
            const OcrQuestionRegionSource(
              blockId: 'question_block',
              field: OcrRegionField.stem,
              text: 'Synthetic question',
            ),
            localAnswerOwner,
          ],
        ),
      ],
      _index(
        answer: 'Different reference answer',
        sourceBlockIds: const <String>[
          'reference_block_1',
          'reference_block_2',
          'reference_block_3',
        ],
      ),
    ).single;

    expect(merged.answerParts, const <String>['Local answer']);
    expect(
      merged.ownedSources
          .where((source) => source.field == OcrRegionField.answer),
      <OcrQuestionRegionSource>[localAnswerOwner],
    );
    expect(merged.diagnostics, contains('reference_answer_conflict'));
    expect(
      merged.evidenceOnlySourceBlockIds,
      const <String>[
        'reference_block_1',
        'reference_block_2',
        'reference_block_3',
      ],
    );
    expect(
      merged.sourceBlockIds,
      const <String>[
        'question_block',
        'local_answer',
        'reference_block_1',
        'reference_block_2',
        'reference_block_3',
      ],
    );
  });

  test('confirms a normalized identical existing answer', () {
    final merged = merger.merge(
      [
        _region(answerParts: const ['Same answer'])
      ],
      _index(answer: 'Same   answer'),
    ).single;

    expect(merged.answerText, 'Same answer');
    expect(merged.diagnostics, contains('reference_answer_confirmed'));
    expect(
      merged.evidenceOnlySourceBlockIds,
      const <String>['reference_block'],
    );
  });

  test('confirmed reference evidence does not duplicate answer ownership', () {
    final localAnswerOwner = const OcrQuestionRegionSource(
      blockId: 'local_answer',
      field: OcrRegionField.answer,
      text: 'Same answer',
    );
    final merged = merger.merge(
      [
        _region(
          answerParts: const ['Same answer'],
          sourceBlockIds: const ['question_block', 'local_answer'],
          ownedSources: <OcrQuestionRegionSource>[localAnswerOwner],
        ),
      ],
      _index(
        answer: 'Same   answer',
        sourceBlockIds: const <String>[
          'reference_block_1',
          'reference_block_2',
          'reference_block_3',
        ],
      ),
    ).single;

    expect(
      merged.ownedSources
          .where((source) => source.field == OcrRegionField.answer),
      <OcrQuestionRegionSource>[localAnswerOwner],
    );
    expect(merged.diagnostics, contains('reference_answer_confirmed'));
    expect(
      merged.evidenceOnlySourceBlockIds,
      const <String>[
        'reference_block_1',
        'reference_block_2',
        'reference_block_3',
      ],
    );
  });

  test('attached reference answer is one authority, not per-block ownership',
      () {
    final stemOwner = const OcrQuestionRegionSource(
      blockId: 'question_block',
      field: OcrRegionField.stem,
      text: 'Synthetic question',
    );
    final staleAnswerOwner = const OcrQuestionRegionSource(
      blockId: 'placeholder_answer',
      field: OcrRegionField.answer,
      text: '暂无',
    );
    final merged = merger.merge(
      [
        _region(
          answerParts: const ['暂无'],
          sourceBlockIds: const [
            'question_block',
            'placeholder_answer',
          ],
          ownedSources: <OcrQuestionRegionSource>[
            stemOwner,
            staleAnswerOwner,
          ],
          diagnostics: const ['missing_answer'],
        ),
      ],
      _index(
        answer: 'Authoritative reference answer',
        sourceBlockIds: const <String>[
          'reference_block_1',
          'reference_block_2',
          'reference_block_3',
        ],
      ),
    ).single;

    expect(
      merged.answerParts,
      const <String>['Authoritative reference answer'],
    );
    expect(merged.ownedSources, <OcrQuestionRegionSource>[stemOwner]);
    expect(merged.diagnostics, contains('reference_answer_attached'));
    expect(merged.diagnostics, isNot(contains('missing_answer')));
    expect(
      merged.evidenceOnlySourceBlockIds,
      const <String>[
        'reference_block_1',
        'reference_block_2',
        'reference_block_3',
      ],
    );
  });

  test('does not attach placeholders or duplicate conflicts', () {
    for (final placeholder in const [
      '无',
      '暂无',
      '未知',
      '未提供',
      '见解析',
      '详见解析',
      '答案见解析',
      '略',
      '证明略',
    ]) {
      final merged = merger.merge(
        [_region(answerParts: const [])],
        _index(answer: placeholder),
      ).single;
      expect(merged.answerText, isEmpty, reason: placeholder);
    }

    final conflicted = merger.merge(
      [_region(answerParts: const [])],
      ReferenceAnswerIndex(
        entries: const {},
        conflictedNumbers: const {1},
        diagnostics: const {},
      ),
    ).single;
    expect(
      conflicted.diagnostics,
      contains('reference_answer_duplicate_conflict'),
    );
    expect(conflicted.answerText, isEmpty);
    expect(conflicted.ownedSources, isEmpty);
    expect(conflicted.evidenceOnlySourceBlockIds, isEmpty);
  });

  test('a block already owning local content is not reclassified as evidence',
      () {
    final merged = merger.merge(
      [
        _region(
          answerParts: const ['Local answer'],
          sourceBlockIds: const ['question_block', 'shared_block'],
          ownedSources: const <OcrQuestionRegionSource>[
            OcrQuestionRegionSource(
              blockId: 'shared_block',
              field: OcrRegionField.answer,
              text: 'Local answer',
            ),
          ],
        ),
      ],
      _index(
        answer: 'Different reference answer',
        sourceBlockIds: const <String>['shared_block'],
      ),
    ).single;

    expect(merged.evidenceOnlySourceBlockIds, isEmpty);
    expect(merged.ownedSources, hasLength(1));
    expect(merged.diagnostics, contains('reference_answer_conflict'));
  });

  test('does not expose answer text through diagnostics', () {
    const sensitiveAnswer = 'SENSITIVE_ANSWER_BODY';
    final merged = merger.merge(
      [_region(answerParts: const [])],
      _index(answer: sensitiveAnswer),
    ).single;

    expect(merged.diagnostics.join('|'), isNot(contains(sensitiveAnswer)));
  });

  test('preserves 22-question order and all non-answer fields', () {
    final regions = List.generate(
      22,
      (index) => OcrQuestionRegion(
        number: index + 1,
        stemParts: ['Stem ${index + 1}'],
        answerParts: const [],
        explanationParts: ['Explanation ${index + 1}'],
        sourcePageIndices: const [1],
        sourceBlockIds: ['q${index + 1}'],
        diagnostics: const [],
        declaredKind: index < 10
            ? TextQuestionKind.choice
            : index < 16
                ? TextQuestionKind.fillBlank
                : TextQuestionKind.subjective,
      ),
    );
    final merged = merger.merge(
      regions,
      ReferenceAnswerIndex(
        entries: {
          for (final number in const [17, 18, 19, 20, 22])
            number: ReferenceAnswerEntry(
              questionNumber: number,
              answerText: 'Answer $number',
              sourcePageIndices: const [3],
              sourceBlockIds: ['answer_$number'],
              patternKind: 'explicit_numbered',
            ),
        },
        conflictedNumbers: const {},
        diagnostics: const {},
      ),
    );

    expect(merged, hasLength(22));
    expect(
        merged.map((region) => region.number), List.generate(22, (i) => i + 1));
    for (var index = 0; index < merged.length; index++) {
      expect(merged[index].stemParts, regions[index].stemParts);
      expect(merged[index].explanationParts, regions[index].explanationParts);
      expect(merged[index].declaredKind, regions[index].declaredKind);
    }
  });
}

OcrQuestionRegion _region({
  required List<String> answerParts,
  List<String> diagnostics = const [],
  List<String> sourceBlockIds = const ['question_block'],
  List<OcrQuestionRegionSource> ownedSources =
      const <OcrQuestionRegionSource>[],
}) {
  return OcrQuestionRegion(
    number: 1,
    stemParts: const ['Synthetic question'],
    answerParts: answerParts,
    explanationParts: const ['Synthetic explanation'],
    sourcePageIndices: const [1],
    sourceBlockIds: sourceBlockIds,
    ownedSources: ownedSources,
    diagnostics: diagnostics,
    declaredKind: TextQuestionKind.subjective,
  );
}

ReferenceAnswerIndex _index({
  required String answer,
  List<String> sourceBlockIds = const ['reference_block'],
}) {
  return ReferenceAnswerIndex(
    entries: {
      1: ReferenceAnswerEntry(
        questionNumber: 1,
        answerText: answer,
        sourcePageIndices: const [3],
        sourceBlockIds: sourceBlockIds,
        patternKind: 'explicit_numbered',
      ),
    },
    conflictedNumbers: const {},
    diagnostics: const {},
  );
}

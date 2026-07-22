import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/import_pipeline/multi_file_question_merge_service.dart';

void main() {
  const service = MultiFileQuestionMergeService();

  MultiFileQuestionBatch stemBatch({
    int fileIndex = 0,
    int count = 1,
    String Function(int number)? marker,
    String Function(int number)? content,
  }) {
    return MultiFileQuestionBatch(
      fileIndex: fileIndex,
      questions: List.generate(count, (index) {
        final number = index + 1;
        return <String, dynamic>{
          'q_num': marker?.call(number) ?? '（$number）',
          'content': content?.call(number) ?? '第 $number 道完整题干，包含全部条件与明确求解要求。',
          'options': <String>['A. 甲', 'B. 乙', 'C. 丙', 'D. 丁'],
          'standard_answer': '',
          'explanation': '',
          'source': 'glm_ocr_intermediate',
          'source_page_indices': <int>[number],
          'source_block_ids': <String>['stem_$number'],
        };
      }),
    );
  }

  MultiFileQuestionBatch answerBatch({
    int fileIndex = 1,
    int count = 1,
    String Function(int number)? marker,
    String Function(int number)? content,
    String Function(int number)? answer,
  }) {
    return MultiFileQuestionBatch(
      fileIndex: fileIndex,
      questions: List.generate(count, (index) {
        final number = index + 1;
        return <String, dynamic>{
          'q_num': marker?.call(number) ?? '$number.',
          'content': content?.call(number) ?? '第 $number 题简要提示',
          'options': <String>[],
          'standard_answer': answer?.call(number) ?? 'answer-$number',
          'explanation': '第 $number 题的脱敏解析',
          'source': 'glm_ocr_intermediate',
          'source_page_indices': <int>[number + 100],
          'source_block_ids': <String>['answer_$number'],
        };
      }),
    );
  }

  test('matches （１） and 1. by explicit question number', () {
    final result = service.merge([
      stemBatch(marker: (_) => '（１）'),
      answerBatch(marker: (_) => '1.'),
    ]);

    expect(result.mergedQuestions, hasLength(1));
    expect(result.mergedQuestions.single['q_num'], '1');
    expect(result.mergedQuestions.single['standard_answer'], 'answer-1');
    expect(result.metrics.exactQuestionNumberBucketCount, 1);
    expect(result.blocked, isFalse);
  });

  test('uses explicit question_number when q_num is absent', () {
    final stem = stemBatch();
    stem.questions.single
      ..remove('q_num')
      ..['question_number'] = 1;

    final result = service.merge([stem, answerBatch()]);

    expect(result.mergedQuestions, hasLength(1));
    expect(result.mergedQuestions.single['question_number'], 1);
    expect(result.residualFragments, isEmpty);
  });

  test('23 stems plus 23 answers deterministically produce 23 questions', () {
    final result = service.merge([
      stemBatch(count: 23),
      answerBatch(count: 23),
    ]);

    expect(result.mergedQuestions, hasLength(23));
    expect(result.residualFragments, isEmpty);
    expect(result.conflictFragments, isEmpty);
    expect(result.metrics.mergedQuestionCount, 23);
    expect(result.metrics.answerOnlyMergeCount, 23);
    expect(result.metrics.finalQuestionCount, 23);
    expect(result.requiresReview, isFalse);
    expect(result.blocked, isFalse);
  });

  test('is synchronous and creates no HTTP client or AI collaborator', () {
    var httpClientCreationCount = 0;

    final result = HttpOverrides.runZoned(
      () => service.merge([stemBatch(), answerBatch()]),
      createHttpClient: (context) {
        httpClientCreationCount++;
        return HttpClient(context: context);
      },
    );

    expect(result, isA<MultiFileQuestionMergeResult>());
    expect(httpClientCreationCount, 0);
  });

  test('stem-dominant content wins and options stay with selected stem', () {
    final result = service.merge([
      stemBatch(
        content: (_) => '完整题干包含条件甲、条件乙以及最终求值要求。',
      ),
      answerBatch(
        content: (_) => '简化题干',
      ),
    ]);

    final question = result.mergedQuestions.single;
    expect(question['content'], '完整题干包含条件甲、条件乙以及最终求值要求。');
    expect(question['options'], <String>['A. 甲', 'B. 乙', 'C. 丙', 'D. 丁']);
    expect(result.batchProfiles[0].role, QuestionBatchRole.stemDominant);
    expect(result.batchProfiles[1].role, QuestionBatchRole.answerDominant);
  });

  test('profiles mixed and ambiguous batches from aggregate field coverage',
      () {
    final mixed = MultiFileQuestionBatch(
      fileIndex: 4,
      questions: <Map<String, dynamic>>[
        <String, dynamic>{
          'q_num': '1',
          'content': '完整题干',
          'options': <String>['A', 'B'],
          'standard_answer': 'A',
          'explanation': '脱敏解析',
        },
      ],
    );

    final result = service.merge([
      mixed,
      const MultiFileQuestionBatch(
        fileIndex: 9,
        questions: <Map<String, dynamic>>[],
      ),
    ]);

    expect(result.batchProfiles[0].role, QuestionBatchRole.mixed);
    expect(result.batchProfiles[1].role, QuestionBatchRole.ambiguous);
    expect(result.batchProfiles[0].validStemRatio, 1);
    expect(result.batchProfiles[0].completeOptionsRatio, 1);
    expect(result.batchProfiles[0].answerRatio, 1);
    expect(result.batchProfiles[0].explanationRatio, 1);
  });

  test('deduplicates equal answers after comparison normalization', () {
    final result = service.merge([
      stemBatch(),
      answerBatch(fileIndex: 1, answer: (_) => ' A '),
      answerBatch(fileIndex: 2, answer: (_) => 'a'),
    ]);

    expect(result.mergedQuestions.single['standard_answer'], 'A');
    expect(result.metrics.answerConflictCount, 0);
    expect(result.blocked, isFalse);
  });

  test('clears conflicting answers and blocks without exposing answer text',
      () {
    final result = service.merge([
      stemBatch(),
      answerBatch(fileIndex: 1, answer: (_) => 'A'),
      answerBatch(fileIndex: 2, answer: (_) => 'B'),
    ]);

    expect(result.mergedQuestions.single['standard_answer'], '');
    expect(result.metrics.answerConflictCount, 1);
    expect(result.requiresReview, isTrue);
    expect(result.blocked, isTrue);
    expect(result.conflictFragments.single.questionNumber, 1);
    expect(
      result.conflictFragments.single.fragmentIds,
      containsAll(<String>['file_1_question_0', 'file_2_question_0']),
    );
    final safeConflict = jsonEncode(result.conflictFragments.single.toMap());
    expect(safeConflict, isNot(contains('"A"')));
    expect(safeConflict, isNot(contains('"B"')));
  });

  test('materially different authoritative stems become a conflict', () {
    final result = service.merge([
      stemBatch(content: (_) => '对象甲满足条件，求参数的全部可能取值。'),
      stemBatch(
        fileIndex: 1,
        content: (_) => '对象乙具有另一组性质，证明给定结论成立。',
      ),
    ]);

    expect(result.mergedQuestions, isEmpty);
    expect(result.residualFragments, hasLength(2));
    expect(result.metrics.stemConflictCount, 1);
    expect(result.requiresReview, isTrue);
    expect(result.blocked, isTrue);
  });

  test('duplicate question number within one file becomes a conflict', () {
    final duplicated = MultiFileQuestionBatch(
      fileIndex: 0,
      questions: <Map<String, dynamic>>[
        stemBatch().questions.single,
        <String, dynamic>{
          ...stemBatch().questions.single,
          'q_num': '1.',
          'content': '同一文件中的另一道第一题。',
          'source_block_ids': <String>['duplicate_1'],
        },
      ],
    );

    final result = service.merge([duplicated, answerBatch()]);

    expect(result.mergedQuestions, isEmpty);
    expect(result.residualFragments, hasLength(3));
    expect(result.metrics.duplicateKeyCount, 1);
    expect(result.blocked, isTrue);
  });

  test('unnumbered fragments remain residual and are not content-matched', () {
    final result = service.merge([
      const MultiFileQuestionBatch(
        fileIndex: 0,
        questions: <Map<String, dynamic>>[
          <String, dynamic>{'content': '1. 相同正文', 'standard_answer': ''},
        ],
      ),
      const MultiFileQuestionBatch(
        fileIndex: 1,
        questions: <Map<String, dynamic>>[
          <String, dynamic>{'content': '相同正文', 'standard_answer': 'A'},
        ],
      ),
    ]);

    expect(result.mergedQuestions, isEmpty);
    expect(result.residualFragments, hasLength(2));
    expect(result.metrics.unmatchedFragmentCount, 2);
    expect(result.blocked, isTrue);
  });

  test('does not depend on input batch order or file order', () {
    final forward = service.merge([
      stemBatch(fileIndex: 7),
      answerBatch(fileIndex: 2),
    ]);
    final reversed = service.merge([
      answerBatch(fileIndex: 2),
      stemBatch(fileIndex: 7),
    ]);
    final rolesReversed = service.merge([
      answerBatch(fileIndex: 0),
      stemBatch(fileIndex: 1),
    ]);

    for (final result in <MultiFileQuestionMergeResult>[
      forward,
      reversed,
      rolesReversed,
    ]) {
      expect(
          result.mergedQuestions.single['content'], '第 1 道完整题干，包含全部条件与明确求解要求。');
      expect(result.mergedQuestions.single['standard_answer'], 'answer-1');
      expect(result.blocked, isFalse);
    }
  });

  test('merges provenance and removes duplicates', () {
    final stem = stemBatch();
    stem.questions.single['source_page_indices'] = <int>[1, 2];
    stem.questions.single['source_block_ids'] = <String>['shared', 'stem'];
    final answer = answerBatch();
    answer.questions.single['source_page_indices'] = <int>[2, 3];
    answer.questions.single['source_block_ids'] = <String>['shared', 'answer'];

    final question = service.merge([stem, answer]).mergedQuestions.single;

    expect(question['source_page_indices'], <int>[1, 2, 3]);
    expect(question['source_block_ids'], <String>['answer', 'shared', 'stem']);
    expect(question['source_file_indices'], <int>[0, 1]);
    expect(question['source_fragment_ids'],
        <String>['file_0_question_0', 'file_1_question_0']);
  });

  test('metrics and profiles contain no private content or paths', () {
    final result = service.merge([
      stemBatch(
        content: (_) => 'PRIVATE_STEM_BASE64_PAYLOAD',
      ),
      answerBatch(
        content: (_) => 'PRIVATE_ANSWER_SUMMARY',
        answer: (_) => 'PRIVATE_ANSWER',
      ),
    ]);

    final safePayload = jsonEncode(<String, dynamic>{
      'metrics': result.metrics.toMap(),
      'profiles':
          result.batchProfiles.map((profile) => profile.toMap()).toList(),
    });

    expect(safePayload, isNot(contains('PRIVATE_STEM')));
    expect(safePayload, isNot(contains('PRIVATE_ANSWER')));
    expect(safePayload, isNot(contains(r'C:\Users')));
    expect(safePayload.toLowerCase(), isNot(contains('base64')));
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_question_regionizer.dart';
import 'package:shiroha_quiz/services/import_pipeline/reference_answer_extractor.dart';
import 'package:shiroha_quiz/services/import_pipeline/reference_answer_merger.dart';
import 'package:shiroha_quiz/services/import_pipeline/reference_answer_section.dart';
import 'package:shiroha_quiz/services/import_pipeline/text_question_region.dart';

void main() {
  const extractor = ReferenceAnswerExtractor();

  group('ReferenceAnswerExtractor section boundaries', () {
    test('starts only after an explicit supported heading', () {
      for (final heading in const ['参考答案', '答案汇总', '答案速查']) {
        final result = extractor.extract(
          _document([
            _block('q1', 0, '1. Official question'),
            _block('title', 1, '## $heading：'),
            _block('answers', 2, '1.A 2.B 3.C'),
          ]),
          _regions(3, lastBlockId: 'q1'),
        );

        expect(result.diagnostics['referenceSectionDetected'], isTrue,
            reason: heading);
        expect(result.entries.keys, [1, 2, 3], reason: heading);
      }
    });

    test('starts after a supported heading suffix in a composite title', () {
      final result = extractor.extract(
        _document([
          _block('q18', 0, '18. Official question'),
          _block('title', 1, '2022 模拟试卷参考答案汇总'),
          _block('a17', 2, '(17) First answer'),
          _block(
              'a17_more', 3, r'Second line \begin{matrix}1&0\\0&1\end{matrix}'),
          _block('a18', 4, '（18）Second answer'),
        ]),
        _regions(18, lastBlockId: 'q18'),
      );

      expect(result.diagnostics['referenceSectionDetected'], isTrue);
      expect(result.entries.keys, [17, 18]);
      expect(
        result.entries[17]!.answerText,
        'First answer\n'
        r'Second line \begin{matrix}1&0\\0&1\end{matrix}',
      );
      expect(result.entries[18]!.answerText, 'Second answer');
    });

    test(
        'starts from a supported heading embedded in the final compound block without question stem',
        () {
      final document = _document([
        _block('q1', 0, '1. Official question'),
        _block(
          'compound',
          1,
          'Tail explanation\r\n'
              '第二行说明\r\n'
              '2022 模拟试卷参考答案汇总\r\n'
              '安全说明',
        ),
        _block('a1', 2, '(1) First answer'),
      ]);
      final regionized = const OcrQuestionRegionizer().regionize(document);
      final boundary = regionized.referenceAnswerSectionBoundary;

      expect(boundary, isNotNull);
      expect(boundary!.blockId, 'compound');
      expect(boundary.pageIndex, 1);
      expect(boundary.headingLineIndex, 2);

      final result = extractor.extract(
        document,
        regionized.regions,
        referenceSectionBoundary: boundary,
      );

      expect(result.diagnostics['referenceSectionDetected'], isTrue);
      expect(result.entries.keys, [1]);
      expect(result.entries[1]!.answerText, 'First answer');
    });

    test('accepts year-led exam titles with bounded subject descriptors', () {
      for (final title in const <String>[
        '# 2022年全国硕士研究生招生考试数学（一）答案速查',
        '2024年全国硕士研究生招生考试英语（二）参考答案',
        '2021年普通高等学校招生全国统一考试文科数学答案汇总',
        '2020年高三第二次模拟考试（理科）试题答案及评分参考',
        '2020年高考真题数学试卷参考答案',
        '2022年试题参考答案',
      ]) {
        expect(
          hasReferenceAnswerSectionHeadingSuffix(title),
          isTrue,
          reason: title,
        );
      }
    });

    test(
        'certifies a year-led composite title qualified by subject name in the final physical block',
        () {
      final blocks = <OcrBlock>[];
      var order = 0;

      void add(String id, String text) {
        blocks.add(_block(id, order++, text));
      }

      add('official_choice', '一、选择题');
      for (var number = 1; number <= 10; number++) {
        add('q$number', '$number. Choice prompt $number.');
      }
      add('official_fill', '二、填空题');
      for (var number = 11; number <= 16; number++) {
        add('q$number', '$number. Fill prompt $number.');
      }
      add('official_subjective', '三、解答题');
      for (var number = 17; number <= 22; number++) {
        add('q$number', '$number. Subjective prompt $number.');
        if (number == 21) {
          add('q21_answer', '答案：Local answer 21');
        }
      }
      add(
        'compound',
        '解析：Continuation for the final question.\r\n'
            '# 2022年全国硕士研究生招生考试数学（一）答案速查\r\n'
            '(17) Reference answer 17\r\n'
            '(18) Reference answer 18\r\n'
            '(19) Reference answer 19\r\n'
            '(20) Reference answer 20\r\n'
            '(21) Local answer 21\r\n'
            '(22) Reference answer 22',
      );

      final document = _document(blocks);
      final regionized = const OcrQuestionRegionizer().regionize(document);
      final boundary = regionized.referenceAnswerSectionBoundary;

      expect(boundary, isNotNull);
      expect(boundary!.blockId, 'compound');
      expect(boundary.headingLineIndex, 1);

      final extracted = extractor.extract(
        document,
        regionized.regions,
        referenceSectionBoundary: boundary,
      );

      expect(extracted.diagnostics['referenceSectionDetected'], isTrue);
      expect(extracted.entries.keys.toList(), [17, 18, 19, 20, 21, 22]);

      final merged = const ReferenceAnswerMerger().merge(
        regionized.regions,
        extracted,
      );
      for (final number in [17, 18, 19, 20, 22]) {
        final region = merged.singleWhere((item) => item.number == number);
        expect(region.answerText, 'Reference answer $number');
        expect(region.diagnostics, contains('reference_answer_attached'));
      }
      final q21 = merged.singleWhere((region) => region.number == 21);
      expect(q21.answerText, 'Local answer 21');
      expect(q21.diagnostics, contains('reference_answer_confirmed'));
    });

    test(
        'certifies a bounded answer and scoring heading in the final physical block',
        () {
      final blocks = <OcrBlock>[];
      var order = 0;

      void add(String id, String text) {
        blocks.add(_block(id, order++, text));
      }

      add('official_choice', '一、选择题');
      for (var number = 1; number <= 10; number++) {
        add('q$number', '$number. Synthetic choice prompt $number.');
      }
      add('official_fill', '二、填空题');
      for (var number = 11; number <= 16; number++) {
        add('q$number', '$number. Synthetic fill prompt $number.');
      }
      add('official_subjective', '三、解答题');
      for (var number = 17; number <= 22; number++) {
        add('q$number', '$number. Synthetic subjective prompt $number.');
        if (number == 21) {
          add('q21_answer', '答案：Synthetic local answer 21');
        }
      }
      add(
        'compound',
        '解析：Synthetic continuation for the final question.\r\n'
            '<div align="center">\r\n'
            '# 2024 合成试卷参考答案及评分参考\r\n'
            '(17) Synthetic reference answer 17\r\n'
            '(18) Synthetic reference answer 18\r\n'
            '(19) Synthetic reference answer 19\r\n'
            '(20) Synthetic reference answer 20\r\n'
            '(21) Synthetic local answer 21\r\n'
            '(22) Synthetic reference answer 22\r\n'
            '详细解析',
      );
      add('reference_choice', '一、选择题');
      add('reference_choice_entry', '（1）A');
      add('reference_fill', '二、填空题');
      add('reference_fill_entry', '（11）Synthetic fill reference');
      add('reference_subjective', '三、解答题');
      add('reference_subjective_entry', '（17）Synthetic detail');

      final document = _document(blocks);
      final regionized = const OcrQuestionRegionizer().regionize(document);
      final q22 = regionized.regions.singleWhere(
        (region) => region.number == 22,
      );
      final boundary = regionized.referenceAnswerSectionBoundary;
      final extracted = extractor.extract(
        document,
        regionized.regions,
        referenceSectionBoundary: boundary,
      );

      expect(
        <String, Object?>{
          'acceptedQuestions': regionized.diagnostics['acceptedNumbers'],
          'genericReferenceMode':
              regionized.diagnostics['referenceSectionDetected'],
          'boundaryCertified': boundary != null,
          'extractorSectionDetected':
              extracted.diagnostics['referenceSectionDetected'],
          'acceptedReferenceNumbers': extracted.entries.keys.toList(),
          'q22UsesPhysicalBlock': q22.sourceBlockIds.contains('compound'),
          'syntheticSplitIdentityLeaked':
              q22.sourceBlockIds.any((id) => id.contains('#')),
        },
        <String, Object?>{
          'acceptedQuestions': List<int>.generate(22, (index) => index + 1),
          'genericReferenceMode': true,
          'boundaryCertified': true,
          'extractorSectionDetected': true,
          'acceptedReferenceNumbers': const <int>[17, 18, 19, 20, 21, 22],
          'q22UsesPhysicalBlock': true,
          'syntheticSplitIdentityLeaked': false,
        },
      );

      expect(boundary!.blockId, 'compound');
      expect(boundary.pageIndex, 1);
      expect(boundary.headingLineIndex, 2);
      for (final number in const <int>[17, 18, 19, 20, 21, 22]) {
        expect(extracted.entries[number]!.sourceBlockIds, <String>['compound']);
      }

      final merged = const ReferenceAnswerMerger().merge(
        regionized.regions,
        extracted,
      );
      for (final number in const <int>[17, 18, 19, 20, 22]) {
        final region = merged.singleWhere((item) => item.number == number);
        expect(region.answerText, 'Synthetic reference answer $number');
        expect(region.diagnostics, contains('reference_answer_attached'));
        expect(
          region.ownedSources.where(
            (source) => source.field == OcrRegionField.answer,
          ),
          isEmpty,
        );
      }

      final q21 = merged.singleWhere((region) => region.number == 21);
      expect(q21.answerText, 'Synthetic local answer 21');
      expect(q21.diagnostics, contains('reference_answer_confirmed'));
      expect(q21.diagnostics, isNot(contains('reference_answer_attached')));
      expect(
        q21.ownedSources
            .where((source) => source.field == OcrRegionField.answer)
            .map((source) => source.blockId),
        <String>['q21_answer'],
      );
    });

    test('does not start from a supported heading followed by prose', () {
      final result = extractor.extract(
        _document([
          _block('q1', 0, '1. Official question'),
          _block('not_title', 1, '参考答案汇总说明'),
          _block('answer_like', 2, '(1) A'),
        ]),
        _regions(1, lastBlockId: 'q1'),
      );

      expect(result.diagnostics['referenceSectionDetected'], isFalse);
      expect(result.entries, isEmpty);
    });

    test('rejects free-text prefixes and suffixes around an answer core', () {
      for (final prose in const <String>[
        '正文中提到参考答案',
        '这里可参考答案',
        '参考答案用于解释正文',
        '参考答案见前文',
      ]) {
        final result = extractor.extract(
          _document([
            _block('q1', 0, '1. Official question'),
            _block('prose', 1, prose),
            _block('answer_like', 2, '(1) A'),
          ]),
          _regions(1, lastBlockId: 'q1'),
        );

        expect(
          result.diagnostics['referenceSectionDetected'],
          isFalse,
          reason: prose,
        );
        expect(result.entries, isEmpty, reason: prose);
      }
    });

    test('does not start from a heading inside an official region', () {
      final result = extractor.extract(
        _document([
          _block('q1', 0, '1. Official question\n参考答案'),
          _block('answer_like', 1, '1.A 2.B'),
        ]),
        _regions(2, lastBlockId: 'q1'),
      );

      expect(result.entries, isEmpty);
      expect(result.diagnostics['referenceSectionDetected'], isFalse);
    });

    test('fails closed when a declared boundary is stale or invalid', () {
      final result = extractor.extract(
        _document([
          _block('q1', 0, '1. Official question'),
          _block('title', 1, '参考答案'),
          _block('answer_like', 2, '(1) A'),
        ]),
        _regions(1, lastBlockId: 'q1'),
        referenceSectionBoundary: const OcrReferenceAnswerSectionBoundary(
          blockId: 'q1',
          pageIndex: 1,
          headingLineIndex: 0,
        ),
      );

      expect(result.entries, isEmpty);
      expect(result.diagnostics['referenceSectionDetected'], isFalse);
    });

    test(
        'does not infer a reference boundary inside the final official continuation block',
        () {
      final result = extractor.extract(
        _document([
          _block('q1_start', 0, '1. Official question'),
          _block(
            'q1_continuation',
            1,
            'Continuation derivation\n参考答案\n(1) Answer-like continuation',
          ),
        ]),
        [
          OcrQuestionRegion(
            number: 1,
            stemParts: const ['Official question'],
            answerParts: const [],
            explanationParts: const ['Continuation derivation'],
            sourcePageIndices: const [1],
            sourceBlockIds: const ['q1_start', 'q1_continuation'],
            diagnostics: const [],
            declaredKind: TextQuestionKind.subjective,
          ),
        ],
      );

      expect(result.entries, isEmpty);
      expect(result.diagnostics['referenceSectionDetected'], isFalse);
    });

    test(
        'production chain does not certify a bare heading inside an official continuation block',
        () {
      final document = _document([
        _block('q1_start', 0, '1. Official question'),
        _block(
          'q1_continuation',
          1,
          'Continuation derivation\n参考答案\n(1) Answer-like continuation',
        ),
      ]);

      final regionized = const OcrQuestionRegionizer().regionize(document);
      final result = extractor.extract(
        document,
        regionized.regions,
        referenceSectionBoundary: regionized.referenceAnswerSectionBoundary,
      );

      expect(regionized.regions, hasLength(1));
      expect(
        regionized.regions.single.sourceBlockIds,
        containsAllInOrder(['q1_start', 'q1_continuation']),
      );
      expect(regionized.referenceAnswerSectionBoundary, isNull);
      expect(regionized.diagnostics['referenceSectionDetected'], isFalse);
      expect(result.entries, isEmpty);
    });

    test(
        'production chain rejects prose ending in a document-title token before an answer heading',
        () {
      for (final prose in const <String>[
        '证明中不能直接照抄考试参考答案',
        '# 证明中不能直接照抄考试参考答案',
        '本段复核试卷答案汇总',
        '推导中引用试题参考答案及评分参考',
      ]) {
        final document = _document([
          _block('q1_start', 0, '1. Official question'),
          _block(
            'q1_continuation',
            1,
            'Continuation derivation\n$prose\n'
                '(1) Answer-like continuation',
          ),
        ]);

        final regionized = const OcrQuestionRegionizer().regionize(document);
        final result = extractor.extract(
          document,
          regionized.regions,
          referenceSectionBoundary: regionized.referenceAnswerSectionBoundary,
        );

        expect(regionized.regions, hasLength(1), reason: prose);
        expect(
          regionized.regions.single.sourceBlockIds,
          containsAllInOrder(['q1_start', 'q1_continuation']),
          reason: prose,
        );
        expect(
          regionized.referenceAnswerSectionBoundary,
          isNull,
          reason: prose,
        );
        expect(
          regionized.diagnostics['referenceSectionDetected'],
          isFalse,
          reason: prose,
        );
        expect(result.entries, isEmpty, reason: prose);
      }
    });

    test('does not start before the final official region', () {
      final result = extractor.extract(
        _document([
          _block('q1', 0, '1. Official question'),
          _block('title', 1, '参考答案'),
          _block('answer_like', 2, '1.A 2.B'),
          _block('q2', 3, '2. Later official question'),
        ]),
        _regions(2, lastBlockId: 'q2'),
      );

      expect(result.entries, isEmpty);
      expect(result.diagnostics['referenceSectionDetected'], isFalse);
    });

    test('stops at a new non-answer section', () {
      final result = extractor.extract(
        _document([
          _block('q2', 0, '2. Official question'),
          _block('title', 1, '参考答案'),
          _block('a1', 2, '1.A 2.B'),
          _block('stop', 3, '详细解析'),
          _block('ignored', 4, '3.C 4.D'),
        ]),
        _regions(4, lastBlockId: 'q2'),
      );

      expect(result.entries.keys, [1, 2]);
    });
  });

  group('ReferenceAnswerExtractor formats and safety', () {
    test('parses dense objective answers in dotted and spaced forms', () {
      final result = extractor.extract(
        _document([
          _block('q4', 0, '4. Official question'),
          _block('title', 1, '答案一览'),
          _block('dense1', 2, '1.A 2.B'),
          _block('dense2', 3, '3 C 4 D'),
        ]),
        _regions(4, lastBlockId: 'q4'),
      );

      expect(
        result.entries
            .map((number, entry) => MapEntry(number, entry.answerText)),
        {1: 'A', 2: 'B', 3: 'C', 4: 'D'},
      );
    });

    test('parses explicit and multiline answers without damaging LaTeX', () {
      final result = extractor.extract(
        _document([
          _block('q18', 0, '18. Official question'),
          _block('title', 1, '全卷答案'),
          _block('a17', 2, '17. 第一行答案'),
          _block('a17_more', 3, r'第二行 \begin{matrix}1&0\\0&1\end{matrix}'),
          _block('a18', 4, '18 答案：下一题答案'),
        ]),
        _regions(18, lastBlockId: 'q18'),
      );

      expect(
        result.entries[17]!.answerText,
        '第一行答案\n'
        r'第二行 \begin{matrix}1&0\\0&1\end{matrix}',
      );
      expect(result.entries[18]!.answerText, '下一题答案');
    });

    test('parses dense parenthesized objective answers conservatively', () {
      final result = extractor.extract(
        _document([
          _block('q4', 0, '4. Official question'),
          _block('title', 1, '答案一览'),
          _block('answers', 2, '(1) A （2）B (3) C （4）D'),
        ]),
        _regions(4, lastBlockId: 'q4'),
      );

      expect(
        result.entries
            .map((number, entry) => MapEntry(number, entry.answerText)),
        {1: 'A', 2: 'B', 3: 'C', 4: 'D'},
      );
    });

    test('keeps backward parenthesized substeps in the pending answer', () {
      final result = extractor.extract(
        _document([
          _block('q22', 0, '22. Official question'),
          _block('title', 1, '参考答案'),
          _block('a21', 2, '(21) Main answer'),
          _block('substep', 3, '(1) Supporting step'),
          _block('a22', 4, '(22) Next answer'),
        ]),
        _regions(22, lastBlockId: 'q22'),
      );

      expect(result.entries.keys, [21, 22]);
      expect(
        result.entries[21]!.answerText,
        'Main answer\n(1) Supporting step',
      );
      expect(result.entries[22]!.answerText, 'Next answer');
    });

    test('ignores years, step numbers, unknown numbers, and empty answers', () {
      final result = extractor.extract(
        _document([
          _block('q22', 0, '22. Official question'),
          _block('title', 1, '试题答案'),
          _block('year', 2, '2022. Edition'),
          _block('step', 3, '步骤 1. Intermediate'),
          _block('unknown', 4, '23. Unknown'),
          _block('empty', 5, '17.'),
          _block('next', 6, '18. Valid answer'),
        ]),
        _regions(22, lastBlockId: 'q22'),
      );

      expect(result.entries.keys, [18]);
      expect(result.diagnostics['acceptedNumbers'], [18]);
    });

    test('deduplicates identical answers and rejects conflicting answers', () {
      final result = extractor.extract(
        _document([
          _block('q18', 0, '18. Official question'),
          _block('title', 1, '参考答案'),
          _block('a17', 2, '17. Same answer'),
          _block('a17_dup', 3, '17. Same   answer'),
          _block('a18', 4, '18. First answer'),
          _block('a18_conflict', 5, '18. Different answer'),
        ]),
        _regions(18, lastBlockId: 'q18'),
      );

      expect(result.entries[17]!.answerText, 'Same answer');
      expect(result.entries.containsKey(18), isFalse);
      expect(result.conflictedNumbers, {18});
      expect(result.diagnostics['conflictCount'], 1);
    });

    test('safe diagnostics never contain answer text or block ids', () {
      final result = extractor.extract(
        _document([
          _block('q1', 0, '1. Official question'),
          _block('title', 1, '参考答案'),
          _block('sensitive_block', 2, '1.A 2.B'),
        ]),
        _regions(2, lastBlockId: 'q1'),
      );
      final diagnostics = result.diagnostics.toString();

      expect(diagnostics, isNot(contains('sensitive_block')));
      expect(diagnostics, isNot(contains('1.A')));
      expect(diagnostics, isNot(contains('2.B')));
    });
  });
}

OcrDocument _document(List<OcrBlock> blocks) {
  return OcrDocument(
    sourceName: 'synthetic.pdf',
    pages: [OcrPage(pageIndex: 1, blocks: blocks)],
    markdown: '',
    rawResponses: const [],
    usage: const {},
  );
}

OcrBlock _block(String id, int order, String text) {
  return OcrBlock(
    blockId: id,
    pageIndex: 1,
    type: 'text',
    text: text,
    bbox: const [],
    readingOrder: order,
  );
}

List<OcrQuestionRegion> _regions(int count, {required String lastBlockId}) {
  return List.generate(
    count,
    (index) {
      final number = index + 1;
      return OcrQuestionRegion(
        number: number,
        stemParts: ['Official question $number'],
        answerParts: const [],
        explanationParts: const [],
        sourcePageIndices: const [1],
        sourceBlockIds: [number == count ? lastBlockId : 'official_$number'],
        diagnostics: const [],
        declaredKind: TextQuestionKind.subjective,
      );
    },
  );
}

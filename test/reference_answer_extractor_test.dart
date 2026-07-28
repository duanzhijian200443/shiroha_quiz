import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_question_regionizer.dart';
import 'package:shiroha_quiz/services/import_pipeline/reference_answer_extractor.dart';
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

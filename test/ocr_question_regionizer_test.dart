import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_question_regionizer.dart';
import 'package:shiroha_quiz/services/import_pipeline/text_question_region.dart';

void main() {
  group('OcrQuestionRegionizer', () {
    test('keeps one cross-page question region with answer and explanation',
        () {
      final document = OcrDocument(
        sourceName: 'sample.pdf',
        markdown: '',
        rawResponses: const [],
        usage: const {},
        pages: [
          OcrPage(
            pageIndex: 1,
            blocks: [
              const OcrBlock(
                blockId: 'p001_b0001',
                pageIndex: 1,
                type: 'text',
                text: '1 设 lim f(x)/ln x = 1，则（ ）\n(A) f(1)=0\n(B) lim f(x)=0',
                bbox: [],
                readingOrder: 0,
              ),
            ],
          ),
          OcrPage(
            pageIndex: 2,
            blocks: [
              const OcrBlock(
                blockId: 'p002_b0001',
                pageIndex: 2,
                type: 'text',
                text: '答案：B',
                bbox: [],
                readingOrder: 0,
              ),
              const OcrBlock(
                blockId: 'p002_b0002',
                pageIndex: 2,
                type: 'text',
                text: '解析：由极限可知 ...',
                bbox: [],
                readingOrder: 1,
              ),
            ],
          ),
        ],
      );

      final result = const OcrQuestionRegionizer().regionize(document);

      expect(result.regions, hasLength(1));
      final region = result.regions.single;
      expect(region.number, 1);
      expect(region.isCrossPage, isTrue);
      expect(region.answerText, contains('B'));
      expect(region.explanationText, contains('由极限'));
      expect(region.sourcePageIndices, [1, 2]);
      expect(result.diagnostics['regionCount'], 1);
    });

    test('treats section headings as hard boundaries', () {
      final document = OcrDocument(
        sourceName: 'sample.pdf',
        markdown: '',
        rawResponses: const [],
        usage: const {},
        pages: [
          OcrPage(
            pageIndex: 1,
            blocks: [
              const OcrBlock(
                blockId: 'p001_b0001',
                pageIndex: 1,
                type: 'text',
                text: '13 设 A,B,C 为随机事件，求概率。',
                bbox: [],
                readingOrder: 0,
              ),
              const OcrBlock(
                blockId: 'p001_b0002',
                pageIndex: 1,
                type: 'text',
                text: '解析：这是上一题的解释。',
                bbox: [],
                readingOrder: 1,
              ),
            ],
          ),
          OcrPage(
            pageIndex: 2,
            blocks: [
              const OcrBlock(
                blockId: 'p002_b0001',
                pageIndex: 2,
                type: 'text',
                text: '## 三，填空题',
                bbox: [],
                readingOrder: 0,
              ),
              const OcrBlock(
                blockId: 'p002_b0002',
                pageIndex: 2,
                type: 'text',
                text: '14 已知矩阵 A 和 E-A 可逆，求 B-A = ____。',
                bbox: [],
                readingOrder: 1,
              ),
            ],
          ),
        ],
      );

      final result = const OcrQuestionRegionizer().regionize(document);

      expect(result.regions, hasLength(2));
      expect(result.regions.first.number, 13);
      expect(result.regions.first.explanationText, isNot(contains('填空题')));
      expect(result.regions.last.number, 14);
      expect(result.regions.last.declaredKind, TextQuestionKind.fillBlank);
      expect(result.diagnostics['ignoredBlockCount'], greaterThanOrEqualTo(1));
    });

    test('splits section heading and question in the same OCR block', () {
      final document = OcrDocument(
        sourceName: 'sample.pdf',
        markdown: '',
        rawResponses: const [],
        usage: const {},
        pages: [
          OcrPage(
            pageIndex: 1,
            blocks: [
              const OcrBlock(
                blockId: 'p001_b0001',
                pageIndex: 1,
                type: 'text',
                text: '## 二、填空题\n14 已知平面区域 D，计算 I。',
                bbox: [],
                readingOrder: 0,
              ),
            ],
          ),
        ],
      );

      final result = const OcrQuestionRegionizer().regionize(document);

      expect(result.regions, hasLength(1));
      expect(result.regions.single.number, 14);
      expect(result.regions.single.declaredKind, TextQuestionKind.fillBlank);
      expect(result.regions.single.stemText, isNot(contains('填空题')));
    });

    test('attaches numbered answer candidates back to matching regions', () {
      final document = OcrDocument(
        sourceName: 'sample.pdf',
        markdown: '',
        rawResponses: const [],
        usage: const {},
        pages: [
          OcrPage(
            pageIndex: 1,
            blocks: [
              const OcrBlock(
                blockId: 'p001_b0001',
                pageIndex: 1,
                type: 'text',
                text: '## 二、填空题\n14 已知平面区域 D，计算 I。',
                bbox: [],
                readingOrder: 0,
              ),
              const OcrBlock(
                blockId: 'p001_b0002',
                pageIndex: 1,
                type: 'text',
                text: '15 已知函数 f，求极值。',
                bbox: [],
                readingOrder: 1,
              ),
              const OcrBlock(
                blockId: 'p001_b0003',
                pageIndex: 1,
                type: 'text',
                text: '14 标准答案：\\(\\frac{1}{2}\\)',
                bbox: [],
                readingOrder: 2,
              ),
            ],
          ),
        ],
      );

      final result = const OcrQuestionRegionizer().regionize(document);

      expect(result.regions, hasLength(2));
      final question14 =
          result.regions.singleWhere((region) => region.number == 14);
      expect(question14.answerText, contains(r'\frac{1}{2}'));
      expect(
        question14.diagnostics,
        contains('attached_numbered_field_candidate'),
      );
    });
  });
}

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

    group('OcrQuestionRegionizer Regression Tests', () {
      test('Positive: Inline question numbers (1., 2., 3.)', () {
        final document = OcrDocument(
          sourceName: 'inline.pdf',
          markdown: '',
          rawResponses: const [],
          usage: const {},
          pages: [
            OcrPage(
              pageIndex: 1,
              blocks: [
                const OcrBlock(
                  blockId: 'b1',
                  pageIndex: 1,
                  type: 'text',
                  text: '1. 某对象满足条件，求值。',
                  bbox: [],
                  readingOrder: 0,
                ),
                const OcrBlock(
                  blockId: 'b2',
                  pageIndex: 1,
                  type: 'text',
                  text: '2．给定对象，判断结论。',
                  bbox: [],
                  readingOrder: 1,
                ),
                const OcrBlock(
                  blockId: 'b3',
                  pageIndex: 1,
                  type: 'text',
                  text: '３、另一对象满足条件。',
                  bbox: [],
                  readingOrder: 2,
                ),
              ],
            ),
          ],
        );

        final result = const OcrQuestionRegionizer().regionize(document);

        // Expect numbers 1, 2, 3 to be recognized.
        // Full-width digit '３' should normalize to integer 3.
        expect(result.regions.map((r) => r.number).toList(),
            containsAll([1, 2, 3]));
      });

      test('Positive: Independent question number block on same page', () {
        final document = OcrDocument(
          sourceName: 'independent.pdf',
          markdown: '',
          rawResponses: const [],
          usage: const {},
          pages: [
            OcrPage(
              pageIndex: 1,
              blocks: [
                const OcrBlock(
                  blockId: 'block_num',
                  pageIndex: 1,
                  type: 'text',
                  text: '4．',
                  bbox: [],
                  readingOrder: 0,
                ),
                const OcrBlock(
                  blockId: 'block_stem',
                  pageIndex: 1,
                  type: 'text',
                  text: '某对象满足条件，计算结果。',
                  bbox: [],
                  readingOrder: 1,
                ),
              ],
            ),
          ],
        );

        final result = const OcrQuestionRegionizer().regionize(document);

        // Expect number 4 to be recognized.
        // The independent 4. and the stem block should belong to the same region.
        final region4 = result.regions.firstWhere((r) => r.number == 4);
        expect(
            region4.sourceBlockIds, containsAll(['block_num', 'block_stem']));
        expect(region4.stemText, contains('某对象满足条件'));
      });

      test('Positive: Section headings with metadata and brackets/colons', () {
        final document = OcrDocument(
          sourceName: 'section.pdf',
          markdown: '',
          rawResponses: const [],
          usage: const {},
          pages: [
            OcrPage(
              pageIndex: 1,
              blocks: [
                const OcrBlock(
                  blockId: 'sec1',
                  pageIndex: 1,
                  type: 'text',
                  text: '## 一、选择题（共 4 题）',
                  bbox: [],
                  readingOrder: 0,
                ),
                const OcrBlock(
                  blockId: 'q1',
                  pageIndex: 1,
                  type: 'text',
                  text: '1. 已知函数 f，求极值。',
                  bbox: [],
                  readingOrder: 1,
                ),
                const OcrBlock(
                  blockId: 'sec2',
                  pageIndex: 1,
                  type: 'text',
                  text: '## 二、填空题：本题共 5 小题',
                  bbox: [],
                  readingOrder: 2,
                ),
                const OcrBlock(
                  blockId: 'q2',
                  pageIndex: 1,
                  type: 'text',
                  text: '2．填空结果是 ____。',
                  bbox: [],
                  readingOrder: 3,
                ),
                const OcrBlock(
                  blockId: 'sec3',
                  pageIndex: 1,
                  type: 'text',
                  text: '## 三、多项选择题',
                  bbox: [],
                  readingOrder: 4,
                ),
                const OcrBlock(
                  blockId: 'q3',
                  pageIndex: 1,
                  type: 'text',
                  text: '3、多选题。',
                  bbox: [],
                  readingOrder: 5,
                ),
              ],
            ),
          ],
        );

        final result = const OcrQuestionRegionizer().regionize(document);

        // Expect questions under these sections to inherit correct declared kinds.
        final q1 = result.regions.firstWhere((r) => r.number == 1);
        final q2 = result.regions.firstWhere((r) => r.number == 2);
        final q3 = result.regions.firstWhere((r) => r.number == 3);

        expect(q1.declaredKind, TextQuestionKind.choice);
        expect(q2.declaredKind, TextQuestionKind.fillBlank);
        expect(q3.declaredKind, TextQuestionKind.choice);
        expect(result.diagnostics['expectedQuestionCount'], isNull);
        expect(result.diagnostics, isNot(contains('sectionHeadings')));
      });

      test('Negative: Non-question text must be rejected', () {
        final document = OcrDocument(
          sourceName: 'negative.pdf',
          markdown: '',
          rawResponses: const [],
          usage: const {},
          pages: [
            OcrPage(
              pageIndex: 1,
              blocks: [
                const OcrBlock(
                  blockId: 'b1',
                  pageIndex: 1,
                  type: 'text',
                  text: '2025. 全国考试',
                  bbox: [],
                  readingOrder: 0,
                ),
                const OcrBlock(
                  blockId: 'b2',
                  pageIndex: 1,
                  type: 'text',
                  text: '3.14',
                  bbox: [],
                  readingOrder: 1,
                ),
                const OcrBlock(
                  blockId: 'b3',
                  pageIndex: 1,
                  type: 'text',
                  text: '100 分',
                  bbox: [],
                  readingOrder: 2,
                ),
                const OcrBlock(
                  blockId: 'b4',
                  pageIndex: 1,
                  type: 'text',
                  text: '第 5 页',
                  bbox: [],
                  readingOrder: 3,
                ),
                const OcrBlock(
                  blockId: 'b5',
                  pageIndex: 1,
                  type: 'text',
                  text: '（1）求函数值',
                  bbox: [],
                  readingOrder: 4,
                ),
                const OcrBlock(
                  blockId: 'b6',
                  pageIndex: 1,
                  type: 'text',
                  text: '（2）证明结论',
                  bbox: [],
                  readingOrder: 5,
                ),
                const OcrBlock(
                  blockId: 'b7',
                  pageIndex: 1,
                  type: 'text',
                  text: '一、这是普通段落，不是题型标题',
                  bbox: [],
                  readingOrder: 6,
                ),
              ],
            ),
          ],
        );

        final result = const OcrQuestionRegionizer().regionize(document);

        // None of these should be recognized as a valid region number
        final numbers = result.regions.map((r) => r.number).toList();
        expect(numbers, isNot(contains(2025)));
        expect(numbers, isNot(contains(3)));
        expect(numbers, isNot(contains(100)));
        expect(numbers, isNot(contains(5)));
        expect(numbers, isNot(contains(1)));
        expect(numbers, isNot(contains(2)));

        // Ensure no choosing section kind was declared from the fake header
        expect(result.diagnostics['sectionHeadingCount'] ?? 0, 0);
      });

      test(
          'Negative: Independent question block must not cross page to connect next page stem',
          () {
        final document = OcrDocument(
          sourceName: 'crosspage_neg.pdf',
          markdown: '',
          rawResponses: const [],
          usage: const {},
          pages: [
            OcrPage(
              pageIndex: 1,
              blocks: [
                const OcrBlock(
                  blockId: 'p1_num',
                  pageIndex: 1,
                  type: 'text',
                  text: '5．',
                  bbox: [],
                  readingOrder: 0,
                ),
              ],
            ),
            OcrPage(
              pageIndex: 2,
              blocks: [
                const OcrBlock(
                  blockId: 'p2_stem',
                  pageIndex: 2,
                  type: 'text',
                  text: '设 x > 0，已知函数满足性质。',
                  bbox: [],
                  readingOrder: 0,
                ),
              ],
            ),
          ],
        );

        final result = const OcrQuestionRegionizer().regionize(document);

        // They must NOT be combined into a single region spanning [1, 2]
        final region5 = result.regions.where((r) => r.number == 5);
        if (region5.isNotEmpty) {
          expect(region5.first.sourceBlockIds, isNot(contains('p2_stem')));
        }
      });

      test('accepts structured section instructions longer than 40 characters',
          () {
        const suffix = '（本题共8小题，每小题4分，共32分。在每小题给出的四个选项中，只有一项符合要求。）';
        expect(suffix.length, greaterThan(40));
        final document = OcrDocument(
          sourceName: 'long-section.pdf',
          markdown: '',
          rawResponses: const [],
          usage: const {},
          pages: [
            OcrPage(
              pageIndex: 1,
              blocks: [
                const OcrBlock(
                  blockId: 'long_section',
                  pageIndex: 1,
                  type: 'text',
                  text: '## 一、选择题$suffix',
                  bbox: [],
                  readingOrder: 0,
                ),
                const OcrBlock(
                  blockId: 'question_1',
                  pageIndex: 1,
                  type: 'text',
                  text: '（1）某对象满足条件。',
                  bbox: [],
                  readingOrder: 1,
                ),
              ],
            ),
          ],
        );

        final result = const OcrQuestionRegionizer().regionize(document);

        expect(result.diagnostics['sectionHeadingCount'], 1);
        expect(result.regions, hasLength(1));
        expect(result.regions.single.number, 1);
        expect(result.regions.single.declaredKind, TextQuestionKind.choice);
      });

      test('accepts sequenced parenthesized Arabic top-level markers', () {
        final document = OcrDocument(
          sourceName: 'parenthesized.pdf',
          markdown: '',
          rawResponses: const [],
          usage: const {},
          pages: [
            OcrPage(
              pageIndex: 1,
              blocks: [
                const OcrBlock(
                  blockId: 'section',
                  pageIndex: 1,
                  type: 'text',
                  text: '一、选择题',
                  bbox: [],
                  readingOrder: 0,
                ),
                const OcrBlock(
                  blockId: 'q1',
                  pageIndex: 1,
                  type: 'text',
                  text: '（1）某对象满足条件。',
                  bbox: [],
                  readingOrder: 1,
                ),
                const OcrBlock(
                  blockId: 'q2',
                  pageIndex: 1,
                  type: 'text',
                  text: '(2) 给定对象，判断结论。',
                  bbox: [],
                  readingOrder: 2,
                ),
                const OcrBlock(
                  blockId: 'q3',
                  pageIndex: 1,
                  type: 'text',
                  text: '（３）另一对象满足条件。',
                  bbox: [],
                  readingOrder: 3,
                ),
              ],
            ),
          ],
        );

        final result = const OcrQuestionRegionizer().regionize(document);

        expect(result.regions.map((region) => region.number), [1, 2, 3]);
        expect(result.diagnostics['acceptedNumbers'], [1, 2, 3]);
        expect(result.diagnostics['parenthesizedArabicCandidateCount'], 3);
        expect(result.diagnostics['parenthesizedArabicAcceptedCount'], 3);
        expect(result.diagnostics['parenthesizedArabicRejectedCount'], 0);
        expect(result.diagnostics['sequenceAcceptedCount'], 3);
        expect(result.diagnostics['sequenceRejectedCount'], 0);
      });

      test('keeps parenthesized numbering continuous across sections', () {
        final blocks = <OcrBlock>[];
        var order = 0;

        void addBlock(String id, String text) {
          blocks.add(
            OcrBlock(
              blockId: id,
              pageIndex: 1,
              type: 'text',
              text: text,
              bbox: const [],
              readingOrder: order++,
            ),
          );
        }

        addBlock('choice', '一、选择题');
        addBlock('q1', '（1）第一道占位题干。');
        addBlock('q2', '（2）第二道占位题干。');
        addBlock('fill', '二、填空题');
        addBlock('q3', '（3）第三道占位题干。');
        addBlock('q4', '（4）第四道占位题干。');
        addBlock('subjective', '三、解答题');
        addBlock('q5', '（5）第五道占位题干。');
        addBlock('q6', '（6）第六道占位题干。');

        final result = const OcrQuestionRegionizer().regionize(
          OcrDocument(
            sourceName: 'cross-section.pdf',
            markdown: '',
            rawResponses: const [],
            usage: const {},
            pages: [OcrPage(pageIndex: 1, blocks: blocks)],
          ),
        );

        expect(
            result.regions.map((region) => region.number), [1, 2, 3, 4, 5, 6]);
        expect(result.regions[0].declaredKind, TextQuestionKind.choice);
        expect(result.regions[1].declaredKind, TextQuestionKind.choice);
        expect(result.regions[2].declaredKind, TextQuestionKind.fillBlank);
        expect(result.regions[3].declaredKind, TextQuestionKind.fillBlank);
        expect(result.regions[4].declaredKind, TextQuestionKind.subjective);
        expect(result.regions[5].declaredKind, TextQuestionKind.subjective);
        expect(result.diagnostics['sectionHeadingCount'], 3);
      });

      test('keeps Roman subquestions inside their parent region', () {
        final document = OcrDocument(
          sourceName: 'roman-subquestions.pdf',
          markdown: '',
          rawResponses: const [],
          usage: const {},
          pages: [
            OcrPage(
              pageIndex: 1,
              blocks: [
                const OcrBlock(
                  blockId: 'section',
                  pageIndex: 1,
                  type: 'text',
                  text: '三、解答题',
                  bbox: [],
                  readingOrder: 0,
                ),
                const OcrBlock(
                  blockId: 'q15',
                  pageIndex: 1,
                  type: 'text',
                  text: '（15）（本题满分10分）',
                  bbox: [],
                  readingOrder: 1,
                ),
                const OcrBlock(
                  blockId: 'q15_stem',
                  pageIndex: 1,
                  type: 'text',
                  text: '设某对象满足条件。',
                  bbox: [],
                  readingOrder: 2,
                ),
                const OcrBlock(
                  blockId: 'q15_roman_1',
                  pageIndex: 1,
                  type: 'text',
                  text: '（Ⅰ）求第一部分；',
                  bbox: [],
                  readingOrder: 3,
                ),
                const OcrBlock(
                  blockId: 'q15_roman_2',
                  pageIndex: 1,
                  type: 'text',
                  text: '（Ⅱ）证明第二部分。',
                  bbox: [],
                  readingOrder: 4,
                ),
                const OcrBlock(
                  blockId: 'q16',
                  pageIndex: 1,
                  type: 'text',
                  text: '（16）（本题满分10分）',
                  bbox: [],
                  readingOrder: 5,
                ),
                const OcrBlock(
                  blockId: 'q16_stem',
                  pageIndex: 1,
                  type: 'text',
                  text: '给定另一对象。',
                  bbox: [],
                  readingOrder: 6,
                ),
              ],
            ),
          ],
        );

        final result = const OcrQuestionRegionizer().regionize(document);

        expect(result.regions.map((region) => region.number), [15, 16]);
        final question15 = result.regions.first;
        expect(question15.stemText, contains('（Ⅰ）'));
        expect(question15.stemText, contains('（Ⅱ）'));
        expect(
          question15.sourceBlockIds,
          containsAll(['q15', 'q15_stem', 'q15_roman_1', 'q15_roman_2']),
        );
        expect(result.diagnostics['romanSubquestionCount'], 2);
      });

      test('rejects restarted Arabic subquestions inside a later question', () {
        final document = OcrDocument(
          sourceName: 'arabic-subquestions.pdf',
          markdown: '',
          rawResponses: const [],
          usage: const {},
          pages: [
            OcrPage(
              pageIndex: 1,
              blocks: [
                const OcrBlock(
                  blockId: 'section',
                  pageIndex: 1,
                  type: 'text',
                  text: '三、解答题',
                  bbox: [],
                  readingOrder: 0,
                ),
                const OcrBlock(
                  blockId: 'q15',
                  pageIndex: 1,
                  type: 'text',
                  text: '（15）某对象满足条件。',
                  bbox: [],
                  readingOrder: 1,
                ),
                const OcrBlock(
                  blockId: 'q15_sub_1',
                  pageIndex: 1,
                  type: 'text',
                  text: '（1）求第一部分。',
                  bbox: [],
                  readingOrder: 2,
                ),
                const OcrBlock(
                  blockId: 'q15_sub_2',
                  pageIndex: 1,
                  type: 'text',
                  text: '（2）证明第二部分。',
                  bbox: [],
                  readingOrder: 3,
                ),
                const OcrBlock(
                  blockId: 'q16',
                  pageIndex: 1,
                  type: 'text',
                  text: '（16）另一道顶层题。',
                  bbox: [],
                  readingOrder: 4,
                ),
              ],
            ),
          ],
        );

        final result = const OcrQuestionRegionizer().regionize(document);

        expect(result.regions.map((region) => region.number), [15, 16]);
        expect(result.regions.first.stemText, contains('（1）'));
        expect(result.regions.first.stemText, contains('（2）'));
        expect(result.diagnostics['parenthesizedArabicCandidateCount'], 4);
        expect(result.diagnostics['parenthesizedArabicAcceptedCount'], 2);
        expect(result.diagnostics['parenthesizedArabicRejectedCount'], 2);
        expect(result.diagnostics['sequenceAcceptedCount'], 2);
        expect(result.diagnostics['sequenceRejectedCount'], 2);
      });

      test('accepts safe line-leading Markdown prefixes for question markers',
          () {
        final document = OcrDocument(
          sourceName: 'markdown-markers.pdf',
          markdown: '',
          rawResponses: const [],
          usage: const {},
          pages: [
            OcrPage(
              pageIndex: 1,
              blocks: const [
                OcrBlock(
                  blockId: 'section',
                  pageIndex: 1,
                  type: 'text',
                  text: '三、解答题',
                  bbox: [],
                  readingOrder: 0,
                ),
                OcrBlock(
                  blockId: 'q15',
                  pageIndex: 1,
                  type: 'text',
                  text: '（15）前置脱敏题干。',
                  bbox: [],
                  readingOrder: 1,
                ),
                OcrBlock(
                  blockId: 'q16',
                  pageIndex: 1,
                  type: 'text',
                  text: '## （16）某对象满足 # 条件，符号 > 应保留。',
                  bbox: [],
                  readingOrder: 2,
                ),
                OcrBlock(
                  blockId: 'q17',
                  pageIndex: 1,
                  type: 'text',
                  text: '### (17) 给定对象。',
                  bbox: [],
                  readingOrder: 3,
                ),
                OcrBlock(
                  blockId: 'q18',
                  pageIndex: 1,
                  type: 'text',
                  text: '> （18）另一对象。',
                  bbox: [],
                  readingOrder: 4,
                ),
              ],
            ),
          ],
        );

        final result = const OcrQuestionRegionizer().regionize(document);

        expect(result.regions.map((region) => region.number), [15, 16, 17, 18]);
        expect(result.regions[1].stemText, contains('# 条件'));
        expect(result.regions[1].stemText, contains('符号 >'));
        expect(result.diagnostics['markdownPrefixedCandidateCount'], 3);
        expect(result.diagnostics['blockStartCandidateCount'], 4);
        expect(result.diagnostics['internalLineCandidateCount'], 0);
      });

      test('splits multiple Markdown-prefixed questions inside one OCR block',
          () {
        final document = OcrDocument(
          sourceName: 'multi-question-block.pdf',
          markdown: '',
          rawResponses: const [],
          usage: const {},
          pages: [
            OcrPage(
              pageIndex: 1,
              blocks: const [
                OcrBlock(
                  blockId: 'section',
                  pageIndex: 1,
                  type: 'text',
                  text: '三、解答题',
                  bbox: [],
                  readingOrder: 0,
                ),
                OcrBlock(
                  blockId: 'q15',
                  pageIndex: 1,
                  type: 'text',
                  text: '（15）前置脱敏题干。',
                  bbox: [],
                  readingOrder: 1,
                ),
                OcrBlock(
                  blockId: 'combined',
                  pageIndex: 1,
                  type: 'text',
                  text: '普通正文或空白\n'
                      '## （16）第一道脱敏题干\n'
                      '若干正文\n'
                      '## （17）第二道脱敏题干',
                  bbox: [],
                  readingOrder: 2,
                ),
              ],
            ),
          ],
        );

        final result = const OcrQuestionRegionizer().regionize(document);

        expect(result.regions.map((region) => region.number), [15, 16, 17]);
        expect(
            result.regions
                .singleWhere((region) => region.number == 16)
                .stemText,
            contains('若干正文'));
        expect(result.diagnostics['internalLineCandidateCount'], 2);
        expect(result.diagnostics['markdownPrefixedCandidateCount'], 2);
      });

      test('keeps Markdown-prefixed numbering continuous across four pages',
          () {
        OcrBlock questionBlock(int page, int number, int order) {
          final marker = switch (number % 3) {
            0 => '> （$number）',
            1 => '## （$number）',
            _ => '### ($number)',
          };
          return OcrBlock(
            blockId: 'p${page}_q$number',
            pageIndex: page,
            type: 'text',
            text: number >= 16
                ? '$marker 第$number道脱敏题干。'
                : '（$number）第$number道脱敏题干。',
            bbox: const [],
            readingOrder: order,
          );
        }

        final pages = <OcrPage>[];
        for (final range in <(int, int, int)>[
          (1, 1, 8),
          (2, 9, 16),
          (3, 17, 20),
          (4, 21, 23),
        ]) {
          final blocks = <OcrBlock>[];
          var order = 0;
          if (range.$1 == 1) {
            blocks.add(OcrBlock(
              blockId: 'choice_section',
              pageIndex: range.$1,
              type: 'text',
              text: '一、选择题（共8题）',
              bbox: const [],
              readingOrder: order++,
            ));
          } else if (range.$1 == 2) {
            blocks.add(OcrBlock(
              blockId: 'fill_section',
              pageIndex: range.$1,
              type: 'text',
              text: '二、填空题（共6题）',
              bbox: const [],
              readingOrder: order++,
            ));
          } else if (range.$1 == 3) {
            blocks.add(OcrBlock(
              blockId: 'subjective_section',
              pageIndex: range.$1,
              type: 'text',
              text: '三、解答题（共9题）',
              bbox: const [],
              readingOrder: order++,
            ));
          }
          for (var number = range.$2; number <= range.$3; number++) {
            blocks.add(questionBlock(range.$1, number, order++));
          }
          pages.add(OcrPage(pageIndex: range.$1, blocks: blocks));
        }

        final result = const OcrQuestionRegionizer().regionize(
          OcrDocument(
            sourceName: 'four-pages.pdf',
            markdown: '',
            rawResponses: const [],
            usage: const {},
            pages: pages,
          ),
        );

        expect(
          result.diagnostics['acceptedNumbers'],
          List<int>.generate(23, (index) => index + 1),
        );
        expect(result.diagnostics['regionCount'], 23);
        expect(result.diagnostics['pageCandidateCounts'], {
          '1': 8,
          '2': 8,
          '3': 4,
          '4': 3,
        });
        expect(result.diagnostics['markdownPrefixedCandidateCount'], 8);
        expect(result.diagnostics['blockStartCandidateCount'], 23);
        expect(result.diagnostics['internalLineCandidateCount'], 0);
        expect(result.diagnostics['expectedQuestionCount'], 23);
        expect(result.diagnostics['tailMissingNumbers'], isEmpty);
        expect(result.diagnostics['missingQuestionCount'], 0);
        expect(result.regions.last.number, 23);
        expect(result.regions.last.sourcePageIndices, [4]);
      });

      test('reports trusted section-derived trailing missing question numbers',
          () {
        final blocks = <OcrBlock>[];
        var order = 0;

        void add(String id, String text) {
          blocks.add(OcrBlock(
            blockId: id,
            pageIndex: 1,
            type: 'text',
            text: text,
            bbox: const [],
            readingOrder: order++,
          ));
        }

        add(
          'choice_section',
          '一、选择题（本题共8小题，每小题4分，共32分）',
        );
        for (var number = 1; number <= 8; number++) {
          add('q$number', '（$number）第$number道选择脱敏题干。');
        }
        add('fill_section', '二、填空题（本题共6小题，每小题4分，共24分）');
        for (var number = 9; number <= 14; number++) {
          add('q$number', '（$number）第$number道填空脱敏题干。');
        }
        add('subjective_section', '三、解答题（本题共9小题，共94分）');
        add('q15', '（15）第15道解答脱敏题干。');

        final result = const OcrQuestionRegionizer().regionize(
          OcrDocument(
            sourceName: 'tail-missing.pdf',
            markdown: '',
            rawResponses: const [],
            usage: const {},
            pages: [OcrPage(pageIndex: 1, blocks: blocks)],
          ),
        );

        expect(result.regions, hasLength(15));
        expect(result.diagnostics['expectedQuestionCount'], 23);
        expect(result.diagnostics['acceptedQuestionCount'], 15);
        expect(
          result.diagnostics['tailMissingNumbers'],
          List<int>.generate(8, (index) => index + 16),
        );
        expect(result.diagnostics['missingQuestionCount'], 8);
        expect(result.diagnostics['sections'], [
          {
            'sectionIndex': 1,
            'kind': 'choice',
            'expectedSectionQuestionCount': 8,
          },
          {
            'sectionIndex': 2,
            'kind': 'fillBlank',
            'expectedSectionQuestionCount': 6,
          },
          {
            'sectionIndex': 3,
            'kind': 'subjective',
            'expectedSectionQuestionCount': 9,
          },
        ]);
      });

      test('does not promote Markdown lookalikes to top-level questions', () {
        final document = OcrDocument(
          sourceName: 'markdown-negative.pdf',
          markdown: '',
          rawResponses: const [],
          usage: const {},
          pages: [
            OcrPage(
              pageIndex: 1,
              blocks: const [
                OcrBlock(
                  blockId: 'section',
                  pageIndex: 1,
                  type: 'text',
                  text: '一、选择题',
                  bbox: [],
                  readingOrder: 0,
                ),
                OcrBlock(
                  blockId: 'q1',
                  pageIndex: 1,
                  type: 'text',
                  text: '（1）第一道脱敏题干。',
                  bbox: [],
                  readingOrder: 1,
                ),
                OcrBlock(
                  blockId: 'year',
                  pageIndex: 1,
                  type: 'text',
                  text: '## 2025. 全国考试',
                  bbox: [],
                  readingOrder: 2,
                ),
                OcrBlock(
                  blockId: 'decimal',
                  pageIndex: 1,
                  type: 'text',
                  text: '> 3.14',
                  bbox: [],
                  readingOrder: 3,
                ),
                OcrBlock(
                  blockId: 'page',
                  pageIndex: 1,
                  type: 'text',
                  text: '## 第 5 页',
                  bbox: [],
                  readingOrder: 4,
                ),
                OcrBlock(
                  blockId: 'embedded',
                  pageIndex: 1,
                  type: 'text',
                  text: '> 正文中的数学编号（2）不在行首。',
                  bbox: [],
                  readingOrder: 5,
                ),
                OcrBlock(
                  blockId: 'roman',
                  pageIndex: 1,
                  type: 'text',
                  text: '> （Ⅰ）罗马数字小问。',
                  bbox: [],
                  readingOrder: 6,
                ),
                OcrBlock(
                  blockId: 'option_a',
                  pageIndex: 1,
                  type: 'text',
                  text: '> (A) 选项甲。',
                  bbox: [],
                  readingOrder: 7,
                ),
                OcrBlock(
                  blockId: 'option_b',
                  pageIndex: 1,
                  type: 'text',
                  text: '> (B) 选项乙。',
                  bbox: [],
                  readingOrder: 8,
                ),
                OcrBlock(
                  blockId: 'list',
                  pageIndex: 1,
                  type: 'text',
                  text: '- （2）普通项目列表。',
                  bbox: [],
                  readingOrder: 9,
                ),
                OcrBlock(
                  blockId: 'q2',
                  pageIndex: 1,
                  type: 'text',
                  text: '## （2）第二道脱敏题干。',
                  bbox: [],
                  readingOrder: 10,
                ),
              ],
            ),
          ],
        );

        final result = const OcrQuestionRegionizer().regionize(document);

        expect(result.regions.map((region) => region.number), [1, 2]);
        expect(result.diagnostics['parenthesizedArabicCandidateCount'], 2);
        expect(result.diagnostics['markdownPrefixedCandidateCount'], 1);
      });
    });

    group('Unified top-level sequence rules', () {
      test(
          'rejects every out-of-sequence marker without polluting the sequence',
          () {
        final blocks = <OcrBlock>[];
        var order = 0;

        void add(String id, String text) {
          blocks.add(
            OcrBlock(
              blockId: id,
              pageIndex: 1,
              type: 'text',
              text: text,
              bbox: const [],
              readingOrder: order++,
            ),
          );
        }

        add('section', '一、选择题');
        for (var number = 1; number <= 8; number++) {
          add('q$number', '$number. 第$number道脱敏题干。');
        }
        add('reference_heading', '1. 扩展条目。');
        for (var number = 1; number <= 5; number++) {
          add('reference_item_$number', '（$number）参考条目。');
        }
        add('reference_table', '2. 参考表格。');
        add('bare_reference', '1 设参考对象。');
        add('plain_reference', '2');
        add('plain_reference_text', '设参考对象。');
        add('q9', '9. 第九道脱敏题干。');

        final result = const OcrQuestionRegionizer().regionize(
          OcrDocument(
            sourceName: 'sequence-pollution.pdf',
            markdown: '',
            rawResponses: const [],
            usage: const {},
            pages: [OcrPage(pageIndex: 1, blocks: blocks)],
          ),
        );

        expect(
          result.diagnostics['acceptedNumbers'],
          List<int>.generate(9, (index) => index + 1),
        );
        expect(result.diagnostics['regionCount'], 9);
        expect(result.diagnostics['sequenceAcceptedCount'], 9);
        expect(result.diagnostics['sequenceRejectedCount'], 9);

        final trace = result.diagnostics['questionCandidateTrace'] as List;
        final rejectedReferenceEntries = trace.where(
          (entry) =>
              entry['blockOrder'] >= 9 &&
              entry['blockOrder'] <= 17 &&
              entry['decision'] == 'rejected',
        );
        expect(rejectedReferenceEntries, hasLength(9));
        for (final entry in rejectedReferenceEntries) {
          expect(entry['reason'], 'sequence_mismatch');
          expect(entry['previousAcceptedNumber'], 8);
        }
        expect(
          rejectedReferenceEntries.map((entry) => entry['markerKind']).toSet(),
          containsAll(<String>{
            'parenthesized_arabic',
            'punctuated_integer',
            'explicit_question',
            'plain_integer',
          }),
        );

        final q9Trace = trace.singleWhere(
          (entry) => entry['blockOrder'] == 19,
        );
        expect(q9Trace['decision'], 'accepted');
        expect(q9Trace['previousAcceptedNumber'], 8);
      });

      test('accepts a formula-leading marker when it continues the sequence',
          () {
        final document = OcrDocument(
          sourceName: 'formula-leading.pdf',
          markdown: '',
          rawResponses: const [],
          usage: const {},
          pages: [
            OcrPage(
              pageIndex: 1,
              blocks: const [
                OcrBlock(
                  blockId: 'section',
                  pageIndex: 1,
                  type: 'text',
                  text: '二、填空题',
                  bbox: [],
                  readingOrder: 0,
                ),
                OcrBlock(
                  blockId: 'q11',
                  pageIndex: 1,
                  type: 'text',
                  text: '11. 第十一道脱敏题干。',
                  bbox: [],
                  readingOrder: 1,
                ),
                OcrBlock(
                  blockId: 'q12',
                  pageIndex: 1,
                  type: 'text',
                  text: r'12 $x^2+1=0$',
                  bbox: [],
                  readingOrder: 2,
                ),
                OcrBlock(
                  blockId: 'q13',
                  pageIndex: 1,
                  type: 'text',
                  text: r'13 $\int_0^1 x\,dx$',
                  bbox: [],
                  readingOrder: 3,
                ),
                OcrBlock(
                  blockId: 'q14',
                  pageIndex: 1,
                  type: 'text',
                  text: '14. 第十四道脱敏题干。',
                  bbox: [],
                  readingOrder: 4,
                ),
              ],
            ),
          ],
        );

        final result = const OcrQuestionRegionizer().regionize(document);

        expect(result.diagnostics['acceptedNumbers'], [11, 12, 13, 14]);
        final trace = result.diagnostics['questionCandidateTrace'] as List;
        for (final number in [12, 13]) {
          final entry = trace.singleWhere((item) => item['number'] == number);
          expect(entry['decision'], 'accepted');
          expect(entry['reason'], 'valid_question_start');
        }
      });

      test('rejects candidates after the official section sequence restarts',
          () {
        final document = OcrDocument(
          sourceName: 'restarted-sections.pdf',
          markdown: '',
          rawResponses: const [],
          usage: const {},
          pages: [
            OcrPage(
              pageIndex: 1,
              blocks: const [
                OcrBlock(
                  blockId: 'choice',
                  pageIndex: 1,
                  type: 'text',
                  text: '一、选择题',
                  bbox: [],
                  readingOrder: 0,
                ),
                OcrBlock(
                  blockId: 'q1',
                  pageIndex: 1,
                  type: 'text',
                  text: '1. 第一道脱敏题干。',
                  bbox: [],
                  readingOrder: 1,
                ),
                OcrBlock(
                  blockId: 'fill',
                  pageIndex: 1,
                  type: 'text',
                  text: '二、填空题',
                  bbox: [],
                  readingOrder: 2,
                ),
                OcrBlock(
                  blockId: 'q2',
                  pageIndex: 1,
                  type: 'text',
                  text: '2. 第二道脱敏题干。',
                  bbox: [],
                  readingOrder: 3,
                ),
                OcrBlock(
                  blockId: 'subjective',
                  pageIndex: 1,
                  type: 'text',
                  text: '三、解答题',
                  bbox: [],
                  readingOrder: 4,
                ),
                OcrBlock(
                  blockId: 'q3',
                  pageIndex: 1,
                  type: 'text',
                  text: '3. 第三道脱敏题干。',
                  bbox: [],
                  readingOrder: 5,
                ),
                OcrBlock(
                  blockId: 'restarted_choice',
                  pageIndex: 1,
                  type: 'text',
                  text: '一、选择题',
                  bbox: [],
                  readingOrder: 6,
                ),
                OcrBlock(
                  blockId: 'reference_q4',
                  pageIndex: 1,
                  type: 'text',
                  text: '（4）参考条目。',
                  bbox: [],
                  readingOrder: 7,
                ),
              ],
            ),
          ],
        );

        final result = const OcrQuestionRegionizer().regionize(document);

        expect(result.diagnostics['acceptedNumbers'], [1, 2, 3]);
        expect(result.diagnostics['referenceSectionDetected'], isTrue);
        final trace = result.diagnostics['questionCandidateTrace'] as List;
        final referenceEntry = trace.singleWhere(
          (entry) => entry['number'] == 4,
        );
        expect(referenceEntry['decision'], 'rejected');
        expect(referenceEntry['reason'], 'reference_section');
        expect(referenceEntry['previousAcceptedNumber'], 3);
      });

      test('rejects an otherwise continuous marker after an answer summary',
          () {
        final document = OcrDocument(
          sourceName: 'answer-summary.pdf',
          markdown: '',
          rawResponses: const [],
          usage: const {},
          pages: [
            OcrPage(
              pageIndex: 1,
              blocks: const [
                OcrBlock(
                  blockId: 'section',
                  pageIndex: 1,
                  type: 'text',
                  text: '一、选择题',
                  bbox: [],
                  readingOrder: 0,
                ),
                OcrBlock(
                  blockId: 'q1',
                  pageIndex: 1,
                  type: 'text',
                  text: '1. 第一道脱敏题干。',
                  bbox: [],
                  readingOrder: 1,
                ),
                OcrBlock(
                  blockId: 'summary',
                  pageIndex: 1,
                  type: 'text',
                  text: '模拟试卷答案速查',
                  bbox: [],
                  readingOrder: 2,
                ),
                OcrBlock(
                  blockId: 'reference_q2',
                  pageIndex: 1,
                  type: 'text',
                  text: '2. 参考条目。',
                  bbox: [],
                  readingOrder: 3,
                ),
              ],
            ),
          ],
        );

        final result = const OcrQuestionRegionizer().regionize(document);

        expect(result.diagnostics['acceptedNumbers'], [1]);
        expect(result.diagnostics['referenceSectionDetected'], isTrue);
        final trace = result.diagnostics['questionCandidateTrace'] as List;
        final referenceEntry = trace.singleWhere(
          (entry) => entry['number'] == 2,
        );
        expect(referenceEntry['decision'], 'rejected');
        expect(referenceEntry['reason'], 'reference_section');
        expect(referenceEntry['previousAcceptedNumber'], 1);
      });
    });

    group('Candidate Trace Tests', () {
      test(
          'records trace for normal, parenthesized, rejected option, sequence mismatch, sectionIndex',
          () {
        final document = OcrDocument(
          sourceName: 'trace_test.pdf',
          markdown: '',
          rawResponses: const [],
          usage: const {},
          pages: [
            OcrPage(
              pageIndex: 1,
              blocks: [
                const OcrBlock(
                  blockId: 'b0',
                  pageIndex: 1,
                  type: 'text',
                  text: '一、选择题',
                  bbox: [],
                  readingOrder: 0,
                ),
                const OcrBlock(
                  blockId: 'b1',
                  pageIndex: 1,
                  type: 'text',
                  text: '（1）第一题。',
                  bbox: [],
                  readingOrder: 1,
                ),
                const OcrBlock(
                  blockId: 'b2',
                  pageIndex: 1,
                  type: 'text',
                  text: 'A. 选项。',
                  bbox: [],
                  readingOrder: 2,
                ),
                const OcrBlock(
                  blockId: 'b3',
                  pageIndex: 1,
                  type: 'text',
                  text: '2',
                  bbox: [],
                  readingOrder: 3,
                ),
                const OcrBlock(
                  blockId: 'b3_stem',
                  pageIndex: 1,
                  type: 'text',
                  text: '设函数连续。',
                  bbox: [],
                  readingOrder: 4,
                ),
                const OcrBlock(
                  blockId: 'b4',
                  pageIndex: 1,
                  type: 'text',
                  text: '（3）第三题。',
                  bbox: [],
                  readingOrder: 5,
                ),
                const OcrBlock(
                  blockId: 'b5',
                  pageIndex: 1,
                  type: 'text',
                  text: '（5）不连续。',
                  bbox: [],
                  readingOrder: 6,
                ),
                const OcrBlock(
                  blockId: 'b6',
                  pageIndex: 1,
                  type: 'text',
                  text: '2025. 范围错误。',
                  bbox: [],
                  readingOrder: 7,
                ),
                const OcrBlock(
                  blockId: 'b7',
                  pageIndex: 1,
                  type: 'text',
                  text: '二、填空题',
                  bbox: [],
                  readingOrder: 8,
                ),
                const OcrBlock(
                  blockId: 'b8',
                  pageIndex: 1,
                  type: 'text',
                  text: '（4）第四题。',
                  bbox: [],
                  readingOrder: 9,
                ),
              ],
            ),
          ],
        );

        final result = const OcrQuestionRegionizer().regionize(document);
        final trace = result.diagnostics['questionCandidateTrace'] as List;

        expect(trace, isNotNull);
        expect(trace, isNotEmpty);

        // 1. 接受的普通数字题号记录完整轨迹
        final t3 = trace
            .firstWhere((t) => t['number'] == 2 && t['decision'] == 'accepted');
        expect(t3['markerKind'], 'plain_integer');
        expect(t3['reason'], 'valid_question_start');
        expect(t3['pageIndex'], 1);
        expect(t3['sectionIndex'], 1);
        expect(t3['previousAcceptedNumber'], 1);

        // 2. 接受的括号阿拉伯数字记录 marker kind
        final t1 = trace.firstWhere((t) =>
            t['number'] == 1 &&
            t['decision'] == 'accepted' &&
            t['sectionIndex'] == 1);
        expect(t1['markerKind'], 'parenthesized_arabic');
        expect(t1['reason'], 'valid_question_start');

        // 3. 连续性拒绝记录前一个接受题号
        final t5 = trace
            .firstWhere((t) => t['number'] == 5 && t['decision'] == 'rejected');
        expect(t5['markerKind'], 'parenthesized_arabic');
        expect(t5['reason'], 'sequence_mismatch');
        expect(t5['previousAcceptedNumber'], 3);

        // 4. 选项型候选记录固定拒绝原因
        final t2 = trace.firstWhere((t) =>
            t['decision'] == 'rejected' && t['reason'] == 'looks_like_option');
        expect(t2['number'], 1);

        // 5. 多章节情况下 sectionIndex 正确变化
        final t8 = trace.firstWhere((t) =>
            t['number'] == 4 &&
            t['decision'] == 'accepted' &&
            t['sectionIndex'] == 2);
        expect(t1['sectionIndex'], 1);
        expect(t8['sectionIndex'], 2);

        // 6. 核心要素不泄露（不含题干正文、答案或OCR原文）
        for (final entry in trace) {
          final keys = (entry as Map).keys;
          expect(keys, isNot(contains('text')));
          expect(keys, isNot(contains('stem')));
          expect(keys, isNot(contains('raw')));
          expect(keys, isNot(contains('content')));
          expect(keys, isNot(contains('answer')));
        }
      });

      test('truncates candidate trace when limit is exceeded', () {
        final blocks = <OcrBlock>[];
        for (var i = 1; i <= 105; i++) {
          blocks.add(OcrBlock(
            blockId: 'b$i',
            pageIndex: 1,
            type: 'text',
            text: '$i. 题干描述。',
            bbox: const [],
            readingOrder: i,
          ));
        }
        final document = OcrDocument(
          sourceName: 'trunc_test.pdf',
          markdown: '',
          rawResponses: const [],
          usage: const {},
          pages: [OcrPage(pageIndex: 1, blocks: blocks)],
        );

        final result = const OcrQuestionRegionizer().regionize(document);
        final trace = result.diagnostics['questionCandidateTrace'] as List;

        expect(trace.length, 100);
        expect(result.diagnostics['questionCandidateTraceTruncated'], isTrue);
      });
    });
  });
}

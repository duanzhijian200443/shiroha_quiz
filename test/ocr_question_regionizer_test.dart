import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_question_assembler.dart';
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
      expect(
        region.ownedSources.map((source) => source.blockId),
        ['p001_b0001', 'p002_b0001', 'p002_b0002'],
      );
      expect(
        region.ownedSources.map((source) => source.field),
        [
          OcrRegionField.stem,
          OcrRegionField.answer,
          OcrRegionField.explanation,
        ],
      );
      expect(result.diagnostics['regionCount'], 1);
    });

    test(
        'splits inline explanation ownership before following structural blocks',
        () {
      const questionText = '1. Valid stem (A) one (B) two (C) three (D) four '
          '答案：A。解析：Synthetic explanation';
      final document = OcrDocument(
        sourceName: 'inline-structural.pdf',
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
                text: '一、选择题（共 1 题）',
                bbox: [],
                readingOrder: 0,
              ),
              OcrBlock(
                blockId: 'question',
                pageIndex: 1,
                type: 'text',
                text: questionText,
                bbox: [],
                readingOrder: 1,
              ),
              OcrBlock(
                blockId: 'image',
                pageIndex: 1,
                type: 'image',
                text: 'data:image/png;base64,synthetic',
                bbox: [],
                readingOrder: 2,
              ),
              OcrBlock(
                blockId: 'table',
                pageIndex: 1,
                type: 'table',
                text: '<table><tr><td>A</td><td>B</td></tr></table>',
                bbox: [],
                readingOrder: 3,
              ),
            ],
          ),
        ],
      );

      final region =
          const OcrQuestionRegionizer().regionize(document).regions.single;

      expect(region.stemText, isNot(contains('解析')));
      expect(region.explanationText, contains('Synthetic explanation'));
      expect(region.explanationText, contains('[图片]'));
      expect(
        region.ownedSources.map((source) => source.blockId),
        ['question', 'question', 'image', 'table'],
      );
      expect(
        region.ownedSources.map((source) => source.field),
        [
          OcrRegionField.stem,
          OcrRegionField.explanation,
          OcrRegionField.explanation,
          OcrRegionField.explanation,
        ],
      );
      final explanationSource = region.ownedSources[1];
      expect(
        explanationSource.startCodeUnitOffset,
        questionText.indexOf('Synthetic explanation'),
      );
      expect(explanationSource.endCodeUnitOffset, questionText.length);
    });

    test('markdown explanation heading owns following table and image blocks',
        () {
      final document = OcrDocument(
        sourceName: 'photo-layout.png',
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
                text: '一、选择题（共 1 题）',
                bbox: [],
                readingOrder: 0,
              ),
              OcrBlock(
                blockId: 'question',
                pageIndex: 1,
                type: 'text',
                text:
                    '5. Synthetic prompt\n(A) one\n(B) two\n(C) three\n(D) four\n答案：A',
                bbox: [],
                readingOrder: 1,
              ),
              OcrBlock(
                blockId: 'analysis_heading',
                pageIndex: 1,
                type: 'text',
                text: '## 分析 Synthetic explanation',
                bbox: [],
                readingOrder: 2,
              ),
              OcrBlock(
                blockId: 'analysis_table',
                pageIndex: 1,
                type: 'table',
                text: '<table><tr><td>left</td><td>right</td></tr></table>',
                bbox: [],
                readingOrder: 3,
              ),
              OcrBlock(
                blockId: 'analysis_image',
                pageIndex: 1,
                type: 'image',
                text: '[图片]',
                bbox: [],
                readingOrder: 4,
              ),
            ],
          ),
        ],
      );

      final region =
          const OcrQuestionRegionizer().regionize(document).regions.single;

      expect(region.stemText, isNot(contains('分析')));
      expect(region.explanationText, contains('Synthetic explanation'));
      expect(
        region.ownedSources
            .where((source) => <String>{
                  'analysis_heading',
                  'analysis_table',
                  'analysis_image',
                }.contains(source.blockId))
            .map((source) => source.field),
        everyElement(OcrRegionField.explanation),
      );
    });

    test('does not infer explanation ownership from table projection text', () {
      final document = OcrDocument(
        sourceName: 'table-marker.pdf',
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
                text: '一、选择题（共 1 题）',
                bbox: [],
                readingOrder: 0,
              ),
              OcrBlock(
                blockId: 'question',
                pageIndex: 1,
                type: 'text',
                text: '1. Valid stem (A) one (B) two',
                bbox: [],
                readingOrder: 1,
              ),
              OcrBlock(
                blockId: 'table',
                pageIndex: 1,
                type: 'table',
                text: '<table><tr><td>解析：cell text</td></tr></table>',
                bbox: [],
                readingOrder: 2,
              ),
              OcrBlock(
                blockId: 'answer',
                pageIndex: 1,
                type: 'text',
                text: '答案：A',
                bbox: [],
                readingOrder: 3,
              ),
            ],
          ),
        ],
      );

      final region =
          const OcrQuestionRegionizer().regionize(document).regions.single;
      final tableSource = region.ownedSources.singleWhere(
        (source) => source.blockId == 'table',
      );

      expect(tableSource.field, OcrRegionField.stem);
      expect(region.explanationText, isEmpty);
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

      test('ignores reference sections when deriving the official tail', () {
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
          '一、选择题（本题共10小题，每小题5分，共50分）',
        );
        for (var number = 1; number <= 10; number++) {
          add('q$number', '$number. 第$number道选择脱敏题干。');
        }
        add('fill_section', '二、填空题（本题共6小题，每小题5分，共30分）');
        for (var number = 11; number <= 12; number++) {
          add('q$number', '$number. 第$number道填空脱敏题干。');
        }
        add('subjective_section', '三、解答题（本题共6小题，共70分）');
        add('reference_choice', '一、选择题');
        add('reference_q1', '（1）参考条目。');
        add('reference_fill', '二、填空题');
        add('reference_q11', '（11）参考条目。');
        add('reference_subjective', '三、解答题');
        add('reference_q13', '（13）参考条目。');

        final result = const OcrQuestionRegionizer().regionize(
          OcrDocument(
            sourceName: 'official-tail-before-reference.pdf',
            markdown: '',
            rawResponses: const [],
            usage: const {},
            pages: [OcrPage(pageIndex: 1, blocks: blocks)],
          ),
        );

        expect(
          result.diagnostics['acceptedNumbers'],
          List<int>.generate(12, (index) => index + 1),
        );
        expect(result.diagnostics['expectedQuestionCount'], 22);
        expect(
          result.diagnostics['tailMissingNumbers'],
          List<int>.generate(10, (index) => index + 13),
        );
        expect(result.diagnostics['missingQuestionCount'], 10);
        expect(result.diagnostics['referenceSectionDetected'], isTrue);
        final trace = result.diagnostics['questionCandidateTrace'] as List;
        final referenceEntries = trace.where(
          (entry) => entry['reason'] == 'reference_section',
        );
        expect(referenceEntries, hasLength(3));
        expect(
          referenceEntries.map((entry) => entry['number']).toList(),
          [1, 11, 13],
        );
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

      test(
          'accepts a block-start bare marker when it strictly continues an official section',
          () {
        final document = OcrDocument(
          sourceName: 'sequential-bare-marker.pdf',
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
                  blockId: 'q12',
                  pageIndex: 1,
                  type: 'text',
                  text: '12. 第十二道脱敏题干。',
                  bbox: [],
                  readingOrder: 1,
                ),
                OcrBlock(
                  blockId: 'q13',
                  pageIndex: 1,
                  type: 'text',
                  text: '13 曲线相关的脱敏题干。',
                  bbox: [],
                  readingOrder: 2,
                ),
                OcrBlock(
                  blockId: 'q14',
                  pageIndex: 1,
                  type: 'text',
                  text: '14. 第十四道脱敏题干。',
                  bbox: [],
                  readingOrder: 3,
                ),
              ],
            ),
          ],
        );

        final result = const OcrQuestionRegionizer().regionize(document);

        expect(result.diagnostics['acceptedNumbers'], [12, 13, 14]);
        final trace = result.diagnostics['questionCandidateTrace'] as List;
        final q13 = trace.singleWhere((entry) => entry['number'] == 13);
        expect(q13['markerKind'], 'explicit_question');
        expect(q13['decision'], 'accepted');
        expect(q13['reason'], 'valid_question_start');
        expect(q13['previousAcceptedNumber'], 12);
      });

      test(
          'recovers sequential digit-prefix question markers only in official sections',
          () {
        final document = OcrDocument(
          sourceName: 'sequential-digit-prefix.pdf',
          markdown: '',
          rawResponses: const [],
          usage: const {},
          pages: [
            OcrPage(
              pageIndex: 1,
              blocks: const [
                OcrBlock(
                  blockId: 'subjective',
                  pageIndex: 1,
                  type: 'text',
                  text: '三、解答题',
                  bbox: [],
                  readingOrder: 0,
                ),
                OcrBlock(
                  blockId: 'q17',
                  pageIndex: 1,
                  type: 'text',
                  text: '17. 第十七道脱敏题干。',
                  bbox: [],
                  readingOrder: 1,
                ),
                OcrBlock(
                  blockId: 'q18',
                  pageIndex: 1,
                  type: 'text',
                  text: '18设函数满足脱敏条件。',
                  bbox: [],
                  readingOrder: 2,
                ),
                OcrBlock(
                  blockId: 'q19',
                  pageIndex: 1,
                  type: 'text',
                  text: '19若脱敏条件成立，求结论。',
                  bbox: [],
                  readingOrder: 3,
                ),
                OcrBlock(
                  blockId: 'q20',
                  pageIndex: 1,
                  type: 'text',
                  text: '20. 第二十道脱敏题干。',
                  bbox: [],
                  readingOrder: 4,
                ),
                OcrBlock(
                  blockId: 'q21',
                  pageIndex: 1,
                  type: 'text',
                  text: '21. 第二十一道脱敏题干。',
                  bbox: [],
                  readingOrder: 5,
                ),
                OcrBlock(
                  blockId: 'q22',
                  pageIndex: 1,
                  type: 'text',
                  text: '22求满足脱敏约束的结果。',
                  bbox: [],
                  readingOrder: 6,
                ),
                OcrBlock(
                  blockId: 'reference_choice',
                  pageIndex: 1,
                  type: 'text',
                  text: '一、选择题',
                  bbox: [],
                  readingOrder: 7,
                ),
                OcrBlock(
                  blockId: 'reference_unrecognized',
                  pageIndex: 1,
                  type: 'text',
                  text: '23设参考对象。',
                  bbox: [],
                  readingOrder: 8,
                ),
                OcrBlock(
                  blockId: 'reference_recognized',
                  pageIndex: 1,
                  type: 'text',
                  text: '（23）参考条目。',
                  bbox: [],
                  readingOrder: 9,
                ),
              ],
            ),
          ],
        );

        final result = const OcrQuestionRegionizer().regionize(document);

        expect(result.diagnostics['acceptedNumbers'], [17, 18, 19, 20, 21, 22]);
        expect(result.diagnostics['missingNumbers'], isEmpty);
        final acceptedNumbers =
            result.regions.map((region) => region.number).toList();
        expect(acceptedNumbers.toSet(), hasLength(acceptedNumbers.length));
        for (final number in [18, 19, 22]) {
          final region =
              result.regions.singleWhere((region) => region.number == number);
          expect(region.stemText, isNot(startsWith(number.toString())));
        }

        final trace = result.diagnostics['questionCandidateTrace'] as List;
        for (final number in [18, 19, 22]) {
          final entry = trace.singleWhere((item) => item['number'] == number);
          expect(entry['markerKind'], 'digit_prefix_unrecognized');
          expect(entry['decision'], 'accepted');
          expect(entry['reason'], 'valid_question_start');
          expect(entry['previousAcceptedNumber'], number - 1);
        }
        for (final number in [20, 21]) {
          final entry = trace.singleWhere((item) => item['number'] == number);
          expect(entry['decision'], 'accepted');
          expect(entry['reason'], 'valid_question_start');
        }
        expect(
          trace.where((entry) => entry['reason'] == 'sequence_mismatch'),
          isEmpty,
        );
        final referenceEntry =
            trace.singleWhere((entry) => entry['blockOrder'] == 9);
        expect(referenceEntry['decision'], 'rejected');
        expect(referenceEntry['reason'], 'reference_section');
        expect(
          result.diagnostics['markerProbeTrace'],
          isEmpty,
        );
      });

      test('keeps unsafe digit-prefix probes out of the candidate sequence',
          () {
        const sensitiveInternal = 'PRIVATE_INTERNAL_STEM';
        const sensitiveOther = 'PRIVATE_OTHER_FOLLOWER';
        final document = OcrDocument(
          sourceName: 'unsafe-digit-prefix.pdf',
          markdown: '',
          rawResponses: const [],
          usage: const {},
          pages: [
            OcrPage(
              pageIndex: 1,
              blocks: const [
                OcrBlock(
                  blockId: 'subjective',
                  pageIndex: 1,
                  type: 'text',
                  text: '三、解答题',
                  bbox: [],
                  readingOrder: 0,
                ),
                OcrBlock(
                  blockId: 'q17_with_internal',
                  pageIndex: 1,
                  type: 'text',
                  text: '17. 第十七道脱敏题干。\n18设$sensitiveInternal',
                  bbox: [],
                  readingOrder: 1,
                ),
                OcrBlock(
                  blockId: 'skipped_q19',
                  pageIndex: 1,
                  type: 'text',
                  text: '19设跳号题干。',
                  bbox: [],
                  readingOrder: 2,
                ),
                OcrBlock(
                  blockId: 'other_q18',
                  pageIndex: 1,
                  type: 'text',
                  text: '18x$sensitiveOther',
                  bbox: [],
                  readingOrder: 3,
                ),
                OcrBlock(
                  blockId: 'valid_q18',
                  pageIndex: 1,
                  type: 'text',
                  text: '18. 第十八道脱敏题干。',
                  bbox: [],
                  readingOrder: 4,
                ),
                OcrBlock(
                  blockId: 'duplicate_q18',
                  pageIndex: 1,
                  type: 'text',
                  text: '18设重复题干。',
                  bbox: [],
                  readingOrder: 5,
                ),
                OcrBlock(
                  blockId: 'skipped_q20',
                  pageIndex: 1,
                  type: 'text',
                  text: '20求跳号结果。',
                  bbox: [],
                  readingOrder: 6,
                ),
                OcrBlock(
                  blockId: 'reference_choice',
                  pageIndex: 1,
                  type: 'text',
                  text: '一、选择题',
                  bbox: [],
                  readingOrder: 7,
                ),
                OcrBlock(
                  blockId: 'reference_q19',
                  pageIndex: 1,
                  type: 'text',
                  text: '19设参考对象。',
                  bbox: [],
                  readingOrder: 8,
                ),
              ],
            ),
          ],
        );

        final result = const OcrQuestionRegionizer().regionize(document);

        expect(result.diagnostics['acceptedNumbers'], [17, 18]);
        final trace = result.diagnostics['questionCandidateTrace'] as List;
        expect(
          trace.where(
            (entry) => entry['markerKind'] == 'digit_prefix_unrecognized',
          ),
          isEmpty,
        );
        final probes = result.diagnostics['markerProbeTrace'] as List;
        expect(
          probes.where((entry) => entry['parsedNumber'] == 19),
          hasLength(1),
        );
        expect(
          probes.where(
            (entry) =>
                entry['parsedNumber'] == 18 &&
                entry['startsAtBlockStart'] == false,
          ),
          hasLength(1),
        );
        final encoded = probes.toString();
        expect(encoded, isNot(contains(sensitiveInternal)));
        expect(encoded, isNot(contains(sensitiveOther)));
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

      test('splits an embedded answer-summary heading before reference entries',
          () {
        final document = OcrDocument(
          sourceName: 'embedded-answer-summary.pdf',
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
                  blockId: 'embedded_summary',
                  pageIndex: 1,
                  type: 'text',
                  text: '安全尾注\n'
                      '第二行安全尾注\n'
                      '2022 模拟试卷参考答案汇总\n'
                      '安全说明\n'
                      '第二行安全说明',
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
        final boundary = result.referenceAnswerSectionBoundary;
        expect(boundary, isNotNull);
        expect(boundary!.blockId, 'embedded_summary');
        expect(boundary.pageIndex, 1);
        expect(boundary.headingLineIndex, 2);
        final trace = result.diagnostics['questionCandidateTrace'] as List;
        final referenceEntry = trace.singleWhere(
          (entry) => entry['number'] == 2,
        );
        expect(referenceEntry['decision'], 'rejected');
        expect(referenceEntry['reason'], 'reference_section');
      });

      test('does not treat a non-terminal answer-summary phrase as a heading',
          () {
        final document = OcrDocument(
          sourceName: 'answer-summary-prose.pdf',
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
                  blockId: 'not_summary',
                  pageIndex: 1,
                  type: 'text',
                  text: '参考答案速查说明',
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
              ],
            ),
          ],
        );

        final result = const OcrQuestionRegionizer().regionize(document);

        expect(result.diagnostics['acceptedNumbers'], [1, 2]);
        expect(result.diagnostics['referenceSectionDetected'], isFalse);
        expect(result.referenceAnswerSectionBoundary, isNull);
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

      test('records only safe probes for marker-like lines not made candidates',
          () {
        const sensitiveInternal = 'PRIVATE_INTERNAL_MARKER_TEXT';
        const sensitiveBlockStart = 'PRIVATE_BLOCK_START_MARKER_TEXT';
        const sensitiveReference = 'PRIVATE_REFERENCE_MARKER_TEXT';
        final document = OcrDocument(
          sourceName: 'marker-probe.pdf',
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
                  blockId: 'q17_with_unmatched_internal',
                  pageIndex: 1,
                  type: 'text',
                  text: '17. 第十七道脱敏题干。\n18x $sensitiveInternal',
                  bbox: [],
                  readingOrder: 1,
                ),
                OcrBlock(
                  blockId: 'unmatched_block_start',
                  pageIndex: 1,
                  type: 'text',
                  text: '19x $sensitiveBlockStart',
                  bbox: [],
                  readingOrder: 2,
                ),
                OcrBlock(
                  blockId: 'reference_heading',
                  pageIndex: 1,
                  type: 'text',
                  text: '参考答案速查',
                  bbox: [],
                  readingOrder: 3,
                ),
                OcrBlock(
                  blockId: 'reference_marker',
                  pageIndex: 1,
                  type: 'text',
                  text: '22x $sensitiveReference',
                  bbox: [],
                  readingOrder: 4,
                ),
              ],
            ),
          ],
        );

        final result = const OcrQuestionRegionizer().regionize(document);
        final probes = result.diagnostics['markerProbeTrace'] as List;

        expect(result.diagnostics['acceptedNumbers'], [17]);
        expect(probes, hasLength(2));
        expect(probes, [
          {
            'pageIndex': 1,
            'blockOrder': 1,
            'sectionIndex': 1,
            'startsAtBlockStart': false,
            'startsAtLineBoundary': true,
            'markerShape': 'digit_prefix_unrecognized',
            'parsedNumber': 18,
            'followerClass': 'other',
            'probeReason': 'internal_line_not_split',
          },
          {
            'pageIndex': 1,
            'blockOrder': 2,
            'sectionIndex': 1,
            'startsAtBlockStart': true,
            'startsAtLineBoundary': true,
            'markerShape': 'digit_prefix_unrecognized',
            'parsedNumber': 19,
            'followerClass': 'other',
            'probeReason': 'block_start_not_candidate',
          },
        ]);
        expect(result.diagnostics['markerProbeTraceTruncated'], isFalse);
        final encoded = probes.toString();
        expect(encoded, isNot(contains(sensitiveInternal)));
        expect(encoded, isNot(contains(sensitiveBlockStart)));
        expect(encoded, isNot(contains(sensitiveReference)));
        for (final probe in probes) {
          expect(
            (probe as Map).keys.toSet(),
            {
              'pageIndex',
              'blockOrder',
              'sectionIndex',
              'startsAtBlockStart',
              'startsAtLineBoundary',
              'markerShape',
              'parsedNumber',
              'followerClass',
              'probeReason',
            },
          );
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

  group('embedded structural image region ownership', () {
    const pngDataUrl = 'data:image/png;base64,'
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
        '+A8AAQUBAScY42YAAAAASUVORK5CYII=';

    OcrBlock block(
      String id,
      String type,
      String text,
      int order, {
      OcrImagePayload? imagePayload,
    }) {
      return OcrBlock(
        blockId: id,
        pageIndex: 1,
        type: type,
        text: text,
        bbox: const [],
        readingOrder: order,
        imagePayload: imagePayload,
      );
    }

    OcrDocument document(List<OcrBlock> blocks) {
      return OcrDocument(
        sourceName: 'figure_region.pdf',
        markdown: '',
        rawResponses: const [],
        usage: const {},
        pages: [OcrPage(pageIndex: 1, blocks: blocks)],
      );
    }

    test('fixture A: baseline text question with embedded image keeps region',
        () {
      final result = const OcrQuestionRegionizer().regionize(document([
        block('section', 'text', '三、解答题', 0),
        block('q_1', 'text', '1. Prompt before image', 1),
        block('img_001', 'image', pngDataUrl, 2),
        block('answer_1', 'text', '答案：A', 3),
        block('explanation_1', 'text', '解析：Because', 4),
      ]));

      expect(result.regions, hasLength(1));
      final region = result.regions.single;
      expect(region.number, 1);
      expect(region.stemText, contains('Prompt before image'));
      expect(
        region.ownedSources.map((source) => source.blockId),
        containsAll(<String>['q_1', 'img_001']),
      );
      expect(
        region.ownedSources
            .where((source) => source.blockId == 'img_001')
            .single
            .field,
        OcrRegionField.stem,
      );
      expect(region.answerText, 'A');
    });

    test(
        'fixture B: accepted standalone marker followed only by a structural '
        'image keeps the region and the owned image source', () {
      final payload = OcrImagePayload.fromDataUrl(pngDataUrl);
      expect(payload, isNotNull);

      // Source layer fact: the OcrDocument carries the structural image.
      final result = const OcrQuestionRegionizer().regionize(document([
        block('section', 'text', '三、解答题', 0),
        block('q_1', 'text', '1.', 1),
        block('img_001', 'image', '', 2, imagePayload: payload),
        block('q_2', 'text', '2. Next question stem', 3),
      ]));

      expect(result.regions.map((region) => region.number), [1, 2]);
      final q1 = result.regions.first;
      expect(
        q1.ownedSources.map((source) => source.blockId),
        contains('img_001'),
      );
      expect(
        q1.ownedSources
            .where((source) => source.blockId == 'img_001')
            .single
            .field,
        OcrRegionField.stem,
      );
    });

    test('fixture C: placeholder image text with payload is not duplicated',
        () {
      final payload = OcrImagePayload.fromDataUrl(pngDataUrl);
      final result = const OcrQuestionRegionizer().regionize(document([
        block('section', 'text', '三、解答题', 0),
        block('q_1', 'text', '1. Prompt', 1),
        block('img_001', 'image', '[图片]', 2, imagePayload: payload),
        block('answer_1', 'text', '答案：A', 3),
      ]));

      expect(result.regions, hasLength(1));
      final region = result.regions.single;
      expect(
        region.stemParts.where((part) => part.contains('图片')),
        hasLength(1),
      );
      expect(
        region.ownedSources.where((source) => source.blockId == 'img_001'),
        hasLength(1),
      );
    });

    test('fixture D: decorative logo and footer images stay question-unowned',
        () {
      final payload = OcrImagePayload.fromDataUrl(pngDataUrl);
      final result = const OcrQuestionRegionizer().regionize(document([
        block('logo', 'image', '', 0, imagePayload: payload),
        block('section', 'text', '三、解答题', 1),
        block('q_1', 'text', '1. Prompt', 2),
        block('answer_1', 'text', '答案：A', 3),
        block('section2', 'text', '四、解答题', 4),
        block('footer', 'image', '', 5, imagePayload: payload),
      ]));

      expect(result.regions.map((region) => region.number), [1]);
      final q1 = result.regions.single;
      expect(q1.sourceBlockIds, isNot(contains('logo')));
      expect(q1.sourceBlockIds, isNot(contains('footer')));
      expect(
        q1.ownedSources.map((source) => source.blockId),
        isNot(contains('logo')),
      );
      expect(
        q1.ownedSources.map((source) => source.blockId),
        isNot(contains('footer')),
      );
    });

    test('fixture E: consecutive structural and text questions keep numbering',
        () {
      final payload = OcrImagePayload.fromDataUrl(pngDataUrl);
      final result = const OcrQuestionRegionizer().regionize(document([
        block('section', 'text', '三、解答题', 0),
        block('q_1', 'text', '1.', 1),
        block('img_001', 'image', '', 2, imagePayload: payload),
        block('q_2', 'text', '2. Text question stem', 3),
        block('answer_2', 'text', '答案：B', 4),
      ]));

      expect(result.regions.map((region) => region.number), [1, 2]);
      expect(result.diagnostics['acceptedNumbers'], [1, 2]);
      expect(
        result.regions.first.ownedSources.map((source) => source.blockId),
        contains('img_001'),
      );
      final q2 = result.regions.last;
      expect(q2.stemText, contains('Text question stem'));
      expect(
        q2.ownedSources.map((source) => source.blockId),
        isNot(contains('img_001')),
      );
    });
  });

  group('range headings and single-sided markers', () {
    OcrBlock block(String id, String text, int order) {
      return OcrBlock(
        blockId: id,
        pageIndex: 1,
        type: 'text',
        text: text,
        bbox: const [],
        readingOrder: order,
      );
    }

    OcrDocument document(List<OcrBlock> blocks) {
      return OcrDocument(
        sourceName: 'synthetic-layout.pdf',
        markdown: '',
        rawResponses: const [],
        usage: const {},
        pages: [OcrPage(pageIndex: 1, blocks: blocks)],
      );
    }

    test('range heading accepts parenthesized and single-sided markers', () {
      final result = const OcrQuestionRegionizer().regionize(document([
        block('heading', '一、选择题(1〜8小题，每小题4分，共32分)', 0),
        block(
          'questions',
          '(1) Synthetic stem one。\n'
              '(2) Synthetic stem two。\n'
              '(3) Synthetic stem three。\n'
              '4）Synthetic stem four。\n'
              '5）Synthetic stem five。\n'
              '6）Synthetic stem six。\n'
              '7) Synthetic stem seven。\n'
              '8）Synthetic stem eight。',
          1,
        ),
      ]));

      expect(result.diagnostics['sectionHeadingCount'], 1);
      expect(
        result.regions.map((region) => region.number).toList(),
        [1, 2, 3, 4, 5, 6, 7, 8],
      );
      expect(result.diagnostics['acceptedNumbers'], [1, 2, 3, 4, 5, 6, 7, 8]);
      expect(result.diagnostics['expectedQuestionCount'], 8);
      expect(result.diagnostics['missingQuestionCount'], 0);
      expect(result.diagnostics['rightParenthesisCandidateCount'], 5);
      expect(result.diagnostics['rightParenthesisAcceptedCount'], 5);
      expect(result.diagnostics['rightParenthesisRejectedCount'], 0);
    });

    test('three range sections keep kind, count and cross-section sequence',
        () {
      final result = const OcrQuestionRegionizer().regionize(document([
        block('heading_1', '一、选择题(1〜8小题，每小题4分，共32分)', 0),
        block('q_1', '(1) Synthetic one。', 1),
        block('q_2', '(2) Synthetic two。', 2),
        block('heading_2', '二、填空题（9〜14小题，每小题4分，共24分）', 3),
        block('q_9', '9）Synthetic nine。', 4),
        block('q_10', '10）Synthetic ten。', 5),
        block('heading_3', '三、解答题（15〜23小题，共94分）', 6),
        block('q_15', '15）Synthetic fifteen。', 7),
        block('q_16', '16）Synthetic sixteen。', 8),
      ]));

      expect(result.diagnostics['sectionHeadingCount'], 3);
      final sections = result.diagnostics['sections'] as List;
      expect(
        sections.map((section) => (section as Map)['kind']).toList(),
        ['choice', 'fillBlank', 'subjective'],
      );
      expect(
        sections
            .map((section) => (section as Map)['expectedSectionQuestionCount'])
            .toList(),
        [8, 6, 9],
      );
      expect(result.diagnostics['acceptedNumbers'], [1, 2, 9, 10, 15, 16]);
      expect(result.diagnostics['expectedQuestionCount'], 23);
      expect(result.diagnostics['sequenceRejectedCount'], 0);
      expect(result.diagnostics['rightParenthesisRejectedCount'], 0);
    });

    test(
        'declared section counts stay authoritative and conflicts are not guessed',
        () {
      final compatible = const OcrQuestionRegionizer().regionize(document([
        block('heading', '一、选择题（共 8 小题）', 0),
        block('q_1', '1. Synthetic one。', 1),
        block('q_2', '2. Synthetic two。', 2),
      ]));

      expect(compatible.diagnostics['sectionHeadingCount'], 1);
      expect(compatible.diagnostics['acceptedNumbers'], [1, 2]);
      expect(compatible.diagnostics['expectedQuestionCount'], 8);

      final conflict = const OcrQuestionRegionizer().regionize(document([
        block('heading', '一、选择题(1〜8小题，共 10 小题)', 0),
        block('q_1', '1. Synthetic one。', 1),
      ]));

      expect(conflict.diagnostics['sectionHeadingCount'], 1);
      expect(conflict.diagnostics['expectedQuestionCount'], isNull);
    });

    test('body-text right-parenthesis shapes never become questions', () {
      final result = const OcrQuestionRegionizer().regionize(document([
        block(
          'body',
          '数据说明：\n'
              '2020）这是年份说明。\n'
              '10) kg\n'
              '12) cm',
          0,
        ),
      ]));

      expect(result.regions, isEmpty);
      expect(result.diagnostics['rightParenthesisCandidateCount'], 2);
      expect(result.diagnostics['rightParenthesisAcceptedCount'], 0);
      expect(result.diagnostics['rightParenthesisRejectedCount'], 2);
    });

    test('a four-digit year line is not a single-sided candidate', () {
      final result = const OcrQuestionRegionizer().regionize(document([
        block('heading', '一、选择题(1〜8小题，每小题4分，共32分)', 0),
        block(
          'body',
          '1. Synthetic one。\n2020）这是年份说明。\n2. Synthetic two。',
          1,
        ),
      ]));

      expect(result.regions.map((region) => region.number).toList(), [1, 2]);
      expect(result.diagnostics['rightParenthesisCandidateCount'], 0);
    });

    test('a sequence break inside a section rejects the single-sided marker',
        () {
      final result = const OcrQuestionRegionizer().regionize(document([
        block('heading', '一、选择题(1〜8小题，每小题4分，共32分)', 0),
        block('q_1', '(1) Synthetic one。', 1),
        block('q_2', '(2) Synthetic two。', 2),
        block('q_3', '(3) Synthetic three。', 3),
        block('q_4', '4）Synthetic four。', 4),
        block('q_9', '9）Synthetic nine。', 5),
      ]));

      expect(
          result.regions.map((region) => region.number).toList(), [1, 2, 3, 4]);
      expect(result.diagnostics['acceptedNumbers'], [1, 2, 3, 4]);
      expect(result.diagnostics['rightParenthesisAcceptedCount'], 1);
      expect(result.diagnostics['rightParenthesisRejectedCount'], 1);
      expect(result.diagnostics['sequenceRejectedCount'], 1);
    });

    test(
        'a drifted ordinal heading keeps its own section kind for 23 questions',
        () {
      var order = 0;
      OcrBlock next(String id, String text) => block(id, text, order++);
      // Faithful to the real 2020 marker shapes: (1)-(3), 4）-12）, (13)-(23).
      String marker(int number) =>
          number <= 3 || number >= 13 ? '($number)' : '$number）';

      final blocks = <OcrBlock>[
        next('heading_1', '一、选择题(1〜8小题，每小题4分，共32分)'),
        for (var number = 1; number <= 8; number++)
          next('q_$number', '${marker(number)} Synthetic stem $number。'),
        // The provider returned this heading's ordinal as a placeholder glyph.
        next('heading_2', '■、填空题（9〜14小题，每小题4分，共24分）'),
        for (var number = 9; number <= 14; number++)
          next('q_$number', '${marker(number)} Synthetic stem $number。'),
        next('heading_3', '三、解答题（15〜23小题，共94分）'),
        for (var number = 15; number <= 23; number++)
          next('q_$number', '${marker(number)} Synthetic stem $number。'),
      ];

      final result = const OcrQuestionRegionizer().regionize(document(blocks));

      expect(result.diagnostics['sectionHeadingCount'], 3);
      final sections = (result.diagnostics['sections'] as List).cast<Map>();
      expect(
        sections.map((section) => section['kind']),
        ['choice', 'fillBlank', 'subjective'],
      );
      expect(
        sections.map((section) => section['expectedSectionQuestionCount']),
        [8, 6, 9],
      );
      expect(sections[1]['ordinalDrifted'], isTrue);
      expect(sections[0].containsKey('ordinalDrifted'), isFalse);
      expect(sections[2].containsKey('ordinalDrifted'), isFalse);
      expect(
        result.diagnostics['acceptedNumbers'],
        List<int>.generate(23, (index) => index + 1),
      );
      expect(result.diagnostics['rightParenthesisAcceptedCount'], 9);

      TextQuestionKind kindFor(int number) => result.regions
          .singleWhere((region) => region.number == number)
          .declaredKind;
      expect(
        [for (var number = 1; number <= 8; number++) kindFor(number)],
        everyElement(TextQuestionKind.choice),
      );
      expect(
        [for (var number = 9; number <= 14; number++) kindFor(number)],
        everyElement(TextQuestionKind.fillBlank),
      );
      expect(
        [for (var number = 15; number <= 23; number++) kindFor(number)],
        everyElement(TextQuestionKind.subjective),
      );

      // Acceptance-equivalent: the assembled question types are 0 / 2 / 3.
      const assembler = OcrQuestionAssembler();
      int typeFor(int number) => assembler
          .assemble(
            result.regions.singleWhere((region) => region.number == number),
          )
          .question['type'] as int;
      expect(
        [for (var number = 1; number <= 8; number++) typeFor(number)],
        everyElement(0),
      );
      expect(
        [for (var number = 9; number <= 14; number++) typeFor(number)],
        everyElement(2),
      );
      expect(
        [for (var number = 15; number <= 23; number++) typeFor(number)],
        everyElement(3),
      );
    });

    test(
        'questions past a declared range window never inherit the missing '
        'section kind', () {
      var order = 0;
      OcrBlock next(String id, String text) => block(id, text, order++);
      // Faithful to the real 2020 trace: the provider never emitted the
      // 二、填空题 heading, so 9-14 sit behind the 选择题 window (1〜8).
      final blocks = <OcrBlock>[
        next('heading_1', '一、选择题(1〜8小题，每小题4分，共32分)'),
        for (var number = 1; number <= 8; number++) ...[
          next('q_$number', '（$number）Synthetic stem $number。'),
          next(
            'options_$number',
            '(A) Synthetic α。\n'
                '(B) Synthetic β。\n'
                '(C) Synthetic γ。\n'
                '(D) Synthetic δ。',
          ),
        ],
        for (var number = 9; number <= 14; number++)
          next('q_$number', '$number）Synthetic stem $number ____。'),
        next('heading_3', '三、解答题（15〜23小题，共94分）'),
        for (var number = 15; number <= 23; number++)
          next('q_$number', '（$number）Synthetic stem $number。'),
      ];

      final result = const OcrQuestionRegionizer().regionize(document(blocks));

      expect(result.diagnostics['sectionHeadingCount'], 2);
      expect(
        result.diagnostics['acceptedNumbers'],
        List<int>.generate(23, (index) => index + 1),
      );
      expect(result.diagnostics['expectedQuestionCount'], isNull);
      final sections = (result.diagnostics['sections'] as List).cast<Map>();
      expect(sections[0]['rangeEnd'], 8);
      expect(sections[1]['rangeStart'], 15);
      expect(sections[1]['rangeEnd'], 23);

      TextQuestionKind kindFor(int number) => result.regions
          .singleWhere((region) => region.number == number)
          .declaredKind;
      expect(
        [for (var number = 1; number <= 8; number++) kindFor(number)],
        everyElement(TextQuestionKind.choice),
      );
      expect(
        [for (var number = 9; number <= 14; number++) kindFor(number)],
        everyElement(TextQuestionKind.unknown),
      );
      expect(
        [for (var number = 15; number <= 23; number++) kindFor(number)],
        everyElement(TextQuestionKind.subjective),
      );

      const assembler = OcrQuestionAssembler();
      int typeFor(int number) => assembler
          .assemble(
            result.regions.singleWhere((region) => region.number == number),
          )
          .question['type'] as int;
      expect(
        [for (var number = 1; number <= 8; number++) typeFor(number)],
        everyElement(0),
      );
      expect(
        [for (var number = 9; number <= 14; number++) typeFor(number)],
        everyElement(2),
      );
      expect(
        [for (var number = 15; number <= 23; number++) typeFor(number)],
        everyElement(3),
      );

      // These six questions drove the useless repair round trips; the choice
      // option trigger must no longer be attached to them.
      for (var number = 9; number <= 14; number++) {
        final diagnostics = assembler
            .assemble(
              result.regions.singleWhere((region) => region.number == number),
            )
            .diagnostics;
        expect(
          diagnostics,
          contains('kind_outside_declared_section_range:choice'),
        );
        expect(diagnostics, isNot(contains('choice_options_less_than_2')));
      }
    });

    test('a heading without a declared range still governs later questions',
        () {
      var order = 0;
      OcrBlock next(String id, String text) => block(id, text, order++);

      final result = const OcrQuestionRegionizer().regionize(document([
        next('heading_1', '一、选择题(1〜8小题，每小题4分，共32分)'),
        for (var number = 1; number <= 8; number++)
          next('q_$number', '（$number）Synthetic stem $number。'),
        next('heading_2', '二、填空题（本题共6小题，每小题4分，共24分）'),
        for (var number = 9; number <= 14; number++)
          next('q_$number', '（$number）Synthetic stem $number ____。'),
      ]));

      expect(result.diagnostics['sectionHeadingCount'], 2);
      expect(result.diagnostics['expectedQuestionCount'], 14);
      expect(
        result.diagnostics['acceptedNumbers'],
        List<int>.generate(14, (index) => index + 1),
      );
      final sections = (result.diagnostics['sections'] as List).cast<Map>();
      expect(sections[1]['expectedSectionQuestionCount'], 6);
      expect(sections[1].containsKey('rangeStart'), isFalse);
      expect(sections[1].containsKey('rangeEnd'), isFalse);
      expect(
        result.regions
            .where((region) => region.number >= 9)
            .map((region) => region.declaredKind),
        everyElement(TextQuestionKind.fillBlank),
      );
    });

    test('a LaTeX math range heading keeps its declared window', () {
      var order = 0;
      OcrBlock next(String id, String text) => block(id, text, order++);

      final result = const OcrQuestionRegionizer().regionize(document([
        next('heading_1', '一、选择题(1〜2小题，每小题5分，共10分)'),
        next('q_1', '（1）Synthetic one。'),
        next('q_2', '（2）Synthetic two。'),
        next('heading_2', '二、填空题（3〜4小题，每小题5分，共10分）'),
        next('q_3', '3）Synthetic three ____。'),
        next('q_4', '4）Synthetic four ____。'),
        // The provider returns this heading's range as inline LaTeX math.
        next('heading_3', '## 三、解答题（\$5\\sim 6\$小题，共10分）'),
        next('q_5', '（5）Synthetic five。'),
        next('q_6', '（6）Synthetic six。'),
        next('body', '设函数 \$7\\sim 8\$ 小题成立。'),
      ]));

      expect(result.diagnostics['sectionHeadingCount'], 3);
      final sections = (result.diagnostics['sections'] as List).cast<Map>();
      expect(
        sections.map((section) => section['kind']),
        ['choice', 'fillBlank', 'subjective'],
      );
      expect(
        sections.map((section) => section['expectedSectionQuestionCount']),
        [2, 2, 2],
      );
      expect(sections[2]['rangeStart'], 5);
      expect(sections[2]['rangeEnd'], 6);
      expect(result.diagnostics['acceptedNumbers'], [1, 2, 3, 4, 5, 6]);
      expect(result.diagnostics['expectedQuestionCount'], 6);
      expect(
        result.regions
            .where((region) => region.number >= 5)
            .map((region) => region.declaredKind),
        everyElement(TextQuestionKind.subjective),
      );
    });

    test(
        'a dropped leading digit marker is recovered inside the declared window',
        () {
      var order = 0;
      OcrBlock next(String id, String text) => block(id, text, order++);
      // Faithful to the real 2021 trace: 13-16 reached the regionizer as
      // `(3)`/`4)`/`5)`/`(6)` because the provider dropped the leading `1`.
      final blocks = <OcrBlock>[
        next('heading_1', '一、选择题(1〜10小题，每小题5分，共50分)'),
        for (var number = 1; number <= 10; number++)
          next('q_$number', '（$number）Synthetic stem $number。'),
        next('heading_2', '二、填空题（11〜16小题，每小题5分，共30分）'),
        next('q_11', '11）Synthetic stem eleven ____。'),
        next('q_12', '12）Synthetic stem twelve ____。'),
        next('q_13', '(3) Synthetic stem thirteen ____。'),
        next('q_14', '4) Synthetic stem fourteen ____。'),
        next('q_15', '5) Synthetic stem fifteen ____。'),
        next('q_16', '(6) Synthetic stem sixteen ____。'),
        next('heading_3', '## 三、解答题（\$17\\sim 22\$小题，共70分）'),
        for (var number = 17; number <= 22; number++)
          next('q_$number', '（$number）Synthetic stem $number。'),
      ];

      final result = const OcrQuestionRegionizer().regionize(document(blocks));

      expect(result.diagnostics['sectionHeadingCount'], 3);
      expect(
        result.diagnostics['acceptedNumbers'],
        List<int>.generate(22, (index) => index + 1),
      );
      expect(result.diagnostics['expectedQuestionCount'], 22);
      expect(result.diagnostics['sequenceRejectedCount'], 0);

      final trace =
          (result.diagnostics['questionCandidateTrace'] as List).cast<Map>();
      final recovered = trace
          .where((entry) => (entry['reason'] as String)
              .startsWith('valid_question_start_leading_digit_recovered:'))
          .toList();
      expect(
        recovered.map((entry) => entry['number']).toList(),
        [13, 14, 15, 16],
      );

      TextQuestionKind kindFor(int number) => result.regions
          .singleWhere((region) => region.number == number)
          .declaredKind;
      expect(
        [for (var number = 1; number <= 10; number++) kindFor(number)],
        everyElement(TextQuestionKind.choice),
      );
      expect(
        [for (var number = 11; number <= 16; number++) kindFor(number)],
        everyElement(TextQuestionKind.fillBlank),
      );
      expect(
        [for (var number = 17; number <= 22; number++) kindFor(number)],
        everyElement(TextQuestionKind.subjective),
      );
    });

    test('leading digit recovery never fires without its three anchors', () {
      // (a) the expected next number does not end with the seen digits
      final noSuffix = const OcrQuestionRegionizer().regionize(document([
        block('heading', '一、选择题(1〜5小题，每小题5分，共25分)', 0),
        block('q_1', '（1）Synthetic one。', 1),
        block('q_2', '（2）Synthetic two。', 2),
        block('q_3', '（3）Synthetic three。', 3),
        block('q_dup', '（3）Synthetic duplicate。', 4),
      ]));
      expect(noSuffix.diagnostics['acceptedNumbers'], [1, 2, 3]);
      expect(noSuffix.diagnostics['sequenceRejectedCount'], 1);

      // (b) the seen number was never accepted in this document
      final neverAccepted = const OcrQuestionRegionizer().regionize(document([
        block('heading_1', '一、选择题(1〜10小题，每小题5分，共50分)', 0),
        block('q_1', '（1）Synthetic one。', 1),
        block('heading_2', '二、填空题（11〜16小题，每小题5分，共30分）', 2),
        block('q_11', '11）Synthetic eleven ____。', 3),
        block('q_12', '12）Synthetic twelve ____。', 4),
        block('q_13', '13）Synthetic thirteen ____。', 5),
        block('q_14', '14）Synthetic fourteen ____。', 6),
        block('q_15', '15）Synthetic fifteen ____。', 7),
        block('q_4', '(4) Synthetic four ____。', 8),
      ]));
      expect(
        neverAccepted.diagnostics['acceptedNumbers'],
        [1, 11, 12, 13, 14, 15],
      );
      expect(neverAccepted.diagnostics['sequenceRejectedCount'], 1);

      // (c) the expected number is outside the section's declared window
      final outsideWindow = const OcrQuestionRegionizer().regionize(document([
        block('heading_1', '一、选择题(1〜10小题，每小题5分，共50分)', 0),
        block('q_1', '（1）Synthetic one。', 1),
        block('heading_2', '二、填空题（11〜13小题，共15分）', 2),
        block('q_11', '11）Synthetic eleven ____。', 3),
        block('q_12', '12）Synthetic twelve ____。', 4),
        block('q_13', '13）Synthetic thirteen ____。', 5),
        block('q_4', '(4) Synthetic four ____。', 6),
      ]));
      expect(outsideWindow.diagnostics['acceptedNumbers'], [1, 11, 12, 13]);
      expect(outsideWindow.diagnostics['sequenceRejectedCount'], 1);
    });

    test(
        'a two-symbol drifted ordinal is tolerated while unsupported shapes are not',
        () {
      final drifted = const OcrQuestionRegionizer().regionize(document([
        block('heading', '：■、填空题（9〜14小题，每小题4分，共24分）', 0),
        block('q_9', '9）Synthetic nine。', 1),
      ]));

      expect(drifted.diagnostics['sectionHeadingCount'], 1);
      final sections = (drifted.diagnostics['sections'] as List).cast<Map>();
      expect(sections.single['kind'], 'fillBlank');
      expect(sections.single['ordinalDrifted'], isTrue);
      expect(sections.single['expectedSectionQuestionCount'], 6);
      expect(drifted.regions.single.declaredKind, TextQuestionKind.fillBlank);

      for (final heading in const <String>[
        '2020、填空题（9〜14小题，每小题4分，共24分）',
        'A、填空题（9〜14小题，每小题4分，共24分）',
        '■、填空题（略）',
      ]) {
        final rejected = const OcrQuestionRegionizer().regionize(document([
          block('heading', heading, 0),
          block('q_1', '1. Synthetic stem。', 1),
        ]));
        expect(rejected.diagnostics['sectionHeadingCount'], 0, reason: heading);
        expect(
          rejected.regions.single.declaredKind,
          TextQuestionKind.unknown,
          reason: heading,
        );
      }
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/domain/assets/asset_ref.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/import/import_issue.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/question/question_region.dart';
import 'package:shiroha_quiz/domain/source/source_part.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/services/import_pipeline/typed_question_assembler.dart';

void main() {
  const assembler = TypedQuestionAssembler();

  group('TypedQuestionAssembler identity and kind mapping', () {
    test('uses the caller-owned question id verbatim', () {
      final draft = assembler.assemble(
        _region(
          stemText: '1. 题干\nA. 甲\nB. 乙',
          answerText: 'A',
          kindHint: QuestionRegionKindHint.singleChoice,
        ),
        questionId: 'caller_owned_42',
      );
      expect(draft.questionId, 'caller_owned_42');
      expect(draft.questionNumber, 1);
    });

    test('maps multipleChoice to singleChoice and trueFalse to shortAnswer',
        () {
      final multi = assembler.assemble(
        _region(
          stemText: '题干\nA. 甲\nB. 乙',
          answerText: 'AB',
          kindHint: QuestionRegionKindHint.multipleChoice,
        ),
        questionId: 'q_1',
      );
      expect(multi.kind, QuestionKind.singleChoice);
      expect(multi.answer, ChoiceAnswer(optionIds: <String>['A', 'B']));

      final trueFalse = assembler.assemble(
        _region(
          stemText: '判断正误（√）',
          answerText: '正确',
          kindHint: QuestionRegionKindHint.trueFalse,
        ),
        questionId: 'q_2',
      );
      expect(trueFalse.kind, QuestionKind.shortAnswer);
      expect(
        ((trueFalse.answer! as ContentAnswer).content.nodes.single as TextNode)
            .text,
        '√',
      );
    });

    test('infers unknown kinds from options and blank markers', () {
      final choice = assembler.assemble(
        _region(
          stemText: '题干\nA. 甲\nB. 乙',
          answerText: 'A',
          kindHint: QuestionRegionKindHint.unknown,
        ),
        questionId: 'q_1',
      );
      expect(choice.kind, QuestionKind.singleChoice);

      final blank = assembler.assemble(
        _region(
          stemText: '计算 ____ 的值',
          answerText: '42',
          kindHint: QuestionRegionKindHint.unknown,
        ),
        questionId: 'q_2',
      );
      expect(blank.kind, QuestionKind.fillBlank);

      final short = assembler.assemble(
        _region(
          stemText: '简述理由',
          answerText: '因为题干。',
          kindHint: QuestionRegionKindHint.unknown,
        ),
        questionId: 'q_3',
      );
      expect(short.kind, QuestionKind.shortAnswer);
    });
  });

  group('TypedQuestionAssembler field fragments', () {
    test('assembles stem, options, answer, and explanation directly', () {
      final draft = assembler.assemble(
        _region(
          stemText: '1. 题干\nA. 甲\nB. 乙\nC. 丙\nD. 丁',
          answerText: 'A',
          explanationText: '解析：因为题干',
          kindHint: QuestionRegionKindHint.singleChoice,
        ),
        questionId: 'q_1',
      );
      expect((draft.stem.nodes.single as TextNode).text, '题干');
      expect(
        draft.options.map((option) => option.optionId).toList(),
        <String>['A', 'B', 'C', 'D'],
      );
      expect(
        (draft.options.first.content.nodes.single as TextNode).text,
        '甲',
      );
      expect(draft.answer, ChoiceAnswer(optionIds: <String>['A']));
      expect(
        (draft.explanation!.nodes.single as TextNode).text,
        '因为题干',
      );
    });

    test('preserves math nodes verbatim when text extraction is unsafe', () {
      final region = QuestionRegion(
        questionNumber: 1,
        fragments: <QuestionRegionFragment>[
          QuestionRegionFragment(
            field: QuestionRegionField.stem,
            part: SourceContentPart(
              sourceRef: _docRef(),
              content: RichContent(nodes: <ContentNode>[
                const TextNode('求'),
                const InlineMathNode(r'f(x)'),
                const TextNode('的极值'),
              ]),
            ),
          ),
        ],
        kindHint: QuestionRegionKindHint.shortAnswer,
      );
      final draft = assembler.assemble(region, questionId: 'q_1');
      expect(draft.stem.nodes, <ContentNode>[
        const TextNode('求'),
        const InlineMathNode(r'f(x)'),
        const TextNode('的极值'),
      ]);
      expect(draft.options, isEmpty);
    });

    test('preserves source refs across multiple sources', () {
      final region = QuestionRegion(
        questionNumber: 1,
        fragments: <QuestionRegionFragment>[
          QuestionRegionFragment(
            field: QuestionRegionField.stem,
            part: _textPart('题干', ref: _docRef('source_a')),
          ),
          QuestionRegionFragment(
            field: QuestionRegionField.answer,
            part: _textPart('42', ref: _docRef('source_b')),
          ),
        ],
        kindHint: QuestionRegionKindHint.shortAnswer,
      );
      final draft = assembler.assemble(region, questionId: 'q_1');
      expect(
        draft.sourceRefs.map((ref) => ref.sourceId).toSet(),
        <String>{'source_a', 'source_b'},
      );
    });
  });

  group('TypedQuestionAssembler lossless and explicit failure paths', () {
    test('maps asset parts to ordered ImageNodes and keeps the inventory', () {
      final region = QuestionRegion(
        questionNumber: 1,
        fragments: <QuestionRegionFragment>[
          QuestionRegionFragment(
            field: QuestionRegionField.stem,
            part: SourceAssetPart(
              sourceRef: SourceRef.at(
                sourceId: 'source_a',
                point: SourcePoint.block(
                  pageNumber: 1,
                  blockId: 'asset_a',
                  readingOrder: 0,
                ),
              ),
              asset: AssetRef(
                assetId: 'asset_a',
                kind: AssetKind.image,
                mimeType: 'image/png',
              ),
            ),
          ),
          QuestionRegionFragment(
            field: QuestionRegionField.stem,
            part: _textPart('题干'),
          ),
          QuestionRegionFragment(
            field: QuestionRegionField.stem,
            part: SourceAssetPart(
              sourceRef: SourceRef.at(
                sourceId: 'source_a',
                point: SourcePoint.block(
                  pageNumber: 1,
                  blockId: 'asset_b',
                  readingOrder: 2,
                ),
              ),
              asset: AssetRef(
                assetId: 'asset_b',
                kind: AssetKind.image,
              ),
            ),
          ),
        ],
        kindHint: QuestionRegionKindHint.shortAnswer,
      );
      final draft = assembler.assemble(region, questionId: 'q_1');

      expect(draft.stem.nodes, <ContentNode>[
        ImageNode(
          sourceId: 'source_a',
          localAssetId: 'asset_a',
        ),
        const TextNode('题干'),
        ImageNode(
          sourceId: 'source_a',
          localAssetId: 'asset_b',
        ),
      ]);
      expect(
        draft.assetRefs.map((asset) => asset.localAssetId),
        <String>['asset_a', 'asset_b'],
      );
    });

    test('preserves asset alternative text on the ImageNode', () {
      final region = QuestionRegion(
        questionNumber: 1,
        fragments: <QuestionRegionFragment>[
          QuestionRegionFragment(
            field: QuestionRegionField.stem,
            part: SourceAssetPart(
              sourceRef: _docRef(),
              asset: AssetRef(assetId: 'asset_1', kind: AssetKind.image),
              alternativeText: RichContent(
                nodes: <ContentNode>[const TextNode('图示')],
              ),
            ),
          ),
        ],
        kindHint: QuestionRegionKindHint.shortAnswer,
      );
      final draft = assembler.assemble(region, questionId: 'q_1');
      final image = draft.stem.nodes.single as ImageNode;
      expect(image.localAssetId, 'asset_1');
      expect(image.alternativeText!.nodes, <ContentNode>[const TextNode('图示')]);
    });

    test('preserves repeated asset placements while deduplicating inventory',
        () {
      final assetPart = SourceAssetPart(
        sourceRef: SourceRef.at(
          sourceId: 'source_a',
          point: SourcePoint.block(
            pageNumber: 1,
            blockId: 'asset_repeat',
            readingOrder: 1,
          ),
        ),
        asset: AssetRef(assetId: 'asset_repeat', kind: AssetKind.image),
      );
      final region = QuestionRegion(
        questionNumber: 1,
        fragments: <QuestionRegionFragment>[
          QuestionRegionFragment(
            field: QuestionRegionField.stem,
            part: _textPart('before'),
          ),
          QuestionRegionFragment(
            field: QuestionRegionField.stem,
            part: assetPart,
          ),
          QuestionRegionFragment(
            field: QuestionRegionField.stem,
            part: assetPart,
          ),
          QuestionRegionFragment(
            field: QuestionRegionField.stem,
            part: _textPart('after'),
          ),
        ],
        kindHint: QuestionRegionKindHint.shortAnswer,
      );
      final draft = assembler.assemble(region, questionId: 'q_repeat');

      expect(draft.stem.nodes, <ContentNode>[
        const TextNode('before'),
        ImageNode(sourceId: 'source_a', localAssetId: 'asset_repeat'),
        ImageNode(sourceId: 'source_a', localAssetId: 'asset_repeat'),
        const TextNode('after'),
      ]);
      expect(draft.assetRefs, hasLength(1));
    });

    test('preserves text, image, formula, image, text order without joins', () {
      final imageA = SourceAssetPart(
        sourceRef: SourceRef.at(
          sourceId: 'source_a',
          point: SourcePoint.block(
            pageNumber: 1,
            blockId: 'image_a',
            readingOrder: 1,
          ),
        ),
        asset: AssetRef(assetId: 'image_a', kind: AssetKind.image),
      );
      final imageB = SourceAssetPart(
        sourceRef: SourceRef.at(
          sourceId: 'source_a',
          point: SourcePoint.block(
            pageNumber: 1,
            blockId: 'image_b',
            readingOrder: 3,
          ),
        ),
        asset: AssetRef(assetId: 'image_b', kind: AssetKind.image),
      );
      final formula = SourceContentPart(
        sourceRef: SourceRef.at(
          sourceId: 'source_a',
          point: SourcePoint.block(
            pageNumber: 1,
            blockId: 'formula_order',
            readingOrder: 2,
          ),
        ),
        content: RichContent(nodes: <ContentNode>[const BlockMathNode('x')]),
        role: SourceContentRole.formula,
      );
      final region = QuestionRegion(
        questionNumber: 1,
        fragments: <QuestionRegionFragment>[
          QuestionRegionFragment(
            field: QuestionRegionField.stem,
            part: _textPart('before'),
          ),
          QuestionRegionFragment(
            field: QuestionRegionField.stem,
            part: imageA,
          ),
          QuestionRegionFragment(
            field: QuestionRegionField.stem,
            part: formula,
          ),
          QuestionRegionFragment(
            field: QuestionRegionField.stem,
            part: imageB,
          ),
          QuestionRegionFragment(
            field: QuestionRegionField.stem,
            part: _textPart('after'),
          ),
        ],
        kindHint: QuestionRegionKindHint.shortAnswer,
      );
      final draft = assembler.assemble(region, questionId: 'q_order');

      expect(draft.stem.nodes, <ContentNode>[
        const TextNode('before'),
        ImageNode(sourceId: 'source_a', localAssetId: 'image_a'),
        const BlockMathNode('x'),
        ImageNode(sourceId: 'source_a', localAssetId: 'image_b'),
        const TextNode('after'),
      ]);
      expect(
        draft.assetRefs.map((asset) => asset.localAssetId),
        <String>['image_a', 'image_b'],
      );
    });

    test('maps a rectangular source table to a TableNode', () {
      final tableRegion = QuestionRegion(
        questionNumber: 1,
        fragments: <QuestionRegionFragment>[
          QuestionRegionFragment(
            field: QuestionRegionField.stem,
            part: SourceTablePart(
              sourceRef: _docRef(),
              rows: <List<RichContent>>[
                <RichContent>[
                  RichContent(nodes: <ContentNode>[const TextNode('cell 1')]),
                  RichContent(nodes: <ContentNode>[const InlineMathNode('x')]),
                ],
                <RichContent>[
                  RichContent(nodes: <ContentNode>[const TextNode('cell 2')]),
                  RichContent(nodes: <ContentNode>[]),
                ],
              ],
            ),
          ),
        ],
        kindHint: QuestionRegionKindHint.unknown,
      );
      final draft = assembler.assemble(tableRegion, questionId: 'q_table');

      final table = draft.stem.nodes.single as TableNode;
      expect(table.structure.rows, hasLength(2));
      expect(table.structure.columnCount, 2);
      expect(table.structure.rows.first.cells, hasLength(2));
      expect(
        table.structure.rows.first.cells[1].content.nodes.single,
        const InlineMathNode('x'),
      );
    });

    test('preserves table and image encounter order in one field', () {
      final tablePart = SourceTablePart(
        sourceRef: _docRef(),
        rows: <List<RichContent>>[
          <RichContent>[
            RichContent(nodes: <ContentNode>[const TextNode('cell')]),
          ],
        ],
      );
      final imagePart = SourceAssetPart(
        sourceRef: _docRef(),
        asset: AssetRef(assetId: 'table_image', kind: AssetKind.image),
      );
      final draft = assembler.assemble(
        QuestionRegion(
          questionNumber: 1,
          fragments: <QuestionRegionFragment>[
            QuestionRegionFragment(
              field: QuestionRegionField.stem,
              part: tablePart,
            ),
            QuestionRegionFragment(
              field: QuestionRegionField.stem,
              part: imagePart,
            ),
          ],
          kindHint: QuestionRegionKindHint.shortAnswer,
        ),
        questionId: 'q_table_image',
      );

      expect(draft.stem.nodes, hasLength(2));
      expect(draft.stem.nodes.first, isA<TableNode>());
      expect(
        draft.stem.nodes[1],
        ImageNode(sourceId: 'source_a', localAssetId: 'table_image'),
      );
    });

    test('fails explicitly for nonrepresentable tables and unsupported parts',
        () {
      final raggedRegion = QuestionRegion(
        questionNumber: 1,
        fragments: <QuestionRegionFragment>[
          QuestionRegionFragment(
            field: QuestionRegionField.stem,
            part: SourceTablePart(
              sourceRef: _docRef(),
              rows: <List<RichContent>>[
                <RichContent>[
                  RichContent(nodes: <ContentNode>[const TextNode('cell')]),
                ],
                <RichContent>[
                  RichContent(nodes: <ContentNode>[const TextNode('a')]),
                  RichContent(nodes: <ContentNode>[const TextNode('b')]),
                ],
              ],
            ),
          ),
        ],
        kindHint: QuestionRegionKindHint.unknown,
      );
      expect(
        () => assembler.assemble(raggedRegion, questionId: 'q_1'),
        throwsA(
          isA<QuestionRegionUnsupportedException>()
              .having((error) => error.kindCode, 'kindCode', 'source_table'),
        ),
      );

      final emptyRegion = QuestionRegion(
        questionNumber: 1,
        fragments: <QuestionRegionFragment>[
          QuestionRegionFragment(
            field: QuestionRegionField.stem,
            part: SourceTablePart(
              sourceRef: _docRef(),
              rows: const <List<RichContent>>[],
            ),
          ),
        ],
        kindHint: QuestionRegionKindHint.unknown,
      );
      expect(
        () => assembler.assemble(emptyRegion, questionId: 'q_empty_table'),
        throwsA(
          isA<QuestionRegionUnsupportedException>()
              .having((error) => error.kindCode, 'kindCode', 'source_table'),
        ),
      );

      final rawCellRegion = QuestionRegion(
        questionNumber: 1,
        fragments: <QuestionRegionFragment>[
          QuestionRegionFragment(
            field: QuestionRegionField.stem,
            part: SourceTablePart(
              sourceRef: _docRef(),
              rows: <List<RichContent>>[
                <RichContent>[
                  RichContent(nodes: <ContentNode>[
                    RawFallbackNode(<String, Object?>{
                      'type': 'raw_fallback',
                      'payload': <String, Object?>{'kind': 'cell'},
                    }),
                  ]),
                ],
              ],
            ),
          ),
        ],
        kindHint: QuestionRegionKindHint.unknown,
      );
      expect(
        () => assembler.assemble(rawCellRegion, questionId: 'q_raw_table'),
        throwsA(isA<QuestionRegionUnsupportedException>()),
      );

      final unsupportedRegion = QuestionRegion(
        questionNumber: 1,
        fragments: <QuestionRegionFragment>[
          QuestionRegionFragment(
            field: QuestionRegionField.stem,
            part: UnsupportedSourcePart(
              sourceRef: _docRef(),
              kindCode: 'ocr_table',
              fallbackContent: RichContent(
                nodes: <ContentNode>[const TextNode('表格')],
              ),
            ),
          ),
        ],
        kindHint: QuestionRegionKindHint.unknown,
      );
      expect(
        () => assembler.assemble(unsupportedRegion, questionId: 'q_1'),
        throwsA(
          isA<QuestionRegionUnsupportedException>()
              .having((error) => error.kindCode, 'kindCode', 'ocr_table'),
        ),
      );
    });

    test('fails explicitly on duplicate extracted option keys', () {
      final region = _region(
        stemText: 'A. 甲\nA. 乙\nB. 丙',
        kindHint: QuestionRegionKindHint.multipleChoice,
      );
      expect(
        () => assembler.assemble(region, questionId: 'q_1'),
        throwsFormatException,
      );
    });
  });

  group('TypedQuestionAssembler source slices', () {
    test('materializes UTF-16 intervals and keeps math/raw nodes whole', () {
      final rawFallback = RawFallbackNode(<String, Object?>{
        'type': 'raw_fallback',
        'payload': <String, Object?>{'kind': 'span'},
      });
      final part = SourceContentPart(
        sourceRef: _docRef(),
        content: RichContent(nodes: <ContentNode>[
          const TextNode('前😀段'),
          rawFallback,
          const InlineMathNode(r'f(x)=x^2'),
          const TextNode('尾段'),
        ]),
      );
      final region = QuestionRegion(
        questionNumber: 1,
        fragments: <QuestionRegionFragment>[
          QuestionRegionFragment(
            field: QuestionRegionField.stem,
            part: part,
            slice: SourceSlice(
              startNodeIndex: 0,
              startCodeUnitOffset: 1,
              endNodeIndex: 3,
              endCodeUnitOffset: 0,
            ),
          ),
          QuestionRegionFragment(
            field: QuestionRegionField.answer,
            part: part,
            slice: SourceSlice(
              startNodeIndex: 3,
              startCodeUnitOffset: 0,
              endNodeIndex: 4,
              endCodeUnitOffset: 0,
            ),
          ),
        ],
        kindHint: QuestionRegionKindHint.shortAnswer,
      );
      final draft = assembler.assemble(region, questionId: 'q_slice');

      expect(draft.stem.nodes, hasLength(3));
      expect((draft.stem.nodes[0] as TextNode).text, '😀段');
      expect(draft.stem.nodes[1], same(rawFallback));
      expect(
        (draft.stem.nodes[2] as InlineMathNode).latex,
        r'f(x)=x^2',
      );
      final answerNodes = (draft.answer! as ContentAnswer).content.nodes;
      expect(answerNodes, hasLength(1));
      expect((answerNodes.single as TextNode).text, '尾段');
      final stemText = _searchTextOf(draft.stem.nodes);
      final answerText =
          _searchTextOf((draft.answer! as ContentAnswer).content.nodes);
      expect(stemText, isNot(contains('前')));
      expect(stemText, isNot(contains('尾段')));
      expect(answerText, isNot(contains('前')));
      expect(answerText, isNot(contains('f(x)')));
      expect(answerText, '尾段');
    });

    test('splits one text node into stem and answer by UTF-16 offsets', () {
      final part = SourceContentPart(
        sourceRef: _docRef(),
        content: RichContent(
          nodes: <ContentNode>[const TextNode('A部分😀B部分')],
        ),
      );
      final region = QuestionRegion(
        questionNumber: 1,
        fragments: <QuestionRegionFragment>[
          QuestionRegionFragment(
            field: QuestionRegionField.stem,
            part: part,
            slice: SourceSlice(
              startNodeIndex: 0,
              startCodeUnitOffset: 0,
              endNodeIndex: 0,
              endCodeUnitOffset: 5,
            ),
          ),
          QuestionRegionFragment(
            field: QuestionRegionField.answer,
            part: part,
            slice: SourceSlice(
              startNodeIndex: 0,
              startCodeUnitOffset: 5,
              endNodeIndex: 1,
              endCodeUnitOffset: 0,
            ),
          ),
        ],
        kindHint: QuestionRegionKindHint.shortAnswer,
      );
      final draft = assembler.assemble(region, questionId: 'q_split');

      expect((draft.stem.nodes.single as TextNode).text, 'A部分😀');
      expect(
        ((draft.answer! as ContentAnswer).content.nodes.single as TextNode)
            .text,
        'B部分',
      );
    });
  });

  group('TypedQuestionAssembler raw fallback preservation', () {
    RawFallbackNode rawFallback() {
      return RawFallbackNode(<Object?, Object?>{
        'type': 'raw_fallback',
        'payload': <Object?, Object?>{'kind': 'span'},
      });
    }

    test('preserves a raw-only stem fragment without missing_stem', () {
      final raw = rawFallback();
      final region = QuestionRegion(
        questionNumber: 1,
        fragments: <QuestionRegionFragment>[
          QuestionRegionFragment(
            field: QuestionRegionField.stem,
            part: SourceContentPart(
              sourceRef: _docRef(),
              content: RichContent(nodes: <ContentNode>[raw]),
            ),
          ),
        ],
        kindHint: QuestionRegionKindHint.unknown,
      );
      final draft = assembler.assemble(region, questionId: 'q_raw_stem');

      expect(draft.stem.nodes, <ContentNode>[raw]);
      final codes = draft.issues.map((issue) => issue.code).toList();
      expect(codes, isNot(contains('missing_stem')));
      expect(codes, isNot(contains('empty_content')));
      expect(draft.kind, QuestionKind.shortAnswer);
    });

    test('preserves a raw-only answer fragment', () {
      final raw = rawFallback();
      final region = QuestionRegion(
        questionNumber: 1,
        fragments: <QuestionRegionFragment>[
          QuestionRegionFragment(
            field: QuestionRegionField.stem,
            part: _textPart('题干'),
          ),
          QuestionRegionFragment(
            field: QuestionRegionField.answer,
            part: SourceContentPart(
              sourceRef: _docRef(),
              content: RichContent(nodes: <ContentNode>[raw]),
            ),
          ),
        ],
        kindHint: QuestionRegionKindHint.shortAnswer,
      );
      final draft = assembler.assemble(region, questionId: 'q_raw_answer');

      final answer = draft.answer! as ContentAnswer;
      expect(answer.content.nodes, <ContentNode>[raw]);
      final codes = draft.issues.map((issue) => issue.code).toList();
      expect(codes, isNot(contains('missing_answer')));
    });

    test('preserves a slice whose materialized nodes are raw-only', () {
      final raw = rawFallback();
      final part = SourceContentPart(
        sourceRef: _docRef(),
        content: RichContent(nodes: <ContentNode>[
          const TextNode('前'),
          raw,
          const TextNode('尾'),
        ]),
      );
      final region = QuestionRegion(
        questionNumber: 1,
        fragments: <QuestionRegionFragment>[
          QuestionRegionFragment(
            field: QuestionRegionField.stem,
            part: part,
            slice: SourceSlice(
              startNodeIndex: 1,
              startCodeUnitOffset: 0,
              endNodeIndex: 2,
              endCodeUnitOffset: 0,
            ),
          ),
        ],
        kindHint: QuestionRegionKindHint.unknown,
      );
      final draft = assembler.assemble(region, questionId: 'q_raw_slice');

      expect(draft.stem.nodes, <ContentNode>[raw]);
      final codes = draft.issues.map((issue) => issue.code).toList();
      expect(codes, isNot(contains('missing_stem')));
    });
  });

  group('TypedQuestionAssembler fragment boundaries', () {
    test('keeps stable newline boundaries between stem fragments', () {
      final region = QuestionRegion(
        questionNumber: 1,
        fragments: <QuestionRegionFragment>[
          QuestionRegionFragment(
            field: QuestionRegionField.stem,
            part: _textPart('题干部分一'),
          ),
          QuestionRegionFragment(
            field: QuestionRegionField.stem,
            part: _textPart('A. 甲\nB. 乙\nC. 丙\nD. 丁'),
          ),
        ],
        kindHint: QuestionRegionKindHint.singleChoice,
      );
      final draft = assembler.assemble(region, questionId: 'q_1');

      expect((draft.stem.nodes.single as TextNode).text, '题干部分一');
      expect(
        draft.options.map((option) => option.optionId).toList(),
        <String>['A', 'B', 'C', 'D'],
      );
    });

    test('drops text-empty fragments like the legacy join', () {
      final region = QuestionRegion(
        questionNumber: 1,
        fragments: <QuestionRegionFragment>[
          QuestionRegionFragment(
            field: QuestionRegionField.stem,
            part: _textPart('题干'),
          ),
          QuestionRegionFragment(
            field: QuestionRegionField.stem,
            part: _textPart('   '),
          ),
          QuestionRegionFragment(
            field: QuestionRegionField.stem,
            part: _textPart('补充'),
          ),
        ],
        kindHint: QuestionRegionKindHint.shortAnswer,
      );
      final draft = assembler.assemble(region, questionId: 'q_1');

      expect(
        draft.stem.nodes.map((node) => (node as TextNode).text).toList(),
        <String>['题干', '\n', '补充'],
      );
      expect(draft.kind, QuestionKind.shortAnswer);
    });
  });

  group('TypedQuestionAssembler answer case parity', () {
    test('preserves non-choice answer case and keeps choice uppercased', () {
      final short = assembler.assemble(
        _region(
          stemText: 'Synthetic prompt marker 1.',
          answerText: 'synthetic-result-1',
          kindHint: QuestionRegionKindHint.shortAnswer,
        ),
        questionId: 'q_case_1',
      );
      expect(
        ((short.answer! as ContentAnswer).content.nodes.single as TextNode)
            .text,
        'synthetic-result-1',
      );

      final choice = assembler.assemble(
        _region(
          stemText: 'A. one\nB. two',
          answerText: 'a',
          kindHint: QuestionRegionKindHint.singleChoice,
        ),
        questionId: 'q_case_2',
      );
      expect(choice.answer, ChoiceAnswer(optionIds: <String>['A']));
    });
  });

  group('TypedQuestionAssembler issues and readiness', () {
    test('keeps region issues and adds policy issues without duplicates', () {
      final draft = assembler.assemble(
        _region(
          stemText: r'1. 题干 \(x',
          kindHint: QuestionRegionKindHint.singleChoice,
          issues: <ImportIssue>[
            ImportIssue(
              code: 'cross_page_region',
              severity: ImportIssueSeverity.warning,
              field: ImportIssueField.source,
            ),
          ],
        ),
        questionId: 'q_1',
      );
      final codes = draft.issues.map((issue) => issue.code).toList();
      expect(codes, contains('cross_page_region'));
      expect(codes, contains('dangling_latex'));
      expect(codes, contains('choice_options_less_than_2'));
      expect(codes, contains('missing_answer'));
    });

    test('marks empty regions as missing and non-ready', () {
      final region = QuestionRegion(
        questionNumber: 1,
        fragments: <QuestionRegionFragment>[
          QuestionRegionFragment(
            field: QuestionRegionField.stem,
            part: _textPart('   '),
          ),
        ],
        kindHint: QuestionRegionKindHint.unknown,
      );
      final draft = assembler.assemble(region, questionId: 'q_1');
      expect(draft.stem.nodes, isEmpty);
      expect(draft.kind, QuestionKind.shortAnswer);
      final codes = draft.issues.map((issue) => issue.code).toList();
      expect(
        codes,
        containsAll(
            <String>['empty_content', 'missing_stem', 'missing_answer']),
      );
    });
  });
}

QuestionRegion _region({
  required String stemText,
  String? answerText,
  String? explanationText,
  QuestionRegionKindHint kindHint = QuestionRegionKindHint.unknown,
  List<ImportIssue> issues = const <ImportIssue>[],
}) {
  return QuestionRegion(
    questionNumber: 1,
    fragments: <QuestionRegionFragment>[
      QuestionRegionFragment(
        field: QuestionRegionField.stem,
        part: _textPart(stemText),
      ),
      if (answerText != null)
        QuestionRegionFragment(
          field: QuestionRegionField.answer,
          part: _textPart(answerText),
        ),
      if (explanationText != null)
        QuestionRegionFragment(
          field: QuestionRegionField.explanation,
          part: _textPart(explanationText),
        ),
    ],
    kindHint: kindHint,
    issues: issues,
  );
}

SourceRef _docRef([String sourceId = 'source_a']) {
  return SourceRef.document(sourceId: sourceId);
}

SourceContentPart _textPart(String text, {SourceRef? ref}) {
  return SourceContentPart(
    sourceRef: ref ?? _docRef(),
    content: RichContent(nodes: <ContentNode>[TextNode(text)]),
  );
}

String _searchTextOf(List<ContentNode> nodes) {
  final buffer = StringBuffer();
  for (final node in nodes) {
    switch (node) {
      case TextNode(:final text):
        buffer.write(text);
      case InlineMathNode(:final latex):
        buffer.write(latex);
      case BlockMathNode(:final latex):
        buffer.write(latex);
      case ImageNode():
      case TableNode():
        break;
      case RawFallbackNode():
        break;
    }
  }
  return buffer.toString();
}

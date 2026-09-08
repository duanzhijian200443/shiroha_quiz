import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/domain/assets/asset_ref.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/import/import_issue.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/question/question_region.dart';
import 'package:shiroha_quiz/domain/source/source_document.dart';
import 'package:shiroha_quiz/domain/source/source_part.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/services/import_pipeline/adapters/ocr_source_document_adapter.dart';
import 'package:shiroha_quiz/services/import_pipeline/adapters/ocr_question_region_bridge.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_question_regionizer.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_rich_content_parser.dart';
import 'package:shiroha_quiz/services/import_pipeline/reference_answer_entry.dart';
import 'package:shiroha_quiz/services/import_pipeline/reference_answer_merger.dart';
import 'package:shiroha_quiz/services/import_pipeline/text_question_region.dart';
import 'package:shiroha_quiz/services/import_pipeline/typed_question_assembler.dart';

void main() {
  const bridge = OcrQuestionRegionBridge();

  group('OcrQuestionRegionBridge fields and order', () {
    test('bridges real regionizer and source-adapter output', () {
      final document = OcrDocument(
        sourceName: 'synthetic.pdf',
        markdown: '',
        rawResponses: const <Map<String, dynamic>>[],
        usage: const <String, dynamic>{},
        pages: const <OcrPage>[
          OcrPage(
            pageIndex: 1,
            blocks: <OcrBlock>[
              OcrBlock(
                blockId: 'p001_b0001',
                pageIndex: 1,
                type: 'text',
                text: '1 设函数 f，求其极值。',
                bbox: <double>[],
                readingOrder: 0,
              ),
            ],
          ),
          OcrPage(
            pageIndex: 2,
            blocks: <OcrBlock>[
              OcrBlock(
                blockId: 'p002_b0001',
                pageIndex: 2,
                type: 'text',
                text: '答案：42',
                bbox: <double>[],
                readingOrder: 0,
              ),
              OcrBlock(
                blockId: 'p002_b0002',
                pageIndex: 2,
                type: 'text',
                text: '解析：synthetic explanation',
                bbox: <double>[],
                readingOrder: 1,
              ),
            ],
          ),
        ],
      );
      final legacy = const OcrQuestionRegionizer().regionize(document);
      final sourceDocument = const OcrSourceDocumentAdapter().convert(
        document,
        sourceId: 'source_a',
        displayLabel: 'synthetic.pdf',
      );

      expect(legacy.regions, hasLength(1));
      final result = bridge.convert(
        legacy.regions.single,
        sourceDocument: sourceDocument,
      );

      expect(result.questionNumber, 1);
      expect(result.fragmentsFor(QuestionRegionField.stem), isNotEmpty);
      expect(result.fragmentsFor(QuestionRegionField.answer), isNotEmpty);
      expect(result.fragmentsFor(QuestionRegionField.explanation), isNotEmpty);
      expect(
          result.sourceRefs.every((ref) => ref.sourceId == 'source_a'), isTrue);
      expect(
        result.issues.map((issue) => issue.code),
        contains('legacy_provenance_coarse'),
      );
    });

    test('preserves typed parts from real OCR producer output', () {
      final document = OcrDocument(
        sourceName: 'synthetic.pdf',
        markdown: '',
        rawResponses: const <Map<String, dynamic>>[],
        usage: const <String, dynamic>{},
        pages: const <OcrPage>[
          OcrPage(
            pageIndex: 1,
            blocks: <OcrBlock>[
              OcrBlock(
                blockId: 'question',
                pageIndex: 1,
                type: 'text',
                text: '1 设函数 f，求其极值。',
                bbox: <double>[],
                readingOrder: 0,
              ),
              OcrBlock(
                blockId: 'formula',
                pageIndex: 1,
                type: 'formula',
                text: r'f(x)=x^2',
                bbox: <double>[],
                readingOrder: 1,
              ),
              OcrBlock(
                blockId: 'table',
                pageIndex: 1,
                type: 'table',
                text: 'synthetic table',
                bbox: <double>[],
                readingOrder: 2,
              ),
              OcrBlock(
                blockId: 'figure',
                pageIndex: 1,
                type: 'image',
                text: 'synthetic figure',
                bbox: <double>[],
                readingOrder: 3,
              ),
              OcrBlock(
                blockId: 'answer',
                pageIndex: 1,
                type: 'text',
                text: '答案：42',
                bbox: <double>[],
                readingOrder: 4,
              ),
            ],
          ),
        ],
      );
      final legacy = const OcrQuestionRegionizer().regionize(document);
      final sourceDocument = const OcrSourceDocumentAdapter().convert(
        document,
        sourceId: 'source_a',
        displayLabel: 'synthetic.pdf',
      );

      final result = bridge.convert(
        legacy.regions.single,
        sourceDocument: sourceDocument,
      );

      expect(
        result.fragments
            .map((fragment) => fragment.part)
            .whereType<SourceContentPart>()
            .map((part) => part.role),
        contains(SourceContentRole.formula),
      );
      expect(
        result.fragments
            .map((fragment) => fragment.part)
            .whereType<UnsupportedSourcePart>()
            .map((part) => part.kindCode),
        containsAllInOrder(const <String>['ocr_table', 'ocr_image']),
      );
    });

    test('block provenance wins over duplicate text and preserves mixed order',
        () {
      final parts = <SourcePart>[
        _blockPart(blockId: 'text_a', page: 1, readingOrder: 0, text: 'same'),
        SourceAssetPart(
          sourceRef: _blockRef(blockId: 'asset_a', page: 1, readingOrder: 1),
          asset: AssetRef(assetId: 'asset_a', kind: AssetKind.image),
        ),
        SourceContentPart(
          sourceRef: _blockRef(blockId: 'formula', page: 1, readingOrder: 2),
          content: RichContent(nodes: <ContentNode>[const BlockMathNode('x')]),
          role: SourceContentRole.formula,
        ),
        SourceAssetPart(
          sourceRef: _blockRef(blockId: 'asset_b', page: 1, readingOrder: 3),
          asset: AssetRef(assetId: 'asset_b', kind: AssetKind.image),
        ),
        _blockPart(blockId: 'text_b', page: 1, readingOrder: 4, text: 'same'),
      ];
      final result = bridge.convert(
        OcrQuestionRegion(
          number: 1,
          stemParts: const <String>['same', 'same'],
          answerParts: const <String>[],
          explanationParts: const <String>[],
          sourcePageIndices: const <int>[1],
          sourceBlockIds: const <String>[
            'text_a',
            'asset_a',
            'formula',
            'asset_b',
            'text_b',
          ],
          diagnostics: const <String>[],
          ownedSources: const <OcrQuestionRegionSource>[
            OcrQuestionRegionSource(
              blockId: 'text_a',
              field: OcrRegionField.stem,
            ),
            OcrQuestionRegionSource(
              blockId: 'asset_a',
              field: OcrRegionField.stem,
            ),
            OcrQuestionRegionSource(
              blockId: 'formula',
              field: OcrRegionField.stem,
            ),
            OcrQuestionRegionSource(
              blockId: 'asset_b',
              field: OcrRegionField.stem,
            ),
            OcrQuestionRegionSource(
              blockId: 'text_b',
              field: OcrRegionField.stem,
            ),
          ],
        ),
        sourceDocument: _document(parts),
      );

      expect(
        result.fragments.map((fragment) => fragment.part),
        <SourcePart>[
          parts[0],
          parts[1],
          parts[2],
          parts[3],
          parts[4],
        ],
      );
      expect(
        result.assetRefs.map((asset) => asset.localAssetId),
        <String>['asset_a', 'asset_b'],
      );
    });

    test('uses ownership slices without matching source text', () {
      final part = _blockPart(
        blockId: 'slice',
        page: 1,
        readingOrder: 0,
        text: 'abcdef',
      );
      final result = bridge.convert(
        OcrQuestionRegion(
          number: 1,
          stemParts: const <String>['bc'],
          answerParts: const <String>[],
          explanationParts: const <String>[],
          sourcePageIndices: const <int>[1],
          sourceBlockIds: const <String>['slice'],
          diagnostics: const <String>[],
          ownedSources: const <OcrQuestionRegionSource>[
            OcrQuestionRegionSource(
              blockId: 'slice',
              field: OcrRegionField.stem,
              startCodeUnitOffset: 1,
              endCodeUnitOffset: 3,
            ),
          ],
        ),
        sourceDocument: _document(<SourcePart>[part]),
      );

      expect(
        result.fragments.single.slice,
        SourceSlice(
          startNodeIndex: 0,
          startCodeUnitOffset: 1,
          endNodeIndex: 0,
          endCodeUnitOffset: 3,
        ),
      );
    });

    test('uses owned text only for a unique SourceSlice boundary', () {
      final part = _blockPart(
        blockId: 'slice_text',
        page: 1,
        readingOrder: 0,
        text: 'prefix body suffix',
      );
      final result = bridge.convert(
        _region(
          stemParts: const <String>['body'],
          sourceBlockIds: const <String>['slice_text'],
          ownedSources: const <OcrQuestionRegionSource>[
            OcrQuestionRegionSource(
              blockId: 'slice_text',
              field: OcrRegionField.stem,
              text: 'body',
            ),
          ],
        ),
        sourceDocument: _document(<SourcePart>[part]),
      );

      expect(
        result.fragments.single.slice,
        SourceSlice(
          startNodeIndex: 0,
          startCodeUnitOffset: 7,
          endNodeIndex: 0,
          endCodeUnitOffset: 11,
        ),
      );
    });

    test('keeps legitimate whole-part ownership with a null SourceSlice', () {
      final part = _blockPart(
        blockId: 'whole_part',
        page: 1,
        readingOrder: 0,
        text: 'whole owned stem',
      );
      final result = bridge.convert(
        _region(
          stemParts: const <String>['whole owned stem'],
          sourceBlockIds: const <String>['whole_part'],
          ownedSources: const <OcrQuestionRegionSource>[
            OcrQuestionRegionSource(
              blockId: 'whole_part',
              field: OcrRegionField.stem,
              startCodeUnitOffset: 0,
              endCodeUnitOffset: 16,
            ),
          ],
        ),
        sourceDocument: _document(<SourcePart>[part]),
      );

      expect(result.fragments.single.part, same(part));
      expect(result.fragments.single.slice, isNull);
      expect(_singleText(result.fragments.single), 'whole owned stem');
    });

    test('excludes unrelated structural blocks from the region', () {
      final owned = _blockPart(
        blockId: 'owned',
        page: 1,
        readingOrder: 0,
        text: 'owned',
      );
      final unrelatedAsset = SourceAssetPart(
        sourceRef:
            _blockRef(blockId: 'unrelated_asset', page: 1, readingOrder: 1),
        asset: AssetRef(assetId: 'unrelated', kind: AssetKind.image),
      );
      final unrelatedTable = SourceTablePart(
        sourceRef:
            _blockRef(blockId: 'unrelated_table', page: 1, readingOrder: 2),
        rows: <List<RichContent>>[
          <RichContent>[
            RichContent(nodes: <ContentNode>[const TextNode('x')])
          ],
        ],
      );
      final result = bridge.convert(
        _region(
          stemParts: const <String>['owned'],
          sourceBlockIds: const <String>['owned'],
          ownedSources: const <OcrQuestionRegionSource>[
            OcrQuestionRegionSource(
              blockId: 'owned',
              field: OcrRegionField.stem,
            ),
          ],
        ),
        sourceDocument: _document(<SourcePart>[
          owned,
          unrelatedAsset,
          unrelatedTable,
        ]),
      );

      expect(result.fragments, hasLength(1));
      expect(result.fragments.single.part, same(owned));
      expect(result.assetRefs, isEmpty);
    });

    test('fails closed for structural parts without block-native ownership',
        () {
      final tablePart = SourceTablePart(
        sourceRef: _blockRef(blockId: 'table', page: 1, readingOrder: 0),
        rows: <List<RichContent>>[
          <RichContent>[
            RichContent(nodes: <ContentNode>[const TextNode('cell')]),
          ],
        ],
      );
      final tableRegion = bridge.convert(
        _region(
          stemParts: const <String>['synthetic table'],
          sourceBlockIds: const <String>['table'],
        ),
        sourceDocument: _document(<SourcePart>[tablePart]),
      );
      expect(tableRegion.fragments, hasLength(1));
      expect(
        tableRegion.fragments.single.part,
        isA<UnsupportedSourcePart>().having(
          (part) => part.kindCode,
          'kindCode',
          'ocr_structural_ownership',
        ),
      );
      expect(tableRegion.assetRefs, isEmpty);

      final assetPart = SourceAssetPart(
        sourceRef: _blockRef(blockId: 'asset', page: 1, readingOrder: 0),
        asset: AssetRef(
          assetId: 'asset_1',
          kind: AssetKind.image,
          mimeType: 'image/png',
        ),
      );
      final assetRegion = bridge.convert(
        _region(
          stemParts: const <String>['synthetic figure'],
          sourceBlockIds: const <String>['asset'],
        ),
        sourceDocument: _document(<SourcePart>[assetPart]),
      );
      expect(assetRegion.fragments, hasLength(1));
      expect(
        assetRegion.fragments.single.part,
        isA<UnsupportedSourcePart>().having(
          (part) => part.kindCode,
          'kindCode',
          'ocr_structural_ownership',
        ),
      );
      expect(assetRegion.assetRefs, isEmpty);
    });

    test('fails closed when legacy text entries cannot own table and asset',
        () {
      final tablePart = SourceTablePart(
        sourceRef: _blockRef(blockId: 'table', page: 1, readingOrder: 0),
        rows: <List<RichContent>>[
          <RichContent>[
            RichContent(nodes: <ContentNode>[const TextNode('table cell')]),
          ],
        ],
      );
      final assetPart = SourceAssetPart(
        sourceRef: _blockRef(blockId: 'asset', page: 1, readingOrder: 1),
        asset: AssetRef(
          assetId: 'asset_1',
          kind: AssetKind.image,
          mimeType: 'image/png',
        ),
      );

      final result = bridge.convert(
        _region(
          stemParts: const <String>['unmatched formal stem'],
          sourceBlockIds: const <String>['table', 'asset'],
        ),
        sourceDocument: _document(<SourcePart>[tablePart, assetPart]),
      );

      expect(result.fragments, hasLength(1));
      expect(result.fragments.single.field, QuestionRegionField.stem);
      expect(
        result.fragments.single.part,
        isA<UnsupportedSourcePart>().having(
          (part) => part.kindCode,
          'kindCode',
          'ocr_structural_ownership',
        ),
      );
      expect(result.assetRefs, isEmpty);
      expect(
        result.issues.map((issue) => issue.code),
        contains('legacy_provenance_coarse'),
      );
      expect(
        () => const TypedQuestionAssembler().assemble(
          result,
          questionId: 'bridge_structural_ownership',
        ),
        throwsA(
          isA<QuestionRegionUnsupportedException>().having(
            (error) => error.kindCode,
            'kindCode',
            'ocr_structural_ownership',
          ),
        ),
      );
    });

    test('duplicate typed text cannot choose a structural part', () {
      final formulaPart = SourceContentPart(
        sourceRef: _blockRef(blockId: 'formula', page: 1, readingOrder: 0),
        content: RichContent(nodes: <ContentNode>[const TextNode('dup')]),
        role: SourceContentRole.formula,
      );
      final assetPart = SourceAssetPart(
        sourceRef: _blockRef(blockId: 'asset', page: 1, readingOrder: 1),
        asset: AssetRef(
          assetId: 'asset_1',
          kind: AssetKind.image,
        ),
        alternativeText:
            RichContent(nodes: <ContentNode>[const TextNode('dup')]),
      );

      final result = bridge.convert(
        _region(
          stemParts: const <String>['dup'],
          sourceBlockIds: const <String>['formula', 'asset'],
        ),
        sourceDocument: _document(<SourcePart>[formulaPart, assetPart]),
      );

      expect(result.fragments, hasLength(1));
      expect(
        result.fragments.single.part,
        isA<UnsupportedSourcePart>().having(
          (part) => part.kindCode,
          'kindCode',
          'ocr_structural_ownership',
        ),
      );
      expect(result.assetRefs, isEmpty);
      expect(
        result.issues.map((issue) => issue.code),
        contains('legacy_provenance_coarse'),
      );
    });

    test('does not pair a structural part with a legacy entry by position', () {
      final tablePart = SourceTablePart(
        sourceRef: _blockRef(blockId: 'table', page: 1, readingOrder: 0),
        rows: <List<RichContent>>[
          <RichContent>[
            RichContent(nodes: <ContentNode>[const TextNode('table cell')]),
          ],
        ],
      );
      final paragraphPart = SourceContentPart(
        sourceRef: _blockRef(blockId: 'text', page: 1, readingOrder: 1),
        content: RichContent(nodes: <ContentNode>[const TextNode('plain')]),
      );

      final result = bridge.convert(
        _region(
          stemParts: const <String>['table', 'plain'],
          sourceBlockIds: const <String>['table', 'text'],
        ),
        sourceDocument: _document(<SourcePart>[tablePart, paragraphPart]),
      );

      expect(result.fragments, hasLength(1));
      expect(
        result.fragments.single.part,
        isA<UnsupportedSourcePart>().having(
          (part) => part.kindCode,
          'kindCode',
          'ocr_structural_ownership',
        ),
      );
      expect(result.assetRefs, isEmpty);
    });

    test('partial ownership cannot guess the remaining structural field', () {
      final tablePart = SourceTablePart(
        sourceRef: _blockRef(blockId: 'table', page: 1, readingOrder: 0),
        rows: <List<RichContent>>[
          <RichContent>[
            RichContent(nodes: <ContentNode>[const TextNode('table cell')]),
          ],
        ],
      );
      final assetPart = SourceAssetPart(
        sourceRef: _blockRef(blockId: 'asset', page: 1, readingOrder: 1),
        asset: AssetRef(assetId: 'asset_1', kind: AssetKind.image),
      );

      final result = bridge.convert(
        _region(
          stemParts: const <String>['legacy stem'],
          sourceBlockIds: const <String>['table', 'asset'],
          ownedSources: const <OcrQuestionRegionSource>[
            OcrQuestionRegionSource(
              blockId: 'table',
              field: OcrRegionField.stem,
            ),
          ],
        ),
        sourceDocument: _document(<SourcePart>[tablePart, assetPart]),
      );

      expect(result.fragments, hasLength(1));
      expect(
        result.fragments.single.part,
        isA<UnsupportedSourcePart>().having(
          (part) => part.kindCode,
          'kindCode',
          'ocr_structural_ownership',
        ),
      );
      expect(result.assetRefs, isEmpty);
    });

    test('keeps per-list order and a fixed stem/answer/explanation order', () {
      final result = bridge.convert(
        OcrQuestionRegion(
          number: 1,
          stemParts: const <String>[' stem one ', '', 'stem two'],
          answerParts: const <String>['answer'],
          explanationParts: const <String>['explanation'],
          sourcePageIndices: const <int>[1],
          sourceBlockIds: const <String>['b1'],
          diagnostics: const <String>[],
        ),
        sourceDocument: _document(<SourcePart>[
          _blockPart(blockId: 'b1', page: 1, readingOrder: 0),
        ]),
      );

      expect(
        result.fragments.map((fragment) => fragment.field),
        <QuestionRegionField>[
          QuestionRegionField.stem,
          QuestionRegionField.stem,
          QuestionRegionField.answer,
          QuestionRegionField.explanation,
        ],
      );
      expect(
        result.fragments.map(_singleText),
        <String>['stem one', 'stem two', 'answer', 'explanation'],
      );
    });

    test('resolves a unique block to a precise block-level ref', () {
      final expectedRef = _blockRef(
        blockId: 'b1',
        page: 2,
        readingOrder: 4,
      );
      final result = bridge.convert(
        _region(
          stemParts: const <String>['stem'],
          answerParts: const <String>['answer'],
          sourceBlockIds: const <String>['b1'],
          sourcePageIndices: const <int>[2],
        ),
        sourceDocument: _document(<SourcePart>[
          _blockPart(blockId: 'b1', page: 2, readingOrder: 4),
        ]),
      );

      for (final fragment in result.fragments) {
        expect(fragment.sourceRef, expectedRef);
        expect(fragment.sourceRef.start!.blockId, 'b1');
      }
      expect(
        result.issues
            .where((issue) => issue.code == 'legacy_provenance_coarse'),
        isEmpty,
      );
    });

    test('resolves ordered multiple blocks to a range ref', () {
      final result = bridge.convert(
        _region(
          stemParts: const <String>['stem'],
          sourceBlockIds: const <String>['b1', 'b2', 'b3'],
          sourcePageIndices: const <int>[1, 2],
        ),
        sourceDocument: _document(<SourcePart>[
          _blockPart(blockId: 'b1', page: 1, readingOrder: 1),
          _blockPart(blockId: 'b2', page: 1, readingOrder: 2),
          _blockPart(blockId: 'b3', page: 2, readingOrder: 0),
        ]),
      );

      final ref = result.fragments.single.sourceRef;
      expect(ref.start!.blockId, 'b1');
      expect(ref.end!.blockId, 'b3');
      expect(ref.start!.pageNumber, 1);
      expect(ref.end!.pageNumber, 2);
      final coarse = result.issues
          .where((issue) => issue.code == 'legacy_provenance_coarse')
          .toList();
      expect(coarse, hasLength(1));
      expect(coarse.single.sourceRef, ref);
      expect(coarse.single.field, ImportIssueField.source);
    });
  });

  group('OcrQuestionRegionBridge provenance degradation', () {
    test('falls back to the document ref for missing block ids', () {
      final document = _document(<SourcePart>[
        _blockPart(blockId: 'b1', page: 1, readingOrder: 0),
      ]);
      final result = bridge.convert(
        _region(
          stemParts: const <String>['stem'],
          sourceBlockIds: const <String>['missing_block'],
        ),
        sourceDocument: document,
      );

      expect(result.fragments.single.sourceRef, document.documentRef);
      expect(
        result.issues,
        contains(
          ImportIssue(
            code: 'legacy_provenance_coarse',
            severity: ImportIssueSeverity.warning,
            field: ImportIssueField.source,
            sourceRef: document.documentRef,
          ),
        ),
      );
    });

    test('falls back when declared pages differ from matched ref pages', () {
      final document = _document(<SourcePart>[
        _blockPart(blockId: 'b1', page: 1, readingOrder: 0),
      ]);
      final result = bridge.convert(
        _region(
          stemParts: const <String>['stem'],
          sourceBlockIds: const <String>['b1'],
          sourcePageIndices: const <int>[2],
        ),
        sourceDocument: document,
      );

      expect(result.fragments.single.sourceRef, document.documentRef);
      expect(
        result.issues,
        contains(
          ImportIssue(
            code: 'legacy_provenance_coarse',
            severity: ImportIssueSeverity.warning,
            field: ImportIssueField.source,
            sourceRef: document.documentRef,
          ),
        ),
      );
    });

    test('falls back when one block id maps to multiple parts', () {
      final document = _document(<SourcePart>[
        _blockPart(blockId: 'b1', page: 1, readingOrder: 1),
        _blockPart(blockId: 'b1', page: 1, readingOrder: 2),
      ]);
      final result = bridge.convert(
        _region(
          stemParts: const <String>['stem'],
          sourceBlockIds: const <String>['b1'],
        ),
        sourceDocument: document,
      );

      expect(result.fragments.single.sourceRef, document.documentRef);
      expect(
        result.issues
            .where((issue) => issue.code == 'legacy_provenance_coarse'),
        hasLength(1),
      );
    });

    test('falls back when matched blocks cannot be ordered', () {
      final document = _document(<SourcePart>[
        _blockPart(blockId: 'b1', page: 1, readingOrder: 3),
        _blockPart(blockId: 'b2', page: 1, readingOrder: 3),
      ]);
      final result = bridge.convert(
        _region(
          stemParts: const <String>['stem'],
          sourceBlockIds: const <String>['b1', 'b2'],
        ),
        sourceDocument: document,
      );

      expect(result.fragments.single.sourceRef, document.documentRef);
      expect(
        result.issues
            .where((issue) => issue.code == 'legacy_provenance_coarse'),
        hasLength(1),
      );
    });
  });

  group('OcrQuestionRegionBridge reference evidence ownership', () {
    test('confirmed multi-block evidence does not duplicate local answer', () {
      final merged = const ReferenceAnswerMerger().merge(
        <OcrQuestionRegion>[
          OcrQuestionRegion(
            number: 1,
            stemParts: <String>['synthetic stem'],
            answerParts: <String>['local answer'],
            explanationParts: <String>[],
            sourcePageIndices: <int>[1],
            sourceBlockIds: <String>['question', 'local_answer'],
            diagnostics: <String>[],
            ownedSources: <OcrQuestionRegionSource>[
              OcrQuestionRegionSource(
                blockId: 'question',
                field: OcrRegionField.stem,
                text: 'synthetic stem',
              ),
              OcrQuestionRegionSource(
                blockId: 'local_answer',
                field: OcrRegionField.answer,
                text: 'local answer',
              ),
            ],
          ),
        ],
        ReferenceAnswerIndex(
          entries: <int, ReferenceAnswerEntry>{
            1: ReferenceAnswerEntry(
              questionNumber: 1,
              answerText: 'local   answer',
              sourcePageIndices: <int>[2],
              sourceBlockIds: <String>[
                'reference_1',
                'reference_2',
                'reference_3',
              ],
              patternKind: 'explicit_numbered',
            ),
          },
          conflictedNumbers: <int>{},
          diagnostics: <String, dynamic>{},
        ),
      ).single;
      final result = bridge.convert(
        merged,
        sourceDocument: _document(<SourcePart>[
          _blockPart(
            blockId: 'question',
            page: 1,
            readingOrder: 0,
            text: 'synthetic stem',
          ),
          _blockPart(
            blockId: 'local_answer',
            page: 1,
            readingOrder: 1,
            text: 'local answer',
          ),
          _blockPart(
            blockId: 'reference_1',
            page: 2,
            readingOrder: 0,
            text: 'reference evidence one',
          ),
          _blockPart(
            blockId: 'reference_2',
            page: 2,
            readingOrder: 1,
            text: 'reference evidence two',
          ),
          _blockPart(
            blockId: 'reference_3',
            page: 2,
            readingOrder: 2,
            text: 'reference evidence three',
          ),
        ]),
      );

      final answers = result.fragmentsFor(QuestionRegionField.answer);
      expect(answers, hasLength(1));
      expect(_singleText(answers.single), 'local answer');
      expect(
        result.sourceRefs.map((ref) => ref.start?.blockId).whereType<String>(),
        const <String>[
          'question',
          'local_answer',
          'reference_1',
          'reference_2',
          'reference_3',
        ],
      );
    });

    test('attached multi-block evidence creates one synthetic answer', () {
      final merged = const ReferenceAnswerMerger().merge(
        <OcrQuestionRegion>[
          OcrQuestionRegion(
            number: 1,
            stemParts: <String>['synthetic stem'],
            answerParts: <String>[],
            explanationParts: <String>[],
            sourcePageIndices: <int>[1],
            sourceBlockIds: <String>['question'],
            diagnostics: <String>['missing_answer'],
            ownedSources: <OcrQuestionRegionSource>[
              OcrQuestionRegionSource(
                blockId: 'question',
                field: OcrRegionField.stem,
                text: 'synthetic stem',
              ),
            ],
          ),
        ],
        ReferenceAnswerIndex(
          entries: <int, ReferenceAnswerEntry>{
            1: ReferenceAnswerEntry(
              questionNumber: 1,
              answerText: 'authoritative reference answer',
              sourcePageIndices: <int>[2],
              sourceBlockIds: <String>[
                'reference_1',
                'reference_2',
                'reference_3',
              ],
              patternKind: 'explicit_numbered',
            ),
          },
          conflictedNumbers: <int>{},
          diagnostics: <String, dynamic>{},
        ),
      ).single;
      final result = bridge.convert(
        merged,
        sourceDocument: _document(<SourcePart>[
          _blockPart(
            blockId: 'question',
            page: 1,
            readingOrder: 0,
            text: 'synthetic stem',
          ),
          _blockPart(
            blockId: 'reference_1',
            page: 2,
            readingOrder: 0,
            text: 'reference evidence one',
          ),
          _blockPart(
            blockId: 'reference_2',
            page: 2,
            readingOrder: 1,
            text: 'reference evidence two',
          ),
          _blockPart(
            blockId: 'reference_3',
            page: 2,
            readingOrder: 2,
            text: 'reference evidence three',
          ),
        ]),
      );

      final answers = result.fragmentsFor(QuestionRegionField.answer);
      expect(answers, hasLength(1));
      expect(_singleText(answers.single), 'authoritative reference answer');
      expect(answers.single.sourceRef.start, isNull,
          reason: 'synthetic answer is not attributed to an evidence block');
      final draft = const TypedQuestionAssembler().assemble(
        result,
        questionId: 'question_1',
      );
      final answer = draft.answer as ContentAnswer;
      expect((answer.content.nodes.single as TextNode).text,
          'authoritative reference answer');
      expect(
        result.sourceRefs.map((ref) => ref.start?.blockId).whereType<String>(),
        const <String>[
          'question',
          'reference_1',
          'reference_2',
          'reference_3',
        ],
      );
    });

    test('reference-only structural evidence is not product content', () {
      final merged = const ReferenceAnswerMerger().merge(
        <OcrQuestionRegion>[
          OcrQuestionRegion(
            number: 1,
            stemParts: <String>['synthetic stem'],
            answerParts: <String>['local answer'],
            explanationParts: <String>[],
            sourcePageIndices: <int>[1],
            sourceBlockIds: <String>['question', 'local_answer'],
            diagnostics: <String>[],
            ownedSources: <OcrQuestionRegionSource>[
              OcrQuestionRegionSource(
                blockId: 'question',
                field: OcrRegionField.stem,
                text: 'synthetic stem',
              ),
              OcrQuestionRegionSource(
                blockId: 'local_answer',
                field: OcrRegionField.answer,
                text: 'local answer',
              ),
            ],
          ),
        ],
        ReferenceAnswerIndex(
          entries: <int, ReferenceAnswerEntry>{
            1: ReferenceAnswerEntry(
              questionNumber: 1,
              answerText: 'different reference answer',
              sourcePageIndices: <int>[2],
              sourceBlockIds: <String>['reference_asset'],
              patternKind: 'explicit_numbered',
            ),
          },
          conflictedNumbers: <int>{},
          diagnostics: <String, dynamic>{},
        ),
      ).single;
      final result = bridge.convert(
        merged,
        sourceDocument: _document(<SourcePart>[
          _blockPart(
            blockId: 'question',
            page: 1,
            readingOrder: 0,
            text: 'synthetic stem',
          ),
          _blockPart(
            blockId: 'local_answer',
            page: 1,
            readingOrder: 1,
            text: 'local answer',
          ),
          SourceAssetPart(
            sourceRef: _blockRef(
              blockId: 'reference_asset',
              page: 2,
              readingOrder: 0,
            ),
            asset: AssetRef(
              assetId: 'reference_asset',
              kind: AssetKind.image,
            ),
          ),
        ]),
      );

      expect(result.fragments, hasLength(2));
      expect(
        result.fragments.map((fragment) => fragment.part),
        everyElement(isA<SourceContentPart>()),
      );
      expect(result.assetRefs, isEmpty);
      expect(
        result.sourceRefs.map((ref) => ref.start?.blockId),
        const <String>['question', 'local_answer', 'reference_asset'],
      );
    });
  });

  group('OcrQuestionRegionBridge kind and diagnostics', () {
    test('maps the effective kind to its frozen hint', () {
      final cases = <(TextQuestionKind, QuestionRegionKindHint)>[
        (TextQuestionKind.choice, QuestionRegionKindHint.singleChoice),
        (TextQuestionKind.multiChoice, QuestionRegionKindHint.multipleChoice),
        (TextQuestionKind.trueFalse, QuestionRegionKindHint.trueFalse),
        (TextQuestionKind.fillBlank, QuestionRegionKindHint.fillBlank),
        (TextQuestionKind.subjective, QuestionRegionKindHint.shortAnswer),
      ];

      for (final (declared, expected) in cases) {
        final result = bridge.convert(
          _region(
            stemParts: const <String>['stem'],
            declaredKind: declared,
          ),
          sourceDocument: _document(<SourcePart>[
            _blockPart(blockId: 'b1', page: 1, readingOrder: 0),
          ]),
        );
        expect(result.kindHint, expected, reason: declared.name);
      }

      final detected = bridge.convert(
        _region(stemParts: const <String>['A. one\nB. two']),
        sourceDocument: _document(<SourcePart>[
          _blockPart(blockId: 'b1', page: 1, readingOrder: 0),
        ]),
      );
      expect(detected.kindHint, QuestionRegionKindHint.singleChoice);
    });

    test('maps the known diagnostic whitelist with stable severities', () {
      final result = bridge.convert(
        _region(
          stemParts: const <String>['stem'],
          diagnostics: const <String>[
            'attached_numbered_field_in_current_region',
            'attached_numbered_field_candidate',
            'contains_formula_block',
            'contains_table_block',
            'cross_page_region',
            'missing_stem',
            'missing_answer',
            'reference_answer_attached',
            'reference_answer_confirmed',
            'reference_answer_conflict',
            'reference_answer_duplicate_conflict',
            'reference_answer_pattern:explicit_numbered',
          ],
        ),
        sourceDocument: _document(<SourcePart>[
          _blockPart(blockId: 'b1', page: 1, readingOrder: 0),
        ]),
      );

      final codes = result.issues.map((issue) => issue.code).toList();
      expect(
        codes,
        containsAll(const <String>[
          'attached_numbered_field_in_current_region',
          'attached_numbered_field_candidate',
          'contains_formula_block',
          'contains_table_block',
          'cross_page_region',
          'missing_stem',
          'missing_answer',
          'reference_answer_attached',
          'reference_answer_confirmed',
          'reference_answer_conflict',
          'reference_answer_duplicate_conflict',
          'reference_answer_pattern',
        ]),
      );
      expect(
        result.issues
            .where(
              (issue) => const <String>{
                'reference_answer_attached',
                'reference_answer_confirmed',
                'reference_answer_pattern',
              }.contains(issue.code),
            )
            .every((issue) => issue.severity == ImportIssueSeverity.info),
        isTrue,
      );
      expect(
        result.issues
            .where((issue) => issue.code == 'missing_stem')
            .single
            .field,
        ImportIssueField.stem,
      );
      expect(
        result.issues
            .where((issue) => issue.code == 'reference_answer_conflict')
            .single
            .field,
        ImportIssueField.answer,
      );
      expect(
        result.issues
            .where((issue) => issue.code == 'contains_table_block')
            .single
            .field,
        ImportIssueField.stem,
      );
      expect(
        result.issues
            .where((issue) => issue.code == 'cross_page_region')
            .single
            .field,
        ImportIssueField.source,
      );
    });

    test('de-parameterizes kind diagnostics and collapses unknown ones', () {
      final result = bridge.convert(
        _region(
          stemParts: const <String>['stem'],
          diagnostics: const <String>[
            'kind_declared_from_section:choice',
            'kind_inferred_from_question_number_range:fillBlank',
            'weird_legacy_diagnostic',
            'another_weird_legacy',
          ],
        ),
        sourceDocument: _document(<SourcePart>[
          _blockPart(blockId: 'b1', page: 1, readingOrder: 0),
        ]),
      );

      final codes = result.issues.map((issue) => issue.code).toList();
      expect(
        codes,
        containsAll(const <String>[
          'kind_declared_from_section',
          'kind_inferred_from_question_number_range',
          'legacy_region_diagnostic',
        ]),
      );
      expect(
        codes.where((code) => code == 'legacy_region_diagnostic'),
        hasLength(1),
      );
      expect(
        codes.any(
          (code) =>
              code.contains(':') ||
              code.contains('weird') ||
              code.contains('another'),
        ),
        isFalse,
      );
    });

    test('preserves reference-answer merger diagnostics as stable codes', () {
      final merged = const ReferenceAnswerMerger().merge(
        <OcrQuestionRegion>[
          OcrQuestionRegion(
            number: 1,
            stemParts: <String>['synthetic stem'],
            answerParts: <String>[],
            explanationParts: <String>[],
            sourcePageIndices: <int>[1],
            sourceBlockIds: <String>['question'],
            diagnostics: <String>['missing_answer'],
          ),
        ],
        ReferenceAnswerIndex(
          entries: <int, ReferenceAnswerEntry>{
            1: ReferenceAnswerEntry(
              questionNumber: 1,
              answerText: 'synthetic answer',
              sourcePageIndices: <int>[2],
              sourceBlockIds: <String>['reference'],
              patternKind: 'explicit_numbered',
            ),
          },
          conflictedNumbers: <int>{},
          diagnostics: <String, dynamic>{},
        ),
      ).single;
      final result = bridge.convert(
        merged,
        sourceDocument: _document(<SourcePart>[
          _blockPart(
            blockId: 'question',
            page: 1,
            readingOrder: 0,
            text: 'synthetic stem',
          ),
          _blockPart(
            blockId: 'reference',
            page: 2,
            readingOrder: 0,
            text: 'synthetic answer',
          ),
        ]),
      );

      final attached = result.issues.singleWhere(
        (issue) => issue.code == 'reference_answer_attached',
      );
      final pattern = result.issues.singleWhere(
        (issue) => issue.code == 'reference_answer_pattern',
      );
      expect(attached.field, ImportIssueField.answer);
      expect(attached.severity, ImportIssueSeverity.info);
      expect(pattern.field, ImportIssueField.answer);
      expect(pattern.severity, ImportIssueSeverity.info);
      expect(
        result.issues.map((issue) => issue.code),
        isNot(contains('legacy_region_diagnostic')),
      );
    });
  });

  group('OcrQuestionRegionBridge readiness and safety', () {
    test('requires a missing stem warning when no stem fragment exists', () {
      final result = bridge.convert(
        _region(
          stemParts: const <String>[],
          answerParts: const <String>['answer'],
        ),
        sourceDocument: _document(<SourcePart>[
          _blockPart(blockId: 'b1', page: 1, readingOrder: 0),
        ]),
      );

      expect(result.fragmentsFor(QuestionRegionField.stem), isEmpty);
      expect(
        result.issues,
        contains(
          ImportIssue(
            code: 'missing_stem',
            severity: ImportIssueSeverity.warning,
            field: ImportIssueField.stem,
            sourceRef: result.fragments.single.sourceRef,
          ),
        ),
      );
      expect(result.readiness, QuestionRegionReadiness.needsReview);
    });

    test('keeps a completely empty region constructible and non-ready', () {
      final result = bridge.convert(
        OcrQuestionRegion(
          number: 5,
          stemParts: const <String>[],
          answerParts: const <String>[],
          explanationParts: const <String>[],
          sourcePageIndices: const <int>[],
          sourceBlockIds: const <String>[],
          diagnostics: const <String>[],
        ),
        sourceDocument: _document(<SourcePart>[
          _blockPart(blockId: 'b1', page: 1, readingOrder: 0),
        ]),
      );

      expect(result.fragments, hasLength(1));
      final fragment = result.fragments.single;
      expect(fragment.field, QuestionRegionField.stem);
      expect(fragment.part, isA<SourceContentPart>());
      expect((fragment.part as SourceContentPart).content.nodes, isEmpty);
      expect(fragment.part.sourceRef.start, isNull);
      final codes = result.issues.map((issue) => issue.code).toList();
      expect(
        codes,
        containsAll(const <String>[
          'legacy_provenance_coarse',
          'missing_stem',
        ]),
      );
      expect(codes, isNot(contains('legacy_region_risky')));
      expect(result.readiness, QuestionRegionReadiness.needsReview);
    });

    test('derives missing_answer when the producer omits the diagnostic', () {
      final result = bridge.convert(
        _region(stemParts: const <String>['stem only']),
        sourceDocument: _document(<SourcePart>[
          _blockPart(blockId: 'b1', page: 1, readingOrder: 0),
        ]),
      );

      expect(
        result.issues,
        contains(
          ImportIssue(
            code: 'missing_answer',
            severity: ImportIssueSeverity.warning,
            field: ImportIssueField.answer,
            sourceRef: result.fragments.single.sourceRef,
          ),
        ),
      );
      expect(
        result.issues.where((issue) => issue.code == 'legacy_region_risky'),
        isEmpty,
      );
      expect(result.readiness, QuestionRegionReadiness.needsReview);
    });

    test('does not mutate legacy inputs and is repeatable', () {
      final stemParts = <String>['stem'];
      final answerParts = <String>['answer'];
      final explanationParts = <String>['explanation'];
      final sourceBlockIds = <String>['b1'];
      final diagnostics = <String>['missing_answer', 'mystery_diag'];
      final region = OcrQuestionRegion(
        number: 9,
        stemParts: stemParts,
        answerParts: answerParts,
        explanationParts: explanationParts,
        sourcePageIndices: const <int>[1],
        sourceBlockIds: sourceBlockIds,
        diagnostics: diagnostics,
      );
      final document = _document(<SourcePart>[
        _blockPart(blockId: 'b1', page: 1, readingOrder: 0),
      ]);

      final first = bridge.convert(region, sourceDocument: document);
      final second = bridge.convert(region, sourceDocument: document);

      expect(identical(region.stemParts, stemParts), isTrue);
      expect(identical(region.answerParts, answerParts), isTrue);
      expect(identical(region.explanationParts, explanationParts), isTrue);
      expect(identical(region.sourceBlockIds, sourceBlockIds), isTrue);
      expect(identical(region.diagnostics, diagnostics), isTrue);
      expect(second, first);
    });
  });

  group('OcrQuestionRegionBridge structural math ownership completeness', () {
    test(
        'real Q1 geometry with multi-block sourceIds and partial math ownership (Regression 1)',
        () {
      final map = OcrMathSourceMap();
      final blocks = <({String id, int order, String text})>[
        (
          id: 'p001_b0002',
          order: 2,
          text: r'1. 设 $ \lim_{x\rightarrow 1}\frac{f(x)}{\ln x}=1 $ ，则（ ）',
        ),
        (
          id: 'p001_b0003',
          order: 3,
          text: r'A. $ f(1)=0. $',
        ),
        (
          id: 'p001_b0004',
          order: 4,
          text: r'B. $ \lim_{x\rightarrow 1}f(x)=0. $',
        ),
        (
          id: 'p001_b0005',
          order: 5,
          text: r'C. $ f^{\prime}(1)=1. $',
        ),
        (
          id: 'p001_b0006',
          order: 6,
          text: r'D. $ \lim_{x\rightarrow 1}f^{\prime}(x)=1. $',
        ),
        (
          id: 'p001_b0007',
          order: 7,
          text: '本题主要考查极限与导数的概念.',
        ),
        (
          id: 'p001_b0008',
          order: 8,
          text:
              r'本题中关于 f(x)的条件相当有限，仅有 $ \lim_{x\to 1}\frac{f(x)}{\ln x}=1 $这一个条件.',
        ),
        (
          id: 'p001_b0009',
          order: 9,
          text:
              r'当 $ x\to 1 $时， $ \lim_{x\to 1}\ln x=0 $ ，故分子 f(x)满足 $ \lim_{x\to 1}f(x)=0 $ .应选B.',
        ),
        (
          id: 'p001_b0010',
          order: 10,
          text: r'洛必达法则：$$\lim _ {x \rightarrow 1} \frac {f (x)}{\ln x} = 1$$',
        ),
        (
          id: 'p001_b0011',
          order: 11,
          text: r'考虑分段函数 $ f ( x ) $ 在 $ x=1 $ 处不可导.',
        ),
        (
          id: 'p001_b0012',
          order: 12,
          text: r'不难发现， $ x=1 $ 是间断点， $ \lim_{x\to 1}f^{\prime}(x) $ 不存在.',
        ),
      ];

      final parts = <SourcePart>[
        for (final b in blocks)
          SourceContentPart(
            sourceRef: _blockRef(blockId: b.id, page: 1, readingOrder: b.order),
            content: map.parse(b.text),
          ),
      ];

      final stemText = r'设 $ \lim_{x\rightarrow 1}\frac{f(x)}{\ln x}=1 $ ，则（ ）';
      final region = OcrQuestionRegion(
        number: 1,
        stemParts: <String>[stemText],
        answerParts: const <String>[],
        explanationParts: const <String>[],
        sourcePageIndices: const <int>[1],
        sourceBlockIds: blocks.map((b) => b.id).toList(growable: false),
        diagnostics: const <String>['contains_formula_block'],
        ownedSources: <OcrQuestionRegionSource>[
          OcrQuestionRegionSource(
            blockId: 'p001_b0002',
            field: OcrRegionField.stem,
            text: stemText,
          ),
        ],
      );

      final result = bridge.convert(
        region,
        sourceDocument: _document(parts),
        mathSourceMap: map,
      );

      expect(result.fragments, hasLength(1));
      expect(result.fragments.single.field, QuestionRegionField.stem);
      expect(result.fragments.single.part, isNot(isA<UnsupportedSourcePart>()));
      expect(result.fragments.single.part, same(parts.first));
      expect(result.fragments.single.slice, isNotNull);

      final materialized = materializeQuestionRegionContent(
        (result.fragments.single.part as SourceContentPart).content,
        result.fragments.single.slice,
      );
      final inlineMath = materialized.whereType<InlineMathNode>().toList();
      expect(inlineMath, hasLength(1));
      expect(inlineMath.single.latex,
          r' \lim_{x\rightarrow 1}\frac{f(x)}{\ln x}=1 ');
      expect(
        identical(
          inlineMath.single,
          (parts.first as SourceContentPart)
              .content
              .nodes
              .whereType<InlineMathNode>()
              .single,
        ),
        isTrue,
      );
    });

    test(
        'unowned inline math outside slice is legal for sliceable paragraph (Regression 2)',
        () {
      const raw = r'A $x$ B';
      final map = OcrMathSourceMap();
      final parsed = map.parse(raw);
      expect(parsed.nodes, [
        const TextNode('A '),
        const InlineMathNode('x'),
        const TextNode(' B'),
      ]);
      final document = _document(<SourcePart>[
        SourceContentPart(
          sourceRef: _blockRef(blockId: 'b1', page: 1, readingOrder: 0),
          content: parsed,
        ),
      ]);
      final region = _region(
        stemParts: const <String>['A '],
        sourceBlockIds: const <String>['b1'],
        ownedSources: const <OcrQuestionRegionSource>[
          OcrQuestionRegionSource(
            blockId: 'b1',
            field: OcrRegionField.stem,
            startCodeUnitOffset: 0,
            endCodeUnitOffset: 2,
          ),
        ],
      );
      final result = bridge.convert(
        region,
        sourceDocument: document,
        mathSourceMap: map,
      );
      expect(result.fragments, hasLength(1));
      expect(result.fragments.single.field, QuestionRegionField.stem);
      expect(result.fragments.single.part, isNot(isA<UnsupportedSourcePart>()));
      expect(result.fragments.single.part, same(document.parts.single));
      expect(result.fragments.single.slice, isNotNull);

      final materialized = materializeQuestionRegionContent(
        (result.fragments.single.part as SourceContentPart).content,
        result.fragments.single.slice,
      );
      expect(materialized, [const TextNode('A ')]);
    });

    test('owned math remains atomic and preserves identity (Regression 3)', () {
      const raw = r'A $x$ B';
      final map = OcrMathSourceMap();
      final parsed = map.parse(raw);
      final document = _document(<SourcePart>[
        SourceContentPart(
          sourceRef: _blockRef(blockId: 'b1', page: 1, readingOrder: 0),
          content: parsed,
        ),
      ]);
      final region = _region(
        stemParts: const <String>[r'A $x$'],
        sourceBlockIds: const <String>['b1'],
        ownedSources: const <OcrQuestionRegionSource>[
          OcrQuestionRegionSource(
            blockId: 'b1',
            field: OcrRegionField.stem,
            startCodeUnitOffset: 0,
            endCodeUnitOffset: 5,
          ),
        ],
      );
      final result = bridge.convert(
        region,
        sourceDocument: document,
        mathSourceMap: map,
      );
      expect(result.fragments, hasLength(1));
      expect(result.fragments.single.field, QuestionRegionField.stem);
      expect(result.fragments.single.part, isNot(isA<UnsupportedSourcePart>()));

      final materialized = materializeQuestionRegionContent(
        (result.fragments.single.part as SourceContentPart).content,
        result.fragments.single.slice,
      );
      expect(materialized, [const TextNode('A '), const InlineMathNode('x')]);
      expect(
        identical(materialized[1], parsed.nodes[1]),
        isTrue,
      );
    });

    test('math interior slice must fail closed (Regression 4)', () {
      const raw = r'A $x$ B';
      final map = OcrMathSourceMap();
      final parsed = map.parse(raw);
      final document = _document(<SourcePart>[
        SourceContentPart(
          sourceRef: _blockRef(blockId: 'b1', page: 1, readingOrder: 0),
          content: parsed,
        ),
      ]);
      // MathNode 'x' is at [2, 5). Offset 3 is interior.
      final region = _region(
        stemParts: const <String>[r'A $'],
        sourceBlockIds: const <String>['b1'],
        ownedSources: const <OcrQuestionRegionSource>[
          OcrQuestionRegionSource(
            blockId: 'b1',
            field: OcrRegionField.stem,
            startCodeUnitOffset: 0,
            endCodeUnitOffset: 3,
          ),
        ],
      );
      final result = bridge.convert(
        region,
        sourceDocument: document,
        mathSourceMap: map,
      );
      expect(result.fragments, hasLength(1));
      expect(
        result.fragments.single.part,
        isA<UnsupportedSourcePart>().having(
          (part) => part.kindCode,
          'kindCode',
          'ocr_structural_ownership',
        ),
      );
    });

    test(
        'complete non-overlapping ownership covering all math nodes remains valid across fields (Regression B)',
        () {
      const raw = r'1. $x$ 答案：$y$';
      final map = OcrMathSourceMap();
      final parsed = map.parse(raw);
      final boundary = raw.indexOf('答案');
      final document = _document(<SourcePart>[
        SourceContentPart(
          sourceRef: _blockRef(blockId: 'b1', page: 1, readingOrder: 0),
          content: parsed,
        ),
      ]);
      final region = _region(
        stemParts: <String>[raw.substring(0, boundary)],
        answerParts: <String>[raw.substring(boundary)],
        sourceBlockIds: const <String>['b1'],
        ownedSources: <OcrQuestionRegionSource>[
          OcrQuestionRegionSource(
            blockId: 'b1',
            field: OcrRegionField.stem,
            startCodeUnitOffset: 0,
            endCodeUnitOffset: boundary,
          ),
          OcrQuestionRegionSource(
            blockId: 'b1',
            field: OcrRegionField.answer,
            startCodeUnitOffset: boundary,
            endCodeUnitOffset: raw.length,
          ),
        ],
      );
      final result = bridge.convert(
        region,
        sourceDocument: document,
        mathSourceMap: map,
      );
      expect(result.fragments, hasLength(2));
      final stemFragment = result.fragments[0];
      final answerFragment = result.fragments[1];
      expect(stemFragment.field, QuestionRegionField.stem);
      expect(answerFragment.field, QuestionRegionField.answer);
      final stemNodes = materializeQuestionRegionContent(
        (stemFragment.part as SourceContentPart).content,
        stemFragment.slice,
      );
      final answerNodes = materializeQuestionRegionContent(
        (answerFragment.part as SourceContentPart).content,
        answerFragment.slice,
      );
      expect(stemNodes.whereType<InlineMathNode>().single.latex, 'x');
      expect(answerNodes.whereType<InlineMathNode>().single.latex, 'y');
      final originalMath = parsed.nodes.whereType<InlineMathNode>().toList();
      expect(
        identical(
            stemNodes.whereType<InlineMathNode>().single, originalMath[0]),
        isTrue,
      );
      expect(
        identical(
            answerNodes.whereType<InlineMathNode>().single, originalMath[1]),
        isTrue,
      );
    });

    test(
        'missing map with partial mixed-math ownership fails closed (Regression C)',
        () {
      final mixedContent = RichContent(nodes: <ContentNode>[
        const TextNode('A '),
        const InlineMathNode('x'),
        const TextNode(' B'),
      ]);
      final document = _document(<SourcePart>[
        SourceContentPart(
          sourceRef: _blockRef(blockId: 'b1', page: 1, readingOrder: 0),
          content: mixedContent,
        ),
      ]);
      final region = _region(
        stemParts: const <String>['A '],
        sourceBlockIds: const <String>['b1'],
        ownedSources: const <OcrQuestionRegionSource>[
          OcrQuestionRegionSource(
            blockId: 'b1',
            field: OcrRegionField.stem,
            startCodeUnitOffset: 0,
            endCodeUnitOffset: 2,
          ),
        ],
      );
      final result = bridge.convert(
        region,
        sourceDocument: document,
        mathSourceMap: null,
      );
      expect(result.fragments, hasLength(1));
      expect(
        result.fragments.single.part,
        isA<UnsupportedSourcePart>().having(
          (part) => part.kindCode,
          'kindCode',
          'ocr_structural_ownership',
        ),
      );
    });

    test(
        'missing map with proven whole-part formula ownership remains valid (Regression D)',
        () {
      final formulaPart = SourceContentPart(
        sourceRef: _blockRef(blockId: 'formula', page: 1, readingOrder: 0),
        content: RichContent(nodes: <ContentNode>[const BlockMathNode('x^2')]),
        role: SourceContentRole.formula,
      );
      final document = _document(<SourcePart>[formulaPart]);
      final region = _region(
        stemParts: const <String>['x^2'],
        sourceBlockIds: const <String>['formula'],
        ownedSources: const <OcrQuestionRegionSource>[
          OcrQuestionRegionSource(
            blockId: 'formula',
            field: OcrRegionField.stem,
          ),
        ],
      );
      final result = bridge.convert(
        region,
        sourceDocument: document,
        mathSourceMap: null,
      );
      expect(result.fragments, hasLength(1));
      expect(result.fragments.single.part, same(formulaPart));
      expect(result.fragments.single.slice, isNull);
      final materialized = materializeQuestionRegionContent(
        (result.fragments.single.part as SourceContentPart).content,
        result.fragments.single.slice,
      );
      expect(materialized, [const BlockMathNode('x^2')]);
    });

    test(
        'formula role content part with text prefix preserves structural ownership (Regression E)',
        () {
      const raw = r'洛必达法则：$$\lim_{x\to 1}f(x)=1$$';
      final map = OcrMathSourceMap();
      final parsed = map.parse(raw, formula: true);
      final formulaPart = SourceContentPart(
        sourceRef: _blockRef(blockId: 'p001_b0010', page: 1, readingOrder: 10),
        content: parsed,
        role: SourceContentRole.formula,
      );
      final document = _document(<SourcePart>[formulaPart]);
      final region = _region(
        stemParts: const <String>[raw],
        sourceBlockIds: const <String>['p001_b0010'],
        diagnostics: const <String>['contains_formula_block'],
        ownedSources: const <OcrQuestionRegionSource>[
          OcrQuestionRegionSource(
            blockId: 'p001_b0010',
            field: OcrRegionField.stem,
            startCodeUnitOffset: 0,
            endCodeUnitOffset: 29,
          ),
        ],
      );
      final result = bridge.convert(
        region,
        sourceDocument: document,
        mathSourceMap: map,
      );
      expect(result.fragments, hasLength(1));
      expect(result.fragments.single.part, isNot(isA<UnsupportedSourcePart>()));
      expect(result.fragments.single.part, same(formulaPart));
      expect(result.fragments.single.slice, isNotNull);

      final materialized = materializeQuestionRegionContent(
        (result.fragments.single.part as SourceContentPart).content,
        result.fragments.single.slice,
      );
      expect(materialized, [
        const TextNode('洛必达法则：'),
        const BlockMathNode(r'\lim_{x\to 1}f(x)=1'),
      ]);
    });
  });
}

OcrQuestionRegion _region({
  List<String> stemParts = const <String>[],
  List<String> answerParts = const <String>[],
  List<String> explanationParts = const <String>[],
  List<String> sourceBlockIds = const <String>['b1'],
  List<int> sourcePageIndices = const <int>[1],
  List<String> diagnostics = const <String>[],
  TextQuestionKind declaredKind = TextQuestionKind.unknown,
  List<OcrQuestionRegionSource> ownedSources =
      const <OcrQuestionRegionSource>[],
}) {
  return OcrQuestionRegion(
    number: 1,
    stemParts: stemParts,
    answerParts: answerParts,
    explanationParts: explanationParts,
    sourcePageIndices: sourcePageIndices,
    sourceBlockIds: sourceBlockIds,
    diagnostics: diagnostics,
    declaredKind: declaredKind,
    ownedSources: ownedSources,
  );
}

SourceDocument _document(List<SourcePart> parts) {
  return SourceDocument(
    sourceId: 'source_a',
    displayLabel: 'paper.pdf',
    parts: parts,
  );
}

SourcePart _blockPart({
  required String blockId,
  required int page,
  required int readingOrder,
  String text = 'block text',
}) {
  return SourceContentPart(
    sourceRef: _blockRef(
      blockId: blockId,
      page: page,
      readingOrder: readingOrder,
    ),
    content: RichContent(nodes: <ContentNode>[TextNode(text)]),
  );
}

SourceRef _blockRef({
  required String blockId,
  required int page,
  required int readingOrder,
}) {
  return SourceRef.at(
    sourceId: 'source_a',
    displayLabel: 'paper.pdf',
    point: SourcePoint.block(
      pageNumber: page,
      blockId: blockId,
      readingOrder: readingOrder,
    ),
  );
}

String _singleText(QuestionRegionFragment fragment) {
  final part = fragment.part as SourceContentPart;
  return (part.content.nodes.single as TextNode).text;
}

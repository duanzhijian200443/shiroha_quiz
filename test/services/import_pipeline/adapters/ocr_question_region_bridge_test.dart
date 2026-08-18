import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/domain/assets/asset_ref.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/import/import_issue.dart';
import 'package:shiroha_quiz/domain/question/question_region.dart';
import 'package:shiroha_quiz/domain/source/source_document.dart';
import 'package:shiroha_quiz/domain/source/source_part.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/services/import_pipeline/adapters/ocr_source_document_adapter.dart';
import 'package:shiroha_quiz/services/import_pipeline/adapters/ocr_question_region_bridge.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_question_regionizer.dart';
import 'package:shiroha_quiz/services/import_pipeline/reference_answer_entry.dart';
import 'package:shiroha_quiz/services/import_pipeline/reference_answer_merger.dart';
import 'package:shiroha_quiz/services/import_pipeline/text_question_region.dart';

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
        containsAllInOrder(const <String>['ocr_table_invalid', 'ocr_image']),
      );
    });

    test('preserves one-to-one table and asset parts without text projection',
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
      expect(tableRegion.fragments.single.part, same(tablePart));

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
      expect(assetRegion.fragments.single.part, same(assetPart));
      expect(assetRegion.assetRefs.single.localAssetId, 'asset_1');
    });

    test('degrades instead of throwing when typed parts cannot be preserved',
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
      final fragment = result.fragments.single;
      expect(fragment.field, QuestionRegionField.stem);
      expect(fragment.part, isA<SourceContentPart>());
      expect(fragment.part, isNot(same(tablePart)));
      expect(_singleText(fragment), 'unmatched formal stem');
      expect(
        result.issues,
        contains(
          ImportIssue(
            code: 'legacy_provenance_coarse',
            severity: ImportIssueSeverity.warning,
            field: ImportIssueField.source,
            sourceRef: fragment.sourceRef,
          ),
        ),
      );
    });

    test('degrades instead of throwing on ambiguous typed text', () {
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
      expect(_singleText(result.fragments.single), 'dup');
      expect(
        result.issues,
        contains(
          ImportIssue(
            code: 'legacy_provenance_coarse',
            severity: ImportIssueSeverity.warning,
            field: ImportIssueField.source,
            sourceRef: result.fragments.single.sourceRef,
          ),
        ),
      );
    });

    test('pairs one typed part and degrades leftover entries', () {
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

      expect(result.fragments, hasLength(2));
      expect(result.fragments[0].part, same(tablePart));
      expect(_singleText(result.fragments[1]), 'plain');
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
}

OcrQuestionRegion _region({
  List<String> stemParts = const <String>[],
  List<String> answerParts = const <String>[],
  List<String> explanationParts = const <String>[],
  List<String> sourceBlockIds = const <String>['b1'],
  List<int> sourcePageIndices = const <int>[1],
  List<String> diagnostics = const <String>[],
  TextQuestionKind declaredKind = TextQuestionKind.unknown,
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

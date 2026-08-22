import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/domain/assets/asset_ref.dart';
import 'package:shiroha_quiz/domain/assets/sourced_asset_ref.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/import/import_issue.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/question/question_region.dart';
import 'package:shiroha_quiz/domain/source/source_document.dart';
import 'package:shiroha_quiz/domain/source/source_part.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/services/import_pipeline/adapters/ocr_question_region_bridge.dart';
import 'package:shiroha_quiz/services/import_pipeline/adapters/text_question_region_bridge.dart';
import 'package:shiroha_quiz/services/import_pipeline/local_question_assembler.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_question_assembler.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_question_regionizer.dart';
import 'package:shiroha_quiz/services/import_pipeline/question_draft_v2_legacy_projection.dart';
import 'package:shiroha_quiz/services/import_pipeline/text_question_region.dart';
import 'package:shiroha_quiz/services/import_pipeline/typed_question_assembler.dart';

const projector = QuestionDraftV2LegacyProjector();
const assembler = TypedQuestionAssembler();

void main() {
  group('Text profile parity with LocalQuestionAssembler', () {
    test('projects a subjective region to the identical legacy map', () {
      final legacy = TextQuestionRegion(
        number: 1,
        rawText: '1. 设函数 f(x)，求值。',
        startOffset: 0,
        endOffset: 10,
        answerText: '42',
        kind: TextQuestionKind.subjective,
        health: RegionHealth.clean,
      );
      final projected = _projectText(legacy);
      final expected = const LocalQuestionAssembler().assemble(legacy);

      expect(projected.question, expected.question);
      expect(projected.repairRecommended, expected.repairRecommended);
      expect(projected.rejected, expected.rejected);
    });

    test('keeps lowercase subjective answer parity with the text legacy path',
        () {
      final legacy = TextQuestionRegion(
        number: 2,
        rawText: '2. Synthetic prompt marker.',
        startOffset: 0,
        endOffset: 27,
        answerText: 'synthetic-result',
        kind: TextQuestionKind.subjective,
        health: RegionHealth.clean,
      );
      final projected = _projectText(legacy);
      final expected = const LocalQuestionAssembler().assemble(legacy);

      expect(expected.question['standard_answer'], 'SYNTHETIC-RESULT');
      expect(projected.question, expected.question);
      expect(projected.repairRecommended, expected.repairRecommended);
      expect(projected.rejected, expected.rejected);
    });

    test('keeps repair parity for a short-content choice region', () {
      final legacy = TextQuestionRegion(
        number: 3,
        rawText: '3. 甲\nA. 甲选项内容\nB. 乙选项内容\nC. 丙选项内容\nD. 丁选项内容',
        startOffset: 0,
        endOffset: 40,
        kind: TextQuestionKind.choice,
        health: RegionHealth.clean,
      );
      final projected = _projectText(legacy);
      final expected = const LocalQuestionAssembler().assemble(legacy);

      expect(projected.repairRecommended, isTrue);
      expect(projected.question, expected.question);
      expect(projected.repairRecommended, expected.repairRecommended);
      expect(projected.rejected, expected.rejected);
    });

    test('reports dropped non-subjective explanation with the legacy code', () {
      final legacy = TextQuestionRegion(
        number: 2,
        rawText: '2. 题干\nA. 甲\nB. 乙\n解析：因为题干。',
        startOffset: 0,
        endOffset: 20,
        kind: TextQuestionKind.choice,
        health: RegionHealth.clean,
      );
      final projected = _projectText(legacy);

      expect(projected.question['type'], 0);
      expect(
        projected.question['source'],
        TextLegacyProjectionProfile.sourceTagValue,
      );
      expect(projected.question['explanation'], '');
      expect(projected.question['raw_explanation'], '因为题干。');
      expect(projected.question['options'], <String>['A. 甲', 'B. 乙']);
      expect(
        projected.diagnostics,
        contains('dropped_non_subjective_explanation'),
      );
      expect(projected.diagnostics, contains('missing_answer'));
    });
  });

  group('OCR profile parity with OcrQuestionAssembler', () {
    test('projects a cross-page choice region to the identical legacy map', () {
      final legacy = OcrQuestionRegion(
        number: 1,
        stemParts: <String>['1. 题干\nA. 甲\nB. 乙\nC. 丙\nD. 丁'],
        answerParts: <String>['A'],
        explanationParts: <String>['解析：因为题干。'],
        sourcePageIndices: <int>[1, 2],
        sourceBlockIds: <String>['b1', 'b2'],
        diagnostics: const <String>[],
        declaredKind: TextQuestionKind.choice,
      );
      final projected = _projectOcr(legacy);
      final expected = const OcrQuestionAssembler().assemble(legacy);

      expect(projected.question, expected.question);
      expect(projected.repairRecommended, isTrue);
      expect(projected.repairRecommended, expected.repairRecommended);
      expect(projected.rejected, expected.rejected);
    });

    test('drops options for non-choice kinds with the legacy diagnostics', () {
      final legacy = OcrQuestionRegion(
        number: 2,
        stemParts: <String>['2. 简述理由\nA. 甲\nB. 乙\nC. 丙\nD. 丁'],
        answerParts: <String>['因为题干。'],
        explanationParts: const <String>[],
        sourcePageIndices: <int>[1],
        sourceBlockIds: <String>['b1'],
        diagnostics: const <String>[],
        declaredKind: TextQuestionKind.subjective,
      );
      final projected = _projectOcr(legacy);
      final expected = const OcrQuestionAssembler().assemble(legacy);

      expect(projected.question, expected.question);
      expect(projected.question['options'], isEmpty);
      expect(
        projected.diagnostics,
        containsAll(<String>[
          'type_constrained_by_region:subjective',
          'ignored_options_due_to_region_type',
        ]),
      );
      expect(projected.repairRecommended, expected.repairRecommended);
      expect(projected.rejected, expected.rejected);
    });

    test('matches the legacy OCR map for multiple stem parts', () {
      final legacy = OcrQuestionRegion(
        number: 1,
        stemParts: <String>['1. 题干部分一', 'A. 甲\nB. 乙\nC. 丙\nD. 丁'],
        answerParts: <String>['A'],
        explanationParts: const <String>[],
        sourcePageIndices: <int>[1],
        sourceBlockIds: <String>['b1', 'b2'],
        diagnostics: const <String>[],
        declaredKind: TextQuestionKind.choice,
      );
      final projected = _projectOcr(legacy);
      final expected = const OcrQuestionAssembler().assemble(legacy);

      expect(projected.question['content'], '题干部分一');
      expect(projected.question['options'], <String>[
        'A. 甲',
        'B. 乙',
        'C. 丙',
        'D. 丁',
      ]);
      expect(projected.question, expected.question);
      expect(projected.repairRecommended, expected.repairRecommended);
      expect(projected.rejected, expected.rejected);
    });

    test('drops incomplete A/B options like the legacy OCR assembler', () {
      final legacy = OcrQuestionRegion(
        number: 3,
        stemParts: <String>['3. 题干\nA. 甲\nB. 乙'],
        answerParts: <String>['A'],
        explanationParts: const <String>[],
        sourcePageIndices: <int>[1],
        sourceBlockIds: <String>['b1'],
        diagnostics: const <String>[],
        declaredKind: TextQuestionKind.choice,
      );
      final projected = _projectOcr(legacy);
      final expected = const OcrQuestionAssembler().assemble(legacy);

      expect(projected.question['type'], 0);
      expect(projected.question['content'], '题干\nA. 甲\nB. 乙');
      expect(projected.question['options'], isEmpty);
      expect(projected.question, expected.question);
      expect(projected.repairRecommended, expected.repairRecommended);
      expect(projected.rejected, expected.rejected);
    });

    test(
        'keeps the legacy OCR map for an incomplete A/B sequence with an '
        'unknown kind', () {
      final legacy = OcrQuestionRegion(
        number: 1,
        stemParts: <String>['题干\nA. 甲\nB. 乙'],
        answerParts: <String>['A'],
        explanationParts: const <String>[],
        sourcePageIndices: <int>[1],
        sourceBlockIds: <String>['b1'],
        diagnostics: const <String>[],
        declaredKind: TextQuestionKind.unknown,
      );
      final blockRef = SourceRef.at(
        sourceId: 'source_a',
        displayLabel: 'paper.pdf',
        point: SourcePoint.block(
          pageNumber: 1,
          blockId: 'b1',
          readingOrder: 0,
        ),
      );
      final region = QuestionRegion(
        questionNumber: 1,
        fragments: <QuestionRegionFragment>[
          QuestionRegionFragment(
            field: QuestionRegionField.stem,
            part: SourceContentPart(
              sourceRef: blockRef,
              content: RichContent(
                nodes: <ContentNode>[const TextNode('题干\nA. 甲\nB. 乙')],
              ),
            ),
          ),
          QuestionRegionFragment(
            field: QuestionRegionField.answer,
            part: SourceContentPart(
              sourceRef: blockRef,
              content: RichContent(nodes: <ContentNode>[const TextNode('A')]),
            ),
          ),
        ],
        kindHint: QuestionRegionKindHint.unknown,
      );
      final draft = assembler.assemble(region, questionId: 'task_q1');
      // The typed parser accepts the A/B pair...
      expect(
        draft.options.map((option) => option.optionId).toList(),
        <String>['A', 'B'],
      );
      final projected = projector.project(
        draft: draft,
        region: region,
        profile: const OcrLegacyProjectionProfile(),
      );
      final expected = const OcrQuestionAssembler().assemble(legacy);

      expect(projected.question['type'], 3);
      expect(projected.question['content'], '题干\nA. 甲\nB. 乙');
      expect(projected.question['options'], isEmpty);
      expect(projected.question, expected.question);
      expect(projected.repairRecommended, expected.repairRecommended);
      expect(projected.rejected, expected.rejected);
    });

    test('falls back to composed raw text and rejects empty regions', () {
      final region = QuestionRegion(
        questionNumber: 5,
        fragments: <QuestionRegionFragment>[
          QuestionRegionFragment(
            field: QuestionRegionField.stem,
            part: SourceContentPart(
              sourceRef: SourceRef.document(sourceId: 'source_a'),
              content: RichContent(nodes: const <ContentNode>[]),
            ),
          ),
        ],
        kindHint: QuestionRegionKindHint.unknown,
        issues: <ImportIssue>[
          ImportIssue(
            code: 'missing_stem',
            severity: ImportIssueSeverity.warning,
            field: ImportIssueField.stem,
          ),
          ImportIssue(
            code: 'missing_answer',
            severity: ImportIssueSeverity.warning,
            field: ImportIssueField.answer,
          ),
        ],
      );
      final draft = assembler.assemble(region, questionId: 'task_q5');
      final projected = projector.project(
        draft: draft,
        region: region,
        profile: const OcrLegacyProjectionProfile(),
      );

      expect(projected.question['content'], '5');
      expect(projected.question['q_num'], '5');
      expect(projected.rejected, isTrue);
      expect(projected.repairRecommended, isTrue);
      expect(
        projected.diagnostics,
        containsAll(
            <String>['empty_content', 'missing_answer', 'missing_stem']),
      );
    });
  });

  group('Text profile fragment and option parity', () {
    test('keeps the >=2 option behavior for an A/B sequence', () {
      final legacy = TextQuestionRegion(
        number: 4,
        rawText: '4. 题干\nA. 甲\nB. 乙',
        startOffset: 0,
        endOffset: 12,
        answerText: 'A',
        kind: TextQuestionKind.choice,
        health: RegionHealth.clean,
      );
      final projected = _projectText(legacy);
      final expected = const LocalQuestionAssembler().assemble(legacy);

      expect(projected.question['type'], 0);
      expect(projected.question['content'], '题干');
      expect(projected.question['options'], <String>['A. 甲', 'B. 乙']);
      expect(projected.question, expected.question);
      expect(projected.repairRecommended, expected.repairRecommended);
      expect(projected.rejected, expected.rejected);
    });
  });

  group('Projector source slices', () {
    test('projects only the selected UTF-16 interval on both profiles', () {
      final part = SourceContentPart(
        sourceRef: SourceRef.document(sourceId: 'source_a'),
        content: RichContent(nodes: <ContentNode>[
          const TextNode('前😀段'),
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
              endNodeIndex: 2,
              endCodeUnitOffset: 0,
            ),
          ),
          QuestionRegionFragment(
            field: QuestionRegionField.answer,
            part: part,
            slice: SourceSlice(
              startNodeIndex: 2,
              startCodeUnitOffset: 0,
              endNodeIndex: 3,
              endCodeUnitOffset: 0,
            ),
          ),
        ],
        kindHint: QuestionRegionKindHint.shortAnswer,
      );
      final draft = assembler.assemble(region, questionId: 'task_q1');

      final ocr = projector.project(
        draft: draft,
        region: region,
        profile: const OcrLegacyProjectionProfile(),
      );
      expect(ocr.question['content'], '😀段f(x)=x^2');
      expect(ocr.question['content'], isNot(contains('前')));
      expect(ocr.question['content'], isNot(contains('尾段')));
      expect(ocr.question['standard_answer'], '尾段');

      final text = projector.project(
        draft: draft,
        region: region,
        profile: const TextLegacyProjectionProfile(),
      );
      expect(text.question['content'], '😀段f(x)=x^2');
      expect(text.question['content'], isNot(contains('前')));
      expect(text.question['content'], isNot(contains('尾段')));
    });
  });

  group('Profiles', () {
    test('carry the frozen source tags and distinct map keys', () {
      final region = QuestionRegion(
        questionNumber: 1,
        fragments: <QuestionRegionFragment>[
          QuestionRegionFragment(
            field: QuestionRegionField.stem,
            part: SourceContentPart(
              sourceRef: SourceRef.document(sourceId: 'source_a'),
              content: RichContent(nodes: <ContentNode>[const TextNode('题干')]),
            ),
          ),
        ],
        kindHint: QuestionRegionKindHint.shortAnswer,
      );
      final draft = assembler.assemble(region, questionId: 'task_q1');

      final textResult = projector.project(
        draft: draft,
        region: region,
        profile: const TextLegacyProjectionProfile(),
      );
      expect(textResult.question['source'], 'docx_text_deterministic');
      expect(textResult.question.containsKey('q_num'), isFalse);
      expect(textResult.question.containsKey('source_page_indices'), isFalse);
      expect(textResult.question['content'], '题干');

      final ocrResult = projector.project(
        draft: draft,
        region: region,
        profile: const OcrLegacyProjectionProfile(),
      );
      expect(ocrResult.question['source'], 'glm_ocr_intermediate');
      expect(ocrResult.question['q_num'], '1');
      expect(ocrResult.question['source_page_indices'], <int>[]);
      expect(ocrResult.question['source_block_ids'], <String>[]);
    });
  });

  group('Projector raw fallback explicit stop', () {
    RawFallbackNode rawFallback() {
      return RawFallbackNode(<Object?, Object?>{
        'type': 'raw_fallback',
        'payload': <Object?, Object?>{'kind': 'span'},
      });
    }

    test('fails explicitly on both profiles instead of dropping raw content',
        () {
      final raw = rawFallback();
      final region = QuestionRegion(
        questionNumber: 1,
        fragments: <QuestionRegionFragment>[
          QuestionRegionFragment(
            field: QuestionRegionField.stem,
            part: SourceContentPart(
              sourceRef: SourceRef.document(sourceId: 'source_a'),
              content: RichContent(nodes: <ContentNode>[raw]),
            ),
          ),
        ],
        kindHint: QuestionRegionKindHint.unknown,
      );
      final draft = assembler.assemble(region, questionId: 'task_q_raw');
      expect(draft.stem.nodes, <ContentNode>[raw]);

      for (final profile in <LegacyProjectionProfile>[
        const TextLegacyProjectionProfile(),
        const OcrLegacyProjectionProfile(),
      ]) {
        expect(
          () => projector.project(
            draft: draft,
            region: region,
            profile: profile,
          ),
          throwsA(
            isA<LegacyProjectionUnsupportedException>()
                .having((error) => error.kindCode, 'kindCode', 'raw_fallback'),
          ),
        );
      }
    });

    test('fails explicitly for raw fallback mixed into answer content', () {
      final raw = rawFallback();
      final region = QuestionRegion(
        questionNumber: 1,
        fragments: <QuestionRegionFragment>[
          QuestionRegionFragment(
            field: QuestionRegionField.stem,
            part: SourceContentPart(
              sourceRef: SourceRef.document(sourceId: 'source_a'),
              content: RichContent(nodes: <ContentNode>[const TextNode('题干')]),
            ),
          ),
          QuestionRegionFragment(
            field: QuestionRegionField.answer,
            part: SourceContentPart(
              sourceRef: SourceRef.document(sourceId: 'source_a'),
              content: RichContent(nodes: <ContentNode>[raw]),
            ),
          ),
        ],
        kindHint: QuestionRegionKindHint.shortAnswer,
      );
      final draft = assembler.assemble(region, questionId: 'task_q_raw_answer');

      expect(
        () => projector.project(
          draft: draft,
          region: region,
          profile: const TextLegacyProjectionProfile(),
        ),
        throwsA(
          isA<LegacyProjectionUnsupportedException>()
              .having((error) => error.kindCode, 'kindCode', 'raw_fallback'),
        ),
      );
    });
  });

  group('Projector boundary guards', () {
    SourceRef blockRef() {
      return SourceRef.at(
        sourceId: 'source_a',
        displayLabel: 'paper.pdf',
        point: SourcePoint.block(
          pageNumber: 1,
          blockId: 'b1',
          readingOrder: 0,
        ),
      );
    }

    QuestionRegion simpleRegion() {
      return QuestionRegion(
        questionNumber: 1,
        fragments: <QuestionRegionFragment>[
          QuestionRegionFragment(
            field: QuestionRegionField.stem,
            part: SourceContentPart(
              sourceRef: blockRef(),
              content: RichContent(
                nodes: <ContentNode>[const TextNode('stem text')],
              ),
            ),
          ),
        ],
        kindHint: QuestionRegionKindHint.shortAnswer,
      );
    }

    QuestionDraftV2 matchingDraft(QuestionRegion region) {
      return QuestionDraftV2(
        questionId: 'task_q1',
        kind: QuestionKind.shortAnswer,
        questionNumber: region.questionNumber,
        stem: RichContent(nodes: <ContentNode>[const TextNode('stem text')]),
        sourceRefs: region.sourceRefs,
        issues: region.issues,
      );
    }

    void expectUnsupported(
      QuestionDraftV2 draft,
      QuestionRegion region,
      String kindCode,
    ) {
      expect(
        () => projector.project(
          draft: draft,
          region: region,
          profile: const TextLegacyProjectionProfile(),
        ),
        throwsA(
          isA<LegacyProjectionUnsupportedException>()
              .having((error) => error.kindCode, 'kindCode', kindCode),
        ),
      );
    }

    test('does not reject an extra declared source-qualified asset by itself',
        () {
      final region = simpleRegion();
      final base = assembler.assemble(region, questionId: 'task_q1');
      final draft = QuestionDraftV2(
        questionId: base.questionId,
        kind: base.kind,
        questionNumber: base.questionNumber,
        stem: base.stem,
        options: base.options,
        answer: base.answer,
        explanation: base.explanation,
        sourceRefs: base.sourceRefs,
        assetRefs: <SourcedAssetRef>[
          SourcedAssetRef(
            sourceId: 'source_a',
            asset: AssetRef(assetId: 'img_1', kind: AssetKind.image),
          ),
        ],
        issues: base.issues,
      );
      final projected = projector.project(
        draft: draft,
        region: region,
        profile: const TextLegacyProjectionProfile(),
      );

      expect(projected.question['content'], 'stem text');
      expect(projected.question['standard_answer'], '');
    });

    test('projects image alternative text and placeholder without identities',
        () {
      final region = simpleRegion();
      final base = assembler.assemble(region, questionId: 'task_q1');
      final sourceQualifiedAsset = SourcedAssetRef(
        sourceId: 'source_a',
        asset: AssetRef(assetId: 'asset_1', kind: AssetKind.image),
      );
      final draft = QuestionDraftV2(
        questionId: base.questionId,
        kind: base.kind,
        questionNumber: base.questionNumber,
        stem: RichContent(nodes: <ContentNode>[
          const TextNode('before '),
          ImageNode(
            sourceId: 'source_a',
            localAssetId: 'asset_1',
            alternativeText: RichContent(nodes: const <ContentNode>[
              TextNode('safe alt'),
            ]),
          ),
          ImageNode(sourceId: 'source_a', localAssetId: 'asset_1'),
          const TextNode(' after'),
        ]),
        options: base.options,
        answer: base.answer,
        explanation: base.explanation,
        sourceRefs: base.sourceRefs,
        assetRefs: <SourcedAssetRef>[sourceQualifiedAsset],
        issues: base.issues,
      );
      final projected = projector.project(
        draft: draft,
        region: region,
        profile: const TextLegacyProjectionProfile(),
      );
      final content = projected.question['content']! as String;

      expect(content, 'before safe alt[图片] after');
      expect(content, isNot(contains('source_a')));
      expect(content, isNot(contains('asset_1')));
    });

    test('projects table geometry, spans, and image cells safely', () {
      final region = simpleRegion();
      final base = assembler.assemble(region, questionId: 'task_q1');
      final table = TableNode(
        structure: TableStructure(rows: <TableRow>[
          TableRow(cells: <TableCell>[
            TableCell(
              content: RichContent(nodes: const <ContentNode>[TextNode('A')]),
              rowSpan: 2,
            ),
            TableCell(
              content: RichContent(nodes: const <ContentNode>[TextNode('B')]),
              columnSpan: 2,
            ),
          ]),
          TableRow(cells: <TableCell>[
            TableCell(
              content: RichContent(nodes: <ContentNode>[
                ImageNode(sourceId: 'source_a', localAssetId: 'asset_1'),
              ]),
            ),
            TableCell(content: RichContent(nodes: const <ContentNode>[])),
          ]),
        ]),
      );
      final draft = QuestionDraftV2(
        questionId: base.questionId,
        kind: base.kind,
        questionNumber: base.questionNumber,
        stem: RichContent(nodes: <ContentNode>[table]),
        options: base.options,
        answer: base.answer,
        explanation: base.explanation,
        sourceRefs: base.sourceRefs,
        assetRefs: <SourcedAssetRef>[
          SourcedAssetRef(
            sourceId: 'source_a',
            asset: AssetRef(assetId: 'asset_1', kind: AssetKind.image),
          ),
        ],
        issues: base.issues,
      );
      final projected = projector.project(
        draft: draft,
        region: region,
        profile: const TextLegacyProjectionProfile(),
      );
      final content = projected.question['content']! as String;

      expect(content, 'A | B | \n | [图片] |');
      expect(content, isNot(contains('source_a')));
      expect(content, isNot(contains('asset_1')));
      expect(content, isNot(contains('{')));
      expect(content, isNot(contains('<table')));
    });

    test('rejects SourceAssetPart fragments instead of ignoring them', () {
      final region = QuestionRegion(
        questionNumber: 1,
        fragments: <QuestionRegionFragment>[
          QuestionRegionFragment(
            field: QuestionRegionField.stem,
            part: SourceAssetPart(
              sourceRef: blockRef(),
              asset: AssetRef(assetId: 'img_1', kind: AssetKind.image),
            ),
          ),
        ],
        kindHint: QuestionRegionKindHint.shortAnswer,
      );
      expectUnsupported(matchingDraft(region), region, 'source_asset');
    });

    test('rejects SourceTablePart fragments instead of ignoring them', () {
      final region = QuestionRegion(
        questionNumber: 1,
        fragments: <QuestionRegionFragment>[
          QuestionRegionFragment(
            field: QuestionRegionField.stem,
            part: SourceTablePart(
              sourceRef: blockRef(),
              rows: <Iterable<RichContent>>[
                <RichContent>[
                  RichContent(nodes: <ContentNode>[const TextNode('cell')]),
                ],
              ],
            ),
          ),
        ],
        kindHint: QuestionRegionKindHint.shortAnswer,
      );
      expectUnsupported(matchingDraft(region), region, 'source_table');
    });

    test('rejects UnsupportedSourcePart fragments with their kind code', () {
      final region = QuestionRegion(
        questionNumber: 1,
        fragments: <QuestionRegionFragment>[
          QuestionRegionFragment(
            field: QuestionRegionField.stem,
            part: UnsupportedSourcePart(
              sourceRef: blockRef(),
              kindCode: 'unknown_rich',
              fallbackContent: RichContent(
                nodes: <ContentNode>[const TextNode('preserved text')],
              ),
            ),
          ),
        ],
        kindHint: QuestionRegionKindHint.shortAnswer,
      );
      expectUnsupported(matchingDraft(region), region, 'unknown_rich');
    });

    test('rejects a draft/region question-number mismatch', () {
      final region = simpleRegion();
      final base = assembler.assemble(region, questionId: 'task_q1');
      final draft = QuestionDraftV2(
        questionId: base.questionId,
        kind: base.kind,
        questionNumber: 2,
        stem: base.stem,
        options: base.options,
        answer: base.answer,
        explanation: base.explanation,
        sourceRefs: base.sourceRefs,
        issues: base.issues,
      );
      expectUnsupported(draft, region, 'draft_region_mismatch');
    });

    test('rejects a reordered draft sourceRefs', () {
      final region = QuestionRegion(
        questionNumber: 1,
        fragments: <QuestionRegionFragment>[
          QuestionRegionFragment(
            field: QuestionRegionField.stem,
            part: _blockPart('b1', 1, 0, 'stem text'),
          ),
          QuestionRegionFragment(
            field: QuestionRegionField.answer,
            part: _blockPart('b2', 1, 1, 'answer text'),
          ),
        ],
        kindHint: QuestionRegionKindHint.shortAnswer,
      );
      final draft = matchingDraft(region);
      final reordered = QuestionDraftV2(
        questionId: draft.questionId,
        kind: draft.kind,
        questionNumber: draft.questionNumber,
        stem: draft.stem,
        options: draft.options,
        answer: draft.answer,
        explanation: draft.explanation,
        sourceRefs: <SourceRef>[region.sourceRefs[1], region.sourceRefs[0]],
        issues: draft.issues,
      );
      expectUnsupported(reordered, region, 'draft_region_mismatch');
    });
  });

  group('Projector provenance degradation contract', () {
    test('locks the three-block range degradation with the coarse diagnostic',
        () {
      final legacy = OcrQuestionRegion(
        number: 1,
        stemParts: const <String>['q1'],
        answerParts: const <String>[],
        explanationParts: const <String>[],
        sourcePageIndices: const <int>[1, 2],
        sourceBlockIds: const <String>['b1', 'b2', 'b3'],
        diagnostics: const <String>[],
        declaredKind: TextQuestionKind.subjective,
      );
      final sourceDocument = SourceDocument(
        sourceId: 'source_a',
        displayLabel: 'paper.pdf',
        parts: <SourcePart>[
          _blockPart('b1', 1, 0, 'x1'),
          _blockPart('b2', 1, 1, 'x2'),
          _blockPart('b3', 2, 0, 'x3'),
        ],
      );
      final region = const OcrQuestionRegionBridge().convert(
        legacy,
        sourceDocument: sourceDocument,
      );
      final draft = assembler.assemble(region, questionId: 'task_q1');
      final projected = projector.project(
        draft: draft,
        region: region,
        profile: const OcrLegacyProjectionProfile(),
      );

      expect(projected.question['source_block_ids'], <String>['b1', 'b3']);
      expect(projected.question['source_page_indices'], <int>[1, 2]);
    });

    test('locks the document-coarse degradation with the coarse diagnostic',
        () {
      final region = QuestionRegion(
        questionNumber: 1,
        fragments: <QuestionRegionFragment>[
          QuestionRegionFragment(
            field: QuestionRegionField.stem,
            part: SourceContentPart(
              sourceRef: SourceRef.document(sourceId: 'source_a'),
              content: RichContent(nodes: <ContentNode>[const TextNode('题干')]),
            ),
          ),
        ],
        kindHint: QuestionRegionKindHint.shortAnswer,
        issues: <ImportIssue>[
          ImportIssue(
            code: 'legacy_provenance_coarse',
            severity: ImportIssueSeverity.warning,
            field: ImportIssueField.source,
          ),
        ],
      );
      final draft = assembler.assemble(region, questionId: 'task_q1');
      final projected = projector.project(
        draft: draft,
        region: region,
        profile: const OcrLegacyProjectionProfile(),
      );

      expect(projected.question['source_page_indices'], isEmpty);
      expect(projected.question['source_block_ids'], isEmpty);
    });

    test('keeps legacy_provenance_coarse in the assembled draft issues', () {
      final legacy = OcrQuestionRegion(
        number: 1,
        stemParts: const <String>['1. stem text'],
        answerParts: const <String>[],
        explanationParts: const <String>[],
        sourcePageIndices: const <int>[1],
        sourceBlockIds: const <String>['missing_b1'],
        diagnostics: const <String>[],
        declaredKind: TextQuestionKind.subjective,
      );
      final sourceDocument = SourceDocument(
        sourceId: 'source_a',
        displayLabel: 'paper.pdf',
        parts: <SourcePart>[
          _blockPart('b1', 1, 0, '1. stem text'),
        ],
      );
      final region = const OcrQuestionRegionBridge().convert(
        legacy,
        sourceDocument: sourceDocument,
      );
      final draft = assembler.assemble(region, questionId: 'task_q1');

      expect(
        draft.issues.map((issue) => issue.code),
        contains('legacy_provenance_coarse'),
      );
    });
  });

  group('Projector real bridge-chain parity', () {
    test('maps unknown A/B input through the R3B bridge to type 0', () {
      final legacy = OcrQuestionRegion(
        number: 1,
        stemParts: const <String>['题干\nA. 甲\nB. 乙'],
        answerParts: const <String>['A'],
        explanationParts: const <String>[],
        sourcePageIndices: const <int>[1],
        sourceBlockIds: const <String>['b1'],
        diagnostics: const <String>[],
        declaredKind: TextQuestionKind.unknown,
      );
      final sourceDocument = SourceDocument(
        sourceId: 'source_a',
        displayLabel: 'paper.pdf',
        parts: <SourcePart>[
          _blockPart('b1', 1, 0, '题干\nA. 甲\nB. 乙'),
        ],
      );
      final region = const OcrQuestionRegionBridge().convert(
        legacy,
        sourceDocument: sourceDocument,
      );

      expect(region.kindHint, QuestionRegionKindHint.singleChoice);
      final draft = assembler.assemble(region, questionId: 'task_q1');
      final projected = projector.project(
        draft: draft,
        region: region,
        profile: const OcrLegacyProjectionProfile(),
      );

      expect(projected.question['type'], 0);
      expect(projected.question['content'], '题干\nA. 甲\nB. 乙');
      expect(projected.question['options'], isEmpty);
    });
  });

  group('Projector text repair threshold parity', () {
    test('uses the untrimmed fragment length for the repair threshold', () {
      final legacy = TextQuestionRegion(
        number: 1,
        rawText: '     \n     \n短题\n     \n     ',
        startOffset: 0,
        endOffset: 26,
        answerText: '42',
        kind: TextQuestionKind.subjective,
        health: RegionHealth.clean,
      );
      final projected = _projectText(legacy);
      final expected = const LocalQuestionAssembler().assemble(legacy);

      expect(projected.repairRecommended, isTrue);
      expect(projected.repairRecommended, expected.repairRecommended);
      expect(projected.rejected, expected.rejected);
    });
  });
}

LocalAssemblyResult _projectText(TextQuestionRegion legacy) {
  final region = const TextQuestionRegionBridge().convert(
    legacy,
    sourceRef: SourceRef.document(sourceId: 'source_a'),
  );
  final draft =
      assembler.assemble(region, questionId: 'task_q${legacy.number}');
  return projector.project(
    draft: draft,
    region: region,
    profile: const TextLegacyProjectionProfile(),
  );
}

LocalAssemblyResult _projectOcr(OcrQuestionRegion legacy) {
  final parts = <SourcePart>[];
  for (var index = 0; index < legacy.stemParts.length; index++) {
    parts.add(
      _blockPart('b${index + 1}', 1, index, legacy.stemParts[index]),
    );
  }
  if (legacy.answerParts.isNotEmpty) {
    parts.add(
      _blockPart(
        'b${legacy.stemParts.length + 1}',
        2,
        legacy.stemParts.length,
        legacy.answerParts.join('\n'),
      ),
    );
  }
  final sourceDocument = SourceDocument(
    sourceId: 'source_a',
    displayLabel: 'paper.pdf',
    parts: parts,
  );
  final region = const OcrQuestionRegionBridge().convert(
    legacy,
    sourceDocument: sourceDocument,
  );
  final draft =
      assembler.assemble(region, questionId: 'task_q${legacy.number}');
  return projector.project(
    draft: draft,
    region: region,
    profile: const OcrLegacyProjectionProfile(),
  );
}

SourcePart _blockPart(
  String blockId,
  int page,
  int readingOrder,
  String text,
) {
  return SourceContentPart(
    sourceRef: SourceRef.at(
      sourceId: 'source_a',
      displayLabel: 'paper.pdf',
      point: SourcePoint.block(
        pageNumber: page,
        blockId: blockId,
        readingOrder: readingOrder,
      ),
    ),
    content: RichContent(nodes: <ContentNode>[TextNode(text)]),
  );
}

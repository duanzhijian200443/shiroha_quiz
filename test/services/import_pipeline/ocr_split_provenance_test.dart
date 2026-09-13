import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/import_review/typed_review_snapshot.dart';
import 'package:shiroha_quiz/services/import_pipeline/adapters/ocr_question_region_bridge.dart';
import 'package:shiroha_quiz/services/import_pipeline/adapters/ocr_source_document_adapter.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_question_assembler.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_question_regionizer.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_typed_candidate.dart';

void main() {
  group('synthetic split block provenance regression', () {
    test(
      'split internal text unit preserves physical block provenance without leaking synthetic ID',
      () {
        // Generic fixture:
        // block_1: question stem and answer
        // block_A: physical block split into internal units (unit 1: explanation tail, unit 2: section heading)
        final document = OcrDocument(
          sourceName: 'generic_split_fixture.pdf',
          markdown: '',
          rawResponses: const [],
          usage: const {},
          pages: const [
            OcrPage(
              pageIndex: 1,
              blocks: [
                OcrBlock(
                  blockId: 'block_1',
                  pageIndex: 1,
                  type: 'text',
                  text:
                      '1. Generic question stem one.\n答案：A\n解析：First line of explanation.',
                  bbox: [],
                  readingOrder: 0,
                ),
                OcrBlock(
                  blockId: 'block_A',
                  pageIndex: 1,
                  type: 'text',
                  text: 'Continuation explanation text.\n二、填空题',
                  bbox: [],
                  readingOrder: 1,
                ),
              ],
            ),
          ],
        );

        // 1. Verify physical source exists in raw document
        final physicalBlockIds =
            document.pages.first.blocks.map((b) => b.blockId).toList();
        expect(physicalBlockIds, contains('block_A'));
        expect(physicalBlockIds, isNot(contains(contains('#'))));

        // 2. Regionize document - split unit must exist internally
        const regionizer = OcrQuestionRegionizer();
        final regionized = regionizer.regionize(document);
        expect(regionized.regions, hasLength(1));
        expect(regionized.diagnostics['splitUnitCount'], greaterThan(0));

        final region = regionized.regions.single;
        expect(region.number, 1);

        // 3. Contract: Question-level sourceBlockIds must contain physical block_A,
        // and must NOT leak synthetic block_A#s1.
        expect(
          region.sourceBlockIds,
          contains('block_A'),
          reason: 'Physical block_A must be recorded in region.sourceBlockIds',
        );
        expect(
          region.sourceBlockIds,
          isNot(contains(contains('#'))),
          reason:
              'Internal synthetic ID must not leak into region.sourceBlockIds',
        );
        expect(region.sourceBlockIds, equals(['block_1', 'block_A']));

        // 4. Verify SourceDocument has physical block_A
        final sourceDoc = const OcrSourceDocumentAdapter().convert(
          document,
          sourceId: 'src_synthetic_1',
        );
        final sourceDocBlockIds = sourceDoc.parts
            .map((p) => p.sourceRef.start?.blockId)
            .whereType<String>()
            .toSet();
        expect(sourceDocBlockIds, contains('block_A'));

        // 5. Bridge resolution: Bridge must resolve physical block_A into QuestionRegion.sourceRefs
        final typedRegion = const OcrQuestionRegionBridge().convert(
          region,
          sourceDocument: sourceDoc,
        );
        final bridgeBlockIds = typedRegion.sourceRefs
            .map((ref) => ref.start?.blockId)
            .whereType<String>()
            .toList();
        expect(
          bridgeBlockIds,
          contains('block_A'),
          reason: 'Bridge must resolve SourceRef for physical block_A',
        );
        expect(bridgeBlockIds, equals(['block_1', 'block_A']));

        // 6. Assemble candidate and project legacy
        const assembler = OcrQuestionAssembler();
        final legacyQuestion = assembler.assemble(region).question;
        legacyQuestion['source_page_indices'] = region.sourcePageIndices;
        legacyQuestion['source_block_ids'] = region.sourceBlockIds;

        final batch = buildOcrTypedCandidateBatch(
          document: document,
          regions: regionized.regions,
          legacyQuestions: [legacyQuestion],
          uuidV4Factory: () => '00000000-0000-4000-8000-000000000001',
        );

        expect(batch.failure, isNull);
        expect(batch.candidates, hasLength(1));
        final candidate = batch.candidates.single;

        // Projected candidate must have physical block_A
        expect(candidate.sourceBlockIds, equals(['block_1', 'block_A']));

        // 7. Gate parity: Strict provenance parity must pass
        final gateResult = applyOcrTypedCandidateGate(
          batch: batch,
          finalQuestions: [legacyQuestion],
          singleFile: true,
        );

        expect(
          gateResult.route,
          ImportStorageRoute.typedV2,
          reason: 'Provenance parity must succeed without blockIds mismatch',
        );
        expect(gateResult.reason, ocrTypedCandidateReadyReason);
      },
    );

    test(
      'multiple split units from same physical block deduplicate in physical provenance maintaining deterministic order',
      () {
        // block_B has 2 subquestion markers internally: (1) and (2), followed by a section heading.
        final document = OcrDocument(
          sourceName: 'generic_multi_split.pdf',
          markdown: '',
          rawResponses: const [],
          usage: const {},
          pages: const [
            OcrPage(
              pageIndex: 1,
              blocks: [
                OcrBlock(
                  blockId: 'block_0',
                  pageIndex: 1,
                  type: 'text',
                  text: '1. Lead question stem.\n答案：C\n解析：First part.',
                  bbox: [],
                  readingOrder: 0,
                ),
                OcrBlock(
                  blockId: 'block_B',
                  pageIndex: 1,
                  type: 'text',
                  text:
                      'Middle part of question one.\nAdditional tail of question one.\n三、解答题',
                  bbox: [],
                  readingOrder: 1,
                ),
              ],
            ),
          ],
        );

        const regionizer = OcrQuestionRegionizer();
        final regionized = regionizer.regionize(document);
        final region = regionized.regions.single;

        expect(region.number, 1);
        // sourceBlockIds must be deduplicated to exactly ['block_0', 'block_B']
        expect(region.sourceBlockIds, equals(['block_0', 'block_B']));
        expect(
            region.sourceBlockIds.where((id) => id == 'block_B'), hasLength(1));
        expect(region.sourceBlockIds, isNot(contains(contains('#'))));

        final sourceDoc = const OcrSourceDocumentAdapter().convert(
          document,
          sourceId: 'src_synthetic_2',
        );
        final typedRegion = const OcrQuestionRegionBridge().convert(
          region,
          sourceDocument: sourceDoc,
        );
        final bridgeBlockIds = typedRegion.sourceRefs
            .map((ref) => ref.start?.blockId)
            .whereType<String>()
            .toList();
        expect(bridgeBlockIds, equals(['block_0', 'block_B']));
      },
    );
  });
}

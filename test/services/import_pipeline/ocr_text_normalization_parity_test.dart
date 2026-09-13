import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/import_review/typed_review_snapshot.dart';
import 'package:shiroha_quiz/domain/content/rich_content_text_projection.dart';
import 'package:shiroha_quiz/services/import_pipeline/adapters/ocr_question_region_bridge.dart';
import 'package:shiroha_quiz/services/import_pipeline/adapters/ocr_source_document_adapter.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_question_assembler.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_question_regionizer.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_typed_candidate.dart';
import 'package:shiroha_quiz/services/import_pipeline/question_draft_v2_legacy_projection.dart';
import 'package:shiroha_quiz/services/import_pipeline/typed_question_assembler.dart';

const _sourceId = '11111111-1111-4111-8111-111111111111';

void main() {
  test(
    'Q1-Q10 choice raw repeated spaces preserve exact draft/projector parity',
    () {
      final document = _tenChoiceQuestionDocument();
      final regionized = const OcrQuestionRegionizer().regionize(document);
      final sourceDocument = const OcrSourceDocumentAdapter().convert(
        document,
        sourceId: _sourceId,
      );

      expect(
        regionized.regions.map((region) => region.number).toList(),
        <int>[1, 2, 3, 4, 5, 6, 7, 8, 9, 10],
      );

      const textProjection = RichContentTextProjection();
      const bridge = OcrQuestionRegionBridge();
      const typedAssembler = TypedQuestionAssembler();
      const legacyAssembler = OcrQuestionAssembler();
      const projector = QuestionDraftV2LegacyProjector();
      final exactParity = <Map<String, Object?>>[];
      final legacyQuestions = <Map<String, dynamic>>[];

      for (final region in regionized.regions) {
        expect(
          RegExp(r'[ \t]{2,}').hasMatch(region.stemText),
          isFalse,
          reason: 'Regionizer must remain the normalized OCR authority.',
        );
        final typedRegion = bridge.convert(
          region,
          sourceDocument: sourceDocument,
        );
        final draft = typedAssembler.assemble(
          typedRegion,
          questionId: 'synthetic_q${region.number}',
        );
        final projected = projector.project(
          draft: draft,
          region: typedRegion,
          profile: const OcrLegacyProjectionProfile(),
        );
        final authoritative = legacyAssembler.assemble(region);
        final authoritativeContent =
            authoritative.question['content'] as String;
        legacyQuestions.add(authoritative.question);
        final draftContent = textProjection.project(draft.stem).trim();
        final projectedContent = projected.question['content'] as String;

        expect(draftContent, authoritativeContent);
        expect(
          <int>[
            draft.options.length,
            (projected.question['options'] as List).length,
            (authoritative.question['options'] as List).length,
          ],
          <int>[4, 4, 4],
          reason: 'Option-marker parity must stay closed.',
        );
        expect(
          _diagnosticNormalize(projectedContent),
          _diagnosticNormalize(draftContent),
          reason: 'The historical mismatch must be normalization-only.',
        );
        exactParity.add(<String, Object?>{
          'questionNumber': region.number,
          'exactEqual': projectedContent == draftContent,
          'lengthDelta': projectedContent.length - draftContent.length,
          'spaceDelta':
              _spaceCount(projectedContent) - _spaceCount(draftContent),
        });
      }

      expect(
        exactParity,
        <Map<String, Object?>>[
          for (var questionNumber = 1; questionNumber <= 10; questionNumber++)
            <String, Object?>{
              'questionNumber': questionNumber,
              'exactEqual': true,
              'lengthDelta': 0,
              'spaceDelta': 0,
            },
        ],
      );

      final batch = buildOcrTypedCandidateBatch(
        document: document,
        regions: regionized.regions,
        legacyQuestions: legacyQuestions,
        uuidV4Factory: _uuidV4Sequence(),
      );
      expect(batch.failure, isNull);
      expect(batch.candidates, hasLength(10));

      final gate = applyOcrTypedCandidateGate(
        batch: batch,
        finalQuestions: legacyQuestions,
        singleFile: true,
      );
      expect(gate.route, ImportStorageRoute.typedV2, reason: gate.reason);
      expect(gate.reason, ocrTypedCandidateReadyReason);
    },
  );
}

OcrDocument _tenChoiceQuestionDocument() {
  final blocks = <OcrBlock>[
    const OcrBlock(
      blockId: 'section',
      pageIndex: 1,
      type: 'text',
      text: '一、选择题',
      bbox: <double>[],
      readingOrder: 0,
    ),
  ];
  var readingOrder = 1;
  for (var questionNumber = 1; questionNumber <= 10; questionNumber++) {
    blocks.add(
      OcrBlock(
        blockId: 'q$questionNumber',
        pageIndex: 1,
        type: 'text',
        text: '$questionNumber. Synthetic  stem  token  tail\n'
            '(A) Alpha\n'
            '(B) Beta\n'
            '(C) Gamma\n'
            '(D) Delta',
        bbox: const <double>[],
        readingOrder: readingOrder++,
      ),
    );
    blocks.add(
      OcrBlock(
        blockId: 'answer_$questionNumber',
        pageIndex: 1,
        type: 'text',
        text: '答案：A',
        bbox: const <double>[],
        readingOrder: readingOrder++,
      ),
    );
  }
  return OcrDocument(
    sourceName: 'synthetic_normalization_fixture.pdf',
    pages: <OcrPage>[OcrPage(pageIndex: 1, blocks: blocks)],
    markdown: '',
    rawResponses: const <Map<String, dynamic>>[],
    usage: const <String, dynamic>{},
  );
}

String _diagnosticNormalize(String input) {
  return input
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll(RegExp(r'[ \t]{2,}'), ' ')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}

int _spaceCount(String input) {
  return input.codeUnits.where((codeUnit) => codeUnit == 0x20).length;
}

String Function() _uuidV4Sequence() {
  var value = 0;
  return () {
    value++;
    final suffix = value.toRadixString(16).padLeft(12, '0');
    return '00000000-0000-4000-8000-$suffix';
  };
}

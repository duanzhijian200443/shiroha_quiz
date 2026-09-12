// Explicit, read-only local acceptance. No provider calls or replay writes.
import 'dart:convert';
import 'dart:io';

import 'package:shiroha_quiz/services/backup/sha256.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart' hide TableRow, TableCell;
import 'package:shiroha_quiz/ui/widgets/structured_content_renderer.dart';
import 'package:shiroha_quiz/application/import_review/typed_review_snapshot.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/services/import_pipeline/final_question_latex_audit.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_field_policy.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_question_assembler.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_question_regionizer.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_typed_candidate.dart';
import 'package:shiroha_quiz/services/import_pipeline/reference_answer_extractor.dart';
import 'package:shiroha_quiz/services/import_pipeline/reference_answer_merger.dart';

void main() {
  final path = Platform.environment['SHIROHA_RENDER_REPLAY'];
  testWidgets('hash-bound replay reaches typed review without layout wrappers',
      (tester) async {
    final file = File(path!);
    final manifest =
        jsonDecode(File('${file.parent.path}/manifest.json').readAsStringSync())
            as Map;
    final bytes = file.readAsBytesSync();
    expect(sha256Hex(bytes), manifest['documentHash']);
    expect(manifest['pdfContentHash'],
        'e583c1e10f9718e9f9ecdc8f0dd4b8599b2c4d94456507cd6b9a356feb6901fe');
    final document = OcrDocument.fromReplayJson(
        jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>);
    expect(document.pages.length, 26);
    expect(document.flattenedBlocks.length, 417);
    final regionized = const OcrQuestionRegionizer().regionize(document);
    final references = const ReferenceAnswerExtractor().extract(
        document, regionized.regions,
        referenceSectionBoundary: regionized.referenceAnswerSectionBoundary);
    final regions =
        const ReferenceAnswerMerger().merge(regionized.regions, references);
    final questions = finalizeAndAuditImportQuestions([
      for (final region in regions)
        const OcrQuestionAssembler().assemble(region).question,
    ], mode: ExplanationRetentionMode.allQuestionTypes);
    var id = 0;
    final batch = buildOcrTypedCandidateBatch(
        document: document,
        regions: regions,
        legacyQuestions: questions,
        explanationRetentionMode: ExplanationRetentionMode.allQuestionTypes,
        uuidV4Factory: () =>
            '11111111-1111-4111-8111-${(++id).toString().padLeft(12, '0')}');
    expect(batch.failure, isNull);
    expect(batch.candidates.length, 22);
    final gate = applyOcrTypedCandidateGate(
        batch: batch, finalQuestions: questions, singleFile: true);
    expect(gate.reason, ocrTypedCandidateReadyReason);
    expect(gate.route, ImportStorageRoute.typedV2);
    expect(
        gate.questions
            .where((q) => q.containsKey(TypedReviewSnapshotCodec.mapKey))
            .length,
        22);
    for (final candidate in batch.candidates) {
      final explanation = candidate.draft.explanation;
      expect(
          explanation?.nodes
                  .whereType<TextNode>()
                  .any((n) => RegExp(r'</?div\b').hasMatch(n.text)) ??
              false,
          isFalse,
          reason: 'question ${candidate.questionNumber}');
    }
    final tables = batch.candidates[7].draft.explanation!.nodes
        .whereType<TableNode>()
        .toList();
    expect(tables.length, 2);
    final cellNodes = [
      for (final table in tables)
        for (final row in table.structure.rows)
          for (final cell in row.cells) ...cell.content.nodes
    ];
    expect(cellNodes.whereType<InlineMathNode>().length, 13);
    expect(cellNodes.whereType<BlockMathNode>().length, 3);
    var fallbacks = 0;
    final previousPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message?.startsWith('Structured LaTeX render fallback:') ?? false) {
        fallbacks++;
      }
    };
    try {
      for (final table in tables) {
        for (final row in table.structure.rows) {
          for (final cell in row.cells) {
            await tester.pumpWidget(MaterialApp(
                home: Scaffold(
                    body: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: RichContentRenderer(content: cell.content)))));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          }
        }
      }
    } finally {
      debugPrint = previousPrint;
    }
    expect(fallbacks, 0);
    debugPrint(
        'replay questions=22 typedEnvelopes=22 tables=2 structuralMathCells=16 rendererFallbacks=$fallbacks providerCalls=0');
  }, skip: path == null);
}

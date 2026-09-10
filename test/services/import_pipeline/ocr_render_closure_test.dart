import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/content/content_asset_authority.dart';
import 'package:shiroha_quiz/application/import_review/typed_review_snapshot.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart' as c;
import 'package:shiroha_quiz/services/file_library/managed_content_asset_store.dart';
import 'package:shiroha_quiz/services/import_pipeline/final_question_latex_audit.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_field_policy.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_question_assembler.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_question_regionizer.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_typed_candidate.dart';
import 'package:shiroha_quiz/ui/widgets/structured_content_renderer.dart';

void main() {
  testWidgets(
      'real cell excerpts survive image-bearing typed review and render',
      (tester) async {
    final fixture = jsonDecode(
        File('test/fixtures/ocr_renderer_2022_cells.json')
            .readAsStringSync()) as Map;
    final cells =
        (fixture['cells'] as List).map((v) => v['text'] as String).toList();
    cells.addAll(
        [r'ordinary \frac label = prose', r'价格=\frac{1}{p}', r'cost $5']);
    final bytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=');
    final root = Directory.systemTemp.createTempSync('ocr_render_closure_');
    addTearDown(() => root.deleteSync(recursive: true));
    final store = ManagedContentAssetStore(managedRoot: root);
    var order = 0;
    OcrBlock block(String id, String text,
            {String type = 'text', OcrImagePayload? image}) =>
        OcrBlock(
            blockId: id,
            pageIndex: 1,
            type: type,
            text: text,
            bbox: const [],
            readingOrder: order++,
            imagePayload: image);
    final document = OcrDocument(
        sourceName: 'fixture',
        markdown: '',
        rawResponses: const [],
        usage: const {},
        pages: [
          OcrPage(pageIndex: 1, blocks: [
            block('heading', '三、解答题'),
            block('stem', '1. Synthetic question.'),
            block('answer', '答案：1'),
            block('explanation', '解析：before\n<div align="center">'),
            block('image', '[图片]',
                type: 'image',
                image: OcrImagePayload(bytes: bytes, mimeType: 'image/png')),
            block('close', '</div>\nafter'),
            block('table',
                '<table><tr>${cells.map((s) => '<td>${const HtmlEscape().convert(s)}</td>').join()}</tr></table>',
                type: 'table'),
          ]),
        ]);
    final regions = const OcrQuestionRegionizer().regionize(document).regions;
    final legacy = finalizeAndAuditImportQuestions([
      for (final region in regions)
        const OcrQuestionAssembler().assemble(region).question,
    ], mode: ExplanationRetentionMode.allQuestionTypes);
    var id = 0;
    final batch = buildOcrTypedCandidateBatch(
        document: document,
        regions: regions,
        legacyQuestions: legacy,
        assetStore: store,
        explanationRetentionMode: ExplanationRetentionMode.allQuestionTypes,
        uuidV4Factory: () =>
            '11111111-1111-4111-8111-${(++id).toString().padLeft(12, '0')}');
    expect(batch.failure, isNull);
    final gate = applyOcrTypedCandidateGate(
        batch: batch,
        finalQuestions: legacy,
        singleFile: true,
        contentAssetAuthority: store);
    expect(gate.reason, ocrTypedCandidateReadyReason);
    expect(gate.route, ImportStorageRoute.typedV2);
    final snapshot = const TypedReviewSnapshotCodec().decodeRequired(
        Map<String, dynamic>.from(
            gate.questions.single[TypedReviewSnapshotCodec.mapKey] as Map));
    final content = snapshot.draft.explanation!;
    expect(content.nodes.whereType<c.ImageNode>().length, 1);
    final table = content.nodes.whereType<c.TableNode>().single;
    final typedCells = table.structure.rows.single.cells;
    expect(typedCells[0].content.nodes.single, isA<c.TextNode>());
    expect(typedCells[1].content.nodes.single, isA<c.BlockMathNode>());
    expect(typedCells[2].content.nodes.single, isA<c.InlineMathNode>());
    expect(typedCells[3].content.nodes.single, isA<c.InlineMathNode>());
    for (var i = 4; i < cells.length; i++) {
      expect((typedCells[i].content.nodes.single as c.TextNode).text, cells[i]);
    }
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                    width: 2400,
                    child: RichContentRenderer(
                        content: content, assetResolver: _Resolver(bytes)))))));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    expect(find.byType(Math), findsNWidgets(3));
    expect(find.textContaining('<div', findRichText: true), findsNothing);
    expect(find.textContaining('</div>', findRichText: true), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'circled single-digit labels render without changing stored latex',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: StructuredContentRenderer(
                text:
                    r'$\textcircled{1}$ $\textcircled{2}$ $\textcircled{3}$'))));
    await tester.pumpAndSettle();
    expect(find.text(r'\textcircled{1}'), findsNothing);
    expect(find.byType(Math), findsNWidgets(3));
    expect(tester.takeException(), isNull);
  });
}

class _Resolver implements ContentAssetResolver {
  _Resolver(this.bytes);
  final List<int> bytes;
  @override
  List<int>? resolveAssetBytes(
          {required String sourceId, required String localAssetId}) =>
      bytes;
  @override
  Future<List<int>?> resolveAssetBytesAsync(
          {required String sourceId, required String localAssetId}) async =>
      bytes;
}

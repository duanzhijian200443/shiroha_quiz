// Opt-in local evidence: reads only the selected task and its managed assets.
// Never copies private snapshots or prints source/formula/exception payloads.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shiroha_quiz/application/content/content_asset_authority.dart';
import 'package:shiroha_quiz/application/import_review/typed_review_snapshot.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart' as c;
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/services/file_library/managed_content_asset_store.dart';
import 'package:shiroha_quiz/services/import_pipeline/latex_renderability_checker.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_typed_content_cleanup.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_typed_candidate.dart';
import 'package:shiroha_quiz/ui/widgets/structured_content_renderer.dart';

void main() {
  final path = Platform.environment['SHIROHA_RENDER_DATABASE'];
  testWidgets('exact task snapshot assets and command-family render evidence',
      (tester) async {
    sqfliteFfiInit();
    final row = await tester.runAsync(() async {
      final db = await databaseFactoryFfi.openDatabase(path!,
          options: OpenDatabaseOptions(readOnly: true));
      try {
        return (await db.rawQuery(
          'SELECT parsed_data, diagnostics FROM import_tasks WHERE id = ?',
          ['task_1789034267668710'],
        ))
            .single;
      } finally {
        await db.close();
      }
    });
    final questions = jsonDecode(row!['parsed_data'] as String) as List;
    final diagnostics = jsonDecode(row['diagnostics'] as String) as Map;
    expect(diagnostics['_importStorageRoute'], 'typedV2');
    expect(diagnostics['_importStorageReason'], 'typed_candidate_ready');
    expect(questions.length, 22);
    final store = ManagedContentAssetStore(
        managedRoot: Directory('${File(path!).parent.parent.path}/library'));
    final candidates = <OcrTypedCandidate>[];
    var images = 0;
    var commandCases = 0;
    var rawFallback = 0;
    var productionFallback = 0;
    final oldPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message?.startsWith('Structured LaTeX render fallback:') ?? false) {
        productionFallback++;
      }
    };
    addTearDown(() => debugPrint = oldPrint);
    for (final q in questions) {
      final snapshot = const TypedReviewSnapshotCodec().decodeRequired(
          Map<String, dynamic>.from(q[TypedReviewSnapshotCodec.mapKey] as Map));
      final draft = cleanupOcrTypedDraft(snapshot.draft);
      candidates.add(OcrTypedCandidate(
        questionNumber: q['question_number'] as int,
        reviewItemId: snapshot.reviewItemId,
        questionId: snapshot.questionId,
        draft: draft,
        projectedLegacy: snapshot.baselineLegacy,
        sourcePageIndices: List<int>.from(q['source_page_indices'] as List),
        sourceBlockIds: List<String>.from(q['source_block_ids'] as List),
      ));
      expect(draft.assetRefs, snapshot.draft.assetRefs);
      final explanation = draft.explanation;
      if (explanation == null) continue;
      expect(
          explanation.nodes
              .whereType<c.TextNode>()
              .any((n) => RegExp(r'</?div\b').hasMatch(n.text)),
          isFalse);
      for (final node in explanation.nodes) {
        if (node is c.ImageNode) {
          final bytes = store.readAssetBytes(
              sourceId: node.sourceId, localAssetId: node.localAssetId);
          expect(bytes != null, isTrue);
          await tester.pumpWidget(_host(RichContentRenderer(
              content: RichContent(nodes: [node]),
              assetResolver: _Resolver(bytes!))));
          await tester.pumpAndSettle();
          expect(find.byType(Image), findsOneWidget);
          expect(tester.takeException(), isNull);
          images++;
        }
        final latex = switch (node) {
          c.InlineMathNode(:final latex) ||
          c.BlockMathNode(:final latex) =>
            latex,
          _ => null
        };
        if (latex == null ||
            !RegExp(r'\\(?:textcircled|operatorname)\b').hasMatch(latex)) {
          continue;
        }
        commandCases++;
        expect(
            const LatexRenderabilityChecker()
                .check(latex, assumeMathContext: true)
                .isRenderable,
            isTrue);
        await tester.pumpWidget(_host(Math.tex(latex,
            settings: const TexParserSettings(strict: Strict.ignore),
            onErrorFallback: (_) {
          rawFallback++;
          return const SizedBox();
        })));
        await tester.pumpAndSettle();
        await tester.pumpWidget(
            _host(RichContentRenderer(content: RichContent(nodes: [node]))));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
    }
    expect(images, 5);
    debugPrint = oldPrint;
    final gate = applyOcrTypedCandidateGate(
      batch: OcrTypedCandidateBatch(
          candidates: candidates,
          candidateAssetLease: ContentAssetCandidateLease(
              sourceId: diagnostics['_candidate_asset_source_id'] as String,
              localAssetIds: List<String>.from(
                  diagnostics['_candidate_asset_local_ids'] as List))),
      finalQuestions: [
        for (final q in questions) Map<String, dynamic>.from(q as Map)
      ],
      singleFile: true,
      contentAssetAuthority: store,
    );
    expect(gate.route, ImportStorageRoute.typedV2);
    expect(gate.reason, ocrTypedCandidateReadyReason);
    expect(gate.questions.length, 22);
    expect(commandCases, 19);
    expect(rawFallback, 9);
    expect(productionFallback, 0);
    debugPrint(
        'snapshot envelopes=22 images=$images commandCases=$commandCases rawFallback=$rawFallback productionFallback=$productionFallback');
  }, skip: path == null);
}

Widget _host(Widget child) => MaterialApp(
    home: Scaffold(
        body: SingleChildScrollView(
            child: SingleChildScrollView(
                scrollDirection: Axis.horizontal, child: child))));

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

// Review explanation edit provenance contract.
//
// A typed explanation and its legacy review text are intentionally NOT
// isomorphic representations: the typed form carries InlineMathNode / TableNode
// / ImageNode while the legacy form carries `$latex$`, pipe-separated table text
// and `[图片]`. Because of that, "may the original structure still be used?" is
// answered only by an explicit edit provenance marker, never by comparing the
// two strings. These fixtures assert that premise before testing the decision.
//
// Synthetic fixtures only: no Provider, Replay, network, database, filesystem
// or UI, so Provider calls are 0 by construction.
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/content/rich_content_text_projection.dart';
import 'package:shiroha_quiz/services/import_review/explanation_edit_provenance.dart';
import 'package:shiroha_quiz/services/import_review/review_legacy_field_content.dart';

/// Typed explanation carrying every structural node the real OCR payload had.
RichContent _typedExplanation() {
  return RichContent(nodes: <ContentNode>[
    const TextNode('分析本题。'),
    const InlineMathNode('x^2'),
    TableNode(
      structure: TableStructure(rows: <TableRow>[
        TableRow(cells: <TableCell>[
          TableCell(
            content: RichContent(nodes: <ContentNode>[const TextNode('充分')]),
          ),
          TableCell(
            content: RichContent(nodes: <ContentNode>[const TextNode('A有n个')]),
          ),
        ]),
        TableRow(cells: <TableCell>[
          TableCell(
            content: RichContent(nodes: <ContentNode>[const TextNode('必要')]),
            columnSpan: 2,
          ),
        ]),
      ]),
    ),
    ImageNode(
      sourceId: '11111111-1111-4111-8111-111111111111',
      localAssetId: 'image_1',
    ),
    const TextNode('结论。'),
  ]);
}

/// The legacy review text of the same explanation.
///
/// It deliberately uses the other representation: math keeps its delimiters,
/// and the table rows break where the HTML wrappers were rather than at the
/// typed cell separator, so the two texts are different lengths by construction.
String _legacyExplanationText() {
  return '分析本题。\$x^2\$\n'
      '充分 | A有n个\n'
      '必要\n'
      '[图片]\n'
      '结论。';
}

void main() {
  group('representation premise', () {
    test('typed projection and legacy text are not the same string', () {
      final explanation = _typedExplanation();
      final projected = const RichContentTextProjection().project(explanation);
      final legacy = _legacyExplanationText();

      // The premise of the whole contract: neither representation is a
      // round trip of the other, so string equality can never decide whether a
      // user edited the explanation.
      expect(projected == legacy, isFalse,
          reason: 'typed projection length=${projected.length} '
              'legacy length=${legacy.length}');
      expect(projected.contains(r'$'), isFalse,
          reason: 'the typed form extracted math into math nodes');
      expect(legacy.contains(r'$'), isTrue,
          reason: 'the legacy form keeps the math delimiters as text');
      expect(projected.contains('|'), isTrue);
      expect(legacy.contains('\n必要'), isTrue,
          reason: 'the legacy table breaks rows differently');
    });
  });

  group('resolveExplanationReviewContent', () {
    test('untouched retains the original structure without comparing text', () {
      final explanation = _typedExplanation();

      final resolved = resolveExplanationReviewContent(
        originalContent: explanation,
        baselineText: '',
        currentText: _legacyExplanationText(),
        retained: true,
        provenance: ExplanationEditProvenance.untouched,
      );

      // Same instance: no reparse, no rebuilt table, no invented image asset.
      expect(identical(resolved, explanation), isTrue);
      final nodes = resolved!.nodes;
      expect(nodes.whereType<TableNode>(), hasLength(1));
      expect(nodes.whereType<ImageNode>(), hasLength(1));
      expect(nodes.whereType<InlineMathNode>(), hasLength(1));
    });

    test('manualEdited never re-inherits the original structure', () {
      final explanation = _typedExplanation();

      final resolved = resolveExplanationReviewContent(
        originalContent: explanation,
        baselineText: '',
        currentText: _legacyExplanationText(),
        retained: true,
        provenance: ExplanationEditProvenance.manualEdited,
      );

      expect(resolved, isNull);
    });

    test('manualEdited stays literal even when the text matches the baseline',
        () {
      final explanation = _typedExplanation();
      const baseline = 'identical baseline text';

      final resolved = resolveExplanationReviewContent(
        originalContent: explanation,
        baselineText: baseline,
        currentText: baseline,
        retained: true,
        provenance: ExplanationEditProvenance.manualEdited,
      );

      // Edit history cannot be recovered from the final string: the user
      // deleted this text and typed it back, so the structure stays gone.
      expect(resolved, isNull);
    });

    test('manualEdited stays literal even when the text matches the projection',
        () {
      final explanation = _typedExplanation();
      final projected = const RichContentTextProjection().project(explanation);

      final resolved = resolveExplanationReviewContent(
        originalContent: explanation,
        baselineText: '',
        currentText: projected,
        retained: true,
        provenance: ExplanationEditProvenance.manualEdited,
      );

      expect(resolved, isNull);
    });

    test('not retained never renders typed structure for any provenance', () {
      final explanation = _typedExplanation();
      for (final provenance in ExplanationEditProvenance.values) {
        expect(
          resolveExplanationReviewContent(
            originalContent: explanation,
            baselineText: '',
            currentText: _legacyExplanationText(),
            retained: false,
            provenance: provenance,
          ),
          isNull,
          reason: 'retention policy wins for $provenance',
        );
      }
    });

    test('legacyUnknown keeps the strict fallback and adds no normalization',
        () {
      final explanation = _typedExplanation();
      final legacy = _legacyExplanationText();

      // The real observed 517-vs-523-style mismatch must stay unresolved: an
      // old draft can never be silently upgraded to a structural restore.
      expect(
        resolveExplanationReviewContent(
          originalContent: explanation,
          baselineText: '',
          currentText: legacy,
          retained: true,
          provenance: ExplanationEditProvenance.legacyUnknown,
        ),
        isNull,
      );

      // The pre-existing exact cases keep working unchanged.
      final projected = const RichContentTextProjection().project(explanation);
      expect(
        resolveExplanationReviewContent(
          originalContent: explanation,
          baselineText: '',
          currentText: projected,
          retained: true,
          provenance: ExplanationEditProvenance.legacyUnknown,
        ),
        isNotNull,
      );
      expect(
        resolveExplanationReviewContent(
          originalContent: explanation,
          baselineText: legacy,
          currentText: legacy,
          retained: true,
          provenance: ExplanationEditProvenance.legacyUnknown,
        ),
        isNotNull,
      );
    });

    test('untouched without original content resolves to the literal path', () {
      expect(
        resolveExplanationReviewContent(
          originalContent: null,
          baselineText: '',
          currentText: 'user text',
          retained: true,
          provenance: ExplanationEditProvenance.untouched,
        ),
        isNull,
      );
    });
  });

  group('ExplanationEditProvenance persistence', () {
    test('round-trips the two persisted tokens', () {
      expect(
        decodeExplanationEditProvenance(
          encodeExplanationEditProvenance(
            ExplanationEditProvenance.untouched,
          ),
        ),
        ExplanationEditProvenance.untouched,
      );
      expect(
        decodeExplanationEditProvenance(
          encodeExplanationEditProvenance(
            ExplanationEditProvenance.manualEdited,
          ),
        ),
        ExplanationEditProvenance.manualEdited,
      );
    });

    test('legacyUnknown is never written back', () {
      expect(
        encodeExplanationEditProvenance(
          ExplanationEditProvenance.legacyUnknown,
        ),
        isNull,
      );
    });

    test('missing, null and corrupt markers decode to legacyUnknown', () {
      for (final value in <Object?>[null, '', 'banana', 7, <String>[]]) {
        expect(
          decodeExplanationEditProvenance(value),
          ExplanationEditProvenance.legacyUnknown,
          reason: 'marker $value must never be upgraded to untouched',
        );
      }
    });
  });
}

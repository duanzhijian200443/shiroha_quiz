import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/data/models/question_draft.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/services/import_review/review_legacy_field_content.dart';
import 'package:shiroha_quiz/services/import_review/review_repair_edit.dart';

void main() {
  QuestionDraft draft({
    String content = 'Stem',
    List<String> options = const <String>[],
    String standardAnswer = 'Answer',
    String explanation = 'Explanation',
  }) {
    return QuestionDraft(
      type: options.isEmpty
          ? QuestionType.shortAnswer
          : QuestionType.singleChoice,
      content: content,
      options: options,
      standardAnswer: standardAnswer,
      explanation: explanation,
    );
  }

  group('ReviewRepairEdit', () {
    test('records only the fields that changed', () {
      final before = draft(explanation: r'Broken \begin{matrix}1');
      final after = draft(explanation: r'Broken \begin{matrix}1\end{matrix}');

      final edit = ReviewRepairEdit.applied(before: before, after: after);

      expect(edit.digests.keys, <ReviewRepairField>[
        ReviewRepairField.explanation,
      ]);
      expect(
        edit.isSatisfiedByDraft(ReviewRepairField.explanation, after),
        isTrue,
      );
      expect(
        edit.isSatisfiedByDraft(ReviewRepairField.explanation, before),
        isFalse,
      );
      expect(
          edit.isSatisfiedByDraft(ReviewRepairField.content, after), isFalse);
    });

    test('only the exact repaired text satisfies the marker', () {
      final before = draft(explanation: 'broken');
      final after = draft(explanation: r'Fixed \(x+1\)');
      final edit = ReviewRepairEdit.applied(before: before, after: after);

      expect(edit.isSatisfiedByDraft(ReviewRepairField.explanation, after),
          isTrue);
      expect(
        edit.isSatisfiedByDraft(
          ReviewRepairField.explanation,
          draft(explanation: r'Fixed \(x+1\) '),
        ),
        isFalse,
      );
      expect(
        edit.isSatisfiedByDraft(
          ReviewRepairField.explanation,
          draft(explanation: r'Fixed \(x+2\)'),
        ),
        isFalse,
      );
    });

    test('round-trips through the persisted map', () {
      final edit = ReviewRepairEdit.applied(
        before: draft(explanation: 'broken'),
        after: draft(explanation: 'fixed'),
      );

      final restored = ReviewRepairEdit.fromMap(edit.toMap());

      expect(restored, isNotNull);
      expect(restored!.digests, edit.digests);
    });

    test('rejects unrecognized persisted markers', () {
      final edit = ReviewRepairEdit.applied(
        before: draft(explanation: 'broken'),
        after: draft(explanation: 'fixed'),
      );
      final valid = edit.toMap();

      expect(ReviewRepairEdit.fromMap(null), isNull);
      expect(ReviewRepairEdit.fromMap('not-a-map'), isNull);
      expect(ReviewRepairEdit.fromMap(<String, Object?>{}), isNull);
      expect(
        ReviewRepairEdit.fromMap(<String, Object?>{
          'schemaVersion': 2,
          'fields': valid['fields'],
        }),
        isNull,
      );
      expect(
        ReviewRepairEdit.fromMap(<String, Object?>{
          'schemaVersion': 1,
          'fields': <String, Object?>{'raw_explanation': 'a' * 64},
        }),
        isNull,
      );
      expect(
        ReviewRepairEdit.fromMap(<String, Object?>{
          'schemaVersion': 1,
          'fields': <String, Object?>{'explanation': 'short'},
        }),
        isNull,
      );
    });

    test('option digests keep option boundaries significant', () {
      final before = draft(options: const <String>['A. one', 'B. two']);
      final after = draft(options: const <String>['A. on', 'B. etwo']);

      final edit = ReviewRepairEdit.applied(before: before, after: after);

      expect(edit.digests.keys, <ReviewRepairField>[ReviewRepairField.options]);
      expect(
        edit.isSatisfiedByDraft(ReviewRepairField.options, before),
        isFalse,
      );
    });
  });

  group('reviewFieldContentFromLegacyText', () {
    test('rebuilds math from both delimiter families', () {
      final content = reviewFieldContentFromLegacyText(
        r'前 \(x+1\) 后 $$y=2$$ 尾',
      );

      expect(content, isNotNull);
      expect(content!.nodes, hasLength(5));
      expect(content.nodes[0], const TextNode('前 '));
      expect(content.nodes[1], const InlineMathNode('x+1'));
      expect(content.nodes[2], const TextNode(' 后 '));
      expect(content.nodes[3], const BlockMathNode('y=2'));
      expect(content.nodes[4], const TextNode(' 尾'));
    });

    test('keeps plain text as literal text', () {
      final content = reviewFieldContentFromLegacyText('只有文字');

      expect(content, isNotNull);
      expect(content!.nodes, <ContentNode>[const TextNode('只有文字')]);
    });

    test('refuses image references and unclosed delimiters', () {
      expect(
        reviewFieldContentFromLegacyText(
          '文字 ![image](https://example.invalid/a.png) 结尾',
        ),
        isNull,
      );
      expect(reviewFieldContentFromLegacyText(r'未闭合 \(x+1'), isNull);
      expect(reviewFieldContentFromLegacyText('   '), isNull);
    });
  });

  group('reviewFieldSupportsStructuralEdit', () {
    test('accepts text and math only', () {
      expect(
        reviewFieldSupportsStructuralEdit(
          RichContent(nodes: <ContentNode>[
            const TextNode('a'),
            const InlineMathNode('x'),
            const BlockMathNode('y'),
          ]),
        ),
        isTrue,
      );
    });

    test('rejects images, tables and raw fallback', () {
      expect(
        reviewFieldSupportsStructuralEdit(
          RichContent(nodes: <ContentNode>[
            ImageNode(sourceId: 's', localAssetId: 'a'),
          ]),
        ),
        isFalse,
      );
      expect(
        reviewFieldSupportsStructuralEdit(
          RichContent(nodes: <ContentNode>[
            TableNode(
              structure: TableStructure(rows: <TableRow>[
                TableRow(cells: <TableCell>[
                  TableCell(content: RichContent(nodes: const <ContentNode>[])),
                ]),
              ]),
            ),
          ]),
        ),
        isFalse,
      );
      expect(
        reviewFieldSupportsStructuralEdit(
          RichContent(nodes: <ContentNode>[
            RawFallbackNode(<String, Object?>{'type': 'unknown'}),
          ]),
        ),
        isFalse,
      );
    });
  });
}

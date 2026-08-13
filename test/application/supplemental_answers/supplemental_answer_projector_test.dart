import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/supplemental_answers/supplemental_answer_projector.dart';
import 'package:shiroha_quiz/domain/assets/asset_ref.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/source/source_document.dart';
import 'package:shiroha_quiz/domain/source/source_part.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';

void main() {
  const projector = SupplementalAnswerProjector();

  test('projects numbered answer paragraphs with normalization', () {
    final document = SourceDocument(
      sourceId: 'artifact_001',
      parts: [
        _paragraph('第1题：A', role: SourceContentRole.answerLike),
        _paragraph('2．B', role: SourceContentRole.answerLike),
        _paragraph('１、C', role: SourceContentRole.answerLike),
      ],
    );

    final result = projector.project(document);

    expect(result.fragments, hasLength(3));
    expect(result.fragments[0].normalizedMainNumber, '1');
    expect(result.fragments[0].sourceRefs.single.sourceId, 'artifact_001');
    expect(result.fragments[1].normalizedMainNumber, '2');
    expect(result.fragments[2].normalizedMainNumber, '1');
    expect(result.issues, isEmpty);
  });

  test('combines multi-part answers structurally and keeps explanations',
      () {
    final document = SourceDocument(
      sourceId: 'artifact_001',
      parts: [
        _paragraph('1. ', role: SourceContentRole.answerLike),
        _paragraph('x = 2', role: SourceContentRole.paragraph),
        _paragraph('解析：代入即可', role: SourceContentRole.paragraph),
      ],
    );

    final result = projector.project(document);

    expect(result.fragments, hasLength(1));
    final fragment = result.fragments.single;
    expect(fragment.normalizedMainNumber, '1');
    expect(
      fragment.answerContent.nodes.map((node) => (node as TextNode).text),
      ['x = 2'],
    );
    expect(
      fragment.explanationContent!.nodes
          .map((node) => (node as TextNode).text),
      ['解析：代入即可'],
    );
    expect(fragment.sourceRefs, hasLength(1));
    expect(fragment.sequencePosition.continuationOrdinal, 2);
  });

  test('projects table number/answer layout into one fragment per column',
      () {
    final document = SourceDocument(
      sourceId: 'artifact_001',
      parts: [
        SourceTablePart(
          sourceRef: SourceRef.document(sourceId: 'artifact_001'),
          rows: [
            [_text('题号'), _text('1'), _text('2'), _text('3')],
            [_text('答案'), _text('A'), _text('C'), _text('B')],
          ],
        ),
      ],
    );

    final result = projector.project(document);

    expect(result.fragments, hasLength(3));
    expect(
      result.fragments.map((fragment) => fragment.normalizedMainNumber),
      ['1', '2', '3'],
    );
    expect(
      result.fragments.map(
        (fragment) =>
            (fragment.answerContent.nodes.single as TextNode).text,
      ),
      ['A', 'C', 'B'],
    );
    expect(
      result.fragments.map((fragment) => fragment.sequencePosition.tableRow),
      [1, 1, 1],
    );
    expect(
      result.fragments.map(
        (fragment) => fragment.sequencePosition.tableColumn,
      ),
      [1, 2, 3],
    );
  });

  test('skips unrecognized tables and image/unsupported parts', () {
    final document = SourceDocument(
      sourceId: 'artifact_001',
      parts: [
        SourceTablePart(
          sourceRef: SourceRef.document(sourceId: 'artifact_001'),
          rows: [
            [_text('1'), _text('A')],
            [_text('2'), _text('C')],
          ],
        ),
        SourceAssetPart(
          sourceRef: SourceRef.document(sourceId: 'artifact_001'),
          asset: AssetRef(assetId: 'asset_001', kind: AssetKind.image),
        ),
        UnsupportedSourcePart(
          sourceRef: SourceRef.document(sourceId: 'artifact_001'),
          kindCode: 'parsed_source_boundary',
          fallbackContent: RichContent(nodes: <ContentNode>[
            TextNode('[Source]'),
          ]),
        ),
      ],
    );

    final result = projector.project(document);

    expect(result.fragments, isEmpty);
    expect(
      result.issues.map((issue) => issue.kind),
      containsAll(<SupplementalProjectionIssueKind>[
        SupplementalProjectionIssueKind.tableUnrecognized,
        SupplementalProjectionIssueKind.imageWithoutAltTextSkipped,
        SupplementalProjectionIssueKind.unsupportedPartSkipped,
      ]),
    );
  });

  test('skips continuations without an open fragment', () {
    final document = SourceDocument(
      sourceId: 'artifact_001',
      parts: [
        _paragraph('前言', role: SourceContentRole.paragraph),
        _paragraph('1. A', role: SourceContentRole.answerLike),
      ],
    );

    final result = projector.project(document);

    expect(result.fragments, hasLength(1));
    expect(
      result.issues,
      contains(
        const SupplementalProjectionIssue(
          kind: SupplementalProjectionIssueKind
              .continuationWithoutFragmentSkipped,
          partIndex: 0,
        ),
      ),
    );
  });

  test('heading context is captured on following fragments', () {
    final document = SourceDocument(
      sourceId: 'artifact_001',
      parts: [
        _paragraph('参考答案', role: SourceContentRole.heading),
        _paragraph('1. A', role: SourceContentRole.answerLike),
      ],
    );

    final result = projector.project(document);

    expect(result.fragments.single.headingContext, hasLength(1));
    expect(
      (result.fragments.single.headingContext.single.nodes.single as TextNode)
          .text,
      '参考答案',
    );
  });
}

SourceContentPart _paragraph(
  String text, {
  required SourceContentRole role,
}) {
  return SourceContentPart(
    sourceRef: SourceRef.document(sourceId: 'artifact_001'),
    content: _text(text),
    role: role,
  );
}

RichContent _text(String text) {
  return RichContent(nodes: [TextNode(text)]);
}

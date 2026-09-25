import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/supplemental_answers/supplemental_answer_projector.dart';
import 'package:shiroha_quiz/domain/assets/asset_ref.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/source/source_document.dart';
import 'package:shiroha_quiz/domain/source/source_part.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/domain/supplemental_answers/supplemental_answer_fragment.dart';

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

  test('combines multi-part answers structurally and keeps explanations', () {
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
      fragment.explanationContent!.nodes.map((node) => (node as TextNode).text),
      ['解析：代入即可'],
    );
    expect(fragment.sourceRefs, hasLength(1));
    expect(fragment.sequencePosition.continuationOrdinal, 2);
  });

  test('projects table number/answer layout into one fragment per column', () {
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
        (fragment) => (fragment.answerContent.nodes.single as TextNode).text,
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

  group('field markers and solution blocks', () {
    SourceDocument documentOf(List<SourceContentPart> parts) {
      return SourceDocument(sourceId: 'artifact_001', parts: parts);
    }

    test('keeps marker-less continuations inside the explanation field', () {
      final result = projector.project(
        documentOf([
          _paragraph('1. 答案：A', role: SourceContentRole.answerLike),
          _paragraph('解析：first line', role: SourceContentRole.paragraph),
          _paragraph('second line of the same explanation',
              role: SourceContentRole.paragraph),
        ]),
      );

      final fragment = result.fragments.single;
      expect(_texts(fragment.answerContent), ['A']);
      expect(_texts(fragment.explanationContent!), [
        '解析：first line',
        'second line of the same explanation',
      ]);
      expect(fragment.source, SupplementalAnswerSource.explicitAnswer);
    });

    test('recognizes a wrapped solution marker as a solution block', () {
      final result = projector.project(
        documentOf([
          _paragraph('15.【解】由题意可得', role: SourceContentRole.answerLike),
        ]),
      );

      final fragment = result.fragments.single;
      expect(fragment.normalizedMainNumber, '15');
      expect(fragment.source, SupplementalAnswerSource.solutionBlock);
      expect(_texts(fragment.answerContent), ['【解】由题意可得']);
      expect(fragment.explanationContent, isNull);
    });

    test('keeps (I)/(II) context labels inside a proof solution block', () {
      final result = projector.project(
        documentOf([
          _paragraph('18.(I)【证明】first half',
              role: SourceContentRole.answerLike),
          _paragraph('(II)【解】second half', role: SourceContentRole.paragraph),
        ]),
      );

      final fragment = result.fragments.single;
      expect(fragment.normalizedMainNumber, '18');
      expect(fragment.normalizedSubquestion, isNull);
      expect(fragment.source, SupplementalAnswerSource.solutionBlock);
      expect(_texts(fragment.answerContent), [
        '(I)【证明】first half',
        '(II)【解】second half',
      ]);
    });

    test('recognizes a solution marker that opens the next part', () {
      final result = projector.project(
        documentOf([
          _paragraph('15.', role: SourceContentRole.answerLike),
          _paragraph('【解】body in the next part',
              role: SourceContentRole.paragraph),
        ]),
      );

      final fragment = result.fragments.single;
      expect(fragment.normalizedMainNumber, '15');
      expect(fragment.source, SupplementalAnswerSource.solutionBlock);
      expect(_texts(fragment.answerContent), ['【解】body in the next part']);
    });

    test('a later explicit answer keeps the block an explicit answer', () {
      final result = projector.project(
        documentOf([
          _paragraph('15.【解】derived body', role: SourceContentRole.answerLike),
          _paragraph('【答案】C', role: SourceContentRole.paragraph),
        ]),
      );

      final fragment = result.fragments.single;
      expect(fragment.source, SupplementalAnswerSource.explicitAnswer);
      expect(_texts(fragment.answerContent), ['C']);
      expect(_texts(fragment.explanationContent!), ['【解】derived body']);
    });

    test('an unmarked solution word inside prose stays content', () {
      final result = projector.project(
        documentOf([
          _paragraph('16. 解答如下', role: SourceContentRole.answerLike),
        ]),
      );

      final fragment = result.fragments.single;
      expect(fragment.source, SupplementalAnswerSource.explicitAnswer);
      expect(_texts(fragment.answerContent), ['解答如下']);
    });

    test('a second main locator on one line stays unwritable', () {
      final result = projector.project(
        documentOf([
          _paragraph('17. first answer 18. second answer',
              role: SourceContentRole.answerLike),
          _paragraph('19. clean answer', role: SourceContentRole.answerLike),
        ]),
      );

      expect(result.fragments, hasLength(1));
      expect(result.fragments.single.normalizedMainNumber, '19');
      expect(_texts(result.fragments.single.answerContent), ['clean answer']);
      expect(
        result.issues.map((issue) => issue.kind),
        contains(SupplementalProjectionIssueKind.ambiguousMultiLocatorLine),
      );
    });
  });

  group('bracket top-level locators', () {
    SourceDocument documentOf(List<SourceContentPart> parts) {
      return SourceDocument(sourceId: 'artifact_001', parts: parts);
    }

    test('bracket numbers open top-level fragments with their marker', () {
      final result = projector.project(
        documentOf([
          _paragraph('(1)【答案】C', role: SourceContentRole.answerLike),
          _paragraph('【解】reason-one', role: SourceContentRole.paragraph),
          _paragraph('\n', role: SourceContentRole.paragraph),
          _paragraph('(2)【答案】B', role: SourceContentRole.answerLike),
          _paragraph('【解】reason-two', role: SourceContentRole.paragraph),
        ]),
      );

      expect(
        result.fragments.map((fragment) => fragment.normalizedMainNumber),
        ['1', '2'],
      );
      expect(_texts(result.fragments[0].answerContent), ['C']);
      expect(
        _texts(result.fragments[0].explanationContent!),
        contains('【解】reason-one'),
      );
      expect(_texts(result.fragments[1].answerContent), ['B']);
      expect(
        _texts(result.fragments[1].explanationContent!),
        contains('【解】reason-two'),
      );
      expect(
        result.fragments.map((fragment) => fragment.source),
        everyElement(SupplementalAnswerSource.explicitAnswer),
      );
    });

    test('a bracket solution block keeps the solutionBlock source', () {
      final result = projector.project(
        documentOf([
          _paragraph('(15)【解】', role: SourceContentRole.answerLike),
          _paragraph('step-a', role: SourceContentRole.paragraph),
          _paragraph('step-b', role: SourceContentRole.paragraph),
        ]),
      );

      final fragment = result.fragments.single;
      expect(fragment.normalizedMainNumber, '15');
      expect(fragment.source, SupplementalAnswerSource.solutionBlock);
      expect(_texts(fragment.answerContent), ['【解】', 'step-a', 'step-b']);
    });

    test('context labels keep one main fragment for (18)(I)/(II)', () {
      final result = projector.project(
        documentOf([
          _paragraph('(18)(I)【证明】', role: SourceContentRole.answerLike),
          _paragraph('proof-a', role: SourceContentRole.paragraph),
          _paragraph('(II)【解】', role: SourceContentRole.paragraph),
          _paragraph('solution-b', role: SourceContentRole.paragraph),
        ]),
      );

      expect(result.fragments, hasLength(1));
      final fragment = result.fragments.single;
      expect(fragment.normalizedMainNumber, '18');
      expect(fragment.source, SupplementalAnswerSource.solutionBlock);
      expect(_texts(fragment.answerContent), [
        '(I)【证明】',
        'proof-a',
        '(II)【解】',
        'solution-b',
      ]);
    });

    test('bracket sub-solutions under an open question stay content', () {
      final result = projector.project(
        documentOf([
          _paragraph('18.', role: SourceContentRole.answerLike),
          _paragraph('(1)【解】sub solution', role: SourceContentRole.paragraph),
          _paragraph('(2)【解】sub solution', role: SourceContentRole.paragraph),
        ]),
      );

      expect(result.fragments, hasLength(1));
      final numbers = result.fragments
          .map((fragment) => fragment.normalizedMainNumber)
          .toList();
      expect(numbers, ['18']);
      expect(numbers, isNot(contains('1')));
      expect(numbers, isNot(contains('2')));
    });

    test('a bracket number without field evidence stays content', () {
      final result = projector.project(
        documentOf([
          _paragraph('(3) plain line', role: SourceContentRole.answerLike),
        ]),
      );

      expect(result.fragments, isEmpty);
      expect(
        result.issues.map((issue) => issue.kind),
        contains(
          SupplementalProjectionIssueKind.continuationWithoutFragmentSkipped,
        ),
      );
    });
  });

  group('assembled content admission', () {
    SourceDocument documentOf(List<SourceContentPart> parts) {
      return SourceDocument(sourceId: 'artifact_001', parts: parts);
    }

    test('content beyond the scalar budget never becomes a fragment', () {
      final result = projector.project(
        documentOf([
          _paragraph('1. 答案：A', role: SourceContentRole.answerLike),
          _paragraph('a' * 3000, role: SourceContentRole.paragraph),
          _paragraph('b' * 3000, role: SourceContentRole.paragraph),
          _paragraph('c' * 3000, role: SourceContentRole.paragraph),
        ]),
      );

      expect(result.fragments, isEmpty);
      expect(
        result.issues.map((issue) => issue.kind),
        contains(SupplementalProjectionIssueKind.contentAdmissionRejected),
      );
    });

    test('content beyond the node bound never becomes a fragment', () {
      final result = projector.project(
        documentOf([
          _paragraph('1. 答案：A', role: SourceContentRole.answerLike),
          for (var index = 0; index < 260; index++)
            _paragraph('line $index', role: SourceContentRole.paragraph),
        ]),
      );

      expect(result.fragments, isEmpty);
      expect(
        result.issues.map((issue) => issue.kind),
        contains(SupplementalProjectionIssueKind.contentAdmissionRejected),
      );
    });

    test('a solution block beyond admission never becomes a fragment', () {
      final result = projector.project(
        documentOf([
          _paragraph('(15)【解】', role: SourceContentRole.answerLike),
          _paragraph('a' * 3000, role: SourceContentRole.paragraph),
          _paragraph('b' * 3000, role: SourceContentRole.paragraph),
          _paragraph('c' * 3000, role: SourceContentRole.paragraph),
        ]),
      );

      expect(result.fragments, isEmpty);
      expect(
        result.issues.map((issue) => issue.kind),
        contains(SupplementalProjectionIssueKind.contentAdmissionRejected),
      );
    });
  });
}

List<String> _texts(RichContent content) {
  return [
    for (final node in content.nodes)
      if (node is TextNode) node.text,
  ];
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

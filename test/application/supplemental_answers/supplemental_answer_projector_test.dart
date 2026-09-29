import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/supplemental_answers/supplemental_answer_projector.dart';
import 'package:shiroha_quiz/domain/assets/asset_ref.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/source/source_document.dart';
import 'package:shiroha_quiz/domain/source/source_part.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/domain/supplemental_answers/rich_content_equality.dart';
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

  group('fragmented text-run parts', () {
    SourceDocument documentOf(List<SourcePart> parts) {
      return SourceDocument(sourceId: 'artifact_001', parts: parts);
    }

    List<SupplementalProjectionIssueKind> kindsOf(
      SupplementalProjectionResult result,
    ) {
      return result.issues.map((issue) => issue.kind).toList(growable: false);
    }

    test('recovers a bracket choice answer split across text runs', () {
      final result = projector.project(
        documentOf([
          _paragraph('(1)', role: SourceContentRole.paragraph),
          _paragraph('【', role: SourceContentRole.paragraph),
          _paragraph('答案', role: SourceContentRole.paragraph),
          _paragraph('】', role: SourceContentRole.paragraph),
          _paragraph('(C).', role: SourceContentRole.paragraph),
          _paragraph('【', role: SourceContentRole.paragraph),
          _paragraph('解', role: SourceContentRole.paragraph),
          _paragraph('】', role: SourceContentRole.paragraph),
          _paragraph('reason', role: SourceContentRole.paragraph),
        ]),
      );

      expect(result.fragments, hasLength(1));
      final fragment = result.fragments.single;
      expect(fragment.normalizedMainNumber, '1');
      expect(fragment.source, SupplementalAnswerSource.explicitAnswer);
      expect(_texts(fragment.answerContent), ['(C).']);
      expect(_texts(fragment.explanationContent!), contains('reason'));
      expect(_texts(fragment.explanationContent!), isNot(contains('(C).')));
      expect(fragment.sourceRefs.single.sourceId, 'artifact_001');
      expect(kindsOf(result), isEmpty);
    });

    test('recovers a fragmented explicit content answer', () {
      final result = projector.project(
        documentOf([
          _paragraph('(9)', role: SourceContentRole.paragraph),
          _paragraph('【', role: SourceContentRole.paragraph),
          _paragraph('答案', role: SourceContentRole.paragraph),
          _paragraph('】', role: SourceContentRole.paragraph),
          _paragraph('x + y', role: SourceContentRole.paragraph),
          _paragraph('【', role: SourceContentRole.paragraph),
          _paragraph('解', role: SourceContentRole.paragraph),
          _paragraph('】', role: SourceContentRole.paragraph),
          _paragraph('derivation', role: SourceContentRole.paragraph),
        ]),
      );

      expect(result.fragments, hasLength(1));
      final fragment = result.fragments.single;
      expect(fragment.normalizedMainNumber, '9');
      expect(fragment.source, SupplementalAnswerSource.explicitAnswer);
      expect(_texts(fragment.answerContent), ['x + y']);
      expect(_texts(fragment.explanationContent!), contains('derivation'));
    });

    test('keeps whole markers that were never split', () {
      final result = projector.project(
        documentOf([
          _paragraph('(2)', role: SourceContentRole.paragraph),
          _paragraph('【答案】', role: SourceContentRole.paragraph),
          _paragraph('(B).', role: SourceContentRole.paragraph),
        ]),
      );

      expect(result.fragments, hasLength(1));
      expect(result.fragments.single.normalizedMainNumber, '2');
      expect(_texts(result.fragments.single.answerContent), ['(B).']);
    });

    test('a document title year never opens a fragment', () {
      final result = projector.project(
        documentOf([
          _paragraph('2019年数学（一）真题解析', role: SourceContentRole.paragraph),
          _paragraph('一、选择题', role: SourceContentRole.paragraph),
        ]),
      );

      expect(result.fragments, isEmpty);
      expect(
        result.fragments.map((fragment) => fragment.normalizedMainNumber),
        isNot(contains('2019')),
      );
      expect(
        kindsOf(result),
        isNot(
          contains(
            SupplementalProjectionIssueKind.contentAdmissionRejected,
          ),
        ),
      );
    });

    test('a bare number stays content while a fragment is open', () {
      final result = projector.project(
        documentOf([
          _paragraph('1. A', role: SourceContentRole.answerLike),
          _paragraph('2019', role: SourceContentRole.paragraph),
        ]),
      );

      expect(result.fragments, hasLength(1));
      expect(result.fragments.single.normalizedMainNumber, '1');
      expect(_texts(result.fragments.single.answerContent), ['A', '2019']);
    });

    test('separated locators keep their existing contract', () {
      final result = projector.project(
        documentOf([
          _paragraph('1. A', role: SourceContentRole.answerLike),
          _paragraph('2．B', role: SourceContentRole.answerLike),
          _paragraph('3、C', role: SourceContentRole.answerLike),
          _paragraph('第4题：D', role: SourceContentRole.answerLike),
        ]),
      );

      expect(
        result.fragments.map((fragment) => fragment.normalizedMainNumber),
        ['1', '2', '3', '4'],
      );
      expect(
        result.fragments.map((fragment) => _texts(fragment.answerContent)),
        [
          ['A'],
          ['B'],
          ['C'],
          ['D'],
        ],
      );
    });

    test('never joins a locator across a structural part boundary', () {
      final splitMarker = <SourceContentPart>[
        _paragraph('【', role: SourceContentRole.paragraph),
        _paragraph('答案', role: SourceContentRole.paragraph),
        _paragraph('】', role: SourceContentRole.paragraph),
        _paragraph('(C).', role: SourceContentRole.paragraph),
      ];
      final boundaries = <SourcePart>[
        SourceTablePart(
          sourceRef: SourceRef.document(sourceId: 'artifact_001'),
          rows: [
            [_text('题号'), _text('7')],
            [_text('答案'), _text('B')],
          ],
        ),
        SourceAssetPart(
          sourceRef: SourceRef.document(sourceId: 'artifact_001'),
          asset: AssetRef(assetId: 'asset_001', kind: AssetKind.image),
        ),
        UnsupportedSourcePart(
          sourceRef: SourceRef.document(sourceId: 'artifact_001'),
          kindCode: 'parsed_source_boundary',
          fallbackContent: _text('[Source]'),
        ),
      ];

      for (final boundary in boundaries) {
        final result = projector.project(
          documentOf([
            _paragraph('(1)', role: SourceContentRole.paragraph),
            boundary,
            ...splitMarker,
          ]),
        );
        expect(
          result.fragments.map((fragment) => fragment.normalizedMainNumber),
          isNot(contains('1')),
          reason: '${boundary.runtimeType} must end the recognition window',
        );
      }
    });

    test('a heading ends the recognition window', () {
      final result = projector.project(
        documentOf([
          _paragraph('(1)', role: SourceContentRole.paragraph),
          _paragraph('二、填空题', role: SourceContentRole.heading),
          _paragraph('【', role: SourceContentRole.paragraph),
          _paragraph('答案', role: SourceContentRole.paragraph),
          _paragraph('】', role: SourceContentRole.paragraph),
          _paragraph('(C).', role: SourceContentRole.paragraph),
        ]),
      );

      expect(result.fragments, isEmpty);
    });

    test('a part carrying a structured node ends the recognition window', () {
      final result = projector.project(
        documentOf([
          _paragraph('(1)', role: SourceContentRole.paragraph),
          SourceContentPart(
            sourceRef: SourceRef.document(sourceId: 'artifact_001'),
            content: RichContent(nodes: <ContentNode>[
              TextNode('【'),
              InlineMathNode('\\answer'),
            ]),
            role: SourceContentRole.formula,
          ),
          _paragraph('答案', role: SourceContentRole.paragraph),
          _paragraph('】', role: SourceContentRole.paragraph),
        ]),
      );

      expect(result.fragments, isEmpty);
    });

    test('recognition never joins more parts than the bounded window', () {
      final result = projector.project(
        documentOf([
          _paragraph('(1)', role: SourceContentRole.paragraph),
          for (var index = 0; index < 8; index++)
            _paragraph('x', role: SourceContentRole.paragraph),
          _paragraph('【', role: SourceContentRole.paragraph),
          _paragraph('答案', role: SourceContentRole.paragraph),
          _paragraph('】', role: SourceContentRole.paragraph),
          _paragraph('(C).', role: SourceContentRole.paragraph),
        ]),
      );

      expect(result.fragments, isEmpty);
    });

    test('recognition never joins beyond the bounded character window', () {
      final result = projector.project(
        documentOf([
          _paragraph('(1)', role: SourceContentRole.paragraph),
          _paragraph('y' * 200, role: SourceContentRole.paragraph),
          _paragraph('【', role: SourceContentRole.paragraph),
          _paragraph('答案', role: SourceContentRole.paragraph),
          _paragraph('】', role: SourceContentRole.paragraph),
        ]),
      );

      expect(result.fragments, isEmpty);
    });

    test('an adjacent proven locator ends the recognition window', () {
      final result = projector.project(
        documentOf([
          _paragraph('(1)', role: SourceContentRole.paragraph),
          _paragraph('(2)【答案】B', role: SourceContentRole.paragraph),
        ]),
      );

      expect(
        result.fragments.map((fragment) => fragment.normalizedMainNumber),
        ['2'],
      );
      expect(_texts(result.fragments.single.answerContent), ['B']);
    });

    test('a fragmented sub-solution under an open question stays content', () {
      final result = projector.project(
        documentOf([
          _paragraph('18.', role: SourceContentRole.answerLike),
          _paragraph('(1)', role: SourceContentRole.paragraph),
          _paragraph('【', role: SourceContentRole.paragraph),
          _paragraph('解', role: SourceContentRole.paragraph),
          _paragraph('】', role: SourceContentRole.paragraph),
          _paragraph('sub solution', role: SourceContentRole.paragraph),
        ]),
      );

      expect(result.fragments, hasLength(1));
      expect(result.fragments.single.normalizedMainNumber, '18');
    });
  });

  group('answer part-boundary evidence', () {
    SourceDocument documentOf(List<SourcePart> parts) {
      return SourceDocument(sourceId: 'artifact_001', parts: parts);
    }

    test('binds every fragmented answer part to its own source part', () {
      final document = documentOf([
        _paragraphAt('(6)', role: SourceContentRole.paragraph, page: 1),
        _paragraphAt('【答案】', role: SourceContentRole.paragraph, page: 1),
        _paragraphAt('(', role: SourceContentRole.paragraph, page: 2),
        _paragraphAt('A).', role: SourceContentRole.paragraph, page: 2),
        _paragraphAt(
          'solution prose',
          role: SourceContentRole.paragraph,
          page: 3,
        ),
      ]);

      final result = projector.project(document);

      expect(result.fragments, hasLength(1));
      final fragment = result.fragments.single;
      expect(fragment.normalizedMainNumber, '6');
      // The answer is never truncated to fit a seal candidate.
      expect(_texts(fragment.answerContent), ['(', 'A).', 'solution prose']);
      expect(fragment.explanationContent, isNull);
      expect(
        fragment.answerPartEvidence.map((segment) => segment.partIndex),
        [2, 3, 4],
      );
      expect(
        fragment.answerPartEvidence.map(
          (segment) => (segment.answerNodeStart, segment.answerNodeEnd),
        ),
        [(0, 1), (1, 2), (2, 3)],
      );
      expect(
        fragment.answerPartEvidence.map(
          (segment) => _texts(segment.content).join(),
        ),
        ['(', 'A).', 'solution prose'],
      );
      for (final segment in fragment.answerPartEvidence) {
        expect(segment.sourceRef,
            same(document.parts[segment.partIndex].sourceRef));
        expect(
          richContentEquals(
            RichContent(
              nodes: fragment.answerContent.nodes.sublist(
                segment.answerNodeStart,
                segment.answerNodeEnd,
              ),
            ),
            segment.content,
          ),
          isTrue,
        );
      }
    });

    test('keeps part order and node ranges across a recovered marker', () {
      final result = projector.project(
        documentOf([
          _paragraph('(1)', role: SourceContentRole.paragraph),
          _paragraph('【', role: SourceContentRole.paragraph),
          _paragraph('答案', role: SourceContentRole.paragraph),
          _paragraph('】', role: SourceContentRole.paragraph),
          _paragraph('(C).', role: SourceContentRole.paragraph),
          _paragraph('【', role: SourceContentRole.paragraph),
          _paragraph('解', role: SourceContentRole.paragraph),
          _paragraph('】', role: SourceContentRole.paragraph),
          _paragraph('reason', role: SourceContentRole.paragraph),
        ]),
      );

      final fragment = result.fragments.single;
      expect(_texts(fragment.answerContent), ['(C).']);
      final segment = fragment.answerPartEvidence.single;
      expect(segment.partIndex, 4);
      expect(segment.answerNodeStart, 0);
      expect(segment.answerNodeEnd, 1);
      expect(_texts(segment.content), ['(C).']);
      // The explanation keeps its own marker-proven content only.
      expect(_texts(fragment.explanationContent!), contains('reason'));
      expect(_texts(fragment.explanationContent!), isNot(contains('(C).')));
    });

    test('a same-part answer keeps exactly one segment', () {
      final result = projector.project(
        documentOf([
          _paragraph('(3)【答案】D', role: SourceContentRole.answerLike),
        ]),
      );

      final fragment = result.fragments.single;
      expect(_texts(fragment.answerContent), ['D']);
      final segments = fragment.answerPartEvidence;
      expect(segments, hasLength(1));
      expect(segments.single.partIndex, 0);
      expect(segments.single.answerNodeStart, 0);
      expect(segments.single.answerNodeEnd, 1);
    });

    test('an answer without a part boundary keeps absent evidence', () {
      final result = projector.project(
        documentOf([
          _paragraph('1. ', role: SourceContentRole.answerLike),
        ]),
      );

      expect(result.fragments, isEmpty);
    });

    test('table and asset parts never fabricate text-part evidence', () {
      final tableDocument = documentOf([
        SourceTablePart(
          sourceRef: SourceRef.document(sourceId: 'artifact_001'),
          rows: [
            [_text('题号'), _text('1'), _text('2')],
            [_text('答案'), _text('A'), _text('C')],
          ],
        ),
      ]);

      final tableFragments = projector.project(tableDocument).fragments;

      expect(
        tableFragments.map((fragment) => _texts(fragment.answerContent)),
        [
          ['A'],
          ['C'],
        ],
      );
      expect(
        tableFragments.every(
          (fragment) => fragment.answerPartEvidence.isEmpty,
        ),
        isTrue,
      );

      final assetDocument = documentOf([
        _paragraph('(4)【答案】', role: SourceContentRole.paragraph),
        SourceAssetPart(
          sourceRef: SourceRef.document(sourceId: 'artifact_001'),
          asset: AssetRef(assetId: 'asset_001', kind: AssetKind.image),
          alternativeText: _text('figure one'),
        ),
        UnsupportedSourcePart(
          sourceRef: SourceRef.document(sourceId: 'artifact_001'),
          kindCode: 'parsed_source_boundary',
          fallbackContent: _text('[Source]'),
        ),
      ]);

      final assetFragment = projector.project(assetDocument).fragments.single;

      expect(_texts(assetFragment.answerContent), ['figure one']);
      expect(assetFragment.sourceRefs, hasLength(1));
      expect(assetFragment.answerPartEvidence, isEmpty);
    });

    test('a solution block never claims answer part evidence', () {
      final result = projector.project(
        documentOf([
          _paragraph('(15)【解】', role: SourceContentRole.answerLike),
          _paragraph('step-a', role: SourceContentRole.paragraph),
        ]),
      );

      final fragment = result.fragments.single;
      expect(fragment.source, SupplementalAnswerSource.solutionBlock);
      expect(_texts(fragment.answerContent), ['【解】', 'step-a']);
      expect(fragment.answerPartEvidence, isEmpty);
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

SourceContentPart _paragraphAt(
  String text, {
  required SourceContentRole role,
  required int page,
}) {
  return SourceContentPart(
    sourceRef: SourceRef.at(
      sourceId: 'artifact_001',
      point: SourcePoint.page(pageNumber: page),
    ),
    content: _text(text),
    role: role,
  );
}

RichContent _text(String text) {
  return RichContent(nodes: [TextNode(text)]);
}

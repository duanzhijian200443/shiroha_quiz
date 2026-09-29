import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/domain/supplemental_answers/supplemental_answer_fragment.dart';

void main() {
  group('SupplementalAnswerPartSegment', () {
    test('binds one part to one answer node range', () {
      final segment = SupplementalAnswerPartSegment(
        partIndex: 4,
        answerNodeStart: 1,
        answerNodeEnd: 2,
        content: _text('A).'),
        sourceRef: _ref(),
      );

      expect(segment.partIndex, 4);
      expect(segment.answerNodeStart, 1);
      expect(segment.answerNodeEnd, 2);
      expect(segment.content.nodes, hasLength(1));
      expect(segment.sourceRef, _ref());
      expect(
        segment,
        SupplementalAnswerPartSegment(
          partIndex: 4,
          answerNodeStart: 1,
          answerNodeEnd: 2,
          content: _text('A).'),
          sourceRef: _ref(),
        ),
      );
      expect(
        segment.hashCode,
        SupplementalAnswerPartSegment(
          partIndex: 4,
          answerNodeStart: 1,
          answerNodeEnd: 2,
          content: _text('A).'),
          sourceRef: _ref(),
        ).hashCode,
      );
      expect(
        segment,
        isNot(
          SupplementalAnswerPartSegment(
            partIndex: 5,
            answerNodeStart: 1,
            answerNodeEnd: 2,
            content: _text('A).'),
            sourceRef: _ref(),
          ),
        ),
      );
    });

    test('rejects a content that does not match its node range', () {
      expect(
        () => SupplementalAnswerPartSegment(
          partIndex: 0,
          answerNodeStart: 0,
          answerNodeEnd: 2,
          content: _text('A).'),
          sourceRef: _ref(),
        ),
        throwsFormatException,
      );
    });

    test('rejects a negative part index or an empty node range', () {
      expect(
        () => SupplementalAnswerPartSegment(
          partIndex: -1,
          answerNodeStart: 0,
          answerNodeEnd: 1,
          content: _text('A'),
          sourceRef: _ref(),
        ),
        throwsFormatException,
      );
      expect(
        () => SupplementalAnswerPartSegment(
          partIndex: 0,
          answerNodeStart: 3,
          answerNodeEnd: 3,
          content: RichContent(nodes: const <ContentNode>[]),
          sourceRef: _ref(),
        ),
        throwsFormatException,
      );
    });
  });

  group('SupplementalAnswerFragment part evidence', () {
    test('defaults to absent evidence and keeps legacy fragments equal', () {
      final legacy = _fragment();
      final explicitEmpty = _fragment(
        evidence: const <SupplementalAnswerPartSegment>[],
      );

      expect(legacy.answerPartEvidence, isEmpty);
      expect(legacy, explicitEmpty);
      expect(legacy.hashCode, explicitEmpty.hashCode);
    });

    test('keeps ordered evidence as an immutable defensive copy', () {
      final segments = <SupplementalAnswerPartSegment>[
        _segment(partIndex: 2, start: 0, end: 1, text: '('),
        _segment(partIndex: 3, start: 1, end: 2, text: 'A).'),
      ];
      final fragment = _fragment(
        answerContent: _nodes(['(', 'A).']),
        evidence: segments,
      );

      expect(fragment.answerPartEvidence, hasLength(2));
      expect(
        fragment.answerPartEvidence.map((segment) => segment.partIndex),
        [2, 3],
      );

      segments.removeLast();
      expect(fragment.answerPartEvidence, hasLength(2));
      expect(
        () => fragment.answerPartEvidence.add(
          _segment(partIndex: 4, start: 2, end: 3, text: 'tail'),
        ),
        throwsUnsupportedError,
      );
    });

    test('part evidence participates in fragment equality', () {
      final withEvidence = _fragment(
        evidence: <SupplementalAnswerPartSegment>[
          _segment(partIndex: 2, start: 0, end: 1, text: 'x = 2'),
        ],
      );

      expect(withEvidence, isNot(_fragment()));
      expect(
        withEvidence,
        _fragment(
          evidence: <SupplementalAnswerPartSegment>[
            _segment(partIndex: 2, start: 0, end: 1, text: 'x = 2'),
          ],
        ),
      );
      expect(
        withEvidence,
        isNot(
          _fragment(
            evidence: <SupplementalAnswerPartSegment>[
              _segment(partIndex: 3, start: 0, end: 1, text: 'x = 2'),
            ],
          ),
        ),
      );
    });

    test('rejects a segment whose content is not the answer node range', () {
      expect(
        () => _fragment(
          answerContent: _nodes(['(', 'A).']),
          evidence: <SupplementalAnswerPartSegment>[
            SupplementalAnswerPartSegment(
              partIndex: 2,
              answerNodeStart: 0,
              answerNodeEnd: 1,
              content: _text('('),
              sourceRef: _ref(),
            ),
            // Same node count, same range shape, different content.
            SupplementalAnswerPartSegment(
              partIndex: 3,
              answerNodeStart: 1,
              answerNodeEnd: 2,
              content: _text('B).'),
              sourceRef: _ref(),
            ),
          ],
        ),
        throwsFormatException,
      );
    });

    test('rejects evidence that leaves the fragment source', () {
      expect(
        () => _fragment(
          evidence: <SupplementalAnswerPartSegment>[
            SupplementalAnswerPartSegment(
              partIndex: 0,
              answerNodeStart: 0,
              answerNodeEnd: 1,
              content: _text('x = 2'),
              sourceRef: SourceRef.document(sourceId: 'artifact_other'),
            ),
          ],
        ),
        throwsFormatException,
      );
    });

    test('rejects a same-artifact ref that is not a fragment ref', () {
      expect(
        () => _fragment(
          evidence: <SupplementalAnswerPartSegment>[
            SupplementalAnswerPartSegment(
              partIndex: 0,
              answerNodeStart: 0,
              answerNodeEnd: 1,
              content: _text('x = 2'),
              sourceRef: SourceRef.at(
                sourceId: 'artifact_001',
                point: SourcePoint.page(pageNumber: 9),
              ),
            ),
          ],
        ),
        throwsFormatException,
      );
    });

    test('rejects evidence whose part order does not increase', () {
      RichContent answer() => _nodes(['a', 'b']);

      expect(
        () => _fragment(
          answerContent: answer(),
          evidence: <SupplementalAnswerPartSegment>[
            _segment(partIndex: 3, start: 0, end: 1, text: 'a'),
            _segment(partIndex: 3, start: 1, end: 2, text: 'b'),
          ],
        ),
        throwsFormatException,
      );
      expect(
        () => _fragment(
          answerContent: answer(),
          evidence: <SupplementalAnswerPartSegment>[
            _segment(partIndex: 5, start: 0, end: 1, text: 'a'),
            _segment(partIndex: 4, start: 1, end: 2, text: 'b'),
          ],
        ),
        throwsFormatException,
      );
    });

    test('rejects unordered or overlapping evidence', () {
      expect(
        () => _fragment(
          evidence: <SupplementalAnswerPartSegment>[
            _segment(partIndex: 3, start: 1, end: 2, text: 'b'),
            _segment(partIndex: 2, start: 0, end: 1, text: 'a'),
          ],
        ),
        throwsFormatException,
      );
      expect(
        () => _fragment(
          evidence: <SupplementalAnswerPartSegment>[
            SupplementalAnswerPartSegment(
              partIndex: 2,
              answerNodeStart: 0,
              answerNodeEnd: 2,
              content: _nodes(['a', 'b']),
              sourceRef: _ref(),
            ),
            SupplementalAnswerPartSegment(
              partIndex: 3,
              answerNodeStart: 1,
              answerNodeEnd: 3,
              content: _nodes(['b', 'c']),
              sourceRef: _ref(),
            ),
          ],
        ),
        throwsFormatException,
      );
    });

    test('rejects evidence outside the answer content', () {
      expect(
        () => _fragment(
          evidence: <SupplementalAnswerPartSegment>[
            _segment(partIndex: 2, start: 0, end: 1, text: 'x = 2'),
            _segment(partIndex: 3, start: 1, end: 2, text: 'tail'),
          ],
        ),
        throwsFormatException,
      );
    });
  });
}

SupplementalAnswerPartSegment _segment({
  required int partIndex,
  required int start,
  required int end,
  required String text,
}) {
  return SupplementalAnswerPartSegment(
    partIndex: partIndex,
    answerNodeStart: start,
    answerNodeEnd: end,
    content: _text(text),
    sourceRef: _ref(),
  );
}

SupplementalAnswerFragment _fragment({
  Iterable<SupplementalAnswerPartSegment> evidence =
      const <SupplementalAnswerPartSegment>[],
  RichContent? answerContent,
}) {
  return SupplementalAnswerFragment(
    fragmentId: 'fragment_001',
    normalizedMainNumber: '1',
    answerContent: answerContent ?? _text('x = 2'),
    sourceRefs: [_ref()],
    sequencePosition: const SupplementalSequencePosition(
      partIndex: 0,
      continuationOrdinal: 0,
    ),
    answerPartEvidence: evidence,
  );
}

SourceRef _ref() {
  return SourceRef.document(sourceId: 'artifact_001');
}

RichContent _text(String text) {
  return RichContent(nodes: [TextNode(text)]);
}

RichContent _nodes(List<String> texts) {
  return RichContent(nodes: [for (final text in texts) TextNode(text)]);
}

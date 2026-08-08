// Stem preview normalization and safe content projection unit tests.
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/study_query/study_query_dtos.dart';
import 'package:shiroha_quiz/application/study_query/study_query_stem_preview.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';

import 'study_query_test_support.dart';

void main() {
  const normalizer = StemPreviewNormalizer();

  group('plain text normalization', () {
    test('collapses consecutive whitespace and trims', () {
      expect(normalizer.normalizeText('  a \t\n  b   '), 'a b');
      expect(normalizer.normalizeText('single'), 'single');
      expect(normalizer.normalizeText('   '), '');
    });

    test('truncates over 160 grapheme clusters to 159 plus ellipsis', () {
      final long = 'x' * 200;
      final preview = normalizer.normalizeText(long);
      expect(preview, 'x' * 159 + '\u2026');
      expect(splitGraphemeClusters(preview), hasLength(160));
    });

    test('stays intact at exactly 160 clusters', () {
      final value = 'y' * 160;
      expect(normalizer.normalizeText(value), value);
    });
  });

  group('grapheme clusters', () {
    test('combining marks, ZWJ families, flags, and skin tones are atomic', () {
      expect(splitGraphemeClusters('a\u0301'), <String>['a\u0301']);
      expect(splitGraphemeClusters('\u{1F468}\u200D\u{1F469}\u200D\u{1F467}'),
          <String>['\u{1F468}\u200D\u{1F469}\u200D\u{1F467}']);
      expect(splitGraphemeClusters('\u{1F1E8}\u{1F1F3}'),
          <String>['\u{1F1E8}\u{1F1F3}']);
      expect(splitGraphemeClusters('\u{1F44D}\u{1F3FD}'),
          <String>['\u{1F44D}\u{1F3FD}']);
      expect(splitGraphemeClusters('ab'), <String>['a', 'b']);
      expect(
        splitGraphemeClusters('a\u0301b'),
        <String>['a\u0301', 'b'],
      );
    });

    test('truncation keeps emoji sequences as single clusters', () {
      final value = 'a' * 158 + '\u{1F468}\u200D\u{1F469}\u200D\u{1F467}bc';
      final preview = normalizer.normalizeText(value);
      expect(
          preview, 'a' * 158 + '\u{1F468}\u200D\u{1F469}\u200D\u{1F467}\u2026');
      expect(splitGraphemeClusters(preview), hasLength(160));
    });
  });

  group('typed content projection', () {
    test('text and math contribute; raw fallback never leaks', () {
      final content = richContent(<ContentNode>[
        const TextNode('Solve  '),
        const InlineMathNode(r'x^2=1'),
        RawFallbackNode(rawFallbackPayload('private-marker')),
        const BlockMathNode(r'\int_0^1'),
      ]);

      final preview = normalizer.fromRichContent(content);
      expect(preview, r'Solve x^2=1\int_0^1');
      expect(preview, isNot(contains('private-marker')));
      expect(preview, isNot(contains('raw_fallback')));
    });

    test('projectNodes maps every node kind exactly once', () {
      final content = richContent(<ContentNode>[
        const TextNode('t'),
        const InlineMathNode('i'),
        const BlockMathNode('b'),
        RawFallbackNode(rawFallbackPayload('marker')),
      ]);

      final nodes = StemPreviewNormalizer.projectNodes(content);
      expect(nodes, hasLength(4));
      expect(nodes[0], isA<StudyTextNode>());
      expect(nodes[1], isA<StudyInlineMathNode>());
      expect(nodes[2], isA<StudyBlockMathNode>());
      expect(nodes[3], isA<StudyUnsupportedNode>());
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/answers/ai_answer_provider.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';

void main() {
  group('AiAnswerSafeContent egress boundary', () {
    test('admits only text and math nodes', () {
      final content = AiAnswerSafeContent.from(
        RichContent(nodes: [
          TextNode('x = 1'),
          InlineMathNode(r'\frac{1}{2}'),
          BlockMathNode(r'\int_0^1 x\,dx'),
        ]),
      );
      expect(content.nodes, hasLength(3));
      expect(content.nodes[0], const AiAnswerSafeText('x = 1'));
      expect(
        content.nodes[1],
        const AiAnswerSafeInlineMath(r'\frac{1}{2}'),
      );
      expect(
        content.nodes[2],
        const AiAnswerSafeBlockMath(r'\int_0^1 x\,dx'),
      );
      expect(content.hasVisiblePayload, isTrue);
    });

    test('rejects RawFallbackNode and never drops it silently', () {
      expect(
        () => AiAnswerSafeContent.from(
          RichContent(nodes: [
            RawFallbackNode(<String, Object?>{
              'type': 'raw_fallback',
              'payload': <String, Object?>{'secret': 'nope'},
            }),
          ]),
        ),
        throwsFormatException,
      );
      expect(
        () => AiAnswerSafeContent.from(
          RichContent(nodes: [
            TextNode('ok'),
            RawFallbackNode(
              <String, Object?>{'type': 'raw_fallback', 'payload': null},
            )
          ]),
        ),
        throwsFormatException,
      );
    });

    test('is immutable and has stable value semantics', () {
      final content = AiAnswerSafeContent.from(
        RichContent(nodes: [TextNode('x')]),
      );
      expect(
        () => content.nodes.add(const AiAnswerSafeText('y')),
        throwsUnsupportedError,
      );
      expect(
        content,
        AiAnswerSafeContent.from(RichContent(nodes: [TextNode('x')])),
      );
      expect(
        content ==
            AiAnswerSafeContent.from(RichContent(nodes: [TextNode('y')])),
        isFalse,
      );
    });

    test('visible payload detection ignores whitespace-only nodes', () {
      expect(
        AiAnswerSafeContent.from(RichContent(nodes: const []))
            .hasVisiblePayload,
        isFalse,
      );
      expect(
        AiAnswerSafeContent.from(
          RichContent(nodes: [TextNode('   ')]),
        ).hasVisiblePayload,
        isFalse,
      );
      expect(
        AiAnswerSafeContent.from(
          RichContent(nodes: [InlineMathNode('  ')]),
        ).hasVisiblePayload,
        isFalse,
      );
    });
  });

  group('AiAnswerProviderRequest boundary', () {
    test('singleChoice request requires and preserves option identities', () {
      final request = AiAnswerProviderRequest(
        kind: QuestionKind.singleChoice,
        stem: AiAnswerSafeContent.from(
          RichContent(nodes: [TextNode('stem')]),
        ),
        options: [
          AiAnswerSafeOption(
            optionId: 'opt_a',
            label: 'A',
            content: AiAnswerSafeContent.from(
              RichContent(nodes: [TextNode('option A')]),
            ),
          ),
          AiAnswerSafeOption(
            optionId: 'opt_b',
            label: 'B',
            content: AiAnswerSafeContent.from(
              RichContent(nodes: [TextNode('option B')]),
            ),
          ),
        ],
      );
      expect(request.kind, QuestionKind.singleChoice);
      expect(
        request.options.map((option) => option.optionId),
        ['opt_a', 'opt_b'],
      );
      expect(
        () => request.options.clear(),
        throwsUnsupportedError,
      );
      expect(
        () => AiAnswerProviderRequest(
          kind: QuestionKind.singleChoice,
          stem: request.stem,
        ),
        throwsFormatException,
      );
    });

    test('content requests reject choice options', () {
      for (final kind in [QuestionKind.fillBlank, QuestionKind.shortAnswer]) {
        expect(
          () => AiAnswerProviderRequest(
            kind: kind,
            stem: AiAnswerSafeContent.from(
              RichContent(nodes: [TextNode('stem')]),
            ),
            options: [
              AiAnswerSafeOption(
                optionId: 'opt_a',
                label: 'A',
                content: AiAnswerSafeContent.from(
                  RichContent(nodes: [TextNode('option A')]),
                ),
              ),
            ],
          ),
          throwsFormatException,
        );
        final request = AiAnswerProviderRequest(
          kind: kind,
          stem: AiAnswerSafeContent.from(
            RichContent(nodes: [TextNode('stem')]),
          ),
        );
        expect(request.options, isEmpty);
        expect(request.kind, kind);
      }
    });

    test('request shape structurally carries no forbidden fields', () {
      // The request exposes only kind / stem / options; storageId, bankName,
      // questionId, SourceRef, AssetRef, issues, current answer, explanation,
      // paths, and Base64 have no representation in the type. The wire-level
      // privacy proof is pinned by the adapter test with sentinels.
      final request = AiAnswerProviderRequest(
        kind: QuestionKind.shortAnswer,
        stem: AiAnswerSafeContent.from(
          RichContent(nodes: [TextNode('stem')]),
        ),
      );
      expect(request.kind, QuestionKind.shortAnswer);
      expect(request.stem.nodes, hasLength(1));
      expect(request.options, isEmpty);
    });
  });

  group('typed failure taxonomy', () {
    test('every D1 failure renders a fixed safe message', () {
      for (final failure in AiAnswerProviderFailure.values) {
        final message = AiAnswerProviderException(failure).toString();
        expect(message, contains('AiAnswerProviderException'));
        expect(message, isNot(contains('http')));
        expect(message, isNot(contains('api_key')));
        expect(message, isNot(contains('Bearer')));
      }
    });
  });
}

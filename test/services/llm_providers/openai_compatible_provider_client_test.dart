import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/llm_providers/openai_compatible_provider_client.dart';

Map<String, Object?> _envelope({
  Object? content = '{"ok":true}',
  Object? reasoningContent,
  String? finishReason = 'stop',
}) {
  return <String, Object?>{
    'choices': <Object?>[
      <String, Object?>{
        'finish_reason': finishReason,
        'message': <String, Object?>{
          'content': content,
          if (reasoningContent != null) 'reasoning_content': reasoningContent,
        },
      },
    ],
  };
}

void main() {
  group('OpenAI-compatible response inspection', () {
    test('preserves normal JSON content and reports bounded shape', () {
      const content = '{"question_number":21}';
      final inspection = OpenAiCompatibleProviderClient.inspectResponse(
        jsonEncode(_envelope(content: content)),
      );

      expect(inspection.content, content);
      expect(inspection.envelopeDecodeSucceeded, isTrue);
      expect(inspection.choicesCount, 1);
      expect(inspection.messagePresent, isTrue);
      expect(inspection.finishReason, 'stop');
      expect(inspection.contentNull, isFalse);
      expect(inspection.contentEmpty, isFalse);
      expect(inspection.contentCharacterLength, content.length);
      expect(
        inspection.classification,
        OpenAiCompatibleResponseClassification.contentPresent,
      );
    });

    test('classifies null and empty content without exposing text', () {
      final inspection = OpenAiCompatibleProviderClient.inspectResponse(
        jsonEncode(_envelope(content: null, finishReason: 'stop')),
      );

      expect(inspection.content, isEmpty);
      expect(inspection.contentNull, isTrue);
      expect(inspection.contentEmpty, isTrue);
      expect(inspection.contentCharacterLength, 0);
      expect(
        inspection.classification,
        OpenAiCompatibleResponseClassification.emptyContent,
      );
    });

    test('preserves the existing reasoning-only fallback and classifies it',
        () {
      const reasoning = 'PRIVATE_REASONING_BODY';
      final responseBody = jsonEncode(
        _envelope(content: '', reasoningContent: reasoning),
      );
      final inspection =
          OpenAiCompatibleProviderClient.inspectResponse(responseBody);

      expect(inspection.content, reasoning);
      expect(
        OpenAiCompatibleProviderClient.extractContent(responseBody),
        reasoning,
      );
      expect(inspection.reasoningContentNull, isFalse);
      expect(inspection.reasoningContentEmpty, isFalse);
      expect(inspection.reasoningContentCharacterLength, reasoning.length);
      expect(
        inspection.classification,
        OpenAiCompatibleResponseClassification.reasoningOnly,
      );
      expect(
        jsonEncode(inspection.diagnosticData),
        isNot(contains(reasoning)),
      );
    });

    test('classifies malformed provider envelopes without throwing', () {
      final wrongShape = OpenAiCompatibleProviderClient.inspectResponse(
        jsonEncode(<String, Object?>{'choices': 'not-a-list'}),
      );
      final malformedJson =
          OpenAiCompatibleProviderClient.inspectResponse('{not-json');

      for (final inspection in <OpenAiCompatibleResponseInspection>[
        wrongShape,
        malformedJson,
      ]) {
        expect(inspection.content, isEmpty);
        expect(inspection.messagePresent, isFalse);
        expect(
          inspection.classification,
          OpenAiCompatibleResponseClassification.invalidEnvelope,
        );
      }
      expect(wrongShape.envelopeDecodeSucceeded, isTrue);
      expect(malformedJson.envelopeDecodeSucceeded, isFalse);
    });

    test('finish_reason length takes diagnostic precedence', () {
      final inspection = OpenAiCompatibleProviderClient.inspectResponse(
        jsonEncode(
          _envelope(
            content: '{"partial":true}',
            reasoningContent: 'PRIVATE_REASONING_BODY',
            finishReason: 'length',
          ),
        ),
      );

      expect(inspection.finishReason, 'length');
      expect(
        inspection.classification,
        OpenAiCompatibleResponseClassification.finishLength,
      );
      expect(inspection.content, '{"partial":true}');
    });

    test('diagnostic shape excludes provider body fields', () {
      const content = 'PRIVATE_RESPONSE_CONTENT';
      const reasoning = 'PRIVATE_REASONING_CONTENT';
      final inspection = OpenAiCompatibleProviderClient.inspectResponse(
        jsonEncode(
          _envelope(content: content, reasoningContent: reasoning),
        ),
      );
      final encoded = jsonEncode(inspection.diagnosticData);

      expect(encoded, isNot(contains(content)));
      expect(encoded, isNot(contains(reasoning)));
      expect(encoded, isNot(contains('choices":[')));
      expect(inspection.toString(), isNot(contains(content)));
    });
  });
}

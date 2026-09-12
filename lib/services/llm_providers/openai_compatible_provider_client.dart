import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/observability/app_logger.dart';
import 'llm_provider_client.dart';

enum OpenAiCompatibleResponseClassification {
  contentPresent,
  emptyContent,
  reasoningOnly,
  finishLength,
  invalidEnvelope,
}

extension on OpenAiCompatibleResponseClassification {
  String get wireName => switch (this) {
        OpenAiCompatibleResponseClassification.contentPresent =>
          'provider_content_present',
        OpenAiCompatibleResponseClassification.emptyContent =>
          'provider_empty_content',
        OpenAiCompatibleResponseClassification.reasoningOnly =>
          'provider_reasoning_only',
        OpenAiCompatibleResponseClassification.finishLength =>
          'provider_finish_length',
        OpenAiCompatibleResponseClassification.invalidEnvelope =>
          'provider_invalid_envelope',
      };
}

/// Transient provider response inspection.
///
/// [content] preserves the legacy extraction result. [diagnosticData] exposes
/// shape-only metadata and never includes response or reasoning text.
final class OpenAiCompatibleResponseInspection {
  const OpenAiCompatibleResponseInspection({
    required this.content,
    required this.envelopeDecodeSucceeded,
    required this.choicesCount,
    required this.messagePresent,
    required this.finishReason,
    required this.contentNull,
    required this.contentEmpty,
    required this.contentCharacterLength,
    required this.reasoningContentNull,
    required this.reasoningContentEmpty,
    required this.reasoningContentCharacterLength,
    required this.classification,
  });

  final String content;
  final bool envelopeDecodeSucceeded;
  final int choicesCount;
  final bool messagePresent;
  final String? finishReason;
  final bool contentNull;
  final bool contentEmpty;
  final int contentCharacterLength;
  final bool reasoningContentNull;
  final bool reasoningContentEmpty;
  final int reasoningContentCharacterLength;
  final OpenAiCompatibleResponseClassification classification;

  Map<String, Object?> get diagnosticData => <String, Object?>{
        'responseEnvelopeDecodeSucceeded': envelopeDecodeSucceeded,
        'choicesCount': choicesCount,
        'messagePresent': messagePresent,
        'finishReason': finishReason,
        'contentNull': contentNull,
        'contentEmpty': contentEmpty,
        'contentCharacterLength': contentCharacterLength,
        'reasoningContentNull': reasoningContentNull,
        'reasoningContentEmpty': reasoningContentEmpty,
        'reasoningContentCharacterLength': reasoningContentCharacterLength,
        'failureClassification': classification.wireName,
      };

  @override
  String toString() => 'OpenAiCompatibleResponseInspection([REDACTED])';
}

class OpenAiCompatibleProviderClient extends LlmProviderClient {
  const OpenAiCompatibleProviderClient();

  static String buildChatUrl(String baseUrl) {
    return baseUrl.endsWith('/v1')
        ? '$baseUrl/chat/completions'
        : '$baseUrl/v1/chat/completions';
  }

  String buildChatUrlFor(String baseUrl) => buildChatUrl(baseUrl);

  static String extractContent(String responseBody) {
    return inspectResponse(responseBody).content;
  }

  static OpenAiCompatibleResponseInspection inspectResponse(
    String responseBody,
  ) {
    try {
      final decoded = jsonDecode(responseBody);
      if (decoded is! Map) {
        return _invalidEnvelope(envelopeDecodeSucceeded: true);
      }
      final choices = decoded['choices'];
      if (choices is! List || choices.isEmpty) {
        return _invalidEnvelope(
          envelopeDecodeSucceeded: true,
          choicesCount: choices is List ? choices.length : 0,
        );
      }
      final firstChoice = choices.first;
      if (firstChoice is! Map) {
        return _invalidEnvelope(
          envelopeDecodeSucceeded: true,
          choicesCount: choices.length,
        );
      }
      final message = firstChoice['message'];
      if (message is! Map) {
        return _invalidEnvelope(
          envelopeDecodeSucceeded: true,
          choicesCount: choices.length,
        );
      }

      final rawContent = message['content'];
      final rawReasoning = message['reasoning_content'];
      final contentText = (rawContent ?? '').toString();
      final reasoningText = (rawReasoning ?? '').toString();
      final contentEmpty = contentText.trim().isEmpty;
      final reasoningEmpty = reasoningText.trim().isEmpty;
      final finishReason = _safeFinishReason(firstChoice['finish_reason']);
      final extractedContent =
          contentEmpty && rawReasoning != null ? reasoningText : contentText;
      final classification = switch ((
        finishReason,
        contentEmpty,
        rawReasoning != null && !reasoningEmpty,
      )) {
        ('length', _, _) => OpenAiCompatibleResponseClassification.finishLength,
        (_, true, true) => OpenAiCompatibleResponseClassification.reasoningOnly,
        (_, true, false) => OpenAiCompatibleResponseClassification.emptyContent,
        _ => OpenAiCompatibleResponseClassification.contentPresent,
      };

      return OpenAiCompatibleResponseInspection(
        content: extractedContent,
        envelopeDecodeSucceeded: true,
        choicesCount: choices.length,
        messagePresent: true,
        finishReason: finishReason,
        contentNull: rawContent == null,
        contentEmpty: contentEmpty,
        contentCharacterLength: contentText.length,
        reasoningContentNull: rawReasoning == null,
        reasoningContentEmpty: reasoningEmpty,
        reasoningContentCharacterLength: reasoningText.length,
        classification: classification,
      );
    } catch (_) {
      return _invalidEnvelope(envelopeDecodeSucceeded: false);
    }
  }

  static OpenAiCompatibleResponseInspection _invalidEnvelope({
    required bool envelopeDecodeSucceeded,
    int choicesCount = 0,
  }) {
    return OpenAiCompatibleResponseInspection(
      content: '',
      envelopeDecodeSucceeded: envelopeDecodeSucceeded,
      choicesCount: choicesCount,
      messagePresent: false,
      finishReason: null,
      contentNull: true,
      contentEmpty: true,
      contentCharacterLength: 0,
      reasoningContentNull: true,
      reasoningContentEmpty: true,
      reasoningContentCharacterLength: 0,
      classification: OpenAiCompatibleResponseClassification.invalidEnvelope,
    );
  }

  static String? _safeFinishReason(Object? value) {
    final normalized = value?.toString().trim().toLowerCase();
    return switch (normalized) {
      null || '' => null,
      'stop' => 'stop',
      'length' => 'length',
      'tool_calls' => 'tool_calls',
      'content_filter' => 'content_filter',
      _ => 'other',
    };
  }

  void _recordResponseInspection({
    required LlmTextRequest request,
    required int httpStatus,
    required OpenAiCompatibleResponseInspection inspection,
  }) {
    AppLogger.info(
      'LLM provider response observed',
      module: 'LlmProvider',
      data: <String, Object?>{
        'providerKind': runtimeType.toString(),
        'modelId': request.model,
        'httpStatus': httpStatus,
        ...inspection.diagnosticData,
      },
    );
  }

  @override
  Future<String> callText(LlmTextRequest request) async {
    final res = await http
        .post(
          Uri.parse(buildChatUrlFor(request.baseUrl)),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer ${request.apiKey}',
          },
          body: jsonEncode(_requestBody(request)),
        )
        .timeout(request.timeout);

    final inspection = inspectResponse(res.body);
    _recordResponseInspection(
      request: request,
      httpStatus: res.statusCode,
      inspection: inspection,
    );
    if (res.statusCode == 200) {
      return inspection.content;
    }
    throw Exception('API Error: ${res.statusCode} - ${res.body}');
  }

  @override
  Future<String> callVision(LlmVisionRequest request) async {
    final res = await http
        .post(
          Uri.parse(buildChatUrlFor(request.baseUrl)),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer ${request.apiKey}',
          },
          body: jsonEncode(_visionRequestBody(request)),
        )
        .timeout(request.timeout);

    if (res.statusCode == 200) {
      return extractContent(res.body);
    }
    throw Exception('Vision API Error: ${res.statusCode} - ${res.body}');
  }

  Map<String, dynamic> _requestBody(LlmTextRequest request) {
    final reqBody = <String, dynamic>{
      'model': request.model,
      'messages': request.chatMessages,
      'max_tokens': request.maxTokens,
    };
    if (request.reasoningEffort.isNotEmpty) {
      reqBody['reasoning_effort'] = request.reasoningEffort;
    } else {
      reqBody['temperature'] = request.temperature;
    }
    if (request.jsonResponse) {
      reqBody['response_format'] = {'type': 'json_object'};
    }
    return reqBody;
  }

  Map<String, dynamic> _visionRequestBody(LlmVisionRequest request) {
    return {
      'model': request.model,
      'messages': [
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': request.prompt},
            ...request.assets.map(_assetToVisionContent),
          ],
        },
      ],
      'temperature': request.temperature,
    };
  }

  Map<String, dynamic> _assetToVisionContent(LlmVisionAsset asset) {
    if (asset.uploadAsFile || !asset.hasInlineData) {
      throw ArgumentError(
        'OpenAI-compatible vision requires inline base64 assets.',
      );
    }
    return {
      'type': 'image_url',
      'image_url': {
        'url': 'data:${asset.mimeType};base64,${asset.base64Data}',
      },
    };
  }
}

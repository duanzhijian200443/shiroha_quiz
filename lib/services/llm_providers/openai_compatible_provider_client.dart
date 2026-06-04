import 'dart:convert';

import 'package:http/http.dart' as http;

import 'llm_provider_client.dart';

class OpenAiCompatibleProviderClient extends LlmProviderClient {
  const OpenAiCompatibleProviderClient();

  static String buildChatUrl(String baseUrl) {
    return baseUrl.endsWith('/v1')
        ? '$baseUrl/chat/completions'
        : '$baseUrl/v1/chat/completions';
  }

  String buildChatUrlFor(String baseUrl) => buildChatUrl(baseUrl);

  static String extractContent(String responseBody) {
    try {
      final message = jsonDecode(responseBody)['choices'][0]['message'];
      String content = (message['content'] ?? '').toString();
      if (content.trim().isEmpty && message['reasoning_content'] != null) {
        content = message['reasoning_content'].toString();
      }
      return content;
    } catch (_) {
      return '';
    }
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

    if (res.statusCode == 200) {
      return extractContent(res.body);
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

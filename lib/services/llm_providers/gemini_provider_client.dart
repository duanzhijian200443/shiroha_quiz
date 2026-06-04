import 'dart:convert';

import 'package:http/http.dart' as http;

import 'llm_provider_client.dart';

class GeminiProviderClient extends LlmProviderClient {
  const GeminiProviderClient();

  @override
  Future<String> callText(LlmTextRequest request) async {
    final url =
        '${request.baseUrl}/models/${request.model}:generateContent?key=${request.apiKey}';
    final generationConfig = <String, dynamic>{
      'temperature': request.temperature,
      'maxOutputTokens': request.maxTokens,
    };
    if (request.jsonResponse) {
      generationConfig['responseMimeType'] = 'application/json';
    }

    final res = await http
        .post(
          Uri.parse(url),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'contents': [
              {
                'parts': [
                  {'text': request.combinedPrompt},
                ],
              },
            ],
            'generationConfig': generationConfig,
          }),
        )
        .timeout(request.timeout);

    if (res.statusCode == 200) {
      return jsonDecode(res.body)['candidates'][0]['content']['parts'][0]
              ['text'] ??
          '';
    }
    throw Exception('API Error: ${res.statusCode} - ${res.body}');
  }

  @override
  Future<String> callVision(LlmVisionRequest request) async {
    final url =
        '${request.baseUrl}/models/${request.model}:generateContent?key=${request.apiKey}';
    final parts = <Map<String, dynamic>>[
      {'text': request.prompt},
      ...request.assets.map(_assetToPart),
    ];

    final res = await http
        .post(
          Uri.parse(url),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'contents': [
              {'parts': parts},
            ],
            'generationConfig': {'temperature': request.temperature},
          }),
        )
        .timeout(request.timeout);

    if (res.statusCode == 200) {
      return jsonDecode(res.body)['candidates'][0]['content']['parts'][0]
                  ['text']
              ?.toString() ??
          '';
    }
    throw Exception('Gemini Vision Error: ${res.statusCode} - ${res.body}');
  }

  Map<String, dynamic> _assetToPart(LlmVisionAsset asset) {
    if (asset.uploadAsFile || !asset.hasInlineData) {
      throw ArgumentError('Gemini vision requires inline base64 assets.');
    }
    return {
      'inline_data': {
        'mime_type': asset.mimeType,
        'data': asset.base64Data,
      },
    };
  }
}

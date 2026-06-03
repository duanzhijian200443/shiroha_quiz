import 'dart:convert';

import 'package:http/http.dart' as http;

class LlmApiClient {
  const LlmApiClient();

  static String buildChatUrl(String baseUrl, bool isZhipu) {
    if (isZhipu) {
      return baseUrl.endsWith('/v4')
          ? '$baseUrl/chat/completions'
          : '$baseUrl/v4/chat/completions';
    }
    return baseUrl.endsWith('/v1')
        ? '$baseUrl/chat/completions'
        : '$baseUrl/v1/chat/completions';
  }

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

  Future<String> callText({
    required Map<String, dynamic> profile,
    required String prompt,
    double? temperature,
    String? reasoningEffort,
    int maxTokens = 8192,
    bool jsonResponse = false,
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final apiKey = profile['api_key'] as String? ?? '';
    var baseUrl = profile['base_url'] as String? ?? '';
    final model = profile['model_name'] as String? ?? '';
    final temp =
        temperature ?? (profile['temperature'] as num?)?.toDouble() ?? 0.7;
    final effort =
        reasoningEffort ?? (profile['reasoning_effort'] as String? ?? '');

    if (apiKey.isEmpty || baseUrl.isEmpty || model.isEmpty) {
      throw Exception('引擎配置不完整');
    }

    if (baseUrl.endsWith('/')) {
      baseUrl = baseUrl.substring(0, baseUrl.length - 1);
    }
    final isGemini = baseUrl.contains('generativelanguage.googleapis.com');
    final isZhipu = baseUrl.contains('bigmodel.cn');

    if (isGemini) {
      final url = '$baseUrl/models/$model:generateContent?key=$apiKey';
      final generationConfig = <String, dynamic>{
        'temperature': temp,
        'maxOutputTokens': maxTokens,
      };
      if (jsonResponse) {
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
                    {'text': prompt},
                  ],
                },
              ],
              'generationConfig': generationConfig,
            }),
          )
          .timeout(timeout);

      if (res.statusCode == 200) {
        return jsonDecode(
              res.body,
            )['candidates'][0]['content']['parts'][0]['text'] ??
            '';
      }
      throw Exception('API Error: ${res.statusCode} - ${res.body}');
    }

    final reqBody = <String, dynamic>{
      'model': model,
      'messages': [
        {'role': 'user', 'content': prompt},
      ],
      'max_tokens': maxTokens,
    };
    if (effort.isNotEmpty) {
      reqBody['reasoning_effort'] = effort;
    } else {
      reqBody['temperature'] = temp;
    }
    if (jsonResponse) {
      reqBody['response_format'] = {'type': 'json_object'};
    }

    final res = await http
        .post(
          Uri.parse(buildChatUrl(baseUrl, isZhipu)),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $apiKey',
          },
          body: jsonEncode(reqBody),
        )
        .timeout(timeout);

    if (res.statusCode == 200) {
      return extractContent(res.body);
    }
    throw Exception('API Error: ${res.statusCode} - ${res.body}');
  }
}

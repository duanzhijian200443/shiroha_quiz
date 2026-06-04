import 'dart:convert';

import 'package:http/http.dart' as http;

import 'llm_provider_client.dart';
import 'openai_compatible_provider_client.dart';

class ZhipuProviderClient extends OpenAiCompatibleProviderClient {
  const ZhipuProviderClient();

  static String buildZhipuChatUrl(String baseUrl) {
    return baseUrl.endsWith('/v4')
        ? '$baseUrl/chat/completions'
        : '$baseUrl/v4/chat/completions';
  }

  @override
  String buildChatUrlFor(String baseUrl) => buildZhipuChatUrl(baseUrl);

  @override
  Future<String> callVision(LlmVisionRequest request) async {
    if (request.assets.length == 1 && request.assets.first.uploadAsFile) {
      return _callUploadedFileVision(request, request.assets.first);
    }
    return super.callVision(request);
  }

  Future<String> _callUploadedFileVision(
    LlmVisionRequest request,
    LlmVisionAsset asset,
  ) async {
    final filePath = asset.filePath;
    if (filePath == null || filePath.isEmpty) {
      throw ArgumentError('Zhipu upload vision requires a local file path.');
    }

    final uploadUrl = request.baseUrl.endsWith('/v4')
        ? '${request.baseUrl}/files'
        : '${request.baseUrl}/v4/files';
    final uploadRequest = http.MultipartRequest('POST', Uri.parse(uploadUrl));
    uploadRequest.headers['Authorization'] = 'Bearer ${request.apiKey}';
    uploadRequest.fields['purpose'] = 'file-extract';
    uploadRequest.files
        .add(await http.MultipartFile.fromPath('file', filePath));

    final uploadResponse =
        await uploadRequest.send().timeout(const Duration(seconds: 60));
    final uploadResponseBody = await uploadResponse.stream.bytesToString();
    if (uploadResponse.statusCode != 200) {
      throw Exception(
        'Zhipu upload failed: ${uploadResponse.statusCode} - $uploadResponseBody',
      );
    }

    final fileId = jsonDecode(uploadResponseBody)['id']?.toString() ?? '';
    if (fileId.isEmpty) {
      throw Exception('Zhipu upload response did not include a file id.');
    }

    final res = await http
        .post(
          Uri.parse(buildZhipuChatUrl(request.baseUrl)),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer ${request.apiKey}',
          },
          body: jsonEncode({
            'model': request.model,
            'messages': [
              {
                'role': 'user',
                'content': [
                  {'type': 'text', 'text': request.prompt},
                  {
                    'type': 'file',
                    'file_url': {'url': fileId},
                  },
                ],
              },
            ],
            'temperature': request.temperature,
          }),
        )
        .timeout(request.timeout);

    if (res.statusCode == 200) {
      return OpenAiCompatibleProviderClient.extractContent(res.body);
    }
    throw Exception('Zhipu vision failed: ${res.statusCode} - ${res.body}');
  }
}

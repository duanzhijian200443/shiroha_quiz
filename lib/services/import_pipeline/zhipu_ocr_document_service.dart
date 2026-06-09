import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../data/repositories/ai_engine_repository.dart';
import '../llm_providers/llm_provider_registry.dart';
import 'import_format.dart';

class ZhipuOcrDocumentResult {
  final String markdown;
  final List<String> warnings;
  final Map<String, dynamic> diagnostics;

  const ZhipuOcrDocumentResult({
    required this.markdown,
    this.warnings = const [],
    this.diagnostics = const {},
  });
}

class ZhipuOcrDocumentService {
  const ZhipuOcrDocumentService({
    AiEngineRepository? engineRepository,
    http.Client? httpClient,
  })  : _engineRepository = engineRepository ?? AiEngineRepository.instance,
        _httpClient = httpClient;

  final AiEngineRepository _engineRepository;
  final http.Client? _httpClient;

  Future<ZhipuOcrDocumentResult> parseFile({
    required String filePath,
    required String sourceName,
  }) async {
    final profile = await _engineRepository.getActiveVisionEngine();
    if (profile == null) {
      throw Exception('未激活视觉 AI 引擎，无法使用智谱 GLM-OCR。');
    }
    if (!profile.isComplete) {
      throw Exception('视觉引擎配置不完整: ${profile.missingFields.join(', ')}');
    }
    if (LlmProviderRegistry.kindForBaseUrl(profile.baseUrl) !=
        LlmProviderKind.zhipu) {
      throw Exception('GLM-OCR 需要将视觉引擎 baseUrl 配置为智谱 bigmodel.cn。');
    }

    final file = File(filePath);
    if (!file.existsSync()) {
      throw Exception('OCR 文件不存在: $filePath');
    }

    final format = ImportFormatDetection.fromPath(filePath);
    if (format != ImportFormat.pdf && format != ImportFormat.image) {
      throw Exception('GLM-OCR 当前仅用于 PDF/图片文件: $sourceName');
    }

    final mimeType = _mimeTypeFor(filePath);
    final client = _httpClient ?? http.Client();
    final shouldCloseClient = _httpClient == null;

    try {
      final fileId = await _uploadForOcr(
        client: client,
        baseUrl: profile.baseUrl,
        apiKey: profile.apiKey,
        filePath: filePath,
      );

      final parsed = await _callLayoutParsing(
        client: client,
        baseUrl: profile.baseUrl,
        apiKey: profile.apiKey,
        fileId: fileId,
        sourceName: sourceName,
        mimeType: mimeType,
      );

      return ZhipuOcrDocumentResult(
        markdown: parsed.markdown,
        warnings: parsed.markdown.trim().isEmpty
            ? ['GLM-OCR 返回成功，但未提取到可用于解析的 Markdown 文本。']
            : const [],
        diagnostics: {
          'engine': 'zhipu_glm_ocr',
          'sourceName': sourceName,
          'fileId': fileId,
          'mimeType': mimeType,
          ...parsed.diagnostics,
        },
      );
    } finally {
      if (shouldCloseClient) {
        client.close();
      }
    }
  }

  Future<String> _uploadForOcr({
    required http.Client client,
    required String baseUrl,
    required String apiKey,
    required String filePath,
  }) async {
    final uploadUrl = baseUrl.endsWith('/v4')
        ? '$baseUrl/files'
        : '$baseUrl/v4/files';
    final uploadRequest = http.MultipartRequest('POST', Uri.parse(uploadUrl));
    uploadRequest.headers['Authorization'] = 'Bearer $apiKey';
    uploadRequest.fields['purpose'] = 'file-extract';
    uploadRequest.files.add(await http.MultipartFile.fromPath('file', filePath));

    final streamed = await client.send(uploadRequest).timeout(
          const Duration(minutes: 2),
        );
    final body = await streamed.stream.bytesToString();
    if (streamed.statusCode != 200) {
      throw Exception('GLM-OCR 文件上传失败: ${streamed.statusCode} - $body');
    }

    final decoded = jsonDecode(body);
    final fileId = decoded['id']?.toString() ?? '';
    if (fileId.isEmpty) {
      throw Exception('GLM-OCR 文件上传响应缺少 file id: $body');
    }
    return fileId;
  }

  Future<_ParsedLayoutResponse> _callLayoutParsing({
    required http.Client client,
    required String baseUrl,
    required String apiKey,
    required String fileId,
    required String sourceName,
    required String mimeType,
  }) async {
    final layoutUrl = baseUrl.endsWith('/v4')
        ? '$baseUrl/layout_parsing'
        : '$baseUrl/v4/layout_parsing';
    final response = await client
        .post(
          Uri.parse(layoutUrl),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $apiKey',
          },
          body: jsonEncode({
            'model': 'glm-ocr',
            'file': fileId,
          }),
        )
        .timeout(const Duration(minutes: 8));

    if (response.statusCode != 200) {
      throw Exception('GLM-OCR 文档解析失败: ${response.statusCode} - ${response.body}');
    }

    final decoded = jsonDecode(response.body);
    final markdown = _extractMarkdown(decoded);
    return _ParsedLayoutResponse(
      markdown: markdown,
      diagnostics: {
        'layoutStatusCode': response.statusCode,
        'responseKeys': decoded is Map ? decoded.keys.map((e) => e.toString()).toList() : const [],
        'rawTextLength': markdown.length,
      },
    );
  }

  String _extractMarkdown(dynamic decoded) {
    final candidates = <String>[];

    void visit(dynamic node) {
      if (node == null) return;
      if (node is String) {
        final trimmed = node.trim();
        if (trimmed.isNotEmpty) {
          candidates.add(trimmed);
        }
        return;
      }
      if (node is List) {
        for (final item in node) {
          visit(item);
        }
        return;
      }
      if (node is Map) {
        for (final key in const [
          'markdown',
          'md',
          'content',
          'text',
          'result',
          'document',
          'output',
        ]) {
          if (node.containsKey(key)) {
            visit(node[key]);
          }
        }
      }
    }

    visit(decoded);
    if (candidates.isEmpty) return '';
    candidates.sort((a, b) => b.length.compareTo(a.length));
    return candidates.first;
  }

  String _mimeTypeFor(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.pdf')) return 'application/pdf';
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    return 'application/octet-stream';
  }
}

class _ParsedLayoutResponse {
  final String markdown;
  final Map<String, dynamic> diagnostics;

  const _ParsedLayoutResponse({
    required this.markdown,
    required this.diagnostics,
  });
}

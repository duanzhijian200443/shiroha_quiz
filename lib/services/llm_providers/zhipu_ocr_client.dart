import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:syncfusion_flutter_pdf/pdf.dart';

import '../../data/models/ai_engine_profile.dart';
import '../import_pipeline/ocr_document.dart';
import '../import_pipeline/ocr_document_client.dart';

class ZhipuOcrAuthenticationException implements Exception {
  const ZhipuOcrAuthenticationException();
}

class ZhipuOcrRequestException implements Exception {
  const ZhipuOcrRequestException();
}

class ZhipuOcrResponseFormatException implements Exception {
  const ZhipuOcrResponseFormatException();
}

class ZhipuOcrInvalidPdfException implements Exception {
  const ZhipuOcrInvalidPdfException();
}

class ZhipuOcrClient implements OcrDocumentClient {
  const ZhipuOcrClient({
    http.Client? httpClient,
    this.pdfPageChunkSize = 30,
  }) : _httpClient = httpClient;

  final http.Client? _httpClient;
  final int pdfPageChunkSize;

  static const String model = 'glm-ocr';
  static const int maxPdfBytes = 50 * 1024 * 1024;
  static const int maxImageBytes = 10 * 1024 * 1024;

  @override
  String get modelId => model;

  static String buildLayoutParsingUrl(String baseUrl) {
    var normalized = baseUrl.trim();
    while (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    if (normalized.endsWith('/v4')) {
      return '$normalized/layout_parsing';
    }
    return '$normalized/v4/layout_parsing';
  }

  @override
  Future<OcrDocument> parseFile({
    required AiEngineProfile profile,
    required String filePath,
    required String sourceName,
    Duration timeout = const Duration(minutes: 8),
  }) async {
    if (!profile.isComplete) {
      throw Exception(
        'AI OCR profile is incomplete: ${profile.missingFields.join(', ')}',
      );
    }

    final file = File(filePath);
    final length = await file.length();
    final mimeType = _mimeTypeFor(filePath, sourceName);
    final isPdf = mimeType == 'application/pdf';
    if (isPdf && length > maxPdfBytes) {
      throw Exception('GLM-OCR PDF file exceeds 50MB limit.');
    }
    if (!isPdf && length > maxImageBytes) {
      throw Exception('GLM-OCR image file exceeds 10MB limit.');
    }

    final bytes = await file.readAsBytes();
    final dataUrl = 'data:$mimeType;base64,${base64Encode(bytes)}';
    final pageCount = isPdf ? _readPdfPageCount(bytes) : 1;
    final chunks = <OcrDocument>[];

    if (!isPdf || pageCount <= pdfPageChunkSize) {
      chunks.add(
        await _callLayoutParsing(
          profile: profile,
          dataUrl: dataUrl,
          sourceName: sourceName,
          timeout: timeout,
          pageOffset: 0,
        ),
      );
    } else {
      for (var start = 1; start <= pageCount; start += pdfPageChunkSize) {
        final end = (start + pdfPageChunkSize - 1).clamp(1, pageCount);
        chunks.add(
          await _callLayoutParsing(
            profile: profile,
            dataUrl: dataUrl,
            sourceName: sourceName,
            timeout: timeout,
            startPage: start,
            endPage: end,
            pageOffset: start - 1,
          ),
        );
      }
    }

    return OcrDocument.merge(sourceName: sourceName, chunks: chunks);
  }

  Future<OcrDocument> _callLayoutParsing({
    required AiEngineProfile profile,
    required String dataUrl,
    required String sourceName,
    required Duration timeout,
    int? startPage,
    int? endPage,
    required int pageOffset,
  }) async {
    final client = _httpClient ?? http.Client();
    try {
      final body = <String, dynamic>{
        'model': model,
        'file': dataUrl,
        'return_crop_images': false,
        'need_layout_visualization': false,
        'request_id': _requestId(sourceName, startPage),
        if (startPage != null) 'start_page_id': startPage,
        if (endPage != null) 'end_page_id': endPage,
      };

      final response = await client
          .post(
            Uri.parse(buildLayoutParsingUrl(profile.baseUrl)),
            headers: {
              'Authorization': 'Bearer ${profile.apiKey}',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(timeout);

      if (response.statusCode != 200) {
        if (response.statusCode == 401 || response.statusCode == 403) {
          throw const ZhipuOcrAuthenticationException();
        }
        throw const ZhipuOcrRequestException();
      }

      try {
        final decoded = jsonDecode(response.body);
        if (decoded is! Map) {
          throw const ZhipuOcrResponseFormatException();
        }

        return OcrDocument.fromLayoutParsingResponse(
          Map<String, dynamic>.from(decoded),
          sourceName: sourceName,
          pageOffset: pageOffset,
        );
      } on ZhipuOcrResponseFormatException {
        rethrow;
      } on FormatException {
        throw const ZhipuOcrResponseFormatException();
      }
    } finally {
      if (_httpClient == null) {
        client.close();
      }
    }
  }

  /// Resolves the media type for OCR admission.
  ///
  /// The physical [filePath] is tried first (its extension, when present, is
  /// authoritative). When the managed path has no supported extension, the
  /// caller-provided [sourceName] is tried, so privacy-neutral runtime names
  /// such as `<artifactId>.pdf` / `.png` / `.jpg` can carry the MIME signal.
  String _mimeTypeFor(String filePath, String sourceName) {
    final fromPath = _tryMimeForPath(filePath);
    if (fromPath != null) return fromPath;
    final fromSource = _tryMimeForPath(sourceName);
    if (fromSource != null) return fromSource;
    throw ArgumentError('GLM-OCR only supports PDF, JPG, JPEG, and PNG.');
  }

  String? _tryMimeForPath(String value) {
    final lower = value.toLowerCase();
    if (lower.endsWith('.pdf')) return 'application/pdf';
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
      return 'image/jpeg';
    }
    return null;
  }

  int _readPdfPageCount(List<int> bytes) {
    PdfDocument? document;
    try {
      document = PdfDocument(inputBytes: bytes);
      final count = document.pages.count;
      if (count <= 0) {
        throw const ZhipuOcrInvalidPdfException();
      }
      return count;
    } catch (e) {
      if (e is ZhipuOcrInvalidPdfException) rethrow;
      throw const ZhipuOcrInvalidPdfException();
    } finally {
      document?.dispose();
    }
  }

  String _requestId(String sourceName, int? startPage) {
    final normalized = sourceName
        .replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_');
    final stem = normalized.isEmpty ? 'file' : normalized;
    final prefix = stem.length > 24 ? stem.substring(0, 24) : stem;
    final millis = DateTime.now().millisecondsSinceEpoch;
    final suffix = startPage == null ? 'all' : 'p$startPage';
    final requestId = 'ocr_${prefix}_${suffix}_$millis';
    return requestId.length > 64 ? requestId.substring(0, 64) : requestId;
  }
}

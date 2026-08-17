import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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
  static const int _maxRemoteImageRedirects = 3;
  static const Duration _remoteImageTimeout = Duration(seconds: 20);

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
        'return_crop_images': true,
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

        final normalized = Map<String, dynamic>.from(decoded);
        await _materializeRemoteCropImages(
          normalized,
          client: client,
          requestTimeout: timeout,
        );
        return OcrDocument.fromLayoutParsingResponse(
          normalized,
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

  Future<void> _materializeRemoteCropImages(
    Map<String, dynamic> response, {
    required http.Client client,
    required Duration requestTimeout,
  }) async {
    Future<void> visit(dynamic value) async {
      if (value is List) {
        for (final item in value) {
          await visit(item);
        }
        return;
      }
      if (value is! Map) return;

      final label = value['label']?.toString().trim().toLowerCase();
      final rawContent = value['content'];
      if ((label == 'image' || label == 'figure') && rawContent is String) {
        final content = rawContent.trim();
        final uri = Uri.tryParse(content);
        if (uri != null &&
            (uri.scheme.toLowerCase() == 'http' ||
                uri.scheme.toLowerCase() == 'https')) {
          String? materialized;
          if (_isSafeRemoteImageUri(uri)) {
            try {
              materialized = await _downloadRemoteImageAsDataUrl(
                client,
                uri,
                timeout: _effectiveRemoteImageTimeout(requestTimeout),
              );
            } catch (_) {
              materialized = null;
            }
          }
          // Provider-owned crop URLs are ephemeral infrastructure data. If
          // they cannot be safely materialized, keep only a fixed placeholder
          // so no signed URL or local network locator can enter typed content.
          value['content'] = materialized ?? '[图片]';
        }
      }

      for (final entry in value.entries.toList(growable: false)) {
        if (entry.key == 'content' || entry.key == 'label') continue;
        await visit(entry.value);
      }
    }

    await visit(response['layout_details']);
  }

  Future<String?> _downloadRemoteImageAsDataUrl(
    http.Client client,
    Uri initialUri, {
    required Duration timeout,
  }) async {
    var uri = initialUri;
    for (var redirectCount = 0;
        redirectCount <= _maxRemoteImageRedirects;
        redirectCount++) {
      if (!_isSafeRemoteImageUri(uri)) return null;

      final request = http.Request('GET', uri)..followRedirects = false;
      final response = await client.send(request).timeout(timeout);
      final status = response.statusCode;
      if (status >= 300 && status < 400) {
        await response.stream.drain<void>();
        if (redirectCount == _maxRemoteImageRedirects) return null;
        final location = response.headers['location'];
        if (location == null || location.trim().isEmpty) return null;
        final next = uri.resolve(location.trim());
        if (!_isSafeRemoteImageUri(next)) return null;
        uri = next;
        continue;
      }
      if (status != 200) {
        await response.stream.drain<void>();
        return null;
      }
      final contentLength = response.contentLength;
      if (contentLength != null && contentLength > maxImageBytes) {
        return null;
      }

      final builder = BytesBuilder(copy: false);
      var totalBytes = 0;
      await for (final chunk in response.stream.timeout(timeout)) {
        totalBytes += chunk.length;
        if (totalBytes > maxImageBytes) return null;
        builder.add(chunk);
      }
      final bytes = builder.takeBytes();
      if (bytes.isEmpty) return null;
      final mimeType = _resolveDownloadedImageMime(
        response.headers['content-type'],
        bytes,
      );
      if (mimeType == null) return null;
      return 'data:$mimeType;base64,${base64Encode(bytes)}';
    }
    return null;
  }

  Duration _effectiveRemoteImageTimeout(Duration requestTimeout) {
    return requestTimeout.compareTo(_remoteImageTimeout) < 0
        ? requestTimeout
        : _remoteImageTimeout;
  }

  bool _isSafeRemoteImageUri(Uri uri) {
    if (uri.scheme.toLowerCase() != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.fragment.isNotEmpty) {
      return false;
    }
    if (uri.hasPort && uri.port != 443) return false;

    final host = uri.host.toLowerCase();
    if (InternetAddress.tryParse(host) != null) return false;
    if (!host.contains('.') ||
        host == 'localhost' ||
        host.endsWith('.localhost') ||
        host.endsWith('.local') ||
        host.endsWith('.internal') ||
        host.endsWith('.lan') ||
        host.endsWith('.home') ||
        host.endsWith('.test') ||
        host.endsWith('.invalid') ||
        host.endsWith('.example')) {
      return false;
    }
    return true;
  }

  String? _resolveDownloadedImageMime(
    String? contentType,
    Uint8List bytes,
  ) {
    final normalizedHeader = contentType?.split(';').first.trim().toLowerCase();
    final fromHeader = switch (normalizedHeader) {
      'image/png' => 'image/png',
      'image/jpeg' || 'image/jpg' => 'image/jpeg',
      'image/webp' => 'image/webp',
      'image/gif' => 'image/gif',
      _ => null,
    };
    if (fromHeader != null) return fromHeader;

    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4e &&
        bytes[3] == 0x47 &&
        bytes[4] == 0x0d &&
        bytes[5] == 0x0a &&
        bytes[6] == 0x1a &&
        bytes[7] == 0x0a) {
      return 'image/png';
    }
    if (bytes.length >= 3 &&
        bytes[0] == 0xff &&
        bytes[1] == 0xd8 &&
        bytes[2] == 0xff) {
      return 'image/jpeg';
    }
    if (bytes.length >= 6) {
      final prefix = ascii.decode(bytes.sublist(0, 6), allowInvalid: true);
      if (prefix == 'GIF87a' || prefix == 'GIF89a') return 'image/gif';
    }
    if (bytes.length >= 12 &&
        ascii.decode(bytes.sublist(0, 4), allowInvalid: true) == 'RIFF' &&
        ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WEBP') {
      return 'image/webp';
    }
    return null;
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

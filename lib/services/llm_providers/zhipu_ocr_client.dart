import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

import '../../core/observability/app_logger.dart';
import '../../data/models/ai_engine_profile.dart';
import '../../domain/assets/image_byte_signature.dart';
import '../../domain/content/rich_content_limits.dart';
import '../import_pipeline/ocr_document.dart';
import '../import_pipeline/ocr_document_client.dart';

typedef OcrDnsResolver = Future<List<InternetAddress>> Function(String host);
typedef OcrRemoteCropClientFactory = http.Client Function(
  Uri uri,
  InternetAddress approvedAddress,
);

/// Fixed, privacy-safe classification for one OCR image materialization
/// decision. Values are intentionally independent of provider payloads,
/// URLs, paths and exception text.
enum OcrImageMaterializationCategory {
  inlineSuccess,
  remoteSuccess,
  inlinePayloadInvalid,
  providerPlaceholder,
  locatorShapeUnsupported,
  uriPolicyRejected,
  dnsResolutionFailed,
  redirectRejectedOrExhausted,
  httpNonSuccess,
  timeoutOrTransport,
  bodyOrMimeInvalid,
}

String ocrImageMaterializationCategoryValue(
  OcrImageMaterializationCategory category,
) {
  return switch (category) {
    OcrImageMaterializationCategory.inlineSuccess => 'inline_success',
    OcrImageMaterializationCategory.remoteSuccess => 'remote_success',
    OcrImageMaterializationCategory.inlinePayloadInvalid =>
      'inline_payload_invalid',
    OcrImageMaterializationCategory.providerPlaceholder =>
      'provider_placeholder',
    OcrImageMaterializationCategory.locatorShapeUnsupported =>
      'locator_shape_unsupported',
    OcrImageMaterializationCategory.uriPolicyRejected => 'uri_policy_rejected',
    OcrImageMaterializationCategory.dnsResolutionFailed =>
      'dns_resolution_failed',
    OcrImageMaterializationCategory.redirectRejectedOrExhausted =>
      'redirect_rejected_or_exhausted',
    OcrImageMaterializationCategory.httpNonSuccess => 'http_non_success',
    OcrImageMaterializationCategory.timeoutOrTransport =>
      'timeout_or_transport',
    OcrImageMaterializationCategory.bodyOrMimeInvalid => 'body_or_mime_invalid',
  };
}

/// Fixed, privacy-safe subcategories for a remote image body that failed
/// validation. These values describe only the bounded admission decision;
/// they never contain response data, MIME payloads, URLs, or exceptions.
enum OcrImageBodyFailureCategory {
  emptyBody,
  bodyTooLarge,
  signatureUnrecognized,
  mimeUnsupported,
  mimeSignatureMismatch,
}

String ocrImageBodyFailureCategoryValue(
  OcrImageBodyFailureCategory category,
) {
  return switch (category) {
    OcrImageBodyFailureCategory.emptyBody => 'empty_body',
    OcrImageBodyFailureCategory.bodyTooLarge => 'body_too_large',
    OcrImageBodyFailureCategory.signatureUnrecognized =>
      'signature_unrecognized',
    OcrImageBodyFailureCategory.mimeUnsupported => 'mime_unsupported',
    OcrImageBodyFailureCategory.mimeSignatureMismatch =>
      'mime_signature_mismatch',
  };
}

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
    OcrDnsResolver? dnsResolver,
    OcrRemoteCropClientFactory? remoteCropClientFactory,
    this.remoteCropCountLimit = maxRemoteCropCount,
    this.remoteCropTotalBytesLimit = maxRemoteCropTotalBytes,
    this.layoutResponseBytesLimit = maxLayoutParsingResponseBytes,
  })  : _httpClient = httpClient,
        _dnsResolver = dnsResolver,
        _remoteCropClientFactory = remoteCropClientFactory;

  final http.Client? _httpClient;
  final int pdfPageChunkSize;

  static const String model = 'glm-ocr';
  static const int maxPdfBytes = 50 * 1024 * 1024;
  static const int maxImageBytes = 10 * 1024 * 1024;

  /// Transient OCR/provider acquisition limits. These are not persisted
  /// schema values and are intentionally independent from domain admission.
  static const int maxRemoteCropCount = RichContentLimits.maxImages;
  static const int maxRemoteCropTotalBytes = 32 * 1024 * 1024;
  static const int maxLayoutParsingResponseBytes = 64 * 1024 * 1024;
  static const int maxRemoteImageRedirects = 3;
  static const int maxRemoteResponseDiscardBytes = 64 * 1024;
  static const Duration remoteImageTimeout = Duration(seconds: 30);

  final OcrDnsResolver? _dnsResolver;
  final OcrRemoteCropClientFactory? _remoteCropClientFactory;
  final int remoteCropCountLimit;
  final int remoteCropTotalBytesLimit;
  final int layoutResponseBytesLimit;

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
    final remoteCropBudget = _RemoteCropBudget(
      maxCount: remoteCropCountLimit,
      maxTotalBytes: remoteCropTotalBytesLimit,
    );
    final layoutResponseBudget = _LayoutResponseBudget(
      maxTotalBytes: layoutResponseBytesLimit,
    );

    if (!isPdf || pageCount <= pdfPageChunkSize) {
      chunks.add(
        await _callLayoutParsing(
          profile: profile,
          dataUrl: dataUrl,
          sourceName: sourceName,
          timeout: timeout,
          pageOffset: 0,
          remoteCropBudget: remoteCropBudget,
          layoutResponseBudget: layoutResponseBudget,
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
            remoteCropBudget: remoteCropBudget,
            layoutResponseBudget: layoutResponseBudget,
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
    required _RemoteCropBudget remoteCropBudget,
    required _LayoutResponseBudget layoutResponseBudget,
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

      final request = http.Request(
        'POST',
        Uri.parse(buildLayoutParsingUrl(profile.baseUrl)),
      )
        ..headers.addAll(<String, String>{
          'Authorization': 'Bearer ${profile.apiKey}',
          'Content-Type': 'application/json',
        })
        ..body = jsonEncode(body);
      final response = await client.send(request).timeout(timeout);

      if (response.statusCode != 200) {
        await _discardRemoteResponseBodyBounded(
          response.stream,
          timeout: timeout,
        );
        if (response.statusCode == 401 || response.statusCode == 403) {
          throw const ZhipuOcrAuthenticationException();
        }
        throw const ZhipuOcrRequestException();
      }

      try {
        final responseBytes = await _readLayoutResponseBodyBounded(
          response.stream,
          contentLength: response.contentLength,
          timeout: timeout,
          budget: layoutResponseBudget,
        );
        final decoded = jsonDecode(utf8.decode(responseBytes));
        if (decoded is! Map) {
          throw const ZhipuOcrResponseFormatException();
        }

        final normalized = Map<String, dynamic>.from(decoded);
        await _materializeRemoteCropImages(
          normalized,
          requestTimeout: timeout,
          budget: remoteCropBudget,
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
    required Duration requestTimeout,
    required _RemoteCropBudget budget,
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
        final trimmedContent = rawContent.trim();
        if (trimmedContent.toLowerCase().startsWith('data:image/')) {
          try {
            // Inline provider payloads share the same document-level count
            // and decoded-byte authority as remote crop acquisitions.
            budget.reserveCrop();
            final payload = OcrImagePayload.fromDataUrl(trimmedContent);
            if (payload == null) {
              value['content'] = '[图片]';
              _recordImageMaterialization(
                OcrImageMaterializationCategory.inlinePayloadInvalid,
              );
            } else {
              budget.reserveBytes(payload.bytes.length);
              _recordImageMaterialization(
                OcrImageMaterializationCategory.inlineSuccess,
              );
            }
          } on _RemoteCropBudgetExceeded {
            throw const ZhipuOcrResponseFormatException();
          }
        } else {
          final uri = Uri.tryParse(trimmedContent);
          if (uri != null && uri.scheme.toLowerCase() == 'https') {
            try {
              budget.reserveCrop();
            } on _RemoteCropBudgetExceeded {
              throw const ZhipuOcrResponseFormatException();
            }
            late final _RemoteImageMaterializationResult materialized;
            try {
              materialized = await _downloadRemoteImageAsDataUrl(
                uri,
                timeout: _effectiveRemoteImageTimeout(requestTimeout),
                budget: budget,
              );
            } on _RemoteCropBudgetExceeded {
              throw const ZhipuOcrResponseFormatException();
            }
            _recordImageMaterialization(
              materialized.category,
              failureCategory: materialized.failureCategory,
            );
            // The URL is ephemeral provider infrastructure. It must not reach
            // OcrDocument text, replay JSON, or any Domain/persistence
            // payload.
            value['content'] = materialized.dataUrl ?? '[图片]';
          } else if (trimmedContent == '[图片]') {
            _recordImageMaterialization(
              OcrImageMaterializationCategory.providerPlaceholder,
            );
          } else if (_hasExplicitLocatorShape(trimmedContent)) {
            _recordImageMaterialization(
              _classifyUnsupportedLocator(trimmedContent),
            );
          }
        }
      }

      for (final entry in value.entries.toList(growable: false)) {
        if (entry.key == 'content' || entry.key == 'label') continue;
        await visit(entry.value);
      }
    }

    await visit(response['layout_details']);
  }

  void _recordImageMaterialization(
    OcrImageMaterializationCategory category, {
    OcrImageBodyFailureCategory? failureCategory,
  }) {
    final data = <String, Object?>{
      'stage': 'image_materialization',
      'category': ocrImageMaterializationCategoryValue(category),
      'count': 1,
    };
    if (failureCategory != null) {
      data['failureCategory'] =
          ocrImageBodyFailureCategoryValue(failureCategory);
    }
    AppLogger.info(
      'OCR image materialization classified',
      module: 'Ocr',
      data: data,
    );
  }

  bool _hasExplicitLocatorShape(String value) {
    return value.startsWith('//') ||
        RegExp(r'^[A-Za-z][A-Za-z0-9+.-]*://').hasMatch(value);
  }

  OcrImageMaterializationCategory _classifyUnsupportedLocator(String value) {
    final scheme = Uri.tryParse(value)?.scheme.toLowerCase();
    return switch (scheme) {
      'http' ||
      'https' ||
      'file' =>
        OcrImageMaterializationCategory.uriPolicyRejected,
      _ => OcrImageMaterializationCategory.locatorShapeUnsupported,
    };
  }

  Future<List<int>> _readLayoutResponseBodyBounded(
    Stream<List<int>> stream, {
    required int? contentLength,
    required Duration timeout,
    required _LayoutResponseBudget budget,
  }) async {
    if (layoutResponseBytesLimit <= 0 ||
        (contentLength != null &&
            (contentLength > layoutResponseBytesLimit ||
                !budget.canReserveBytes(contentLength)))) {
      throw const ZhipuOcrResponseFormatException();
    }

    final completed = Completer<List<int>>();
    final builder = BytesBuilder(copy: false);
    late final StreamSubscription<List<int>> subscription;
    Timer? timer;
    var totalBytes = 0;

    void fail(Object error, [StackTrace? stackTrace]) {
      if (completed.isCompleted) return;
      unawaited(subscription.cancel());
      if (stackTrace == null) {
        completed.completeError(error);
      } else {
        completed.completeError(error, stackTrace);
      }
    }

    subscription = stream.listen(
      (chunk) {
        if (completed.isCompleted) return;
        totalBytes += chunk.length;
        if (totalBytes > layoutResponseBytesLimit ||
            !budget.canReserveBytes(chunk.length)) {
          fail(const ZhipuOcrResponseFormatException());
          return;
        }
        budget.reserveBytes(chunk.length);
        builder.add(chunk);
      },
      onError: (Object error, StackTrace stackTrace) => fail(error, stackTrace),
      onDone: () {
        if (!completed.isCompleted) {
          completed.complete(builder.takeBytes());
        }
      },
    );
    timer = Timer(
      timeout,
      () => fail(TimeoutException('GLM-OCR response body timed out.')),
    );

    try {
      return await completed.future;
    } finally {
      timer.cancel();
      await subscription.cancel();
    }
  }

  Future<_RemoteImageMaterializationResult> _downloadRemoteImageAsDataUrl(
    Uri initialUri, {
    required Duration timeout,
    required _RemoteCropBudget budget,
  }) async {
    var uri = initialUri;
    for (var redirect = 0; redirect <= maxRemoteImageRedirects; redirect++) {
      final addressResolution = await _resolveSafeRemoteImageAddress(uri);
      final approvedAddress = addressResolution.address;
      if (approvedAddress == null) {
        return _RemoteImageMaterializationResult.failure(
          addressResolution.failureCategory ??
              OcrImageMaterializationCategory.uriPolicyRejected,
        );
      }
      http.Client? client;
      var ownsClient = false;
      try {
        client = _remoteCropClient(uri, approvedAddress);
        ownsClient = !identical(client, _httpClient);
        final request = http.Request('GET', uri)..followRedirects = false;
        final response = await client.send(request).timeout(timeout);
        if (response.statusCode >= 300 && response.statusCode < 400) {
          await _discardRemoteResponseBodyBounded(
            response.stream,
            timeout: timeout,
          );
          if (redirect == maxRemoteImageRedirects) {
            return _RemoteImageMaterializationResult.failure(
              OcrImageMaterializationCategory.redirectRejectedOrExhausted,
            );
          }
          final location = response.headers['location'];
          if (location == null || location.trim().isEmpty) {
            return _RemoteImageMaterializationResult.failure(
              OcrImageMaterializationCategory.redirectRejectedOrExhausted,
            );
          }
          uri = uri.resolve(location.trim());
          continue;
        }
        if (response.statusCode != 200) {
          await _discardRemoteResponseBodyBounded(
            response.stream,
            timeout: timeout,
          );
          return _RemoteImageMaterializationResult.failure(
            OcrImageMaterializationCategory.httpNonSuccess,
          );
        }
        final contentLength = response.contentLength;
        if (contentLength != null && contentLength > maxImageBytes) {
          return _RemoteImageMaterializationResult.failure(
            OcrImageMaterializationCategory.bodyOrMimeInvalid,
            failureCategory: OcrImageBodyFailureCategory.bodyTooLarge,
          );
        }
        if (contentLength != null && !budget.canReserveBytes(contentLength)) {
          throw const _RemoteCropBudgetExceeded();
        }

        final builder = BytesBuilder(copy: false);
        var totalBytes = 0;
        await for (final chunk in response.stream.timeout(timeout)) {
          totalBytes += chunk.length;
          if (totalBytes > maxImageBytes) {
            return _RemoteImageMaterializationResult.failure(
              OcrImageMaterializationCategory.bodyOrMimeInvalid,
              failureCategory: OcrImageBodyFailureCategory.bodyTooLarge,
            );
          }
          budget.reserveBytes(chunk.length);
          builder.add(chunk);
        }
        final bytes = builder.takeBytes();
        if (bytes.isEmpty) {
          return _RemoteImageMaterializationResult.failure(
            OcrImageMaterializationCategory.bodyOrMimeInvalid,
            failureCategory: OcrImageBodyFailureCategory.emptyBody,
          );
        }
        final mimeResolution = _resolveDownloadedImageMime(
          response.headers['content-type'],
          bytes,
        );
        if (mimeResolution.mimeType == null) {
          return _RemoteImageMaterializationResult.failure(
            OcrImageMaterializationCategory.bodyOrMimeInvalid,
            failureCategory: mimeResolution.failureCategory ??
                OcrImageBodyFailureCategory.signatureUnrecognized,
          );
        }
        return _RemoteImageMaterializationResult.success(
          'data:${mimeResolution.mimeType};base64,${base64Encode(bytes)}',
        );
      } on _RemoteCropBudgetExceeded {
        rethrow;
      } on TimeoutException {
        return _RemoteImageMaterializationResult.failure(
          OcrImageMaterializationCategory.timeoutOrTransport,
        );
      } on Object {
        return _RemoteImageMaterializationResult.failure(
          OcrImageMaterializationCategory.timeoutOrTransport,
        );
      } finally {
        if (ownsClient) client?.close();
      }
    }
    return _RemoteImageMaterializationResult.failure(
      OcrImageMaterializationCategory.redirectRejectedOrExhausted,
    );
  }

  Future<void> _discardRemoteResponseBodyBounded(
    Stream<List<int>> stream, {
    required Duration timeout,
  }) async {
    final completed = Completer<void>();
    late final StreamSubscription<List<int>> subscription;
    Timer? timer;
    var discardedBytes = 0;

    void complete() {
      if (!completed.isCompleted) completed.complete();
    }

    subscription = stream.listen(
      (chunk) {
        discardedBytes += chunk.length;
        if (discardedBytes >= maxRemoteResponseDiscardBytes) {
          unawaited(subscription.cancel());
          complete();
        }
      },
      onError: (_, __) => complete(),
      onDone: complete,
    );
    timer = Timer(timeout, () {
      unawaited(subscription.cancel());
      complete();
    });

    try {
      await completed.future;
    } finally {
      timer.cancel();
      await subscription.cancel();
    }
  }

  Duration _effectiveRemoteImageTimeout(Duration requestTimeout) {
    return requestTimeout.compareTo(remoteImageTimeout) < 0
        ? requestTimeout
        : remoteImageTimeout;
  }

  Future<_RemoteImageAddressResolution> _resolveSafeRemoteImageAddress(
    Uri uri,
  ) async {
    if (uri.scheme.toLowerCase() != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.fragment.isNotEmpty ||
        (uri.hasPort && uri.port != 443)) {
      return _RemoteImageAddressResolution.failure(
        OcrImageMaterializationCategory.uriPolicyRejected,
      );
    }
    final host = uri.host.toLowerCase();
    if (InternetAddress.tryParse(host) != null ||
        !host.contains('.') ||
        host == 'localhost' ||
        host.endsWith('.localhost') ||
        host.endsWith('.local') ||
        host.endsWith('.internal') ||
        host.endsWith('.lan') ||
        host.endsWith('.home') ||
        host.endsWith('.test') ||
        host.endsWith('.invalid') ||
        host.endsWith('.example')) {
      return _RemoteImageAddressResolution.failure(
        OcrImageMaterializationCategory.uriPolicyRejected,
      );
    }
    try {
      final addresses = await (_dnsResolver ?? InternetAddress.lookup)(host);
      if (addresses.isEmpty) {
        return _RemoteImageAddressResolution.failure(
          OcrImageMaterializationCategory.dnsResolutionFailed,
        );
      }
      if (!addresses.every(_isPublicAddress)) {
        return _RemoteImageAddressResolution.failure(
          OcrImageMaterializationCategory.uriPolicyRejected,
        );
      }
      // The approved address is returned to the transport below. The
      // production transport connects to this exact address while retaining
      // the original hostname for TLS SNI and certificate verification.
      return _RemoteImageAddressResolution.success(addresses.first);
    } on SocketException {
      return _RemoteImageAddressResolution.failure(
        OcrImageMaterializationCategory.dnsResolutionFailed,
      );
    } on OSError {
      return _RemoteImageAddressResolution.failure(
        OcrImageMaterializationCategory.dnsResolutionFailed,
      );
    } on FormatException {
      return _RemoteImageAddressResolution.failure(
        OcrImageMaterializationCategory.dnsResolutionFailed,
      );
    }
  }

  http.Client _remoteCropClient(Uri uri, InternetAddress approvedAddress) {
    final factory = _remoteCropClientFactory;
    if (factory != null) return factory(uri, approvedAddress);

    // Injected clients are deterministic test transports. The production
    // composition uses the const client with no injected transport and takes
    // the bound-socket path below.
    final injected = _httpClient;
    if (injected != null) return injected;

    final secureClient = HttpClient();
    secureClient.findProxy = (_) => 'DIRECT';
    secureClient.connectionFactory = (url, proxyHost, proxyPort) async {
      if (proxyHost != null ||
          proxyPort != null ||
          url.host != uri.host ||
          url.port != uri.port) {
        return Future<ConnectionTask<Socket>>.error(
          const SocketException('remote crop connection target rejected'),
        );
      }

      final rawTask = await Socket.startConnect(approvedAddress, uri.port);
      final secureFuture = rawTask.socket.then<Socket>(
        (socket) => SecureSocket.secure(socket, host: uri.host),
      );
      return ConnectionTask.fromSocket<Socket>(
        secureFuture,
        rawTask.cancel,
      );
    };
    return IOClient(secureClient);
  }

  bool _isPublicAddress(InternetAddress address) {
    final bytes = address.rawAddress;
    if (address.type == InternetAddressType.IPv4 && bytes.length == 4) {
      final first = bytes[0];
      final second = bytes[1];
      final third = bytes[2];
      if (first == 0 ||
          first == 10 ||
          first == 127 ||
          (first == 100 && second >= 64 && second <= 127) ||
          (first == 169 && second == 254) ||
          (first == 172 && second >= 16 && second <= 31) ||
          (first == 192 && second == 0 && third == 0) ||
          (first == 192 && second == 0 && third == 2) ||
          (first == 192 && second == 88 && third == 99) ||
          (first == 192 && second == 168) ||
          (first == 198 && second >= 18 && second <= 19) ||
          (first == 198 && second == 51 && third == 100) ||
          (first == 203 && second == 0 && third == 113) ||
          first >= 224) {
        return false;
      }
      return true;
    }
    if (address.type != InternetAddressType.IPv6 || bytes.length != 16) {
      return false;
    }
    final allZero = bytes.every((byte) => byte == 0);
    final loopback =
        bytes.take(15).every((byte) => byte == 0) && bytes[15] == 1;
    final uniqueLocal = (bytes[0] & 0xfe) == 0xfc;
    final linkLocal = bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80;
    final multicast = bytes[0] == 0xff;
    final documentation = bytes[0] == 0x20 &&
        bytes[1] == 0x01 &&
        bytes[2] == 0x0d &&
        bytes[3] == 0xb8;
    final mappedIpv4 = bytes.take(10).every((byte) => byte == 0) &&
        bytes[10] == 0xff &&
        bytes[11] == 0xff;
    if (allZero ||
        loopback ||
        uniqueLocal ||
        linkLocal ||
        multicast ||
        documentation) {
      return false;
    }
    if (mappedIpv4) {
      return _isPublicAddress(
        InternetAddress(
          '${bytes[12]}.${bytes[13]}.${bytes[14]}.${bytes[15]}',
        ),
      );
    }
    return true;
  }

  _DownloadedImageMimeResolution _resolveDownloadedImageMime(
    String? contentType,
    List<int> bytes,
  ) {
    final declared = contentType == null
        ? null
        : ImageByteSignature.canonicalMime(contentType);
    final detected = ImageByteSignature.detectMime(bytes);
    if (detected == null) {
      return const _DownloadedImageMimeResolution.failure(
        OcrImageBodyFailureCategory.signatureUnrecognized,
      );
    }
    if (declared == null) {
      return const _DownloadedImageMimeResolution.failure(
        OcrImageBodyFailureCategory.mimeUnsupported,
      );
    }

    // The provider's header identifies the declared image family, while the
    // validated byte signature identifies the bytes we are actually admitting.
    // If both are supported but disagree, retain the bytes and canonicalize
    // the payload to the signature authority. Unknown/non-image declarations
    // and unknown signatures remain fail-closed above.
    return _DownloadedImageMimeResolution.success(detected);
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

final class _LayoutResponseBudget {
  _LayoutResponseBudget({required this.maxTotalBytes});

  final int maxTotalBytes;
  var totalBytes = 0;

  void reserveBytes(int bytes) {
    totalBytes += bytes;
  }

  bool canReserveBytes(int bytes) {
    return bytes >= 0 && bytes <= maxTotalBytes - totalBytes;
  }
}

final class _RemoteCropBudget {
  _RemoteCropBudget({required this.maxCount, required this.maxTotalBytes});

  final int maxCount;
  final int maxTotalBytes;
  var count = 0;
  var totalBytes = 0;

  void reserveCrop() {
    count++;
    if (count > maxCount) throw const _RemoteCropBudgetExceeded();
  }

  void reserveBytes(int bytes) {
    if (!canReserveBytes(bytes)) {
      throw const _RemoteCropBudgetExceeded();
    }
    totalBytes += bytes;
  }

  bool canReserveBytes(int bytes) {
    return bytes >= 0 && bytes <= maxTotalBytes - totalBytes;
  }
}

final class _RemoteCropBudgetExceeded implements Exception {
  const _RemoteCropBudgetExceeded();
}

final class _RemoteImageMaterializationResult {
  const _RemoteImageMaterializationResult({
    required this.category,
    this.dataUrl,
    this.failureCategory,
  });

  const _RemoteImageMaterializationResult.success(String dataUrl)
      : this(
          category: OcrImageMaterializationCategory.remoteSuccess,
          dataUrl: dataUrl,
        );

  const _RemoteImageMaterializationResult.failure(
    OcrImageMaterializationCategory category, {
    OcrImageBodyFailureCategory? failureCategory,
  }) : this(category: category, failureCategory: failureCategory);

  final OcrImageMaterializationCategory category;
  final String? dataUrl;
  final OcrImageBodyFailureCategory? failureCategory;
}

final class _DownloadedImageMimeResolution {
  const _DownloadedImageMimeResolution({
    this.mimeType,
    this.failureCategory,
  });

  const _DownloadedImageMimeResolution.success(String mimeType)
      : this(mimeType: mimeType);

  const _DownloadedImageMimeResolution.failure(
    OcrImageBodyFailureCategory failureCategory,
  ) : this(failureCategory: failureCategory);

  final String? mimeType;
  final OcrImageBodyFailureCategory? failureCategory;
}

final class _RemoteImageAddressResolution {
  const _RemoteImageAddressResolution._({
    this.address,
    this.failureCategory,
  });

  const _RemoteImageAddressResolution.success(InternetAddress address)
      : this._(address: address);

  const _RemoteImageAddressResolution.failure(
    OcrImageMaterializationCategory category,
  ) : this._(failureCategory: category);

  final InternetAddress? address;
  final OcrImageMaterializationCategory? failureCategory;
}

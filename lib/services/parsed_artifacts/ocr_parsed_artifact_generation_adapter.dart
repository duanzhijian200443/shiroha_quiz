import 'dart:async';
import 'dart:io';

import '../../application/parsed_artifacts/parsed_artifact_lifecycle.dart';
import '../../data/models/ai_engine_profile.dart';
import '../../domain/assets/library_file.dart';
import '../../domain/source/source_document.dart';
import '../file_library/managed_file_storage.dart';
import '../import_pipeline/adapters/ocr_source_document_adapter.dart';
import '../import_pipeline/import_format.dart';
import '../import_pipeline/ocr_document.dart';
import '../import_pipeline/ocr_document_client.dart';
import '../llm_providers/llm_provider_registry.dart';
import '../llm_providers/zhipu_ocr_client.dart';

/// Loads the currently active OCR engine profile, or null when none exists.
typedef ActiveOcrProfileLoader = Future<AiEngineProfile?> Function();

/// Explicit OCR production generation adapter (F1-I2).
///
/// OCR source truth is:
///
/// ```text
/// OcrDocumentClient -> OcrDocument -> OcrSourceDocumentAdapter -> SourceDocument
/// ```
///
/// The question OCR pipeline (regionizer/assembler/typed candidates/reference
/// answers) is deliberately not part of ParsedArtifact generation.
///
/// `resolvePlan()` is strictly offline: it never loads the active profile,
/// never touches a provider, and never inspects network state, so existing
/// OCR cache artifacts stay readable as cache hits even while OCR
/// configuration is temporarily absent.
final class OcrParsedArtifactGenerationAdapter
    implements ParsedArtifactGenerationPort {
  OcrParsedArtifactGenerationAdapter({
    required ManagedFileStorage managedFileStorage,
    required OcrDocumentClient ocrClient,
    required ActiveOcrProfileLoader activeOcrProfileLoader,
  })  : _managedFileStorage = managedFileStorage,
        _ocrClient = ocrClient,
        _activeOcrProfileLoader = activeOcrProfileLoader;

  final ManagedFileStorage _managedFileStorage;
  final OcrDocumentClient _ocrClient;
  final ActiveOcrProfileLoader _activeOcrProfileLoader;

  static const String ocrPdfRoute = 'ocr_pdf';
  static const String ocrImageRoute = 'ocr_image';
  static const String _parserVersion = 'glm-ocr.ocr-source-adapter.v1';
  static const int _optionsSchemaVersion = 1;
  static const OcrSourceDocumentAdapter _sourceDocumentAdapter =
      OcrSourceDocumentAdapter();

  @override
  Future<ParsedArtifactGenerationPlan> resolvePlan({
    required LibraryFile file,
    required ParsedArtifactParseOptions options,
  }) async {
    final route = switch (options.routeSelection) {
      ParsedArtifactRouteSelection.ocrPdf => _admitPdf(file),
      ParsedArtifactRouteSelection.ocrImage => _admitImage(file),
      _ => throw const ParsedArtifactGenerationException(
          ParsedArtifactGenerationFailure.unsupportedRoute,
        ),
    };
    return ParsedArtifactGenerationPlan(
      parserRoute: route,
      parserVersion: _parserVersion,
      optionsSchemaVersion: _optionsSchemaVersion,
    );
  }

  @override
  Future<SourceDocument> generate({
    required LibraryFile file,
    required String artifactId,
    required ParsedArtifactGenerationPlan plan,
  }) async {
    final String route;
    switch (plan.parserRoute) {
      case ocrPdfRoute:
        route = _admitPdf(file);
        break;
      case ocrImageRoute:
        route = _admitImage(file);
        break;
      default:
        throw const ParsedArtifactGenerationException(
          ParsedArtifactGenerationFailure.unsupportedRoute,
        );
    }

    final managed = await _resolveManagedFile(file);
    final profile = await _loadActiveProfile();
    final runtimeSourceName = _runtimeSourceName(file, artifactId, route);

    final OcrDocument document;
    try {
      document = await _ocrClient.parseFile(
        profile: profile,
        filePath: managed.path,
        sourceName: runtimeSourceName,
      );
    } on ZhipuOcrAuthenticationException {
      throw const ParsedArtifactGenerationException(
        ParsedArtifactGenerationFailure.temporarilyUnavailable,
      );
    } on ZhipuOcrRequestException {
      throw const ParsedArtifactGenerationException(
        ParsedArtifactGenerationFailure.temporarilyUnavailable,
      );
    } on TimeoutException {
      throw const ParsedArtifactGenerationException(
        ParsedArtifactGenerationFailure.temporarilyUnavailable,
      );
    } on SocketException {
      throw const ParsedArtifactGenerationException(
        ParsedArtifactGenerationFailure.temporarilyUnavailable,
      );
    } on ZhipuOcrResponseFormatException {
      throw const ParsedArtifactGenerationException(
        ParsedArtifactGenerationFailure.parseFailed,
      );
    } on ZhipuOcrInvalidPdfException {
      throw const ParsedArtifactGenerationException(
        ParsedArtifactGenerationFailure.parseFailed,
      );
    } catch (_) {
      // Anything else inside the client-call boundary is a provider
      // availability/transport failure.
      throw const ParsedArtifactGenerationException(
        ParsedArtifactGenerationFailure.temporarilyUnavailable,
      );
    }

    try {
      if (!document.hasUsableBlocks && document.markdown.trim().isEmpty) {
        throw const ParsedArtifactGenerationException(
          ParsedArtifactGenerationFailure.sourceUnavailable,
        );
      }
      final sourceDocument = _sourceDocumentAdapter.convert(
        document,
        sourceId: artifactId,
        displayLabel: file.displayName,
      );
      if (sourceDocument.documentRef.sourceId != artifactId) {
        throw const ParsedArtifactGenerationException(
          ParsedArtifactGenerationFailure.parseFailed,
        );
      }
      return sourceDocument;
    } on ParsedArtifactGenerationException {
      rethrow;
    } catch (_) {
      // A failure after the provider returned is a local projection issue.
      throw const ParsedArtifactGenerationException(
        ParsedArtifactGenerationFailure.parseFailed,
      );
    }
  }

  /// Explicit `ocr_pdf` admission (Amendment A): only a PDF-identified
  /// display name without a conflicting known MIME, or an unknown extension
  /// with `application/pdf`.
  String _admitPdf(LibraryFile file) {
    final format = ImportFormatDetection.fromPath(file.displayName);
    if (format == ImportFormat.pdf) {
      if (_conflictingKnownMime(
        file.mimeType,
        allowed: const <String>{'application/pdf'},
      )) {
        throw const ParsedArtifactGenerationException(
          ParsedArtifactGenerationFailure.unsupportedRoute,
        );
      }
      return ocrPdfRoute;
    }
    if (format == ImportFormat.unknown && file.mimeType == 'application/pdf') {
      return ocrPdfRoute;
    }
    throw const ParsedArtifactGenerationException(
      ParsedArtifactGenerationFailure.unsupportedRoute,
    );
  }

  /// Explicit `ocr_image` admission (Amendment A): only PNG or JPEG.
  String _admitImage(LibraryFile file) {
    final format = ImportFormatDetection.fromPath(file.displayName);
    if (format == ImportFormat.image) {
      final lower = file.displayName.toLowerCase();
      final allowed = lower.endsWith('.png') ? 'image/png' : 'image/jpeg';
      if (_conflictingKnownMime(file.mimeType, allowed: <String>{allowed})) {
        throw const ParsedArtifactGenerationException(
          ParsedArtifactGenerationFailure.unsupportedRoute,
        );
      }
      return ocrImageRoute;
    }
    if (format == ImportFormat.unknown &&
        (file.mimeType == 'image/png' || file.mimeType == 'image/jpeg')) {
      return ocrImageRoute;
    }
    throw const ParsedArtifactGenerationException(
      ParsedArtifactGenerationFailure.unsupportedRoute,
    );
  }

  /// Returns true when [mime] is a known media type that conflicts with the
  /// [allowed] set. Null/empty and `application/octet-stream` carry no known
  /// type signal.
  bool _conflictingKnownMime(String? mime, {required Set<String> allowed}) {
    if (mime == null || mime.isEmpty) return false;
    if (mime == 'application/octet-stream') return false;
    return !allowed.contains(mime);
  }

  /// Privacy-neutral provider runtime source name with the correct extension
  /// for MIME resolution. The user's display name never reaches the provider.
  String _runtimeSourceName(
    LibraryFile file,
    String artifactId,
    String route,
  ) {
    if (route == ocrPdfRoute) return '$artifactId.pdf';
    final lower = file.displayName.toLowerCase();
    if (lower.endsWith('.png') || file.mimeType == 'image/png') {
      return '$artifactId.png';
    }
    return '$artifactId.jpg';
  }

  Future<File> _resolveManagedFile(LibraryFile file) async {
    try {
      if (!await _managedFileStorage.managedFileExists(file.storageKey)) {
        throw const ParsedArtifactGenerationException(
          ParsedArtifactGenerationFailure.sourceUnavailable,
        );
      }
      return _managedFileStorage.resolveManagedFile(file.storageKey);
    } on ParsedArtifactGenerationException {
      rethrow;
    } catch (_) {
      throw const ParsedArtifactGenerationException(
        ParsedArtifactGenerationFailure.sourceUnavailable,
      );
    }
  }

  Future<AiEngineProfile> _loadActiveProfile() async {
    final AiEngineProfile? profile;
    try {
      profile = await _activeOcrProfileLoader();
    } catch (_) {
      throw const ParsedArtifactGenerationException(
        ParsedArtifactGenerationFailure.temporarilyUnavailable,
      );
    }
    if (profile == null ||
        !profile.isComplete ||
        profile.engineType != AiEngineType.ocr ||
        LlmProviderRegistry.kindForBaseUrl(profile.baseUrl) !=
            LlmProviderKind.zhipu) {
      throw const ParsedArtifactGenerationException(
        ParsedArtifactGenerationFailure.temporarilyUnavailable,
      );
    }
    return profile;
  }
}

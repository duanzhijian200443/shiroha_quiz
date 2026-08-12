library;

import '../../domain/assets/library_file.dart';
import '../../domain/assets/parsed_artifact.dart';
import '../../domain/source/source_document.dart';

/// Minimal typed route selection for A1 orchestration.
///
/// `auto` is a request-time selection only and must never be persisted as a
/// parser route; it resolves only to deterministic routes and never
/// implicitly to OCR.
enum ParsedArtifactRouteSelection {
  auto,
  pdfText,
  docxText,
  txt,
  markdown,
  ocrPdf,
  ocrImage,
}

/// Frozen A1 parse options. A1 defines no OCR/provider tuning knobs.
final class ParsedArtifactParseOptions {
  const ParsedArtifactParseOptions({required this.routeSelection});

  final ParsedArtifactRouteSelection routeSelection;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is ParsedArtifactParseOptions &&
            routeSelection == other.routeSelection;
  }

  @override
  int get hashCode => routeSelection.hashCode;
}

/// Minimal safe artifact snapshot exposed to Presentation/Agent/MCP.
///
/// Never carries SQLite rows, storage keys, absolute/resolved paths, sidecar
/// bytes, raw JSON, provider documents, or raw exceptions.
final class ParsedArtifactSnapshot {
  const ParsedArtifactSnapshot({
    required this.artifact,
    required this.sourceDocument,
  });

  final ParsedArtifact artifact;
  final SourceDocument sourceDocument;
}

enum ParsedArtifactLifecycleOutcome { cacheHit, published }

/// Result of one ensure/reparse call.
final class ParsedArtifactEnsureResult {
  const ParsedArtifactEnsureResult({
    required this.outcome,
    required this.snapshot,
  });

  final ParsedArtifactLifecycleOutcome outcome;
  final ParsedArtifactSnapshot snapshot;
}

/// Canonical 11-item Application failure taxonomy.
enum ParsedArtifactLifecycleFailure {
  invalidRequest,
  fileNotFound,
  unsupportedRoute,
  sourceUnavailable,
  parseFailed,
  publishConflict,
  artifactMissing,
  artifactCorrupt,
  payloadUnsupported,
  temporarilyUnavailable,
  internalError,
}

/// Fixed safe lifecycle failure.
///
/// Retains no arbitrary message, raw cause, SQL, path, storage key, or
/// provider body; [toString] renders one fixed safe message per failure.
final class ParsedArtifactLifecycleException implements Exception {
  const ParsedArtifactLifecycleException(this.failure);

  final ParsedArtifactLifecycleFailure failure;

  @override
  String toString() {
    final detail = switch (failure) {
      ParsedArtifactLifecycleFailure.invalidRequest =>
        'The parsed artifact request is invalid.',
      ParsedArtifactLifecycleFailure.fileNotFound =>
        'The library file does not exist.',
      ParsedArtifactLifecycleFailure.unsupportedRoute =>
        'The requested parser route is unsupported.',
      ParsedArtifactLifecycleFailure.sourceUnavailable =>
        'The source file is unavailable for parsing.',
      ParsedArtifactLifecycleFailure.parseFailed =>
        'The parse generation failed.',
      ParsedArtifactLifecycleFailure.publishConflict =>
        'The artifact revision changed concurrently.',
      ParsedArtifactLifecycleFailure.artifactMissing =>
        'The current artifact does not exist.',
      ParsedArtifactLifecycleFailure.artifactCorrupt =>
        'The current artifact payload is corrupt.',
      ParsedArtifactLifecycleFailure.payloadUnsupported =>
        'The current artifact payload version is unsupported.',
      ParsedArtifactLifecycleFailure.temporarilyUnavailable =>
        'The parsed artifact service is temporarily unavailable.',
      ParsedArtifactLifecycleFailure.internalError =>
        'The parsed artifact service encountered an internal error.',
    };
    return 'ParsedArtifactLifecycleException(${failure.name}): $detail';
  }
}

/// Stable Application seam for parsed-artifact lifecycle operations.
///
/// Presentation, Agent, and MCP consume artifacts only through this port.
/// Implementations orchestrate the frozen D1 repository/storage primitives
/// behind one process-wide per-file mutation gate and never expose SQLite
/// rows, absolute paths, or provider documents.
abstract interface class ParsedArtifactLifecyclePort {
  /// Reads the current artifact for [fileId], verifying sidecar integrity,
  /// strict payload decode, and identity binding.
  Future<ParsedArtifactSnapshot> getCurrentArtifact(String fileId);

  /// Returns the current artifact when its semantic cache facts and payload
  /// match, otherwise generates and publishes a new generation.
  Future<ParsedArtifactEnsureResult> ensureParsedArtifact({
    required String fileId,
    required ParsedArtifactParseOptions options,
  });

  /// Always bypasses the cache and publishes a new generation when
  /// [expectedRevision] matches the retained revision head.
  Future<ParsedArtifactEnsureResult> reparseArtifact({
    required String fileId,
    required ParsedArtifactParseOptions options,
    required int expectedRevision,
  });

  /// Removes the current artifact while retaining the revision head.
  Future<void> removeCurrentArtifact({
    required String fileId,
    required int expectedRevision,
  });
}

/// Safe, path/provider-free plan produced by a generation port.
final class ParsedArtifactGenerationPlan {
  const ParsedArtifactGenerationPlan({
    required this.parserRoute,
    required this.parserVersion,
    required this.optionsSchemaVersion,
  });

  final String parserRoute;
  final String parserVersion;
  final int optionsSchemaVersion;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is ParsedArtifactGenerationPlan &&
            parserRoute == other.parserRoute &&
            parserVersion == other.parserVersion &&
            optionsSchemaVersion == other.optionsSchemaVersion;
  }

  @override
  int get hashCode =>
      Object.hash(parserRoute, parserVersion, optionsSchemaVersion);
}

/// Safe classification of generation-port failures.
enum ParsedArtifactGenerationFailure {
  unsupportedRoute,
  sourceUnavailable,
  parseFailed,
  temporarilyUnavailable,
}

/// Fixed safe generation failure; retains no raw cause or provider body.
final class ParsedArtifactGenerationException implements Exception {
  const ParsedArtifactGenerationException(this.failure);

  final ParsedArtifactGenerationFailure failure;

  @override
  String toString() {
    final detail = switch (failure) {
      ParsedArtifactGenerationFailure.unsupportedRoute =>
        'The parse route is unsupported.',
      ParsedArtifactGenerationFailure.sourceUnavailable =>
        'The source file is unavailable for parsing.',
      ParsedArtifactGenerationFailure.parseFailed =>
        'The parse generation failed.',
      ParsedArtifactGenerationFailure.temporarilyUnavailable =>
        'The parse generation service is temporarily unavailable.',
    };
    return 'ParsedArtifactGenerationException(${failure.name}): $detail';
  }
}

/// Provider-neutral generation port implemented by F1-I1 (deterministic
/// routes) and F1-I2 (explicit OCR). A1 orchestrates through this port and
/// never calls a parser directly.
abstract interface class ParsedArtifactGenerationPort {
  /// Resolves the persisted parser route/version for [file] and [options].
  Future<ParsedArtifactGenerationPlan> resolvePlan({
    required LibraryFile file,
    required ParsedArtifactParseOptions options,
  });

  /// Generates the [SourceDocument] bound to [artifactId].
  Future<SourceDocument> generate({
    required LibraryFile file,
    required String artifactId,
    required ParsedArtifactGenerationPlan plan,
  });
}

/// Versioned opaque cache identity (v1).
///
/// The concrete hash algorithm is an implementation detail of cacheKeyVersion
/// 1, not a permanent architecture contract.
final class ParsedArtifactCacheKey {
  const ParsedArtifactCacheKey({
    required this.version,
    required this.fingerprint,
  });

  final int version;
  final String fingerprint;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is ParsedArtifactCacheKey &&
            version == other.version &&
            fingerprint == other.fingerprint;
  }

  @override
  int get hashCode => Object.hash(version, fingerprint);
}

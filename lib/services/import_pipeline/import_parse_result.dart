import 'package:shiroha_quiz/application/import_review/typed_review_snapshot.dart';

import 'import_question_field_policy.dart';
import 'ocr_typed_candidate.dart';

/// Immutable validated task-level storage metadata.
///
/// Produced only by [validateImportStorageMetadata]; no invalid route or
/// reason combination can reach production consumers through this boundary.
final class ValidatedImportStorageMetadata {
  const ValidatedImportStorageMetadata({
    required this.route,
    required this.reason,
  });

  final ImportStorageRoute route;
  final String? reason;
}

/// Strict validation boundary for task-level storage metadata.
///
/// Rules:
/// - [ImportStorageRoute.legacyV1]: reason must be absent or a bounded
///   lower_snake_case scalar (historical fixed reasons continue to pass).
/// - [ImportStorageRoute.typedV2]: reason must be exactly
///   [ocrTypedCandidateReadyReason]; typedV2 with a null, shadow-ready or
///   any other reason fails.
/// - Unknown routes fail.
///
/// Every production consumer (Pipeline, Coordinator, Staging and the typed
/// commit service) must use this boundary; the raw const constructor remains
/// only for legacy compatibility call sites.
ValidatedImportStorageMetadata validateImportStorageMetadata({
  required ImportStorageRoute route,
  required Object? reason,
}) {
  final normalizedReason = normalizeImportStorageReason(reason);
  switch (route) {
    case ImportStorageRoute.legacyV1:
      return ValidatedImportStorageMetadata(
        route: route,
        reason: normalizedReason,
      );
    case ImportStorageRoute.typedV2:
      if (normalizedReason != ocrTypedCandidateReadyReason) {
        throw const TypedReviewSnapshotException(
          TypedReviewSnapshotFailure.invalidEnvelope,
        );
      }
      return ValidatedImportStorageMetadata(
        route: route,
        reason: normalizedReason,
      );
  }
}

class ImportParseResult {
  final List<Map<String, dynamic>> questions;
  final List<String> warnings;
  final Map<String, dynamic> diagnostics;
  final bool blocked;
  final String? blockReason;
  final ExplanationRetentionMode explanationRetentionMode;
  final ImportStorageRoute storageRoute;
  final String? storageReason;

  const ImportParseResult({
    required this.questions,
    this.warnings = const [],
    this.diagnostics = const {},
    this.blocked = false,
    this.blockReason,
    this.explanationRetentionMode = ExplanationRetentionMode.subjectiveOnly,
    this.storageRoute = ImportStorageRoute.legacyV1,
    this.storageReason,
  });

  /// Strict construction boundary for R7B shadow storage metadata.
  ///
  /// [storageReason] and [storageRoute] pass through
  /// [validateImportStorageMetadata]: legacyV1 accepts null or bounded
  /// lower_snake_case scalars, while typedV2 requires exactly
  /// [ocrTypedCandidateReadyReason]. Invalid combinations throw the fixed
  /// [TypedReviewSnapshotException].
  factory ImportParseResult.withStorageMetadata({
    required List<Map<String, dynamic>> questions,
    List<String> warnings = const [],
    Map<String, dynamic> diagnostics = const {},
    bool blocked = false,
    String? blockReason,
    ExplanationRetentionMode explanationRetentionMode =
        ExplanationRetentionMode.subjectiveOnly,
    ImportStorageRoute storageRoute = ImportStorageRoute.legacyV1,
    String? storageReason,
  }) {
    final validated = validateImportStorageMetadata(
      route: storageRoute,
      reason: storageReason,
    );
    return ImportParseResult(
      questions: questions,
      warnings: warnings,
      diagnostics: diagnostics,
      blocked: blocked,
      blockReason: blockReason,
      explanationRetentionMode: explanationRetentionMode,
      storageRoute: validated.route,
      storageReason: validated.reason,
    );
  }
}

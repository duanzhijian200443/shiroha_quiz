import 'package:shiroha_quiz/application/import_review/typed_review_snapshot.dart';

import 'import_question_field_policy.dart';

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
  /// [storageReason] is normalized with [normalizeImportStorageReason] so
  /// only bounded lower_snake_case scalars (or null) can enter the task
  /// diagnostics; the route is always [ImportStorageRoute.legacyV1] in R7B.
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
    return ImportParseResult(
      questions: questions,
      warnings: warnings,
      diagnostics: diagnostics,
      blocked: blocked,
      blockReason: blockReason,
      explanationRetentionMode: explanationRetentionMode,
      storageRoute: storageRoute,
      storageReason: normalizeImportStorageReason(storageReason),
    );
  }
}

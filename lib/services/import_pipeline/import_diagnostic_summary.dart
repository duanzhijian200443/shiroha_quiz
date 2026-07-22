import 'package:shiroha_quiz/services/import_pipeline/import_diagnostic_message.dart';

enum ImportTaskOutcome { success, emptyResult, failure, processing }

class ImportDiagnosticSummary {
  final ImportTaskOutcome outcome;
  final String outcomeLabel;
  final String? parseMode;
  final String? traceId;
  final Duration? elapsed;
  final String? lastSuccessStage;
  final String? failedStage;
  final String? errorType;
  final bool suggestRetry;
  final String? userGuidance;
  final List<ImportDiagnosticMessage> details;
  final Map<String, String> technicalFields;

  ImportDiagnosticSummary({
    required this.outcome,
    required this.outcomeLabel,
    this.parseMode,
    this.traceId,
    this.elapsed,
    this.lastSuccessStage,
    this.failedStage,
    this.errorType,
    this.suggestRetry = false,
    this.userGuidance,
    this.details = const [],
    this.technicalFields = const {},
  });
}

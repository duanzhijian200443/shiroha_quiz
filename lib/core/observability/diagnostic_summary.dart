import 'trace_context.dart';

/// OBS-1 whitelist-only diagnostic summary used for user-facing
/// `复制诊断信息` (copy diagnostic info) actions.
///
/// Only structural, fixed-category fields may be present here. User message
/// text, Assistant text, prompts, tool arguments/outputs, RAG passages,
/// question/answer bodies, StudyPlan text, provider bodies/reasoning, keys,
/// tokens, base64, absolute paths and raw exceptions must never be carried
/// by this type.
final class DiagnosticSummary {
  const DiagnosticSummary({
    required this.diagnosticId,
    required this.operation,
    this.failure,
    this.status,
    this.providerRounds,
    this.toolCalls,
    this.lastTool,
    this.durationMs,
    this.taskId,
    this.attemptNumber,
    this.traceId,
  });

  /// The user-visible diagnostic number (`OBS-XXXX-XXXX`).
  final String diagnosticId;

  /// Fixed operation word (`agent_turn`, `import_attempt`, ...).
  final String operation;

  /// Fixed failure code / category, never a raw exception message.
  final String? failure;

  /// Fixed status word (`success`, `failed`, `cancelled`, ...).
  final String? status;

  final int? providerRounds;
  final int? toolCalls;
  final String? lastTool;
  final int? durationMs;
  final String? taskId;
  final int? attemptNumber;
  final String? traceId;
}

/// Hard-limited formatter for [DiagnosticSummary].
///
/// Output uses fixed field names only; every value is bounded in length and
/// stripped of control characters. Returns null when the summary cannot be
/// formatted safely (for example an invalid diagnostic id), in which case the
/// caller simply hides the diagnostic affordance.
abstract final class DiagnosticSummaryFormatter {
  static const int maxValueLength = 64;
  static const int maxTotalLength = 2000;

  static final RegExp _operationPattern = RegExp(r'^[a-z_]{1,32}$');

  /// Fixed safe token/category pattern for whitelist fields: letters,
  /// digits, underscore and hyphen only, bounded length. Any value that does
  /// not conform is omitted from the formatted output.
  static final RegExp _tokenPattern = RegExp(r'^[A-Za-z0-9_\-]{1,64}$');

  /// True only for strictly valid OBS-1 diagnostic ids; callers use this to
  /// gate user-visible diagnostic affordances.
  static bool isValidDiagnosticId(String value) =>
      TraceContext.isValidCorrelationId(value);

  static String? format(DiagnosticSummary summary) {
    final diagnosticId = summary.diagnosticId;
    final operation = summary.operation;
    if (!isValidDiagnosticId(diagnosticId) ||
        !_operationPattern.hasMatch(operation)) {
      return null;
    }

    final buffer = StringBuffer(
      'Shiroha diagnostic\n\ndiagnosticId=$diagnosticId\noperation=$operation',
    );
    void add(String key, String? value) {
      if (value == null || !_tokenPattern.hasMatch(value)) return;
      buffer.write('\n$key=$value');
    }

    add('failure', summary.failure);
    add('status', summary.status);
    add('providerRounds', summary.providerRounds?.toString());
    add('toolCalls', summary.toolCalls?.toString());
    add('lastTool', summary.lastTool);
    add('durationMs', summary.durationMs?.toString());
    add('taskId', summary.taskId);
    add('attemptNumber', summary.attemptNumber?.toString());
    add('traceId', summary.traceId);

    var text = buffer.toString();
    if (text.length > maxTotalLength) {
      text = '${text.substring(0, maxTotalLength)}...[TRUNCATED]';
    }
    return text;
  }
}

import 'dart:async';
import 'dart:math';

/// Fixed, deliberately small taxonomy of Shiroha operations that participate
/// in the unified operation trace (OBS-1). Do not grow this into a broad
/// classification of every application action.
enum TraceOperationKind {
  agentTurn,
  importAttempt,
  parsedArtifactGeneration,
  ragRetrieval,
}

/// Correlation data that follows an asynchronous operation through Dart zones.
///
/// OBS-1 frozen identity semantics:
/// - [correlationId]: one user-visible diagnostic id per user-level workflow
///   (`diagnosticId == correlationId`, product copy: 诊断编号). It is short,
///   random, carries no time/file/user/title semantics, is safe to display,
///   and can be used directly to filter logs.
/// - [traceId]: one concrete execution attempt / operation. Different
///   operations never share a traceId merely to appear "unified".
/// - [parentTraceId]: the trace that directly triggered the current
///   operation; used to build the trace tree.
///
/// Zone propagation is authoritative only within one execution boundary.
/// Isolate / Process / native background boundaries never inherit this
/// context implicitly; future cross-boundary work must pass correlation
/// context explicitly.
abstract final class TraceContext {
  static const Symbol _correlationIdKey = #shirohaCorrelationId;
  static const Symbol _traceIdKey = #shirohaTraceId;
  static const Symbol _parentTraceIdKey = #shirohaParentTraceId;
  static const Symbol _operationKindKey = #shirohaOperationKind;
  static const Symbol _taskIdKey = #shirohaTaskId;

  static final Random _random = Random.secure();

  static String? get correlationId =>
      Zone.current[_correlationIdKey] as String?;
  static String? get traceId => Zone.current[_traceIdKey] as String?;
  static String? get parentTraceId =>
      Zone.current[_parentTraceIdKey] as String?;
  static TraceOperationKind? get operationKind =>
      Zone.current[_operationKindKey] as TraceOperationKind?;
  static String? get taskId => Zone.current[_taskIdKey] as String?;

  /// Runs [action] inside a fresh execution context.
  ///
  /// Backward-compatible core: explicit [traceId] / [taskId] remain
  /// supported. When [correlationId] is omitted the current zone's
  /// correlation is inherited (or a new one is created); [parentTraceId] and
  /// [operationKind] are only set when explicitly provided. New OBS-1 code
  /// should prefer [runRoot] / [runOperation] instead.
  static Future<T> run<T>({
    required Future<T> Function() action,
    String? traceId,
    String? taskId,
    String? correlationId,
    String? parentTraceId,
    TraceOperationKind? operationKind,
  }) {
    return runZoned(
      action,
      zoneValues: <Object?, Object?>{
        _correlationIdKey: correlationId ??
            Zone.current[_correlationIdKey] as String? ??
            createCorrelationId(),
        _traceIdKey: traceId ?? createTraceId(),
        _parentTraceIdKey: parentTraceId,
        _operationKindKey: operationKind,
        _taskIdKey: taskId,
      },
    );
  }

  /// Runs [action] as a root operation: a new correlation, a new trace and
  /// `parentTraceId = null`, regardless of any enclosing zone. A root never
  /// inherits the enclosing zone's taskId: without an explicit [taskId] the
  /// root zone observes `taskId == null`.
  static Future<T> runRoot<T>({
    required TraceOperationKind operationKind,
    required Future<T> Function() action,
    String? taskId,
    String? traceId,
    String? correlationId,
  }) {
    return run(
      action: action,
      traceId: traceId ?? createTraceId(),
      taskId: taskId,
      correlationId: correlationId ?? createCorrelationId(),
      operationKind: operationKind,
    );
  }

  /// Runs [action] as a child of the current zone when a trace is active:
  /// the correlation is inherited, a new trace is created and
  /// `parentTraceId = current traceId`. Without an enclosing trace this
  /// degrades to a root operation (new correlation, parent null).
  static Future<T> runOperation<T>({
    required TraceOperationKind operationKind,
    required Future<T> Function() action,
    String? taskId,
    String? traceId,
    String? correlationId,
    String? parentTraceId,
  }) {
    final current = Zone.current;
    return run(
      action: action,
      traceId: traceId ?? createTraceId(),
      // A child operation inherits the enclosing taskId (current behavior).
      taskId: taskId ?? current[_taskIdKey] as String?,
      correlationId: correlationId ?? current[_correlationIdKey] as String?,
      parentTraceId: parentTraceId ?? current[_traceIdKey] as String?,
      operationKind: operationKind,
    );
  }

  /// Short random diagnostic id in the form `OBS-XXXX-XXXX`. No time, file,
  /// user or conversation semantics; safe for display and log filtering.
  static const String _correlationAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

  static String createCorrelationId() {
    final buffer = StringBuffer('OBS-');
    for (var group = 0; group < 2; group++) {
      if (group > 0) buffer.write('-');
      for (var index = 0; index < 4; index++) {
        buffer.write(
          _correlationAlphabet[_random.nextInt(_correlationAlphabet.length)],
        );
      }
    }
    return buffer.toString();
  }

  static String createTraceId() {
    final timestamp = DateTime.now().toUtc().microsecondsSinceEpoch;
    final entropy = _random.nextInt(0x7fffffff).toRadixString(16);
    return 'trace-$timestamp-$entropy';
  }
}

import '../../core/observability/log_writer.dart';
import '../../core/observability/trace_context.dart';

/// Bounded destructive authorities closed by DM-D5.
///
/// These values are safe operation categories. Entity ids, titles, file
/// names, paths, storage keys and user content never belong in this trace.
enum DestructiveMutationKind {
  questionDelete,
  questionBankDelete,
  libraryFileDelete,
  projectDelete,
  conversationDelete,
  reviewStateReset,
  questionDataClearAll,
  studyPlanStop,
  examPaperDelete,
}

enum DestructiveMutationOutcome {
  completed,
  completedWithOrphan,
  rejected,
  failed,
}

typedef DestructiveMutationOutcomeResolver<T> = DestructiveMutationOutcome
    Function(T result);

/// Pure-Dart, best-effort destructive-operation trace seam.
///
/// Business authority and results remain owned by the wrapped Application
/// command. Trace failures are swallowed and error objects are never logged.
abstract final class DestructiveMutationTrace {
  static Future<T> run<T>({
    required DestructiveMutationKind kind,
    required Future<T> Function() action,
    DestructiveMutationOutcomeResolver<T>? outcome,
  }) {
    return TraceContext.runOperation(
      operationKind: TraceOperationKind.destructiveMutation,
      action: () async {
        _record('destructive_started', kind, status: 'started');
        try {
          final result = await action();
          final resolved =
              outcome?.call(result) ?? DestructiveMutationOutcome.completed;
          _recordOutcome(kind, resolved);
          return result;
        } catch (_) {
          _record(
            'destructive_failed',
            kind,
            status: 'failed',
            failureCode: 'operation_failed',
          );
          rethrow;
        }
      },
    );
  }

  /// Records a denied/stale destructive request without invoking authority.
  static Future<void> rejected(DestructiveMutationKind kind) {
    return TraceContext.runOperation(
      operationKind: TraceOperationKind.destructiveMutation,
      action: () async {
        _record('destructive_rejected', kind, status: 'rejected');
      },
    );
  }

  static void _recordOutcome(
    DestructiveMutationKind kind,
    DestructiveMutationOutcome outcome,
  ) {
    switch (outcome) {
      case DestructiveMutationOutcome.completed:
        _record('destructive_completed', kind, status: 'completed');
      case DestructiveMutationOutcome.completedWithOrphan:
        _record(
          'destructive_completed',
          kind,
          status: 'completed_with_orphan',
          cleanupOutcome: 'orphaned',
        );
      case DestructiveMutationOutcome.rejected:
        _record('destructive_rejected', kind, status: 'rejected');
      case DestructiveMutationOutcome.failed:
        _record(
          'destructive_failed',
          kind,
          status: 'failed',
          failureCode: 'operation_failed',
        );
    }
  }

  static void _record(
    String event,
    DestructiveMutationKind kind, {
    required String status,
    String? failureCode,
    String? cleanupOutcome,
  }) {
    try {
      LogWriter.info(
        event,
        module: 'DestructiveMutation',
        data: <String, Object?>{
          'event': event,
          'mutationKind': kind.name,
          'status': status,
          if (failureCode != null) 'failureCode': failureCode,
          if (cleanupOutcome != null) 'cleanupOutcome': cleanupOutcome,
        },
      );
    } catch (_) {
      // Observability is best effort and never changes the business result.
    }
  }
}

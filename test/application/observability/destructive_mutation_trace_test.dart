import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/observability/destructive_mutation_trace.dart';
import 'package:shiroha_quiz/core/observability/log_record.dart';
import 'package:shiroha_quiz/core/observability/log_writer.dart';
import 'package:shiroha_quiz/core/observability/trace_context.dart';

void main() {
  tearDown(() {
    LogWriter.setRecordHandler(null);
  });

  test('successful destructive authority emits one correlated lifecycle',
      () async {
    final records = <LogRecord>[];
    LogWriter.setRecordHandler(records.add);

    final result = await DestructiveMutationTrace.run<int>(
      kind: DestructiveMutationKind.questionDelete,
      action: () async => 7,
    );

    expect(result, 7);
    expect(
      records.map((record) => record.message),
      <String>['destructive_started', 'destructive_completed'],
    );
    expect(records.map((record) => record.traceId).toSet(), hasLength(1));
    expect(
      records.every(
        (record) =>
            record.operationKind == TraceOperationKind.destructiveMutation &&
            record.data['mutationKind'] == 'questionDelete',
      ),
      isTrue,
    );
  });

  test('post-commit orphan is completed_with_orphan, never failed', () async {
    final records = <LogRecord>[];
    LogWriter.setRecordHandler(records.add);

    await DestructiveMutationTrace.run<void>(
      kind: DestructiveMutationKind.libraryFileDelete,
      action: () async {},
      outcome: (_) => DestructiveMutationOutcome.completedWithOrphan,
    );

    expect(records.last.message, 'destructive_completed');
    expect(records.last.data['status'], 'completed_with_orphan');
    expect(records.last.data['cleanupOutcome'], 'orphaned');
    expect(
      records.where((record) => record.message == 'destructive_failed'),
      isEmpty,
    );
  });

  test('failure is fixed and rethrows without logging the exception', () async {
    final records = <LogRecord>[];
    LogWriter.setRecordHandler(records.add);

    await expectLater(
      DestructiveMutationTrace.run<void>(
        kind: DestructiveMutationKind.examPaperDelete,
        action: () async => throw StateError('private failure body'),
      ),
      throwsStateError,
    );

    expect(records.last.message, 'destructive_failed');
    expect(records.last.data['failureCode'], 'operation_failed');
    expect(records.join(), isNot(contains('private failure body')));
    expect(records.last.data.keys, isNot(contains('error')));
  });

  test('rejected request records zero authority execution', () async {
    final records = <LogRecord>[];
    LogWriter.setRecordHandler(records.add);

    await DestructiveMutationTrace.rejected(
      DestructiveMutationKind.studyPlanStop,
    );

    expect(records, hasLength(1));
    expect(records.single.message, 'destructive_rejected');
    expect(records.single.data['status'], 'rejected');
  });

  test('observer failure cannot change the business result', () async {
    LogWriter.setRecordHandler((_) => throw StateError('observer failed'));

    expect(
      await DestructiveMutationTrace.run<int>(
        kind: DestructiveMutationKind.projectDelete,
        action: () async => 9,
      ),
      9,
    );
  });
}

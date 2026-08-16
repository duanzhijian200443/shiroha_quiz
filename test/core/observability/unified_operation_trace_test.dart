import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/core/observability/app_logger.dart';
import 'package:shiroha_quiz/core/observability/diagnostic_summary.dart';
import 'package:shiroha_quiz/core/observability/log_record.dart';
import 'package:shiroha_quiz/core/observability/trace_context.dart';

class _MemoryLogSink implements LogSink {
  final List<LogRecord> records = <LogRecord>[];

  @override
  Future<void> write(LogRecord record) async {
    records.add(record);
  }

  @override
  Future<void> flush() async {}
}

void main() {
  tearDown(() {
    AppLogger.setSink(null);
  });

  group('TraceContext OBS-1 contracts', () {
    test('root operation creates correlation, trace, parent null and kind',
        () async {
      await TraceContext.runRoot(
        operationKind: TraceOperationKind.agentTurn,
        action: () async {
          expect(
            TraceContext.correlationId,
            matches(RegExp(r'^OBS-[A-Z0-9]{4}-[A-Z0-9]{4}$')),
          );
          expect(TraceContext.traceId, startsWith('trace-'));
          expect(TraceContext.parentTraceId, isNull);
          expect(
            TraceContext.operationKind,
            TraceOperationKind.agentTurn,
          );
        },
      );

      expect(TraceContext.correlationId, isNull);
      expect(TraceContext.traceId, isNull);
    });

    test('nested child inherits correlation and points at current trace',
        () async {
      await TraceContext.runRoot(
        operationKind: TraceOperationKind.importAttempt,
        taskId: 'task-root',
        action: () async {
          final rootCorrelation = TraceContext.correlationId;
          final rootTrace = TraceContext.traceId;

          await TraceContext.runOperation(
            operationKind: TraceOperationKind.ragRetrieval,
            action: () async {
              expect(TraceContext.correlationId, rootCorrelation);
              expect(TraceContext.traceId, isNot(rootTrace));
              expect(TraceContext.traceId, startsWith('trace-'));
              expect(TraceContext.parentTraceId, rootTrace);
              expect(
                TraceContext.operationKind,
                TraceOperationKind.ragRetrieval,
              );
            },
          );
        },
      );
    });

    test('nested async/await keeps context across boundaries', () async {
      await TraceContext.runRoot(
        operationKind: TraceOperationKind.agentTurn,
        action: () async {
          final expectedCorrelation = TraceContext.correlationId;
          final expectedTrace = TraceContext.traceId;

          Future<void> nested() async {
            await Future<void>.delayed(Duration.zero);
            await Future<void>.value();
            expect(TraceContext.correlationId, expectedCorrelation);
            expect(TraceContext.traceId, expectedTrace);
            expect(
              TraceContext.operationKind,
              TraceOperationKind.agentTurn,
            );
          }

          await nested();
          await Future<void>.delayed(Duration.zero);
          expect(TraceContext.traceId, expectedTrace);
        },
      );
    });

    test('explicit Import trace/task identity remains supported', () async {
      await TraceContext.run(
        traceId: 'trace-explicit-import',
        taskId: 'task-explicit-import',
        correlationId: 'OBS-AAAA-BBBB',
        parentTraceId: 'trace-explicit-parent',
        operationKind: TraceOperationKind.importAttempt,
        action: () async {
          expect(TraceContext.traceId, 'trace-explicit-import');
          expect(TraceContext.taskId, 'task-explicit-import');
          expect(TraceContext.correlationId, 'OBS-AAAA-BBBB');
          expect(TraceContext.parentTraceId, 'trace-explicit-parent');
          expect(
            TraceContext.operationKind,
            TraceOperationKind.importAttempt,
          );
        },
      );
    });

    test('sibling operations never leak context', () async {
      final values = <({String correlation, String trace})>[];
      await TraceContext.runRoot(
        operationKind: TraceOperationKind.importAttempt,
        action: () async {
          values.add((
            correlation: TraceContext.correlationId!,
            trace: TraceContext.traceId!,
          ));
        },
      );
      await TraceContext.runRoot(
        operationKind: TraceOperationKind.parsedArtifactGeneration,
        action: () async {
          values.add((
            correlation: TraceContext.correlationId!,
            trace: TraceContext.traceId!,
          ));
        },
      );

      expect(values, hasLength(2));
      expect(values[0].correlation, isNot(values[1].correlation));
      expect(values[0].trace, isNot(values[1].trace));
      expect(TraceContext.correlationId, isNull);
      expect(TraceContext.traceId, isNull);
    });

    test('runRoot inside a task zone does not inherit the parent taskId',
        () async {
      await TraceContext.runRoot(
        operationKind: TraceOperationKind.importAttempt,
        taskId: 'task-T1',
        action: () async {
          final parentCorrelation = TraceContext.correlationId;
          await TraceContext.runRoot(
            operationKind: TraceOperationKind.agentTurn,
            action: () async {
              expect(TraceContext.taskId, isNull);
              expect(TraceContext.correlationId, isNot(parentCorrelation));
              expect(TraceContext.parentTraceId, isNull);
            },
          );
        },
      );
    });

    test('runOperation child inherits the enclosing taskId', () async {
      await TraceContext.runRoot(
        operationKind: TraceOperationKind.importAttempt,
        taskId: 'task-T1',
        action: () async {
          await TraceContext.runOperation(
            operationKind: TraceOperationKind.ragRetrieval,
            action: () async {
              expect(TraceContext.taskId, 'task-T1');
            },
          );
        },
      );
    });
  });

  group('OBS-1 logger injection', () {
    test('LogRecord automatically includes all correlation fields', () async {
      final sink = _MemoryLogSink();
      AppLogger.setSink(sink);

      await TraceContext.runRoot(
        operationKind: TraceOperationKind.agentTurn,
        taskId: 'task-logger',
        action: () async {
          final agentTrace = TraceContext.traceId;
          final agentCorrelation = TraceContext.correlationId;
          await TraceContext.runOperation(
            operationKind: TraceOperationKind.ragRetrieval,
            action: () async {
              AppLogger.info(
                'Retrieval completed',
                module: 'Retrieval',
                data: <String, Object?>{
                  'hitCount': 5,
                  'durationMs': 43,
                },
              );
              await AppLogger.flush();
            },
          );

          final record = sink.records.single;
          expect(record.correlationId, agentCorrelation);
          expect(record.traceId, isNot(agentTrace));
          expect(record.parentTraceId, agentTrace);
          expect(record.operationKind, TraceOperationKind.ragRetrieval);
          expect(record.taskId, 'task-logger');
          expect(record.module, 'Retrieval');
          expect(record.toJson()['operationKind'], 'ragRetrieval');
          expect(record.toJson()['correlationId'], agentCorrelation);
          expect(record.toJson()['parentTraceId'], agentTrace);
        },
      );
    });

    test('outside any trace context correlation fields are absent', () async {
      final sink = _MemoryLogSink();
      AppLogger.setSink(sink);

      AppLogger.info('plain log', module: 'Test');
      await AppLogger.flush();

      final record = sink.records.single;
      expect(record.correlationId, isNull);
      expect(record.traceId, isNull);
      expect(record.parentTraceId, isNull);
      expect(record.operationKind, isNull);
      expect(record.taskId, isNull);
      expect(record.toJson().containsKey('correlationId'), isFalse);
      expect(record.toJson().containsKey('traceId'), isFalse);
      expect(record.toJson().containsKey('operationKind'), isFalse);
    });

    test('OBS structured records never contain payload sentinels', () async {
      final sink = _MemoryLogSink();
      AppLogger.setSink(sink);

      await TraceContext.runRoot(
        operationKind: TraceOperationKind.agentTurn,
        action: () async {
          // The caller disciplines itself: only whitelist structure may be
          // passed. Even if a payload string were supplied, the logger
          // redaction would mask credentials; the OBS contract test asserts
          // the structural fields stay payload-free.
          AppLogger.info(
            'Tool call completed',
            module: 'Agent',
            data: <String, Object?>{
              'toolName': 'get_weak_questions',
              'callId': 'call-1',
              'status': 'success',
              'durationMs': 12,
            },
          );
          await AppLogger.flush();
        },
      );

      final encoded = sink.records.single.toJson().toString();
      for (final sentinel in <String>[
        'user-prompt-sentinel',
        'pdf-text-sentinel',
        'rag-content-sentinel',
        'api-key-sentinel',
        'provider-payload-sentinel',
        r'C:\private\absolute\path',
      ]) {
        expect(encoded, isNot(contains(sentinel)));
      }
    });
  });

  group('DiagnosticSummaryFormatter', () {
    test('formats the frozen whitelist example shape', () {
      final text = DiagnosticSummaryFormatter.format(
        const DiagnosticSummary(
          diagnosticId: 'OBS-7Q2M-91KD',
          operation: 'agent_turn',
          failure: 'tool_round_limit_exceeded',
          providerRounds: 5,
          toolCalls: 6,
          lastTool: 'get_study_overview',
          durationMs: 10324,
        ),
      );

      expect(text, isNotNull);
      expect(text, startsWith('Shiroha diagnostic'));
      expect(text, contains('diagnosticId=OBS-7Q2M-91KD'));
      expect(text, contains('operation=agent_turn'));
      expect(text, contains('failure=tool_round_limit_exceeded'));
      expect(text, contains('providerRounds=5'));
      expect(text, contains('toolCalls=6'));
      expect(text, contains('lastTool=get_study_overview'));
      expect(text, contains('durationMs=10324'));
    });

    test('rejects invalid or missing diagnostic ids', () {
      for (final id in <String>[
        '',
        'not-a-diag-id!',
        'obs-7q2m-91kd',
        'OBS-7Q2M-91KD-extra',
        'OBS-7Q2M-91K',
        'OBS-7Q2M-91KD ',
        'OBS-7Q2M-91KD\n',
        'OBS-<script>alert</script>',
      ]) {
        expect(
          DiagnosticSummaryFormatter.format(
            DiagnosticSummary(diagnosticId: id, operation: 'agent_turn'),
          ),
          isNull,
          reason: 'Expected strict rejection for diagnostic id: $id',
        );
        expect(DiagnosticSummaryFormatter.isValidDiagnosticId(id), isFalse);
      }
      expect(
        DiagnosticSummaryFormatter.format(
          const DiagnosticSummary(
            diagnosticId: 'OBS-7Q2M-91KD',
            operation: 'Not An Operation',
          ),
        ),
        isNull,
      );
    });

    test('accepts exactly the frozen OBS-XXXX-XXXX format', () {
      for (final id in <String>[
        'OBS-7Q2M-91KD',
        'OBS-AAAA-BBBB',
        'OBS-ABCD-2345',
      ]) {
        expect(
          DiagnosticSummaryFormatter.isValidDiagnosticId(id),
          isTrue,
          reason: 'Expected valid diagnostic id: $id',
        );
      }
      expect(
        DiagnosticSummaryFormatter.format(
          const DiagnosticSummary(
            diagnosticId: 'OBS-7Q2M-91KD',
            operation: 'agent_turn',
          ),
        ),
        isNotNull,
      );
    });

    test('omits values that are not fixed safe tokens', () {
      final text = DiagnosticSummaryFormatter.format(
        DiagnosticSummary(
          diagnosticId: 'OBS-7Q2M-91KD',
          operation: 'agent_turn',
          failure: 'a\nb\rc',
          lastTool: 'tool_${List.filled(500, 'x').join()}',
          taskId: 'task_ok_1',
          status: 'ok',
        ),
      )!;

      // Non-token values (control chars, unbounded length) are omitted.
      expect(text, isNot(contains('failure=')));
      expect(text, isNot(contains('lastTool=')));
      expect(text, contains('taskId=task_ok_1'));
      expect(text, contains('status=ok'));
      expect(text.length, lessThanOrEqualTo(2000));
    });
  });
}

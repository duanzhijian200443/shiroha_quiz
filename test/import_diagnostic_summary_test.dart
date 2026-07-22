import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/task_manager.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_diagnostic_formatter.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_diagnostic_summary.dart';

void main() {
  group('ImportDiagnosticSummary & Formatter', () {
    test('1. Processing task with traceId', () {
      final task = ImportTask(
        id: 't1',
        title: 'test',
        status: TaskStatus.processing,
        diagnostics: {
          TaskManager.keyTraceId: 'trace-123',
          TaskManager.keyParseMode: 'ocr',
        },
      );

      final summary = ImportDiagnosticFormatter.summarize(task);
      expect(summary.outcome, ImportTaskOutcome.processing);
      expect(summary.traceId, 'trace-123');
      expect(summary.parseMode, 'ocr');
      expect(summary.technicalFields, isEmpty);
    });

    test('2. Pipeline error retains traceId and parseMode', () {
      final task = ImportTask(
        id: 't2',
        title: 'test',
        status: TaskStatus.error,
        errorMsg: 'Exception: Something went wrong',
        diagnostics: {
          TaskManager.keyTraceId: 'trace-456',
          TaskManager.keyParseMode: 'vision',
        },
      );

      final summary = ImportDiagnosticFormatter.summarize(task);
      expect(summary.outcome, ImportTaskOutcome.failure);
      expect(summary.traceId, 'trace-456');
      expect(summary.parseMode, 'vision');
      expect(summary.errorType, 'Exception');
    });

    test('3. attachDiagnostics merges and does not overwrite metadata', () {
      final tm = TaskManager.instance;
      // Setup task
      tm.tasks.clear();
      final task = ImportTask(
        id: 't3',
        title: 'test',
        diagnostics: {
          TaskManager.keyTraceId: 'trace-789',
          TaskManager.keyParseMode: 'text',
        },
      );
      tm.addTask(task);

      tm.attachDiagnostics('t3',
          diagnostics: {'status': 'success', 'pageCount': 5});

      final updatedTask = tm.tasks.firstWhere((t) => t.id == 't3');
      expect(updatedTask.traceId, 'trace-789');
      expect(updatedTask.parseMode, 'text');
      expect(updatedTask.diagnostics!['status'], 'success');
      expect(updatedTask.diagnostics!['pageCount'], 5);

      // Cleanup
      tm.tasks.clear();
    });

    test('4. Unknown or sensitive fields are not in technicalFields whitelist',
        () {
      final task = ImportTask(
        id: 't4',
        title: 'test',
        status: TaskStatus.completed,
        parsedData: [{}],
        diagnostics: {
          TaskManager.keyTraceId: 'trace-abc',
          'status': 'used_ocr',
          'apiKey': 'sk-1234567890',
          'Authorization': 'Bearer 123',
          'ocrRawText': 'This is full text',
          'nested': {
            'pageCount': 10,
            'secret': 'hidden',
          }
        },
      );

      final summary = ImportDiagnosticFormatter.summarize(task);
      expect(summary.traceId, 'trace-abc');

      // Should contain whitelisted fields
      expect(summary.technicalFields.containsKey('status'), true);
      expect(summary.technicalFields.containsKey('nested.pageCount'), true);

      // Should NOT contain non-whitelisted fields
      expect(summary.technicalFields.containsKey('apiKey'), false);
      expect(summary.technicalFields.containsKey('Authorization'), false);
      expect(summary.technicalFields.containsKey('ocrRawText'), false);
      expect(summary.technicalFields.containsKey('nested.secret'), false);
    });

    test('5. Task without traceId and parseMode does not crash', () {
      final task = ImportTask(
        id: 't5',
        title: 'test',
        status: TaskStatus.error,
        errorMsg: 'failed',
        diagnostics: {'status': 'crash'},
      );

      final summary = ImportDiagnosticFormatter.summarize(task);
      expect(summary.traceId, isNull);
      expect(summary.parseMode, 'text'); // default
      expect(summary.technicalFields.containsKey('status'), true);
    });

    test('6. OCR request success but 0 questions', () {
      final task = ImportTask(
        id: 't6',
        title: 'test',
        status: TaskStatus.completed,
        parsedData: [], // Empty result
        diagnostics: {
          TaskManager.keyParseMode: 'ocr',
          'ocr_import_file_0': {'status': 'used_ocr'}
        },
      );

      final summary = ImportDiagnosticFormatter.summarize(task);
      expect(summary.outcome, ImportTaskOutcome.emptyResult);
      expect(summary.lastSuccessStage, 'OCR 引擎请求');
      expect(summary.failedStage, '提取阶段');
      expect(summary.suggestRetry, true);
    });

    test('7. Vision batch failed', () {
      final task = ImportTask(
        id: 't7',
        title: 'test',
        status: TaskStatus.completed,
        parsedData: [],
        diagnostics: {
          TaskManager.keyParseMode: 'vision',
          'vision_batch_file_0': {'failedBatchCount': 2}
        },
      );

      final summary = ImportDiagnosticFormatter.summarize(task);
      expect(summary.outcome, ImportTaskOutcome.emptyResult);
      expect(summary.lastSuccessStage, 'PDF 渲染 / 文件准备');
      expect(summary.failedStage, '视觉批次解析');
      expect(summary.suggestRetry, true);
    });

    test('8. OCR failed_no_question_regions maps to Regionizer stage', () {
      final task = ImportTask(
        id: 't8',
        title: 'test',
        status: TaskStatus.completed,
        parsedData: [],
        diagnostics: {
          TaskManager.keyParseMode: 'ocr',
          'ocr_import_file_0': {'status': 'failed_no_question_regions'}
        },
      );

      final summary = ImportDiagnosticFormatter.summarize(task);
      expect(summary.outcome, ImportTaskOutcome.emptyResult);
      expect(summary.failedStage, '题目区域识别阶段 / Regionizer');
      expect(summary.suggestRetry, true);
      expect(summary.userGuidance, contains('题目区域'));
    });
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_attempt_context.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_format.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_parse_request.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_parse_result.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_pipeline_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_field_policy.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_import_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_request_scheduler.dart';

void main() {
  late Directory tempDirectory;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp('ocr-budget-test-');
  });

  tearDown(() async {
    await tempDirectory.delete(recursive: true);
  });

  List<String> createFakePdfs(int count) {
    return List<String>.generate(count, (index) {
      final file = File(
        '${tempDirectory.path}${Platform.pathSeparator}doc$index.pdf',
      );
      file.writeAsBytesSync(<int>[0x25, 0x50, 0x44, 0x46]);
      return file.path;
    });
  }

  ImportParseRequest requestFor(List<String> paths, int maxConcurrency) {
    return ImportParseRequest(
      filePaths: paths,
      fileNames:
          paths.map((path) => path.split(Platform.pathSeparator).last).toList(),
      mode: ImportParseMode.ocr,
      maxConcurrency: maxConcurrency,
      taskId: 'ocr-budget-test',
      explanationRetentionMode: ExplanationRetentionMode.allQuestionTypes,
    );
  }

  int fileIndexOf(String filePath) {
    final name = filePath.split(Platform.pathSeparator).last;
    return int.parse(name.substring(3, name.length - 4));
  }

  /// A fake OCR parser that records the in-flight peak and tags every output
  /// with the source file index so order preservation is observable.
  ImportOcrParser recordingOcrParser({
    required void Function(int peak) reportPeak,
    Duration latency = const Duration(milliseconds: 20),
  }) {
    var inFlight = 0;
    var peak = 0;
    return ({
      required filePath,
      required sourceName,
      required ImportFormat format,
      required ExplanationRetentionMode explanationRetentionMode,
    }) async {
      final index = fileIndexOf(filePath);
      inFlight++;
      if (inFlight > peak) {
        peak = inFlight;
        reportPeak(peak);
      }
      await Future<void>.delayed(latency);
      inFlight--;
      return OcrImportResult(
        usedOcr: true,
        questions: <Map<String, dynamic>>[
          <String, dynamic>{
            'content': '${index + 1}. Question from file $index',
            'standard_answer': 'A',
            'type': 3,
          },
        ],
        warnings: <String>['ocr-warning-$index'],
        diagnostics: <String, dynamic>{'fileIndex': index},
      );
    };
  }

  ImportPipelineService buildPipeline(ImportOcrParser ocrParser) {
    return ImportPipelineService.forTesting(
      textParser: (rawText, {required taskId, required isMarkdown}) async {
        fail('textParser must not run in OCR mode');
      },
      visionParser: (imagePaths) async {
        fail('visionParser must not run in OCR mode');
      },
      ocrParser: ocrParser,
    );
  }

  List<String> taggedWarnings(ImportParseResult result) {
    return result.warnings
        .where((warning) => warning.startsWith('ocr-warning-'))
        .toList();
  }

  List<String> ocrDiagnosticKeys(ImportParseResult result) {
    return result.diagnostics.keys
        .where((key) => key.startsWith('ocr_import_file_'))
        .toList();
  }

  test('one task parses its OCR files one after another, never in parallel',
      () async {
    final paths = createFakePdfs(4);
    var peak = 0;
    final pipeline = buildPipeline(
      recordingOcrParser(reportPeak: (value) => peak = value),
    );

    final result = await pipeline.parseFiles(requestFor(paths, 1));

    expect(peak, 1);
    expect(result.questions, hasLength(4));
  });

  test('a recorded budget above one never parallelizes a single task',
      () async {
    final paths = createFakePdfs(4);
    var peak = 0;
    final pipeline = buildPipeline(
      recordingOcrParser(reportPeak: (value) => peak = value),
    );

    // The concurrency budget bounds independent ImportTasks; files of one task
    // stay serial whatever budget the request recorded.
    final result = await pipeline.parseFiles(requestFor(paths, 10));

    expect(peak, 1);
    expect(result.questions, hasLength(4));
  });

  test('the serial output contract holds for every recorded budget', () async {
    final paths = createFakePdfs(4);

    var serialPeak = 0;
    final serial = await buildPipeline(
      recordingOcrParser(reportPeak: (value) => serialPeak = value),
    ).parseFiles(requestFor(paths, 1));

    var budgetedPeak = 0;
    final budgeted = await buildPipeline(
      recordingOcrParser(reportPeak: (value) => budgetedPeak = value),
    ).parseFiles(requestFor(paths, 10));

    expect(serialPeak, 1);
    expect(budgetedPeak, 1);
    expect(
      budgeted.questions.map((question) => question['content']).toList(),
      serial.questions.map((question) => question['content']).toList(),
      reason: 'question order must follow the file order',
    );
    expect(
      taggedWarnings(budgeted),
      taggedWarnings(serial),
      reason: 'warning order must follow the file order',
    );
    expect(
      ocrDiagnosticKeys(budgeted),
      ocrDiagnosticKeys(serial),
      reason: 'diagnostics insertion order must follow the file order',
    );
    expect(
      ocrDiagnosticKeys(budgeted),
      <String>[
        'ocr_import_file_0',
        'ocr_import_file_1',
        'ocr_import_file_2',
        'ocr_import_file_3',
      ],
    );
  });

  test('one task never issues two provider requests for the same attempt',
      () async {
    final paths = createFakePdfs(4);
    // The real scheduler rejects a second concurrent request that reuses one
    // taskId + attemptToken with StateError('Duplicate OCR attempt'), so a
    // parallel file loop inside one task cannot pass unnoticed.
    final scheduler = OcrRequestScheduler(maxConcurrentRequests: 10);
    var inFlight = 0;
    var peakPerAttempt = 0;
    final pipeline = buildPipeline(({
      required filePath,
      required sourceName,
      required ImportFormat format,
      required ExplanationRetentionMode explanationRetentionMode,
    }) async {
      final attempt = ImportAttemptContext.current;
      return scheduler.run(
        taskId: attempt?.taskId ?? 'unscoped-ocr-task',
        attemptToken: attempt?.attemptToken,
        operation: () async {
          inFlight++;
          peakPerAttempt =
              inFlight > peakPerAttempt ? inFlight : peakPerAttempt;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          inFlight--;
          return OcrImportResult(
            usedOcr: true,
            questions: <Map<String, dynamic>>[
              <String, dynamic>{
                'content': '${fileIndexOf(filePath) + 1}. Question',
                'standard_answer': 'A',
                'type': 3,
              },
            ],
            warnings: const <String>[],
            diagnostics: const <String, dynamic>{},
          );
        },
      );
    });

    const attempt = ImportAttemptRef(
      taskId: 'ocr-task-1',
      attemptNumber: 1,
      attemptToken: 'attempt-token-1',
      traceId: 'trace-1',
    );
    final result = await ImportAttemptContext.run(
      attempt: attempt,
      action: () => pipeline.parseFiles(requestFor(paths, 10)),
    );

    expect(peakPerAttempt, 1);
    expect(result.questions, hasLength(4));

    // The finished attempt released its scheduled requests: reusing the same
    // taskId + attemptToken is accepted again instead of leaking the duplicate
    // guard of the finished run.
    expect(
      await scheduler.run(
        taskId: attempt.taskId,
        attemptToken: attempt.attemptToken,
        operation: () async => 'released',
      ),
      'released',
    );
  });

  test('a failing file still propagates its error through the OCR path',
      () async {
    final paths = createFakePdfs(4);
    final pipeline = buildPipeline(({
      required filePath,
      required sourceName,
      required ImportFormat format,
      required ExplanationRetentionMode explanationRetentionMode,
    }) async {
      if (fileIndexOf(filePath) == 1) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        throw StateError('synthetic ocr failure');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return OcrImportResult(
        usedOcr: true,
        questions: <Map<String, dynamic>>[
          <String, dynamic>{
            'content': '1. Question',
            'standard_answer': 'A',
            'type': 3,
          },
        ],
        warnings: const <String>[],
        diagnostics: const <String, dynamic>{},
      );
    });

    await expectLater(
      pipeline.parseFiles(requestFor(paths, 10)),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'synthetic ocr failure',
        ),
      ),
    );
  });
}

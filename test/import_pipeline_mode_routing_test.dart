import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_format.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_parse_request.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_pipeline_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_import_service.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

void main() {
  late Directory tempDirectory;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp('import-mode-test-');
  });

  tearDown(() async {
    await tempDirectory.delete(recursive: true);
  });

  ImportParseRequest requestFor(String path, ImportParseMode mode) {
    return ImportParseRequest(
      filePaths: <String>[path],
      fileNames: <String>[path.split(Platform.pathSeparator).last],
      mode: mode,
      maxConcurrency: 1,
      taskId: 'mode-routing-test',
    );
  }

  List<Map<String, dynamic>> questions(String source) => <Map<String, dynamic>>[
        <String, dynamic>{
          'content': '1. Question parsed by $source',
          'standard_answer': 'A',
          'type': 3,
        },
      ];

  test('text mode calls only text parsing', () async {
    final file = File('${tempDirectory.path}${Platform.pathSeparator}a.txt');
    await file.writeAsString('1. A sufficiently long text question. Answer: A');
    var textCalls = 0;
    var visionCalls = 0;
    var ocrCalls = 0;

    final pipeline = ImportPipelineService.forTesting(
      textParser: (rawText, {required taskId, required isMarkdown}) async {
        textCalls++;
        return questions('text');
      },
      visionParser: (imagePaths) async {
        visionCalls++;
        return questions('vision');
      },
      ocrParser: (
          {required filePath,
          required sourceName,
          required ImportFormat format}) async {
        ocrCalls++;
        return OcrImportResult(
          usedOcr: true,
          questions: questions('ocr'),
          warnings: const <String>[],
          diagnostics: const <String, dynamic>{'status': 'used_ocr'},
        );
      },
    );

    final result = await pipeline.parseFiles(
      requestFor(file.path, ImportParseMode.text),
    );

    expect(result.questions, isNotEmpty);
    expect(textCalls, 1);
    expect(visionCalls, 0);
    expect(ocrCalls, 0);
  });

  test('text mode: non-expected parsers throw to fail immediately if called',
      () async {
    final file = File('${tempDirectory.path}${Platform.pathSeparator}b.txt');
    await file.writeAsString('1. A sufficiently long text question. Answer: A');

    final pipeline = ImportPipelineService.forTesting(
      textParser: (rawText, {required taskId, required isMarkdown}) async =>
          questions('text'),
      visionParser: (imagePaths) async {
        fail('visionParser must not be called in text mode');
      },
      ocrParser: ({
        required filePath,
        required sourceName,
        required ImportFormat format,
      }) async {
        fail('ocrParser must not be called in text mode');
      },
    );

    final result = await pipeline.parseFiles(
      requestFor(file.path, ImportParseMode.text),
    );

    expect(result.questions, isNotEmpty);
  });

  test('text mode reports a scanned PDF without extractable text', () async {
    final file = File('${tempDirectory.path}${Platform.pathSeparator}scan.pdf');
    final document = PdfDocument();
    await file.writeAsBytes(document.saveSync(), flush: true);
    document.dispose();

    final pipeline = ImportPipelineService.forTesting(
      textParser: (rawText, {required taskId, required isMarkdown}) async =>
          questions('text'),
      visionParser: (imagePaths) async => questions('vision'),
      ocrParser: (
              {required filePath,
              required sourceName,
              required ImportFormat format}) async =>
          OcrImportResult(
        usedOcr: true,
        questions: questions('ocr'),
        warnings: const <String>[],
        diagnostics: const <String, dynamic>{'status': 'used_ocr'},
      ),
    );

    final result = await pipeline.parseFiles(
      requestFor(file.path, ImportParseMode.text),
    );

    expect(result.questions, isEmpty);
    expect(
      result.warnings,
      contains('未检测到可提取文字，请改用视觉或 OCR 模式。'),
    );
  });

  test('vision mode calls only Vision parsing', () async {
    var textCalls = 0;
    var visionCalls = 0;
    var ocrCalls = 0;
    final pipeline = ImportPipelineService.forTesting(
      textParser: (rawText, {required taskId, required isMarkdown}) async {
        textCalls++;
        return questions('text');
      },
      visionParser: (imagePaths) async {
        visionCalls++;
        return questions('vision');
      },
      ocrParser: (
          {required filePath,
          required sourceName,
          required ImportFormat format}) async {
        ocrCalls++;
        return OcrImportResult(
          usedOcr: true,
          questions: questions('ocr'),
          warnings: const <String>[],
          diagnostics: const <String, dynamic>{'status': 'used_ocr'},
        );
      },
    );

    final result = await pipeline.parseFiles(
      requestFor('question.png', ImportParseMode.vision),
    );

    expect(result.questions, isNotEmpty);
    expect(textCalls, 0);
    expect(visionCalls, 1);
    expect(ocrCalls, 0);
  });

  test('vision mode: non-expected parsers throw to fail immediately if called',
      () async {
    final pipeline = ImportPipelineService.forTesting(
      textParser: (rawText, {required taskId, required isMarkdown}) async {
        fail('textParser must not be called in vision mode');
      },
      visionParser: (imagePaths) async => questions('vision'),
      ocrParser: ({
        required filePath,
        required sourceName,
        required ImportFormat format,
      }) async {
        fail('ocrParser must not be called in vision mode');
      },
    );

    final result = await pipeline.parseFiles(
      requestFor('question.png', ImportParseMode.vision),
    );

    expect(result.questions, isNotEmpty);
  });

  test('ocr mode calls only OCR parsing', () async {
    var textCalls = 0;
    var visionCalls = 0;
    var ocrCalls = 0;
    final pipeline = ImportPipelineService.forTesting(
      textParser: (rawText, {required taskId, required isMarkdown}) async {
        textCalls++;
        return questions('text');
      },
      visionParser: (imagePaths) async {
        visionCalls++;
        return questions('vision');
      },
      ocrParser: (
          {required filePath,
          required sourceName,
          required ImportFormat format}) async {
        ocrCalls++;
        return OcrImportResult(
          usedOcr: true,
          questions: questions('ocr'),
          warnings: const <String>[],
          diagnostics: const <String, dynamic>{'status': 'used_ocr'},
        );
      },
    );

    final result = await pipeline.parseFiles(
      requestFor('question.png', ImportParseMode.ocr),
    );

    expect(result.questions, isNotEmpty);
    expect(textCalls, 0);
    expect(visionCalls, 0);
    expect(ocrCalls, 1);
  });

  test('ocr mode: non-expected parsers throw to fail immediately if called',
      () async {
    final pipeline = ImportPipelineService.forTesting(
      textParser: (rawText, {required taskId, required isMarkdown}) async {
        fail('textParser must not be called in ocr mode');
      },
      visionParser: (imagePaths) async {
        fail('visionParser must not be called in ocr mode');
      },
      ocrParser: ({
        required filePath,
        required sourceName,
        required ImportFormat format,
      }) async =>
          OcrImportResult(
        usedOcr: true,
        questions: questions('ocr'),
        warnings: const <String>[],
        diagnostics: const <String, dynamic>{'status': 'used_ocr'},
      ),
    );

    final result = await pipeline.parseFiles(
      requestFor('question.png', ImportParseMode.ocr),
    );

    expect(result.questions, isNotEmpty);
  });

  test('OCR failure does not fall back to Vision', () async {
    var visionCalls = 0;
    final pipeline = ImportPipelineService.forTesting(
      textParser: (rawText, {required taskId, required isMarkdown}) async =>
          questions('text'),
      visionParser: (imagePaths) async {
        visionCalls++;
        return questions('vision');
      },
      ocrParser: (
              {required filePath,
              required sourceName,
              required ImportFormat format}) async =>
          const OcrImportResult(
        usedOcr: false,
        questions: <Map<String, dynamic>>[],
        warnings: <String>['OCR 请求失败，请检查 OCR 配置或网络后重试。'],
        diagnostics: <String, dynamic>{'status': 'failed_request'},
      ),
    );

    final result = await pipeline.parseFiles(
      requestFor('question.png', ImportParseMode.ocr),
    );

    expect(result.questions, isEmpty);
    expect(result.warnings, contains('OCR 请求失败，请检查 OCR 配置或网络后重试。'));
    expect(visionCalls, 0);
  });

  test('request mode is a snapshot of UI state at task creation', () async {
    final file = File('${tempDirectory.path}${Platform.pathSeparator}a.txt');
    await file.writeAsString('1. A sufficiently long text question. Answer: A');
    var selectedMode = ImportParseMode.text;
    final request = requestFor(file.path, selectedMode);
    selectedMode = ImportParseMode.vision;
    var textCalls = 0;
    var visionCalls = 0;

    final pipeline = ImportPipelineService.forTesting(
      textParser: (rawText, {required taskId, required isMarkdown}) async {
        textCalls++;
        return questions('text');
      },
      visionParser: (imagePaths) async {
        visionCalls++;
        return questions('vision');
      },
      ocrParser: (
              {required filePath,
              required sourceName,
              required ImportFormat format}) async =>
          null,
    );

    await pipeline.parseFiles(request);

    expect(selectedMode, ImportParseMode.vision);
    expect(request.mode, ImportParseMode.text);
    expect(textCalls, 1);
    expect(visionCalls, 0);
  });
}

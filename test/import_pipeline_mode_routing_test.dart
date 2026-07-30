import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_format.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_parse_request.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_pipeline_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_field_policy.dart';
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

  ImportParseRequest requestFor(
    String path,
    ImportParseMode mode, {
    ExplanationRetentionMode explanationRetentionMode =
        ExplanationRetentionMode.subjectiveOnly,
  }) {
    return ImportParseRequest(
      filePaths: <String>[path],
      fileNames: <String>[path.split(Platform.pathSeparator).last],
      mode: mode,
      maxConcurrency: 1,
      taskId: 'mode-routing-test',
      explanationRetentionMode: explanationRetentionMode,
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
          required ImportFormat format,
          required ExplanationRetentionMode explanationRetentionMode}) async {
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
        required ExplanationRetentionMode explanationRetentionMode,
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
              required ImportFormat format,
              required ExplanationRetentionMode
                  explanationRetentionMode}) async =>
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
          required ImportFormat format,
          required ExplanationRetentionMode explanationRetentionMode}) async {
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

  test('vision mode audits LaTeX after final question processing', () async {
    final pipeline = ImportPipelineService.forTesting(
      textParser: (rawText, {required taskId, required isMarkdown}) async =>
          questions('text'),
      visionParser: (imagePaths) async => <Map<String, dynamic>>[
        <String, dynamic>{
          'content': 'Synthetic vision question',
          'standard_answer': 'A',
          'explanation': r'Explanation \(\begin{matrix}1 & 2\end{pmatrix}\)',
          'type': 3,
        },
      ],
      ocrParser: ({
        required filePath,
        required sourceName,
        required ImportFormat format,
        required ExplanationRetentionMode explanationRetentionMode,
      }) async =>
          null,
    );

    final result = await pipeline.parseFiles(
      requestFor('question.png', ImportParseMode.vision),
    );

    final metadata =
        result.questions.single['_import_review'] as Map<String, dynamic>;
    expect(metadata['riskHints'], contains('latex_unrenderable'));
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
        required ExplanationRetentionMode explanationRetentionMode,
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
          required ImportFormat format,
          required ExplanationRetentionMode explanationRetentionMode}) async {
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
        required ExplanationRetentionMode explanationRetentionMode,
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
              required ImportFormat format,
              required ExplanationRetentionMode
                  explanationRetentionMode}) async =>
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
              required ImportFormat format,
              required ExplanationRetentionMode
                  explanationRetentionMode}) async =>
          null,
    );

    await pipeline.parseFiles(request);

    expect(selectedMode, ImportParseMode.vision);
    expect(request.mode, ImportParseMode.text);
    expect(textCalls, 1);
    expect(visionCalls, 0);
  });

  List<Map<String, dynamic>> retentionQuestions() => <Map<String, dynamic>>[
        <String, dynamic>{
          'q_num': 1,
          'content': 'Synthetic choice question',
          'options': <String>['A', 'B'],
          'standard_answer': 'A',
          'explanation': 'Choice explanation',
          'type': 0,
        },
        <String, dynamic>{
          'q_num': 2,
          'content': 'Synthetic fill question',
          'options': const <String>[],
          'standard_answer': '42',
          'explanation': 'Fill explanation',
          'type': 2,
        },
        <String, dynamic>{
          'q_num': 3,
          'content': 'Synthetic short answer question',
          'options': const <String>[],
          'standard_answer': 'Conclusion',
          'explanation': 'Short answer explanation',
          'type': 3,
        },
      ];

  test('subjective-only finalization removes only objective explanations',
      () async {
    final file =
        File('${tempDirectory.path}${Platform.pathSeparator}retention.txt');
    await file.writeAsString(
      'Synthetic source text long enough to enter the text parser.',
    );
    final pipeline = ImportPipelineService.forTesting(
      textParser: (rawText, {required taskId, required isMarkdown}) async =>
          retentionQuestions(),
      visionParser: (imagePaths) async => fail('vision parser must not run'),
      ocrParser: ({
        required filePath,
        required sourceName,
        required ImportFormat format,
        required ExplanationRetentionMode explanationRetentionMode,
      }) async =>
          fail('OCR parser must not run'),
    );

    final result = await pipeline.parseFiles(
      requestFor(file.path, ImportParseMode.text),
    );

    expect(
      result.explanationRetentionMode,
      ExplanationRetentionMode.subjectiveOnly,
    );
    expect(result.questions.map((question) => question['explanation']), [
      '',
      '',
      'Short answer explanation',
    ]);
    expect(result.questions.map((question) => question['q_num']), [1, 2, 3]);
    expect(result.questions.first['options'], <String>['A', 'B']);
    expect(result.questions.first['standard_answer'], 'A');
  });

  for (final mode in ImportParseMode.values) {
    test('${mode.name} route retains objective explanations when requested',
        () async {
      final textFile = File(
          '${tempDirectory.path}${Platform.pathSeparator}${mode.name}.txt');
      await textFile.writeAsString(
        'Synthetic source text long enough to enter the text parser.',
      );
      ExplanationRetentionMode? observedOcrRetentionMode;
      final pipeline = ImportPipelineService.forTesting(
        textParser: (rawText, {required taskId, required isMarkdown}) async =>
            retentionQuestions(),
        visionParser: (imagePaths) async => retentionQuestions(),
        ocrParser: ({
          required filePath,
          required sourceName,
          required ImportFormat format,
          required ExplanationRetentionMode explanationRetentionMode,
        }) async {
          observedOcrRetentionMode = explanationRetentionMode;
          return OcrImportResult(
            usedOcr: true,
            questions: retentionQuestions(),
            warnings: const <String>[],
            diagnostics: const <String, dynamic>{'status': 'used_ocr'},
          );
        },
      );
      final path =
          mode == ImportParseMode.text ? textFile.path : 'question.png';

      final result = await pipeline.parseFiles(
        requestFor(
          path,
          mode,
          explanationRetentionMode: ExplanationRetentionMode.allQuestionTypes,
        ),
      );

      expect(
        result.explanationRetentionMode,
        ExplanationRetentionMode.allQuestionTypes,
      );
      expect(result.questions.map((question) => question['explanation']), [
        'Choice explanation',
        'Fill explanation',
        'Short answer explanation',
      ]);
      if (mode == ImportParseMode.ocr) {
        expect(
          observedOcrRetentionMode,
          ExplanationRetentionMode.allQuestionTypes,
        );
      }
    });
  }

  test('multi-file finalization uses the request retention mode once',
      () async {
    final first =
        File('${tempDirectory.path}${Platform.pathSeparator}first.txt');
    final second =
        File('${tempDirectory.path}${Platform.pathSeparator}second.txt');
    await first.writeAsString('Synthetic source text for the first question.');
    await second
        .writeAsString('Synthetic source text for the second question.');
    var parseCall = 0;
    final pipeline = ImportPipelineService.forTesting(
      textParser: (rawText, {required taskId, required isMarkdown}) async {
        parseCall++;
        return <Map<String, dynamic>>[
          <String, dynamic>{
            'q_num': parseCall,
            'content': 'Synthetic question $parseCall',
            'options': <String>['A', 'B'],
            'standard_answer': 'A',
            'explanation': 'Explanation $parseCall',
            'type': 0,
          },
        ];
      },
      visionParser: (imagePaths) async => fail('vision parser must not run'),
      ocrParser: ({
        required filePath,
        required sourceName,
        required ImportFormat format,
        required ExplanationRetentionMode explanationRetentionMode,
      }) async =>
          fail('OCR parser must not run'),
    );

    final result = await pipeline.parseFiles(
      ImportParseRequest(
        filePaths: <String>[first.path, second.path],
        fileNames: const <String>['first.txt', 'second.txt'],
        mode: ImportParseMode.text,
        maxConcurrency: 1,
        taskId: 'multi-file-retention',
        explanationRetentionMode: ExplanationRetentionMode.allQuestionTypes,
      ),
    );

    expect(result.questions, hasLength(2));
    expect(result.questions.map((question) => question['q_num']), [1, 2]);
    expect(
      result.questions.map((question) => question['explanation']),
      ['Explanation 1', 'Explanation 2'],
    );
  });

  test('independent single-file requests never call the question merger',
      () async {
    final files = <File>[];
    for (var index = 0; index < 4; index++) {
      final file = File(
        '${tempDirectory.path}${Platform.pathSeparator}independent-$index.txt',
      );
      await file.writeAsString('Synthetic source text ${index + 1}.');
      files.add(file);
    }
    var parseCalls = 0;
    var mergerCalls = 0;
    final pipeline = ImportPipelineService.forTesting(
      textParser: (rawText, {required taskId, required isMarkdown}) async {
        parseCalls++;
        return questions('text-$taskId');
      },
      visionParser: (imagePaths) async => fail('vision parser must not run'),
      ocrParser: ({
        required filePath,
        required sourceName,
        required ImportFormat format,
        required ExplanationRetentionMode explanationRetentionMode,
      }) async =>
          fail('OCR parser must not run'),
      questionMerger: (fileResults) async {
        mergerCalls++;
        return fileResults.expand((questions) => questions).toList();
      },
    );

    for (var index = 0; index < files.length; index++) {
      final result = await pipeline.parseFiles(
        ImportParseRequest(
          filePaths: <String>[files[index].path],
          fileNames: <String>['independent-$index.txt'],
          mode: ImportParseMode.text,
          maxConcurrency: 1,
          taskId: 'independent-$index',
        ),
      );
      expect(result.questions, hasLength(1));
    }

    expect(parseCalls, 4);
    expect(mergerCalls, 0);
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/services/import_pipeline/latex_sanity_checker.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document.dart';

import '../tool/import_acceptance.dart';
import '../tool/import_acceptance_report.dart';

void main() {
  group('OcrDocument Replay Serialization Tests', () {
    test('round-trip preserves all necessary downstream fields', () {
      const original = OcrDocument(
        sourceName: '2022_math1.pdf',
        markdown: '# Math Exam\n1. Question text',
        usage: {'total_tokens': 150},
        rawResponses: [
          {'raw': 'secret_provider_response'}
        ],
        pages: [
          OcrPage(
            pageIndex: 1,
            width: 1000,
            height: 1400,
            blocks: [
              OcrBlock(
                blockId: 'p001_b0001',
                pageIndex: 1,
                type: 'text',
                text: '1. 第一题题目内容',
                bbox: [0.1, 0.1, 0.9, 0.2],
                readingOrder: 0,
                confidence: 0.98,
                raw: {'secret_block_data': 123},
              ),
              OcrBlock(
                blockId: 'p001_b0002',
                pageIndex: 1,
                type: 'formula',
                text: r'\(x^2 + y^2 = 1\)',
                bbox: [0.1, 0.3, 0.9, 0.4],
                readingOrder: 1,
              ),
            ],
          ),
        ],
      );

      final json = original.toReplayJson();
      expect(json['schemaVersion'], 1);
      expect(json['sourceName'], '2022_math1.pdf');
      expect(json['markdown'], '# Math Exam\n1. Question text');
      expect(json['usage'], {'total_tokens': 150});
      expect(json.containsKey('rawResponses'), isFalse);

      final restored = OcrDocument.fromReplayJson(json);
      expect(restored.sourceName, '2022_math1.pdf');
      expect(restored.markdown, '# Math Exam\n1. Question text');
      expect(restored.usage, {'total_tokens': 150});
      expect(restored.rawResponses, isEmpty);
      expect(restored.pages.length, 1);

      final page = restored.pages.first;
      expect(page.pageIndex, 1);
      expect(page.width, 1000);
      expect(page.height, 1400);
      expect(page.blocks.length, 2);

      final b1 = page.blocks[0];
      expect(b1.blockId, 'p001_b0001');
      expect(b1.pageIndex, 1);
      expect(b1.type, 'text');
      expect(b1.text, '1. 第一题题目内容');
      expect(b1.readingOrder, 0);
      expect(b1.bbox, isEmpty);
      expect(b1.confidence, isNull);
      expect(b1.raw, isEmpty);

      final b2 = page.blocks[1];
      expect(b2.blockId, 'p001_b0002');
      expect(b2.type, 'formula');
      expect(b2.text, r'\(x^2 + y^2 = 1\)');
    });

    test('fromReplayJson throws FormatException on invalid schemaVersion', () {
      expect(
        () => OcrDocument.fromReplayJson({'schemaVersion': 99}),
        throwsFormatException,
      );
      expect(
        () => OcrDocument.fromReplayJson({}),
        throwsFormatException,
      );
    });
  });

  group('LatexSanityChecker Tests', () {
    const checker = LatexSanityChecker();

    test('balanced LaTeX delimiters return false', () {
      expect(checker.hasDanglingDelimiters(r'\(a + b = c\)'), isFalse);
      expect(checker.hasDanglingDelimiters(r'\[\int_0^1 f(x)dx\]'), isFalse);
      expect(
        checker.hasDanglingDelimiters(r'\left( \frac{a}{b} \right)'),
        isFalse,
      );
    });

    test('unbalanced inline delimiters return true', () {
      expect(checker.hasDanglingDelimiters(r'\(a + b = c'), isTrue);
      expect(checker.hasDanglingDelimiters(r'a + b = c\)'), isTrue);
    });

    test('unbalanced block delimiters return true', () {
      expect(checker.hasDanglingDelimiters(r'\[\int_0^1 f(x)dx'), isTrue);
    });

    test('unbalanced left/right return true', () {
      expect(checker.hasDanglingDelimiters(r'\left( \frac{a}{b}'), isTrue);
    });
  });

  group('Acceptance Quality Checker Tests', () {
    const testCase = ImportAcceptanceCase(
      schemaVersion: 1,
      caseId: '2022_math1',
      pdf: 'math/single/2022数学一解析.pdf',
      expectedQuestionCount: 3,
      expectedNumbers: [1, 2, 3],
      allowDuplicateNumbers: false,
    );

    test('all clean questions pass structure and quality', () {
      final questions = [
        {
          'question_number': 1,
          'type': 0, // Choice
          'content': '1. 下列选项正确的是',
          'options': ['A. 选项1', 'B. 选项2'],
          'standard_answer': 'A',
          'explanation': '解析说明',
        },
        {
          'question_number': 2,
          'type': 2, // Fill-blank
          'content': '2. 极限等于 ___',
          'options': <String>[],
          'standard_answer': '1',
          'explanation': '解析说明',
        },
        {
          'question_number': 3,
          'type': 3, // Subjective
          'content': '3. 求积分',
          'options': <String>[],
          'standard_answer': '积分结果为 1',
          'explanation': '详细证明过程',
        },
      ];

      final quality = runAcceptanceQualityChecks(
        questions: questions,
        testCase: testCase,
      );

      expect(quality.structureVerdict, 'pass');
      expect(quality.missingNumbers, isEmpty);
      expect(quality.duplicateNumbers, isEmpty);
      final verdict = computeVerdict(
        quality: quality,
        repairCandidateCount: 0,
        repairMode: 'skipped',
      );
      expect(verdict.verdict, 'PASS');
      expect(verdict.exitCode, 0);
    });

    test('missing expected question results in FAIL', () {
      final questions = [
        {
          'question_number': 1,
          'type': 0,
          'content': '题1',
          'options': ['A. 1', 'B. 2'],
          'standard_answer': 'A',
        },
        {
          'question_number': 2,
          'type': 0,
          'content': '题2',
          'options': ['A. 1', 'B. 2'],
          'standard_answer': 'B',
        },
        // Q3 missing
      ];

      final quality = runAcceptanceQualityChecks(
        questions: questions,
        testCase: testCase,
      );

      expect(quality.structureVerdict, 'fail');
      expect(quality.missingNumbers, [3]);
      final verdict = computeVerdict(
        quality: quality,
        repairCandidateCount: 0,
        repairMode: 'skipped',
      );
      expect(verdict.verdict, 'FAIL');
      expect(verdict.exitCode, 1);
    });

    test('duplicate question number results in FAIL', () {
      final questions = [
        {
          'question_number': 1,
          'type': 0,
          'content': '题1',
          'options': ['A. 1', 'B. 2'],
          'standard_answer': 'A',
        },
        {
          'question_number': 2,
          'type': 0,
          'content': '题2a',
          'options': ['A. 1', 'B. 2'],
          'standard_answer': 'A',
        },
        {
          'question_number': 2, // Duplicate
          'type': 0,
          'content': '题2b',
          'options': ['A. 1', 'B. 2'],
          'standard_answer': 'B',
        },
      ];

      final quality = runAcceptanceQualityChecks(
        questions: questions,
        testCase: testCase,
      );

      expect(quality.structureVerdict, 'fail');
      expect(quality.duplicateNumbers, [2]);
      final verdict = computeVerdict(
        quality: quality,
        repairCandidateCount: 0,
        repairMode: 'skipped',
      );
      expect(verdict.verdict, 'FAIL');
      expect(verdict.exitCode, 1);
    });

    test('subjective question missing answer but has explanation triggers REVIEW', () {
      final questions = [
        {
          'question_number': 1,
          'type': 0,
          'content': '题1',
          'options': ['A. 1', 'B. 2'],
          'standard_answer': 'A',
        },
        {
          'question_number': 2,
          'type': 2,
          'content': '题2',
          'options': <String>[],
          'standard_answer': '1',
        },
        {
          'question_number': 3,
          'type': 3, // Subjective
          'content': '3. 求解微分方程',
          'options': <String>[],
          'standard_answer': '', // Missing explicit answer!
          'explanation': '【解析】由已知条件可知...',
        },
      ];

      final quality = runAcceptanceQualityChecks(
        questions: questions,
        testCase: testCase,
      );

      expect(quality.structureVerdict, 'pass');
      final q3Report =
          quality.questionReports.firstWhere((r) => r.questionNumber == 3);
      expect(
        q3Report.issues.any((i) => i.code == 'missing_explicit_answer'),
        isTrue,
      );
      expect(q3Report.hasReviewIssue, isTrue);

      final verdict = computeVerdict(
        quality: quality,
        repairCandidateCount: 0,
        repairMode: 'skipped',
      );
      expect(verdict.verdict, 'REVIEW');
      expect(verdict.exitCode, 2);
    });

    test('subjective question missing both answer and explanation triggers FAIL', () {
      final questions = [
        {
          'question_number': 1,
          'type': 0,
          'content': '题1',
          'options': ['A. 1', 'B. 2'],
          'standard_answer': 'A',
        },
        {
          'question_number': 2,
          'type': 2,
          'content': '题2',
          'options': <String>[],
          'standard_answer': '1',
        },
        {
          'question_number': 3,
          'type': 3,
          'content': '3. 题3干',
          'options': <String>[],
          'standard_answer': '',
          'explanation': '',
        },
      ];

      final quality = runAcceptanceQualityChecks(
        questions: questions,
        testCase: testCase,
      );

      final q3Report =
          quality.questionReports.firstWhere((r) => r.questionNumber == 3);
      expect(
        q3Report.issues
            .any((i) => i.code == 'missing_answer_and_explanation'),
        isTrue,
      );
      expect(q3Report.hasHardIssue, isTrue);

      final verdict = computeVerdict(
        quality: quality,
        repairCandidateCount: 0,
        repairMode: 'skipped',
      );
      expect(verdict.verdict, 'FAIL');
      expect(verdict.exitCode, 1);
    });

    test('unbalanced LaTeX triggers REVIEW', () {
      final questions = [
        {
          'question_number': 1,
          'type': 0,
          'content': r'1. 设 \(f(x) = x^2', // Unbalanced \(
          'options': ['A. 1', 'B. 2'],
          'standard_answer': 'A',
        },
        {
          'question_number': 2,
          'type': 2,
          'content': '题2',
          'options': <String>[],
          'standard_answer': '1',
        },
        {
          'question_number': 3,
          'type': 3,
          'content': '题3',
          'options': <String>[],
          'standard_answer': '3',
        },
      ];

      final quality = runAcceptanceQualityChecks(
        questions: questions,
        testCase: testCase,
      );

      final q1Report =
          quality.questionReports.firstWhere((r) => r.questionNumber == 1);
      expect(
        q1Report.issues.any((i) => i.code == 'latex_unrenderable'),
        isTrue,
      );
      expect(q1Report.latexValidationMode, 'limited');

      final verdict = computeVerdict(
        quality: quality,
        repairCandidateCount: 0,
        repairMode: 'skipped',
      );
      expect(verdict.verdict, 'REVIEW');
      expect(verdict.exitCode, 2);
    });

    test('HTML residue triggers REVIEW', () {
      final questions = [
        {
          'question_number': 1,
          'type': 0,
          'content': '1. 题1 <div align="center">居中内容</div>',
          'options': ['A. 1', 'B. 2'],
          'standard_answer': 'A',
        },
        {
          'question_number': 2,
          'type': 2,
          'content': '题2',
          'options': <String>[],
          'standard_answer': '1',
        },
        {
          'question_number': 3,
          'type': 3,
          'content': '题3',
          'options': <String>[],
          'standard_answer': '3',
        },
      ];

      final quality = runAcceptanceQualityChecks(
        questions: questions,
        testCase: testCase,
      );

      final q1Report =
          quality.questionReports.firstWhere((r) => r.questionNumber == 1);
      expect(
        q1Report.issues.any((i) => i.code == 'raw_html_tag'),
        isTrue,
      );

      final verdict = computeVerdict(
        quality: quality,
        repairCandidateCount: 0,
        repairMode: 'skipped',
      );
      expect(verdict.verdict, 'REVIEW');
      expect(verdict.exitCode, 2);
    });

    test('repair candidates > 0 with repairMode=skipped triggers REVIEW', () {
      final questions = [
        {
          'question_number': 1,
          'type': 0,
          'content': '题1',
          'options': ['A. 1', 'B. 2'],
          'standard_answer': 'A',
        },
        {
          'question_number': 2,
          'type': 2,
          'content': '题2',
          'options': <String>[],
          'standard_answer': '1',
        },
        {
          'question_number': 3,
          'type': 3,
          'content': '题3',
          'options': <String>[],
          'standard_answer': '3',
        },
      ];

      final quality = runAcceptanceQualityChecks(
        questions: questions,
        testCase: testCase,
      );

      // Even if quality checks pass completely, skipping repair when candidateCount > 0 must give REVIEW
      final verdict = computeVerdict(
        quality: quality,
        repairCandidateCount: 2,
        repairMode: 'skipped',
      );
      expect(verdict.verdict, 'REVIEW');
      expect(verdict.exitCode, 2);
    });
  });

  group('Replay Cache Runner Integration Tests', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('import_acceptance_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('missing cache returns replay_cache_missing and exit code 1 without network call', () async {
      // Create a dummy case file in tempDir
      final casesDir = Directory(p.join(tempDir.path, 'tool', 'import_cases'))
        ..createSync(recursive: true);
      File(p.join(casesDir.path, 'test_missing.json')).writeAsStringSync(jsonEncode({
        'schemaVersion': 1,
        'caseId': 'test_missing',
        'pdf': 'math/single/test.pdf',
        'expectedQuestionCount': 1,
        'expectedNumbers': [1],
        'allowDuplicateNumbers': false,
      }));

      final events = <Map<String, dynamic>>[];
      final exitCode = await runImportAcceptance(
        caseId: 'test_missing',
        repositoryRoot: tempDir.path,
        emitEvent: events.add,
        refreshOcr: false,
      );

      expect(exitCode, 1);
      expect(
        events.any((e) => e['status'] == 'replay_cache_missing'),
        isTrue,
      );
    });

    test('offline replay with valid cache runs production pipeline with 0 provider calls', () async {
      // Create case file
      final casesDir = Directory(p.join(tempDir.path, 'tool', 'import_cases'))
        ..createSync(recursive: true);
      File(p.join(casesDir.path, 'test_valid.json')).writeAsStringSync(jsonEncode({
        'schemaVersion': 1,
        'caseId': 'test_valid',
        'pdf': 'math/single/test.pdf',
        'expectedQuestionCount': 1,
        'expectedNumbers': [1],
        'allowDuplicateNumbers': false,
      }));

      // Create valid OcrDocument
      const doc = OcrDocument(
        sourceName: 'test.pdf',
        markdown: '1. 第一题题目内容\n答案：A',
        usage: {},
        rawResponses: [],
        pages: [
          OcrPage(
            pageIndex: 1,
            blocks: [
              OcrBlock(
                blockId: 'p001_b0001',
                pageIndex: 1,
                type: 'text',
                text: '1. 设 f(x) 为连续函数，则（ ）\n(A) 选项1\n(B) 选项2',
                bbox: [],
                readingOrder: 0,
              ),
              OcrBlock(
                blockId: 'p001_b0002',
                pageIndex: 1,
                type: 'text',
                text: '答案：A',
                bbox: [],
                readingOrder: 1,
              ),
              OcrBlock(
                blockId: 'p001_b0003',
                pageIndex: 1,
                type: 'text',
                text: '解析：由题意可知...',
                bbox: [],
                readingOrder: 2,
              ),
            ],
          ),
        ],
      );

      final fingerprint = computeReplayCacheFingerprint(
        pdfBytes: utf8.encode(jsonEncode(doc.toReplayJson())),
        documentSchemaVersion: 1,
        ocrModelId: 'glm-ocr',
      );

      // Write cache using helper
      writeReplayCache(
        caseId: 'test_valid',
        repositoryRoot: tempDir.path,
        document: doc,
        fingerprint: fingerprint,
        pdfContentHash: 'fakehash',
      );

      final events = <Map<String, dynamic>>[];
      final exitCode = await runImportAcceptance(
        caseId: 'test_valid',
        repositoryRoot: tempDir.path,
        emitEvent: events.add,
        refreshOcr: false,
      );

      expect(exitCode, 0);
      final completedEvt = events.firstWhere((e) => e['stage'] == 'completed');
      expect(completedEvt['verdict'], 'PASS');

      final pipelineEvt = events.firstWhere((e) => e['stage'] == 'pipeline' && e['status'] == 'completed');
      expect(pipelineEvt['providerCallCount'], 0);
      expect(pipelineEvt['repairMode'], 'skipped');
    });

    test('report writer produces expected json files and agent_brief.md without leaking secrets', () async {
      final writer = AcceptanceReportWriter(
        repositoryRoot: tempDir.path,
        runId: 'test-run-001',
      );

      final summary = {
        'caseId': '2022_math1',
        'sourceMode': 'replay',
        'fingerprint': 'abc12345',
        'verdict': 'REVIEW',
        'expectedQuestionCount': 22,
        'actualQuestionCount': 22,
        'repairMode': 'skipped',
        'repairCandidateCount': 0,
        'hardFailureCount': 0,
        'reviewIssueCount': 1,
        'durationMs': 120,
      };

      final reports = [
        AcceptanceQuestionReport(
          questionNumber: 18,
          questionType: 3,
          hasContent: true,
          optionCount: 0,
          hasStandardAnswer: false,
          hasExplanation: true,
          issues: [
            const AcceptanceQuestionIssue(
              code: 'missing_explicit_answer',
              severity: 'review',
            ),
          ],
          latexValidationMode: 'limited',
        ),
      ];

      final runDir = await writer.write(
        summary: summary,
        questionReports: reports,
        candidateTrace: const [],
        verdict: const AcceptanceVerdict(verdict: 'REVIEW', exitCode: 2),
      );

      expect(File(p.join(runDir, 'summary.json')).existsSync(), isTrue);
      expect(File(p.join(runDir, 'question_quality.json')).existsSync(), isTrue);
      expect(File(p.join(runDir, 'candidate_trace.json')).existsSync(), isTrue);
      expect(File(p.join(runDir, 'agent_brief.md')).existsSync(), isTrue);

      final briefText = File(p.join(runDir, 'agent_brief.md')).readAsStringSync();
      expect(briefText, contains('Verdict: **REVIEW**'));
      expect(briefText, contains('- Q18: missing_explicit_answer'));
      // Verify no question content leaked
      expect(briefText, isNot(contains('题目内容')));
      expect(briefText, isNot(contains('fixture-api-key')));
    });
  });

  group('CLI Startup Contract Tests', () {
    test('runImportAcceptance handles missing case gracefully without throwing', () async {
      final events = <Map<String, dynamic>>[];
      final exitCode = await runImportAcceptance(
        caseId: 'non_existent_test_case',
        repositoryRoot: Directory.current.path,
        emitEvent: (e) => events.add(e),
      );
      expect(exitCode, equals(1));
      expect(events.any((e) => e['status'] == 'case_not_found'), isTrue);
    });
  });
}

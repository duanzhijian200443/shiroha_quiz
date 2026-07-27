import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/services/import_pipeline/final_question_latex_audit.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_field_policy.dart';
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

    test(
        'subjective question missing answer but has explanation triggers REVIEW',
        () {
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

    test(
        'subjective question missing both answer and explanation triggers FAIL',
        () {
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
        q3Report.issues.any((i) => i.code == 'missing_answer_and_explanation'),
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

    test(
        'missing cache returns replay_cache_missing and exit code 1 without network call',
        () async {
      // Create a dummy case file in tempDir
      final casesDir = Directory(p.join(tempDir.path, 'tool', 'import_cases'))
        ..createSync(recursive: true);
      File(p.join(casesDir.path, 'test_missing.json'))
          .writeAsStringSync(jsonEncode({
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
      );

      expect(exitCode, 1);
      expect(
        events.any((e) => e['status'] == 'replay_cache_missing'),
        isTrue,
      );
    });

    test(
        'offline replay with valid cache runs production pipeline with 0 provider calls',
        () async {
      // Create case file
      final casesDir = Directory(p.join(tempDir.path, 'tool', 'import_cases'))
        ..createSync(recursive: true);
      File(p.join(casesDir.path, 'test_valid.json'))
          .writeAsStringSync(jsonEncode({
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
        pdfContentHash:
            '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      );

      final events = <Map<String, dynamic>>[];
      final exitCode = await runImportAcceptance(
        caseId: 'test_valid',
        repositoryRoot: tempDir.path,
        emitEvent: events.add,
      );

      expect(exitCode, 0);
      final completedEvt = events.firstWhere((e) => e['stage'] == 'completed');
      expect(completedEvt['verdict'], 'PASS');

      final pipelineEvt = events.firstWhere(
          (e) => e['stage'] == 'pipeline' && e['status'] == 'completed');
      expect(pipelineEvt['providerCallCount'], 0);
      expect(pipelineEvt['answerDistillationCandidates'], 0);
      expect(pipelineEvt['repairMode'], 'skipped');
    });

    group('Replay Cache Loader & Writer Strong Contract Tests (Phase 2)', () {
      late Directory tempRepo;

      setUp(() {
        tempRepo = Directory.systemTemp.createTempSync('replay-contract-test-');
      });

      tearDown(() {
        if (tempRepo.existsSync()) {
          tempRepo.deleteSync(recursive: true);
        }
      });

      const sampleDoc = OcrDocument(
        sourceName: 'test.pdf',
        markdown: '1. 测试题目',
        usage: {},
        rawResponses: [],
        pages: [
          OcrPage(
            pageIndex: 1,
            blocks: [
              OcrBlock(
                blockId: 'b1',
                pageIndex: 1,
                type: 'text',
                text: '1. 设 f(x) 为连续函数',
                bbox: [],
                readingOrder: 0,
              ),
            ],
          ),
        ],
      );
      const changedDoc = OcrDocument(
        sourceName: 'test.pdf',
        markdown: '1. changed fixture',
        usage: {},
        rawResponses: [],
        pages: [
          OcrPage(
            pageIndex: 1,
            blocks: [
              OcrBlock(
                blockId: 'b2',
                pageIndex: 1,
                type: 'text',
                text: '1. changed fixture',
                bbox: [],
                readingOrder: 0,
              ),
            ],
          ),
        ],
      );

      const validPdfHash =
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
      const fpOld = 'ffffffffffffffff';
      const fpNew = '1111111111111111';
      const fpThird = '2222222222222222';

      test(
          'lexicographical regression: current.json selection overrides directory alphabetical sort',
          () {
        // Create old cache with fingerprint 'ffffffffffffffff' (alphabetically larger)
        writeReplayCache(
          caseId: 'lex_test',
          repositoryRoot: tempRepo.path,
          document: sampleDoc,
          fingerprint: fpOld,
          pdfContentHash: validPdfHash,
        );

        // Create new cache with fingerprint '1111111111111111' (alphabetically smaller)
        writeReplayCache(
          caseId: 'lex_test',
          repositoryRoot: tempRepo.path,
          document: sampleDoc,
          fingerprint: fpNew,
          pdfContentHash: validPdfHash,
        );

        // current.json now points to fpNew (1111111111111111)
        final loaded = loadReplayCache(
          caseId: 'lex_test',
          repositoryRoot: tempRepo.path,
        );

        expect(loaded.isLoaded, isTrue);
        expect(loaded.fingerprint, fpNew);
        expect(loaded.fingerprint, isNot(fpOld));
      });

      test('missing cache: missing case directory or missing current.json', () {
        // 1. case directory does not exist
        final res1 = loadReplayCache(
          caseId: 'non_existent_case',
          repositoryRoot: tempRepo.path,
        );
        expect(res1.isMissing, isTrue);

        // 2. case directory exists, but current.json missing
        Directory(p.join(
                tempRepo.path, 'scratch', 'ocr_replay', 'missing_current'))
            .createSync(recursive: true);
        final res2 = loadReplayCache(
          caseId: 'missing_current',
          repositoryRoot: tempRepo.path,
        );
        expect(res2.isMissing, isTrue);
      });

      test(
          'corrupted current.json returns replay_cache_invalid without fallback',
          () {
        writeReplayCache(
          caseId: 'bad_current_case',
          repositoryRoot: tempRepo.path,
          document: sampleDoc,
          fingerprint: fpOld,
          pdfContentHash: validPdfHash,
        );

        final currentFile = File(p.join(tempRepo.path, 'scratch', 'ocr_replay',
            'bad_current_case', 'current.json'));

        // Corrupt current.json
        currentFile.writeAsStringSync('{ invalid json }');

        final res = loadReplayCache(
          caseId: 'bad_current_case',
          repositoryRoot: tempRepo.path,
        );

        expect(res.isInvalid, isTrue);
        expect(res.causeType, 'CurrentPointerFormatException');
      });

      test(
          'current.json with path traversal or invalid fingerprint returns invalid',
          () {
        final caseDir = Directory(
            p.join(tempRepo.path, 'scratch', 'ocr_replay', 'traversal_case'))
          ..createSync(recursive: true);

        File(p.join(caseDir.path, 'current.json'))
            .writeAsStringSync(jsonEncode({
          'schemaVersion': 1,
          'caseId': 'traversal_case',
          'fingerprint': '../outside_dir',
          'updatedAtUtc': DateTime.now().toUtc().toIso8601String(),
        }));

        final res = loadReplayCache(
          caseId: 'traversal_case',
          repositoryRoot: tempRepo.path,
        );

        expect(res.isInvalid, isTrue);
        expect(res.causeType, 'CurrentPointerFormatException');
      });

      test(
          'manifest.json corruption or model mismatch returns replay_cache_invalid',
          () {
        writeReplayCache(
          caseId: 'manifest_test',
          repositoryRoot: tempRepo.path,
          document: sampleDoc,
          fingerprint: fpNew,
          pdfContentHash: validPdfHash,
        );

        final manifestFile = File(p.join(
          _currentReplayVersionPath(tempRepo.path, 'manifest_test'),
          'manifest.json',
        ));

        final manifestData =
            jsonDecode(manifestFile.readAsStringSync()) as Map<String, dynamic>;
        manifestData['ocrModelId'] = 'incompatible-model-id';
        manifestFile.writeAsStringSync(jsonEncode(manifestData));

        final res = loadReplayCache(
          caseId: 'manifest_test',
          repositoryRoot: tempRepo.path,
        );

        expect(res.isInvalid, isTrue);
        expect(res.causeType, 'ReplayModelMismatch');
      });

      test(
          'documentHash mismatch returns replay_cache_invalid (ReplayDocumentHashMismatch)',
          () {
        writeReplayCache(
          caseId: 'hash_mismatch_case',
          repositoryRoot: tempRepo.path,
          document: sampleDoc,
          fingerprint: fpNew,
          pdfContentHash: validPdfHash,
        );

        final docFile = File(p.join(
          _currentReplayVersionPath(tempRepo.path, 'hash_mismatch_case'),
          'ocr_document.private.json',
        ));

        // Tamper with document file content
        docFile.writeAsStringSync('{"tampered": true}');

        final res = loadReplayCache(
          caseId: 'hash_mismatch_case',
          repositoryRoot: tempRepo.path,
        );

        expect(res.isInvalid, isTrue);
        expect(res.causeType, 'ReplayDocumentHashMismatch');
      });

      test(
          'forbidden fallback: invalid current pointer does not fallback to valid old cache',
          () {
        // Create valid cache under fpOld
        writeReplayCache(
          caseId: 'fallback_test',
          repositoryRoot: tempRepo.path,
          document: sampleDoc,
          fingerprint: fpOld,
          pdfContentHash: validPdfHash,
        );

        // Manually write current.json pointing to corrupt/non-existent target fpNew
        final currentFile = File(p.join(tempRepo.path, 'scratch', 'ocr_replay',
            'fallback_test', 'current.json'));
        currentFile.writeAsStringSync(jsonEncode({
          'schemaVersion': 1,
          'caseId': 'fallback_test',
          'fingerprint': fpNew,
          'updatedAtUtc': DateTime.now().toUtc().toIso8601String(),
        }));

        final res = loadReplayCache(
          caseId: 'fallback_test',
          repositoryRoot: tempRepo.path,
        );

        expect(res.isInvalid, isTrue);
        expect(res.causeType, 'ReplayTargetMissing');
        // Proves it NEVER fell back to fpOld!
      });

      test('same fingerprint and document reuse the fully validated version',
          () {
        final res1 = writeReplayCache(
          caseId: 'reuse_test',
          repositoryRoot: tempRepo.path,
          document: sampleDoc,
          fingerprint: fpNew,
          pdfContentHash: validPdfHash,
        );

        expect(res1.reusedExistingDirectory, isFalse);

        final res2 = writeReplayCache(
          caseId: 'reuse_test',
          repositoryRoot: tempRepo.path,
          document: sampleDoc,
          fingerprint: fpNew,
          pdfContentHash: validPdfHash,
        );

        expect(res2.reusedExistingDirectory, isTrue);
      });

      test('same document with corrupted manifest is not reused', () {
        writeReplayCache(
          caseId: 'repair_test',
          repositoryRoot: tempRepo.path,
          document: sampleDoc,
          fingerprint: fpNew,
          pdfContentHash: validPdfHash,
        );
        final oldVersion =
            _currentReplayVersionPath(tempRepo.path, 'repair_test');
        File(p.join(oldVersion, 'manifest.json')).writeAsStringSync('corrupt');

        final res = writeReplayCache(
          caseId: 'repair_test',
          repositoryRoot: tempRepo.path,
          document: sampleDoc,
          fingerprint: fpNew,
          pdfContentHash: validPdfHash,
        );

        expect(res.reusedExistingDirectory, isFalse);
        expect(
          _currentReplayVersionPath(tempRepo.path, 'repair_test'),
          isNot(oldVersion),
        );

        final loaderRes = loadReplayCache(
          caseId: 'repair_test',
          repositoryRoot: tempRepo.path,
        );
        expect(loaderRes.isLoaded, isTrue);
      });

      test('atomic staging cleanup: write leaves no .staging-* directories',
          () {
        writeReplayCache(
          caseId: 'staging_clean_test',
          repositoryRoot: tempRepo.path,
          document: sampleDoc,
          fingerprint: fpNew,
          pdfContentHash: validPdfHash,
        );

        final caseDir = Directory(p.join(
            tempRepo.path, 'scratch', 'ocr_replay', 'staging_clean_test'));
        final stagings = caseDir
            .listSync()
            .whereType<Directory>()
            .where((d) => p.basename(d.path).startsWith('.staging'));

        expect(stagings, isEmpty);
      });

      test(
          'same fingerprint with different document hashes keeps old and new versions',
          () {
        writeReplayCache(
          caseId: 'versioned_replace',
          repositoryRoot: tempRepo.path,
          document: sampleDoc,
          fingerprint: fpNew,
          pdfContentHash: validPdfHash,
        );
        final oldVersion =
            _currentReplayVersionPath(tempRepo.path, 'versioned_replace');

        writeReplayCache(
          caseId: 'versioned_replace',
          repositoryRoot: tempRepo.path,
          document: changedDoc,
          fingerprint: fpNew,
          pdfContentHash: validPdfHash,
        );
        final newVersion =
            _currentReplayVersionPath(tempRepo.path, 'versioned_replace');
        final versions = Directory(p.join(tempRepo.path, 'scratch',
                'ocr_replay', 'versioned_replace', 'versions'))
            .listSync()
            .whereType<Directory>()
            .where((entry) => !p.basename(entry.path).startsWith('.staging-'))
            .map((entry) => entry.path)
            .toSet();

        expect(newVersion, isNot(oldVersion));
        expect(versions, containsAll(<String>[oldVersion, newVersion]));
        expect(
          loadReplayCache(
            caseId: 'versioned_replace',
            repositoryRoot: tempRepo.path,
          ).documentHash,
          isNotNull,
        );
      });

      for (final failure in <(String, ReplayCacheWriteHooks)>[
        (
          'staging write',
          ReplayCacheWriteHooks(
            beforeStagingWrite: () => throw FileSystemException('fixture'),
          ),
        ),
        (
          'staging to target',
          ReplayCacheWriteHooks(
            beforeTargetRename: () => throw FileSystemException('fixture'),
          ),
        ),
        (
          'current update',
          ReplayCacheWriteHooks(
            beforeCurrentReplace: () => throw FileSystemException('fixture'),
          ),
        ),
        (
          'post-write load verification',
          ReplayCacheWriteHooks(
            beforePostWriteVerification: () =>
                throw FileSystemException('fixture'),
          ),
        ),
      ]) {
        test('${failure.$1} failure preserves the old current cache', () {
          final caseId = 'failure_${failure.$1.replaceAll(' ', '_')}';
          writeReplayCache(
            caseId: caseId,
            repositoryRoot: tempRepo.path,
            document: sampleDoc,
            fingerprint: fpOld,
            pdfContentHash: validPdfHash,
          );
          final old = loadReplayCache(
            caseId: caseId,
            repositoryRoot: tempRepo.path,
          );

          expect(
            () => writeReplayCache(
              caseId: caseId,
              repositoryRoot: tempRepo.path,
              document: changedDoc,
              fingerprint: fpNew,
              pdfContentHash: validPdfHash,
              hooks: failure.$2,
            ),
            throwsA(anything),
          );

          final loaded = loadReplayCache(
            caseId: caseId,
            repositoryRoot: tempRepo.path,
          );
          expect(loaded.isLoaded, isTrue);
          expect(loaded.fingerprint, fpOld);
          expect(loaded.documentHash, old.documentHash);
          expect(loaded.cacheDirectory, old.cacheDirectory);
        });
      }

      test(
          'reader observes complete old then complete new cache during publish',
          () {
        const caseId = 'reader_writer_atomicity';
        writeReplayCache(
          caseId: caseId,
          repositoryRoot: tempRepo.path,
          document: sampleDoc,
          fingerprint: fpOld,
          pdfContentHash: validPdfHash,
        );
        ReplayCacheResult? beforeCurrent;
        ReplayCacheResult? afterCurrent;

        writeReplayCache(
          caseId: caseId,
          repositoryRoot: tempRepo.path,
          document: changedDoc,
          fingerprint: fpNew,
          pdfContentHash: validPdfHash,
          hooks: ReplayCacheWriteHooks(
            afterTargetPublished: () {
              beforeCurrent = loadReplayCache(
                caseId: caseId,
                repositoryRoot: tempRepo.path,
              );
            },
            afterCurrentPublished: () {
              afterCurrent = loadReplayCache(
                caseId: caseId,
                repositoryRoot: tempRepo.path,
              );
            },
          ),
        );

        expect(beforeCurrent?.isLoaded, isTrue);
        expect(beforeCurrent?.fingerprint, fpOld);
        expect(afterCurrent?.isLoaded, isTrue);
        expect(afterCurrent?.fingerprint, fpNew);
      });

      test('paused reader completes version A after writers publish B and C',
          () {
        const caseId = 'slow_reader_three_versions';
        writeReplayCache(
          caseId: caseId,
          repositoryRoot: tempRepo.path,
          document: sampleDoc,
          fingerprint: fpOld,
          pdfContentHash: validPdfHash,
        );
        final versionA = _currentReplayVersionPath(tempRepo.path, caseId);
        String? versionB;
        String? versionC;
        var resumed = false;

        final slowReader = loadReplayCache(
          caseId: caseId,
          repositoryRoot: tempRepo.path,
          hooks: ReplayCacheLoadHooks(
            afterCurrentResolved: (targetPath) {
              expect(targetPath, versionA);
              writeReplayCache(
                caseId: caseId,
                repositoryRoot: tempRepo.path,
                document: changedDoc,
                fingerprint: fpNew,
                pdfContentHash: validPdfHash,
              );
              versionB = _currentReplayVersionPath(tempRepo.path, caseId);
              writeReplayCache(
                caseId: caseId,
                repositoryRoot: tempRepo.path,
                document: sampleDoc,
                fingerprint: fpThird,
                pdfContentHash: validPdfHash,
              );
              versionC = _currentReplayVersionPath(tempRepo.path, caseId);
              resumed = true;
            },
          ),
        );
        final newReader = loadReplayCache(
          caseId: caseId,
          repositoryRoot: tempRepo.path,
        );

        expect(resumed, isTrue);
        expect(slowReader.isLoaded, isTrue);
        expect(slowReader.fingerprint, fpOld);
        expect(slowReader.causeType, isNot('ReplayTargetMissing'));
        expect(newReader.isLoaded, isTrue);
        expect(newReader.fingerprint, fpThird);
        expect(
          <String>[versionA, versionB!, versionC!]
              .every((path) => Directory(path).existsSync()),
          isTrue,
        );
      });

      test('lock failure closes its handle and preserves the old cache', () {
        const caseId = 'lock_failure_cleanup';
        writeReplayCache(
          caseId: caseId,
          repositoryRoot: tempRepo.path,
          document: sampleDoc,
          fingerprint: fpOld,
          pdfContentHash: validPdfHash,
        );
        final old = loadReplayCache(
          caseId: caseId,
          repositoryRoot: tempRepo.path,
        );
        final lockProbe = Directory(p.join(tempRepo.path, 'lock-probe'))
          ..createSync();
        final throwingLock = _ThrowingReplayCacheWriteLock(
          p.join(lockProbe.path, 'writer.lock'),
        );

        expect(
          () => writeReplayCache(
            caseId: caseId,
            repositoryRoot: tempRepo.path,
            document: changedDoc,
            fingerprint: fpNew,
            pdfContentHash: validPdfHash,
            lockFactory: (_) => throwingLock,
          ),
          throwsA(isA<FileSystemException>()),
        );

        expect(throwingLock.closed, isTrue);
        expect(throwingLock.unlockCalls, 0);
        expect(() => lockProbe.deleteSync(recursive: true), returnsNormally);
        final loaded = loadReplayCache(
          caseId: caseId,
          repositoryRoot: tempRepo.path,
        );
        expect(loaded.isLoaded, isTrue);
        expect(loaded.fingerprint, fpOld);
        expect(loaded.documentHash, old.documentHash);
        expect(loaded.cacheDirectory, old.cacheDirectory);
      });

      test('two concurrent writers leave one complete current version',
          () async {
        const caseId = 'concurrent_writers';
        await Future.wait([
          Isolate.run(() {
            writeReplayCache(
              caseId: caseId,
              repositoryRoot: tempRepo.path,
              document: sampleDoc,
              fingerprint: fpOld,
              pdfContentHash: validPdfHash,
            );
          }),
          Isolate.run(() {
            writeReplayCache(
              caseId: caseId,
              repositoryRoot: tempRepo.path,
              document: changedDoc,
              fingerprint: fpNew,
              pdfContentHash: validPdfHash,
            );
          }),
        ]);

        final loaded = loadReplayCache(
          caseId: caseId,
          repositoryRoot: tempRepo.path,
        );
        expect(loaded.isLoaded, isTrue);
        expect(loaded.fingerprint, anyOf(fpOld, fpNew));
        expect(
          jsonDecode(File(p.join(tempRepo.path, 'scratch', 'ocr_replay', caseId,
                  'current.json'))
              .readAsStringSync()),
          isA<Map<String, dynamic>>(),
        );
      });

      test(
          'security: manifest and current.json do not contain sensitive tokens',
          () {
        final sensitiveDoc = OcrDocument(
          sourceName: 'private.pdf',
          markdown: 'sensitive',
          usage: const {
            'Authorization': 'Bearer fixture-api-key-sensitive',
            'secretPath': r'C:\Users\private\exam.pdf',
          },
          rawResponses: const [
            {'rawSecret': 'OCR-SENSITIVE-CONTENT'}
          ],
          pages: const [
            OcrPage(
              pageIndex: 1,
              blocks: [
                OcrBlock(
                  blockId: 'b1',
                  pageIndex: 1,
                  type: 'text',
                  text: '1. 问题说明',
                  bbox: [],
                  readingOrder: 0,
                ),
              ],
            ),
          ],
        );

        writeReplayCache(
          caseId: 'security_test',
          repositoryRoot: tempRepo.path,
          document: sensitiveDoc,
          fingerprint: fpNew,
          pdfContentHash: validPdfHash,
        );

        final currentText = File(p.join(tempRepo.path, 'scratch', 'ocr_replay',
                'security_test', 'current.json'))
            .readAsStringSync();
        final manifestText = File(p.join(
                _currentReplayVersionPath(tempRepo.path, 'security_test'),
                'manifest.json'))
            .readAsStringSync();

        expect(currentText, isNot(contains('fixture-api-key-sensitive')));
        expect(currentText, isNot(contains(r'C:\Users\private')));
        expect(currentText, isNot(contains('OCR-SENSITIVE-CONTENT')));

        expect(manifestText, isNot(contains('fixture-api-key-sensitive')));
        expect(manifestText, isNot(contains(r'C:\Users\private')));
        expect(manifestText, isNot(contains('OCR-SENSITIVE-CONTENT')));
      });

      test('runImportAcceptance emits replay_cache_invalid on corrupted cache',
          () async {
        final casesDir =
            Directory(p.join(tempRepo.path, 'tool', 'import_cases'))
              ..createSync(recursive: true);
        File(p.join(casesDir.path, 'test_invalid.json'))
            .writeAsStringSync(jsonEncode({
          'schemaVersion': 1,
          'caseId': 'test_invalid',
          'pdf': 'math/single/test.pdf',
          'expectedQuestionCount': 1,
          'expectedNumbers': [1],
          'allowDuplicateNumbers': false,
        }));

        writeReplayCache(
          caseId: 'test_invalid',
          repositoryRoot: tempRepo.path,
          document: sampleDoc,
          fingerprint: fpNew,
          pdfContentHash: validPdfHash,
        );

        // Corrupt current.json pointer
        File(p.join(tempRepo.path, 'scratch', 'ocr_replay', 'test_invalid',
                'current.json'))
            .writeAsStringSync('{ invalid json }');

        final events = <Map<String, dynamic>>[];
        final exitCode = await runImportAcceptance(
          caseId: 'test_invalid',
          repositoryRoot: tempRepo.path,
          emitEvent: events.add,
        );

        expect(exitCode, 1);
        final invalidEvt =
            events.firstWhere((e) => e['status'] == 'replay_cache_invalid');
        expect(invalidEvt['caseId'], 'test_invalid');
        expect(invalidEvt['causeType'], 'CurrentPointerFormatException');
      });
    });

    test(
        'report writer produces expected json files and agent_brief.md without leaking secrets',
        () async {
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
      expect(
          File(p.join(runDir, 'question_quality.json')).existsSync(), isTrue);
      expect(File(p.join(runDir, 'candidate_trace.json')).existsSync(), isTrue);
      expect(File(p.join(runDir, 'agent_brief.md')).existsSync(), isTrue);

      final briefText =
          File(p.join(runDir, 'agent_brief.md')).readAsStringSync();
      expect(briefText, contains('Verdict: **REVIEW**'));
      expect(briefText, contains('- Q18: missing_explicit_answer'));
      // Verify no question content leaked
      expect(briefText, isNot(contains('题目内容')));
      expect(briefText, isNot(contains('fixture-api-key')));
    });
  });

  group('CLI Startup Contract Tests', () {
    test('strict parser accepts only documented argument forms', () {
      final parsed = parseImportAcceptanceCliArguments([
        '--case=case_01',
        r'--repository-root=C:\synthetic',
      ]);

      expect(parsed.caseId, 'case_01');
      expect(parsed.repositoryRoot, r'C:\synthetic');
      expect(parsed.showHelp, isFalse);
    });

    test('strict parser rejects unknown, positional, duplicate, and empty args',
        () {
      final invalidArgs = <List<String>>[
        ['--unknown'],
        ['positional'],
        ['--case=one', '--case=two'],
        ['--case='],
        ['--repository-root='],
        ['--help', '--case=one'],
      ];

      for (final args in invalidArgs) {
        expect(
          () => parseImportAcceptanceCliArguments(args),
          throwsA(isA<ImportAcceptanceCliArgumentException>()),
          reason: 'args=$args',
        );
      }
    });

    test('case id validator rejects traversal and separators', () {
      expect(isValidAcceptanceCaseId('case_01-A'), isTrue);
      expect(isValidAcceptanceCaseId('../bad'), isFalse);
      expect(isValidAcceptanceCaseId(r'..\bad'), isFalse);
      expect(isValidAcceptanceCaseId('2022/math1'), isFalse);
      expect(isValidAcceptanceCaseId(''), isFalse);
    });

    test('runImportAcceptance handles missing case gracefully without throwing',
        () async {
      final events = <Map<String, dynamic>>[];
      final exitCode = await runImportAcceptance(
        caseId: 'non_existent_test_case',
        repositoryRoot: Directory.current.path,
        emitEvent: (e) => events.add(e),
      );
      expect(exitCode, equals(1));
      expect(events.any((e) => e['status'] == 'case_not_found'), isTrue);
    });

    test(
        'runImportAcceptance accepts explicit repositoryRoot without depending on Directory.current',
        () async {
      final syntheticDir =
          Directory.systemTemp.createTempSync('synthetic_repo_root_test');
      try {
        File(p.join(syntheticDir.path, 'pubspec.yaml'))
            .writeAsStringSync('name: test_repo\n');
        final casesDir =
            Directory(p.join(syntheticDir.path, 'tool', 'import_cases'))
              ..createSync(recursive: true);
        final caseFile = File(p.join(casesDir.path, 'synthetic_case.json'));
        caseFile.writeAsStringSync(jsonEncode({
          'schemaVersion': 1,
          'caseId': 'synthetic_case',
          'pdf': 'fake.pdf',
          'expectedQuestionCount': 1,
          'expectedNumbers': [1],
          'allowDuplicateNumbers': false,
        }));

        final events = <Map<String, dynamic>>[];
        final exitCode = await runImportAcceptance(
          caseId: 'synthetic_case',
          repositoryRoot: syntheticDir.path,
          emitEvent: (e) => events.add(e),
        );
        // Will fail at replay_cache_missing, proving case file was found via explicit repositoryRoot!
        expect(
            events.any((e) => e['status'] == 'replay_cache_missing'), isTrue);
        expect(exitCode, equals(1));
      } finally {
        syntheticDir.deleteSync(recursive: true);
      }
    });

    test(
        'CLI subprocess rejects traversal before file access and redacts absolute paths',
        () async {
      final syntheticDir =
          Directory.systemTemp.createTempSync('acceptance_cli_traversal_');
      addTearDown(() {
        if (syntheticDir.existsSync()) {
          syntheticDir.deleteSync(recursive: true);
        }
      });
      final outsideFixture = File(p.join(syntheticDir.path, 'tool', 'bad.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync('OUTSIDE_CASE_FIXTURE_MARKER_31E2');

      final result = await _runImportAcceptanceCli(
        ['--case=../bad', '--repository-root=${syntheticDir.path}'],
      );

      expect(result.exitCode, 2);
      expect(result.stdout, contains('"status":"invalid_case_id"'));
      expect(result.stdout, isNot(contains(syntheticDir.path)));
      expect(
          result.stdout, isNot(contains('OUTSIDE_CASE_FIXTURE_MARKER_31E2')));
      expect(result.stderr, isEmpty);
      expect(outsideFixture.existsSync(), isTrue);
    });

    test('CLI subprocess rejects unknown and refresh arguments safely',
        () async {
      for (final arg in ['--unknown', '--refresh-ocr']) {
        final result = await _runImportAcceptanceCli([arg]);

        expect(result.exitCode, 2, reason: arg);
        expect(result.stdout, contains('"status":"invalid_arguments"'),
            reason: arg);
        expect(result.stdout, isNot(contains('live_ocr_started')), reason: arg);
        expect(result.stderr, isEmpty, reason: arg);
      }
    });

    test('CLI help documents replay-only arguments', () async {
      final result = await _runImportAcceptanceCli(['--help']);

      expect(result.exitCode, 0);
      expect(result.stdout, contains('--case=<caseId>'));
      expect(result.stdout, contains('--repository-root=<path>'));
      expect(result.stdout, isNot(contains('--refresh-ocr')));
      expect(result.stderr, isEmpty);
    });
  });

  group('Phase 3 Static Dependency Boundary Tests', () {
    test('tool/import_acceptance.dart does not import zhipu_ocr_client.dart',
        () {
      final file = File('tool/import_acceptance.dart');
      final content = file.readAsStringSync();
      expect(content.contains('zhipu_ocr_client.dart'), isFalse);
      expect(content.contains('syncfusion_flutter_pdf'), isFalse);
    });

    test('ocr_import_service.dart does not import zhipu_ocr_client.dart', () {
      final file = File('lib/services/import_pipeline/ocr_import_service.dart');
      final content = file.readAsStringSync();
      expect(content.contains('zhipu_ocr_client.dart'), isFalse);
    });

    test(
        'ocr_document_client.dart is pure Dart without Flutter or PDF dependencies',
        () {
      final file =
          File('lib/services/import_pipeline/ocr_document_client.dart');
      final content = file.readAsStringSync();
      expect(content.contains('package:flutter'), isFalse);
      expect(content.contains('dart:ui'), isFalse);
      expect(content.contains('syncfusion_flutter_pdf'), isFalse);
      expect(content.contains('zhipu_ocr_client.dart'), isFalse);
    });

    test('offline acceptance does not initialize DatabaseHelper', () {
      final content = File('tool/import_acceptance.dart').readAsStringSync();

      expect(content, isNot(contains('database_helper.dart')));
      expect(content, isNot(contains('DatabaseHelper')));
      expect(content, isNot(contains('sqflite')));
      expect(content, isNot(contains('AiEngineRepository.instance')));
    });

    test(
        '_NoOpRepairService.repair override signature matches SingleQuestionRepairService.repair',
        () {
      final acceptanceContent =
          File('tool/import_acceptance.dart').readAsStringSync();
      final serviceContent = File(
              'lib/services/import_pipeline/single_question_repair_service.dart')
          .readAsStringSync();

      // Extracts the repair parameter block from SingleQuestionRepairService
      final serviceMatch =
          RegExp(r'Future<LocalAssemblyResult>\s+repair\s*\(([^)]+)\)')
              .firstMatch(serviceContent);
      expect(serviceMatch, isNotNull,
          reason: 'SingleQuestionRepairService must define a repair method');

      final serviceParams = serviceMatch!.group(1)!;

      // Extract each parameter name from SingleQuestionRepairService.repair
      final paramNames = RegExp(r'(\w+)\s*[,=)]')
          .allMatches(serviceParams)
          .map((m) => m.group(1)!)
          .where((name) =>
              name != 'required' &&
              name != 'bool' &&
              name != 'true' &&
              name != 'false')
          .toList();

      // Ensure _NoOpRepairService in tool/import_acceptance.dart contains all parameter names
      for (final param in paramNames) {
        expect(
          acceptanceContent,
          contains(param),
          reason:
              '_NoOpRepairService.repair must include parameter "$param" from SingleQuestionRepairService.repair',
        );
      }
    });
  });

  group('Phase 3B.1 Final LaTeX Audit Integration Tests', () {
    test(
        'acceptance pipeline calls finalizeAndAuditImportQuestions (static import check)',
        () {
      final content = File('tool/import_acceptance.dart').readAsStringSync();
      expect(
        content,
        contains('finalizeAndAuditImportQuestions'),
        reason:
            'tool/import_acceptance.dart must call finalizeAndAuditImportQuestions to match production pipeline',
      );
      expect(
        content,
        contains('final_question_latex_audit.dart'),
        reason:
            'tool/import_acceptance.dart must import final_question_latex_audit.dart',
      );
    });

    test(
        'deterministically repairable LaTeX does not produce latex_unrenderable',
        () {
      // A trailing unclosed \( is deterministically repairable
      final questions = <Map<String, dynamic>>[
        {
          'question_number': 1,
          'type': 0,
          'content': r'Find \(x + 1',
          'options': ['A. 1', 'B. 2', 'C. 3', 'D. 4'],
          'standard_answer': 'A',
          'explanation': '',
        },
      ];

      final audited = finalizeAndAuditImportQuestions(questions);
      final quality = runAcceptanceQualityChecks(
        questions: audited,
        testCase: const ImportAcceptanceCase(
          schemaVersion: 1,
          caseId: 'synthetic_repairable',
          pdf: 'synthetic.pdf',
          expectedQuestionCount: 1,
          expectedNumbers: [1],
          allowDuplicateNumbers: false,
        ),
      );

      expect(quality.questionReports.length, 1);
      final issues = quality.questionReports.first.issues;
      expect(
        issues.map((i) => i.code),
        isNot(contains('latex_unrenderable')),
        reason:
            'Deterministically repairable LaTeX must not produce latex_unrenderable after audit',
      );
    });

    test('safe bare array is normalized before acceptance quality checks', () {
      final audited = finalizeAndAuditImportQuestions([
        {
          'question_number': 1,
          'type': 3,
          'content': 'Question',
          'options': <String>[],
          'standard_answer': 'Answer',
          'explanation': r'Before \{\begin{array}{l}x=1\\y=2\end{array} after',
        },
      ]);
      final quality = runAcceptanceQualityChecks(
        questions: audited,
        testCase: const ImportAcceptanceCase(
          schemaVersion: 1,
          caseId: 'synthetic_bare_array',
          pdf: 'synthetic.pdf',
          expectedQuestionCount: 1,
          expectedNumbers: [1],
          allowDuplicateNumbers: false,
        ),
      );

      expect(
        quality.questionReports.single.issues.map((issue) => issue.code),
        isNot(contains('latex_unrenderable')),
      );
      expect(audited.single['explanation'], contains(r'\[\{\begin{array}'));
    });

    test('unrepairable LaTeX still produces latex_unrenderable', () {
      // Mismatched environment: \begin{matrix}...\end{pmatrix} is not repairable
      final questions = <Map<String, dynamic>>[
        {
          'question_number': 1,
          'type': 0,
          'content': r'Compute \(\begin{matrix}1\end{pmatrix}\)',
          'options': ['A. 1', 'B. 2', 'C. 3', 'D. 4'],
          'standard_answer': 'A',
          'explanation': '',
        },
      ];

      final audited = finalizeAndAuditImportQuestions(questions);
      final quality = runAcceptanceQualityChecks(
        questions: audited,
        testCase: const ImportAcceptanceCase(
          schemaVersion: 1,
          caseId: 'synthetic_unrepairable',
          pdf: 'synthetic.pdf',
          expectedQuestionCount: 1,
          expectedNumbers: [1],
          allowDuplicateNumbers: false,
        ),
      );

      expect(quality.questionReports.length, 1);
      final issues = quality.questionReports.first.issues;
      expect(
        issues.map((i) => i.code),
        contains('latex_unrenderable'),
        reason: 'Unrepairable LaTeX must still produce latex_unrenderable',
      );
    });

    test('acceptance applies final field policy before LaTeX audit', () {
      final questions = <Map<String, dynamic>>[
        {
          'question_number': 1,
          'type': 2,
          'content': r'Solve \(x^2 + 1',
          'options': <String>[],
          'standard_answer': '2',
          'explanation': r'Because \[a + b',
        },
        {
          'question_number': 2,
          'type': 0,
          'content': r'Normal \(x\) question',
          'options': ['A', 'B', 'C', 'D'],
          'standard_answer': 'A',
          'explanation': '',
        },
      ];

      // Acceptance and production share this finalization function.
      final audited = finalizeAndAuditImportQuestions(questions);

      // Persisted content is repaired, while type=2 explanation is discarded
      // before audit because it is not a final saved/displayed field.
      expect(audited[0]['content'], r'Solve \(x^2 + 1\)');
      expect(audited[0]['explanation'], isEmpty);
      // Normal question unchanged
      expect(audited[1]['content'], r'Normal \(x\) question');
    });

    test('raw objective explanation is excluded unless retention is enabled',
        () {
      final questions = <Map<String, dynamic>>[
        {
          'question_number': 1,
          'type': 0,
          'content': 'Valid question',
          'options': ['A', 'B'],
          'standard_answer': 'A',
          'explanation': '',
          'raw_explanation':
              r'Broken \(\begin{matrix}1\end{pmatrix}\) <table>x</table>',
        },
      ];
      const testCase = ImportAcceptanceCase(
        schemaVersion: 1,
        caseId: 'retention_contract',
        pdf: 'synthetic.pdf',
        expectedQuestionCount: 1,
        expectedNumbers: [1],
        allowDuplicateNumbers: false,
      );

      final defaultQuestions = finalizeAndAuditImportQuestions(questions);
      final defaultQuality = runAcceptanceQualityChecks(
        questions: defaultQuestions,
        testCase: testCase,
      );
      expect(defaultQuestions.single['explanation'], isEmpty);
      expect(defaultQuality.questionReports.single.hasExplanation, isFalse);
      expect(defaultQuality.questionReports.single.issues, isEmpty);

      final enabledQuestions = finalizeAndAuditImportQuestions(
        questions,
        mode: ExplanationRetentionMode.allQuestionTypes,
      );
      final enabledQuality = runAcceptanceQualityChecks(
        questions: enabledQuestions,
        testCase: testCase,
      );
      expect(enabledQuestions.single['explanation'], isNotEmpty);
      expect(
        enabledQuality.questionReports.single.issues.map((issue) => issue.code),
        containsAll(['latex_unrenderable', 'raw_html_tag']),
      );
    });

    test('audited questions are used for issue and repair candidate statistics',
        () {
      // Build a question with repairable trailing \( that after audit is clean
      final questions = <Map<String, dynamic>>[
        {
          'question_number': 1,
          'type': 0,
          'content': r'Compute \(x + 1',
          'options': ['A. 1', 'B. 2', 'C. 3', 'D. 4'],
          'standard_answer': 'A',
          'explanation': '',
        },
        {
          'question_number': 2,
          'type': 0,
          'content': r'Compute \(\begin{matrix}1\end{pmatrix}\)',
          'options': ['A. 1', 'B. 2', 'C. 3', 'D. 4'],
          'standard_answer': 'A',
          'explanation': '',
        },
      ];

      // Without audit: both would have dangling delimiters
      final preAuditQuality = runAcceptanceQualityChecks(
        questions: questions,
        testCase: const ImportAcceptanceCase(
          schemaVersion: 1,
          caseId: 'pre_audit',
          pdf: 'synthetic.pdf',
          expectedQuestionCount: 2,
          expectedNumbers: [1, 2],
          allowDuplicateNumbers: false,
        ),
      );
      final preAuditLatex = preAuditQuality.questionReports
          .where((r) => r.issues.any((i) => i.code == 'latex_unrenderable'))
          .length;

      // With audit: repairable one is fixed
      final audited = finalizeAndAuditImportQuestions(questions);
      final postAuditQuality = runAcceptanceQualityChecks(
        questions: audited,
        testCase: const ImportAcceptanceCase(
          schemaVersion: 1,
          caseId: 'post_audit',
          pdf: 'synthetic.pdf',
          expectedQuestionCount: 2,
          expectedNumbers: [1, 2],
          allowDuplicateNumbers: false,
        ),
      );
      final postAuditLatex = postAuditQuality.questionReports
          .where((r) => r.issues.any((i) => i.code == 'latex_unrenderable'))
          .length;

      expect(preAuditLatex, 2,
          reason: 'Without audit both questions have dangling LaTeX');
      expect(postAuditLatex, 1,
          reason: 'After audit only unrepairable question has dangling LaTeX');
    });

    test('22-question synthetic sequence preserves count and order after audit',
        () {
      final questions = List.generate(22, (i) {
        final num = i + 1;
        return <String, dynamic>{
          'question_number': num,
          'type': num <= 10 ? 0 : (num <= 16 ? 2 : 3),
          'content': 'Question $num content \\(x^$num\\)',
          'options': num <= 10 ? ['A. a', 'B. b', 'C. c', 'D. d'] : <String>[],
          'standard_answer': num <= 16 || num == 21 ? 'A' : '',
          'explanation': 'Explanation $num',
        };
      });

      final audited = finalizeAndAuditImportQuestions(questions);

      expect(audited.length, 22);
      for (var i = 0; i < 22; i++) {
        expect(audited[i]['question_number'], i + 1);
      }
      expect(
        countSubjectiveAnswerDistillationCandidates(
          audited,
          isStemOnly: false,
        ),
        5,
      );
      expect(
        countSubjectiveAnswerDistillationCandidates(
          audited,
          isStemOnly: true,
        ),
        0,
      );
    });

    test('providerCallCount remains 0 in offline audit path', () {
      // The audit is purely deterministic; verify no network/provider
      // dependency by checking the acceptance pipeline source
      final content = File('tool/import_acceptance.dart').readAsStringSync();
      // The providerCallCount: 0 must come after finalization and audit
      final auditIndex = content.indexOf('finalizeAndAuditImportQuestions');
      final providerIndex = content.indexOf("'providerCallCount': 0");
      expect(auditIndex, greaterThan(-1));
      expect(providerIndex, greaterThan(auditIndex),
          reason:
              'providerCallCount: 0 must appear after finalizeAndAuditImportQuestions call');
    });
  });
}

String _currentReplayVersionPath(String repositoryRoot, String caseId) {
  final caseRoot = p.join(repositoryRoot, 'scratch', 'ocr_replay', caseId);
  final current = jsonDecode(
    File(p.join(caseRoot, 'current.json')).readAsStringSync(),
  ) as Map<String, dynamic>;
  return p.join(caseRoot, 'versions', current['version'] as String);
}

class _ThrowingReplayCacheWriteLock implements ReplayCacheWriteLock {
  _ThrowingReplayCacheWriteLock(String path)
      : _file = File(path).openSync(mode: FileMode.append);

  final RandomAccessFile _file;
  bool closed = false;
  int unlockCalls = 0;

  @override
  void lockSync() {
    throw const FileSystemException('fixture lock failure');
  }

  @override
  void unlockSync() {
    unlockCalls++;
    _file.unlockSync();
  }

  @override
  void closeSync() {
    _file.closeSync();
    closed = true;
  }
}

Future<ProcessResult> _runImportAcceptanceCli(List<String> args) {
  final script =
      p.join(Directory.current.path, 'tool', 'import_acceptance.dart');
  return Process.run(
    'dart',
    ['run', script, ...args],
    runInShell: Platform.isWindows,
  );
}

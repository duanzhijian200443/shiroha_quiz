import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/data/models/ai_engine_profile.dart';
import 'package:shiroha_quiz/data/persistence/ai_engine_store.dart';
import 'package:shiroha_quiz/data/repositories/ai_engine_repository.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_import_service.dart';

import '../tool/ocr_smoke.dart';
import '../tool/ocr_smoke_report.dart';

void main() {
  group('ocr_smoke.dart contract tests', () {
    test('maps only safe existing OCR diagnostics without fabricated zeros',
        () {
      final report = buildOcrSmokeIndependentParseReport(
        durationMs: 42,
        result: OcrImportResult(
          usedOcr: true,
          questions: const [
            {'q_num': '1'},
            {'q_num': '2'},
          ],
          warnings: const ['safe warning'],
          diagnostics: const {
            'status': 'used_ocr',
            'document': {
              'pageCount': 26,
              'blockCount': 321,
              'totalBlockCount': 999,
            },
            'regionizer': {
              'unitCount': 400,
              'regionCount': 24,
              'acceptedNumbers': [1, 2],
              'missingNumbers': [3],
              'sectionHeadingCount': 3,
              'numberedFieldCandidateCount': 5,
              'splitUnitCount': 6,
              'markdownPrefixedCandidateCount': 7,
              'blockStartCandidateCount': 8,
              'internalLineCandidateCount': 9,
              'parenthesizedArabicCandidateCount': 10,
              'parenthesizedArabicAcceptedCount': 11,
              'parenthesizedArabicRejectedCount': 12,
              'romanSubquestionCount': 13,
              'sequenceAcceptedCount': 14,
              'sequenceRejectedCount': 15,
            },
            'documentRole': 'ambiguous',
            'documentRoleConfidence': 0.5,
            'explicitAnswerMarkerCount': 16,
            'explicitExplanationMarkerCount': 17,
            'documentQuestionCount': 24,
            'documentNonEmptyStemCount': 24,
            'localNonEmptyAnswerCount': 18,
            'localNonEmptyExplanationCount': 19,
            'finalNonEmptyAnswerCount': 20,
            'finalNonEmptyExplanationCount': 21,
            'repairRecommendedCount': 22,
            'repairAttemptedCount': 22,
            'repairAppliedCount': 0,
            'repairSkippedForStemOnlyCount': 23,
            'discardedAnswerFromRepairCount': 24,
            'clearedAssemblerAnswerCount': 25,
            'rejectedRegionCount': 0,
          },
        ),
      );

      expect(report, containsPair('blockCount', 321));
      expect(report, isNot(containsPair('blockCount', 999)));
      expect(report['unitCount'], 400);
      expect(report['regionCount'], 24);
      expect(report['acceptedNumbers'], [1, 2]);
      expect(report['missingNumbers'], [3]);
      expect(report['sectionHeadingCount'], 3);
      expect(report['numberedFieldCandidateCount'], 5);
      expect(report['splitUnitCount'], 6);
      expect(report['markdownPrefixedCandidateCount'], 7);
      expect(report['blockStartCandidateCount'], 8);
      expect(report['internalLineCandidateCount'], 9);
      expect(report['parenthesizedArabicCandidateCount'], 10);
      expect(report['parenthesizedArabicAcceptedCount'], 11);
      expect(report['parenthesizedArabicRejectedCount'], 12);
      expect(report['romanSubquestionCount'], 13);
      expect(report['sequenceAcceptedCount'], 14);
      expect(report['sequenceRejectedCount'], 15);
      expect(report['documentRoleConfidence'], 0.5);
      expect(report['explicitAnswerMarkerCount'], 16);
      expect(report['explicitExplanationMarkerCount'], 17);
      expect(report['documentQuestionCount'], 24);
      expect(report['documentNonEmptyStemCount'], 24);
      expect(report['localNonEmptyAnswerCount'], 18);
      expect(report['localNonEmptyExplanationCount'], 19);
      expect(report['finalNonEmptyAnswerCount'], 20);
      expect(report['finalNonEmptyExplanationCount'], 21);
      expect(report['repairSkippedForStemOnlyCount'], 23);
      expect(report['repairAppliedCount'], 0);
      expect(report['questionCandidateTrace'], isNull);
      expect(report['questionCandidateTraceTruncated'], isFalse);
      expect(report['markerProbeTrace'], isNull);
      expect(report['markerProbeTraceTruncated'], isFalse);
    });

    test('maps candidate and marker probe trace fields when provided', () {
      final report = buildOcrSmokeIndependentParseReport(
        durationMs: 10,
        result: OcrImportResult(
          usedOcr: true,
          questions: const [],
          warnings: const [],
          diagnostics: {
            'status': 'used_ocr',
            'regionizer': {
              'questionCandidateTrace': [
                {
                  'number': 1,
                  'pageIndex': 1,
                  'markerKind': 'plain_integer',
                  'decision': 'accepted',
                  'reason': 'valid_question_start',
                  'previousAcceptedNumber': null,
                  'sectionIndex': 0,
                  'blockOrder': 0,
                }
              ],
              'questionCandidateTraceTruncated': true,
              'markerProbeTrace': [
                {
                  'pageIndex': 2,
                  'blockOrder': 3,
                  'sectionIndex': 1,
                  'startsAtBlockStart': false,
                  'startsAtLineBoundary': true,
                  'markerShape': 'digit_prefix_unrecognized',
                  'parsedNumber': 18,
                  'followerClass': 'other',
                  'probeReason': 'internal_line_not_split',
                },
              ],
              'markerProbeTraceTruncated': false,
            }
          },
        ),
      );

      expect(report['questionCandidateTrace'], isNotNull);
      expect(
        (report['questionCandidateTrace'] as List)[0]['number'],
        1,
      );
      expect(report['questionCandidateTraceTruncated'], isTrue);
      final probes = report['markerProbeTrace'] as List;
      expect(probes, hasLength(1));
      expect(probes.single['parsedNumber'], 18);
      expect(report['markerProbeCount'], 1);
      expect(report['markerProbeTraceTruncated'], isFalse);
    });

    test('reports unavailable diagnostics as null', () {
      final report = buildOcrSmokeIndependentParseReport(
        durationMs: 1,
        result: const OcrImportResult(
          usedOcr: false,
          questions: [],
          warnings: [],
          diagnostics: {'status': 'failed_request'},
        ),
      );

      expect(report['pageCount'], isNull);
      expect(report['blockCount'], isNull);
      expect(report['unitCount'], isNull);
      expect(report['regionCount'], isNull);
      expect(report['acceptedNumbers'], isNull);
      expect(report['documentRoleConfidence'], isNull);
      expect(report['repairRecommendedCount'], isNull);
      expect(report['repairAppliedCount'], isNull);
      expect(report['rejectedRegionCount'], isNull);
      expect(report['questionCandidateTrace'], isNull);
      expect(report['questionCandidateTraceTruncated'], isNull);
      expect(report['markerProbeTrace'], isNull);
      expect(report['markerProbeTraceTruncated'], isNull);
    });

    test('diagnostic report does not forward nested sensitive fields', () {
      final report = buildOcrSmokeIndependentParseReport(
        durationMs: 1,
        result: const OcrImportResult(
          usedOcr: true,
          questions: [
            {
              'q_num': '1',
              'content': 'PRIVATE_QUESTION_TEXT',
              'standard_answer': 'PRIVATE_ANSWER',
            },
          ],
          warnings: [],
          diagnostics: {
            'document': {
              'blockCount': 1,
              'rawResponses': 'PRIVATE_PROVIDER_BODY',
              'sourceName': r'C:\private\exam.pdf',
            },
            'Authorization': 'PRIVATE_AUTHORIZATION',
          },
        ),
      );

      final output = jsonEncode(report);
      expect(output, isNot(contains('PRIVATE_QUESTION_TEXT')));
      expect(output, isNot(contains('PRIVATE_ANSWER')));
      expect(output, isNot(contains('PRIVATE_PROVIDER_BODY')));
      expect(output, isNot(contains('PRIVATE_AUTHORIZATION')));
      expect(output, isNot(contains(r'C:\private')));
      expect(report, isNot(contains('fileName')));
    });

    test('terminal event omits full trace and nested sensitive fields', () {
      final terminalEvent = buildOcrSmokeTerminalEvent({
        'stage': 'independent_parse',
        'status': 'used_ocr',
        'durationMs': 12,
        'blockCount': 20,
        'acceptedNumbers': [12],
        'missingNumbers': [13],
        'questionCandidateTrace': [
          {
            'number': 13,
            'decision': 'rejected',
            'reason': 'other',
            'text': 'OCR-SENSITIVE-CONTENT',
          },
        ],
        'sourceName': 'private-exam.pdf',
        'apiKey': 'fixture-api-key',
      });

      expect(terminalEvent['questionCandidateCount'], 1);
      expect(terminalEvent['firstAnomaly'], {
        'number': 13,
        'decision': 'rejected',
        'reason': 'other',
      });
      final output = jsonEncode(terminalEvent);
      expect(terminalEvent, isNot(contains('questionCandidateTrace')));
      expect(output, isNot(contains('OCR-SENSITIVE-CONTENT')));
      expect(output, isNot(contains('private-exam.pdf')));
      expect(output, isNot(contains('fixture-api-key')));
    });

    test('normalizes all supported Unicode PDF path forms to one file', () {
      final repository = Directory.systemTemp.createTempSync(
        'ocr-smoke-unicode-',
      );
      addTearDown(() => repository.deleteSync(recursive: true));
      File('${repository.path}${Platform.pathSeparator}pubspec.yaml')
          .writeAsStringSync('name: test\n');
      final pdf = File(
        '${repository.path}${Platform.pathSeparator}scratch'
        '${Platform.pathSeparator}test_pdfs${Platform.pathSeparator}fixture'
        '${Platform.pathSeparator}中文试卷.pdf',
      )..createSync(recursive: true);
      pdf.writeAsBytesSync(const [0x25, 0x50, 0x44, 0x46]);

      final shortPath = resolveOcrSmokePdfPath(
        p.join('fixture', '中文试卷.pdf'),
        repositoryRoot: repository.path,
      );
      final repositoryRelativePath = resolveOcrSmokePdfPath(
        p.join('scratch', 'test_pdfs', 'fixture', '中文试卷.pdf'),
        repositoryRoot: repository.path,
      );
      final absolutePath = resolveOcrSmokePdfPath(
        pdf.path,
        repositoryRoot: repository.path,
      );

      expect(shortPath, absolutePath);
      expect(repositoryRelativePath, absolutePath);
      expect(absolutePath, contains('中文试卷.pdf'));
    });

    test('classifies PDF preflight failures before provider execution', () {
      final repository = Directory.systemTemp.createTempSync(
        'ocr-smoke-preflight-',
      );
      addTearDown(() => repository.deleteSync(recursive: true));
      Directory(
        '${repository.path}${Platform.pathSeparator}scratch'
        '${Platform.pathSeparator}test_pdfs',
      ).createSync(recursive: true);

      expect(
        () => resolveOcrSmokePdfPath(
          p.join('math', 'single', 'missing.pdf'),
          repositoryRoot: repository.path,
        ),
        throwsA(
          isA<OcrSmokePreflightException>().having(
            (error) => error.status,
            'status',
            'pdf_not_found',
          ),
        ),
      );
      expect(
        () => resolveOcrSmokePdfPath(
          '${repository.parent.path}${Platform.pathSeparator}outside.pdf',
          repositoryRoot: repository.path,
        ),
        throwsA(
          isA<OcrSmokePreflightException>().having(
            (error) => error.status,
            'status',
            'path_outside_repository_root',
          ),
        ),
      );
    });

    test('classifies provider and regionizer failures by safe type', () {
      expect(
        classifyOcrSmokeResultFailure(
          const OcrImportResult(
            usedOcr: false,
            questions: [],
            warnings: [],
            diagnostics: {
              'status': 'failed_request',
              'errorType': 'ZhipuOcrAuthenticationException',
            },
          ),
        ),
        const OcrSmokeFailure('provider', 'authentication_error'),
      );
      expect(
        classifyOcrSmokeResultFailure(
          const OcrImportResult(
            usedOcr: false,
            questions: [],
            warnings: [],
            diagnostics: {
              'status': 'failed_request',
              'errorType': 'ZhipuOcrResponseFormatException',
            },
          ),
        ),
        const OcrSmokeFailure('provider', 'response_format_error'),
      );
      expect(
        classifyOcrSmokeResultFailure(
          const OcrImportResult(
            usedOcr: false,
            questions: [],
            warnings: [],
            diagnostics: {'status': 'failed_no_question_regions'},
          ),
        ),
        const OcrSmokeFailure('regionizer', 'no_question_regions'),
      );
      expect(
        classifyOcrSmokeResultFailure(
          const OcrImportResult(
            usedOcr: false,
            questions: [],
            warnings: [],
            diagnostics: {
              'status': 'failed_request',
              'errorType': 'FileSystemException',
            },
          ),
        ),
        const OcrSmokeFailure('preflight', 'file_read_error'),
      );
    });

    Future<Map<String, dynamic>> runSmokeTest(
      List<String> args, {
      Map<String, String>? env,
      String? repositoryRoot,
      Future<String?> Function()? loadSavedApiKey,
      required int expectedExitCode,
      required void Function(List<Map<String, dynamic>> jsonLines) verify,
    }) async {
      final List<Map<String, dynamic>> outputJson = [];

      final exitCode = await runOcrSmoke(
        args,
        (line) {
          final trimmed = line.trim();
          if (trimmed.startsWith('{') && trimmed.endsWith('}')) {
            try {
              outputJson.add(jsonDecode(trimmed) as Map<String, dynamic>);
            } catch (_) {}
          }
        },
        environment: env ?? {'SHIROHA_OCR_API_KEY': 'fake-key-for-test'},
        repositoryRoot: repositoryRoot,
        loadSavedApiKey: loadSavedApiKey,
      );

      expect(exitCode, expectedExitCode);
      verify(outputJson);

      return {'exitCode': exitCode, 'output': outputJson};
    }

    test('fails when no pdf provided', () async {
      await runSmokeTest(
        [],
        expectedExitCode: 1,
        verify: (jsonLines) {
          expect(jsonLines, isNotEmpty);
          final json = jsonLines.last;
          expect(json['stage'], 'launcher');
          expect(json['status'], 'invalid_pdf_argument');
        },
      );
    });

    test('fails when unknown parameters are provided', () async {
      await runSmokeTest(
        ['--unknown'],
        expectedExitCode: 1,
        verify: (jsonLines) {
          expect(jsonLines, isNotEmpty);
          final json = jsonLines.last;
          expect(json['stage'], 'launcher');
          expect(json['status'], 'invalid_pdf_argument');
        },
      );
    });

    test('prints only a boolean API key preflight result', () async {
      await runSmokeTest(
        ['--unknown'],
        env: const {'SHIROHA_OCR_API_KEY': 'contract-test-secret'},
        expectedExitCode: 1,
        verify: (jsonLines) {
          expect(jsonLines.first, {
            'stage': 'preflight',
            'apiKeyPresent': true,
          });
          final output = jsonEncode(jsonLines);
          expect(output, isNot(contains('contract-test-secret')));
          expect(output, isNot(contains('Authorization')));
        },
      );
    });

    test('environment API Key takes priority over the saved credential',
        () async {
      var savedKeyReadCount = 0;
      await runSmokeTest(
        ['--unknown'],
        env: const {
          'SHIROHA_OCR_API_KEY': 'environment-contract-secret',
          'SHIROHA_OCR_USE_SAVED_APP_KEY': 'true',
        },
        loadSavedApiKey: () async {
          savedKeyReadCount++;
          return 'saved-contract-secret';
        },
        expectedExitCode: 1,
        verify: (jsonLines) {
          expect(jsonLines.first, {
            'stage': 'preflight',
            'apiKeyPresent': true,
          });
          final output = jsonEncode(jsonLines);
          expect(output, isNot(contains('environment-contract-secret')));
          expect(output, isNot(contains('saved-contract-secret')));
        },
      );

      expect(savedKeyReadCount, 0);
    });

    test('explicit saved credential request uses the injected loader',
        () async {
      var savedKeyReadCount = 0;
      await runSmokeTest(
        ['--unknown'],
        env: const {'SHIROHA_OCR_USE_SAVED_APP_KEY': 'true'},
        loadSavedApiKey: () async {
          savedKeyReadCount++;
          return 'saved-contract-secret';
        },
        expectedExitCode: 1,
        verify: (jsonLines) {
          expect(jsonLines.first, {
            'stage': 'preflight',
            'apiKeyPresent': true,
          });
          expect(
            jsonLines.where(
              (line) => line['status'] == 'saved_api_key_unavailable',
            ),
            isEmpty,
          );
          expect(
            jsonEncode(jsonLines),
            isNot(contains('saved-contract-secret')),
          );
        },
      );

      expect(savedKeyReadCount, 1);
    });

    test('saved credential read failure is safely classified', () async {
      await runSmokeTest(
        ['--pdf=fake.pdf'],
        env: const {'SHIROHA_OCR_USE_SAVED_APP_KEY': 'true'},
        loadSavedApiKey: () async {
          throw StateError('PRIVATE saved credential failure');
        },
        expectedExitCode: 1,
        verify: (jsonLines) {
          expect(jsonLines.last['stage'], 'launcher');
          expect(jsonLines.last['status'], 'saved_api_key_unavailable');
          final output = jsonEncode(jsonLines);
          expect(output, isNot(contains('PRIVATE saved credential failure')));
          expect(output, isNot(contains('StateError')));
        },
      );
    });

    test('fails when empty path is provided', () async {
      await runSmokeTest(
        ['--pdf='],
        expectedExitCode: 1,
        verify: (jsonLines) {
          expect(jsonLines, isNotEmpty);
          final json = jsonLines.last;
          expect(json['stage'], 'launcher');
          expect(json['status'], 'invalid_pdf_argument');
        },
      );
    });

    test('fails before request when API Key is missing', () async {
      await runSmokeTest(
        ['--pdf=fake.pdf'],
        env: const {},
        expectedExitCode: 1,
        verify: (jsonLines) {
          expect(jsonLines.first, {
            'stage': 'preflight',
            'apiKeyPresent': false,
          });
          final json = jsonLines.last;
          expect(json['stage'], 'launcher');
          expect(json['status'], 'missing_api_key');
          expect(
            jsonLines.where((line) => line['stage'] == 'independent_parse'),
            isEmpty,
          );
        },
      );
    });

    test('treats a whitespace-only API Key as missing', () async {
      await runSmokeTest(
        ['--pdf=fake.pdf'],
        env: const {'SHIROHA_OCR_API_KEY': '  \t\r\n '},
        expectedExitCode: 1,
        verify: (jsonLines) {
          expect(jsonLines.first['apiKeyPresent'], isFalse);
          expect(jsonLines.last['status'], 'missing_api_key');
          expect(
            jsonLines.where((line) => line['stage'] == 'independent_parse'),
            isEmpty,
          );
        },
      );
    });

    test('an existing API Key is not reported as missing', () async {
      await runSmokeTest(
        ['--pdf=contract-test-missing.pdf'],
        env: const {'SHIROHA_OCR_API_KEY': 'contract-test-secret'},
        expectedExitCode: 1,
        verify: (jsonLines) {
          expect(jsonLines.first['apiKeyPresent'], isTrue);
          expect(
            jsonLines.where((line) => line['status'] == 'missing_api_key'),
            isEmpty,
          );
        },
      );
    });

    test('accepts absolute paths under the allowed root', () async {
      final repository = Directory.systemTemp.createTempSync(
        'ocr-smoke-absolute-',
      );
      addTearDown(() => repository.deleteSync(recursive: true));
      File('${repository.path}${Platform.pathSeparator}pubspec.yaml')
          .writeAsStringSync('name: test\n');
      final pdfPath = '${repository.path}${Platform.pathSeparator}scratch'
          '${Platform.pathSeparator}test_pdfs${Platform.pathSeparator}empty.pdf';

      await runSmokeTest(
        ['--pdf=$pdfPath'],
        repositoryRoot: repository.path,
        expectedExitCode: 1,
        verify: (jsonLines) {
          final json = jsonLines.last;
          expect(json['stage'], 'preflight');
          expect(json['status'], 'pdf_not_found');
        },
      );
    });

    test('rejects path traversal (..)', () async {
      await runSmokeTest(
        ['--pdf=../fake.pdf'],
        expectedExitCode: 1,
        verify: (jsonLines) {
          final json = jsonLines.last;
          expect(json['status'], 'path_outside_repository_root');
        },
      );
    });

    test('rejects non-PDF files', () async {
      await runSmokeTest(
        ['--pdf=fake.png'],
        expectedExitCode: 1,
        verify: (jsonLines) {
          final json = jsonLines.last;
          expect(json['stage'], 'preflight');
          expect(json['status'], 'invalid_pdf_extension');
        },
      );
    });

    test('reports missing PDF as preflight rather than provider failure',
        () async {
      await runSmokeTest(
        ['--pdf=math/single/missing.pdf'],
        expectedExitCode: 1,
        verify: (jsonLines) {
          final json = jsonLines.last;
          expect(json['stage'], 'preflight');
          expect(json['status'], 'pdf_not_found');
          expect(
            jsonLines.where((line) => line['stage'] == 'provider'),
            isEmpty,
          );
        },
      );
    });

    test('single missing file stops during preflight', () async {
      await runSmokeTest(
        ['--pdf=math/single/missing.pdf'],
        expectedExitCode: 1,
        verify: (jsonLines) {
          expect(jsonLines.length, 2);
          expect(jsonLines[0]['stage'], 'preflight');
          expect(jsonLines[1]['stage'], 'preflight');
        },
      );
    });

    test('two PDF parameters are rejected before Provider access', () async {
      await runSmokeTest(
        ['--pdf=math/single/missing1.pdf', '--pdf=math/single/missing2.pdf'],
        expectedExitCode: 2,
        verify: (jsonLines) {
          expect(jsonLines, hasLength(1));
          expect(jsonLines.single['stage'], 'launcher');
          expect(jsonLines.single['status'], 'multiple_pdfs_not_supported');
          expect(jsonLines.single['causeType'], 'MultiplePdfNotSupported');
          expect(
            jsonLines.where((line) => line['stage'] == 'provider'),
            isEmpty,
          );
          expect(
            jsonLines.where((line) => line['stage'] == 'independent_parse'),
            isEmpty,
          );
        },
      );
    });

    test('rejects more than two PDF parameters with the same safe status',
        () async {
      await runSmokeTest(
        [
          '--pdf=first.pdf',
          '--pdf=second.pdf',
          '--pdf=third.pdf',
        ],
        expectedExitCode: 2,
        verify: (jsonLines) {
          expect(jsonLines.single['stage'], 'launcher');
          expect(jsonLines.single['status'], 'multiple_pdfs_not_supported');
          expect(jsonLines.single['causeType'], 'MultiplePdfNotSupported');
          expect(
            jsonLines.where((line) => line['stage'] == 'independent_parse'),
            isEmpty,
          );
        },
      );
    });

    test('report does not contain sensitive data', () async {
      await runSmokeTest(
        ['--pdf=math/single/missing.pdf'],
        expectedExitCode: 1,
        verify: (jsonLines) {
          final output = jsonEncode(jsonLines);
          expect(output.contains('fake-key-for-test'), isFalse,
              reason: 'Key leaked');
          expect(output.contains('Authorization'), isFalse);
          expect(output.contains('base64'), isFalse);
          expect(output.contains('content'), isFalse); // No question bodies
          expect(output.contains('standard_answer'), isFalse); // No answers
        },
      );
    });

    test('raw exception info does not enter output', () async {
      await runSmokeTest(
        ['--pdf=math/single/missing.pdf'],
        expectedExitCode: 1,
        verify: (jsonLines) {
          final output = jsonEncode(jsonLines);
          expect(output.contains('Cannot open file'), isFalse);
          expect(output.contains('OS Error'), isFalse);
        },
      );
    });

    test('production main passes Platform.environment explicitly and exits',
        () {
      final source = File('tool/ocr_smoke.dart').readAsStringSync();
      expect(source, contains('final environment = Platform.environment'));
      expect(source, contains('exit(exitCode)'));
    });

    test('invalid invocation completes without waiting for Flutter run',
        () async {
      final output = <String>[];
      final exitCode = await runOcrSmoke(
        const ['--unknown'],
        output.add,
        environment: const {},
      ).timeout(const Duration(seconds: 2));

      expect(exitCode, 1);
      expect(output, isNotEmpty);
    });

    test('report write failure preserves smoke exit and emits safe status',
        () async {
      final output = <String>[];
      final writer = OcrSmokeReportWriter(
        repositoryRoot: Directory.systemTemp.path,
        runId: 'ocr-run-20260723-120002-c1d2e3f4',
        fileWriter: (_, __) async {
          throw const FileSystemException('PRIVATE report path');
        },
      );

      final exitCode = await runOcrSmoke(
        const [],
        output.add,
        environment: const {},
        reportWriter: writer,
      );

      expect(exitCode, 1);
      final lastEvent = jsonDecode(output.last) as Map<String, dynamic>;
      expect(lastEvent, {
        'stage': 'report',
        'status': 'report_write_failed',
        'causeType': 'FileSystemException',
      });
      expect(output.join(), isNot(contains('PRIVATE report path')));
    });

    test('saved fixture credential is absent from output and report files',
        () async {
      const fixtureKey = 'saved-report-contract-secret';
      const args = ['--unknown'];
      final repository = Directory.systemTemp.createTempSync(
        'ocr-smoke-saved-key-report-',
      );
      addTearDown(() {
        if (repository.existsSync()) {
          repository.deleteSync(recursive: true);
        }
      });
      final output = <String>[];

      final exitCode = await runOcrSmoke(
        args,
        output.add,
        environment: const {'SHIROHA_OCR_USE_SAVED_APP_KEY': 'true'},
        loadSavedApiKey: () async => fixtureKey,
        reportWriter: OcrSmokeReportWriter(
          repositoryRoot: repository.path,
          runId: 'ocr-run-20260723-120003-d1e2f3a4',
        ),
      );

      expect(exitCode, 1);
      expect(args, isNot(contains(fixtureKey)));
      expect(output.join(), isNot(contains(fixtureKey)));
      final files = repository
          .listSync(recursive: true)
          .whereType<File>()
          .toList(growable: false);
      expect(files, isNotEmpty);
      expect(
        files.map((file) => file.readAsStringSync()).join(),
        isNot(contains(fixtureKey)),
      );
      expect(
        files.where((file) => file.path.toLowerCase().endsWith('.db')),
        isEmpty,
      );
    });

    test('PowerShell launcher preserves credential and Unicode boundaries', () {
      final source = File('tool/run_ocr_smoke.ps1').readAsStringSync();
      final dartSource = File('tool/ocr_smoke.dart').readAsStringSync();

      expect(
        source,
        isNot(contains(r'[Parameter(Mandatory = $true, Position = 0)]')),
      );
      expect(source, contains(r'[switch]$UseSavedAppKey'));
      expect(source, contains(r'[switch]$SkipBuild'));
      expect(source, contains('Read-Host'));
      expect(source, contains('-AsSecureString'));
      expect(source, contains('SHIROHA_OCR_API_KEY'));
      expect(source, contains('SHIROHA_OCR_USE_SAVED_APP_KEY'));
      expect(source, contains('ZeroFreeBSTR'));
      expect(
        source,
        contains("EnvironmentVariables['SHIROHA_OCR_API_KEY'] = $apiKey"),
      );
      expect(
        source,
        contains(
          "$null = $startInfo.EnvironmentVariables.Remove('SHIROHA_OCR_API_KEY')",
        ),
      );
      expect(source, isNot(contains('.Environment[')));
      expect(source, isNot(contains('.Environment.Remove(')));
      expect(source, contains('Resolve-Path -LiteralPath'));
      expect(source, contains('Join-WindowsCommandLine'));
      expect(dartSource, contains('saved_api_key_unavailable'));
      expect(
        dartSource,
        contains('repository.getActiveOcrEngine()'),
      );
      expect(dartSource, contains('sqfliteFfiInit()'));
      expect(dartSource, contains('databaseFactory = databaseFactoryFfi'));
      expect(source, isNot(contains('shiroha_core_v1.db')));
      expect(source, isNot(contains('sqlite')));
      expect(source, contains('taskkill.exe'));
      expect(source, isNot(contains('Kill($true)')));
      expect(source, isNot(contains('ToHexString')));
      expect(source, isNot(contains('.ArgumentList')));
      expect(source, isNot(contains('SetEnvironmentVariable')));
      expect(source, isNot(contains('--dart-define')));
      expect(source, isNot(contains('--api-key')));
      expect(source, isNot(contains('flutter run')));
      expect(
        source,
        contains(r'$startInfo.Arguments = Join-WindowsCommandLine'),
      );
      expect(source.toLowerCase(), isNot(contains('cmd.exe')));
      expect(source, contains("Get-Command 'flutter'"));
      expect(source, contains(r'$startInfo.FileName = $executablePath'));
      expect(source, contains('[System.Diagnostics.Process]::Start'));
      expect(source, contains('New-OcrSmokeReportContext'));
      expect(source, contains('Write-OcrSmokeTerminalSummary'));
      expect(source, contains('multiple_pdfs_not_supported'));
      expect(source, contains('MultiplePdfNotSupported'));
      expect(source, contains(r'$Pdf.Count -gt 1'));
      expect(source, isNot(contains("'combined_merge'")));
      expect(source, contains('SHIROHA_OCR_RUN_ID'));
      expect(source, contains('tool\\ocr_smoke_report.dart'));
      expect(source, contains("'report'"));
      expect(
        source,
        contains(r"$parsed.stage -ne 'independent_parse'"),
      );
      expect(
        source,
        contains(
          r"$null = $startInfo.EnvironmentVariables.Remove('SHIROHA_OCR_API_KEY')",
        ),
      );

      final environmentCheck = source.indexOf(
        r'$env:SHIROHA_OCR_API_KEY',
      );
      final savedKeyBranch = source.indexOf(r'elseif ($UseSavedAppKey');
      final prompt = source.indexOf('Read-Host');
      expect(environmentCheck, greaterThanOrEqualTo(0));
      expect(savedKeyBranch, greaterThan(environmentCheck));
      expect(environmentCheck, lessThan(prompt));
      expect(savedKeyBranch, lessThan(prompt));

      final gitignore = File('.gitignore').readAsStringSync();
      expect(gitignore, contains('scratch/ocr_reports/'));
    });

    test('PowerShell launcher delegates PDF path resolution to the helper', () {
      final source = File('tool/run_ocr_smoke.ps1').readAsStringSync();
      final helper = File('tool/ocr_smoke_path_helpers.ps1').readAsStringSync();

      expect(
        source,
        contains(r". (Join-Path $PSScriptRoot 'ocr_smoke_path_helpers.ps1')"),
        reason: 'launcher must dot-source the path helper',
      );
      expect(
        source,
        isNot(contains('function Resolve-SmokePdfPath')),
        reason: 'launcher must not keep a second path resolver implementation',
      );
      expect(helper, contains('function Resolve-SmokePdfPath'));
      expect(helper, isNot(contains('Read-Host')));
      expect(helper, isNot(contains('SHIROHA_OCR_API_KEY')));
      expect(helper, isNot(contains('ConvertTo-Json')));

      // Multi-PDF rejection contract stays in the launcher.
      expect(source, contains('multiple_pdfs_not_supported'));
      expect(source, contains('MultiplePdfNotSupported'));
      expect(source, contains(r'$Pdf.Count -gt 1'));
    });

    test(
        'loadSavedOcrApiKey resolves saved profile using an explicit repository',
        () async {
      final fakeProfile = AiEngineProfile(
        id: 'test-id',
        engineType: AiEngineType.ocr,
        name: 'test-ocr',
        apiKey: 'fake-saved-key-12345',
        baseUrl: 'https://fake.url',
        modelName: 'glm-4v',
        temperature: 0.0,
        reasoningEffort: '',
        isActive: true,
      );

      final explicitRepo =
          AiEngineRepository(store: _FakeAiEngineStore(fakeProfile));
      final key = await loadSavedOcrApiKey(repository: explicitRepo);
      expect(key, equals('fake-saved-key-12345'));
    });

    test(
      'runOcrSmoke under both normal and WriteReplayCache modes resolve the same saved credential loader',
      () async {
        final fakeProfile = AiEngineProfile(
          id: 'test-id',
          engineType: AiEngineType.ocr,
          name: 'test-ocr',
          apiKey: 'fake-saved-key-12345',
          baseUrl: 'https://fake.url',
          modelName: 'glm-4v',
          temperature: 0.0,
          reasoningEffort: '',
          isActive: true,
        );
        final explicitRepo =
            AiEngineRepository(store: _FakeAiEngineStore(fakeProfile));

        // Standard mode
        final eventsNormal = <Map<String, dynamic>>[];
        await runOcrSmoke(
          ['--pdf=non_existent.pdf'],
          (line) => eventsNormal.add(jsonDecode(line) as Map<String, dynamic>),
          environment: {'SHIROHA_OCR_USE_SAVED_APP_KEY': 'true'},
          loadSavedApiKey: () => loadSavedOcrApiKey(repository: explicitRepo),
        );

        // WriteReplayCache mode
        final eventsCache = <Map<String, dynamic>>[];
        await runOcrSmoke(
          ['--pdf=non_existent.pdf'],
          (line) => eventsCache.add(jsonDecode(line) as Map<String, dynamic>),
          environment: {
            'SHIROHA_OCR_USE_SAVED_APP_KEY': 'true',
            'SHIROHA_WRITE_REPLAY_CACHE': 'true',
            'SHIROHA_REPLAY_CASE_ID': 'test_case',
          },
          loadSavedApiKey: () => loadSavedOcrApiKey(repository: explicitRepo),
        );

        expect(eventsNormal.first['apiKeyPresent'], isTrue);
        expect(eventsCache.first['apiKeyPresent'], isTrue);
        expect(eventsNormal.first['stage'], 'preflight');
        expect(eventsCache.first['stage'], 'preflight');
      },
    );

    test('DatabaseHelper does not configure mutable Repository provider state',
        () {
      final databaseSource =
          File('lib/core/database/database_helper.dart').readAsStringSync();
      final repositorySource =
          File('lib/data/repositories/ai_engine_repository.dart')
              .readAsStringSync();

      expect(databaseSource, isNot(contains('AiEngineRepository')));
      expect(
          repositorySource, isNot(contains('defaultDatabaseHelperProvider')));
      expect(repositorySource, isNot(contains('static AiEngineRepository')));
    });

    test('loadSavedOcrApiKey supports explicit repository injection', () async {
      final fakeProfile = AiEngineProfile(
        id: 'test-id',
        engineType: AiEngineType.ocr,
        name: 'test-ocr',
        apiKey: 'explicit-injected-key-secret',
        baseUrl: 'https://fake.url',
        modelName: 'glm-4v',
        temperature: 0.0,
        reasoningEffort: '',
        isActive: true,
      );
      final explicitRepo =
          AiEngineRepository(store: _FakeAiEngineStore(fakeProfile));

      final key = await loadSavedOcrApiKey(repository: explicitRepo);
      expect(key, equals('explicit-injected-key-secret'));
    });

    test(
        'SavedKeyProbe contract tests for available, unavailable, and exception states without making network calls',
        () async {
      const fixtureKey = 'fixture-saved-key-sensitive';
      final fakeProfile = AiEngineProfile(
        id: 'test-id',
        engineType: AiEngineType.ocr,
        name: 'test-ocr',
        apiKey: fixtureKey,
        baseUrl: 'https://fake.url',
        modelName: 'glm-4v',
        temperature: 0.0,
        reasoningEffort: '',
        isActive: true,
      );
      final explicitRepo =
          AiEngineRepository(store: _FakeAiEngineStore(fakeProfile));

      // Available state
      final eventsAvailable = <Map<String, dynamic>>[];
      final exitCodeAvailable = await runOcrSmoke(
        ['--saved-key-probe'],
        (line) => eventsAvailable.add(jsonDecode(line) as Map<String, dynamic>),
        environment: {'SHIROHA_OCR_USE_SAVED_APP_KEY': 'true'},
        loadSavedApiKey: () => loadSavedOcrApiKey(repository: explicitRepo),
      );

      expect(exitCodeAvailable, equals(0));
      expect(eventsAvailable.first, {
        'stage': 'credential_probe',
        'status': 'available',
        'apiKeyPresent': true,
      });
      final jsonOutputAvailable = jsonEncode(eventsAvailable);
      expect(jsonOutputAvailable, isNot(contains(fixtureKey)));

      // Unavailable state
      final eventsUnavailable = <Map<String, dynamic>>[];
      final exitCodeUnavailable = await runOcrSmoke(
        ['--saved-key-probe'],
        (line) =>
            eventsUnavailable.add(jsonDecode(line) as Map<String, dynamic>),
        environment: {'SHIROHA_OCR_USE_SAVED_APP_KEY': 'true'},
        loadSavedApiKey: () async => null,
      );

      expect(exitCodeUnavailable, equals(1));
      expect(eventsUnavailable.first, {
        'stage': 'credential_probe',
        'status': 'unavailable',
        'apiKeyPresent': false,
        'causeType': 'SavedApiKeyUnavailable',
      });

      // Exception state
      final eventsException = <Map<String, dynamic>>[];
      final exitCodeException = await runOcrSmoke(
        ['--saved-key-probe'],
        (line) => eventsException.add(jsonDecode(line) as Map<String, dynamic>),
        environment: {'SHIROHA_OCR_USE_SAVED_APP_KEY': 'true'},
        loadSavedApiKey: () async {
          throw StateError('DB error');
        },
      );

      expect(exitCodeException, equals(1));
      expect(eventsException.first, {
        'stage': 'credential_probe',
        'status': 'unavailable',
        'apiKeyPresent': false,
        'causeType': 'SavedApiKeyUnavailable',
      });
    });

    test(
        'Replay Cache parameter validation checks exit code 2 before OCR execution',
        () async {
      final cases = [
        (
          args: ['--write-replay-cache'],
          status: 'replay_cache_requires_single_pdf',
          cause: 'InvalidReplayCacheRequest'
        ),
        (
          args: [
            '--write-replay-cache',
            '--pdf=a.pdf',
            '--pdf=b.pdf',
            '--case-id=2022_math1'
          ],
          status: 'multiple_pdfs_not_supported',
          cause: 'MultiplePdfNotSupported'
        ),
        (
          args: ['--write-replay-cache', '--pdf=a.pdf', '--case-id='],
          status: 'replay_case_id_required',
          cause: 'InvalidReplayCacheRequest'
        ),
        (
          args: ['--write-replay-cache', '--pdf=a.pdf', '--case-id=../bad'],
          status: 'invalid_replay_case_id',
          cause: 'InvalidReplayCaseId'
        ),
        (
          args: ['--write-replay-cache', '--pdf=a.pdf', '--case-id=2022/math1'],
          status: 'invalid_replay_case_id',
          cause: 'InvalidReplayCaseId'
        ),
        (
          args: ['--saved-key-probe', '--write-replay-cache'],
          status: 'invalid_arguments',
          cause: 'InvalidArguments'
        ),
      ];

      for (final testCase in cases) {
        final events = <Map<String, dynamic>>[];
        final exitCode = await runOcrSmoke(
          testCase.args,
          (line) => events.add(jsonDecode(line) as Map<String, dynamic>),
          environment: {},
        );
        expect(exitCode, equals(2), reason: 'Args: ${testCase.args}');
        expect(events.first['stage'], equals('launcher'));
        expect(events.first['status'], equals(testCase.status));
        expect(events.first['causeType'], equals(testCase.cause));
      }
    });

    test(
        'PowerShell launcher script updated safeStages and replayCacheWritten contract checks',
        () {
      final psScript = File('tool/run_ocr_smoke.ps1').readAsStringSync();
      expect(psScript, contains("'replay_cache'"));
      expect(psScript, contains("'credential_probe'"));
      expect(psScript, contains(r'$replayCacheWritten = $true'));
      expect(psScript,
          contains(r'$WriteReplayCache -and -not $replayCacheWritten'));

      final acceptancePsScript =
          File('tool/run_import_acceptance.ps1').readAsStringSync();
      expect(
          acceptancePsScript,
          contains(
              r"$evt.stage -eq 'replay_cache' -and $evt.status -eq 'written'"));
      expect(acceptancePsScript,
          contains(r'$smokeExit -ne 0 -or -not $replayCacheWritten'));
      expect(acceptancePsScript, contains('--repository-root='));
    });

    test(
        'launcher passes --repository-root as single = token, '
        'never as two separate tokens', () {
      final psScript = File('tool/run_ocr_smoke.ps1').readAsStringSync();

      // Must use the = form so the Dart CLI parser recognizes a single token.
      expect(
        psScript,
        contains(r'"--repository-root=$repoRoot"'),
        reason: 'launcher must join --repository-root and path with =',
      );

      // Must NOT pass the path as a second, separate array element.
      // The old two-token form caused the path to be misidentified as a PDF.
      expect(
        psScript,
        isNot(contains("'--repository-root', $repoRoot")),
        reason:
            'two-token form would leak repo root as a positional PDF argument',
      );
    });

    test('acceptance PowerShell missing case is path-redacted JSON', () async {
      final outsideDirectory =
          Directory.systemTemp.createTempSync('acceptance-ps-missing-');
      addTearDown(() {
        if (outsideDirectory.existsSync()) {
          outsideDirectory.deleteSync(recursive: true);
        }
      });
      final script = p.join(
        Directory.current.path,
        'tool',
        'run_import_acceptance.ps1',
      );

      final result = await Process.run(
        'powershell.exe',
        [
          '-NoProfile',
          '-ExecutionPolicy',
          'Bypass',
          '-File',
          script,
          '-Case',
          'definitely_missing_case',
        ],
        workingDirectory: outsideDirectory.path,
      );

      expect(result.exitCode, 1);
      expect(result.stdout, contains('"status":"case_not_found"'));
      expect(result.stdout, isNot(contains(Directory.current.path)));
      expect(result.stdout, isNot(contains(outsideDirectory.path)));
      expect(result.stderr, isEmpty);
    }, skip: !Platform.isWindows);

    test('acceptance PowerShell runner failure redacts exception and paths',
        () async {
      final outsideDirectory =
          Directory.systemTemp.createTempSync('acceptance-ps-runner-');
      addTearDown(() {
        if (outsideDirectory.existsSync()) {
          outsideDirectory.deleteSync(recursive: true);
        }
      });
      final script = p.join(
        Directory.current.path,
        'tool',
        'run_import_acceptance.ps1',
      );
      const missingRunner = r'Z:\SENSITIVE_RUNNER_PATH_5E20\dart.exe';

      final result = await Process.run(
        'powershell.exe',
        [
          '-NoProfile',
          '-ExecutionPolicy',
          'Bypass',
          '-File',
          script,
          '-Case',
          '2022_math1',
          '-DartExecutableForTesting',
          missingRunner,
        ],
        workingDirectory: outsideDirectory.path,
      );

      expect(result.exitCode, 1);
      expect(result.stdout, contains('"status":"runner_start_failed"'));
      expect(result.stdout, isNot(contains(missingRunner)));
      expect(result.stdout, isNot(contains(Directory.current.path)));
      expect(result.stderr, isEmpty);
    }, skip: !Platform.isWindows);
  });
}

class _FakeAiEngineStore implements AiEngineStore {
  _FakeAiEngineStore(this._profile);

  final AiEngineProfile _profile;

  @override
  Future<AiEngineProfile?> getActiveAiEngine(AiEngineType type) async {
    return type == AiEngineType.ocr ? _profile : null;
  }

  @override
  Future<List<AiEngineProfile>> listAiEngines(AiEngineType type) async {
    return type == AiEngineType.ocr ? <AiEngineProfile>[_profile] : const [];
  }

  @override
  Future<void> saveAiEngine(AiEngineProfile profile) async {
    throw UnsupportedError('Read-only fake AI engine store');
  }

  @override
  Future<void> setActiveAiEngine(String id, AiEngineType type) async {
    throw UnsupportedError('Read-only fake AI engine store');
  }

  @override
  Future<void> deleteAiEngine(String id) async {
    throw UnsupportedError('Read-only fake AI engine store');
  }
}

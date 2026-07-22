import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_import_service.dart';

import '../tool/ocr_smoke.dart';

void main() {
  group('ocr_smoke.dart contract tests', () {
    test('maps only safe existing OCR diagnostics without fabricated zeros',
        () {
      final report = buildOcrSmokeIndependentParseReport(
        fileName: 'safe.pdf',
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
      expect(report['questionCandidateTraceTruncated'], isNull);
    });

    test('maps candidate trace fields when they are provided', () {
      final report = buildOcrSmokeIndependentParseReport(
        fileName: 'trace.pdf',
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
    });

    test('reports unavailable diagnostics as null', () {
      final report = buildOcrSmokeIndependentParseReport(
        fileName: 'safe.pdf',
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
    });

    test('diagnostic report does not forward nested sensitive fields', () {
      final report = buildOcrSmokeIndependentParseReport(
        fileName: 'safe.pdf',
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
    });

    Future<Map<String, dynamic>> runSmokeTest(
      List<String> args, {
      Map<String, String>? env,
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
          expect(json['stage'], 'failed');
          expect(json['status'], 'no_pdf_provided');
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
          expect(json['stage'], 'failed');
          expect(json['status'], 'invalid_arguments');
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

    test('fails when empty path is provided', () async {
      await runSmokeTest(
        ['--pdf='],
        expectedExitCode: 1,
        verify: (jsonLines) {
          expect(jsonLines, isNotEmpty);
          final json = jsonLines.last;
          expect(json['stage'], 'failed');
          expect(json['status'], 'invalid_arguments');
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
          expect(json['stage'], 'failed');
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

    test('rejects absolute paths', () async {
      await runSmokeTest(
        ['--pdf=C:/fake.pdf'],
        expectedExitCode: 1,
        verify: (jsonLines) {
          final json = jsonLines.last;
          expect(json['status'], 'absolute_path_rejected');
        },
      );
    });

    test('rejects path traversal (..)', () async {
      await runSmokeTest(
        ['--pdf=../fake.pdf'],
        expectedExitCode: 1,
        verify: (jsonLines) {
          final json = jsonLines.last;
          expect(json['status'], 'path_traversal_rejected');
        },
      );
    });

    test('rejects non-PDF files', () async {
      await runSmokeTest(
        ['--pdf=fake.png'],
        expectedExitCode: 1,
        verify: (jsonLines) {
          final json = jsonLines.last;
          expect(json['status'], 'non_pdf_rejected');
        },
      );
    });

    test('rejects targets outside the root directory', () async {
      await runSmokeTest(
        ['--pdf=math/single/missing.pdf'],
        expectedExitCode: 1,
        verify: (jsonLines) {
          final parseJson = jsonLines[1];
          expect(parseJson['stage'], 'independent_parse');
          expect(parseJson['status'], 'failed_unhandled_exception');
          expect(parseJson['causeType'], 'FileSystemException');

          final endJson = jsonLines[2];
          expect(endJson['stage'], 'failed');
          expect(endJson['status'], 'provider_error');
        },
      );
    });

    test('single file parameter creates only an independent task', () async {
      await runSmokeTest(
        ['--pdf=math/single/missing.pdf'],
        expectedExitCode: 1,
        verify: (jsonLines) {
          expect(jsonLines.length, 3);
          expect(jsonLines[0]['stage'], 'preflight');
          expect(jsonLines[1]['stage'], 'independent_parse');
          expect(jsonLines[2]['stage'], 'failed');
        },
      );
    });

    test(
        'double file parameters produce two independent stages and one combined stage',
        () async {
      await runSmokeTest(
        ['--pdf=math/single/missing1.pdf', '--pdf=math/single/missing2.pdf'],
        expectedExitCode: 1,
        verify: (jsonLines) {
          expect(jsonLines.length, 4);
          expect(jsonLines[0]['stage'], 'preflight');
          expect(jsonLines[1]['stage'], 'independent_parse');
          expect(jsonLines[2]['stage'], 'independent_parse');
          expect(jsonLines[3]['stage'], 'failed');
        },
      );
    });

    test('rejects more than two PDF parameters', () async {
      await runSmokeTest(
        [
          '--pdf=first.pdf',
          '--pdf=second.pdf',
          '--pdf=third.pdf',
        ],
        expectedExitCode: 1,
        verify: (jsonLines) {
          expect(jsonLines.last['status'], 'invalid_arguments');
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
      expect(source, contains('environment: Platform.environment'));
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

    test('PowerShell launcher keeps API Key out of command-line arguments', () {
      final source = File('tool/run_ocr_smoke.ps1').readAsStringSync();

      expect(source, contains('Read-Host'));
      expect(source, contains('-AsSecureString'));
      expect(source, contains('SHIROHA_OCR_API_KEY'));
      expect(source, contains('ZeroFreeBSTR'));
      expect(source, contains("EnvironmentVariables['SHIROHA_OCR_API_KEY']"));
      expect(
        source,
        contains("EnvironmentVariables.Remove('SHIROHA_OCR_API_KEY')"),
      );
      expect(source, contains(r'$process.Kill()'));
      expect(source, isNot(contains('SetEnvironmentVariable')));
      expect(source, isNot(contains('--dart-define')));
      expect(source, isNot(contains('--api-key')));
      expect(source, isNot(contains('flutter run')));
      expect(source,
          contains("flutter build windows --release -t tool/ocr_smoke.dart"));
      expect(source, contains(r'$startInfo.FileName = $executablePath'));
      expect(source, contains('[System.Diagnostics.Process]::Start'));
    });
  });
}

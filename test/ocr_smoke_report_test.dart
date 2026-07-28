import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/ocr_smoke_report.dart';

void main() {
  group('OcrSmokeReportWriter', () {
    late Directory repository;

    setUp(() {
      repository = Directory.systemTemp.createTempSync('ocr-smoke-report-');
    });

    tearDown(() {
      if (repository.existsSync()) {
        repository.deleteSync(recursive: true);
      }
    });

    test('writes sorted, parseable, whitelist-only report files', () async {
      const runId = 'ocr-run-20260723-120000-a1b2c3d4';
      final writer = OcrSmokeReportWriter(
        repositoryRoot: repository.path,
        runId: runId,
        traceIdFactory: () => 'trace-safe-test',
      );
      final events = <Map<String, dynamic>>[
        {
          'stage': 'preflight',
          'status': 'success',
          'apiKey': 'fixture-api-key',
          'Authorization': 'Bearer PRIVATE',
          'sourcePath': r'C:\Users\private\exam.pdf',
        },
        {
          'stage': 'independent_parse',
          'status': 'used_ocr',
          'durationMs': 901341,
          'blockCount': 417,
          'regionCount': 12,
          'assembledQuestionCount': 12,
          'finalQuestionCount': 12,
          'acceptedNumbers': [12, 12],
          'missingNumbers': [13, 14, 15, 16, 17],
          'referenceSectionDetected': true,
          'referenceSectionCandidateCount': 1,
          'questionCandidateTraceTruncated': true,
          'markerProbeTraceTruncated': false,
          'providerBody': '{"providerBody":"PRIVATE"}',
          'questionCandidateTrace': [
            {
              'number': 15,
              'pageIndex': 4,
              'sectionIndex': 2,
              'blockOrder': 4,
              'markerKind': 'punctuated_integer',
              'decision': 'rejected',
              'reason': 'sequence_mismatch',
              'previousAcceptedNumber': 12,
              'text': 'OCR-SENSITIVE-CONTENT',
            },
            {
              'number': 12,
              'pageIndex': 3,
              'sectionIndex': 2,
              'blockOrder': 1,
              'markerKind': 'punctuated_integer',
              'decision': 'accepted',
              'reason': 'valid_question_start',
              'previousAcceptedNumber': 11,
              'content': 'QUESTION-SENSITIVE-CONTENT',
            },
            {
              'number': 14,
              'pageIndex': 4,
              'sectionIndex': 2,
              'blockOrder': 3,
              'markerKind': 'punctuated_integer',
              'decision': 'rejected',
              'reason': 'sequence_mismatch',
              'previousAcceptedNumber': 12,
            },
            {
              'number': 13,
              'pageIndex': 4,
              'sectionIndex': 2,
              'blockOrder': 2,
              'markerKind': 'explicit_question',
              'decision': 'rejected',
              'reason': 'other',
              'previousAcceptedNumber': 12,
            },
            {
              'number': 17,
              'pageIndex': 26,
              'sectionIndex': 4,
              'blockOrder': 8,
              'markerKind': 'parenthesized_arabic',
              'decision': 'rejected',
              'reason': 'reference_section',
              'previousAcceptedNumber': 12,
            },
          ],
          'markerProbeTrace': [
            {
              'pageIndex': 5,
              'blockOrder': 6,
              'sectionIndex': 3,
              'startsAtBlockStart': false,
              'startsAtLineBoundary': true,
              'markerShape': 'digit_prefix_unrecognized',
              'parsedNumber': 18,
              'followerClass': 'other',
              'probeReason': 'internal_line_not_split',
              'text': 'MARKER-PROBE-SENSITIVE-CONTENT',
            },
          ],
        },
        {
          'stage': 'completed',
          'status': 'success',
        },
      ];

      final result = await writer.write(
        events: events,
        exitCode: 0,
        buildCacheHit: true,
      );

      expect(result.succeeded, isTrue);
      expect(result.relativeDirectory, 'scratch/ocr_reports/$runId');

      final reportDirectory = Directory(
        '${repository.path}${Platform.pathSeparator}scratch'
        '${Platform.pathSeparator}ocr_reports'
        '${Platform.pathSeparator}$runId',
      );
      final files = {
        for (final name in const [
          'summary.json',
          'candidate_trace.json',
          'rejected_candidates.json',
          'marker_probe_trace.json',
          'launcher.log',
        ])
          name: File(
            '${reportDirectory.path}${Platform.pathSeparator}$name',
          ),
      };
      for (final file in files.values) {
        expect(file.existsSync(), isTrue);
        expect(() => jsonDecode(file.readAsStringSync()), returnsNormally);
      }

      final summary =
          jsonDecode(files['summary.json']!.readAsStringSync()) as Map;
      expect(summary['schemaVersion'], 1);
      expect(summary['runId'], runId);
      expect(summary['traceId'], 'trace-safe-test');
      expect(summary['stage'], 'completed');
      expect(summary['status'], 'success');
      expect(summary['durationMs'], 901341);
      expect(summary['ocrBlockCount'], 417);
      expect(summary['questionCandidateCount'], 5);
      expect(summary['acceptedNumbers'], [12, 12]);
      expect(summary['rejectedCandidateCount'], 4);
      expect(summary['duplicateNumbers'], [12]);
      expect(summary['missingNumbers'], [13, 14, 15, 16, 17]);
      expect(summary['referenceSectionDetected'], isTrue);
      expect(summary['referenceSectionCandidateCount'], 1);
      expect(summary['questionCandidateTraceTruncated'], isTrue);
      expect(summary['markerProbeCount'], 1);
      expect(summary['markerProbeTraceTruncated'], isFalse);
      expect(summary['firstAnomaly'], {
        'number': 13,
        'decision': 'rejected',
        'reason': 'other',
      });

      final trace =
          jsonDecode(files['candidate_trace.json']!.readAsStringSync()) as List;
      expect(trace.map((entry) => entry['number']), [12, 13, 14, 15, 17]);
      expect(trace.first.keys.toSet(), {
        'number',
        'pageIndex',
        'sectionIndex',
        'blockOrder',
        'markerKind',
        'decision',
        'reason',
        'previousAcceptedNumber',
      });

      final rejected = jsonDecode(
        files['rejected_candidates.json']!.readAsStringSync(),
      ) as List;
      expect(rejected, hasLength(4));
      expect(
        rejected.every((entry) => entry['decision'] == 'rejected'),
        isTrue,
      );

      final probes = jsonDecode(
        files['marker_probe_trace.json']!.readAsStringSync(),
      ) as List;
      expect(probes, hasLength(1));
      expect((probes.single as Map).keys.toSet(), {
        'pageIndex',
        'blockOrder',
        'sectionIndex',
        'startsAtBlockStart',
        'startsAtLineBoundary',
        'markerShape',
        'parsedNumber',
        'followerClass',
        'probeReason',
      });
      expect(probes.single['parsedNumber'], 18);

      final launcher =
          jsonDecode(files['launcher.log']!.readAsStringSync()) as List;
      const launcherKeys = {
        'stage',
        'status',
        'causeType',
        'durationMs',
        'buildCacheHit',
        'exitCode',
      };
      expect(
        launcher.every(
          (entry) => (entry as Map).keys.every(launcherKeys.contains),
        ),
        isTrue,
      );

      final allContents =
          files.values.map((file) => file.readAsStringSync()).join('\n');
      for (final forbidden in const [
        'fixture-api-key',
        'Authorization',
        r'C:\Users\private\exam.pdf',
        'OCR-SENSITIVE-CONTENT',
        'QUESTION-SENSITIVE-CONTENT',
        'MARKER-PROBE-SENSITIVE-CONTENT',
        '{"providerBody":"PRIVATE"}',
      ]) {
        expect(allContents, isNot(contains(forbidden)));
      }
    });

    test('returns a safe failure without changing the caller result', () async {
      final writer = OcrSmokeReportWriter(
        repositoryRoot: repository.path,
        runId: 'ocr-run-20260723-120001-b1c2d3e4',
        fileWriter: (_, __) async {
          throw const FileSystemException('PRIVATE absolute path');
        },
      );
      const originalExitCode = 7;

      final result = await writer.write(
        events: const [
          {'stage': 'provider', 'status': 'request_error'},
        ],
        exitCode: originalExitCode,
        buildCacheHit: false,
      );

      expect(originalExitCode, 7);
      expect(result.succeeded, isFalse);
      expect(result.failureEvent, {
        'stage': 'report',
        'status': 'report_write_failed',
        'causeType': 'FileSystemException',
      });
      expect(
        jsonEncode(result.failureEvent),
        isNot(contains('PRIVATE absolute path')),
      );
    });

    test('PowerShell launcher persists a safe early failure report', () async {
      if (!Platform.isWindows) return;
      final toolDirectory = Directory(
        '${repository.path}${Platform.pathSeparator}tool',
      )..createSync(recursive: true);
      Directory(
        '${repository.path}${Platform.pathSeparator}scratch'
        '${Platform.pathSeparator}test_pdfs',
      ).createSync(recursive: true);
      final launcher = File(
        '${toolDirectory.path}${Platform.pathSeparator}run_ocr_smoke.ps1',
      )..writeAsStringSync(
          File('tool/run_ocr_smoke.ps1').readAsStringSync(),
        );

      final process = await Process.run(
        'powershell.exe',
        [
          '-NoProfile',
          '-ExecutionPolicy',
          'Bypass',
          '-File',
          launcher.path,
        ],
        workingDirectory: repository.path,
      ).timeout(const Duration(seconds: 15));

      expect(process.exitCode, 2);
      expect(process.stdout.toString(), contains('invalid_pdf_argument'));
      final reportRoot = Directory(
        '${repository.path}${Platform.pathSeparator}scratch'
        '${Platform.pathSeparator}ocr_reports',
      );
      final runDirectories = reportRoot.listSync().whereType<Directory>();
      expect(runDirectories, hasLength(1));
      final reportDirectory = runDirectories.single;
      final files = [
        for (final name in const [
          'summary.json',
          'candidate_trace.json',
          'rejected_candidates.json',
          'launcher.log',
        ])
          File('${reportDirectory.path}${Platform.pathSeparator}$name'),
      ];
      for (final file in files) {
        expect(file.existsSync(), isTrue);
        expect(() => jsonDecode(file.readAsStringSync()), returnsNormally);
      }
      final summary = jsonDecode(files.first.readAsStringSync()) as Map;
      expect(summary['schemaVersion'], 1);
      expect(summary['stage'], 'launcher');
      expect(summary['status'], 'invalid_pdf_argument');
      final contents = files.map((file) => file.readAsStringSync()).join();
      expect(contents, isNot(contains('SHIROHA_OCR_API_KEY')));
      expect(contents, isNot(contains(repository.path)));
    });

    test('PowerShell 5.1 renders the terminal summary without mojibake',
        () async {
      if (!Platform.isWindows) return;
      final source = File('tool/run_ocr_smoke.ps1').readAsStringSync();

      String extractFunction(String name, String nextName) {
        final start = source.indexOf('function $name');
        final end = source.indexOf('function $nextName', start);
        expect(start, greaterThanOrEqualTo(0));
        expect(end, greaterThan(start));
        return source.substring(start, end);
      }

      final harness = File(
        '${repository.path}${Platform.pathSeparator}summary_harness.ps1',
      )..writeAsStringSync(
          '''
${extractFunction('Write-OcrSmokeTerminalSummary', 'Invoke-SmokeBuild')}
\$report = [pscustomobject]@{
    ocrStatus = 'success'
    traceId = 'trace-20260723-120000-a1b2c3d4'
    durationMs = 1234
    ocrBlockCount = 20
    questionCandidateCount = 3
    acceptedNumbers = @(1, 2, 3)
    missingNumbers = @()
    duplicateNumbers = @()
    firstAnomaly = [pscustomobject]@{
        number = 4
        reason = 'looks_like_option'
    }
    reportDirectory = 'scratch/ocr_reports/ocr-run-20260723-120000-a1b2c3d4'
}
Write-OcrSmokeTerminalSummary -Report \$report
''',
        );

      final process = await Process.run(
        'powershell.exe',
        [
          '-NoProfile',
          '-ExecutionPolicy',
          'Bypass',
          '-File',
          harness.path,
        ],
        workingDirectory: repository.path,
      ).timeout(const Duration(seconds: 15));

      final output = process.stdout.toString();
      expect(process.exitCode, 0, reason: process.stderr.toString());
      expect(output, contains('OCR: success'));
      expect(output, contains('Trace ID: trace-20260723-120000-a1b2c3d4'));
      expect(output, contains('Duration: 1234 ms'));
      expect(output, contains('OCR Blocks: 20'));
      expect(output, contains('Candidates: 3'));
      expect(output, contains('Accepted Numbers: 1,2,3'));
      expect(output, contains('Missing Numbers: none'));
      expect(output, contains('Duplicate Count: 0'));
      expect(output, contains('First Anomaly: 4 / looks_like_option'));
      expect(
        output,
        contains(
          'Report Directory: '
          'scratch/ocr_reports/ocr-run-20260723-120000-a1b2c3d4',
        ),
      );
      expect(output, isNot(contains('@{')));
      expect(output, isNot(contains('System.Object[]')));
      expect(output, isNot(contains('锛')));
    });

    test('builds unique safe run identifiers', () {
      final first = createOcrSmokeRunId(
        DateTime.utc(2026, 7, 23, 12),
        'a1b2c3d4',
      );
      final second = createOcrSmokeRunId(
        DateTime.utc(2026, 7, 23, 12),
        'e5f6a7b8',
      );

      expect(first, 'ocr-run-20260723-120000-a1b2c3d4');
      expect(second, isNot(first));
      expect(first, isNot(contains(r'\')));
      expect(first, isNot(contains('/')));
    });
  });
}

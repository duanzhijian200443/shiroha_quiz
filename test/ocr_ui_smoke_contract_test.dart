import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/main_ocr_ui_smoke.dart';

void main() {
  group('OCR UI smoke argument and output contract', () {
    test('accepts one relative PDF and explicit commit expectations', () {
      final config = OcrUiSmokeConfig.parse(
        const [
          '--pdf=math/single/fixture.pdf',
          '--commit',
          '--expected-question-count=22',
          '--expected-numbers=1-3,5',
          '--close-on-success',
        ],
        repositoryRoot: r'C:\repo',
      );

      expect(config.relativePdfPath, 'math/single/fixture.pdf');
      expect(config.fileName, 'fixture.pdf');
      expect(config.commit, isTrue);
      expect(config.expectedQuestionCount, 22);
      expect(config.expectedNumbers, [1, 2, 3, 5]);
      expect(config.closeOnSuccess, isTrue);
    });

    test('rejects unsafe or unsupported PDF arguments', () {
      for (final args in <List<String>>[
        const [],
        const ['--pdf=C:/private/fixture.pdf'],
        const ['--pdf=../fixture.pdf'],
        const ['--pdf=fixture.txt'],
        const ['--pdf=one.pdf', '--pdf=two.pdf'],
        const ['--unknown'],
      ]) {
        expect(
          () => OcrUiSmokeConfig.parse(args, repositoryRoot: r'C:\repo'),
          throwsA(isA<OcrUiSmokeArgumentException>()),
          reason: 'Arguments should be rejected: $args',
        );
      }
    });

    test('blank API key is missing without exposing its value', () {
      expect(isOcrUiSmokeApiKeyPresent(const {}), isFalse);
      expect(
        isOcrUiSmokeApiKeyPresent(
          const {'SHIROHA_OCR_API_KEY': ' \t\r\n '},
        ),
        isFalse,
      );
      expect(
        isOcrUiSmokeApiKeyPresent(
          const {'SHIROHA_OCR_API_KEY': 'fixture-value'},
        ),
        isTrue,
      );
    });

    test('structured event writer emits only allowlisted safe fields', () {
      final lines = <String>[];
      final writer = OcrUiSmokeEventWriter(lines.add);

      writer.emit(const OcrUiSmokeEvent(
        stage: 'failed',
        status: 'request_failed',
        traceId: 'trace-fixture',
        taskId: 'task-fixture',
        causeType: 'Unsafe Type fixture-secret',
        screen: 'import_review',
        questionCount: 1,
      ));

      final encoded = lines.single;
      final decoded = jsonDecode(encoded) as Map<String, dynamic>;
      expect(decoded['stage'], 'failed');
      expect(decoded['traceId'], 'trace-fixture');
      expect(decoded['causeType'], 'UnknownFailure');
      expect(encoded, isNot(contains('fixture-secret')));
      expect(encoded, isNot(contains('Authorization')));
      expect(encoded, isNot(contains('content')));
      expect(encoded, isNot(contains('standard_answer')));
      expect(encoded, isNot(contains(r'C:\')));
    });

    test('entrypoint configures isolated database before singleton access', () {
      final source = File('lib/main_ocr_ui_smoke.dart').readAsStringSync();
      final configureIndex = source.indexOf(
        'DatabaseHelper.configureRuntimeProfile(',
      );
      final engineRepositoryIndex =
          source.indexOf('AiEngineRepository.instance');
      final taskManagerIndex = source.indexOf('TaskManager.instance');

      expect(configureIndex, greaterThanOrEqualTo(0));
      expect(engineRepositoryIndex, greaterThan(configureIndex));
      expect(taskManagerIndex, greaterThan(configureIndex));
    });

    test('PowerShell launcher keeps secrets out of arguments and streams JSON',
        () {
      final source = File('tool/run_ocr_ui_smoke.ps1').readAsStringSync();

      expect(source, contains('Read-Host'));
      expect(source, contains('-AsSecureString'));
      expect(source, contains("EnvironmentVariables['SHIROHA_OCR_API_KEY']"));
      expect(source, contains('ZeroFreeBSTR'));
      expect(source, contains(r'$startInfo.CreateNoWindow = $false'));
      expect(source, contains('lib/main_ocr_ui_smoke.dart'));
      expect(source, contains('StandardOutput.ReadLine()'));
      expect(source, contains('SHIROHA_UI_SMOKE_RUNTIME_DIR'));
      expect(source, contains('Remove-Item'));
      expect(source, isNot(contains('--api-key')));
      expect(source, isNot(contains('--dart-define')));
      expect(source, isNot(contains('flutter run')));
      expect(source, isNot(contains('SetEnvironmentVariable')));
    });
  });
}

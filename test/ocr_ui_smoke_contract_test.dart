import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/data/models/ai_engine_profile.dart';
import 'package:shiroha_quiz/data/persistence/ai_engine_store.dart';
import 'package:shiroha_quiz/data/repositories/ai_engine_repository.dart';
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

    test('entrypoint explicitly composes one repository after database profile',
        () {
      final source = File('lib/main_ocr_ui_smoke.dart').readAsStringSync();
      final configureIndex = source.indexOf(
        'DatabaseHelper.configureRuntimeProfile(',
      );
      final helperIndex = source.indexOf('final databaseHelper =');
      final engineRepositoryIndex =
          source.indexOf('AiEngineRepository(store: databaseHelper)');
      final taskManagerIndex = source.indexOf('final taskManager =');

      expect(configureIndex, greaterThanOrEqualTo(0));
      expect(helperIndex, greaterThan(configureIndex));
      expect(engineRepositoryIndex, greaterThan(configureIndex));
      expect(taskManagerIndex, greaterThan(engineRepositoryIndex));
      expect(source, isNot(contains('AiEngineRepository.instance')));
    });

    test(
        'UI smoke saves and re-reads the active profile through one repository',
        () async {
      final store = _OcrUiSmokeMemoryStore();
      final repository = AiEngineRepository(store: store);
      const profile = AiEngineProfile(
        id: 'ui-smoke-profile',
        engineType: AiEngineType.ocr,
        name: 'UI Smoke Profile',
        apiKey: 'fixture-value',
        baseUrl: 'https://example.invalid',
        modelName: 'fixture-model',
        temperature: 0,
        reasoningEffort: '',
        isActive: true,
      );

      final active = await configureOcrUiSmokeEngine(
        repository: repository,
        profile: profile,
      );

      expect(active, same(profile));
      expect(store.saved, [profile]);
      expect(store.activeId, profile.id);
    });

    test('PowerShell launcher bounds build and run lifecycle safely', () {
      final source = File('tool/run_ocr_ui_smoke.ps1').readAsStringSync();

      for (final parameter in <String>[
        r'$Pdf',
        r'$Commit',
        r'$ExpectedQuestionCount',
        r'$ExpectedNumbers',
        r'$CloseOnSuccess',
        r'$SkipBuild',
        r'$BuildTimeoutSeconds',
        r'$RunTimeoutSeconds',
        r'$Interactive',
      ]) {
        expect(source, contains(parameter));
      }
      expect(source, contains(r'[int]$BuildTimeoutSeconds = 600'));
      expect(source, contains(r'[int]$RunTimeoutSeconds = 900'));

      expect(source, contains('Read-Host'));
      expect(source, contains('-AsSecureString'));
      expect(source, contains("EnvironmentVariables['SHIROHA_OCR_API_KEY']"));
      expect(source, contains('ZeroFreeBSTR'));
      expect(source, contains(r'$startInfo.CreateNoWindow = $false'));
      expect(source, contains('lib/main_ocr_ui_smoke.dart'));
      expect(source, contains('StandardOutput.ReadLineAsync()'));
      expect(source, contains('SHIROHA_UI_SMOKE_RUNTIME_DIR'));
      expect(source, contains('Remove-Item'));
      expect(source, contains("-Stage 'build' -Status 'running'"));
      expect(source, contains("-Stage 'build' -Status 'timeout'"));
      expect(source, contains("-Stage 'run' -Status 'timeout'"));
      expect(source,
          contains("\$stage -eq 'ui_ready' -and \$status -eq 'success'"));
      expect(source, contains("'quality_gate_blocked'"));
      expect(source, contains("'duplicate_question_numbers'"));
      expect(source, contains("'expected_question_count_mismatch'"));
      expect(source, contains("'unexpected_question_numbers'"));
      expect(source, contains('function Stop-OwnedProcessTree'));
      expect(source, contains('taskkill.exe'));
      expect(source, contains("'/PID'"));
      expect(source, contains("'/T'"));
      expect(source, contains(r'if (-not $Interactive -or $CloseOnSuccess)'));

      expect(
        source,
        isNot(matches(RegExp(r'^\s*&\s*flutter\s+build\b', multiLine: true))),
      );
      expect(source, isNot(contains('StandardOutput.ReadLine()')));
      expect(source, isNot(matches(RegExp(r'\.WaitForExit\(\s*\)'))));
      expect(source, isNot(contains('/IM')));
      expect(source, isNot(contains('Get-Process')));
      expect(source, isNot(contains('Stop-Process -Name')));
      expect(source, isNot(contains('--api-key')));
      expect(source, isNot(contains('--dart-define')));
      expect(source, isNot(contains('flutter run')));
      expect(source, isNot(contains('SetEnvironmentVariable')));
    });
  });
}

class _OcrUiSmokeMemoryStore implements AiEngineStore {
  final List<AiEngineProfile> saved = <AiEngineProfile>[];
  String? activeId;

  @override
  Future<List<AiEngineProfile>> listAiEngines(AiEngineType type) async {
    return saved.where((profile) => profile.engineType == type).toList();
  }

  @override
  Future<AiEngineProfile?> getActiveAiEngine(AiEngineType type) async {
    return saved
        .where(
          (profile) => profile.id == activeId && profile.engineType == type,
        )
        .firstOrNull;
  }

  @override
  Future<void> saveAiEngine(AiEngineProfile profile) async {
    saved
      ..removeWhere((existing) => existing.id == profile.id)
      ..add(profile);
  }

  @override
  Future<void> setActiveAiEngine(String id, AiEngineType type) async {
    activeId = id;
  }

  @override
  Future<void> deleteAiEngine(String id) async {
    saved.removeWhere((profile) => profile.id == id);
  }
}

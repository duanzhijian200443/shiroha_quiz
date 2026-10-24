import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/application/capabilities/capability.dart';
import 'package:shiroha_quiz/application/external/external_authorization.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/models/question_draft.dart';
import 'package:shiroha_quiz/data/persistence/engine_credential_store.dart';
import 'package:shiroha_quiz/data/repositories/external_authorization_repository.dart';
import 'package:shiroha_quiz/data/repositories/question_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import '../../tool/mcp_vnext_windows_app_smoke.dart';
import '../../tool/mcp_vnext_windows_controls_smoke.dart'
    show ControlsSmokeEvidence;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;

  for (final mode in [
    'complete',
    'body-failed',
    'cleanup-failed',
    'missing-cleanup',
    'missing-post',
    'extra-case'
  ]) {
    test('controls smoke requires complete owning evidence: $mode', () async {
      final root = await Directory.systemTemp.createTemp(smokePrefix);
      addTearDown(() => root.delete(recursive: true));
      final file = File(p.join(root.path, 'events.jsonl'));
      final evidence = ControlsSmokeEvidence(file);
      expect(evidence.passed, isFalse);
      for (var i = 0; i < (mode == 'extra-case' ? 8 : 7); i++) {
        evidence.record('case_start');
        if (mode == 'body-failed') evidence.record('case_failed');
        evidence.record('case_complete');
        if (mode == 'cleanup-failed') evidence.record('cleanup_failed');
        if (mode != 'missing-cleanup') evidence.record('cleanup_complete');
        if (mode != 'missing-post') evidence.record('post_test_complete');
      }
      expect(evidence.passed, mode == 'complete');
      expect(file.readAsStringSync(), isNot(contains(root.path)));
    });
  }

  test('isolation refuses missing, relative and unowned roots', () async {
    expect(() => smokeDataPaths(''), throwsStateError);
    expect(() => smokeDataPaths('relative'), throwsStateError);
    final root = await Directory.systemTemp.createTemp(smokePrefix);
    addTearDown(() => root.delete(recursive: true));
    expect(() => smokeDataPaths(root.path), throwsStateError);
    await File(p.join(root.path, '.smoke-owner')).writeAsString('foreign');
    expect(() => smokeDataPaths(root.path), throwsStateError);
    await File(p.join(root.path, '.smoke-owner')).writeAsString(smokeOwner);
    final paths = smokeDataPaths(root.path);
    expect(p.isWithin(root.resolveSymbolicLinksSync(), paths.databasePath),
        isTrue);
    final nested = await Directory(p.join(root.path, smokePrefix)).create();
    await File(p.join(nested.path, '.smoke-owner')).writeAsString(smokeOwner);
    expect(() => smokeDataPaths(nested.path), throwsStateError);
  });

  test('smoke credentials reject every operation without native storage',
      () async {
    final store = SmokeCredentialStore();
    final denied = throwsA(isA<EngineCredentialException>().having(
        (e) => e.failure,
        'failure',
        EngineCredentialFailure.temporarilyUnavailable));
    await expectLater(store.readCredential('synthetic'), denied);
    await expectLater(store.writeCredential('synthetic', 'unused'), denied);
    await expectLater(store.deleteCredential('synthetic'), denied);
  });

  test('smoke HTTP cannot establish a connection', () async {
    final client = SmokeHttpOverrides().createHttpClient(null);
    addTearDown(() => client.close(force: true));
    await expectLater(
        Future.sync(() => client.getUrl(Uri.parse('http://127.0.0.1:1/'))),
        throwsStateError);
  });

  test('prepare only synthetic bank and policy fixtures for the actual App',
      () async {
    const supplied = String.fromEnvironment(smokeRootDefine);
    final preserve = supplied.isNotEmpty;
    final root = preserve
        ? Directory(supplied)
        : await Directory.systemTemp.createTemp(smokePrefix);
    if (!preserve) {
      await File(p.join(root.path, '.smoke-owner')).writeAsString(smokeOwner);
      addTearDown(() => root.delete(recursive: true));
    }
    final paths = smokeDataPaths(root.path);
    // Existing data is never reseeded or adopted by the preparation command.
    expect(File(paths.databasePath).existsSync(), isFalse);
    DatabaseHelper.configureRuntimeProfile(DatabaseRuntimeProfile.explicitFile,
        databasePath: paths.databaseRoot);
    final helper = DatabaseHelper.instance;
    addTearDown(DatabaseHelper.resetRuntimeProfileForTesting);
    await QuestionRepository(databaseHelper: helper).saveQuestionDraftsToBank(
      bankName: 'MCP Smoke Bank',
      folderName: 'MCP Smoke Folder',
      questions: const [
        QuestionDraft(
          type: QuestionType.singleChoice,
          content: 'MCP smoke: 2 + 2 = ?',
          options: ['3', '4'],
          standardAnswer: 'B',
          explanation: 'Synthetic offline question. 2 + 2 = 4.',
        )
      ],
    );
    final repository =
        SqliteExternalAuthorizationRepository(databaseHelper: helper);
    final management = ExternalAuthorizationManagement(
      repository: repository,
      compositionIsCurrent: () => true,
      mintProfileId: const Uuid().v4,
    );
    for (final stage in [false, true]) {
      final ref = await management.createProfile(
          displayName: stage ? 'Smoke READ + STAGE' : 'Smoke READ',
          adapter: 'local-policy',
          protocol: 'unconfigured');
      await management.replaceGrant(
          ref,
          0,
          ExternalGrantPolicy(
            permissions: [
              CapabilityPermission.read,
              if (stage) CapabilityPermission.stage
            ],
            scopes: [
              ExternalGrantScope(
                  kind: ExternalTargetKind.bank, targetId: 'MCP Smoke Bank')
            ],
            categories: [
              ExternalContentCategory.questionContent,
              ExternalContentCategory.proposalMetadata
            ],
          ));
    }
    management.invalidate();
    expect((await repository.listProfiles()).items.length, 2);
    final db = await helper.database;
    expect((await db.query('questions')).length, 1);
    expect(await helper.getProductionDatabasePath(), paths.databasePath);
    await helper.close();
    final reopened = await helper.database;
    expect((await reopened.query('questions')).length, 1);
    expect((await repository.listProfiles()).items.length, 2);
  });
}

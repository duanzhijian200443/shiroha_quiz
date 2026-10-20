import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:shiroha_quiz/application/backup/backup_restore_coordinator.dart';
import 'package:shiroha_quiz/application/capabilities/capability.dart';
import 'package:shiroha_quiz/application/external/first_party_external_access.dart';
import 'package:shiroha_quiz/application/external/local_authorization_service.dart';
import 'package:shiroha_quiz/application/file_library/library_folder_service.dart';
import 'package:shiroha_quiz/application/projects/project_service.dart';
import 'package:shiroha_quiz/composition/mcp_vnext_app_integration.dart';
import 'package:shiroha_quiz/data/repositories/backup_database_authority.dart';
import 'package:shiroha_quiz/data/repositories/backup_snapshot_repository.dart';
import 'package:shiroha_quiz/data/repositories/library_folder_repository.dart';
import 'package:shiroha_quiz/data/repositories/project_repository.dart';
import 'package:shiroha_quiz/data/repositories/generated_proposal_repository.dart';
import 'package:shiroha_quiz/data/repositories/external_target_read_repository.dart';
import 'package:shiroha_quiz/data/repositories/external_question_read_repository.dart';
import 'package:shiroha_quiz/data/repositories/external_file_read_repository.dart';
import 'package:shiroha_quiz/domain/backup/backup_failure.dart';
import 'package:shiroha_quiz/domain/backup/backup_manifest.dart';
import 'package:shiroha_quiz/mcp/vnext_mcp_server.dart';
import 'package:shiroha_quiz/services/backup/backup_disk_space.dart';
import 'package:shiroha_quiz/services/backup/backup_restore_runtime.dart';
import 'package:shiroha_quiz/services/file_library/managed_file_storage_adapter.dart';
import 'package:shiroha_quiz/services/retrieval/deterministic_source_chunker.dart';
import 'package:shiroha_quiz/ui/pages/first_party_external_control.dart';
import '../../application/external/external_file_read_test_support.dart';
import '../../application/external/local_host_test_support.dart'
    show OfflineReadiness;
import '../../ui/generated_question/generated_ui_test_support.dart'
    show settleGenerated;

final class _Disk implements BackupDiskSpaceProbe {
  @override
  Future<int?> availableBytes(String path) async => 1 << 40;
}

final class _FailSwap extends BackupFaultInjector {
  @override
  Future<void> beforePostSwapValidation() async =>
      throw const BackupException(BackupFailure.databaseInvalid);
}

/// The exact product root, with existing isolated DB/F1/RAG owners. Only this
/// fixture supplies synthetic P0 credentials; product startup supplies none.
class FirstPartyAppHarness {
  final files = FileReadHarness();
  late LocalAuthorizationService policy;
  late McpVnextAppIntegration integration;
  VnextMcpPort? port;
  Object? attempt;
  FirstPartyExternalAccess get controls => integration.controls;
  Future<void> open({bool attach = true}) async {
    await files.open();
    files.s.clock.current = DateTime.utc(2030);
    files.s.trust.disable(files.s.principal);
    attempt = files.s.credentials.authentication;
    compose();
    if (attach) await connect();
  }

  void compose() {
    final s = files.s;
    final db = s.h.db;
    policy = LocalAuthorizationService(
        repository: s.authorization,
        profiles: s.authorization,
        files: LibraryFolderService(
            repository:
                SqliteLibraryFolderRepository(databaseHelper: s.h.helper),
            folderIdFactory: const Uuid().v4),
        projects: ProjectService(
            repository: SqliteProjectRepository(databaseHelper: s.h.helper)),
        mintProfileId: const Uuid().v4,
        compositionIsCurrent: () => db.isOpen);
    integration = McpVnextAppIntegration(
        policy: policy,
        targets: SqliteExternalTargetReadRepository(databaseHelper: s.h.helper),
        questions:
            SqliteExternalQuestionReadRepository(databaseHelper: s.h.helper),
        files: SqliteExternalFileReadRepository(databaseHelper: s.h.helper),
        authorization: s.authorization,
        proposals: s.repository,
        localAuthority: s.localFactory,
        artifacts: files.lifecycle,
        artifactMetadata: files.metadata,
        index: files.index,
        chunker: const DeterministicSourceChunker(),
        mintId: const Uuid().v4,
        compositionIsCurrent: () => db.isOpen);
  }

  Future<void> connect() async {
    port = await integration.attachTrusted(
        trust: files.s.trust,
        readiness:
            OfflineReadiness(() async => files.s.h.db.rawQuery('SELECT 1')),
        authenticationAttempt: () => attempt);
  }

  Future<void> closeDatabase() => SqliteBackupDatabaseAuthority(
          databaseHelper: files.s.h.helper, beforeClose: integration.close)
      .closeProduction();

  Future<void> enable() async {
    await controls.select(files.s.profile.profileId);
    await controls.enable(const Duration(minutes: 10));
  }

  Future<void> approve() async {
    final choices = await controls.targets();
    await controls.approveTarget(choices.firstWhere((c) =>
        c.target.bankName == 'bank' && c.target.projectId == files.project));
  }

  Future<Map<String, Object?>> call(String tool,
          [Map<String, dynamic> args = const {}]) =>
      port!.call(tool, args,
          cancelled: const Stream.empty(), available: () => true);
  Map<String, dynamic> data(Map<String, Object?> result) {
    expect(result['error'], isNull);
    return (result['data'] as Map).cast<String, dynamic>();
  }

  Future<String> context() async {
    final page = data(await call('open_generation_context'));
    final target = (page['items'] as List).first as Map;
    return data(await call('open_generation_context',
        {'targetRef': target['targetRef']}))['contextRef'] as String;
  }

  Future<Map<String, Object?>> stage(String context,
          {String key = 'first-party'}) =>
      call('propose_generated_questions', {
        'contextRef': context,
        'submission': jsonDecode(submission(key: key))
      });
  Future<void> close() async {
    await integration.close();
    policy.invalidate();
    await files.close();
  }
}

/// Registered by the standing P11 architecture shard as well as focused runs.
void registerFirstPartyAppIntegrationTests() {
  group('first-party App composition', () {
    late FirstPartyAppHarness f;
    setUp(() async {
      f = FirstPartyAppHarness();
      await f.open();
    });
    tearDown(() => f.close());

    test(
        'local select/auth/finite-enable/target-confirm/STAGE/lifecycle/disable use original owners',
        () async {
      expect((await f.controls.status()).enabled, isFalse);
      expect((await f.call('open_generation_context'))['error'], isNotNull);
      await f.enable();
      final session = await f.controls.authenticatedSession();
      expect(session, isNotNull);
      final context = await f.context();
      expect((await f.stage(context))['error'], isNotNull);
      await f.approve();
      expect(f.data(await f.stage(context))['publication'], 'STAGED');
      expect(
          f.data(await f.call('get_question_proposal',
              {'submissionKey': 'first-party'}))['lifecycleStatus'],
          'pending_review');
      expect(await f.files.s.h.count('generated_question_proposals'), 1);
      expect(await f.files.s.h.count('generated_question_commit_receipts'), 0);
      expect(await f.files.s.h.count('questions'), 0);
      expect((await f.call('commit_generated_questions'))['error'], isNotNull);
      await f.controls.disable();
      expect(session!.failure, isNotNull);
      expect(
          (await f.stage(context, key: 'after-disable'))['error'], isNotNull);
      await f.controls.enable(const Duration(minutes: 5));
      expect((await f.controls.status()).approvedTargets, 0);
      expect((await f.stage(await f.context(), key: 'after-reenable'))['error'],
          isNotNull);
    });

    test(
        'unpaired, missing authentication and missing STAGE cannot approve or submit',
        () async {
      final view = f.policy.openView();
      final unpaired = await view.create('Unpaired');
      view.close();
      await f.controls.select(unpaired.profileId);
      await expectLater(
          f.controls.enable(const Duration(minutes: 5)), throwsA(anything));
      expect((await f.controls.status()).connected, isFalse);
      await f.controls.select(f.files.s.profile.profileId);
      f.attempt = null;
      await expectLater(
          f.controls.enable(const Duration(minutes: 5)), throwsA(anything));
      f.attempt = f.files.s.credentials.authentication;
      await f.files.grant();
      final s = f.files.s;
      final revision =
          (await s.management.read(s.profile)).profile.grantRevision;
      await s.management.replaceGrant(
          s.profile,
          revision,
          s.policy(
              permissions: [CapabilityPermission.read],
              scopes: [f.files.bank]));
      await f.controls.enable(const Duration(minutes: 5));
      await expectLater(f.approve(), throwsA(anything));
      expect((await f.stage(await f.context()))['error'], isNotNull);
      expect(await s.h.count('generated_question_proposals'), 0);
    });

    test('product root uses the existing verified F1/RAG File READ path',
        () async {
      await f.enable();
      final parent = await f.context();
      final choices = f.data(
          await f.call('open_generation_context', {'contextRef': parent}));
      final selected = f.data(await f.call('open_generation_context', {
        'contextRef': parent,
        'fileRefs': [(choices['items'] as List).first['fileRef']]
      }))['contextRef'] as String;
      final hits = f.data(await f.call('retrieve_file_content',
          {'contextRef': selected, 'query': 'needle'}));
      final hit = (hits['items'] as List).single as Map;
      expect(hit['content'], 'needle file-a');
      final passage = f.data(await f.call('get_file_passage',
          {'contextRef': selected, 'passageRef': hit['passageRef']}));
      expect(passage['items'], isNotEmpty);
      expect((await f.stage(selected))['error'], isNotNull);
      expect((await f.controls.status()).approvedTargets, 0);
    });

    test(
        'database close waits for original STAGE settlement and blocks new work immediately',
        () async {
      await f.enable();
      await f.approve();
      final context = await f.context();
      final reached = Completer<void>(), release = Completer<void>();
      f.files.s.checkpoint = (point) async {
        if (point == ExternalStageCheckpoint.authorized) {
          reached.complete();
          await release.future;
        }
      };
      final pending = f.stage(context);
      await reached.future;
      final db = f.files.s.h.db;
      var closed = false;
      final closing = f.closeDatabase().then((_) => closed = true);
      await Future<void>.value();
      expect(f.controls.isCurrent, isFalse);
      expect(closed, isFalse);
      expect(db.isOpen, isTrue);
      expect((await f.call('open_generation_context'))['error'], isNotNull);
      release.complete();
      await pending;
      await closing;
      expect(db.isOpen, isFalse);
      final reopened = await f.files.s.h.helper.database;
      expect((await reopened.query('generated_question_commit_receipts')),
          isEmpty);
    });

    test(
        'expiry, disconnect and grant revoke never resurrect old Session/approval',
        () async {
      await f.enable();
      await f.approve();
      final context = await f.context();
      final session = await f.controls.authenticatedSession();
      f.files.s.clock.current =
          f.files.s.clock.now().add(const Duration(minutes: 11));
      expect((await f.stage(context))['error'], isNotNull);
      expect(session!.failure, isNotNull);
      expect((await f.controls.status()).enabled, isFalse);
      await f.controls.enable(const Duration(minutes: 5));
      await f.approve();
      f.attempt = null;
      expect((await f.call('open_generation_context'))['error'], isNotNull);
      f.attempt = f.files.s.credentials.authentication;
      expect((await f.controls.status()).enabled, isFalse);
      await f.controls.enable(const Duration(minutes: 5));
      final s = f.files.s;
      final revision =
          (await s.management.read(s.profile)).profile.grantRevision;
      await s.management.revokeGrant(s.profile, revision);
      expect((await f.call('open_generation_context'))['error'], isNotNull);
      expect((await f.controls.status()).enabled, isFalse);
      await s.management.replaceGrant(
          s.profile,
          revision + 1,
          s.policy(permissions: [
            CapabilityPermission.read,
            CapabilityPermission.stage
          ], scopes: [
            f.files.bank
          ]));
      expect(await f.controls.authenticatedSession(), isNull);
      expect((await f.stage(context))['error'], isNotNull);
    });

    test('Profile switching invalidates the original Session and approvals',
        () async {
      await f.enable();
      await f.approve();
      final session = await f.controls.authenticatedSession();
      final view = f.policy.openView();
      final other = await view.create('Another local profile');
      view.close();
      await f.controls.select(other.profileId);
      expect(session!.failure, isNotNull);
      expect((await f.controls.status()).connected, isFalse);
      await f.controls.select(f.files.s.profile.profileId);
      expect((await f.controls.status()).enabled, isFalse);
      await f.controls.enable(const Duration(minutes: 5));
      expect((await f.controls.status()).approvedTargets, 0);
      expect((await f.stage(await f.context()))['error'], isNotNull);
    });

    test('failed database close barrier preserves the live handle', () async {
      final db = f.files.s.h.db;
      final authority = SqliteBackupDatabaseAuthority(
          databaseHelper: f.files.s.h.helper,
          beforeClose: () async {
            await f.integration.close();
            throw StateError('Synthetic drain failure');
          });
      await expectLater(
          authority.closeProduction(), throwsA(isA<StateError>()));
      expect(db.isOpen, isTrue);
      expect(f.controls.isCurrent, isFalse);
    });

    test('database close racing trusted attachment awaits startup settlement',
        () async {
      await f.integration.close();
      f.compose();
      final reached = Completer<void>(), release = Completer<void>();
      final readiness = OfflineReadiness(() async {
        reached.complete();
        await release.future;
      });
      final attaching = f.integration.attachTrusted(
          trust: f.files.s.trust,
          readiness: readiness,
          authenticationAttempt: () => f.attempt);
      await reached.future;
      var closed = false;
      final closing = f.closeDatabase().then((_) => closed = true);
      await Future<void>.value();
      expect(closed, isFalse);
      expect(f.controls.isCurrent, isFalse);
      expect(f.files.s.h.db.isOpen, isTrue);
      release.complete();
      await expectLater(attaching, throwsA(anything));
      await closing;
      expect(f.files.s.h.db.isOpen, isFalse);
    });

    test(
        'port close drains the owning composition; replacement starts disabled and original key survives',
        () async {
      await f.enable();
      await f.approve();
      final context = await f.context();
      f.data(await f.stage(context));
      final oldPort = f.port!;
      final session = await f.controls.authenticatedSession();
      await oldPort.close();
      expect(session!.failure, isNotNull);
      expect(f.controls.isCurrent, isFalse);
      await f.closeDatabase();
      await f.files.s.h.reopen();
      f.compose();
      await f.connect();
      expect((await f.controls.status()).enabled, isFalse);
      expect(
          (await oldPort.call(
              'get_question_proposal', {'submissionKey': 'first-party'},
              cancelled: const Stream.empty(), available: () => true))['error'],
          isNotNull);
      await f.enable();
      expect((await f.stage(context))['error'], isNotNull);
      expect(
          f.data(await f.call('get_question_proposal',
              {'submissionKey': 'first-party'}))['lifecycleStatus'],
          'pending_review');
      expect(await f.files.s.h.count('generated_question_proposals'), 1);
    });

    for (final rollback in [false, true]) {
      test(
          'real B0 ${rollback ? 'rollback' : 'Restore'} closes the root before database swap',
          () async {
        await f.enable();
        await f.approve();
        final session = await f.controls.authenticatedSession();
        final context = await f.context();
        f.data(await f.stage(context));
        final s = f.files.s;
        final snapshots = BackupSnapshotRepository(databaseHelper: s.h.helper);
        final backup = BackupRestoreCoordinator(
            operations: BackupRestoreRuntime(
                databaseAuthority: SqliteBackupDatabaseAuthority(
                    beforeClose: f.integration.close,
                    databaseHelper: s.h.helper,
                    snapshotRepository: snapshots),
                snapshotRepository: snapshots,
                managedFileStorage:
                    ManagedFileStorageAdapter(managedRoot: f.files.managed),
                restoreRoot: Directory(p.join(s.h.temp.path, 'restore')),
                managedFilesRoot: f.files.managed,
                diskSpaceProbe: _Disk(),
                faultInjector:
                    rollback ? _FailSwap() : const BackupFaultInjector()));
        final path = p.join(s.h.temp.path, 'synthetic.zip');
        await backup.exportTo(path);
        await backup.prepareRestore(path);
        if (rollback) {
          await expectLater(
              backup.commitPreparedRestore(), throwsA(isA<BackupException>()));
        } else {
          await backup.commitPreparedRestore();
        }
        expect(f.controls.isCurrent, isFalse);
        expect(session!.failure, isNotNull);
        expect((await f.stage(context))['error'], isNotNull);
        final db = await s.h.helper.database;
        expect((await db.query('generated_question_proposals')).length, 1);
        expect((await db.query('external_client_profiles')).length,
            rollback ? 1 : 0);
      });
    }

    testWidgets(
        'trusted local controls select, finite-enable, confirm target and disable',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: FirstPartyExternalControl(access: f.controls))));
      await settleGenerated(tester);
      Future<void> tap(String text) async {
        await tester.tap(find.text(text).last);
        await settleGenerated(tester);
      }

      await tap('选择连接 Profile');
      await tap('Synthetic client');
      expect(find.text('可信连接已认证'), findsOneWidget);
      await tap('限时启用');
      expect((await tester.runAsync(f.controls.status))!.enabled, isTrue);
      await tap('确认 STAGE 目标');
      await tap('Synthetic · bank · folder');
      expect(find.text('确认草稿目标'), findsOneWidget);
      await tap('批准目标');
      expect((await tester.runAsync(f.controls.status))!.approvedTargets, 1);
      await tap('禁用访问');
      expect((await tester.runAsync(f.controls.status))!.enabled, isFalse);
      await tester.pumpWidget(const SizedBox());
    });
  });

  testWidgets(
      'dormant product controls show unavailable and cannot manufacture authentication',
      (tester) async {
    final f = FirstPartyAppHarness();
    await tester.runAsync(() => f.open(attach: false));
    addTearDown(f.close);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: FirstPartyExternalControl(access: f.controls))));
    await settleGenerated(tester);
    expect(find.textContaining('未连接 / 不可用'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '限时启用'))
            .onPressed,
        isNull);
    expect(find.text('配对不可用：尚无已准入的凭据服务'), findsOneWidget);
    expect(
        tester
            .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '请求配对'))
            .onPressed,
        isNull);
    expect((await tester.runAsync(f.controls.status))!.enabled, isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  test(
      'startup remains dormant and trusted root adds no credential or listener implementation',
      () {
    final main = File('lib/main.dart').readAsStringSync();
    expect(main, contains('McpVnextAppIntegration('));
    expect(main, isNot(contains('.attachTrusted(')));
    expect(main, isNot(contains('.attachCredentials(')));
    final root = File('lib/composition/mcp_vnext_app_integration.dart')
        .readAsStringSync();
    for (final forbidden in [
      'implements ExternalCredentialPort',
      'windows_tls',
      'windows_pairing',
      'ServerSocket',
      'Socket.connect',
      'SyntheticMailbox',
      'SyntheticCredential',
      'serveStdio'
    ]) {
      expect(root, isNot(contains(forbidden)), reason: forbidden);
    }
    for (final path in [
      'lib/ui/pages/first_party_external_control.dart',
      'lib/ui/dependencies/first_party_external_scope.dart'
    ]) {
      final source = File(path).readAsStringSync();
      for (final forbidden in [
        'data/',
        'DatabaseHelper',
        'sqflite',
        'attachTrusted',
        'installTrusted'
      ]) {
        expect(source, isNot(contains(forbidden)), reason: '$path $forbidden');
      }
    }
  });
}

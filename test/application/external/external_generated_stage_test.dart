import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/backup/backup_restore_gate.dart';
import 'package:shiroha_quiz/application/capabilities/capability.dart';
import 'package:shiroha_quiz/application/external/external_generated_stage.dart';
import 'package:shiroha_quiz/application/external/external_authorization.dart';
import 'package:shiroha_quiz/application/external/external_trust_core.dart';
import 'package:shiroha_quiz/application/external/external_invocation_core.dart';
import 'package:shiroha_quiz/application/generated_question/generated_question_service.dart';
import 'package:shiroha_quiz/data/repositories/generated_proposal_repository.dart';
import 'package:shiroha_quiz/data/repositories/generated_proposal_reader.dart';
import 'package:shiroha_quiz/core/database/generated_proposal_schema.dart';
import 'package:shiroha_quiz/domain/generated_question/generated_question_contract.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'durable_stage_test_support.dart';

void main() {
  initializeGeneratedTests();
  late DurableStageHarness s;
  setUp(() async {
    s = DurableStageHarness();
    await s.open();
  });
  tearDown(() async {
    BackupRestoreMutationGate.resetForTesting();
    await s.close();
  });
  Future<void> rows(int proposals, int items) async {
    expect(await s.h.count('generated_question_proposals'), proposals);
    expect(await s.h.count('generated_question_proposal_items'), items);
    expect(await s.h.count('generated_question_review_state'), items);
    expect(await s.h.count('generated_question_commit_receipts'), 0);
    expect(await s.h.count('questions'), 0);
  }

  void staged(ExternalStageResult r) {
    expect(r.status, CapabilityExecutionStatus.completed);
    expect(r.effect, CapabilityEffect.proposalStaged);
    expect(r.output, isNotNull);
  }

  test(
      'T1 opaque identity binding and credential proof reject forged identities',
      () async {
    expect(() => s.trust.authenticate(s.profile.profileId),
        throwsA(isA<ExternalCoreException>()));
    final other = await s.management.createProfile(
        displayName: 'Other', adapter: 'bridge', protocol: 'tcp-v1');
    await expectLater(s.service.bindIdentity(other, s.principal),
        failure(GeneratedFailure.unauthorized));
    final foreign = ExternalTrustCore(
        credentials: s.credentials,
        clock: s.clock,
        mintProfileId: () => s.profile.profileId);
    final fake = foreign.createProfile();
    await expectLater(s.service.bindIdentity(s.profile, fake),
        throwsA(isA<ExternalCoreException>()));
    foreign.requestPairing(fake,
        requestId: 'synthetic-pairing',
        credentialIdentity: 'synthetic-credential');
    foreign.approvePairing(fake);
    foreign.completePairing(fake, s.credentials.proof);
    foreign.enable(fake, const Duration(minutes: 10));
    final forged =
        foreign.openSession(foreign.authenticate(s.credentials.authentication));
    final result = await s.reconcile('external-key', authenticated: forged);
    expect(result.failure, GeneratedFailure.unauthorized);
    expect(result.output, isNull);
    await rows(0, 0);
  });

  for (final field in [
    'clientProfileId',
    'externalOrigin',
    'trusted',
    'grantRevision',
    'target',
    'permissions'
  ]) {
    test('T1 client JSON cannot declare $field', () async {
      final raw = jsonDecode(submission()) as Map<String, dynamic>;
      raw[field] = field == 'trusted' ? true : s.profile.profileId;
      final r = await s.service.stage(
          session: s.session,
          context: await s.context(),
          submissionJson: jsonEncode(raw),
          control: s.control(),
          responseAvailable: () => true);
      expect(r.failure, GeneratedFailure.invalidSubmission);
      expect(r.effect, CapabilityEffect.none);
      await rows(0, 0);
    });
  }

  test('T2 STAGE-only grant publishes trusted v34 Origin and local Review',
      () async {
    final r = await s.stage(externalRequestId: 'correlation-1');
    staged(r);
    final p = await readGeneratedProposal(s.h.db, r.output!.proposalId);
    expect(p.toJson()['schemaVersion'], 2);
    expect(p.originKind, 'external');
    expect(p.localOwner, s.localSession.localOwner);
    expect(p.clientProfileId, s.profile.profileId);
    expect(p.lifecycleStatus, GeneratedStatus.pendingReview);
    expect(p.externalOrigin!.externalRequestId, 'correlation-1');
    expect(p.externalOrigin!.authorizationSnapshot.grantRevision, 1);
    expect(p.externalOrigin!.adapterProtocol.protocol, 'tcp-v1');
    expect(p.externalOrigin!.authorizationSnapshot.egressCategories,
        ['proposalMetadata', 'questionContent']);
    expect((await s.localSession.pending()).single.proposalId, p.proposalId);
    staged(await s.reconcile('external-key'));
    await rows(1, 1);
  });

  for (final kind in [
    'read-only',
    'empty-scope',
    'missing-metadata',
    'missing-content'
  ]) {
    test('T2 $kind denies without durable writes', () async {
      await s.management.replaceGrant(
          s.profile,
          1,
          s.policy(
              permissions: kind == 'read-only'
                  ? [CapabilityPermission.read]
                  : [CapabilityPermission.stage],
              scopes: kind == 'empty-scope' ? [] : null,
              categories: kind == 'missing-metadata'
                  ? [ExternalContentCategory.questionContent]
                  : kind == 'missing-content'
                      ? [ExternalContentCategory.proposalMetadata]
                      : [
                          ExternalContentCategory.proposalMetadata,
                          ExternalContentCategory.questionContent
                        ]));
      await expectLater(s.context(), failure(GeneratedFailure.unauthorized));
      await rows(0, 0);
    });
  }

  for (final mode in ['disable', 'restart', 'expiry', 'context-expiry']) {
    test('T2 $mode invalidates old Session or Context', () async {
      final approved = await s.context();
      switch (mode) {
        case 'disable':
          s.trust.disable(s.principal);
        case 'restart':
          s.trust.restart();
        case 'expiry':
          s.clock.current = s.clock.current.add(const Duration(minutes: 31));
        case 'context-expiry':
          s.clock.current = s.clock.current.add(const Duration(minutes: 16));
      }
      final r = await s.stage(approved: approved);
      expect(r.failure, GeneratedFailure.unauthorized);
      expect(r.effect, CapabilityEffect.none);
      await rows(0, 0);
    });
  }

  test(
      'T3 real SQLite: STAGE owns transaction first; queued revoke preserves history and denies release',
      () async {
    final approved = await s.context();
    final entered = Completer<void>(), proceed = Completer<void>();
    s.checkpoint = (point) async {
      if (point == ExternalStageCheckpoint.authorized) {
        entered.complete();
        await proceed.future;
      }
    };
    final staging = s.stage(approved: approved);
    await entered.future;
    // Queued against the same database while publication transaction is open.
    final revoking = s.management.revokeGrant(s.profile, 1);
    proceed.complete();
    final r = await staging;
    await revoking;
    expect(r.effect, CapabilityEffect.proposalStaged);
    expect(r.output, isNull);
    await rows(1, 1);
    final p = await readGeneratedProposal(
        s.h.db,
        (await s.h.db.query('generated_question_proposals'))
            .single['proposal_id'] as String);
    expect(p.externalOrigin!.authorizationSnapshot.grantRevision, 1);
    expect(
        (await s.management.read(s.profile)).grant!.revokedAtUtcMs, isNotNull);
    expect((await s.reconcile('external-key')).output, isNull);
    expect((await s.localSession.pending()).single.proposalId, p.proposalId);
  });

  for (final mutation in [
    'grant-revoke',
    'profile-revoke',
    'shrink',
    'expand',
    'same-policy'
  ]) {
    test(
        'T3/T4 real SQLite: $mutation wins after admission, old revision cannot publish',
        () async {
      final approved = await s.context();
      final entered = Completer<void>(), proceed = Completer<void>();
      s.checkpoint = (point) async {
        if (point == ExternalStageCheckpoint.beforeTransaction) {
          entered.complete();
          await proceed.future;
        }
      };
      final staging = s.stage(approved: approved);
      await entered.future;
      if (mutation == 'grant-revoke') {
        await s.management.revokeGrant(s.profile, 1);
      } else if (mutation == 'profile-revoke') {
        await s.management.revokeProfile(s.profile, 1);
      } else {
        await s.management.replaceGrant(
            s.profile,
            1,
            s.policy(
                scopes: mutation == 'shrink' ? [] : null,
                permissions: mutation == 'expand'
                    ? [CapabilityPermission.read, CapabilityPermission.stage]
                    : [CapabilityPermission.stage]));
      }
      proceed.complete();
      final r = await staging;
      expect(r.status, CapabilityExecutionStatus.failedWithoutEffect);
      expect(r.effect, CapabilityEffect.none);
      expect(r.output, isNull);
      await rows(0, 0);
      expect((await s.management.read(s.profile)).profile.grantRevision, 2);
    });
  }

  test('T4 revision queued after STAGE cannot alter its historical snapshot',
      () async {
    final entered = Completer<void>(), proceed = Completer<void>();
    s.checkpoint = (point) async {
      if (point == ExternalStageCheckpoint.authorized) {
        entered.complete();
        await proceed.future;
      }
    };
    final staging = s.stage();
    await entered.future;
    final changing =
        s.management.replaceGrant(s.profile, 1, s.policy(scopes: []));
    proceed.complete();
    final r = await staging;
    await changing;
    expect(r.effect, CapabilityEffect.proposalStaged);
    expect(r.output, isNull);
    await rows(1, 1);
  });

  test(
      'T5 same semantics reuses immutable Proposal; different semantics conflicts',
      () async {
    final first = await s.stage();
    final again = await s.stage(externalRequestId: 'different-correlation');
    staged(first);
    staged(again);
    expect(first.output!.proposalId, again.output!.proposalId);
    final changed =
        await s.stage(items: [candidate(stem: 'Different semantics')]);
    expect(changed.failure, GeneratedFailure.idempotencyConflict);
    expect(changed.status, CapabilityExecutionStatus.failedWithoutEffect);
    expect(changed.effect, CapabilityEffect.none);
    await rows(1, 1);
  });

  test(
      'T6 real SQLite concurrent same Profile/key has one complete durable result',
      () async {
    final approved = await s.context();
    final firstEntered = Completer<void>(), proceed = Completer<void>();
    var transactions = 0;
    s.checkpoint = (point) async {
      if (point == ExternalStageCheckpoint.authorized && transactions++ == 0) {
        firstEntered.complete();
        await proceed.future;
      }
    };
    final first = s.stage(approved: approved);
    await firstEntered.future;
    final second = s.stage(approved: approved);
    final third = s.stage(approved: approved);
    proceed.complete();
    final results = await Future.wait([first, second, third]);
    for (final r in results) {
      staged(r);
    }
    expect(results.map((r) => r.output!.proposalId).toSet(), hasLength(1));
    await rows(1, 1);
    expect(s.service.pendingCount, 0);
  });

  for (final point in [
    ExternalStageCheckpoint.headerWritten,
    ExternalStageCheckpoint.itemsWritten,
    ExternalStageCheckpoint.beforeCommit
  ]) {
    test(
        'T7 SQLite fault at ${point.name} rolls back Header/Origin/Items/Review',
        () async {
      s.checkpoint = (current) async {
        if (point == current) {
          throw StateError('synthetic fault');
        }
      };
      final r = await s.stage();
      expect(r.status, CapabilityExecutionStatus.failedWithoutEffect);
      expect(r.effect, CapabilityEffect.none);
      expect(r.output, isNull);
      await rows(0, 0);
      s.checkpoint = null;
      staged(await s.stage());
      await rows(1, 1);
    });
  }

  test(
      'T8 file close/reopen uses fresh credential proof and original key without old Context',
      () async {
    final oldContext = await s.context();
    final oldSession = s.session;
    final stagedResult = await s.stage(approved: oldContext);
    staged(stagedResult);
    await s.reopen();
    expect(
        (await s.reconcile('external-key', authenticated: oldSession)).output,
        isNull);
    expect((await s.stage(approved: oldContext)).failure,
        GeneratedFailure.unauthorized);
    final recovered = await s.reconcile('external-key');
    staged(recovered);
    expect(recovered.output!.proposalId, stagedResult.output!.proposalId);
    expect(
        (await s.stage()).output!.proposalId, stagedResult.output!.proposalId);
    await rows(1, 1);
  });

  test(
      'T9 SQLite commit succeeds then response is lost; original key reconciles after restart',
      () async {
    s.checkpoint = (point) async {
      if (point == ExternalStageCheckpoint.afterCommit) {
        throw StateError('synthetic lost response');
      }
    };
    final unknown = await s.stage();
    expect(unknown.status, CapabilityExecutionStatus.outcomeUnknown);
    expect(unknown.effect, CapabilityEffect.proposalStaged);
    expect(unknown.output, isNull);
    await rows(1, 1);
    s.checkpoint = null;
    await s.reopen();
    final recovered = await s.reconcile('external-key');
    staged(recovered);
    expect((await s.stage()).output!.proposalId, recovered.output!.proposalId);
    await rows(1, 1);
  });

  test('T9 caller disconnect never restages or releases content', () async {
    final r = await s.stage(responseAvailable: () => false);
    expect(r.status, CapabilityExecutionStatus.outcomeUnknown);
    expect(r.interruption, ExternalFailure.responseLost);
    expect(r.effect, CapabilityEffect.proposalStaged);
    expect(r.output, isNull);
    await rows(1, 1);
    staged(await s.reconcile('external-key'));
  });

  test(
      'T9 disconnect during release is rechecked after the authorization query',
      () async {
    var available = true;
    s.checkpoint = (point) async {
      if (point == ExternalStageCheckpoint.beforeRelease) available = false;
    };
    final r = await s.stage(responseAvailable: () => available);
    expect(r.output, isNull);
    expect(r.status, CapabilityExecutionStatus.outcomeUnknown);
    expect(r.effect, CapabilityEffect.proposalStaged);
    await rows(1, 1);
  });

  test('T7 SQLite RAISE IGNORE cannot fabricate a complete stage result',
      () async {
    await s.h.db.execute(
        "CREATE TRIGGER synthetic_ignore BEFORE INSERT ON generated_question_review_state BEGIN SELECT RAISE(IGNORE); END");
    final r = await s.stage();
    expect(r.output, isNull);
    expect(r.effect, CapabilityEffect.none);
    await rows(0, 0);
  });

  test('T12 corrupt retained Origin fails closed during reconciliation',
      () async {
    final first = await s.stage();
    staged(first);
    await s.h.db.execute('DROP TRIGGER gq_original_header_immutable');
    await s.h.db
        .update('generated_question_proposals', {'external_origin_json': '{}'});
    await s.h.db.execute(
        generatedProposalSchemaObjects['gq_original_header_immutable']!);
    final r = await s.reconcile('external-key');
    expect(r.output, isNull);
    expect(r.failure, GeneratedFailure.corruptState);
    expect(r.effect, isNull);
    await rows(1, 1);
  });

  test(
      'T12 scope admission precedes child content decoding; hidden and absent keys are indistinguishable',
      () async {
    staged(await s.stage());
    await s.h.db
        .insert('bank_folders', {'bank_name': 'other', 'folder_name': 'other'});
    await s.management.replaceGrant(
        s.profile,
        1,
        s.policy(scopes: [
          ExternalGrantScope(kind: ExternalTargetKind.bank, targetId: 'other')
        ]));
    // Malformed working content in a protected target must not be decoded by
    // a caller whose current grant no longer includes that target.
    await s.h.db
        .update('generated_question_review_state', {'working_json': '{}'});
    for (final key in ['external-key', 'absent']) {
      final r = await s.reconcile(key);
      expect(r.output, isNull);
      expect(r.failure, isNull);
      expect(r.status, CapabilityExecutionStatus.outcomeUnknown);
      expect(r.effect, isNull);
    }
  });

  test('T10 cancel before handler proves not_started/none with zero rows',
      () async {
    final approved = await s.context();
    final control = s.control()..cancel();
    var entered = false;
    s.checkpoint = (point) async {
      entered = true;
    };
    final r = await s.stage(approved: approved, call: control);
    expect(r.status, CapabilityExecutionStatus.notStarted);
    expect(r.effect, CapabilityEffect.none);
    expect(entered, isFalse);
    await rows(0, 0);
  });

  for (final interrupt in ['cancel', 'deadline']) {
    test(
        'T10 $interrupt after transaction entry stays unknown and holds capacity until settlement',
        () async {
      // A one-slot service makes premature capacity release observable.
      s.service.close();
      await s.service.whenIdle;
      s.service = ExternalGeneratedStageService(
          trust: s.trust,
          management: s.management,
          localOwner: s.localSession,
          persistence: s.repository,
          admission: GeneratedQuestionAdmission(
              idFactory: () => '99999999-9999-4999-8999-999999999999'),
          maxInFlight: 1);
      await s.service.bindIdentity(s.profile, s.principal);
      final approved = await s.context();
      final entered = Completer<void>(), proceed = Completer<void>();
      s.checkpoint = (point) async {
        if (point == ExternalStageCheckpoint.authorized) {
          entered.complete();
          await proceed.future;
        }
      };
      final control = ExternalCallControl(
          clock: s.clock,
          deadline: s.clock.current.add(const Duration(seconds: 1)));
      final staging = s.stage(approved: approved, call: control);
      await entered.future;
      if (interrupt == 'cancel') {
        control.cancel();
      } else {
        s.clock.current = s.clock.current.add(const Duration(seconds: 2));
        control.checkDeadline();
      }
      final r = await staging;
      expect(r.status, CapabilityExecutionStatus.outcomeUnknown);
      expect(r.effect, isNull);
      expect(s.service.pendingCount, 1);
      expect((await s.stage(approved: approved, key: 'other')).failure,
          GeneratedFailure.resourceLimit);
      proceed.complete();
      await s.service.whenIdle;
      expect(s.service.pendingCount, 0);
      await rows(1, 1);
      staged(await s.reconcile('external-key'));
    });
  }

  test(
      'T10 cancelled while queued before owning transaction settles with zero rows',
      () async {
    final entered = Completer<void>(), proceed = Completer<void>();
    s.checkpoint = (point) async {
      if (point == ExternalStageCheckpoint.beforeTransaction) {
        entered.complete();
        await proceed.future;
      }
    };
    final control = s.control();
    final staging = s.stage(call: control);
    await entered.future;
    control.cancel();
    expect((await staging).status, CapabilityExecutionStatus.outcomeUnknown);
    proceed.complete();
    await s.service.whenIdle;
    await rows(0, 0);
  });

  test(
      'T12 reconcile absence remains unknown; another Profile cannot enumerate a key',
      () async {
    final first = await s.stage();
    staged(first);
    final absent = await s.reconcile('absent');
    expect(absent.status, CapabilityExecutionStatus.outcomeUnknown);
    expect(absent.effect, isNull);
    expect(absent.output, isNull);
    final other = await s.management.createProfile(
        displayName: 'Other', adapter: 'bridge', protocol: 'tcp-v1');
    await s.management.replaceGrant(other, 0, s.policy());
    s.nextProfile = other.profileId;
    final principal = s.trust.createProfile();
    await s.service.bindIdentity(other, principal);
    // A second controlled credential port requires another trust composition;
    // without pairing/proof there is no business Session at all.
    expect(() => s.trust.openSession(s.trust.authenticate(Object())),
        throwsA(isA<ExternalCoreException>()));
    expect((await s.reconcile(other.profileId)).output, isNull);
    await rows(1, 1);
  });

  test(
      'T12 revoke during reconciliation denies output but preserves local history',
      () async {
    staged(await s.stage());
    var revoked = false;
    s.checkpoint = (point) async {
      if (point == ExternalStageCheckpoint.beforeRelease && !revoked) {
        revoked = true;
        await s.management.revokeGrant(s.profile, 1);
      }
    };
    final r = await s.reconcile('external-key');
    expect(r.output, isNull);
    expect(r.effect, CapabilityEffect.proposalStaged);
    await rows(1, 1);
  });

  test(
      'T11 target folder drift refuses publication without substituting targets',
      () async {
    final approved = await s.context();
    await s.h.db.update('bank_folders', {'folder_name': 'changed'},
        where: 'bank_name=?', whereArgs: ['bank']);
    final r = await s.stage(approved: approved);
    expect(r.output, isNull);
    expect(r.effect, CapabilityEffect.none);
    await rows(0, 0);
  });

  test(
      'durable branch pending guard drains failures and never accumulates historical keys',
      () async {
    for (var i = 0; i < 70; i++) {
      final r = await s
          .stage(key: 'history-$i', items: [candidate(stem: 'Candidate $i')]);
      staged(r);
      expect(s.service.pendingCount, 0);
    }
    staged(await s.reconcile('history-0'));
    s.checkpoint = (point) async {
      if (point == ExternalStageCheckpoint.headerWritten) {
        throw StateError('fault');
      }
    };
    for (var i = 0; i < 70; i++) {
      expect((await s.stage(key: 'failed-$i')).effect, CapabilityEffect.none);
      expect(s.service.pendingCount, 0);
    }
    await rows(70, 70);
  });

  test('Application dependency direction and unpublished adapter boundary', () {
    final file = File('lib/application/external/external_generated_stage.dart')
        .readAsStringSync();
    final imports = RegExp(r'''(?:import|export)\s+['"]([^'"]+)['"]''')
        .allMatches(file)
        .map((m) => m[1]!);
    for (final forbidden in [
      'sqflite',
      'database_helper',
      '/data/',
      'flutter',
      'mcp_dart',
      'dart:io'
    ]) {
      expect(imports.any((p) => p.contains(forbidden)), isFalse);
    }
    for (final path in [
      'lib/main.dart',
      'lib/mcp/study_mcp_server.dart',
      'lib/application/modules/generated_question_module.dart'
    ]) {
      expect(File(path).readAsStringSync(),
          isNot(contains('external_generated_stage')));
    }
  });

  for (final drift in [
    'none',
    'artifact',
    'revision',
    'digest',
    'file',
    'project-file',
    'project-bank',
    'file-grant'
  ]) {
    test('T11 trusted File/Artifact/Project evidence: $drift', () async {
      final digest = List.filled(64, 'b').join();
      const source = '11111111-1111-4111-8111-111111111111';
      await s.h.db.insert('library_files', {
        'file_id': 'file',
        'display_name': 'Synthetic.txt',
        'mime_type': 'text/plain',
        'storage_key': 'file/source',
        'size_bytes': 0,
        'sha256': digest,
        'created_at': 1000
      });
      await s.h.db.insert(
          'parsed_artifact_heads', {'file_id': 'file', 'last_revision': 1});
      await s.h.db.insert('parsed_artifacts', {
        'file_id': 'file',
        'artifact_id': source,
        'revision': 1,
        'source_sha256': digest,
        'cache_key_version': 1,
        'cache_fingerprint': 'synthetic',
        'parser_route': 'synthetic',
        'parser_version': '1',
        'options_schema_version': 1,
        'payload_schema_version': 1,
        'storage_key': 'artifact/file',
        'payload_sha256': digest,
        'size_bytes': 0,
        'published_at': 1000
      });
      await s.h.db.insert('projects', {
        'project_id': 'project',
        'display_name': 'Project',
        'created_at': 1000
      });
      await s.h.db.insert(
          'project_banks', {'project_id': 'project', 'bank_name': 'bank'});
      await s.h.db.insert(
          'project_files', {'project_id': 'project', 'file_id': 'file'});
      s.h.target = GeneratedTarget(
          bankName: 'bank',
          folderName: 'folder',
          projectId: 'project',
          projectBankNames: const ['bank']);
      final policy = s.policy(scopes: [
        s.bank,
        ExternalGrantScope(
            kind: ExternalTargetKind.file,
            targetId: 'file',
            projectId: 'project')
      ], categories: ExternalContentCategory.values);
      await s.management.replaceGrant(s.profile, 1, policy);
      final evidence = GeneratedEvidence(
          evidenceKey: 'evidence',
          sourceRef: SourceRef.document(sourceId: source),
          fileId: 'file',
          artifactRevision: 1,
          artifactDigest: digest);
      final approved = await s.context(evidence: [evidence]);
      // Drift after preflight admission, immediately before the owning write.
      s.checkpoint = (point) async {
        if (point != ExternalStageCheckpoint.beforeTransaction) return;
        switch (drift) {
          case 'artifact':
            await s.h.db.update('parsed_artifacts',
                {'artifact_id': '22222222-2222-4222-8222-222222222222'});
          case 'revision':
            await s.h.db.update('parsed_artifacts', {'revision': 2});
          case 'digest':
            await s.h.db.update('parsed_artifacts',
                {'payload_sha256': List.filled(64, 'c').join()});
          case 'file':
            await s.h.db.delete('library_files',
                where: 'file_id=?', whereArgs: ['file']);
          case 'project-file':
            await s.h.db.delete('project_files');
          case 'project-bank':
            await s.h.db.delete('project_banks');
          case 'file-grant':
            await s.management
                .replaceGrant(s.profile, 2, s.policy(scopes: [s.bank]));
        }
      };
      final r = await s.stage(approved: approved, items: [
        candidate(evidence: ['evidence'])
      ]);
      if (drift == 'none') {
        staged(r);
        await rows(1, 1);
        final p = await readGeneratedProposal(s.h.db, r.output!.proposalId);
        expect(p.externalOrigin!.authorizationSnapshot.authorizedFileIds,
            ['file']);
        expect(p.items.single.evidence.single.artifactDigest, digest);
      } else {
        expect(r.output, isNull);
        expect(r.effect, CapabilityEffect.none);
        await rows(0, 0);
      }
    });
  }

  test(
      'T12 independently paired second Profile sees no acknowledgement for another Profile key',
      () async {
    final first = await s.stage();
    staged(first);
    final profile = await s.management.createProfile(
        displayName: 'Other', adapter: 'bridge', protocol: 'tcp-v1');
    await s.management.replaceGrant(profile, 0, s.policy());
    final credentials = StageCredentials();
    final trust = ExternalTrustCore(
        credentials: credentials,
        clock: s.clock,
        mintProfileId: () => profile.profileId);
    final principal = trust.createProfile();
    final service = ExternalGeneratedStageService(
        trust: trust,
        management: s.management,
        localOwner: s.localSession,
        persistence: s.repository,
        admission: GeneratedQuestionAdmission(
            idFactory: () => '99999999-9999-4999-8999-999999999999'));
    await service.bindIdentity(profile, principal);
    trust.requestPairing(principal,
        requestId: 'synthetic-pairing',
        credentialIdentity: 'synthetic-credential');
    trust.approvePairing(principal);
    trust.completePairing(principal, credentials.proof);
    trust.enable(principal, const Duration(minutes: 10));
    final session =
        trust.openSession(trust.authenticate(credentials.authentication));
    final approved = await s.context();
    expect(
        (await s.service.stage(
                session: session,
                context: approved,
                submissionJson: submission(),
                control: s.control(),
                responseAvailable: () => true))
            .failure,
        GeneratedFailure.unauthorized);
    for (final key in ['external-key', 'absent']) {
      final r = await service.reconcile(
          session: session,
          submissionKey: key,
          control: s.control(),
          responseAvailable: () => true);
      expect(r.status, CapabilityExecutionStatus.outcomeUnknown);
      expect(r.effect, isNull);
      expect(r.output, isNull);
    }
    service.close();
    await service.whenIdle;
    await rows(1, 1);
  });
}

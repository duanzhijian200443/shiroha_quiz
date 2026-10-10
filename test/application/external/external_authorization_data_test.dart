import 'package:uuid/uuid.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shiroha_quiz/application/backup/backup_restore_gate.dart';
import 'package:shiroha_quiz/application/capabilities/capability.dart';
import 'package:shiroha_quiz/application/external/external_authorization.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/core/database/external_authorization_schema.dart';
import 'package:shiroha_quiz/data/repositories/external_authorization_repository.dart';
import '../generated_question/generated_test_support.dart';
import '../generated_question/external_origin_test_support.dart'
    show installLegacyGeneratedHeaderFixture;
import 'package:shiroha_quiz/core/database/generated_proposal_schema.dart';

Matcher authFailure(ExternalAuthFailure f) => throwsA(
    isA<ExternalAuthException>().having((e) => e.failure, 'fixed failure', f));

void main() {
  initializeGeneratedTests();
  late GeneratedHarness h;
  late ExternalAuthorizationManagement management;
  late SqliteExternalAuthorizationRepository repository;
  late ExternalProfileReference ref;
  late ExternalGrantScope bank;
  bool current = true;
  setUp(() async {
    current = true;
    h = GeneratedHarness();
    await h.open();
    repository =
        SqliteExternalAuthorizationRepository(databaseHelper: h.helper);
    management = ExternalAuthorizationManagement(
        mintProfileId: const Uuid().v4,
        repository: repository,
        compositionIsCurrent: () => current,
        clock: () => DateTime.utc(2026));
    ref = await management.createProfile(
        displayName: 'Client', adapter: 'bridge', protocol: 'tcp-v1');
    bank = ExternalGrantScope(kind: ExternalTargetKind.bank, targetId: 'bank');
  });
  tearDown(() async {
    BackupRestoreMutationGate.resetForTesting();
    await h.close();
  });
  ExternalGrantPolicy policy(
          {List<CapabilityPermission> permissions = const [
            CapabilityPermission.read
          ],
          List<ExternalGrantScope>? scopes,
          Set<ExternalContentCategory> categories = const {
            ExternalContentCategory.questionContent
          }}) =>
      ExternalGrantPolicy(
          permissions: permissions,
          scopes: scopes ?? [bank],
          categories: categories);
  Future<ExternalGrant> inspect(
          {ExternalProfileReference? profile,
          int revision = 1,
          CapabilityPermission permission = CapabilityPermission.read,
          ExternalGrantScope? scope,
          ExternalContentCategory category =
              ExternalContentCategory.questionContent,
          String? recipient}) =>
      management.inspectGrant(profile ?? ref,
          expectedRevision: revision,
          permission: permission,
          scope: scope ?? bank,
          category: category,
          recipientProfileId: recipient ?? (profile ?? ref).profileId);

  test('App mints identity, metadata is non-secret, creation grants no access',
      () async {
    expect(ExternalAuthLimits.validId(ref.profileId), isTrue);
    final stored = (await h.db.query('external_client_profiles')).single;
    expect(stored.keys.toSet(), {
      'profile_id',
      'display_name',
      'adapter',
      'protocol',
      'created_at',
      'revoked_at',
      'grant_revision'
    });
    expect(stored['grant_revision'], 0);
    expect((await management.read(ref)).grant, isNull);
    expect(await h.db.query('external_grants'), isEmpty);
    await expectLater(
        inspect(revision: 0), authFailure(ExternalAuthFailure.unauthorized));
    final second = await management.createProfile(
        displayName: 'Client', adapter: 'bridge', protocol: 'tcp-v1');
    expect(second.profileId, isNot(ref.profileId));
    await expectLater(management.selectProfile('client-claimed-id'),
        authFailure(ExternalAuthFailure.unauthorized));
  });
  for (final permission in [
    CapabilityPermission.commit,
    CapabilityPermission.destructive
  ]) {
    test('Grant rejects ${permission.name} without writing', () async {
      expect(() => policy(permissions: [permission]),
          authFailure(ExternalAuthFailure.invalidInput));
      expect(await h.db.query('external_grants'), isEmpty);
      await management.replaceGrant(ref, 0, policy());
      await expectLater(inspect(permission: permission),
          authFailure(ExternalAuthFailure.unauthorized));
    });
  }
  test('READ/STAGE exact scope and recipient/category checks survive reopen',
      () async {
    await management.replaceGrant(
        ref,
        0,
        policy(permissions: [
          CapabilityPermission.read,
          CapabilityPermission.stage
        ]));
    await h.reopen();
    expect((await inspect()).revision, 1);
    expect((await inspect(permission: CapabilityPermission.stage)).revision, 1);
    await expectLater(
        inspect(
            scope: ExternalGrantScope(
                kind: ExternalTargetKind.bank, targetId: 'missing')),
        authFailure(ExternalAuthFailure.unauthorized));
    await expectLater(inspect(category: ExternalContentCategory.fileContent),
        authFailure(ExternalAuthFailure.unauthorized));
    final other = await management.createProfile(
        displayName: 'Other', adapter: 'bridge', protocol: 'tcp-v1');
    await expectLater(inspect(recipient: other.profileId),
        authFailure(ExternalAuthFailure.unauthorized));
    await expectLater(
        inspect(profile: other), authFailure(ExternalAuthFailure.unauthorized));
    final another = ExternalAuthorizationManagement(
        mintProfileId: const Uuid().v4,
        repository: repository,
        compositionIsCurrent: () => true);
    await expectLater(
        another.read(ref), authFailure(ExternalAuthFailure.unauthorized));
  });
  test('CAS contenders on real SQLite have one winner; stale write rolls back',
      () async {
    final results = await Future.wait([
      policy(),
      policy(permissions: [CapabilityPermission.stage])
    ].map((p) async {
      try {
        await management.replaceGrant(ref, 0, p);
        return 'winner';
      } on ExternalAuthException catch (e) {
        return e.failure.name;
      }
    }));
    expect(results.where((r) => r == 'winner'), hasLength(1));
    expect(results.where((r) => r == 'staleRevision'), hasLength(1));
    final before = await h.db.query('external_grants');
    await expectLater(management.replaceGrant(ref, 0, policy(scopes: [])),
        authFailure(ExternalAuthFailure.staleRevision));
    expect(await h.db.query('external_grants'), before);
    expect((await management.read(ref)).profile.grantRevision, 1);
  });
  test('shrink increments revision and empty scopes never become global',
      () async {
    await management.replaceGrant(ref, 0, policy());
    await management.replaceGrant(ref, 1, policy(scopes: []));
    await expectLater(
        inspect(revision: 1), authFailure(ExternalAuthFailure.unauthorized));
    await expectLater(
        inspect(revision: 2), authFailure(ExternalAuthFailure.unauthorized));
    expect(await h.db.query('external_grant_scopes'), isEmpty);
    expect((await h.db.query('external_grants')).single['revision'], 2);
  });
  test('Grant and Profile revoke prevent old snapshots restoring access',
      () async {
    await management.replaceGrant(ref, 0, policy());
    final snapshot = await inspect();
    await management.revokeGrant(ref, 1);
    expect(snapshot.revokedAtUtcMs, isNull);
    await expectLater(
        inspect(revision: 2), authFailure(ExternalAuthFailure.unauthorized));
    await management.replaceGrant(ref, 2, policy());
    await management.revokeProfile(ref, 3);
    await expectLater(
        inspect(revision: 4), authFailure(ExternalAuthFailure.unauthorized));
    await expectLater(management.replaceGrant(ref, 4, policy()),
        authFailure(ExternalAuthFailure.unauthorized));
    await h.reopen();
    final record = await management.read(ref);
    expect(record.profile.grantRevision, 4);
    expect(record.profile.revokedAtUtcMs, isNotNull);
    expect(record.grant!.revokedAtUtcMs, record.profile.revokedAtUtcMs);
  });
  test('never-granted Profile can be revoked without inventing a Grant',
      () async {
    await management.revokeProfile(ref, 0);
    await h.reopen();
    expect((await management.read(ref)).grant, isNull);
  });
  test(
      'Learning Space and file relation must exist, deletion denies without fallback',
      () async {
    await h.db.insert('projects',
        {'project_id': 'space', 'display_name': 'Space', 'created_at': 0});
    final scoped = ExternalGrantScope(
        kind: ExternalTargetKind.bank, targetId: 'bank', projectId: 'space');
    await expectLater(management.replaceGrant(ref, 0, policy(scopes: [scoped])),
        authFailure(ExternalAuthFailure.unauthorized));
    await h.db
        .insert('project_banks', {'project_id': 'space', 'bank_name': 'bank'});
    await h.db.insert('library_files', {
      'file_id': 'file',
      'display_name': 'Synthetic',
      'mime_type': 'text/plain',
      'size_bytes': 0,
      'sha256': '0' * 64,
      'storage_key': 'synthetic',
      'created_at': 0
    });
    await h.db
        .insert('project_files', {'project_id': 'space', 'file_id': 'file'});
    final file = ExternalGrantScope(
        kind: ExternalTargetKind.file, targetId: 'file', projectId: 'space');
    await management.replaceGrant(
        ref,
        0,
        policy(
            scopes: [scoped, file],
            categories: ExternalContentCategory.values.toSet()));
    await inspect(scope: scoped);
    await inspect(scope: file, category: ExternalContentCategory.fileContent);
    await expectLater(inspect(), authFailure(ExternalAuthFailure.unauthorized));
    await h.db.delete('projects', where: 'project_id=?', whereArgs: ['space']);
    await expectLater(
        inspect(scope: scoped), authFailure(ExternalAuthFailure.unauthorized));
    await expectLater(
        inspect(scope: file, category: ExternalContentCategory.fileContent),
        authFailure(ExternalAuthFailure.unauthorized));
  });
  test('management invalidation inside a transaction rolls back', () async {
    var calls = 0;
    await expectLater(
        repository.change(ref.profileId, 0, policy(),
            DateTime.utc(2026).millisecondsSinceEpoch, false, () {
          if (++calls == 2) externalAuthFail(ExternalAuthFailure.unauthorized);
        }),
        authFailure(ExternalAuthFailure.unauthorized));
    expect(
        (await h.db.query('external_client_profiles')).single['grant_revision'],
        0);
    expect(await h.db.query('external_grants'), isEmpty);
    current = false;
    await expectLater(
        management.read(ref), authFailure(ExternalAuthFailure.unauthorized));
  });
  test('B0 maintenance blocks durable management and policy inspection',
      () async {
    await management.replaceGrant(ref, 0, policy());
    BackupRestoreMutationGate.instance.tryEnterQuiescence();
    await expectLater(inspect(), throwsA(isA<Exception>()));
    await expectLater(
        management.revokeGrant(ref, 1), throwsA(isA<Exception>()));
    expect((await h.db.query('external_grants')).single['revision'], 1);
  });
  for (final defect in [
    'permission',
    'category',
    'scope',
    'revision',
    'metadata',
    'schema'
  ]) {
    test(
        'corrupt $defect rejected on current read, staged validation and reopen',
        () async {
      await management.replaceGrant(ref, 0, policy());
      await h.db.execute('PRAGMA ignore_check_constraints=ON');
      switch (defect) {
        case 'permission':
          await h.db.update('external_grants', {'allow_read': 2});
        case 'category':
          await h.db.update('external_grant_egress', {'category': 'commit'});
        case 'scope':
          await h.db.update('external_grant_scopes', {'target_kind': 'all'});
        case 'revision':
          await h.db.update('external_grants', {'updated_at': -1});
        case 'metadata':
          await h.db
              .execute('DROP TRIGGER external_profile_identity_immutable');
          await h.db.execute('DROP TRIGGER external_profile_revision_guard');
          await h.db
              .update('external_client_profiles', {'adapter': 'Bad Adapter'});
          await h.db.execute(externalAuthorizationSchemaObjects[
              'external_profile_identity_immutable']!);
          await h.db.execute(externalAuthorizationSchemaObjects[
              'external_profile_revision_guard']!);
        case 'schema':
          await h.db
              .execute('ALTER TABLE external_grants ADD COLUMN unsafe TEXT');
      }
      await h.db.execute('PRAGMA ignore_check_constraints=OFF');
      await expectLater(
          inspect(), authFailure(ExternalAuthFailure.corruptState));
      await expectLater(DatabaseHelper.validateStagedBackupSchema(h.db),
          authFailure(ExternalAuthFailure.corruptState));
      await h.helper.close();
      await expectLater(
          h.helper.database, authFailure(ExternalAuthFailure.corruptState));
    });
  }
  test('schema CHECK/FK/immutable guards reject invalid durable writes',
      () async {
    await management.replaceGrant(ref, 0, policy());
    for (final row in [
      {'allow_read': 2},
      {'allow_read': 0, 'allow_stage': 0},
      {'revision': 9}
    ]) {
      await expectLater(h.db.update('external_grants', row),
          throwsA(isA<DatabaseException>()));
    }
    await expectLater(
        h.db.update('external_client_profiles', {'display_name': 'Forged'}),
        throwsA(isA<DatabaseException>()));
    await expectLater(
        h.db.insert('external_grant_egress',
            {'profile_id': ref.profileId, 'category': 'destructive'}),
        throwsA(isA<DatabaseException>()));
    await expectLater(
        h.db.insert('external_grant_egress',
            {'profile_id': 'missing', 'category': 'fileContent'}),
        throwsA(isA<DatabaseException>()));
    expect(await h.db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
  });
  test(
      'v32 upgrade preserves old data/unrelated schema; Origin migrates to v34',
      () async {
    final proposal = await h.decide(await h.stage());
    await h.service.approve(h.approval(proposal), h.local);
    final original = await h.repository.read(proposal.proposalId, h.local);
    final questions = await h.db.query('questions');
    final sidecars = await h.db.query('question_v2_payloads');
    await installLegacyGeneratedHeaderFixture(h.db);
    for (final table in externalAuthorizationTables.reversed) {
      await h.db.delete(table);
      await h.db.execute('DROP TABLE $table');
    }
    final oldRows = await h.db.query('bank_folders');
    final oldSchema = await h.db.rawQuery(
        "SELECT name,sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'");
    await h.db.setVersion(32);
    await h.reopen();
    expect(await h.db.getVersion(), 34);
    expect(await h.db.query('bank_folders'), oldRows);
    expect((await h.repository.read(proposal.proposalId, h.local)).toJson(),
        original.toJson());
    expect(await h.db.query('questions'), questions);
    expect(await h.db.query('question_v2_payloads'), sidecars);
    final newSchema = await h.db.rawQuery(
        "SELECT name,sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'");
    for (final row in oldSchema) {
      final actual = newSchema.where((r) => r['name'] == row['name']).single;
      if (['generated_question_proposals', 'gq_original_header_immutable']
          .contains(row['name'])) {
        expect(
            actual['sql'],
            generatedProposalSchemaObjects[row['name']]!
                .trim()
                .replaceFirst(RegExp(r';\s*$'), ''));
      } else {
        expect(actual, row);
      }
    }
    for (final table in externalAuthorizationTables) {
      expect(await h.db.query(table), isEmpty);
    }
    await DatabaseHelper.validateStagedBackupSchema(h.db);
  });
  test(
      'failed older-version migration preserves version and rows without adoption',
      () async {
    final path = DatabaseHelper.openedDatabasePathForTesting!;
    await h.db.setVersion(32);
    await h.helper.close();
    await expectLater(
        h.helper.database, authFailure(ExternalAuthFailure.corruptState));
    final probe = await databaseFactory.openDatabase(path);
    expect(await probe.getVersion(), 32);
    expect((await probe.query('external_client_profiles')).single['profile_id'],
        ref.profileId);
    await probe.close();
  });
  test(
      'malformed names, protocols, scopes and resource overflow reject before writes',
      () {
    for (final name in ['', 'a' * 81, ' private ', 'bad\nname']) {
      expect(
          () => ExternalClientProfile(
              clientProfileId: ref.profileId,
              displayName: name,
              adapter: 'bridge',
              protocol: 'tcp-v1',
              createdAtUtcMs: 0,
              grantRevision: 0),
          authFailure(ExternalAuthFailure.invalidInput));
    }
    expect(
        () => policy(
            scopes: List.generate(
                129,
                (i) => ExternalGrantScope(
                    kind: ExternalTargetKind.bank, targetId: 'bank$i'))),
        authFailure(ExternalAuthFailure.invalidInput));
    expect(() => policy(scopes: [bank, bank]),
        authFailure(ExternalAuthFailure.invalidInput));
  });
}

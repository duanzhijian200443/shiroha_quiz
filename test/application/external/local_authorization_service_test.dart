import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/backup/backup_restore_gate.dart';
import 'package:shiroha_quiz/application/capabilities/capability.dart';
import 'package:shiroha_quiz/application/external/external_authorization.dart';
import 'package:shiroha_quiz/application/external/local_authorization_service.dart';
import 'external_authorization_data_test.dart' show authFailure;
import 'local_authorization_test_support.dart';

void main() {
  initializeGeneratedTests();
  late LocalAuthorizationHarness fixture;
  late LocalAuthorizationView view;
  setUp(() async {
    fixture = LocalAuthorizationHarness();
    await fixture.open();
    view = fixture.service.openView();
  });
  tearDown(() async {
    BackupRestoreMutationGate.resetForTesting();
    view.close();
    await fixture.close();
  });

  Future<ExternalAuthorizationRecord> save(
          ExternalProfileReference ref, int revision,
          {List<LocalAuthorizationTarget> targets = const [],
          List<CapabilityPermission> permissions = const [
            CapabilityPermission.read
          ],
          List<ExternalContentCategory> categories = const []}) =>
      view.save(ref, revision,
          permissions: permissions, targets: targets, categories: categories);

  test('App-generated Profile is non-secret, revision zero and has no Grant',
      () async {
    final ref = await view.create('Synthetic client');
    final record = await view.read(ref);
    expect(ExternalAuthLimits.validId(ref.profileId), isTrue);
    expect(record.profile.grantRevision, 0);
    expect(record.grant, isNull);
    expect(record.profile.protocol, 'unconfigured');
    expect((await view.profiles()).items.single.clientProfileId, ref.profileId);
  });
  test(
      'precise multi-bank/file/Project roundtrip; Permission and Egress independent',
      () async {
    final ref = await view.create('Synthetic');
    final targets = await view.targets();
    expect(targets, hasLength(6));
    final selected = targets
        .where((t) => t.scope.targetId != 'file1' || t.scope.projectId != null)
        .toList();
    final first = await save(ref, 0,
        targets: selected,
        permissions: [CapabilityPermission.read, CapabilityPermission.stage]);
    expect(first.grant!.policy.categories, isEmpty);
    expect(first.grant!.policy.scopes.toSet(),
        selected.map((t) => t.scope).toSet());
    await save(ref, 1,
        targets: selected,
        permissions: [CapabilityPermission.stage],
        categories: ExternalContentCategory.values);
    // A new management composition reads persisted policy after real reopen.
    await fixture.h.reopen();
    fixture.compose();
    final fresh = fixture.service.openView();
    final record = await fresh.read(await fresh.select(ref.profileId));
    expect(record.profile.grantRevision, 2);
    expect(record.grant!.policy.permissions, {CapabilityPermission.stage});
    expect(record.grant!.policy.categories,
        ExternalContentCategory.values.toSet());
    expect(record.grant!.policy.scopes.toSet(),
        selected.map((t) => t.scope).toSet());
    fresh.close();
  });
  test('empty Scope and Egress remain empty; forbidden permissions reject',
      () async {
    final ref = await view.create('Synthetic');
    final record = await save(ref, 0);
    expect(record.grant!.policy.scopes, isEmpty);
    expect(record.grant!.policy.categories, isEmpty);
    for (final permission in [
      CapabilityPermission.commit,
      CapabilityPermission.destructive
    ]) {
      await expectLater(save(ref, 1, permissions: [permission]),
          authFailure(ExternalAuthFailure.invalidInput));
    }
    expect((await view.read(ref)).profile.grantRevision, 1);
  });
  test(
      'two management views CAS one winner; references and choices cannot be borrowed',
      () async {
    final ref = await view.create('Synthetic');
    final second = fixture.service.openView();
    final otherRef = await second.select(ref.profileId);
    final winners = await Future.wait([
      save(ref, 0)
          .then((_) => 'winner')
          .catchError((Object e) => (e as ExternalAuthException).failure.name),
      second
          .save(otherRef, 0,
              permissions: [CapabilityPermission.stage],
              targets: [],
              categories: [])
          .then((_) => 'winner')
          .catchError((Object e) => (e as ExternalAuthException).failure.name),
    ]);
    expect(winners.toSet(), {'winner', 'staleRevision'});
    await expectLater(
        second.read(ref), authFailure(ExternalAuthFailure.unauthorized));
    await expectLater(
        second.save(otherRef, 1,
            permissions: [CapabilityPermission.read],
            targets: await view.targets(),
            categories: []),
        authFailure(ExternalAuthFailure.unauthorized));
    final unrelated = await view.create('Other');
    await save(unrelated, 0);
    expect((await view.read(ref)).profile.grantRevision, 1);
    second.close();
  });
  test('Grant revoke advances revision; Profile revoke cannot be reactivated',
      () async {
    final ref = await view.create('Synthetic');
    await save(ref, 0);
    final revoked = await view.revokeGrant(ref, 1);
    expect(revoked.profile.grantRevision, 2);
    expect(revoked.grant!.revokedAtUtcMs, isNotNull);
    await save(ref, 2);
    final profile = await view.revokeProfile(ref, 3);
    expect(profile.profile.grantRevision, 4);
    await expectLater(
        save(ref, 4), authFailure(ExternalAuthFailure.unauthorized));
    expect((await view.profiles()).items.single.revokedAtUtcMs, isNotNull);
  });
  test(
      'detached/deleted target rejects stale selection in existing transaction',
      () async {
    final ref = await view.create('Synthetic');
    final targets = await view.targets();
    final scoped = targets.where((t) => t.scope.projectId != null).toList();
    await fixture.h.db.delete('project_files');
    await expectLater(save(ref, 0, targets: scoped),
        authFailure(ExternalAuthFailure.unauthorized));
    expect((await view.read(ref)).grant, isNull);
    await fixture.h.db
        .delete('library_files', where: 'file_id=?', whereArgs: ['file2']);
    await expectLater(
        save(ref, 0,
            targets:
                targets.where((t) => t.scope.targetId == 'file2').toList()),
        authFailure(ExternalAuthFailure.unauthorized));
    expect((await view.read(ref)).profile.grantRevision, 0);
  });
  test(
      'pagination is bounded, ordered, disjoint; invalid cursors safely reject',
      () async {
    for (var i = 0; i < 53; i++) {
      await view.create('Synthetic $i');
    }
    final first = await view.profiles();
    final second = await view.profiles(afterId: first.nextId);
    expect(first.items, hasLength(50));
    expect(second.items, hasLength(3));
    expect(second.nextId, isNull);
    expect({
      ...first.items.map((p) => p.clientProfileId),
      ...second.items.map((p) => p.clientProfileId)
    }, hasLength(53));
    await expectLater(view.profiles(afterId: 'invalid'),
        authFailure(ExternalAuthFailure.invalidInput));
    await expectLater(fixture.repository.listProfiles(limit: 51),
        authFailure(ExternalAuthFailure.invalidInput));
  });
  test('B0 gate, closed database and replacement deny old management writes',
      () async {
    final ref = await view.create('Synthetic');
    await BackupRestoreMutationGate.instance.enterQuiescence();
    await expectLater(
        save(ref, 0), authFailure(ExternalAuthFailure.unauthorized));
    BackupRestoreMutationGate.instance.exitQuiescence();
    await fixture.h.reopen();
    await expectLater(
        save(ref, 0), authFailure(ExternalAuthFailure.unauthorized));
    fixture.compose();
    final replacement = fixture.service.openView();
    expect(
        (await replacement.read(await replacement.select(ref.profileId))).grant,
        isNull);
    replacement.close();
  });
  test('closed page refuses delayed releases; corrupt policy fails closed',
      () async {
    await view.create('Synthetic');
    fixture.query.pause = Completer<void>();
    final pending = view.profiles();
    final rejected =
        expectLater(pending, authFailure(ExternalAuthFailure.unauthorized));
    view.close();
    fixture.query.pause!.complete();
    await rejected;
    final fresh = fixture.service.openView();
    final ref = await fresh
        .select((await fresh.profiles()).items.single.clientProfileId);
    await fresh.save(ref, 0,
        permissions: [CapabilityPermission.read], targets: [], categories: []);
    await fixture.h.db.execute('PRAGMA ignore_check_constraints=ON');
    await fixture.h.db.execute("UPDATE external_grants SET allow_read=2");
    await fixture.h.db.execute('PRAGMA ignore_check_constraints=OFF');
    await expectLater(
        fresh.profiles(), authFailure(ExternalAuthFailure.corruptState));
    fresh.close();
  });
}

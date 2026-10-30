import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shiroha_quiz/application/capabilities/capability.dart';
import 'package:shiroha_quiz/application/external/external_authorization.dart';
import 'package:shiroha_quiz/core/database/external_access_v35_schema.dart';
import 'package:shiroha_quiz/data/repositories/external_authorization_repository.dart';
import 'external_authorization_data_test.dart' show authFailure;
import 'local_authorization_test_support.dart';

void main() {
  initializeGeneratedTests();
  late LocalAuthorizationHarness f;
  setUp(() async {
    f = LocalAuthorizationHarness();
    await f.open();
  });
  tearDown(() async => f.close());
  test('all content and review default persist, direct opt-in survives reopen',
      () async {
    final view = f.service.openView();
    final ref = await view.create('Synthetic');
    final saved = await view.saveAllContent(ref, 0, directWrite: false);
    expect(saved.grant!.policy.allContent, isTrue);
    expect(saved.grant!.policy.scopes, isEmpty);
    expect(saved.grant!.policy.generationMode, ExternalGenerationMode.review);
    await view.saveAllContent(ref, 1, directWrite: true);
    await expectLater(view.saveAllContent(ref, 1, directWrite: false),
        authFailure(ExternalAuthFailure.staleRevision));
    view.close();
    await f.h.reopen();
    f.compose();
    final reopened = f.service.openView();
    final persisted = await reopened.read(await reopened.select(ref.profileId));
    expect(
        persisted.grant!.policy.generationMode, ExternalGenerationMode.direct);
    expect(persisted.profile.grantRevision, 2);
    reopened.close();
  });
  test(
      'all-content allows future targets beyond old scope cap but checks existence and Project membership',
      () async {
    final view = f.service.openView();
    final ref = await view.create('All');
    await view.saveAllContent(ref, 0, directWrite: false);
    for (var i = 0; i < 130; i++) {
      await f.h.db.insert(
          'bank_folders', {'bank_name': 'future-$i', 'folder_name': 'folder'});
    }
    Future<void> inspect(String id, {String? project}) async {
      await requireExternalGrant(
          f.h.db,
          ref.profileId,
          1,
          CapabilityPermission.read,
          ExternalGrantScope(
              kind: ExternalTargetKind.bank, targetId: id, projectId: project),
          ExternalContentCategory.questionContent,
          ref.profileId);
    }

    await inspect('future-129');
    await expectLater(
        inspect('missing'), authFailure(ExternalAuthFailure.unauthorized));
    await expectLater(inspect('future-129', project: 'space'),
        authFailure(ExternalAuthFailure.unauthorized));
    await view.revokeGrant(ref, 1);
    await expectLater(
        inspect('future-129'), authFailure(ExternalAuthFailure.unauthorized));
    view.close();
  });
  test(
      'actual v34 migration preserves exact old grant and never widens an empty scope',
      () async {
    final view = f.service.openView();
    final ref = await view.create('Legacy');
    await view.save(ref, 0,
        permissions: [CapabilityPermission.read], targets: [], categories: []);
    final before = await f.h.db.query('external_grants');
    await f.h.db.execute('DROP TABLE external_access_preferences');
    await f.h.db.setVersion(34);
    view.close();
    await f.h.reopen();
    f.compose();
    expect(await f.h.db.getVersion(), 36);
    expect(await f.h.db.query('external_grants'), before);
    expect(await f.h.db.query(externalAccessPreferencesTable), isEmpty);
    final record = await f.repository.read(ref.profileId);
    expect(record.grant!.policy.allContent, isFalse);
    expect(record.grant!.policy.scopes, isEmpty);
    expect(record.grant!.policy.generationMode, ExternalGenerationMode.confirm);
  });
  test('corrupt saved policy refuses reads rather than widening access',
      () async {
    final view = f.service.openView();
    final ref = await view.create('Corrupt');
    await view.saveAllContent(ref, 0, directWrite: false);
    await f.h.db.execute('PRAGMA ignore_check_constraints=ON');
    await f.h.db.execute(
        "UPDATE external_access_preferences SET generation_mode='unknown'");
    await f.h.db.execute('PRAGMA ignore_check_constraints=OFF');
    await expectLater(
        view.read(ref), authFailure(ExternalAuthFailure.corruptState));
    view.close();
  });
}

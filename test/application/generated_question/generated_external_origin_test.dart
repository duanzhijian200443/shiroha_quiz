import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shiroha_quiz/application/generated_question/generated_question_service.dart';
import 'package:shiroha_quiz/application/external/external_authorization.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/core/database/generated_proposal_schema.dart';
import 'package:shiroha_quiz/domain/generated_question/generated_question_contract.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/data/repositories/external_authorization_repository.dart';
import 'external_origin_test_support.dart';

void main() {
  initializeGeneratedTests();
  late GeneratedHarness h;
  setUp(() async {
    h = GeneratedHarness();
    await h.open();
  });
  tearDown(() async => h.close());
  test(
      'external history roundtrips as v2; header is the only identity/key/target source',
      () async {
    final p = await insertExternalHistory(h);
    expect(p.toJson()['schemaVersion'], 2);
    expect(GeneratedQuestionProposal.fromJson(p.toJson()).toJson(), p.toJson());
    final origin = p.externalOrigin!;
    expect(origin.clientProfileId, p.clientProfileId);
    expect(origin.submissionKey, p.submissionKey);
    expect(origin.authorizationSnapshot.originalTarget.toJson(),
        p.originalTarget.toJson());
    expect(origin.authorizationSnapshot.recipientProfileId, p.clientProfileId);
    expect(origin.toPersistedPayload().containsKey('clientProfileId'), isFalse);
    await h.reopen();
    expect(
        (await h.repository.read(p.proposalId, h.local)).toJson(), p.toJson());
    expect(await h.db.query('external_client_profiles'), isEmpty);
  });
  for (final kind in ['local', 'synthetic']) {
    test('$kind remains exact v1 without invented external metadata', () async {
      final context = GeneratedOriginContext(
          localOwner: 'owner',
          originKind: kind,
          clientProfileId: 'internal',
          target: h.target,
          evidence: const [],
          isCurrent: () => true);
      final p = (await h.service.stage(submission(), context)).proposal;
      expect(p.externalOrigin, isNull);
      expect(p.toJson()['schemaVersion'], 1);
      expect(p.toJson().containsKey('externalOrigin'), isFalse);
      expect(
          GeneratedQuestionProposal.fromJson(p.toJson()).toJson(), p.toJson());
      await h.reopen();
      expect((await h.repository.read(p.proposalId, h.local)).toJson(),
          p.toJson());
    });
  }
  test('caller-asserted external context and RPC authority fields cannot STAGE',
      () async {
    final context = GeneratedOriginContext(
        localOwner: 'owner',
        originKind: 'external',
        clientProfileId: externalFixtureProfile,
        target: h.target,
        evidence: const [],
        isCurrent: () => true);
    expect(() => h.service.stage(submission(), context),
        failure(GeneratedFailure.unauthorized));
    for (final field in [
      'originKind',
      'clientProfileId',
      'grant',
      'scope',
      'target',
      'externalOrigin',
      'trusted'
    ]) {
      final input = jsonDecode(submission()) as Map<String, dynamic>;
      input[field] =
          field == 'externalOrigin' ? externalPayload() : 'external-claim';
      expect(() => h.service.stage(jsonEncode(input), h.origin()),
          failure(GeneratedFailure.invalidSubmission));
    }
    expect(await h.count('generated_question_proposals'), 0);
    expect(await h.count('questions'), 0);
  });
  test('existing external key cannot be reused through local/synthetic STAGE',
      () async {
    final p = await insertExternalHistory(h);
    final context = h.origin(profile: p.clientProfileId);
    await expectLater(
        h.service.stage(
            submission(
                key: p.submissionKey,
                items: [candidate(stem: 'External synthetic history')]),
            context),
        failure(GeneratedFailure.unauthorized));
    expect(await h.count('generated_question_proposals'), 1);
  });
  for (final defect in [
    'uuid',
    'unknown-origin',
    'missing-payload',
    'legacy-external',
    'v2-local',
    'v1-payload',
    'payload-version',
    'payload-bytes',
    'request-id',
    'request-null-absent',
    'adapter',
    'revision',
    'permission',
    'unknown-field',
    'scope-field',
    'categories',
    'unsorted-files',
    'too-many-files'
  ]) {
    test('strict persisted origin rejects $defect', () async {
      final p = await insertExternalHistory(h);
      final value = jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>;
      final payload = value['externalOrigin'] as Map<String, dynamic>;
      final auth = payload['authorizationSnapshot'] as Map<String, dynamic>;
      switch (defect) {
        case 'uuid':
          value['clientProfileId'] = 'claimed';
        case 'unknown-origin':
          value['originKind'] = 'other';
        case 'missing-payload':
          value.remove('externalOrigin');
        case 'legacy-external':
          value['schemaVersion'] = 1;
          value.remove('externalOrigin');
        case 'v2-local':
          value['originKind'] = 'local';
        case 'v1-payload':
          value['schemaVersion'] = 1;
          value['originKind'] = 'synthetic';
        case 'payload-version':
          payload['schemaVersion'] = 1.0;
        case 'payload-bytes':
          payload['padding'] = 'x' * GeneratedLimits.externalOriginBytes;
        case 'request-id':
          payload['externalRequestId'] = 'r' * 129;
        case 'request-null-absent':
          payload.remove('externalRequestId');
        case 'adapter':
          (payload['adapterProtocol'] as Map)['protocol'] = 'raw secret\n';
        case 'revision':
          auth['grantRevision'] = 0;
        case 'permission':
          auth['permission'] = 'commit';
        case 'unknown-field':
          payload['credential'] = 'synthetic';
        case 'scope-field':
          auth['target'] = {'bankName': 'other'};
        case 'categories':
          auth['egressCategories'] = ['unknown'];
        case 'unsorted-files':
          auth['authorizedFileIds'] = ['z', 'a'];
        case 'too-many-files':
          auth['authorizedFileIds'] = List.generate(129, (i) => 'f$i');
      }
      expect(() => GeneratedQuestionProposal.fromJson(value),
          throwsA(isA<GeneratedQuestionException>()));
    });
  }
  test(
      'optional request null is explicit and never affects semantic fingerprint',
      () async {
    final p = await insertExternalHistory(h);
    final value = p.toJson();
    (value['externalOrigin'] as Map)['externalRequestId'] = null;
    final other = GeneratedQuestionProposal.fromJson(value);
    expect(other.externalOrigin!.externalRequestId, isNull);
    expect(other.semanticFingerprint, p.semanticFingerprint);
    expect(other.submissionKey, p.submissionKey);
  });
  test(
      'historical evidence must match file scope without current source existence',
      () async {
    final p = await insertExternalHistory(h, authorizedFileIds: [
      'historical-file'
    ], evidence: [
      GeneratedEvidence(
          evidenceKey: 'evidence',
          sourceRef: SourceRef.document(sourceId: externalFixtureProfile),
          fileId: 'historical-file',
          artifactRevision: 1,
          artifactDigest: 'a' * 64)
    ]);
    expect(await h.db.query('library_files'), isEmpty);
    expect(GeneratedQuestionProposal.fromJson(p.toJson()).toJson(), p.toJson());
    final value = p.toJson();
    ((value['externalOrigin'] as Map)['authorizationSnapshot']
        as Map)['authorizedFileIds'] = [];
    expect(() => GeneratedQuestionProposal.fromJson(value),
        failure(GeneratedFailure.corruptState));
  });
  test(
      'local Review rebind changes current target, never original Origin scope',
      () async {
    var p = await insertExternalHistory(h);
    final original = p.originalTarget.toJson();
    await h.db.insert('bank_folders',
        {'bank_name': 'other-bank', 'folder_name': 'other-folder'});
    h.target = GeneratedTarget(
        bankName: 'other-bank',
        folderName: 'other-folder',
        projectId: null,
        projectBankNames: const []);
    p = await h.flush(p, [
      {'type': 'rebind', 'target': h.target.toJson()}
    ]);
    expect(p.target.bankName, 'other-bank');
    expect(p.originalTarget.toJson(), original);
    expect(p.externalOrigin!.authorizationSnapshot.originalTarget.toJson(),
        original);
    p = await h.decide(p);
    await h.service.approve(h.approval(p), h.local);
    expect((await h.db.query('questions')).single['bank_name'], 'other-bank');
    expect(
        (await h.repository.read(p.proposalId, h.local))
            .externalOrigin!
            .originalTarget
            .toJson(),
        original);
  });
  test('revoke/missing Profile does not affect history or local Review/COMMIT',
      () async {
    final repository =
        SqliteExternalAuthorizationRepository(databaseHelper: h.helper);
    final profile = ExternalClientProfile(
        clientProfileId: externalFixtureProfile,
        displayName: 'Synthetic',
        adapter: 'bridge',
        protocol: 'tcp-v1',
        createdAtUtcMs: 0,
        grantRevision: 0);
    await repository.create(profile, () {});
    var p = await insertExternalHistory(h);
    await repository.change(profile.clientProfileId, 0, null, 1, true, () {});
    expect(
        (await h.repository.pending(h.local)).single.externalOrigin, isNotNull);
    final original = generatedCanonical(p.toJson()['externalOrigin']);
    p = await h.decide(p);
    expect(generatedCanonical(p.toJson()['externalOrigin']), original);
    final receipt = await h.service.approve(h.approval(p), h.local);
    expect(receipt.itemMappings, hasLength(1));
    expect(await h.count('questions'), 1);
    await h.reopen();
    p = await h.repository.read(p.proposalId, h.local);
    expect(p.commitReceipt!.toJson(), receipt.toJson());
    expect(generatedCanonical(p.toJson()['externalOrigin']), original);
  });
  for (final defect in [
    'payload',
    'duplicate-json',
    'field-combination',
    'extra-table',
    'missing-trigger'
  ]) {
    test('live persisted $defect fails read/open/schema validation', () async {
      final p = await insertExternalHistory(h);
      switch (defect) {
        case 'payload':
        case 'duplicate-json':
        case 'field-combination':
          await h.db.execute('DROP TRIGGER gq_original_header_immutable');
          await h.db.execute('PRAGMA ignore_check_constraints=ON');
          await h.db.update(
              'generated_question_proposals',
              defect == 'field-combination'
                  ? {'origin_kind': 'synthetic'}
                  : {
                      'external_origin_json': defect == 'payload'
                          ? '{}'
                          : '{"schemaVersion":1,"schemaVersion":1}'
                    },
              where: 'proposal_id=?',
              whereArgs: [p.proposalId]);
          await h.db.execute('PRAGMA ignore_check_constraints=OFF');
          await h.db.execute(
              generatedProposalSchemaObjects['gq_original_header_immutable']!);
          await expectLater(h.repository.read(p.proposalId, h.local),
              failure(GeneratedFailure.corruptState));
        case 'extra-table':
          await h.db
              .execute('CREATE TABLE generated_question_unowned (x TEXT)');
        case 'missing-trigger':
          await h.db.execute('DROP TRIGGER gq_original_header_immutable');
      }
      await expectLater(DatabaseHelper.validateStagedBackupSchema(h.db),
          failure(GeneratedFailure.corruptState));
      await h.helper.close();
      await expectLater(
          h.helper.database, failure(GeneratedFailure.corruptState));
    });
  }
  test('origin/immutable originals and terminal state remain guarded by SQLite',
      () async {
    var p = await insertExternalHistory(h);
    for (final row in [
      {'external_origin_json': '{}'},
      {'origin_kind': 'synthetic'},
      {'original_target_json': '{}'}
    ]) {
      await expectLater(
          h.db.update('generated_question_proposals', row,
              where: 'proposal_id=?', whereArgs: [p.proposalId]),
          throwsA(isA<DatabaseException>()));
    }
    await expectLater(
        h.db.update(
            'generated_question_proposal_items', {'original_json': '{}'}),
        throwsA(isA<DatabaseException>()));
    p = await h.decide(p);
    await h.service.approve(h.approval(p), h.local);
    await expectLater(
        h.db.update(
            'generated_question_review_state', {'decision': 'unreviewed'}),
        throwsA(isA<DatabaseException>()));
    await expectLater(
        h.db.update('generated_question_proposals', {'review_revision': 99}),
        throwsA(isA<DatabaseException>()));
    expect(await h.db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
  });
}

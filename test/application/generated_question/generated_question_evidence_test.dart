import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/domain/generated_question/generated_question_contract.dart';
import 'generated_test_support.dart';

void main() {
  initializeGeneratedTests();
  late GeneratedHarness h;
  const sourceId = '11111111-1111-4111-8111-111111111111';
  String digest(String char) => List.filled(64, char).join();
  GeneratedEvidence evidence(
          {String source = sourceId,
          String file = 'file',
          String char = 'b'}) =>
      GeneratedEvidence(
          evidenceKey: 'evidence',
          sourceRef: SourceRef.document(sourceId: source),
          fileId: file,
          artifactRevision: 1,
          artifactDigest: digest(char));
  Future<void> addSource(
      String file, String artifact, String fileChar, String payloadChar) async {
    await h.db.insert('library_files', {
      'file_id': file,
      'display_name': 'Synthetic $file.txt',
      'mime_type': 'text/plain',
      'storage_key': '$file/source',
      'size_bytes': 0,
      'sha256': digest(fileChar),
      'created_at': 1000
    });
    await h.db
        .insert('parsed_artifact_heads', {'file_id': file, 'last_revision': 1});
    await h.db.insert('parsed_artifacts', {
      'file_id': file,
      'artifact_id': artifact,
      'revision': 1,
      'source_sha256': digest(fileChar),
      'cache_key_version': 1,
      'cache_fingerprint': 'synthetic',
      'parser_route': 'synthetic',
      'parser_version': '1',
      'options_schema_version': 1,
      'payload_schema_version': 1,
      'storage_key': 'artifact/$file',
      'payload_sha256': digest(payloadChar),
      'size_bytes': 0,
      'published_at': 1000
    });
  }

  setUp(() async {
    h = GeneratedHarness();
    await h.open();
    await addSource('file', sourceId, 'a', 'b');
  });
  tearDown(() async => h.close());
  test(
      'trusted current source resolves, different valid provenance conflicts even with unchanged content',
      () async {
    const secondSource = '22222222-2222-4222-8222-222222222222';
    await addSource('file2', secondSource, 'c', 'd');
    final p = await h.stage(items: [
      candidate(evidence: ['evidence'])
    ], evidence: [
      evidence()
    ]);
    expect(p.items.single.evidence.single.sourceRef.sourceId, sourceId);
    await expectLater(
        h.stage(items: [
          candidate(evidence: ['evidence'])
        ], evidence: [
          evidence(source: secondSource, file: 'file2', char: 'd')
        ]),
        failure(GeneratedFailure.idempotencyConflict));
    expect(await h.count('generated_question_proposals'), 1);
  });
  test(
      'reparse requires exact revision acknowledgement and subsequent change blocks again',
      () async {
    var p = await h.decide(await h.stage(items: [
      candidate(evidence: ['evidence'])
    ], evidence: [
      evidence()
    ]));
    await h.db.update(
        'parsed_artifacts', {'revision': 2, 'payload_sha256': digest('c')},
        where: 'file_id=?', whereArgs: ['file']);
    await expectLater(h.service.approve(h.approval(p), h.local),
        failure(GeneratedFailure.staleEvidence));
    final state = await h.repository
        .evidenceState(p.proposalId, p.items.single.itemId, h.local);
    expect((state.single as Map)['status'], 'stale');
    p = await h.flush(p, [
      {
        'type': 'acknowledge',
        'itemId': p.items.single.itemId,
        'evidenceState': state
      }
    ]);
    await h.db.update(
        'parsed_artifacts', {'revision': 3, 'payload_sha256': digest('d')},
        where: 'file_id=?', whereArgs: ['file']);
    await expectLater(h.service.approve(h.approval(p), h.local),
        failure(GeneratedFailure.staleEvidence));
    final next = await h.repository
        .evidenceState(p.proposalId, p.items.single.itemId, h.local);
    p = await h.flush(p, [
      {
        'type': 'acknowledge',
        'itemId': p.items.single.itemId,
        'evidenceState': next
      }
    ]);
    await h.service.approve(h.approval(p), h.local);
    expect(await h.count('questions'), 1);
  });
  test(
      'deleted evidence keeps original readable and requires local unavailable acknowledgement',
      () async {
    var p = await h.decide(await h.stage(items: [
      candidate(evidence: ['evidence'])
    ], evidence: [
      evidence()
    ]));
    final original = p.items.single.original;
    await h.db.delete('library_files', where: 'file_id=?', whereArgs: ['file']);
    await h.reopen();
    expect(
        (await h.repository.read(p.proposalId, h.local)).items.single.original,
        original);
    await expectLater(h.service.approve(h.approval(p), h.local),
        failure(GeneratedFailure.staleEvidence));
    final state = await h.repository
        .evidenceState(p.proposalId, p.items.single.itemId, h.local);
    expect((state.single as Map)['status'], 'unavailable');
    p = await h.flush(p, [
      {
        'type': 'acknowledge',
        'itemId': p.items.single.itemId,
        'evidenceState': state
      }
    ]);
    await h.service.approve(h.approval(p), h.local);
    expect(await h.count('questions'), 1);
  });
  test(
      'stale evidence cannot authorize a new stage and client source injection rejects whole batch',
      () async {
    await h.db.delete('library_files', where: 'file_id=?', whereArgs: ['file']);
    await expectLater(
        h.stage(items: [
          candidate(evidence: ['evidence'])
        ], evidence: [
          evidence()
        ]),
        failure(GeneratedFailure.invalidEvidence));
    final injected = candidate();
    injected['sourceId'] = sourceId;
    await expectLater(
        () => h.service.stage(submission(items: [injected]), h.origin()),
        throwsA(isA<GeneratedQuestionException>()));
    expect(await h.count('generated_question_proposals'), 0);
  });

  test('context evidence aliases do not change real provenance semantics',
      () async {
    final first = await h.stage(items: [
      candidate(evidence: ['evidence'])
    ], evidence: [
      evidence()
    ]);
    final alias = GeneratedEvidence(
        evidenceKey: 'new_alias',
        sourceRef: evidence().sourceRef,
        fileId: 'file',
        artifactRevision: 1,
        artifactDigest: digest('b'));
    final retry = await h.stage(items: [
      candidate(evidence: ['new_alias'])
    ], evidence: [
      alias
    ]);
    expect(retry.proposalId, first.proposalId);
    expect(await h.count('generated_question_proposals'), 1);
  });

  test('a source claim bound to a different artifact identity stages zero rows',
      () async {
    const otherIdentity = '33333333-3333-4333-8333-333333333333';
    await expectLater(
        h.stage(items: [
          candidate(evidence: ['evidence'])
        ], evidence: [
          evidence(source: otherIdentity)
        ]),
        failure(GeneratedFailure.invalidEvidence));
    expect(await h.count('generated_question_proposals'), 0);
    expect(await h.count('generated_question_proposal_items'), 0);
    expect(await h.count('questions'), 0);
  });

  test(
      'replaced artifact identity marks staged provenance unavailable until explicitly acknowledged',
      () async {
    var p = await h.decide(await h.stage(items: [
      candidate(evidence: ['evidence'])
    ], evidence: [
      evidence()
    ]));
    await h.db.update('parsed_artifacts',
        {'artifact_id': '44444444-4444-4444-8444-444444444444'},
        where: 'file_id=?', whereArgs: ['file']);
    await expectLater(h.service.approve(h.approval(p), h.local),
        failure(GeneratedFailure.staleEvidence));
    expect(await h.count('questions'), 0);
    final state = await h.repository
        .evidenceState(p.proposalId, p.items.single.itemId, h.local);
    expect((state.single as Map)['status'], 'unavailable');
    expect((state.single as Map)['currentRevision'], isNull);
    expect((state.single as Map)['currentDigest'], isNull);
    p = await h.flush(p, [
      {
        'type': 'acknowledge',
        'itemId': p.items.single.itemId,
        'evidenceState': state
      }
    ]);
    await h.service.approve(h.approval(p), h.local);
    expect(await h.count('questions'), 1);
  });

  test(
      'Project file scope gates staged provenance and re-link or explicit acknowledgement restores approval',
      () async {
    await h.db.insert('projects', {
      'project_id': 'project',
      'display_name': 'Project',
      'created_at': 1000
    });
    await h.db.insert(
        'project_banks', {'project_id': 'project', 'bank_name': 'bank'});
    await h.db
        .insert('project_files', {'project_id': 'project', 'file_id': 'file'});
    h.target = GeneratedTarget(
        bankName: 'bank',
        folderName: 'folder',
        projectId: 'project',
        projectBankNames: const ['bank']);
    final first = await h.decide(await h.stage(items: [
      candidate(evidence: ['evidence'])
    ], evidence: [
      evidence()
    ]));
    await h.db
        .delete('project_files', where: 'project_id=?', whereArgs: ['project']);
    await expectLater(h.service.approve(h.approval(first), h.local),
        failure(GeneratedFailure.staleEvidence));
    expect(await h.count('questions'), 0);
    final unbound = await h.repository
        .evidenceState(first.proposalId, first.items.single.itemId, h.local);
    expect((unbound.single as Map)['status'], 'unavailable');
    expect((unbound.single as Map)['currentRevision'], isNull);
    await h.db
        .insert('project_files', {'project_id': 'project', 'file_id': 'file'});
    expect(
        ((await h.repository.evidenceState(
                first.proposalId, first.items.single.itemId, h.local))
            .single as Map)['status'],
        'authorized');
    await h.service.approve(h.approval(first), h.local);
    expect(await h.count('questions'), 1);

    var second = await h.decide(await h.stage(key: 'unbound', items: [
      candidate(stem: 'Other stem', evidence: ['evidence'])
    ], evidence: [
      evidence()
    ]));
    await h.db
        .delete('project_files', where: 'project_id=?', whereArgs: ['project']);
    final acknowledged = await h.repository
        .evidenceState(second.proposalId, second.items.single.itemId, h.local);
    expect((acknowledged.single as Map)['status'], 'unavailable');
    await expectLater(h.service.approve(h.approval(second), h.local),
        failure(GeneratedFailure.staleEvidence));
    second = await h.flush(second, [
      {
        'type': 'acknowledge',
        'itemId': second.items.single.itemId,
        'evidenceState': acknowledged
      }
    ]);
    await h.service.approve(h.approval(second), h.local);
    expect(await h.count('questions'), 2);
  });
}

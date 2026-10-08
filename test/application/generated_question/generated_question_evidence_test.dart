import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/domain/generated_question/generated_question_contract.dart';
import 'generated_test_support.dart';

void main() {
  initializeGeneratedTests();
  late GeneratedHarness h;
  const sourceId = '11111111-1111-4111-8111-111111111111';
  String digest(String char) => List.filled(64, char).join();
  GeneratedEvidence evidence({String source = sourceId}) => GeneratedEvidence(
      evidenceKey: 'evidence',
      sourceRef: SourceRef.document(sourceId: source),
      fileId: 'file',
      artifactRevision: 1,
      artifactDigest: digest('b'));
  setUp(() async {
    h = GeneratedHarness();
    await h.open();
    await h.db.insert('library_files', {
      'file_id': 'file',
      'display_name': 'Synthetic.txt',
      'mime_type': 'text/plain',
      'storage_key': 'file/source',
      'size_bytes': 0,
      'sha256': digest('a'),
      'created_at': 1000
    });
    await h.db.insert(
        'parsed_artifact_heads', {'file_id': 'file', 'last_revision': 1});
    await h.db.insert('parsed_artifacts', {
      'file_id': 'file',
      'artifact_id': sourceId,
      'revision': 1,
      'source_sha256': digest('a'),
      'cache_key_version': 1,
      'cache_fingerprint': 'synthetic',
      'parser_route': 'synthetic',
      'parser_version': '1',
      'options_schema_version': 1,
      'payload_schema_version': 1,
      'storage_key': 'artifact/source',
      'payload_sha256': digest('b'),
      'size_bytes': 0,
      'published_at': 1000
    });
  });
  tearDown(() async => h.close());
  test(
      'trusted current source resolves, different provenance conflicts even with unchanged content',
      () async {
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
          evidence(source: '22222222-2222-4222-8222-222222222222')
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
}

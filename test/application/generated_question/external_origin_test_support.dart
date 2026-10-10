import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';
import 'package:shiroha_quiz/application/generated_question/generated_question_service.dart';
import 'package:shiroha_quiz/core/database/generated_proposal_v32_schema.dart';
import 'package:shiroha_quiz/data/repositories/generated_proposal_reader.dart';
import 'package:shiroha_quiz/domain/generated_question/generated_question_contract.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2_codec.dart';
import 'generated_test_support.dart';

export 'generated_test_support.dart';

const externalFixtureProfile = '11111111-1111-4111-8111-111111111111';

Map<String, Object?> externalPayload() => {
      'schemaVersion': 1,
      'externalRequestId': 'request-1',
      'adapterProtocol': {'adapter': 'bridge', 'protocol': 'tcp-v1'},
      'authorizationSnapshot': {
        'grantRevision': 1,
        'permission': 'stage',
        'authorizedFileIds': <String>[],
        'egressCategories': ['proposalMetadata', 'questionContent']
      }
    };

/// Historical synthetic DB fixture only; no external Application STAGE factory.
Future<GeneratedQuestionProposal> insertExternalHistory(GeneratedHarness h,
    {String profile = externalFixtureProfile,
    String key = 'external',
    String owner = 'owner',
    String stem = 'External synthetic history',
    List<GeneratedEvidence> evidence = const [],
    List<String> authorizedFileIds = const []}) async {
  final input = GeneratedQuestionAdmission(idFactory: const Uuid().v4).admit(
      submission(key: key, items: [
        candidate(
            stem: stem, evidence: evidence.map((e) => e.evidenceKey).toList())
      ]),
      h.origin(evidence: evidence));
  final payload = externalPayload();
  (payload['authorizationSnapshot'] as Map)['authorizedFileIds'] =
      authorizedFileIds;
  final now = DateTime.utc(2026).millisecondsSinceEpoch;
  final p = GeneratedQuestionProposal.fromJson({
    'schemaVersion': 2,
    'proposalId': const Uuid().v4(),
    'createdAtUtcMs': now,
    'updatedAtUtcMs': now,
    'localOwner': owner,
    'originKind': 'external',
    'clientProfileId': profile,
    'submissionKey': key,
    'semanticFingerprint':
        generatedSha(generatedSubmissionSemantics(h.target, input.items)),
    'requestedCount': 1,
    'actualCount': 1,
    'countMismatchWarning': false,
    'originalTarget': h.target.toJson(),
    'target': h.target.toJson(),
    'reviewRevision': 0,
    'lifecycleStatus': 'pending_review',
    'items': input.items.map((i) => i.toJson()).toList(),
    'commitReceipt': null,
    'externalOrigin': payload
  });
  await h.db.transaction((txn) async {
    await txn.insert('generated_question_proposals', {
      'proposal_id': p.proposalId,
      'schema_version': 2,
      'created_at_utc_ms': now,
      'updated_at_utc_ms': now,
      'local_owner': owner,
      'origin_kind': 'external',
      'client_profile_id': profile,
      'submission_key': key,
      'semantic_fingerprint': p.semanticFingerprint,
      'requested_count': 1,
      'actual_count': 1,
      'original_target_json': generatedCanonical(p.originalTarget.toJson()),
      'target_json': generatedCanonical(p.target.toJson()),
      'review_revision': 0,
      'lifecycle_status': 'pending_review',
      'terminal_revision': null,
      'external_origin_json':
          generatedCanonical(p.externalOrigin!.toPersistedPayload())
    });
    for (final item in p.items) {
      await txn.insert('generated_question_proposal_items', {
        'proposal_id': p.proposalId,
        'item_id': item.itemId,
        'item_key': item.itemKey,
        'position': item.position,
        'original_json': generatedCanonical(
            const QuestionDraftV2Codec().encode(item.original)),
        'evidence_json':
            generatedCanonical(item.evidence.map((e) => e.toJson()).toList())
      });
      await txn.insert('generated_question_review_state', {
        'proposal_id': p.proposalId,
        'item_id': item.itemId,
        'working_json': generatedCanonical(
            const QuestionDraftV2Codec().encode(item.working)),
        'decision': item.decision.name,
        'evidence_ack_json': null
      });
    }
  });
  return readGeneratedProposal(h.db, p.proposalId);
}

/// Builds actual historical v32 physical objects inside a controlled fixture.
/// No child data/trigger is dropped, and FK enforcement remains ON at commit.
Future<void> installLegacyGeneratedHeaderFixture(Database db) async {
  await db.transaction((txn) async {
    final rows =
        await txn.rawQuery('PRAGMA table_info(generated_question_proposals)');
    final columns = rows
        .map((r) => r['name'] as String)
        .where((n) => n != 'external_origin_json')
        .join(',');
    await txn.execute(
        'CREATE TABLE fixture_legacy_header AS SELECT $columns FROM generated_question_proposals');
    await txn.execute('PRAGMA defer_foreign_keys=ON');
    await txn.execute('DROP TABLE generated_question_proposals');
    await txn.execute(
        generatedProposalV32SchemaObjects['generated_question_proposals']!);
    for (final name in [
      'idx_generated_pending_owner',
      'gq_original_header_immutable',
      'gq_terminal_immutable'
    ]) {
      await txn.execute(generatedProposalV32SchemaObjects[name]!);
    }
    await txn.execute(
        'INSERT INTO generated_question_proposals ($columns) SELECT $columns FROM fixture_legacy_header');
    await txn.execute('DROP TABLE fixture_legacy_header');
    await validateGeneratedProposalV32Schema(txn);
    await validateGeneratedProposalData(txn);
  });
}

import 'dart:convert';

import '../../core/database/sqflite_runtime.dart';
import '../../domain/generated_question/generated_question_contract.dart';
import '../../services/backup/sha256.dart';

const generatedProposalTableNames = [
  'generated_question_proposals',
  'generated_question_proposal_items',
  'generated_question_review_state',
  'generated_question_commit_receipts',
  'generated_question_commit_items'
];

String generatedSha(Object? value) {
  final hash = StreamingSha256()
    ..update(utf8.encode(generatedCanonical(value)));
  return hash.digestHex();
}

/// Retained storage compatibility reader; independent of runtime contribution.
Future<GeneratedQuestionProposal> readGeneratedProposal(
    DatabaseExecutor db, String id) async {
  try {
    final headers = await db.query('generated_question_proposals',
        where: 'proposal_id = ?', whereArgs: [id]);
    if (headers.length != 1) {
      generatedFail(GeneratedFailure.proposalUnavailable);
    }
    final h = headers.single;
    if (h['origin_kind'] != 'external' && h['external_origin_json'] != null) {
      generatedFail(GeneratedFailure.corruptState);
    }
    final originals = await db.query('generated_question_proposal_items',
        where: 'proposal_id = ?', whereArgs: [id], orderBy: 'position');
    final working = await db.query('generated_question_review_state',
        where: 'proposal_id = ?', whereArgs: [id]);
    final receipts = await db.query('generated_question_commit_receipts',
        where: 'proposal_id = ?', whereArgs: [id]);
    final mappings = await db.query('generated_question_commit_items',
        where: 'proposal_id = ?', whereArgs: [id]);
    if (working.length != originals.length || receipts.length > 1) {
      generatedFail(GeneratedFailure.corruptState);
    }
    final items = <Object?>[];
    for (final o in originals) {
      final matches = working.where((w) => w['item_id'] == o['item_id']);
      if (matches.length != 1) generatedFail(GeneratedFailure.corruptState);
      final w = matches.single;
      items.add({
        'itemId': o['item_id'],
        'itemKey': o['item_key'],
        'position': o['position'],
        'original': generatedDecode(o['original_json'] as String,
            maxBytes: GeneratedLimits.itemBytes),
        'working': generatedDecode(w['working_json'] as String,
            maxBytes: GeneratedLimits.itemBytes),
        'evidence':
            generatedDecode(o['evidence_json'] as String, maxBytes: 16384),
        'decision': w['decision'],
        'evidenceAcknowledgement': w['evidence_ack_json'] == null
            ? null
            : generatedDecode(w['evidence_ack_json'] as String, maxBytes: 16384)
      });
    }
    final p = GeneratedQuestionProposal.fromJson({
      'schemaVersion': h['schema_version'],
      'proposalId': h['proposal_id'],
      'createdAtUtcMs': h['created_at_utc_ms'],
      'updatedAtUtcMs': h['updated_at_utc_ms'],
      'localOwner': h['local_owner'],
      'originKind': h['origin_kind'],
      'clientProfileId': h['client_profile_id'],
      'submissionKey': h['submission_key'],
      'semanticFingerprint': h['semantic_fingerprint'],
      'requestedCount': h['requested_count'],
      'actualCount': h['actual_count'],
      'countMismatchWarning': h['requested_count'] != h['actual_count'],
      'originalTarget': generatedDecode(h['original_target_json'] as String),
      'target': generatedDecode(h['target_json'] as String),
      'reviewRevision': h['review_revision'],
      'lifecycleStatus': h['lifecycle_status'],
      'items': items,
      'commitReceipt': receipts.isEmpty
          ? null
          : generatedDecode(receipts.single['receipt_json'] as String,
              maxBytes: GeneratedLimits.receiptBytes),
      if (h['origin_kind'] == 'external')
        'externalOrigin': generatedDecode(h['external_origin_json'] as String,
            maxBytes: GeneratedLimits.externalOriginBytes)
    });
    if (generatedSha(generatedSubmissionSemantics(p.originalTarget, p.items)) !=
            p.semanticFingerprint ||
        (p.lifecycleStatus == GeneratedStatus.pendingReview
            ? h['terminal_revision'] != null
            : h['terminal_revision'] != p.reviewRevision)) {
      generatedFail(GeneratedFailure.corruptState);
    }
    final receipt = p.commitReceipt;
    if (receipt == null) {
      if (mappings.isNotEmpty) generatedFail(GeneratedFailure.corruptState);
    } else {
      if (mappings.length != receipt.itemMappings.length ||
          receipts.single['review_revision'] != p.reviewRevision ||
          receipts.single['committed_at_utc_ms'] != receipt.committedAtUtcMs) {
        generatedFail(GeneratedFailure.corruptState);
      }
      for (final m in mappings) {
        if (receipt.itemMappings[m['item_id']] != m['persisted_question_id']) {
          generatedFail(GeneratedFailure.corruptState);
        }
      }
    }
    return p;
  } on GeneratedQuestionException catch (e) {
    if (e.failure == GeneratedFailure.proposalUnavailable) rethrow;
    generatedFail(GeneratedFailure.corruptState);
  } catch (_) {
    generatedFail(GeneratedFailure.corruptState);
  }
}

Future<void> validateGeneratedProposalData(DatabaseExecutor db) async {
  try {
    if ((await db.rawQuery('PRAGMA foreign_key_check'))
        .any((row) => generatedProposalTableNames.contains(row['table']))) {
      generatedFail(GeneratedFailure.corruptState);
    }
    final rows = await db
        .query('generated_question_proposals', columns: ['proposal_id']);
    for (final row in rows) {
      await readGeneratedProposal(db, row['proposal_id'] as String);
    }
    // Orphans are forbidden even on a candidate opened with foreign_keys disabled.
    for (final table in [
      'generated_question_proposal_items',
      'generated_question_review_state',
      'generated_question_commit_receipts',
      'generated_question_commit_items'
    ]) {
      if ((await db.rawQuery(
              'SELECT 1 FROM $table AS c LEFT JOIN generated_question_proposals AS p ON p.proposal_id=c.proposal_id WHERE p.proposal_id IS NULL LIMIT 1'))
          .isNotEmpty) {
        generatedFail(GeneratedFailure.corruptState);
      }
    }
  } catch (_) {
    generatedFail(GeneratedFailure.corruptState);
  }
}

import '../../data/repositories/generated_proposal_reader.dart';
import '../../domain/generated_question/generated_question_contract.dart';
import 'sqflite_runtime.dart';

const generatedProposalV32SchemaVersion = 32;
const generatedProposalV32Tables = generatedProposalTableNames;

const generatedProposalV32SchemaObjects = <String, String>{
  'generated_question_proposals': '''CREATE TABLE generated_question_proposals (
  proposal_id TEXT PRIMARY KEY NOT NULL CHECK(length(proposal_id)=36),
  schema_version INTEGER NOT NULL CHECK(typeof(schema_version)='integer' AND schema_version=1),
  created_at_utc_ms INTEGER NOT NULL CHECK(typeof(created_at_utc_ms)='integer' AND created_at_utc_ms>=0),
  updated_at_utc_ms INTEGER NOT NULL CHECK(typeof(updated_at_utc_ms)='integer' AND updated_at_utc_ms>=created_at_utc_ms),
  local_owner TEXT NOT NULL CHECK(length(local_owner) BETWEEN 1 AND 64),
  origin_kind TEXT NOT NULL CHECK(origin_kind IN ('local','synthetic')),
  client_profile_id TEXT NOT NULL CHECK(length(client_profile_id) BETWEEN 1 AND 64),
  submission_key TEXT NOT NULL CHECK(length(submission_key) BETWEEN 1 AND 64),
  semantic_fingerprint TEXT NOT NULL CHECK(length(semantic_fingerprint)=64),
  requested_count INTEGER NOT NULL CHECK(typeof(requested_count)='integer' AND requested_count BETWEEN 1 AND 50),
  actual_count INTEGER NOT NULL CHECK(typeof(actual_count)='integer' AND actual_count BETWEEN 1 AND 50),
  original_target_json TEXT NOT NULL CHECK(length(original_target_json)>0),
  target_json TEXT NOT NULL CHECK(length(target_json)>0),
  review_revision INTEGER NOT NULL CHECK(typeof(review_revision)='integer' AND review_revision>=0),
  lifecycle_status TEXT NOT NULL CHECK(lifecycle_status IN ('pending_review','committed','rejected')),
  terminal_revision INTEGER,
  UNIQUE(client_profile_id,submission_key),
  CHECK((lifecycle_status='pending_review' AND terminal_revision IS NULL) OR
    (lifecycle_status!='pending_review' AND terminal_revision IS NOT NULL AND typeof(terminal_revision)='integer' AND terminal_revision=review_revision))
);''',
  'generated_question_proposal_items':
      '''CREATE TABLE generated_question_proposal_items (
  proposal_id TEXT NOT NULL,
  item_id TEXT NOT NULL CHECK(length(item_id)=36),
  item_key TEXT NOT NULL CHECK(length(item_key) BETWEEN 1 AND 64),
  position INTEGER NOT NULL CHECK(typeof(position)='integer' AND position BETWEEN 0 AND 49),
  original_json TEXT NOT NULL CHECK(length(original_json)>0),
  evidence_json TEXT NOT NULL CHECK(length(evidence_json)>0),
  PRIMARY KEY(proposal_id,item_id),
  UNIQUE(proposal_id,item_key),
  UNIQUE(proposal_id,position),
  FOREIGN KEY(proposal_id) REFERENCES generated_question_proposals(proposal_id)
);''',
  'generated_question_review_state':
      '''CREATE TABLE generated_question_review_state (
  proposal_id TEXT NOT NULL,
  item_id TEXT NOT NULL,
  working_json TEXT NOT NULL CHECK(length(working_json)>0),
  decision TEXT NOT NULL CHECK(decision IN ('unreviewed','accepted','rejected','deferred')),
  evidence_ack_json TEXT CHECK(evidence_ack_json IS NULL OR length(evidence_ack_json)>0),
  PRIMARY KEY(proposal_id,item_id),
  FOREIGN KEY(proposal_id,item_id) REFERENCES generated_question_proposal_items(proposal_id,item_id)
);''',
  'generated_question_commit_receipts':
      '''CREATE TABLE generated_question_commit_receipts (
  proposal_id TEXT PRIMARY KEY NOT NULL,
  receipt_json TEXT NOT NULL CHECK(length(receipt_json)>0),
  review_revision INTEGER NOT NULL CHECK(typeof(review_revision)='integer' AND review_revision>=0),
  committed_at_utc_ms INTEGER NOT NULL CHECK(typeof(committed_at_utc_ms)='integer' AND committed_at_utc_ms>=0),
  FOREIGN KEY(proposal_id) REFERENCES generated_question_proposals(proposal_id)
);''',
  'generated_question_commit_items':
      '''CREATE TABLE generated_question_commit_items (
  proposal_id TEXT NOT NULL,
  item_id TEXT NOT NULL,
  persisted_question_id TEXT NOT NULL UNIQUE CHECK(length(persisted_question_id)=36),
  PRIMARY KEY(proposal_id,item_id),
  FOREIGN KEY(proposal_id,item_id) REFERENCES generated_question_proposal_items(proposal_id,item_id),
  FOREIGN KEY(proposal_id) REFERENCES generated_question_commit_receipts(proposal_id)
);''',
  'idx_generated_pending_owner':
      'CREATE INDEX idx_generated_pending_owner ON generated_question_proposals(local_owner,lifecycle_status);',
  'gq_original_header_immutable':
      '''CREATE TRIGGER gq_original_header_immutable BEFORE UPDATE OF proposal_id,schema_version,created_at_utc_ms,local_owner,origin_kind,client_profile_id,submission_key,semantic_fingerprint,requested_count,actual_count,original_target_json ON generated_question_proposals BEGIN SELECT RAISE(ABORT,'gq_immutable'); END;''',
  'gq_terminal_immutable':
      '''CREATE TRIGGER gq_terminal_immutable BEFORE UPDATE ON generated_question_proposals WHEN OLD.lifecycle_status!='pending_review' BEGIN SELECT RAISE(ABORT,'gq_terminal'); END;''',
  'gq_original_item_immutable':
      '''CREATE TRIGGER gq_original_item_immutable BEFORE UPDATE ON generated_question_proposal_items BEGIN SELECT RAISE(ABORT,'gq_immutable'); END;''',
  'gq_terminal_review_immutable':
      '''CREATE TRIGGER gq_terminal_review_immutable BEFORE UPDATE ON generated_question_review_state WHEN (SELECT lifecycle_status FROM generated_question_proposals WHERE proposal_id=OLD.proposal_id)!='pending_review' BEGIN SELECT RAISE(ABORT,'gq_terminal'); END;''',
  'gq_receipt_immutable':
      '''CREATE TRIGGER gq_receipt_immutable BEFORE UPDATE ON generated_question_commit_receipts BEGIN SELECT RAISE(ABORT,'gq_immutable'); END;''',
  'gq_mapping_immutable':
      '''CREATE TRIGGER gq_mapping_immutable BEFORE UPDATE ON generated_question_commit_items BEGIN SELECT RAISE(ABORT,'gq_immutable'); END;''',
};

Future<void> createGeneratedProposalV32Schema(DatabaseExecutor db,
    {bool ifNotExists = false}) async {
  for (final sql in generatedProposalV32SchemaObjects.values) {
    await db.execute(ifNotExists
        ? sql
            .replaceFirst('CREATE TABLE ', 'CREATE TABLE IF NOT EXISTS ')
            .replaceFirst('CREATE INDEX ', 'CREATE INDEX IF NOT EXISTS ')
            .replaceFirst('CREATE TRIGGER ', 'CREATE TRIGGER IF NOT EXISTS ')
        : sql);
  }
}

Future<void> migrateGeneratedProposalToV32(DatabaseExecutor db) async {
  // Upgrade callback already owns the SQLite transaction; no parallel migration owner.
  await createGeneratedProposalV32Schema(db, ifNotExists: true);
  await validateGeneratedProposalV32Schema(db);
  await validateGeneratedProposalData(db);
  // An older version cannot legitimately own published Proposal data. Exact,
  // empty additive objects are idempotent; unknown shapes or data fail closed.
  for (final table in generatedProposalV32Tables) {
    if ((await db.query(table, limit: 1)).isNotEmpty) {
      generatedFail(GeneratedFailure.corruptState);
    }
  }
}

String _sql(String text) => text
    .replaceAll(RegExp(r'\bIF\s+NOT\s+EXISTS\b'), '')
    .replaceAll(RegExp(r';\s*$'), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .replaceAllMapped(RegExp(r'\s*([(),=;])\s*'), (match) => match[1]!)
    .trim();
Future<void> validateGeneratedProposalV32Schema(DatabaseExecutor db) async {
  try {
    for (final object in generatedProposalV32SchemaObjects.entries) {
      final rows = await db
          .rawQuery('SELECT sql FROM sqlite_master WHERE name=?', [object.key]);
      if (rows.length != 1 ||
          rows.single['sql'] is! String ||
          _sql(rows.single['sql'] as String) != _sql(object.value)) {
        generatedFail(GeneratedFailure.corruptState);
      }
    }
    final owned = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='trigger' OR (type='index' AND sql IS NOT NULL)");
    for (final table in generatedProposalV32Tables) {
      final objects = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE tbl_name=? AND (type='trigger' OR (type='index' AND sql IS NOT NULL))",
          [table]);
      if (objects.any(
          (o) => !generatedProposalV32SchemaObjects.containsKey(o['name']))) {
        generatedFail(GeneratedFailure.corruptState);
      }
    }
    if (!owned.any((o) => o['name'] == 'idx_generated_pending_owner')) {
      generatedFail(GeneratedFailure.corruptState);
    }
    if ((await db.rawQuery('PRAGMA foreign_key_check'))
        .any((row) => generatedProposalV32Tables.contains(row['table']))) {
      generatedFail(GeneratedFailure.corruptState);
    }
  } catch (_) {
    generatedFail(GeneratedFailure.corruptState);
  }
}

import 'package:uuid/uuid.dart';

import '../../application/backup/backup_restore_gate.dart';
import '../../application/generated_question/generated_question_service.dart';
import '../../application/generated_question/generated_local_authority.dart';
import '../../core/database/database_helper.dart';
import '../../core/database/sqflite_runtime.dart';
import '../../core/database/training_content_binding_lifecycle.dart';
import '../../domain/generated_question/generated_question_contract.dart';
import '../../domain/question/question_draft_v2_codec.dart';
import '../../services/import_review/import_review_analyzer.dart';
import '../../services/import_review/import_review_blocking_policy.dart';
import '../models/persisted_question.dart';
import '../models/question_draft.dart';
import '../persistence/question_v2_persistence_mapper.dart';
import '../persistence/typed_question_batch_writer.dart';
import 'generated_proposal_reader.dart';

/// Sole generated Proposal transaction owner. No public independently
/// transactional QuestionRepository API or fabricated ImportTask is used.
final class GeneratedProposalRepository
    implements GeneratedQuestionPersistencePort {
  GeneratedProposalRepository(
      {DatabaseHelper? databaseHelper,
      String Function()? idFactory,
      int Function()? clock})
      : _helper = databaseHelper ?? DatabaseHelper.instance,
        _id = idFactory ?? const Uuid().v4,
        _clock = clock ?? (() => DateTime.now().toUtc().millisecondsSinceEpoch);
  final DatabaseHelper _helper;
  final String Function() _id;
  final int Function() _clock;
  static const _codec = QuestionDraftV2Codec();
  static const _mapper = QuestionV2PersistenceMapper();

  Future<T> _mutation<T>(Future<T> Function(DatabaseExecutor) operation) async {
    final lease = BackupRestoreMutationGate.instance.acquireMutationLease();
    try {
      final db = await _helper.database;
      return await db.transaction(operation);
    } on GeneratedQuestionException {
      rethrow;
    } catch (_) {
      generatedFail(GeneratedFailure.persistenceFailed);
    } finally {
      lease.release();
    }
  }

  Future<T> _query<T>(Future<T> Function(DatabaseExecutor) operation) async {
    try {
      final db = await _helper.database;
      return await db.transaction(operation);
    } on GeneratedQuestionException {
      rethrow;
    } catch (_) {
      generatedFail(GeneratedFailure.corruptState);
    }
  }

  void _local(GeneratedQuestionProposal p, GeneratedLocalContext c,
      {bool target = true}) {
    c.validate();
    // A foreign owner must be indistinguishable from an absent proposal.
    if (p.localOwner != c.localOwner) {
      generatedFail(GeneratedFailure.proposalUnavailable);
    }
    if (target &&
        generatedCanonical(p.target.toJson()) !=
            generatedCanonical(c.confirmedTarget.toJson())) {
      generatedFail(GeneratedFailure.targetChanged);
    }
  }

  void _pending(GeneratedQuestionProposal p, int revision) {
    if (p.lifecycleStatus != GeneratedStatus.pendingReview) {
      generatedFail(GeneratedFailure.terminalConflict);
    }
    if (p.reviewRevision != revision) {
      generatedFail(GeneratedFailure.staleRevision);
    }
  }

  Future<void> _target(DatabaseExecutor db, GeneratedTarget target) async {
    final banks = await db.rawQuery(
        'SELECT bank_name FROM questions WHERE bank_name=? UNION SELECT bank_name FROM bank_folders WHERE bank_name=?',
        [target.bankName, target.bankName]);
    if (banks.isEmpty) generatedFail(GeneratedFailure.targetChanged);
    final folders = await db.query('bank_folders',
        where: 'bank_name=?', whereArgs: [target.bankName]);
    if (folders.length > 1 ||
        (folders.isEmpty ? null : folders.single['folder_name']) !=
            target.folderName) {
      generatedFail(GeneratedFailure.targetChanged);
    }
    if (target.projectId != null) {
      if ((await db.query('projects',
                  where: 'project_id=?', whereArgs: [target.projectId]))
              .length !=
          1) {
        generatedFail(GeneratedFailure.targetChanged);
      }
      final bankRows = await db.query('project_banks',
          columns: ['bank_name'],
          where: 'project_id=?',
          whereArgs: [target.projectId],
          orderBy: 'bank_name');
      if (generatedCanonical(bankRows.map((r) => r['bank_name']).toList()) !=
          generatedCanonical(target.projectBankNames)) {
        generatedFail(GeneratedFailure.targetChanged);
      }
    }
  }

  Future<List<Object?>> _evidence(
      DatabaseExecutor db, GeneratedTarget target, GeneratedItem item) async {
    final states = <Object?>[];
    for (final e in item.evidence) {
      final files = await db
          .query('library_files', where: 'file_id=?', whereArgs: [e.fileId]);
      final artifacts = await db
          .query('parsed_artifacts', where: 'file_id=?', whereArgs: [e.fileId]);
      // Current authorization binds the claimed source identity to the file's
      // parsed artifact and, under a Project target, to the Project file scope.
      var current = files.length == 1 &&
              artifacts.length == 1 &&
              artifacts.single['artifact_id'] == e.sourceRef.sourceId
          ? artifacts.single
          : null;
      if (current != null && target.projectId != null) {
        final linked = await db.query('project_files',
            where: 'project_id=? AND file_id=?',
            whereArgs: [target.projectId, e.fileId]);
        if (linked.length != 1) current = null;
      }
      states.add({
        'evidenceKey': e.evidenceKey,
        'status': current == null
            ? 'unavailable'
            : current['revision'] == e.artifactRevision &&
                    current['payload_sha256'] == e.artifactDigest
                ? 'authorized'
                : 'stale',
        'currentRevision': current?['revision'],
        'currentDigest': current?['payload_sha256']
      });
    }
    validateEvidenceState(states, item.evidence);
    return states;
  }

  void _quality(List<FrozenQuestionV2Write> writes) {
    final drafts = [
      for (final w in writes)
        QuestionDraft.fromMap(Map<String, dynamic>.from(w.questionRow))
    ];
    if (ImportReviewBlockingPolicy.isBlocked(
        ImportReviewAnalyzer.analyze(drafts))) {
      generatedFail(GeneratedFailure.qualityBlocked);
    }
  }

  List<FrozenQuestionV2Write> _freeze(
      GeneratedTarget target, List<GeneratedItem> items, int now) {
    final writes = <FrozenQuestionV2Write>[];
    for (final item in items) {
      validateGeneratedDraft(item.working);
      writes.add(_mapper.freezeForWrite(
          storageId: generatedToken(_id(), uuid: true),
          bankName: target.bankName,
          createdAt: now ~/ 1000,
          draft: item.working));
    }
    _quality(writes);
    return writes;
  }

  Future<void> _verifyWrittenBatch(
      DatabaseExecutor db, List<FrozenQuestionV2Write> writes) async {
    for (final write in writes) {
      final id = write.questionRow['id'];
      final questions =
          await db.query('questions', where: 'id=?', whereArgs: [id]);
      final payloads = await db.query('question_v2_payloads',
          where: 'question_id=?', whereArgs: [id]);
      final reviews = await db
          .query('review_states', where: 'question_id=?', whereArgs: [id]);
      final expectedReview =
          TypedQuestionBatchWriter.initialReviewState(id as String);
      if (questions.length != 1 ||
          payloads.length != 1 ||
          reviews.length != 1 ||
          write.questionRow.entries
              .any((e) => questions.single[e.key] != e.value) ||
          write.payloadRow.entries
              .any((e) => payloads.single[e.key] != e.value) ||
          expectedReview.entries.any((e) => reviews.single[e.key] != e.value)) {
        generatedFail(GeneratedFailure.persistenceFailed);
      }
    }
  }

  Future<({List<String> exact, List<String> legacyOverlap})> _duplicates(
      DatabaseExecutor db, GeneratedTarget target, List<GeneratedItem> items,
      {String? excluding}) async {
    final signatures = <String, String>{};
    final duplicateIds = <String>{};
    final legacyOverlap = <String>{};
    for (final item in items) {
      final signature = generatedSha(generatedSemantics(item.working));
      if (signatures.containsKey(signature)) {
        duplicateIds.add(signatures[signature]!);
        duplicateIds.add(item.itemId);
      }
      signatures[signature] = item.itemId;
    }
    final pending = await db.query('generated_question_proposals',
        columns: ['proposal_id'], where: "lifecycle_status='pending_review'");
    for (final row in pending) {
      if (row['proposal_id'] == excluding) continue;
      final p = await readGeneratedProposal(db, row['proposal_id'] as String);
      if (p.target.bankName != target.bankName) continue;
      for (final i
          in p.items.where((i) => i.decision != GeneratedDecision.rejected)) {
        final other = [
          generatedSha(generatedSemantics(i.original)),
          generatedSha(generatedSemantics(i.working))
        ];
        for (final signature in other) {
          if (signatures.containsKey(signature)) {
            duplicateIds.add(signatures[signature]!);
          }
        }
      }
    }
    final rows = await db.rawQuery(
        '''SELECT q.*, p.payload_schema_version AS ${QuestionV2PersistenceMapper.payloadSchemaVersionAlias},
      p.payload_json AS ${QuestionV2PersistenceMapper.payloadJsonAlias} FROM questions q
      LEFT JOIN question_v2_payloads p ON p.question_id=q.id WHERE q.bank_name=?''',
        [target.bankName]);
    for (final row in rows) {
      final persisted = _mapper.decodeJoinedRow(row);
      if (persisted case TypedPersistedQuestion(:final draft)) {
        final signature = generatedSha(generatedSemantics(draft));
        if (signatures.containsKey(signature)) {
          duplicateIds.add(signatures[signature]!);
        }
      } else {
        // Legacy overlap is conservative quality evidence, NOT typed structural equality.
        // Never reconstruct a typed candidate from a String compatibility projection.
        for (final item in items) {
          final candidate = _mapper
              .freezeForWrite(
                  storageId: '00000000-0000-4000-8000-000000000000',
                  bankName: target.bankName,
                  createdAt: 0,
                  draft: item.working)
              .questionRow;
          const fields = [
            'type',
            'content',
            'options',
            'standard_answer',
            'explanation'
          ];
          if (fields.every((k) => row[k] == candidate[k])) {
            legacyOverlap.add(item.itemId);
          }
        }
      }
    }
    return (
      exact: items
          .where((i) => duplicateIds.contains(i.itemId))
          .map((i) => i.itemId)
          .toList(),
      legacyOverlap: items
          .where((i) => legacyOverlap.contains(i.itemId))
          .map((i) => i.itemId)
          .toList()
    );
  }

  @override
  Future<GeneratedStageResult> stage(
      GeneratedStageInput input, GeneratedOriginContext context) {
    context.validate();
    return _mutation((db) async {
      context.validate();
      final fingerprint = generatedSha(
          generatedSubmissionSemantics(context.target, input.items));
      final existing = await db.query('generated_question_proposals',
          columns: ['proposal_id'],
          where: 'client_profile_id=? AND submission_key=?',
          whereArgs: [context.clientProfileId, input.submissionKey]);
      if (existing.isNotEmpty) {
        final p = await readGeneratedProposal(
            db, existing.single['proposal_id'] as String);
        if (p.localOwner != context.localOwner) {
          generatedFail(GeneratedFailure.unauthorized);
        }
        if (p.semanticFingerprint != fingerprint) {
          generatedFail(GeneratedFailure.idempotencyConflict);
        }
        final dup =
            await _duplicates(db, p.target, p.items, excluding: p.proposalId);
        return GeneratedStageResult(p, [...dup.exact, ...dup.legacyOverlap]);
      }
      await _target(db, context.target);
      for (final item in input.items) {
        if ((await _evidence(db, context.target, item))
            .any((v) => (v as Map)['status'] != 'authorized')) {
          generatedFail(GeneratedFailure.invalidEvidence);
        }
      }
      final now = generatedInt(_clock());
      _freeze(context.target, input.items, now);
      final id = generatedToken(_id(), uuid: true);
      await db.insert('generated_question_proposals', {
        'proposal_id': id,
        'schema_version': 1,
        'created_at_utc_ms': now,
        'updated_at_utc_ms': now,
        'local_owner': context.localOwner,
        'origin_kind': context.originKind,
        'client_profile_id': context.clientProfileId,
        'submission_key': input.submissionKey,
        'semantic_fingerprint': fingerprint,
        'requested_count': input.requestedCount,
        'actual_count': input.items.length,
        'original_target_json': generatedCanonical(context.target.toJson()),
        'target_json': generatedCanonical(context.target.toJson()),
        'review_revision': 0,
        'lifecycle_status': 'pending_review',
        'terminal_revision': null
      });
      for (final item in input.items) {
        await db.insert('generated_question_proposal_items', {
          'proposal_id': id,
          'item_id': item.itemId,
          'item_key': item.itemKey,
          'position': item.position,
          'original_json': generatedCanonical(_codec.encode(item.original)),
          'evidence_json':
              generatedCanonical(item.evidence.map((e) => e.toJson()).toList())
        });
        await db.insert('generated_question_review_state', {
          'proposal_id': id,
          'item_id': item.itemId,
          'working_json': generatedCanonical(_codec.encode(item.working)),
          'decision': 'unreviewed',
          'evidence_ack_json': null
        });
      }
      context.validate();
      final p = await readGeneratedProposal(db, id);
      final dup = await _duplicates(db, p.target, p.items, excluding: id);
      return GeneratedStageResult(p, [...dup.exact, ...dup.legacyOverlap]);
    });
  }

  @override
  Future<GeneratedQuestionProposal> read(
      String proposalId, GeneratedLocalContext context) {
    context.validate();
    generatedToken(proposalId, uuid: true);
    return _query((db) async {
      final p = await readGeneratedProposal(db, proposalId);
      _local(p, context, target: false);
      return p;
    });
  }

  @override
  Future<List<GeneratedQuestionProposal>> pending(
      GeneratedLocalContext context) {
    context.validate();
    return _query((db) async {
      final rows = await db.query('generated_question_proposals',
          columns: ['proposal_id'],
          where: "local_owner=? AND lifecycle_status='pending_review'",
          whereArgs: [context.localOwner],
          orderBy: 'created_at_utc_ms,proposal_id');
      final result = <GeneratedQuestionProposal>[];
      for (final row in rows) {
        final p = await readGeneratedProposal(db, row['proposal_id'] as String);
        _local(p, context, target: false);
        result.add(p);
      }
      return List.unmodifiable(result);
    });
  }

  @override
  Future<List<Object?>> evidenceState(
      String proposalId, String itemId, GeneratedLocalContext context) {
    context.validate();
    return _query((db) async {
      final p = await readGeneratedProposal(db, proposalId);
      _local(p, context, target: false);
      final matches = p.items.where((i) => i.itemId == itemId);
      if (matches.length != 1) {
        generatedFail(GeneratedFailure.proposalUnavailable);
      }
      return _evidence(db, p.target, matches.single);
    });
  }

  /// Same R5A resolver, with read-only first-party ownership authority.
  Future<List<Object?>> evidenceStateForLocalRead(
      String proposalId, String itemId, GeneratedLocalReadAuthority authority) {
    authority.validate();
    return _query((db) async {
      final p = await readGeneratedProposal(db, proposalId);
      authority.validate();
      if (p.localOwner != authority.localOwner) {
        generatedFail(GeneratedFailure.proposalUnavailable);
      }
      final matches = p.items.where((i) => i.itemId == itemId);
      if (matches.length != 1) {
        generatedFail(GeneratedFailure.proposalUnavailable);
      }
      final states = await _evidence(db, p.target, matches.single);
      authority.validate();
      return states;
    });
  }

  @override
  Future<GeneratedQuestionProposal> flush(
      GeneratedReviewFlush command, GeneratedLocalContext context) {
    context.validate();
    return _mutation((db) async {
      final p = await readGeneratedProposal(db, command.proposalId);
      _local(p, context, target: false);
      _pending(p, command.expectedReviewRevision);
      var items = p.items.toList();
      var target = p.target;
      for (final raw in command.operations) {
        final op = Map<String, Object?>.from(raw as Map);
        if (op['type'] == 'rebind') {
          target = GeneratedTarget.fromJson(op['target']);
          if (generatedCanonical(target.toJson()) !=
              generatedCanonical(context.confirmedTarget.toJson())) {
            generatedFail(GeneratedFailure.unauthorized);
          }
          await _target(db, target);
          items = [
            for (final i in items)
              i.reviewed(i.working, GeneratedDecision.unreviewed, null)
          ];
          continue;
        }
        final edit = op['type'] == 'edit'
            ? Map<String, Object?>.from(op['edit'] as Map)
            : null;
        final id = edit?['itemId'] ?? op['itemId'];
        final index = items.indexWhere((i) => i.itemId == id);
        if (index < 0) generatedFail(GeneratedFailure.invalidEdit);
        final item = items[index];
        switch (op['type']) {
          case 'edit':
            items[index] = item.reviewed(
                applyGeneratedEdit(item.working, edit!),
                GeneratedDecision.unreviewed,
                item.evidenceAcknowledgement);
          case 'decide':
            items[index] = item.reviewed(
                item.working,
                GeneratedDecision.values.byName(op['decision'] as String),
                item.evidenceAcknowledgement);
          case 'acknowledge':
            validateEvidenceState(op['evidenceState'], item.evidence);
            final actual = await _evidence(db, target, item);
            if (generatedCanonical(op['evidenceState']) !=
                generatedCanonical(actual)) {
              generatedFail(GeneratedFailure.staleEvidence);
            }
            items[index] = item.reviewed(
                item.working, item.decision, generatedCanonical(actual));
          default:
            generatedFail(GeneratedFailure.invalidEdit);
        }
      }
      if (generatedCanonical(context.confirmedTarget.toJson()) !=
          generatedCanonical(target.toJson())) {
        generatedFail(GeneratedFailure.targetChanged);
      }
      generatedSize(items.map((i) => i.toJson()).toList(),
          GeneratedLimits.batchBytes * 2);
      for (final item in items) {
        final updated = await db.update(
            'generated_question_review_state',
            {
              'working_json': generatedCanonical(_codec.encode(item.working)),
              'decision': item.decision.name,
              'evidence_ack_json': item.evidenceAcknowledgement
            },
            where: 'proposal_id=? AND item_id=?',
            whereArgs: [p.proposalId, item.itemId]);
        if (updated != 1) generatedFail(GeneratedFailure.persistenceFailed);
      }
      context.validate();
      final count = await db.update(
          'generated_question_proposals',
          {
            'target_json': generatedCanonical(target.toJson()),
            'review_revision': p.reviewRevision + 1,
            'updated_at_utc_ms': generatedInt(_clock(), min: p.updatedAtUtcMs)
          },
          where:
              "proposal_id=? AND lifecycle_status='pending_review' AND review_revision=?",
          whereArgs: [p.proposalId, p.reviewRevision]);
      if (count != 1) generatedFail(GeneratedFailure.staleRevision);
      return readGeneratedProposal(db, p.proposalId);
    });
  }

  @override
  Future<GeneratedReceipt> approve(
      ApproveGeneratedProposalCommand command, GeneratedLocalContext context) {
    context.validate();
    return _mutation((db) async {
      final p = await readGeneratedProposal(db, command.proposalId);
      _local(p, context);
      final ids = command.approvedItemIds;
      if (p.lifecycleStatus == GeneratedStatus.committed) {
        final receipt = p.commitReceipt!;
        if (command.expectedReviewRevision != receipt.reviewRevision ||
            generatedCanonical(ids) !=
                generatedCanonical(receipt.itemMappings.keys.toList())) {
          generatedFail(GeneratedFailure.terminalConflict);
        }
        context.validate();
        return receipt;
      }
      _pending(p, command.expectedReviewRevision);
      final selected = p.items
          .where((i) => i.decision == GeneratedDecision.accepted)
          .toList();
      if (selected.isEmpty ||
          generatedCanonical(ids) !=
              generatedCanonical(selected.map((i) => i.itemId).toList()) ||
          p.items.any((i) =>
              i.decision != GeneratedDecision.accepted &&
              i.decision != GeneratedDecision.rejected)) {
        generatedFail(GeneratedFailure.reviewIncomplete);
      }
      await _target(db, p.target);
      for (final item in selected) {
        final states = await _evidence(db, p.target, item);
        if (states.any((v) => (v as Map)['status'] != 'authorized') &&
            item.evidenceAcknowledgement != generatedCanonical(states)) {
          generatedFail(GeneratedFailure.staleEvidence);
        }
      }
      final duplicates =
          await _duplicates(db, p.target, selected, excluding: p.proposalId);
      if (duplicates.exact.isNotEmpty) {
        generatedFail(GeneratedFailure.duplicateContent);
      }
      if (duplicates.legacyOverlap.isNotEmpty) {
        generatedFail(GeneratedFailure.qualityBlocked);
      }
      final now = generatedInt(_clock(), min: p.updatedAtUtcMs);
      final writes = _freeze(p.target, selected, now);
      await reconcilePreexistingTrainingBindingDrift(db,
          affectedBankNames: [p.target.bankName]);
      await const TypedQuestionBatchWriter().write(db,
          bankName: p.target.bankName,
          resolvedFolderName: p.target.folderName,
          frozenWrites: writes,
          assetIdentities: {});
      await _verifyWrittenBatch(db, writes);
      await _target(db, p.target);
      await invalidateTrainingBindingsAtFinalState(db,
          affectedBankNames: [p.target.bankName]);
      final receipt = GeneratedReceipt(
          proposalId: p.proposalId,
          committedAtUtcMs: now,
          reviewRevision: p.reviewRevision,
          itemMappings: {
            for (var i = 0; i < selected.length; i++)
              selected[i].itemId: writes[i].questionRow['id']! as String
          });
      await db.insert('generated_question_commit_receipts', {
        'proposal_id': p.proposalId,
        'receipt_json': generatedCanonical(receipt.toJson()),
        'review_revision': p.reviewRevision,
        'committed_at_utc_ms': now
      });
      for (final mapping in receipt.itemMappings.entries) {
        await db.insert('generated_question_commit_items', {
          'proposal_id': p.proposalId,
          'item_id': mapping.key,
          'persisted_question_id': mapping.value
        });
      }
      context.validate();
      final count = await db.update(
          'generated_question_proposals',
          {
            'lifecycle_status': 'committed',
            'terminal_revision': p.reviewRevision,
            'updated_at_utc_ms': now
          },
          where:
              "proposal_id=? AND lifecycle_status='pending_review' AND review_revision=?",
          whereArgs: [p.proposalId, p.reviewRevision]);
      if (count != 1) generatedFail(GeneratedFailure.staleRevision);
      return (await readGeneratedProposal(db, p.proposalId)).commitReceipt!;
    });
  }

  @override
  Future<GeneratedQuestionProposal> reject(
      RejectGeneratedProposalCommand command, GeneratedLocalContext context) {
    context.validate();
    return _mutation((db) async {
      final p = await readGeneratedProposal(db, command.proposalId);
      _local(p, context);
      if (p.lifecycleStatus == GeneratedStatus.rejected &&
          p.reviewRevision == command.expectedReviewRevision) {
        return p;
      }
      _pending(p, command.expectedReviewRevision);
      if (p.items.any((i) => i.decision != GeneratedDecision.rejected)) {
        generatedFail(GeneratedFailure.reviewIncomplete);
      }
      context.validate();
      final count = await db.update(
          'generated_question_proposals',
          {
            'lifecycle_status': 'rejected',
            'terminal_revision': p.reviewRevision,
            'updated_at_utc_ms': generatedInt(_clock(), min: p.updatedAtUtcMs)
          },
          where:
              "proposal_id=? AND lifecycle_status='pending_review' AND review_revision=?",
          whereArgs: [p.proposalId, p.reviewRevision]);
      if (count != 1) generatedFail(GeneratedFailure.staleRevision);
      return readGeneratedProposal(db, p.proposalId);
    });
  }
}

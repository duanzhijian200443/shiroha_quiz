import '../../application/supplemental_answers/supplemental_answer_command.dart';
import '../../application/supplemental_answers/supplemental_answer_failure.dart';
import '../../core/database/database_helper.dart';
import '../../core/database/sqflite_runtime.dart';
import '../../domain/supplemental_answers/answer_candidate.dart';
import '../models/persisted_question.dart';
import '../persistence/question_v2_persistence_mapper.dart';
import '../persistence/typed_answer_persistence.dart';

/// Data-layer implementation of the P6 confirm port.
///
/// One SQLite transaction performs:
///
/// 1. a current parsed-artifact metadata generation check (`fileId`,
///    `artifactId`, `revision` must exactly match the candidate);
/// 2. a strict typed-target recheck (storageId exists, bankName matches the
///    snapshot, the full `QuestionDraftV2` equals the expected draft, and the
///    current answer state still satisfies the fill/replace precondition);
/// 3. the existing [TypedAnswerPersistenceKernel] answer mutation in the same
///    transaction.
///
/// Any failed precondition throws with zero writes. Domain/Application never
/// read SQLite directly; this data adapter owns the transaction and the
/// kernel never starts or nests one.
final class SupplementalAnswerPersistenceRepository
    implements SupplementalAnswerPersistencePort {
  SupplementalAnswerPersistenceRepository({
    DatabaseHelper? databaseHelper,
    QuestionV2PersistenceMapper mapper = const QuestionV2PersistenceMapper(),
    TypedAnswerPersistenceKernel kernel = const TypedAnswerPersistenceKernel(),
  })  : _databaseHelper = databaseHelper ?? DatabaseHelper.instance,
        _mapper = mapper,
        _kernel = kernel;

  final DatabaseHelper _databaseHelper;
  final QuestionV2PersistenceMapper _mapper;
  final TypedAnswerPersistenceKernel _kernel;

  @override
  Future<void> confirmCandidate(AnswerCandidate candidate) async {
    try {
      final db = await _databaseHelper.database;
      await db.transaction((txn) async {
        await _recheckArtifactGeneration(txn, candidate);
        await _recheckTypedTarget(txn, candidate);
        await _kernel.applyAnswerUpdate(
          txn: _P6TransactionExecutor(txn),
          storageId: candidate.targetStorageId,
          expectedDraft: candidate.expectedDraft,
          newAnswer: candidate.answer,
        );
        // The kernel revalidates the full draft inside the same transaction;
        // `current` here is only the P6 precondition projection.
      });
    } on SupplementalAnswerException {
      rethrow;
    } on DatabaseException {
      throw const SupplementalAnswerException(
        SupplementalAnswerFailure.temporarilyUnavailable,
      );
    }
  }

  Future<void> _recheckArtifactGeneration(
    DatabaseExecutor txn,
    AnswerCandidate candidate,
  ) async {
    final rows = await txn.rawQuery(
      '''
      SELECT a.artifact_id AS artifact_id, a.revision AS revision
      FROM parsed_artifact_heads h
      JOIN parsed_artifacts a ON a.file_id = h.file_id
      WHERE h.file_id = ?
      LIMIT 2
      ''',
      <Object?>[candidate.supplementalFileId],
    );
    if (rows.length != 1) {
      throw const SupplementalAnswerException(
        SupplementalAnswerFailure.staleTarget,
      );
    }
    final row = rows.single;
    if (row['artifact_id'] != candidate.artifactId ||
        row['revision'] != candidate.artifactRevision) {
      throw const SupplementalAnswerException(
        SupplementalAnswerFailure.staleTarget,
      );
    }
  }

  Future<TypedPersistedQuestion> _recheckTypedTarget(
    DatabaseExecutor txn,
    AnswerCandidate candidate,
  ) async {
    final rows = await txn.rawQuery(
      '''
      SELECT q.*,
             p.payload_schema_version AS ${QuestionV2PersistenceMapper.payloadSchemaVersionAlias},
             p.payload_json AS ${QuestionV2PersistenceMapper.payloadJsonAlias}
      FROM questions q
      LEFT JOIN question_v2_payloads p ON q.id = p.question_id
      WHERE q.id = ?
      LIMIT 2
      ''',
      <Object?>[candidate.targetStorageId],
    );
    if (rows.length != 1) {
      throw const SupplementalAnswerException(
        SupplementalAnswerFailure.staleTarget,
      );
    }
    final row = rows.single;
    if (row['bank_name'] != candidate.targetBankName) {
      throw const SupplementalAnswerException(
        SupplementalAnswerFailure.staleTarget,
      );
    }

    final PersistedQuestion decoded;
    try {
      decoded = _mapper.decodeJoinedRow(row);
    } on QuestionV2PayloadException {
      throw const SupplementalAnswerException(
        SupplementalAnswerFailure.targetUnavailable,
      );
    }
    if (decoded is! TypedPersistedQuestion) {
      throw const SupplementalAnswerException(
        SupplementalAnswerFailure.staleTarget,
      );
    }
    if (decoded.draft != candidate.expectedDraft) {
      throw const SupplementalAnswerException(
        SupplementalAnswerFailure.staleTarget,
      );
    }

    switch (candidate.writeIntent) {
      case CandidateWriteIntent.fill:
        if (decoded.draft.answer != null) {
          throw const SupplementalAnswerException(
            SupplementalAnswerFailure.staleTarget,
          );
        }
      case CandidateWriteIntent.replace:
        final current = decoded.draft.answer;
        if (current == null || current == candidate.answer) {
          throw const SupplementalAnswerException(
            SupplementalAnswerFailure.staleTarget,
          );
        }
      case CandidateWriteIntent.noOp:
        // A noOp candidate must never reach the write boundary; the review
        // session already treats it as a terminal zero-transaction outcome.
        throw const SupplementalAnswerException(
          SupplementalAnswerFailure.invalidCandidate,
        );
    }
    return decoded;
  }
}

/// Adapts the caller-owned SQLite transaction to the shared kernel's minimal
/// transaction surface. The repository owns the transaction; the kernel
/// never starts or nests one.
final class _P6TransactionExecutor implements TypedAnswerTransactionExecutor {
  const _P6TransactionExecutor(this._txn);

  final DatabaseExecutor _txn;

  @override
  Future<List<Map<String, Object?>>> queryRaw(
    String sql, [
    List<Object?>? arguments,
  ]) {
    return _txn.rawQuery(sql, arguments);
  }

  @override
  Future<int> update(
    String table,
    Map<String, Object?> values, {
    String? where,
    List<Object?>? whereArgs,
  }) {
    return _txn.update(
      table,
      values,
      where: where,
      whereArgs: whereArgs,
    );
  }
}

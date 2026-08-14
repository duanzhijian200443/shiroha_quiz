import '../../application/answers/ai_answer_commit_command.dart';
import '../../application/safe_write/typed_answer_command.dart';
import '../../core/database/database_helper.dart';
import '../../core/database/sqflite_runtime.dart';
import '../../domain/answers/answer_candidate.dart';
import '../models/persisted_question.dart';
import '../persistence/question_v2_persistence_mapper.dart';
import '../persistence/typed_answer_persistence.dart';

/// P7-C0 data-layer implementation of the AI commit port.
///
/// One SQLite transaction performs, in order:
///
/// 1. a strict joined-row read of `questions` + `question_v2_payloads` by
///    `targetStorageId` (exactly one row);
/// 2. `bank_name` must equal `candidate.targetBankName`;
/// 3. the row must strictly decode to [TypedPersistedQuestion]; corrupt,
///    unsafe, or legacy targets fail closed;
/// 4. the decoded complete `QuestionDraftV2` must structurally equal
///    `candidate.expectedDraft`;
/// 5. the write-intent precondition must still hold (`fill` requires the
///    current answer to be null; `replace` requires a different non-null
///    current answer; `noOp` never reaches this boundary);
/// 6. the existing [TypedAnswerPersistenceKernel] reuses the same
///    caller-owned transaction for the answer-only mutation (sidecar +
///    V1 `standard_answer` projection; `review_states` untouched).
///
/// The repository owns the transaction; the kernel never starts or nests
/// one. Only `candidate.answer` enters formal persistence — no origin,
/// generation id, provider identity, candidate id, session revision,
/// provider payload, or explanation is ever written.
final class AiAnswerCommitRepository implements AiAnswerCommitPersistencePort {
  AiAnswerCommitRepository({
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
  Future<void> commitAnswer(AnswerCandidate candidate) async {
    // Defense in depth: only AI-origin candidates may reach the AI commit
    // boundary; the Application command already enforces this before any
    // transaction opens.
    if (candidate.origin is! AiAnswerOrigin) {
      throw const AiAnswerCommitException(
        AiAnswerCommitFailure.candidateNotCommittable,
      );
    }
    try {
      final db = await _databaseHelper.database;
      await db.transaction((txn) async {
        await _recheckDurableTarget(txn, candidate);
        await _kernel.applyAnswerUpdate(
          txn: _AiCommitTransactionExecutor(txn),
          storageId: candidate.targetStorageId,
          expectedDraft: candidate.expectedDraft,
          newAnswer: candidate.answer,
        );
        // The kernel revalidates the decoded draft equality inside the same
        // transaction; `current` here is only the P7 precondition projection.
      });
    } on AiAnswerCommitException {
      rethrow;
    } on TypedAnswerMutationException catch (error) {
      throw AiAnswerCommitException(_mapMutationFailure(error.failure));
    } on DatabaseException {
      throw const AiAnswerCommitException(
        AiAnswerCommitFailure.persistenceFailed,
      );
    }
  }

  /// Strict durable-target revalidation inside the caller's transaction.
  Future<void> _recheckDurableTarget(
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
      throw const AiAnswerCommitException(
        AiAnswerCommitFailure.staleTarget,
      );
    }
    final row = rows.single;
    if (row['bank_name'] != candidate.targetBankName) {
      throw const AiAnswerCommitException(
        AiAnswerCommitFailure.staleTarget,
      );
    }

    final PersistedQuestion decoded;
    try {
      decoded = _mapper.decodeJoinedRow(row);
    } on QuestionV2PayloadException {
      // Corrupt or unsafe sidecars fail closed; never a V1 fallback.
      throw const AiAnswerCommitException(
        AiAnswerCommitFailure.staleTarget,
      );
    }
    if (decoded is! TypedPersistedQuestion) {
      throw const AiAnswerCommitException(
        AiAnswerCommitFailure.staleTarget,
      );
    }
    if (decoded.draft != candidate.expectedDraft) {
      throw const AiAnswerCommitException(
        AiAnswerCommitFailure.staleTarget,
      );
    }

    switch (candidate.writeIntent) {
      case CandidateWriteIntent.fill:
        if (decoded.draft.answer != null) {
          throw const AiAnswerCommitException(
            AiAnswerCommitFailure.staleTarget,
          );
        }
      case CandidateWriteIntent.replace:
        final current = decoded.draft.answer;
        if (current == null || current == candidate.answer) {
          throw const AiAnswerCommitException(
            AiAnswerCommitFailure.staleTarget,
          );
        }
      case CandidateWriteIntent.noOp:
        // A noOp candidate never reaches the write boundary; the review
        // session and command already treat it as terminal.
        throw const AiAnswerCommitException(
          AiAnswerCommitFailure.candidateNotCommittable,
        );
    }
  }

  AiAnswerCommitFailure _mapMutationFailure(
    TypedAnswerMutationFailure failure,
  ) {
    return switch (failure) {
      TypedAnswerMutationFailure.notFound ||
      TypedAnswerMutationFailure.notTyped ||
      TypedAnswerMutationFailure.stale ||
      TypedAnswerMutationFailure.corruptPayload ||
      TypedAnswerMutationFailure.unsafePayload ||
      TypedAnswerMutationFailure.invalidAnswer =>
        AiAnswerCommitFailure.staleTarget,
      TypedAnswerMutationFailure.transactionFailed =>
        AiAnswerCommitFailure.persistenceFailed,
    };
  }
}

/// Adapts the caller-owned SQLite transaction to the shared kernel's minimal
/// transaction surface. The repository owns the transaction; the kernel
/// never starts or nests one.
final class _AiCommitTransactionExecutor
    implements TypedAnswerTransactionExecutor {
  const _AiCommitTransactionExecutor(this._txn);

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

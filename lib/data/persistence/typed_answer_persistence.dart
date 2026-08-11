import '../../domain/question/question_draft_v2.dart';
import '../models/persisted_question.dart';
import 'question_v2_persistence_mapper.dart';

/// Minimal transaction surface the typed-answer kernel needs from the
/// caller-owned transaction. The caller (repository) opens the SQLite
/// transaction and adapts its executor; the kernel never starts or nests a
/// transaction itself.
abstract interface class TypedAnswerTransactionExecutor {
  /// Runs one joined-row SELECT inside the caller's transaction.
  Future<List<Map<String, Object?>>> queryRaw(
    String sql, [
    List<Object?>? arguments,
  ]);

  /// Updates rows inside the caller's transaction and returns the affected
  /// row count.
  Future<int> update(
    String table,
    Map<String, Object?> values, {
    String? where,
    List<Object?>? whereArgs,
  });
}

/// Failure taxonomy of the frozen typed manual answer mutation boundary.
enum TypedAnswerMutationFailure {
  notFound,
  notTyped,
  stale,
  corruptPayload,
  invalidAnswer,
  unsafePayload,
  transactionFailed,
}

/// Raised when a typed manual answer mutation cannot be applied atomically.
/// The exception retains no raw cause, message, SQL, payload, path, storage
/// id, bank, or user content.
final class TypedAnswerMutationException implements Exception {
  const TypedAnswerMutationException(this.failure);

  final TypedAnswerMutationFailure failure;

  @override
  String toString() {
    final detail = switch (failure) {
      TypedAnswerMutationFailure.notFound =>
        'The typed question cannot be found.',
      TypedAnswerMutationFailure.notTyped =>
        'The question is not stored as a typed question.',
      TypedAnswerMutationFailure.stale =>
        'The question changed after it was loaded.',
      TypedAnswerMutationFailure.corruptPayload =>
        'The typed question payload cannot be read safely.',
      TypedAnswerMutationFailure.invalidAnswer =>
        'The answer does not match the typed question options.',
      TypedAnswerMutationFailure.unsafePayload =>
        'The typed answer contains unsafe content.',
      TypedAnswerMutationFailure.transactionFailed =>
        'The typed answer cannot be saved atomically.',
    };
    return 'TypedAnswerMutationException(${failure.name}): $detail';
  }
}

/// Transaction-scoped shared kernel for answer-only typed mutations.
///
/// Manual repair and the future W0 dedicated adapter both reuse this kernel
/// inside their own caller-owned transaction. The kernel itself never opens
/// a transaction and never narrows the generic mutation semantics: manual
/// replace / clear / valid no-op all remain supported. W0's fill-only policy
/// is enforced by the proposal layer, not here.
final class TypedAnswerPersistenceKernel {
  const TypedAnswerPersistenceKernel([
    this._mapper = const QuestionV2PersistenceMapper(),
  ]);

  final QuestionV2PersistenceMapper _mapper;

  /// Inside the caller's transaction, reads the joined row strictly, checks
  /// the decoded current draft equals [expectedDraft] structurally, validates
  /// the new answer against the current options, and atomically updates the
  /// V2 sidecar plus the V1 `standard_answer` projection. Each UPDATE must
  /// touch exactly one row and `review_states` is never modified. Every
  /// failure throws [TypedAnswerMutationException] with zero writes.
  Future<void> applyAnswerUpdate({
    required TypedAnswerTransactionExecutor txn,
    required String storageId,
    required QuestionDraftV2 expectedDraft,
    required QuestionAnswer? newAnswer,
  }) async {
    final rows = await txn.queryRaw(
      '''
      SELECT q.*,
             p.payload_schema_version AS ${QuestionV2PersistenceMapper.payloadSchemaVersionAlias},
             p.payload_json AS ${QuestionV2PersistenceMapper.payloadJsonAlias}
      FROM questions q
      LEFT JOIN question_v2_payloads p ON q.id = p.question_id
      WHERE q.id = ?
      ''',
      <Object?>[storageId],
    );
    if (rows.isEmpty) {
      throw const TypedAnswerMutationException(
        TypedAnswerMutationFailure.notFound,
      );
    }
    final row = rows.single;
    if (row[QuestionV2PersistenceMapper.payloadSchemaVersionAlias] == null &&
        row[QuestionV2PersistenceMapper.payloadJsonAlias] == null) {
      throw const TypedAnswerMutationException(
        TypedAnswerMutationFailure.notTyped,
      );
    }
    final current = _decodeTypedForMutation(row);
    if (current.draft != expectedDraft) {
      throw const TypedAnswerMutationException(
        TypedAnswerMutationFailure.stale,
      );
    }
    if (newAnswer case ChoiceAnswer(:final optionIds)) {
      // A no-op (the new answer equals the persisted answer) never
      // introduces invalid data, so pre-existing unknown or duplicate
      // choice identities remain no-op repairable. Only real changes are
      // validated against the current options.
      if (newAnswer != current.draft.answer) {
        final optionIdsInDraft = <String>{
          for (final option in current.draft.options) option.optionId,
        };
        final hasDuplicateIds = optionIds.toSet().length != optionIds.length;
        if (hasDuplicateIds || !optionIds.every(optionIdsInDraft.contains)) {
          throw const TypedAnswerMutationException(
            TypedAnswerMutationFailure.invalidAnswer,
          );
        }
      }
    }
    final replacementDraft = QuestionDraftV2(
      questionId: current.draft.questionId,
      kind: current.draft.kind,
      questionNumber: current.draft.questionNumber,
      stem: current.draft.stem,
      options: current.draft.options,
      answer: newAnswer,
      explanation: current.draft.explanation,
      sourceRefs: current.draft.sourceRefs,
      assetRefs: current.draft.assetRefs,
      issues: current.draft.issues,
    );
    final FrozenQuestionV2AnswerUpdate update;
    try {
      update = _mapper.freezeAnswerUpdate(
        storageId: storageId,
        replacementDraft: replacementDraft,
      );
    } on QuestionV2PayloadException {
      throw const TypedAnswerMutationException(
        TypedAnswerMutationFailure.unsafePayload,
      );
    }
    final payloadUpdated = await txn.update(
      'question_v2_payloads',
      <String, Object?>{
        'payload_schema_version': update.payloadRow['payload_schema_version'],
        'payload_json': update.payloadRow['payload_json'],
      },
      where: 'question_id = ?',
      whereArgs: <Object?>[storageId],
    );
    if (payloadUpdated != 1) {
      throw const TypedAnswerMutationException(
        TypedAnswerMutationFailure.transactionFailed,
      );
    }
    final questionUpdated = await txn.update(
      'questions',
      <String, Object?>{'standard_answer': update.standardAnswer},
      where: 'id = ?',
      whereArgs: <Object?>[storageId],
    );
    if (questionUpdated != 1) {
      throw const TypedAnswerMutationException(
        TypedAnswerMutationFailure.transactionFailed,
      );
    }
  }

  /// Strict joined-row decode for the typed mutation path. Corrupt sidecars
  /// map to [TypedAnswerMutationFailure.corruptPayload] and privacy
  /// admission failures to [TypedAnswerMutationFailure.unsafePayload],
  /// reusing [QuestionV2PersistenceMapper.decodeJoinedRow] semantics.
  TypedPersistedQuestion _decodeTypedForMutation(Map<String, Object?> row) {
    final PersistedQuestion decoded;
    try {
      decoded = _mapper.decodeJoinedRow(row);
    } on QuestionV2PayloadException catch (error) {
      throw TypedAnswerMutationException(
        error.failure == QuestionV2PayloadFailure.unsafePayload
            ? TypedAnswerMutationFailure.unsafePayload
            : TypedAnswerMutationFailure.corruptPayload,
      );
    }
    if (decoded is! TypedPersistedQuestion) {
      throw const TypedAnswerMutationException(
        TypedAnswerMutationFailure.notTyped,
      );
    }
    return decoded;
  }
}

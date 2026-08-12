import 'package:sqflite/sqflite.dart';

import '../../application/safe_write/agent_write_persistence.dart';
import '../../application/safe_write/agent_write_proposed_answer_policy.dart';
import '../../application/safe_write/typed_answer_command.dart';
import '../../core/database/database_helper.dart';
import '../../domain/conversations/conversation.dart';
import '../../domain/question/question_draft_v2.dart';
import '../models/persisted_question.dart';
import '../persistence/question_v2_persistence_mapper.dart';
import '../persistence/typed_answer_persistence.dart';

/// SQLite implementation of the W0 [AgentWritePersistencePort].
///
/// Staging admission authorizes source/scope/relation/target before any
/// preview-visible content is decoded or returned; unauthorized and
/// nonexistent targets share one safe denial shape and an authorized but
/// corrupt/unsafe typed target returns a distinct unavailable failure.
///
/// The approved commit runs every source/scope/relation/target/CAS and
/// fill-only recheck plus the shared typed-answer write inside one
/// caller-owned SQLite transaction, so any failed precondition or write
/// rolls the complete transaction back with zero formal writes.
final class ApprovedAgentWriteRepository
    implements AgentWritePersistencePort, AgentWriteReconciliationPort {
  ApprovedAgentWriteRepository({DatabaseHelper? databaseHelper})
      : _databaseHelper = databaseHelper ?? DatabaseHelper.instance;

  static final ApprovedAgentWriteRepository instance =
      ApprovedAgentWriteRepository();

  final DatabaseHelper _databaseHelper;
  static const QuestionV2PersistenceMapper _mapper =
      QuestionV2PersistenceMapper();
  static const TypedAnswerPersistenceKernel _kernel =
      TypedAnswerPersistenceKernel();
  static const AgentWriteProposedAnswerPolicy _answerPolicy =
      AgentWriteProposedAnswerPolicy();

  @override
  Future<AgentWriteAdmissionResult> admitStagingTarget(
    AgentWriteAdmissionRequest request,
  ) async {
    _validateRequestIds(
      request.sourceConversationId,
      request.sourceMessageId,
      request.targetStorageId,
    );
    try {
      final db = await _databaseHelper.database;
      return await db.transaction((txn) async {
        final storedScope = await _conversationScope(
          txn,
          request.sourceConversationId,
        );
        if (storedScope == null ||
            request.scope.isUnavailableLearningSpace ||
            storedScope != request.scope) {
          return const AgentWriteAdmissionDenied();
        }
        if (!await _isUserMessage(
          txn,
          request.sourceMessageId,
          request.sourceConversationId,
        )) {
          return const AgentWriteAdmissionDenied();
        }
        final bankName = await _targetBankName(txn, request.targetStorageId);
        if (bankName == null ||
            !await _isBankAuthorized(txn, request.scope, bankName)) {
          return const AgentWriteAdmissionDenied();
        }
        final joined = await _joinedTargetRow(txn, request.targetStorageId);
        if (joined == null) return const AgentWriteAdmissionDenied();
        final admitted = _decodeForAdmission(joined);
        if (admitted == null) return const AgentWriteAdmissionDenied();
        if (admitted is AgentWriteAdmissionUnavailable) return admitted;
        final typed = admitted as TypedPersistedQuestion;
        return AgentWriteAdmissionGranted(
          AgentWriteAdmittedTarget(
            storageId: typed.storageId,
            bankName: typed.bankName,
            draft: typed.draft,
          ),
        );
      });
    } on DatabaseException {
      // Admission has no safe recovery; deny rather than leak or crash.
      return const AgentWriteAdmissionDenied();
    }
  }

  @override
  Future<void> commitApproved(AgentWriteCommitRequest request) async {
    _validateRequestIds(
      request.sourceConversationId,
      request.sourceMessageId,
      request.targetStorageId,
    );
    if (request.expectedBankName.trim().isEmpty) {
      throw ArgumentError('Expected bank name is required.');
    }
    try {
      final db = await _databaseHelper.database;
      await db.transaction((txn) async {
        final storedScope = await _conversationScope(
          txn,
          request.sourceConversationId,
        );
        if (storedScope == null) {
          throw const TypedAnswerMutationException(
            TypedAnswerMutationFailure.notFound,
          );
        }
        if (storedScope != request.scope) {
          throw const TypedAnswerMutationException(
            TypedAnswerMutationFailure.stale,
          );
        }
        final role = await _messageRole(
          txn,
          request.sourceMessageId,
          request.sourceConversationId,
        );
        if (role == null) {
          throw const TypedAnswerMutationException(
            TypedAnswerMutationFailure.notFound,
          );
        }
        if (role != 'user') {
          throw const TypedAnswerMutationException(
            TypedAnswerMutationFailure.stale,
          );
        }
        final bankName = await _targetBankName(txn, request.targetStorageId);
        if (bankName == null) {
          throw const TypedAnswerMutationException(
            TypedAnswerMutationFailure.notFound,
          );
        }
        if (bankName != request.expectedBankName ||
            !await _isBankAuthorized(txn, request.scope, bankName)) {
          throw const TypedAnswerMutationException(
            TypedAnswerMutationFailure.stale,
          );
        }

        // Fill-only recheck and structural validation (defense-in-depth).
        final joined = await _joinedTargetRow(txn, request.targetStorageId);
        if (joined == null) {
          throw const TypedAnswerMutationException(
            TypedAnswerMutationFailure.notFound,
          );
        }
        final current = _decodeForCommit(joined);
        if (current.draft != request.expectedDraft) {
          throw const TypedAnswerMutationException(
            TypedAnswerMutationFailure.stale,
          );
        }
        if (current.draft.answer != null) {
          throw const TypedAnswerMutationException(
            TypedAnswerMutationFailure.stale,
          );
        }
        if (!_answerPolicy.isValidForDraft(
          request.proposedAnswer,
          current.draft,
        )) {
          throw const TypedAnswerMutationException(
            TypedAnswerMutationFailure.invalidAnswer,
          );
        }

        await _kernel.applyAnswerUpdate(
          txn: _TransactionExecutorAdapter(txn),
          storageId: request.targetStorageId,
          expectedDraft: request.expectedDraft,
          newAnswer: request.proposedAnswer,
        );
      });
    } on TypedAnswerMutationException {
      rethrow;
    } on DatabaseException {
      throw const TypedAnswerMutationException(
        TypedAnswerMutationFailure.transactionFailed,
      );
    }
  }

  @override
  Future<AgentWriteReconciliationResult> reconcileAfterAmbiguousCommit(
    AgentWriteReconciliationRequest request,
  ) async {
    _validateRequestIds(
      request.sourceConversationId,
      request.sourceMessageId,
      request.targetStorageId,
    );
    if (request.expectedBankName.trim().isEmpty) {
      throw ArgumentError('Expected bank name is required.');
    }
    try {
      final db = await _databaseHelper.database;
      return await db.transaction((txn) async {
        // The same source/scope/relation/target authority as the COMMIT
        // transaction; every failed precondition is unconfirmable.
        final storedScope = await _conversationScope(
          txn,
          request.sourceConversationId,
        );
        if (storedScope == null ||
            request.scope.isUnavailableLearningSpace ||
            storedScope != request.scope) {
          return const AgentWriteReconciliationUnavailable();
        }
        final role = await _messageRole(
          txn,
          request.sourceMessageId,
          request.sourceConversationId,
        );
        if (role != 'user') {
          return const AgentWriteReconciliationUnavailable();
        }
        final bankName = await _targetBankName(txn, request.targetStorageId);
        if (bankName == null ||
            bankName != request.expectedBankName ||
            !await _isBankAuthorized(txn, request.scope, bankName)) {
          return const AgentWriteReconciliationUnavailable();
        }
        final joined = await _joinedTargetRow(txn, request.targetStorageId);
        if (joined == null) {
          return const AgentWriteReconciliationUnavailable();
        }
        final TypedPersistedQuestion current;
        try {
          final decoded = _mapper.decodeJoinedRow(joined);
          if (decoded is! TypedPersistedQuestion) {
            return const AgentWriteReconciliationUnavailable();
          }
          current = decoded;
        } on QuestionV2PayloadException {
          return const AgentWriteReconciliationUnavailable();
        }
        if (current.draft == request.expectedDraft) {
          return const AgentWriteReconciliationBaseline();
        }
        if (current.draft == _postImage(request)) {
          return const AgentWriteReconciliationCommitted();
        }
        return const AgentWriteReconciliationConflicted();
      });
    } on DatabaseException {
      return const AgentWriteReconciliationUnavailable();
    }
  }

  void _validateRequestIds(
    String conversationId,
    String messageId,
    String storageId,
  ) {
    if (conversationId.trim().isEmpty || messageId.trim().isEmpty) {
      throw ArgumentError('Source Conversation and Message ids are required.');
    }
    if (storageId.trim().isEmpty) {
      throw ArgumentError('Target storage id is required.');
    }
  }

  /// Reads the persisted Conversation scope, or null when the Conversation
  /// does not exist. Unknown scope kinds decode to an unavailable scope so
  /// both admission and commit fail safely.
  Future<ConversationScope?> _conversationScope(
    DatabaseExecutor txn,
    String conversationId,
  ) async {
    final rows = await txn.query(
      'conversations',
      columns: const <String>['scope_kind', 'project_id'],
      where: 'conversation_id = ?',
      whereArgs: <Object?>[conversationId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return switch (rows.single['scope_kind']) {
      'global' => ConversationScope.global(),
      'learning_space' => rows.single['project_id'] == null
          ? ConversationScope.unavailableLearningSpace()
          : ConversationScope.learningSpace(
              rows.single['project_id']! as String,
            ),
      _ => ConversationScope.unavailableLearningSpace(),
    };
  }

  Future<bool> _isUserMessage(
    DatabaseExecutor txn,
    String messageId,
    String conversationId,
  ) async {
    return await _messageRole(txn, messageId, conversationId) == 'user';
  }

  Future<String?> _messageRole(
    DatabaseExecutor txn,
    String messageId,
    String conversationId,
  ) async {
    final rows = await txn.query(
      'conversation_messages',
      columns: const <String>['role'],
      where: 'message_id = ? AND conversation_id = ?',
      whereArgs: <Object?>[messageId, conversationId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final role = rows.single['role'];
    return role is String ? role : null;
  }

  Future<String?> _targetBankName(
    DatabaseExecutor txn,
    String storageId,
  ) async {
    final rows = await txn.query(
      'questions',
      columns: const <String>['bank_name'],
      where: 'id = ?',
      whereArgs: <Object?>[storageId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final bankName = rows.single['bank_name'];
    return bankName is String ? bankName : null;
  }

  /// Global scope admits any eligible local target; Learning Space scope
  /// requires the current Project and the current
  /// `project_banks(project_id, bank_name)` relation.
  Future<bool> _isBankAuthorized(
    DatabaseExecutor txn,
    ConversationScope scope,
    String bankName,
  ) async {
    if (scope.kind == ConversationScopeKind.global) return true;
    final projectId = scope.projectId;
    if (projectId == null) return false;
    final project = await txn.query(
      'projects',
      columns: const <String>['project_id'],
      where: 'project_id = ?',
      whereArgs: <Object?>[projectId],
      limit: 1,
    );
    if (project.isEmpty) return false;
    final relation = await txn.query(
      'project_banks',
      columns: const <String>['bank_name'],
      where: 'project_id = ? AND bank_name = ?',
      whereArgs: <Object?>[projectId, bankName],
      limit: 1,
    );
    return relation.isNotEmpty;
  }

  Future<Map<String, Object?>?> _joinedTargetRow(
    DatabaseExecutor txn,
    String storageId,
  ) async {
    final rows = await txn.rawQuery(
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
    if (rows.isEmpty) return null;
    return rows.single;
  }

  /// Admission decode: null means ineligible (legacy row) and maps to the
  /// safe denial shape; a payload failure maps to the distinct unavailable
  /// category without payload or content.
  Object? _decodeForAdmission(Map<String, Object?> row) {
    try {
      final decoded = _mapper.decodeJoinedRow(row);
      return decoded is TypedPersistedQuestion ? decoded : null;
    } on QuestionV2PayloadException {
      return const AgentWriteAdmissionUnavailable();
    }
  }

  /// Strict joined-row decode for the commit path. Corrupt sidecars map to
  /// [TypedAnswerMutationFailure.corruptPayload] and privacy admission
  /// failures to [TypedAnswerMutationFailure.unsafePayload].
  TypedPersistedQuestion _decodeForCommit(Map<String, Object?> row) {
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

  /// Exact fill-missing-answer post-image: the expected baseline draft with
  /// only the proposed answer applied and every other field preserved.
  QuestionDraftV2 _postImage(AgentWriteReconciliationRequest request) {
    final expected = request.expectedDraft;
    return QuestionDraftV2(
      questionId: expected.questionId,
      kind: expected.kind,
      questionNumber: expected.questionNumber,
      stem: expected.stem,
      options: expected.options,
      answer: request.proposedAnswer,
      explanation: expected.explanation,
      sourceRefs: expected.sourceRefs,
      assetRefs: expected.assetRefs,
      issues: expected.issues,
    );
  }
}

/// Adapts the caller-owned SQLite transaction to the shared kernel's minimal
/// transaction surface. The repository owns the transaction; the kernel
/// never starts or nests one.
final class _TransactionExecutorAdapter
    implements TypedAnswerTransactionExecutor {
  _TransactionExecutorAdapter(this._txn);

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
    return _txn.update(table, values, where: where, whereArgs: whereArgs);
  }
}

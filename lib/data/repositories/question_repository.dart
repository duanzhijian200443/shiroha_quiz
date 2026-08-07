import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../core/database/database_helper.dart';
import '../../domain/question/question_draft_v2.dart';
import '../models/persisted_question.dart';
import '../models/question_draft.dart';
import '../models/subject_tree_index.dart';
import '../models/typed_import_commit_guard.dart';
import '../persistence/question_v2_persistence_mapper.dart';
import '../../utils/ai_data_sanitizer.dart';
import '../../data/repositories/settings_repository.dart';

const String _globalWrongBookBankName = '🔥 全局错题本';

class QuestionRepository {
  QuestionRepository({DatabaseHelper? databaseHelper, Uuid? uuid})
      : _databaseHelper = databaseHelper ?? DatabaseHelper.instance,
        _uuid = uuid ?? const Uuid();

  static final QuestionRepository instance = QuestionRepository();

  final DatabaseHelper _databaseHelper;
  final Uuid _uuid;
  static const QuestionV2PersistenceMapper _mapper =
      QuestionV2PersistenceMapper();

  Future<void> saveQuestionsToBank({
    required String bankName,
    required String? folderName,
    required List<Map<String, dynamic>> questions,
  }) async {
    return saveQuestionDraftsToBank(
      bankName: bankName,
      folderName: folderName,
      questions: QuestionDraft.listFromMaps(questions),
    );
  }

  Future<void> saveQuestionDraftsToBank({
    required String bankName,
    required String? folderName,
    required List<QuestionDraft> questions,
  }) async {
    final trimmedBankName = bankName.trim();
    if (trimmedBankName.isEmpty) {
      throw ArgumentError.value(bankName, 'bankName', 'Bank name is required.');
    }
    if (questions.isEmpty) return;

    final db = await _databaseHelper.database;
    final nowUnix = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    await db.transaction((txn) async {
      for (final question in questions) {
        final row = _questionToRow(
          question,
          bankName: trimmedBankName,
          createdAt: nowUnix,
        );
        await txn.insert('questions', row);
        await txn.insert(
          'review_states',
          _initialReviewState(row['id'] as String),
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
    });

    await _syncBankFolder(trimmedBankName, folderName);
  }

  /// Typed additive V2 persistence: writes the full V2 payload sidecar, the
  /// V1 compatibility row, and the initial review state for every draft in
  /// one atomic SQLite transaction, then optionally upserts the frozen
  /// folder mapping inside the same transaction.
  ///
  /// All mapper/privacy/format failures happen before the transaction and
  /// propagate their safe typed errors with zero database writes. The
  /// folder-decision reads and the folder upsert share the transaction
  /// executor and snapshot, so folder state cannot change between the reads
  /// and the write. Every [DatabaseException] from the folder reads, the
  /// database handle, or the transaction maps to the fixed
  /// [QuestionV2WriteException].
  Future<void> saveQuestionDraftsV2ToBank({
    required String bankName,
    required String? folderName,
    required List<QuestionDraftV2> questions,
  }) async {
    final trimmedBankName = bankName.trim();
    if (trimmedBankName.isEmpty) {
      throw ArgumentError('Bank name is required.');
    }
    if (questions.isEmpty) return;

    final nowUtcSeconds = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    final frozenWrites = _freezeV2Writes(
      bankName: trimmedBankName,
      questions: questions,
      createdAt: nowUtcSeconds,
    );

    try {
      final db = await _databaseHelper.database;
      await db.transaction((txn) async {
        await _writeFrozenV2Batch(
          txn,
          bankName: trimmedBankName,
          folderName: folderName,
          frozenWrites: frozenWrites,
        );
      });
    } on DatabaseException {
      throw const QuestionV2WriteException(
        QuestionV2WriteFailure.transactionFailed,
      );
    }
  }

  /// Attempt-aware atomic typed import commit.
  ///
  /// Runs the persisted `import_tasks` ownership gate, the folder decision,
  /// the question/payload/review-state writes, the folder mapping upsert and
  /// the compare-and-set `import_tasks` completion update in one SQLite
  /// transaction. Any ownership mismatch, CAS mismatch or database failure
  /// rolls the whole transaction back with zero question rows and the task
  /// still `pendingReview`.
  ///
  /// [guard] carries the exact attempt/revision/route/reason expected from
  /// the persisted `import_tasks.diagnostics`; the persisted values are
  /// decoded strictly (no `toString()` repair, no trimming, no guessing).
  Future<TypedImportCommitPersistenceResult> commitQuestionDraftsV2ForImport({
    required String bankName,
    required String? folderName,
    required List<QuestionDraftV2> questions,
    required TypedImportCommitGuard guard,
    required String completionText,
  }) async {
    final trimmedBankName = bankName.trim();
    if (trimmedBankName.isEmpty) {
      throw ArgumentError('Bank name is required.');
    }
    if (questions.isEmpty) {
      throw ArgumentError('At least one question is required.');
    }
    _validateImportCommitGuard(guard);

    final nowUtcSeconds = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    final frozenWrites = _freezeV2Writes(
      bankName: trimmedBankName,
      questions: questions,
      createdAt: nowUtcSeconds,
    );

    try {
      final db = await _databaseHelper.database;
      return await db.transaction((txn) async {
        await _validatePersistedImportTask(txn, guard);
        await _writeFrozenV2Batch(
          txn,
          bankName: trimmedBankName,
          folderName: folderName,
          frozenWrites: frozenWrites,
        );
        final updated = await txn.update(
          'import_tasks',
          <String, Object?>{
            'status': TypedImportCommitPersistence.completedStatusCode,
            'progress_text': completionText,
            'percent': 1.0,
            'error_msg': null,
            'parsed_data': null,
            'completed_at': nowUtcSeconds,
          },
          where: 'id = ? AND status = ?',
          whereArgs: <Object?>[
            guard.taskId,
            TypedImportCommitPersistence.pendingReviewStatusCode,
          ],
        );
        if (updated != 1) {
          throw const TypedImportCommitPersistenceException(
            TypedImportCommitPersistenceFailure.transactionFailed,
          );
        }
        return TypedImportCommitPersistenceResult(
          questionCount: frozenWrites.length,
          completedAt: nowUtcSeconds,
        );
      });
    } on TypedImportCommitPersistenceException {
      rethrow;
    } on DatabaseException {
      throw const TypedImportCommitPersistenceException(
        TypedImportCommitPersistenceFailure.transactionFailed,
      );
    }
  }

  void _validateImportCommitGuard(TypedImportCommitGuard guard) {
    final guardValid = guard.taskId.trim().isNotEmpty &&
        guard.attemptToken.trim().isNotEmpty &&
        guard.attemptNumber > 0 &&
        guard.reviewDraftRevision > 0 &&
        guard.storageRoute == TypedImportCommitPersistence.typedV2RouteValue &&
        guard.storageReason ==
            TypedImportCommitPersistence.typedCandidateReadyReasonValue;
    if (!guardValid) {
      throw ArgumentError('Typed import commit guard is invalid.');
    }
  }

  /// Strict persisted `import_tasks` ownership gate (P2-A, second location).
  ///
  /// Must match exactly one row. Every attempt/revision/route/reason value is
  /// decoded from the diagnostics JSON with strict types; the status must be
  /// the frozen pendingReview code and `parsed_data` must be non-null.
  Future<void> _validatePersistedImportTask(
    DatabaseExecutor txn,
    TypedImportCommitGuard guard,
  ) async {
    final rows = await txn.query(
      'import_tasks',
      where: 'id = ?',
      whereArgs: <Object?>[guard.taskId],
      limit: 2,
    );
    if (rows.isEmpty) {
      throw const TypedImportCommitPersistenceException(
        TypedImportCommitPersistenceFailure.taskMissing,
      );
    }
    if (rows.length != 1) {
      throw const TypedImportCommitPersistenceException(
        TypedImportCommitPersistenceFailure.invalidTaskMetadata,
      );
    }
    final row = rows.single;
    final status = row['status'];
    if (status is! int ||
        status != TypedImportCommitPersistence.pendingReviewStatusCode) {
      if (status is int &&
          status == TypedImportCommitPersistence.completedStatusCode) {
        throw const TypedImportCommitPersistenceException(
          TypedImportCommitPersistenceFailure.alreadyCompleted,
        );
      }
      throw const TypedImportCommitPersistenceException(
        TypedImportCommitPersistenceFailure.taskNotPendingReview,
      );
    }
    final parsedData = row['parsed_data'];
    if (parsedData is! String || parsedData.isEmpty) {
      throw const TypedImportCommitPersistenceException(
        TypedImportCommitPersistenceFailure.invalidTaskMetadata,
      );
    }
    final diagnosticsText = row['diagnostics'];
    if (diagnosticsText is! String || diagnosticsText.isEmpty) {
      throw const TypedImportCommitPersistenceException(
        TypedImportCommitPersistenceFailure.invalidTaskMetadata,
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(diagnosticsText);
    } on FormatException {
      throw const TypedImportCommitPersistenceException(
        TypedImportCommitPersistenceFailure.invalidTaskMetadata,
      );
    }
    if (decoded is! Map) {
      throw const TypedImportCommitPersistenceException(
        TypedImportCommitPersistenceFailure.invalidTaskMetadata,
      );
    }
    final diagnostics = <String, Object?>{};
    for (final entry in decoded.entries) {
      if (entry.key is! String) {
        throw const TypedImportCommitPersistenceException(
          TypedImportCommitPersistenceFailure.invalidTaskMetadata,
        );
      }
      diagnostics[entry.key as String] = entry.value;
    }

    final attemptToken =
        diagnostics[TypedImportCommitPersistence.keyAttemptToken];
    if (attemptToken is! String) {
      throw const TypedImportCommitPersistenceException(
        TypedImportCommitPersistenceFailure.invalidTaskMetadata,
      );
    }
    if (attemptToken != guard.attemptToken) {
      throw const TypedImportCommitPersistenceException(
        TypedImportCommitPersistenceFailure.staleAttempt,
      );
    }

    final attemptNumber =
        diagnostics[TypedImportCommitPersistence.keyAttemptNumber];
    if (attemptNumber is! int || attemptNumber <= 0) {
      throw const TypedImportCommitPersistenceException(
        TypedImportCommitPersistenceFailure.invalidTaskMetadata,
      );
    }
    if (attemptNumber != guard.attemptNumber) {
      throw const TypedImportCommitPersistenceException(
        TypedImportCommitPersistenceFailure.staleAttempt,
      );
    }

    final attemptState =
        diagnostics[TypedImportCommitPersistence.keyAttemptState];
    if (attemptState is! String ||
        attemptState !=
            TypedImportCommitPersistence.readyForReviewAttemptStateValue) {
      throw const TypedImportCommitPersistenceException(
        TypedImportCommitPersistenceFailure.invalidTaskMetadata,
      );
    }

    final route =
        diagnostics[TypedImportCommitPersistence.keyImportStorageRoute];
    if (route is! String ||
        route != TypedImportCommitPersistence.typedV2RouteValue) {
      throw const TypedImportCommitPersistenceException(
        TypedImportCommitPersistenceFailure.invalidTaskMetadata,
      );
    }

    final reason =
        diagnostics[TypedImportCommitPersistence.keyImportStorageReason];
    if (reason is! String ||
        reason != TypedImportCommitPersistence.typedCandidateReadyReasonValue) {
      throw const TypedImportCommitPersistenceException(
        TypedImportCommitPersistenceFailure.invalidTaskMetadata,
      );
    }

    final revision =
        diagnostics[TypedImportCommitPersistence.keyReviewDraftRevision];
    if (revision is! int || revision <= 0) {
      throw const TypedImportCommitPersistenceException(
        TypedImportCommitPersistenceFailure.invalidTaskMetadata,
      );
    }
    if (revision != guard.reviewDraftRevision) {
      throw const TypedImportCommitPersistenceException(
        TypedImportCommitPersistenceFailure.staleReviewDraft,
      );
    }
  }

  /// Shared V2 freeze step used by both public typed write APIs.
  List<FrozenQuestionV2Write> _freezeV2Writes({
    required String bankName,
    required List<QuestionDraftV2> questions,
    required int createdAt,
  }) {
    return <FrozenQuestionV2Write>[
      for (final draft in questions)
        _mapper.freezeForWrite(
          storageId: _uuid.v4(),
          bankName: bankName,
          createdAt: createdAt,
          draft: draft,
        ),
    ];
  }

  /// Shared in-transaction V2 batch write: folder decision, parent rows,
  /// sidecar rows, initial review states and the folder mapping upsert.
  Future<void> _writeFrozenV2Batch(
    DatabaseExecutor txn, {
    required String bankName,
    required String? folderName,
    required List<FrozenQuestionV2Write> frozenWrites,
  }) async {
    final resolvedFolderName =
        await _resolveV2FolderAction(txn, bankName, folderName);
    for (final frozenWrite in frozenWrites) {
      await txn.insert('questions', frozenWrite.questionRow);
      await txn.insert('question_v2_payloads', frozenWrite.payloadRow);
      await txn.insert(
        'review_states',
        _initialReviewState(frozenWrite.questionRow['id']! as String),
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
    if (resolvedFolderName != null) {
      await txn.insert(
        'bank_folders',
        <String, Object?>{
          'bank_name': bankName,
          'folder_name': resolvedFolderName,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
  }

  /// Frozen typed-save folder rule. An explicit non-empty folder name wins;
  /// otherwise the bank keeps its own name only when it already exists as a
  /// custom folder or as a folder mapped inside `bank_folders`. The
  /// `custom_folders` table is never created here; it is consulted only when
  /// sqlite_master reports that it exists. All reads run on the caller's
  /// [DatabaseExecutor] so they share the active transaction snapshot.
  Future<String?> _resolveV2FolderAction(
    DatabaseExecutor executor,
    String bankName,
    String? folderName,
  ) async {
    final trimmedFolderName = folderName?.trim() ?? '';
    if (trimmedFolderName.isNotEmpty) return trimmedFolderName;

    final customFoldersTable = await executor.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' "
      "AND name = 'custom_folders'",
    );
    if (customFoldersTable.isNotEmpty) {
      final customMatch = await executor.query(
        'custom_folders',
        columns: ['name'],
        where: 'name = ?',
        whereArgs: [bankName],
        limit: 1,
      );
      if (customMatch.isNotEmpty) return bankName;
    }

    final folderMatch = await executor.query(
      'bank_folders',
      columns: ['folder_name'],
      where: 'folder_name = ?',
      whereArgs: [bankName],
      limit: 1,
    );
    if (folderMatch.isNotEmpty) return bankName;

    return null;
  }

  Future<SubjectTreeIndex> getSubjectTreeIndex() async {
    return SubjectTreeIndex.fromRawTree(await _databaseHelper.getSubjectTree());
  }

  Future<List<String>> getAvailableBanksAndFolders() async {
    final index = await getSubjectTreeIndex();
    return index.availableBanksAndFolders;
  }

  Future<List<String>> getAvailableFolders() async {
    final index = await getSubjectTreeIndex();
    return index.availableFolders;
  }

  Future<void> deleteQuestion(String id) {
    return _databaseHelper.deleteSingleQuestion(id);
  }

  /// Delete an entire question bank and clear the current-bank cache if needed.
  Future<void> deleteQuestionBank(String bankName) async {
    await _databaseHelper.deleteQuestionBank(bankName);
    // If the deleted bank was the active one, reset the cached value.
    final current = await SettingsRepository.instance.getCurrentBank();
    if (current == bankName) {
      await SettingsRepository.instance.setCurrentBank('点击修改选择题库');
    }
  }

  // ---------------------------------------------------------------------------
  // Subject-tree & folder management
  // Advanced data structure: the tree is now modelled by SubjectTreeIndex,
  // providing robust normalization, duplicate protection, and unmodifiable indices.
  // ---------------------------------------------------------------------------

  Future<Map<String, List<Map<String, dynamic>>>> getSubjectTree() {
    return _databaseHelper.getSubjectTree();
  }

  Future<void> addCustomFolder(String folderName) {
    return _databaseHelper.addCustomFolder(folderName);
  }

  Future<void> updateBankFolder(String bankName, String folderName) {
    return _databaseHelper.updateBankFolder(bankName, folderName);
  }

  Future<String> getFolderForBank(String bankName) {
    return _databaseHelper.getFolderForBank(bankName);
  }

  // ---------------------------------------------------------------------------
  // Question read / edit
  // ---------------------------------------------------------------------------

  /// Typed dual-read: V2 sidecar rows decode through the persistence mapper;
  /// wholly legacy rows fall back to [LegacyPersistedQuestion]. Any corrupt,
  /// partial, or unsafe sidecar fails the whole list without V1 fallback.
  Future<List<PersistedQuestion>> getPersistedQuestionsByBank(
    String bankName,
  ) async {
    final trimmedBankName = bankName.trim();
    if (trimmedBankName.isEmpty) {
      throw ArgumentError('Bank name is required.');
    }

    final db = await _databaseHelper.database;
    final rows = trimmedBankName == _globalWrongBookBankName
        ? await _queryWrongBookRows(db)
        : await db.rawQuery('''
            SELECT q.*,
                   p.payload_schema_version AS ${QuestionV2PersistenceMapper.payloadSchemaVersionAlias},
                   p.payload_json AS ${QuestionV2PersistenceMapper.payloadJsonAlias}
            FROM questions q
            LEFT JOIN question_v2_payloads p ON q.id = p.question_id
            WHERE q.bank_name = ?
            ORDER BY q.created_at DESC
          ''', [trimmedBankName]);

    return rows
        .map((row) => _attachReviewMetrics(_mapper.decodeJoinedRow(row), row))
        .toList(growable: false);
  }

  /// Typed wrong-book read: lapsed rows from every bank with their review
  /// metrics. Wrong-book filtering (`lapses > 0`) and ordering (last lapse
  /// time descending) stay in SQL at the repository boundary; the UI never
  /// joins `review_states` itself.
  Future<List<PersistedQuestion>> getPersistedWrongQuestions() async {
    final db = await _databaseHelper.database;
    final rows = await _queryWrongBookRows(db);
    return rows
        .map((row) => _attachReviewMetrics(_mapper.decodeJoinedRow(row), row))
        .toList(growable: false);
  }

  Future<List<Map<String, Object?>>> _queryWrongBookRows(Database db) {
    return db.rawQuery('''
      SELECT q.*,
             r.lapses,
             r.difficulty,
             r.stability,
             r.last_lapse_time,
             p.payload_schema_version AS ${QuestionV2PersistenceMapper.payloadSchemaVersionAlias},
             p.payload_json AS ${QuestionV2PersistenceMapper.payloadJsonAlias}
      FROM questions q
      JOIN review_states r ON q.id = r.question_id
      LEFT JOIN question_v2_payloads p ON q.id = p.question_id
      WHERE r.lapses > 0
      ORDER BY r.last_lapse_time DESC
    ''');
  }

  /// Projects the joined `review_states` columns into [PersistedQuestionReviewMetrics].
  /// Returns null when the read did not join `review_states` (regular bank
  /// list). Presentation metrics decode leniently: wrong types or missing
  /// values degrade to zero rather than failing the whole list.
  PersistedQuestionReviewMetrics? _decodeReviewMetrics(
    Map<String, Object?> row,
  ) {
    final lapses = row['lapses'];
    final difficulty = row['difficulty'];
    final stability = row['stability'];
    final lastLapseTime = row['last_lapse_time'];
    if (lapses == null &&
        difficulty == null &&
        stability == null &&
        lastLapseTime == null) {
      return null;
    }
    return PersistedQuestionReviewMetrics(
      lapses: lapses is num ? lapses.toInt() : 0,
      difficulty: difficulty is num ? difficulty.toDouble() : 0.0,
      stability: stability is num ? stability.toDouble() : 0.0,
      lastLapseTime: lastLapseTime is num ? lastLapseTime.toInt() : 0,
    );
  }

  /// Rebuilds the decoded union row with review metrics when the read joined
  /// `review_states`; otherwise returns the decoded row unchanged.
  PersistedQuestion _attachReviewMetrics(
    PersistedQuestion question,
    Map<String, Object?> row,
  ) {
    final metrics = _decodeReviewMetrics(row);
    if (metrics == null) return question;
    return switch (question) {
      TypedPersistedQuestion(
        :final storageId,
        :final bankName,
        :final createdAt,
        :final draft,
      ) =>
        TypedPersistedQuestion(
          storageId: storageId,
          bankName: bankName,
          createdAt: createdAt,
          draft: draft,
          reviewMetrics: metrics,
        ),
      LegacyPersistedQuestion(:final question) => LegacyPersistedQuestion(
          question: question,
          reviewMetrics: metrics,
        ),
    };
  }

  Future<void> updateQuestion(Map<String, dynamic> question) {
    return _databaseHelper.updateQuestion(question);
  }

  Future<List<Map<String, dynamic>>> getQuestionBanksSummary() {
    return _databaseHelper.getQuestionBanksSummary();
  }

  // ---------------------------------------------------------------------------
  // Pomodoro session
  // ---------------------------------------------------------------------------

  Future<void> insertPomodoroSession(Map<String, dynamic> session) {
    return _databaseHelper.insertPomodoroSession(session);
  }

  // ---------------------------------------------------------------------------
  // Heatmap
  // ---------------------------------------------------------------------------

  /// Returns a date → review-count map for the activity heatmap.
  Future<Map<DateTime, int>> getHeatmapData() {
    return _databaseHelper.getHeatmapData();
  }

  // ---------------------------------------------------------------------------
  // Preview-question persistence
  // Replaces the inline DatabaseHelper.instance.database usage in practice_page.
  // ---------------------------------------------------------------------------

  Future<void> savePreviewQuestion(Map<String, dynamic> question) async {
    final db = await _databaseHelper.database;
    final now = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;

    final rawId = (question['id'] as String?) ?? _uuid.v4();
    final cleanId = rawId.replaceAll('preview_', '');
    final type = (question['type'] as int?) ?? 0;

    final content = (question['content'] as String?)?.trim() ?? '';
    final options = question['options'] as String? ?? '[]';
    final answer = (question['standard_answer'] as String?)?.trim() ?? '';
    final bankName = (question['bank_name'] as String?)?.trim() ?? '默认题库';

    final row = <String, dynamic>{
      'id': cleanId,
      'type': type,
      'content': content.isEmpty ? '无题干' : content,
      'options': options,
      'standard_answer': answer.isEmpty ? '暂无答案' : answer,
      'created_at': now,
      'bank_name': bankName.isEmpty ? '默认题库' : bankName,
    };

    await db.transaction((txn) async {
      // A preview id that collides with a typed row must never REPLACE the
      // typed parent or cascade its sidecar away.
      final sidecar = await txn.query(
        'question_v2_payloads',
        columns: ['question_id'],
        where: 'question_id = ?',
        whereArgs: [cleanId],
        limit: 1,
      );
      if (sidecar.isNotEmpty) {
        throw const QuestionV2LegacyMutationBlockedException();
      }
      await txn.insert(
        'questions',
        row,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await txn.insert(
        'review_states',
        {
          'question_id': cleanId,
          'state': 0,
          'difficulty': 5.0,
          'stability': 0.0,
          'next_review_time': now,
          'reps': 0,
          'lapses': 0,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    });
  }

  Map<String, dynamic> _questionToRow(
    QuestionDraft question, {
    required String bankName,
    required int createdAt,
  }) {
    final explanation = AiDataSanitizer.cleanLatexBeforeDB(
      question.explanation,
    );
    final answer = AiDataSanitizer.cleanLatexBeforeDB(
      question.standardAnswer,
    );

    return {
      'id': _uuid.v4(),
      'bank_name': bankName,
      'type': question.type.code,
      'content': AiDataSanitizer.cleanLatexBeforeDB(
        question.content.trim().isEmpty ? '无题干' : question.content,
      ),
      'options': jsonEncode(
        question.options
            .map(AiDataSanitizer.cleanLatexBeforeDB)
            .toList(growable: false),
      ),
      'standard_answer': '$answer|||$explanation',
      'explanation': explanation,
      'raw_explanation': question.rawExplanation == null
          ? null
          : AiDataSanitizer.cleanLatexBeforeDB(question.rawExplanation!),
      'created_at': createdAt,
    };
  }

  Map<String, dynamic> _initialReviewState(String questionId) {
    return {
      'question_id': questionId,
      'state': 0,
      'difficulty': 5.0,
      'stability': 0.0,
      'last_review_time': 0,
      'next_review_time': 0,
      'reps': 0,
      'lapses': 0,
      'last_lapse_time': 0,
    };
  }

  Future<void> _syncBankFolder(String bankName, String? folderName) async {
    final trimmedFolderName = folderName?.trim() ?? '';
    if (trimmedFolderName.isNotEmpty) {
      await _databaseHelper.updateBankFolder(bankName, trimmedFolderName);
      return;
    }

    if (await _folderExists(bankName)) {
      await _databaseHelper.updateBankFolder(bankName, bankName);
    }
  }

  Future<bool> _folderExists(String name) async {
    await _databaseHelper.getSubjectTree();
    final db = await _databaseHelper.database;
    final customFolders = await db.query(
      'custom_folders',
      where: 'name = ?',
      whereArgs: [name],
      limit: 1,
    );
    if (customFolders.isNotEmpty) return true;

    final bankFolders = await db.query(
      'bank_folders',
      where: 'folder_name = ?',
      whereArgs: [name],
      limit: 1,
    );
    return bankFolders.isNotEmpty;
  }

  // Get recent wrong questions for AI engine
  Future<List<Map<String, dynamic>>> getRecentWrongQuestions({int limit = 30}) {
    return _databaseHelper.getRecentWrongQuestions(limit: limit);
  }
}

/// Failure taxonomy of the frozen typed V2 write boundary.
enum QuestionV2WriteFailure { transactionFailed }

/// Raised when a typed V2 batch cannot be written atomically. The exception
/// retains no raw cause, message, SQL, arguments, bank, folder, or content.
final class QuestionV2WriteException implements Exception {
  const QuestionV2WriteException(this.failure);

  final QuestionV2WriteFailure failure;

  @override
  String toString() {
    final detail = switch (failure) {
      QuestionV2WriteFailure.transactionFailed =>
        'The typed question batch cannot be written atomically.',
    };
    return 'QuestionV2WriteException(${failure.name}): $detail';
  }
}

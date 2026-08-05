import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../core/database/database_helper.dart';
import '../../domain/question/question_draft_v2.dart';
import '../models/persisted_question.dart';
import '../models/question_draft.dart';
import '../models/subject_tree_index.dart';
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
    final frozenWrites = <FrozenQuestionV2Write>[
      for (final draft in questions)
        _mapper.freezeForWrite(
          storageId: _uuid.v4(),
          bankName: trimmedBankName,
          createdAt: nowUtcSeconds,
          draft: draft,
        ),
    ];

    try {
      final db = await _databaseHelper.database;
      await db.transaction((txn) async {
        final resolvedFolderName =
            await _resolveV2FolderAction(txn, trimmedBankName, folderName);
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
              'bank_name': trimmedBankName,
              'folder_name': resolvedFolderName,
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      });
    } on DatabaseException {
      throw const QuestionV2WriteException(
        QuestionV2WriteFailure.transactionFailed,
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

  Future<List<Map<String, dynamic>>> getQuestionsByBank(String bankName) {
    return _databaseHelper.getQuestionsByBank(bankName);
  }

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
        ? await db.rawQuery('''
            SELECT q.*,
                   p.payload_schema_version AS ${QuestionV2PersistenceMapper.payloadSchemaVersionAlias},
                   p.payload_json AS ${QuestionV2PersistenceMapper.payloadJsonAlias}
            FROM questions q
            JOIN review_states r ON q.id = r.question_id
            LEFT JOIN question_v2_payloads p ON q.id = p.question_id
            WHERE r.lapses > 0
            ORDER BY r.last_lapse_time DESC
          ''')
        : await db.rawQuery('''
            SELECT q.*,
                   p.payload_schema_version AS ${QuestionV2PersistenceMapper.payloadSchemaVersionAlias},
                   p.payload_json AS ${QuestionV2PersistenceMapper.payloadJsonAlias}
            FROM questions q
            LEFT JOIN question_v2_payloads p ON q.id = p.question_id
            WHERE q.bank_name = ?
            ORDER BY q.created_at DESC
          ''', [trimmedBankName]);

    return rows.map(_mapper.decodeJoinedRow).toList(growable: false);
  }

  Future<List<Map<String, dynamic>>> searchQuestions(
    String bankName,
    String query,
  ) {
    return _databaseHelper.searchQuestions(bankName, query);
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

import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../core/database/database_helper.dart';
import '../models/question_draft.dart';
import '../models/subject_tree_index.dart';
import '../../utils/ai_data_sanitizer.dart';
import '../../data/repositories/settings_repository.dart';

class QuestionRepository {
  QuestionRepository({DatabaseHelper? databaseHelper, Uuid? uuid})
      : _databaseHelper = databaseHelper ?? DatabaseHelper.instance,
        _uuid = uuid ?? const Uuid();

  static final QuestionRepository instance = QuestionRepository();

  final DatabaseHelper _databaseHelper;
  final Uuid _uuid;

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

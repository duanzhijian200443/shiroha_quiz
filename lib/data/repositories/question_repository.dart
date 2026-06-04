import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../core/database/database_helper.dart';
import '../models/question_draft.dart';
import '../../utils/ai_data_sanitizer.dart';

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

  Future<List<String>> getAvailableBanksAndFolders() async {
    final index =
        _BankFolderIndex.fromTree(await _databaseHelper.getSubjectTree());
    return index.availableBanksAndFolders;
  }

  Future<List<String>> getAvailableFolders() async {
    final index =
        _BankFolderIndex.fromTree(await _databaseHelper.getSubjectTree());
    return index.availableFolders;
  }

  Future<void> deleteQuestion(String id) {
    return _databaseHelper.deleteSingleQuestion(id);
  }

  Future<String> createExamPaper(
    String title,
    int sourceType,
    List<Map<String, dynamic>> questions,
  ) {
    return _databaseHelper.createExamPaper(title, sourceType, questions);
  }

  Future<String> createExamPaperFromDrafts(
    String title,
    int sourceType,
    List<QuestionDraft> questions,
  ) {
    return _databaseHelper.createExamPaper(
      title,
      sourceType,
      questions.map((question) => question.toMap()).toList(growable: false),
    );
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
}

class _BankFolderIndex {
  _BankFolderIndex({
    required Set<String> banksAndFolders,
    required Set<String> folders,
  })  : _banksAndFolders = banksAndFolders,
        _folders = folders;

  static const _defaultSubject = '默认学科';
  static const _uncategorizedFolder = '📁 未分类题库';

  final Set<String> _banksAndFolders;
  final Set<String> _folders;

  factory _BankFolderIndex.fromTree(
    Map<String, List<Map<String, dynamic>>> tree,
  ) {
    final banksAndFolders = <String>{};
    final folders = <String>{};

    for (final entry in tree.entries) {
      final folderName = entry.key.trim();
      if (folderName.isNotEmpty) {
        banksAndFolders.add(folderName);
        folders.add(folderName);
      }

      for (final bank in entry.value) {
        final bankName = bank['name']?.toString().trim();
        if (bankName != null && bankName.isNotEmpty) {
          banksAndFolders.add(bankName);
        }
      }
    }

    banksAndFolders
      ..remove(_defaultSubject)
      ..remove(_uncategorizedFolder);
    folders.remove(_uncategorizedFolder);

    return _BankFolderIndex(
      banksAndFolders: banksAndFolders,
      folders: folders,
    );
  }

  List<String> get availableBanksAndFolders => _sorted(_banksAndFolders);

  List<String> get availableFolders => _sorted(_folders);

  static List<String> _sorted(Set<String> values) {
    return values.toList()..sort();
  }
}

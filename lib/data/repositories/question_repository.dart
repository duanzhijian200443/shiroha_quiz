import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../core/database/database_helper.dart';
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
    final tree = await _databaseHelper.getSubjectTree();
    final names = <String>{};

    for (final entry in tree.entries) {
      names.add(entry.key);
      for (final bank in entry.value) {
        final name = bank['name']?.toString().trim();
        if (name != null && name.isNotEmpty) names.add(name);
      }
    }

    names
      ..remove('默认学科')
      ..remove('📁 未分类题库');
    return (names.toList()..sort());
  }

  Future<List<String>> getAvailableFolders() async {
    final tree = await _databaseHelper.getSubjectTree();
    final folders = tree.keys.where((name) => name != '📁 未分类题库').toList()
      ..sort();
    return folders;
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

  Map<String, dynamic> _questionToRow(
    Map<String, dynamic> question, {
    required String bankName,
    required int createdAt,
  }) {
    final explanation = AiDataSanitizer.cleanLatexBeforeDB(
      _readString(question['explanation']),
    );
    final answer = AiDataSanitizer.cleanLatexBeforeDB(
      _readString(question['standard_answer'], fallback: question['answer']),
    );
    final rawExplanation = question['raw_explanation'];

    return {
      'id': _uuid.v4(),
      'bank_name': bankName,
      'type': _readInt(question['type']) ?? 0,
      'content': AiDataSanitizer.cleanLatexBeforeDB(
        _readString(question['content'], fallbackText: '无题干'),
      ),
      'options': jsonEncode(_readOptions(question['options'])),
      'standard_answer': '$answer|||$explanation',
      'explanation': explanation,
      'raw_explanation': rawExplanation == null
          ? null
          : AiDataSanitizer.cleanLatexBeforeDB(rawExplanation.toString()),
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

  List<String> _readOptions(dynamic value) {
    if (value is List) {
      return value
          .map(
            (option) => AiDataSanitizer.cleanLatexBeforeDB(option.toString()),
          )
          .toList(growable: false);
    }

    if (value is String && value.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(value);
        if (decoded is List) return _readOptions(decoded);
      } catch (_) {
        return [AiDataSanitizer.cleanLatexBeforeDB(value)];
      }
    }

    return const <String>[];
  }

  String _readString(
    dynamic value, {
    dynamic fallback,
    String fallbackText = '',
  }) {
    final primary = value?.toString().trim();
    if (primary != null && primary.isNotEmpty) return primary;

    final fallbackValue = fallback?.toString().trim();
    if (fallbackValue != null && fallbackValue.isNotEmpty) {
      return fallbackValue;
    }

    return fallbackText;
  }

  int? _readInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }
}

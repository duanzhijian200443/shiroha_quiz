import 'dart:collection';
import 'dart:convert';

class WrongBookEntry {
  const WrongBookEntry({
    required this.id,
    required this.type,
    required this.content,
    required this.bankName,
    required this.optionsRaw,
    required this.options,
    required this.standardAnswerRaw,
    required this.answer,
    required this.explanation,
    required this.lapses,
    required this.difficulty,
    required this.stability,
    required this.lastLapseTime,
  });

  final String id;
  final int type;
  final String content;
  final String bankName;
  final String optionsRaw;
  final List<String> options;
  final String standardAnswerRaw;
  final String answer;
  final String explanation;
  final int lapses;
  final double difficulty;
  final double stability;
  final int lastLapseTime;

  bool get hasAnswerOrExplanation =>
      answer.isNotEmpty || explanation.isNotEmpty;
  bool get isSelectionQuestion => type == 1;

  Map<String, dynamic> toQuestionEditMap() {
    return {
      'id': id,
      'type': type,
      'content': content,
      'options': optionsRaw,
      'standard_answer': standardAnswerRaw,
      'bank_name': bankName,
    };
  }

  factory WrongBookEntry.fromRow(Map<String, dynamic> row) {
    final id = _readString(row['id']);
    final type = _readInt(row['type']) ?? 0;
    final content = _readString(row['content']);
    final bankName = _readString(row['bank_name']);

    final optionsRaw = _readString(row['options']);
    final options = _parseOptions(optionsRaw);

    final standardAnswerRaw = _readString(row['standard_answer']);
    final (answer, explanation) = _parseAnswer(standardAnswerRaw);

    return WrongBookEntry(
      id: id,
      type: type,
      content: content,
      bankName: bankName,
      optionsRaw: optionsRaw,
      options: UnmodifiableListView(options),
      standardAnswerRaw: standardAnswerRaw,
      answer: answer,
      explanation: explanation,
      lapses: _readInt(row['lapses']) ?? 0,
      difficulty: _readDouble(row['difficulty']) ?? 0.0,
      stability: _readDouble(row['stability']) ?? 0.0,
      lastLapseTime: _readInt(row['last_lapse_time']) ?? 0,
    );
  }

  static String _readString(dynamic value) {
    if (value == null) return '';
    return value.toString().trim();
  }

  static int? _readInt(dynamic value) {
    return switch (value) {
      final int raw => raw,
      final num raw => raw.toInt(),
      final String raw => int.tryParse(raw.trim()),
      _ => null,
    };
  }

  static double? _readDouble(dynamic value) {
    return switch (value) {
      final double raw => raw,
      final num raw => raw.toDouble(),
      final String raw => double.tryParse(raw.trim()),
      _ => null,
    };
  }

  static List<String> _parseOptions(String optionsRaw) {
    if (optionsRaw.isEmpty) return [];
    try {
      var decoded = jsonDecode(optionsRaw);
      if (decoded is String) {
        // Fallback for double-encoded JSON string
        try {
          final inner = jsonDecode(decoded);
          if (inner is List) {
            return inner.map((e) => e.toString().trim()).toList();
          }
        } catch (_) {
          // Ignore inner parse error
        }
      } else if (decoded is List) {
        return decoded.map((e) => e.toString().trim()).toList();
      }
    } catch (_) {
      // Not a valid JSON, return as a single element if not empty
    }
    return [optionsRaw];
  }

  static (String answer, String explanation) _parseAnswer(String raw) {
    if (raw.isEmpty) return ('', '');
    final parts = raw.split('|||');
    if (parts.length == 1) {
      return (parts[0].trim(), '');
    }
    final answer = parts[0].trim();
    final explanation = parts.sublist(1).join('|||').trim();
    return (answer, explanation);
  }
}

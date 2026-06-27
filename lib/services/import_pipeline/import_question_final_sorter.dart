import '../../data/models/question_identity.dart';

class ImportQuestionFinalSortResult {
  final List<Map<String, dynamic>> questions;
  final Map<String, dynamic> diagnostics;

  const ImportQuestionFinalSortResult({
    required this.questions,
    required this.diagnostics,
  });
}

class ImportQuestionFinalSorter {
  const ImportQuestionFinalSorter();

  static const _unreliableQNumHints = {
    'q_num_drift',
    'duplicate_q_num',
    'orphan_fragment',
    'answer_only_fragment',
    'partial_question',
  };

  ImportQuestionFinalSortResult sort(List<Map<String, dynamic>> questions) {
    if (questions.isEmpty) {
      return ImportQuestionFinalSortResult(
        questions: questions,
        diagnostics: const {'total': 0, 'movedCount': 0, 'typeBuckets': {}},
      );
    }

    final items = <_SortableQuestion>[];
    for (var i = 0; i < questions.length; i++) {
      items.add(_SortableQuestion._fromMap(questions[i], i));
    }

    items.sort(_compare);

    final sorted = items.map((item) => item.raw).toList();
    final movedCount = _countMoved(items);
    final typeBuckets = _countTypeBuckets(items);

    return ImportQuestionFinalSortResult(
      questions: sorted,
      diagnostics: {
        'total': items.length,
        'movedCount': movedCount,
        'typeBuckets': typeBuckets,
      },
    );
  }

  static int _countMoved(List<_SortableQuestion> items) {
    var moved = 0;
    for (var i = 0; i < items.length; i++) {
      if (items[i].originalListIndex != i) moved++;
    }
    return moved;
  }

  static Map<String, int> _countTypeBuckets(List<_SortableQuestion> items) {
    final buckets = <String, int>{};
    for (final item in items) {
      final label = _typeLabel(item.typeRank);
      buckets[label] = (buckets[label] ?? 0) + 1;
    }
    return buckets;
  }

  static String _typeLabel(int rank) {
    return switch (rank) {
      0 => 'choice',
      1 => 'fill',
      2 => 'essay',
      3 => 'judgment',
      _ => 'unknown',
    };
  }

  static int _compare(_SortableQuestion a, _SortableQuestion b) {
    final typeCompare = a.typeRank.compareTo(b.typeRank);
    if (typeCompare != 0) return typeCompare;

    if (a.hasReliableQNum && b.hasReliableQNum && a.qNum != null && b.qNum != null) {
      final qCompare = a.qNum!.compareTo(b.qNum!);
      if (qCompare != 0) return qCompare;
    }

    final sourceCompare = a.sourceOrder.compareTo(b.sourceOrder);
    if (sourceCompare != 0) return sourceCompare;

    return a.originalListIndex.compareTo(b.originalListIndex);
  }
}

class _SortableQuestion {
  final Map<String, dynamic> raw;
  final int originalListIndex;
  final int sourceOrder;
  final int typeRank;
  final int? qNum;
  final bool hasReliableQNum;

  _SortableQuestion._({
    required this.raw,
    required this.originalListIndex,
    required this.sourceOrder,
    required this.typeRank,
    required this.qNum,
    required this.hasReliableQNum,
  });

  factory _SortableQuestion._fromMap(Map<String, dynamic> question, int index) {
    return _SortableQuestion._(
      raw: question,
      originalListIndex: index,
      sourceOrder: _readSourceOrder(question, index),
      typeRank: _readTypeRank(question['type']),
      qNum: _readQuestionNumber(question),
      hasReliableQNum: _hasReliableQNum(question),
    );
  }
}

int _readSourceOrder(Map<String, dynamic> question, int fallback) {
  final meta = question['_import_review'];
  if (meta is! Map) return fallback;
  final indices = meta['originalIndices'];
  if (indices is! List || indices.isEmpty) return fallback;
  int? min;
  for (final e in indices) {
    int? value;
    if (e is int) {
      value = e;
    } else if (e is num) {
      value = e.toInt();
    } else if (e is String) {
      value = int.tryParse(e);
    }
    if (value != null && value >= 0 && (min == null || value < min)) {
      min = value;
    }
  }
  return min ?? fallback;
}

int _readTypeRank(dynamic typeValue) {
  int? raw;
  if (typeValue is int) {
    raw = typeValue;
  } else if (typeValue is num) {
    raw = typeValue.toInt();
  } else if (typeValue is String) {
    raw = int.tryParse(typeValue.trim());
  }
  if (raw == null) return 4;
  return switch (raw) {
    0 || 1 => 0,
    2 => 1,
    3 => 2,
    4 => 3,
    _ => 4,
  };
}

int? _readQuestionNumber(Map<String, dynamic> question) {
  final normalized = QuestionIdentity.normalizeQuestionNumber(question['q_num']);
  if (normalized.isEmpty) return null;
  final match = RegExp(r'\d+').firstMatch(normalized);
  if (match == null) return null;
  return int.tryParse(match.group(0)!);
}

bool _hasReliableQNum(Map<String, dynamic> question) {
  final meta = question['_import_review'];
  if (meta is! Map) return true;
  final hints = meta['riskHints'];
  if (hints is! List || hints.isEmpty) return true;
  for (final hint in hints) {
    if (ImportQuestionFinalSorter._unreliableQNumHints.contains(hint.toString())) {
      return false;
    }
  }
  return true;
}

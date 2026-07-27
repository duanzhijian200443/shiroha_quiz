import '../../data/models/question_identity.dart';
import 'import_document_role.dart';

class VisionQuestionQualityGateResult {
  final List<Map<String, dynamic>> questions;
  final List<String> warnings;
  final Map<String, dynamic> diagnostics;

  const VisionQuestionQualityGateResult({
    required this.questions,
    required this.warnings,
    required this.diagnostics,
  });
}

class VisionQuestionQualityGate {
  const VisionQuestionQualityGate();

  static const String importReviewKey = '_import_review';

  VisionQuestionQualityGateResult evaluate(
    List<Map<String, dynamic>> questions, {
    required String sourceName,
    ImportDocumentRole? documentRole,
  }) {
    final annotated = <Map<String, dynamic>>[];
    final warnings = <String>[];
    final issueCounts = <String, int>{};
    final seenNumbers = <String, _SeenQuestionNumber>{};
    int? previousNumber;

    void record(String hint) {
      issueCounts[hint] = (issueCounts[hint] ?? 0) + 1;
    }

    for (var i = 0; i < questions.length; i++) {
      final question = Map<String, dynamic>.from(questions[i]);
      final hints = _readRiskHints(question);
      final content = _readString(question['content']);
      final answer = _readString(question['standard_answer']);
      final explanation = _readString(question['explanation']);
      final normalizedNumber =
          QuestionIdentity.normalizeQuestionNumber(question['q_num']);
      final numericQuestionNumber = _readLeadingNumber(normalizedNumber);

      if (_looksLikeAnswerLeakedToContent(content)) {
        hints.add('answer_leaked_to_content');
        record('answer_leaked_to_content');
      }

      if (documentRole == ImportDocumentRole.stemOnly) {
        hints.remove('missing_answer_or_explanation');
      } else if (answer.isEmpty && explanation.isEmpty) {
        hints.add('missing_answer_or_explanation');
        record('missing_answer_or_explanation');
      }

      if (_hasTypeOptionsMismatch(question)) {
        hints.add('type_options_mismatch');
        record('type_options_mismatch');
      }

      if (normalizedNumber.isNotEmpty) {
        final previous = seenNumbers[normalizedNumber];
        if (previous != null &&
            previous.normalizedContent !=
                QuestionIdentity.normalizeContent(question['content'])) {
          hints.add('duplicate_q_num');
          record('duplicate_q_num');
        } else {
          seenNumbers[normalizedNumber] = _SeenQuestionNumber(
            normalizedContent: QuestionIdentity.normalizeContent(
              question['content'],
            ),
          );
        }
      }

      if (numericQuestionNumber != null) {
        if (previousNumber != null &&
            numericQuestionNumber < previousNumber - 1) {
          hints.add('q_num_drift');
          record('q_num_drift');
        }
        previousNumber = numericQuestionNumber;
      }

      _writeRiskHints(question, hints);
      annotated.add(question);
    }

    final riskyCount = annotated.where((q) {
      final hints = _readRiskHints(q);
      return hints.any((hint) =>
          hint == 'answer_leaked_to_content' ||
          hint == 'missing_answer_or_explanation' ||
          hint == 'type_options_mismatch' ||
          hint == 'duplicate_q_num' ||
          hint == 'q_num_drift');
    }).length;

    final lowQuality =
        annotated.isNotEmpty && riskyCount / annotated.length > 0.4;
    if (lowQuality) {
      for (final question in annotated) {
        final hints = _readRiskHints(question)..add('low_quality_vision_parse');
        _writeRiskHints(question, hints);
      }
      warnings.add('$sourceName 视觉结构质量偏低，建议人工复核或更换更强视觉模型重试。');
    }

    return VisionQuestionQualityGateResult(
      questions: annotated,
      warnings: warnings,
      diagnostics: {
        'sourceName': sourceName,
        'total': questions.length,
        'riskyCount': riskyCount,
        'lowQuality': lowQuality,
        'blocked': false,
        if (documentRole != null) 'documentRole': documentRole.name,
        'requiresReview': documentRole == ImportDocumentRole.ambiguous,
        if (issueCounts.isNotEmpty) 'issueCounts': issueCounts,
      },
    );
  }

  Set<String> _readRiskHints(Map<String, dynamic> question) {
    final meta = question[importReviewKey];
    if (meta is Map) {
      final rawHints = meta['riskHints'];
      if (rawHints is List) {
        return rawHints.map((hint) => hint.toString()).toSet();
      }
    }
    return <String>{};
  }

  void _writeRiskHints(Map<String, dynamic> question, Set<String> hints) {
    final rawMeta = question[importReviewKey];
    final meta = rawMeta is Map
        ? Map<String, dynamic>.fromEntries(
            rawMeta.entries.map(
              (entry) => MapEntry(entry.key.toString(), entry.value),
            ),
          )
        : <String, dynamic>{};
    meta['riskHints'] = hints.toList()..sort();
    question[importReviewKey] = meta;
  }

  String _readString(dynamic value) => value?.toString().trim() ?? '';

  int? _readLeadingNumber(String normalizedQuestionNumber) {
    final match = RegExp(r'\d+').firstMatch(normalizedQuestionNumber);
    if (match == null) return null;
    return int.tryParse(match.group(0)!);
  }

  bool _looksLikeAnswerLeakedToContent(String content) {
    if (content.isEmpty) return false;
    final compact = content.replaceAll(RegExp(r'\s+'), '');
    if (RegExp(r'^(?:解[:：]?|分析[:：]?|证明[:：]?|参考答案[:：]?|答案[:：]?)')
        .hasMatch(compact)) {
      return true;
    }
    if (RegExp(r'^[（(][ⅠⅡⅢⅣⅤⅥIVXivx0-9]+[）)]').hasMatch(compact)) {
      return RegExp(r'(A=|矩阵|正交变换|标准形|特征值|特征向量|可得|故|所以)').hasMatch(compact);
    }
    return false;
  }

  bool _hasTypeOptionsMismatch(Map<String, dynamic> question) {
    final type = _readType(question['type']);
    final options = question['options'];
    final hasOptions = options is List && options.isNotEmpty;
    if (type == 0 || type == 1) {
      return !hasOptions;
    }
    if (type != null && type != 0 && type != 1) {
      return hasOptions;
    }
    return false;
  }

  int? _readType(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }
}

class _SeenQuestionNumber {
  final String normalizedContent;

  const _SeenQuestionNumber({required this.normalizedContent});
}

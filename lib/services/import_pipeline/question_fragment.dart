import '../../data/models/question_identity.dart';
import '../../data/models/import_question_validation.dart';

enum QuestionFragmentSource {
  text,
  vision,
  answerOnly,
  unknown,
}

enum QuestionFragmentKind {
  fullQuestion,
  stemOnly,
  answerOnly,
  partialQuestion,
  orphan,
}

class QuestionFragment {
  final Map<String, dynamic> raw;
  final QuestionIdentity identity;
  final QuestionFragmentSource source;
  final QuestionFragmentKind kind;
  final int originalIndex;

  const QuestionFragment({
    required this.raw,
    required this.identity,
    required this.source,
    required this.kind,
    required this.originalIndex,
  });

  factory QuestionFragment.fromMap(
    Map<String, dynamic> raw, {
    required QuestionFragmentSource source,
    required int originalIndex,
  }) {
    final identity = QuestionIdentity.fromMap(raw);

    final hasStem = _hasValidStem(raw['content']);
    final hasAnswer = _isValidAnswer(raw['standard_answer']);

    final QuestionFragmentKind kind;
    if (hasStem && hasAnswer) {
      kind = QuestionFragmentKind.fullQuestion;
    } else if (hasStem && !hasAnswer) {
      final contentStr = raw['content']?.toString().trim() ?? '';
      if (contentStr.length < 5 &&
          RegExp(r'^[A-Ea-e✓×TFM]+$').hasMatch(contentStr)) {
        kind = QuestionFragmentKind.answerOnly;
      } else if (contentStr.length < 10 &&
          !contentStr.contains(RegExp(r'[\u4e00-\u9fa5]'))) {
        kind = QuestionFragmentKind.partialQuestion;
      } else {
        kind = QuestionFragmentKind.stemOnly;
      }
    } else if (!hasStem && hasAnswer) {
      kind = QuestionFragmentKind.answerOnly;
    } else {
      kind = QuestionFragmentKind.orphan;
    }

    return QuestionFragment(
      raw: raw,
      identity: identity,
      source: source,
      kind: kind,
      originalIndex: originalIndex,
    );
  }

  static bool _hasValidString(dynamic value) {
    return value != null && value.toString().trim().isNotEmpty;
  }

  static bool _hasValidStem(dynamic value) {
    final text = value?.toString().trim();
    if (text == null || text.isEmpty) return false;
    return !isPlaceholderStem(text);
  }

  static bool isPlaceholderStem(String text) {
    final normalized = text.trim().replaceAll(RegExp(r'\s+'), '');
    const exactPlaceholders = {
      '无题干',
      '题干',
      '题干内容',
      '真实的题干内容',
      '题干完整原文',
      '原题干',
      '同上',
      '略',
    };
    if (exactPlaceholders.contains(normalized)) return true;

    return normalized.contains('题干完整原文') ||
        normalized.contains('真实的题干内容') ||
        normalized.contains('原题干');
  }

  static bool _isValidAnswer(dynamic ans) {
    return isMeaningfulAnswer(ans?.toString());
  }

  bool get hasQuestionNumber => identity.hasQuestionNumber;
  bool get hasStem => _hasValidStem(raw['content']);
  bool get hasAnswer => _isValidAnswer(raw['standard_answer']);
  bool get hasExplanation => _hasValidString(raw['explanation']);
  int get contentLength => raw['content']?.toString().trim().length ?? 0;

  String? get answerPatch {
    final answer = raw['standard_answer'];
    if (_isValidAnswer(answer)) {
      return answer.toString().trim();
    }

    if (kind == QuestionFragmentKind.answerOnly) {
      final content = raw['content']?.toString().trim();
      if (_hasValidString(content)) {
        return content;
      }
    }

    return null;
  }

  bool get hasAnswerPatch => answerPatch != null;
}

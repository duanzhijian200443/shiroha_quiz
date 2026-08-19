/// T0 read-only study query public DTOs.
///
/// These are the safe application-layer result values handed to presentation
/// adapters (Flutter UI, the built-in Agent, and the future MCP adapter).
/// They never contain SQL, database rows, provider payloads, absolute paths,
/// raw fallback JSON, complete answers/history beyond the frozen fields, or
/// internal exception details.
library;

/// Opaque application cursor token.
///
/// Only the study query layer creates cursors; adapters carry them as opaque
/// strings. Values are bounded and no cursor is backed by SQL `OFFSET`.
final class OpaqueCursor {
  const OpaqueCursor._(this.value);

  /// Creates a cursor from an already-encoded opaque token.
  ///
  /// The token is bounded and restricted to a safe charset. Throws
  /// [ArgumentError] for malformed tokens so adapters can surface
  /// user-supplied cursors as invalid requests.
  factory OpaqueCursor.fromEncoded(String value) {
    if (value.isEmpty ||
        value.length > _maxCursorLength ||
        !_cursorCharset.hasMatch(value)) {
      throw ArgumentError.value(
        value,
        'cursor',
        'Cursor is not a valid opaque token.',
      );
    }
    return OpaqueCursor._(value);
  }

  static const int _maxCursorLength = 256;
  static final RegExp _cursorCharset = RegExp(r'^[A-Za-z0-9._~-]+$');

  final String value;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is OpaqueCursor && other.value == value;
  }

  @override
  int get hashCode => value.hashCode;
}

/// Source kind exposed at the public DTO boundary. Only `typed` and `legacy`
/// are ever visible.
enum StudySourceKind { typed, legacy }

/// Safe question kind exposed at the public DTO boundary.
enum StudyQuestionKind { singleChoice, fillBlank, shortAnswer, unknown }

/// A calendar date in the selected timezone.
final class StudyLocalDate {
  const StudyLocalDate({
    required this.year,
    required this.month,
    required this.day,
  });

  final int year;
  final int month;
  final int day;

  int compareTo(StudyLocalDate other) {
    final byYear = year.compareTo(other.year);
    if (byYear != 0) return byYear;
    final byMonth = month.compareTo(other.month);
    if (byMonth != 0) return byMonth;
    return day.compareTo(other.day);
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is StudyLocalDate &&
            year == other.year &&
            month == other.month &&
            day == other.day;
  }

  @override
  int get hashCode => Object.hash(year, month, day);

  @override
  String toString() {
    final monthText = month.toString().padLeft(2, '0');
    final dayText = day.toString().padLeft(2, '0');
    return '$year-$monthText-$dayText';
  }
}

/// One question-bank summary row of the bank list page.
final class QuestionBankSummary {
  const QuestionBankSummary({
    required this.bankName,
    required this.folderName,
    required this.questionCount,
    required this.dueCount,
    required this.masteredCount,
  });

  final String bankName;
  final String folderName;
  final int questionCount;
  final int dueCount;
  final int masteredCount;
}

/// Page result of `list_question_banks`.
final class BankListPage {
  const BankListPage({required this.items, required this.nextCursor});

  final List<QuestionBankSummary> items;
  final OpaqueCursor? nextCursor;
}

/// Result of `get_study_overview`.
final class StudyOverview {
  const StudyOverview({
    required this.questionCount,
    required this.masteredCount,
    required this.dueCount,
    required this.todayPracticeCount,
    required this.wrongQuestionCount,
  });

  final int questionCount;
  final int masteredCount;
  final int dueCount;
  final int todayPracticeCount;
  final int wrongQuestionCount;
}

/// Result of `get_due_review_summary`.
final class DueReviewSummary {
  const DueReviewSummary({
    required this.dueNow,
    required this.scheduledCount,
    required this.buckets,
  });

  final int dueNow;
  final int scheduledCount;
  final List<DueBucket> buckets;
}

/// One local-date bucket inside a due-review window.
final class DueBucket {
  const DueBucket({required this.date, required this.count});

  final StudyLocalDate date;
  final int count;
}

/// Page result of `search_questions`.
final class QuestionSearchPage {
  const QuestionSearchPage({required this.items, required this.nextCursor});

  final List<QuestionSearchItem> items;
  final OpaqueCursor? nextCursor;
}

/// One search hit.
final class QuestionSearchItem {
  const QuestionSearchItem({
    required this.questionId,
    required this.bankName,
    required this.kind,
    required this.stemPreview,
    required this.hasAnswer,
    required this.hasExplanation,
    required this.due,
    required this.sourceKind,
  });

  final String questionId;
  final String bankName;
  final StudyQuestionKind kind;
  final String stemPreview;
  final bool hasAnswer;
  final bool hasExplanation;
  final bool due;
  final StudySourceKind sourceKind;
}

/// Safe rich-content node projection for `get_question_detail`.
///
/// A persisted [RichContent] node maps to exactly one of these nodes.
/// `RawFallbackNode` projects only to [StudyUnsupportedNode]; its payload is
/// never exposed.
sealed class StudyContentNode {
  const StudyContentNode();
}

final class StudyTextNode extends StudyContentNode {
  const StudyTextNode(this.text);

  final String text;
}

final class StudyInlineMathNode extends StudyContentNode {
  const StudyInlineMathNode(this.latex);

  final String latex;
}

final class StudyBlockMathNode extends StudyContentNode {
  const StudyBlockMathNode(this.latex);

  final String latex;
}

final class StudyImageNode extends StudyContentNode {
  const StudyImageNode({
    required this.assetRef,
    this.altText,
  });

  final String assetRef;
  final String? altText;
}

/// Marker for a node whose payload must never leave the application layer.
final class StudyUnsupportedNode extends StudyContentNode {
  const StudyUnsupportedNode();
}

/// One question option inside a detail response.
final class StudyOption {
  const StudyOption({required this.label, required this.content});

  final String label;
  final List<StudyContentNode> content;
}

/// Result of `get_question_detail`.
final class QuestionDetail {
  const QuestionDetail({
    required this.questionId,
    required this.bankName,
    required this.kind,
    required this.stem,
    required this.options,
    required this.answer,
    required this.explanation,
    required this.due,
    required this.sourceKind,
  });

  final String questionId;
  final String bankName;
  final StudyQuestionKind kind;
  final List<StudyContentNode> stem;
  final List<StudyOption> options;
  final List<StudyContentNode>? answer;
  final List<StudyContentNode>? explanation;
  final bool due;
  final StudySourceKind sourceKind;
}

/// Page result of `get_weak_questions`.
final class WeakQuestionPage {
  const WeakQuestionPage({required this.items, required this.nextCursor});

  final List<WeakQuestionItem> items;
  final OpaqueCursor? nextCursor;
}

/// One weak-question summary item. Deliberately carries no answers, review
/// history logs, or AI evaluations.
final class WeakQuestionItem {
  const WeakQuestionItem({
    required this.questionId,
    required this.bankName,
    required this.stemPreview,
    required this.lapseCount,
    required this.difficulty,
    required this.lastLapseAt,
  });

  final String questionId;
  final String bankName;
  final String stemPreview;
  final int lapseCount;
  final double difficulty;
  final DateTime? lastLapseAt;
}

import '../study_query/study_query_dtos.dart';
import 'external_read_context.dart';

/// Internal immutable selection identity. Never encoded into an external token.
final class ExternalQuestionKey {
  const ExternalQuestionKey(
      this.storageId, this.createdAt, this.rowIdentity, this.fingerprint);
  final String storageId, fingerprint;
  final int createdAt, rowIdentity;
  @override
  bool operator ==(Object other) =>
      other is ExternalQuestionKey &&
      storageId == other.storageId &&
      createdAt == other.createdAt &&
      rowIdentity == other.rowIdentity &&
      fingerprint == other.fingerprint;
  @override
  int get hashCode =>
      Object.hash(storageId, createdAt, rowIdentity, fingerprint);
}

final class ExternalQuestionCandidate {
  const ExternalQuestionCandidate(this.key, this.summary);
  final ExternalQuestionKey key;
  final QuestionSearchItem summary;
}

final class ExternalQuestionCandidates {
  ExternalQuestionCandidates(
      Iterable<ExternalQuestionCandidate> items, this.nextKey)
      : items = List.unmodifiable(items);
  final List<ExternalQuestionCandidate> items;
  final ExternalQuestionKey? nextKey;
}

/// Narrow Data port: Context proof, current policy/target and exact question
/// ownership are checked in each owning read transaction, including release.
abstract interface class ExternalQuestionReadPort {
  Future<ExternalQuestionCandidates> search(
      ExternalQuestionReadAccess access,
      String query,
      int limit,
      ExternalQuestionKey? after,
      void Function() check);
  Future<ExternalQuestionDetail> detail(ExternalQuestionReadAccess access,
      ExternalQuestionKey key, void Function() check);
  Future<void> release(ExternalQuestionReadAccess access,
      List<ExternalQuestionKey> keys, void Function() check);
}

String _kind(StudyQuestionKind kind) => switch (kind) {
      StudyQuestionKind.singleChoice => 'single_choice',
      StudyQuestionKind.fillBlank => 'fill_blank',
      StudyQuestionKind.shortAnswer => 'short_answer',
      StudyQuestionKind.unknown => 'unknown',
    };

List<Map<String, Object?>>? _nodes(List<StudyContentNode>? nodes) =>
    nodes == null
        ? null
        : [
            for (final node in nodes)
              switch (node) {
                StudyTextNode(:final text) => {'type': 'text', 'text': text},
                StudyInlineMathNode(:final latex) => {
                    'type': 'inline_math',
                    'latex': latex
                  },
                StudyBlockMathNode(:final latex) => {
                    'type': 'block_math',
                    'latex': latex
                  },
                StudyUnsupportedNode() => {'type': 'unsupported'},
              }
          ];

/// Six search fields only. Constructing a DTO supplies no access authority.
final class ExternalQuestionHit {
  ExternalQuestionHit.project(this.questionRef, QuestionSearchItem item)
      : kind = item.kind,
        stemPreview = item.stemPreview,
        hasAnswer = item.hasAnswer,
        hasExplanation = item.hasExplanation,
        sourceKind = item.sourceKind;
  final String questionRef, stemPreview;
  final StudyQuestionKind kind;
  final bool hasAnswer, hasExplanation;
  final StudySourceKind sourceKind;
  Map<String, Object?> toJson() => {
        'questionRef': questionRef,
        'kind': _kind(kind),
        'stemPreview': stemPreview,
        'hasAnswer': hasAnswer,
        'hasExplanation': hasExplanation,
        'sourceKind': sourceKind.name,
      };
}

final class ExternalQuestionSearchPage {
  ExternalQuestionSearchPage(
      Iterable<ExternalQuestionHit> items, this.nextCursor)
      : items = List.unmodifiable(items);
  final List<ExternalQuestionHit> items;
  final String? nextCursor;
  Map<String, Object?> toJson() => {
        'items': items.map((item) => item.toJson()).toList(),
        'nextCursor': nextCursor,
      };
}

/// Six detail fields only. Deep immutable safe StudyQuery nodes; no ids/review.
final class ExternalQuestionDetail {
  ExternalQuestionDetail.project(QuestionDetail detail)
      : kind = detail.kind,
        sourceKind = detail.sourceKind,
        stem = List.unmodifiable(detail.stem),
        options = List.unmodifiable(detail.options.map((option) => StudyOption(
            label: option.label, content: List.unmodifiable(option.content)))),
        answer =
            detail.answer == null ? null : List.unmodifiable(detail.answer!),
        explanation = detail.explanation == null
            ? null
            : List.unmodifiable(detail.explanation!) {
    final count = stem.length +
        (answer?.length ?? 0) +
        (explanation?.length ?? 0) +
        options.fold<int>(0, (total, option) => total + option.content.length);
    if (options.length > 26 || count > 512) {
      externalReadFail(ExternalReadFailure.resourceLimit);
    }
  }
  final StudyQuestionKind kind;
  final StudySourceKind sourceKind;
  final List<StudyContentNode> stem;
  final List<StudyOption> options;
  final List<StudyContentNode>? answer, explanation;
  Map<String, Object?> toJson() => {
        'kind': _kind(kind),
        'stem': _nodes(stem),
        'options': [
          for (final option in options)
            {'label': option.label, 'content': _nodes(option.content)}
        ],
        'answer': _nodes(answer),
        'explanation': _nodes(explanation),
        'sourceKind': sourceKind.name,
      };
}

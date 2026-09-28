import '../../domain/answer_completion/imported_question_set.dart';
import '../../domain/question/question_draft_v2.dart';

enum AnswerCompletionEligibility { missing, answered, legacy, corrupt }

/// Metadata availability only; no filesystem access belongs in this read.
enum AnswerCompletionProvenance { none, available, unavailable }

enum AnswerCompletionCategory { pending, unsupported, completed }

final class AnswerCompletionMember {
  const AnswerCompletionMember.typed({
    required this.storageId,
    required QuestionDraftV2 typedDraft,
  })  : draft = typedDraft,
        invalidState = null;

  const AnswerCompletionMember.legacy(this.storageId)
      : draft = null,
        invalidState = AnswerCompletionEligibility.legacy;
  const AnswerCompletionMember.corrupt(this.storageId)
      : draft = null,
        invalidState = AnswerCompletionEligibility.corrupt;

  final String storageId;
  final QuestionDraftV2? draft;
  final AnswerCompletionEligibility? invalidState;

  AnswerCompletionEligibility get eligibility =>
      invalidState ??
      (draft!.answer == null
          ? AnswerCompletionEligibility.missing
          : AnswerCompletionEligibility.answered);
  bool get isTyped => draft != null;
}

final class AnswerCompletionSet {
  AnswerCompletionSet(
      {required this.set,
      required this.provenance,
      required Iterable<AnswerCompletionMember> members})
      : members = List.unmodifiable(members);

  final ImportedQuestionSet set;
  final AnswerCompletionProvenance provenance;
  final List<AnswerCompletionMember> members;
  int get total => members.length;
  int get missing => members
      .where((m) => m.eligibility == AnswerCompletionEligibility.missing)
      .length;
  int get answered => members
      .where((m) => m.eligibility == AnswerCompletionEligibility.answered)
      .length;
  int get ineligible => members.where((m) => !m.isTyped).length;
  bool get completed => total > 0 && missing == 0 && ineligible == 0;
  bool get canSupplement => total > 0 && ineligible == 0;
  AnswerCompletionCategory get category => !canSupplement
      ? AnswerCompletionCategory.unsupported
      : completed
          ? AnswerCompletionCategory.completed
          : AnswerCompletionCategory.pending;
}

sealed class AnswerCompletionRead {
  const AnswerCompletionRead();
}

final class AnswerCompletionSnapshot extends AnswerCompletionRead {
  AnswerCompletionSnapshot(
      {required Iterable<AnswerCompletionSet> sets,
      required Iterable<AnswerCompletionMember> ungrouped})
      : sets = List.unmodifiable(sets),
        ungrouped = List.unmodifiable(ungrouped);
  final List<AnswerCompletionSet> sets;
  final List<AnswerCompletionMember> ungrouped;

  AnswerCompletionSet? findSet(String setId) {
    for (final set in sets) {
      if (set.set.setId == setId) return set;
    }
    return null;
  }
}

/// No counts are attached to query failure.
final class AnswerCompletionQueryUnavailable extends AnswerCompletionRead {
  const AnswerCompletionQueryUnavailable();
}

/// Every response must be read in one short SQLite transaction. Consumers
/// must not compose this projection from independent repository reads.
abstract interface class AnswerCompletionQuery {
  Future<AnswerCompletionRead> readBank(String bankName);
}

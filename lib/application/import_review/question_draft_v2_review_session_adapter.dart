import '../../domain/question/question_draft_v2.dart';
import 'review_session.dart';

/// One caller-supplied entry for an R4B review session: an explicit item
/// identity paired with the read-only original draft.
///
/// Both fields are caller-owned; the adapter performs no identity synthesis
/// and all format and uniqueness invariants are enforced by the aggregate.
typedef QuestionDraftV2ReviewItemInput = ({
  String itemId,
  QuestionDraftV2 draft,
});

/// One-way adapter from immutable [QuestionDraftV2] drafts to the R4A
/// [ReviewSession]/[ReviewItem] aggregate.
///
/// Each call forms exactly one independent task/producing-attempt session.
/// The caller explicitly supplies the session identity, the origin identity,
/// and every item identity. Drafts are referenced directly and read-only:
/// source refs, asset refs, issues, and raw fallback content are preserved
/// without AI, map/JSON round-trips, or database/UI/filesystem types. No
/// reverse projection or codec exists in this adapter.
final class QuestionDraftV2ReviewSessionAdapter {
  const QuestionDraftV2ReviewSessionAdapter();

  ReviewSession openSession({
    required String sessionId,
    required String taskId,
    required String attemptToken,
    required int attemptNumber,
    required Iterable<QuestionDraftV2ReviewItemInput> items,
  }) {
    final reviewItems = <ReviewItem>[
      for (final input in items)
        ReviewItem.initial(itemId: input.itemId, original: input.draft),
    ];
    return ReviewSession.open(
      sessionId: sessionId,
      taskId: taskId,
      attemptToken: attemptToken,
      attemptNumber: attemptNumber,
      items: reviewItems,
    );
  }
}

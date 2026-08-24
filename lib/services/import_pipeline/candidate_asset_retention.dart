import '../../application/content/content_asset_authority.dart';
import '../../domain/content/content_node.dart';
import '../../domain/content/rich_content.dart';
import '../../domain/question/question_draft_v2.dart';

final class CandidateAssetRetentionPlan {
  const CandidateAssetRetentionPlan({
    required this.original,
    required this.retained,
    required this.unused,
  });

  final ContentAssetCandidateLease original;
  final ContentAssetCandidateLease? retained;
  final ContentAssetCandidateLease? unused;
}

CandidateAssetRetentionPlan partitionCandidateAssets({
  required ContentAssetCandidateLease lease,
  required Iterable<QuestionDraftV2> drafts,
}) {
  final reachable = <(String sourceId, String localAssetId)>{};

  void collect(RichContent content) {
    for (final image in reachableImageNodes(content)) {
      reachable.add((image.sourceId, image.localAssetId));
    }
  }

  for (final draft in drafts) {
    collect(draft.stem);
    for (final option in draft.options) {
      collect(option.content);
    }
    final answer = draft.answer;
    if (answer is ContentAnswer) collect(answer.content);
    final explanation = draft.explanation;
    if (explanation != null) collect(explanation);
  }

  final retainedIds = <String>[];
  final unusedIds = <String>[];
  for (final localAssetId in lease.localAssetIds) {
    if (reachable.contains((lease.sourceId, localAssetId))) {
      retainedIds.add(localAssetId);
    } else {
      unusedIds.add(localAssetId);
    }
  }

  return CandidateAssetRetentionPlan(
    original: lease,
    retained: retainedIds.isEmpty
        ? null
        : ContentAssetCandidateLease(
            sourceId: lease.sourceId,
            localAssetIds: retainedIds,
          ),
    unused: unusedIds.isEmpty
        ? null
        : ContentAssetCandidateLease(
            sourceId: lease.sourceId,
            localAssetIds: unusedIds,
          ),
  );
}

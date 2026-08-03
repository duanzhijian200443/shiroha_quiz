import '../assets/sourced_asset_ref.dart';
import '../content/content_node.dart';
import '../import/import_issue.dart';
import '../source/source_part.dart';
import '../source/source_ref.dart';

enum QuestionRegionField { stem, answer, explanation }

enum QuestionRegionKindHint {
  singleChoice,
  multipleChoice,
  trueFalse,
  fillBlank,
  shortAnswer,
  unknown,
}

enum QuestionRegionReadiness { ready, needsReview, rejected }

final class SourceSlice {
  factory SourceSlice({
    required int startNodeIndex,
    required int startCodeUnitOffset,
    required int endNodeIndex,
    required int endCodeUnitOffset,
  }) {
    if (startNodeIndex < 0 ||
        startCodeUnitOffset < 0 ||
        endNodeIndex < 0 ||
        endCodeUnitOffset < 0) {
      throw const FormatException(
          'Source slice positions must be non-negative.');
    }
    if (_compareSlicePositions(
          startNodeIndex,
          startCodeUnitOffset,
          endNodeIndex,
          endCodeUnitOffset,
        ) >=
        0) {
      throw const FormatException(
        'Source slice start must strictly precede its end.',
      );
    }
    return SourceSlice._(
      startNodeIndex: startNodeIndex,
      startCodeUnitOffset: startCodeUnitOffset,
      endNodeIndex: endNodeIndex,
      endCodeUnitOffset: endCodeUnitOffset,
    );
  }

  const SourceSlice._({
    required this.startNodeIndex,
    required this.startCodeUnitOffset,
    required this.endNodeIndex,
    required this.endCodeUnitOffset,
  });

  final int startNodeIndex;
  final int startCodeUnitOffset;
  final int endNodeIndex;
  final int endCodeUnitOffset;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is SourceSlice &&
            startNodeIndex == other.startNodeIndex &&
            startCodeUnitOffset == other.startCodeUnitOffset &&
            endNodeIndex == other.endNodeIndex &&
            endCodeUnitOffset == other.endCodeUnitOffset;
  }

  @override
  int get hashCode => Object.hash(
        startNodeIndex,
        startCodeUnitOffset,
        endNodeIndex,
        endCodeUnitOffset,
      );
}

final class QuestionRegionFragment {
  factory QuestionRegionFragment({
    required QuestionRegionField field,
    required SourcePart part,
    SourceSlice? slice,
  }) {
    if (slice != null) {
      if (part is! SourceContentPart) {
        throw const FormatException(
          'Source slices are supported only for source content parts.',
        );
      }
      _validateSlice(part, slice);
    }
    return QuestionRegionFragment._(
      field: field,
      part: part,
      slice: slice,
    );
  }

  const QuestionRegionFragment._({
    required this.field,
    required this.part,
    required this.slice,
  });

  final QuestionRegionField field;
  final SourcePart part;
  final SourceSlice? slice;

  SourceRef get sourceRef => part.sourceRef;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is QuestionRegionFragment &&
            field == other.field &&
            part == other.part &&
            slice == other.slice;
  }

  @override
  int get hashCode => Object.hash(field, part, slice);
}

final class QuestionRegion {
  factory QuestionRegion({
    required int questionNumber,
    required Iterable<QuestionRegionFragment> fragments,
    QuestionRegionKindHint kindHint = QuestionRegionKindHint.unknown,
    Iterable<ImportIssue> issues = const <ImportIssue>[],
  }) {
    if (questionNumber <= 0) {
      throw const FormatException('Question numbers must be positive.');
    }

    final copiedFragments =
        List<QuestionRegionFragment>.unmodifiable(fragments);
    if (copiedFragments.isEmpty) {
      throw const FormatException(
        'Question regions require at least one fragment.',
      );
    }
    final copiedIssues = List<ImportIssue>.unmodifiable(issues);

    _deriveAssetRefs(copiedFragments);
    _validateIssueSources(copiedFragments, copiedIssues);
    _validateStemEvidence(copiedFragments, copiedIssues);

    return QuestionRegion._(
      questionNumber: questionNumber,
      fragments: copiedFragments,
      kindHint: kindHint,
      issues: copiedIssues,
    );
  }

  const QuestionRegion._({
    required this.questionNumber,
    required this.fragments,
    required this.kindHint,
    required this.issues,
  });

  final int questionNumber;
  final List<QuestionRegionFragment> fragments;
  final QuestionRegionKindHint kindHint;
  final List<ImportIssue> issues;

  QuestionRegionReadiness get readiness {
    if (issues.any((issue) => issue.severity == ImportIssueSeverity.error)) {
      return QuestionRegionReadiness.rejected;
    }
    if (issues.any((issue) => issue.severity == ImportIssueSeverity.warning)) {
      return QuestionRegionReadiness.needsReview;
    }
    return QuestionRegionReadiness.ready;
  }

  List<QuestionRegionFragment> fragmentsFor(QuestionRegionField field) {
    return List<QuestionRegionFragment>.unmodifiable(
      fragments.where((fragment) => fragment.field == field),
    );
  }

  List<SourceRef> get sourceRefs {
    final seen = <SourceRef>{};
    final derived = <SourceRef>[];
    for (final fragment in fragments) {
      final sourceRef = fragment.part.sourceRef;
      if (seen.add(sourceRef)) {
        derived.add(sourceRef);
      }
    }
    return List<SourceRef>.unmodifiable(derived);
  }

  List<SourcedAssetRef> get assetRefs => _deriveAssetRefs(fragments);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is QuestionRegion &&
            questionNumber == other.questionNumber &&
            kindHint == other.kindHint &&
            _listEquals(fragments, other.fragments) &&
            _listEquals(issues, other.issues);
  }

  @override
  int get hashCode => Object.hash(
        questionNumber,
        kindHint,
        Object.hashAll(fragments),
        Object.hashAll(issues),
      );
}

void _validateSlice(SourceContentPart part, SourceSlice slice) {
  final nodes = part.content.nodes;
  _validateSlicePosition(
    nodes,
    slice.startNodeIndex,
    slice.startCodeUnitOffset,
  );
  _validateSlicePosition(
    nodes,
    slice.endNodeIndex,
    slice.endCodeUnitOffset,
  );
}

void _validateSlicePosition(
  List<ContentNode> nodes,
  int nodeIndex,
  int codeUnitOffset,
) {
  if (nodeIndex > nodes.length) {
    throw const FormatException('Source slice node index is out of bounds.');
  }
  if (nodeIndex == nodes.length) {
    if (codeUnitOffset != 0) {
      throw const FormatException(
        'The terminal source slice position requires a zero offset.',
      );
    }
    return;
  }
  if (codeUnitOffset == 0) return;

  final node = nodes[nodeIndex];
  if (node is! TextNode || codeUnitOffset >= node.text.length) {
    throw const FormatException(
      'Non-zero source slice offsets must be strictly inside text nodes.',
    );
  }
}

int _compareSlicePositions(
  int leftNodeIndex,
  int leftCodeUnitOffset,
  int rightNodeIndex,
  int rightCodeUnitOffset,
) {
  final nodeComparison = leftNodeIndex.compareTo(rightNodeIndex);
  if (nodeComparison != 0) return nodeComparison;
  return leftCodeUnitOffset.compareTo(rightCodeUnitOffset);
}

List<SourcedAssetRef> _deriveAssetRefs(
  Iterable<QuestionRegionFragment> fragments,
) {
  final byIdentity = <(String, String), SourcedAssetRef>{};
  final derived = <SourcedAssetRef>[];
  for (final fragment in fragments) {
    final part = fragment.part;
    if (part is! SourceAssetPart) continue;

    final sourced = SourcedAssetRef(
      sourceId: part.sourceRef.sourceId,
      asset: part.asset,
    );
    final identity = (sourced.sourceId, sourced.localAssetId);
    final existing = byIdentity[identity];
    if (existing == null) {
      byIdentity[identity] = sourced;
      derived.add(sourced);
    } else if (existing.asset != sourced.asset) {
      throw const FormatException(
        'A source-qualified asset identity has conflicting metadata.',
      );
    }
  }
  return List<SourcedAssetRef>.unmodifiable(derived);
}

void _validateIssueSources(
  List<QuestionRegionFragment> fragments,
  List<ImportIssue> issues,
) {
  final sourceIds =
      fragments.map((fragment) => fragment.part.sourceRef.sourceId).toSet();
  for (final issue in issues) {
    final issueSourceRef = issue.sourceRef;
    if (issueSourceRef != null &&
        !sourceIds.contains(issueSourceRef.sourceId)) {
      throw const FormatException(
        'Issue source IDs must belong to the question region.',
      );
    }
  }
}

void _validateStemEvidence(
  List<QuestionRegionFragment> fragments,
  List<ImportIssue> issues,
) {
  if (fragments.any((fragment) => fragment.field == QuestionRegionField.stem)) {
    return;
  }
  final hasMissingStemIssue = issues.any(
    (issue) =>
        (issue.severity == ImportIssueSeverity.warning ||
            issue.severity == ImportIssueSeverity.error) &&
        (issue.field == ImportIssueField.stem ||
            issue.field == ImportIssueField.question),
  );
  if (!hasMissingStemIssue) {
    throw const FormatException(
      'Regions without stem fragments require a warning or error.',
    );
  }
}

bool _listEquals<T>(List<T> left, List<T> right) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

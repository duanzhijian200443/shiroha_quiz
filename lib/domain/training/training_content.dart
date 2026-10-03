import 'category_key.dart';
import 'training_content_member.dart';

/// Immutable configuration snapshot. Only [contentId] identifies the content;
/// names may repeat. Bank existence, eligibility and category admission belong
/// to Application/persistence, not this value's structural validation.
final class TrainingContent {
  TrainingContent({
    required this.contentId,
    required this.categoryKey,
    required String name,
    required this.questionLimit,
    required this.sortOrder,
    required this.revision,
    required List<TrainingContentMember> members,
  })  : name = name.trim(),
        members = List.unmodifiable(members) {
    if (contentId.trim().isEmpty) {
      throw const FormatException('Training content identity is required.');
    }
    if (this.name.isEmpty) {
      throw const FormatException('Training content name is required.');
    }
    validateTrainingQuestionLimit(questionLimit);
    if (revision <= 0) {
      throw const FormatException(
          'Training content revision must be positive.');
    }
    validateTrainingMemberWeights(this.members);
    final positions = <int>{};
    for (final member in this.members) {
      if (!positions.add(member.position)) {
        throw const FormatException(
            'Training member positions must be unique.');
      }
    }
  }

  final String contentId;
  final CategoryKey categoryKey;
  final String name;
  final int questionLimit;
  final int sortOrder;
  final int revision;
  final List<TrainingContentMember> members;

  /// A necessary condition only; this does not assert runtime bank eligibility.
  bool get hasValidBindings => members
      .every((member) => member.bindingStatus == TrainingBindingStatus.valid);
}

/// Shared question-limit admission for configuration and ideal quota.
void validateTrainingQuestionLimit(int questionLimit) {
  if (questionLimit < 1 || questionLimit > 100) {
    throw const FormatException('Training question limit must be 1..100.');
  }
}

/// Validates the saved weight distribution, without consulting bank state.
void validateTrainingMemberWeights(List<TrainingContentMember> members) {
  if (members.isEmpty) {
    throw const FormatException('Training content needs at least one member.');
  }
  final bankNames = <String>{};
  var sum = 0;
  var hasPositiveWeight = false;
  for (final member in members) {
    if (!bankNames.add(member.bankName)) {
      throw const FormatException('Training member bank names must be unique.');
    }
    sum += member.weightPercent;
    hasPositiveWeight |= member.weightPercent > 0;
  }
  if (!hasPositiveWeight || sum != 100) {
    throw const FormatException(
        'Training member weights must sum to 100 with a positive member.');
  }
}

import '../../domain/training/category_key.dart';
import '../../domain/training/training_content.dart';
import '../../domain/training/training_content_member.dart';
import '../home_training_result.dart';

final class OrdinaryTrainingBankInput {
  OrdinaryTrainingBankInput(this.bankName) {
    requireHomeTrainingInput(bankName.trim().isNotEmpty);
  }
  final String bankName;
}

enum OrdinaryTrainingBankEligibilityStatus { eligible, ineligible }

/// Single eligibility authority for catalog, selector, seed, admission and
/// Category review. Implementations consume existing visibility/reserved-bank
/// authority; no name/emoji heuristics, mutation or legacy self-healing.
abstract interface class OrdinaryTrainingBankEligibility {
  Future<HomeTrainingResult<OrdinaryTrainingBankEligibilityStatus>> evaluate(
    OrdinaryTrainingBankInput input,
  );
}

final class TrainingCatalogBank {
  TrainingCatalogBank({
    required this.bankName,
    required this.categoryKey,
    required this.ordinaryTrainingEligible,
  }) {
    requireHomeTrainingInput(bankName.trim().isNotEmpty);
  }
  final String bankName;
  final CategoryKey categoryKey;
  final bool ordinaryTrainingEligible;
}

/// One captured catalog. Category order is supplied by the query authority;
/// empty custom folders remain available to configuration. Each exact bank
/// occurs once with one Category/eligibility decision in this snapshot.
final class TrainingCatalogSnapshot {
  TrainingCatalogSnapshot({
    required Iterable<CategoryKey> categories,
    required Iterable<TrainingCatalogBank> banks,
  })  : categories = List.unmodifiable(categories),
        banks = List.unmodifiable(banks) {
    final categorySet = this.categories.toSet();
    requireHomeTrainingInput(categorySet.length == this.categories.length);
    final bankNames = <String>{};
    for (final bank in this.banks) {
      requireHomeTrainingInput(
        categorySet.contains(bank.categoryKey) && bankNames.add(bank.bankName),
      );
    }
  }
  final List<CategoryKey> categories;
  final List<TrainingCatalogBank> banks;
}

abstract interface class TrainingCatalogQuery {
  /// Captures a consistent read-only catalog, with no ReviewState/folder writes.
  Future<HomeTrainingResult<TrainingCatalogSnapshot>> capture();
}

enum CategoryVisualKey { math, english, computerScience, genericLearning }

/// Null revision means the preference row is absent. A null currentContentId
/// on an existing row means explicit no selection, not an absent preference.
final class TrainingCategoryPreference {
  TrainingCategoryPreference({
    required this.categoryKey,
    required this.revision,
    this.currentContentId,
    this.visualKey,
  }) {
    requireHomeTrainingInput(revision == null || revision! > 0);
    requireHomeTrainingInput(
        currentContentId == null || currentContentId!.trim().isNotEmpty);
    requireHomeTrainingInput(
        revision != null || (currentContentId == null && visualKey == null));
  }
  final CategoryKey categoryKey;
  final int? revision;
  final String? currentContentId;
  final CategoryVisualKey? visualKey;
}

/// Usability is supplied by Application from a captured catalog, never inferred
/// in Presentation. A structurally valid unavailable configuration is retained.
final class TrainingContentView {
  TrainingContentView({required this.content, required this.usable}) {
    requireHomeTrainingInput(!usable || content.hasValidBindings);
  }
  final TrainingContent content;
  final bool usable;
}

final class TrainingCategorySnapshot {
  TrainingCategorySnapshot({
    required this.categoryKey,
    required this.preference,
    required Iterable<TrainingContentView> contents,
  }) : contents = List.unmodifiable(contents) {
    requireHomeTrainingInput(preference.categoryKey == categoryKey);
    final ids = <String>{};
    for (final view in this.contents) {
      requireHomeTrainingInput(view.content.categoryKey == categoryKey &&
          ids.add(view.content.contentId));
    }
    requireHomeTrainingInput(preference.currentContentId == null ||
        ids.contains(preference.currentContentId));
  }
  final CategoryKey categoryKey;
  final TrainingCategoryPreference preference;
  final List<TrainingContentView> contents;
}

enum TrainingCurrentContentState { usable, unconfigured, unavailable }

/// Persisted references and runtime fallback are separate. Reading this value
/// never saves the fallback, clears an unavailable preference, or repairs data.
final class TrainingCurrentSelection {
  TrainingCurrentSelection({
    required this.persistedCategoryKey,
    required this.categoryKey,
    required this.preference,
    required this.currentContent,
    required this.state,
  }) {
    requireHomeTrainingInput(
        preference == null || preference!.categoryKey == categoryKey);
    requireHomeTrainingInput(currentContent == null ||
        currentContent!.content.categoryKey == categoryKey);
    requireHomeTrainingInput(switch (state) {
      TrainingCurrentContentState.usable =>
        categoryKey != null && currentContent?.usable == true,
      TrainingCurrentContentState.unconfigured => currentContent == null,
      TrainingCurrentContentState.unavailable => currentContent?.usable != true,
    });
  }
  final CategoryKey? persistedCategoryKey;
  final CategoryKey? categoryKey;
  final TrainingCategoryPreference? preference;
  final TrainingContentView? currentContent;
  final TrainingCurrentContentState state;
}

abstract interface class TrainingContentQuery {
  Future<HomeTrainingResult<TrainingCategorySnapshot>> listByCategory(
      CategoryKey categoryKey);
  Future<HomeTrainingResult<TrainingContentView>> getById(String contentId);
  Future<HomeTrainingResult<TrainingCurrentSelection>> current();
}

/// Immutable editable fields; identity, Category and revision are not editable.
final class TrainingContentEdit {
  TrainingContentEdit({
    required String name,
    required this.questionLimit,
    required this.sortOrder,
    required Iterable<TrainingContentMember> members,
  })  : name = name.trim(),
        members = List.unmodifiable(members) {
    requireHomeTrainingInput(this.name.isNotEmpty);
    try {
      validateTrainingQuestionLimit(questionLimit);
      validateTrainingMemberWeights(this.members);
    } on FormatException {
      throw const HomeTrainingContractException(
          HomeTrainingFailure.invalidInput);
    }
    requireHomeTrainingInput(
        this.members.map((member) => member.position).toSet().length ==
            this.members.length);
  }
  final String name;
  final int questionLimit;
  final int sortOrder;
  final List<TrainingContentMember> members;
}

final class CreateTrainingContentRequest {
  const CreateTrainingContentRequest(
      {required this.categoryKey, required this.edit});
  final CategoryKey categoryKey;
  final TrainingContentEdit edit;
}

final class TrainingContentTarget {
  TrainingContentTarget(
      {required this.contentId, required this.expectedRevision}) {
    requireHomeTrainingInput(
        contentId.trim().isNotEmpty && expectedRevision > 0);
  }
  final String contentId;
  final int expectedRevision;
}

final class UpdateTrainingContentRequest {
  const UpdateTrainingContentRequest(
      {required this.target, required this.edit});
  final TrainingContentTarget target;
  final TrainingContentEdit edit;
}

/// Separate preference CAS. Null expectedRevision requires the row to remain
/// absent; it is never a wildcard/upsert permission. Non-null uses exact CAS.
final class TrainingPreferenceTarget {
  TrainingPreferenceTarget(
      {required this.categoryKey, required this.expectedRevision}) {
    requireHomeTrainingInput(expectedRevision == null || expectedRevision! > 0);
  }
  final CategoryKey categoryKey;
  final int? expectedRevision;
}

final class SelectTrainingContentRequest {
  SelectTrainingContentRequest(
      {required this.target, required this.contentId}) {
    requireHomeTrainingInput(contentId == null || contentId!.trim().isNotEmpty);
  }
  final TrainingPreferenceTarget target;
  final String? contentId;
}

final class UpdateCategoryVisualRequest {
  const UpdateCategoryVisualRequest(
      {required this.target, required this.visualKey});
  final TrainingPreferenceTarget target;
  final CategoryVisualKey visualKey;
}

/// Future adapters must revalidate bank existence, eligibility and same-Category
/// in one atomic mutation. Stale is zero mutation, with no automatic retry.
/// Create generates opaque identity; update cannot migrate Category. Delete
/// removes configuration only. Select saves global Category and its preference
/// before publishing context; visual/selection never increase content revision.
abstract interface class TrainingContentCommand {
  Future<HomeTrainingResult<TrainingContent>> create(
      CreateTrainingContentRequest request);
  Future<HomeTrainingResult<TrainingContent>> update(
      UpdateTrainingContentRequest request);
  Future<HomeTrainingResult<HomeTrainingUnit>> delete(
      TrainingContentTarget target);
  Future<HomeTrainingResult<TrainingCurrentSelection>> selectCurrent(
      SelectTrainingContentRequest request);
  Future<HomeTrainingResult<TrainingCategoryPreference>> updateCategoryVisual(
      UpdateCategoryVisualRequest request);
}

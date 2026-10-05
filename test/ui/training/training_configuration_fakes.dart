import 'dart:async';
import 'package:shiroha_quiz/application/home_training_result.dart';
import 'package:shiroha_quiz/application/training/training_configuration_contracts.dart';
import 'package:shiroha_quiz/application/training/training_contracts.dart';
import 'package:shiroha_quiz/domain/training/category_key.dart';
import 'package:shiroha_quiz/domain/training/training_content.dart';
import 'package:shiroha_quiz/domain/training/training_content_member.dart';
import 'package:shiroha_quiz/ui/training/training_configuration_controller.dart';

final mathCategory = FolderCategoryKey('数学');

TrainingContent fixtureContent(
        {String id = 'content',
        String name = '高数 + 线代',
        bool invalid = false,
        int revision = 4}) =>
    TrainingContent(
      contentId: id,
      categoryKey: mathCategory,
      name: name,
      questionLimit: 20,
      sortOrder: 0,
      revision: revision,
      members: [
        TrainingContentMember(
            bankName: '高数',
            weightPercent: 60,
            position: 0,
            bindingStatus: invalid
                ? TrainingBindingStatus.invalidated
                : TrainingBindingStatus.valid,
            invalidationReason:
                invalid ? TrainingBindingInvalidationReason.bankMissing : null),
        TrainingContentMember(bankName: '线代', weightPercent: 40, position: 1),
      ],
    );

TrainingConfigurationSnapshot fixtureSnapshot(
    {bool invalid = false, CategoryVisualKey? visual}) {
  final category = mathCategory;
  final empty = FolderCategoryKey('空分类');
  final english = FolderCategoryKey('英语');
  return TrainingConfigurationSnapshot(
    catalog: TrainingCatalogSnapshot(categories: [
      category,
      empty,
      english
    ], banks: [
      TrainingCatalogBank(
          bankName: '高数',
          categoryKey: category,
          ordinaryTrainingEligible: true),
      TrainingCatalogBank(
          bankName: '线代',
          categoryKey: category,
          ordinaryTrainingEligible: true),
      TrainingCatalogBank(
          bankName: '概率',
          categoryKey: category,
          ordinaryTrainingEligible: true),
      TrainingCatalogBank(
          bankName: '保留库',
          categoryKey: category,
          ordinaryTrainingEligible: false),
      TrainingCatalogBank(
          bankName: '四级', categoryKey: english, ordinaryTrainingEligible: true),
    ]),
    categories: [
      TrainingCategorySnapshot(
          categoryKey: category,
          preference: TrainingCategoryPreference(
              categoryKey: category,
              revision: 7,
              currentContentId: 'content',
              visualKey: visual),
          contents: [
            TrainingContentView(
                content: fixtureContent(invalid: invalid), usable: !invalid),
            TrainingContentView(
                content: fixtureContent(id: 'second', name: '第二配置'),
                usable: true)
          ]),
      for (final key in [empty, english])
        TrainingCategorySnapshot(
            categoryKey: key,
            preference:
                TrainingCategoryPreference(categoryKey: key, revision: null),
            contents: []),
    ],
  );
}

class ConfigurationFake
    implements
        TrainingConfigurationQuery,
        TrainingContentCommand,
        TrainingContentOrderCommand {
  TrainingConfigurationSnapshot value = fixtureSnapshot();
  final calls = <Object>[];
  int reads = 0;
  HomeTrainingFailure? contentFailure;
  HomeTrainingFailure? visualFailure;
  HomeTrainingFailure? otherFailure;
  bool readFails = false;
  bool readThrows = false;
  final pendingReads =
      <Completer<HomeTrainingResult<TrainingConfigurationSnapshot>>>[];
  Completer<HomeTrainingResult<TrainingContent>>? pendingContent;
  TrainingConfigurationController controller() =>
      TrainingConfigurationController(
          query: this, command: this, orderCommand: this);

  @override
  Future<HomeTrainingResult<TrainingConfigurationSnapshot>>
      readConfiguration() async {
    reads++;
    if (pendingReads.isNotEmpty) return pendingReads.removeAt(0).future;
    if (readThrows) throw StateError('synthetic cause must not reach UI');
    return readFails
        ? const HomeTrainingFailed(HomeTrainingFailure.unavailable)
        : HomeTrainingSuccess(value);
  }

  TrainingContent saved(TrainingContentEdit edit,
          {String id = 'new', int revision = 1}) =>
      TrainingContent(
          contentId: id,
          categoryKey: mathCategory,
          name: edit.name,
          questionLimit: edit.questionLimit,
          sortOrder: edit.sortOrder,
          revision: revision,
          members: edit.members);

  @override
  Future<HomeTrainingResult<TrainingContent>> create(
      CreateTrainingContentRequest request) async {
    calls.add(request);
    if (pendingContent != null) return pendingContent!.future;
    return contentFailure == null
        ? HomeTrainingSuccess(saved(request.edit))
        : HomeTrainingFailed(contentFailure!);
  }

  @override
  Future<HomeTrainingResult<TrainingContent>> update(
      UpdateTrainingContentRequest request) async {
    calls.add(request);
    if (pendingContent != null) return pendingContent!.future;
    return contentFailure == null
        ? HomeTrainingSuccess(saved(request.edit,
            id: request.target.contentId,
            revision: request.target.expectedRevision + 1))
        : HomeTrainingFailed(contentFailure!);
  }

  @override
  Future<HomeTrainingResult<TrainingContent>> rebindMember(
      RebindTrainingContentMemberRequest request) async {
    calls.add(request);
    return otherFailure == null
        ? HomeTrainingSuccess(
            fixtureContent(revision: request.target.expectedRevision + 1))
        : HomeTrainingFailed(otherFailure!);
  }

  @override
  Future<HomeTrainingResult<HomeTrainingUnit>> delete(
      TrainingContentTarget target) async {
    calls.add(target);
    return otherFailure == null
        ? const HomeTrainingSuccess(HomeTrainingUnit())
        : HomeTrainingFailed(otherFailure!);
  }

  @override
  Future<HomeTrainingResult<TrainingCurrentSelection>> selectCurrent(
      SelectTrainingContentRequest request) async {
    calls.add(request);
    return otherFailure == null
        ? HomeTrainingSuccess(TrainingCurrentSelection(
            persistedCategoryKey: request.target.categoryKey,
            categoryKey: request.target.categoryKey,
            preference: TrainingCategoryPreference(
                categoryKey: request.target.categoryKey,
                revision: (request.target.expectedRevision ?? 0) + 1,
                currentContentId: request.contentId),
            currentContent:
                TrainingContentView(content: fixtureContent(), usable: true),
            state: TrainingCurrentContentState.usable))
        : HomeTrainingFailed(otherFailure!);
  }

  @override
  Future<HomeTrainingResult<TrainingCategoryPreference>> updateCategoryVisual(
      UpdateCategoryVisualRequest request) async {
    calls.add(request);
    return visualFailure == null
        ? HomeTrainingSuccess(TrainingCategoryPreference(
            categoryKey: request.target.categoryKey,
            revision: (request.target.expectedRevision ?? 0) + 1,
            visualKey: request.visualKey))
        : HomeTrainingFailed(visualFailure!);
  }

  @override
  Future<HomeTrainingResult<HomeTrainingUnit>> moveContent(
      MoveTrainingContentRequest request) async {
    calls.add(request);
    return otherFailure == null
        ? const HomeTrainingSuccess(HomeTrainingUnit())
        : HomeTrainingFailed(otherFailure!);
  }
}

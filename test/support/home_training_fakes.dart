import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/home_training_result.dart';
import 'package:shiroha_quiz/application/training/today_training_contracts.dart';
import 'package:shiroha_quiz/application/training/training_contracts.dart';
import 'package:shiroha_quiz/application/training/training_configuration_contracts.dart';
import 'package:shiroha_quiz/application/training/training_session_contracts.dart';
import 'package:shiroha_quiz/application/study_activity/study_activity_contracts.dart';
import 'package:shiroha_quiz/domain/training/category_key.dart';
import 'package:shiroha_quiz/domain/training/training_content.dart';
import 'package:shiroha_quiz/domain/training/training_content_member.dart';
import 'package:shiroha_quiz/ui/dependencies/home_training_dependencies.dart';

final homeA = FolderCategoryKey('数学');
final homeB = FolderCategoryKey('英语');
final homeC = FolderCategoryKey('计算机');

TrainingContent homeContent(String id, CategoryKey key, {int order = 0}) =>
    TrainingContent(
        contentId: id,
        categoryKey: key,
        name: key == homeB
            ? '词汇 + 阅读'
            : key == homeC
                ? '算法与数据结构'
                : '高数 + 线代 $id',
        questionLimit: 20,
        sortOrder: order,
        revision: 1,
        members: [
          TrainingContentMember(
              bankName: 'bank-$id', weightPercent: 100, position: 0)
        ]);

class HomeTrainingFake extends Fake
    implements
        TodayTrainingQuery,
        TrainingContentQuery,
        TrainingContentCommand,
        TrainingConfigurationQuery,
        TrainingContentOrderCommand,
        TrainingSessionApplicationService,
        StudyActivityQuery {
  HomeTrainingFake(
      {int categories = 2,
      this.unconfigured = false,
      this.newCount = 7,
      this.reviewCount = 12,
      this.partial = false,
      this.durationMs = 15000}) {
    groups = [
      for (final key in [homeA, homeB, homeC].take(categories))
        TrainingCategorySnapshot(
            categoryKey: key,
            preference:
                TrainingCategoryPreference(categoryKey: key, revision: 1),
            contents: unconfigured
                ? []
                : [
                    TrainingContentView(
                        content: homeContent(
                            'A${key == homeA ? 'math' : key == homeB ? 'english' : 'computer'}',
                            key),
                        usable: true),
                    TrainingContentView(
                        content: homeContent(
                            'B${key == homeA ? 'math' : key == homeB ? 'english' : 'computer'}',
                            key,
                            order: 1),
                        usable: true),
                    TrainingContentView(
                        content: homeContent(
                            'C${key == homeA ? 'math' : key == homeB ? 'english' : 'computer'}',
                            key,
                            order: 2),
                        usable: true),
                  ])
    ];
  }
  late List<TrainingCategorySnapshot> groups;
  CategoryKey selected = homeA;
  bool unconfigured;
  int newCount;
  int reviewCount;
  bool partial;
  int durationMs;
  bool weekFailed = false;
  int reads = 0, weeks = 0, starts = 0;
  List<SelectTrainingContentRequest> selections = [];
  TrainingContentTarget? launchedTarget;
  CategoryKey? launchedCategory;
  TrainingSessionLaunchResult launchResult = const TrainingSessionEmpty();
  HomeTrainingFailure? selectionFailure;
  Completer<HomeTrainingResult<TodayTrainingSnapshot>>? readGate;
  Completer<void>? selectionGate;
  Completer<TrainingSessionLaunchResult>? launchGate;
  HomeTrainingDependencies get ports => HomeTrainingDependencies(
      today: this,
      contentQuery: this,
      command: this,
      configurationQuery: this,
      orderCommand: this,
      session: this);

  TodayTrainingSnapshot get snapshot {
    final group = groups.firstWhere((g) => g.categoryKey == selected);
    final content = group.contents
            .where(
                (v) => v.content.contentId == group.preference.currentContentId)
            .firstOrNull ??
        group.contents.firstOrNull;
    return TodayTrainingSnapshot(
        selection: TrainingCurrentSelection(
            persistedCategoryKey: selected,
            categoryKey: selected,
            preference: group.preference,
            currentContent: content,
            state: content == null
                ? TrainingCurrentContentState.unconfigured
                : TrainingCurrentContentState.usable),
        categories: groups.map((g) => g.categoryKey),
        categoryVisuals: {
          for (final group in groups)
            group.categoryKey: group.preference.visualKey
        },
        newCount: content == null
            ? const HomeTrainingFailed(HomeTrainingFailure.unavailable)
            : HomeTrainingSuccess(TrainingCount(newCount)),
        categoryReviewCount: HomeTrainingSuccess(TrainingCount(reviewCount)),
        summary: content == null
            ? const HomeTrainingFailed(HomeTrainingFailure.unavailable)
            : HomeTrainingSuccess(TrainingContentSummary(
                totalCount: 327, masteredCount: 27, todayPracticedCount: 5)));
  }

  @override
  Future<HomeTrainingResult<TodayTrainingSnapshot>> readCurrent() async {
    reads++;
    return readGate?.future ?? HomeTrainingSuccess(snapshot);
  }

  @override
  Future<HomeTrainingResult<TrainingCategorySnapshot>> listByCategory(
          CategoryKey key) async =>
      HomeTrainingSuccess(groups.firstWhere((g) => g.categoryKey == key));
  @override
  Future<HomeTrainingResult<TrainingConfigurationSnapshot>>
      readConfiguration() async =>
          HomeTrainingSuccess(TrainingConfigurationSnapshot(
              catalog: TrainingCatalogSnapshot(
                  categories: groups.map((g) => g.categoryKey), banks: []),
              categories: groups));
  @override
  Future<HomeTrainingResult<TrainingCurrentSelection>> selectCurrent(
      SelectTrainingContentRequest request) async {
    selections.add(request);
    await selectionGate?.future;
    if (selectionFailure != null) return HomeTrainingFailed(selectionFailure!);
    selected = request.target.categoryKey;
    groups = [
      for (final g in groups)
        if (g.categoryKey != selected)
          g
        else
          TrainingCategorySnapshot(
              categoryKey: selected,
              preference: TrainingCategoryPreference(
                  categoryKey: selected,
                  revision: (g.preference.revision ?? 0) + 1,
                  currentContentId: request.contentId,
                  visualKey: g.preference.visualKey),
              contents: g.contents)
    ];
    return HomeTrainingSuccess(snapshot.selection);
  }

  @override
  Future<TrainingSessionLaunchResult> startNew(
      TrainingContentTarget target) async {
    starts++;
    launchedTarget = target;
    return launchGate?.future ?? launchResult;
  }

  @override
  Future<TrainingSessionLaunchResult> startCategoryReview(
      CategoryKey key) async {
    starts++;
    launchedCategory = key;
    return launchGate?.future ?? launchResult;
  }

  @override
  Future<HomeTrainingResult<StudyActivityWeekSnapshot>>
      readCurrentWeek() async {
    weeks++;
    if (weekFailed) {
      return const HomeTrainingFailed(HomeTrainingFailure.unavailable);
    }
    return HomeTrainingSuccess(StudyActivityWeekSnapshot(
        mondayLocalDate: '2026-10-05',
        recordingQuality: partial
            ? StudyActivityRecordingQuality.partial
            : StudyActivityRecordingQuality.recordedOnly,
        days: [
          for (var i = 0; i < 7; i++)
            StudyActivityDaySummary(
                localDate: '2026-10-${(5 + i).toString().padLeft(2, '0')}',
                durationMs: i == 0 ? durationMs : 0)
        ]));
  }
}

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/home_training_result.dart';
import 'package:shiroha_quiz/application/training/training_contracts.dart';
import 'package:shiroha_quiz/application/training/today_training_contracts.dart';
import 'package:shiroha_quiz/domain/training/category_key.dart';
import 'package:shiroha_quiz/domain/training/training_content.dart';
import 'package:shiroha_quiz/domain/training/training_content_member.dart';

const _category = UncategorizedCategoryKey();

TrainingCurrentSelection _unconfigured() => TrainingCurrentSelection(
    persistedCategoryKey: _category,
    categoryKey: _category,
    preference:
        TrainingCategoryPreference(categoryKey: _category, revision: null),
    currentContent: null,
    state: TrainingCurrentContentState.unconfigured);

void main() {
  test('Category review succeeds independently of unconfigured new training',
      () {
    final categories = <CategoryKey>[_category];
    final snapshot = TodayTrainingSnapshot(
        selection: _unconfigured(),
        categories: categories,
        categoryVisuals: {_category: null},
        newCount: const HomeTrainingFailed(HomeTrainingFailure.notFound),
        categoryReviewCount: HomeTrainingSuccess(TrainingCount(8)),
        summary: const HomeTrainingFailed(HomeTrainingFailure.notFound));
    categories.clear();
    expect(
        (snapshot.categoryReviewCount as HomeTrainingSuccess<TrainingCount>)
            .value
            .value,
        8);
    expect(snapshot.selection.state, TrainingCurrentContentState.unconfigured);
    expect(snapshot.newCount, isA<HomeTrainingFailed<TrainingCount>>());
    expect(snapshot.categories, [_category]);
    expect(snapshot.categoryVisuals, {_category: null});
    expect(() => snapshot.categories.clear(), throwsUnsupportedError);
    expect(() => snapshot.categoryVisuals.clear(), throwsUnsupportedError);
  });

  test(
      'usable content can express true zero and independent safe count failure',
      () {
    final content = TrainingContent(
        contentId: 'a',
        categoryKey: _category,
        name: 'A',
        questionLimit: 20,
        sortOrder: 0,
        revision: 1,
        members: [
          TrainingContentMember(bankName: 'A', weightPercent: 100, position: 0),
          TrainingContentMember(bankName: 'B', weightPercent: 0, position: 1)
        ]);
    final selection = TrainingCurrentSelection(
        persistedCategoryKey: _category,
        categoryKey: _category,
        preference: TrainingCategoryPreference(
            categoryKey: _category, revision: 1, currentContentId: 'a'),
        currentContent: TrainingContentView(content: content, usable: true),
        state: TrainingCurrentContentState.usable);
    final snapshot = TodayTrainingSnapshot(
        selection: selection,
        categories: [_category],
        categoryVisuals: {_category: CategoryVisualKey.english},
        newCount: HomeTrainingSuccess(TrainingCount(0)),
        categoryReviewCount:
            const HomeTrainingFailed(HomeTrainingFailure.unavailable),
        summary: HomeTrainingSuccess(TrainingContentSummary(
            totalCount: 100, masteredCount: 10, todayPracticedCount: 2)));
    expect(snapshot.categoryVisuals[_category], CategoryVisualKey.english);
    expect(
        (snapshot.newCount as HomeTrainingSuccess<TrainingCount>).value.value,
        0);
    expect(
        snapshot.categoryReviewCount, isA<HomeTrainingFailed<TrainingCount>>());
    expect(
        (snapshot.summary as HomeTrainingSuccess<TrainingContentSummary>)
            .value
            .totalCount,
        100);
    expect(content.members.last.weightPercent, 0);
  });

  test(
      'unavailable/unconfigured cannot claim new-count or content-summary success',
      () {
    expect(
        () => TodayTrainingSnapshot(
            selection: _unconfigured(),
            categories: [_category],
            categoryVisuals: {_category: null},
            newCount: HomeTrainingSuccess(TrainingCount(0)),
            categoryReviewCount: HomeTrainingSuccess(TrainingCount(0)),
            summary: const HomeTrainingFailed(HomeTrainingFailure.notFound)),
        throwsA(isA<HomeTrainingContractException>()));
    expect(
        () => TodayTrainingSnapshot(
            selection: _unconfigured(),
            categories: [_category],
            categoryVisuals: const {},
            newCount: const HomeTrainingFailed(HomeTrainingFailure.notFound),
            categoryReviewCount: HomeTrainingSuccess(TrainingCount(0)),
            summary: const HomeTrainingFailed(HomeTrainingFailure.notFound)),
        throwsA(isA<HomeTrainingContractException>()));
    expect(
        () => TrainingCount(-1), throwsA(isA<HomeTrainingContractException>()));
    expect(
        () => TrainingContentSummary(
            totalCount: 3, masteredCount: 4, todayPracticedCount: 0),
        throwsA(isA<HomeTrainingContractException>()));
  });
}

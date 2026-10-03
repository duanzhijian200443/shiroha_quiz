import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/training/training_configuration_projection.dart';
import 'package:shiroha_quiz/application/training/training_contracts.dart';
import 'package:shiroha_quiz/domain/training/category_key.dart';
import 'package:shiroha_quiz/domain/training/training_content.dart';
import 'package:shiroha_quiz/domain/training/training_content_member.dart';

const _key = UncategorizedCategoryKey();

TrainingContent _content(String id,
        {int order = 0, bool invalidated = false}) =>
    TrainingContent(
        contentId: id,
        categoryKey: _key,
        name: 'Training',
        questionLimit: 40,
        sortOrder: order,
        revision: 1,
        members: [
          TrainingContentMember(
              bankName: 'Bank', weightPercent: 100, position: 0),
          TrainingContentMember(
              bankName: 'Zero',
              weightPercent: 0,
              position: 1,
              bindingStatus: invalidated
                  ? TrainingBindingStatus.invalidated
                  : TrainingBindingStatus.valid),
        ]);

TrainingCatalogSnapshot _catalog(
        {bool zeroEligible = true, CategoryKey zeroCategory = _key}) =>
    TrainingCatalogSnapshot(categories: {
      _key,
      zeroCategory
    }, banks: [
      TrainingCatalogBank(
          bankName: 'Bank', categoryKey: _key, ordinaryTrainingEligible: true),
      TrainingCatalogBank(
          bankName: 'Zero',
          categoryKey: zeroCategory,
          ordinaryTrainingEligible: zeroEligible),
    ]);

void main() {
  test('Category identity order is exact and Uncategorized always last', () {
    final keys = <CategoryKey>[
      _key,
      FolderCategoryKey('a'),
      FolderCategoryKey('Z'),
      FolderCategoryKey('📁 未分类题库'),
      FolderCategoryKey(' A ')
    ];
    keys.sort(compareTrainingCategories);
    expect(keys, [
      FolderCategoryKey(' A '),
      FolderCategoryKey('Z'),
      FolderCategoryKey('a'),
      FolderCategoryKey('📁 未分类题库'),
      _key
    ]);
  });

  test(
      'every member including zero weight must be valid, present, eligible and same Category',
      () {
    final content = _content('a');
    expect(projectTrainingContent(content, _catalog()).usable, isTrue);
    expect(
        projectTrainingContent(content, _catalog(zeroEligible: false)).usable,
        isFalse);
    expect(
        projectTrainingContent(
                content, _catalog(zeroCategory: FolderCategoryKey('Elsewhere')))
            .usable,
        isFalse);
    expect(
        projectTrainingContent(_content('a', invalidated: true), _catalog())
            .usable,
        isFalse);
    final missing = TrainingCatalogSnapshot(
        categories: [_key], banks: [_catalog().banks.first]);
    expect(projectTrainingContent(content, missing).usable, isFalse);
  });

  test(
      'content fallback uses sortOrder/contentId while retaining unavailable persisted reference',
      () {
    final catalog = _catalog();
    final snapshot = TrainingCategorySnapshot(
        categoryKey: _key,
        preference: TrainingCategoryPreference(
            categoryKey: _key, revision: 7, currentContentId: 'A'),
        contents: [
          projectTrainingContent(_content('C', order: -1), catalog),
          projectTrainingContent(_content('B', order: -1), catalog),
          projectTrainingContent(_content('A', invalidated: true), catalog),
        ]);
    final selected = resolveTrainingCurrent(
        persistedCategoryKey: _key, catalog: catalog, categories: [snapshot]);
    expect(selected.currentContent!.content.contentId, 'B');
    expect(selected.preference, same(snapshot.preference));
    expect(selected.preference!.currentContentId, 'A');
    expect(selected.preference!.revision, 7);
  });

  test('persisted eligible Category is preferred to earlier fallback Category',
      () {
    final a = FolderCategoryKey('A');
    final catalog = TrainingCatalogSnapshot(categories: [
      a,
      _key
    ], banks: [
      TrainingCatalogBank(
          bankName: 'Bank', categoryKey: _key, ordinaryTrainingEligible: true),
      TrainingCatalogBank(
          bankName: 'A-bank', categoryKey: a, ordinaryTrainingEligible: true),
    ]);
    final selected = resolveTrainingCurrent(
        persistedCategoryKey: _key,
        catalog: catalog,
        categories: [
          for (final key in catalog.categories)
            TrainingCategorySnapshot(
                categoryKey: key,
                preference: TrainingCategoryPreference(
                    categoryKey: key, revision: null),
                contents: [])
        ]);
    expect(selected.categoryKey, _key);
    expect(selected.state, TrainingCurrentContentState.unconfigured);
  });

  test(
      'empty folder cannot become runtime Category while content-only Category can',
      () {
    final empty = FolderCategoryKey('Empty');
    final catalog = TrainingCatalogSnapshot(categories: [empty], banks: []);
    final emptySnapshot = TrainingCategorySnapshot(
        categoryKey: empty,
        preference:
            TrainingCategoryPreference(categoryKey: empty, revision: null),
        contents: []);
    final contentSnapshot = TrainingCategorySnapshot(
        categoryKey: _key,
        preference:
            TrainingCategoryPreference(categoryKey: _key, revision: null),
        contents: [projectTrainingContent(_content('a'), catalog)]);
    final selected = resolveTrainingCurrent(
        persistedCategoryKey: empty,
        catalog: catalog,
        categories: [emptySnapshot, contentSnapshot]);
    expect(selected.persistedCategoryKey, empty);
    expect(selected.categoryKey, _key);
    expect(selected.state, TrainingCurrentContentState.unavailable);
    expect(selected.currentContent, isNull);
  });
}

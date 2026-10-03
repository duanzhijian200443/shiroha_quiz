import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/home_training_result.dart';
import 'package:shiroha_quiz/application/training/training_contracts.dart';
import 'package:shiroha_quiz/domain/training/category_key.dart';
import 'package:shiroha_quiz/domain/training/training_content.dart';
import 'package:shiroha_quiz/domain/training/training_content_member.dart';

const _category = UncategorizedCategoryKey();

TrainingContentEdit _edit() => TrainingContentEdit(
        name: ' training ',
        questionLimit: 20,
        sortOrder: 0,
        members: [
          TrainingContentMember(
              bankName: 'Bank', weightPercent: 100, position: 0)
        ]);

TrainingContent _content(String id, {bool invalidated = false}) =>
    TrainingContent(
        contentId: id,
        categoryKey: _category,
        name: 'Same name',
        questionLimit: 20,
        sortOrder: 0,
        revision: 4,
        members: [
          TrainingContentMember(
              bankName: 'Bank',
              weightPercent: 100,
              position: 0,
              bindingStatus: invalidated
                  ? TrainingBindingStatus.invalidated
                  : TrainingBindingStatus.valid)
        ]);

final class _EligibilityFake implements OrdinaryTrainingBankEligibility {
  String? capturedBank;
  @override
  Future<HomeTrainingResult<OrdinaryTrainingBankEligibilityStatus>> evaluate(
      OrdinaryTrainingBankInput input) async {
    capturedBank = input.bankName;
    return const HomeTrainingSuccess(
        OrdinaryTrainingBankEligibilityStatus.eligible);
  }
}

final class _CommandFake implements TrainingContentCommand {
  UpdateTrainingContentRequest? updateRequest;
  TrainingContentTarget? deleted;
  RebindTrainingContentMemberRequest? rebound;
  SelectTrainingContentRequest? selected;
  UpdateCategoryVisualRequest? visual;
  @override
  Future<HomeTrainingResult<TrainingContent>> create(
          CreateTrainingContentRequest request) async =>
      HomeTrainingSuccess(_content('created'));
  @override
  Future<HomeTrainingResult<TrainingContent>> update(
      UpdateTrainingContentRequest request) async {
    updateRequest = request;
    return const HomeTrainingFailed(HomeTrainingFailure.stale);
  }

  @override
  Future<HomeTrainingResult<HomeTrainingUnit>> delete(
      TrainingContentTarget target) async {
    deleted = target;
    return const HomeTrainingFailed(HomeTrainingFailure.conflict);
  }

  @override
  Future<HomeTrainingResult<TrainingContent>> rebindMember(
      RebindTrainingContentMemberRequest request) async {
    rebound = request;
    return const HomeTrainingFailed(HomeTrainingFailure.stale);
  }

  @override
  Future<HomeTrainingResult<TrainingCurrentSelection>> selectCurrent(
      SelectTrainingContentRequest request) async {
    selected = request;
    return const HomeTrainingFailed(HomeTrainingFailure.stale);
  }

  @override
  Future<HomeTrainingResult<TrainingCategoryPreference>> updateCategoryVisual(
      UpdateCategoryVisualRequest request) async {
    visual = request;
    return const HomeTrainingFailed(HomeTrainingFailure.unavailable);
  }
}

void main() {
  test(
      'rebind contract preserves exact bank and content CAS without editable fields',
      () async {
    final target =
        TrainingContentTarget(contentId: 'content', expectedRevision: 4);
    final request =
        RebindTrainingContentMemberRequest(target: target, bankName: ' Bank ');
    final command = _CommandFake();
    final result = await command.rebindMember(request);
    expect(command.rebound, same(request));
    expect(request.bankName, ' Bank ');
    expect(request.target.expectedRevision, 4);
    expect((result as HomeTrainingFailed<TrainingContent>).failure,
        HomeTrainingFailure.stale);
    expect(
        () => RebindTrainingContentMemberRequest(target: target, bankName: ' '),
        throwsA(isA<HomeTrainingContractException>()));
  });
  test('eligibility is independently fakeable and preserves exact bank input',
      () async {
    final fake = _EligibilityFake();
    final result = await fake.evaluate(OrdinaryTrainingBankInput(' 📁 Bank '));
    expect(fake.capturedBank, ' 📁 Bank ');
    expect(
        (result as HomeTrainingSuccess<OrdinaryTrainingBankEligibilityStatus>)
            .value,
        OrdinaryTrainingBankEligibilityStatus.eligible);
    expect(() => OrdinaryTrainingBankInput(' '),
        throwsA(isA<HomeTrainingContractException>()));
  });

  test(
      'catalog snapshot copies lists, retains empty categories, rejects conflicting bank facts',
      () {
    final empty = FolderCategoryKey('Empty folder');
    final categories = <CategoryKey>[_category, empty];
    final banks = [
      TrainingCatalogBank(
          bankName: 'Bank',
          categoryKey: _category,
          ordinaryTrainingEligible: true)
    ];
    final snapshot =
        TrainingCatalogSnapshot(categories: categories, banks: banks);
    categories.clear();
    banks.clear();
    expect(snapshot.categories, hasLength(2));
    expect(snapshot.banks.single.ordinaryTrainingEligible, isTrue);
    expect(() => snapshot.categories.clear(), throwsUnsupportedError);
    expect(() => snapshot.banks.clear(), throwsUnsupportedError);
    expect(
        () => TrainingCatalogSnapshot(categories: [
              _category
            ], banks: [
              snapshot.banks.single,
              TrainingCatalogBank(
                  bankName: 'Bank',
                  categoryKey: _category,
                  ordinaryTrainingEligible: false)
            ]),
        throwsA(isA<HomeTrainingContractException>()));
    expect(() => TrainingCatalogSnapshot(categories: [], banks: snapshot.banks),
        throwsA(isA<HomeTrainingContractException>()));
  });

  test('content and preference commands carry distinct CAS targets', () async {
    final fake = _CommandFake();
    final target =
        TrainingContentTarget(contentId: 'content-a', expectedRevision: 4);
    final edit = _edit();
    final updated = await fake
        .update(UpdateTrainingContentRequest(target: target, edit: edit));
    await fake.delete(target);
    final preferenceTarget =
        TrainingPreferenceTarget(categoryKey: _category, expectedRevision: 7);
    await fake.selectCurrent(SelectTrainingContentRequest(
        target: preferenceTarget, contentId: 'content-a'));
    await fake.updateCategoryVisual(UpdateCategoryVisualRequest(
        target: preferenceTarget, visualKey: CategoryVisualKey.math));
    expect(fake.updateRequest!.target.expectedRevision, 4);
    expect(fake.deleted!.expectedRevision, 4);
    expect(fake.selected!.target.expectedRevision, 7);
    expect(fake.visual!.target.expectedRevision, 7);
    expect((updated as HomeTrainingFailed<TrainingContent>).failure,
        HomeTrainingFailure.stale);
    expect(edit.name, 'training');
    expect(() => edit.members.clear(), throwsUnsupportedError);
    expect(() => TrainingContentTarget(contentId: 'a', expectedRevision: 0),
        throwsA(isA<HomeTrainingContractException>()));
  });

  test(
      'null preference revision means absent row; existing explicit-null selection stays distinct',
      () {
    final absent =
        TrainingCategoryPreference(categoryKey: _category, revision: null);
    final cleared = TrainingCategoryPreference(
        categoryKey: _category, revision: 3, currentContentId: null);
    expect(absent.revision, isNull);
    expect(cleared.revision, 3);
    expect(cleared.currentContentId, isNull);
    expect(
        TrainingPreferenceTarget(categoryKey: _category, expectedRevision: null)
            .expectedRevision,
        isNull);
    expect(
        () => TrainingCategoryPreference(
            categoryKey: _category, revision: null, currentContentId: 'a'),
        throwsA(isA<HomeTrainingContractException>()));
  });

  test(
      'unavailable persisted selection remains A while runtime displays usable B',
      () {
    final a = TrainingContentView(
        content: _content('a', invalidated: true), usable: false);
    final b = TrainingContentView(content: _content('b'), usable: true);
    final preference = TrainingCategoryPreference(
        categoryKey: _category, revision: 3, currentContentId: 'a');
    final entries = [a, b];
    final snapshot = TrainingCategorySnapshot(
        categoryKey: _category, preference: preference, contents: entries);
    entries.clear();
    final selection = TrainingCurrentSelection(
        persistedCategoryKey: FolderCategoryKey('No longer visible'),
        categoryKey: _category,
        preference: preference,
        currentContent: b,
        state: TrainingCurrentContentState.usable);
    expect(snapshot.preference.currentContentId, 'a');
    expect(snapshot.contents, hasLength(2));
    expect(selection.currentContent!.content.contentId, 'b');
    expect(
        selection.persistedCategoryKey, FolderCategoryKey('No longer visible'));
    expect(() => snapshot.contents.clear(), throwsUnsupportedError);
    expect(() => TrainingContentView(content: a.content, usable: true),
        throwsA(isA<HomeTrainingContractException>()));
    expect(
        () => TrainingCategorySnapshot(
            categoryKey: _category, preference: preference, contents: [b]),
        throwsA(isA<HomeTrainingContractException>()));
  });

  test('edit validates Domain weights/positions without bank existence lookup',
      () {
    expect(
        () => TrainingContentEdit(
            name: ' ',
            questionLimit: 20,
            sortOrder: 0,
            members: _edit().members),
        throwsA(isA<HomeTrainingContractException>()));
    expect(
        () => TrainingContentEdit(
            name: 'a',
            questionLimit: 101,
            sortOrder: 0,
            members: _edit().members),
        throwsA(isA<HomeTrainingContractException>()));
    expect(
        () => TrainingContentEdit(
                name: 'a',
                questionLimit: 20,
                sortOrder: 0,
                members: [
                  TrainingContentMember(
                      bankName: 'A', weightPercent: 50, position: 0),
                  TrainingContentMember(
                      bankName: 'B', weightPercent: 50, position: 0)
                ]),
        throwsA(isA<HomeTrainingContractException>()));
  });
}

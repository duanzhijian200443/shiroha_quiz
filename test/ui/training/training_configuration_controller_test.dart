import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/home_training_result.dart';
import 'package:shiroha_quiz/application/training/training_configuration_contracts.dart';
import 'package:shiroha_quiz/application/training/training_contracts.dart';
import 'package:shiroha_quiz/domain/training/training_content.dart';
import 'package:shiroha_quiz/domain/training/training_content_member.dart';
import 'package:shiroha_quiz/ui/training/training_configuration_controller.dart';
import 'package:shiroha_quiz/ui/training/training_content_draft.dart';
import 'training_configuration_fakes.dart';

TrainingContentDraft draft({bool create = false, bool invalid = false}) =>
    TrainingContentDraft(
        categoryKey: mathCategory,
        preference:
            TrainingCategoryPreference(categoryKey: mathCategory, revision: 7),
        content: create ? null : fixtureContent(invalid: invalid));

void main() {
  test('latest read wins; failure is not empty; dispose rejects late result',
      () async {
    final fake = ConfigurationFake();
    final a = Completer<HomeTrainingResult<TrainingConfigurationSnapshot>>();
    final b = Completer<HomeTrainingResult<TrainingConfigurationSnapshot>>();
    fake.pendingReads.addAll([a, b]);
    final controller = fake.controller();
    final first = controller.load();
    final second = controller.load();
    final latest = fixtureSnapshot(invalid: true);
    b.complete(HomeTrainingSuccess(latest));
    await second;
    a.complete(HomeTrainingSuccess(fixtureSnapshot()));
    await first;
    expect(controller.snapshot, same(latest));
    fake.readThrows = true;
    await controller.load();
    expect(controller.state, TrainingConfigurationLoad.unavailable);
    expect(controller.snapshot, isNull);
    final c = Completer<HomeTrainingResult<TrainingConfigurationSnapshot>>();
    fake.pendingReads.add(c);
    final last = controller.load();
    controller.dispose();
    c.complete(HomeTrainingSuccess(latest));
    await last;
    expect(controller.snapshot, isNull);
  });

  test('stale update uses captured CAS once, reloads, never tries visual',
      () async {
    final fake = ConfigurationFake()
      ..contentFailure = HomeTrainingFailure.stale;
    final controller = fake.controller();
    final edit = draft()..visualKey = CategoryVisualKey.math;
    final result = await controller.save(edit);
    expect(result.content, isNull);
    expect(result.failure, HomeTrainingFailure.stale);
    final request = fake.calls.single as UpdateTrainingContentRequest;
    expect(request.target.expectedRevision, 4);
    expect(fake.reads, 1);
    expect(controller.message, contains('配置已变化'));
    controller.dispose();
  });

  test(
      'content success plus visual stale remains partial success with separate revision',
      () async {
    final fake = ConfigurationFake()..visualFailure = HomeTrainingFailure.stale;
    final controller = fake.controller();
    final result =
        await controller.save(draft()..visualKey = CategoryVisualKey.math);
    expect(result.content!.revision, 5);
    expect(result.visualSaved, isFalse);
    expect(fake.calls.length, 2);
    expect(
        (fake.calls[1] as UpdateCategoryVisualRequest).target.expectedRevision,
        7);
    expect(controller.message, contains('训练内容已保存，分类视觉未保存'));
    expect(fake.reads, 1);
    controller.dispose();
  });

  test('busy blocks duplicate command; dispose prevents second durable command',
      () async {
    final fake = ConfigurationFake()
      ..pendingContent = Completer<HomeTrainingResult<TrainingContent>>();
    final controller = fake.controller();
    final edited = draft()..visualKey = CategoryVisualKey.math;
    final saving = controller.save(edited);
    final duplicate = await controller.save(edited);
    expect(duplicate.failure, HomeTrainingFailure.conflict);
    controller.dispose();
    fake.pendingContent!
        .complete(HomeTrainingSuccess(fixtureContent(revision: 5)));
    final result = await saving;
    expect(result.content, isNotNull);
    expect(result.visualSaved, isFalse);
    expect(fake.calls.length, 1);
    expect(fake.reads, 0);
  });

  test('pre-mutation load cannot overwrite refreshed result', () async {
    final fake = ConfigurationFake();
    final old = Completer<HomeTrainingResult<TrainingConfigurationSnapshot>>();
    fake.pendingReads.add(old);
    final controller = fake.controller();
    final reading = controller.load();
    await controller.save(draft());
    old.complete(HomeTrainingSuccess(fixtureSnapshot(invalid: true)));
    await reading;
    expect(controller.snapshot, same(fake.value));
    controller.dispose();
  });

  test('create exact category, banks, positions, weights and integer limits',
      () async {
    for (final limit in [1, 2, 99, 100]) {
      final fake = ConfigurationFake();
      final controller = fake.controller();
      final edit = draft(create: true)
        ..name = ' 配置 '
        ..questionLimit = limit
        ..sortOrder = 9;
      edit.setBanks(['线代', '高数', '概率']);
      edit.moveMember(2, -1);
      await controller.save(edit);
      final request = fake.calls.single as CreateTrainingContentRequest;
      expect(request.categoryKey, mathCategory);
      expect(request.edit.name, '配置');
      expect(request.edit.questionLimit, limit);
      expect(request.edit.sortOrder, 9);
      expect(request.edit.members.map((m) => m.bankName), ['线代', '概率', '高数']);
      expect(request.edit.members.map((m) => m.position), [0, 1, 2]);
      expect(request.edit.members.fold<int>(0, (v, m) => v + m.weightPercent),
          100);
      controller.dispose();
    }
  });

  test('current preference stale and delete use exact targets once', () async {
    final fake = ConfigurationFake()..otherFailure = HomeTrainingFailure.stale;
    final controller = fake.controller();
    await controller.select(fake.value.categories.first, 'second');
    expect(
        (fake.calls.single as SelectTrainingContentRequest)
            .target
            .expectedRevision,
        7);
    expect(fake.reads, 1);
    await controller.delete(fixtureContent());
    expect((fake.calls.last as TrainingContentTarget).expectedRevision, 4);
    expect(fake.calls.length, 2);
    controller.dispose();
  });

  test('ratio edits conserve 100, zero relation and quota authority', () {
    final edit = draft(create: true)..name = '比例';
    edit.setBanks(['A']);
    expect(edit.members.single.weightPercent, 100);
    edit.setBanks(['A', 'B', 'C']);
    expect(edit.members.map((m) => m.weightPercent), [34, 33, 33]);
    for (var percent = 0; percent <= 100; percent++) {
      edit.adjustWeight('A', percent);
      expect(edit.members.fold<int>(0, (v, m) => v + m.weightPercent), 100);
      expect(
          edit.members
              .every((m) => m.weightPercent >= 0 && m.weightPercent <= 100),
          isTrue);
    }
    edit.adjustWeight('A', 0);
    expect(edit.members.first.weightPercent, 0);
    expect(edit.quotas['A'], 0);
    edit.members = [
      for (final (i, weight) in [40, 35, 25].indexed)
        TrainingContentMember(
            bankName: ['A', 'B', 'C'][i], weightPercent: weight, position: i),
    ];
    expect(edit.quotas, {'A': 8, 'B': 7, 'C': 5});
    edit.setBanks(['A', 'B']);
    expect(edit.members.map((m) => m.weightPercent), [53, 47]);
  });

  test(
      'deselect/reselect cannot revive original invalidated binding; rebind uses returned revision',
      () async {
    final edit = draft(invalid: true);
    edit.setBanks(['线代']);
    edit.setBanks(['线代', '高数']);
    expect(edit.members.last.bindingStatus, TrainingBindingStatus.invalidated);
    final fake = ConfigurationFake();
    final controller = fake.controller();
    final first = await controller.rebind(edit.original!, '高数')
        as HomeTrainingSuccess<TrainingContent>;
    edit.acceptRebind(first.value, '高数');
    await controller.rebind(edit.original!, '线代');
    expect(
        (fake.calls.last as RebindTrainingContentMemberRequest)
            .target
            .expectedRevision,
        5);
    expect(edit.members.last.bindingStatus, TrainingBindingStatus.valid);
    controller.dispose();
  });
}

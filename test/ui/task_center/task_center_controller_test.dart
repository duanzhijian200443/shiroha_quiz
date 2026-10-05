import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/home_training_result.dart';
import 'package:shiroha_quiz/application/task_center/task_center_contracts.dart';
import 'package:shiroha_quiz/ui/task_center/task_center_controller.dart';
import '../../support/task_center_fakes.dart';

void main() {
  test(
      'queued refresh invalidates late reads with one query in flight; failure is not empty',
      () async {
    final fake = TaskCenterFake();
    final old = Completer<HomeTrainingResult<TaskCenterSnapshot>>();
    fake.readGates.add(old);
    final c = TaskCenterController(fake.ports);
    addTearDown(c.dispose);
    final first = c.load();
    final second = c.load();
    old.complete(HomeTrainingSuccess(TaskCenterSnapshot([])));
    await first;
    await second;
    expect(c.snapshot!.items, hasLength(3));
    expect(fake.maxReads, 1);
    expect(fake.reads, 2);
    fake.unavailable = true;
    await c.load();
    expect(c.phase, TaskCenterLoadPhase.unavailable);
    expect(c.snapshot!.items, hasLength(3));
  });
  test(
      'per-task duplicate actions, exact target, stale and picker cancellation do not replay',
      () async {
    final fake = TaskCenterFake();
    final c = TaskCenterController(fake.ports);
    addTearDown(c.dispose);
    final item = fake.items[1];
    fake.actionGate = Completer<void>();
    final first = c.act(item, TaskCenterAction.delete);
    await c.act(item, TaskCenterAction.delete);
    expect(fake.commands, 1);
    expect(fake.targets.single, same(item.target));
    fake.failure = HomeTrainingFailure.stale;
    fake.actionGate!.complete();
    await first;
    expect(fake.commands, 1);
    expect(c.message, '任务状态已变化，请刷新');
    fake.pickerCancelled = true;
    await c.act(fake.items.last, TaskCenterAction.retry);
    expect(fake.selectedRetries, 0);
    fake.pickerCancelled = false;
    await c.act(fake.items.last, TaskCenterAction.retry);
    expect(fake.selectedRetries, 1);
    expect(fake.targets.last, same(fake.items.last.target));
  });
  test(
      'cleanup submits the issued object across confirmation; empty and cancel never clear',
      () async {
    final fake = TaskCenterFake();
    final c = TaskCenterController(fake.ports);
    addTearDown(c.dispose);
    await c.cleanup((count) async {
      expect(count, 1);
      fake.items.add(taskItem('new', status: TaskCenterCoarseStatus.completed));
      return true;
    });
    expect(fake.submitted, same(fake.issued));
    expect(fake.submitted!.targets, hasLength(1));
    expect(fake.commands, 1);
    await c.cleanup((_) async => false);
    expect(fake.commands, 1);
    fake.items = [];
    await c.cleanup((_) async {
      fail('empty must not confirm');
    });
    expect(fake.commands, 1);
  });
  test(
      'dispose rejects late reads and prevents a picked input from becoming a retry',
      () async {
    final fake = TaskCenterFake();
    final c = TaskCenterController(fake.ports);
    fake.pickerGate = Completer<void>();
    final action = c.act(fake.items.last, TaskCenterAction.retry);
    await Future<void>.delayed(Duration.zero);
    c.dispose();
    fake.pickerGate!.complete();
    await action;
    expect(fake.selectedRetries, 0);
    final pending = Completer<HomeTrainingResult<TaskCenterSnapshot>>();
    fake.readGates.add(pending);
    final other = TaskCenterController(fake.ports);
    final load = other.load();
    var notifications = 0;
    other.addListener(() => notifications++);
    other.dispose();
    pending.complete(HomeTrainingSuccess(TaskCenterSnapshot([])));
    await load;
    expect(notifications, 0);
  });
  testWidgets(
      'bounded timer reads only when visible, skips pending read, and stops on dispose',
      (tester) async {
    await tester.pumpWidget(const SizedBox());
    final fake = TaskCenterFake();
    final c = TaskCenterController(fake.ports,
        refreshInterval: const Duration(seconds: 1));
    c.setVisible(true);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(fake.reads, 1);
    final pending = Completer<HomeTrainingResult<TaskCenterSnapshot>>();
    fake.readGates.add(pending);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 5));
    expect(fake.reads, 2);
    pending.complete(HomeTrainingSuccess(TaskCenterSnapshot(fake.items)));
    await tester.pump();
    c.setVisible(false);
    await tester.pump(const Duration(seconds: 5));
    expect(fake.reads, 2);
    c.dispose();
    await tester.pump(const Duration(seconds: 5));
    expect(fake.reads, 2);
    expect(fake.commands, 0);
  });
}

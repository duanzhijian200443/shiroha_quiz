import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_request_scheduler.dart';

void main() {
  test('never starts more than two operations at once', () async {
    final scheduler = OcrRequestScheduler(maxConcurrentRequests: 2);
    final releases = List<Completer<void>>.generate(
      4,
      (_) => Completer<void>(),
    );
    final started = List<Completer<void>>.generate(
      4,
      (_) => Completer<void>(),
    );
    var activeCount = 0;
    var maxActiveCount = 0;

    Future<int> operation(int index) async {
      activeCount++;
      maxActiveCount =
          activeCount > maxActiveCount ? activeCount : maxActiveCount;
      started[index].complete();
      try {
        await releases[index].future;
        return index;
      } finally {
        activeCount--;
      }
    }

    final futures = <Future<int>>[
      for (var index = 0; index < 4; index++)
        scheduler.run(
          taskId: 'task-$index',
          operation: () => operation(index),
        ),
    ];

    await Future.wait(<Future<void>>[started[0].future, started[1].future]);
    expect(started[2].isCompleted, isFalse);
    expect(started[3].isCompleted, isFalse);

    releases[0].complete();
    await started[2].future;
    expect(started[3].isCompleted, isFalse);

    releases[1].complete();
    await started[3].future;
    releases[2].complete();
    releases[3].complete();

    expect(await Future.wait(futures), <int>[0, 1, 2, 3]);
    expect(maxActiveCount, 2);
  });

  test('starts the third operation as soon as one slot is released', () async {
    final scheduler = OcrRequestScheduler(maxConcurrentRequests: 2);
    final firstRelease = Completer<void>();
    final secondRelease = Completer<void>();
    final thirdStarted = Completer<void>();
    final thirdRelease = Completer<void>();

    final first = scheduler.run<void>(
      taskId: 'first',
      operation: () => firstRelease.future,
    );
    final second = scheduler.run<void>(
      taskId: 'second',
      operation: () => secondRelease.future,
    );
    final third = scheduler.run<void>(
      taskId: 'third',
      operation: () async {
        thirdStarted.complete();
        await thirdRelease.future;
      },
    );

    expect(thirdStarted.isCompleted, isFalse);
    firstRelease.complete();
    await thirdStarted.future;

    secondRelease.complete();
    thirdRelease.complete();
    await Future.wait<void>(<Future<void>>[first, second, third]);
  });

  test('preserves strict FIFO order for queued operations', () async {
    final scheduler = OcrRequestScheduler(maxConcurrentRequests: 2);
    final releases = List<Completer<void>>.generate(
      5,
      (_) => Completer<void>(),
    );
    final starts = <int>[];
    final started = List<Completer<void>>.generate(
      5,
      (_) => Completer<void>(),
    );

    Future<void> operation(int index) async {
      starts.add(index);
      started[index].complete();
      await releases[index].future;
    }

    final futures = <Future<void>>[
      for (var index = 0; index < 5; index++)
        scheduler.run<void>(
          taskId: 'fifo-$index',
          operation: () => operation(index),
        ),
    ];

    await Future.wait(<Future<void>>[started[0].future, started[1].future]);
    expect(starts, <int>[0, 1]);

    releases[1].complete();
    await started[2].future;
    expect(starts, <int>[0, 1, 2]);

    releases[0].complete();
    await started[3].future;
    expect(starts, <int>[0, 1, 2, 3]);

    releases[2].complete();
    await started[4].future;
    expect(starts, <int>[0, 1, 2, 3, 4]);

    releases[3].complete();
    releases[4].complete();
    await Future.wait<void>(futures);
  });

  test('returns the operation result after releasing its slot', () async {
    final scheduler = OcrRequestScheduler(maxConcurrentRequests: 1);
    final firstRelease = Completer<void>();
    final secondStarted = Completer<void>();

    final first = scheduler.run<int>(
      taskId: 'first',
      operation: () async {
        await firstRelease.future;
        return 42;
      },
    );
    final second = scheduler.run<void>(
      taskId: 'second',
      operation: () async => secondStarted.complete(),
    );

    firstRelease.complete();
    await secondStarted.future;
    expect(await first, 42);
    await second;
  });

  test('releases a slot after an asynchronous error', () async {
    final scheduler = OcrRequestScheduler(maxConcurrentRequests: 1);
    final fail = Completer<void>();
    final nextStarted = Completer<void>();

    final failing = scheduler.run<void>(
      taskId: 'failing',
      operation: () async {
        await fail.future;
        throw StateError('synthetic asynchronous failure');
      },
    );
    final failureExpectation = expectLater(failing, throwsStateError);
    final next = scheduler.run<void>(
      taskId: 'next',
      operation: () async => nextStarted.complete(),
    );

    fail.complete();
    await nextStarted.future;
    await failureExpectation;
    await next;
  });

  test('releases a slot after an operation throws synchronously', () async {
    final scheduler = OcrRequestScheduler(maxConcurrentRequests: 1);
    final nextStarted = Completer<void>();

    final failing = scheduler.run<void>(
      taskId: 'sync-failing',
      operation: () {
        throw StateError('synthetic synchronous failure');
      },
    );
    final failureExpectation = expectLater(failing, throwsStateError);
    final next = scheduler.run<void>(
      taskId: 'next',
      operation: () async => nextStarted.complete(),
    );

    await nextStarted.future;
    await failureExpectation;
    await next;
  });

  test('one failed operation does not affect other operations', () async {
    final scheduler = OcrRequestScheduler(maxConcurrentRequests: 2);

    final failed = scheduler.run<void>(
      taskId: 'failed',
      operation: () async => throw StateError('synthetic failure'),
    );
    final failureExpectation = expectLater(failed, throwsStateError);
    final successful = scheduler.run<int>(
      taskId: 'successful',
      operation: () async => 7,
    );

    await failureExpectation;
    expect(await successful, 7);
  });

  test('starts every operation exactly once', () async {
    final scheduler = OcrRequestScheduler(maxConcurrentRequests: 2);
    final callCounts = <int>[0, 0, 0, 0];

    final results = await Future.wait<int>(<Future<int>>[
      for (var index = 0; index < callCounts.length; index++)
        scheduler.run<int>(
          taskId: 'once-$index',
          operation: () async {
            callCounts[index]++;
            return index;
          },
        ),
    ]);

    expect(results, <int>[0, 1, 2, 3]);
    expect(callCounts, <int>[1, 1, 1, 1]);
  });

  test('rejects non-positive concurrency limits', () {
    expect(
      () => OcrRequestScheduler(maxConcurrentRequests: 0),
      throwsArgumentError,
    );
    expect(
      () => OcrRequestScheduler(maxConcurrentRequests: -1),
      throwsArgumentError,
    );
  });

  test('keeps scheduler instances isolated', () async {
    final firstScheduler = OcrRequestScheduler(maxConcurrentRequests: 1);
    final secondScheduler = OcrRequestScheduler(maxConcurrentRequests: 1);
    final firstRelease = Completer<void>();
    final firstQueuedStarted = Completer<void>();
    final otherSchedulerStarted = Completer<void>();

    final first = firstScheduler.run<void>(
      taskId: 'first',
      operation: () => firstRelease.future,
    );
    final firstQueued = firstScheduler.run<void>(
      taskId: 'first-queued',
      operation: () async => firstQueuedStarted.complete(),
    );
    final other = secondScheduler.run<void>(
      taskId: 'other',
      operation: () async => otherSchedulerStarted.complete(),
    );

    await otherSchedulerStarted.future;
    expect(firstQueuedStarted.isCompleted, isFalse);

    firstRelease.complete();
    await firstQueuedStarted.future;
    await Future.wait<void>(<Future<void>>[first, firstQueued, other]);
  });
}

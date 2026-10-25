import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/ui/dependencies/first_party_external_scope.dart';

void main() {
  test('exit waits for original close before waiting for queued logs',
      () async {
    final originalClose = Completer<void>();
    final logFlush = Completer<void>();
    final events = <String>[];
    var completed = false;
    final exit = settleExternalAppExit(close: () async {
      events.add('closeEntered');
      await originalClose.future;
      events.add('originalSettled');
    }, flushLogs: () async {
      events.add('flushEntered');
      await logFlush.future;
      events.add('logsSettled');
    }).then((value) {
      completed = true;
      return value;
    });
    await pumpEventQueue();
    expect(events, ['closeEntered']);
    expect(completed, isFalse);
    originalClose.complete();
    await pumpEventQueue();
    expect(events, ['closeEntered', 'originalSettled', 'flushEntered']);
    expect(completed, isFalse);
    logFlush.complete();
    expect(await exit, AppExitResponse.exit);
    expect(events.last, 'logsSettled');
  });

  test('failed original close still flushes failure evidence and cancels exit',
      () async {
    final logFlush = Completer<void>();
    var flushEntered = false;
    var completed = false;
    final exit = settleExternalAppExit(
        close: () async => throw StateError('Original close failed'),
        flushLogs: () async {
          flushEntered = true;
          await logFlush.future;
        }).then((value) {
      completed = true;
      return value;
    });
    await pumpEventQueue();
    expect(flushEntered, isTrue);
    expect(completed, isFalse);
    logFlush.complete();
    expect(await exit, AppExitResponse.cancel);
  });

  test('failed log flush cancels exit without replaying original cleanup',
      () async {
    var originalCalls = 0;
    final result = await settleExternalAppExit(
        close: () async {
          originalCalls++;
        },
        flushLogs: () async => throw StateError('Log flush failed'));
    expect(result, AppExitResponse.cancel);
    expect(originalCalls, 1);
  });

  test('existing lifetime callers without a log sink retain original drain',
      () async {
    var originalSettled = false;
    expect(
        await settleExternalAppExit(close: () async {
          originalSettled = true;
        }),
        AppExitResponse.exit);
    expect(originalSettled, isTrue);
  });
}

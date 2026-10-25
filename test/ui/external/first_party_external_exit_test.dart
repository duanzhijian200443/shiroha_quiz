import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/core/observability/app_logger.dart';
import 'package:shiroha_quiz/core/observability/log_writer.dart';
import 'package:shiroha_quiz/ui/dependencies/first_party_external_scope.dart';

void main() {
  test('real file sink failure remains visible after a later successful write',
      () async {
    final root = await Directory('.dart_tool').createTemp('exit-log-');
    final blocked = File('${root.path}/logs');
    await blocked.writeAsString('test-only directory blocker');
    final sink = RotatingFileLogSink(directory: Directory(blocked.path));
    AppLogger.setSink(sink);
    final failed = Completer<void>();
    LogWriter.setRecordHandler(null);
    LogWriter.setSinkErrorHandler((_, __) => failed.complete());
    addTearDown(() async {
      AppLogger.setSink(null);
      await root.delete(recursive: true);
    });

    AppLogger.info('originalBridgeSettled', module: 'RelayTest');
    await failed.future;
    await blocked.delete();
    AppLogger.info('later diagnostic', module: 'RelayTest');
    await AppLogger.flush(); // Historical best-effort API can still succeed.
    final contents = await sink.currentFile.readAsString();
    expect(contents, contains('later diagnostic'));
    expect(contents, isNot(contains('originalBridgeSettled')));
    var closes = 0;
    for (var attempt = 0; attempt < 2; attempt++) {
      expect(
          await settleExternalAppExit(
              close: () async {
                closes++;
              },
              flushLogs: AppLogger.flushForExit),
          AppExitResponse.cancel);
    }
    expect(closes, 2);
  });

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

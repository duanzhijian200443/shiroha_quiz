import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/external/first_party_external_access.dart';
import 'package:shiroha_quiz/data/external/windows_pairing.dart';
import 'package:shiroha_quiz/ui/pages/first_party_external_control.dart';
import 'package:shiroha_quiz/ui/pages/first_party_bridge_pairing_control.dart';
import 'package:shiroha_quiz/ui/dependencies/first_party_external_scope.dart';
import '../../data/external/windows_tls_transport_test.dart' as tls;
import '../../data/external/bootstrap_test_support.dart' show unhex;
import 'windows_app_transport_fixture.dart';

Future<void> interactionFrame(WidgetTester tester,
    [Duration elapsed = const Duration(milliseconds: 300)]) async {
  await tester.pump(elapsed);
  // Disposal/timer callbacks start SQLite continuations in the fake clock zone.
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(() => pumpEventQueue(times: 10));
    await tester.pump();
  }
}

Future<T> interactionRead<T>(WidgetTester tester, Future<T> Function() read,
    {Duration timeout = const Duration(seconds: 10)}) async {
  if (tester.binding is LiveTestWidgetsFlutterBinding) return read();
  var done = false;
  T? result;
  Object? failure;
  StackTrace? trace;
  final settled = Completer<void>();
  final elapsed = Stopwatch()..start();
  await tester.runAsync(() async {
    unawaited(read().then((value) {
      result = value;
      done = true;
      settled.complete();
    }, onError: (Object error, StackTrace stack) {
      failure = error;
      trace = stack;
      done = true;
      settled.complete();
    }));
  });
  // SQLite/fixture files use real I/O while widgets use a fake clock. A fixed
  // number of zero-time event turns can run out before that I/O is scheduled.
  // Pump widget callbacks AND await the original completion with a wall bound.
  while (!done && elapsed.elapsed < timeout) {
    await interactionFrame(tester, Duration.zero);
    if (!done) {
      await tester.runAsync(() => Future.any<void>([
            settled.future,
            Future<void>.delayed(const Duration(milliseconds: 10)),
          ]));
    }
  }
  expect(done, isTrue, reason: 'original asynchronous operation must settle');
  if (failure != null) Error.throwWithStackTrace(failure!, trace!);
  return result as T;
}

Future<void> interactionTap(WidgetTester tester, String label) async {
  final target = find.text(label).last;
  await tester.ensureVisible(target);
  await tester.pump();
  await tester.runAsync(() async {
    await tester.tap(target);
    await pumpEventQueue(times: 30);
  });
  await interactionFrame(tester);
}

Widget interactionApp(FirstPartyExternalAccess access) => MaterialApp(
    home: Scaffold(
        body: SingleChildScrollView(
            child: FirstPartyExternalControl(access: access))));

void registerFirstPartyInteractionTests({
  Future<void> Function(WidgetTester, String)? observe,
  void Function(String)? trace,
}) {
  Future<void> cleanup(
      WidgetTester tester, Future<void> Function() close) async {
    trace?.call('cleanup_start');
    try {
      await tester.runAsync(() => tester.pumpWidget(const SizedBox()));
      await interactionRead(tester, close);
      trace?.call('cleanup_complete');
    } catch (_) {
      trace?.call('cleanup_failed');
      rethrow;
    }
  }

  Future<void> mount(WidgetTester tester, Widget widget) async {
    await tester.binding.setSurfaceSize(const Size(1600, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(RepaintBoundary(
        key: const Key('external-interaction-surface'), child: widget));
    await interactionFrame(tester);
  }

  Future<WindowsAppTransportFixture> paired(WidgetTester tester) async {
    final f = WindowsAppTransportFixture()..useAcceptedLocalConnection = true;
    await interactionRead(tester, () async {
      await f.open(stage: false);
      await f.approve();
      await f.controls.disable();
      await f.controlChannel!.close();
    });
    addTearDown(() => cleanup(tester, f.close));
    trace?.call('fixture_ready');
    await mount(tester, interactionApp(f.controls));
    return f;
  }

  testWidgets('desktop pending Enable cancel and explicit fresh connection',
      (tester) async {
    final f = await paired(tester);
    await interactionTap(tester, '限时启用');
    expect(find.textContaining('正在等待独立 Bridge'), findsOneWidget);
    expect(find.textContaining('剩余有效期：'), findsOneWidget);
    expect(f.host.verification.hasPendingLocalConnection, isTrue);
    final button = tester
        .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '禁用并取消等待'));
    expect(button.onPressed, isNotNull);
    await observe?.call(tester, 'pending');
    await interactionTap(tester, '禁用并取消等待');
    expect(f.host.verification.hasPendingLocalConnection, isFalse);
    expect(f.pairing.native.owner.isClosed, isFalse);
    expect(find.textContaining('连接等待已取消'), findsOneWidget);
    expect((await interactionRead(tester, f.controls.status)).enabled, isFalse);
    await interactionTap(tester, '限时启用');
    expect(f.host.verification.hasPendingLocalConnection, isTrue);
    await tester.runAsync(() async {
      f.controlChannel = tls.MemoryTlsChannel(f.clientDer);
      f.listener.controller.add(tls.MemoryRawPeer(f.controlChannel!));
      await pumpEventQueue(times: 30);
    });
    await interactionFrame(tester);
    expect(find.text('可信连接已认证'), findsOneWidget);
    expect(
        (await interactionRead(tester, f.controls.status)).approvedTargets, 0);
    await observe?.call(tester, 'connected');
    await interactionTap(tester, '禁用访问');
    expect((await interactionRead(tester, f.controls.status)).enabled, isFalse);
  });

  for (final failure in ['expired', 'failed', 'revoked']) {
    testWidgets('desktop pending $failure becomes visible without retry',
        (tester) async {
      final f = await paired(tester);
      await interactionTap(tester, '限时启用');
      await tester.runAsync(() async {
        if (failure == 'expired') {
          f.files.s.clock.current =
              f.files.s.clock.current.add(const Duration(minutes: 31));
        } else if (failure == 'failed') {
          f.host.verification.cancelLocalConnection();
        } else {
          final record = await f.files.s.management.read(f.files.s.profile);
          await f.files.s.management
              .revokeGrant(f.files.s.profile, record.profile.grantRevision);
        }
      });
      await interactionFrame(tester, const Duration(seconds: 1));
      await interactionFrame(tester);
      expect(find.textContaining('连接失败、已过期或授权已撤销'), findsOneWidget);
      expect(f.host.verification.hasPendingLocalConnection, isFalse);
      final status = (await interactionRead(tester, f.controls.status));
      expect(status.enabled, isFalse);
      expect(status.approvedTargets, 0);
      expect(f.pairing.native.owner.isClosed, isFalse);
    });
  }

  testWidgets(
      'desktop page disposal cancels waiting and reopening stays disabled',
      (tester) async {
    final f = await paired(tester);
    await interactionTap(tester, '限时启用');
    await tester.runAsync(() => tester.pumpWidget(const SizedBox()));
    await interactionFrame(tester);
    expect(f.host.verification.hasPendingLocalConnection, isFalse);
    expect((await interactionRead(tester, f.controls.status)).enabled, isFalse);
    await mount(tester, interactionApp(f.controls));
    expect(find.textContaining('正在等待独立 Bridge'), findsNothing);
    expect(find.text('访问已禁用'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop lifetime replacement drains old pending owner',
      (tester) async {
    final f = await paired(tester);
    await mount(
        tester,
        FirstPartyExternalLifetime(
            access: f.controls,
            close: f.startup.close,
            child: interactionApp(f.controls)));
    await interactionTap(tester, '限时启用');
    final replacement = FirstPartyExternalAccess(
        policy: f.policy, compositionIsCurrent: () => true);
    await tester.pumpWidget(FirstPartyExternalLifetime(
        access: replacement,
        close: replacement.shutdown,
        child: interactionApp(replacement)));
    await interactionFrame(tester);
    expect(f.host.verification.hasPendingLocalConnection, isFalse);
    expect(f.pairing.native.owner.isClosed, isTrue);
    expect(find.textContaining('生产认证与传输尚未准入'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'desktop public P27 handoff requires both independent UI decisions',
      (tester) async {
    String? copied;
    // Exercise the real App button and platform-channel write. This fixture
    // owns only a synthetic clipboard, not the user's Windows clipboard.
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      if (call.method == 'Clipboard.getData') return {'text': copied};
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    final f = WindowsAppTransportFixture()..useAcceptedLocalConnection = true;
    f.pairingOverride = (owner) => WindowsAppPublicPairingHandoff(owner: owner);
    await interactionRead(tester, () => f.open(enroll: false, stage: false));
    final bridge = WindowsBridgePublicPairing(owner: f.pairing.bridge);
    addTearDown(() => cleanup(tester, () async {
          await bridge.close();
          await f.close();
        }));
    trace?.call('fixture_ready');
    await mount(
        tester,
        MaterialApp(
            home: Scaffold(
                body: Row(children: [
          Expanded(
              child: SingleChildScrollView(
                  child: FirstPartyExternalControl(access: f.controls))),
          Expanded(child: FirstPartyBridgePairingControl(port: bridge)),
        ]))));
    await interactionTap(tester, '开始配对');
    final id = bridge.display().submissionId!;
    await interactionTap(tester, '选择连接 Profile');
    await interactionTap(tester, 'Synthetic client');
    await tester.enterText(find.byKey(const Key('external-submission-id')), id);
    await interactionTap(tester, '请求配对');
    expect(
        (await interactionRead(tester, f.controls.status))
            .pairingDisplay!
            .submissionId,
        id);
    await interactionTap(tester, '复制当前 Trust');
    expect(
        copied, await interactionRead(tester, f.controls.exportPairingTrust));
    expect(find.text('已复制 Trust 公共数据。'), findsOneWidget);
    await interactionTap(tester, '粘贴并导入 Trust');
    final initial = (await interactionRead(tester, f.controls.status))
        .pairingDisplay!
        .digest;
    expect(bridge.display().initialDigest, initial);
    expect(f.pairing.appExchange.readProof(unhex(id)), isNull);
    expect(f.pairing.native.calls.credentialFiles[4], isNull);
    await interactionTap(tester, '确认配对');
    await interactionTap(tester, '取消');
    expect(f.pairing.native.calls.associationFile, isNull);
    await interactionTap(tester, '确认配对');
    await interactionTap(tester, '批准配对');
    expect(f.pairing.appExchange.readProof(unhex(id)), isNull);
    await interactionTap(tester, '我已与受信任 App 独立比较完整初始摘要，且完全相同');
    await interactionTap(tester, '确认初始比较并发布 Proof');
    expect(f.pairing.appExchange.readProof(unhex(id)), isNotNull);
    await interactionTap(tester, '验证配对证明');
    // The earlier Trust copy belongs to the initial digest; completion changes
    // that identity, so the stale export must disappear before any re-import.
    await interactionFrame(tester, const Duration(seconds: 1));
    expect(find.byKey(const Key('external-public-export')), findsNothing);
    final oldTrust = copied;
    await interactionTap(tester, '粘贴并导入 Completion');
    expect(bridge.display().closed, isFalse);
    expect(bridge.display().completionDigest, isNull);
    expect(f.pairing.native.calls.credentialFiles[4], isNull);
    expect(find.textContaining('尚未导入或确认'), findsOneWidget);
    await interactionTap(tester, '复制当前 Completion');
    expect(copied,
        await interactionRead(tester, f.controls.exportPairingCompletion));
    expect(copied, isNot(oldTrust));
    expect(find.text('已复制 Completion 公共数据。'), findsOneWidget);
    await interactionTap(tester, '粘贴并导入 Completion');
    final actual =
        (await interactionRead(tester, f.controls.status)).pairingDisplay!;
    expect(bridge.display().completionDigest, actual.digest);
    expect(find.textContaining('尚未导入或确认'), findsNothing);
    expect(bridge.display().revision, actual.revision);
    expect(f.pairing.native.calls.credentialFiles[4], isNull);
    await observe?.call(tester, 'comparison');
    await interactionTap(tester, '我已再次独立比较 App 的完整完成摘要及实际 Revision，且均相同');
    await interactionTap(tester, '确认完成比较并保存凭据');
    expect(bridge.display().pinSaved, isTrue);
    expect((await interactionRead(tester, f.controls.status)).enabled, isFalse);
    expect(await tester.runAsync(f.controls.authenticatedSession), isNull);
  });
}

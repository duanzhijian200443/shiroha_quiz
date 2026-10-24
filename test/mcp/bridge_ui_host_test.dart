import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/composition/bridge_ui_host.dart';
import 'package:shiroha_quiz/data/external/windows_pairing.dart';

import '../application/generated_question/generated_test_support.dart';
import '../data/external/windows_pairing_test.dart' show PairingHarness;
import '../data/external/windows_credential_object_store_test.dart' as objects;
import 'fixtures/codex_app_server_support.dart' show flutterDartExecutable;

int _submissions(PairingHarness h) =>
    h.native.calls.exchangeFiles.keys.where((key) => key.$1 == 1).length;

Future<void> _pump(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(1000, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

/// Real P27 owner plus its task-owned host root; every entry is real file I/O.
final class _World {
  _World(this.h, this.root);
  final PairingHarness h;
  final Directory root;
  int resources = 0;

  static Future<_World> create() async {
    final h = PairingHarness();
    await h.open();
    return _World(
        h, await Directory.systemTemp.createTemp('shiroha_bridge_host_'));
  }

  Future<BridgeUiHost> open({bool closeOwners = true}) =>
      BridgeUiHost.open(BridgeUiHostDependencies(
        pairing: h.bridge,
        instanceRoot: root.path,
        closeResources: () async {
          resources++;
          if (closeOwners) {
            h.bridge.close();
            h.bridgeOwner.close();
          }
        },
      ));

  Future<void> close() async {
    try {
      h.bridge.close();
      await h.close();
    } finally {
      try {
        await root.delete(recursive: true);
      } on FileSystemException {
        // A latched close inside the widget-test fake zone may still hold the
        // host lock file; the isolate releases it on exit.
      }
    }
  }
}

void main() {
  initializeGeneratedTests();

  testWidgets(
      'one controller survives page rebuild without a second enrollment',
      (tester) async {
    final w = (await tester.runAsync(_World.create))!;
    final host = (await tester.runAsync(w.open))!;
    await tester.pumpWidget(host.build());
    await _pump(tester);
    expect(find.text('开始配对'), findsOneWidget);
    await tester.tap(find.text('开始配对'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(_submissions(w.h), 1);
    final id = host.port.display().submissionId;
    expect(id, isNotNull);
    expect(find.text(id!), findsOneWidget);

    // The same host surface rebuilt: same port, same live Enrollment.
    await tester.pumpWidget(host.build());
    await _pump(tester);
    expect(_submissions(w.h), 1);
    expect(host.port.display().submissionId, id);
    expect(find.text('开始配对'), findsNothing);
    expect(find.text(id), findsOneWidget);

    // Explicit close drains the original controller; later disposal is a no-op.
    await tester.runAsync(host.close);
    expect(w.resources, 1);
    expect(w.h.bridgeOwner.isClosed, isTrue);
    expect(host.isClosed, isTrue);
    expect(host.port.display().closed, isTrue);
    Object? lateFailure;
    await tester.runAsync(() async {
      try {
        await host.port.importTrust('[]');
      } catch (error) {
        lateFailure = error;
      }
    });
    expect(lateFailure, isNotNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(w.resources, 1);
    expect(tester.takeException(), isNull);
    await tester.runAsync(w.close);
  });

  test('a second host is refused by the process guard and the OS file lock',
      () async {
    final w = await _World.create();
    try {
      final first = await w.open(closeOwners: false);
      await expectLater(
          BridgeUiHost.open(BridgeUiHostDependencies(
              pairing: w.h.bridge,
              instanceRoot: w.root.path,
              closeResources: () async {})),
          throwsStateError);
      // POSIX locks are process-scoped, so a separate process is essential to
      // prove the same exclusion on Windows and the standing Linux CI worker.
      final probe = File(p.join(w.root.path, 'lock_probe.dart'));
      await probe.writeAsString('''
import 'dart:io';
Future<void> main(List<String> args) async {
  final file = await File(args.single).open(mode: FileMode.append);
  try {
    await file.lock(FileLock.exclusive);
    exitCode = 1;
  } on FileSystemException {
    exitCode = 0;
  } finally {
    await file.close();
  }
}
''');
      final result = await Process.run(
          flutterDartExecutable(),
          [
            probe.path,
            p.join(w.root.path, BridgeUiHost.lockFileName),
          ],
          runInShell: false);
      expect(result.exitCode, 0);
      expect(result.stdout, isEmpty);
      expect(result.stderr, isEmpty);
      await first.close();
      // The released lock no longer blocks a fresh host over the same owner.
      final second = await w.open(closeOwners: false);
      expect(second, isNot(same(first)));
      await second.close();
      expect(w.resources, 2);
    } finally {
      await w.close();
    }
  });

  test('a missing host root is refused without starting a host', () async {
    final w = await _World.create();
    try {
      final missing = p.join(w.root.path, 'missing');
      await expectLater(
          BridgeUiHost.open(BridgeUiHostDependencies(
              pairing: w.h.bridge,
              instanceRoot: missing,
              closeResources: () async {})),
          throwsStateError);
      expect(Directory(missing).existsSync(), isFalse);
      // No static host was retained by the refused construction.
      final host = await w.open(closeOwners: false);
      await host.close();
    } finally {
      await w.close();
    }
  });

  test('concurrent opens cannot create hosts over separate roots', () async {
    final w = await _World.create();
    final otherRoot =
        await Directory.systemTemp.createTemp('shiroha_bridge_host_');
    try {
      final opening = w.open(closeOwners: false);
      await expectLater(
          BridgeUiHost.open(BridgeUiHostDependencies(
              pairing: w.h.bridge,
              instanceRoot: otherRoot.path,
              closeResources: () async {})),
          throwsStateError);
      final host = await opening;
      expect(
          File(p.join(otherRoot.path, BridgeUiHost.lockFileName)).existsSync(),
          isFalse);
      await host.close();
    } finally {
      await otherRoot.delete(recursive: true);
      await w.close();
    }
  });

  test('surface cancellation joins the same original resource close', () async {
    final w = await _World.create();
    final resourcesReached = Completer<void>();
    final releaseResources = Completer<void>();
    final host = await BridgeUiHost.open(BridgeUiHostDependencies(
        pairing: w.h.bridge,
        instanceRoot: w.root.path,
        closeResources: () async {
          w.resources++;
          resourcesReached.complete();
          await releaseResources.future;
        }));
    try {
      host.port.beginEnrollment(displayLabel: 'Bridge', clientBuild: 'test');
      final closing = host.port.close();
      expect(identical(closing, host.close()), isTrue);
      expect(identical(closing, host.port.close()), isTrue);
      await resourcesReached.future;
      expect(host.port.display().closed, isTrue);
      expect(w.resources, 1);
      var settled = false;
      final observed = closing.then((_) => settled = true);
      await expectLater(host.port.importTrust('[]'), throwsA(anything));
      await expectLater(w.open(closeOwners: false), throwsStateError);
      expect(settled, isFalse);
      releaseResources.complete();
      await observed;
      expect(settled, isTrue);
      expect(w.resources, 1);
    } finally {
      if (!releaseResources.isCompleted) releaseResources.complete();
      await host.close();
      await w.close();
    }
  });

  test(
      'completed pairing hands off only after controller, Owner and lock close',
      () async {
    final w = await _World.create();
    final host = await w.open();
    final app = WindowsAppPublicPairingHandoff(owner: w.h.app);
    try {
      expect(host.closeForBusiness, throwsStateError);
      host.port.beginEnrollment(displayLabel: 'Bridge', clientBuild: 'handoff');
      final request = await app.requestSubmission(
          w.h.local.reference, host.port.display().submissionId!);
      await host.port.importTrust(await app.exportPublicTrust());
      host.port.confirmInitial((await request.display()).digest!);
      await request.approve();
      await request.complete();
      await host.port.importCompletion(await app.exportPublicCompletion());
      final completed = await request.display();
      host.port.confirmCompletion(completed.digest!, completed.revision!);
      expect(host.port.display().pinSaved, isTrue);
      expect(() => objects.adapter(w.h.native.calls).acquireBridgeObjects(),
          throwsA(anything));
      final closing = host.closeForBusiness();
      expect(identical(closing, host.close()), isTrue);
      await closing;
      expect(w.resources, 1);
      expect(w.h.bridgeOwner.isClosed, isTrue);
      final fresh = objects.adapter(w.h.native.calls).acquireBridgeObjects();
      expect(fresh.runtimeClaimed, isFalse);
      fresh.close();
      final lock = await File(p.join(w.root.path, BridgeUiHost.lockFileName))
          .open(mode: FileMode.append);
      await lock.lock(FileLock.exclusive);
      await lock.close();
    } finally {
      await host.close();
      await app.close();
      await w.close();
    }
  });

  // Keep last: unmounting starts the host's latched close inside the test's
  // fake-async zone, so that host remains retained for the rest of the process.
  testWidgets('window disposal withdraws the live surface immediately',
      (tester) async {
    final w = (await tester.runAsync(_World.create))!;
    final host = (await tester.runAsync(w.open))!;
    await tester.pumpWidget(host.build());
    await _pump(tester);
    await tester.tap(find.text('开始配对'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(_submissions(w.h), 1);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(host.isClosed, isTrue);
    expect(w.resources, 1);
    expect(tester.takeException(), isNull);
    await tester.runAsync(w.close);
  });
}

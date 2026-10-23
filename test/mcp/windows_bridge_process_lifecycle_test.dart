// Explicitly bounded Windows ordinary-child evidence. All Owners/TLS are Fake.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/data/external/windows_tls_transport.dart';

import '../application/generated_question/generated_test_support.dart'
    show initializeGeneratedTests;
import 'fixtures/windows_app_transport_fixture.dart';
import 'fixtures/windows_process_lifecycle_fixture.dart';

// Quarantine disposal is test-only and follows the original startup fixture.
// It never clears a product failed-close latch or retries unknown SDK work.
Future<void> _disposeFake(WindowsAppTransportFixture f) async {
  try {
    await f.bridge.close();
  } catch (_) {}
  try {
    await f.startup.close();
  } catch (_) {}
  await f.controlChannel?.close();
  f.plan.dispose();
  f.policy.invalidate();
  await f.files.close();
  await f.pairing.close();
}

void main() {
  initializeGeneratedTests();
  group('Windows ordinary Dart child lifecycle', () {
    test('creation, ready, stdin EOF, zero exit and both raw streams',
        () async {
      final f = await WindowsProcessLifecycleFixture.open();
      expect(f.creates, 0);
      expect(f.inventory.inspections, 0);
      expect(f.custody.isCurrent, isFalse);
      await f.start();
      final child = f.child!;
      expect(child.stdoutBytes, readyBytes);
      expect(child.exitObserved, isFalse);
      await f.allowExit();
      final first = f.custody.stopAndWait();
      expect(identical(first, f.custody.stopAndWait()), isTrue);
      await child.eof.future;
      await first;
      await f.custody.exited;
      expect(await child.rawExit, 0);
      expect(await child.settlement, 0);
      child.expectRawOutput();
      expect(child.closes, 1);
      expect(f.inventory.inspections, 1);
      expect(f.creates, 1);
      expect(f.custody.isCurrent, isFalse);
      expect(f.custody.start, throwsStateError);
    });

    test('delayed original exit holds repeated close and leaves another child',
        () async {
      final f = await WindowsProcessLifecycleFixture.open();
      final other = await WindowsProcessLifecycleFixture.open();
      await f.start();
      await other.start();
      var settled = false;
      final first = f.custody.stopAndWait();
      expect(identical(first, f.custody.stopAndWait()), isTrue);
      final closing = first.then((_) => settled = true);
      await f.child!.eof.future;
      expect(settled, isFalse);
      expect(f.child!.exitObserved, isFalse);
      expect(other.custody.isCurrent, isTrue);
      await f.allowExit();
      await closing;
      expect(await f.child!.rawExit, 0);
      expect(other.child!.exitObserved, isFalse);
      expect(other.child!.closes, 0);
      expect(other.custody.isCurrent, isTrue);
      await other.allowExit();
      await other.custody.stopAndWait();
      expect(await other.child!.rawExit, 0);
      f.child!.expectRawOutput();
      other.child!.expectRawOutput();
      expect(f.creates, 1);
      expect(other.creates, 1);
    });

    test('real exit cannot substitute either separately delayed drain receipt',
        () async {
      final f = await WindowsProcessLifecycleFixture.open(holdDrains: true);
      await f.start();
      var settled = false;
      final closing = f.custody.stopAndWait().then((_) => settled = true);
      await f.child!.eof.future;
      await f.allowExit();
      expect(await f.child!.rawExit, 0);
      await Future.wait([f.child!.rawStdout, f.child!.rawStderr]);
      f.child!.expectRawOutput();
      expect(settled, isFalse);
      f.stdoutReceipt.complete();
      await f.child!.stdoutDrained;
      expect(settled, isFalse);
      f.stderrReceipt.complete();
      await f.child!.stderrDrained;
      await closing;
      expect(settled, isTrue);
      expect(f.child!.closes, 1);
    });

    test(
        'cancel during creation joins the late original child through EOF/exit',
        () async {
      final f = await WindowsProcessLifecycleFixture.open(holdCreate: true);
      final opening = expectLater(f.custody.start(), throwsStateError);
      final child = await Future.any<ObservedWindowsTestChild>([
        f.created.future,
        opening.then<ObservedWindowsTestChild>(
            (_) => throw StateError('Ordinary child was not created')),
      ]);
      await child.ready.future;
      expect(child.exitObserved, isFalse);
      var settled = false;
      final first = f.custody.stopAndWait();
      expect(identical(first, f.custody.stopAndWait()), isTrue);
      final closing = first.then((_) => settled = true);
      expect(child.closes, 0);
      expect(settled, isFalse);
      f.transfer.complete();
      await opening;
      await child.eof.future;
      expect(settled, isFalse);
      expect(child.exitObserved, isFalse);
      await f.allowExit();
      await closing;
      expect(await child.rawExit, 0);
      child.expectRawOutput();
      expect(child.closes, 1);
      expect(f.creates, 1);
      expect(f.custody.isCurrent, isFalse);
    });

    test('real nonzero exit drains both streams and latches the same failure',
        () async {
      final f = await WindowsProcessLifecycleFixture.open(code: 23);
      await f.start();
      final first = f.custody.stopAndWait();
      final failure = expectLater(first, throwsStateError);
      await f.child!.eof.future;
      await f.allowExit();
      await failure;
      expect(await f.child!.rawExit, 23);
      expect(await f.child!.settlement, 23);
      f.child!.expectRawOutput();
      expect(identical(first, f.custody.stopAndWait()), isTrue);
      await expectLater(f.custody.stopAndWait(), throwsStateError);
      expect(f.child!.closes, 1);
      expect(f.creates, 1);
      expect(f.custody.isCurrent, isFalse);
    });

    test(
        'Bridge Owner is released only after real exit and both drain receipts',
        () async {
      final child = await WindowsProcessLifecycleFixture.open(holdDrains: true);
      await child.start();
      final f = WindowsAppTransportFixture()
        ..bridgeProcessOverride = child.custody;
      await f.open(productBridge: true, protectedAcquisition: true);
      addTearDown(() async {
        await child.releaseForCleanup();
        await _disposeFake(f);
      });
      expect((await f.call('open_generation_context'))['error'], isNull);
      final calls = f.clients.length;
      var settled = false;
      final first = f.bridge.close();
      expect(identical(first, f.bridge.close()), isTrue);
      final closing = first.then((_) => settled = true);
      await child.child!.eof.future;
      expect(settled, isFalse);
      expect(child.child!.exitObserved, isFalse);
      expect(f.pairing.bridgeOwner.isClosed, isFalse);
      expect((await f.call('open_generation_context'))['error'], 'unavailable');
      expect(f.clients.length, calls);
      await child.allowExit();
      expect(await child.child!.rawExit, 0);
      expect(f.pairing.bridgeOwner.isClosed, isFalse);
      child.stdoutReceipt.complete();
      await child.child!.stdoutDrained;
      expect(f.pairing.bridgeOwner.isClosed, isFalse);
      child.stderrReceipt.complete();
      await closing;
      child.child!.expectRawOutput();
      expect(f.pairing.bridgeOwner.isClosed, isTrue);
      expect(f.pairing.native.owner.isClosed, isFalse);
      expect(child.creates, 1);
      expect(f.bridgeProcess.stops, 0);
    });

    for (final fault in ['nonzero', 'unknown-exit', 'input', 'drain']) {
      test('Bridge $fault retains original Fake Owner and closes admission',
          () async {
        final child = await WindowsProcessLifecycleFixture.open(
            code: fault == 'nonzero' ? 23 : 0,
            waitsForEof: fault != 'nonzero',
            hideExit: fault == 'unknown-exit',
            failInput: fault == 'input',
            failDrain: fault == 'drain');
        await child.start();
        final f = WindowsAppTransportFixture()
          ..bridgeProcessOverride = child.custody;
        await f.open(productBridge: true, protectedAcquisition: true);
        addTearDown(() async {
          await child.releaseForCleanup();
          await _disposeFake(f);
        });
        if (fault == 'nonzero') {
          // An independent real exit must trigger the startup's own observer.
          await child.allowExit();
          await child.custody.exited;
          await child.child!.inputReached.future;
        }
        final first = f.bridge.close();
        final failure = expectLater(first, throwsStateError);
        await child.child!.inputReached.future;
        await child.allowExit();
        await failure;
        expect(await child.child!.rawExit, fault == 'nonzero' ? 23 : 0);
        child.child!.expectRawOutput(waitsForEof: fault != 'nonzero');
        expect(identical(first, f.bridge.close()), isTrue);
        await expectLater(f.bridge.close(), throwsStateError);
        expect(f.pairing.bridgeOwner.isClosed, isFalse);
        expect(f.pairing.bridgeOwner.runtimeClaimed, isTrue);
        expect(
            (await f.call('open_generation_context'))['error'], 'unavailable');
        expect(child.custody.start, throwsStateError);
        expect(child.creates, 1);
        expect(child.child!.closes, 1);
        expect(f.bridgeProcess.stops, 0);
        expect(f.clients, isEmpty);
        f.pairing.native.owner.ensureOpen();
      });
    }

    for (final code in [0, 23]) {
      test('App/Restore database close barrier joins actual child exit $code',
          () async {
        final child = await WindowsProcessLifecycleFixture.open(code: code);
        final f = WindowsAppTransportFixture()
          ..appProcessOverride = child.custody;
        await f.open(productBridge: true, protectedAcquisition: true);
        await child.child!.ready.future;
        expect(child.creates, 1); // Startup owns launch and later settlement.
        addTearDown(() async {
          await child.releaseForCleanup();
          await _disposeFake(f);
        });
        var settled = false;
        final closing = f.closeDatabase().then((_) => settled = true);
        final result =
            code == 0 ? closing : expectLater(closing, throwsA(anything));
        await child.child!.eof.future;
        expect(settled, isFalse);
        expect(child.child!.exitObserved, isFalse);
        expect(f.files.s.h.db.isOpen, isTrue);
        expect(f.pairing.native.owner.isClosed, isFalse);
        expect(f.host.phase, WindowsTlsHostPhase.closing);
        await child.allowExit();
        await result;
        expect(await child.child!.rawExit, code);
        child.child!.expectRawOutput();
        expect(f.pairing.native.owner.isClosed, code == 0);
        expect(f.files.s.h.db.isOpen, code != 0);
        expect(f.appProcess.stops, 0);
        expect(child.creates, 1);
        if (code != 0) {
          await expectLater(f.startup.close(), throwsA(anything));
          await expectLater(f.integration.close(), throwsA(anything));
          expect((await f.call('open_generation_context'))['error'], isNotNull);
          expect(f.pairing.native.owner.isClosed, isFalse);
        }
      });
    }
  },
      skip: Platform.isWindows
          ? false
          : 'Requires actual Windows child processes');
}

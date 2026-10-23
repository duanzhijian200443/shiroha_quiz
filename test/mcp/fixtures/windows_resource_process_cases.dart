// G0-L0: public credentials, Fake Native/process/TLS, isolated SQLite only.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/external/external_credential_association.dart';
import 'package:shiroha_quiz/composition/mcp_vnext_windows_acquisition.dart';
import 'package:shiroha_quiz/composition/mcp_vnext_windows_startup.dart'
    show McpVnextWindowsBridgeStartup;
import 'package:shiroha_quiz/data/external/windows_bridge_process.dart';
import 'package:shiroha_quiz/data/external/windows_release_candidate.dart';
import 'package:shiroha_quiz/data/external/windows_tls_transport.dart';
import '../../application/external/local_host_test_support.dart'
    show OfflineReadiness;

import '../../data/external/windows_credential_initialization_test.dart'
    as init;
import '../../data/external/windows_credential_object_store_test.dart'
    as objects;
import '../../data/external/windows_release_candidate_test.dart' show pe;
import 'windows_app_transport_fixture.dart';

class FakeCreatedBridge implements WindowsCreatedBridgeProcess {
  final exit = Completer<int>(), drained = Completer<int>();
  final inputReached = Completer<void>();
  bool failInput = false;
  int closes = 0;
  @override
  Future<int> get exitCode => exit.future;
  @override
  Future<int> get settlement => drained.future;
  @override
  Future<void> closeInput() async {
    closes++;
    if (!inputReached.isCompleted) inputReached.complete();
    if (failInput) throw StateError('Fake input close unknown');
  }

  void finish([int code = 0]) {
    exit.complete(code);
    drained.complete(code);
  }
}

class FakeBridgeProcessIo implements WindowsBridgeProcessIo {
  final child = FakeCreatedBridge();
  final creating = Completer<void>();
  Completer<void>? releaseCreate;
  int inspections = 0, creates = 0;
  bool invalidPackage = false, failInspect = false, failCreate = false;
  @override
  Future<Map<String, Uint8List>> inspect() async {
    inspections++;
    if (failInspect) throw StateError('Fake inspection handle unknown');
    return {
      for (final name in WindowsExternalReleaseCandidate.bridgeFiles)
        name: invalidPackage ? Uint8List(1) : pe()
    };
  }

  @override
  Future<WindowsCreatedBridgeProcess> create() async {
    creates++;
    creating.complete();
    await releaseCreate?.future;
    if (failCreate) throw StateError('Fake creation unknown');
    return child;
  }
}

McpVnextWindowsProtectedAcquirer _acquirer(init.Harness h) =>
    McpVnextWindowsProtectedAcquirer(
      openNative: () => objects.adapter(h.calls),
      primitives: McpVnextWindowsCredentialPrimitives(
          generateKey: h.generate, signDigest: h.sign, verifyDigest: h.verify),
      utcNow: () => h.now,
      monotonicNow: () => Duration.zero,
      compositionIsCurrent: () => true,
      randomBytes: (_) => throw StateError('No random operation allowed'),
    );

void windowsResourceProcessCases() {
  test(
      'runtime App assembly supplies original resources, public handoff and inert concrete defaults',
      () async {
    final f = WindowsAppTransportFixture();
    await f.open();
    addTearDown(f.close);
    final h = init.Harness();
    h.seed(1);
    h.seed(2);
    h.owner.close();
    final d = await _acquirer(h).acquireAppRuntime(
        clock: f.files.s.clock,
        readiness: OfflineReadiness(() async {}),
        port: 43123,
        submissionId: () async => throw StateError('No local input requested'));
    try {
      expect(d.listener, isA<DartLoopbackTlsIo>());
      expect(d.process, isA<WindowsBridgeProcess>());
      expect((d.process as WindowsBridgeProcess).isCurrent, isFalse);
      expect(d.openLocalConnection, isNull);
      expect(d.closeLocalConnections, isNull);
      expect(d.owner.runtimeClaimed, isFalse);
      expect(h.generated, 0);
      expect(h.randomCalls, 0);
    } finally {
      await d.process.stopAndWait();
      await d.associations.close();
      d.owner.close();
      h.dispose();
    }
  });
  test('native acquirer construction and process construction do nothing', () {
    var loads = 0;
    McpVnextWindowsProtectedAcquirer(
        openNative: () {
          loads++;
          throw StateError('Not admitted');
        },
        utcNow: () => throw StateError('No clock'),
        monotonicNow: () => throw StateError('No clock'),
        compositionIsCurrent: () => throw StateError('No admission'),
        randomBytes: (_) => throw StateError('No random'));
    final io = FakeBridgeProcessIo();
    final process = WindowsBridgeProcess(io: io);
    expect(loads, 0);
    expect(io.inspections, 0);
    expect(io.creates, 0);
    expect(process.isCurrent, isFalse);
  });

  for (final kind in ['app', 'bridge']) {
    test('occupied $kind Owner is never closed by rejected acquisition',
        () async {
      final f = WindowsAppTransportFixture();
      await f.open(productBridge: true);
      addTearDown(f.close);
      final h = f.pairing.native;
      final before = h.calls.events.where((e) => e == 'close').length;
      final a = _acquirer(h), process = FakeWindowsMcpProcess();
      if (kind == 'app') {
        await expectLater(
            a.acquireApp(
                assemble: (_) => throw StateError('Must not assemble'),
                process: process,
                closeLocalConnections: () async {}),
            throwsStateError);
      } else {
        await expectLater(
            a.acquireBridge(
                assemble: (_) => throw StateError('Must not assemble'),
                process: process),
            throwsStateError);
      }
      expect(h.calls.events.where((e) => e == 'close').length, before);
      expect(h.calls.owners.length, 2);
      expect((await f.call('open_generation_context'))['error'], isNull);
    });
  }

  for (final missing in [true, false]) {
    test('partial App acquisition drains before release; missing=$missing',
        () async {
      final h = init.Harness();
      if (!missing) {
        h.seed(1);
        h.seed(2);
      }
      h.owner.close();
      final a = _acquirer(h), process = FakeWindowsMcpProcess();
      process.stopping = Completer<void>();
      var assembled = false;
      final result = expectLater(
          a.acquireApp(
              assemble: (_) {
                assembled = true;
                throw StateError('Partial assembly');
              },
              process: process,
              closeLocalConnections: () async {}),
          throwsStateError);
      await process.reached.future;
      expect(h.calls.owners.length, 1);
      expect(assembled, !missing);
      expect(h.generated, 0);
      expect(h.randomCalls, 0);
      process.stopping!.complete();
      await result;
      expect(h.calls.owners, isEmpty);
      final calls = h.calls.events.length;
      await expectLater(
          a.acquireBridge(
              assemble: (_) => throw StateError('Duplicate'), process: process),
          throwsStateError);
      expect(h.calls.events.length, calls);
      h.dispose();
    });
  }

  test('partial acquisition unknown close retains original owner without retry',
      () async {
    final h = init.Harness();
    h.seed(1);
    h.seed(2);
    h.owner.close();
    final a = _acquirer(h), process = FakeWindowsMcpProcess()..fail = true;
    McpVnextWindowsAppResources? captured;
    await expectLater(
        a.acquireApp(
            assemble: (r) {
              captured = r;
              throw StateError('Partial assembly');
            },
            process: process,
            closeLocalConnections: () async {}),
        throwsStateError);
    captured!.owner.ensureOpen();
    expect(captured!.owner.runtimeClaimed, isTrue);
    expect(h.calls.owners.length, 1);
    expect(process.stops, 1);
    await expectLater(
        a.acquireApp(
            assemble: (_) => throw StateError('Duplicate'),
            process: process,
            closeLocalConnections: () async {}),
        throwsStateError);
    expect(process.stops, 1);
    expect(captured!.owner.isClosed, isFalse);
    // Test-only disposal of quarantined Fake resources, never product recovery.
    await captured!.associations.close();
    captured!.owner.close();
    h.dispose();
  });

  test('foreign bundle never transfers or releases the foreign owner',
      () async {
    final f = WindowsAppTransportFixture();
    await f.open();
    addTearDown(f.close);
    final h = init.Harness();
    h.seed(1);
    h.seed(2);
    h.owner.close();
    final process = FakeWindowsMcpProcess();
    await expectLater(
        _acquirer(h).acquireApp(
            assemble: (_) => f.appDependencies,
            process: process,
            closeLocalConnections: () async {}),
        throwsStateError);
    expect(h.calls.owners, isEmpty);
    f.pairing.native.owner.ensureOpen();
    expect(f.appProcess.stops, 0);
    expect((await f.call('open_generation_context'))['error'], isNull);
    h.dispose();
  });

  test('duplicate Bridge runtime rejects without touching original custody',
      () async {
    final f = WindowsAppTransportFixture();
    await f.open(productBridge: true, protectedAcquisition: true);
    addTearDown(f.close);
    final candidate =
        McpVnextWindowsBridgeStartup(acquire: () async => f.bridgeDependencies);
    await expectLater(candidate.start(), throwsStateError);
    await candidate.close();
    f.pairing.bridgeOwner.ensureOpen();
    expect(f.bridgeProcess.stops, 0);
    expect((await f.call('open_generation_context'))['error'], isNull);
  });

  test('Bridge partial acquisition retains unknown process owner and lock',
      () async {
    final h = init.Harness();
    final process = FakeWindowsMcpProcess()..fail = true;
    final a = _acquirer(h);
    // The original App owner is independent and must remain usable.
    await expectLater(
        a.acquireBridge(
            assemble: (_) => throw StateError('Partial Bridge assembly'),
            process: process),
        throwsStateError);
    h.owner.ensureOpen();
    expect(h.calls.owners.length, 2);
    final before = h.calls.events.length;
    await expectLater(
        a.acquireBridge(
            assemble: (_) => throw StateError('No retry'), process: process),
        throwsStateError);
    expect(h.calls.events.length, before);
    // Fake registry disposal only; no product recovery path.
    h.calls.owners.removeWhere((_, role) => role == 2);
    h.dispose();
  });

  test('fixed package rejection never creates a child', () async {
    final io = FakeBridgeProcessIo()..invalidPackage = true;
    final process = WindowsBridgeProcess(io: io);
    await expectLater(process.start(), throwsStateError);
    await process.stopAndWait();
    expect(io.creates, 0);
    expect(process.start, throwsStateError);
  });

  test('failed drain notification still waits for original exit before failure',
      () async {
    final io = FakeBridgeProcessIo();
    final process = WindowsBridgeProcess(io: io);
    await process.start();
    io.child.drained.completeError(StateError('Fake drain failed early'));
    await process.exited;
    expect(process.isCurrent, isFalse);
    var settled = false;
    final closing = expectLater(process.stopAndWait(), throwsStateError)
        .then((_) => settled = true);
    await io.child.inputReached.future;
    expect(settled, isFalse);
    io.child.exit.complete(0);
    await closing;
  });

  test('interrupted launch joins original create, input, exit and stream drain',
      () async {
    final io = FakeBridgeProcessIo()..releaseCreate = Completer<void>();
    final process = WindowsBridgeProcess(io: io);
    final opening = expectLater(process.start(), throwsStateError);
    await io.creating.future;
    var closed = false;
    final first = process.stopAndWait(), second = process.stopAndWait();
    expect(identical(first, second), isTrue);
    final closing = first.then((_) => closed = true);
    io.releaseCreate!.complete();
    await opening;
    await io.child.inputReached.future;
    expect(closed, isFalse);
    io.child.exit.complete(0);
    await process.exited;
    expect(closed, isFalse);
    io.child.drained.complete(0);
    await closing;
    expect(io.child.closes, 1);
    expect(io.creates, 1);
  });

  for (final failure in ['inspect', 'create', 'input', 'exit', 'drain']) {
    test('unknown $failure is latched without relaunch or false close',
        () async {
      final io = FakeBridgeProcessIo()
        ..failInspect = failure == 'inspect'
        ..failCreate = failure == 'create';
      final process = WindowsBridgeProcess(io: io);
      if (failure == 'create' || failure == 'inspect') {
        await expectLater(process.start(), throwsStateError);
      } else {
        await process.start();
        io.child.failInput = failure == 'input';
      }
      final closing = expectLater(process.stopAndWait(), throwsStateError);
      if (failure != 'create' && failure != 'inspect') {
        io.child.exit.complete(failure == 'exit' ? 78 : 0);
        if (failure == 'drain') {
          io.child.drained.completeError(StateError('Fake stream failure'));
        } else {
          io.child.drained.complete(failure == 'exit' ? 78 : 0);
        }
      }
      await closing;
      await expectLater(process.stopAndWait(), throwsStateError);
      expect(process.isCurrent, isFalse);
      expect(process.start, throwsStateError);
      expect(io.creates, failure == 'inspect' ? 0 : 1);
      expect(io.child.closes, ['create', 'inspect'].contains(failure) ? 0 : 1);
    });
  }

  test(
      'unexpected child exit stops App and retains Owner and database on failure',
      () async {
    final io = FakeBridgeProcessIo();
    final process = WindowsBridgeProcess(io: io);
    await process.start();
    final f = WindowsAppTransportFixture()..appProcessOverride = process;
    await f.open(productBridge: true, protectedAcquisition: true);
    io.child.exit.complete(78);
    await process.exited;
    await io.child.inputReached.future;
    expect(f.pairing.native.owner.isClosed, isFalse);
    expect(f.files.s.h.db.isOpen, isTrue);
    final closing = expectLater(
        f.startup.close(), throwsA(isA<ExternalCredentialException>()));
    io.child.drained.complete(78);
    await closing;
    await expectLater(
        f.integration.close(), throwsA(isA<ExternalCredentialException>()));
    expect(f.pairing.native.owner.isClosed, isFalse);
    expect(f.files.s.h.db.isOpen, isTrue);
    // Explicit Fake quarantine disposal after assertions.
    await f.bridge.close();
    await f.controlChannel?.close();
    f.plan.dispose();
    f.policy.invalidate();
    await f.files.close();
    await f.pairing.close();
  });
}

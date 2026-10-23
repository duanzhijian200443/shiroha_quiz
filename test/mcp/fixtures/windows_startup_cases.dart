// G0-L0 only: existing public mathematical credentials, Fake Native/TLS and DB.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/external/external_authorization.dart';
import 'package:shiroha_quiz/application/external/first_party_external_credentials.dart';
import 'package:shiroha_quiz/composition/mcp_vnext_app_integration.dart';
import 'package:shiroha_quiz/composition/mcp_vnext_windows_startup.dart';
import 'package:shiroha_quiz/data/external/windows_bridge_process.dart'
    show WindowsBridgeProcess;
import 'package:shiroha_quiz/data/external/windows_tls_transport.dart';
import 'package:shiroha_quiz/data/external/windows_pairing.dart';
import 'package:shiroha_quiz/mcp/vnext_mcp_composition_root.dart';

import '../../application/external/local_host_test_support.dart'
    show OfflineReadiness;
import '../../application/study_query/study_query_test_support.dart'
    show insertLegacyQuestion;
import '../../data/external/windows_tls_lifecycle_test.dart' show BindBarrier;
import 'first_party_app_integration_cases.dart';
import 'windows_app_transport_fixture.dart';
import 'windows_resource_process_cases.dart';

final class _ForeignTransport implements McpVnextAppTransport {
  _ForeignTransport(this.binding);
  @override
  final VnextMcpAppComposition binding;
  int starts = 0, closes = 0;
  @override
  Future<void> start() async {
    starts++;
  }

  @override
  Future<void> close() async {
    closes++;
  }
}

final class _UnusedPairing implements FirstPartyPairingPort {
  @override
  Future<FirstPartyPairingRequest> request(ExternalProfileReference _) =>
      throw StateError('No pairing requested');
  @override
  Future<void> close() async {}
}

McpVnextAppIntegration _newApp(WindowsAppTransportFixture f) {
  final original = f.integration;
  return McpVnextAppIntegration(
    policy: f.policy,
    localAuthority: original.localAuthority,
    authorization: original.authorization,
    proposals: original.proposals,
    targets: original.targets,
    questions: original.questions,
    files: original.files,
    artifacts: original.artifacts,
    artifactMetadata: original.artifactMetadata,
    index: original.index,
    chunker: original.chunker,
    mintId: original.mintId,
    compositionIsCurrent: () => f.files.s.h.db.isOpen,
  );
}

// Explicit disposal of test-only quarantine AFTER assertions. It does not call
// a production retry/recovery API or turn a latched failed close into success.
Future<void> _disposeFake(WindowsAppTransportFixture f) async {
  try {
    await f.bridgeStartup?.close();
  } catch (_) {}
  try {
    await f.startup.close();
  } catch (_) {}
  f.controlChannel?.failClose = false;
  await f.controlChannel?.close();
  if (f.localPlanCreated) f.plan.dispose();
  f.policy.invalidate();
  await f.files.close();
  await f.pairing.close();
}

/// Registered through the existing standing P11 architecture test entry.
void windowsStartupCases() {
  windowsResourceProcessCases();
  test('dormant startup constructors and close-before-start acquire nothing',
      () async {
    final f = FirstPartyAppHarness();
    await f.open(attach: false);
    addTearDown(f.close);
    var acquisitions = 0;
    final app = McpVnextWindowsAppStartup(
      integration: f.integration,
      acquire: () async {
        acquisitions++;
        throw StateError('Not admitted');
      },
    );
    final bridge = McpVnextWindowsBridgeStartup(
      acquire: () async {
        acquisitions++;
        throw StateError('Not admitted');
      },
    );
    expect(acquisitions, 0);
    expect(
        (await bridge.call('open_generation_context', {},
            cancelled: const Stream.empty(), available: () => true))['error'],
        'unavailable');
    await Future.wait([app.close(), bridge.close()]);
    expect(acquisitions, 0);
    expect(app.start, throwsStateError);
    expect(bridge.start, throwsStateError);
  });

  for (final protectedAcquisition in [false, true]) {
    test(
        'trusted startup bundles wire all seven tools: native=$protectedAcquisition',
        () async {
      final f = WindowsAppTransportFixture();
      final processIo = protectedAcquisition ? FakeBridgeProcessIo() : null;
      if (processIo != null) {
        final process = WindowsBridgeProcess(io: processIo);
        await process.start();
        f.appProcessOverride = process;
      }
      addTearDown(() async {
        if (processIo != null && !processIo.child.exit.isCompleted) {
          processIo.child.finish();
        }
        await f.close();
      });
      await f.open(
          productBridge: true, protectedAcquisition: protectedAcquisition);
      await insertLegacyQuestion(f.files.s.h.db,
          id: 'startup-question',
          bankName: 'bank',
          createdAt: 1,
          content: 'Synthetic needle');
      final context = await f.context();
      final search = f.data(await f.call(
          'search_questions', {'contextRef': context, 'query': 'needle'}));
      final question = (search['items'] as List).single as Map;
      expect(
          f.data(await f.call('get_question_detail', {
            'contextRef': context,
            'questionRef': question['questionRef']
          }))['sourceKind'],
          'legacy');
      final choices = f.data(
          await f.call('open_generation_context', {'contextRef': context}));
      final selected = f.data(await f.call('open_generation_context', {
        'contextRef': context,
        'fileRefs': [(choices['items'] as List).first['fileRef']]
      }))['contextRef'];
      final retrieval = f.data(await f.call('retrieve_file_content',
          {'contextRef': selected, 'query': 'needle'}));
      final passage = (retrieval['items'] as List).single as Map;
      expect(
          f.data(await f.call('get_file_passage', {
            'contextRef': selected,
            'passageRef': passage['passageRef']
          }))['items'],
          isNotEmpty);
      expect(
          f.data(await f.approvedStage(context, 'startup-key'))['publication'],
          'STAGED');
      expect(
          f.data(await f.call('get_question_proposal',
              {'submissionKey': 'startup-key'}))['lifecycleStatus'],
          'pending_review');
      expect(await f.files.s.h.count('generated_question_proposals'), 1);
      expect(await f.files.s.h.count('generated_question_commit_receipts'), 0);
      expect(f.clients.length, 10);
      expect(f.clients.every((c) => c.writes.length == 1 && !c.isOpen), isTrue);
      await f.host.whenConnectionsSettled;
      for (final resource in TlsResource.values) {
        expect(f.host.budget.used(resource), 0);
      }
      await f.bridge.close();
      expect(f.pairing.bridgeOwner.isClosed, isTrue);
      expect(f.pairing.native.owner.isClosed, isFalse);
      final closing = f.startup.close();
      if (processIo != null) {
        await processIo.child.inputReached.future;
        expect(f.pairing.native.owner.isClosed, isFalse);
        processIo.child.finish();
      }
      await closing;
      expect(f.pairing.native.owner.isClosed, isTrue);
      expect(f.appProcess.stops, processIo == null ? 1 : 0);
      if (processIo != null) expect(processIo.child.closes, 1);
      expect(f.bridgeProcess.stops, 1);
    });
  }

  test(
      'foreign App binding is rejected without touching its existing transport',
      () async {
    final foreign = WindowsAppTransportFixture();
    await foreign.open();
    addTearDown(foreign.close);
    // Share the existing isolated database without reopening the global runtime
    // profile. The candidate App has its own local lifecycle, no second writer.
    final candidateApp = _newApp(foreign);
    addTearDown(candidateApp.close);
    final p = foreign.pairing;
    final candidate =
        _ForeignTransport(foreign.host.binding as VnextMcpAppComposition);
    await expectLater(
        candidateApp.attachCredentials(
          associations: p.associations,
          verification: (_) => WindowsPairingVerification.withPrimitives(
              verifyDigest: p.native.verify,
              utcNow: () => p.native.now,
              monotonicNow: () => p.elapsed,
              compositionIsCurrent: () => p.current),
          clock: foreign.files.s.clock,
          installationId:
              p.native.service.validatedPublicMaterial().installationId,
          readiness: OfflineReadiness(() async {}),
          services: (boundary) => FirstPartyCredentialServices(
            boundary: boundary,
            pairing: _UnusedPairing(),
            openConnection: (_) async =>
                throw StateError('No authentication requested'),
            close: () async {},
          ),
          transport: (coordinator, binding) => candidate,
        ),
        throwsStateError);
    expect(candidate.starts, 0);
    expect(candidate.closes, 0);
    expect(foreign.host.isReady, isTrue);
    foreign.pairing.native.owner.ensureOpen();
  });

  for (final mode in ['attachment', 'owner']) {
    test('startup refuses borrowed $mode without closing the original runtime',
        () async {
      final f = WindowsAppTransportFixture();
      await f.open();
      addTearDown(f.close);
      final integration = mode == 'attachment' ? f.integration : _newApp(f);
      var acquisitions = 0;
      final candidate = McpVnextWindowsAppStartup(
        integration: integration,
        acquire: () async {
          acquisitions++;
          return f.appDependencies;
        },
      );
      await expectLater(candidate.start(), throwsStateError);
      await candidate.close();
      expect(acquisitions, mode == 'attachment' ? 0 : 1);
      expect(f.host.isReady, isTrue);
      expect(f.integration.controls.isCurrent, isTrue);
      expect(f.appProcess.stops, 0);
      f.pairing.native.owner.ensureOpen();
      expect(
          f.data(await f.call('open_generation_context'))['items'], isNotEmpty);
    });
  }

  for (final mode in ['readiness', 'bind', 'acquire-interruption']) {
    test('App startup $mode settles original partial owners and cannot restart',
        () async {
      final f = WindowsAppTransportFixture();
      final reached = Completer<void>(), release = Completer<void>();
      if (mode == 'readiness') f.failReadiness = true;
      if (mode == 'bind') {
        f.listener.onBind = () => throw StateError('Fake bind failure');
      }
      if (mode == 'acquire-interruption') {
        f.beforeAcquire = () async {
          reached.complete();
          await release.future;
        };
      }
      final opening = expectLater(f.open(), throwsStateError);
      Future<void>? closing;
      if (mode == 'acquire-interruption') {
        await reached.future;
        var closed = false;
        closing = f.startup.close().then((_) => closed = true);
        expect(closed, isFalse);
        f.pairing.native.owner.ensureOpen();
        expect(f.listener.binds, 0);
        release.complete();
      }
      await opening;
      await closing;
      addTearDown(() => _disposeFake(f));
      expect(f.pairing.native.owner.isClosed, isTrue);
      expect(f.appProcess.stops, 1);
      expect(f.startup.start, throwsStateError);
      expect(f.listener.binds, mode == 'bind' ? 1 : 0);
    });
  }

  test(
      'close during bind retains Owner until the original listener Future settles',
      () async {
    final f = WindowsAppTransportFixture();
    final bind = BindBarrier();
    f.listenerOverride = bind;
    final opening = expectLater(f.open(), throwsStateError);
    await bind.reached.future;
    var closed = false;
    final closing = f.startup.close().then((_) => closed = true);
    expect(closed, isFalse);
    f.pairing.native.owner.ensureOpen();
    bind.resume.complete();
    await Future.wait([opening, closing]);
    addTearDown(() => _disposeFake(f));
    expect(bind.listener.closes, 1);
    expect(f.pairing.native.owner.isClosed, isTrue);
  });

  test('pending local authentication open remains owned through App close',
      () async {
    final f = WindowsAppTransportFixture();
    final reached = Completer<void>(), release = Completer<void>();
    f.beforeLocalOpen = () async {
      reached.complete();
      await release.future;
    };
    final opening = expectLater(f.open(), throwsA(anything));
    await reached.future;
    final drained = f.localCloseReached = Completer<void>();
    var closed = false;
    final closing = f.startup.close().then((_) => closed = true);
    await drained.future;
    expect(closed, isFalse);
    f.pairing.native.owner.ensureOpen();
    release.complete();
    await Future.wait([opening, closing]);
    addTearDown(() => _disposeFake(f));
    expect(f.pairing.native.owner.isClosed, isTrue);
    expect(f.controlChannel!.isOpen, isFalse);
  });

  test('Bridge busy and EOF retain credential Owner through pending raw write',
      () async {
    final f = WindowsAppTransportFixture();
    await f.open(productBridge: true);
    addTearDown(f.close);
    final release = Completer<void>(), reached = Completer<void>();
    f.configureConnection = (client, _) {
      client.writing = release;
      client.written.future.then((_) => reached.complete());
    };
    final call = f.call('open_generation_context');
    await reached.future;
    expect((await f.call('open_generation_context'))['error'], 'busy');
    expect(f.clients.length, 1);
    var closed = false;
    final closing = f.bridge.close().then((_) => closed = true);
    await f.bridgeProcess.reached.future;
    expect(closed, isFalse);
    f.pairing.bridgeOwner.ensureOpen();
    expect((await f.call('open_generation_context'))['error'], 'unavailable');
    release.complete();
    expect((await call)['error'], isNotNull);
    await closing;
    expect(f.pairing.bridgeOwner.isClosed, isTrue);
    expect(f.bridgeProcess.stops, 1);
  });

  test('Bridge failed raw cleanup locks admission and retains credential Owner',
      () async {
    final f = WindowsAppTransportFixture();
    await f.open(productBridge: true);
    addTearDown(() => _disposeFake(f));
    f.configureConnection = (client, _) => client.failClose = true;
    expect(
        (await f.call('open_generation_context'))['error'], 'outcome_unknown');
    expect((await f.call('open_generation_context'))['error'], 'unavailable');
    expect(f.clients.length, 1);
    final first = f.bridge.close(), second = f.bridge.close();
    expect(identical(first, second), isTrue);
    await expectLater(first, throwsStateError);
    expect(f.pairing.bridgeOwner.isClosed, isFalse);
    expect(f.bridgeProcess.stops, 1);
    expect((await f.call('open_generation_context'))['error'], 'unavailable');
  });

  test('Bridge unknown process exit locks admission and retains Owner',
      () async {
    final f = WindowsAppTransportFixture();
    await f.open(productBridge: true);
    addTearDown(() => _disposeFake(f));
    f.bridgeProcess.fail = true;
    await expectLater(f.bridge.close(), throwsStateError);
    expect(f.pairing.bridgeOwner.isClosed, isFalse);
    expect(f.bridgeProcess.stops, 1);
    expect((await f.call('open_generation_context'))['error'], 'unavailable');
  });

  for (final mode in ['local-close', 'process-exit']) {
    test('App $mode failure blocks database close and retains runtime.lock',
        () async {
      final f = WindowsAppTransportFixture();
      await f.open();
      addTearDown(() => _disposeFake(f));
      if (mode == 'local-close') f.controlChannel!.failClose = true;
      if (mode == 'process-exit') f.appProcess.fail = true;
      await expectLater(f.closeDatabase(), throwsA(anything));
      expect(f.files.s.h.db.isOpen, isTrue);
      expect(f.host.phase, WindowsTlsHostPhase.closing);
      f.pairing.native.owner.ensureOpen();
      expect((await f.call('open_generation_context'))['error'], isNotNull);
      await expectLater(f.startup.close(), throwsA(anything));
      expect(f.pairing.native.owner.isClosed, isFalse);
      expect(f.appProcess.stops, 1);
      expect(f.startup.start, throwsStateError);
    });
  }
}

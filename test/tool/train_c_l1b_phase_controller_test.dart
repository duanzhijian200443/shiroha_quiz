import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';

import '../../tool/train_c_evidence_probe.dart';
import '../../tool/train_c_http_observer.dart';
import '../../tool/train_c_isolated_runtime.dart';
import '../../tool/train_c_l1b_live_runtime.dart';
import '../../tool/train_c_l1b_phase_controller.dart';
import '../../tool/train_c_l1b_supervisor.dart';
import '../../tool/train_c_l1b_transport.dart';
import '../../tool/train_c_live_attempt_authority.dart';
import '../../tool/train_c_runtime_evidence_source.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const head = 'a000000000000000000000000000000000000000';
  const base = 'b000000000000000000000000000000000000000';
  const digest =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

  Directory createState() {
    final directory = Directory.systemTemp.createTempSync(
      'train_c_phase_controller_test_',
    );
    addTearDown(() {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });
    return directory;
  }

  ({
    String token,
    TrainCLiveRunCapability capability,
    Directory directory,
  }) authorize() {
    final directory = createState();
    final token = TrainCLiveRunCapability.authorize(
      stateDirectory: directory,
      approvedHarnessHead: head,
      approvedBase: base,
    );
    final capability = TrainCLiveRunCapability.fromCapability(token);
    capability.verifyUnused(
      reviewedHarnessHead: head,
      reviewedBase: base,
    );
    return (token: token, capability: capability, directory: directory);
  }

  void bindAndConfigure(TrainCLiveRunCapability capability) {
    capability.bindRuntimeCapability('runtime-a');
    capability.markConfigured();
  }

  test('runtime identity survives recreation and rejects another runtime', () {
    final authority = authorize();
    final capability = authority.capability;
    bindAndConfigure(capability);
    final recreated = TrainCLiveRunCapability.fromCapability(authority.token);
    expect(recreated.runtimeMatches('runtime-a'), isTrue);
    expect(recreated.runtimeMatches('runtime-b'), isFalse);
    expect(
      () => recreated.validateRestoreRuntimeIdentity('runtime-a'),
      _code('TRAIN_C_ISOLATION_FAILURE'),
    );
    recreated.validateRestoreRuntimeIdentity('runtime-b');
    expect(
      () => recreated.transitionTo(TrainCLiveRunPhase.parseRunning),
      _code('TRAIN_C_HEAD_DRIFT'),
    );
  });

  test('one-shot consumption is durable before a second parse can start', () {
    final authority = authorize();
    final capability = authority.capability;
    bindAndConfigure(capability);
    capability.markParseRunning();
    final ledger = TrainCRequestLedger(attemptAuthority: capability);
    ledger.beginParse(expectedLayoutRequests: 1);
    ledger.recordDispatchMethod('POST');
    expect(
      capability.snapshot.attemptState,
      TrainCLiveRunAttemptState.consumed,
    );
    final recreated = TrainCLiveRunCapability.fromCapability(authority.token);
    expect(
      () => recreated.verifyUnused(
        reviewedHarnessHead: head,
        reviewedBase: base,
      ),
      _code('TRAIN_C_ATTEMPT_BUDGET_EXHAUSTED'),
    );
  });

  test('phase controller accepts only the frozen linear chain', () {
    final capability = authorize().capability;
    bindAndConfigure(capability);
    capability.markParseRunning();
    capability.consumeAtDispatch();
    capability.markPendingReview();
    final controller = TrainCL1BPhaseController.forContinuation(
      capability: capability,
      reviewedHarnessHead: head,
      reviewedBase: base,
    );
    controller.transitionTo(TrainCLiveRunPhase.commitReady);
    controller.transitionTo(TrainCLiveRunPhase.committed);
    controller.transitionTo(TrainCLiveRunPhase.restartProved);
    controller.transitionTo(TrainCLiveRunPhase.b0Exported);
    controller.transitionTo(TrainCLiveRunPhase.b0Restored);
    controller.transitionTo(TrainCLiveRunPhase.finalized);
    expect(capability.snapshot.phase, TrainCLiveRunPhase.finalized);
    expect(
      () => controller.transitionTo(TrainCLiveRunPhase.parseRunning),
      _code('TRAIN_C_HARNESS_NOT_READY'),
    );
  });

  test('continuation is provider-forbidden and pending survives recreation',
      () {
    final authority = authorize();
    final capability = authority.capability;
    bindAndConfigure(capability);
    capability.markParseRunning();
    capability.consumeAtDispatch();
    capability.markPendingReview();
    final recreated = TrainCLiveRunCapability.fromCapability(authority.token);
    final controller = TrainCL1BPhaseController.forContinuation(
      capability: recreated,
      reviewedHarnessHead: head,
      reviewedBase: base,
    );
    controller.requireProviderForbidden();
    expect(recreated.snapshot.phase, TrainCLiveRunPhase.pendingReview);
    expect(
      () => TrainCRequestLedger(providerDisabled: true)
          .recordDispatchMethod('GET'),
      _protocol('TRAIN_C_PROVIDER_REQUEST_COUNT_FAILURE'),
    );
  });

  test('stale revision cannot advance after another writer commits', () {
    final capability = authorize().capability;
    bindAndConfigure(capability);
    final staleRevision = capability.snapshot.revision;
    capability.markParseRunning();
    expect(
      () => capability.transitionTo(
        TrainCLiveRunPhase.pendingReview,
        expectedRevision: staleRevision,
      ),
      _code('TRAIN_C_STALE_STATE'),
    );
  });

  test('wrong reviewed head or base fails before runtime continuation', () {
    final capability = authorize().capability;
    expect(
      () => TrainCL1BPhaseController.forLive(
        capability: capability,
        reviewedHarnessHead: 'c000000000000000000000000000000000000000',
        reviewedBase: base,
      ),
      _code('TRAIN_C_HEAD_DRIFT'),
    );
    expect(
      () => TrainCL1BPhaseController.forLive(
        capability: capability,
        reviewedHarnessHead: head,
        reviewedBase: 'd000000000000000000000000000000000000000',
      ),
      _code('TRAIN_C_HEAD_DRIFT'),
    );
  });

  test('controller reattaches same durable runtime instead of creating B',
      () async {
    final authority = authorize();
    final controller = TrainCL1BPhaseController.forLive(
      capability: authority.capability,
      reviewedHarnessHead: head,
      reviewedBase: base,
    );
    TrainCIsolatedRuntime? first;
    TrainCIsolatedRuntime? second;
    addTearDown(() async {
      await second?.dispose();
      await first?.dispose();
    });
    final createdFirst = await controller.createOrReattachRuntime();
    first = createdFirst;
    final firstRoot = createdFirst.root.path;
    final firstDatabasePath = (await createdFirst.database).path;
    controller.markConfigured();
    await createdFirst.closeForRestart();
    await DatabaseHelper.resetRuntimeProfileForTesting();
    final recreated = TrainCLiveRunCapability.fromCapability(authority.token);
    final continuation = TrainCL1BPhaseController.forLive(
      capability: recreated,
      reviewedHarnessHead: head,
      reviewedBase: base,
    );
    final createdSecond = await continuation.reattachRuntime();
    second = createdSecond;
    expect(createdSecond.root.path, firstRoot);
    expect((await createdSecond.database).path, firstDatabasePath);
    await createdSecond.closeForRestart();
  });

  test('supervisor serializes fresh child phases and retains transient facts',
      () async {
    final started = <TrainCL1BChildPhase>[];
    Map<String, Object?>? finalFacts;
    var nextPid = 1000;
    final result = await TrainCL1BSupervisor.run(
      liveEnvironment: const <String, String>{'LIVE_ONLY': '1'},
      continuationEnvironment: const <String, String>{'CONTINUE_ONLY': '1'},
      startChild: (phase, environment) async {
        started.add(phase);
        final exit = Completer<int>();
        unawaited(Future<void>(() async {
          final client = TrainCL1BSupervisorClient.fromEnvironment(
            environment: environment,
          );
          if (phase == TrainCL1BChildPhase.finalize) {
            finalFacts = await client.requestFacts();
          }
          await client.reportPass(<String, Object?>{
            'safeCount': phase.index + 1,
          });
          exit.complete(0);
        }));
        return (
          pid: nextPid++,
          stdout: const Stream<List<int>>.empty(),
          stderr: const Stream<List<int>>.empty(),
          exitCode: exit.future,
          kill: () => true,
        );
      },
    );
    expect(result, 0);
    expect(started, TrainCL1BChildPhase.values);
    expect(finalFacts, contains(TrainCL1BChildPhase.parse.wireName));
    expect(finalFacts, contains(TrainCL1BChildPhase.commit.wireName));
    expect(finalFacts, contains(TrainCL1BChildPhase.restart.wireName));
  });

  test('reportPass waits for supervisor ACK before completing', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final requestSeen = Completer<void>();
    final subscription = server.listen((socket) async {
      try {
        await socket
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first;
        requestSeen.complete();
        await Future<void>.delayed(const Duration(milliseconds: 150));
        socket.writeln(jsonEncode(const <String, Object?>{'status': 'PASS'}));
        await socket.flush();
      } finally {
        await socket.close();
      }
    });
    addTearDown(() async {
      await subscription.cancel();
      await server.close();
    });

    final client = TrainCL1BSupervisorClient.fromEnvironment(
      environment: <String, String>{
        trainCL1BSupervisorPortEnvironment: server.port.toString(),
        trainCL1BSupervisorNonceEnvironment: 'test-nonce',
        trainCL1BChildPhaseEnvironment: TrainCL1BChildPhase.parse.wireName,
      },
    );
    var completed = false;
    final reportFuture = client
        .reportPass(const <String, Object?>{'safeCount': 1}).whenComplete(
            () => completed = true);

    await requestSeen.future.timeout(const Duration(seconds: 2));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(completed, isFalse);
    await reportFuture;
    expect(completed, isTrue);
  });

  test('supervisor preserves parse failure code and terminalizer callback',
      () async {
    var terminalizerCalls = 0;
    await expectLater(
      TrainCL1BSupervisor.run(
        liveEnvironment: const <String, String>{'LIVE_ONLY': '1'},
        continuationEnvironment: const <String, String>{'CONTINUE_ONLY': '1'},
        onParseFailure: () {
          terminalizerCalls++;
        },
        startChild: (phase, environment) async {
          final exit = Completer<int>();
          unawaited(Future<void>(() async {
            final client = TrainCL1BSupervisorClient.fromEnvironment(
              environment: environment,
            );
            await client.reportFailure('TRAIN_C_PROVIDER_SHAPE_MISMATCH');
            exit.complete(1);
          }));
          return (
            pid: 2000,
            stdout: const Stream<List<int>>.empty(),
            stderr: const Stream<List<int>>.empty(),
            exitCode: exit.future,
            kill: () => true,
          );
        },
      ),
      throwsA(
        predicate<TrainCL1BSupervisorException>(
          (error) => error.code == 'TRAIN_C_PROVIDER_SHAPE_MISMATCH',
        ),
      ),
    );
    expect(terminalizerCalls, 1);
  });

  test(
      'supervisor fails immediately with TRAIN_C_HARNESS_NOT_READY on child early exit without timeout',
      () async {
    final authority = authorize();
    final capability = authority.capability;
    expect(capability.snapshot.attemptState,
        TrainCLiveRunAttemptState.authorizedUnused);
    expect(capability.snapshot.phase, TrainCLiveRunPhase.prepared);
    expect(capability.snapshot.revision, 0);

    final stopwatch = Stopwatch()..start();
    await expectLater(
      TrainCL1BSupervisor.run(
        liveEnvironment: const <String, String>{'LIVE_ONLY': '1'},
        continuationEnvironment: const <String, String>{'CONTINUE_ONLY': '1'},
        onParseFailure: () {
          final state = capability.snapshot;
          if (state.attemptState == TrainCLiveRunAttemptState.consumed &&
              state.phase == TrainCLiveRunPhase.parseRunning) {
            capability.markFailedConsumed();
          }
        },
        startChild: (phase, environment) async {
          final exit = Completer<int>();
          exit.complete(1);
          return (
            pid: 2001,
            stdout: const Stream<List<int>>.empty(),
            stderr: const Stream<List<int>>.empty(),
            exitCode: exit.future,
            kill: () => true,
          );
        },
      ),
      throwsA(
        predicate<TrainCL1BSupervisorException>(
          (error) => error.code == 'TRAIN_C_HARNESS_NOT_READY',
        ),
      ),
    );
    stopwatch.stop();
    expect(stopwatch.elapsedMilliseconds, lessThan(2000));
    expect(capability.snapshot.attemptState,
        TrainCLiveRunAttemptState.authorizedUnused);
    expect(capability.snapshot.phase, TrainCLiveRunPhase.prepared);
    expect(capability.snapshot.revision, 0);
  });

  test(
      'child early exit with exitCode 0 without report fails immediately as HARNESS_NOT_READY',
      () async {
    final stopwatch = Stopwatch()..start();
    await expectLater(
      TrainCL1BSupervisor.run(
        liveEnvironment: const <String, String>{'LIVE_ONLY': '1'},
        continuationEnvironment: const <String, String>{'CONTINUE_ONLY': '1'},
        startChild: (phase, environment) async {
          final exit = Completer<int>();
          exit.complete(0);
          return (
            pid: 2002,
            stdout: const Stream<List<int>>.empty(),
            stderr: const Stream<List<int>>.empty(),
            exitCode: exit.future,
            kill: () => true,
          );
        },
      ),
      throwsA(
        predicate<TrainCL1BSupervisorException>(
          (error) => error.code == 'TRAIN_C_HARNESS_NOT_READY',
        ),
      ),
    );
    stopwatch.stop();
    expect(stopwatch.elapsedMilliseconds, lessThan(2000));
  });

  test('supervisor diagnostics are allowlisted and emitted once', () async {
    final diagnostics = <String>[];
    final privateChildOutput = utf8.encode(
      r'Failed reading D:\PrivateStudy\secret.pdf'
      '\n'
      'OCR_PRIVATE_TEXT=do-not-print-this\n'
      'Authorization: Bearer secret-auth-token-xyz\n'
      'providerBody=do-not-print-provider-body\n'
      'base64=ZXh0cmVtZWx5LXByaXZhdGU=',
    );

    await expectLater(
      TrainCL1BSupervisor.run(
        liveEnvironment: const <String, String>{'LIVE_ONLY': '1'},
        continuationEnvironment: const <String, String>{'CONTINUE_ONLY': '1'},
        diagnosticSink: diagnostics.add,
        startChild: (phase, environment) async {
          final exit = Completer<int>()..complete(1);
          return (
            pid: 2003,
            stdout: Stream<List<int>>.value(privateChildOutput),
            stderr: Stream<List<int>>.value(privateChildOutput),
            exitCode: exit.future,
            kill: () => true,
          );
        },
      ),
      throwsA(
        predicate<TrainCL1BSupervisorException>(
          (error) => error.code == 'TRAIN_C_HARNESS_NOT_READY',
        ),
      ),
    );

    expect(diagnostics, hasLength(1));
    final output = diagnostics.single;
    expect(output, contains('phase=parse'));
    expect(output, contains('category=CHILD_EARLY_EXIT'));
    expect(output, contains('reportReceived=false'));
    expect(output, contains('childExitCode=1'));
    expect(output, isNot(contains('[STDOUT]')));
    expect(output, isNot(contains('[STDERR]')));
    expect(output, isNot(contains('PrivateStudy')));
    expect(output, isNot(contains('OCR_PRIVATE_TEXT')));
    expect(output, isNot(contains('secret-auth-token-xyz')));
    expect(output, isNot(contains('providerBody')));
    expect(output, isNot(contains('ZXh0cmVtZWx5LXByaXZhdGU=')));
  });

  test('supervisor preserves one deadline across report and child exit',
      () async {
    var reportAcknowledged = false;
    final stopwatch = Stopwatch()..start();
    await expectLater(
      TrainCL1BSupervisor.run(
        liveEnvironment: const <String, String>{'LIVE_ONLY': '1'},
        continuationEnvironment: const <String, String>{'CONTINUE_ONLY': '1'},
        phaseTimeoutOverrideForTesting: const Duration(milliseconds: 1000),
        startChild: (phase, environment) async {
          final exit = Completer<int>();
          unawaited(Future<void>(() async {
            await Future<void>.delayed(const Duration(milliseconds: 400));
            final client = TrainCL1BSupervisorClient.fromEnvironment(
              environment: environment,
            );
            await client.reportPass(const <String, Object?>{'safeCount': 1});
            reportAcknowledged = true;
          }));
          return (
            pid: 2004,
            stdout: const Stream<List<int>>.empty(),
            stderr: const Stream<List<int>>.empty(),
            exitCode: exit.future,
            kill: () => true,
          );
        },
      ),
      throwsA(
        predicate<TrainCL1BSupervisorException>(
          (error) => error.code == 'TRAIN_C_HARNESS_NOT_READY',
        ),
      ),
    );
    stopwatch.stop();
    expect(reportAcknowledged, isTrue);
    expect(stopwatch.elapsedMilliseconds, lessThan(1250));
  });

  test(
      'supervisor maps startChild exception to TRAIN_C_HARNESS_NOT_READY when wrapped',
      () async {
    await expectLater(
      TrainCL1BSupervisor.run(
        liveEnvironment: const <String, String>{'LIVE_ONLY': '1'},
        continuationEnvironment: const <String, String>{'CONTINUE_ONLY': '1'},
        startChild: (phase, environment) async {
          throw const TrainCL1BSupervisorException('TRAIN_C_HARNESS_NOT_READY');
        },
      ),
      throwsA(
        predicate<TrainCL1BSupervisorException>(
          (error) => error.code == 'TRAIN_C_HARNESS_NOT_READY',
        ),
      ),
    );
  });

  test('completed request ledger survives supervisor handoff without replay',
      () {
    final ledger = TrainCRequestLedger();
    ledger.beginParse(expectedLayoutRequests: 1);
    final post = ledger.recordDispatchMethod('POST');
    ledger.recordResponse(eventIndex: post, statusCode: 200, durationMs: 1);
    final crop = ledger.recordDispatchMethod('GET');
    ledger.recordResponse(eventIndex: crop, statusCode: 200, durationMs: 1);
    ledger.finishParse(successful: true);
    final restored = TrainCRequestLedger.fromTransportSnapshot(
      ledger.transportSnapshot(),
    );
    expect(restored.phase, TrainCPhase.pendingReview);
    expect(restored.attemptConsumed, isTrue);
    expect(restored.layoutPostCount, 1);
    expect(restored.remoteCropRequestCount, 1);
    expect(restored.providerDispatchCount, 2);
    expect(restored.providerResponseCount, 2);
  });

  test('final PASS evidence publishes only after durable finalization', () {
    final authority = authorize();
    final evidenceFile = File(
      '${authority.directory.path}${Platform.pathSeparator}'
      'train_c_run_1_evidence.json',
    );
    final digestFile = File('${evidenceFile.path}.sha256');
    var finalized = false;

    publishTrainCSafeEvidenceAfterFinalization(
      attemptCapability: authority.token,
      evidence: const <String, dynamic>{'result': 'PASS'},
      finalizeDurably: () {
        expect(evidenceFile.existsSync(), isFalse);
        expect(digestFile.existsSync(), isFalse);
        finalized = true;
      },
    );

    expect(finalized, isTrue);
    expect(evidenceFile.existsSync(), isTrue);
    expect(digestFile.existsSync(), isTrue);
    final decoded = jsonDecode(evidenceFile.readAsStringSync());
    expect(decoded, isA<Map<String, dynamic>>());
    expect((decoded as Map<String, dynamic>)['result'], 'PASS');
  });

  test('failed durable finalization leaves no published PASS evidence', () {
    final authority = authorize();
    final evidenceFile = File(
      '${authority.directory.path}${Platform.pathSeparator}'
      'train_c_run_1_evidence.json',
    );
    final digestFile = File('${evidenceFile.path}.sha256');

    expect(
      () => publishTrainCSafeEvidenceAfterFinalization(
        attemptCapability: authority.token,
        evidence: const <String, dynamic>{'result': 'PASS'},
        finalizeDurably: () => throw const TrainCEvidenceProbeException(
          'TRAIN_C_STALE_STATE',
        ),
      ),
      _code('TRAIN_C_STALE_STATE'),
    );

    expect(evidenceFile.existsSync(), isFalse);
    expect(digestFile.existsSync(), isFalse);
    expect(File('${evidenceFile.path}.pending').existsSync(), isFalse);
    expect(File('${digestFile.path}.pending').existsSync(), isFalse);
  });

  test('same-parse source facts survive memory transport with raw hash intact',
      () {
    final source = TrainCSourceImageFacts(
      referencedImageCounts: const <int, int>{5: 1},
      referencedIdentitiesByQuestion: const <int, Set<(String, String)>>{
        5: <(String, String)>{('source-a', 'asset-a')},
      },
      orderedEvidence: const <TrainCPreTypedSourceImageEvidence>[
        TrainCPreTypedSourceImageEvidence(
          questionNumber: 5,
          sourceId: 'source-a',
          blockId: 'block-a',
          localAssetId: 'asset-a',
          contentHash: digest,
          readingOrder: 0,
        ),
      ],
    );
    final restored = decodeTrainCSourceImages(encodeTrainCSourceImages(source));
    expect(restored.countFor(5), 1);
    expect(
        restored.identitiesFor(5), <(String, String)>{('source-a', 'asset-a')});
    expect(restored.evidenceFor(5).single.contentHash, digest);
  });
}

Matcher _code(String expected) => throwsA(
      predicate<TrainCEvidenceProbeException>(
        (error) => error.code == expected,
      ),
    );

Matcher _protocol(String expected) => throwsA(
      predicate<TrainCProtocolException>(
        (error) => error.code == expected,
      ),
    );

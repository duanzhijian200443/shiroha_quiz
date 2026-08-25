import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';

import '../../tool/train_c_evidence_probe.dart';
import '../../tool/train_c_http_observer.dart';
import '../../tool/train_c_isolated_runtime.dart';
import '../../tool/train_c_l1b_phase_controller.dart';
import '../../tool/train_c_live_attempt_authority.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const head = 'a000000000000000000000000000000000000000';
  const base = 'b000000000000000000000000000000000000000';

  Directory createState() {
    final directory = Directory.systemTemp.createTempSync(
      'train_c_phase_controller_test_',
    );
    addTearDown(() {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });
    return directory;
  }

  ({String token, TrainCLiveRunCapability capability}) authorize() {
    final token = TrainCLiveRunCapability.authorize(
      stateDirectory: createState(),
      approvedHarnessHead: head,
      approvedBase: base,
    );
    final capability = TrainCLiveRunCapability.fromCapability(token);
    capability.verifyUnused(reviewedHarnessHead: head);
    return (token: token, capability: capability);
  }

  void bindAndConfigure(TrainCLiveRunCapability capability) {
    capability.bindRuntimeCapability('runtime-a');
    capability.markConfigured();
  }

  test('runtime identity survives recreation and rejects a different runtime',
      () {
    final authority = authorize();
    final capability = authority.capability;
    bindAndConfigure(capability);

    final recreated = TrainCLiveRunCapability.fromCapability(
      authority.token,
    );
    expect(recreated.runtimeMatches('runtime-a'), isTrue);
    expect(recreated.runtimeMatches('runtime-b'), isFalse);
    expect(recreated.snapshot.runtimeBound, isTrue);
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
        capability.snapshot.attemptState, TrainCLiveRunAttemptState.consumed);

    final recreated = TrainCLiveRunCapability.fromCapability(
      authority.token,
    );
    expect(
      () => recreated.verifyUnused(reviewedHarnessHead: head),
      _code('TRAIN_C_ATTEMPT_BUDGET_EXHAUSTED'),
    );
    expect(
      () => TrainCRequestLedger(providerDisabled: true)
          .recordDispatchMethod('POST'),
      _protocol('TRAIN_C_PROVIDER_REQUEST_COUNT_FAILURE'),
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

    final recreated = TrainCLiveRunCapability.fromCapability(
      authority.token,
    );
    final controller = TrainCL1BPhaseController.forContinuation(
      capability: recreated,
      reviewedHarnessHead: head,
    );
    controller.requireProviderForbidden();
    expect(recreated.snapshot.phase, TrainCLiveRunPhase.pendingReview);
    expect(
      () => TrainCRequestLedger(providerDisabled: true)
          .recordDispatchMethod('GET'),
      _protocol('TRAIN_C_PROVIDER_REQUEST_COUNT_FAILURE'),
    );
  });

  test('stale revision cannot advance a phase after another writer commits',
      () {
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
    expect(capability.snapshot.phase, TrainCLiveRunPhase.parseRunning);
  });

  test('wrong reviewed head fails before runtime or provider continuation', () {
    final capability = authorize().capability;
    expect(
      () => TrainCL1BPhaseController.forLive(
        capability: capability,
        reviewedHarnessHead: 'c000000000000000000000000000000000000000',
      ),
      _code('TRAIN_C_HEAD_DRIFT'),
    );
  });

  test('controller reattaches the same durable runtime instead of creating B',
      () async {
    final authority = authorize();
    final controller = TrainCL1BPhaseController.forLive(
      capability: authority.capability,
      reviewedHarnessHead: head,
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
    final continuationController = TrainCL1BPhaseController.forLive(
      capability: recreated,
      reviewedHarnessHead: head,
    );
    final createdSecond = await continuationController.reattachRuntime();
    second = createdSecond;
    expect(createdSecond.root.path, firstRoot);
    expect((await createdSecond.database).path, firstDatabasePath);
    expect(continuationController.status.runtimeBound, isTrue);
    await createdSecond.closeForRestart();
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

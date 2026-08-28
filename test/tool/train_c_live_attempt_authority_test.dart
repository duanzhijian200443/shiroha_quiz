import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/train_c_evidence_probe.dart';
import '../../tool/train_c_http_observer.dart';
import '../../tool/train_c_live_entrypoint.dart';
import '../../tool/train_c_live_attempt_authority.dart';
import '../../tool/train_c_l1b_review_authorization.dart';
import '../../tool/train_c_review_authorization.dart';

void main() {
  const head = 'a000000000000000000000000000000000000000';
  const base = 'b000000000000000000000000000000000000000';

  Directory createState(String prefix) {
    final directory = Directory.systemTemp.createTempSync(prefix);
    addTearDown(() {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });
    return directory;
  }

  test('historical Run 1 authorization remains prepared and unused', () {
    final directory = createState('train_c_run1_authority_test_');
    final token = TrainCLiveRunCapability.authorize(
      stateDirectory: directory,
      approvedHarnessHead: head,
      approvedBase: base,
    );

    final snapshot = TrainCLiveRunCapability.fromCapability(token).snapshot;
    expect(snapshot.runNumber, 1);
    expect(snapshot.attemptState, TrainCLiveRunAttemptState.authorizedUnused);
    expect(snapshot.phase, TrainCLiveRunPhase.prepared);
    expect(snapshot.runtimeIdentity, isNull);

    final decoded = Map<String, Object?>.from(
      jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(token))),
      ) as Map,
    )..remove('runNumber');
    final historicalToken = base64Url.encode(utf8.encode(jsonEncode(decoded)));
    expect(
      TrainCLiveRunCapability.fromCapability(historicalToken)
          .snapshot
          .runNumber,
      1,
    );
  });

  test('Run 2 authorization creates only prepared unused durable state', () {
    final directory = createState('train_c_run2_authority_test_');
    final token = TrainCLiveRunCapability.authorize(
      stateDirectory: directory,
      approvedHarnessHead: head,
      approvedBase: base,
      runNumber: 2,
    );
    final authority = TrainCLiveRunCapability.fromCapability(token);

    authority.verifyUnused(reviewedHarnessHead: head, reviewedBase: base);
    final safeStatus = authority.safeStatus(
      reviewedHarnessHead: head,
      reviewedBase: base,
    );
    expect(safeStatus['runNumber'], 2);
    expect(safeStatus['attemptState'], 'AUTHORIZED_UNUSED');
    expect(safeStatus['phase'], 'PREPARED');
    expect(safeStatus['runtimeIdentityPreserved'], isFalse);
    expect(safeStatus, isNot(contains('runtimeCapability')));
    expect(authority.snapshot.attemptState,
        TrainCLiveRunAttemptState.authorizedUnused);
    expect(authority.snapshot.phase, TrainCLiveRunPhase.prepared);
    expect(authority.snapshot.runtimeIdentity, isNull);
    expect(authority.snapshot.runtimeBound, isFalse);
  });

  test('capability run binding cannot masquerade Run 1 as Run 2', () {
    final directory = createState('train_c_run_binding_test_');
    final token = TrainCLiveRunCapability.authorize(
      stateDirectory: directory,
      approvedHarnessHead: head,
      approvedBase: base,
    );
    final decoded = Map<String, Object?>.from(
      jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(token))),
      ) as Map,
    )..['runNumber'] = 2;
    final tamperedToken = base64Url.encode(utf8.encode(jsonEncode(decoded)));

    expect(
      () => TrainCLiveRunCapability.fromCapability(tamperedToken),
      _code('TRAIN_C_PROVIDER_ENVIRONMENT_BLOCKED'),
    );
    expect(
      TrainCLiveRunCapability.fromCapability(token).snapshot.runNumber,
      1,
    );
  });

  test('authorization rejects every unsupported run number', () {
    for (final runNumber in <int>[0, 3, -1]) {
      final directory = createState('train_c_illegal_run_test_');
      expect(
        () => TrainCLiveRunCapability.authorize(
          stateDirectory: directory,
          approvedHarnessHead: head,
          approvedBase: base,
          runNumber: runNumber,
        ),
        _code('TRAIN_C_HARNESS_NOT_READY'),
      );
      expect(directory.listSync(), isEmpty);
    }
  });

  test('Run 2 authorization cannot reuse Run 1 state directory', () {
    final directory = createState('train_c_run_directory_reuse_test_');
    final run1 = TrainCLiveRunCapability.authorize(
      stateDirectory: directory,
      approvedHarnessHead: head,
      approvedBase: base,
    );
    final before = TrainCLiveRunCapability.fromCapability(run1).snapshot;

    expect(
      () => TrainCLiveRunCapability.authorize(
        stateDirectory: directory,
        approvedHarnessHead: head,
        approvedBase: base,
        runNumber: 2,
      ),
      _code('TRAIN_C_ISOLATION_FAILURE'),
    );
    final after = TrainCLiveRunCapability.fromCapability(run1).snapshot;
    expect(after.runNumber, before.runNumber);
    expect(after.revision, before.revision);
    expect(after.attemptState, before.attemptState);
  });

  test('Run 2 authorization cannot reuse consumed Run 1 directory', () {
    final directory = createState('train_c_consumed_directory_reuse_test_');
    final run1 = TrainCLiveRunCapability.authorize(
      stateDirectory: directory,
      approvedHarnessHead: head,
      approvedBase: base,
    );
    final authority = TrainCLiveRunCapability.fromCapability(run1)
      ..verifyUnused(reviewedHarnessHead: head, reviewedBase: base)
      ..bindRuntimeCapability('runtime-a')
      ..markConfigured()
      ..markParseRunning()
      ..consumeAtDispatch();
    expect(authority.snapshot.attemptState, TrainCLiveRunAttemptState.consumed);

    expect(
      () => TrainCLiveRunCapability.authorize(
        stateDirectory: directory,
        approvedHarnessHead: head,
        approvedBase: base,
        runNumber: 2,
      ),
      _code('TRAIN_C_ISOLATION_FAILURE'),
    );
    expect(authority.snapshot.runNumber, 1);
    expect(authority.snapshot.attemptState, TrainCLiveRunAttemptState.consumed);
  });

  test('Run 1 and Run 2 directories remain independent', () {
    final run1Directory = createState('train_c_independent_run1_test_');
    final run2Directory = createState('train_c_independent_run2_test_');
    final run1 = TrainCLiveRunCapability.authorize(
      stateDirectory: run1Directory,
      approvedHarnessHead: head,
      approvedBase: base,
    );
    final run1FilesBefore = run1Directory
        .listSync()
        .map((entity) => entity.uri.pathSegments.last)
        .toList();

    final run2 = TrainCLiveRunCapability.authorize(
      stateDirectory: run2Directory,
      approvedHarnessHead: head,
      approvedBase: base,
      runNumber: 2,
    );

    expect(
      run1Directory
          .listSync()
          .map((entity) => entity.uri.pathSegments.last)
          .toList(),
      run1FilesBefore,
    );
    expect(TrainCLiveRunCapability.fromCapability(run1).snapshot.runNumber, 1);
    expect(TrainCLiveRunCapability.fromCapability(run2).snapshot.runNumber, 2);
  });

  test('Run 2 shares consumed-state rejection with Run 1', () {
    final directory = createState('train_c_run2_consumption_test_');
    final token = TrainCLiveRunCapability.authorize(
      stateDirectory: directory,
      approvedHarnessHead: head,
      approvedBase: base,
      runNumber: 2,
    );
    final authority = TrainCLiveRunCapability.fromCapability(token)
      ..verifyUnused(reviewedHarnessHead: head, reviewedBase: base)
      ..bindRuntimeCapability('runtime-b')
      ..markConfigured()
      ..markParseRunning()
      ..consumeAtDispatch();

    expect(
      () => authority.verifyUnused(
        reviewedHarnessHead: head,
        reviewedBase: base,
      ),
      _code('TRAIN_C_ATTEMPT_BUDGET_EXHAUSTED'),
    );
  });

  test('entrypoint authorizes distinct Run 1 and Run 2 capabilities', () {
    for (final runNumber in <int>[1, 2]) {
      final directory = createState('train_c_entrypoint_run${runNumber}_test_');
      final marker = TrainCLiveEntrypoint.authorizeFromArgs(
        <String>['--authorize-run$runNumber'],
        environment: <String, String>{
          trainCApprovedHarnessHeadEnvironment: head,
          trainCL1BApprovedBaseEnvironment: base,
          trainCAttemptStateDirectoryEnvironment: directory.path,
        },
      );
      final token = File(
        '${directory.path}${Platform.pathSeparator}capability.v1',
      ).readAsStringSync();
      final snapshot = TrainCLiveRunCapability.fromCapability(token).snapshot;

      expect(marker, 'TRAIN_C_RUN${runNumber}_AUTHORIZED');
      expect(snapshot.runNumber, runNumber);
      expect(snapshot.attemptState, TrainCLiveRunAttemptState.authorizedUnused);
      expect(snapshot.phase, TrainCLiveRunPhase.prepared);
      expect(snapshot.runtimeIdentity, isNull);
    }
  });

  test('PowerShell wrapper exposes an exclusive Run 2 authorization mode', () {
    final source =
        File('tool/run_train_c_live_acceptance.ps1').readAsStringSync();

    expect(source, contains('[switch]\$AuthorizeRun2'));
    expect(
      source,
      contains(
        '@(\$Preflight, \$AuthorizeRun1, \$AuthorizeRun2, \$Live, '
        '\$Continue, \$Status)',
      ),
    );
    expect(source, contains('elseif (\$AuthorizeRun2)'));
    expect(
      source,
      contains(
        '& dart run tool/train_c_live_entrypoint.dart --authorize-run2',
      ),
    );
  });

  test('one Run permits multiple requests but relaunch stays one-shot', () {
    final directory = Directory.systemTemp.createTempSync(
      'train_c_attempt_authority_test_',
    );
    addTearDown(() => directory.deleteSync(recursive: true));

    final capability = TrainCLiveAttemptAuthority.authorize(
      stateDirectory: directory,
      approvedHarnessHead: head,
      approvedBase: base,
    );
    final first = TrainCLiveAttemptAuthority.fromCapability(capability);
    first.verifyUnused(reviewedHarnessHead: head);
    first.bindRuntimeCapability('runtime-a');
    first.markConfigured();

    final ledger = TrainCRequestLedger(attemptAuthority: first);
    ledger.beginParse(expectedLayoutRequests: 2);

    ledger.recordDispatchMethod('POST');
    expect(ledger.attemptConsumed, isTrue);
    expect(first.snapshot.attemptState, TrainCLiveRunAttemptState.consumed);

    // These are additional legitimate requests within the same top-level Run,
    // not a second Run. They must not try to consume durable authority again.
    ledger.recordDispatchMethod('POST');
    ledger.recordDispatchMethod('GET');
    ledger.recordDispatchMethod('GET');
    expect(ledger.layoutPostCount, 2);
    expect(ledger.remoteCropRequestCount, 2);
    expect(ledger.providerDispatchCount, 4);

    final files = directory.listSync().whereType<File>().toList();
    expect(
        files.where((file) => file.path.contains('authorized.json')), isEmpty);
    expect(files.where((file) => file.path.contains('consumed.v1')), isEmpty);
    expect(
      files
          .where(
            (file) => file.uri.pathSegments.last.startsWith('run_capability.'),
          )
          .length,
      5,
    );

    // A fresh authority/ledger cannot reinterpret the consumed Run as another
    // top-level live parse.
    final recreated = TrainCLiveAttemptAuthority.fromCapability(capability);
    expect(
      () => recreated.verifyUnused(reviewedHarnessHead: head),
      throwsA(
        predicate<TrainCEvidenceProbeException>(
          (error) => error.code == 'TRAIN_C_ATTEMPT_BUDGET_EXHAUSTED',
        ),
      ),
    );
    expect(
      () => recreated.consumeAtDispatch(),
      throwsA(
        predicate<TrainCEvidenceProbeException>(
          (error) => error.code == 'TRAIN_C_ATTEMPT_BUDGET_EXHAUSTED',
        ),
      ),
    );
  });

  test('authority failure blocks dispatch before the ledger increments', () {
    final directory = Directory.systemTemp.createTempSync(
      'train_c_attempt_authority_block_test_',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final capability = TrainCLiveAttemptAuthority.authorize(
      stateDirectory: directory,
      approvedHarnessHead: head,
      approvedBase: base,
    );
    final authority = TrainCLiveAttemptAuthority.fromCapability(capability);
    authority.verifyUnused(reviewedHarnessHead: head);
    authority.bindRuntimeCapability('runtime-a');
    authority.markConfigured();
    authority.markParseRunning();
    authority.consumeAtDispatch();

    final ledger = TrainCRequestLedger(attemptAuthority: authority);
    expect(
      () => ledger.beginParse(expectedLayoutRequests: 1),
      throwsA(
        predicate<TrainCEvidenceProbeException>(
          (error) => error.code == 'TRAIN_C_ATTEMPT_BUDGET_EXHAUSTED',
        ),
      ),
    );
    expect(ledger.providerDispatchCount, 0);
  });
}

Matcher _code(String expected) => throwsA(
      predicate<TrainCEvidenceProbeException>(
        (error) => error.code == expected,
      ),
    );

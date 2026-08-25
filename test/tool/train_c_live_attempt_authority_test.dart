import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/train_c_evidence_probe.dart';
import '../../tool/train_c_http_observer.dart';
import '../../tool/train_c_live_attempt_authority.dart';

void main() {
  const head = 'a000000000000000000000000000000000000000';
  const base = 'b000000000000000000000000000000000000000';

  test('authorization survives recreation and consumption is one-shot', () {
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
    ledger.beginParse(expectedLayoutRequests: 1);
    ledger.recordDispatchMethod('POST');
    expect(ledger.providerDispatchCount, 1);
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

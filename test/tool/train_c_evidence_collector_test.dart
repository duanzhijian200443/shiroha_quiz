import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/train_c_evidence_collector.dart';
import '../../tool/train_c_evidence_probe.dart';

void main() {
  test('trusted collector is the only seam that can authorize final PASS',
      () async {
    final expected = TrainCExpectedCodeIdentity.forCurrentRepository();
    final probe = TrainCEvidenceProbe(expectedIdentity: expected);
    final source = _SyntheticTrustedSource(_validSnapshot(expected));

    final external = probe.inspect(_validSnapshot(expected));
    expect(external.schemaValid, isTrue);
    expect(external.acceptanceAuthorized, isFalse);
    expect(external.evidence['result'], 'SCHEMA_VALID');
    expect(external.evidence['authority'], 'schema_validator_only');

    final result = await TrainCTrustedEvidenceCollector(
      probe,
      executionStateGate: const _FakeExecutionStateGate(),
    ).collect(source);
    expect(result.schemaValid, isTrue);
    expect(result.acceptanceAuthorized, isTrue);
    expect(result.evidence['authority'], 'trusted_collector');
    expect(result.evidence['result'], 'PASS');
  });

  test('trusted collector blocks a source without OS-process restart proof',
      () async {
    final expected = TrainCExpectedCodeIdentity.forCurrentRepository();
    final probe = TrainCEvidenceProbe(expectedIdentity: expected);
    final result = await TrainCTrustedEvidenceCollector(
      probe,
      executionStateGate: const _FakeExecutionStateGate(),
    ).collect(
      _SyntheticTrustedSource(
        _validSnapshot(expected),
        processRestartVerified: false,
      ),
    );

    expect(result.schemaValid, isTrue);
    expect(result.acceptanceAuthorized, isFalse);
    expect(result.evidence['authority'], 'trusted_collector_blocked');
    expect(result.evidence['failureCode'], 'TRAIN_C_RESTART_FAILURE');
    expect(result.evidence['firstLoss'], <String, dynamic>{
      'status': 'PROVEN',
      'checkpoint': 'P12',
    });
  });

  test('trusted collector recomputes request count with production chunk',
      () async {
    final expected = TrainCExpectedCodeIdentity.forCurrentRepository();
    final probe = TrainCEvidenceProbe(expectedIdentity: expected);
    final snapshot = _validSnapshot(expected);
    (snapshot['input'] as Map<String, dynamic>)['pageCount'] = 25;
    final attempt = snapshot['attempt'] as Map<String, dynamic>;
    attempt['layoutChunkSize'] = 20;
    attempt['layoutPostCount'] = 2;
    attempt['expectedLayoutRequestCount'] = 2;
    attempt['providerDispatchCount'] = 2;
    attempt['providerResponseCount'] = 2;

    final result = await TrainCTrustedEvidenceCollector(
      probe,
      executionStateGate: const _FakeExecutionStateGate(),
    ).collect(_SyntheticTrustedSource(snapshot));

    expect(result.schemaValid, isFalse);
    expect(result.acceptanceAuthorized, isFalse);
    expect(
      result.evidence['failureCode'],
      'TRAIN_C_PROVIDER_REQUEST_COUNT_FAILURE',
    );
  });

  test('blocks a dirty worktree without changing schema validity', () async {
    final expected = TrainCExpectedCodeIdentity.forCurrentRepository();
    final probe = TrainCEvidenceProbe(expectedIdentity: expected);
    final result = await TrainCTrustedEvidenceCollector(
      probe,
      executionStateGate: const _FakeExecutionStateGate(
        failureCode: 'TRAIN_C_DIRTY_WORKTREE',
      ),
    ).collect(_SyntheticTrustedSource(_validSnapshot(expected)));

    expect(result.schemaValid, isTrue);
    expect(result.acceptanceAuthorized, isFalse);
    expect(result.evidence['authority'], 'trusted_collector_blocked');
    expect(result.evidence['result'], 'AUTHORIZATION_BLOCKED');
    expect(result.evidence['failureCode'], 'TRAIN_C_DIRTY_WORKTREE');
    expect(result.evidence['firstLoss'], <String, dynamic>{
      'status': 'PROVEN',
      'checkpoint': 'P0',
    });
    expect(jsonEncode(result.evidence), isNot(contains('modified-file.dart')));
  });

  test('maps an unreadable repository state to a fixed safe failure', () async {
    final expected = TrainCExpectedCodeIdentity.forCurrentRepository();
    final probe = TrainCEvidenceProbe(expectedIdentity: expected);
    final result = await TrainCTrustedEvidenceCollector(
      probe,
      executionStateGate: const _FakeExecutionStateGate(
        throwUnexpectedError: true,
      ),
    ).collect(_SyntheticTrustedSource(_validSnapshot(expected)));

    expect(result.schemaValid, isTrue);
    expect(result.acceptanceAuthorized, isFalse);
    expect(result.evidence['authority'], 'trusted_collector_blocked');
    expect(result.evidence['result'], 'AUTHORIZATION_BLOCKED');
    expect(result.evidence['failureCode'], 'TRAIN_C_CODE_IDENTITY_MISMATCH');
    expect(result.evidence['firstLoss'], <String, dynamic>{
      'status': 'PROVEN',
      'checkpoint': 'P0',
    });
    expect(
      jsonEncode(result.evidence),
      isNot(contains('private repository state')),
    );
  });
}

final class _FakeExecutionStateGate implements TrainCExecutionStateGate {
  const _FakeExecutionStateGate({
    this.failureCode,
    this.throwUnexpectedError = false,
  });

  final String? failureCode;
  final bool throwUnexpectedError;

  @override
  void verify() {
    if (throwUnexpectedError) {
      throw StateError('private repository state');
    }
    final code = failureCode;
    if (code != null) {
      throw TrainCEvidenceProbeException(code);
    }
  }
}

final class _SyntheticTrustedSource implements TrainCTrustedEvidenceSource {
  _SyntheticTrustedSource(
    this.snapshot, {
    this.processRestartVerified = true,
  });

  final Map<String, dynamic> snapshot;
  final bool processRestartVerified;

  @override
  Future<Map<String, dynamic>> readAuthoritativeSnapshot() async => snapshot;
}

Map<String, dynamic> _validSnapshot(TrainCExpectedCodeIdentity expected) {
  return <String, dynamic>{
    'schemaVersion': 3,
    'runNumber': 1,
    'code': <String, dynamic>{
      'productionHead': expected.productionHead,
      'harnessHead': expected.harnessHead,
      'trainBMergeCommit': expected.trainBMergeCommit,
      'currentHead': expected.approvedHarnessHead.isEmpty
          ? expected.harnessHead
          : expected.approvedHarnessHead,
      'approvedHarnessHead': expected.approvedHarnessHead.isEmpty
          ? expected.harnessHead
          : expected.approvedHarnessHead,
      'approvedBase': expected.approvedBase.isEmpty
          ? 'f1d58a278180eff38686338c28f26e4d1d7b8b7a'
          : expected.approvedBase,
      'approvedProductionBase': expected.approvedProductionBase.isEmpty
          ? expected.productionHead
          : expected.approvedProductionBase,
      'productionDiffFromBase': 0,
    },
    'input': <String, dynamic>{
      'sha256': List<String>.filled(64, 'd').join(),
      'sizeBytes': 1024,
      'pageCount': 22,
    },
    'attempt': <String, dynamic>{
      'consumed': true,
      'layoutPostCount': 1,
      'layoutChunkSize': 30,
      'expectedLayoutRequestCount': 1,
      'providerDispatchCount': 1,
      'providerResponseCount': 1,
      'remoteCropRequestCount': 0,
      'unexpectedProviderRequestCount': 0,
      'networkFailureCount': 0,
    },
    'safety': <String, dynamic>{
      'layoutResponsePolicyActive': true,
      'documentImageBudgetPolicyActive': true,
      'resourceFailure': false,
      'candidateCleanupPending': false,
    },
    'parse': <String, dynamic>{
      'status': 'PASS',
      'blockCount': 22,
      'imageBlockCount': 3,
      'tableBlockCount': 0,
      'assembledQuestionCount': 22,
      'finalQuestionCount': 22,
      'warningCount': 0,
    },
    'numbering': <String, dynamic>{
      'questionCount': 22,
      'questionNumbers': List<int>.generate(22, (index) => index + 1),
      'exactSet1To22': true,
    },
    'typed': <String, dynamic>{
      'storageRoute': 'typedV2',
      'storageReason': 'typed_candidate_ready',
      'typedCount': 22,
      'validEnvelopeCount': 22,
    },
    'imageSummary': <String, dynamic>{
      'referencedImageBlockCount': 3,
      'typedImageNodeCount': 3,
      'referencedUniqueAssetCount': 3,
      'typedUniqueAssetCount': 3,
      'resolvedUniqueAssetCount': 3,
      'allReachableResolved': true,
      'canonicalIdentityPreserved': true,
    },
    'mandatoryQuestions': <String, dynamic>{
      '5': _mandatoryQuestion(),
      '18': _mandatoryQuestion(),
      '19': _mandatoryQuestion(),
    },
    'commit': <String, dynamic>{
      'status': 'PASS',
      'questionRows': 22,
      'v2Sidecars': 22,
      'legacyWriterCalls': 0,
      'candidateCleanupPending': false,
    },
    'restart': <String, dynamic>{
      'status': 'PASS',
      'questionCount': 22,
      'typedAuthorityPreserved': true,
      'allReachableResolved': true,
      'providerDispatchCount': 0,
    },
    'backupRestore': <String, dynamic>{
      'packageVersion': 2,
      'schemaVersion': 23,
      'backupStatus': 'PASS',
      'restoreStatus': 'PASS',
      'restoredQuestionCount': 22,
      'restoredV2Sidecars': 22,
      'reachableAssetCount': 3,
      'backupManifestAssetCount': 3,
      'restoredAssetCount': 3,
      'manifestMatchesReachableAssets': true,
      'restoredIdentityPreserved': true,
      'allReachableResolved': true,
      'providerDispatchCount': 0,
    },
    'tableLiveCoverage': 'NOT PRESENT',
    'tableSummary': <String, dynamic>{
      'referencedTableBlockCount': 0,
      'typedTableNodeCount': 0,
      'tableContractConformant': true,
    },
  };
}

Map<String, dynamic> _mandatoryQuestion() {
  return <String, dynamic>{
    'referencedImageCount': 1,
    'sourceReferencedImageCount': 1,
    'typedImageNodeCount': 1,
    'referencedUniqueAssetCount': 1,
    'sourceReferencedUniqueAssetCount': 1,
    'resolvedUniqueAssetCount': 1,
    'sourceIdentityPreserved': true,
    'canonicalIdentityPreserved': true,
    'commitPreserved': true,
    'restartResolution': true,
    'restartRender': true,
    'b0RestoreResolution': true,
    'b0RestoreRender': true,
  };
}

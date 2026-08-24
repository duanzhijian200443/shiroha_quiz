import 'package:flutter_test/flutter_test.dart';

import '../../tool/train_c_evidence_collector.dart';
import '../../tool/train_c_evidence_probe.dart';

void main() {
  test('synthetic schema input cannot authorize final PASS', () {
    final expected = TrainCExpectedCodeIdentity.forCurrentRepository();
    final source = _SyntheticTrustedSource(_validSnapshot(expected));
    final result = TrainCTrustedEvidenceCollector(
      reviewedIdentity: _reviewed(expected),
    ).inspectSchema(source.snapshot);
    expect(result.schemaValid, isTrue);
    expect(result.acceptanceAuthorized, isFalse);
    expect(result.evidence['authority'], 'schema_validator_only');
    expect(result.evidence['result'], 'SCHEMA_VALID');
  });

  test('synthetic boolean restart metadata cannot authorize final PASS', () {
    final expected = TrainCExpectedCodeIdentity.forCurrentRepository();
    final source = _SyntheticTrustedSource(
      _validSnapshot(expected),
      processRestartVerified: true,
    );
    expect(source.processRestartVerified, isTrue);
    final result = TrainCTrustedEvidenceCollector(
      reviewedIdentity: _reviewed(expected),
    ).inspectSchema(source.snapshot);
    expect(result.schemaValid, isTrue);
    expect(result.acceptanceAuthorized, isFalse);
    expect(result.evidence['authority'], 'schema_validator_only');
  });

  test('trusted collector recomputes request count with production chunk', () {
    final expected = TrainCExpectedCodeIdentity.forCurrentRepository();
    final snapshot = _validSnapshot(expected);
    (snapshot['input'] as Map<String, dynamic>)['pageCount'] = 25;
    final attempt = snapshot['attempt'] as Map<String, dynamic>;
    attempt['layoutChunkSize'] = 20;
    attempt['layoutPostCount'] = 2;
    attempt['expectedLayoutRequestCount'] = 2;
    attempt['providerDispatchCount'] = 2;
    attempt['providerResponseCount'] = 2;

    final result = TrainCTrustedEvidenceCollector(
      reviewedIdentity: _reviewed(expected),
    ).inspectSchema(snapshot);

    expect(result.schemaValid, isFalse);
    expect(result.acceptanceAuthorized, isFalse);
    expect(
      result.evidence['failureCode'],
      'TRAIN_C_PROVIDER_REQUEST_COUNT_FAILURE',
    );
  });

  test('synthetic extra metadata fails with a fixed privacy category', () {
    final expected = TrainCExpectedCodeIdentity.forCurrentRepository();
    final snapshot = _validSnapshot(expected)
      ..['privateMetadata'] = 'private repository state';
    expect(
      () => TrainCTrustedEvidenceCollector(
        reviewedIdentity: _reviewed(expected),
      ).inspectSchema(snapshot),
      throwsA(
        isA<TrainCEvidenceProbeException>().having(
          (error) => error.code,
          'code',
          'TRAIN_C_PRIVACY_FAILURE',
        ),
      ),
    );
  });
}

final class _SyntheticTrustedSource {
  _SyntheticTrustedSource(
    this.snapshot, {
    this.processRestartVerified = true,
  });

  final Map<String, dynamic> snapshot;
  final bool processRestartVerified;
}

TrainCReviewedIdentity _reviewed(TrainCExpectedCodeIdentity expected) {
  return TrainCReviewedIdentity(
    approvedHarnessHead: expected.approvedHarnessHead.isEmpty
        ? expected.harnessHead
        : expected.approvedHarnessHead,
    approvedBase: expected.approvedBase.isEmpty
        ? 'f1d58a278180eff38686338c28f26e4d1d7b8b7a'
        : expected.approvedBase,
    approvedProductionBase: expected.approvedProductionBase.isEmpty
        ? expected.productionHead
        : expected.approvedProductionBase,
  );
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

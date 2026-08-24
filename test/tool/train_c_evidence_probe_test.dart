import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/train_c_evidence_probe.dart';

void main() {
  test('accepts a complete safe schema without granting live authority', () {
    final expected = TrainCExpectedCodeIdentity.forCurrentRepository();
    final result = TrainCEvidenceProbe(expectedIdentity: expected).inspect(
      _validSnapshot(expected),
    );

    expect(result.schemaValid, isTrue);
    expect(result.acceptanceAuthorized, isFalse);
    expect(result.evidence['result'], 'SCHEMA_VALID');
    expect(result.evidence['authority'], 'schema_validator_only');
    expect(result.evidence['failureCode'], isNull);
    expect(
      result.evidence['numbering']['questionNumbers'],
      List<int>.generate(22, (index) => index + 1),
    );
    expect(jsonEncode(result.evidence), isNot(contains('provider.example')));
    expect(jsonEncode(result.evidence), isNot(contains('PRIVATE')));
  });

  test('rejects unknown privacy-bearing keys before projection', () {
    final expected = TrainCExpectedCodeIdentity.forCurrentRepository();
    final snapshot = _validSnapshot(expected)
      ..['providerUrl'] = 'https://provider.example';

    expect(
      () => TrainCEvidenceProbe(expectedIdentity: expected).inspect(snapshot),
      throwsA(
        isA<TrainCEvidenceProbeException>().having(
          (error) => error.code,
          'code',
          'TRAIN_C_PRIVACY_FAILURE',
        ),
      ),
    );
  });

  test('rejects raw source identity fields in nested safe sections', () {
    final expected = TrainCExpectedCodeIdentity.forCurrentRepository();
    final snapshot = _validSnapshot(expected);
    final images = snapshot['imageSummary'] as Map<String, dynamic>;
    images['sourceId'] = 'private-source';

    expect(
      () => TrainCEvidenceProbe(expectedIdentity: expected).inspect(snapshot),
      throwsA(
        isA<TrainCEvidenceProbeException>().having(
          (error) => error.code,
          'code',
          'TRAIN_C_PRIVACY_FAILURE',
        ),
      ),
    );
  });

  test('returns a fixed first-loss code for typed route failure', () {
    final expected = TrainCExpectedCodeIdentity.forCurrentRepository();
    final snapshot = _validSnapshot(expected);
    (snapshot['typed'] as Map<String, dynamic>)['storageRoute'] = 'legacyV1';

    final result = TrainCEvidenceProbe(expectedIdentity: expected).inspect(
      snapshot,
    );

    expect(result.schemaValid, isFalse);
    expect(result.acceptanceAuthorized, isFalse);
    expect(result.evidence['result'], 'SCHEMA_INVALID');
    expect(result.evidence['failureCode'], 'TRAIN_C_TYPED_ROUTE_FAILURE');
    expect(result.evidence['firstLoss'], <String, dynamic>{
      'status': 'PROVEN',
      'checkpoint': 'P8',
    });
  });

  test('reports cleanup pending as a lifecycle failure', () {
    final expected = TrainCExpectedCodeIdentity.forCurrentRepository();
    final snapshot = _validSnapshot(expected);
    (snapshot['safety'] as Map<String, dynamic>)['candidateCleanupPending'] =
        true;

    final result = TrainCEvidenceProbe(expectedIdentity: expected).inspect(
      snapshot,
    );

    expect(result.schemaValid, isFalse);
    expect(result.evidence['failureCode'], 'TRAIN_C_CANDIDATE_CLEANUP_PENDING');
    expect(result.evidence['firstLoss'], <String, dynamic>{
      'status': 'PROVEN',
      'checkpoint': 'P9',
    });
  });

  test('rejects image first-loss instead of accepting a partial typed set', () {
    final expected = TrainCExpectedCodeIdentity.forCurrentRepository();
    final snapshot = _validSnapshot(expected);
    final images = snapshot['imageSummary'] as Map<String, dynamic>;
    images['typedImageNodeCount'] = 3;
    images['referencedImageBlockCount'] = 5;

    final result = TrainCEvidenceProbe(expectedIdentity: expected).inspect(
      snapshot,
    );

    expect(result.schemaValid, isFalse);
    expect(result.evidence['failureCode'], 'TRAIN_C_IMAGE_CLOSURE_FAILURE');
  });

  test('rejects unique asset resolution loss', () {
    final expected = TrainCExpectedCodeIdentity.forCurrentRepository();
    final snapshot = _validSnapshot(expected);
    (snapshot['imageSummary']
        as Map<String, dynamic>)['resolvedUniqueAssetCount'] = 4;

    final result = TrainCEvidenceProbe(expectedIdentity: expected).inspect(
      snapshot,
    );

    expect(result.schemaValid, isFalse);
    expect(result.evidence['failureCode'], 'TRAIN_C_IMAGE_CLOSURE_FAILURE');
  });

  test('rejects a mandatory Q18 local image loss', () {
    final expected = TrainCExpectedCodeIdentity.forCurrentRepository();
    final snapshot = _validSnapshot(expected);
    final q18 = (snapshot['mandatoryQuestions'] as Map<String, dynamic>)['18']
        as Map<String, dynamic>;
    q18['typedImageNodeCount'] = 1;
    q18['referencedImageCount'] = 2;

    final result = TrainCEvidenceProbe(expectedIdentity: expected).inspect(
      snapshot,
    );

    expect(result.schemaValid, isFalse);
    expect(result.evidence['failureCode'], 'TRAIN_C_IMAGE_CLOSURE_FAILURE');
  });

  test('rejects a present table with a missing TableNode', () {
    final expected = TrainCExpectedCodeIdentity.forCurrentRepository();
    final snapshot = _validSnapshot(expected);
    snapshot['tableLiveCoverage'] = 'PRESENT';
    (snapshot['tableSummary'] as Map<String, dynamic>)
      ..['referencedTableBlockCount'] = 2
      ..['typedTableNodeCount'] = 1;

    final result = TrainCEvidenceProbe(expectedIdentity: expected).inspect(
      snapshot,
    );

    expect(result.schemaValid, isFalse);
    expect(result.evidence['failureCode'], 'TRAIN_C_TABLE_CLOSURE_FAILURE');
  });

  test('rejects inconsistent provider arithmetic', () {
    final expected = TrainCExpectedCodeIdentity.forCurrentRepository();
    final snapshot = _validSnapshot(expected);
    (snapshot['attempt'] as Map<String, dynamic>)['providerDispatchCount'] = 1;

    final result = TrainCEvidenceProbe(expectedIdentity: expected).inspect(
      snapshot,
    );

    expect(result.schemaValid, isFalse);
    expect(result.evidence['failureCode'], 'TRAIN_C_EVIDENCE_INCONSISTENT');
  });

  test('rejects a well-formed but unexpected code identity', () {
    final expected = TrainCExpectedCodeIdentity.forCurrentRepository();
    final snapshot = _validSnapshot(expected);
    (snapshot['code'] as Map<String, dynamic>)['harnessHead'] =
        List<String>.filled(40, 'f').join();

    final result = TrainCEvidenceProbe(expectedIdentity: expected).inspect(
      snapshot,
    );

    expect(result.schemaValid, isFalse);
    expect(result.evidence['failureCode'], 'TRAIN_C_CODE_IDENTITY_MISMATCH');
  });

  test('malformed numbering fails closed without RangeError', () {
    final expected = TrainCExpectedCodeIdentity.forCurrentRepository();
    final probe = TrainCEvidenceProbe(expectedIdentity: expected);
    final variants = <List<Object?>>[
      <Object?>[],
      <Object?>[1],
      List<Object?>.generate(21, (index) => index + 1),
      List<Object?>.generate(23, (index) => index + 1),
      List<Object?>.generate(22, (index) => index + 1)..[4] = '5',
      List<Object?>.generate(22, (index) => index + 1)..[4] = 6,
    ];

    for (final numbers in variants) {
      final snapshot = _validSnapshot(expected);
      (snapshot['numbering'] as Map<String, dynamic>)['questionNumbers'] =
          numbers;
      final result = probe.inspect(snapshot);
      expect(result.schemaValid, isFalse);
      expect(result.evidence['failureCode'], 'TRAIN_C_NUMBERING_FAILURE');
    }
  });

  test('rejects a B0 manifest that omits a reachable asset', () {
    final expected = TrainCExpectedCodeIdentity.forCurrentRepository();
    final snapshot = _validSnapshot(expected);
    (snapshot['backupRestore']
        as Map<String, dynamic>)['backupManifestAssetCount'] = 4;

    final result = TrainCEvidenceProbe(expectedIdentity: expected).inspect(
      snapshot,
    );

    expect(result.schemaValid, isFalse);
    expect(result.evidence['failureCode'], 'TRAIN_C_B0_ASSET_SET_FAILURE');
  });
}

Map<String, dynamic> _validSnapshot(TrainCExpectedCodeIdentity expected) {
  return <String, dynamic>{
    'schemaVersion': 3,
    'runNumber': 1,
    'code': <String, dynamic>{
      'productionHead': expected.productionHead,
      'harnessHead': expected.harnessHead,
      'trainBMergeCommit': expected.trainBMergeCommit,
      'productionDiffFromBase': 0,
    },
    'input': <String, dynamic>{
      'sha256': _hex('d', 64),
      'sizeBytes': 1024,
      'pageCount': 22,
    },
    'attempt': <String, dynamic>{
      'consumed': true,
      'layoutPostCount': 1,
      'layoutChunkSize': 30,
      'expectedLayoutRequestCount': 1,
      'providerDispatchCount': 4,
      'providerResponseCount': 4,
      'remoteCropRequestCount': 3,
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
      'blockCount': 100,
      'imageBlockCount': 5,
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
      'referencedImageBlockCount': 5,
      'typedImageNodeCount': 5,
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
    'typedImageNodeCount': 1,
    'referencedUniqueAssetCount': 1,
    'resolvedUniqueAssetCount': 1,
    'canonicalIdentityPreserved': true,
    'commitPreserved': true,
    'restartResolution': true,
    'restartRender': true,
    'b0RestoreResolution': true,
    'b0RestoreRender': true,
  };
}

String _hex(String value, int length) =>
    List<String>.filled(length, value).join();

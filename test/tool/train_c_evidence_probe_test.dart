import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/train_c_evidence_probe.dart';

void main() {
  const probe = TrainCEvidenceProbe();

  test('accepts a complete safe TRAIN C snapshot', () {
    final result = probe.inspect(_validSnapshot());

    expect(result.passed, isTrue);
    expect(result.evidence['result'], 'PASS');
    expect(result.evidence['failureCode'], isNull);
    expect(
      result.evidence['numbering']['questionNumbers'],
      List<int>.generate(22, (index) => index + 1),
    );
    expect(jsonEncode(result.evidence), isNot(contains('provider.example')));
    expect(jsonEncode(result.evidence), isNot(contains('PRIVATE')));
  });

  test('rejects unknown privacy-bearing keys before projection', () {
    final snapshot = _validSnapshot()
      ..['providerUrl'] = 'https://provider.example';

    expect(
      () => probe.inspect(snapshot),
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
    final snapshot = _validSnapshot();
    final images = snapshot['imageSummary'] as Map<String, dynamic>;
    images['sourceId'] = 'private-source';

    expect(
      () => probe.inspect(snapshot),
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
    final snapshot = _validSnapshot();
    (snapshot['typed'] as Map<String, dynamic>)['storageRoute'] = 'legacyV1';

    final result = probe.inspect(snapshot);

    expect(result.passed, isFalse);
    expect(result.evidence['result'], 'FAIL');
    expect(result.evidence['failureCode'], 'TRAIN_C_TYPED_ROUTE_FAILURE');
    expect(result.evidence['firstLoss'], <String, dynamic>{
      'status': 'PROVEN',
      'checkpoint': 'P8',
    });
  });

  test('reports cleanup pending as a lifecycle failure', () {
    final snapshot = _validSnapshot();
    (snapshot['safety'] as Map<String, dynamic>)['candidateCleanupPending'] =
        true;

    final result = probe.inspect(snapshot);

    expect(result.passed, isFalse);
    expect(result.evidence['failureCode'], 'TRAIN_C_CANDIDATE_CLEANUP_PENDING');
    expect(result.evidence['firstLoss'], <String, dynamic>{
      'status': 'PROVEN',
      'checkpoint': 'P9',
    });
  });
}

Map<String, dynamic> _validSnapshot() {
  return <String, dynamic>{
    'schemaVersion': 2,
    'runNumber': 1,
    'code': <String, dynamic>{
      'productionHead': _hex('a', 40),
      'harnessHead': _hex('b', 40),
      'trainBMergeCommit': _hex('c', 40),
      'productionDiffFromBase': 0,
    },
    'input': <String, dynamic>{
      'sha256': _hex('d', 64),
      'sizeBytes': 1024,
      'pageCount': 22,
    },
    'attempt': <String, dynamic>{
      'consumed': true,
      'providerDispatchCount': 1,
      'providerResponseCount': 1,
      'remoteCropRequestCount': 3,
      'unexpectedProviderRequestCount': 0,
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
      'typedImageNodeCount': 3,
      'uniqueReferencedAssetCount': 3,
      'resolvedAssetCount': 3,
      'allReachableResolved': true,
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
      'allReachableResolved': true,
      'providerDispatchCount': 0,
    },
    'tableLiveCoverage': 'NOT PRESENT',
    'firstLoss': <String, dynamic>{'status': 'NONE', 'checkpoint': null},
  };
}

Map<String, bool> _mandatoryQuestion() {
  return <String, bool>{
    'typedImageNode': true,
    'assetRefClosure': true,
    'durableBytes': true,
    'restartResolution': true,
    'restartRender': true,
    'b0RestoreResolution': true,
    'b0RestoreRender': true,
  };
}

String _hex(String value, int length) =>
    List<String>.filled(length, value).join();

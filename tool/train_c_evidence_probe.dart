import 'dart:convert';
import 'dart:io';

import 'train_c_http_observer.dart';

const _topLevelKeys = <String>{
  'schemaVersion',
  'runNumber',
  'code',
  'input',
  'attempt',
  'safety',
  'parse',
  'numbering',
  'typed',
  'imageSummary',
  'mandatoryQuestions',
  'commit',
  'restart',
  'backupRestore',
  'tableLiveCoverage',
  'tableSummary',
};

const _sectionKeys = <String, Set<String>>{
  'code': <String>{
    'productionHead',
    'harnessHead',
    'trainBMergeCommit',
    'currentHead',
    'approvedHarnessHead',
    'approvedBase',
    'approvedProductionBase',
    'productionDiffFromBase',
  },
  'input': <String>{'sha256', 'sizeBytes', 'pageCount'},
  'attempt': <String>{
    'consumed',
    'layoutPostCount',
    'layoutChunkSize',
    'expectedLayoutRequestCount',
    'providerDispatchCount',
    'providerResponseCount',
    'remoteCropRequestCount',
    'unexpectedProviderRequestCount',
    'networkFailureCount',
  },
  'safety': <String>{
    'layoutResponsePolicyActive',
    'documentImageBudgetPolicyActive',
    'resourceFailure',
    'candidateCleanupPending',
  },
  'parse': <String>{
    'status',
    'blockCount',
    'imageBlockCount',
    'tableBlockCount',
    'assembledQuestionCount',
    'finalQuestionCount',
    'warningCount',
  },
  'numbering': <String>{'questionCount', 'questionNumbers', 'exactSet1To22'},
  'typed': <String>{
    'storageRoute',
    'storageReason',
    'typedCount',
    'validEnvelopeCount',
  },
  'imageSummary': <String>{
    'referencedImageBlockCount',
    'typedImageNodeCount',
    'referencedUniqueAssetCount',
    'typedUniqueAssetCount',
    'resolvedUniqueAssetCount',
    'allReachableResolved',
    'canonicalIdentityPreserved',
  },
  'tableSummary': <String>{
    'referencedTableBlockCount',
    'typedTableNodeCount',
    'tableContractConformant',
  },
  'commit': <String>{
    'status',
    'questionRows',
    'v2Sidecars',
    'legacyWriterCalls',
    'candidateCleanupPending',
  },
  'restart': <String>{
    'status',
    'questionCount',
    'typedAuthorityPreserved',
    'allReachableResolved',
    'providerDispatchCount',
  },
  'backupRestore': <String>{
    'packageVersion',
    'schemaVersion',
    'backupStatus',
    'restoreStatus',
    'restoredQuestionCount',
    'restoredV2Sidecars',
    'reachableAssetCount',
    'backupManifestAssetCount',
    'restoredAssetCount',
    'manifestMatchesReachableAssets',
    'restoredIdentityPreserved',
    'allReachableResolved',
    'providerDispatchCount',
  },
};

const _mandatoryQuestionKeys = <String>{
  'referencedImageCount',
  'sourceReferencedImageCount',
  'typedImageNodeCount',
  'referencedUniqueAssetCount',
  'sourceReferencedUniqueAssetCount',
  'resolvedUniqueAssetCount',
  'sourceIdentityPreserved',
  'canonicalIdentityPreserved',
  'commitPreserved',
  'restartResolution',
  'restartRender',
  'b0RestoreResolution',
  'b0RestoreRender',
};

const _trainBMergeCommit = '711fd33f564b9fb6bb3c992d6458b0075990646c';
const _trainCL1BaseMaster = 'f1d58a278180eff38686338c28f26e4d1d7b8b7a';
const _trainCL1ReviewedHarnessHead = '2fc0bc823e3ce75c1205729206280db5a59b2c58';

final class TrainCEvidenceProbeException implements Exception {
  const TrainCEvidenceProbeException(this.code);

  final String code;

  @override
  String toString() => code;
}

final class TrainCReviewedIdentity {
  const TrainCReviewedIdentity({
    required this.approvedHarnessHead,
    required this.approvedBase,
    required this.approvedProductionBase,
  });

  static const l1a = TrainCReviewedIdentity(
    approvedHarnessHead: _trainCL1ReviewedHarnessHead,
    approvedBase: _trainCL1BaseMaster,
    approvedProductionBase: _trainBMergeCommit,
  );

  final String approvedHarnessHead;
  final String approvedBase;
  final String approvedProductionBase;

  TrainCExpectedCodeIdentity toExpectedCodeIdentity() {
    return TrainCExpectedCodeIdentity.fromReviewed(this);
  }
}

final class TrainCExpectedCodeIdentity {
  const TrainCExpectedCodeIdentity({
    required this.productionHead,
    required this.harnessHead,
    required this.trainBMergeCommit,
    this.approvedHarnessHead = '',
    this.approvedBase = '',
    this.approvedProductionBase = '',
  });

  final String productionHead;
  final String harnessHead;
  final String trainBMergeCommit;
  final String approvedHarnessHead;
  final String approvedBase;
  final String approvedProductionBase;

  factory TrainCExpectedCodeIdentity.fromReviewed(
    TrainCReviewedIdentity reviewed,
  ) {
    return TrainCExpectedCodeIdentity(
      productionHead: reviewed.approvedProductionBase,
      harnessHead: reviewed.approvedHarnessHead,
      trainBMergeCommit: reviewed.approvedProductionBase,
      approvedHarnessHead: reviewed.approvedHarnessHead,
      approvedBase: reviewed.approvedBase,
      approvedProductionBase: reviewed.approvedProductionBase,
    );
  }

  factory TrainCExpectedCodeIdentity.forCurrentRepository() {
    final result = Process.runSync('git', <String>['rev-parse', 'HEAD']);
    final output = result.stdout;
    if (result.exitCode != 0 || output is! String) {
      throw const TrainCEvidenceProbeException(
        'TRAIN_C_CODE_IDENTITY_MISMATCH',
      );
    }
    final harnessHead = output.trim();
    if (!_isHex(harnessHead, 40)) {
      throw const TrainCEvidenceProbeException(
        'TRAIN_C_CODE_IDENTITY_MISMATCH',
      );
    }
    return TrainCExpectedCodeIdentity.fromReviewed(
      TrainCReviewedIdentity(
        approvedHarnessHead: harnessHead,
        approvedBase: _trainCL1BaseMaster,
        approvedProductionBase: _trainBMergeCommit,
      ),
    );
  }

  void validate(Map<String, dynamic> code) {
    final expectedHarness =
        approvedHarnessHead.isEmpty ? harnessHead : approvedHarnessHead;
    final expectedBase =
        approvedBase.isEmpty ? _trainCL1BaseMaster : approvedBase;
    final expectedProduction = approvedProductionBase.isEmpty
        ? (productionHead.isEmpty ? trainBMergeCommit : productionHead)
        : approvedProductionBase;
    if (_requiredString(code, 'productionHead') != expectedProduction ||
        _requiredString(code, 'harnessHead') != expectedHarness ||
        _requiredString(code, 'trainBMergeCommit') != expectedProduction ||
        _requiredString(code, 'currentHead') != expectedHarness ||
        _requiredString(code, 'approvedHarnessHead') != expectedHarness ||
        _requiredString(code, 'approvedBase') != expectedBase ||
        _requiredString(code, 'approvedProductionBase') != expectedProduction) {
      throw const TrainCEvidenceProbeException(
        'TRAIN_C_CODE_IDENTITY_MISMATCH',
      );
    }
  }
}

final class TrainCEvidenceProbeResult {
  const TrainCEvidenceProbeResult({
    required this.schemaValid,
    required this.acceptanceAuthorized,
    required this.evidence,
  });

  final bool schemaValid;
  final bool acceptanceAuthorized;
  final Map<String, dynamic> evidence;

  /// Compatibility accessor for focused harness tests. A true value means
  /// only that the supplied snapshot is schema-valid, not live-accepted.
  bool get passed => schemaValid;
}

/// Read-only, privacy-allowlisted schema validator.
///
/// This class never opens a database, starts Flutter, calls a provider, or
/// writes replay/evidence data. External JSON can become `SCHEMA_VALID`, but
/// it cannot become final TRAIN C acceptance because [acceptanceAuthorized]
/// remains false. The trusted collector is the only acceptance seam.
final class TrainCEvidenceProbe {
  const TrainCEvidenceProbe({required this.expectedIdentity});

  factory TrainCEvidenceProbe.forCurrentRepository() {
    // Schema-only CLI compatibility. The default remains bound to the frozen
    // review artifact; it must never derive acceptance authority from HEAD.
    return TrainCEvidenceProbe(
      expectedIdentity: TrainCReviewedIdentity.l1a.toExpectedCodeIdentity(),
    );
  }

  final TrainCExpectedCodeIdentity expectedIdentity;

  TrainCEvidenceProbeResult inspect(Map<String, dynamic> input) {
    final safe = _normalize(input);
    final failure = _firstFailure(safe);
    final evidence = <String, dynamic>{
      ...safe,
      'authority': 'schema_validator_only',
      'result': failure == null ? 'SCHEMA_VALID' : 'SCHEMA_INVALID',
      'failureCode': failure?.code,
      'firstLoss': <String, dynamic>{
        'status': failure == null ? 'NONE' : 'PROVEN',
        'checkpoint': failure?.checkpoint,
      },
    };
    return TrainCEvidenceProbeResult(
      schemaValid: failure == null,
      acceptanceAuthorized: false,
      evidence: evidence,
    );
  }

  TrainCEvidenceProbeResult inspectJson(String rawJson) {
    try {
      final decoded = jsonDecode(rawJson);
      if (decoded is! Map) {
        throw const TrainCEvidenceProbeException('TRAIN_C_HARNESS_NOT_READY');
      }
      return inspect(Map<String, dynamic>.from(decoded));
    } on TrainCEvidenceProbeException {
      rethrow;
    } catch (_) {
      throw const TrainCEvidenceProbeException('TRAIN_C_HARNESS_NOT_READY');
    }
  }

  TrainCEvidenceProbeResult inspectFile(String path) {
    if (path.trim().isEmpty || path.toLowerCase().endsWith('.pdf')) {
      throw const TrainCEvidenceProbeException('TRAIN_C_HARNESS_NOT_READY');
    }
    final file = File(path);
    if (!file.existsSync()) {
      throw const TrainCEvidenceProbeException('TRAIN_C_HARNESS_NOT_READY');
    }
    try {
      return inspectJson(file.readAsStringSync());
    } catch (error) {
      if (error is TrainCEvidenceProbeException) rethrow;
      throw const TrainCEvidenceProbeException('TRAIN_C_HARNESS_NOT_READY');
    }
  }

  Map<String, dynamic> _normalize(Map<String, dynamic> input) {
    for (final key in input.keys) {
      if (!_topLevelKeys.contains(key)) {
        throw const TrainCEvidenceProbeException('TRAIN_C_PRIVACY_FAILURE');
      }
    }

    final schemaVersion = _requiredInt(input, 'schemaVersion');
    final runNumber = _requiredInt(input, 'runNumber');
    if (schemaVersion != 3 || runNumber != 1) {
      throw const TrainCEvidenceProbeException('TRAIN_C_HARNESS_NOT_READY');
    }

    final normalized = <String, dynamic>{
      'schemaVersion': schemaVersion,
      'runNumber': runNumber,
    };
    for (final entry in _sectionKeys.entries) {
      final raw = input[entry.key];
      if (raw == null) {
        throw const TrainCEvidenceProbeException('TRAIN_C_HARNESS_NOT_READY');
      }
      normalized[entry.key] = _copySection(raw, entry.value);
    }

    final rawMandatory = input['mandatoryQuestions'];
    if (rawMandatory is! Map) {
      throw const TrainCEvidenceProbeException('TRAIN_C_HARNESS_NOT_READY');
    }
    final mandatory = <String, dynamic>{};
    for (final number in const <String>['5', '18', '19']) {
      final rawQuestion = rawMandatory[number];
      if (rawQuestion == null) {
        throw const TrainCEvidenceProbeException('TRAIN_C_HARNESS_NOT_READY');
      }
      mandatory[number] = _copySection(rawQuestion, _mandatoryQuestionKeys);
    }
    for (final key in rawMandatory.keys) {
      if (key is! String || !mandatory.containsKey(key)) {
        throw const TrainCEvidenceProbeException('TRAIN_C_PRIVACY_FAILURE');
      }
    }
    normalized['mandatoryQuestions'] = mandatory;

    final tableCoverage = input['tableLiveCoverage'];
    if (tableCoverage != 'PRESENT' && tableCoverage != 'NOT PRESENT') {
      throw const TrainCEvidenceProbeException('TRAIN_C_HARNESS_NOT_READY');
    }
    normalized['tableLiveCoverage'] = tableCoverage;
    return normalized;
  }

  Map<String, dynamic> _copySection(Object? raw, Set<String> allowedKeys) {
    if (raw is! Map) {
      throw const TrainCEvidenceProbeException('TRAIN_C_HARNESS_NOT_READY');
    }
    final output = <String, dynamic>{};
    for (final entry in raw.entries) {
      final key = entry.key;
      if (key is! String || !allowedKeys.contains(key)) {
        throw const TrainCEvidenceProbeException('TRAIN_C_PRIVACY_FAILURE');
      }
      output[key] = _copyValue(entry.value);
    }
    return output;
  }

  dynamic _copyValue(Object? value) {
    if (value == null || value is String || value is num || value is bool) {
      return value;
    }
    if (value is List) {
      return value.map(_copyValue).toList(growable: false);
    }
    throw const TrainCEvidenceProbeException('TRAIN_C_PRIVACY_FAILURE');
  }

  void _validateTypes(Map<String, dynamic> evidence) {
    final code = _section(evidence, 'code');
    expectedIdentity.validate(code);
    if (_requiredInt(code, 'productionDiffFromBase') != 0) {
      throw const TrainCEvidenceProbeException('TRAIN_C_HEAD_DRIFT');
    }

    final input = _section(evidence, 'input');
    _requireHex(input, 'sha256', 64);
    final pageCount = _requiredInt(input, 'pageCount');
    if (_requiredInt(input, 'sizeBytes') <= 0 || pageCount <= 0) {
      throw const TrainCEvidenceProbeException('TRAIN_C_INPUT_INVALID');
    }

    final attempt = _section(evidence, 'attempt');
    final pageChunkSize = _requiredInt(attempt, 'layoutChunkSize');
    final expectedLayoutCount = trainCExpectedLayoutRequestCount(
      pageCount: pageCount,
      pageChunkSize: pageChunkSize,
    );
    if (_requiredBool(attempt, 'consumed') != true ||
        _requiredInt(attempt, 'expectedLayoutRequestCount') !=
            expectedLayoutCount ||
        _requiredInt(attempt, 'layoutPostCount') != expectedLayoutCount ||
        _requiredInt(attempt, 'unexpectedProviderRequestCount') != 0) {
      throw const TrainCEvidenceProbeException(
        'TRAIN_C_PROVIDER_REQUEST_COUNT_FAILURE',
      );
    }
    _nonNegativeFields(attempt, const <String>[
      'layoutPostCount',
      'layoutChunkSize',
      'expectedLayoutRequestCount',
      'providerDispatchCount',
      'providerResponseCount',
      'remoteCropRequestCount',
      'unexpectedProviderRequestCount',
      'networkFailureCount',
    ]);
    final dispatch = _requiredInt(attempt, 'providerDispatchCount');
    final arithmetic = _requiredInt(attempt, 'layoutPostCount') +
        _requiredInt(attempt, 'remoteCropRequestCount') +
        _requiredInt(attempt, 'unexpectedProviderRequestCount');
    if (dispatch != arithmetic ||
        _requiredInt(attempt, 'providerResponseCount') != dispatch) {
      throw const TrainCEvidenceProbeException(
        'TRAIN_C_EVIDENCE_INCONSISTENT',
      );
    }
    if (_requiredInt(attempt, 'networkFailureCount') != 0) {
      throw const TrainCEvidenceProbeException(
        'TRAIN_C_PROVIDER_RESPONSE_RESOURCE_FAILURE',
      );
    }

    final safety = _section(evidence, 'safety');
    if (_requiredBool(safety, 'layoutResponsePolicyActive') != true ||
        _requiredBool(safety, 'documentImageBudgetPolicyActive') != true) {
      throw const TrainCEvidenceProbeException('TRAIN_C_HARNESS_NOT_READY');
    }
    if (_requiredBool(safety, 'resourceFailure')) {
      throw const TrainCEvidenceProbeException(
        'TRAIN_C_PROVIDER_RESPONSE_RESOURCE_FAILURE',
      );
    }
    if (_requiredBool(safety, 'candidateCleanupPending')) {
      throw const TrainCEvidenceProbeException(
        'TRAIN_C_CANDIDATE_CLEANUP_PENDING',
      );
    }

    final parse = _section(evidence, 'parse');
    if (_requiredString(parse, 'status') != 'PASS' ||
        _requiredInt(parse, 'imageBlockCount') <= 0 ||
        _requiredInt(parse, 'assembledQuestionCount') != 22 ||
        _requiredInt(parse, 'finalQuestionCount') != 22) {
      throw const TrainCEvidenceProbeException(
        'TRAIN_C_PENDING_REVIEW_FAILURE',
      );
    }
    _nonNegativeFields(parse, const <String>[
      'blockCount',
      'imageBlockCount',
      'tableBlockCount',
      'assembledQuestionCount',
      'finalQuestionCount',
      'warningCount',
    ]);

    final numbering = _section(evidence, 'numbering');
    final numbers = numbering['questionNumbers'];
    if (numbers is! List ||
        numbers.length != 22 ||
        numbers.asMap().entries.any(
              (entry) => entry.value is! int || entry.value != entry.key + 1,
            ) ||
        _requiredInt(numbering, 'questionCount') != 22 ||
        _requiredBool(numbering, 'exactSet1To22') != true) {
      throw const TrainCEvidenceProbeException('TRAIN_C_NUMBERING_FAILURE');
    }

    final typed = _section(evidence, 'typed');
    if (_requiredString(typed, 'storageRoute') != 'typedV2' ||
        _requiredString(typed, 'storageReason') != 'typed_candidate_ready' ||
        _requiredInt(typed, 'typedCount') != 22 ||
        _requiredInt(typed, 'validEnvelopeCount') != 22) {
      throw const TrainCEvidenceProbeException('TRAIN_C_TYPED_ROUTE_FAILURE');
    }

    final images = _section(evidence, 'imageSummary');
    final referencedImageCount =
        _requiredInt(images, 'referencedImageBlockCount');
    final typedImageCount = _requiredInt(images, 'typedImageNodeCount');
    final referencedAssetCount =
        _requiredInt(images, 'referencedUniqueAssetCount');
    final typedAssetCount = _requiredInt(images, 'typedUniqueAssetCount');
    final resolvedAssetCount = _requiredInt(images, 'resolvedUniqueAssetCount');
    if (referencedImageCount <= 0 ||
        typedImageCount != referencedImageCount ||
        referencedAssetCount <= 0 ||
        typedAssetCount != referencedAssetCount ||
        resolvedAssetCount != referencedAssetCount ||
        _requiredBool(images, 'allReachableResolved') != true ||
        _requiredBool(images, 'canonicalIdentityPreserved') != true) {
      throw const TrainCEvidenceProbeException(
        'TRAIN_C_IMAGE_CLOSURE_FAILURE',
      );
    }
    if (referencedImageCount > _requiredInt(parse, 'imageBlockCount')) {
      throw const TrainCEvidenceProbeException(
        'TRAIN_C_IMAGE_CLOSURE_FAILURE',
      );
    }

    final tables = _section(evidence, 'tableSummary');
    final referencedTableCount =
        _requiredInt(tables, 'referencedTableBlockCount');
    final typedTableCount = _requiredInt(tables, 'typedTableNodeCount');
    final tableCoverage = evidence['tableLiveCoverage'];
    if (tableCoverage == 'PRESENT') {
      if (referencedTableCount <= 0 ||
          typedTableCount != referencedTableCount ||
          _requiredBool(tables, 'tableContractConformant') != true) {
        throw const TrainCEvidenceProbeException(
          'TRAIN_C_TABLE_CLOSURE_FAILURE',
        );
      }
    } else if (referencedTableCount != 0 || typedTableCount != 0) {
      throw const TrainCEvidenceProbeException(
        'TRAIN_C_TABLE_CLOSURE_FAILURE',
      );
    } else {
      _requiredBool(tables, 'tableContractConformant');
    }
    if (referencedTableCount > _requiredInt(parse, 'tableBlockCount')) {
      throw const TrainCEvidenceProbeException(
        'TRAIN_C_TABLE_CLOSURE_FAILURE',
      );
    }

    final mandatory = evidence['mandatoryQuestions'] as Map<String, dynamic>;
    var mandatoryReferencedTotal = 0;
    var mandatoryTypedTotal = 0;
    for (final number in const <String>['5', '18', '19']) {
      final question = mandatory[number] as Map<String, dynamic>;
      final referenced = _requiredInt(question, 'referencedImageCount');
      final sourceReferenced =
          _requiredInt(question, 'sourceReferencedImageCount');
      final typedCount = _requiredInt(question, 'typedImageNodeCount');
      mandatoryReferencedTotal += referenced;
      mandatoryTypedTotal += typedCount;
      final referencedAssets =
          _requiredInt(question, 'referencedUniqueAssetCount');
      final sourceReferencedAssets =
          _requiredInt(question, 'sourceReferencedUniqueAssetCount');
      if (referenced <= 0 ||
          sourceReferenced != referenced ||
          typedCount != referenced ||
          referencedAssets <= 0 ||
          sourceReferencedAssets != referencedAssets ||
          _requiredInt(question, 'resolvedUniqueAssetCount') !=
              referencedAssets ||
          _requiredBool(question, 'sourceIdentityPreserved') != true ||
          !_allTrue(question, const <String>[
            'canonicalIdentityPreserved',
            'commitPreserved',
            'restartResolution',
            'restartRender',
            'b0RestoreResolution',
            'b0RestoreRender',
          ])) {
        throw const TrainCEvidenceProbeException(
          'TRAIN_C_IMAGE_CLOSURE_FAILURE',
        );
      }
    }
    if (mandatoryReferencedTotal > referencedImageCount ||
        mandatoryTypedTotal > typedImageCount) {
      throw const TrainCEvidenceProbeException(
        'TRAIN_C_IMAGE_CLOSURE_FAILURE',
      );
    }

    final commit = _section(evidence, 'commit');
    if (_requiredString(commit, 'status') != 'PASS' ||
        _requiredInt(commit, 'questionRows') != 22 ||
        _requiredInt(commit, 'v2Sidecars') != 22 ||
        _requiredInt(commit, 'legacyWriterCalls') != 0 ||
        _requiredBool(commit, 'candidateCleanupPending')) {
      throw const TrainCEvidenceProbeException('TRAIN_C_COMMIT_FAILURE');
    }

    final restart = _section(evidence, 'restart');
    if (_requiredString(restart, 'status') != 'PASS' ||
        _requiredInt(restart, 'questionCount') != 22 ||
        _requiredBool(restart, 'typedAuthorityPreserved') != true ||
        _requiredBool(restart, 'allReachableResolved') != true ||
        _requiredInt(restart, 'providerDispatchCount') != 0) {
      throw const TrainCEvidenceProbeException('TRAIN_C_RESTART_FAILURE');
    }

    final backup = _section(evidence, 'backupRestore');
    final reachableAssets = _requiredInt(backup, 'reachableAssetCount');
    if (_requiredInt(backup, 'packageVersion') != 2 ||
        _requiredInt(backup, 'schemaVersion') != 23 ||
        _requiredString(backup, 'backupStatus') != 'PASS' ||
        _requiredString(backup, 'restoreStatus') != 'PASS' ||
        _requiredInt(backup, 'restoredQuestionCount') != 22 ||
        _requiredInt(backup, 'restoredV2Sidecars') != 22 ||
        reachableAssets <= 0 ||
        _requiredInt(backup, 'backupManifestAssetCount') != reachableAssets ||
        _requiredInt(backup, 'restoredAssetCount') != reachableAssets ||
        _requiredBool(backup, 'manifestMatchesReachableAssets') != true ||
        _requiredBool(backup, 'restoredIdentityPreserved') != true ||
        _requiredBool(backup, 'allReachableResolved') != true ||
        _requiredInt(backup, 'providerDispatchCount') != 0) {
      throw const TrainCEvidenceProbeException(
        'TRAIN_C_B0_ASSET_SET_FAILURE',
      );
    }
    if (reachableAssets != referencedAssetCount) {
      throw const TrainCEvidenceProbeException(
        'TRAIN_C_B0_ASSET_SET_FAILURE',
      );
    }
  }

  _ProbeFailure? _firstFailure(Map<String, dynamic> evidence) {
    try {
      _validateTypes(evidence);
      return null;
    } on TrainCEvidenceProbeException catch (error) {
      final checkpoint = switch (error.code) {
        'TRAIN_C_PROVIDER_RESPONSE_RESOURCE_FAILURE' => 'P2',
        'TRAIN_C_PROVIDER_REQUEST_COUNT_FAILURE' => 'P1',
        'TRAIN_C_EVIDENCE_INCONSISTENT' => 'P2',
        'TRAIN_C_CANDIDATE_CLEANUP_PENDING' => 'P9',
        'TRAIN_C_PENDING_REVIEW_FAILURE' => 'P9',
        'TRAIN_C_NUMBERING_FAILURE' => 'P8',
        'TRAIN_C_TYPED_ROUTE_FAILURE' => 'P8',
        'TRAIN_C_IMAGE_CLOSURE_FAILURE' => 'P7',
        'TRAIN_C_TABLE_CLOSURE_FAILURE' => 'P7',
        'TRAIN_C_ASSET_RESOLUTION_FAILURE' => 'P7',
        'TRAIN_C_IMAGE_NODE_MISSING' => 'P7',
        'TRAIN_C_COMMIT_FAILURE' => 'P11',
        'TRAIN_C_RESTART_FAILURE' => 'P12',
        'TRAIN_C_B0_IDENTITY_MISMATCH' => 'P14',
        'TRAIN_C_B0_ASSET_SET_FAILURE' => 'P14',
        'TRAIN_C_RESTORE_FAILURE' => 'P14',
        'TRAIN_C_CODE_IDENTITY_MISMATCH' => 'P0',
        'TRAIN_C_INPUT_INVALID' => 'P0',
        'TRAIN_C_HEAD_DRIFT' => 'P0',
        _ => 'P0',
      };
      return _ProbeFailure(checkpoint: checkpoint, code: error.code);
    }
  }

  Map<String, dynamic> _section(Map<String, dynamic> root, String key) {
    final value = root[key];
    if (value is! Map<String, dynamic>) {
      throw const TrainCEvidenceProbeException('TRAIN_C_HARNESS_NOT_READY');
    }
    return value;
  }

  bool _allTrue(Map<String, dynamic> map, Iterable<String> keys) {
    for (final key in keys) {
      if (_requiredBool(map, key) != true) return false;
    }
    return true;
  }

  int _requiredInt(Map<String, dynamic> map, String key) {
    final value = map[key];
    if (value is! int) {
      throw const TrainCEvidenceProbeException('TRAIN_C_HARNESS_NOT_READY');
    }
    return value;
  }

  bool _requiredBool(Map<String, dynamic> map, String key) {
    final value = map[key];
    if (value is! bool) {
      throw const TrainCEvidenceProbeException('TRAIN_C_HARNESS_NOT_READY');
    }
    return value;
  }

  String _requiredString(Map<String, dynamic> map, String key) {
    final value = map[key];
    if (value is! String) {
      throw const TrainCEvidenceProbeException('TRAIN_C_HARNESS_NOT_READY');
    }
    return value;
  }

  void _requireHex(Map<String, dynamic> map, String key, int length) {
    final value = _requiredString(map, key);
    if (!_isHex(value, length)) {
      throw const TrainCEvidenceProbeException('TRAIN_C_HARNESS_NOT_READY');
    }
  }

  void _nonNegativeFields(Map<String, dynamic> map, Iterable<String> keys) {
    for (final key in keys) {
      if (_requiredInt(map, key) < 0) {
        throw const TrainCEvidenceProbeException('TRAIN_C_HARNESS_NOT_READY');
      }
    }
  }
}

final class _ProbeFailure {
  const _ProbeFailure({required this.checkpoint, required this.code});

  final String checkpoint;
  final String code;
}

bool _isHex(String value, int length) {
  return value.length == length && RegExp(r'^[0-9a-fA-F]+$').hasMatch(value);
}

String _requiredString(Map<String, dynamic> map, String key) {
  final value = map[key];
  if (value is! String) {
    throw const TrainCEvidenceProbeException('TRAIN_C_HARNESS_NOT_READY');
  }
  return value;
}

void main(List<String> args) {
  if (args.length != 2 || args.first != '--input') {
    stderr.writeln('TRAIN_C_HARNESS_NOT_READY');
    exitCode = 2;
    return;
  }
  try {
    final result = TrainCEvidenceProbe.forCurrentRepository().inspectFile(
      args[1],
    );
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(result.evidence));
    exitCode = result.schemaValid ? 0 : 1;
  } on TrainCEvidenceProbeException catch (error) {
    stderr.writeln(error.code);
    exitCode = 2;
  }
}

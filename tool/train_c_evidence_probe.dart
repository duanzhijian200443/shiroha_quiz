import 'dart:convert';
import 'dart:io';

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
  'firstLoss',
  'result',
  'failureCode',
};

const _sectionKeys = <String, Set<String>>{
  'code': <String>{
    'productionHead',
    'harnessHead',
    'trainBMergeCommit',
    'productionDiffFromBase',
  },
  'input': <String>{'sha256', 'sizeBytes', 'pageCount'},
  'attempt': <String>{
    'consumed',
    'providerDispatchCount',
    'providerResponseCount',
    'remoteCropRequestCount',
    'unexpectedProviderRequestCount',
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
    'typedImageNodeCount',
    'uniqueReferencedAssetCount',
    'resolvedAssetCount',
    'allReachableResolved',
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
    'allReachableResolved',
    'providerDispatchCount',
  },
  'firstLoss': <String>{'status', 'checkpoint'},
};

const _mandatoryQuestionKeys = <String>{
  'typedImageNode',
  'assetRefClosure',
  'durableBytes',
  'restartResolution',
  'restartRender',
  'b0RestoreResolution',
  'b0RestoreRender',
};

final class TrainCEvidenceProbeException implements Exception {
  const TrainCEvidenceProbeException(this.code);

  final String code;

  @override
  String toString() => code;
}

final class TrainCEvidenceProbeResult {
  const TrainCEvidenceProbeResult({
    required this.passed,
    required this.evidence,
  });

  final bool passed;
  final Map<String, dynamic> evidence;
}

/// Read-only, privacy-allowlisted acceptance probe.
///
/// The probe accepts only the safe aggregate schema from the TRAIN C runbook.
/// It never opens a database, starts Flutter, calls a provider, or writes a
/// replay/evidence file. The optional CLI input is a JSON snapshot supplied by
/// a future live runner, never the source PDF itself.
final class TrainCEvidenceProbe {
  const TrainCEvidenceProbe();

  TrainCEvidenceProbeResult inspect(Map<String, dynamic> input) {
    final safe = _normalize(input);
    final failure = _firstFailure(safe);
    final evidence = <String, dynamic>{
      ...safe,
      'result': failure == null ? 'PASS' : 'FAIL',
      'failureCode': failure?.code,
      'firstLoss': <String, dynamic>{
        'status': failure == null ? 'NONE' : 'PROVEN',
        'checkpoint': failure?.checkpoint,
      },
    };
    return TrainCEvidenceProbeResult(
      passed: failure == null,
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
    if (schemaVersion != 2 || runNumber != 1) {
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
    _requireHex(code, 'productionHead', 40);
    _requireHex(code, 'harnessHead', 40);
    _requireHex(code, 'trainBMergeCommit', 40);
    if (_requiredInt(code, 'productionDiffFromBase') != 0) {
      throw const TrainCEvidenceProbeException('TRAIN_C_HEAD_DRIFT');
    }

    final input = _section(evidence, 'input');
    _requireHex(input, 'sha256', 64);
    if (_requiredInt(input, 'sizeBytes') <= 0 ||
        _requiredInt(input, 'pageCount') <= 0) {
      throw const TrainCEvidenceProbeException('TRAIN_C_INPUT_INVALID');
    }

    final attempt = _section(evidence, 'attempt');
    if (_requiredBool(attempt, 'consumed') != true ||
        _requiredInt(attempt, 'unexpectedProviderRequestCount') != 0) {
      throw const TrainCEvidenceProbeException(
        'TRAIN_C_PROVIDER_REQUEST_COUNT_FAILURE',
      );
    }
    _nonNegativeFields(attempt, const <String>[
      'providerDispatchCount',
      'providerResponseCount',
      'remoteCropRequestCount',
      'unexpectedProviderRequestCount',
    ]);

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
        !List<Object?>.generate(
          22,
          (index) => index + 1,
        ).asMap().entries.every((entry) => numbers[entry.key] == entry.value) ||
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
    if (_requiredInt(images, 'typedImageNodeCount') <= 0 ||
        _requiredInt(images, 'uniqueReferencedAssetCount') <= 0 ||
        _requiredInt(images, 'resolvedAssetCount') !=
            _requiredInt(images, 'uniqueReferencedAssetCount') ||
        _requiredBool(images, 'allReachableResolved') != true) {
      throw const TrainCEvidenceProbeException(
        'TRAIN_C_ASSET_RESOLUTION_FAILURE',
      );
    }

    final mandatory = evidence['mandatoryQuestions'] as Map<String, dynamic>;
    for (final number in const <String>['5', '18', '19']) {
      final question = mandatory[number] as Map<String, dynamic>;
      for (final key in _mandatoryQuestionKeys) {
        if (_requiredBool(question, key) != true) {
          throw const TrainCEvidenceProbeException(
            'TRAIN_C_IMAGE_NODE_MISSING',
          );
        }
      }
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
    if (_requiredInt(backup, 'packageVersion') != 2 ||
        _requiredInt(backup, 'schemaVersion') != 23 ||
        _requiredString(backup, 'backupStatus') != 'PASS' ||
        _requiredString(backup, 'restoreStatus') != 'PASS' ||
        _requiredInt(backup, 'restoredQuestionCount') != 22 ||
        _requiredInt(backup, 'restoredV2Sidecars') != 22 ||
        _requiredBool(backup, 'allReachableResolved') != true ||
        _requiredInt(backup, 'providerDispatchCount') != 0) {
      throw const TrainCEvidenceProbeException('TRAIN_C_RESTORE_FAILURE');
    }

    final firstLoss = _section(evidence, 'firstLoss');
    if (_requiredString(firstLoss, 'status') != 'NONE' ||
        firstLoss['checkpoint'] != null) {
      throw const TrainCEvidenceProbeException('TRAIN_C_FIRST_LOSS_UNKNOWN');
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
        'TRAIN_C_CANDIDATE_CLEANUP_PENDING' => 'P9',
        'TRAIN_C_PENDING_REVIEW_FAILURE' => 'P9',
        'TRAIN_C_NUMBERING_FAILURE' => 'P8',
        'TRAIN_C_TYPED_ROUTE_FAILURE' => 'P8',
        'TRAIN_C_ASSET_RESOLUTION_FAILURE' => 'P7',
        'TRAIN_C_IMAGE_NODE_MISSING' => 'P7',
        'TRAIN_C_COMMIT_FAILURE' => 'P11',
        'TRAIN_C_RESTART_FAILURE' => 'P12',
        'TRAIN_C_RESTORE_FAILURE' => 'P14',
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
    if (value.length != length || !RegExp(r'^[0-9a-fA-F]+$').hasMatch(value)) {
      throw const TrainCEvidenceProbeException('TRAIN_C_HEAD_DRIFT');
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

void main(List<String> args) {
  if (args.length != 2 || args.first != '--input') {
    stderr.writeln('TRAIN_C_HARNESS_NOT_READY');
    exitCode = 2;
    return;
  }
  try {
    final result = const TrainCEvidenceProbe().inspectFile(args[1]);
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(result.evidence));
    exitCode = result.passed ? 0 : 1;
  } on TrainCEvidenceProbeException catch (error) {
    stderr.writeln(error.code);
    exitCode = 2;
  }
}

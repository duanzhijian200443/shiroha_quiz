import 'train_c_evidence_probe.dart';
import 'train_c_restart_proof.dart';
import 'train_c_runtime_evidence_source.dart';

Map<String, Object?> encodeTrainCSourceImages(TrainCSourceImageFacts facts) {
  return <String, Object?>{
    'counts': <String, Object?>{
      for (final entry in facts.referencedImageCounts.entries)
        '${entry.key}': entry.value,
    },
    'identities': <String, Object?>{
      for (final entry in facts.referencedIdentitiesByQuestion.entries)
        '${entry.key}': _encodeIdentities(entry.value),
    },
    'ordered': <Object?>[
      for (final item in facts.orderedEvidence)
        <String, Object?>{
          'questionNumber': item.questionNumber,
          'sourceId': item.sourceId,
          'blockId': item.blockId,
          'localAssetId': item.localAssetId,
          'contentHash': item.contentHash,
          'readingOrder': item.readingOrder,
        },
    ],
  };
}

TrainCSourceImageFacts decodeTrainCSourceImages(Object? raw) {
  try {
    final map = _map(raw);
    final countsRaw = _map(map['counts']);
    final identitiesRaw = _map(map['identities']);
    final orderedRaw = _list(map['ordered']);
    final counts = <int, int>{};
    for (final entry in countsRaw.entries) {
      final number = int.tryParse(entry.key);
      final count = entry.value;
      if (number == null || number <= 0 || count is! int || count < 0) {
        throw const FormatException();
      }
      counts[number] = count;
    }
    final identities = <int, Set<(String, String)>>{};
    for (final entry in identitiesRaw.entries) {
      final number = int.tryParse(entry.key);
      if (number == null || number <= 0) throw const FormatException();
      identities[number] = _decodeIdentities(entry.value);
    }
    final ordered = <TrainCPreTypedSourceImageEvidence>[];
    for (final value in orderedRaw) {
      final item = _map(value);
      final number = item['questionNumber'];
      final sourceId = item['sourceId'];
      final blockId = item['blockId'];
      final localAssetId = item['localAssetId'];
      final contentHash = item['contentHash'];
      final readingOrder = item['readingOrder'];
      if (number is! int ||
          number <= 0 ||
          sourceId is! String ||
          sourceId.isEmpty ||
          blockId is! String ||
          blockId.isEmpty ||
          localAssetId is! String ||
          localAssetId.isEmpty ||
          contentHash is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(contentHash) ||
          readingOrder is! int ||
          readingOrder < 0) {
        throw const FormatException();
      }
      ordered.add(
        TrainCPreTypedSourceImageEvidence(
          questionNumber: number,
          sourceId: sourceId,
          blockId: blockId,
          localAssetId: localAssetId,
          contentHash: contentHash,
          readingOrder: readingOrder,
        ),
      );
    }
    return TrainCSourceImageFacts(
      referencedImageCounts: counts,
      referencedIdentitiesByQuestion: identities,
      orderedEvidence: ordered,
    );
  } catch (_) {
    throw const TrainCEvidenceProbeException('TRAIN_C_HARNESS_NOT_READY');
  }
}

Map<String, Object?> encodeTrainCCandidateCheckpoint(
  TrainCCandidateCheckpoint checkpoint,
) {
  return <String, Object?>{
    'typedCount': checkpoint.typedCount,
    'validEnvelopeCount': checkpoint.validEnvelopeCount,
    'payloadDigest': checkpoint.payloadDigest,
    'questionNumbers': checkpoint.questionNumbers,
    'typedImageNodeCount': checkpoint.typedImageNodeCount,
    'typedUniqueAssetCount': checkpoint.typedUniqueAssetCount,
    'typedTableNodeCount': checkpoint.typedTableNodeCount,
    'reachableIdentities': _encodeIdentities(checkpoint.reachableIdentities),
    'questions': <Object?>[
      for (final question in checkpoint.questions)
        <String, Object?>{
          'questionNumber': question.questionNumber,
          'payloadDigest': question.payloadDigest,
          'imageNodeCount': question.imageNodeCount,
          'uniqueAssetCount': question.uniqueAssetCount,
          'tableNodeCount': question.tableNodeCount,
          'canonicalIdentityPreserved': question.canonicalIdentityPreserved,
          'reachableIdentities':
              _encodeIdentities(question.reachableIdentities),
        },
    ],
  };
}

TrainCCandidateCheckpoint decodeTrainCCandidateCheckpoint(Object? raw) {
  try {
    final map = _map(raw);
    final questions = <TrainCCandidateQuestionCheckpoint>[];
    for (final value in _list(map['questions'])) {
      final item = _map(value);
      questions.add(
        TrainCCandidateQuestionCheckpoint(
          questionNumber: _nullablePositiveInt(item['questionNumber']),
          payloadDigest: _digest(item['payloadDigest']),
          imageNodeCount: _nonNegativeInt(item['imageNodeCount']),
          uniqueAssetCount: _nonNegativeInt(item['uniqueAssetCount']),
          tableNodeCount: _nonNegativeInt(item['tableNodeCount']),
          canonicalIdentityPreserved:
              _bool(item['canonicalIdentityPreserved']),
          reachableIdentities: _decodeIdentities(item['reachableIdentities']),
        ),
      );
    }
    return TrainCCandidateCheckpoint(
      typedCount: _nonNegativeInt(map['typedCount']),
      validEnvelopeCount: _nonNegativeInt(map['validEnvelopeCount']),
      payloadDigest: _digest(map['payloadDigest']),
      questionNumbers: _positiveIntList(map['questionNumbers']),
      typedImageNodeCount: _nonNegativeInt(map['typedImageNodeCount']),
      typedUniqueAssetCount: _nonNegativeInt(map['typedUniqueAssetCount']),
      typedTableNodeCount: _nonNegativeInt(map['typedTableNodeCount']),
      reachableIdentities: _decodeIdentities(map['reachableIdentities']),
      questions: questions,
    );
  } catch (_) {
    throw const TrainCEvidenceProbeException('TRAIN_C_HARNESS_NOT_READY');
  }
}

Map<String, Object?> encodeTrainCRuntimeCheckpoint(
  TrainCRuntimeCheckpoint checkpoint,
) {
  return <String, Object?>{
    'questionRows': checkpoint.questionRows,
    'v2Sidecars': checkpoint.v2Sidecars,
    'typedCount': checkpoint.typedCount,
    'validEnvelopeCount': checkpoint.validEnvelopeCount,
    'questionNumbers': checkpoint.questionNumbers,
    'typedImageNodeCount': checkpoint.typedImageNodeCount,
    'typedUniqueAssetCount': checkpoint.typedUniqueAssetCount,
    'resolvedUniqueAssetCount': checkpoint.resolvedUniqueAssetCount,
    'allReachableResolved': checkpoint.allReachableResolved,
    'canonicalIdentityPreserved': checkpoint.canonicalIdentityPreserved,
    'typedTableNodeCount': checkpoint.typedTableNodeCount,
    'payloadDigest': checkpoint.payloadDigest,
    'reachableIdentities': _encodeIdentities(checkpoint.reachableIdentities),
    'assetSizes': <Object?>[
      for (final entry in checkpoint.assetSizes.entries)
        <String, Object?>{
          'sourceId': entry.key.$1,
          'localAssetId': entry.key.$2,
          'value': entry.value,
        },
    ],
    'assetDigests': <Object?>[
      for (final entry in checkpoint.assetDigests.entries)
        <String, Object?>{
          'sourceId': entry.key.$1,
          'localAssetId': entry.key.$2,
          'value': entry.value,
        },
    ],
    'questions': <Object?>[
      for (final question in checkpoint.questions)
        <String, Object?>{
          'questionNumber': question.questionNumber,
          'payloadDigest': question.payloadDigest,
          'imageNodeCount': question.imageNodeCount,
          'uniqueAssetCount': question.uniqueAssetCount,
          'resolvedUniqueAssetCount': question.resolvedUniqueAssetCount,
          'tableNodeCount': question.tableNodeCount,
          'canonicalIdentityPreserved': question.canonicalIdentityPreserved,
          'allReachableResolved': question.allReachableResolved,
          'identityDigest': question.identityDigest,
          'reachableIdentities':
              _encodeIdentities(question.reachableIdentities),
          'orderedImageIdentities': <Object?>[
            for (final identity in question.orderedImageIdentities)
              <Object?>[identity.$1, identity.$2],
          ],
        },
    ],
  };
}

TrainCRuntimeCheckpoint decodeTrainCRuntimeCheckpoint(Object? raw) {
  try {
    final map = _map(raw);
    final sizes = <(String, String), int>{};
    for (final value in _list(map['assetSizes'])) {
      final entry = _map(value);
      sizes[_identityFromEntry(entry)] = _nonNegativeInt(entry['value']);
    }
    final digests = <(String, String), String>{};
    for (final value in _list(map['assetDigests'])) {
      final entry = _map(value);
      digests[_identityFromEntry(entry)] = _digest(entry['value']);
    }
    final questions = <TrainCQuestionCheckpoint>[];
    for (final value in _list(map['questions'])) {
      final item = _map(value);
      questions.add(
        TrainCQuestionCheckpoint(
          questionNumber: _nullablePositiveInt(item['questionNumber']),
          payloadDigest: _digest(item['payloadDigest']),
          imageNodeCount: _nonNegativeInt(item['imageNodeCount']),
          uniqueAssetCount: _nonNegativeInt(item['uniqueAssetCount']),
          resolvedUniqueAssetCount:
              _nonNegativeInt(item['resolvedUniqueAssetCount']),
          tableNodeCount: _nonNegativeInt(item['tableNodeCount']),
          canonicalIdentityPreserved:
              _bool(item['canonicalIdentityPreserved']),
          allReachableResolved: _bool(item['allReachableResolved']),
          identityDigest: _digest(item['identityDigest']),
          reachableIdentities: _decodeIdentities(item['reachableIdentities']),
          orderedImageIdentities:
              _decodeIdentityList(item['orderedImageIdentities']),
        ),
      );
    }
    return TrainCRuntimeCheckpoint(
      questionRows: _nonNegativeInt(map['questionRows']),
      v2Sidecars: _nonNegativeInt(map['v2Sidecars']),
      typedCount: _nonNegativeInt(map['typedCount']),
      validEnvelopeCount: _nonNegativeInt(map['validEnvelopeCount']),
      questionNumbers: _positiveIntList(map['questionNumbers']),
      typedImageNodeCount: _nonNegativeInt(map['typedImageNodeCount']),
      typedUniqueAssetCount: _nonNegativeInt(map['typedUniqueAssetCount']),
      resolvedUniqueAssetCount:
          _nonNegativeInt(map['resolvedUniqueAssetCount']),
      allReachableResolved: _bool(map['allReachableResolved']),
      canonicalIdentityPreserved: _bool(map['canonicalIdentityPreserved']),
      typedTableNodeCount: _nonNegativeInt(map['typedTableNodeCount']),
      payloadDigest: _digest(map['payloadDigest']),
      reachableIdentities: _decodeIdentities(map['reachableIdentities']),
      assetSizes: sizes,
      assetDigests: digests,
      questions: questions,
    );
  } catch (_) {
    throw const TrainCEvidenceProbeException('TRAIN_C_HARNESS_NOT_READY');
  }
}

Map<String, Object?> encodeTrainCRestartProof(TrainCOsProcessRestartProof proof) {
  return <String, Object?>{
    'parentPid': proof.parentPid,
    'childPid': proof.childPid,
    'questionRows': proof.checkpoint.questionRows,
    'v2Sidecars': proof.checkpoint.v2Sidecars,
    'managedFileCount': proof.checkpoint.managedFileCount,
    'durableDigest': proof.checkpoint.durableDigest,
    'providerDispatchCount': proof.providerDispatchCount,
  };
}

TrainCOsProcessRestartProof decodeTrainCRestartProof(Object? raw) {
  try {
    final map = _map(raw);
    final parentPid = _positiveInt(map['parentPid']);
    final childPid = _positiveInt(map['childPid']);
    if (parentPid == childPid) throw const FormatException();
    return TrainCOsProcessRestartProof(
      parentPid: parentPid,
      childPid: childPid,
      checkpoint: TrainCDurableRestartCheckpoint(
        questionRows: _nonNegativeInt(map['questionRows']),
        v2Sidecars: _nonNegativeInt(map['v2Sidecars']),
        managedFileCount: _nonNegativeInt(map['managedFileCount']),
        durableDigest: _digest(map['durableDigest']),
      ),
      providerDispatchCount: _nonNegativeInt(map['providerDispatchCount']),
    );
  } catch (_) {
    throw const TrainCEvidenceProbeException('TRAIN_C_HARNESS_NOT_READY');
  }
}

List<Object?> _encodeIdentities(Set<(String, String)> identities) {
  final values = identities.toList()
    ..sort((left, right) {
      final source = left.$1.compareTo(right.$1);
      return source != 0 ? source : left.$2.compareTo(right.$2);
    });
  return <Object?>[
    for (final identity in values) <Object?>[identity.$1, identity.$2],
  ];
}

Set<(String, String)> _decodeIdentities(Object? raw) =>
    _decodeIdentityList(raw).toSet();

List<(String, String)> _decodeIdentityList(Object? raw) {
  final values = <(String, String)>[];
  for (final value in _list(raw)) {
    final pair = _list(value);
    if (pair.length != 2 || pair[0] is! String || pair[1] is! String) {
      throw const FormatException();
    }
    final sourceId = pair[0] as String;
    final localAssetId = pair[1] as String;
    if (sourceId.isEmpty || localAssetId.isEmpty) throw const FormatException();
    values.add((sourceId, localAssetId));
  }
  return values;
}

(String, String) _identityFromEntry(Map<String, Object?> entry) {
  final sourceId = entry['sourceId'];
  final localAssetId = entry['localAssetId'];
  if (sourceId is! String ||
      sourceId.isEmpty ||
      localAssetId is! String ||
      localAssetId.isEmpty) {
    throw const FormatException();
  }
  return (sourceId, localAssetId);
}

Map<String, Object?> _map(Object? value) {
  if (value is! Map) throw const FormatException();
  return Map<String, Object?>.from(value);
}

List<Object?> _list(Object? value) {
  if (value is! List) throw const FormatException();
  return List<Object?>.from(value);
}

int _nonNegativeInt(Object? value) {
  if (value is! int || value < 0) throw const FormatException();
  return value;
}

int _positiveInt(Object? value) {
  if (value is! int || value <= 0) throw const FormatException();
  return value;
}

int? _nullablePositiveInt(Object? value) {
  if (value == null) return null;
  return _positiveInt(value);
}

bool _bool(Object? value) {
  if (value is! bool) throw const FormatException();
  return value;
}

String _digest(Object? value) {
  if (value is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
    throw const FormatException();
  }
  return value;
}

List<int> _positiveIntList(Object? raw) {
  final result = <int>[];
  for (final value in _list(raw)) {
    result.add(_positiveInt(value));
  }
  return result;
}

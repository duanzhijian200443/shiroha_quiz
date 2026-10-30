part of 'generated_question_contract.dart';

/// Historical format only. Decoding this value grants no current authority and
/// cannot produce a GeneratedOriginContext or an external STAGE command.
final class ExternalProposalOrigin {
  ExternalProposalOrigin._(
      {required this.schemaVersion,
      required this.clientProfileId,
      required this.submissionKey,
      required this.originalTarget,
      required this.adapterProtocol,
      required this.authorizationSnapshot,
      required this.externalRequestId});

  // These are bound to the Proposal's original header, not repeated in payload.
  final String clientProfileId, submissionKey;
  final int schemaVersion;
  final GeneratedTarget originalTarget;
  final ExternalOriginAdapterProtocol adapterProtocol;
  final ExternalOriginAuthorizationSnapshot authorizationSnapshot;
  final String? externalRequestId;

  static ExternalProposalOrigin fromPersistedPayload(Object? value,
      {required String clientProfileId,
      required String submissionKey,
      required GeneratedTarget originalTarget}) {
    generatedSize(value, GeneratedLimits.externalOriginBytes);
    final m = generatedObject(value, [
      'schemaVersion',
      'externalRequestId',
      'adapterProtocol',
      'authorizationSnapshot'
    ]);
    final version = m['schemaVersion'];
    if (version is! int || (version != 1 && version != 2)) {
      generatedFail(GeneratedFailure.corruptState);
    }
    final request = m['externalRequestId'];
    if (request != null &&
        (request is! String ||
            !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(request))) {
      generatedFail(GeneratedFailure.corruptState);
    }
    final target = GeneratedTarget.fromJson(originalTarget.toJson());
    final profile = generatedToken(clientProfileId, uuid: true);
    return ExternalProposalOrigin._(
        schemaVersion: version,
        clientProfileId: profile,
        submissionKey: generatedToken(submissionKey),
        originalTarget: target,
        externalRequestId: request as String?,
        adapterProtocol:
            ExternalOriginAdapterProtocol._decode(m['adapterProtocol']),
        authorizationSnapshot: ExternalOriginAuthorizationSnapshot._decode(
            m['authorizationSnapshot'], target, profile,
            schemaVersion: version));
  }

  Map<String, Object?> toPersistedPayload() => {
        'schemaVersion': schemaVersion,
        'externalRequestId': externalRequestId,
        'adapterProtocol': adapterProtocol.toJson(),
        'authorizationSnapshot': authorizationSnapshot.toJson()
      };

  void validateOriginalEvidence(Iterable<GeneratedItem> items) {
    for (final item in items) {
      if (item.evidence.any(
          (e) => !authorizationSnapshot.authorizedFileIds.contains(e.fileId))) {
        generatedFail(GeneratedFailure.corruptState);
      }
    }
  }
}

final class ExternalOriginAdapterProtocol {
  const ExternalOriginAdapterProtocol._(this.adapter, this.protocol);
  final String adapter, protocol;
  static ExternalOriginAdapterProtocol _decode(Object? value) {
    final m = generatedObject(value, ['adapter', 'protocol']);
    String token(Object? value) {
      if (value is! String ||
          !RegExp(r'^[a-z][a-z0-9._-]{0,31}$').hasMatch(value)) {
        generatedFail(GeneratedFailure.corruptState);
      }
      return value;
    }

    return ExternalOriginAdapterProtocol._(
        token(m['adapter']), token(m['protocol']));
  }

  Map<String, Object?> toJson() => {'adapter': adapter, 'protocol': protocol};
}

/// Target scope and recipient use the original header, never Review's rebind.
/// This is a record of admission facts, not a reusable Grant or Context Handle.
final class ExternalOriginAuthorizationSnapshot {
  ExternalOriginAuthorizationSnapshot._(
      this.grantRevision,
      this.originalTarget,
      this.recipientProfileId,
      Iterable<String> files,
      Iterable<String> categories)
      : authorizedFileIds = List.unmodifiable(files),
        egressCategories = List.unmodifiable(categories);
  final int grantRevision;
  final GeneratedTarget originalTarget;
  final String recipientProfileId;
  final List<String> authorizedFileIds, egressCategories;
  static ExternalOriginAuthorizationSnapshot _decode(
      Object? value, GeneratedTarget target, String recipient,
      {required int schemaVersion}) {
    final m = generatedObject(value, [
      'grantRevision',
      'permission',
      'authorizedFileIds',
      'egressCategories'
    ]);
    if (m['permission'] != 'stage') {
      generatedFail(GeneratedFailure.corruptState);
    }
    final files = generatedList(m['authorizedFileIds'], max: 128)
        .map(generatedToken)
        .toList();
    final allowedCategories = [
      'questionContent',
      'fileContent',
      'proposalMetadata',
      if (schemaVersion == 2) 'studyStatistics',
    ];
    final categories =
        generatedList(m['egressCategories'], max: allowedCategories.length)
            .map((v) {
      if (v is! String || !allowedCategories.contains(v)) {
        generatedFail(GeneratedFailure.corruptState);
      }
      return v;
    }).toList();
    for (final values in [files, categories]) {
      final ordered = values.toSet().toList()..sort();
      if (generatedCanonical(ordered) != generatedCanonical(values)) {
        generatedFail(GeneratedFailure.corruptState);
      }
    }
    return ExternalOriginAuthorizationSnapshot._(
        generatedInt(m['grantRevision'], min: 1, max: 2147483647),
        target,
        recipient,
        files,
        categories);
  }

  Map<String, Object?> toJson() => {
        'grantRevision': grantRevision,
        'permission': 'stage',
        'authorizedFileIds': authorizedFileIds,
        'egressCategories': egressCategories
      };
}

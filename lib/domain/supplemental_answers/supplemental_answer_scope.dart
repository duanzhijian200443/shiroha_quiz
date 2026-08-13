final _opaqueIdentifierPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$');

/// Explicit target scope for one supplemental-answer matching session.
///
/// One session = one target scope + one supplemental file. Project is
/// resolved at session start into a complete typed-question snapshot and is
/// never reinterpreted at commit time.
sealed class SupplementalAnswerTargetScope {
  const SupplementalAnswerTargetScope();
}

/// All eligible typed questions whose current `bankName` equals [bankName].
final class QuestionBankScope extends SupplementalAnswerTargetScope {
  const QuestionBankScope({required this.bankName});

  final String bankName;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is QuestionBankScope && bankName == other.bankName;
  }

  @override
  int get hashCode => bankName.hashCode;
}

/// The Project's bank relations resolved into a typed-question snapshot at
/// session start. [projectId] is the stable Project identity.
final class ProjectScope extends SupplementalAnswerTargetScope {
  const ProjectScope({required this.projectId});

  final String projectId;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is ProjectScope && projectId == other.projectId;
  }

  @override
  int get hashCode => projectId.hashCode;
}

/// Caller-ordered explicit subset of typed targets. Missing, duplicate, and
/// legacy IDs must be reported explicitly; the order is preserved.
final class ExplicitQuestionScope extends SupplementalAnswerTargetScope {
  factory ExplicitQuestionScope({required Iterable<String> storageIds}) {
    final copied = List<String>.unmodifiable(
      storageIds.map(_validateOpaqueIdentifier),
    );
    if (copied.isEmpty) {
      throw const FormatException(
        'Explicit question scopes require at least one storage id.',
      );
    }
    return ExplicitQuestionScope._(copied);
  }

  const ExplicitQuestionScope._(this.storageIds);

  final List<String> storageIds;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is ExplicitQuestionScope &&
            _orderedEquals(storageIds, other.storageIds);
  }

  @override
  int get hashCode => Object.hashAll(storageIds);
}

/// One matching session request: exactly one explicitly selected
/// supplemental file plus one explicit target scope.
final class SupplementalAnswerMatchRequest {
  factory SupplementalAnswerMatchRequest({
    required SupplementalAnswerTargetScope targetScope,
    required String supplementalFileId,
  }) {
    return SupplementalAnswerMatchRequest._(
      targetScope: targetScope,
      supplementalFileId: _validateOpaqueIdentifier(supplementalFileId),
    );
  }

  const SupplementalAnswerMatchRequest._({
    required this.targetScope,
    required this.supplementalFileId,
  });

  final SupplementalAnswerTargetScope targetScope;
  final String supplementalFileId;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is SupplementalAnswerMatchRequest &&
            targetScope == other.targetScope &&
            supplementalFileId == other.supplementalFileId;
  }

  @override
  int get hashCode => Object.hash(targetScope, supplementalFileId);
}

String _validateOpaqueIdentifier(String value) {
  if (!_opaqueIdentifierPattern.hasMatch(value)) {
    throw const FormatException(
      'Domain identifiers must use the bounded opaque token format.',
    );
  }
  return value;
}

bool _orderedEquals<T>(List<T> left, List<T> right) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

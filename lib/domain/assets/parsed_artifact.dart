final _artifactIdentityPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$');

/// D0 identity and metadata value semantics for one ParsedArtifact
/// generation.
///
/// [fileId] is the long-lived `LibraryFile` identity, [artifactId] identifies
/// one successfully published generation and must never be derived from file
/// name, path, timestamp, or task/attempt ID, and [revision] is the monotonic
/// per-[fileId] publication sequence number. D0 establishes the domain values
/// only; publication, CAS, and persistence belong to later stages.
final class ParsedArtifact {
  factory ParsedArtifact({
    required String fileId,
    required String artifactId,
    required int revision,
    required int payloadSchemaVersion,
  }) {
    final validatedFileId = _validateIdentity(fileId, 'fileId');
    final validatedArtifactId = _validateIdentity(artifactId, 'artifactId');
    if (validatedArtifactId == validatedFileId) {
      throw const FormatException(
        'Artifact identity must differ from the file identity.',
      );
    }
    if (revision <= 0) {
      throw const FormatException(
        'Artifact revisions are one-based positive integers.',
      );
    }
    if (payloadSchemaVersion <= 0) {
      throw const FormatException(
        'Payload schema versions are positive integers.',
      );
    }
    return ParsedArtifact._(
      fileId: validatedFileId,
      artifactId: validatedArtifactId,
      revision: revision,
      payloadSchemaVersion: payloadSchemaVersion,
    );
  }

  const ParsedArtifact._({
    required this.fileId,
    required this.artifactId,
    required this.revision,
    required this.payloadSchemaVersion,
  });

  final String fileId;
  final String artifactId;
  final int revision;
  final int payloadSchemaVersion;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is ParsedArtifact &&
            fileId == other.fileId &&
            artifactId == other.artifactId &&
            revision == other.revision &&
            payloadSchemaVersion == other.payloadSchemaVersion;
  }

  @override
  int get hashCode =>
      Object.hash(fileId, artifactId, revision, payloadSchemaVersion);
}

String _validateIdentity(String value, String label) {
  if (!_artifactIdentityPattern.hasMatch(value)) {
    throw FormatException('$label must use the bounded opaque token format.');
  }
  return value;
}

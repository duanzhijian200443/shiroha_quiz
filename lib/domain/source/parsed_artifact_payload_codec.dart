import 'source_document.dart';
import 'source_document_codec.dart';

final _payloadIdentityPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$');

/// Strict versioned envelope for one persisted parsed-artifact payload.
///
/// [schemaVersion] must equal [ParsedArtifactPayloadCodec.schemaVersion],
/// [artifactId] must be a bounded opaque generation identity distinct from
/// [fileId], and the nested [SourceDocument] must bind to the same
/// [artifactId] through `SourceDocument.sourceId`.
final class ParsedArtifactPayload {
  factory ParsedArtifactPayload({
    required int schemaVersion,
    required String artifactId,
    required String fileId,
    required SourceDocument sourceDocument,
  }) {
    if (schemaVersion != ParsedArtifactPayloadCodec.schemaVersion) {
      throw FormatException(
        'Unsupported ParsedArtifactPayload schemaVersion: $schemaVersion.',
      );
    }
    final validatedArtifactId = _validateIdentity(artifactId, 'artifactId');
    final validatedFileId = _validateIdentity(fileId, 'fileId');
    if (validatedArtifactId == validatedFileId) {
      throw const FormatException(
        'Artifact identity must differ from the file identity.',
      );
    }
    if (sourceDocument.documentRef.sourceId != validatedArtifactId) {
      throw const FormatException(
        'SourceDocument.sourceId must equal the payload artifactId.',
      );
    }
    return ParsedArtifactPayload._(
      schemaVersion: schemaVersion,
      artifactId: validatedArtifactId,
      fileId: validatedFileId,
      sourceDocument: sourceDocument,
    );
  }

  const ParsedArtifactPayload._({
    required this.schemaVersion,
    required this.artifactId,
    required this.fileId,
    required this.sourceDocument,
  });

  final int schemaVersion;
  final String artifactId;
  final String fileId;
  final SourceDocument sourceDocument;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is ParsedArtifactPayload &&
            schemaVersion == other.schemaVersion &&
            artifactId == other.artifactId &&
            fileId == other.fileId &&
            sourceDocument == other.sourceDocument;
  }

  @override
  int get hashCode =>
      Object.hash(schemaVersion, artifactId, fileId, sourceDocument);
}

final class ParsedArtifactPayloadCodec {
  const ParsedArtifactPayloadCodec();

  static const int schemaVersion = 1;
  static const SourceDocumentCodec _sourceDocumentCodec = SourceDocumentCodec();

  Map<String, Object?> encode(ParsedArtifactPayload payload) {
    return <String, Object?>{
      'schemaVersion': schemaVersion,
      'artifactId': payload.artifactId,
      'fileId': payload.fileId,
      'sourceDocument': _sourceDocumentCodec.encode(payload.sourceDocument),
    };
  }

  ParsedArtifactPayload decode(Object? json) {
    final root = _expectObject(
      json,
      expectedKeys: _payloadKeys,
      label: 'ParsedArtifactPayload root',
    );
    final version = root['schemaVersion'];
    if (version is! int) {
      throw const FormatException(
        'ParsedArtifactPayload schemaVersion must be an integer.',
      );
    }
    if (version != schemaVersion) {
      throw UnsupportedError(
        'Unsupported ParsedArtifactPayload schemaVersion: $version.',
      );
    }
    return ParsedArtifactPayload(
      schemaVersion: version,
      artifactId: _expectString(root['artifactId'], 'artifactId'),
      fileId: _expectString(root['fileId'], 'fileId'),
      sourceDocument: _sourceDocumentCodec.decode(root['sourceDocument']),
    );
  }
}

const _payloadKeys = <String>{
  'schemaVersion',
  'artifactId',
  'fileId',
  'sourceDocument',
};

Map<String, Object?> _expectObject(
  Object? value, {
  required Set<String> expectedKeys,
  required String label,
}) {
  final object = _expectUntypedObject(value, label);
  _requireExactKeys(object, expectedKeys, label);
  return object;
}

Map<String, Object?> _expectUntypedObject(Object? value, String label) {
  if (value is! Map) {
    throw FormatException('$label must be a JSON object.');
  }
  final object = <String, Object?>{};
  for (final entry in value.entries) {
    final key = entry.key;
    if (key is! String) {
      throw const FormatException('JSON object keys must be strings.');
    }
    object[key] = entry.value;
  }
  return object;
}

void _requireExactKeys(
  Map<String, Object?> object,
  Set<String> expectedKeys,
  String label,
) {
  if (object.length != expectedKeys.length ||
      !expectedKeys.every(object.containsKey)) {
    throw FormatException('$label must contain exactly the schema fields.');
  }
}

String _expectString(Object? value, String label) {
  if (value is! String) {
    throw FormatException('$label must be a string.');
  }
  return value;
}

String _validateIdentity(String value, String label) {
  if (!_payloadIdentityPattern.hasMatch(value)) {
    throw FormatException('$label must use the bounded opaque token format.');
  }
  return value;
}

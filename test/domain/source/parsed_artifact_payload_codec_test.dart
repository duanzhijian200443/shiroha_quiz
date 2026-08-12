import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/source/parsed_artifact_payload_codec.dart';
import 'package:shiroha_quiz/domain/source/source_document.dart';
import 'package:shiroha_quiz/domain/source/source_part.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';

void main() {
  const codec = ParsedArtifactPayloadCodec();

  group('ParsedArtifactPayloadCodec round-trip', () {
    test('preserves the envelope and nested source document', () {
      final payload = _payload();

      final decoded = codec.decode(codec.encode(payload));

      expect(decoded, equals(payload));
      expect(decoded.schemaVersion, ParsedArtifactPayloadCodec.schemaVersion);
      expect(decoded.sourceDocument, equals(payload.sourceDocument));
    });

    test('encoding is deterministic', () {
      final payload = _payload();

      expect(codec.encode(payload), equals(codec.encode(payload)));
      final decoded = codec.decode(codec.encode(payload));
      expect(codec.encode(decoded), equals(codec.encode(payload)));
    });
  });

  group('ParsedArtifactPayloadCodec strictness', () {
    test('rejects missing schemaVersion', () {
      final copy = Map<String, Object?>.from(codec.encode(_payload()))
        ..remove('schemaVersion');

      expect(() => codec.decode(copy), throwsFormatException);
    });

    test('distinguishes an unsupported schemaVersion', () {
      final copy = Map<String, Object?>.from(codec.encode(_payload()))
        ..['schemaVersion'] = 2;

      expect(() => codec.decode(copy), throwsA(isA<UnsupportedError>()));
    });

    test('rejects unknown top-level fields', () {
      final copy = Map<String, Object?>.from(codec.encode(_payload()))
        ..['extra'] = true;

      expect(() => codec.decode(copy), throwsFormatException);
    });

    test('rejects wrong field types', () {
      final encoded = codec.encode(_payload());
      final invalidCases = <String, Object?>{
        'schemaVersion is bool': <String, Object?>{
          ...encoded,
          'schemaVersion': true,
        },
        'artifactId is int': <String, Object?>{
          ...encoded,
          'artifactId': 123,
        },
        'fileId is list': <String, Object?>{
          ...encoded,
          'fileId': <Object?>[],
        },
        'sourceDocument is string': <String, Object?>{
          ...encoded,
          'sourceDocument': 'not a document',
        },
      };

      for (final entry in invalidCases.entries) {
        expect(
          () => codec.decode(entry.value),
          throwsFormatException,
          reason: entry.key,
        );
      }
    });

    test('rejects invalid and colliding identities', () {
      final encoded = codec.encode(_payload());
      final invalidCases = <String, Object?>{
        'invalid artifactId': <String, Object?>{
          ...encoded,
          'artifactId': 'bad id!',
        },
        'invalid fileId': <String, Object?>{
          ...encoded,
          'fileId': 'file/id',
        },
        'artifactId equals fileId': <String, Object?>{
          ...encoded,
          'artifactId': 'file_0001',
        },
      };

      for (final entry in invalidCases.entries) {
        expect(
          () => codec.decode(entry.value),
          throwsFormatException,
          reason: entry.key,
        );
      }
    });

    test('rejects SourceDocument.sourceId != artifactId', () {
      final input = <String, Object?>{
        'schemaVersion': 1,
        'artifactId': 'artifact_0001',
        'fileId': 'file_0001',
        'sourceDocument': <String, Object?>{
          'schemaVersion': 1,
          'sourceId': 'artifact_0002',
          'displayLabel': null,
          'parts': <Object?>[],
          'issues': <Object?>[],
        },
      };

      expect(() => codec.decode(input), throwsFormatException);
      expect(
        () => ParsedArtifactPayload(
          schemaVersion: ParsedArtifactPayloadCodec.schemaVersion,
          artifactId: 'artifact_0001',
          fileId: 'file_0001',
          sourceDocument: SourceDocument(sourceId: 'artifact_0002'),
        ),
        throwsFormatException,
      );
    });

    test('rejects nested malformed SourceDocument', () {
      final encoded = codec.encode(_payload());
      final document = encoded['sourceDocument']! as Map<String, Object?>;
      final parts = document['parts']! as List<Object?>;
      final first = parts.first! as Map<String, Object?>;
      first['type'] = 'hologram';

      expect(() => codec.decode(encoded), throwsFormatException);
    });

    test('rejects nested privacy violations', () {
      final input = <String, Object?>{
        'schemaVersion': 1,
        'artifactId': 'artifact_0001',
        'fileId': 'file_0001',
        'sourceDocument': <String, Object?>{
          'schemaVersion': 1,
          'sourceId': 'artifact_0001',
          'displayLabel': null,
          'parts': <Object?>[
            <String, Object?>{
              'type': 'content',
              'sourceRef': <String, Object?>{
                'type': 'document',
                'sourceId': 'artifact_0001',
                'displayLabel': null,
              },
              'content': <String, Object?>{
                'schemaVersion': 1,
                'nodes': <Object?>[
                  <String, Object?>{
                    'type': 'raw_fallback',
                    'payload': <String, Object?>{
                      'path': r'C:\private\page.pdf',
                    },
                  },
                ],
              },
              'role': 'paragraph',
            },
          ],
          'issues': <Object?>[],
        },
      };

      expect(() => codec.decode(input), throwsFormatException);
    });

    test('rejects unsupported schema metadata at construction', () {
      final sourceDocument = SourceDocument(sourceId: 'artifact_0001');
      expect(
        () => ParsedArtifactPayload(
          schemaVersion: 0,
          artifactId: 'artifact_0001',
          fileId: 'file_0001',
          sourceDocument: sourceDocument,
        ),
        throwsFormatException,
      );
      expect(
        () => ParsedArtifactPayload(
          schemaVersion: 2,
          artifactId: 'artifact_0001',
          fileId: 'file_0001',
          sourceDocument: sourceDocument,
        ),
        throwsFormatException,
      );
    });
  });
}

ParsedArtifactPayload _payload() {
  return ParsedArtifactPayload(
    schemaVersion: ParsedArtifactPayloadCodec.schemaVersion,
    artifactId: 'artifact_0001',
    fileId: 'file_0001',
    sourceDocument: SourceDocument(
      sourceId: 'artifact_0001',
      displayLabel: 'notes.md',
      parts: <SourcePart>[
        SourceContentPart(
          sourceRef: SourceRef.at(
            sourceId: 'artifact_0001',
            point: SourcePoint.block(
              pageNumber: 1,
              blockId: 'b1',
              readingOrder: 0,
            ),
          ),
          content: RichContent(
            nodes: const <ContentNode>[TextNode('parsed text')],
          ),
        ),
      ],
    ),
  );
}

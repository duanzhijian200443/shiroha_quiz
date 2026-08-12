import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/domain/assets/parsed_artifact.dart';

void main() {
  group('ParsedArtifact identity and metadata', () {
    test('constructs a valid value object', () {
      final artifact = ParsedArtifact(
        fileId: 'file_0001',
        artifactId: 'artifact_0001',
        revision: 1,
        payloadSchemaVersion: 1,
      );

      expect(artifact.fileId, 'file_0001');
      expect(artifact.artifactId, 'artifact_0001');
      expect(artifact.revision, 1);
      expect(artifact.payloadSchemaVersion, 1);
    });

    test('uses structural equality and hashCode', () {
      final first = ParsedArtifact(
        fileId: 'file_a',
        artifactId: 'artifact_a',
        revision: 3,
        payloadSchemaVersion: 1,
      );
      final same = ParsedArtifact(
        fileId: 'file_a',
        artifactId: 'artifact_a',
        revision: 3,
        payloadSchemaVersion: 1,
      );

      expect(first, equals(same));
      expect(first.hashCode, same.hashCode);
      expect(
        first,
        isNot(
          equals(
            ParsedArtifact(
              fileId: 'file_a',
              artifactId: 'artifact_a',
              revision: 4,
              payloadSchemaVersion: 1,
            ),
          ),
        ),
      );
      expect(
        first,
        isNot(
          equals(
            ParsedArtifact(
              fileId: 'file_a',
              artifactId: 'artifact_a',
              revision: 3,
              payloadSchemaVersion: 2,
            ),
          ),
        ),
      );
    });

    test('rejects invalid artifact identities', () {
      expect(
        () => ParsedArtifact(
          fileId: 'file_a',
          artifactId: '',
          revision: 1,
          payloadSchemaVersion: 1,
        ),
        throwsFormatException,
      );
      expect(
        () => ParsedArtifact(
          fileId: 'file_a',
          artifactId: 'bad id!',
          revision: 1,
          payloadSchemaVersion: 1,
        ),
        throwsFormatException,
      );
      expect(
        () => ParsedArtifact(
          fileId: 'file_a',
          artifactId: 'x' * 129,
          revision: 1,
          payloadSchemaVersion: 1,
        ),
        throwsFormatException,
      );
    });

    test('rejects invalid file identities', () {
      expect(
        () => ParsedArtifact(
          fileId: '',
          artifactId: 'artifact_a',
          revision: 1,
          payloadSchemaVersion: 1,
        ),
        throwsFormatException,
      );
      expect(
        () => ParsedArtifact(
          fileId: 'file/a',
          artifactId: 'artifact_a',
          revision: 1,
          payloadSchemaVersion: 1,
        ),
        throwsFormatException,
      );
    });

    test('rejects invalid revision and schema metadata', () {
      expect(
        () => ParsedArtifact(
          fileId: 'file_a',
          artifactId: 'artifact_a',
          revision: 0,
          payloadSchemaVersion: 1,
        ),
        throwsFormatException,
      );
      expect(
        () => ParsedArtifact(
          fileId: 'file_a',
          artifactId: 'artifact_a',
          revision: -1,
          payloadSchemaVersion: 1,
        ),
        throwsFormatException,
      );
      expect(
        () => ParsedArtifact(
          fileId: 'file_a',
          artifactId: 'artifact_a',
          revision: 1,
          payloadSchemaVersion: 0,
        ),
        throwsFormatException,
      );
    });

    test('never mixes artifact identity with file identity', () {
      expect(
        () => ParsedArtifact(
          fileId: 'same_id',
          artifactId: 'same_id',
          revision: 1,
          payloadSchemaVersion: 1,
        ),
        throwsFormatException,
      );

      final artifact = ParsedArtifact(
        fileId: 'file_a',
        artifactId: 'artifact_a',
        revision: 1,
        payloadSchemaVersion: 1,
      );
      final swapped = ParsedArtifact(
        fileId: 'artifact_a',
        artifactId: 'file_a',
        revision: 1,
        payloadSchemaVersion: 1,
      );
      expect(artifact, isNot(equals(swapped)));
    });
  });
}

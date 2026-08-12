import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/services/file_library/managed_artifact_storage.dart';
import 'package:shiroha_quiz/services/file_library/managed_artifact_storage_adapter.dart';

void main() {
  late Directory tempDir;
  late ManagedArtifactStorageAdapter adapter;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('artifact_storage_');
    adapter = ManagedArtifactStorageAdapter(managedRoot: tempDir);
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  List<int> payload() => '{"schemaVersion":1,"synthetic":true}'.codeUnits;

  group('ManagedArtifactStorageAdapter finalize and read', () {
    test('allocates the canonical namespace key', () {
      expect(
        adapter.allocateArtifactStorageKey('artifact_0001'),
        'artifacts/artifact_0001.json',
      );
    });

    test('write/finalize/read round-trips with exact digest and size',
        () async {
      final bytes = payload();
      final expectedDigest = sha256.convert(bytes).toString();

      final written = await adapter.writeArtifact(
        storageKey: 'artifacts/artifact_0001.json',
        bytes: bytes,
      );

      expect(written.sha256, expectedDigest);
      expect(written.sizeBytes, bytes.length);
      final read = await adapter.readArtifact(
        storageKey: 'artifacts/artifact_0001.json',
        expectedSha256: expectedDigest,
        expectedSizeBytes: bytes.length,
      );
      expect(read, isNotNull);
      expect(read!.bytes, bytes);
      expect(read.sha256, expectedDigest);
      expect(read.sizeBytes, bytes.length);
    });

    test('an existing finalized sidecar is never overwritten', () async {
      final bytes = payload();
      await adapter.writeArtifact(
        storageKey: 'artifacts/artifact_0001.json',
        bytes: bytes,
      );

      await expectLater(
        adapter.writeArtifact(
          storageKey: 'artifacts/artifact_0001.json',
          bytes: <int>[1, 2, 3],
        ),
        throwsA(
          isA<ManagedArtifactStorageException>().having(
            (error) => error.failure,
            'failure',
            ManagedArtifactStorageFailure.alreadyFinalized,
          ),
        ),
      );
      final read = await adapter.readArtifact(
        storageKey: 'artifacts/artifact_0001.json',
      );
      expect(read!.bytes, bytes);
    });

    test('failure removes stale temp files and leaves no final sidecar',
        () async {
      final bytes = payload();
      await adapter.writeArtifact(
        storageKey: 'artifacts/artifact_0001.json',
        bytes: bytes,
      );
      final staleTemp = File(
        p.join(tempDir.path, 'artifacts', 'artifact_0001.json.tmp'),
      );
      await staleTemp.create(recursive: true);
      await staleTemp.writeAsBytes(<int>[9, 9]);

      await expectLater(
        adapter.writeArtifact(
          storageKey: 'artifacts/artifact_0001.json',
          bytes: <int>[1],
        ),
        throwsA(
          isA<ManagedArtifactStorageException>().having(
            (error) => error.failure,
            'failure',
            ManagedArtifactStorageFailure.alreadyFinalized,
          ),
        ),
      );
      expect(await staleTemp.exists(), isFalse);
      final read = await adapter.readArtifact(
        storageKey: 'artifacts/artifact_0001.json',
      );
      expect(read!.bytes, bytes);
    });

    test('io failure is typed, leaves no final, and leaks no path', () async {
      final namespace = File(p.join(tempDir.path, 'artifacts'));
      await namespace.writeAsString('blocked');
      final blocked = await File(namespace.path).stat();
      expect(blocked.type, FileSystemEntityType.file);

      try {
        await adapter.writeArtifact(
          storageKey: 'artifacts/artifact_0001.json',
          bytes: payload(),
        );
        fail('expected io failure');
      } on ManagedArtifactStorageException catch (error) {
        expect(error.failure, ManagedArtifactStorageFailure.ioFailed);
        expect(error.toString(), isNot(contains(tempDir.path)));
        expect(error.toString(), isNot(contains('artifact_0001')));
      }
      expect(
        await File(p.join(tempDir.path, 'artifacts', 'artifact_0001.json'))
            .exists(),
        isFalse,
      );
    });
  });

  group('ManagedArtifactStorageAdapter delete', () {
    test('deletes an existing sidecar and is idempotent', () async {
      await adapter.writeArtifact(
        storageKey: 'artifacts/artifact_0001.json',
        bytes: payload(),
      );

      await adapter.deleteArtifact('artifacts/artifact_0001.json');
      expect(
        await adapter.readArtifact(storageKey: 'artifacts/artifact_0001.json'),
        isNull,
      );
      await adapter.deleteArtifact('artifacts/artifact_0001.json');
    });
  });

  group('ManagedArtifactStorageAdapter validation', () {
    test('missing sidecar reads as null', () async {
      expect(
        await adapter.readArtifact(storageKey: 'artifacts/missing.json'),
        isNull,
      );
    });

    test('size mismatch is a typed corruption failure', () async {
      final bytes = payload();
      await adapter.writeArtifact(
        storageKey: 'artifacts/artifact_0001.json',
        bytes: bytes,
      );

      await expectLater(
        adapter.readArtifact(
          storageKey: 'artifacts/artifact_0001.json',
          expectedSizeBytes: bytes.length + 1,
        ),
        throwsA(
          isA<ManagedArtifactStorageException>().having(
            (error) => error.failure,
            'failure',
            ManagedArtifactStorageFailure.sizeMismatch,
          ),
        ),
      );
    });

    test('digest mismatch is a typed corruption failure', () async {
      final bytes = payload();
      await adapter.writeArtifact(
        storageKey: 'artifacts/artifact_0001.json',
        bytes: bytes,
      );

      await expectLater(
        adapter.readArtifact(
          storageKey: 'artifacts/artifact_0001.json',
          expectedSha256: 'f' * 64,
        ),
        throwsA(
          isA<ManagedArtifactStorageException>().having(
            (error) => error.failure,
            'failure',
            ManagedArtifactStorageFailure.digestMismatch,
          ),
        ),
      );
    });

    test('unsafe storage keys are rejected before any IO', () async {
      final unsafeKeys = <String>[
        '../escape.json',
        '/absolute/escape.json',
        r'C:\escape.json',
        'a:b/escape.json',
        '',
      ];

      for (final key in unsafeKeys) {
        await expectLater(
          adapter.writeArtifact(storageKey: key, bytes: <int>[1]),
          throwsA(
            isA<ManagedArtifactStorageException>().having(
              (error) => error.failure,
              'failure',
              ManagedArtifactStorageFailure.unsafeStorageKey,
            ),
          ),
          reason: key,
        );
        await expectLater(
          adapter.readArtifact(storageKey: key),
          throwsA(
            isA<ManagedArtifactStorageException>().having(
              (error) => error.failure,
              'failure',
              ManagedArtifactStorageFailure.unsafeStorageKey,
            ),
          ),
          reason: key,
        );
        await expectLater(
          adapter.deleteArtifact(key),
          throwsA(
            isA<ManagedArtifactStorageException>().having(
              (error) => error.failure,
              'failure',
              ManagedArtifactStorageFailure.unsafeStorageKey,
            ),
          ),
          reason: key,
        );
      }
      expect(
        await Directory(
          p.join(tempDir.path, '..', 'escape.json'),
        ).exists(),
        isFalse,
      );
    });

    test('unsafe artifact identities cannot allocate storage keys', () {
      final unsafeIds = <String>[
        '',
        'bad id!',
        '../x',
        'a/b',
        'x' * 129,
      ];

      for (final artifactId in unsafeIds) {
        expect(
          () => adapter.allocateArtifactStorageKey(artifactId),
          throwsA(
            isA<ManagedArtifactStorageException>().having(
              (error) => error.failure,
              'failure',
              ManagedArtifactStorageFailure.unsafeArtifactId,
            ),
          ),
          reason: artifactId,
        );
      }
    });
  });
}

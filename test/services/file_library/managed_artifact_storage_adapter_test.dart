import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/services/file_library/managed_artifact_storage.dart';
import 'package:shiroha_quiz/services/file_library/managed_artifact_storage_adapter.dart';

const String _payloadSha256 =
    'd0546103008cfd9b7d041387f5cc501d7824dc609a8029105836156abc234171';

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

      final written = await adapter.writeArtifact(
        storageKey: 'artifacts/artifact_0001.json',
        bytes: bytes,
      );

      expect(written.sha256, _payloadSha256);
      expect(written.sizeBytes, bytes.length);
      final read = await adapter.readArtifact(
        storageKey: 'artifacts/artifact_0001.json',
        expectedSha256: _payloadSha256,
        expectedSizeBytes: bytes.length,
      );
      expect(read, isNotNull);
      expect(read!.bytes, bytes);
      expect(read.sha256, _payloadSha256);
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

    test('existing-final rejection leaves no temp leftovers', () async {
      final bytes = payload();
      await adapter.writeArtifact(
        storageKey: 'artifacts/artifact_0001.json',
        bytes: bytes,
      );

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
      final entries = Directory(
        p.join(tempDir.path, 'artifacts'),
      ).listSync();
      expect(
        entries.map((entity) => p.basename(entity.path)).toList(),
        <String>['artifact_0001.json'],
      );
    });

    test('concurrent writes to one key finalize exactly one winner', () async {
      final bytesA = 'payload-A'.codeUnits;
      final bytesB = 'payload-B-longer'.codeUnits;
      const key = 'artifacts/artifact_0001.json';

      final outcomes = await Future.wait<Object>([
        adapter
            .writeArtifact(storageKey: key, bytes: bytesA)
            .then<Object>((result) => result, onError: (Object error) => error),
        adapter
            .writeArtifact(storageKey: key, bytes: bytesB)
            .then<Object>((result) => result, onError: (Object error) => error),
      ]);

      final successes = outcomes.whereType<ArtifactWriteResult>().toList();
      final failures =
          outcomes.whereType<ManagedArtifactStorageException>().toList();
      expect(successes, hasLength(1));
      expect(failures, hasLength(1));
      expect(
        failures.single.failure,
        ManagedArtifactStorageFailure.alreadyFinalized,
      );

      final winner = successes.single;
      final winnerBytes = winner.sizeBytes == bytesA.length ? bytesA : bytesB;
      final read = await adapter.readArtifact(storageKey: key);
      expect(read, isNotNull);
      expect(read!.bytes, winnerBytes);
      expect(read.sizeBytes, winner.sizeBytes);
      expect(read.sha256, winner.sha256);

      final entries = Directory(
        p.join(tempDir.path, 'artifacts'),
      ).listSync();
      expect(
        entries.map((entity) => p.basename(entity.path)).toList(),
        <String>['artifact_0001.json'],
      );
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
      final entries = Directory(tempDir.path).listSync();
      expect(
        entries.map((entity) => p.basename(entity.path)).toList(),
        <String>['artifacts'],
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

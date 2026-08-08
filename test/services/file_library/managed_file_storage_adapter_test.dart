// F0 ManagedFileStorage adapter contract: copy-only ingestion, SHA-256 /
// size integrity, root containment, traversal/absolute/drive-escape
// rejection, existence and cleanup.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/services/file_library/managed_file_storage_adapter.dart';

const List<String> _unsafeKeys = <String>[
  '',
  '../evil',
  'library/../evil',
  'a/../../evil',
  '/abs',
  r'\abs',
  'C:/abs',
  r'C:\abs',
  'library//x',
  'library/.',
  'library/x:y',
];

void main() {
  late Directory tempDir;
  late Directory managedRoot;
  late ManagedFileStorageAdapter storage;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('f0_storage_');
    managedRoot = Directory(p.join(tempDir.path, 'managed'));
    storage = ManagedFileStorageAdapter(managedRoot: managedRoot);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<File> writeSource(String name, List<int> bytes) async {
    final source = File(p.join(tempDir.path, name));
    await source.writeAsBytes(bytes, flush: true);
    return source;
  }

  test('copy computes SHA-256 and size over the exact bytes', () async {
    const vectors = <String, String>{
      'abc': 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      '': 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq':
          '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
    };

    var index = 0;
    for (final entry in vectors.entries) {
      final source = await writeSource(
        'source_$index.txt',
        entry.key.codeUnits,
      );
      final key = storage.allocateStorageKey('file-vector-$index');
      final result = await storage.copyIntoManagedStorage(
        externalPath: source.path,
        storageKey: key,
      );

      expect(result.storageKey, key);
      expect(result.sha256, entry.value);
      expect(result.sizeBytes, entry.key.codeUnits.length);

      final managed = storage.resolveManagedFile(key);
      expect(await managed.readAsBytes(), entry.key.codeUnits);
      index++;
    }
  });

  test('resolve/existence/delete operate inside the managed root', () async {
    final source = await writeSource('source.txt', 'abc'.codeUnits);
    final key = storage.allocateStorageKey('file-lifecycle');
    await storage.copyIntoManagedStorage(
      externalPath: source.path,
      storageKey: key,
    );

    final resolved = storage.resolveManagedFile(key);
    expect(p.isWithin(managedRoot.path, resolved.path), isTrue);
    expect(await storage.managedFileExists(key), isTrue);
    expect(await resolved.exists(), isTrue);

    await storage.deleteManagedFile(key);
    expect(await storage.managedFileExists(key), isFalse);
    expect(await resolved.exists(), isFalse);
    // Deleting again is a no-op.
    await storage.deleteManagedFile(key);
  });

  test('unsafe storage keys are rejected by every operation', () async {
    final source = await writeSource('source.txt', 'abc'.codeUnits);
    for (final key in _unsafeKeys) {
      expect(
        () => storage.resolveManagedFile(key),
        throwsA(
          isA<ManagedFileStorageException>().having(
            (e) => e.failure,
            'failure',
            ManagedFileStorageFailure.unsafeStorageKey,
          ),
        ),
        reason: 'resolve: $key',
      );
      await expectLater(
        storage.copyIntoManagedStorage(
          externalPath: source.path,
          storageKey: key,
        ),
        throwsA(
          isA<ManagedFileStorageException>().having(
            (e) => e.failure,
            'failure',
            ManagedFileStorageFailure.unsafeStorageKey,
          ),
        ),
        reason: 'copy: $key',
      );
      await expectLater(
        storage.managedFileExists(key),
        throwsA(
          isA<ManagedFileStorageException>().having(
            (e) => e.failure,
            'failure',
            ManagedFileStorageFailure.unsafeStorageKey,
          ),
        ),
        reason: 'exists: $key',
      );
      await expectLater(
        storage.deleteManagedFile(key),
        throwsA(
          isA<ManagedFileStorageException>().having(
            (e) => e.failure,
            'failure',
            ManagedFileStorageFailure.unsafeStorageKey,
          ),
        ),
        reason: 'delete: $key',
      );
    }
    expect(managedRoot.existsSync(), isFalse);
  });

  test('missing external source fails with no managed residue', () async {
    final key = storage.allocateStorageKey('file-missing');
    await expectLater(
      storage.copyIntoManagedStorage(
        externalPath: p.join(tempDir.path, 'does_not_exist.pdf'),
        storageKey: key,
      ),
      throwsA(
        isA<ManagedFileStorageException>().having(
          (e) => e.failure,
          'failure',
          ManagedFileStorageFailure.sourceMissing,
        ),
      ),
    );
    expect(await storage.managedFileExists(key), isFalse);
    expect(
      Directory(p.join(managedRoot.path, 'library')).existsSync(),
      isFalse,
    );
  });

  test('allocateStorageKey produces a safe relative identity', () {
    final key = storage.allocateStorageKey('file-alloc-0001');
    expect(key, 'library/file-alloc-0001');
    expect(p.isAbsolute(key), isFalse);

    for (final fileId in <String>[
      '',
      '../escape',
      'has space',
      'C:evil',
    ]) {
      expect(
        () => storage.allocateStorageKey(fileId),
        throwsA(
          isA<ManagedFileStorageException>().having(
            (e) => e.failure,
            'failure',
            ManagedFileStorageFailure.unsafeStorageKey,
          ),
        ),
        reason: 'fileId: $fileId',
      );
    }
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/supplemental_answers/supplemental_source_inspection.dart';
import 'package:shiroha_quiz/domain/assets/library_file.dart';
import 'package:shiroha_quiz/services/file_library/managed_file_storage_adapter.dart';
import 'package:shiroha_quiz/services/file_library/supplemental_source_reader.dart';

const _abcSha256 =
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';
const _storageKey = 'library/file-1';

void main() {
  group('SupplementalSourceReader', () {
    late Directory managedRoot;
    late ManagedFileStorageAdapter storage;
    late SupplementalSourceReader reader;

    setUp(() async {
      managedRoot = await Directory.systemTemp.createTemp('sv-c1-reader-');
      storage = ManagedFileStorageAdapter(managedRoot: managedRoot);
      reader = SupplementalSourceReader(managedStorage: storage);
    });

    tearDown(() async {
      if (await managedRoot.exists()) {
        await managedRoot.delete(recursive: true);
      }
    });

    test('reads managed original bytes and hashes those exact bytes', () async {
      final managedFile = storage.resolveManagedFile(_storageKey);
      await managedFile.parent.create(recursive: true);
      await managedFile.writeAsBytes(<int>[97, 98, 99]);

      final result = await reader.readOriginalBytes(
        file: _file(),
        maxBytes: 3,
      );

      expect(result.bytes, <int>[97, 98, 99]);
      expect(result.actualSizeBytes, 3);
      expect(result.actualSha256, _abcSha256);
      expect(
        () => result.bytes[0] = 0,
        throwsUnsupportedError,
      );
    });

    test('fails when actual streamed bytes exceed budget despite metadata',
        () async {
      final managedFile = storage.resolveManagedFile(_storageKey);
      await managedFile.parent.create(recursive: true);
      await managedFile.writeAsBytes(List<int>.filled(1024 * 1024, 7));

      await expectLater(
        reader.readOriginalBytes(
          file: _file(sizeBytes: 1),
          maxBytes: 4,
        ),
        throwsA(
          isA<SupplementalSourceReaderException>().having(
            (error) => error.failure,
            'failure',
            SupplementalSourceReaderFailure.resourceLimitExceeded,
          ),
        ),
      );
    });

    test('reports a missing managed file without exposing its path or key',
        () async {
      try {
        await reader.readOriginalBytes(file: _file(), maxBytes: 8);
        fail('Expected the missing managed file to fail closed.');
      } on SupplementalSourceReaderException catch (error) {
        expect(
          error.failure,
          SupplementalSourceReaderFailure.fileUnavailable,
        );
        expect(error.toString(), isNot(contains(managedRoot.path)));
        expect(error.toString(), isNot(contains(_storageKey)));
      }
    });
  });
}

LibraryFile _file({int sizeBytes = 3}) {
  return LibraryFile(
    fileId: 'file-1',
    displayName: 'source.pdf',
    mimeType: 'application/pdf',
    sizeBytes: sizeBytes,
    sha256: _abcSha256,
    storageKey: _storageKey,
    createdAt: DateTime.utc(2026, 1, 1),
  );
}

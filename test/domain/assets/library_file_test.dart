// F0 LibraryFile domain contract: bounded opaque identity, safe relative
// storage keys, lowercase SHA-256 hex, and no physical-path / project /
// OCR ownership in the model.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/domain/assets/library_file.dart';

LibraryFile sample({
  String fileId = 'file-a1b2c3d4',
  String displayName = 'exam.pdf',
  String mimeType = 'application/pdf',
  int sizeBytes = 1024,
  String sha256 =
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
  String storageKey = 'library/file-a1b2c3d4',
}) {
  return LibraryFile(
    fileId: fileId,
    displayName: displayName,
    mimeType: mimeType,
    sizeBytes: sizeBytes,
    sha256: sha256,
    storageKey: storageKey,
    createdAt: DateTime.utc(2026, 8, 8, 12),
  );
}

void main() {
  test('constructs and compares structurally', () {
    final first = sample();
    final second = sample();
    expect(first, second);
    expect(first.hashCode, second.hashCode);

    expect(sample(displayName: 'other.pdf'), isNot(first));
    expect(sample(fileId: 'file-other'), isNot(first));
    expect(sample(storageKey: 'library/file-other'), isNot(first));
    expect(sample(sizeBytes: 2048), isNot(first));
  });

  group('validation', () {
    test('rejects unsafe storage keys', () {
      for (final key in <String>[
        '',
        '../library/x',
        'library/../x',
        'library/a/../../x',
        '/library/x',
        r'\library\x',
        'C:/library/x',
        r'C:\library\x',
        'library//x',
        'library/.',
        'library/x:y',
        'library/x ',
        'library/ x',
      ]) {
        expect(
          () => sample(storageKey: key),
          throwsA(isA<FormatException>()),
          reason: 'key: $key',
        );
        expect(LibraryFile.isSafeStorageKey(key), isFalse, reason: key);
      }
    });

    test('accepts relative token storage keys', () {
      for (final key in <String>[
        'library/file-a1b2c3d4',
        'library/2026/08/uuid-123',
        'a/b.c-d_e/f0',
      ]) {
        expect(LibraryFile.isSafeStorageKey(key), isTrue, reason: key);
        expect(() => sample(storageKey: key), returnsNormally);
      }
    });

    test('rejects malformed identities and metadata', () {
      expect(
        () => sample(fileId: ''),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => sample(fileId: 'has space'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => sample(displayName: '   '),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => sample(mimeType: 'application'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => sample(mimeType: 'Application/PDF'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => sample(sizeBytes: -1),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => sample(
          sha256:
              'BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD',
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => sample(sha256: 'abc'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => sample(sha256: 'z' * 64),
        throwsA(isA<FormatException>()),
      );
    });
  });

  test('model stays free of physical paths and downstream ownership', () {
    final source =
        File('lib/domain/assets/library_file.dart').readAsStringSync();
    expect(source, isNot(contains('dart:io')));
    expect(source, isNot(contains('sqflite')));
    expect(source, isNot(contains('projectId;')));
    expect(source, isNot(contains('absolutePath;')));
    expect(source, isNot(contains('ocrPayload')));
  });
}

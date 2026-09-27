import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/domain/answer_completion/imported_question_set.dart';

const String _setId = '3f1b0a52-9c6d-4b8e-8f0a-1c2d3e4f5a6b';
const String _itemSetId = 'a1b2c3d4-e5f6-4789-abcd-ef0123456789';
const String _storageId = 'b7c8d9e0-f1a2-4b3c-9d4e-5f6a7b8c9d0e';

Matcher _throwsValidationFailure(ImportedQuestionSetValidationFailure failure) {
  return throwsA(
    isA<ImportedQuestionSetValidationException>().having(
      (exception) => exception.failure,
      'failure',
      failure,
    ),
  );
}

String _scalars(String scalar, int count) {
  return List<String>.filled(count, scalar).join();
}

void main() {
  group('ImportedQuestionSet', () {
    test('constructs with the frozen fields', () {
      final set = ImportedQuestionSet(
        setId: _setId,
        bankName: '数学一',
        displayName: '2021数学一真题.pdf',
        createdAt: 1758888888,
      );

      expect(set.setId, _setId);
      expect(set.bankName, '数学一');
      expect(set.displayName, '2021数学一真题.pdf');
      expect(set.createdAt, 1758888888);
      expect(set.sourceFileId, isNull);
    });

    test('accepts an optional bounded LibraryFile token reference', () {
      for (final sourceFileId in <String>[
        'file-abc',
        'a',
        '2021.math_1-a',
        _scalars('a', 128),
      ]) {
        final set = ImportedQuestionSet(
          setId: _setId,
          bankName: 'b',
          displayName: 'a.pdf',
          createdAt: 0,
          sourceFileId: sourceFileId,
        );

        expect(set.sourceFileId, sourceFileId);
      }
    });

    test('rejects every non-canonical setId', () {
      for (final setId in <String>[
        '',
        'set-1',
        '3F1B0A52-9C6D-4B8E-8F0A-1C2D3E4F5A6B',
        '3f1b0a52-9c6d-1b8e-8f0a-1c2d3e4f5a6b',
        '3f1b0a52-9c6d-4b8e-7f0a-1c2d3e4f5a6b',
        '3f1b0a52-9c6d-4b8e-8f0a-1c2d3e4f5a6',
      ]) {
        expect(
          () => ImportedQuestionSet(
            setId: setId,
            bankName: 'b',
            displayName: 'a.pdf',
            createdAt: 0,
          ),
          _throwsValidationFailure(
            ImportedQuestionSetValidationFailure.invalidSetId,
          ),
          reason: 'setId $setId must be rejected',
        );
      }
    });

    test('rejects every path-like or non-token sourceFileId', () {
      for (final sourceFileId in <String>[
        '',
        '/tmp/a.pdf',
        'C:\\a.pdf',
        'a/b.pdf',
        '.hidden',
        '-leading',
        _scalars('a', 129),
      ]) {
        expect(
          () => ImportedQuestionSet(
            setId: _setId,
            bankName: 'b',
            displayName: 'a.pdf',
            createdAt: 0,
            sourceFileId: sourceFileId,
          ),
          _throwsValidationFailure(
            ImportedQuestionSetValidationFailure.invalidSourceFileId,
          ),
          reason: 'sourceFileId $sourceFileId must be rejected',
        );
      }
    });

    test('rejects an empty bankName', () {
      expect(
        () => ImportedQuestionSet(
          setId: _setId,
          bankName: '',
          displayName: 'a.pdf',
          createdAt: 0,
        ),
        _throwsValidationFailure(
          ImportedQuestionSetValidationFailure.invalidBankName,
        ),
      );
    });

    test('rejects an empty displayName', () {
      expect(
        () => ImportedQuestionSet(
          setId: _setId,
          bankName: 'b',
          displayName: '',
          createdAt: 0,
        ),
        _throwsValidationFailure(
          ImportedQuestionSetValidationFailure.invalidDisplayName,
        ),
      );
    });

    test('accepts 256 scalars and rejects 257 scalars', () {
      final set = ImportedQuestionSet(
        setId: _setId,
        bankName: 'b',
        displayName: _scalars('a', 256),
        createdAt: 0,
      );
      expect(set.displayName.runes.length, 256);

      expect(
        () => ImportedQuestionSet(
          setId: _setId,
          bankName: 'b',
          displayName: _scalars('a', 257),
          createdAt: 0,
        ),
        _throwsValidationFailure(
          ImportedQuestionSetValidationFailure.invalidDisplayName,
        ),
      );
    });

    test('counts Unicode scalars instead of UTF-16 code units', () {
      final emojiName = _scalars('\u{1F600}', 256);
      expect(emojiName.length, 512);
      expect(emojiName.runes.length, 256);

      final set = ImportedQuestionSet(
        setId: _setId,
        bankName: 'b',
        displayName: emojiName,
        createdAt: 0,
      );
      expect(set.displayName, emojiName);

      expect(
        () => ImportedQuestionSet(
          setId: _setId,
          bankName: 'b',
          displayName: _scalars('\u{1F600}', 257),
          createdAt: 0,
        ),
        _throwsValidationFailure(
          ImportedQuestionSetValidationFailure.invalidDisplayName,
        ),
      );
    });

    test('rejects display names containing an unpaired surrogate half', () {
      for (final rune in <int>[0xd800, 0xdfff]) {
        final displayName = 'a${String.fromCharCode(rune)}b';
        expect(
          () => ImportedQuestionSet(
            setId: _setId,
            bankName: 'b',
            displayName: displayName,
            createdAt: 0,
          ),
          _throwsValidationFailure(
            ImportedQuestionSetValidationFailure.invalidDisplayName,
          ),
          reason: 'surrogate half U+${rune.toRadixString(16)} must be rejected',
        );
      }
    });

    test('rejects display names containing a path separator', () {
      for (final displayName in <String>['a/b.pdf', 'a\\b.pdf', '/', '\\']) {
        expect(
          () => ImportedQuestionSet(
            setId: _setId,
            bankName: 'b',
            displayName: displayName,
            createdAt: 0,
          ),
          _throwsValidationFailure(
            ImportedQuestionSetValidationFailure.invalidDisplayName,
          ),
          reason: 'displayName $displayName must be rejected',
        );
      }
    });

    test('rejects display names containing control runes', () {
      for (final rune in <int>[0x00, 0x1f, 0x7f, 0x9f]) {
        final displayName = 'a${String.fromCharCode(rune)}b';
        expect(
          () => ImportedQuestionSet(
            setId: _setId,
            bankName: 'b',
            displayName: displayName,
            createdAt: 0,
          ),
          _throwsValidationFailure(
            ImportedQuestionSetValidationFailure.invalidDisplayName,
          ),
          reason: 'control rune U+${rune.toRadixString(16)} must be rejected',
        );
      }
    });

    test('rejects a negative createdAt', () {
      expect(
        () => ImportedQuestionSet(
          setId: _setId,
          bankName: 'b',
          displayName: 'a.pdf',
          createdAt: -1,
        ),
        _throwsValidationFailure(
          ImportedQuestionSetValidationFailure.invalidCreatedAt,
        ),
      );
    });

    test('keeps a display name verbatim without trimming', () {
      final set = ImportedQuestionSet(
        setId: _setId,
        bankName: 'b',
        displayName: ' exam.pdf ',
        createdAt: 0,
      );

      expect(set.displayName, ' exam.pdf ');
    });
  });

  group('ImportedQuestionSetItem', () {
    test('accepts position 0', () {
      final item = ImportedQuestionSetItem(
        setId: _itemSetId,
        questionStorageId: _storageId,
        position: 0,
      );

      expect(item.setId, _itemSetId);
      expect(item.questionStorageId, _storageId);
      expect(item.position, 0);
    });

    test('accepts a positive position', () {
      final item = ImportedQuestionSetItem(
        setId: _itemSetId,
        questionStorageId: _storageId,
        position: 21,
      );

      expect(item.position, 21);
    });

    test('rejects a negative position', () {
      expect(
        () => ImportedQuestionSetItem(
          setId: _itemSetId,
          questionStorageId: _storageId,
          position: -1,
        ),
        _throwsValidationFailure(
          ImportedQuestionSetValidationFailure.invalidPosition,
        ),
      );
    });

    test('rejects a non-canonical setId', () {
      for (final setId in <String>['', 'set-1']) {
        expect(
          () => ImportedQuestionSetItem(
            setId: setId,
            questionStorageId: _storageId,
            position: 0,
          ),
          _throwsValidationFailure(
            ImportedQuestionSetValidationFailure.invalidSetId,
          ),
          reason: 'setId $setId must be rejected',
        );
      }
    });

    test('rejects an empty questionStorageId', () {
      expect(
        () => ImportedQuestionSetItem(
          setId: _itemSetId,
          questionStorageId: '',
          position: 0,
        ),
        _throwsValidationFailure(
          ImportedQuestionSetValidationFailure.invalidQuestionStorageId,
        ),
      );
    });
  });
}

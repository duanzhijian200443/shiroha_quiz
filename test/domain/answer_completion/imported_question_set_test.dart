import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/domain/answer_completion/imported_question_set.dart';

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
        setId: 'set-1',
        bankName: '数学一',
        displayName: '2021数学一真题.pdf',
        createdAt: 1758888888,
      );

      expect(set.setId, 'set-1');
      expect(set.bankName, '数学一');
      expect(set.displayName, '2021数学一真题.pdf');
      expect(set.createdAt, 1758888888);
      expect(set.sourceFileId, isNull);
    });

    test('accepts an optional non-empty source file reference', () {
      final set = ImportedQuestionSet(
        setId: 'set-1',
        bankName: 'b',
        displayName: 'a.pdf',
        createdAt: 0,
        sourceFileId: 'file-abc',
      );

      expect(set.sourceFileId, 'file-abc');
    });

    test('rejects an empty setId', () {
      expect(
        () => ImportedQuestionSet(
          setId: '',
          bankName: 'b',
          displayName: 'a.pdf',
          createdAt: 0,
        ),
        _throwsValidationFailure(
          ImportedQuestionSetValidationFailure.invalidSetId,
        ),
      );
    });

    test('rejects an empty bankName', () {
      expect(
        () => ImportedQuestionSet(
          setId: 'set-1',
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
          setId: 'set-1',
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
        setId: 'set-1',
        bankName: 'b',
        displayName: _scalars('a', 256),
        createdAt: 0,
      );
      expect(set.displayName.runes.length, 256);

      expect(
        () => ImportedQuestionSet(
          setId: 'set-1',
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
        setId: 'set-1',
        bankName: 'b',
        displayName: emojiName,
        createdAt: 0,
      );
      expect(set.displayName, emojiName);

      expect(
        () => ImportedQuestionSet(
          setId: 'set-1',
          bankName: 'b',
          displayName: _scalars('\u{1F600}', 257),
          createdAt: 0,
        ),
        _throwsValidationFailure(
          ImportedQuestionSetValidationFailure.invalidDisplayName,
        ),
      );
    });

    test('rejects display names containing a path separator', () {
      for (final displayName in <String>['a/b.pdf', 'a\\b.pdf', '/', '\\']) {
        expect(
          () => ImportedQuestionSet(
            setId: 'set-1',
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
            setId: 'set-1',
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
          setId: 'set-1',
          bankName: 'b',
          displayName: 'a.pdf',
          createdAt: -1,
        ),
        _throwsValidationFailure(
          ImportedQuestionSetValidationFailure.invalidCreatedAt,
        ),
      );
    });

    test('rejects an empty source file reference', () {
      expect(
        () => ImportedQuestionSet(
          setId: 'set-1',
          bankName: 'b',
          displayName: 'a.pdf',
          createdAt: 0,
          sourceFileId: '',
        ),
        _throwsValidationFailure(
          ImportedQuestionSetValidationFailure.invalidSourceFileId,
        ),
      );
    });

    test('keeps a display name verbatim without trimming', () {
      final set = ImportedQuestionSet(
        setId: 'set-1',
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
        setId: 'set-1',
        questionStorageId: 'storage-1',
        position: 0,
      );

      expect(item.setId, 'set-1');
      expect(item.questionStorageId, 'storage-1');
      expect(item.position, 0);
    });

    test('accepts a positive position', () {
      final item = ImportedQuestionSetItem(
        setId: 'set-1',
        questionStorageId: 'storage-1',
        position: 21,
      );

      expect(item.position, 21);
    });

    test('rejects a negative position', () {
      expect(
        () => ImportedQuestionSetItem(
          setId: 'set-1',
          questionStorageId: 'storage-1',
          position: -1,
        ),
        _throwsValidationFailure(
          ImportedQuestionSetValidationFailure.invalidPosition,
        ),
      );
    });

    test('rejects an empty setId', () {
      expect(
        () => ImportedQuestionSetItem(
          setId: '',
          questionStorageId: 'storage-1',
          position: 0,
        ),
        _throwsValidationFailure(
          ImportedQuestionSetValidationFailure.invalidSetId,
        ),
      );
    });

    test('rejects an empty questionStorageId', () {
      expect(
        () => ImportedQuestionSetItem(
          setId: 'set-1',
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

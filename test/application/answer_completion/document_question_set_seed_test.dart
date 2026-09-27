import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/answer_completion/document_question_set_seed.dart';

const DocumentQuestionSetSeedCodec _codec = DocumentQuestionSetSeedCodec();
const String _displayName = 'a.pdf';

Matcher _throwsSeedFailure(DocumentQuestionSetSeedFailure failure) {
  return throwsA(
    isA<DocumentQuestionSetSeedException>().having(
      (exception) => exception.failure,
      'failure',
      failure,
    ),
  );
}

String _scalars(String scalar, int count) {
  return List<String>.filled(count, scalar).join();
}

Map<String, Object?> _envelope({
  Object? schemaVersion = 1,
  Object? capture = true,
  Object? displayName = '2021数学一真题.pdf',
  Object? sourceFileId,
}) {
  return <String, Object?>{
    'schemaVersion': schemaVersion,
    'capture': capture,
    'displayName': displayName,
    'sourceFileId': sourceFileId,
  };
}

Map<String, Object?> _withoutKey(String key) {
  return _envelope()..remove(key);
}

int _byteLengthOf(String displayName, String sourceFileId) {
  return utf8
      .encode(
        jsonEncode(<String, Object?>{
          'schemaVersion': 1,
          'capture': true,
          'displayName': displayName,
          'sourceFileId': sourceFileId,
        }),
      )
      .length;
}

void main() {
  group('DocumentQuestionSetSeedCodec encode', () {
    test('encodes the canonical exact-key envelope', () {
      final encoded = _codec.encode(
        DocumentQuestionSetSeed(displayName: '2021数学一真题.pdf'),
      );

      expect(encoded.length, 4);
      expect(encoded.keys.toSet(), <String>{
        'schemaVersion',
        'capture',
        'displayName',
        'sourceFileId',
      });
      expect(encoded['schemaVersion'], 1);
      expect(encoded['capture'], true);
      expect(encoded['displayName'], '2021数学一真题.pdf');
      expect(encoded['sourceFileId'], isNull);
    });

    test('encodes a non-empty sourceFileId', () {
      final encoded = _codec.encode(
        DocumentQuestionSetSeed(
            displayName: _displayName, sourceFileId: 'file-1'),
      );

      expect(encoded['sourceFileId'], 'file-1');
    });

    test('rejects an envelope above the byte cap', () {
      final overhead = _byteLengthOf(_displayName, '');
      final maxIdLength =
          DocumentQuestionSetSeedCodec.maxEnvelopeBytes - overhead;
      final atCap = _scalars('a', maxIdLength);
      final aboveCap = _scalars('a', maxIdLength + 1);

      expect(
        _byteLengthOf(_displayName, atCap),
        DocumentQuestionSetSeedCodec.maxEnvelopeBytes,
      );
      expect(
        _codec.encode(
          DocumentQuestionSetSeed(
            displayName: _displayName,
            sourceFileId: atCap,
          ),
        )['sourceFileId'],
        atCap,
      );
      expect(
        () => _codec.encode(
          DocumentQuestionSetSeed(
            displayName: _displayName,
            sourceFileId: aboveCap,
          ),
        ),
        _throwsSeedFailure(DocumentQuestionSetSeedFailure.oversize),
      );
    });
  });

  group('DocumentQuestionSetSeedCodec decode valid', () {
    test('round-trips a null sourceFileId', () {
      final encoded = _codec.encode(
        DocumentQuestionSetSeed(displayName: '2021数学一真题.pdf'),
      );

      final decoded = _codec.decode(encoded);

      expect(decoded.displayName, '2021数学一真题.pdf');
      expect(decoded.sourceFileId, isNull);
      expect(_codec.encode(decoded), encoded);
    });

    test('round-trips a non-empty sourceFileId', () {
      final encoded = _codec.encode(
        DocumentQuestionSetSeed(
            displayName: _displayName, sourceFileId: 'file-1'),
      );

      final decoded = _codec.decode(encoded);

      expect(decoded.displayName, _displayName);
      expect(decoded.sourceFileId, 'file-1');
      expect(_codec.encode(decoded), encoded);
    });

    test('accepts 256 scalars and counts emoji as single scalars', () {
      final emojiName = _scalars('\u{1F600}', 256);
      expect(emojiName.length, 512);

      final decoded = _codec.decode(_envelope(displayName: emojiName));

      expect(decoded.displayName, emojiName);
      expect(decoded.displayName.runes.length, 256);
    });

    test('accepts exactly 256 scalars', () {
      final displayName = _scalars('a', 256);

      expect(_codec.decode(_envelope(displayName: displayName)).displayName,
          displayName);
    });
  });

  group('DocumentQuestionSetSeedCodec decode displayName invalid', () {
    test('rejects 0 scalars', () {
      expect(
        () => _codec.decode(_envelope(displayName: '')),
        _throwsSeedFailure(DocumentQuestionSetSeedFailure.invalidEnvelope),
      );
    });

    test('rejects 257 scalars', () {
      expect(
        () => _codec.decode(_envelope(displayName: _scalars('a', 257))),
        _throwsSeedFailure(DocumentQuestionSetSeedFailure.invalidEnvelope),
      );
    });

    test('rejects path separators', () {
      for (final displayName in <String>['a/b.pdf', 'a\\b.pdf']) {
        expect(
          () => _codec.decode(_envelope(displayName: displayName)),
          _throwsSeedFailure(DocumentQuestionSetSeedFailure.invalidEnvelope),
          reason: 'displayName $displayName must be rejected',
        );
      }
    });

    test('rejects control characters', () {
      for (final rune in <int>[0x00, 0x1f, 0x7f, 0x9f]) {
        final displayName = 'a${String.fromCharCode(rune)}b';
        expect(
          () => _codec.decode(_envelope(displayName: displayName)),
          _throwsSeedFailure(DocumentQuestionSetSeedFailure.invalidEnvelope),
          reason: 'control rune U+${rune.toRadixString(16)} must be rejected',
        );
      }
    });

    test('rejects a non-string displayName', () {
      expect(
        () => _codec.decode(_envelope(displayName: 42)),
        _throwsSeedFailure(DocumentQuestionSetSeedFailure.invalidEnvelope),
      );
    });
  });

  group('DocumentQuestionSetSeedCodec decode envelope invalid', () {
    test('rejects a null root', () {
      expect(
        () => _codec.decode(null),
        _throwsSeedFailure(DocumentQuestionSetSeedFailure.invalidEnvelope),
      );
    });

    test('rejects a non-map root', () {
      for (final root in <Object?>[
        'document_v3',
        42,
        true,
        <Object?>[1]
      ]) {
        expect(
          () => _codec.decode(root),
          _throwsSeedFailure(DocumentQuestionSetSeedFailure.invalidEnvelope),
          reason: 'root $root must be rejected',
        );
      }
    });

    test('rejects a non-string JSON object key', () {
      final withNonStringKey = <Object?, Object?>{
        7: 'nope',
        'schemaVersion': 1,
        'capture': true,
        'displayName': 'a.pdf',
        'sourceFileId': null,
      };
      final replacingKey = <Object?, Object?>{
        1: 1,
        'capture': true,
        'displayName': 'a.pdf',
        'sourceFileId': null,
      };

      for (final envelope in <Map<Object?, Object?>>[
        withNonStringKey,
        replacingKey,
      ]) {
        expect(
          () => _codec.decode(envelope),
          _throwsSeedFailure(DocumentQuestionSetSeedFailure.invalidEnvelope),
        );
      }
    });

    test('rejects every missing key', () {
      for (final key in <String>[
        'schemaVersion',
        'capture',
        'displayName',
        'sourceFileId',
      ]) {
        expect(
          () => _codec.decode(_withoutKey(key)),
          _throwsSeedFailure(DocumentQuestionSetSeedFailure.invalidEnvelope),
          reason: 'missing $key must be rejected',
        );
      }
    });

    test('rejects extra and unknown extension keys', () {
      final extra = _envelope()..['extra'] = 1;
      final unknownExtension = _envelope()
        ..['_questionSetCaptureV2'] = <String, Object?>{};

      for (final envelope in <Map<String, Object?>>[extra, unknownExtension]) {
        expect(
          () => _codec.decode(envelope),
          _throwsSeedFailure(DocumentQuestionSetSeedFailure.invalidEnvelope),
        );
      }
    });
  });

  group('DocumentQuestionSetSeedCodec decode schemaVersion invalid', () {
    test('rejects a non-integer schemaVersion', () {
      for (final version in <Object?>['1', 1.0, true, null]) {
        expect(
          () => _codec.decode(_envelope(schemaVersion: version)),
          _throwsSeedFailure(DocumentQuestionSetSeedFailure.invalidEnvelope),
          reason: 'schemaVersion $version must be rejected',
        );
      }
    });

    test('classifies an unknown integer schemaVersion as unsupported', () {
      for (final version in <int>[0, 2, 3]) {
        expect(
          () => _codec.decode(_envelope(schemaVersion: version)),
          _throwsSeedFailure(
            DocumentQuestionSetSeedFailure.unsupportedSchema,
          ),
          reason: 'schemaVersion $version must not fall back silently',
        );
      }
    });
  });

  group('DocumentQuestionSetSeedCodec decode capture invalid', () {
    test('rejects every capture value other than true', () {
      for (final capture in <Object?>[false, null, 1, 'true']) {
        expect(
          () => _codec.decode(_envelope(capture: capture)),
          _throwsSeedFailure(DocumentQuestionSetSeedFailure.invalidEnvelope),
          reason: 'capture $capture must be rejected',
        );
      }
    });
  });

  group('DocumentQuestionSetSeedCodec decode sourceFileId invalid', () {
    test('rejects an empty sourceFileId', () {
      expect(
        () => _codec.decode(_envelope(sourceFileId: '')),
        _throwsSeedFailure(DocumentQuestionSetSeedFailure.invalidEnvelope),
      );
    });

    test('rejects a non-string sourceFileId', () {
      for (final sourceFileId in <Object?>[
        42,
        true,
        <Object?>[],
        <Object?, Object?>{}
      ]) {
        expect(
          () => _codec.decode(_envelope(sourceFileId: sourceFileId)),
          _throwsSeedFailure(DocumentQuestionSetSeedFailure.invalidEnvelope),
          reason: 'sourceFileId $sourceFileId must be rejected',
        );
      }
    });
  });

  group('DocumentQuestionSetSeedCodec byte cap', () {
    test('accepts a compact envelope of exactly 4096 bytes', () {
      final overhead = _byteLengthOf(_displayName, '');
      final maxIdLength =
          DocumentQuestionSetSeedCodec.maxEnvelopeBytes - overhead;
      final atCap = _scalars('a', maxIdLength);

      expect(
        _byteLengthOf(_displayName, atCap),
        DocumentQuestionSetSeedCodec.maxEnvelopeBytes,
      );

      final decoded = _codec.decode(
        _envelope(displayName: _displayName, sourceFileId: atCap),
      );

      expect(decoded.sourceFileId, atCap);
    });

    test('rejects a compact envelope above 4096 bytes on decode', () {
      final overhead = _byteLengthOf(_displayName, '');
      final aboveCap = _scalars(
        'a',
        DocumentQuestionSetSeedCodec.maxEnvelopeBytes - overhead + 1,
      );

      expect(
        () => _codec.decode(
          _envelope(displayName: _displayName, sourceFileId: aboveCap),
        ),
        _throwsSeedFailure(DocumentQuestionSetSeedFailure.oversize),
      );
    });
  });

  group('DocumentQuestionSetSeedCodec decode never repairs', () {
    test('never trims a display name', () {
      final decoded = _codec.decode(_envelope(displayName: ' exam.pdf '));

      expect(decoded.displayName, ' exam.pdf ');
    });

    test('never converts an empty sourceFileId into null', () {
      expect(
        () => _codec.decode(_envelope(sourceFileId: '')),
        _throwsSeedFailure(DocumentQuestionSetSeedFailure.invalidEnvelope),
      );
    });

    test('keeps a null sourceFileId null', () {
      expect(_codec.decode(_envelope()).sourceFileId, isNull);
    });
  });

  group('DocumentQuestionSetSeed construction', () {
    test('accepts a canonical display name', () {
      final seed = DocumentQuestionSetSeed(
        displayName: '2021数学一真题.pdf',
        sourceFileId: 'file-1',
      );

      expect(seed.displayName, '2021数学一真题.pdf');
      expect(seed.sourceFileId, 'file-1');
    });

    test('rejects a display name that is not canonical-safe', () {
      for (final displayName in <String>['', 'a/b', 'a\\b', 'a\u0000b']) {
        expect(
          () => DocumentQuestionSetSeed(displayName: displayName),
          _throwsSeedFailure(DocumentQuestionSetSeedFailure.invalidEnvelope),
          reason: 'displayName $displayName must be rejected',
        );
      }
    });

    test('rejects an empty sourceFileId', () {
      expect(
        () => DocumentQuestionSetSeed(
            displayName: _displayName, sourceFileId: ''),
        _throwsSeedFailure(DocumentQuestionSetSeedFailure.invalidEnvelope),
      );
    });
  });

  group('DocumentQuestionSetSeedCodec containsSeedKey', () {
    test('returns false without the reserved key', () {
      expect(_codec.containsSeedKey(<String, Object?>{}), isFalse);
      expect(_codec.containsSeedKey(null), isFalse);
      expect(_codec.containsSeedKey('document_v3'), isFalse);
    });

    test('returns true for a present key even when its value is null', () {
      expect(
        _codec.containsSeedKey(
          <String, Object?>{questionSetCaptureMetadataKey: null},
        ),
        isTrue,
      );
    });

    test('returns true for a present valid envelope', () {
      expect(
        _codec.containsSeedKey(
          <String, Object?>{questionSetCaptureMetadataKey: _envelope()},
        ),
        isTrue,
      );
    });

    test('keeps a present null key out of the historical-task path', () {
      final diagnostics = <String, Object?>{
        questionSetCaptureMetadataKey: null,
      };

      expect(_codec.containsSeedKey(diagnostics), isTrue);
      expect(
        () => _codec.decode(diagnostics[questionSetCaptureMetadataKey]),
        _throwsSeedFailure(DocumentQuestionSetSeedFailure.invalidEnvelope),
      );
    });
  });
}

import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/data/external/exchange_message_codec.dart';
import 'bootstrap_test_support.dart';

EnrollmentSubmission submission(
        {Uint8List? point, String? label, String? build}) =>
    EnrollmentSubmission(
        submissionId: vectorBytes('submissionId'),
        publicPoint: point ?? vectorBytes('point'),
        displayLabel: label ?? bootstrapVector['displayLabel'] as String,
        clientBuild: build ?? bootstrapVector['clientBuild'] as String);
PairingChallengeMessage challenge({Uint8List? leaf, BigInt? epoch}) =>
    PairingChallengeMessage(
        submissionId: vectorBytes('submissionId'),
        transcript: transcript(),
        publicationEpoch: epoch ?? vectorInt('publicationEpoch'),
        clientLeafDer: leaf ?? vectorBytes('clientDer'));
PossessionProofMessage proof({Uint8List? signature}) => PossessionProofMessage(
    submissionId: vectorBytes('submissionId'),
    requestId: vectorBytes('requestId'),
    rawSignature: signature ?? vectorBytes('transcriptSignature'));

void main() {
  final messages = <String, ExchangeMessage>{
    'submission': submission(),
    'challenge': challenge(),
    'proof': proof()
  };
  for (final entry in messages.entries) {
    final name = ExchangeMessageCodec.fileName(entry.value);
    test('${entry.key}: exact independent vector and round trip', () {
      final bytes = vectorBytes(entry.key);
      expect(ExchangeMessageCodec.encode(name, entry.value), bytes);
      final decoded = ExchangeMessageCodec.decode(name, bytes);
      expect(ExchangeMessageCodec.fileName(decoded), name);
      expect(ExchangeMessageCodec.encode(name, decoded), bytes);
    });
    test('${entry.key}: exact basename and internal submission binding', () {
      final bytes = vectorBytes(entry.key);
      for (final bad in [
        '$name\n',
        name.toUpperCase(),
        '../$name',
        'x/$name',
        'x\\$name',
        name.replaceFirst('000102', 'ff0102'),
        name.replaceFirst('.', '.x')
      ]) {
        expect(() => ExchangeMessageCodec.decode(bad, bytes),
            throwsFormatException);
        expect(() => ExchangeMessageCodec.encode(bad, entry.value),
            throwsFormatException);
      }
      expect(() => ExchangeMessageCodec.decode(name, changed(bytes, 9)),
          throwsFormatException);
    });
    test('${entry.key}: magic/version/cap/trailing bytes and all truncations',
        () {
      final bytes = vectorBytes(entry.key);
      for (var i = 0; i < bytes.length; i++) {
        expect(
            () => ExchangeMessageCodec.decode(
                name, Uint8List.fromList(bytes.take(i).toList())),
            throwsFormatException);
      }
      for (final bad in [
        changed(bytes, 0),
        changed(bytes, 8),
        Uint8List.fromList([...bytes, 0]),
        Uint8List(4097)
      ]) {
        expect(() => ExchangeMessageCodec.decode(name, bad),
            throwsFormatException);
      }
    });
  }

  test('UTF-8 byte caps and shortest explicit text boundaries', () {
    for (final value in [
      submission(label: 'é' * 32, build: 'é' * 16),
      submission(label: '', build: '')
    ]) {
      final name = ExchangeMessageCodec.fileName(value);
      expect(
          ExchangeMessageCodec.decode(
              name, ExchangeMessageCodec.encode(name, value)),
          isA<EnrollmentSubmission>());
    }
    for (final value in [
      submission(label: 'é' * 33),
      submission(build: 'é' * 17),
      submission(label: '\ud800')
    ]) {
      expect(
          () => ExchangeMessageCodec.encode(
              ExchangeMessageCodec.fileName(value), value),
          throwsFormatException);
    }
    final name = ExchangeMessageCodec.fileName(submission());
    final malformed = vectorBytes('submission')..[92] = 255;
    expect(() => ExchangeMessageCodec.decode(name, malformed),
        throwsFormatException);
    final long = vectorBytes('submission')..[90] = 65;
    expect(
        () => ExchangeMessageCodec.decode(name, long), throwsFormatException);
  });

  test('P21 point shape and exact client certificate/digest binding', () {
    for (final value in [
      submission(point: Uint8List(65)),
      submission(point: vectorBytes('clientDer')),
      challenge(leaf: vectorBytes('serverDer')),
      challenge(leaf: vectorBytes('issuerDer')),
      challenge(leaf: Uint8List(2049)),
      challenge(leaf: changed(vectorBytes('clientDer'), 100)),
      challenge(epoch: -BigInt.one),
      challenge(epoch: BigInt.one << 64),
      proof(signature: Uint8List(64))
    ]) {
      expect(
          () => ExchangeMessageCodec.encode(
              ExchangeMessageCodec.fileName(value), value),
          throwsFormatException);
    }
    final name = ExchangeMessageCodec.fileName(challenge());
    expect(
        () => ExchangeMessageCodec.decode(
            name, changed(vectorBytes('challenge'), 159)),
        throwsFormatException);
  });

  test(
      'private-key DER/PEM have no key, leaf or signature field representation',
      () {
    // Complete RFC5208/RFC5915 PKCS#8 with the published RFC6979 A.2.5 scalar.
    // Public test knowledge only, never a live private credential.
    final pkcs8 = unhex(
        '3041020100301306072a8648ce3d020106082a8648ce3d030107042730250201010420'
        'c9afa9d845ba75166b5c215767b1d6934e50c3db36e89b127b8a622b120f6721');
    for (final value in [
      submission(point: pkcs8),
      challenge(leaf: pkcs8),
      proof(signature: pkcs8),
      submission(
          label:
              '-----BEGIN PRIVATE KEY-----\n${'A' * 64}\n-----END PRIVATE KEY-----')
    ]) {
      expect(
          () => ExchangeMessageCodec.encode(
              ExchangeMessageCodec.fileName(value), value),
          throwsFormatException);
    }
    // Public output schemas expose no private-key, object-store or opaque extras.
    for (final entry in messages.entries) {
      expect(
          ExchangeMessageCodec.encode(
              ExchangeMessageCodec.fileName(entry.value), entry.value),
          vectorBytes(entry.key));
    }
  });
}

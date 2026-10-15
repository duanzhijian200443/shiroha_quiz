import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/data/external/pairing_transcript_codec.dart';
import 'bootstrap_test_support.dart';

void main() {
  test('independent exact transcript, digest and raw-signature vectors', () {
    final value = transcript();
    expect(PairingTranscriptCodec.encode(value), vectorBytes('transcript'));
    expect(PairingTranscriptCodec.encode(value).length, 201);
    expect(
        PairingTranscriptCodec.digest(value), vectorBytes('transcriptDigest'));
    expect(
        PairingTranscriptCodec.encode(
            PairingTranscriptCodec.decode(vectorBytes('transcript'))),
        vectorBytes('transcript'));
    expect(
        PairingTranscriptCodec.verify(value,
            publicPoint: vectorBytes('point'),
            rawSignature: vectorBytes('transcriptSignature'),
            verifier: offlineVerify),
        isTrue);
    expect(
        PairingTranscriptCodec.sign(value, signer: (digest) {
          expect(digest, vectorBytes('transcriptDigest'));
          return vectorBytes('transcriptSignature');
        }),
        vectorBytes('transcriptSignature'));
  });

  test('every bound field changes the actual digest and rejects old signature',
      () {
    for (final value in [
      transcript(nonce: changed(vectorBytes('nonce'), 0)),
      transcript(requestId: changed(vectorBytes('requestId'), 0)),
      transcript(profileId: changed(vectorBytes('profileId'), 0)),
      transcript(installationId: '10112233-4455-4677-8899-aabbccddeeff'),
      transcript(runtime: changed(vectorBytes('runtimeInstanceId'), 0)),
      transcript(generation: vectorInt('generation') + BigInt.one),
      transcript(identity: changed(vectorBytes('credentialIdentity'), 0)),
      transcript(revision: vectorInt('expectedRevision') + BigInt.one),
      transcript(expiry: vectorInt('expiresAtUtcMs') + BigInt.one),
    ]) {
      expect(
          PairingTranscriptCodec.verify(value,
              publicPoint: vectorBytes('point'),
              rawSignature: vectorBytes('transcriptSignature'),
              verifier: offlineVerify),
          isFalse);
    }
    expect(
        PairingTranscriptCodec.verify(transcript(),
            publicPoint: vectorBytes('point'),
            rawSignature: vectorBytes('descriptorSignature'),
            verifier: offlineVerify),
        isFalse);
  });

  test('strict domain/kind/order/length and every truncation', () {
    final bytes = vectorBytes('transcript');
    for (var i = 0; i < bytes.length; i++) {
      expect(
          () => PairingTranscriptCodec.decode(
              Uint8List.fromList(bytes.take(i).toList())),
          throwsFormatException);
    }
    for (final value in [
      changed(bytes, 0),
      changed(bytes, 25),
      changed(bytes, 26),
      changed(bytes, 91),
      (Uint8List.fromList(bytes)..[93] = 255),
      Uint8List.fromList([...bytes, 0]),
      Uint8List(294)
    ]) {
      expect(() => PairingTranscriptCodec.decode(value), throwsFormatException);
    }
    // Profile UUID version and RFC variant live at offsets 75+6 and 75+8.
    for (final offset in [81, 83]) {
      final invalid = Uint8List.fromList(bytes)..[offset] = 0;
      expect(
          () => PairingTranscriptCodec.decode(invalid), throwsFormatException);
    }
  });

  test('UUID and fixed-width inputs reject instead of normalization', () {
    for (final value in [
      transcript(nonce: Uint8List(31)),
      transcript(requestId: Uint8List(17)),
      transcript(profileId: Uint8List(16)),
      transcript(runtime: Uint8List(15)),
      transcript(identity: Uint8List(33)),
      transcript(installationId: '00112233-4455-4677-8899-AABBCCDDEEFF'),
      transcript(installationId: '00112233-4455-1677-8899-aabbccddeeff'),
      transcript(installationId: '00112233-4455-4677-8899-aabbccddeeff\n'),
      transcript(installationId: '\ud800'),
    ]) {
      expect(() => PairingTranscriptCodec.encode(value), throwsFormatException);
    }
  });

  test('full u64 BigInt round trips; negative and overflowing inputs reject',
      () {
    final max = (BigInt.one << 64) - BigInt.one;
    for (final n in [BigInt.zero, BigInt.one << 63, max]) {
      final value = PairingTranscriptCodec.decode(PairingTranscriptCodec.encode(
          transcript(generation: n, revision: n, expiry: n)));
      expect([value.generation, value.expectedRevision, value.expiresAtUtcMs],
          [n, n, n]);
    }
    for (final n in [-BigInt.one, max + BigInt.one]) {
      for (final value in [
        transcript(generation: n),
        transcript(revision: n),
        transcript(expiry: n)
      ]) {
        expect(
            () => PairingTranscriptCodec.encode(value), throwsFormatException);
      }
    }
  });

  test('immutable snapshots and malformed crypto fail before injected call',
      () {
    final nonce = vectorBytes('nonce');
    final value = transcript(nonce: nonce);
    nonce[0] ^= 1;
    expect(value.nonce, vectorBytes('nonce'));
    expect(() => value.nonce[0] = 1, throwsUnsupportedError);
    var calls = 0;
    bool verifier(
        {required Uint8List publicPoint,
        required Uint8List digest,
        required Uint8List rawSignature}) {
      calls++;
      return true;
    }

    for (final signature in [Uint8List(63), Uint8List(64), Uint8List(65)]) {
      expect(
          () => PairingTranscriptCodec.verify(value,
              publicPoint: vectorBytes('point'),
              rawSignature: signature,
              verifier: verifier),
          throwsFormatException);
      expect(() => PairingTranscriptCodec.sign(value, signer: (_) => signature),
          throwsFormatException);
    }
    expect(calls, 0);
  });
}

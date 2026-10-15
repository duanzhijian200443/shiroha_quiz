import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/external/external_credential_association.dart';
import 'package:shiroha_quiz/data/external/discovery_descriptor_codec.dart';
import 'bootstrap_test_support.dart';

void validate(DiscoveryDescriptor value,
        {DiscoveryExpectations? expected,
        Uint8List? anchor,
        Uint8List? installation}) =>
    DiscoveryDescriptorCodec.validatePublicObjects(value,
        anchorDer: anchor ?? vectorBytes('issuerDer'),
        installationIdBytes: installation ??
            Uint8List.fromList(
                utf8.encode(bootstrapVector['installationId'] as String)),
        expected: expected ?? expectations(),
        verifier: offlineVerify);

void main() {
  test(
      'independent descriptor unsigned bytes, digest, raw signature and public binding',
      () {
    final value = descriptor();
    expect(DiscoveryDescriptorCodec.unsignedBytes(value),
        vectorBytes('descriptorUnsigned'));
    expect(DiscoveryDescriptorCodec.digest(value),
        vectorBytes('descriptorDigest'));
    expect(DiscoveryDescriptorCodec.encode(value), vectorBytes('descriptor'));
    expect(
        DiscoveryDescriptorCodec.encode(
            DiscoveryDescriptorCodec.decode(vectorBytes('descriptor'))),
        vectorBytes('descriptor'));
    expect(
        DiscoveryDescriptorCodec.sign(value, signer: (digest) {
          expect(digest, vectorBytes('descriptorDigest'));
          return vectorBytes('descriptorSignature');
        }),
        vectorBytes('descriptorSignature'));
    validate(value);
    expect(DiscoveryDescriptorCodec.loopbackHost, '127.0.0.1');
  });

  test('all descriptor fields and signature are bound; no generation ordering',
      () {
    for (final value in [
      descriptor(runtime: changed(vectorBytes('runtimeInstanceId'), 0)),
      descriptor(epoch: vectorInt('publicationEpoch') + BigInt.one),
      descriptor(generation: vectorInt('generation') + BigInt.one),
      descriptor(port: 12345),
      descriptor(published: vectorInt('publishedAtUtcMs') + BigInt.one),
      descriptor(serverDigest: changed(vectorBytes('serverLeafDigest'), 0)),
      descriptor(installationId: '10112233-4455-4677-8899-aabbccddeeff'),
      descriptor(signature: vectorBytes('transcriptSignature')),
      descriptor(signature: changed(vectorBytes('descriptorSignature'), 0))
    ]) {
      expect(() => validate(value), throwsFormatException);
    }
  });

  test('self-consistent Discovery bytes cannot select their own trust anchor',
      () {
    expect(() => validate(descriptor(), anchor: vectorBytes('clientDer')),
        throwsFormatException);
    expect(
        () => validate(descriptor(),
            anchor: changed(vectorBytes('issuerDer'), 100)),
        throwsFormatException);
    expect(
        () => validate(descriptor(),
            expected: expectations(anchor: vectorBytes('serverDer'))),
        throwsFormatException);
    expect(
        () => validate(descriptor(),
            expected: expectations(serverDigest: Uint8List(32))),
        throwsFormatException);
    expect(
        () => validate(descriptor(),
            expected: expectations(
                installationId: '10112233-4455-4677-8899-aabbccddeeff')),
        throwsFormatException);
    for (final value in [
      Uint8List(0),
      Uint8List(36),
      Uint8List(129),
      Uint8List.fromList(
          [...utf8.encode(bootstrapVector['installationId'] as String), 10]),
      Uint8List.fromList(utf8
          .encode((bootstrapVector['installationId'] as String).toUpperCase()))
    ]) {
      expect(() => validate(descriptor(), installation: value),
          throwsFormatException);
    }
  });

  test(
      'verified epoch equality or increase only, no overflow or automatic commit',
      () {
    final epoch = vectorInt('publicationEpoch');
    validate(descriptor(), expected: expectations(highWater: epoch));
    validate(descriptor(),
        expected: expectations(highWater: epoch - BigInt.one));
    expect(
        () => validate(descriptor(),
            expected: expectations(highWater: epoch + BigInt.one)),
        throwsFormatException);
    for (final invalid in [-BigInt.one, BigInt.one << 64]) {
      expect(
          () => validate(descriptor(),
              expected: expectations(highWater: invalid)),
          throwsFormatException);
      expect(() => DiscoveryDescriptorCodec.nextEpoch(invalid),
          throwsA(isA<ExternalCredentialException>()));
    }
    final max = (BigInt.one << 64) - BigInt.one;
    expect(DiscoveryDescriptorCodec.nextEpoch(BigInt.zero), BigInt.one);
    expect(DiscoveryDescriptorCodec.nextEpoch(max - BigInt.one), max);
    expect(() => DiscoveryDescriptorCodec.nextEpoch(max),
        throwsA(isA<ExternalCredentialException>()));
    final decoded = DiscoveryDescriptorCodec.decode(
        DiscoveryDescriptorCodec.encode(
            descriptor(epoch: max, generation: max, published: max)));
    expect([
      decoded.publicationEpoch,
      decoded.generation,
      decoded.publishedAtUtcMs
    ], [
      max,
      max,
      max
    ]);
  });

  test('bad widths, UUID, unsigned values and ports fail structurally', () {
    for (final value in [
      descriptor(port: 0),
      descriptor(port: -1),
      descriptor(port: 65536),
      descriptor(epoch: BigInt.zero),
      descriptor(epoch: -BigInt.one),
      descriptor(epoch: BigInt.one << 64),
      descriptor(generation: -BigInt.one),
      descriptor(published: BigInt.one << 64),
      descriptor(runtime: Uint8List(15)),
      descriptor(serverDigest: Uint8List(31)),
      descriptor(installationId: 'bad'),
      descriptor(signature: Uint8List(64))
    ]) {
      expect(
          () => DiscoveryDescriptorCodec.encode(value), throwsFormatException);
    }
    for (final port in [1, 65535]) {
      expect(
          DiscoveryDescriptorCodec.decode(
                  DiscoveryDescriptorCodec.encode(descriptor(port: port)))
              .port,
          port);
    }
  });

  test('every truncation, bad magic/version/framing and trailing data reject',
      () {
    final bytes = vectorBytes('descriptor');
    for (var i = 0; i < bytes.length; i++) {
      expect(
          () => DiscoveryDescriptorCodec.decode(
              Uint8List.fromList(bytes.take(i).toList())),
          throwsFormatException);
    }
    for (final value in [
      changed(bytes, 0),
      changed(bytes, 8),
      changed(bytes, 75),
      Uint8List.fromList([...bytes, 0]),
      Uint8List(278)
    ]) {
      expect(
          () => DiscoveryDescriptorCodec.decode(value), throwsFormatException);
    }
  });

  test('pin snapshots are immutable and rejected metadata never calls verifier',
      () {
    final anchor = vectorBytes('issuerDer');
    final pins = expectations(anchor: anchor);
    anchor[0] = 0;
    expect(pins.trustedAnchorDer, vectorBytes('issuerDer'));
    var calls = 0;
    expect(
        () => DiscoveryDescriptorCodec.validatePublicObjects(descriptor(),
                anchorDer: anchor,
                installationIdBytes: Uint8List(36),
                expected: pins, verifier: (
                    {required publicPoint,
                    required digest,
                    required rawSignature}) {
              calls++;
              return true;
            }),
        throwsFormatException);
    expect(calls, 0);
  });
}

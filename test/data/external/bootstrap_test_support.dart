import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:shiroha_quiz/data/external/discovery_descriptor_codec.dart';
import 'package:shiroha_quiz/data/external/pairing_transcript_codec.dart';

final bootstrapVector = jsonDecode(
  File('test/data/external/fixtures/bootstrap_v1.json').readAsStringSync(),
) as Map<String, dynamic>;

Uint8List unhex(String value) => Uint8List.fromList([
      for (var i = 0; i < value.length; i += 2)
        int.parse(value.substring(i, i + 2), radix: 16),
    ]);
Uint8List vectorBytes(String name) => unhex(bootstrapVector[name] as String);
BigInt vectorInt(String name) => BigInt.parse(bootstrapVector[name] as String);

PairingTranscript transcript(
        {Uint8List? nonce,
        Uint8List? requestId,
        Uint8List? profileId,
        String? installationId,
        BigInt? generation,
        Uint8List? runtime,
        Uint8List? identity,
        BigInt? revision,
        BigInt? expiry}) =>
    PairingTranscript(
        nonce: nonce ?? vectorBytes('nonce'),
        requestId: requestId ?? vectorBytes('requestId'),
        profileId: profileId ?? vectorBytes('profileId'),
        installationId:
            installationId ?? bootstrapVector['installationId'] as String,
        generation: generation ?? vectorInt('generation'),
        runtimeInstanceId: runtime ?? vectorBytes('runtimeInstanceId'),
        credentialIdentity: identity ?? vectorBytes('credentialIdentity'),
        expectedRevision: revision ?? vectorInt('expectedRevision'),
        expiresAtUtcMs: expiry ?? vectorInt('expiresAtUtcMs'));

DiscoveryDescriptor descriptor(
        {Uint8List? runtime,
        BigInt? epoch,
        BigInt? generation,
        int? port,
        Uint8List? serverDigest,
        String? installationId,
        BigInt? published,
        Uint8List? signature}) =>
    DiscoveryDescriptor(
        runtimeInstanceId: runtime ?? vectorBytes('runtimeInstanceId'),
        publicationEpoch: epoch ?? vectorInt('publicationEpoch'),
        generation: generation ?? vectorInt('generation'),
        port: port ?? bootstrapVector['port'] as int,
        serverLeafDigest: serverDigest ?? vectorBytes('serverLeafDigest'),
        installationId:
            installationId ?? bootstrapVector['installationId'] as String,
        publishedAtUtcMs: published ?? vectorInt('publishedAtUtcMs'),
        rawSignature: signature ?? vectorBytes('descriptorSignature'));

DiscoveryExpectations expectations(
        {Uint8List? anchor,
        String? installationId,
        Uint8List? serverDigest,
        BigInt? highWater}) =>
    DiscoveryExpectations(
        trustedAnchorDer: anchor ?? vectorBytes('issuerDer'),
        installationId:
            installationId ?? bootstrapVector['installationId'] as String,
        serverLeafDigest: serverDigest ?? vectorBytes('serverLeafDigest'),
        verifiedEpochHighWater: highWater ?? vectorInt('publicationEpoch'));

Uint8List changed(Uint8List bytes, int index) =>
    Uint8List.fromList(bytes)..[index] ^= 1;

// Test-only P-256 ECDSA verification. No signing, keys, native calls or trust.
// Fixed goldens were produced independently by Python/OpenSSL, not this helper.
final _p = BigInt.parse(
    'ffffffff00000001000000000000000000000000ffffffffffffffffffffffff',
    radix: 16);
final _n = BigInt.parse(
    'ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551',
    radix: 16);
final _b = BigInt.parse(
    '5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b',
    radix: 16);
final _g = (
  BigInt.parse(
      '6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296',
      radix: 16),
  BigInt.parse(
      '4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5',
      radix: 16),
);
typedef _Point = (BigInt, BigInt)?;
BigInt _integer(List<int> bytes) =>
    bytes.fold(BigInt.zero, (n, b) => (n << 8) | BigInt.from(b));
_Point _add(_Point a, _Point b) {
  if (a == null) return b;
  if (b == null) return a;
  if (a.$1 == b.$1 && (a.$2 + b.$2) % _p == BigInt.zero) return null;
  final slope = a == b
      ? ((BigInt.from(3) * a.$1 * a.$1 - BigInt.from(3)) *
              (BigInt.two * a.$2).modInverse(_p)) %
          _p
      : ((b.$2 - a.$2) * (b.$1 - a.$1).modInverse(_p)) % _p;
  final x = (slope * slope - a.$1 - b.$1) % _p;
  return (x, (slope * (a.$1 - x) - a.$2) % _p);
}

_Point _multiply(BigInt k, _Point point) {
  _Point result;
  while (k > BigInt.zero) {
    if (k.isOdd) result = _add(result, point);
    point = _add(point, point);
    k >>= 1;
  }
  return result;
}

bool offlineVerify(
    {required Uint8List publicPoint,
    required Uint8List digest,
    required Uint8List rawSignature}) {
  if (publicPoint.length != 65 ||
      publicPoint[0] != 4 ||
      digest.length != 32 ||
      rawSignature.length != 64) {
    return false;
  }
  final x = _integer(publicPoint.sublist(1, 33)),
      y = _integer(publicPoint.sublist(33));
  if (x >= _p ||
      y >= _p ||
      (y * y - x * x * x + BigInt.from(3) * x - _b) % _p != BigInt.zero) {
    return false;
  }
  final r = _integer(rawSignature.sublist(0, 32)),
      s = _integer(rawSignature.sublist(32));
  if (r <= BigInt.zero || r >= _n || s <= BigInt.zero || s >= _n) return false;
  final w = s.modInverse(_n);
  final point = _add(_multiply((_integer(digest) * w) % _n, _g),
      _multiply((r * w) % _n, (x, y)));
  return point != null && point.$1 % _n == r;
}

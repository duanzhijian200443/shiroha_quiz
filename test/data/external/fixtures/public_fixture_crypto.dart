// Shared public test vectors; never imported by product code.
import 'dart:typed_data';
import 'package:shiroha_quiz/data/external/external_bootstrap_bytes.dart';
import '../bootstrap_test_support.dart';

// Only the unchanged public RFC6979/P21 fixture key exists in these tests.
Uint8List publicFixtureKey() => unhex(
    '3041020100301306072a8648ce3d020106082a8648ce3d030107042730250201010420c9afa9d845ba75166b5c215767b1d6934e50c3db36e89b127b8a622b120f6721');
// PUBLIC RFC6979 fixture only. Deliberately fixed k=1 is NOT production crypto.
// Arbitrary locally reconstructed transcripts are checked by the independent
// existing mathematical P-256 verifier, rather than an accepting boolean fake.
Uint8List signPublicFixture(
    {required Uint8List pkcs8Der,
    required Uint8List publicPoint,
    required Uint8List digest}) {
  if (pkcs8Der.length != publicFixtureKey().length ||
      !bootstrapEqual(publicPoint, vectorBytes('point'))) {
    throw StateError('Synthetic signing vector mismatch');
  }
  final n = BigInt.parse(
      'ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551',
      radix: 16);
  final r = BigInt.parse(
      '6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296',
      radix: 16);
  final d =
      BigInt.parse(hex(pkcs8Der.sublist(pkcs8Der.length - 32)), radix: 16);
  final z = BigInt.parse(hex(digest), radix: 16);
  return unhex(r.toRadixString(16).padLeft(64, '0') +
      ((z + r * d) % n).toRadixString(16).padLeft(64, '0'));
}

String hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

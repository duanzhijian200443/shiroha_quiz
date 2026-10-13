import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/external/external_credential_association.dart';
import 'package:shiroha_quiz/data/external/association_object_codec.dart';

Uint8List vector(String hex) => Uint8List.fromList([
      for (var i = 0; i < hex.replaceAll(' ', '').length; i += 2)
        int.parse(hex.replaceAll(' ', '').substring(i, i + 2), radix: 16)
    ]);
const emptyVector = '53485245584f424a010300000000';
const recordVector = '53485245584f424a010301000000'
    '01'
    '00000000000040008000000000000001'
    '2400'
    '30303030303030302d303030302d343030302d383030302d303030303030303030303032'
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    '0100000000000000'
    '00'
    '0100000000000000';

void main() {
  final corrupt = throwsA(isA<ExternalCredentialException>().having(
      (e) => e.failure, 'failure', ExternalCredentialFailure.dataCorrupt));
  test('frozen empty and one-record vectors decode and encode exactly', () {
    expect(AssociationObjectCodec.decode(vector(emptyVector)), isEmpty);
    expect(AssociationObjectCodec.encode([]), vector(emptyVector));
    final rows = AssociationObjectCodec.decode(vector(recordVector));
    final a = rows.single.association;
    expect(a.profileId, '00000000-0000-4000-8000-000000000001');
    expect(a.installationId, '00000000-0000-4000-8000-000000000002');
    expect(a.credentialIdentity, 'aa' * 32);
    expect(a.revision, 1);
    expect(a.revoked, isFalse);
    expect(rows.single.updatedAtUtcMs, 1);
    expect(AssociationObjectCodec.encode(rows), vector(recordVector));
  });
  test('every truncation and trailing byte fails the whole object', () {
    final bytes = vector(recordVector);
    for (var n = 0; n < bytes.length; n++) {
      expect(
          () =>
              AssociationObjectCodec.decode(Uint8List.sublistView(bytes, 0, n)),
          corrupt,
          reason: 'length $n');
    }
    expect(
        () => AssociationObjectCodec.decode(Uint8List.fromList([...bytes, 0])),
        corrupt);
    expect(() => AssociationObjectCodec.decode(Uint8List(65537)), corrupt);
  });
  test('unknown header/record versions, kinds, UUID and UTF-8 reject', () {
    for (final change in <int, int>{
      0: 0,
      8: 2,
      9: 1,
      14: 2,
      21: 0,
      23: 0,
      31: 129,
      33: 0xff,
      109: 2
    }.entries) {
      final bytes = vector(recordVector)..[change.key] = change.value;
      expect(() => AssociationObjectCodec.decode(bytes), corrupt,
          reason: 'offset ${change.key}');
    }
    for (final seq in [
      [0xc0, 0xaf],
      [0xed, 0xa0, 0x80],
      [0xf4, 0x90, 0x80, 0x80]
    ]) {
      final bytes = vector(recordVector)..setRange(33, 33 + seq.length, seq);
      expect(() => AssociationObjectCodec.decode(bytes), corrupt);
    }
  });
  test('u64 bounds and record-count cap checked before admission', () {
    for (final (offset, invalid) in [
      (101, 0),
      (101, 2147483648),
      (110, 9007199254740992)
    ]) {
      final bytes = vector(recordVector);
      ByteData.sublistView(bytes).setUint64(offset, invalid, Endian.little);
      expect(() => AssociationObjectCodec.decode(bytes), corrupt);
    }
    final bytes = vector(emptyVector)..[10] = 65;
    expect(() => AssociationObjectCodec.decode(bytes), corrupt);
    final high = vector(recordVector)..fillRange(101, 109, 255);
    expect(() => AssociationObjectCodec.decode(high), corrupt);
  });
  test('duplicate Profiles and active identities fail; tombstones survive', () {
    final one = vector(recordVector);
    final two = Uint8List.fromList([...one, ...one.sublist(14)])..[10] = 2;
    expect(() => AssociationObjectCodec.decode(two), corrupt);
    two[118 + 16] = 3; // second Profile's last raw byte
    expect(() => AssociationObjectCodec.decode(two), corrupt);
    two[118 + 95] = 1; // second revoked byte
    final rows = AssociationObjectCodec.decode(two);
    expect(rows.length, 2);
    expect(rows.last.association.revoked, isTrue);
    expect(AssociationObjectCodec.encode(rows), two);
  });
}

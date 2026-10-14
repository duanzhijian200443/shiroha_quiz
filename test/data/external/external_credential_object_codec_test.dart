import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/external/external_credential_association.dart';
import 'package:shiroha_quiz/data/external/external_credential_object_codec.dart';

// 固定离线字节夹具。PKCS#8 与证书 DER 都是真实、公开、可重复的合成材料：
// - PKCS#8 由 RFC 6979 A.2.5 公开 P-256 测试密钥导出（67 字节）；
// - 证书 DER 是 external_certificate_der_test.dart 的冻结向量，已由 OpenSSL
//   独立解析与链校验。这里只搬运字节，不做任何密码学判断。
const _pkcs8Hex = '3041020100301306072a8648ce3d020106082a8648ce3d03010704273025'
    '0201010420c9afa9d845ba75166b5c215767b1d6934e50c3db36e89b127b8a622b120f6721';
const _serverCertHex =
    '308201963082013ca0030201020210112233445566778899aabbccddeeff00'
    '300a06082a8648ce3d040302'
    '302f312d302b06035504030c24536869726f68612045787465726e616c20'
    '496e7374616c6c6174696f6e20497373756572'
    '301e170d3236313031343233353530305a170d3238313031343030303030305a'
    '3020311e301c06035504030c15536869726f68612045787465726e616c20486f7374'
    '3059301306072a8648ce3d020106082a8648ce3d030107034200'
    '0460fed4ba255a9d31c961eb74c6356d68c049b8923b61fa6ce669622e60f29fb6'
    '7903fe1008b8bc99a41ae9e95628bc64f2f1b20c2d7e9f5177a3c294d4462299'
    'a3493047300c0603551d130101ff04023000'
    '300e0603551d0f0101ff040403020780'
    '30130603551d25040c300a06082b06010505070301'
    '30120603551d110101ff0408300687047f000001'
    '300a06082a8648ce3d040302034800'
    '30450220447eef779928859126e436a72ea2fce7f28941ae51e8668226c3da2221199b9a'
    '022100cae8368cac31b1ca2b91087a04eb4be3f686f390ad4d65549201b9205a5b917c';
const _installationId = '0f9c2c1e-6a4d-4f2b-9c31-7d5a8e0b1f42';
const _otherInstallationId = '1a2b3c4d-5e6f-4a1b-8c2d-3e4f50617283';

Uint8List _bytes(String hex) => Uint8List.fromList([
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ]);

List<int> _u16(int value) => (ByteData(2)..setUint16(0, value, Endian.little))
    .buffer
    .asUint8List()
    .toList();

List<int> _u64(Object value) {
  final n = value is BigInt ? value : BigInt.from(value as int);
  return [
    for (var i = 0; i < 8; i++) ((n >> (8 * i)) & BigInt.from(255)).toInt()
  ];
}

List<int> _der(Uint8List bytes) => [..._u16(bytes.length), ...bytes];

List<int> _installation(String id) => [
      ..._u16(utf8.encode(id).length),
      ...utf8.encode(id),
    ];

Uint8List _object(int kind, List<int> body) =>
    Uint8List.fromList([83, 72, 82, 69, 88, 79, 66, 74, 1, kind, ...body]);

Uint8List _kind1({
  String installation = _installationId,
  Object epoch = 0,
  Uint8List? pkcs8,
  Uint8List? certificate,
}) =>
    _object(1, [
      ..._installation(installation),
      ..._u64(epoch),
      ..._der(pkcs8 ?? _bytes(_pkcs8Hex)),
      ..._der(certificate ?? _bytes(_serverCertHex)),
    ]);

Uint8List _kind2({Uint8List? pkcs8, Uint8List? leaf, Uint8List? certificate}) =>
    _object(2, [
      ..._der(pkcs8 ?? _bytes(_pkcs8Hex)),
      ..._der(leaf ?? _bytes(_serverCertHex)),
      ..._der(certificate ?? _bytes(_serverCertHex)),
    ]);

Uint8List _kind4({
  Uint8List? pkcs8,
  Uint8List? leaf,
  Uint8List? certificate,
  String installation = _installationId,
  Object highWater = 7,
}) =>
    _object(4, [
      ..._der(pkcs8 ?? _bytes(_pkcs8Hex)),
      ..._der(leaf ?? _bytes(_serverCertHex)),
      ..._der(certificate ?? _bytes(_serverCertHex)),
      ..._installation(installation),
      ..._u64(highWater),
    ]);

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

void main() {
  final corrupt = throwsA(isA<ExternalCredentialException>());
  final pkcs8 = _bytes(_pkcs8Hex);
  final certificate = _bytes(_serverCertHex);

  test('kind 1/2/4 round trip preserves every frozen field', () {
    final issuer = ExternalIssuerKeyPair(
      installationId: _installationId,
      publicationEpoch: BigInt.from(0),
      issuerPkcs8Der: pkcs8,
      issuerCertificateDer: certificate,
    );
    final encodedIssuer = issuer.encode();
    expect(encodedIssuer, _kind1());
    final decodedIssuer = ExternalCredentialObjectCodec.decode(encodedIssuer)
        as ExternalIssuerKeyPair;
    expect(decodedIssuer.installationId, _installationId);
    expect(decodedIssuer.publicationEpoch, BigInt.zero);
    expect(decodedIssuer.issuerPkcs8Der, pkcs8);
    expect(decodedIssuer.issuerCertificateDer, certificate);
    expect(decodedIssuer.encode(), encodedIssuer);

    final server = ExternalServerKeyChain(
      serverPkcs8Der: pkcs8,
      serverLeafDer: certificate,
      issuerCertificateDer: certificate,
    );
    expect(server.encode(), _kind2());
    final decodedServer = ExternalCredentialObjectCodec.decode(server.encode())
        as ExternalServerKeyChain;
    expect(decodedServer.serverPkcs8Der, pkcs8);
    expect(decodedServer.serverLeafDer, certificate);
    expect(decodedServer.issuerCertificateDer, certificate);
    expect(decodedServer.encode(), server.encode());

    final bridge = ExternalBridgeClient(
      clientPkcs8Der: pkcs8,
      clientLeafDer: certificate,
      issuerCertificateDer: certificate,
      pinnedInstallationId: _installationId,
      pinnedDiscoveryEpochHighWater: BigInt.from(7),
    );
    expect(bridge.encode(), _kind4());
    final decodedBridge = ExternalCredentialObjectCodec.decode(bridge.encode())
        as ExternalBridgeClient;
    expect(decodedBridge.clientPkcs8Der, pkcs8);
    expect(decodedBridge.clientLeafDer, certificate);
    expect(decodedBridge.issuerCertificateDer, certificate);
    expect(decodedBridge.pinnedInstallationId, _installationId);
    expect(decodedBridge.pinnedDiscoveryEpochHighWater, BigInt.from(7));
    expect(decodedBridge.encode(), bridge.encode());

    expect(issuer.kind, 1);
    expect(server.kind, 2);
    expect(bridge.kind, 4);
  });

  test('non-zero epoch and high-water survive the round trip', () {
    final maxEpoch = ExternalCredentialObjectCodec.maxEpoch;
    final decoded = ExternalCredentialObjectCodec.decode(
            _kind1(epoch: maxEpoch, installation: _otherInstallationId))
        as ExternalIssuerKeyPair;
    expect(decoded.publicationEpoch, maxEpoch);
    expect(decoded.installationId, _otherInstallationId);
    final decodedBridge =
        ExternalCredentialObjectCodec.decode(_kind4(highWater: maxEpoch))
            as ExternalBridgeClient;
    expect(decodedBridge.pinnedDiscoveryEpochHighWater, maxEpoch);
  });

  test('unknown magic, version and kind are dataCorrupt', () {
    final valid = _kind1();
    for (final index in [0, 3, 7]) {
      final tampered = Uint8List.fromList(valid)..[index] = 0x00;
      expect(() => ExternalCredentialObjectCodec.decode(tampered), corrupt);
    }
    for (final version in [0, 2, 0x7f, 0xff]) {
      final tampered = Uint8List.fromList(valid)..[8] = version;
      expect(() => ExternalCredentialObjectCodec.decode(tampered), corrupt,
          reason: 'version $version');
    }
    for (final kind in [0, 3, 5, 6, 0x7f, 0xff]) {
      final tampered = Uint8List.fromList(valid)..[9] = kind;
      expect(() => ExternalCredentialObjectCodec.decode(tampered), corrupt,
          reason: 'kind $kind');
    }
  });

  test('truncation and trailing bytes reject for every kind', () {
    for (final valid in [_kind1(), _kind2(), _kind4()]) {
      for (var i = 0; i < valid.length; i++) {
        expect(
            () => ExternalCredentialObjectCodec.decode(
                Uint8List.fromList(valid.sublist(0, i))),
            corrupt,
            reason: 'length $i of ${valid.length}');
      }
      expect(
          () => ExternalCredentialObjectCodec.decode(
              Uint8List.fromList([...valid, 0])),
          corrupt);
      expect(
          () => ExternalCredentialObjectCodec.decode(
              Uint8List.fromList([...valid, 0, 0, 0])),
          corrupt);
    }
  });

  test('invalid installationId text and framing reject', () {
    for (final id in [
      '',
      '0F9C2C1E-6A4D-4F2B-9C31-7D5A8E0B1F42', // 大写
      '0f9c2c1e-6a4d-1f2b-9c31-7d5a8e0b1f42', // 非 v4
      '0f9c2c1e-6a4d-4f2b-1c31-7d5a8e0b1f42', // 非 RFC4122 variant
      '0f9c2c1e6a4d4f2b9c317d5a8e0b1f42', // 缺连字符
      '0f9c2c1e-6a4d-4f2b-9c31-7d5a8e0b1f4', // 长度不足
      '0' * 36, // 非法字符
    ]) {
      expect(
          () => ExternalCredentialObjectCodec.decode(_kind1(installation: id)),
          corrupt,
          reason: id);
      expect(
          () => ExternalCredentialObjectCodec.decode(_kind4(installation: id)),
          corrupt,
          reason: 'kind4 $id');
    }
    // 声明长度与实际不符。
    final body = _kind1();
    for (final length in [0, 1, 200, 0xffff]) {
      final tampered = Uint8List.fromList(body);
      final declared = ByteData(2)..setUint16(0, length, Endian.little);
      tampered[10] = declared.getUint8(0);
      tampered[11] = declared.getUint8(1);
      expect(() => ExternalCredentialObjectCodec.decode(tampered), corrupt,
          reason: 'declared $length');
    }
    // 非 UTF-8 字节。
    final invalidUtf8 = Uint8List.fromList(body);
    invalidUtf8[12] = 0xff;
    expect(() => ExternalCredentialObjectCodec.decode(invalidUtf8), corrupt);
  });

  test('full u64 epochs and overflow reject without timestamp restriction', () {
    final max = ExternalCredentialObjectCodec.maxEpoch;
    for (final value in [
      BigInt.zero,
      BigInt.from(9007199254740992),
      BigInt.one << 63,
      max
    ]) {
      final issuer = ExternalCredentialObjectCodec.decode(_kind1(epoch: value))
          as ExternalIssuerKeyPair;
      final bridge =
          ExternalCredentialObjectCodec.decode(_kind4(highWater: value))
              as ExternalBridgeClient;
      expect(issuer.publicationEpoch, value);
      expect(bridge.pinnedDiscoveryEpochHighWater, value);
      expect(issuer.encode(), _kind1(epoch: value));
      expect(bridge.encode(), _kind4(highWater: value));
    }
    for (final bad in [-BigInt.one, max + BigInt.one]) {
      expect(
          () => ExternalIssuerKeyPair(
                  installationId: _installationId,
                  publicationEpoch: bad,
                  issuerPkcs8Der: pkcs8,
                  issuerCertificateDer: certificate)
              .encode(),
          corrupt);
      expect(
          () => ExternalBridgeClient(
                  clientPkcs8Der: pkcs8,
                  clientLeafDer: certificate,
                  issuerCertificateDer: certificate,
                  pinnedInstallationId: _installationId,
                  pinnedDiscoveryEpochHighWater: bad)
              .encode(),
          corrupt);
    }
    expect(ExternalCredentialObjectCodec.nextEpoch(max - BigInt.one), max);
    expect(() => ExternalCredentialObjectCodec.nextEpoch(max), corrupt);
    expect(() => ExternalCredentialObjectCodec.nextEpoch(-BigInt.one), corrupt);
  });
  test('DER outer length cannot truncate or include extra bytes', () {
    for (final bytes in [_kind1(), _kind2(), _kind4()]) {
      final offset = bytes[9] == 1 ? 10 + 2 + 36 + 8 : 10;
      for (final delta in [-1, 1]) {
        final changed = Uint8List.fromList(bytes);
        ByteData.sublistView(changed)
            .setUint16(offset, pkcs8.length + delta, Endian.little);
        expect(() => ExternalCredentialObjectCodec.decode(changed), corrupt);
      }
    }
    for (final noncanonical in [
      [0x30, 4, 0x02, 2, 0, 1],
      [0x30, 3, 0x01, 1, 1],
      [0x30, 4, 0x03, 2, 1, 1],
      [0x30, 3, 0x30, 0x80, 0],
      [0x30, 4, 0x06, 2, 0x80, 0],
    ]) {
      expect(
          () => ExternalCredentialObjectCodec.decode(
              _kind2(pkcs8: Uint8List.fromList(noncanonical))),
          corrupt);
    }
  });

  test('key and certificate length bounds reject', () {
    Uint8List der(int bodyLength) => Uint8List.fromList([
          0x30,
          0x82,
          bodyLength >> 8,
          bodyLength & 255,
          ...List.filled(bodyLength, 0)
        ]);
    expect(() => ExternalCredentialObjectCodec.decode(_kind1(pkcs8: der(300))),
        corrupt);
    expect(
        () => ExternalCredentialObjectCodec.decode(
            _kind1(certificate: der(2000))),
        corrupt);
    expect(() => ExternalCredentialObjectCodec.decode(_kind2(pkcs8: der(300))),
        corrupt);
    expect(
        () => ExternalCredentialObjectCodec.decode(
            _kind2(certificate: der(2000))),
        corrupt);
    expect(() => ExternalCredentialObjectCodec.decode(_kind4(leaf: der(2000))),
        corrupt);
    expect(
        () => ExternalIssuerKeyPair(
              installationId: _installationId,
              publicationEpoch: BigInt.from(0),
              issuerPkcs8Der: der(300),
              issuerCertificateDer: certificate,
            ).encode(),
        corrupt);
    expect(
        () => ExternalServerKeyChain(
              serverPkcs8Der: pkcs8,
              serverLeafDer: der(2000),
              issuerCertificateDer: certificate,
            ).encode(),
        corrupt);
    // 空 DER 字段。
    expect(
        () => ExternalCredentialObjectCodec.decode(_kind1(pkcs8: Uint8List(0))),
        corrupt);
  });

  test('non-canonical or malformed DER framing rejects', () {
    for (final der in [
      Uint8List.fromList([0x30, 0x80, 0x00, 0x00]), // 不定长度
      Uint8List.fromList([0x30, 0x03, 0x02, 0x01, 0x01, 0x00]), // 字段内尾随
      Uint8List.fromList([0x30, 0x05, 0x02, 0x01]), // 长度超出可用字节
      Uint8List.fromList([0x30, 0x81, 0x02, 0x02, 0x01]), // 短长度用长形式
      Uint8List.fromList([0x30, 0x82, 0x00, 0x02, 0x02, 0x01]), // 前导零长度
      Uint8List.fromList([0x30, 0x05]), // 截断
    ]) {
      expect(() => ExternalCredentialObjectCodec.decode(_kind1(pkcs8: der)),
          corrupt,
          reason: der.toString());
      expect(() => ExternalCredentialObjectCodec.decode(_kind2(leaf: der)),
          corrupt);
    }
  });

  test('canonical DER string/time validation rejects in encode and decode', () {
    Uint8List field(int tag, List<int> body) =>
        Uint8List.fromList([0x30, body.length + 2, tag, body.length, ...body]);
    final invalid = <Uint8List>[
      field(0x13, [255]),
      field(0x13, [...utf8.encode('Shiroha'), 10]),
      field(0x17, [...utf8.encode('261014235500Z'), 10]),
      field(0x18, [...utf8.encode('20500228235959Z'), 10]),
      field(0x13, utf8.encode('@')),
      field(0x16, [128]),
      for (final text in [
        '261014235500+',
        '2610142355Z',
        '261014235500+0000',
        '260230235500Z',
        '261014245500Z',
        '261014236000Z',
        '261014235560Z'
      ])
        field(0x17, utf8.encode(text)),
      for (final text in [
        '20261014235500+',
        '202610142355Z',
        '20261014235500,1Z',
        '20261014235500.0Z',
        '20261014235500.10Z',
        '20260230235500Z'
      ])
        field(0x18, utf8.encode(text)),
    ];
    final changedCertificate = Uint8List.fromList(certificate);
    final marker = utf8.encode('261014235500Z');
    for (var offset = 0;
        offset <= changedCertificate.length - marker.length;
        offset++) {
      if (_same(
          changedCertificate.sublist(offset, offset + marker.length), marker)) {
        changedCertificate[offset + marker.length - 1] = 43;
        break;
      }
    }
    expect(changedCertificate, isNot(certificate));
    invalid.add(changedCertificate);
    for (final bytes in invalid) {
      for (final object in [
        ExternalIssuerKeyPair(
            installationId: _installationId,
            publicationEpoch: BigInt.zero,
            issuerPkcs8Der: pkcs8,
            issuerCertificateDer: bytes),
        ExternalServerKeyChain(
            serverPkcs8Der: pkcs8,
            serverLeafDer: bytes,
            issuerCertificateDer: certificate),
        ExternalBridgeClient(
            clientPkcs8Der: pkcs8,
            clientLeafDer: bytes,
            issuerCertificateDer: certificate,
            pinnedInstallationId: _installationId,
            pinnedDiscoveryEpochHighWater: BigInt.zero),
      ]) {
        expect(object.encode, corrupt);
      }
      for (final encoded in [
        _kind1(certificate: bytes),
        _kind2(leaf: bytes),
        _kind4(leaf: bytes)
      ]) {
        expect(() => ExternalCredentialObjectCodec.decode(encoded), corrupt);
      }
    }
    // Legal character sets and shortest fractional GeneralizedTime remain DER.
    for (final valid in [
      field(0x13, utf8.encode("Shiroha (A)+B,./:=?'-")),
      field(0x16, [0, 127]),
      field(0x17, utf8.encode('000229235959Z')),
      field(0x18, utf8.encode('20500228235959.123Z'))
    ]) {
      final value = ExternalCredentialObjectCodec.decode(_kind2(leaf: valid))
          as ExternalServerKeyChain;
      expect(value.serverLeafDer, valid);
      expect(value.encode(), _kind2(leaf: valid));
    }
  });

  test('oversized input objects reject before any parsing', () {
    expect(
        () => ExternalCredentialObjectCodec.decode(
            Uint8List.fromList([..._kind1(), ...List.filled(65536, 0)])),
        corrupt);
    expect(
        () => ExternalCredentialObjectCodec.decode(Uint8List(65537)), corrupt);
  });

  test('decoded objects never share storage with the caller buffer', () {
    final buffer = _kind1();
    final decoded =
        ExternalCredentialObjectCodec.decode(buffer) as ExternalIssuerKeyPair;
    buffer.fillRange(0, buffer.length, 0);
    expect(decoded.issuerPkcs8Der, pkcs8);
    expect(decoded.issuerCertificateDer, certificate);
    expect(decoded.encode(), _kind1());
  });

  test('kind 3 remains owned by AssociationObjectCodec', () {
    // kind 3 是本轮明确不改动的稳定对象；此 codec 必须拒绝它。
    expect(() => ExternalCredentialObjectCodec.decode(_object(3, [0, 0, 0, 0])),
        corrupt);
    expect(_same([1, 2], [1, 2]), isTrue);
  });
}

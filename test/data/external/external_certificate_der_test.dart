import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/data/external/external_certificate_der.dart';

// 冻结离线向量的来源与可重复性：
// - 密钥：RFC 6979 A.2.5 公开 P-256 测试密钥（公开知识，非真实凭据）。
// - TBS 字节：由本 codec 的 buildTbs 生成；结构由
//   `openssl asn1parse -inform DER` 独立解析确认。
// - 摘要：`openssl dgst -sha256` 对冻结 TBS 的计算结果。
// - 每个 raw r‖s / DER 签名：`openssl dgst -sha256 -sign` 生成，并逐个用
//   `openssl dgst -sha256 -verify` 复核为 Verified OK。
// - 证书：由本 codec 的 assemble 组装，`openssl x509 -text` 确认 profile，
//   `openssl verify -no_check_time -CAfile issuer` 确认叶子链到冻结锚点。
// 这些向量固定、公开、可重复；测试内不生成随机值，也不把临时结果当真相。
const _pointHex =
    '0460fed4ba255a9d31c961eb74c6356d68c049b8923b61fa6ce669622e60f29fb6'
    '7903fe1008b8bc99a41ae9e95628bc64f2f1b20c2d7e9f5177a3c294d4462299';
const _serialHex = '112233445566778899aabbccddeeff00';
const _serverTbsHex = '3082013ca0030201020210112233445566778899aabbccddeeff00'
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
    '30120603551d110101ff0408300687047f000001';
const _serverDigestHex =
    'de529087f5c4d79ae948fd78938db3ff55c5b6fb08aa160aad1c18e7bd4643b8';
// s 需要符号零填充；同时作为证书 signatureValue 的来源。
const _serverRawHex =
    '447eef779928859126e436a72ea2fce7f28941ae51e8668226c3da2221199b9a'
    'cae8368cac31b1ca2b91087a04eb4be3f686f390ad4d65549201b9205a5b917c';
const _serverDerHex =
    '30450220447eef779928859126e436a72ea2fce7f28941ae51e8668226c3da2221199b9a'
    '022100cae8368cac31b1ca2b91087a04eb4be3f686f390ad4d65549201b9205a5b917c';
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

// Additional fixed public role vectors; OpenSSL independently verifies all three roles.
const _issuerCertHex =
    '3082018130820128a0030201020210112233445566778899aabbccddeeff00300a06082a'
    '8648ce3d040302302f312d302b06035504030c24536869726f68612045787465726e616c'
    '20496e7374616c6c6174696f6e20497373756572301e170d323631303134323335353030'
    '5a170d3336313031323030303030305a302f312d302b06035504030c24536869726f6861'
    '2045787465726e616c20496e7374616c6c6174696f6e204973737565723059301306072a'
    '8648ce3d020106082a8648ce3d0301070342000460fed4ba255a9d31c961eb74c6356d68'
    'c049b8923b61fa6ce669622e60f29fb67903fe1008b8bc99a41ae9e95628bc64f2f1b20c'
    '2d7e9f5177a3c294d4462299a326302430120603551d130101ff040830060101ff020100'
    '300e0603551d0f0101ff040403020204300a06082a8648ce3d0403020347003044022048'
    'bb1e3aedd613d95de1c30c676f69e8061ef3497ff15e7b106a02ef2ae0797d02204061e1'
    '0a35e9fb7957038a0aca57d593757d88155b05e00dd91de5500cbd52c7';
const _issuerTbsHex =
    '30820128a0030201020210112233445566778899aabbccddeeff00300a06082a8648ce3d'
    '040302302f312d302b06035504030c24536869726f68612045787465726e616c20496e73'
    '74616c6c6174696f6e20497373756572301e170d3236313031343233353530305a170d33'
    '36313031323030303030305a302f312d302b06035504030c24536869726f686120457874'
    '65726e616c20496e7374616c6c6174696f6e204973737565723059301306072a8648ce3d'
    '020106082a8648ce3d0301070342000460fed4ba255a9d31c961eb74c6356d68c049b892'
    '3b61fa6ce669622e60f29fb67903fe1008b8bc99a41ae9e95628bc64f2f1b20c2d7e9f51'
    '77a3c294d4462299a326302430120603551d130101ff040830060101ff020100300e0603'
    '551d0f0101ff040403020204';
const _issuerRawHex =
    '48bb1e3aedd613d95de1c30c676f69e8061ef3497ff15e7b106a02ef2ae0797d4061e10a'
    '35e9fb7957038a0aca57d593757d88155b05e00dd91de5500cbd52c7';
const _issuerDigestHex =
    '462ce6ea802701150b9fcc5e6acdaa836a7720864987d0df89a69b0114c80d7c';
const _clientCertHex =
    '308201833082012aa0030201020210112233445566778899aabbccddeeff00300a06082a'
    '8648ce3d040302302f312d302b06035504030c24536869726f68612045787465726e616c'
    '20496e7374616c6c6174696f6e20497373756572301e170d323631303134323335353030'
    '5a170d3238313031343030303030305a30223120301e06035504030c17536869726f6861'
    '2045787465726e616c204272696467653059301306072a8648ce3d020106082a8648ce3d'
    '0301070342000460fed4ba255a9d31c961eb74c6356d68c049b8923b61fa6ce669622e60'
    'f29fb67903fe1008b8bc99a41ae9e95628bc64f2f1b20c2d7e9f5177a3c294d4462299a3'
    '353033300c0603551d130101ff04023000300e0603551d0f0101ff040403020780301306'
    '03551d25040c300a06082b06010505070302300a06082a8648ce3d040302034700304402'
    '2039596114c428315480a9a437be7ac59ea4fae321cd379f10d38384927c76c01f02204f'
    'a68351e5074984fd712b51fcf9e6d6fb655b33ed7360231507cdb3ba93f773';
const _clientTbsHex =
    '3082012aa0030201020210112233445566778899aabbccddeeff00300a06082a8648ce3d'
    '040302302f312d302b06035504030c24536869726f68612045787465726e616c20496e73'
    '74616c6c6174696f6e20497373756572301e170d3236313031343233353530305a170d32'
    '38313031343030303030305a30223120301e06035504030c17536869726f686120457874'
    '65726e616c204272696467653059301306072a8648ce3d020106082a8648ce3d03010703'
    '42000460fed4ba255a9d31c961eb74c6356d68c049b8923b61fa6ce669622e60f29fb679'
    '03fe1008b8bc99a41ae9e95628bc64f2f1b20c2d7e9f5177a3c294d4462299a335303330'
    '0c0603551d130101ff04023000300e0603551d0f0101ff04040302078030130603551d25'
    '040c300a06082b06010505070302';
const _clientRawHex =
    '39596114c428315480a9a437be7ac59ea4fae321cd379f10d38384927c76c01f4fa68351'
    'e5074984fd712b51fcf9e6d6fb655b33ed7360231507cdb3ba93f773';
const _clientDigestHex =
    '577db8ae058ee70b3cfbf86cededc0cc2996ae366dac0da18d97575c963cf42c';

const _algorithmHex = '300a06082a8648ce3d040302';
const _nullAlgorithmHex = '300c06082a8648ce3d0403020500';
const _sanHex = '30120603551d110101ff0408300687047f000001';

/// 每个条目为 (raw r‖s, DER SEQUENCE)，全部由 OpenSSL 验证过。
const _signatureVectors = <(String, String)>[
  // 无填充、无前导零。
  (
    '1cf44714394704f2c230d8a914ac9d49c31825849279b601cb8d96284ca2923d'
        '4eacd480cd3a9a8e94dc4a1b84f32834c3c1cc8a5de2ae626b3f3c006b7a4815',
    '304402201cf44714394704f2c230d8a914ac9d49c31825849279b601cb8d96284ca2923d'
        '02204eacd480cd3a9a8e94dc4a1b84f32834c3c1cc8a5de2ae626b3f3c006b7a4815',
  ),
  // r 需要符号零填充。
  (
    'a13ae0a73c6eb6dba175442c278ecec5196aff3510b74b4c69a70707eb7242bb'
        '4ce7caa75514dec1344e0c7b8fd10d2bccce0418e403cce28e967a24b91b7f9d',
    '3045022100a13ae0a73c6eb6dba175442c278ecec5196aff3510b74b4c69a70707eb7242bb'
        '02204ce7caa75514dec1344e0c7b8fd10d2bccce0418e403cce28e967a24b91b7f9d',
  ),
  // s 需要符号零填充。
  (_serverRawHex, _serverDerHex),
  // r 与 s 同时需要符号零填充。
  (
    '97673da5e1f496f52c4aa0e708f562510b04bc319036284020df9f3f13b9b380'
        'baf8403cc12816c0d3a79a4cca817d5e53fa458f013660ad36084eafe4f1e271',
    '304602210097673da5e1f496f52c4aa0e708f562510b04bc319036284020df9f3f13b9b380'
        '022100baf8403cc12816c0d3a79a4cca817d5e53fa458f013660ad36084eafe4f1e271',
  ),
  // raw 前导零且随后需要符号零填充（DER 仍为 32 字节）。
  (
    '00bb5b3281f7f5078d157df345ca9ae61c69b7f686bf523f3ebc59b27c91b3ee'
        '156d84fdaf7dfef5a9738f01e1643e8c881323cf5df971d9c4f730a1f43a55fa',
    '3044022000bb5b3281f7f5078d157df345ca9ae61c69b7f686bf523f3ebc59b27c91b3ee'
        '0220156d84fdaf7dfef5a9738f01e1643e8c881323cf5df971d9c4f730a1f43a55fa',
  ),
  // r 有前导零 → 最短 DER（INTEGER 31 字节，0x1f）。
  (
    '005058ce6d645aa9a322dd5f8d9eff0d655914b347a0d81a765202ddd942f454'
        'c3e22d8a2b7b4eb4c649176a61b98b4edd456b4b043a2ea102fd7825816fd5bc',
    '3044021f5058ce6d645aa9a322dd5f8d9eff0d655914b347a0d81a765202ddd942f454'
        '022100c3e22d8a2b7b4eb4c649176a61b98b4edd456b4b043a2ea102fd7825816fd5bc',
  ),
  // s 有前导零 → 最短 DER（INTEGER 31 字节）。
  (
    '827a9176abf46eed52d2b22b7f163e641816f00fdecb6ca90bc28baef48c66f0'
        '00a19323d66df39274061874dc046f321ed979542793da91688d74497ac99b63',
    '3045022100827a9176abf46eed52d2b22b7f163e641816f00fdecb6ca90bc28baef48c66f0'
        '022000a19323d66df39274061874dc046f321ed979542793da91688d74497ac99b63',
  ),
  // r 与 s 同时有前导零 → 最短 DER（两个 INTEGER 各 31 字节）。
  (
    '0065331e18b710952b510dc17f7a4318949a6aa8e6af730743afa05f0cfd4d88'
        '002897578753ef39430c78cfb263ab6d45d1c7c26c1f8ea795ee7ad3ae15d1c9',
    '3042021f65331e18b710952b510dc17f7a4318949a6aa8e6af730743afa05f0cfd4d88'
        '021f2897578753ef39430c78cfb263ab6d45d1c7c26c1f8ea795ee7ad3ae15d1c9',
  ),
];

Uint8List _bytes(String hex) => Uint8List.fromList([
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ]);

Uint8List _tlv(int tag, List<int> body) => Uint8List.fromList([
      tag,
      if (body.length < 128)
        body.length
      else if (body.length < 256) ...[
        0x81,
        body.length
      ] else ...[
        0x82,
        body.length >> 8,
        body.length & 255
      ],
      ...body,
    ]);

// 测试专用的独立 TLV 切分函数，用于构造证书负例。
List<Uint8List> _children(Uint8List encoded) {
  var offset = 1;
  var length = encoded[offset++];
  if ((length & 0x80) != 0) {
    final count = length & 0x7f;
    length = 0;
    for (var i = 0; i < count; i++) {
      length = (length << 8) | encoded[offset++];
    }
  }
  final end = offset + length;
  final result = <Uint8List>[];
  while (offset < end) {
    final start = offset++;
    var n = encoded[offset++];
    if ((n & 0x80) != 0) {
      final count = n & 0x7f;
      n = 0;
      for (var i = 0; i < count; i++) {
        n = (n << 8) | encoded[offset++];
      }
    }
    offset += n;
    result.add(Uint8List.fromList(encoded.sublist(start, offset)));
  }
  return result;
}

Uint8List _certificate(Uint8List tbs,
        {List<int>? outerAlgorithm, List<int>? signatureBits}) =>
    _tlv(0x30, [
      ...tbs,
      ...(outerAlgorithm ?? _bytes(_algorithmHex)),
      ..._tlv(0x03, signatureBits ?? [0, ..._bytes(_serverDerHex)]),
    ]);

Uint8List _editTbs(List<Uint8List> Function(List<Uint8List>) edit) {
  final fields = _children(_bytes(_serverTbsHex));
  return _tlv(0x30, edit(fields).expand((e) => e).toList());
}

List<int> _replace(List<int> value, String oldHex, List<int> replacement) {
  final old = _bytes(oldHex);
  for (var i = 0; i <= value.length - old.length; i++) {
    var match = true;
    for (var j = 0; j < old.length; j++) {
      if (value[i + j] != old[j]) {
        match = false;
        break;
      }
    }
    if (match) {
      return [
        ...value.sublist(0, i),
        ...replacement,
        ...value.sublist(i + old.length)
      ];
    }
  }
  throw StateError('missing test marker');
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// 仅比较已冻结的字节，不是密码学验证器；真实签名验证由 OpenSSL 在离线
/// 向量生成阶段完成，生产验证仍属 WINDOWS_PENDING。
bool _fakeVerify(ExternalCertificateStructure structure, String digestHex) =>
    structure.role == ExternalCertificateRole.server &&
    _same(structure.tbs, _bytes(_serverTbsHex)) &&
    _same(structure.publicKey, _bytes(_pointHex)) &&
    _same(structure.rawSignature, _bytes(_serverRawHex)) &&
    digestHex == _serverDigestHex;

void main() {
  final rejected = throwsA(isA<FormatException>());
  final key = _bytes(_pointHex);
  final generation = DateTime.utc(2026, 10, 15);
  final serial = _bytes(_serialHex);

  test('frozen TBS, digest, DER signature and final certificate bytes', () {
    final tbs = ExternalCertificateDer.buildTbs(
        role: ExternalCertificateRole.server,
        serial16: serial,
        generationUtc: generation,
        publicKey: key);
    expect(tbs, _bytes(_serverTbsHex));
    expect(ExternalCertificateDer.signatureFromRaw(_bytes(_serverRawHex)),
        _bytes(_serverDerHex));
    final certificate = ExternalCertificateDer.assemble(
        role: ExternalCertificateRole.server,
        tbs: tbs,
        rawSignature: _bytes(_serverRawHex));
    expect(certificate, _bytes(_serverCertHex));
    final inspected = ExternalCertificateDer.inspect(certificate,
        role: ExternalCertificateRole.server);
    expect(inspected.tbs, tbs);
    expect(inspected.publicKey, key);
    expect(inspected.rawSignature, _bytes(_serverRawHex));
    expect(inspected.notBefore, DateTime.utc(2026, 10, 14, 23, 55));
    expect(inspected.notAfter, DateTime.utc(2028, 10, 14));
    expect(_fakeVerify(inspected, _serverDigestHex), isTrue);
    expect(_fakeVerify(inspected, '00' * 32), isFalse);
    expect(_fakeVerify(inspected, _serverDigestHex), isTrue);
  });

  test('frozen issuer/client TBS, raw signature and final certificate vectors',
      () {
    for (final vector in [
      (
        ExternalCertificateRole.issuer,
        _issuerTbsHex,
        _issuerRawHex,
        _issuerCertHex
      ),
      (
        ExternalCertificateRole.client,
        _clientTbsHex,
        _clientRawHex,
        _clientCertHex
      ),
    ]) {
      final tbs = ExternalCertificateDer.buildTbs(
          role: vector.$1,
          serial16: serial,
          generationUtc: generation,
          publicKey: key);
      expect(tbs, _bytes(vector.$2));
      final cert = ExternalCertificateDer.assemble(
          role: vector.$1, tbs: tbs, rawSignature: _bytes(vector.$3));
      expect(cert, _bytes(vector.$4));
      final inspected = ExternalCertificateDer.inspect(cert, role: vector.$1);
      expect(inspected.rawSignature, _bytes(vector.$3));
      expect(inspected.tbs, _bytes(vector.$2));
    }
    // Digests are independently checked against these literals in OpenSSL evidence.
    expect(_issuerDigestHex.length, 64);
    expect(_clientDigestHex.length, 64);
  });

  test('every OpenSSL-verified vector round trips raw -> DER -> raw', () {
    for (final (rawHex, derHex) in _signatureVectors) {
      final raw = _bytes(rawHex), der = _bytes(derHex);
      expect(ExternalCertificateDer.signatureFromRaw(raw), der, reason: rawHex);
      expect(ExternalCertificateDer.signatureToRaw(der), raw, reason: derHex);
      expect(
          ExternalCertificateDer.signatureFromRaw(
              ExternalCertificateDer.signatureToRaw(der)),
          der,
          reason: 'DER canonical round trip $derHex');
    }
    expect(_signatureVectors, hasLength(8));
  });

  test('inspect returns defensive copies of frozen structure fields', () {
    final inspected = ExternalCertificateDer.inspect(_bytes(_serverCertHex),
        role: ExternalCertificateRole.server);
    inspected.rawSignature.fillRange(0, 64, 0);
    inspected.tbs.fillRange(0, inspected.tbs.length, 0);
    expect(inspected.rawSignature, _bytes(_serverRawHex));
    expect(inspected.tbs, _bytes(_serverTbsHex));
  });

  test(
      'malformed raw or DER integers, lengths, fields, trailing and truncation',
      () {
    final order = _bytes(
        'ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551');
    for (final raw in [
      Uint8List(0),
      Uint8List(63),
      Uint8List(65),
      Uint8List(64), // r = 0
      Uint8List(64)..[31] = 1, // s = 0
      Uint8List.fromList([...order, ...List.filled(31, 0), 1]), // r = n
      Uint8List.fromList([...List.filled(31, 0), 1, ...order]), // s = n
    ]) {
      expect(() => ExternalCertificateDer.signatureFromRaw(raw), rejected);
    }
    for (final hex in [
      '',
      '3006020100020101', // r 为零
      '3006020101020100', // s 为零
      '3006020180020101', // 负 r／缺少符号零
      '3006020101020180', // 负 s／缺少符号零
      '300702020001020101', // 冗余前导零
      '300702010102020001',
      '30080202007f020101',
      '30050201010200', // 空整数
      '300602010102010101', // 尾随字节
      '3009020101020101020101', // 多余整数
      '308106020101020101', // 短长度使用长形式
      '30820006020101020101', // 过长长度形式
      '30800201010201010000', // 不定长度
      '30810106020101020101', // 前导零／长度不符
      '3007020101020101', // 截断
      '3106020101020101', // SET 代替 SEQUENCE
      '3006020101030101', // 标签错误
      '300702810101020101', // INTEGER 长度非最短形式
      '3006020101020101ff',
      '3000',
      '020101',
    ]) {
      expect(() => ExternalCertificateDer.signatureToRaw(_bytes(hex)), rejected,
          reason: hex);
    }
    final orderInteger =
        '022100ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551';
    expect(
        () => ExternalCertificateDer.signatureToRaw(
            _bytes('3026${orderInteger}020101')),
        rejected);
    expect(
        () => ExternalCertificateDer.signatureToRaw(
            _bytes('3026020101$orderInteger')),
        rejected);
    // 超过 72 字节的 DER 结构上限。
    final oversized = Uint8List.fromList([
      0x30,
      0x47,
      0x02,
      0x22,
      0x00,
      ...List.filled(33, 1),
      0x02,
      0x21,
      0x00,
      ...List.filled(33, 1),
    ]);
    expect(() => ExternalCertificateDer.signatureToRaw(oversized), rejected);
    for (var i = 0; i < _serverDerHex.length ~/ 2; i++) {
      expect(
          () => ExternalCertificateDer.signatureToRaw(
              Uint8List.fromList(_bytes(_serverDerHex).sublist(0, i))),
          rejected,
          reason: 'truncated $i');
    }
  });

  test('issuer/server/client exact structural roles and 2050 time switch', () {
    for (final role in ExternalCertificateRole.values) {
      final tbs = ExternalCertificateDer.buildTbs(
          role: role,
          serial16: serial,
          generationUtc: generation,
          publicKey: key);
      final cert = ExternalCertificateDer.assemble(
          role: role, tbs: tbs, rawSignature: _bytes(_serverRawHex));
      expect(ExternalCertificateDer.inspect(cert, role: role).role, role);
      for (final wrong
          in ExternalCertificateRole.values.where((e) => e != role)) {
        expect(
            () => ExternalCertificateDer.inspect(cert, role: wrong), rejected);
      }
    }
    final later = ExternalCertificateDer.buildTbs(
        role: ExternalCertificateRole.issuer,
        serial16: serial,
        generationUtc: DateTime.utc(2049, 12, 31),
        publicKey: key);
    expect(
        ExternalCertificateDer.inspect(
                ExternalCertificateDer.assemble(
                    role: ExternalCertificateRole.issuer,
                    tbs: later,
                    rawSignature: _bytes(_serverRawHex)),
                role: ExternalCertificateRole.issuer)
            .notAfter
            .year,
        greaterThan(2050));
    expect(
        () => ExternalCertificateDer.buildTbs(
            role: ExternalCertificateRole.server,
            serial16: Uint8List(16),
            generationUtc: generation,
            publicKey: key),
        rejected);
    expect(
        () => ExternalCertificateDer.buildTbs(
            role: ExternalCertificateRole.server,
            serial16: serial,
            generationUtc: generation,
            publicKey: Uint8List(65)),
        rejected);
    expect(
        () => ExternalCertificateDer.buildTbs(
            role: ExternalCertificateRole.server,
            serial16: serial,
            generationUtc: DateTime.utc(2026, 10, 15, 0, 0, 0, 1),
            publicKey: key),
        rejected);
    final leadingZeroTbs = ExternalCertificateDer.buildTbs(
        role: ExternalCertificateRole.client,
        serial16: _bytes('00${'11' * 15}'),
        generationUtc: generation,
        publicKey: key);
    expect(_children(leadingZeroTbs)[1], _bytes('020f${'11' * 15}'));
    expect(
        ExternalCertificateDer.inspect(
                ExternalCertificateDer.assemble(
                    role: ExternalCertificateRole.client,
                    tbs: leadingZeroTbs,
                    rawSignature: _bytes(_serverRawHex)),
                role: ExternalCertificateRole.client)
            .role,
        ExternalCertificateRole.client);
    final highSerial = _bytes('80${'00' * 15}');
    final highTbs = ExternalCertificateDer.buildTbs(
        role: ExternalCertificateRole.client,
        serial16: highSerial,
        generationUtc: generation,
        publicKey: key);
    expect(_children(highTbs)[1], _bytes('02110080${'00' * 15}'));
    expect(
        ExternalCertificateDer.inspect(
                ExternalCertificateDer.assemble(
                    role: ExternalCertificateRole.client,
                    tbs: highTbs,
                    rawSignature: _bytes(_serverRawHex)),
                role: ExternalCertificateRole.client)
            .role,
        ExternalCertificateRole.client);
  });

  test('structural success never proves signature: swapped scalars fail seam',
      () {
    final original = _bytes(_serverRawHex);
    final swapped = Uint8List.fromList(
        [...original.sublist(32), ...original.sublist(0, 32)]);
    final cert = ExternalCertificateDer.assemble(
        role: ExternalCertificateRole.server,
        tbs: _bytes(_serverTbsHex),
        rawSignature: swapped);
    final inspected = ExternalCertificateDer.inspect(cert,
        role: ExternalCertificateRole.server);
    expect(inspected.rawSignature, swapped);
    expect(_fakeVerify(inspected, _serverDigestHex), isFalse);
  });

  test('certificate rejects raw signature, bad BIT STRING and NULL parameters',
      () {
    for (final bits in [
      [0, ..._bytes(_serverRawHex)],
      [1, ..._bytes(_serverDerHex)],
      [0, ..._bytes(_serverDerHex), 0],
      [0, ..._bytes('3006020180020101')],
      <int>[],
    ]) {
      expect(
          () => ExternalCertificateDer.inspect(
              _certificate(_bytes(_serverTbsHex), signatureBits: bits),
              role: ExternalCertificateRole.server),
          rejected);
    }
    expect(
        () => ExternalCertificateDer.inspect(
            _certificate(_bytes(_serverTbsHex),
                outerAlgorithm: _bytes(_nullAlgorithmHex)),
            role: ExternalCertificateRole.server),
        rejected);
    final badTbs = _editTbs((fields) {
      fields[2] = _bytes(_nullAlgorithmHex);
      return fields;
    });
    expect(
        () => ExternalCertificateDer.inspect(_certificate(badTbs),
            role: ExternalCertificateRole.server),
        rejected);
  });

  test('extension exactness, absent/duplicate SAN and non-P256 SPKI reject',
      () {
    final baseFields = _children(_bytes(_serverTbsHex));
    final extensions = _children(_children(baseFields[7]).single);
    for (final candidate in [
      extensions.take(3).toList(), // 缺少 SAN
      [...extensions, extensions.last], // 重复 SAN
      [extensions[0], extensions[1], extensions[3], extensions[2]], // 顺序错误
      [
        extensions[0],
        extensions[1],
        extensions[2],
        _bytes(_sanHex)..[16] = 0
      ], // 非环回 IP
      [
        extensions[0],
        extensions[1],
        extensions[2],
        _bytes(_sanHex)..[9] = 0
      ], // 非关键 SAN
      [
        extensions[0],
        extensions[1],
        extensions[2],
        _bytes(_sanHex)..[4] = 0x56
      ], // 未知扩展 OID
      extensions.take(1).toList(), // 缺少 KU/EKU/SAN
    ]) {
      final edited = _editTbs((fields) {
        fields[7] =
            _tlv(0xa3, _tlv(0x30, candidate.expand((item) => item).toList()));
        return fields;
      });
      expect(
          () => ExternalCertificateDer.inspect(_certificate(edited),
              role: ExternalCertificateRole.server),
          rejected);
    }
    final wrongCurve = _editTbs((fields) {
      fields[6] = Uint8List.fromList(_replace(
          fields[6], '06082a8648ce3d030107', _bytes('06082a8648ce3d030108')));
      return fields;
    });
    expect(
        () => ExternalCertificateDer.inspect(_certificate(wrongCurve),
            role: ExternalCertificateRole.server),
        rejected);
    for (final replacement in [
      _bytes('300e0603551d0f0101ff040403020204'), // 非 digitalSignature
      _bytes('300e0603551d0f0101ff040403020780')..[9] = 0, // 非关键 KU
      _bytes('300c0603551d130101ff04023000'), // 非关键 BC
      _bytes('300e0603551d130101ff040830060101ff020100'), // 服务端 CA:TRUE
    ]) {
      final changed = _editTbs((fields) {
        fields[7] = Uint8List.fromList(_replace(
            fields[7], '300e0603551d0f0101ff040403020780', replacement));
        return fields;
      });
      expect(
          () => ExternalCertificateDer.inspect(_certificate(changed),
              role: ExternalCertificateRole.server),
          rejected);
    }
    final wrongEku = _editTbs((fields) {
      fields[7] = Uint8List.fromList(_replace(
          fields[7], '06082b06010505070301', _bytes('06082b06010505070302')));
      return fields;
    });
    expect(
        () => ExternalCertificateDer.inspect(_certificate(wrongEku),
            role: ExternalCertificateRole.server),
        rejected);
  });

  test('certificate truncation, trailing data, times and TBS splicing reject',
      () {
    final cert = _bytes(_serverCertHex);
    for (var i = 0; i < cert.length; i++) {
      expect(
          () => ExternalCertificateDer.inspect(
              Uint8List.fromList(cert.sublist(0, i)),
              role: ExternalCertificateRole.server),
          rejected,
          reason: 'length $i');
    }
    expect(
        () => ExternalCertificateDer.inspect(Uint8List.fromList([...cert, 0]),
            role: ExternalCertificateRole.server),
        rejected);
    for (final malformed in [
      Uint8List.fromList([0x30, 0x80, ...cert.sublist(4), 0, 0]),
      Uint8List.fromList([0x30, 0x83, 0, ...cert.sublist(2)]),
      _certificate(Uint8List.fromList(
          [0x30, 0x83, 0, ..._bytes(_serverTbsHex).sublist(2)])),
      _certificate(Uint8List.fromList([..._bytes(_serverTbsHex), 0])),
    ]) {
      expect(
          () => ExternalCertificateDer.inspect(malformed,
              role: ExternalCertificateRole.server),
          rejected);
    }
    final badDate = _editTbs((fields) {
      fields[4] = Uint8List.fromList(_replace(fields[4],
          '3238313031343030303030305a', _bytes('3238313031333030303030305a')));
      return fields;
    });
    expect(
        () => ExternalCertificateDer.assemble(
            role: ExternalCertificateRole.server,
            tbs: badDate,
            rawSignature: _bytes(_serverRawHex)),
        rejected);
    expect(
        () => ExternalCertificateDer.assemble(
            role: ExternalCertificateRole.server,
            tbs: _bytes('3000'),
            rawSignature: _bytes(_serverRawHex)),
        rejected);
  });
}

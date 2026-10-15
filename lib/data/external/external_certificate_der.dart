import 'dart:convert';
import 'dart:typed_data';

/// 仅供离线处理 X.509 结构；检视与组装都不验证签名、公钥曲线成员、信任链或当前有效期。
enum ExternalCertificateRole { issuer, server, client }

final class ExternalCertificateStructure {
  ExternalCertificateStructure._(this.role, this._tbs, this._publicKey,
      this._rawSignature, this.notBefore, this.notAfter);

  final ExternalCertificateRole role;
  final Uint8List _tbs;
  final Uint8List _publicKey;
  final Uint8List _rawSignature;
  final DateTime notBefore;
  final DateTime notAfter;

  Uint8List get tbs => Uint8List.fromList(_tbs);
  Uint8List get publicKey => Uint8List.fromList(_publicKey);
  Uint8List get rawSignature => Uint8List.fromList(_rawSignature);
}

abstract final class ExternalCertificateDer {
  static const _orderHex =
      'ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551';
  static final _order = BigInt.parse(_orderHex, radix: 16);
  static final _signatureAlgorithm = _Der.wrap(0x30, [
    ..._Der.wrap(0x06, [0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02])
  ]);
  static final _spkiAlgorithm = _Der.wrap(0x30, [
    ..._Der.wrap(0x06, [0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01]),
    ..._Der.wrap(0x06, [0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07]),
  ]);
  static final _issuerName = _name('Shiroha External Installation Issuer');
  static final _names = [
    _issuerName,
    _name('Shiroha External Host'),
    _name('Shiroha External Bridge'),
  ];
  static final _basicConstraintsOid = [0x55, 0x1d, 0x13];
  static final _keyUsageOid = [0x55, 0x1d, 0x0f];
  static final _ekuOid = [0x55, 0x1d, 0x25];
  static final _sanOid = [0x55, 0x1d, 0x11];

  /// Shares the P21 uncompressed-point shape check; not curve membership proof.
  static void inspectPublicPointShape(Uint8List publicKey) =>
      _checkPointShape(publicKey);

  static Uint8List signatureFromRaw(Uint8List raw) {
    if (raw.length != 64) _invalid();
    final r = _scalar(raw.sublist(0, 32));
    final s = _scalar(raw.sublist(32));
    return _Der.wrap(0x30, [..._integer(r), ..._integer(s)]);
  }

  static Uint8List signatureToRaw(Uint8List der) {
    if (der.length > 72) _invalid();
    final outer = _Cursor(der);
    final sequence = _Cursor(outer.read(0x30).body);
    outer.done();
    final r = _positiveInteger(sequence.read(0x02).body);
    final s = _positiveInteger(sequence.read(0x02).body);
    sequence.done();
    if (r <= BigInt.zero || s <= BigInt.zero || r >= _order || s >= _order) {
      _invalid();
    }
    return Uint8List.fromList([..._padded32(r), ..._padded32(s)]);
  }

  /// 调用方提供已生成的 16 字节正整数序列号及未压缩 P-256 公钥；不生成随机数、密钥或签名。
  static Uint8List buildTbs({
    required ExternalCertificateRole role,
    required Uint8List serial16,
    required DateTime generationUtc,
    required Uint8List publicKey,
  }) {
    if (serial16.length != 16 || serial16.every((byte) => byte == 0)) {
      _invalid();
    }
    _checkPointShape(publicKey);
    final generation = generationUtc.toUtc();
    final before = generation.subtract(const Duration(minutes: 5));
    final after = generation.add(
        Duration(days: role == ExternalCertificateRole.issuer ? 3650 : 730));
    if (generation.millisecond != 0 ||
        generation.microsecond != 0 ||
        before.year < 1950 ||
        after.year > 9999) {
      _invalid();
    }
    final serial = _unsigned(serial16);
    final validity = _Der.wrap(0x30, [..._time(before), ..._time(after)]);
    final spki = _Der.wrap(0x30, [
      ..._spkiAlgorithm,
      ..._Der.wrap(0x03, [0, ...publicKey]),
    ]);
    return _Der.wrap(0x30, [
      ..._Der.wrap(0xa0, _Der.wrap(0x02, [2])),
      ..._integer(serial),
      ..._signatureAlgorithm,
      ..._issuerName,
      ...validity,
      ..._names[role.index],
      ...spki,
      ..._Der.wrap(0xa3, _Der.wrap(0x30, _extensions(role))),
    ]);
  }

  /// `rawSignature` 应是签名方对原样 `tbs` 字节的输出；转成 DER 不验证这一声明。
  static Uint8List assemble({
    required ExternalCertificateRole role,
    required Uint8List tbs,
    required Uint8List rawSignature,
  }) {
    final derSignature = signatureFromRaw(rawSignature);
    final certificate = _Der.wrap(0x30, [
      ...tbs,
      ..._signatureAlgorithm,
      ..._Der.wrap(0x03, [0, ...derSignature]),
    ]);
    inspect(certificate, role: role);
    return certificate;
  }

  /// 严格检视离线结构与角色配置；绝不执行密码学签名验证。
  static ExternalCertificateStructure inspect(Uint8List certificate,
      {required ExternalCertificateRole role}) {
    if (certificate.length > 4096) _invalid();
    final root = _Cursor(certificate);
    final outer = _Cursor(root.read(0x30).body);
    root.done();
    final tbsNode = outer.read(0x30);
    final publicKeyAndTimes = _inspectTbs(tbsNode.body, role);
    _expect(outer.read(0x30).encoded, _signatureAlgorithm);
    final signatureBits = outer.read(0x03).body;
    outer.done();
    if (signatureBits.isEmpty || signatureBits.first != 0) _invalid();
    final raw = signatureToRaw(Uint8List.fromList(signatureBits.sublist(1)));
    return ExternalCertificateStructure._(
      role,
      Uint8List.fromList(tbsNode.encoded),
      publicKeyAndTimes.$1,
      raw,
      publicKeyAndTimes.$2,
      publicKeyAndTimes.$3,
    );
  }

  static (Uint8List, DateTime, DateTime) _inspectTbs(
      Uint8List body, ExternalCertificateRole role) {
    final tbs = _Cursor(body);
    _expect(tbs.read(0xa0).body, _Der.wrap(0x02, [2]));
    final serialBytes = tbs.read(0x02).body;
    final serial = _positiveInteger(serialBytes);
    if (serial <= BigInt.zero || _magnitude(serial).length > 16) _invalid();
    _expect(tbs.read(0x30).encoded, _signatureAlgorithm);
    _expect(tbs.read(0x30).encoded, _issuerName);
    final validity = _Cursor(tbs.read(0x30).body);
    final before = _readTime(validity);
    final after = _readTime(validity);
    validity.done();
    final expectedAfter = before.add(const Duration(minutes: 5)).add(
        Duration(days: role == ExternalCertificateRole.issuer ? 3650 : 730));
    if (after != expectedAfter) _invalid();
    _expect(tbs.read(0x30).encoded, _names[role.index]);
    final spki = _Cursor(tbs.read(0x30).body);
    _expect(spki.read(0x30).encoded, _spkiAlgorithm);
    final pointBits = spki.read(0x03).body;
    spki.done();
    if (pointBits.isEmpty || pointBits.first != 0) _invalid();
    final point = Uint8List.fromList(pointBits.sublist(1));
    _checkPointShape(point);
    final extensions = _Cursor(tbs.read(0xa3).body);
    _expect(extensions.read(0x30).body, _extensions(role));
    extensions.done();
    tbs.done();
    return (point, before, after);
  }

  static List<int> _extensions(ExternalCertificateRole role) {
    final issuer = role == ExternalCertificateRole.issuer;
    return [
      ..._extension(_basicConstraintsOid,
          _Der.wrap(0x30, issuer ? [0x01, 0x01, 0xff, 0x02, 0x01, 0x00] : []),
          critical: true),
      ..._extension(_keyUsageOid, _Der.wrap(0x03, issuer ? [2, 4] : [7, 0x80]),
          critical: true),
      if (!issuer)
        ..._extension(
            _ekuOid,
            _Der.wrap(
                0x30,
                _Der.wrap(0x06, [
                  0x2b,
                  0x06,
                  0x01,
                  0x05,
                  0x05,
                  0x07,
                  0x03,
                  role == ExternalCertificateRole.server ? 1 : 2,
                ]))),
      if (role == ExternalCertificateRole.server)
        ..._extension(_sanOid, _Der.wrap(0x30, [0x87, 4, 127, 0, 0, 1]),
            critical: true),
    ];
  }

  static List<int> _extension(List<int> oid, List<int> value,
          {bool critical = false}) =>
      [
        ..._Der.wrap(0x30, [
          ..._Der.wrap(0x06, oid),
          if (critical) ...[0x01, 0x01, 0xff],
          ..._Der.wrap(0x04, value),
        ])
      ];

  static List<int> _name(String cn) => _Der.wrap(0x30, [
        ..._Der.wrap(
            0x31,
            _Der.wrap(0x30, [
              ..._Der.wrap(0x06, [0x55, 0x04, 0x03]),
              ..._Der.wrap(0x0c, utf8.encode(cn)),
            ]))
      ]);

  static List<int> _time(DateTime value) {
    final utc = value.toUtc();
    final year = utc.year.toString().padLeft(4, '0');
    final text = '${utc.year >= 2050 ? year : year.substring(2)}'
        '${utc.month.toString().padLeft(2, '0')}'
        '${utc.day.toString().padLeft(2, '0')}'
        '${utc.hour.toString().padLeft(2, '0')}'
        '${utc.minute.toString().padLeft(2, '0')}'
        '${utc.second.toString().padLeft(2, '0')}Z';
    return _Der.wrap(utc.year >= 2050 ? 0x18 : 0x17, ascii.encode(text));
  }

  static DateTime _readTime(_Cursor cursor) {
    final node = cursor.readOneOf([0x17, 0x18]);
    final text = ascii.decode(node.body, allowInvalid: true);
    if (!RegExp(node.tag == 0x17 ? r'^\d{12}Z$' : r'^\d{14}Z$')
        .hasMatch(text)) {
      _invalid();
    }
    final year = node.tag == 0x17
        ? (int.parse(text.substring(0, 2)) >= 50 ? 1900 : 2000) +
            int.parse(text.substring(0, 2))
        : int.parse(text.substring(0, 4));
    final i = node.tag == 0x17 ? 2 : 4;
    final date = DateTime.utc(
        year,
        int.parse(text.substring(i, i + 2)),
        int.parse(text.substring(i + 2, i + 4)),
        int.parse(text.substring(i + 4, i + 6)),
        int.parse(text.substring(i + 6, i + 8)),
        int.parse(text.substring(i + 8, i + 10)));
    if (date.year < 1950 ||
        date.year > 9999 ||
        node.tag != (date.year >= 2050 ? 0x18 : 0x17) ||
        ascii.decode(_time(date).sublist(2)) != text) {
      _invalid();
    }
    return date;
  }

  static void _checkPointShape(Uint8List key) {
    if (key.length != 65 || key.first != 4) _invalid();
  }

  static BigInt _unsigned(List<int> bytes) {
    var n = BigInt.zero;
    for (final byte in bytes) {
      n = (n << 8) | BigInt.from(byte);
    }
    return n;
  }

  static BigInt _scalar(List<int> bytes) {
    final n = _unsigned(bytes);
    if (n <= BigInt.zero || n >= _order) _invalid();
    return n;
  }

  static BigInt _positiveInteger(Uint8List bytes) {
    if (bytes.isEmpty ||
        (bytes.first & 0x80) != 0 ||
        (bytes.length > 1 && bytes.first == 0 && (bytes[1] & 0x80) == 0)) {
      _invalid();
    }
    return _unsigned(bytes);
  }

  static List<int> _magnitude(BigInt number) {
    if (number == BigInt.zero) return [0];
    final out = <int>[];
    var current = number;
    while (current > BigInt.zero) {
      out.insert(0, (current & BigInt.from(255)).toInt());
      current >>= 8;
    }
    return out;
  }

  static List<int> _integer(BigInt number) {
    final bytes = _magnitude(number);
    return _Der.wrap(0x02, [if ((bytes.first & 0x80) != 0) 0, ...bytes]);
  }

  static List<int> _padded32(BigInt number) => [
        for (var i = _magnitude(number).length; i < 32; i++) 0,
        ..._magnitude(number)
      ];

  static void _expect(List<int> actual, List<int> expected) {
    if (actual.length != expected.length) _invalid();
    for (var i = 0; i < actual.length; i++) {
      if (actual[i] != expected[i]) _invalid();
    }
  }
}

Never _invalid() =>
    throw const FormatException('Invalid external certificate DER');

final class _Der {
  static Uint8List wrap(int tag, List<int> body) {
    final n = body.length;
    if (n > 4096) _invalid();
    final length = n < 128
        ? [n]
        : n < 256
            ? [0x81, n]
            : [0x82, n >> 8, n & 255];
    return Uint8List.fromList([tag, ...length, ...body]);
  }
}

final class _Node {
  _Node(this.tag, this.encoded, this.body);
  final int tag;
  final Uint8List encoded;
  final Uint8List body;
}

final class _Cursor {
  _Cursor(this.bytes);
  final Uint8List bytes;
  int offset = 0;

  _Node read(int tag) {
    final result = readOneOf([tag]);
    return result;
  }

  _Node readOneOf(List<int> tags) {
    final start = offset;
    if (offset + 2 > bytes.length) _invalid();
    final tag = bytes[offset++];
    if (!tags.contains(tag)) _invalid();
    var length = bytes[offset++];
    if ((length & 0x80) != 0) {
      final count = length & 0x7f;
      if (count == 0 ||
          count > 2 ||
          offset + count > bytes.length ||
          bytes[offset] == 0) {
        _invalid();
      }
      length = 0;
      for (var i = 0; i < count; i++) {
        length = (length << 8) | bytes[offset++];
      }
      if (length < 128 || (count == 2 && length < 256)) _invalid();
    }
    if (length > 4096 || length > bytes.length - offset) _invalid();
    final body = Uint8List.sublistView(bytes, offset, offset + length);
    offset += length;
    return _Node(tag, Uint8List.sublistView(bytes, start, offset), body);
  }

  void done() {
    if (offset != bytes.length) _invalid();
  }
}

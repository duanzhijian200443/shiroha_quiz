import 'dart:convert';
import 'dart:typed_data';

import '../../application/external/external_authorization.dart';
import '../../application/external/external_credential_association.dart';

/// 冻结 §9.B.3 的 kind 1/2/4 明文载荷编解码。
///
/// 本文件只处理版本化字节布局：不做 DPAPI、文件系统、TLS、信任链、密钥生成
/// 或授权判断，也不激活任何生产凭据。kind 3 仍由 `AssociationObjectCodec`
/// 独占，二者互不引用。
///
/// DER 与 installationId 都采用 u16le 字节长度前缀；完整消耗且严格校验 DER。
/// epoch 使用 BigInt 表示真正 u64 范围，和 P15 timestamp 上限无关。
sealed class ExternalCredentialObject {
  const ExternalCredentialObject();

  /// 冻结 kind 编号：1 issuerKeyPair、2 serverKeyChain、4 bridgeClient。
  int get kind;

  /// 严格序列化；字段越界或超限时按 `dataCorrupt` 失败，不截断。
  Uint8List encode();
}

/// kind 1：App 信任根。`publicationEpoch` 在创建时为 0，每次描述符发布提交 +1。
final class ExternalIssuerKeyPair extends ExternalCredentialObject {
  const ExternalIssuerKeyPair({
    required this.installationId,
    required this.publicationEpoch,
    required this.issuerPkcs8Der,
    required this.issuerCertificateDer,
  });

  final String installationId;
  final BigInt publicationEpoch;
  final Uint8List issuerPkcs8Der;
  final Uint8List issuerCertificateDer;

  @override
  int get kind => ExternalCredentialObjectCodec.issuerKeyPairKind;

  @override
  Uint8List encode() => ExternalCredentialObjectCodec.encode(this);

  @override
  String toString() => 'ExternalIssuerKeyPair(REDACTED)';
}

/// kind 2：App 服务端链；编解码只搬运字节，不判断链顺序或信任。
final class ExternalServerKeyChain extends ExternalCredentialObject {
  const ExternalServerKeyChain({
    required this.serverPkcs8Der,
    required this.serverLeafDer,
    required this.issuerCertificateDer,
  });

  final Uint8List serverPkcs8Der;
  final Uint8List serverLeafDer;
  final Uint8List issuerCertificateDer;

  @override
  int get kind => ExternalCredentialObjectCodec.serverKeyChainKind;

  @override
  Uint8List encode() => ExternalCredentialObjectCodec.encode(this);

  @override
  String toString() => 'ExternalServerKeyChain(REDACTED)';
}

/// kind 4：Bridge 客户端对象。pinned 字段是入网时已验证值的本地副本。
final class ExternalBridgeClient extends ExternalCredentialObject {
  const ExternalBridgeClient({
    required this.clientPkcs8Der,
    required this.clientLeafDer,
    required this.issuerCertificateDer,
    required this.pinnedInstallationId,
    required this.pinnedDiscoveryEpochHighWater,
  });

  final Uint8List clientPkcs8Der;
  final Uint8List clientLeafDer;
  final Uint8List issuerCertificateDer;
  final String pinnedInstallationId;
  final BigInt pinnedDiscoveryEpochHighWater;

  @override
  int get kind => ExternalCredentialObjectCodec.bridgeClientKind;

  @override
  Uint8List encode() => ExternalCredentialObjectCodec.encode(this);

  @override
  String toString() => 'ExternalBridgeClient(REDACTED)';
}

abstract final class ExternalCredentialObjectCodec {
  static const issuerKeyPairKind = 1,
      serverKeyChainKind = 2,
      bridgeClientKind = 4;
  static const maxBytes = 65536;
  static const maxPkcs8DerBytes = 256, maxCertificateDerBytes = 1024;
  static const maxInstallationIdBytes = 128;
  static final maxEpoch = (BigInt.one << 64) - BigInt.one;

  static BigInt nextEpoch(BigInt value) {
    if (value < BigInt.zero || value >= maxEpoch) {
      _corrupt();
    }
    return value + BigInt.one;
  }

  static const _magic = [83, 72, 82, 69, 88, 79, 66, 74];
  static const _version = 1;

  /// 按冻结 kind 分派严格解码；未知 magic/version/kind、截断、多余字节、
  /// 超限或不规范字段一律整对象 `dataCorrupt`，没有迁移、回退或尽力解析。
  static ExternalCredentialObject decode(Uint8List bytes) {
    try {
      if (bytes.length > maxBytes) {
        _corrupt();
      }
      final cursor = _Cursor(bytes);
      for (final byte in _magic) {
        if (cursor.byte() != byte) {
          _corrupt();
        }
      }
      if (cursor.byte() != _version) {
        _corrupt();
      }
      final object = switch (cursor.byte()) {
        issuerKeyPairKind => _decodeIssuer(cursor),
        serverKeyChainKind => _decodeServer(cursor),
        bridgeClientKind => _decodeBridge(cursor),
        _ => _corrupt(),
      };
      if (cursor.remaining != 0) {
        _corrupt();
      }
      return object;
    } on ExternalCredentialException {
      rethrow;
    } catch (_) {
      _corrupt();
    }
  }

  static Uint8List encode(ExternalCredentialObject object) {
    final out = BytesBuilder(copy: false)..add(_magic);
    out.addByte(_version);
    switch (object) {
      case ExternalIssuerKeyPair():
        out.addByte(issuerKeyPairKind);
        _writeInstallationId(out, object.installationId);
        _writeU64(out, object.publicationEpoch);
        _writeDer(out, object.issuerPkcs8Der, maxPkcs8DerBytes);
        _writeDer(out, object.issuerCertificateDer, maxCertificateDerBytes);
      case ExternalServerKeyChain():
        out.addByte(serverKeyChainKind);
        _writeDer(out, object.serverPkcs8Der, maxPkcs8DerBytes);
        _writeDer(out, object.serverLeafDer, maxCertificateDerBytes);
        _writeDer(out, object.issuerCertificateDer, maxCertificateDerBytes);
      case ExternalBridgeClient():
        out.addByte(bridgeClientKind);
        _writeDer(out, object.clientPkcs8Der, maxPkcs8DerBytes);
        _writeDer(out, object.clientLeafDer, maxCertificateDerBytes);
        _writeDer(out, object.issuerCertificateDer, maxCertificateDerBytes);
        _writeInstallationId(out, object.pinnedInstallationId);
        _writeU64(out, object.pinnedDiscoveryEpochHighWater);
    }
    final bytes = out.takeBytes();
    if (bytes.length > maxBytes) {
      _corrupt();
    }
    return bytes;
  }

  static ExternalIssuerKeyPair _decodeIssuer(_Cursor cursor) =>
      ExternalIssuerKeyPair(
        installationId: cursor.installationId(),
        publicationEpoch: cursor.u64(),
        issuerPkcs8Der: cursor.der(maxPkcs8DerBytes),
        issuerCertificateDer: cursor.der(maxCertificateDerBytes),
      );

  static ExternalServerKeyChain _decodeServer(_Cursor cursor) =>
      ExternalServerKeyChain(
        serverPkcs8Der: cursor.der(maxPkcs8DerBytes),
        serverLeafDer: cursor.der(maxCertificateDerBytes),
        issuerCertificateDer: cursor.der(maxCertificateDerBytes),
      );

  static ExternalBridgeClient _decodeBridge(_Cursor cursor) =>
      ExternalBridgeClient(
        clientPkcs8Der: cursor.der(maxPkcs8DerBytes),
        clientLeafDer: cursor.der(maxCertificateDerBytes),
        issuerCertificateDer: cursor.der(maxCertificateDerBytes),
        pinnedInstallationId: cursor.installationId(),
        pinnedDiscoveryEpochHighWater: cursor.u64(),
      );

  static void _writeInstallationId(BytesBuilder out, String value) {
    if (!ExternalAuthLimits.validId(value)) {
      _corrupt();
    }
    final encoded = utf8.encode(value);
    if (encoded.isEmpty || encoded.length > maxInstallationIdBytes) {
      _corrupt();
    }
    final header = ByteData(2)..setUint16(0, encoded.length, Endian.little);
    out.add(header.buffer.asUint8List());
    out.add(encoded);
  }

  static void _writeU64(BytesBuilder out, BigInt value) {
    if (value < BigInt.zero || value > maxEpoch) {
      _corrupt();
    }
    for (var i = 0; i < 8; i++) {
      out.addByte(((value >> (i * 8)) & BigInt.from(255)).toInt());
    }
  }

  static void _writeDer(BytesBuilder out, Uint8List value, int max) {
    _validateDer(value, max);
    final header = ByteData(2)..setUint16(0, value.length, Endian.little);
    out.add(header.buffer.asUint8List());
    out.add(value);
  }

  static void _validateDer(Uint8List bytes, int max) {
    if (bytes.length < 2 ||
        bytes.length > max ||
        bytes[0] != 0x30 ||
        _derBounds(bytes, 0, bytes.length, 0) != bytes.length) {
      _corrupt();
    }
  }

  // DER syntax, not certificate role/chain or cryptographic key validation.
  // OCTET STRING payloads stay opaque; their ASN.1 owner validates their meaning.
  static int _derBounds(Uint8List bytes, int start, int limit, int depth) {
    if (depth > 16 || limit - start < 2) {
      _corrupt();
    }
    final tag = bytes[start];
    if ((tag & 31) == 31 || tag == 0) {
      _corrupt();
    }
    var offset = start + 1;
    final first = bytes[offset++];
    var length = first;
    if ((first & 0x80) != 0) {
      final count = first & 0x7f;
      if (count == 0 ||
          count > 2 ||
          offset + count > limit ||
          bytes[offset] == 0) {
        _corrupt();
      }
      length = 0;
      for (var i = 0; i < count; i++) {
        length = (length << 8) | bytes[offset++];
      }
      if (length < 128 || (count == 2 && length < 256)) {
        _corrupt();
      }
    }
    final end = offset + length;
    if (end > limit) {
      _corrupt();
    }
    if ((tag & 0x20) != 0) {
      if ((tag & 0xc0) == 0 && tag != 0x30 && tag != 0x31) {
        _corrupt();
      }
      var child = offset;
      Uint8List? previous;
      while (child < end) {
        final next = _derBounds(bytes, child, end, depth + 1);
        if (tag == 0x31) {
          final current = Uint8List.sublistView(bytes, child, next);
          if (previous != null) {
            var comparison = 0;
            for (var i = 0; i < previous.length && i < current.length; i++) {
              if (previous[i] != current[i]) {
                comparison = previous[i] - current[i];
                break;
              }
            }
            if (comparison > 0 ||
                (comparison == 0 && previous.length > current.length)) {
              _corrupt();
            }
          }
          previous = current;
        }
        child = next;
      }
    } else if ((tag & 0xc0) == 0) {
      switch (tag) {
        case 0x01:
          if (length != 1 || (bytes[offset] != 0 && bytes[offset] != 255)) {
            _corrupt();
          }
        case 0x02:
          if (length == 0 ||
              (length > 1 &&
                  ((bytes[offset] == 0 && bytes[offset + 1] < 128) ||
                      (bytes[offset] == 255 && bytes[offset + 1] >= 128)))) {
            _corrupt();
          }
        case 0x03:
          if (length == 0 ||
              bytes[offset] > 7 ||
              (length == 1 && bytes[offset] != 0) ||
              (length > 1 &&
                  (bytes[end - 1] & ((1 << bytes[offset]) - 1)) != 0)) {
            _corrupt();
          }
        case 0x05:
          if (length != 0) {
            _corrupt();
          }
        case 0x06:
          if (length == 0 || (bytes[end - 1] & 128) != 0) {
            _corrupt();
          }
          var firstOctet = true;
          for (var i = offset; i < end; i++) {
            if (firstOctet && bytes[i] == 128) {
              _corrupt();
            }
            firstOctet = (bytes[i] & 128) == 0;
          }
        case 0x0c:
          try {
            utf8.decode(Uint8List.sublistView(bytes, offset, end),
                allowMalformed: false);
          } catch (_) {
            _corrupt();
          }
        case 0x13:
          final text = _ascii(Uint8List.sublistView(bytes, offset, end));
          if (!RegExp(r"^[A-Za-z0-9 '()+,./:=?-]*$").hasMatch(text)) {
            _corrupt();
          }
        case 0x16:
          if (Uint8List.sublistView(bytes, offset, end)
              .any((byte) => byte > 127)) {
            _corrupt();
          }
        case 0x17 || 0x18:
          _validateTime(tag, _ascii(Uint8List.sublistView(bytes, offset, end)));
        case 0x04:
          break;
        default:
          _corrupt();
      }
    }
    return end;
  }

  static String _ascii(Uint8List bytes) {
    if (bytes.any((byte) => byte > 127)) _corrupt();
    return String.fromCharCodes(bytes);
  }

  static void _validateTime(int tag, String text) {
    final utc = tag == 0x17;
    final pattern = utc
        ? RegExp(r'^[0-9]{12}Z$')
        : RegExp(r'^[0-9]{14}(?:\.[0-9]*[1-9])?Z$');
    if (!pattern.hasMatch(text)) {
      _corrupt();
    }
    // DER requires seconds and UTC Z, and a fraction (GeneralizedTime only)
    // uses '.' with no trailing zero. Calendar checks reject normalization.
    final yearDigits = utc ? 2 : 4;
    var year = int.parse(text.substring(0, yearDigits));
    if (utc) year += year >= 50 ? 1900 : 2000;
    int field(int offset) =>
        int.parse(text.substring(yearDigits + offset, yearDigits + offset + 2));
    final month = field(0),
        day = field(2),
        hour = field(4),
        minute = field(6),
        second = field(8);
    final date = DateTime.utc(year, month, day, hour, minute, second);
    if (date.year != year ||
        date.month != month ||
        date.day != day ||
        date.hour != hour ||
        date.minute != minute ||
        date.second != second) {
      _corrupt();
    }
  }

  static Never _corrupt() =>
      credentialFail(ExternalCredentialFailure.dataCorrupt);
}

final class _Cursor {
  _Cursor(this.bytes);
  final Uint8List bytes;
  int offset = 0;
  int get remaining => bytes.length - offset;

  int byte() {
    if (remaining < 1) ExternalCredentialObjectCodec._corrupt();
    return bytes[offset++];
  }

  Uint8List take(int count) {
    if (count < 0 || count > remaining) {
      ExternalCredentialObjectCodec._corrupt();
    }
    final view = Uint8List.fromList(
        Uint8List.sublistView(bytes, offset, offset + count));
    offset += count;
    return view;
  }

  BigInt u64() {
    final bytes = take(8);
    var value = BigInt.zero;
    for (var i = 7; i >= 0; i--) {
      value = (value << 8) | BigInt.from(bytes[i]);
    }
    return value;
  }

  String installationId() {
    final length = ByteData.sublistView(take(2)).getUint16(0, Endian.little);
    if (length < 1 ||
        length > ExternalCredentialObjectCodec.maxInstallationIdBytes) {
      ExternalCredentialObjectCodec._corrupt();
    }
    final text = utf8.decode(take(length), allowMalformed: false);
    if (!ExternalAuthLimits.validId(text)) {
      ExternalCredentialObjectCodec._corrupt();
    }
    return text;
  }

  Uint8List der(int max) {
    final length = ByteData.sublistView(take(2)).getUint16(0, Endian.little);
    if (length < 2 || length > max) ExternalCredentialObjectCodec._corrupt();
    final value = take(length);
    ExternalCredentialObjectCodec._validateDer(value, max);
    return value;
  }
}

import 'dart:convert';
import 'dart:typed_data';

import '../../application/external/external_authorization.dart';
import '../../services/backup/sha256.dart';
import 'external_certificate_der.dart';
import 'external_credential_object_codec.dart';

// Internal byte helpers shared only by the three frozen P22 formats.
// No registry, generic protocol, file access or authentication evidence.
typedef BootstrapDigestSigner = Uint8List Function(Uint8List digest);
typedef BootstrapDigestVerifier = bool Function({
  required Uint8List publicPoint,
  required Uint8List digest,
  required Uint8List rawSignature,
});

Never bootstrapInvalid() =>
    throw const FormatException('Invalid external bootstrap data');

Uint8List bootstrapCopy(List<int> bytes) =>
    Uint8List.fromList(bytes).asUnmodifiableView();

bool bootstrapEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var difference = 0;
  for (var i = 0; i < a.length; i++) {
    difference |= a[i] ^ b[i];
  }
  return difference == 0;
}

void bootstrapU64(BigInt value) {
  if (value < BigInt.zero || value > ExternalCredentialObjectCodec.maxEpoch) {
    bootstrapInvalid();
  }
}

void bootstrapUuid(String value) {
  if (value.length != 36 || !ExternalAuthLimits.validId(value)) {
    bootstrapInvalid();
  }
}

void bootstrapProfile(Uint8List value) {
  if (value.length != 16 || value[6] >> 4 != 4 || value[8] >> 6 != 2) {
    bootstrapInvalid();
  }
}

void bootstrapSignature(Uint8List value) {
  ExternalCertificateDer.signatureFromRaw(value);
}

Uint8List bootstrapDigest(List<int> bytes) {
  final hash = StreamingSha256()..update(bytes);
  final hex = hash.digestHex();
  return Uint8List.fromList([
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ]);
}

final class BootstrapWriter {
  final _out = BytesBuilder(copy: false);
  void fixed(Uint8List value, int size) {
    if (value.length != size) bootstrapInvalid();
    _out.add(value);
  }

  void header(String magic) {
    _out.add(ascii.encode(magic));
    _out.addByte(1);
  }

  void u16(int value) {
    if (value < 0 || value > 65535) bootstrapInvalid();
    _out.add([value & 255, value >> 8]);
  }

  void u64(BigInt value) {
    bootstrapU64(value);
    for (var i = 0; i < 8; i++) {
      _out.addByte(((value >> (i * 8)) & BigInt.from(255)).toInt());
    }
  }

  void field(Uint8List value, int max) {
    if (value.length > max) bootstrapInvalid();
    u16(value.length);
    _out.add(value);
  }

  void text(String value, int max) {
    if (value.length > max) bootstrapInvalid();
    // Dart's UTF-8 encoder replaces lone surrogates. Never silently normalize.
    final bytes = utf8.encode(value);
    if (utf8.decode(bytes) != value) bootstrapInvalid();
    field(Uint8List.fromList(bytes), max);
  }

  void uuid(String value) {
    bootstrapUuid(value);
    text(value, ExternalCredentialObjectCodec.maxInstallationIdBytes);
  }

  Uint8List finish(int max) {
    final bytes = _out.takeBytes();
    if (bytes.length > max) bootstrapInvalid();
    return bytes;
  }
}

final class BootstrapReader {
  BootstrapReader(Uint8List bytes, int max) : _bytes = _boundedCopy(bytes, max);

  static Uint8List _boundedCopy(Uint8List bytes, int max) {
    if (bytes.length > max) bootstrapInvalid();
    return bootstrapCopy(bytes);
  }

  final Uint8List _bytes;
  var _offset = 0;

  Uint8List fixed(int size) {
    if (size < 0 || size > _bytes.length - _offset) bootstrapInvalid();
    final result = bootstrapCopy(_bytes.sublist(_offset, _offset + size));
    _offset += size;
    return result;
  }

  void expect(List<int> value) {
    if (!bootstrapEqual(fixed(value.length), value)) bootstrapInvalid();
  }

  void header(String magic) {
    expect(ascii.encode(magic));
    expect([1]);
  }

  int u16() {
    final bytes = fixed(2);
    return bytes[0] | (bytes[1] << 8);
  }

  BigInt u64() {
    final bytes = fixed(8);
    var value = BigInt.zero;
    for (var i = 7; i >= 0; i--) {
      value = (value << 8) | BigInt.from(bytes[i]);
    }
    return value;
  }

  Uint8List field(int max) {
    final size = u16();
    if (size > max) bootstrapInvalid();
    return fixed(size);
  }

  String text(int max) => utf8.decode(field(max), allowMalformed: false);

  String uuid() {
    final value = text(ExternalCredentialObjectCodec.maxInstallationIdBytes);
    bootstrapUuid(value);
    return value;
  }

  void done() {
    if (_offset != _bytes.length) bootstrapInvalid();
  }
}

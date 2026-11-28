import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../services/backup/sha256.dart';
import 'android_native_association_backend.dart';
import 'external_certificate_der.dart';

final class AndroidHttpRootCertificate {
  const AndroidHttpRootCertificate._(this._der);

  final Uint8List _der;
  String get fingerprint => sha256Hex(_der);
  Uint8List get pem => Uint8List.fromList(
      ascii.encode(ExternalCertificateDer.encodePemCertificate(_der)));
}

final class AndroidHttpTlsMaterial {
  const AndroidHttpTlsMaterial._(this.root, this.chainPem, this.privateKey);

  final AndroidHttpRootCertificate root;
  final Uint8List chainPem;
  final Uint8List privateKey;
}

/// Uses the installation CA's native signing key and the existing DER codec.
/// Only the server leaf's key is handed to Dart, for the HTTPS bind.
final class AndroidHttpTls {
  AndroidHttpTls(this._native, {required DateTime Function() now}) : _now = now;

  final AndroidNativeCalls _native;
  final DateTime Function() _now;
  static const _leafDays = 90;

  Future<AndroidHttpRootCertificate?> readRoot() async {
    final der = await _native.invoke('httpCaRead');
    return der == null ? null : AndroidHttpRootCertificate._(_bytes(der));
  }

  Future<AndroidHttpRootCertificate> ensureRoot() async =>
      (await _ensureRoot()).$1;

  Future<(AndroidHttpRootCertificate, Uint8List)> _ensureRoot() async {
    final info = await _native.invoke('httpCaEnsure');
    if (info is! Map || info['nonExportable'] != true) _fail();
    final publicKey = _bytes(info['publicKey']);
    final ski = ExternalCertificateDer.computeKeyIdentifier(publicKey);
    var root = await readRoot();
    if (root == null) {
      final der = await _signed(
        role: ExternalCertificateRole.issuer,
        publicKey: publicKey,
        ski: ski,
        generation: _generation(),
      );
      if (await _native.invoke('httpCaStore', {'caDer': der}) != true) _fail();
      root = await readRoot();
      if (root == null || !listEquals(root._der, der)) _fail();
    }
    final certificate = ExternalCertificateDer.inspect(root._der,
        role: ExternalCertificateRole.issuer,
        expectedSubjectKeyIdentifier: ski);
    final now = _now();
    if (!listEquals(certificate.publicKey, publicKey) ||
        now.isBefore(certificate.notBefore) ||
        !now.isBefore(certificate.notAfter)) {
      _fail();
    }
    return (root, ski);
  }

  Future<AndroidHttpTlsMaterial> prepare(String address) async {
    ExternalCertificateDer.parsePrivateIpv4(address);
    final (root, caKeyIdentifier) = await _ensureRoot();
    final stored = await _openLeaf(root, address);
    if (stored != null) return stored;

    final generation = _generation();
    try {
      final publicKey = _bytes(await _native.invoke('httpLeafGenerateKey'));
      final der = await _signed(
        role: ExternalCertificateRole.server,
        publicKey: publicKey,
        ski: ExternalCertificateDer.computeKeyIdentifier(publicKey),
        aki: caKeyIdentifier,
        address: address,
        generation: generation,
        validityDays: _leafDays,
      );
      if (await _native.invoke('httpLeafStore', {
            'ipv4': address,
            'expiresAtUtcMs': generation
                .add(const Duration(days: _leafDays))
                .millisecondsSinceEpoch,
            'leafDer': der,
          }) !=
          true) {
        _fail();
      }
    } finally {
      await _native.invoke('httpLeafDiscard');
    }
    return await _openLeaf(root, address) ?? _fail();
  }

  Future<AndroidHttpTlsMaterial?> _openLeaf(
      AndroidHttpRootCertificate root, String address) async {
    final Object? reply;
    try {
      reply = await _native.invoke('httpLeafOpen');
    } on PlatformException catch (error) {
      if (error.code == 'pairing_required') return null;
      rethrow;
    }
    if (reply is! Map) _fail();
    final incomingKey = _bytes(reply['leafPrivateKeyPkcs8']);
    final key = Uint8List.fromList(incomingKey);
    try {
      incomingKey.fillRange(0, incomingKey.length, 0);
    } on UnsupportedError {
      // Platform codec buffers can be read-only. The TLS owner wipes its copy.
    }
    var retained = false;
    try {
      final expiry = reply['expiresAtUtcMs'];
      if (expiry is! int || !listEquals(_bytes(reply['caDer']), root._der)) {
        _fail();
      }
      if (reply['ipv4'] != address ||
          expiry <=
              _now().add(const Duration(days: 1)).millisecondsSinceEpoch) {
        return null;
      }
      final leaf =
          ExternalCertificateDer.encodePemCertificate(_bytes(reply['leafDer']));
      final rootPem = ExternalCertificateDer.encodePemCertificate(root._der);
      retained = true;
      return AndroidHttpTlsMaterial._(
          root, Uint8List.fromList(ascii.encode('$leaf$rootPem')), key);
    } finally {
      if (!retained) key.fillRange(0, key.length, 0);
    }
  }

  DateTime _generation() => DateTime.fromMillisecondsSinceEpoch(
      (_now().millisecondsSinceEpoch ~/ 1000) * 1000,
      isUtc: true);

  Future<Uint8List> _signed({
    required ExternalCertificateRole role,
    required Uint8List publicKey,
    required Uint8List ski,
    required DateTime generation,
    Uint8List? aki,
    String? address,
    int? validityDays,
  }) async {
    final random = Random.secure();
    final serial =
        Uint8List.fromList(List.generate(16, (_) => random.nextInt(256)));
    if (serial.every((byte) => byte == 0)) serial[15] = 1;
    final tbs = ExternalCertificateDer.buildTbs(
        role: role,
        serial16: serial,
        generationUtc: generation,
        publicKey: publicKey,
        ipv4San: address,
        subjectKeyIdentifier: ski,
        authorityKeyIdentifier: aki,
        validityDays: validityDays);
    final signature =
        _bytes(await _native.invoke('httpCaSignTbs', {'tbs': tbs}));
    return ExternalCertificateDer.assembleFromDerSignature(
        role: role,
        tbs: tbs,
        derSignature: signature,
        expectedIpv4San: address,
        expectedSubjectKeyIdentifier: ski,
        expectedAuthorityKeyIdentifier: aki,
        expectedValidityDays: validityDays);
  }

  static Uint8List _bytes(Object? value) {
    if (value is! Uint8List || value.isEmpty || value.length > 4096) _fail();
    return value;
  }

  static Never _fail() =>
      throw const FormatException('android_http_tls_material');
}

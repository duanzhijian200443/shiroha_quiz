import 'dart:math';
import 'dart:typed_data';

import '../../application/external/external_authorization.dart';
import '../../application/external/external_credential_association.dart';
import '../../services/backup/sha256.dart';
import 'external_certificate_der.dart';
import 'discovery_descriptor_codec.dart';
import 'external_credential_object_codec.dart';
import 'native/windows_external_crypto.dart';
import 'native/windows_external_native.dart';
import 'windows_credential_object_store.dart';

typedef CredentialDigestSigner = Uint8List Function({
  required Uint8List pkcs8Der,
  required Uint8List publicPoint,
  required Uint8List digest,
});
typedef CredentialDigestVerifier = void Function({
  required Uint8List publicPoint,
  required Uint8List digest,
  required Uint8List rawSignature,
});

enum ExternalInitializationState { initialized, existing, incomplete }

/// Public material only, never runtime readiness or authorization evidence.
final class ExternalInitializationResult {
  ExternalInitializationResult(this.state, this.installationId,
      this.publicationEpoch, Uint8List issuer, Uint8List? server)
      : issuerCertificateDer = Uint8List.fromList(issuer).asUnmodifiableView(),
        serverLeafDer = server == null
            ? null
            : Uint8List.fromList(server).asUnmodifiableView();
  final ExternalInitializationState state;
  final String installationId;
  final BigInt publicationEpoch;
  final Uint8List issuerCertificateDer;
  final Uint8List? serverLeafDer;
  @override
  String toString() => 'ExternalInitializationResult(${state.name}, REDACTED)';
}

/// Issuance does not prove client possession, Pairing or Association membership.
final class ExternalClientLeaf {
  ExternalClientLeaf(Uint8List leaf, Uint8List issuer)
      : clientLeafDer = Uint8List.fromList(leaf).asUnmodifiableView(),
        issuerCertificateDer = Uint8List.fromList(issuer).asUnmodifiableView(),
        credentialIdentity = _hashHex(leaf);
  final Uint8List clientLeafDer, issuerCertificateDer;
  final String credentialIdentity;
  @override
  String toString() => 'ExternalClientLeaf(REDACTED)';
}

/// Explicit inactive App infrastructure. Never called by a composition root.
/// The caller owns/drains/closes the protected App Owner. Operations are bounded
/// and synchronous, with no background retries or cross-file atomicity claim.
final class WindowsCredentialInitialization {
  WindowsCredentialInitialization({
    required ExternalProtectedObjects owner,
    required WindowsExternalCrypto crypto,
  }) : this.withPrimitives(
          owner: owner,
          generateKey: crypto.generateKey,
          signDigest: crypto.signDigest,
          verifyDigest: crypto.verifyDigest,
          utcNow: () => DateTime.now().toUtc(),
          randomBytes: _secureBytes,
        );

  /// Trusted injection seam for G0-L0. No accepting/default verifier exists.
  WindowsCredentialInitialization.withPrimitives({
    required ExternalProtectedObjects owner,
    required ExternalP256KeyPair Function() generateKey,
    required CredentialDigestSigner signDigest,
    required CredentialDigestVerifier verifyDigest,
    required DateTime Function() utcNow,
    required Uint8List Function(int count) randomBytes,
  })  : _storeOwner = owner,
        _store = WindowsCredentialObjectStore(owner),
        _generate = generateKey,
        _sign = signDigest,
        _verify = verifyDigest,
        _now = utcNow,
        _random = randomBytes;

  final WindowsCredentialObjectStore _store;
  final ExternalProtectedObjects _storeOwner;
  final ExternalP256KeyPair Function() _generate;
  final CredentialDigestSigner _sign;
  final CredentialDigestVerifier _verify;
  final DateTime Function() _now;
  final Uint8List Function(int) _random;
  bool _busy = false;
  bool usesOwner(ExternalProtectedObjects owner) =>
      identical(_storeOwner, owner);

  /// Explicit public export from existing, freshly verified credentials only.
  /// Missing/partial state rejects; this action never initializes or recovers.
  ExternalInitializationResult validatedPublicMaterial() => _operation(() {
        final pair = _read(_time());
        try {
          if (pair.$1 == null || pair.$2 == null) {
            credentialFail(ExternalCredentialFailure.unauthorized);
          }
          return _result(
              pair.$1!, pair.$2, ExternalInitializationState.existing);
        } finally {
          _clear(pair.$1, pair.$2);
        }
      });

  /// Revalidates the current persisted pair and exact publication immediately
  /// before I/O; this neither initializes nor repairs missing credentials.
  ExternalInitializationResult validatePublication(
          DiscoveryDescriptor descriptor) =>
      _operation(() {
        final pair = _read(_time());
        try {
          if (pair.$1 == null || pair.$2 == null) {
            credentialFail(ExternalCredentialFailure.unauthorized);
          }
          final issuer = pair.$1!, server = pair.$2!;
          if (issuer.publicationEpoch != descriptor.publicationEpoch) {
            _conflict();
          }
          DiscoveryDescriptorCodec.validatePublicObjects(descriptor,
              anchorDer: issuer.issuerCertificateDer,
              installationIdBytes:
                  Uint8List.fromList(issuer.installationId.codeUnits),
              expected: DiscoveryExpectations(
                  trustedAnchorDer: issuer.issuerCertificateDer,
                  installationId: issuer.installationId,
                  serverLeafDigest: _hash(server.serverLeafDer),
                  verifiedEpochHighWater: issuer.publicationEpoch),
              verifier: (
                  {required publicPoint,
                  required digest,
                  required rawSignature}) {
            _verify(
                publicPoint: publicPoint,
                digest: digest,
                rawSignature: rawSignature);
            return true;
          });
          return _result(issuer, server, ExternalInitializationState.existing);
        } finally {
          _clear(pair.$1, pair.$2);
        }
      });

  /// P26 inactive preparation: commit epoch under one ticket before signing.
  /// Public runtime inputs describe an offline candidate, never listener liveness.
  DiscoveryDescriptor prepareDiscoveryDescriptor(
          {required Uint8List runtimeInstanceId,
          required BigInt generation,
          required int port,
          required BigInt publishedAtUtcMs}) =>
      _operation(() {
        final now = _time();
        final pair = _read(now);
        try {
          final issuer = pair.$1, server = pair.$2;
          if (issuer == null || server == null) {
            credentialFail(ExternalCredentialFailure.unauthorized);
          }
          DiscoveryDescriptor value(BigInt epoch, Uint8List signature) =>
              DiscoveryDescriptor(
                  runtimeInstanceId: runtimeInstanceId,
                  publicationEpoch: epoch,
                  generation: generation,
                  port: port,
                  serverLeafDigest: _hash(server.serverLeafDer),
                  installationId: issuer.installationId,
                  publishedAtUtcMs: publishedAtUtcMs,
                  rawSignature: signature);
          // Reject invalid public input and overflow without consuming an epoch.
          final next =
              ExternalCredentialObjectCodec.nextEpoch(issuer.publicationEpoch);
          DiscoveryDescriptorCodec.unsignedBytes(value(next, Uint8List(0)));
          final epoch = _store.advancePublicationEpoch(
              issuer, (current) => _validateIssuer(current, now));
          final committed = _read(now);
          try {
            if (committed.$1 == null ||
                committed.$2 == null ||
                committed.$1!.publicationEpoch != epoch ||
                committed.$1!.installationId != issuer.installationId ||
                !_equal(committed.$1!.issuerCertificateDer,
                    issuer.issuerCertificateDer) ||
                !_equal(committed.$2!.serverLeafDer, server.serverLeafDer)) {
              _conflict();
            }
            final unsigned = value(epoch, Uint8List(0));
            final cert = _validateIssuer(committed.$1!, now);
            final signature = _sign(
                pkcs8Der: committed.$1!.issuerPkcs8Der,
                publicPoint: cert.publicKey,
                digest: DiscoveryDescriptorCodec.digest(unsigned));
            _verify(
                publicPoint: cert.publicKey,
                digest: DiscoveryDescriptorCodec.digest(unsigned),
                rawSignature: signature);
            return value(epoch, signature);
          } finally {
            _clear(committed.$1, committed.$2);
          }
        } finally {
          _clear(pair.$1, pair.$2);
        }
      });

  /// Both absent permits first create. A partial Issuer is returned incomplete;
  /// only recoverServer() can explicitly finish it. Valid pairs are reused.
  ExternalInitializationResult initialize() => _operation(() {
        final now = _time();
        final pair = _read(now);
        try {
          if (pair.$1 != null) {
            return _result(
                pair.$1!,
                pair.$2,
                pair.$2 == null
                    ? ExternalInitializationState.incomplete
                    : ExternalInitializationState.existing);
          }
        } finally {
          _clear(pair.$1, pair.$2);
        }
        // Generation occurs only after Missing is rechecked under the ticket.
        if (!_store.createIfMissing(1, () => _newIssuer(now))) _conflict();
        // This is a new persisted fact, not the transient generated candidate.
        // A failure/commitUnknown exits immediately; never auto-rekey/rollback.
        return _finishServer(now, ExternalInitializationState.initialized);
      });

  /// Fresh explicit recovery after a partial/unknown operation. Never generates
  /// an Issuer. Existing valid Server is reused, never rotated or replaced.
  ExternalInitializationResult recoverServer() => _operation(
      () => _finishServer(_time(), ExternalInitializationState.initialized));

  /// Accepts only an untrusted uncompressed P-256 point. No Client private key,
  /// anchor, profile, extensions, algorithm or runtime state enters this API.
  ExternalClientLeaf issueClientLeaf(Uint8List publicPoint) => _operation(() {
        if (publicPoint.length != 65) {
          credentialFail(ExternalCredentialFailure.verificationRejected);
        }
        final point = Uint8List.fromList(publicPoint);
        _curvePoint(point, ExternalCredentialFailure.verificationRejected);
        final now = _time();
        final pair = _read(now);
        try {
          if (pair.$1 == null || pair.$2 == null) {
            credentialFail(ExternalCredentialFailure.unauthorized);
          }
          final issuer = pair.$1!;
          final structure = _certificate(
              issuer.issuerCertificateDer, ExternalCertificateRole.issuer, now);
          final leaf = _issue(
              ExternalCertificateRole.client, point, issuer, structure, now);
          _checkSigned(leaf, ExternalCertificateRole.client, structure, now);
          return ExternalClientLeaf(leaf, issuer.issuerCertificateDer);
        } finally {
          _clear(pair.$1, pair.$2);
        }
      });

  ExternalInitializationResult _finishServer(
      DateTime now, ExternalInitializationState state) {
    final pair = _read(now);
    try {
      final issuer = pair.$1;
      if (issuer == null) {
        credentialFail(ExternalCredentialFailure.unauthorized);
      }
      if (pair.$2 != null) {
        return _result(issuer, pair.$2, ExternalInitializationState.existing);
      }
      if (!_store.createIfMissing(2, () => _newServer(issuer, now))) {
        _conflict();
      }
    } finally {
      _clear(pair.$1, pair.$2);
    }
    final committed = _read(now);
    try {
      if (committed.$1 == null || committed.$2 == null) _corrupt();
      return _result(committed.$1!, committed.$2, state);
    } finally {
      _clear(committed.$1, committed.$2);
    }
  }

  (ExternalIssuerKeyPair?, ExternalServerKeyChain?) _read(DateTime now) {
    ExternalIssuerKeyPair? issuer;
    ExternalServerKeyChain? server;
    try {
      issuer = _store.read(1) as ExternalIssuerKeyPair?;
      server = _store.read(2) as ExternalServerKeyChain?;
      if (issuer == null) {
        if (server != null) _corrupt();
      } else {
        final structure = _validateIssuer(issuer, now);
        if (server != null) _validateServer(server, issuer, structure, now);
      }
      return (issuer, server);
    } catch (_) {
      _clear(issuer, server);
      rethrow;
    }
  }

  ExternalCertificateStructure _validateIssuer(
      ExternalIssuerKeyPair issuer, DateTime now) {
    if (issuer.installationId.length != 36 ||
        !ExternalAuthLimits.validId(issuer.installationId) ||
        issuer.publicationEpoch < BigInt.zero ||
        issuer.publicationEpoch > ExternalCredentialObjectCodec.maxEpoch) {
      _corrupt();
    }
    final cert = _certificate(
        issuer.issuerCertificateDer, ExternalCertificateRole.issuer, now);
    _verify(
        publicPoint: cert.publicKey,
        digest: _hash(cert.tbs),
        rawSignature: cert.rawSignature);
    _keyMatches(issuer.issuerPkcs8Der, cert);
    return cert;
  }

  void _validateServer(
      ExternalServerKeyChain server,
      ExternalIssuerKeyPair issuer,
      ExternalCertificateStructure anchor,
      DateTime now) {
    if (!_equal(server.issuerCertificateDer, issuer.issuerCertificateDer)) {
      credentialFail(ExternalCredentialFailure.verificationRejected);
    }
    final cert = _checkSigned(
        server.serverLeafDer, ExternalCertificateRole.server, anchor, now);
    _keyMatches(server.serverPkcs8Der, cert);
  }

  ExternalCertificateStructure _certificate(
      Uint8List der, ExternalCertificateRole role, DateTime now) {
    final cert = ExternalCertificateDer.inspect(der, role: role);
    _curvePoint(cert.publicKey, ExternalCredentialFailure.dataCorrupt);
    if (now.isBefore(cert.notBefore) || !now.isBefore(cert.notAfter)) {
      credentialFail(ExternalCredentialFailure.verificationRejected);
    }
    return cert;
  }

  ExternalCertificateStructure _checkSigned(
      Uint8List der,
      ExternalCertificateRole role,
      ExternalCertificateStructure issuer,
      DateTime now) {
    final cert = _certificate(der, role, now);
    if (cert.notBefore.isBefore(issuer.notBefore) ||
        cert.notAfter.isAfter(issuer.notAfter)) {
      credentialFail(ExternalCredentialFailure.verificationRejected);
    }
    _verify(
        publicPoint: issuer.publicKey,
        digest: _hash(cert.tbs),
        rawSignature: cert.rawSignature);
    return cert;
  }

  void _keyMatches(Uint8List key, ExternalCertificateStructure cert) {
    // Actual signing+verification checks the scalar/point relationship, including
    // PKCS#8 without an embedded public point; ASN.1 equality cannot prove it.
    final digest = _hash(cert.tbs);
    final signature =
        _sign(pkcs8Der: key, publicPoint: cert.publicKey, digest: digest);
    _verify(
        publicPoint: cert.publicKey, digest: digest, rawSignature: signature);
  }

  ExternalIssuerKeyPair _newIssuer(DateTime now) {
    final idBytes = _bytes(16);
    idBytes[6] = (idBytes[6] & 0x0f) | 0x40;
    idBytes[8] = (idBytes[8] & 0x3f) | 0x80;
    final hex = _hex(idBytes);
    final id = '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
    final key = _generate();
    try {
      _curvePoint(key.publicPoint, ExternalCredentialFailure.dataCorrupt);
      final tbs = _tbs(ExternalCertificateRole.issuer, key.publicPoint, now);
      final der = ExternalCertificateDer.assemble(
          role: ExternalCertificateRole.issuer,
          tbs: tbs,
          rawSignature: _sign(
              pkcs8Der: key.pkcs8Der,
              publicPoint: key.publicPoint,
              digest: _hash(tbs)));
      final candidate = ExternalIssuerKeyPair(
          installationId: id,
          publicationEpoch: BigInt.zero,
          issuerPkcs8Der: key.pkcs8Der,
          issuerCertificateDer: der);
      _validateIssuer(candidate, now);
      // Ownership passes to createIfMissing, which wipes factory output.
      return candidate;
    } catch (_) {
      key.clearPrivateKey();
      rethrow;
    }
  }

  ExternalServerKeyChain _newServer(
      ExternalIssuerKeyPair issuer, DateTime now) {
    final anchor = _validateIssuer(issuer, now);
    final key = _generate();
    try {
      _curvePoint(key.publicPoint, ExternalCredentialFailure.dataCorrupt);
      final der = _issue(
          ExternalCertificateRole.server, key.publicPoint, issuer, anchor, now);
      final candidate = ExternalServerKeyChain(
          serverPkcs8Der: key.pkcs8Der,
          serverLeafDer: der,
          issuerCertificateDer:
              Uint8List.fromList(issuer.issuerCertificateDer));
      _validateServer(candidate, issuer, anchor, now);
      return candidate;
    } catch (_) {
      key.clearPrivateKey();
      rethrow;
    }
  }

  Uint8List _issue(
      ExternalCertificateRole role,
      Uint8List point,
      ExternalIssuerKeyPair issuer,
      ExternalCertificateStructure anchor,
      DateTime now) {
    if (now.subtract(const Duration(minutes: 5)).isBefore(anchor.notBefore) ||
        now.add(const Duration(days: 730)).isAfter(anchor.notAfter)) {
      credentialFail(ExternalCredentialFailure.verificationRejected);
    }
    final tbs = _tbs(role, point, now);
    return ExternalCertificateDer.assemble(
        role: role,
        tbs: tbs,
        rawSignature: _sign(
            pkcs8Der: issuer.issuerPkcs8Der,
            publicPoint: anchor.publicKey,
            digest: _hash(tbs)));
  }

  Uint8List _tbs(ExternalCertificateRole role, Uint8List point, DateTime now) =>
      ExternalCertificateDer.buildTbs(
          role: role,
          serial16: _bytes(16),
          generationUtc: now,
          publicKey: point);

  Uint8List _bytes(int count) {
    final bytes = _random(count);
    if (bytes.length != count || bytes.every((b) => b == 0)) {
      credentialFail(ExternalCredentialFailure.invalidInput);
    }
    return bytes;
  }

  DateTime _time() {
    final value = _now().toUtc();
    final time = DateTime.fromMillisecondsSinceEpoch(
        (value.millisecondsSinceEpoch ~/ 1000) * 1000,
        isUtc: true);
    if (time.subtract(const Duration(minutes: 5)).year < 1950 ||
        time.add(const Duration(days: 3650)).year > 9999) {
      credentialFail(ExternalCredentialFailure.invalidInput);
    }
    return time;
  }

  T _operation<T>(T Function() run) {
    if (_busy) credentialFail(ExternalCredentialFailure.temporarilyUnavailable);
    _busy = true;
    try {
      return run();
    } on ExternalCredentialException {
      rethrow;
    } on FormatException {
      _corrupt();
    } on ExternalNativeException catch (e) {
      credentialFail(switch (e.failure) {
        ExternalNativeFailure.verificationRejected =>
          ExternalCredentialFailure.verificationRejected,
        ExternalNativeFailure.invalidInput ||
        ExternalNativeFailure.dataCorrupt =>
          ExternalCredentialFailure.dataCorrupt,
        ExternalNativeFailure.resourceLimit =>
          ExternalCredentialFailure.resourceLimit,
        ExternalNativeFailure.commitUnknown =>
          ExternalCredentialFailure.commitUnknown,
        _ => ExternalCredentialFailure.temporarilyUnavailable,
      });
    } catch (_) {
      credentialFail(ExternalCredentialFailure.temporarilyUnavailable);
    } finally {
      _busy = false;
    }
  }

  static ExternalInitializationResult _result(ExternalIssuerKeyPair issuer,
          ExternalServerKeyChain? server, ExternalInitializationState state) =>
      ExternalInitializationResult(
          state,
          issuer.installationId,
          issuer.publicationEpoch,
          issuer.issuerCertificateDer,
          server?.serverLeafDer);

  static void _clear(
      ExternalIssuerKeyPair? issuer, ExternalServerKeyChain? server) {
    issuer?.issuerPkcs8Der.fillRange(0, issuer.issuerPkcs8Der.length, 0);
    server?.serverPkcs8Der.fillRange(0, server.serverPkcs8Der.length, 0);
  }

  @override
  String toString() => 'WindowsCredentialInitialization(REDACTED)';
}

Never _corrupt() => credentialFail(ExternalCredentialFailure.dataCorrupt);
Never _conflict() => credentialFail(ExternalCredentialFailure.conflict);
Uint8List _secureBytes(int count) {
  final random = Random.secure();
  return Uint8List.fromList(List.generate(count, (_) => random.nextInt(256)));
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
String _hashHex(List<int> bytes) =>
    (StreamingSha256()..update(bytes)).digestHex();
Uint8List _hash(List<int> bytes) {
  final hex = _hashHex(bytes);
  return Uint8List.fromList([
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16)
  ]);
}

bool _equal(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var difference = 0;
  for (var i = 0; i < a.length; i++) {
    difference |= a[i] ^ b[i];
  }
  return difference == 0;
}

// P-256 has cofactor 1: a finite canonical point satisfying its equation is in
// the prime-order group. This rejects malformed peer material before signing;
// it proves no possession and is not an ECDSA implementation.
void _curvePoint(Uint8List point, ExternalCredentialFailure failure) {
  if (point.length != 65 || point[0] != 4) credentialFail(failure);
  BigInt integer(List<int> bytes) =>
      bytes.fold(BigInt.zero, (n, b) => (n << 8) | BigInt.from(b));
  final p = BigInt.parse(
      'ffffffff00000001000000000000000000000000ffffffffffffffffffffffff',
      radix: 16);
  final b = BigInt.parse(
      '5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b',
      radix: 16);
  final x = integer(point.sublist(1, 33)), y = integer(point.sublist(33));
  if (x >= p ||
      y >= p ||
      (y * y - x * x * x + BigInt.from(3) * x - b) % p != BigInt.zero) {
    credentialFail(failure);
  }
}

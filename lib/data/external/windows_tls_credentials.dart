part of 'windows_tls_transport.dart';

/// Pure configuration/PEM plan. Construction verifies real signatures and key
/// correspondence through P21's injected primitives, without creating TLS state.
final class TlsContextPlan {
  TlsContextPlan._(this.role, this._leaf, this._anchor, this._key,
      this.notBefore, this.notAfter, this._now);
  final TlsPeerRole role;
  final Uint8List _leaf, _anchor, _key;
  final DateTime notBefore, notAfter;
  final DateTime Function() _now;
  bool _disposed = false;
  SecurityContext? _context;
  bool get isCurrent =>
      !_disposed && !_now().isBefore(notBefore) && _now().isBefore(notAfter);
  Uint8List get leafDigest => _tlsHash(_leaf);
  Uint8List get anchorDer => Uint8List.fromList(_anchor);

  static TlsContextPlan validate(
      {required TlsPeerRole role,
      required Uint8List leafDer,
      required Uint8List issuerDer,
      required Uint8List privateKeyDer,
      required Uint8List independentlyPinnedIssuer,
      required CredentialDigestSigner signDigest,
      required CredentialDigestVerifier verifyDigest,
      required DateTime Function() utcNow}) {
    if (!bootstrapEqual(issuerDer, independentlyPinnedIssuer) ||
        privateKeyDer.isEmpty ||
        privateKeyDer.length > ExternalCredentialObjectCodec.maxPkcs8DerBytes) {
      _tlsReject();
    }
    final issuer = ExternalCertificateDer.inspect(issuerDer,
        role: ExternalCertificateRole.issuer);
    final leaf = ExternalCertificateDer.inspect(leafDer,
        role: role == TlsPeerRole.server
            ? ExternalCertificateRole.server
            : ExternalCertificateRole.client);
    final now = utcNow();
    for (final cert in [issuer, leaf]) {
      if (now.isBefore(cert.notBefore) || !now.isBefore(cert.notAfter)) {
        _tlsReject();
      }
      verifyDigest(
          publicPoint: issuer.publicKey,
          digest: _tlsHash(cert.tbs),
          rawSignature: cert.rawSignature);
    }
    if (leaf.notBefore.isBefore(issuer.notBefore) ||
        leaf.notAfter.isAfter(issuer.notAfter)) {
      _tlsReject();
    }
    final keyProofDigest = _tlsHash(leaf.tbs);
    final signature = signDigest(
        pkcs8Der: privateKeyDer,
        publicPoint: leaf.publicKey,
        digest: keyProofDigest);
    verifyDigest(
        publicPoint: leaf.publicKey,
        digest: keyProofDigest,
        rawSignature: signature);
    return TlsContextPlan._(
        role,
        Uint8List.fromList(leafDer),
        Uint8List.fromList(issuerDer),
        Uint8List.fromList(privateKeyDer),
        leaf.notBefore,
        leaf.notAfter,
        utcNow);
  }

  /// Fake sink verifies exact configuration and order without BoringSSL calls.
  void configure(TlsContextSink sink) {
    if (!isCurrent) _tlsReject();
    sink.minimumTls13();
    sink.disableRenegotiation();
    // Frozen LEAF FIRST, ISSUER LAST; never the misleading root-first dartdoc.
    sink.chain(Uint8List.fromList(
        [..._pem('CERTIFICATE', _leaf), ..._pem('CERTIFICATE', _anchor)]));
    final key = _pem('PRIVATE KEY', _key);
    try {
      sink.privateKey(key);
    } finally {
      key.fillRange(0, key.length, 0);
    }
    final anchor = _pem('CERTIFICATE', _anchor);
    sink.trustOnly(anchor);
    if (role == TlsPeerRole.server) sink.clientAuthorities(anchor);
  }

  SecurityContext createSecurityContext() {
    if (!isCurrent) _tlsReject();
    // Exactly one context per validated listener/connection plan. In particular,
    // P15's bounded one-use event cache must not retain a new native context for
    // every closed server connection. No context is created by construction.
    return _context ??= () {
      final context = SecurityContext(withTrustedRoots: false);
      configure(_IoContextSink(context));
      return context;
    }();
  }

  void dispose() {
    _disposed = true;
    _context = null;
    _key.fillRange(0, _key.length, 0);
  }

  @override
  String toString() => 'TlsContextPlan(REDACTED)';
}

abstract interface class TlsContextSink {
  void minimumTls13();
  void disableRenegotiation();
  void chain(Uint8List pem);
  void privateKey(Uint8List pem);
  void trustOnly(Uint8List pem);
  void clientAuthorities(Uint8List pem);
}

final class _IoContextSink implements TlsContextSink {
  _IoContextSink(this.context);
  final SecurityContext context;
  @override
  void minimumTls13() =>
      context.minimumTlsProtocolVersion = TlsProtocolVersion.tls1_3;
  @override
  void disableRenegotiation() => context.allowLegacyUnsafeRenegotiation = false;
  @override
  void chain(Uint8List pem) => context.useCertificateChainBytes(pem);
  @override
  void privateKey(Uint8List pem) => context.usePrivateKeyBytes(pem);
  @override
  void trustOnly(Uint8List pem) => context.setTrustedCertificatesBytes(pem);
  @override
  void clientAuthorities(Uint8List pem) =>
      context.setClientAuthoritiesBytes(pem);
}

Uint8List _pem(String label, Uint8List der) {
  final encoded = base64.encode(der);
  return Uint8List.fromList(ascii.encode('-----BEGIN $label-----\n${[
    for (var offset = 0; offset < encoded.length; offset += 64)
      encoded.substring(
          offset, offset + 64 < encoded.length ? offset + 64 : encoded.length)
  ].join('\n')}\n-----END $label-----\n'));
}

/// Existing acquired Owner/Runtime Lock remains caller-owned through full drain.
/// No owner acquisition, credential initialization or silent repair occurs here.
final class P26TlsStartup implements TlsStartup {
  P26TlsStartup(
      {required ExternalProtectedObjects owner,
      required WindowsCredentialInitialization credentials,
      required this.publisher,
      required Uint8List runtimeInstanceId,
      required this.generation,
      required this.signDigest,
      required this.verifyDigest,
      required this.utcNow,
      required bool Function() compositionIsCurrent})
      : _owner = owner,
        _credentials = credentials,
        _current = compositionIsCurrent,
        runtimeInstanceId =
            Uint8List.fromList(runtimeInstanceId).asUnmodifiableView() {
    if (!credentials.usesOwner(owner) ||
        !publisher.usesOwner(owner) ||
        runtimeInstanceId.length != 16) {
      _tlsReject();
    }
  }
  final ExternalProtectedObjects _owner;
  final WindowsCredentialInitialization _credentials;
  final WindowsDiscoveryPublisher publisher;
  final Uint8List runtimeInstanceId;
  final BigInt generation;
  final CredentialDigestSigner signDigest;
  final CredentialDigestVerifier verifyDigest;
  final DateTime Function() utcNow;
  final bool Function() _current;
  bool _invalid = false, _prepared = false, _published = false;
  BigInt? _epoch;
  String? _installationId;
  TlsContextPlan? _plan;
  @override
  bool get isCurrent => !_invalid && _current() && _owner.isUsable;
  @override
  Future<TlsContextPlan> prepare() async {
    if (!isCurrent || _prepared) _tlsReject();
    _prepared = true;
    _owner.ensureOpen();
    final public = _credentials.validatedPublicMaterial();
    _epoch = public.publicationEpoch;
    _installationId = public.installationId;
    final server =
        WindowsCredentialObjectStore(_owner).read(2) as ExternalServerKeyChain?;
    if (server == null) _tlsReject();
    try {
      if (!bootstrapEqual(public.serverLeafDer!, server.serverLeafDer) ||
          !bootstrapEqual(
              public.issuerCertificateDer, server.issuerCertificateDer)) {
        _tlsReject();
      }
      return _plan = TlsContextPlan.validate(
          role: TlsPeerRole.server,
          leafDer: server.serverLeafDer,
          issuerDer: server.issuerCertificateDer,
          privateKeyDer: server.serverPkcs8Der,
          independentlyPinnedIssuer: public.issuerCertificateDer,
          signDigest: signDigest,
          verifyDigest: verifyDigest,
          utcNow: utcNow);
    } finally {
      server.serverPkcs8Der.fillRange(0, server.serverPkcs8Der.length, 0);
    }
  }

  @override
  Future<DiscoveryDescriptor> publish(int port) async {
    if (!isCurrent || !_prepared || _published || _plan?.isCurrent != true) {
      _tlsReject();
    }
    _published = true; // includes unknown/failure: no publication retry
    final result = publisher.publish(
        runtimeInstanceId: runtimeInstanceId,
        generation: generation,
        port: port,
        publishedAtUtcMs: BigInt.from(utcNow().millisecondsSinceEpoch));
    if (!isCurrent ||
        result.port != port ||
        result.generation != generation ||
        result.installationId != _installationId ||
        !bootstrapEqual(result.runtimeInstanceId, runtimeInstanceId) ||
        !bootstrapEqual(result.serverLeafDigest, _plan!.leafDigest) ||
        result.publicationEpoch <= _epoch!) {
      _tlsReject();
    }
    return result;
  }

  @override
  void invalidate() {
    _invalid = true;
    _plan?.dispose();
  }
}

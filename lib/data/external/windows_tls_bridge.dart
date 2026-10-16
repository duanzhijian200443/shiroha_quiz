part of 'windows_tls_transport.dart';

/// One explicit connection candidate, with no business routes. P26 performs
/// signature/installation/epoch validation BEFORE any connection operation.
final class WindowsTlsBridge {
  WindowsTlsBridge(
      {required this.io,
      required this.reader,
      required this.trusted,
      required ExternalProtectedObjects owner,
      required this.signDigest,
      required this.verifyDigest,
      required this.nativePolicy,
      required this.utcNow,
      required bool Function() compositionIsCurrent,
      TlsBudgets? limits})
      : _owner = owner,
        _current = compositionIsCurrent,
        budget = TlsResourceBudget(limits ?? TlsBudgets()) {
    if (!reader.usesOwner(owner)) _tlsReject();
  }
  final TlsBridgeIo io;
  final WindowsDiscoveryReader reader;
  final DiscoveryExpectations trusted;
  final ExternalProtectedObjects _owner;
  final CredentialDigestSigner signDigest;
  final CredentialDigestVerifier verifyDigest;
  final void Function(Uint8List, TlsPeerRole) nativePolicy;
  final DateTime Function() utcNow;
  final bool Function() _current;
  final TlsResourceBudget budget;
  TlsContextPlan? _plan;
  TlsChannel? _channel;
  bool _started = false, _closed = false, _invalid = false;
  Future<void>? _connecting, _closing, _disposing;
  TlsReservation? _socket, _handshake;
  bool get isLive {
    if (!_started) return false;
    if (_closed ||
        !_current() ||
        (_channel != null && !_channel!.isOpen) ||
        (_plan != null && !_plan!.isCurrent)) {
      _invalid = true;
    }
    return !_invalid && _channel != null;
  }

  Future<void> connect() {
    if (_started || _closed || !_current()) _tlsReject();
    _started = true;
    return _connecting = _connect();
  }

  Future<void> _connect() async {
    Timer? timer;
    ExternalBridgeClient? pin;
    try {
      _owner.ensureOpen();
      pin =
          WindowsCredentialObjectStore(_owner).read(4) as ExternalBridgeClient?;
      if (pin == null) _tlsReject();
      if (pin.pinnedInstallationId != trusted.installationId ||
          !bootstrapEqual(pin.issuerCertificateDer, trusted.trustedAnchorDer)) {
        _tlsReject();
      }
      _plan = TlsContextPlan.validate(
          role: TlsPeerRole.client,
          leafDer: pin.clientLeafDer,
          issuerDer: pin.issuerCertificateDer,
          privateKeyDer: pin.clientPkcs8Der,
          independentlyPinnedIssuer: trusted.trustedAnchorDer,
          signDigest: signDigest,
          verifyDigest: verifyDigest,
          utcNow: utcNow);
      final descriptor = reader.readAndAdvanceExistingPin(trusted);
      if (_closed || !_current()) _tlsReject();
      _socket = budget.reserve(TlsResource.socket);
      _handshake = budget.reserve(TlsResource.handshake);
      timer = Timer(const Duration(seconds: 5), () {
        _invalid = true;
        _closed = true;
        // A pending Future is still owned until it actually settles. The real
        // SDK connect also has a five-second cancellation deadline.
      });
      _channel = await io.connect(descriptor.port, _plan!);
      timer.cancel();
      if (_closed || !_current() || !_channel!.isOpen) _tlsReject();
      final der = _channel!.peerDer;
      nativePolicy(der, TlsPeerRole.server);
      _verifyPeer(
          der, _plan!.anchorDer, TlsPeerRole.server, utcNow(), verifyDigest);
      if (!bootstrapEqual(_tlsHash(der), descriptor.serverLeafDigest)) {
        _tlsReject();
      }
      if (_closed || _invalid || !_current() || !_plan!.isCurrent) _tlsReject();
      _handshake!.release();
      _handshake = null;
    } catch (_) {
      _invalid = true;
      _closed = true;
      await _dispose();
      rethrow;
    } finally {
      timer?.cancel();
      pin?.clientPkcs8Der.fillRange(0, pin.clientPkcs8Der.length, 0);
    }
  }

  Future<void> _dispose() => _disposing ??= () async {
        try {
          await _channel?.close();
          _handshake?.release();
          _socket?.release();
        } catch (_) {
          budget.invalidate();
          rethrow;
        } finally {
          _plan?.dispose();
        }
      }();

  Future<void> close() {
    _closed = true;
    _invalid = true;
    return _closing ??= () async {
      try {
        await _connecting;
      } catch (_) {/* original failure is preserved by connect */}
      await _dispose();
    }();
  }
}

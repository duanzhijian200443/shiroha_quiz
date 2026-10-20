part of 'windows_tls_transport.dart';

enum TlsBridgeFailure {
  unavailable,
  invalidRequest,
  protocol,
  responseLost,
  timedOut,
  cancelled
}

/// Transport evidence only. Unknown execution must be reconciled by the App's
/// original submission key; it never implies failure, rollback or safe retry.
final class TlsBridgeException implements Exception {
  const TlsBridgeException(this.failure,
      {required this.executionUnknown, this.protocolFailure});
  final TlsBridgeFailure failure;
  final bool executionUnknown;
  final IpcProtocolFailure? protocolFailure;
  @override
  String toString() => 'TlsBridgeException(${failure.name})';
}

/// One explicit connection candidate. P26 performs
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
      Duration Function()? monotonicNow,
      this.schedule = _tlsSchedule,
      TlsBudgets? limits})
      : _owner = owner,
        _current = compositionIsCurrent,
        _monotonicNow = monotonicNow,
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
  final Duration Function()? _monotonicNow;
  final _clock = Stopwatch()..start();
  final TlsSchedule schedule;
  Duration get _now => _monotonicNow?.call() ?? _clock.elapsed;
  final TlsResourceBudget budget;
  TlsContextPlan? _plan;
  TlsChannel? _channel;
  bool _started = false, _closed = false, _invalid = false, _verified = false;
  Future<void>? _connecting, _closing, _disposing;
  TlsReservation? _socket, _handshake;
  Future<void>? _requesting;
  Completer<UntrustedIpcEnvelope>? _reply;
  bool _sent = false;
  bool get isLive {
    if (!_started) return false;
    if (_closed ||
        !_current() ||
        (_channel != null && !_channel!.isOpen) ||
        (_plan != null && !_plan!.isCurrent)) {
      _invalid = true;
    }
    return !_invalid && _verified && _channel != null;
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
      _verified = true;
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

  /// Sends opaque P10 text once, only after existing server verification.
  /// P9 validates IDs/bytes; App P10/P8 alone own business schema and authority.
  /// Caller close cancels availability, while [close] waits actual I/O drain.
  Future<UntrustedIpcEnvelope> request(
      {required String requestId, required String payload}) {
    if (!isLive || _reply != null) {
      throw const TlsBridgeException(TlsBridgeFailure.unavailable,
          executionUnknown: false);
    }
    final reply = _reply = Completer<UntrustedIpcEnvelope>();
    _requesting = _exchange(requestId, payload);
    return reply.future;
  }

  void _fail(TlsBridgeFailure failure, [IpcProtocolFailure? protocol]) {
    _closed = true;
    _invalid = true;
    final reply = _reply;
    if (reply != null && !reply.isCompleted) {
      reply.completeError(TlsBridgeException(failure,
          executionUnknown: _sent, protocolFailure: protocol));
    }
    unawaited(_dispose().catchError((Object _) {}));
  }

  Future<void> _exchange(String requestId, String payload) async {
    final reservations = <TlsReservation>[];
    final decoder = IpcEnvelopeDecoder();
    UntrustedIpcEnvelope? response;
    void reserve(TlsResource resource, int count) =>
        reservations.add(budget.reserve(resource, count));
    final started = _now;
    final cancelTotal = schedule(
        const Duration(seconds: 10), () => _fail(TlsBridgeFailure.timedOut));
    var cancelProgress = schedule(
        const Duration(seconds: 2), () => _fail(TlsBridgeFailure.timedOut));
    void progressed() {
      if (_now - started >= const Duration(seconds: 10)) {
        _fail(TlsBridgeFailure.timedOut);
      }
      if (!isLive) _tlsReject();
      cancelProgress();
      cancelProgress = schedule(
          const Duration(seconds: 2), () => _fail(TlsBridgeFailure.timedOut));
    }

    Future<Uint8List?> read(int maximum) async {
      if (!isLive) _tlsReject();
      final bytes = await _channel!.read(maximum);
      // EOF is required after the sole response. A closed peer is expected
      // there, but local cancellation/currentness must still fail closed.
      if (_closed || _invalid || !_current() || !_plan!.isCurrent) _tlsReject();
      if (bytes != null) {
        if (bytes.isEmpty || bytes.length > maximum) _tlsReject();
        progressed();
      }
      return bytes;
    }

    try {
      reserve(TlsResource.pipeline, 1);
      reserve(TlsResource.protocolBytes, 65536 + 80); // input ring + scratch
      reserve(TlsResource.writeBytes, 65536); // retained TLS output ring
      // Reserve a conservative UTF-8 bound BEFORE P9 allocates its sole frame.
      final upper = payload.length * 3;
      reserve(
          TlsResource.protocolBytes,
          (upper < IpcEnvelopeLimits.requestBytes
                  ? upper
                  : IpcEnvelopeLimits.requestBytes) +
              80);
      reserve(TlsResource.stringBytes,
          2 * payload.length + 2 * IpcEnvelopeLimits.responseBytes);
      final Uint8List frame;
      try {
        frame = IpcEnvelopeCodec.encodeRequest(requestId, payload);
      } on IpcProtocolException catch (error) {
        _fail(TlsBridgeFailure.invalidRequest, error.failure);
        return;
      }
      for (var offset = 0; offset < frame.length;) {
        if (!isLive) _tlsReject();
        final end =
            offset + 65536 < frame.length ? offset + 65536 : frame.length;
        // A write can partially execute before failing. Never infer no effect.
        _sent = true;
        await _channel!.write(Uint8List.sublistView(frame, offset, end));
        offset = end;
        progressed();
      }
      final header = Uint8List(IpcEnvelopeLimits.headerBytes);
      var used = 0;
      while (used < header.length) {
        final bytes = await read(header.length - used);
        if (bytes == null) {
          decoder.finish();
          throw const IpcProtocolException(IpcProtocolFailure.truncated);
        }
        header.setRange(used, used + bytes.length, bytes);
        used += bytes.length;
        decoder.consume(bytes);
      }
      // Reject a request-kind frame before its potentially large body allocates.
      if (header[5] == IpcMessageKind.request.index + 1) {
        throw const IpcProtocolException(IpcProtocolFailure.unsupportedMessage);
      }
      var remaining = header[8] + ByteData.sublistView(header).getUint32(12);
      reserve(TlsResource.protocolBytes, remaining + 65536);
      while (response == null) {
        final bytes = await read(remaining < 65536 ? remaining : 65536);
        if (bytes == null) {
          decoder.finish();
          throw const IpcProtocolException(IpcProtocolFailure.truncated);
        }
        final step = decoder.consume(bytes);
        if (step.consumed != bytes.length) {
          throw const IpcProtocolException(IpcProtocolFailure.invalidFrame);
        }
        remaining -= step.consumed;
        response = step.envelope;
      }
      if (response.kind == IpcMessageKind.protocolError) {
        throw IpcProtocolException(IpcProtocolFailure.values
            .firstWhere((failure) => failure.name == response!.payload));
      }
      if (response.requestId != requestId) {
        throw const IpcProtocolException(IpcProtocolFailure.invalidId);
      }
      // The Host closes after one response. Require EOF so a duplicate frame
      // or trailing byte cannot be accepted as a successful single exchange.
      if (await read(1) != null) {
        throw const IpcProtocolException(IpcProtocolFailure.invalidFrame);
      }
      decoder.finish();
    } on IpcProtocolException catch (error) {
      _fail(TlsBridgeFailure.protocol, error.failure);
    } catch (_) {
      _fail(
          _sent ? TlsBridgeFailure.responseLost : TlsBridgeFailure.unavailable);
    } finally {
      cancelTotal();
      cancelProgress();
      decoder.close();
      _closed = true;
      _invalid = true;
      try {
        await _dispose();
      } catch (_) {
        _fail(TlsBridgeFailure.unavailable);
      }
      // Caller cancellation/deadline never releases a pending read/write or an
      // unacknowledged close. App work remains under the Host's own P8 barrier.
      if (budget.isUsable) {
        for (final token in reservations.reversed) {
          token.release();
        }
        _socket?.release();
      }
      if (!_reply!.isCompleted && response != null) _reply!.complete(response);
    }
  }

  Future<void> _dispose() => _disposing ??= () async {
        try {
          await _channel?.close();
          _handshake?.release();
          if (_requesting == null) _socket?.release();
        } catch (_) {
          budget.invalidate();
          rethrow;
        } finally {
          _plan?.dispose();
        }
      }();

  Future<void> close() {
    if (_reply != null && !_reply!.isCompleted) {
      _fail(TlsBridgeFailure.cancelled);
    }
    _closed = true;
    _invalid = true;
    return _closing ??= () async {
      try {
        await _connecting;
      } catch (_) {/* original failure is preserved by connect */}
      try {
        await _dispose();
      } finally {
        await _requesting;
      }
    }();
  }
}

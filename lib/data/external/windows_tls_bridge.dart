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
      this.enableStageApprovalWait = false,
      this.requirePublication,
      this.report,
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
  final bool enableStageApprovalWait;
  final void Function(BigInt)? requirePublication;
  final WindowsBusinessProcessReport? report;
  Duration get _now => _monotonicNow?.call() ?? _clock.elapsed;
  final TlsResourceBudget budget;
  TlsContextPlan? _plan;
  TlsChannel? _channel;
  bool _started = false, _closed = false, _invalid = false, _verified = false;
  Future<void>? _connecting, _closing, _disposing;
  TlsReservation? _socket, _handshake;
  Future<void>? _requesting;
  Future<void>? _proofWaiting;
  Completer<UntrustedIpcEnvelope>? _reply;
  bool _sent = false;
  bool get _connectionIsCurrent {
    if (!_started) return false;
    if (_closed || !_current() || (_plan != null && !_plan!.isCurrent)) {
      _invalid = true;
    }
    return !_invalid && _verified && _channel != null;
  }

  // Peer EOF stops new writes, but does not invalidate an already received
  // response. Its final EOF read still checks local lifetime and credentials.
  bool get isLive => _connectionIsCurrent && _channel!.isOpen;

  Future<void> connect() {
    if (_started || _closed || !_current()) _tlsReject();
    _started = true;
    return _connecting = _connect();
  }

  Future<void> _connect() async {
    Timer? timer;
    ExternalBridgeClient? pin;
    try {
      report?.enter(FirstPartyBusinessStage.credentialRead);
      _owner.ensureOpen();
      pin =
          WindowsCredentialObjectStore(_owner).read(4) as ExternalBridgeClient?;
      if (pin == null) _tlsReject();
      if (pin.pinnedInstallationId != trusted.installationId ||
          !bootstrapEqual(pin.issuerCertificateDer, trusted.trustedAnchorDer)) {
        _tlsReject();
      }
      report?.enter(FirstPartyBusinessStage.credentialValidation);
      _plan = TlsContextPlan.validate(
          role: TlsPeerRole.client,
          leafDer: pin.clientLeafDer,
          issuerDer: pin.issuerCertificateDer,
          privateKeyDer: pin.clientPkcs8Der,
          independentlyPinnedIssuer: trusted.trustedAnchorDer,
          signDigest: signDigest,
          verifyDigest: verifyDigest,
          utcNow: utcNow);
      report?.enter(FirstPartyBusinessStage.discovery);
      final descriptor = reader.readAndAdvanceExistingPin(trusted);
      requirePublication?.call(descriptor.publicationEpoch);
      if (_closed || !_current()) _tlsReject();
      _socket = budget.reserve(TlsResource.socket);
      _handshake = budget.reserve(TlsResource.handshake);
      timer = Timer(const Duration(seconds: 5), () {
        _invalid = true;
        _closed = true;
        // A pending Future is still owned until it actually settles. The real
        // SDK connect also has a five-second cancellation deadline.
      });
      report?.enter(FirstPartyBusinessStage.tlsConnect);
      _channel = await io.connect(descriptor.port, _plan!);
      timer.cancel();
      if (_closed || !_current() || !_channel!.isOpen) _tlsReject();
      final der = _channel!.peerDer;
      report?.enter(FirstPartyBusinessStage.peerPolicy);
      nativePolicy(der, TlsPeerRole.server);
      report?.enter(FirstPartyBusinessStage.peerCertificate);
      _verifyPeer(
          der, _plan!.anchorDer, TlsPeerRole.server, utcNow(), verifyDigest);
      report?.enter(FirstPartyBusinessStage.peerBinding);
      if (!bootstrapEqual(_tlsHash(der), descriptor.serverLeafDigest)) {
        _tlsReject();
      }
      if (_closed || _invalid || !_current() || !_plan!.isCurrent) _tlsReject();
      _handshake!.release();
      _handshake = null;
      _verified = true;
      report?.enter(FirstPartyBusinessStage.connected);
    } catch (error) {
      report?.primary(error);
      _invalid = true;
      _closed = true;
      try {
        await _dispose();
      } catch (cleanup) {
        report?.cleanup(cleanup);
        rethrow;
      }
      rethrow;
    } finally {
      timer?.cancel();
      pin?.clientPkcs8Der.fillRange(0, pin.clientPkcs8Der.length, 0);
    }
  }

  /// Sends opaque P10 text once, only after existing server verification.
  /// First-party proof channel only: no request bytes or business response.
  Future<void> waitForProofClosure() {
    if (!isLive || _reply != null || _proofWaiting != null) _tlsReject();
    return _proofWaiting = () async {
      final timer = Timer(ExternalCredentialBoundary.evidenceLifetime, () {
        unawaited(close().then((_) {}, onError: (Object _, StackTrace __) {}));
      });
      try {
        if (await _channel!.read(1) != null) _tlsReject();
      } finally {
        timer.cancel();
      }
    }();
  }

  /// Sends opaque P10 text once, only after existing server verification.
  /// P9 validates IDs/bytes; App P10/P8 alone own business schema and authority.
  /// Caller close cancels availability, while [close] waits actual I/O drain.
  Future<UntrustedIpcEnvelope> request(
          {required String requestId, required String payload}) =>
      _request(requestId, payload: payload);

  /// Explicit source-only profile. The bounded builder runs after reservations;
  /// it carries text only and supplies no App approval or business authority.
  Future<UntrustedIpcEnvelope> requestStageApproval(
      {required String requestId, required String Function() buildPayload}) {
    if (!enableStageApprovalWait) {
      throw const TlsBridgeException(TlsBridgeFailure.unavailable,
          executionUnknown: false);
    }
    return _request(requestId, stagePayload: buildPayload);
  }

  Future<UntrustedIpcEnvelope> _request(String requestId,
      {String? payload, String Function()? stagePayload}) {
    if (!isLive || _reply != null || _proofWaiting != null) {
      throw const TlsBridgeException(TlsBridgeFailure.unavailable,
          executionUnknown: false);
    }
    final reply = _reply = Completer<UntrustedIpcEnvelope>();
    _requesting = _exchange(requestId, payload, stagePayload);
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

  Future<void> _exchange(String requestId, String? payload,
      String Function()? stagePayload) async {
    final reservations = <TlsReservation>[];
    final decoder = IpcEnvelopeDecoder();
    UntrustedIpcEnvelope? response;
    void reserve(TlsResource resource, int count) =>
        reservations.add(budget.reserve(resource, count));
    final started = _now;
    final stageWait = stagePayload != null;
    final total = stageWait
        ? FirstPartyStageLimits.bridgeExchange
        : const Duration(seconds: 10);
    final cancelTotal = schedule(total, () => _fail(TlsBridgeFailure.timedOut));
    final cancelUpload = stageWait
        ? schedule(
            const Duration(seconds: 10), () => _fail(TlsBridgeFailure.timedOut))
        : null;
    void Function()? cancelResponse, cancelResponseFrame;
    var awaitingResponse = false, responseStarted = false;
    var cancelProgress = schedule(
        const Duration(seconds: 2), () => _fail(TlsBridgeFailure.timedOut));
    void progressed({bool receiving = false}) {
      if (_now - started >= total) {
        _fail(TlsBridgeFailure.timedOut);
      }
      if (stageWait && receiving && awaitingResponse && !responseStarted) {
        responseStarted = true;
        cancelResponseFrame = schedule(const Duration(seconds: 10),
            () => _fail(TlsBridgeFailure.timedOut));
      }
      if (!(receiving ? _connectionIsCurrent : isLive)) _tlsReject();
      cancelProgress();
      cancelProgress = schedule(
          const Duration(seconds: 2), () => _fail(TlsBridgeFailure.timedOut));
    }

    Future<Uint8List?> read(int maximum) async {
      if (!_connectionIsCurrent) _tlsReject();
      final bytes = await _channel!.read(maximum);
      // EOF is required after the sole response. A closed peer is expected
      // there, but local cancellation/currentness must still fail closed.
      if (!_connectionIsCurrent) _tlsReject();
      if (bytes != null) {
        if (bytes.isEmpty || bytes.length > maximum) _tlsReject();
        progressed(receiving: true);
      }
      return bytes;
    }

    try {
      reserve(TlsResource.pipeline, 1);
      reserve(TlsResource.protocolBytes, 65536 + 80); // input ring + scratch
      reserve(TlsResource.writeBytes, 65536); // retained TLS output ring
      // Reserve a conservative UTF-8 bound BEFORE P9 allocates its sole frame.
      final upper =
          stageWait ? IpcEnvelopeLimits.requestBytes : payload!.length * 3;
      reserve(
          TlsResource.protocolBytes,
          (upper < IpcEnvelopeLimits.requestBytes
                  ? upper
                  : IpcEnvelopeLimits.requestBytes) +
              80);
      reserve(
          TlsResource.stringBytes,
          (stageWait
                  ? 2 * IpcEnvelopeLimits.requestBytes + 4 * 1024 * 1024
                  : 2 * payload!.length) +
              2 * IpcEnvelopeLimits.responseBytes);
      payload ??= stagePayload!();
      final Uint8List frame;
      try {
        frame = IpcEnvelopeCodec.encodeRequest(requestId, payload);
      } on IpcProtocolException catch (error) {
        _fail(TlsBridgeFailure.invalidRequest, error.failure);
        return;
      }
      for (var offset = 0; offset < frame.length;) {
        if (_now - started >= const Duration(seconds: 10)) {
          _fail(TlsBridgeFailure.timedOut);
        }
        if (!isLive) _tlsReject();
        final end =
            offset + 65536 < frame.length ? offset + 65536 : frame.length;
        // A write can partially execute before failing. Never infer no effect.
        _sent = true;
        await _channel!.write(Uint8List.sublistView(frame, offset, end));
        offset = end;
        progressed();
      }
      if (stageWait) {
        // No intermediate frame identifies the App's actual thinking interval.
        // This is an explicit bounded final-response window, not a renewed
        // ordinary no-progress deadline. Short caller cancellation still wins.
        awaitingResponse = true;
        cancelUpload?.call();
        cancelProgress();
        cancelResponse = schedule(FirstPartyStageLimits.bridgeResponse,
            () => _fail(TlsBridgeFailure.timedOut));
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
    } on FormatException {
      _fail(TlsBridgeFailure.invalidRequest);
    } catch (_) {
      _fail(
          _sent ? TlsBridgeFailure.responseLost : TlsBridgeFailure.unavailable);
    } finally {
      cancelTotal();
      cancelProgress();
      cancelResponse?.call();
      cancelResponseFrame?.call();
      cancelUpload?.call();
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
          if (_requesting == null && _proofWaiting == null) _socket?.release();
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
        await _proofWaiting;
        if (_proofWaiting != null && budget.isUsable) _socket?.release();
      }
    }();
  }
}

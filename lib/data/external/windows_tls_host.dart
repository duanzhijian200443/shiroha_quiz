part of 'windows_tls_transport.dart';

/// Coordination phases only. PairingState and Session authority remain P0/P15.
enum WindowsTlsHostPhase { inactive, preparing, ready, closing, closed }

/// Single inactive Host candidate. Startup does not return readiness until
/// protected P26 publication has acknowledged the SAME listener/epoch/runtime.
final class WindowsTlsHost {
  WindowsTlsHost(
      {required this.io,
      required this.startup,
      required this.verification,
      required this.host,
      this.context,
      this.binding,
      required this.port,
      required this.monotonicNow,
      TlsBudgets? limits,
      TlsSchedule? schedule})
      : schedule = schedule ?? _tlsSchedule,
        budget = TlsResourceBudget(limits ?? TlsBudgets()) {
    if (port < 1 || port > 65535) _tlsReject();
    if ((context == null) == (binding == null) ||
        (binding != null && !identical(binding!.host, host))) {
      _tlsReject();
    }
    if (startup is P26TlsStartup) {
      (startup as P26TlsStartup)._owner.claimRuntime();
    }
  }

  /// Transfers one already acquired App Owner/lock to this SAME Host lifecycle.
  /// Acquisition precedes all Store operations. No successor may be composed
  /// until its predecessor is fully closed and its OS lock can be reacquired.
  factory WindowsTlsHost.owned({
    required ExternalProtectedObjects owner,
    required WindowsAppPairing pairing,
    required WindowsCredentialAssociationStore associations,
    required ExternalCredentialBoundary boundary,
    required ExternalTrustCoordinator coordinator,
    required P26TlsStartup startup,
    required WindowsChannelVerification verification,
    required TlsListenerIo io,
    TlsTrustedContext? context,
    IpcTrustedContextBinding? binding,
    required int port,
    required Duration Function() monotonicNow,
    TlsBudgets? limits,
    TlsSchedule? schedule,
  }) {
    if (!identical(startup._owner, owner) ||
        !associations.usesOwner(owner) ||
        !identical(verification.associations, associations) ||
        !identical(verification._boundary, boundary) ||
        !boundary.usesComposition(
            coordinator, associations, verification, startup.generation) ||
        !pairing.usesRuntime(owner, boundary, associations,
            verification.pairing, startup.runtimeInstanceId)) {
      _tlsReject();
    }
    owner.ensureOpen();
    final candidate = WindowsTlsHost(
        io: io,
        startup: startup,
        verification: verification,
        host: coordinator.host,
        context: context,
        binding: binding,
        port: port,
        monotonicNow: monotonicNow,
        limits: limits,
        schedule: schedule);
    candidate._owner = owner;
    candidate._pairing = pairing;
    candidate._associations = associations;
    candidate._boundary = boundary;
    return candidate;
  }
  final TlsListenerIo io;
  final TlsStartup startup;
  final WindowsChannelVerification verification;
  final LocalHostDispatchCore host;
  final TlsTrustedContext? context;
  final IpcTrustedContextBinding? binding;
  final int port;
  final Duration Function() monotonicNow;
  final TlsSchedule schedule;
  final TlsResourceBudget budget;
  bool _started = false, _ready = false, _stopped = false;
  TlsContextPlan? _plan;
  TlsCandidateListener? _listener;
  StreamSubscription<TlsRawPeer>? _accepts;
  final _connections = <_TlsConnection>{};
  Future<void>? _stopping;
  Future<void>? _listenerClosing;
  Completer<void>? _startDone;
  ExternalProtectedObjects? _owner;
  WindowsAppPairing? _pairing;
  WindowsCredentialAssociationStore? _associations;
  ExternalCredentialBoundary? _boundary;
  Future<void>? _controlWork;
  WindowsTlsHostPhase _phase = WindowsTlsHostPhase.inactive;
  WindowsTlsHostPhase get phase => _phase;
  bool get isReady =>
      _ready &&
      !_stopped &&
      startup.isCurrent &&
      budget.isUsable &&
      (_owner == null || host.isReady) &&
      (_boundary == null || _boundary!.isCurrent) &&
      _plan?.isCurrent == true;

  Future<void> get whenConnectionsSettled =>
      Future.wait(_connections.map((c) => c.done ?? Future<void>.value()))
          .then((_) {});

  Future<void> start() async {
    if (_started || _stopped) _tlsReject();
    _started = true;
    _phase = WindowsTlsHostPhase.preparing;
    _startDone = Completer<void>();
    try {
      if (!startup.isCurrent || !budget.isUsable) _tlsReject();
      // Application owns readiness and its ten-route registry. Transport only
      // observes the existing preparation; it cannot start Application services.
      if (_owner != null && !host.isReady) _tlsReject();
      if (_stopped || !startup.isCurrent) _tlsReject();
      _plan = await startup.prepare();
      if (_stopped || !startup.isCurrent || !_plan!.isCurrent) _tlsReject();
      _listener = await io.bind(port); // no TLS object or handshake yet
      if (_stopped ||
          !startup.isCurrent ||
          _listener!.address != '127.0.0.1' ||
          _listener!.port != port ||
          _listener!.shared) {
        _tlsReject();
      }
      await startup.publish(_listener!.port);
      if (_stopped || !startup.isCurrent || !_plan!.isCurrent) _tlsReject();
      _ready = true;
      _phase = WindowsTlsHostPhase.ready;
      _accepts = _listener!.peers.listen(_accept, onError: (Object _) {
        unawaited(shutdown());
      }, onDone: () {
        if (!_stopped) unawaited(shutdown());
      });
    } catch (_) {
      _ready = false;
      _stopped = true;
      _phase = WindowsTlsHostPhase.closing;
      startup.invalidate();
      try {
        await _closeListener();
      } catch (_) {
        budget.invalidate();
      }
      _plan?.dispose();
      // Run full owning drain after finally has signalled startup settlement.
      // Retain the failed Future for an explicit caller's shutdown observation.
      scheduleMicrotask(() {
        unawaited(shutdown().catchError((Object _) {}));
      });
      rethrow;
    } finally {
      _startDone!.complete();
    }
  }

  Future<void> _closeListener() => _listenerClosing ??= () async {
        await _listener?.close();
      }();

  void _accept(TlsRawPeer raw) {
    // The real RawServerSocket subscription is paused at capacity, preventing
    // unbounded accepted Futures. There is no handshake-completed admission.
    final connection = _TlsConnection(this, raw);
    _connections.add(connection);
    connection.done = connection.run().whenComplete(() {
      _connections.remove(connection);
      if (isReady &&
          _accepts?.isPaused == true &&
          budget.used(TlsResource.socket) < budget.limit(TlsResource.socket)) {
        _accepts?.resume();
      }
    });
    if (!isReady ||
        budget.used(TlsResource.socket) >= budget.limit(TlsResource.socket)) {
      _accepts?.pause();
    }
  }

  Future<void> shutdown() {
    if (_stopping != null) return _stopping!;
    _stopped = true;
    _ready = false;
    _phase = WindowsTlsHostPhase.closing;
    startup.invalidate();
    verification.close();
    final owning = host.shutdown();
    // These calls close evidence/admission synchronously, before any await.
    final pairing = _pairing?.close();
    final boundary = _boundary?.shutdown();
    return _stopping = () async {
      await _startDone?.future;
      var failed = false;
      Future<void> settle(Future<void> Function() work) async {
        try {
          await work();
        } catch (_) {
          failed = true;
          budget.invalidate();
        }
      }

      try {
        // Close the producer before draining the finite accepted set.
        await settle(() async {
          await _closeListener();
        });
        await settle(() async {
          await _accepts?.cancel();
        });
        final connections = _connections.toList();
        await Future.wait(connections.map((c) => settle(c.close)));
        await Future.wait(connections
            .map((c) => settle(() => c.done ?? Future<void>.value())));
        // Even a failed Socket/Listener close cannot shorten owning settlement.
        // Returning a fixed failure is distinct from claiming resources closed.
        await settle(() => owning);
        await settle(() async {
          await pairing;
        });
        await settle(() async {
          await boundary;
        });
        // P15 revoke drains BEFORE its Association CAS. Keep the Store and lock
        // alive through that CAS, even when shutdown races the management call.
        await settle(() async {
          await _controlWork;
        });
        await settle(() async {
          await _associations?.close();
        });
      } finally {
        _plan?.dispose();
      }
      if (failed || !budget.isUsable) {
        credentialFail(ExternalCredentialFailure.temporarilyUnavailable);
      }
      // Unknown socket/listener/Store settlement never releases runtime.lock.
      _owner?.close();
      _phase = WindowsTlsHostPhase.closed;
    }();
  }

  /// Explicit trusted local action, delegated unchanged to P15. No global
  /// revoke is ever triggered by closing an individual Socket.
  Future<void> revoke(
      ExternalProfileReference reference, int expectedRevision) {
    if (_boundary == null || _stopped || _controlWork != null) _tlsReject();
    final operation = _boundary!.revoke(reference, expectedRevision);
    _controlWork = operation;
    return () async {
      try {
        await operation;
      } finally {
        await shutdown();
      }
    }();
  }
}

final class _TlsConnection {
  _TlsConnection(this.owner, this.raw);
  final WindowsTlsHost owner;
  final TlsRawPeer raw;
  TlsChannel? channel;
  WindowsTlsSession? session;
  bool _closing = false;
  Future<void>? _closeFuture, done;
  bool get live =>
      !_closing &&
      owner.isReady &&
      channel?.isOpen == true &&
      session?.isLive == true;

  Future<void> close() => _closeFuture ??= () async {
        _closing = true;
        if (channel != null) owner.verification.invalidateChannel(channel!);
        try {
          await channel?.close();
          await raw.close();
        } catch (_) {
          owner.budget.invalidate();
          rethrow;
        }
      }();

  Future<void> run() async {
    TlsReservation? socket, handshake, tlsInput, tlsOutput;
    void Function()? cancelHandshake;
    try {
      if (!owner.isReady) _tlsReject();
      socket = owner.budget.reserve(TlsResource.socket);
      handshake = owner.budget.reserve(TlsResource.handshake);
      // Separate retained TLS ring reservations; NEVER mistaken for a measured
      // native/OS heap ceiling. They remain owned through acknowledged close.
      tlsInput = owner.budget.reserve(TlsResource.protocolBytes, 65536);
      tlsOutput = owner.budget.reserve(TlsResource.writeBytes, 65536);
      cancelHandshake = owner.schedule(const Duration(seconds: 5), () {
        unawaited(close().catchError((Object _) {}));
      });
      // Reservation exists BEFORE even creating the handshake Future.
      channel = await raw.upgrade(owner._plan!);
      cancelHandshake();
      if (_closing || !owner.isReady) {
        try {
          await channel!
              .close(); // late completion cannot revive this connection
        } catch (_) {
          owner.budget.invalidate();
          rethrow;
        }
        _tlsReject();
      }
      handshake.release();
      handshake = null;
      session = await owner.verification.authenticate(channel!, owner._plan!);
      if (!live) _tlsReject();
      final projection = OfflineIpcCommandProjection(
          host: owner.host, authentication: session!);
      // Frozen first-candidate ceiling: one request per connection; the single
      // frame settles before acknowledged close and reservation release.
      await _frame(projection);
    } catch (_) {
      // Fixed fail-closed boundary. No wire echo, retry, alternate parser or
      // inference of STAGE effect. Owning P8 settlement is awaited in _frame.
    } finally {
      cancelHandshake?.call();
      try {
        await close();
      } catch (_) {
        owner.budget.invalidate();
      }
      // Awaiting upgrade/owning work AND acknowledged close is required. Unknown
      // cleanup keeps the reservations owned and poisons further admission.
      if (owner.budget.isUsable) {
        tlsInput?.release();
        tlsOutput?.release();
        handshake?.release();
        socket?.release();
      }
    }
  }

  Future<void> _frame(OfflineIpcCommandProjection projection) async {
    final reservations = <TlsReservation>[];
    final decoder = IpcEnvelopeDecoder();
    final header = Uint8List(16);
    var headerUsed = 0;
    final started = owner.monotonicNow();
    var progress = started;
    var failed = false;
    void expire() {
      unawaited(close().catchError((Object _) {}));
    }

    final cancelTotal = owner.schedule(const Duration(seconds: 10), expire);
    var cancelProgress = owner.schedule(const Duration(seconds: 2), expire);
    void progressed() {
      progress = owner.monotonicNow();
      if (progress - started >= const Duration(seconds: 10)) {
        expire();
        return;
      }
      cancelProgress();
      cancelProgress = owner.schedule(const Duration(seconds: 2), expire);
    }

    void reserve(TlsResource kind, int count) =>
        reservations.add(owner.budget.reserve(kind, count));
    try {
      reserve(TlsResource.pipeline, 1);
      reserve(TlsResource.protocolBytes, 65536 + 80);
      // Authenticate before constructing/feeding a business decoder or reading
      // application bytes; every next command refreshes current P15/P8 state.
      if (await session!.authenticate() == null || !live) _tlsReject();
      while (headerUsed < 16) {
        final bytes = await channel!.read(16 - headerUsed);
        if (!live) _tlsReject();
        if (bytes == null) {
          decoder.finish();
          await close();
          return;
        }
        if (bytes.isEmpty || bytes.length > 16 - headerUsed) _tlsReject();
        header.setRange(headerUsed, headerUsed + bytes.length, bytes);
        headerUsed += bytes.length;
        decoder
            .consume(bytes); // P9 validates header before any body allocation
        progressed();
      }
      final payloadBytes = ByteData.sublistView(header).getUint32(12);
      // Include retained P9 body, P10 JSON containers (<=4096 lexical units),
      // response encoding/scratch/copies and one raw read. Global across peers.
      reserve(
          TlsResource.protocolBytes,
          payloadBytes +
              3 * (IpcEnvelopeLimits.responseBytes + 80) +
              512 * 1024);
      reserve(TlsResource.stringBytes, 4 * payloadBytes + 4 * 1024 * 1024);
      UntrustedIpcEnvelope? envelope;
      var remaining = header[8] + payloadBytes;
      while (envelope == null) {
        final bytes =
            await channel!.read(remaining < 65536 ? remaining : 65536);
        if (!live) _tlsReject();
        if (bytes == null) {
          decoder.finish();
          _tlsReject();
        }
        if (bytes.isEmpty || bytes.length > remaining || bytes.length > 65536) {
          _tlsReject();
        }
        final step = decoder.consume(bytes);
        remaining -= step.consumed;
        if (step.consumed != bytes.length) _tlsReject();
        envelope = step.envelope;
        progressed();
      }
      cancelTotal();
      cancelProgress();
      _boundJsonAllocation(envelope.payload);
      final OfflineIpcCommandResult result;
      if (owner.binding != null) {
        // v3 parsing and selector resolution happen only after the original
        // P15/P0 Session has been admitted by P8. No legacy Context fallback.
        result = await projection.invokeV3(envelope,
            binding: owner.binding!, responseAvailable: () => live);
      } else {
        final trustedContext = await owner.context!(session!.session);
        if (!live) _tlsReject();
        result = await projection.invoke(envelope,
            context: trustedContext, responseAvailable: () => live);
      }
      // The result may precede STAGE settlement. Never release the owning slot
      // until P8/P7/Registry/Stage report true settlement, even after close.
      await projection.whenSettled;
      if (!live || result.frame == null) {
        await close();
        return;
      }
      reserve(TlsResource.writeBytes, result.frame!.length);
      await channel!.write(result.frame!);
      if (!live) _tlsReject();
    } catch (_) {
      failed = true;
      rethrow;
    } finally {
      cancelTotal();
      cancelProgress();
      decoder.close();
      await projection.whenSettled;
      if (failed) {
        try {
          await close();
        } catch (_) {
          owner.budget.invalidate();
        }
      }
      if (owner.budget.isUsable) {
        for (final token in reservations.reversed) {
          token.release();
        }
      }
    }
  }
}

/// Allocation admission only, not a JSON/schema parser. P10 remains the sole
/// strict business decoder. Bound containers, duplicate-key scanner scratch and
/// string escapes before allowing jsonDecode to create an object graph.
void _boundJsonAllocation(String source) {
  var quoted = false,
      escaped = false,
      units = 0,
      stringStart = 0,
      lastString = 0;
  for (var i = 0; i < source.length; i++) {
    final c = source.codeUnitAt(i);
    if (quoted) {
      if (escaped) {
        escaped = false;
        continue;
      }
      if (c == 92) {
        escaped = true;
        continue;
      }
      if (c == 34) {
        quoted = false;
        lastString = i - stringStart;
      }
    } else if (c == 34) {
      quoted = true;
      stringStart = i + 1;
      units++;
    } else if (c == 58) {
      if (lastString > 256) _tlsReject();
      units++;
    } else if (c == 123 || c == 125 || c == 91 || c == 93 || c == 44) {
      units++;
    }
    if (units > 4096) credentialFail(ExternalCredentialFailure.resourceLimit);
  }
}

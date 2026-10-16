part of 'windows_tls_transport.dart';

/// The only real server bind. Never invoked by construction or normal startup.
final class DartLoopbackTlsIo implements TlsListenerIo {
  const DartLoopbackTlsIo();
  @override
  Future<TlsCandidateListener> bind(int port) async {
    if (port < 1 || port > 65535) _tlsReject();
    final raw = await RawServerSocket.bind(InternetAddress.loopbackIPv4, port,
        shared: false, backlog: 8);
    if (raw.address.type != InternetAddressType.IPv4 ||
        raw.address.address != '127.0.0.1' ||
        raw.port != port) {
      await raw.close();
      _tlsReject();
    }
    return _IoListener(raw);
  }
}

final class _IoListener implements TlsCandidateListener {
  _IoListener(this.raw);
  final RawServerSocket raw;
  @override
  String get address => raw.address.address;
  @override
  int get port => raw.port;
  @override
  bool get shared => false;
  @override
  Stream<TlsRawPeer> get peers => raw.map((socket) => _IoRawPeer(socket));
  @override
  Future<void> close() async {
    await raw.close();
  }
}

final class _IoRawPeer implements TlsRawPeer {
  _IoRawPeer(this.raw) {
    raw.readEventsEnabled = false;
    raw.writeEventsEnabled = false;
  }
  final RawSocket raw;
  Future<void>? _closing;
  bool _used = false;
  @override
  Future<TlsChannel> upgrade(TlsContextPlan plan) async {
    if (_used || _closing != null || plan.role != TlsPeerRole.server) {
      _tlsReject();
    }
    _used = true;
    final context = plan.createSecurityContext();
    final secure = await RawSecureSocket.secureServer(raw, context,
        requestClientCertificate: true, requireClientCertificate: true);
    if (_closing != null) {
      await secure.close();
      _tlsReject();
    }
    return _IoChannel(secure);
  }

  @override
  Future<void> close() => _closing ??= () async {
        await raw.close();
      }();
}

/// At most one bounded read and one bounded response write. Raw reads prevent
/// a byte-stream consumer from accumulating unreserved plaintext chunks.
final class _IoChannel implements TlsChannel {
  _IoChannel(RawSecureSocket raw) : _socket = raw {
    raw.readEventsEnabled = false;
    raw.writeEventsEnabled = false;
    _subscription = raw.listen((event) {
      if (event == RawSocketEvent.read) {
        raw.readEventsEnabled = false;
        _reader?.complete();
        _reader = null;
      } else if (event == RawSocketEvent.write) {
        raw.writeEventsEnabled = false;
        _writer?.complete();
        _writer = null;
      } else {
        _end();
      }
    }, onError: (Object _) => _end(), onDone: _end);
  }
  RawSecureSocket? _socket;
  RawSecureSocket get raw =>
      _socket ??
      (throw const ExternalCredentialException(
          ExternalCredentialFailure.verificationRejected));
  StreamSubscription<RawSocketEvent>? _subscription;
  Completer<void>? _reader, _writer;
  bool _open = true, _reading = false, _writing = false;
  Future<void>? _closing;
  @override
  bool get isOpen => _open;
  @override
  Uint8List get peerDer {
    final der = raw.peerCertificate?.der;
    if (der == null || der.isEmpty || der.length > 16384) _tlsReject();
    return Uint8List.fromList(der);
  }

  void _end() {
    _open = false;
    _reader?.complete();
    _reader = null;
    _writer?.complete();
    _writer = null;
  }

  @override
  Future<Uint8List?> read(int maximum) async {
    if (_reading || maximum < 1 || maximum > 65536) _tlsReject();
    _reading = true;
    try {
      while (_open) {
        final bytes = raw.read(maximum);
        if (bytes != null) return bytes;
        final waiter = _reader = Completer<void>();
        raw.readEventsEnabled = true;
        await waiter.future;
      }
      return null;
    } finally {
      _reading = false;
    }
  }

  @override
  Future<void> write(Uint8List response) async {
    if (_writing ||
        !_open ||
        response.length > IpcEnvelopeLimits.responseBytes + 80) {
      _tlsReject();
    }
    _writing = true;
    try {
      var offset = 0;
      while (offset < response.length) {
        if (!_open) _tlsReject();
        offset += raw.write(response, offset, response.length - offset);
        if (offset < response.length) {
          final waiter = _writer = Completer<void>();
          raw.writeEventsEnabled = true;
          await waiter.future;
        }
      }
      // All bytes were accepted by the bounded TLS output ring. Kernel/TLS
      // drain and cross-process close semantics still require Windows trials.
    } finally {
      _writing = false;
    }
  }

  @override
  Future<void> close() => _closing ??= () async {
        _end();
        final socket = _socket;
        if (socket != null) await socket.close();
        await _subscription?.cancel();
        // Clear only AFTER actual close/cancellation acknowledgement. A failure
        // retains ownership/references and poisons the Host budget instead.
        _subscription = null;
        _socket = null;
      }();
}

abstract interface class TlsBridgeIo {
  Future<TlsChannel> connect(int verifiedDescriptorPort, TlsContextPlan plan);
}

final class DartLoopbackBridgeIo implements TlsBridgeIo {
  const DartLoopbackBridgeIo();
  @override
  Future<TlsChannel> connect(
      int verifiedDescriptorPort, TlsContextPlan plan) async {
    if (verifiedDescriptorPort < 1 ||
        verifiedDescriptorPort > 65535 ||
        plan.role != TlsPeerRole.client) {
      _tlsReject();
    }
    final raw = await RawSecureSocket.connect(
        InternetAddress.loopbackIPv4, verifiedDescriptorPort,
        context: plan.createSecurityContext(),
        timeout: const Duration(seconds: 5));
    return _IoChannel(raw);
  }
}

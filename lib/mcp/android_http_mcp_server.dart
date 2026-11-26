/// Android Streamable HTTP MCP v1 READ-only server core (Profile 3, 9 tools).
///
/// Owns only HTTP transport framing, Bearer admission wiring, bounded in-memory
/// legacy MCP sessions (8 global / 4 per Profile / 15 min idle TTL), stateless
/// 2026-07-28 request dispatch, lock-screen continuation checks, and pre-send
/// OUTPUT_WITHHELD revalidation. All business authorization, scopes, egress,
/// and opaque references remain owned by Application (P0/P4/P5/P6/P7/P8).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:mcp_dart/mcp_dart.dart';

import '../application/external/external_trust_core.dart';
import '../data/external/external_certificate_der.dart';
import 'vnext_mcp_server.dart';

/// Current runtime access gate snapshot supplied by trusted composition.
final class AndroidHttpAdmissionStatus {
  const AndroidHttpAdmissionStatus({
    required this.allowsAuthenticatedUse,
    required this.acceptsNew,
  });

  static const denied = AndroidHttpAdmissionStatus(
    allowsAuthenticatedUse: false,
    acceptsNew: false,
  );

  /// Whether already-authenticated clients from the current unlocked Enable
  /// window may continue issuing READ calls (e.g., under `continueWhileLocked`).
  final bool allowsAuthenticatedUse;

  /// Whether new clients/sessions may authenticate (requires unlocked screen).
  final bool acceptsNew;
}

typedef AndroidHttpBearerAuthenticator = Future<ExternalSession?> Function(
  List<String>? authorizationHeaders,
);
typedef AndroidHttpAdmissionCheck = Future<AndroidHttpAdmissionStatus> Function(
  String profileId,
);
typedef AndroidHttpEventSink = void Function(
  String event,
  Map<String, Object?> fields,
);
typedef AndroidHttpPortFactory = VnextMcpPort Function(
  ExternalSession session,
  bool Function() isSessionCurrent,
);

/// Bounded in-memory legacy MCP HTTP session (2025-06-18 / 2025-11-25).
/// Ephemeral only: no persistence, no durable lease, no DIRTY state.
final class _LegacyHttpSession {
  _LegacyHttpSession({
    required this.profileId,
    required this.server,
    required this.transport,
    required this.lastActivity,
  });

  final String profileId;
  final VnextMcpServer server;
  final StreamableHTTPServerTransport transport;
  DateTime lastActivity;
}

final class AndroidHttpMcpServer {
  AndroidHttpMcpServer({
    required this.listener,
    required this.bindAddress,
    required this.openPort,
    required this.invalidateSessionContexts,
    required this.drainReads,
    required this.deviceRef,
    required this.authenticateBearer,
    required this.checkAdmission,
    this.isTls = true,
    DateTime Function()? now,
    this.idleSessionTtl = defaultIdleSessionTtl,
    this.maxSessions = defaultMaxSessions,
    this.maxSessionsPerProfile = defaultMaxSessionsPerProfile,
    this.maxBodyBytes = defaultMaxBodyBytes,
    this.bodyReadTimeout = defaultBodyReadTimeout,
    this.responseTimeout = defaultResponseTimeout,
    this.beforeResponseRelease,
    this.onEvent,
    Random? random,
  })  : _now = now ?? (() => DateTime.now().toUtc()),
        _random = random ?? Random.secure(),
        _allowedHosts = {
          bindAddress,
          if (bindAddress == '127.0.0.1') 'localhost'
        } {
    if (!validVnextSource(VnextDataSource('android', deviceRef).toJson())) {
      throw ArgumentError('Invalid Android deviceRef');
    }
    if (maxSessions < 1 ||
        maxSessionsPerProfile < 1 ||
        maxSessionsPerProfile > maxSessions ||
        maxBodyBytes < 1024 ||
        idleSessionTtl <= Duration.zero) {
      throw ArgumentError('Invalid HTTP MCP server bounds');
    }
  }

  static const defaultMaxSessions = 8;
  static const defaultMaxSessionsPerProfile = 4;
  static const defaultIdleSessionTtl = Duration(minutes: 15);
  static const defaultMaxBodyBytes = 65536; // 64 KiB
  static const defaultBodyReadTimeout = Duration(seconds: 4);
  static const defaultResponseTimeout = Duration(seconds: 35);

  /// Binds an isolated TLS 1.3 HTTPS server over a strict private RFC 1918 IPv4
  /// address (or `127.0.0.1` only when [allowLoopbackForTest] is set).
  /// Never uses `SecurityContext.defaultContext` or wildcard binds.
  static Future<HttpServer> bindSecure({
    required String ipv4Address,
    required int port,
    required Uint8List certificateChainPemBytes,
    required Uint8List privateKeyPemOrPkcs8Bytes,
    bool allowLoopbackForTest = false,
  }) async {
    final isLoopback = allowLoopbackForTest && ipv4Address == '127.0.0.1';
    if (!isLoopback) {
      ExternalCertificateDer.parsePrivateIpv4(ipv4Address);
    }
    final context = SecurityContext(withTrustedRoots: false)
      ..minimumTlsProtocolVersion = TlsProtocolVersion.tls1_3
      ..allowLegacyUnsafeRenegotiation = false
      ..useCertificateChainBytes(certificateChainPemBytes)
      ..usePrivateKeyBytes(privateKeyPemOrPkcs8Bytes);
    return HttpServer.bindSecure(
      InternetAddress(ipv4Address),
      port,
      context,
      shared: false,
    );
  }

  final HttpServer listener;
  final String bindAddress;
  final bool isTls;
  final AndroidHttpPortFactory openPort;
  final void Function(ExternalSession session) invalidateSessionContexts;
  final Future<void> Function() drainReads;
  final String deviceRef;
  final AndroidHttpBearerAuthenticator authenticateBearer;
  final AndroidHttpAdmissionCheck checkAdmission;
  final DateTime Function() _now;
  final Duration idleSessionTtl;
  final int maxSessions;
  final int maxSessionsPerProfile;
  final int maxBodyBytes;
  final Duration bodyReadTimeout;
  final Duration responseTimeout;
  final Future<void> Function(String profileId, String tool)?
      beforeResponseRelease;
  final AndroidHttpEventSink? onEvent;
  final Random _random;
  final Set<String> _allowedHosts;

  final Map<String, _LegacyHttpSession> _sessions = {};
  final Map<String, VnextMcpPort> _ports = {};
  final Map<String, ExternalSession> _activeSessions = {};
  final Set<String> _unlockedAuthenticatedProfiles = {};
  final Set<Future<void>> _inFlight = {};

  StreamSubscription<HttpRequest>? _subscription;
  Timer? _sweepTimer;
  bool _started = false;
  bool _closed = false;
  Future<void>? _closing;

  int get port => listener.port;
  int get activeLegacySessionCount {
    sweepIdleSessions();
    return _sessions.length;
  }

  int activeLegacySessionsFor(String profileId) {
    sweepIdleSessions();
    return _sessions.values.where((s) => s.profileId == profileId).length;
  }

  bool get isClosed => _closed;

  void start() {
    if (_started || _closed) {
      throw StateError('android_http_server_unavailable');
    }
    _started = true;
    _subscription = listener.listen(
      (request) {
        late final Future<void> task;
        task = _handleRequest(request).whenComplete(() {
          _inFlight.remove(task);
        });
        _inFlight.add(task);
      },
      onError: (Object _) {},
      cancelOnError: false,
    );
    _sweepTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => sweepIdleSessions(),
    );
  }

  /// Removes expired legacy in-memory sessions without touching active
  /// Profile grants or stateless `contextRef`s.
  void sweepIdleSessions() {
    final cutoff = _now().subtract(idleSessionTtl);
    final expiredIds = <String>[];
    _sessions.forEach((id, session) {
      if (!session.lastActivity.isAfter(cutoff)) {
        expiredIds.add(id);
      }
    });
    for (final id in expiredIds) {
      final removed = _sessions.remove(id);
      if (removed != null) {
        _emit('SESSION_EXPIRED', {'profileId': removed.profileId});
        unawaited(removed.server.close().catchError((Object _) {}));
      }
    }
  }

  /// Drops ONLY the specified Profile's HTTP sessions, unlocked continuation
  /// mark, and READ `contextRef`s. Sibling Profiles continue uninterrupted.
  Future<void> revokeProfile(
    String profileId, {
    ExternalSession? session,
  }) async {
    _unlockedAuthenticatedProfiles.remove(profileId);
    _ports.remove(profileId);
    final trackedSession = _activeSessions.remove(profileId) ?? session;
    final matchingIds = _sessions.entries
        .where((e) => e.value.profileId == profileId)
        .map((e) => e.key)
        .toList();
    final removed = <_LegacyHttpSession>[];
    for (final id in matchingIds) {
      final entry = _sessions.remove(id);
      if (entry != null) removed.add(entry);
    }
    for (final entry in removed) {
      await entry.server.close().catchError((Object _) {});
    }
    if (trackedSession != null) {
      invalidateSessionContexts(trackedSession);
    }
  }

  /// Stops accepting requests, closes all ephemeral legacy HTTP sessions, and
  /// awaits in-flight request handlers + owning READ settlement. Never closes
  /// the shared host dispatch core or SQLite database.
  Future<void> close() {
    _closed = true;
    return _closing ??= () async {
      _sweepTimer?.cancel();
      _sweepTimer = null;
      _unlockedAuthenticatedProfiles.clear();
      _ports.clear();
      _activeSessions.clear();
      await _subscription?.cancel();
      _subscription = null;
      try {
        await listener.close(force: true);
      } catch (_) {
        // Best-effort listener close; still drain all sessions and reads.
      }
      final existing = _sessions.values.toList();
      _sessions.clear();
      for (final session in existing) {
        await session.server.close().catchError((Object _) {});
      }
      await Future.wait(_inFlight.toList());
      await drainReads();
    }();
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final response = request.response;
    var transient = false;
    _LegacyHttpSession? activeLegacy;
    VnextMcpServer? transientServer;
    String? assignedSessionId;
    try {
      if (_closed) {
        await _reject(response, HttpStatus.unauthorized);
        return;
      }
      if (request.uri.path != '/mcp') {
        await _reject(response, HttpStatus.notFound);
        return;
      }
      if (!_isOriginAllowed(request.headers['origin'])) {
        _emit('ORIGIN_REFUSED', {'http': HttpStatus.forbidden});
        await _reject(response, HttpStatus.forbidden);
        return;
      }
      if (request.method == 'GET') {
        response.headers.set(HttpHeaders.allowHeader, 'POST, DELETE');
        await _reject(response, HttpStatus.methodNotAllowed);
        return;
      }
      if (request.method != 'POST' && request.method != 'DELETE') {
        response.headers.set(HttpHeaders.allowHeader, 'POST, DELETE');
        await _reject(response, HttpStatus.methodNotAllowed);
        return;
      }

      final session = await authenticateBearer(
        request.headers[HttpHeaders.authorizationHeader],
      );
      if (session == null || session.failure != null) {
        _emit('AUTH_REFUSED', {'http': HttpStatus.unauthorized});
        await _reject(response, HttpStatus.unauthorized);
        return;
      }
      final profileId = session.principal.profileId;

      final admission = await checkAdmission(profileId);
      if (!admission.allowsAuthenticatedUse || _closed) {
        _emit('AUTH_REFUSED', {'profileId': profileId, 'http': 401});
        await _reject(response, HttpStatus.unauthorized);
        return;
      }
      if (admission.acceptsNew) {
        _unlockedAuthenticatedProfiles.add(profileId);
      } else if (!_unlockedAuthenticatedProfiles.contains(profileId)) {
        _emit('LOCKED_NEW_CLIENT_REFUSED', {
          'profileId': profileId,
          'http': HttpStatus.forbidden,
        });
        await _reject(response, HttpStatus.forbidden);
        return;
      }

      sweepIdleSessions();

      final suppliedSessionId = request.headers.value('mcp-session-id');
      final existing =
          suppliedSessionId == null ? null : _sessions[suppliedSessionId];
      if (suppliedSessionId != null) {
        if (existing == null) {
          _emit('SESSION_REFUSED', {
            'profileId': profileId,
            'http': HttpStatus.notFound,
          });
          await _reject(response, HttpStatus.notFound);
          return;
        }
        if (existing.profileId != profileId) {
          _emit('SESSION_REFUSED', {
            'profileId': profileId,
            'http': HttpStatus.forbidden,
          });
          await _reject(response, HttpStatus.forbidden);
          return;
        }
        existing.lastActivity = _now();
      }

      if (request.method == 'DELETE') {
        if (suppliedSessionId == null || existing == null) {
          await _reject(response, HttpStatus.badRequest);
          return;
        }
        activeLegacy = existing;
        assignedSessionId = suppliedSessionId;
        await existing.transport.handleRequest(request, null);
        await response.done.timeout(responseTimeout);
        return;
      }

      final declaredLength = request.contentLength;
      if (declaredLength > maxBodyBytes) {
        await _reject(response, HttpStatus.requestEntityTooLarge);
        return;
      }
      final bytes = <int>[];
      await for (final chunk in request.timeout(bodyReadTimeout)) {
        if (bytes.length + chunk.length > maxBodyBytes) {
          await _reject(response, HttpStatus.requestEntityTooLarge);
          return;
        }
        bytes.addAll(chunk);
      }
      final Object? decoded;
      try {
        decoded = jsonDecode(utf8.decode(bytes));
      } on FormatException {
        await _reject(response, HttpStatus.badRequest);
        return;
      }
      if (decoded is! Map<String, dynamic>) {
        await _reject(response, HttpStatus.badRequest);
        return;
      }

      // Recheck admission after reading the body.
      if (!await _isProfileAllowedForSession(profileId, session)) {
        _emit('AUTH_REFUSED', {'profileId': profileId, 'http': 401});
        await _reject(response, HttpStatus.unauthorized);
        return;
      }

      final method = decoded['method'];
      final isInitialize = method == 'initialize';
      final StreamableHTTPServerTransport transport;

      if (existing != null) {
        activeLegacy = existing;
        transport = existing.transport;
      } else if (isInitialize) {
        if (_sessions.length >= maxSessions ||
            _sessions.values.where((s) => s.profileId == profileId).length >=
                maxSessionsPerProfile) {
          await _reject(response, HttpStatus.tooManyRequests);
          return;
        }
        final created = await _createServerAndTransport(
          profileId: profileId,
          session: session,
          initializing: true,
        );
        activeLegacy = created.$1;
        transport = created.$2;
      } else {
        transient = true;
        final created = await _createServerAndTransport(
          profileId: profileId,
          session: session,
          initializing: false,
        );
        transientServer = created.$1.server;
        transport = created.$2;
      }

      await transport.handleRequest(request, decoded);
      await response.done.timeout(responseTimeout);
      if (activeLegacy != null) {
        activeLegacy.lastActivity = _now();
      }
    } on TimeoutException {
      await _tryReject(response, HttpStatus.requestTimeout);
    } on FormatException {
      await _tryReject(response, HttpStatus.badRequest);
    } on Object {
      if (!_closed) {
        _emit('REQUEST_FAILED', {'http': HttpStatus.internalServerError});
        await _tryReject(response, HttpStatus.internalServerError);
      }
    } finally {
      if (transient && transientServer != null) {
        await transientServer.close().catchError((Object _) {});
      } else if (request.method == 'DELETE' &&
          assignedSessionId != null &&
          activeLegacy != null) {
        _sessions.remove(assignedSessionId);
        await activeLegacy.server.close().catchError((Object _) {});
      } else if (activeLegacy != null &&
          activeLegacy.transport.sessionId == null) {
        await activeLegacy.server.close().catchError((Object _) {});
      }
    }
  }

  Future<(_LegacyHttpSession, StreamableHTTPServerTransport)>
      _createServerAndTransport({
    required String profileId,
    required ExternalSession session,
    required bool initializing,
  }) async {
    final portAdapter = _HttpReadMcpPort(
      owner: this,
      profileId: profileId,
      session: session,
    );
    final protocolServer = McpServer(
      const Implementation(name: 'shiroha', version: '0.1.0'),
      options: const McpServerOptions(
        protocol: McpProtocol.stable,
        instructions:
            'Read currently authorized Shiroha question banks, study summaries, '
            'and explicitly permitted files over Streamable HTTP (Profile 3 '
            'read-only subset).',
        capabilities: ServerCapabilities(tools: ServerCapabilitiesTools()),
      ),
    );
    final mcpServer = VnextMcpServer(
      portAdapter,
      protocolServer: protocolServer,
      profileVersion: 3,
      readOnlyToolsOnly: true,
    );
    late final _LegacyHttpSession entry;
    final transport = StreamableHTTPServerTransport(
      options: StreamableHTTPServerTransportOptions(
        sessionIdGenerator: initializing ? _mintSessionId : () => null,
        onsessioninitialized: (id) {
          if (!_closed) {
            _sessions[id] = entry;
          }
        },
        enableJsonResponse: true,
        allowedHosts: _allowedHosts,
      ),
    );
    entry = _LegacyHttpSession(
      profileId: profileId,
      server: mcpServer,
      transport: transport,
      lastActivity: _now(),
    );
    await protocolServer.connect(transport);
    return (entry, transport);
  }

  VnextMcpPort _portFor(
    String profileId,
    ExternalSession session,
  ) {
    final tracked = _activeSessions[profileId];
    final existing = _ports[profileId];
    if (existing != null && identical(tracked, session)) {
      return existing;
    }
    _activeSessions[profileId] = session;
    final created = openPort(
      session,
      () =>
          !_closed &&
          session.failure == null &&
          identical(_activeSessions[profileId], session),
    );
    _ports[profileId] = created;
    return created;
  }

  Future<bool> _isProfileAllowedForSession(
    String profileId,
    ExternalSession session,
  ) async {
    if (_closed || session.failure != null) return false;
    final status = await checkAdmission(profileId);
    if (!status.allowsAuthenticatedUse || _closed || session.failure != null) {
      return false;
    }
    if (status.acceptsNew) {
      _unlockedAuthenticatedProfiles.add(profileId);
      return true;
    }
    return _unlockedAuthenticatedProfiles.contains(profileId);
  }

  bool _isOriginAllowed(List<String>? origins) {
    if (origins == null || origins.isEmpty) return true;
    final scheme = isTls ? 'https' : 'http';
    final allowed = <String>{
      for (final h in _allowedHosts) '$scheme://$h:$port',
    };
    return origins.every(allowed.contains);
  }

  String _mintSessionId() {
    final bytes = List<int>.generate(24, (_) => _random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  void _emit(String event, Map<String, Object?> fields) {
    onEvent?.call(event, fields);
  }

  static Future<void> _reject(HttpResponse response, int status) async {
    response.statusCode = status;
    response.persistentConnection = false;
    if (status == HttpStatus.unauthorized) {
      response.headers.set('www-authenticate', 'Bearer realm="shiroha"');
    }
    await response.close();
  }

  static Future<void> _tryReject(HttpResponse response, int status) async {
    try {
      await _reject(response, status);
    } on Object {
      // Peer or listener may already have closed the response stream.
    }
  }
}

/// Per-request / per-session VnextMcpPort adapter that enforces Profile 3's
/// 9-tool read-only allowlist and pre-send `OUTPUT_WITHHELD` revalidation
/// without invalidating `contextRef`s on single HTTP request close.
final class _HttpReadMcpPort implements VnextMcpPort {
  _HttpReadMcpPort({
    required this.owner,
    required this.profileId,
    required this.session,
  });

  final AndroidHttpMcpServer owner;
  final String profileId;
  final ExternalSession session;

  @override
  Future<Map<String, Object?>> call(
    String tool,
    Map<String, dynamic> arguments, {
    required Stream<void> cancelled,
    required bool Function() available,
  }) async {
    final source = VnextDataSource('android', owner.deviceRef);
    Map<String, Object?> denied() =>
        vnextFailure('unavailable', profileVersion: 3, source: source);

    if (!VnextMcpServer.unifiedReadOnlyInputSchemas.containsKey(tool)) {
      return denied();
    }
    if (!available() ||
        !await owner._isProfileAllowedForSession(profileId, session)) {
      return denied();
    }
    final port = owner._portFor(profileId, session);
    final result = await port.call(
      tool,
      arguments,
      cancelled: cancelled,
      available: () => !owner._closed && session.failure == null && available(),
    );
    if (owner.beforeResponseRelease != null) {
      await owner.beforeResponseRelease!(profileId, tool);
    }
    final stillAllowed = available() &&
        !owner._closed &&
        session.failure == null &&
        await owner._isProfileAllowedForSession(profileId, session);
    if (!stillAllowed) {
      owner._emit('OUTPUT_WITHHELD', {
        'profileId': profileId,
        'tool': tool,
      });
      return denied();
    }
    return result;
  }

  @override
  Future<void> close() async {
    // Deliberately does NOT call `reads.invalidateConnectionContexts(session)`
    // or `host.shutdown()` so valid `contextRef`s survive across stateless HTTP
    // requests and legacy session refreshes within the same Enable window.
  }
}

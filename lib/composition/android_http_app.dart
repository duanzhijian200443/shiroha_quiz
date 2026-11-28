import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../application/backup/backup_restore_gate.dart';
import '../application/external/android_foreground_access.dart';
import '../application/external/android_http_access.dart';
import '../application/external/external_credential_association.dart';
import '../application/external/external_trust_core.dart';
import '../application/external/local_host_dispatch.dart';
import '../core/observability/app_logger.dart';
import '../data/external/android_association_store.dart';
import '../data/external/android_http_tls.dart';
import '../data/external/android_http_token_codec.dart';
import '../data/external/android_native_association_backend.dart';
import '../data/external/external_certificate_der.dart';
import '../mcp/android_http_mcp_server.dart';
import '../mcp/vnext_mcp_composition_root.dart';
import '../mcp/vnext_mcp_server.dart';
import 'mcp_vnext_app_integration.dart';

typedef AndroidHttpListenerBinder = Future<HttpServer> Function({
  required String ipv4Address,
  required int port,
  required Uint8List certificateChainPemBytes,
  required Uint8List privateKeyPemOrPkcs8Bytes,
});

/// The regular Android App owns one inactive READ composition. Opening a
/// window and issuing a credential are separate local actions.
final class AndroidHttpApp implements AndroidHttpAccess {
  AndroidHttpApp({
    required McpVnextAppIntegration Function() createIntegration,
    required bool Function() applicationCurrent,
    required String Function() mintId,
    AndroidHttpListenerBinder bindListener = AndroidHttpMcpServer.bindSecure,
  })  : _createIntegration = createIntegration,
        _applicationCurrent = applicationCurrent,
        _bindListener = bindListener,
        _mintId = mintId {
    _foreground = AndroidForegroundAccess(elapsed: () => _clock.elapsed);
    _tls = AndroidHttpTls(_native, now: _clock.now);
    _associations = AndroidAssociationStore.forHttp(_backend,
        nowUtcMs: () => _clock.now().millisecondsSinceEpoch);
    _events = _native.events.listen(_onEvent);
  }

  static const _port = 17443;
  static const _foregroundLimit = Duration(minutes: 30);
  final McpVnextAppIntegration Function() _createIntegration;
  final bool Function() _applicationCurrent;
  final AndroidHttpListenerBinder _bindListener;
  final String Function() _mintId;
  final _clock = _HttpClock();
  final _native = AndroidDeviceMethodChannel();
  late final _backend = AndroidNativeAssociationBackend(_native);
  late final AndroidAssociationStore _associations;
  late final AndroidForegroundAccess _foreground;
  late final AndroidHttpTls _tls;
  late final StreamSubscription<(String, Map<String, Object?>)> _events;
  final _changes = StreamController<void>.broadcast();

  McpVnextAppIntegration? _integration;
  AndroidHttpClientCredentials? _credentials;
  VnextMcpAppComposition? _binding;
  AndroidHttpMcpServer? _server;
  AndroidForegroundObservation? _observation;
  AndroidHttpRootCertificate? _root;
  String? _address;
  String? _deviceId;
  int _nativeElapsedMs = 0;
  Duration _observationReceived = Duration.zero;
  bool _available = false, _notificationsAllowed = false, _disposed = false;
  bool _enabling = false;
  AndroidAccessDuration? _duration;
  int _cancelEpoch = 0;
  Future<void>? _operation, _closing;
  Timer? _deadline;

  bool get _current =>
      !_disposed &&
      _applicationCurrent() &&
      !BackupRestoreMutationGate.instance.isMaintenance;

  @override
  Stream<void> get changes => _changes.stream;

  @override
  AndroidHttpAccessState get state {
    final server = _server;
    final foregroundPhase = _foreground.phase;
    final phase = _enabling &&
            (foregroundPhase == AndroidAccessPhase.off ||
                foregroundPhase == AndroidAccessPhase.ready)
        ? AndroidAccessPhase.preparing
        : foregroundPhase;
    final ready = _current &&
        phase == AndroidAccessPhase.ready &&
        _foreground.allowsAuthenticatedUse &&
        _credentials?.enableWindowOpen == true &&
        server != null &&
        !server.isClosed;
    return AndroidHttpAccessState(
      available: _available,
      privateWifi: _address != null,
      notificationsAllowed: _notificationsAllowed,
      phase: phase,
      endpoint: ready
          ? Uri(
              scheme: 'https',
              host: server.bindAddress,
              port: server.port,
              path: '/mcp')
          : null,
      caFingerprint: _root?.fingerprint,
      remaining: ready ? _foreground.boundedRemaining : null,
      duration: _foreground.phase == AndroidAccessPhase.off ? null : _duration,
      background: _foreground.allowBackgroundRead,
      continueWhileLocked: _foreground.continueWhileLocked,
    );
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  void _onEvent((String, Map<String, Object?>) event) {
    if (_disposed) return;
    final (name, value) = event;
    if (name == 'foreground') _observe(value);
    if (name == 'readServiceWithdrawn') unawaited(disable());
  }

  void _observe(Map<Object?, Object?> value) {
    final sequence = value['sequence'];
    final nativeTime = value['elapsedMs'];
    if (_disposed ||
        sequence is! int ||
        nativeTime is! int ||
        sequence <= (_observation?.sequence ?? -1)) {
      return;
    }
    final rawAddress = value['address'];
    final network = value['network'];
    _address = null;
    if (rawAddress is String && network is String) {
      try {
        ExternalCertificateDer.parsePrivateIpv4(rawAddress);
        _address = rawAddress;
      } on FormatException {
        // This observation cannot authorize a listener.
      }
    }
    _notificationsAllowed = value['notificationsAllowed'] == true;
    _nativeElapsedMs = nativeTime;
    _observationReceived = _clock.elapsed;
    final previous = _foreground.phase;
    final observation = _observation = AndroidForegroundObservation(
      sequence: sequence,
      resumed: value['resumed'] == true,
      focused: value['focused'] == true,
      interactive: value['interactive'] == true,
      unlocked: value['unlocked'] == true,
      visible: value['visible'] == true,
      network: _address == null ? null : network as String,
      backgroundRead: value['backgroundRead'] == true,
    );
    _foreground.observe(observation);
    if (_foreground.phase == AndroidAccessPhase.suspended ||
        (previous != AndroidAccessPhase.draining &&
            _foreground.phase == AndroidAccessPhase.draining)) {
      unawaited(disable());
    }
    _notify();
  }

  Future<void> _refreshStatus() async {
    try {
      final status = await _native.invoke('status');
      if (!_current) return;
      if (status is Map &&
          status['runtimeAvailable'] == true &&
          status['http'] == true &&
          status['observation'] is Map) {
        _available = true;
        _observe(status['observation'] as Map);
        return;
      }
    } on PlatformException {
      // A lost native observation withdraws the current window.
    } on MissingPluginException {
      // This Android installation has no admitted HTTP channel.
    }
    _available = false;
    _address = null;
    unawaited(disable());
  }

  @override
  Future<void> inspect() async {
    await _refreshStatus();
    if (_current && _available && _root == null) {
      _root = await _tls.readRoot();
    }
    _notify();
  }

  @override
  Future<void> observeFlutter(bool resumed) async {
    if (_disposed) return;
    try {
      await _native.invoke('flutterLifecycle', {'resumed': resumed});
    } on PlatformException {
      await disable();
    } on MissingPluginException {
      await disable();
    }
  }

  void _requireLocalForeground() {
    final observed = _observation;
    if (!_current ||
        !_available ||
        observed == null ||
        !observed.resumed ||
        !observed.focused ||
        !observed.interactive ||
        !observed.unlocked ||
        !observed.visible) {
      throw const AndroidHttpAccessException('foreground_required');
    }
  }

  Future<T> _local<T>(Future<T> Function() action,
      {void Function()? validatePending}) async {
    if (!_current || _operation != null) {
      throw const AndroidHttpAccessException('busy');
    }
    final done = Completer<void>();
    _operation = done.future;
    try {
      await _refreshStatus();
      validatePending?.call();
      _requireLocalForeground();
      return await action();
    } on AndroidHttpIssuanceRecoveryRequired catch (error) {
      throw AndroidHttpAccessException('credential_recovery',
          recoveryProfileId: error.profileId);
    } on ExternalCredentialException catch (error) {
      throw AndroidHttpAccessException(error.failure.name);
    } on PlatformException catch (error) {
      throw AndroidHttpAccessException(error.code);
    } finally {
      _operation = null;
      done.complete();
      _notify();
    }
  }

  Future<AndroidHttpClientCredentials> _ensureCredentials(
      {void Function()? validatePending}) async {
    final existing = _credentials;
    if (existing != null) return existing;
    Object? identity;
    try {
      identity = await _native.invoke('identity');
    } on PlatformException catch (error) {
      if (error.code != 'pairing_required') rethrow;
      validatePending?.call();
      identity = await _native.invoke('identity', {'initialize': true});
    }
    validatePending?.call();
    _requireLocalForeground();
    if (identity is! Map ||
        identity['installationId'] is! String ||
        identity['deviceId'] is! String) {
      throw const AndroidHttpAccessException('credential_store_unavailable');
    }
    final port = AndroidHttpCredentialPort();
    final trust = ExternalTrustCore(
      credentials: port,
      clock: _clock,
      mintProfileId: _mintId,
      maxEnableDuration: _foregroundLimit,
    );
    final integration = _integration = _createIntegration();
    try {
      await integration.attachTrusted(
        trust: trust,
        readiness: _HttpReadiness(() => _current),
        authenticationAttempt: () => null,
        onBound: (management, binding) {
          _binding = binding;
          _deviceId = (identity as Map)['deviceId'] as String;
          _credentials = AndroidHttpClientCredentials(
            associations: _associations,
            management: management,
            trust: trust,
            credentialPort: port,
            admission: binding.reads.admission,
            foreground: _foreground,
            installationId: identity['installationId'] as String,
            mintRequestId: _mintId,
            onRevokeFailureWithdrawEnable: disable,
            onProfileRevoked: (id, session) async {
              await _server?.revokeProfile(id, session: session);
            },
          );
        },
      );
      return _credentials!;
    } catch (_) {
      await integration.close();
      _integration = null;
      rethrow;
    }
  }

  @override
  Future<void> enable(AndroidAccessDuration duration,
      {required bool background, required bool continueWhileLocked}) async {
    if (!_current ||
        _operation != null ||
        _enabling ||
        _foreground.phase != AndroidAccessPhase.off) {
      throw const AndroidHttpAccessException('busy');
    }
    final requestedEpoch = _cancelEpoch;
    void validatePending() {
      if (!_current || requestedEpoch != _cancelEpoch) {
        throw const AndroidHttpAccessException('enable_cancelled');
      }
    }

    _enabling = true;
    _notify();
    try {
      await _local(() async {
        final address = _address;
        if (address == null) {
          throw const AndroidHttpAccessException('wifi_required');
        }
        if (background && !_notificationsAllowed) {
          throw const AndroidHttpAccessException(
              'notification_permission_required');
        }
        if (!background &&
            (continueWhileLocked ||
                duration.limit == null ||
                duration.limit! > _foregroundLimit)) {
          throw const AndroidHttpAccessException('invalid_duration');
        }
        _duration = duration;
        _HttpAccessWindow? window;
        try {
          final credentials =
              await _ensureCredentials(validatePending: validatePending);
          validatePending();
          if (_address != address) {
            throw const AndroidHttpAccessException('enable_cancelled');
          }
          await _foreground.enable(
            (generation) => window = _HttpAccessWindow(
                this, generation, address, background, continueWhileLocked),
            duration: duration.limit,
            allowBackgroundRead: background,
            continueWhileLocked: continueWhileLocked,
          );
          if (_foreground.phase != AndroidAccessPhase.ready) {
            throw window?.failure ??
                const AndroidHttpAccessException('enable_cancelled');
          }
          validatePending();
          final remaining = _foreground.boundedRemaining;
          if (remaining != null) {
            _deadline = Timer(remaining, () => unawaited(disable()));
          }
          final readyWindow = window!;
          readyWindow.stage = 'client_admission';
          final enabled = await credentials.enableActiveClients();
          validatePending();
          readyWindow.check();
          if (enabled.isEmpty) {
            throw const AndroidHttpAccessException('no_eligible_clients');
          }
          readyWindow.stage = 'listen';
          _server!.start();
        } catch (error) {
          AppLogger.warning('Android HTTP access could not start',
              module: 'MCP',
              data: {
                'stage': window?.stage ?? 'app_attachment',
                'failure': _setupFailure(error),
              });
          await disable();
          rethrow;
        }
      }, validatePending: validatePending);
    } finally {
      _enabling = false;
      _notify();
    }
  }

  @override
  Future<void> disable() {
    _cancelEpoch++;
    _deadline?.cancel();
    _deadline = null;
    final closing = _foreground.disable();
    _notify();
    return closing.whenComplete(_notify);
  }

  @override
  Future<void> cancelPending() => _enabling ? disable() : Future<void>.value();

  @override
  Future<void> requestNotifications() =>
      _local(() => _ack('httpNotificationSettings'));

  @override
  Future<void> copyIssuedToken(String token) =>
      _local(() => _ack('httpCopyToken', {'token': token}));

  @override
  Future<Uint8List> exportRootCertificate() => _local(() async {
        await _ensureCredentials();
        final root = _root = await _tls.ensureRoot();
        return root.pem;
      });

  @override
  Future<String> addClient(String displayName) => _local(() async {
        final credentials = await _ensureCredentials();
        return (await credentials.issueClient(displayName: displayName)).token;
      });

  @override
  Future<String> reissueClient(String profileId) => _local(() async {
        final credentials = await _ensureCredentials();
        return (await credentials.reissueClient(oldProfileId: profileId)).token;
      });

  @override
  Future<void> revokeClient(String profileId) => _local(() async {
        final credentials = await _ensureCredentials();
        await credentials.revokeClient(profileId);
      });

  Future<void> _ack(String method, [Map<String, Object?>? args]) async {
    if (await _native.invoke(method, args) != true) {
      throw const AndroidHttpAccessException('platform_unavailable');
    }
  }

  static String _setupFailure(Object error) => switch (error) {
        AndroidHttpAccessException(:final code) => code,
        PlatformException(:final code)
            when RegExp(r'^[a-z_]{1,48}$').hasMatch(code) =>
          code,
        SocketException(:final osError) => 'socket_${osError?.errorCode ?? 0}',
        TlsException(:final osError) => 'tls_${osError?.errorCode ?? 0}',
        FormatException() => 'invalid_certificate_material',
        UnsupportedError() => 'unsupported_operation',
        ArgumentError() => 'invalid_argument',
        StateError() => 'invalid_state',
        ExternalCoreException(:final failure) => failure.name,
        ExternalCredentialException(:final failure) => failure.name,
        _ => 'startup_failed',
      };

  Future<AndroidHttpAuthResult> _authenticate(
      List<String>? authorization) async {
    await _refreshStatus();
    if (!_current || !_available) return const AndroidHttpUnauthenticated();
    return _credentials!.authenticateRequest(authorization);
  }

  @override
  Future<void> close() => _closing ??= () async {
        _disposed = true;
        final closing = _foreground.dispose();
        _deadline?.cancel();
        await closing;
        await _operation;
        await _integration?.close();
        await _associations.close();
        _backend.invalidate();
        await _events.cancel();
        await _native.close();
        await _changes.close();
        if (_foreground.phase == AndroidAccessPhase.recovery) {
          throw const AndroidHttpAccessException('settlement_unknown');
        }
      }();
}

final class _HttpAccessWindow
    implements AndroidAccessPreparation, AndroidAccessResources {
  _HttpAccessWindow(this.owner, this.generation, this.address, this.background,
      this.continueWhileLocked) {
    result = _prepare();
    settled = result.then<void>((_) {}, onError: (Object error, StackTrace _) {
      failure = error;
      return close();
    });
  }

  final AndroidHttpApp owner;
  final int generation;
  final String address;
  final bool background, continueWhileLocked;
  bool _withdrawn = false, _serviceAttempted = false;
  HttpServer? _listener;
  AndroidHttpMcpServer? _server;
  Future<void>? _closing;
  Object? failure;
  String stage = 'service_start';

  @override
  late final Future<AndroidAccessResources> result;
  @override
  late final Future<void> settled;

  void check() {
    if (_withdrawn ||
        !owner._current ||
        owner._foreground.generation != generation ||
        owner._address != address) {
      throw const AndroidHttpAccessException('enable_cancelled');
    }
  }

  Future<AndroidAccessResources> _prepare() async {
    final binding = owner._binding!;
    final deviceId = owner._deviceId!;
    if (background) {
      _serviceAttempted = true;
      await owner._ack('readServiceStart');
      check();
    }
    stage = 'certificate';
    final tls = await owner._tls.prepare(address);
    try {
      check();
      owner._root = tls.root;
      stage = 'bind';
      _listener = await owner._bindListener(
        ipv4Address: address,
        port: AndroidHttpApp._port,
        certificateChainPemBytes: tls.chainPem,
        privateKeyPemOrPkcs8Bytes: tls.privateKey,
      );
    } finally {
      tls.privateKey.fillRange(0, tls.privateKey.length, 0);
    }
    check();
    stage = 'server_construction';
    final source = VnextDataSource('android', deviceId);
    _server = owner._server = AndroidHttpMcpServer(
      listener: _listener!,
      bindAddress: address,
      deviceRef: deviceId,
      foreground: owner._foreground,
      runtimeAdmission: binding.reads.admission,
      authenticateBearer: owner._authenticate,
      openPort: (session, current) => VnextMcpAppComposition(
        host: binding.host,
        reads: binding.reads,
        stages: binding.stages,
        authentication: VnextMcpSessionAuthentication(
            () async => owner._current && current() ? session : null),
        approvedTargets: const [],
        profileVersion: 3,
        source: source,
      ),
      invalidateSessionContexts: binding.reads.invalidateConnectionContexts,
      drainReads: () async {
        await binding.host.whenSettled;
        await binding.reads.whenIdle;
      },
      beforeResponseRelease: (_, __) => owner._refreshStatus(),
      onEvent: (event, _) {
        if (event == 'OUTPUT_WITHHELD') {
          AppLogger.info('Android HTTP READ output withheld',
              module: 'MCP', data: {'event': event});
        }
      },
    );
    if (background) {
      stage = 'service_activation';
      final remaining = owner._foreground.boundedRemaining;
      final nativeNow = owner._nativeElapsedMs +
          (owner._clock.elapsed - owner._observationReceived).inMilliseconds;
      await owner._ack('readServiceActivate', {
        if (remaining != null)
          'endsElapsedMs': nativeNow + remaining.inMilliseconds,
        'continueWhileLocked': continueWhileLocked,
      });
    }
    check();
    return this;
  }

  @override
  void cancel() => withdraw();

  @override
  void withdraw() {
    _withdrawn = true;
    owner._credentials?.disableAllActiveClients();
  }

  @override
  Future<void> close() => _closing ??= () async {
        try {
          final server = _server;
          if (server == null) {
            await _listener?.close(force: true);
          } else {
            await server.close();
          }
        } finally {
          if (identical(owner._server, _server)) owner._server = null;
          if (_serviceAttempted) await owner._ack('readServiceStop');
          owner._notify();
        }
      }();
}

final class _HttpClock implements ExternalClock {
  final _epoch = DateTime.now().toUtc();
  final _stopwatch = Stopwatch()..start();
  Duration get elapsed => _stopwatch.elapsed;
  @override
  DateTime now() => _epoch.add(elapsed);
}

final class _HttpReadiness implements LocalHostReadinessPort {
  const _HttpReadiness(this.current);
  final bool Function() current;
  @override
  bool get isCurrent => current();
  @override
  Future<void> ensureDatabaseReady() async => _check();
  @override
  Future<void> ensureRecoveryComplete() async => _check();
  @override
  Future<void> ensureModulesAndRoutesReady() async => _check();
  void _check() {
    if (!isCurrent) {
      throw const AndroidHttpAccessException('application_unavailable');
    }
  }
}

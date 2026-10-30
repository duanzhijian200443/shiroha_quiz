import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../application/external/first_party_external_access.dart';
import '../application/external/first_party_development_access.dart';
import '../application/external/external_device_connection.dart';
import '../data/external/windows_android_adapter_layout.dart';
import '../data/external/windows_bridge_process.dart';
import '../data/external/windows_local_relay.dart';
import '../data/external/windows_release_candidate.dart';
import '../data/external/windows_development_bootstrap.dart';
import '../mcp/vnext_app_owned_client.dart';
import '../mcp/vnext_mcp_server.dart';

/// Pure admission gate before original child creation. A missing/expired public
/// snapshot is a business refusal, never an attempted child or cleanup failure.
Future<Map<String, Object?>> dispatchWithAppOwnedBootstrap({
  required bool requireBootstrap,
  int profileVersion = 2,
  required WindowsDevelopmentBootstrap Function()? snapshot,
  required Future<Map<String, Object?>> Function(WindowsDevelopmentBootstrap?)
      dispatch,
}) async {
  WindowsDevelopmentBootstrap? packet;
  try {
    packet = snapshot?.call();
  } catch (_) {
    return vnextFailure('unavailable', profileVersion: profileVersion);
  }
  if (requireBootstrap && packet == null) {
    return vnextFailure('unavailable', profileVersion: profileVersion);
  }
  return dispatch(packet);
}

/// Normal App custody for the new local hop. It does not manufacture admission
/// for the adjacent Bridge: its existing formal entry remains fail-closed.
final class McpVnextAppOwnedRelay implements McpVnextWindowsProcessOwner {
  McpVnextAppOwnedRelay(
      {void Function(String, int)? onEvent,
      this.requireBusinessBootstrap = false,
      this.devices,
      Duration idleTimeout = const Duration(minutes: 10)})
      : _onEvent = onEvent,
        _idleTimeout = idleTimeout {
    if (idleTimeout <= Duration.zero ||
        idleTimeout > const Duration(minutes: 10)) {
      throw ArgumentError('Invalid relay idle deadline');
    }
  }
  final void Function(String, int)? _onEvent;
  final Duration _idleTimeout;
  final bool requireBusinessBootstrap;
  ({String stage, String code})? get androidLinkFailure =>
      _observedBusiness?.androidLinkFailure;
  final ExternalDeviceConnection? devices;
  ExternalDeviceLease? _deviceLease;
  Completer<void>? _connectionEnded;
  int _connectionId = 0;
  void _report(String event) {
    try {
      _onEvent?.call(event, _connectionId);
    } catch (_) {/* Observation only. */}
  }

  WindowsLocalRelay? _pipe;
  _OwnedBridge? _bridge;
  Future<void>? _serving, _closing;
  bool _closed = false, _failed = false, _nativeUnsettled = false;
  bool get available => !_closed && !_failed && _pipe != null;
  bool get launchCurrent =>
      !_closed && !_failed && _pipe?.appLaunchCurrent == true;
  bool get hasChild => _bridge != null || _pairing != null;
  bool get hasPairingChild => _pairing != null;
  Future<void> waitPairingWindowClosed() async => await _pairingSettlement;
  WindowsDevelopmentBootstrap Function()? businessBootstrap;
  Future<void> Function()? onDisconnected;
  WindowsBridgeProcess? _pairing;
  WindowsBridgeProcess? _observedPairing;
  FirstPartyChildObservation? get pairingObservation =>
      _observedPairing?.observation;
  WindowsBridgeProcess? _observedBusiness;
  FirstPartyChildObservation? get businessObservation =>
      _observedBusiness?.observation;
  StreamController<List<int>>? _pairingInput;
  Future<void>? _pairingSettlement;

  /// Holds the same child custody barrier as business; the UI never overlaps a
  /// raw Bridge Owner. Exit is observed, not interpreted as successful Pairing.
  Future<void> openPairing(WindowsDevelopmentBootstrap packet) async {
    if (!launchCurrent || hasChild) {
      throw StateError('Pairing window unavailable');
    }
    final input = _pairingInput = StreamController<List<int>>();
    final process = _observedPairing =
        _pairing = WindowsBridgeProcess.pairingUi(input: input.stream);
    try {
      await process.start();
      input.add(packet.encode(DateTime.now().toUtc()));
      _pairingSettlement = () async {
        await process.exited;
        await process.stopAndWait();
        await input.close();
        _pairing = null;
        _pairingInput = null;
      }();
      unawaited(
          _pairingSettlement!.then((_) {}, onError: (Object _, StackTrace __) {
        _failed = true;
        _observe(FirstPartyRelayPhase.unsettled);
      }));
    } catch (_) {
      await process.stopAndWait();
      await input.close();
      _pairing = null;
      _pairingInput = null;
      rethrow;
    }
  }

  FirstPartyRelayObservation _observation =
      const FirstPartyRelayObservation(FirstPartyRelayPhase.unavailable);
  FirstPartyRelayObservation get observation => _observation;

  void _observe(FirstPartyRelayPhase phase) {
    if (_observation.phase != FirstPartyRelayPhase.unsettled) {
      _observation = FirstPartyRelayObservation(phase);
    }
  }

  /// Registration errors disable only this optional connection surface.
  /// No scan, fallback path, credentials or external configuration is loaded.
  void start() {
    if (_serving != null || _closed) {
      throw StateError('Local relay unavailable');
    }
    try {
      _pipe = WindowsLocalRelay.openApp();
      _observe(FirstPartyRelayPhase.listening);
      _report('listening');
    } on LocalRelayException catch (failure) {
      _nativeUnsettled = failure.unsettled;
      _failed = true;
      _observe(failure.unsettled
          ? FirstPartyRelayPhase.unsettled
          : FirstPartyRelayPhase.unavailable);
      _report(failure.unsettled
          ? 'registrationUnsettled'
          : failure.independentAppRequired
              ? 'independentAppRequired'
              : 'registrationUnavailable');
      return;
    }
    _serving = _serve();
    unawaited(_serving!.then((_) {}, onError: (Object _, StackTrace __) {
      _failed = true;
      _observe(FirstPartyRelayPhase.unsettled);
    }));
  }

  Future<void> _serve() async {
    while (!_closed) {
      final pipe = _pipe!;
      Future<void>? lost;
      Future<void>? withdrawn;
      try {
        await pipe.accept();
        if (_closed) break;
        _connectionEnded = Completer<void>();
        _connectionId++;
        _observe(FirstPartyRelayPhase.connected);
        _report('peerAuthenticated');
        lost = pipe.disconnected.then((_) async {
          _observe(FirstPartyRelayPhase.settling);
          if (!_closed) withdrawn ??= onDisconnected?.call();
          await Future.wait([
            if (_bridge != null) _bridge!.close(),
            if (withdrawn != null) withdrawn!,
          ]);
        });
        unawaited(lost.then((_) {}, onError: (Object _, StackTrace __) {}));
        await _connection(pipe);
      } catch (_) {
        _report('relayInterrupted');
        // Protocol/SDK failure is not a custody failure. Never replay it.
        // Only successful original settlement below permits another peer.
      } finally {
        _observe(FirstPartyRelayPhase.settling);
        if (!_closed) withdrawn ??= onDisconnected?.call();
        try {
          await Future.wait([
            pipe.disconnect(),
            if (_bridge != null) _bridge!.close(),
            if (lost != null) lost,
            if (withdrawn != null) withdrawn!,
          ]);
          if (_bridge != null) _report('originalBridgeSettled');
          if (_deviceLease case final lease?) {
            await devices!.settled(lease, clean: true);
          }
          _deviceLease = null;
          _bridge = null;
          if (_connectionEnded?.isCompleted == false) {
            _connectionEnded!.complete();
          }
        } catch (_) {
          _report('originalBridgeCloseFailed');
          if (_deviceLease case final lease?) {
            try {
              await devices!.settled(lease, clean: false);
            } catch (_) {/* Retain the dirty marker. */}
          }
          if (_connectionEnded?.isCompleted == false) {
            _connectionEnded!.complete();
          }
          rethrow;
        }
      }
      if (_closed) break;
      // Accept a new explicit adapter connection only after original custody
      // settled. This does not retry any request or restore business authority.
      _observe(FirstPartyRelayPhase.listening);
      _report('listening');
    }
  }

  Future<void> _connection(WindowsLocalRelay pipe) async {
    var lastId = 0;
    int? connectionProfile;
    while (!_closed && pipe.isCurrent) {
      // Idle expiry closes this connection; no approval/Session is revived.
      final message = await pipe.receive(_idleTimeout);
      final id = message['id'];
      final tool = message['tool'];
      final arguments = message['arguments'];
      final profile = message['version'] == 1 ? 2 : 3;
      if ((profile == 2
              ? message.length != 4 || message['version'] != 1
              : message.length != 5 ||
                  message['version'] != 2 ||
                  message['profileVersion'] != 3) ||
          connectionProfile != null && connectionProfile != profile ||
          id is! int ||
          id != lastId + 1 ||
          id > 0x7fffffff ||
          tool is! String ||
          !VnextMcpServer.schemasFor(profile).containsKey(tool) ||
          arguments is! Map<String, dynamic>) {
        throw const LocalRelayException();
      }
      connectionProfile = profile;
      lastId = id;
      if (_closed || !pipe.isCurrent) throw const LocalRelayException();
      Map<String, Object?> result;
      if (profile == 3) {
        result =
            await _unified(tool, arguments, () => !_closed && pipe.isCurrent);
      } else if (_pairing != null) {
        result = vnextFailure('unavailable', profileVersion: profile);
      } else if (_bridge == null && !_OwnedBridge.packagePresent) {
        _report('bridgePackageUnavailable');
        result = vnextFailure('unavailable', profileVersion: profile);
      } else {
        result = await dispatchWithAppOwnedBootstrap(
            requireBootstrap: requireBusinessBootstrap,
            profileVersion: profile,
            snapshot: businessBootstrap,
            dispatch: (packet) async {
              final bridge = _bridge ??=
                  _createBridge(bootstrap: packet, profileVersion: profile);
              _observedBusiness = bridge.process;
              await bridge.start();
              if (_closed || !pipe.isCurrent) throw const LocalRelayException();
              return bridge.client.call(tool, arguments);
            });
      }
      if (_closed || !pipe.isCurrent) throw const LocalRelayException();
      await pipe.send(
          {'version': profile == 3 ? 2 : 1, 'id': id, 'result': result},
          const Duration(seconds: 5));
    }
  }

  Future<Map<String, Object?>> _unified(String tool,
      Map<String, dynamic> arguments, bool Function() current) async {
    final owner = devices;
    if (owner == null) return vnextFailure('unavailable', profileVersion: 3);
    try {
      if (_pairing != null) return vnextFailure('busy', profileVersion: 3);
      final lease = _deviceLease ??= await owner.begin();
      if (!current()) throw const LocalRelayException();
      final android = lease.target.kind == ExternalDeviceKind.android;
      if (android &&
          lease.target.reference != WindowsAndroidAdapterLayout.reference) {
        return vnextFailure('targetUnavailable', profileVersion: 3);
      }
      final layout = android
          ? WindowsAndroidAdapterLayout.resolve(Platform.resolvedExecutable)
          : null;
      if (android
          ? layout?.packagePresent != true
          : !_OwnedBridge.packagePresent) {
        return vnextFailure('unavailable', profileVersion: 3);
      }
      final result = await dispatchWithAppOwnedBootstrap(
          requireBootstrap: !android && requireBusinessBootstrap,
          profileVersion: 3,
          snapshot: android ? null : businessBootstrap,
          dispatch: (packet) async {
            final child = _bridge ??= _createBridge(
                bootstrap: packet, profileVersion: 3, android: android);
            _observedBusiness = child.process;
            await child.start();
            if (!current()) throw const LocalRelayException();
            return child.client.call(tool, arguments);
          });
      if (result['error'] == null) owner.connected(lease);
      return result;
    } on ExternalDeviceException catch (error) {
      return vnextFailure(error.failure.name, profileVersion: 3);
    }
  }

  _OwnedBridge _createBridge(
      {WindowsDevelopmentBootstrap? bootstrap,
      required int profileVersion,
      bool android = false}) {
    final connection = _connectionId;
    final child = _OwnedBridge(
        onEvent: _report,
        bootstrap: bootstrap,
        profileVersion: profileVersion,
        android: android);
    unawaited(child.process.exited.then((_) async {
      if (_closed ||
          child._closed ||
          connection != _connectionId ||
          !identical(_bridge, child)) {
        return;
      }
      _report('originalBridgeExited');
      try {
        // Wake the original connection owner even when Codex sends no more
        // requests. That owner alone joins work and decides clean vs unknown.
        await _pipe?.disconnect();
      } catch (_) {
        _failed = true;
        _observe(FirstPartyRelayPhase.unsettled);
      }
    }));
    return child;
  }

  /// Selection closes the authenticated pipe first, then waits for the same
  /// child/Session drain used by EOF. It cannot transfer a running connection.
  Future<void> endCurrentConnection() async {
    final ended = _connectionEnded;
    await _pipe?.disconnect();
    await ended?.future;
    if (_bridge != null || _deviceLease != null || _failed) {
      throw const ExternalDeviceException(ExternalDeviceFailure.needsAttention);
    }
  }

  Future<void> close() {
    _closed = true;
    return _closing ??= () async {
      _observe(FirstPartyRelayPhase.settling);
      try {
        await Future.wait([
          if (_pipe != null) _pipe!.close(),
          if (_bridge != null) _bridge!.close(),
          if (_pairing != null) _pairing!.stopAndWait(),
          if (_pairingInput != null) _pairingInput!.close(),
          if (_pairingSettlement != null) _pairingSettlement!,
          if (_serving != null) _serving!,
        ]);
        if (_nativeUnsettled || (_failed && _bridge != null)) {
          throw StateError('Local relay unsettled');
        }
        _observe(FirstPartyRelayPhase.closed);
      } catch (_) {
        _observe(FirstPartyRelayPhase.unsettled);
        rethrow;
      }
    }();
  }

  @override
  Future<void> stopAndWait() => close();
}

/// Stable internal protocol output stays alive after the outer pipe breaks.
/// This keeps the original child's sole stdout consumer draining through EOF.
final class _OwnedBridge {
  _OwnedBridge(
      {required this.onEvent,
      this.bootstrap,
      int profileVersion = 2,
      bool android = false}) {
    _toChild.onListen = () => _toListened = true;
    _fromChild.onListen = () => _fromListened = true;
    _output = IOSink(_ProtocolOutput(_fromChild));
    process = android
        ? WindowsBridgeProcess.androidStdio(
            input: _toChild.stream, output: _output)
        : WindowsBridgeProcess.stdio(
            input: _toChild.stream,
            output: _output,
            profileVersion: profileVersion);
    client = VnextAppOwnedClient(
        input: _fromChild.stream,
        output: _toChild.sink,
        profileVersion: profileVersion);
  }
  static bool get packagePresent {
    final root = p.dirname(Platform.resolvedExecutable);
    return WindowsExternalReleaseCandidate.bridgeFiles
        .every((name) => File(p.join(root, name)).existsSync());
  }

  final _toChild = StreamController<List<int>>(sync: true);
  final void Function(String) onEvent;
  final WindowsDevelopmentBootstrap? bootstrap;
  final _fromChild = StreamController<List<int>>(sync: true);
  late final IOSink _output;
  late final WindowsBridgeProcess process;
  late final VnextAppOwnedClient client;
  Future<void>? _starting, _closing;
  bool _closed = false, _toListened = false, _fromListened = false;

  Future<void> start() => _starting ??= () async {
        if (_closed) throw const LocalRelayException();
        await process.start();
        onEvent('originalBridgeStarted');
        if (_closed) throw const LocalRelayException();
        if (bootstrap != null) {
          _toChild.add(bootstrap!.encode(DateTime.now().toUtc()));
        }
        await client.connect();
      }();

  Future<void> close() {
    _closed = true;
    return _closing ??= () async {
      onEvent('originalBridgeCloseEntered');
      // Invoke the original closer immediately, including during launch. It
      // owns stdin cancellation, original exit and both original output drains.
      await process.stopAndWait();
      // An interrupted launch may never have installed either subscription.
      // Drain those never-consumed controllers before joining their close.
      if (!_fromListened) unawaited(_fromChild.stream.drain<void>());
      if (!_toListened) unawaited(_toChild.stream.drain<void>());
      await _output.close();
      await _fromChild.close();
      await client.close();
      await _toChild.close();
      try {
        await _starting;
      } catch (_) {/* Original cleanup above is authoritative. */}
    }();
  }
}

final class _ProtocolOutput implements StreamConsumer<List<int>> {
  _ProtocolOutput(this.target);
  final StreamController<List<int>> target;
  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      target.add(chunk);
    }
  }

  @override
  Future<void> close() async {}
}

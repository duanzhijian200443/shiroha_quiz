/// Explicit Bridge local UI host. No normal startup consumer.
library;

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

import '../application/external/first_party_external_credentials.dart';
import '../application/external/first_party_development_access.dart';
import '../data/external/windows_pairing.dart';
import '../ui/pages/bridge_host_surface.dart';

/// Already-acquired Bridge custody plus the ONE explicit resource closer.
///
/// Construction performs no OS operation. The caller supplies the original
/// P27 owner and remains responsible for closing the Store/Owner behind
/// [closeResources] AFTER the controller and its Enrollment are drained.
final class BridgeUiHostDependencies {
  const BridgeUiHostDependencies({
    required this.pairing,
    required this.instanceRoot,
    required this.closeResources,
    this.title = 'Shiroha Bridge',
    this.onObservation,
  });

  final WindowsBridgePairing pairing;

  /// Existing, caller-owned directory used only for the host instance lock.
  final String instanceRoot;
  final Future<void> Function() closeResources;
  final String title;

  /// Local composition callback only. It receives no import/comparison bytes;
  /// its exception can never change the original port result or close barrier.
  final void Function(FirstPartyPairingStage, Object?, bool)? onObservation;
}

/// One Bridge window over the original Enrollment controller.
///
/// A second host is refused in this process and across processes sharing the
/// same root (the OS file lock). The port is created exactly once, so a page
/// rebuild re-displays the live Enrollment instead of starting another one.
/// Close is latched: cancellation, disposal, window exit and explicit close all
/// await the SAME original P27 drain, and a failed drain keeps the lock so no
/// second host can adopt an unsettled owner.
final class BridgeUiHost {
  BridgeUiHost._(this._dependencies, this._lock, this._port) {
    _surfacePort = _HostedPairingPort(_port, close, _observe);
  }

  static const lockFileName = 'bridge-ui-host.lock';
  static BridgeUiHost? _active;
  static bool _opening = false;

  final BridgeUiHostDependencies _dependencies;
  final RandomAccessFile _lock;
  final WindowsBridgePublicPairing _port;
  late final _HostedPairingPort _surfacePort;
  Future<void>? _closing;
  bool _closed = false;

  /// Read-only view; the UI never receives host or resource authority.
  FirstPartyBridgePairingPort get port => _surfacePort;
  bool get isClosed => _closed;

  void _observe(FirstPartyPairingStage stage, Object? failure, bool cleanup) {
    try {
      _dependencies.onObservation?.call(stage, failure, cleanup);
    } catch (_) {/* Observation only. */}
  }

  static Future<BridgeUiHost> open(
      BridgeUiHostDependencies dependencies) async {
    if (_active != null || _opening) {
      throw StateError('Bridge UI host unavailable');
    }
    final root = dependencies.instanceRoot;
    final type = FileSystemEntity.typeSync(root, followLinks: false);
    if (type != FileSystemEntityType.directory) {
      throw StateError('Bridge UI host unavailable');
    }
    RandomAccessFile? lock;
    _opening = true;
    try {
      lock = await File(p.join(root, lockFileName)).open(mode: FileMode.append);
      // Non-blocking exclusive lock: a second live host fails instead of waiting.
      await lock.lock(FileLock.exclusive);
      final port = WindowsBridgePublicPairing(owner: dependencies.pairing);
      final host = BridgeUiHost._(dependencies, lock, port);
      _active = host;
      return host;
    } catch (_) {
      try {
        await lock?.close();
      } catch (_) {
        // No ownership was established.
      }
      throw StateError('Bridge UI host unavailable');
    } finally {
      _opening = false;
    }
  }

  /// The one real Bridge window. The same port and close are reused on rebuild.
  Widget build() => BridgeHostSurface(
      port: _surfacePort, close: close, title: _dependencies.title);

  Future<void> close() => _closing ??= _close();

  /// Settles pairing custody before a fresh business Owner can be acquired.
  /// This transfers no credential, Session, approval or live Owner. A cancelled
  /// enrollment is not a successful handoff; failed close remains latched.
  Future<void> closeForBusiness() {
    if (!_surfacePort.display().pinSaved) {
      throw StateError('Bridge UI handoff unavailable');
    }
    return close();
  }

  Future<void> _close() async {
    _closed = true;
    // A failed/unknown P27 drain must retain the caller's Store/Owner too.
    // Sequential awaits preserve the original failure in _closing, with no
    // resource callback, lock release or retry after a failed port close.
    _observe(FirstPartyPairingStage.closing, null, false);
    try {
      await _port.close();
      await _dependencies.closeResources();
      await _release();
      _observe(
          _surfacePort.pinObserved
              ? FirstPartyPairingStage.closed
              : FirstPartyPairingStage.closedWithoutPinObservation,
          null,
          false);
    } catch (error) {
      _observe(FirstPartyPairingStage.closing, error, true);
      rethrow;
    }
  }

  Future<void> _release() async {
    try {
      await _lock.unlock();
    } finally {
      await _lock.close();
      _active = null;
    }
  }
}

/// Keeps the existing controller as the only pairing authority while routing
/// every surface close (including cancellation) through the owning host drain.
final class _HostedPairingPort implements FirstPartyBridgePairingPort {
  _HostedPairingPort(this._delegate, this._closeHost, this._observe);

  final WindowsBridgePublicPairing _delegate;
  final Future<void> Function() _closeHost;
  final void Function(FirstPartyPairingStage, Object?, bool) _observe;
  bool pinObserved = false;
  T _sync<T>(FirstPartyPairingStage stage, T Function() action) {
    _observe(stage, null, false);
    try {
      return action();
    } catch (error) {
      _observe(stage, error, false);
      rethrow;
    }
  }

  Future<void> _async(
      FirstPartyPairingStage stage, Future<void> Function() action) async {
    _observe(stage, null, false);
    try {
      await action();
    } catch (error) {
      _observe(stage, error, false);
      rethrow;
    }
  }

  @override
  FirstPartyBridgePairingDisplay display() =>
      _sync(FirstPartyPairingStage.display, () {
        final value = _delegate.display();
        pinObserved = pinObserved || value.pinSaved;
        if (value.closed && !value.pinSaved) {
          _observe(
              FirstPartyPairingStage.closedWithoutPinObservation, null, false);
        }
        return value;
      });

  @override
  void beginEnrollment(
          {required String displayLabel, required String clientBuild}) =>
      _sync(
          FirstPartyPairingStage.beginEnrollment,
          () => _delegate.beginEnrollment(
              displayLabel: displayLabel, clientBuild: clientBuild));

  @override
  Future<void> importTrust(String publicData) => _async(
      FirstPartyPairingStage.importTrust,
      () => _delegate.importTrust(publicData));

  @override
  void confirmInitial(String comparedDigest) => _sync(
      FirstPartyPairingStage.confirmInitial,
      () => _delegate.confirmInitial(comparedDigest));

  @override
  Future<void> importCompletion(String publicData) => _async(
      FirstPartyPairingStage.importCompletion,
      () => _delegate.importCompletion(publicData));

  @override
  void confirmCompletion(String comparedDigest, int comparedRevision) => _sync(
      FirstPartyPairingStage.confirmCompletion,
      () => _delegate.confirmCompletion(comparedDigest, comparedRevision));

  @override
  Future<void> close() => _closeHost();
}

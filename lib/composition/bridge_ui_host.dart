/// Explicit Bridge local UI host. No normal startup consumer.
library;

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

import '../application/external/first_party_external_credentials.dart';
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
  });

  final WindowsBridgePairing pairing;

  /// Existing, caller-owned directory used only for the host instance lock.
  final String instanceRoot;
  final Future<void> Function() closeResources;
  final String title;
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
    _surfacePort = _HostedPairingPort(_port, close);
  }

  static const lockFileName = 'bridge-ui-host.lock';
  static BridgeUiHost? _active;
  static bool _opening = false;

  final BridgeUiHostDependencies _dependencies;
  final RandomAccessFile _lock;
  final WindowsBridgePublicPairing _port;
  late final FirstPartyBridgePairingPort _surfacePort;
  Future<void>? _closing;
  bool _closed = false;

  /// Read-only view; the UI never receives host or resource authority.
  FirstPartyBridgePairingPort get port => _surfacePort;
  bool get isClosed => _closed;

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
    if (!_port.display().pinSaved) {
      throw StateError('Bridge UI handoff unavailable');
    }
    return close();
  }

  Future<void> _close() async {
    _closed = true;
    // A failed/unknown P27 drain must retain the caller's Store/Owner too.
    // Sequential awaits preserve the original failure in _closing, with no
    // resource callback, lock release or retry after a failed port close.
    await _port.close();
    await _dependencies.closeResources();
    await _release();
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
  _HostedPairingPort(this._delegate, this._closeHost);

  final WindowsBridgePublicPairing _delegate;
  final Future<void> Function() _closeHost;

  @override
  FirstPartyBridgePairingDisplay display() => _delegate.display();

  @override
  void beginEnrollment(
          {required String displayLabel, required String clientBuild}) =>
      _delegate.beginEnrollment(
          displayLabel: displayLabel, clientBuild: clientBuild);

  @override
  Future<void> importTrust(String publicData) =>
      _delegate.importTrust(publicData);

  @override
  void confirmInitial(String comparedDigest) =>
      _delegate.confirmInitial(comparedDigest);

  @override
  Future<void> importCompletion(String publicData) =>
      _delegate.importCompletion(publicData);

  @override
  void confirmCompletion(String comparedDigest, int comparedRevision) =>
      _delegate.confirmCompletion(comparedDigest, comparedRevision);

  @override
  Future<void> close() => _closeHost();
}

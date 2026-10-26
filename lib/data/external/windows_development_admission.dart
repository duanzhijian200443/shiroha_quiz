import 'dart:async';
import 'dart:io';

import 'windows_development_bootstrap.dart';
import 'windows_local_relay.dart';

/// One child of the independently launched normal App. Native provenance and
/// the original finite preface are both mandatory; no caller can mint a guard.
final class WindowsDevelopmentAdmission {
  WindowsDevelopmentAdmission._(this._guard, this.input, this.packet)
      : _remaining = Duration(
            milliseconds: packet.expiresAtUtcMs -
                DateTime.now().toUtc().millisecondsSinceEpoch),
        _elapsed = Stopwatch()..start();

  static Future<WindowsDevelopmentAdmission> receive(
      {required bool pairingUi}) async {
    // Establish the original parent BEFORE reading bytes or touching credentials.
    final guard = WindowsAppParentGuard.open(pairingUi: pairingUi);
    final input =
        WindowsBootstrapInput(stdin, isCurrent: () => guard.isCurrent);
    try {
      final packet = await input.packet;
      packet.requireCurrent(DateTime.now().toUtc(),
          expectedPairingUi: pairingUi);
      final result = WindowsDevelopmentAdmission._(guard, input, packet);
      result.requireCurrent();
      return result;
    } catch (_) {
      await input.close();
      guard.close();
      rethrow;
    }
  }

  final WindowsAppParentGuard _guard;
  final WindowsBootstrapInput input;
  final WindowsDevelopmentBootstrap packet;
  final Duration _remaining;
  final Stopwatch _elapsed;
  bool _closed = false, _claimed = false;
  Future<void>? _closing;

  bool get isCurrent =>
      !_closed &&
      input.isOpen &&
      _guard.isCurrent &&
      _elapsed.elapsed < _remaining &&
      DateTime.now().toUtc().millisecondsSinceEpoch < packet.expiresAtUtcMs;
  void requireCurrent() {
    if (!isCurrent) throw StateError('Development admission unavailable');
  }

  void claimBusiness() {
    requireCurrent();
    if (_claimed || packet.pairingUi) {
      throw StateError('Development admission unavailable');
    }
    _claimed = true;
  }

  Future<void> close() {
    _closed = true;
    return _closing ??= () async {
      await input.close();
      _guard.close();
    }();
  }
}

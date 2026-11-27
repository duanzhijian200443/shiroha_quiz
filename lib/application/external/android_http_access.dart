import 'dart:typed_data';

import 'android_foreground_access.dart';

const androidHttpAdapter = 'android-http';
const androidHttpProtocol = 'streamable-http';

/// First-party setup and control. HTTP clients cannot invoke this surface.
abstract interface class AndroidHttpAccess implements AndroidAccessLifecycle {
  AndroidHttpAccessState get state;
  Stream<void> get changes;
  Future<void> inspect();
  Future<void> enable(AndroidAccessDuration duration,
      {required bool background, required bool continueWhileLocked});
  Future<void> disable();
  Future<void> cancelPending();
  Future<void> requestNotifications();
  Future<Uint8List> exportRootCertificate();
  Future<String> addClient(String displayName);
  Future<String> reissueClient(String profileId);
  Future<void> revokeClient(String profileId);
  Future<void> copyIssuedToken(String token);
}

final class AndroidHttpAccessState {
  const AndroidHttpAccessState({
    required this.available,
    required this.privateWifi,
    required this.notificationsAllowed,
    required this.phase,
    this.endpoint,
    this.caFingerprint,
    this.remaining,
    this.duration,
    this.background = false,
    this.continueWhileLocked = false,
  });

  final bool available, privateWifi, notificationsAllowed;
  final AndroidAccessPhase phase;
  final Uri? endpoint;
  final String? caFingerprint;
  final Duration? remaining;
  final AndroidAccessDuration? duration;
  final bool background, continueWhileLocked;
}

final class AndroidHttpAccessException implements Exception {
  const AndroidHttpAccessException(this.code, {this.recoveryProfileId});
  final String code;
  final String? recoveryProfileId;
}

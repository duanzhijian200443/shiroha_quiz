import 'dart:async';

import '../application/external/first_party_development_access.dart';

/// Observes the original deployment lifetime without owning its resources.
/// Connection loss is handled separately by the relay's original child drain.
Timer monitorWindowsDevelopmentLifetime({
  required bool Function() isCurrent,
  required bool Function() isExpired,
  required bool Function() launchIsCurrent,
  required Future<void> Function(FirstPartyDevelopmentStopCause) stop,
}) =>
    Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!isCurrent()) {
        final cause = isExpired()
            ? FirstPartyDevelopmentStopCause.expired
            : !launchIsCurrent()
                ? FirstPartyDevelopmentStopCause.relayLost
                : FirstPartyDevelopmentStopCause.appInvalidated;
        unawaited(
            stop(cause).then((_) {}, onError: (Object _, StackTrace __) {}));
      }
    });

import 'dart:async';
import 'dart:ui' show AppExitResponse;
import 'package:flutter/widgets.dart';
import '../../application/external/first_party_external_access.dart';

/// A cancelable exit waits for original custody and then its queued evidence.
/// Log completion never substitutes for a successful original close.
Future<AppExitResponse> settleExternalAppExit({
  required Future<void> Function() close,
  Future<void> Function()? flushLogs,
}) async {
  var response = AppExitResponse.exit;
  try {
    await close();
  } catch (_) {
    response = AppExitResponse.cancel;
  }
  // Preserve failure diagnostics too, without overriding a failed close.
  try {
    await flushLogs?.call();
  } catch (_) {
    response = AppExitResponse.cancel;
  }
  return response;
}

/// Owns desktop exit drain. Replacement invalidates the old control immediately.
final class FirstPartyExternalLifetime extends StatefulWidget {
  const FirstPartyExternalLifetime(
      {super.key,
      required this.access,
      required this.close,
      this.flushExitLogs,
      required this.child});
  final FirstPartyExternalAccess access;
  final Future<void> Function() close;
  final Future<void> Function()? flushExitLogs;
  final Widget child;
  @override
  State<FirstPartyExternalLifetime> createState() => _LifetimeState();
}

final class _LifetimeState extends State<FirstPartyExternalLifetime> {
  late final AppLifecycleListener _listener;
  @override
  void initState() {
    super.initState();
    _listener = AppLifecycleListener(
        onExitRequested: () => settleExternalAppExit(
            close: widget.close, flushLogs: widget.flushExitLogs),
        onDetach: () => _closeDetached(widget.close));
  }

  void _closeDetached(Future<void> Function() close) {
    unawaited(Future<void>.sync(close).catchError((Object _) {}));
  }

  @override
  void didUpdateWidget(FirstPartyExternalLifetime oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.access, widget.access)) {
      _closeDetached(oldWidget.close);
    }
  }

  @override
  void dispose() {
    _listener.dispose();
    _closeDetached(widget.close);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      FirstPartyExternalScope(access: widget.access, child: widget.child);
}

final class FirstPartyExternalScope extends InheritedWidget {
  const FirstPartyExternalScope(
      {super.key, required this.access, required super.child});
  final FirstPartyExternalAccess access;
  static FirstPartyExternalAccess? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<FirstPartyExternalScope>()
      ?.access;
  @override
  bool updateShouldNotify(FirstPartyExternalScope oldWidget) =>
      access != oldWidget.access;
}

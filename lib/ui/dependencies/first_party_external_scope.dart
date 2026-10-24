import 'dart:async';
import 'dart:ui' show AppExitResponse;
import 'package:flutter/widgets.dart';
import '../../application/external/first_party_external_access.dart';

/// Owns desktop exit drain. Replacement invalidates the old control immediately.
final class FirstPartyExternalLifetime extends StatefulWidget {
  const FirstPartyExternalLifetime(
      {super.key,
      required this.access,
      required this.close,
      required this.child});
  final FirstPartyExternalAccess access;
  final Future<void> Function() close;
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
        onExitRequested: () async {
          try {
            await widget.close();
            return AppExitResponse.exit;
          } catch (_) {
            return AppExitResponse.cancel;
          }
        },
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

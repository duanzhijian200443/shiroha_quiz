import 'dart:async';
import 'package:flutter/widgets.dart';
import '../../application/external/android_device_access.dart';

final class AndroidDeviceLifetime extends StatefulWidget {
  const AndroidDeviceLifetime(
      {super.key, required this.access, required this.child});
  final AndroidDeviceAccess access;
  final Widget child;
  @override
  State<AndroidDeviceLifetime> createState() => _AndroidLifetimeState();
}

final class _AndroidLifetimeState extends State<AndroidDeviceLifetime> {
  late final AppLifecycleListener _listener;
  void _observe(AppLifecycleState state) {
    unawaited(widget.access.observeFlutter(state == AppLifecycleState.resumed));
  }

  @override
  void initState() {
    super.initState();
    _listener = AppLifecycleListener(onStateChange: _observe);
    _observe(
        WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.detached);
  }

  @override
  void dispose() {
    _listener.dispose();
    unawaited(widget.access.close().catchError((Object _) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      AndroidDeviceScope(access: widget.access, child: widget.child);
}

final class AndroidDeviceScope extends InheritedWidget {
  const AndroidDeviceScope(
      {super.key, required this.access, required super.child});
  final AndroidDeviceAccess access;
  static AndroidDeviceAccess? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AndroidDeviceScope>()?.access;
  @override
  bool updateShouldNotify(AndroidDeviceScope oldWidget) =>
      !identical(access, oldWidget.access);
}

import 'dart:async';
import 'package:flutter/widgets.dart';
import '../../application/external/android_device_access.dart';
import '../../application/external/android_foreground_access.dart';
import '../../application/external/android_http_access.dart';

final class AndroidAccessLifetime extends StatefulWidget {
  const AndroidAccessLifetime(
      {super.key, required this.access, required this.child});
  final AndroidAccessLifecycle access;
  final Widget child;
  @override
  State<AndroidAccessLifetime> createState() => _AndroidLifetimeState();
}

final class _AndroidLifetimeState extends State<AndroidAccessLifetime> {
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
  Widget build(BuildContext context) => widget.child;
}

final class AndroidHttpAccessScope extends InheritedWidget {
  const AndroidHttpAccessScope(
      {super.key, required this.access, required super.child});
  final AndroidHttpAccess access;
  static AndroidHttpAccess? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<AndroidHttpAccessScope>()
      ?.access;
  @override
  bool updateShouldNotify(AndroidHttpAccessScope oldWidget) =>
      !identical(access, oldWidget.access);
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

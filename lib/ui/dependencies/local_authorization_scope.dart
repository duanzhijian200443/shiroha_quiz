import 'package:flutter/widgets.dart';
import '../../application/external/local_authorization_service.dart';

final class LocalAuthorizationScope extends InheritedWidget {
  const LocalAuthorizationScope(
      {super.key, required this.service, required super.child});
  final LocalAuthorizationService service;
  static LocalAuthorizationService? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<LocalAuthorizationScope>()
      ?.service;
  @override
  bool updateShouldNotify(LocalAuthorizationScope oldWidget) =>
      service != oldWidget.service;
}

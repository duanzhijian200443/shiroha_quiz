import 'package:flutter/widgets.dart';

import '../../application/content/content_asset_maintenance.dart';

final class ContentAssetMaintenanceScope extends InheritedWidget {
  const ContentAssetMaintenanceScope({
    super.key,
    required this.maintenance,
    required super.child,
  });

  final ContentAssetMaintenancePort maintenance;

  static ContentAssetMaintenancePort? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<ContentAssetMaintenanceScope>()
      ?.maintenance;

  @override
  bool updateShouldNotify(ContentAssetMaintenanceScope oldWidget) =>
      !identical(maintenance, oldWidget.maintenance);
}

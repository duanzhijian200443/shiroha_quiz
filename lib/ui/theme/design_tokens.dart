import 'package:flutter/material.dart';

/// Semantic layout tokens for the Shiroha Minimal settings hierarchy.
///
/// Values are consolidated from the existing production UI. They are not
/// sampled or inferred from design screenshots.
abstract final class DesignTokens {
  static const double pageHorizontalPadding = 16;
  static const double pageBottomPadding = 32;
  static const double sectionGap = 24;
  static const double cardInternalPadding = 16;
  static const double cardRadius = 18;
  static const double todayCardRadius = 14;
  static const double compactIconContainerRadius = 11;
  static const double prominentIconContainerRadius = 13;
  static const double navigationSelectedRadius = 12;
  static const double contentMaxWidth = 640;
  static const double workspaceMaxWidth = 1360;
  static const double workspaceDashboardMaxWidth = 1440;
  // Narrow workspace windows zoom out from the wide desktop composition.
  static const double workspaceReferenceWidth = 1700;
  static const double workspaceNavigationBreakpoint = 600;
  static const double expandedNavigationBreakpoint = 1200;
  static const double workspaceColumnsBreakpoint = 880;
  static const double compactNavigationWidth = 80;
  static const double expandedNavigationWidth = 248;

  static const Color _lightSurfaceShadowColor = Color(0xFF375078);

  static List<BoxShadow> surfaceShadow(Brightness brightness) {
    if (brightness == Brightness.dark) return const <BoxShadow>[];
    return <BoxShadow>[
      BoxShadow(
        color: _lightSurfaceShadowColor.withValues(alpha: 0.06),
        blurRadius: 18,
        offset: const Offset(0, 6),
      ),
    ];
  }
}

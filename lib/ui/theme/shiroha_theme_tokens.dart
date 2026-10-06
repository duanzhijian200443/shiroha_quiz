import 'package:flutter/material.dart';

enum ShirohaAppearance { light, dark, colorful }

/// Semantic colors shared by all appearances; layout stays in DesignTokens.
class ShirohaThemeTokens extends ThemeExtension<ShirohaThemeTokens> {
  const ShirohaThemeTokens({
    required this.appearance,
    required this.colors,
    required this.canvas,
    required this.success,
    required this.warning,
    required this.featureLibrary,
    required this.featureLibraryFill,
  });

  final ShirohaAppearance appearance;
  final ColorScheme colors;
  final Color canvas;
  final Color success;
  final Color warning;
  final Color featureLibrary;
  final Color featureLibraryFill;

  Color get brandAccent => featureLibrary;
  Color get brandFill => featureLibraryFill;
  Color get featureAi => colors.secondary;
  Color get featureAiFill => colors.secondaryContainer;
  Color get featureNeutral => colors.onSurfaceVariant;
  Color get featureNeutralFill => subtleFill;

  Color get assistantActionBackground => switch (appearance) {
        ShirohaAppearance.light => const Color(0xFF707482),
        ShirohaAppearance.dark => const Color(0xFF575B69),
        ShirohaAppearance.colorful => colors.primary,
      };
  Color get assistantOnAction => appearance == ShirohaAppearance.dark
      ? colors.onSurface
      : colors.onPrimary;
  Color get assistantCanvasStart => Color.lerp(surface, canvas, .35)!;
  Color get assistantCanvasEnd => Color.lerp(canvas, subtleFill, .5)!;
  Color get assistantDrawerScrim => switch (appearance) {
        ShirohaAppearance.light =>
          const Color(0xFFE0E3EE).withValues(alpha: .12),
        ShirohaAppearance.dark => Colors.black.withValues(alpha: .28),
        ShirohaAppearance.colorful =>
          colors.primaryContainer.withValues(alpha: .12),
      };

  Color get surface => colors.surface;
  Color get textPrimary => colors.onSurface;
  Color get textSecondary => colors.onSurfaceVariant;
  Color get border => colors.outline;
  Color get divider => colors.outlineVariant;
  Color get subtleFill => colors.surfaceContainerHighest;
  Color get icon => appearance == ShirohaAppearance.colorful
      ? colors.primary
      : colors.onSurface;
  Color get iconBackground => colors.primaryContainer;
  Color get primaryAction => colors.primary;
  Color get onPrimaryAction => colors.onPrimary;
  Color get secondaryAction => colors.secondary;
  Color get selectedFill => colors.primaryContainer;
  Color get selectedForeground => colors.onPrimaryContainer;
  Color get disabledForeground => colors.onSurface.withValues(alpha: .38);
  Color get disabledFill => colors.onSurface.withValues(alpha: .12);
  Color get error => colors.error;
  Color get correct => success;
  Color get incorrect => error;

  @override
  ShirohaThemeTokens copyWith({
    ShirohaAppearance? appearance,
    ColorScheme? colors,
    Color? canvas,
    Color? success,
    Color? warning,
    Color? featureLibrary,
    Color? featureLibraryFill,
  }) =>
      ShirohaThemeTokens(
        appearance: appearance ?? this.appearance,
        colors: colors ?? this.colors,
        canvas: canvas ?? this.canvas,
        success: success ?? this.success,
        warning: warning ?? this.warning,
        featureLibrary: featureLibrary ?? this.featureLibrary,
        featureLibraryFill: featureLibraryFill ?? this.featureLibraryFill,
      );

  @override
  ShirohaThemeTokens lerp(ShirohaThemeTokens? other, double t) {
    if (other == null) return this;
    return ShirohaThemeTokens(
      appearance: t < .5 ? appearance : other.appearance,
      colors: ColorScheme.lerp(colors, other.colors, t),
      canvas: Color.lerp(canvas, other.canvas, t)!,
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      featureLibrary: Color.lerp(featureLibrary, other.featureLibrary, t)!,
      featureLibraryFill:
          Color.lerp(featureLibraryFill, other.featureLibraryFill, t)!,
    );
  }
}
